import AppKit
import ScreenCaptureKit

/// Continuous meeting recording. Separate from `LocalCaptureSession` (FN
/// push-to-talk) — designed for 30 min – 2 hour sessions with auto-reconnect
/// to Deepgram and live-append to a markdown transcript file.
///
/// Audio routing: mic → channel 0 (Speaker 1, always you), system audio →
/// channel 1 (Speaker 2, 3, ... via diarization). Interleaved 16 kHz Int16
/// stereo PCM is streamed to Deepgram with `multichannel=true` AND
/// `diarize=true`. Per-result `words[]` carry per-word speaker IDs which we
/// group into segments so multi-speaker results emit multiple lines.
///
/// Apple AEC (`voiceProcessingEnabled` on `AVAudioEngine.inputNode`) is
/// enabled at the AudioCapture layer to suppress speaker bleed-through into
/// the mic channel when the user is on speakers — that way Speaker 2's voice
/// played through the laptop speakers doesn't echo into Speaker 1's channel.
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

    /// Speaker labels for the active session. Mic is always Speaker 1; system
    /// audio speakers are numbered Speaker 2, 3, ... in order of appearance.
    /// User-visible labels are mutable via `renameSpeaker(_:to:)`.
    let speakers = SpeakerLabels()

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
        speakers.reset()

        attachMic()
        connectDeepgram()
        startMixerTimer()

        // System-audio is async (SCStream permission + start) — kick it off.
        // It joins the stream when ready; the meeting still works in the
        // meantime as mic-only.
        startSystemAudio()

        isRunning = true
        TrayLog.append("meeting: started -> \(url.path)")
        // Notify sync targets: file exists, rsync the header immediately so
        // any watcher on the remote side sees a fresh meeting starting.
        AgentSyncRegistry.shared.noteSessionStarted(file: url, kind: .meeting)
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
            // Final sync + .done marker on every enabled target. This happens
            // AFTER closeFile() so the file on disk is fully flushed before
            // rsync runs.
            if let url = self.transcriptURL {
                AgentSyncRegistry.shared.noteSessionEnded(file: url, kind: .meeting)
            }
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
        // Mic is recorded continuously into channel 0 (Speaker 1). The
        // FN-hold gate from VoiceMax 1.0.0 is gone — Apple AEC suppresses
        // speaker bleed-through, so we don't need to choke the mic to avoid
        // echo when the user is on laptop speakers.
        subscription = AudioCapture.shared.subscribe { [weak self] chunk in
            guard let self else { return }
            self.mixerLock.lock()
            self.micQueue.append(chunk)
            self.mixerLock.unlock()
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
            multichannel: true,
            diarize: true
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
        let channel = t.channelIndex ?? 0

        // No words[] → either diarization is off or this final has no words.
        // Fallback: emit one line with the full transcript labelled by channel.
        guard !t.words.isEmpty else {
            let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let id = speakers.internalID(channel: channel, dgSpeaker: nil)
            appendSegment(text: trimmed, speakerID: id)
            return
        }

        // Group consecutive words by speaker so a multi-speaker result emits
        // one line per speaker rather than collapsing to a single label.
        var segmentText = ""
        var segmentSpeaker: Int?
        var first = true

        for word in t.words {
            if first || word.speaker == segmentSpeaker {
                if !segmentText.isEmpty { segmentText += " " }
                segmentText += word.text
                segmentSpeaker = word.speaker
                first = false
            } else {
                let id = speakers.internalID(channel: channel, dgSpeaker: segmentSpeaker)
                appendSegment(text: segmentText, speakerID: id)
                segmentText = word.text
                segmentSpeaker = word.speaker
            }
        }
        if !segmentText.isEmpty {
            let id = speakers.internalID(channel: channel, dgSpeaker: segmentSpeaker)
            appendSegment(text: segmentText, speakerID: id)
        }
    }

    private func appendSegment(text: String, speakerID: SpeakerLabels.InternalID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let label = speakers.displayName(for: speakerID)
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
            fmt.dateFormat = "HH:mm"
            return fmt.string(from: Date())
        }()
        // Format per spec FR-M5: "HH:MM Speaker N: text" or "HH:MM <name>: text".
        // No brackets — keeps the file readable when piped through `tail -f`.
        let line = label.isEmpty
            ? "\(timestamp) \(text)\n"
            : "\(timestamp) \(label): \(text)\n"
        if let data = line.data(using: .utf8) {
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                // Tell sync targets the file changed; debounced inside the
                // registry so rapid-fire appends collapse to one rsync.
                if let url = self.transcriptURL {
                    AgentSyncRegistry.shared.noteFileUpdated(file: url, kind: .meeting)
                }
            } catch {
                TrayLog.append("meeting: write failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Speaker rename (live)

    /// Rename a speaker. Updates the tray label and rewrites the transcript
    /// file in place: every line currently labelled `<oldLabel>:` becomes
    /// `<newLabel>:`. Subsequent lines from this speaker also use the new
    /// label.
    ///
    /// Returns true on success, false if the rename was a no-op (empty name,
    /// unchanged, or speaker unknown).
    @discardableResult
    func renameSpeaker(_ id: SpeakerLabels.InternalID, to newName: String) -> Bool {
        guard let change = speakers.rename(id, to: newName) else { return false }
        rewriteFileLabel(from: change.oldLabel, to: change.newLabel)
        TrayLog.append("meeting: rename \(change.oldLabel) → \(change.newLabel)")
        return true
    }

    /// Replace `<oldLabel>:` with `<newLabel>:` on every line of the
    /// transcript file. Naïve full-file rewrite; meetings produce kilobytes
    /// of text per minute so this is cheap. Done in place — we close the
    /// append handle, rewrite, then reopen for append at EOF.
    private func rewriteFileLabel(from oldLabel: String, to newLabel: String) {
        guard let url = transcriptURL else { return }
        // Flush any in-flight write, then drop the handle so we have an
        // exclusive view of the file content.
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil

        do {
            var content = try String(contentsOf: url, encoding: .utf8)
            // Per-line replacement: split on newline, rewrite leading
            // "HH:MM <oldLabel>: " to "HH:MM <newLabel>: ". This pattern is
            // anchored on the timestamp so it can't false-match label-like
            // text inside transcripts.
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            var rewritten: [String] = []
            rewritten.reserveCapacity(lines.count)
            let oldPrefix = " \(oldLabel): "
            let newPrefix = " \(newLabel): "
            for line in lines {
                let s = String(line)
                if let range = s.range(of: oldPrefix),
                   range.lowerBound == s.index(s.startIndex, offsetBy: 5, limitedBy: s.endIndex) {
                    // Char positions 0-4 = "HH:MM"; range.lowerBound at offset 5 means
                    // " Speaker N: " starts right after the timestamp.
                    rewritten.append(s.replacingCharacters(in: range, with: newPrefix))
                } else {
                    rewritten.append(s)
                }
            }
            content = rewritten.joined(separator: "\n")
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            TrayLog.append("meeting: rewrite failed — \(error.localizedDescription)")
        }

        // Reopen for append at EOF for subsequent writes.
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            fileHandle = h
        } catch {
            TrayLog.append("meeting: failed to reopen handle after rewrite — \(error.localizedDescription)")
        }

        // After rewrite, push the renamed file to sync targets so the agent
        // sees the updated labels right away. Without this the watcher would
        // still see "Speaker 2" until the next live append triggered debounce.
        AgentSyncRegistry.shared.noteFileUpdated(file: url, kind: .meeting)
    }

    private func closeFile() {
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
    }
}
