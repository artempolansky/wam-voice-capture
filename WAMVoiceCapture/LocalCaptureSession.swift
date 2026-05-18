import AppKit

/// Orchestrates a single dictation session:
/// mic → Deepgram → accumulate finals → paste into the frontmost app on stop.
///
/// `start()` is split into focused helpers:
///   - `validateAudio()`     — fail-fast checks on the mic before opening the WS
///   - `prepareDeepgram()`   — build the WS client + wire its callbacks
///   - `attachAudio()`       — pre-roll flush + live subscription
///   - `armWatchdog()`       — periodic stall detection while running
@MainActor
final class LocalCaptureSession {

    enum SessionError: LocalizedError {
        case missingAPIKey(String)
        case alreadyRunning
        case silentMic(rms: Double)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let s): return "Deepgram API key unavailable: \(s)"
            case .alreadyRunning:       return "Capture session already running"
            case .silentMic(let rms):   return "Mic produces silence (RMS=\(String(format: "%.1f", rms))) — check transmitter / mute / battery"
            }
        }
    }

    // MARK: - Public callbacks

    /// Fired on every partial/final transcript (for UI preview, if any).
    var onTranscript: ((String, Bool) -> Void)?
    /// Fired when the session ends with the final accumulated text.
    var onFinish: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    /// Fires when the watchdog flips between healthy and stalled.
    var onStallChange: ((Bool) -> Void)?

    // MARK: - State

    private var deepgram: DeepgramClient?
    private var audioSubscription: AudioCapture.SubscriptionID?
    private var finalSegments: [String] = []
    private var lastInterim: String = ""
    private var running = false

    // Deepgram lifecycle flags
    private var deepgramClosed = false
    private var deepgramOpened = false

    // Watchdog
    private var transcriptsReceived = 0
    private var sessionStartedAt: Date?
    private var lastTranscriptAt: Date?
    private var watchdog: Timer?
    private var isStalled = false
    private let stallGracePeriod: TimeInterval = 4.0
    private let stallTimeout:    TimeInterval = 4.0

    // Tail timing
    private let postRollSeconds:        TimeInterval = 0.8
    private let deepgramFlushDeadline:  TimeInterval = 5.0

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { throw SessionError.alreadyRunning }

        let key = try resolveAPIKey()
        try AudioCapture.shared.ensureRunning()
        let preRoll = try validateAudio()

        resetSessionState()

        let dg = prepareDeepgram(apiKey: key)
        dg.connect()
        self.deepgram = dg

        attachAudio(deepgram: dg, preRoll: preRoll)
        armWatchdog()

        running = true
        LightControl.shared.set(.recording)
    }

    /// Stops live forwarding, holds subscription open for `postRollSeconds` so
    /// trailing audio reaches Deepgram, sends CloseStream, waits for the server
    /// to close the WS (which only happens after it flushes finals), then pastes.
    /// AVAudioEngine stays running so the pre-roll buffer keeps filling.
    func stop() {
        guard running else { return }
        running = false
        LightControl.shared.set(.processing)
        watchdog?.invalidate()
        watchdog = nil
        if isStalled { onStallChange?(false); isStalled = false }

        let levelSample = AudioCapture.shared.preRollSnapshot()
        let rms = levelSample.rmsInt16()
        TrayLog.append("local: audio level RMS=\(String(format: "%.1f", rms)) over last \(levelSample.count) bytes")

        Task { @MainActor [self] in
            await drainAndPaste()
        }
    }

    // MARK: - start() helpers

    private func resolveAPIKey() throws -> String {
        do {
            return try KeychainHelper.deepgramAPIKey()
        } catch {
            throw SessionError.missingAPIKey(error.localizedDescription)
        }
    }

    /// Returns the pre-roll snapshot. Throws `silentMic` if the buffer is
    /// mature (≥ 80% of the ring) and its RMS is below the silence threshold.
    /// Skipped on a fresh ring so we don't false-positive right after a
    /// device change.
    private func validateAudio() throws -> Data {
        let preRoll = AudioCapture.shared.preRollSnapshot()
        let maxRingBytes = Int(AudioCapture.shared.preRollSeconds * 16000 * 2)
        let mature = preRoll.count >= Int(Double(maxRingBytes) * 0.8)
        guard mature else { return preRoll }
        let rms = preRoll.rmsInt16()
        if rms < 10 {
            TrayLog.append("local: mic silent — pre-roll RMS=\(String(format: "%.1f", rms)) over \(preRoll.count) bytes — failing fast")
            throw SessionError.silentMic(rms: rms)
        }
        return preRoll
    }

    private func resetSessionState() {
        finalSegments.removeAll()
        lastInterim = ""
        deepgramClosed = false
        deepgramOpened = false
        transcriptsReceived = 0
        sessionStartedAt = Date()
        lastTranscriptAt = nil
        isStalled = false
    }

    private func prepareDeepgram(apiKey: String) -> DeepgramClient {
        let dg = DeepgramClient(apiKey: apiKey)
        dg.onOpen = { [weak self] in
            Task { @MainActor [weak self] in
                self?.deepgramOpened = true
                TrayLog.append("local: deepgram WS opened")
            }
        }
        dg.onTranscript = { [weak self] t in
            Task { @MainActor [weak self] in self?.handleTranscript(t) }
        }
        dg.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.handleDeepgramError(err) }
        }
        dg.onClose = { [weak self] code, _ in
            Task { @MainActor [weak self] in
                self?.deepgramClosed = true
                TrayLog.append("local: deepgram WS closed (code=\(code))")
            }
        }
        return dg
    }

    /// Subscribes the live audio fanout to the Deepgram client and ships the
    /// pre-roll snapshot. The subscription handler captures `dg` directly
    /// (not `self`) so it doesn't need to cross the MainActor boundary on the
    /// audio render thread.
    private func attachAudio(deepgram dg: DeepgramClient, preRoll: Data) {
        if !preRoll.isEmpty {
            dg.sendAudio(preRoll)
            TrayLog.append("local: pre-roll \(preRoll.count) bytes flushed")
        }
        audioSubscription = AudioCapture.shared.subscribe { [weak dg] chunk in
            dg?.sendAudio(chunk)
        }
    }

    private func armWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkHealth() }
        }
    }

    // MARK: - Event handlers

    private func handleTranscript(_ t: DeepgramClient.Transcript) {
        transcriptsReceived += 1
        lastTranscriptAt = Date()
        if t.isFinal {
            let trimmed = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { finalSegments.append(trimmed) }
            lastInterim = ""
        } else {
            lastInterim = t.text
        }
        onTranscript?(t.text, t.isFinal)
        // Any non-empty transcript clears a stall.
        if !t.text.isEmpty, isStalled {
            isStalled = false
            onStallChange?(false)
        }
    }

    private func handleDeepgramError(_ err: Error) {
        // ENOTCONN ('Socket is not connected') is benign tail-end noise after
        // CloseStream, when the server has already closed gracefully.
        let nse = err as NSError
        let benign = (nse.domain == NSPOSIXErrorDomain && nse.code == 57)
                   || err.localizedDescription.contains("Socket is not connected")
        if benign && !running { return }
        onError?(err)
    }

    private func checkHealth() {
        guard running, let startedAt = sessionStartedAt else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(startedAt)
        var stalled = false
        if elapsed > stallGracePeriod {
            if transcriptsReceived == 0 {
                stalled = true
            } else if let last = lastTranscriptAt, now.timeIntervalSince(last) > stallTimeout {
                stalled = true
            }
        }
        if stalled != isStalled {
            isStalled = stalled
            TrayLog.append("local: watchdog -> \(stalled ? "STALLED" : "ok") (elapsed=\(String(format: "%.1f", elapsed))s, transcripts=\(transcriptsReceived))")
            onStallChange?(stalled)
        }
    }

    // MARK: - stop() helpers

    private func drainAndPaste() async {
        let chunksAtStop = deepgram?.chunksSent ?? 0
        let bytesAtStop  = deepgram?.bytesSent  ?? 0
        TrayLog.append("local: stop — opened=\(deepgramOpened), chunks=\(chunksAtStop), bytes=\(bytesAtStop), transcripts=\(transcriptsReceived)")

        // Post-roll: trailing audio still in the engine/converter/WS pipeline
        // needs to land on Deepgram before we close the stream.
        try? await Task.sleep(nanoseconds: UInt64(postRollSeconds * 1_000_000_000))
        if let sub = audioSubscription {
            AudioCapture.shared.unsubscribe(sub)
            audioSubscription = nil
        }
        deepgram?.finish()  // CloseStream — server flushes finals then closes.

        // Wait for the server to close — Deepgram only closes after all finals.
        let deadline = Date().addingTimeInterval(deepgramFlushDeadline)
        while !deepgramClosed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !deepgramClosed {
            let chunks = deepgram?.chunksSent ?? 0
            TrayLog.append("local: deepgram close timeout — pasting what we have (opened=\(deepgramOpened), chunks=\(chunks), transcripts=\(transcriptsReceived))")
        }

        deepgram?.disconnect()
        deepgram = nil

        var text = finalSegments.joined(separator: " ")
        if text.isEmpty { text = lastInterim }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        TrayLog.append("local: pasting \(text.count) chars (finals=\(finalSegments.count), lastInterim=\(lastInterim.count) chars)")

        onFinish?(text)
        if !text.isEmpty { PasteDelivery.paste(text) }

        // On-demand mic: shut the engine back down so the menubar mic
        // indicator goes away between sessions.
        AudioCapture.shared.stop()
        LightControl.shared.setIdleReflectingMic()
    }
}

// MARK: - Paste delivery

/// Writes text to the clipboard and synthesizes ⌘V into the frontmost app.
/// Non-zero delay between writing and paste is required on some apps;
/// keep it short.
enum PasteDelivery {

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Brief delay so the new clipboard value is visible to the target app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            sendCommandV()
        }
    }

    private static func sendCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        let loc = CGEventTapLocation.cghidEventTap
        down?.post(tap: loc)
        up?.post(tap: loc)
    }
}

extension Data {
    /// Root-mean-square amplitude of Int16 PCM samples. ~0 = silence, ~32768 = clipping.
    func rmsInt16() -> Double {
        guard count >= 2 else { return 0 }
        let sampleCount = count / 2
        var sumSquares: Double = 0
        self.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let s = Double(ptr[i])
                sumSquares += s * s
            }
        }
        return (sumSquares / Double(sampleCount)).squareRoot()
    }
}
