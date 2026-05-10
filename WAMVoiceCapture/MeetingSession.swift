import AppKit
import ScreenCaptureKit

/// Continuous meeting recording. Separate from `LocalCaptureSession` (FN
/// push-to-talk) — designed for 30 min – 2 hour sessions with auto-reconnect
/// to Deepgram and live-append to a markdown transcript file.
///
/// Audio routing: mic → channel 0 (Me), system audio → channel 1 (Others).
/// Interleaved 16 kHz Int16 stereo PCM is streamed to Deepgram with
/// `multichannel=true` so each Result carries a `channel_index` and the
/// transcript can label the speaker side.
@MainActor
final class MeetingSession {

    static let shared = MeetingSession()

    enum SessionError: LocalizedError {
        case missingAPIKey(String)
        case alreadyRunning
        case fileCreate(String)
        case systemAudio(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let s): return "Deepgram API key unavailable: \(s)"
            case .alreadyRunning:       return "Meeting already in progress"
            case .fileCreate(let s):    return "Failed to create transcript file: \(s)"
            case .systemAudio(let s):   return "System audio capture failed: \(s)"
            }
        }
    }

    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var transcriptURL: URL?

    var onStateChange: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?

    // Audio routing
    private var subscription: AudioCapture.SubscriptionID?
    private var systemCapture: AnyObject? // SystemAudioCapture, weak-typed to avoid availability guard at property level

    /// When `false`, mic chunks are dropped before they reach the mixer —
    /// channel 0 stays silent and Deepgram emits no `[Me]` transcripts.
    /// Toggled via `setMeCapture(_:)` from the FN-key handler during a meeting.
    private var meCaptureActive: Bool = false

    // Per-channel ring buffers for mic + system. Each holds 16 kHz Int16
    // mono samples; we pop 320 frames from each every 20 ms and interleave
    // into a stereo chunk for Deepgram.
    private let mixerLock = NSLock()
    private var micQueue = Data()
    private var systemQueue = Data()
    private var mixerTimer: Timer?

    // Deepgram
    private var deepgram: DeepgramClient?
    private var apiKey: String = ""
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 30
    private var reconnectTask: Task<Void, Never>?
    private var stoppingDeliberately = false

    // File
    private var fileHandle: FileHandle?

    // Constants
    private let chunkFrames = 320
    private let bytesPerSample = 2
    private var monoChunkBytes: Int { chunkFrames * bytesPerSample }
    private var stereoChunkBytes: Int { chunkFrames * bytesPerSample * 2 }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { throw SessionError.alreadyRunning }

        do {
            apiKey = try KeychainHelper.deepgramAPIKey()
        } catch {
            throw SessionError.missingAPIKey(error.localizedDescription)
        }

        try AudioCapture.shared.ensureRunning()

        let url = try makeTranscriptURL()
        transcriptURL = url
        guard let handle = try? openTranscriptFile(at: url) else {
            throw SessionError.fileCreate(url.path)
        }
        fileHandle = handle

        startedAt = Date()
        stoppingDeliberately = false
        reconnectAttempt = 0
        clearMixerBuffers()

        attachMic()
        connectDeepgram()
        startMixerTimer()

        // System-audio is async (SCStream permission + start) — kick it off.
        // It joins the stream when ready; the meeting still works in the
        // meantime as mic-only.
        startSystemAudio()

        isRunning = true
        TrayLog.append("meeting: started -> \(url.path)")
        onStateChange?(true)
    }

    func stop() {
        guard isRunning else { return }
        stoppingDeliberately = true
        reconnectTask?.cancel()
        reconnectTask = nil

        mixerTimer?.invalidate()
        mixerTimer = nil

        if let sub = subscription {
            AudioCapture.shared.unsubscribe(sub)
            subscription = nil
        }
        stopSystemAudio()

        deepgram?.finish()
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.deepgram?.disconnect()
            self.deepgram = nil
            self.closeFile()
            self.isRunning = false
            self.onStateChange?(false)
            TrayLog.append("meeting: stopped")
        }
    }

    var elapsedSeconds: TimeInterval {
        guard let started = startedAt, isRunning else { return 0 }
        return Date().timeIntervalSince(started)
    }

    // MARK: - Wiring

    private func attachMic() {
        if let sub = subscription { AudioCapture.shared.unsubscribe(sub) }
        subscription = AudioCapture.shared.subscribe { [weak self] chunk in
            guard let self else { return }
            self.mixerLock.lock()
            // FN gates whether mic audio enters the [Me] channel. While the
            // user isn't holding FN, drop the chunk so channel 0 stays silent.
            if self.meCaptureActive {
                self.micQueue.append(chunk)
            }
            self.mixerLock.unlock()
        }
    }

    /// Push-to-record-me: called from the FN handler during a meeting.
    /// On rising edge we prepend the AudioCapture pre-roll snapshot so the
    /// first 1.5 s of the user's utterance (often spoken just before they
    /// reach for FN) lands in `[Me]`.
    func setMeCapture(_ active: Bool) {
        guard isRunning else { return }
        guard active != meCaptureActive else { return }
        if active {
            let preRoll = AudioCapture.shared.preRollSnapshot()
            mixerLock.lock()
            if !preRoll.isEmpty { micQueue.append(preRoll) }
            meCaptureActive = true
            mixerLock.unlock()
            TrayLog.append("meeting: [Me] capture ON (FN held)")
        } else {
            mixerLock.lock()
            meCaptureActive = false
            mixerLock.unlock()
            TrayLog.append("meeting: [Me] capture OFF (FN released)")
        }
    }

    private func startSystemAudio() {
        guard #available(macOS 13.0, *) else {
            TrayLog.append("meeting: system audio capture requires macOS 13+ — skipping")
            return
        }
        let sys = SystemAudioCapture()
        sys.onAudioChunk = { [weak self] chunk in
            guard let self else { return }
            self.mixerLock.lock()
            self.systemQueue.append(chunk)
            self.mixerLock.unlock()
        }
        sys.onError = { [weak self] err in
            DispatchQueue.main.async {
                TrayLog.append("meeting: system audio error — \(err.localizedDescription)")
                self?.onError?(err)
            }
        }
        systemCapture = sys
        Task { [weak sys] in
            do {
                try await sys?.start()
                await MainActor.run {
                    TrayLog.append("meeting: system audio capture started")
                }
            } catch {
                await MainActor.run {
                    TrayLog.append("meeting: system audio failed to start — \(error.localizedDescription). Continuing mic-only.")
                }
            }
        }
    }

    private func stopSystemAudio() {
        guard #available(macOS 13.0, *), let sys = systemCapture as? SystemAudioCapture else {
            systemCapture = nil
            return
        }
        Task { await sys.stop() }
        systemCapture = nil
    }

    private func startMixerTimer() {
        // 50 Hz to match the chunk cadence — interleave one 20 ms stereo chunk per tick.
        mixerTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.mixerTick() }
        }
    }

    private func mixerTick() {
        guard let dg = deepgram else { return }
        mixerLock.lock()
        // Cap each queue at ~2s of audio so a stalled source can't grow
        // memory unbounded. We drop *oldest* samples to keep the live edge.
        capQueue(&micQueue, maxBytes: monoChunkBytes * 100)
        capQueue(&systemQueue, maxBytes: monoChunkBytes * 100)
        let mic = pullMono(from: &micQueue)
        let sys = pullMono(from: &systemQueue)
        mixerLock.unlock()

        var stereo = Data(count: stereoChunkBytes)
        mic.withUnsafeBytes { mb in
            sys.withUnsafeBytes { sb in
                stereo.withUnsafeMutableBytes { db in
                    let mPtr = mb.bindMemory(to: Int16.self)
                    let sPtr = sb.bindMemory(to: Int16.self)
                    let dPtr = db.bindMemory(to: Int16.self)
                    for i in 0..<chunkFrames {
                        dPtr[2 * i]     = mPtr[i]
                        dPtr[2 * i + 1] = sPtr[i]
                    }
                }
            }
        }
        dg.sendAudio(stereo)
    }

    private func pullMono(from queue: inout Data) -> Data {
        if queue.count >= monoChunkBytes {
            let chunk = Data(queue.prefix(monoChunkBytes))
            queue.removeFirst(monoChunkBytes)
            return chunk
        }
        // Not enough — emit silence so the stereo cadence stays steady. This
        // prevents the mixer from drifting if one source pauses briefly.
        return Data(count: monoChunkBytes)
    }

    private func capQueue(_ queue: inout Data, maxBytes: Int) {
        if queue.count > maxBytes {
            queue.removeFirst(queue.count - maxBytes)
        }
    }

    private func clearMixerBuffers() {
        mixerLock.lock()
        micQueue.removeAll()
        systemQueue.removeAll()
        mixerLock.unlock()
    }

    private func connectDeepgram() {
        let dg = DeepgramClient(
            apiKey: apiKey,
            channels: 2,
            multichannel: true
        )
        dg.onOpen = { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconnectAttempt = 0
                TrayLog.append("meeting: deepgram WS opened (multichannel)")
            }
        }
        dg.onTranscript = { [weak self] t in
            Task { @MainActor [weak self] in self?.handleTranscript(t) }
        }
        dg.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.handleError(err) }
        }
        dg.onClose = { [weak self] code, reason in
            Task { @MainActor [weak self] in self?.handleClose(code: code, reason: reason) }
        }
        dg.connect()
        deepgram = dg
    }

    private func handleTranscript(_ t: DeepgramClient.Transcript) {
        guard t.isFinal else { return }
        let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let label: String
        switch t.channelIndex {
        case 0: label = "Me"
        case 1: label = "Others"
        default: label = ""
        }
        appendLine(trimmed, label: label)
    }

    private func handleError(_ err: Error) {
        TrayLog.append("meeting: deepgram error — \(err.localizedDescription)")
    }

    private func handleClose(code: Int, reason: String) {
        TrayLog.append("meeting: deepgram WS closed (code=\(code))")
        guard isRunning, !stoppingDeliberately else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        let delay = min(Double(reconnectAttempt) * 2.0, maxReconnectDelay)
        TrayLog.append("meeting: reconnecting in \(String(format: "%.0f", delay))s (attempt \(reconnectAttempt))")
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isRunning, !self.stoppingDeliberately else { return }
                self.deepgram = nil
                self.connectDeepgram()
            }
        }
    }

    // MARK: - File

    private func makeTranscriptURL() throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("WAM Voice Capture Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        let stem = fmt.string(from: Date())
        return dir.appendingPathComponent("\(stem)-meeting.md")
    }

    private func openTranscriptFile(at url: URL) throws -> FileHandle {
        let header = "# Meeting \(url.deletingPathExtension().lastPathComponent)\n\n"
        try header.write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func appendLine(_ text: String, label: String) {
        guard let handle = fileHandle else { return }
        let timestamp: String = {
            let fmt = DateFormatter()
            fmt.dateFormat = "HH:mm:ss"
            return fmt.string(from: Date())
        }()
        let line = label.isEmpty
            ? "[\(timestamp)] \(text)\n"
            : "[\(timestamp)] [\(label)] \(text)\n"
        if let data = line.data(using: .utf8) {
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } catch {
                TrayLog.append("meeting: write failed — \(error.localizedDescription)")
            }
        }
    }

    private func closeFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }
}
