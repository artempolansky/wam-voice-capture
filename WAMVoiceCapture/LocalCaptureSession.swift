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

    private var stt: STTProvider?
    private var audioSubscription: AudioCapture.SubscriptionID?
    private var finalSegments: [String] = []
    private var lastInterim: String = ""
    private var running = false

    // Deepgram lifecycle flags
    private var deepgramClosed = false
    private var deepgramOpened = false

    // Dictation resilience (v1.2.0). Field data: 168 dictations pasted
    // 0 chars because the WS handshake failed once and there was no second
    // attempt, while meetings on the same network survived via
    // reconnect-with-backoff (2203 reconnects logged, up to attempt 244).
    // Dictation gets the same semantics: audio accumulates in `audioTap`
    // for the whole session; on connection failure we retry the WS with
    // the full buffer; if the WS never comes up by stop(), we POST the
    // buffer to Deepgram's REST endpoint as a last resort.
    private let audioTap = DictationAudioTap()
    private var apiKey: String = ""
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private let retryDelay: TimeInterval = 0.6
    /// Set when the current provider reported an error or closed while the
    /// session is still running — signals the retry loop to rebuild.
    private var connectionDead = false
    /// Finals collected by a previous (dead) connection, parked when a retry
    /// begins. v1.2.0 dropped them outright on retry start — field data
    /// (2026-08-19) showed a retry that never opened wiping 3 perfectly good
    /// finals and pasting 0 chars. Now they're parked here and only
    /// discarded when the fresh connection actually OPENS (its full-buffer
    /// replay then re-transcribes everything they covered). At paste time
    /// the stash is the second-to-last resort, just before giving up.
    private var stashedFinals: [String] = []
    private var stashedInterim = ""

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
        apiKey = key

        let provider = prepareSTT(apiKey: key)
        provider.connect()
        self.stt = provider

        attachAudio(stt: provider, preRoll: preRoll)
        armWatchdog()

        running = true
        armRetryLoop()
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
        retryTask?.cancel()
        retryTask = nil
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
        audioTap.reset()
        retryAttempt = 0
        connectionDead = false
        stashedFinals.removeAll()
        stashedInterim = ""
    }

    private func prepareSTT(apiKey: String) -> STTProvider {
        let stt = STTSettings.shared.makeProvider(apiKey: apiKey,
                                                  channels: 1,
                                                  multichannel: false,
                                                  diarize: false)
        let providerLabel = STTSettings.shared.currentProvider.rawValue
        stt.onOpen = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deepgramOpened = true
                self.connectionDead = false
                // The fresh connection owns the transcript now — its replay
                // re-covers everything the parked finals contained.
                self.stashedFinals.removeAll()
                self.stashedInterim = ""
                TrayLog.append("local: \(providerLabel) opened")
            }
        }
        stt.onTranscript = { [weak self] t in
            Task { @MainActor [weak self] in self?.handleTranscript(t) }
        }
        stt.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.handleDeepgramError(err) }
        }
        stt.onClose = { [weak self] code, reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deepgramClosed = true
                // A close while the session is still running means the
                // provider died under us — flag it so the retry loop
                // rebuilds. (Deliberate closes happen after `running`
                // flips false in stop(), so this doesn't misfire.)
                if self.running { self.connectionDead = true }
                // Reason is Deepgram's server-side close message — e.g.
                // "Deepgram did not receive audio data or a text message
                // within the timeout window". Logging it for parity with
                // MeetingSession; previously only the code was visible.
                let suffix = reason.isEmpty ? "" : " — \(reason)"
                TrayLog.append("local: \(providerLabel) closed (code=\(code))\(suffix)")
            }
        }
        return stt
    }

    /// Subscribes the live audio fanout. Every chunk goes through
    /// ``audioTap``, which (a) accumulates the full session audio for
    /// retry/REST-fallback use and (b) forwards to whatever STT provider
    /// is currently attached — the indirection is what lets the retry loop
    /// swap in a fresh provider mid-session without resubscribing.
    /// The tap is a plain (non-MainActor) class so the audio render thread
    /// never hops actors.
    private func attachAudio(stt: STTProvider, preRoll: Data) {
        if !preRoll.isEmpty {
            audioTap.seed(preRoll)
            stt.sendAudio(preRoll)
            TrayLog.append("local: pre-roll \(preRoll.count) bytes flushed")
        }
        audioTap.setTarget(stt)
        audioSubscription = AudioCapture.shared.subscribe { [audioTap] chunk in
            audioTap.ingest(chunk)
        }
    }

    /// Poll loop that rebuilds the Deepgram connection while the session is
    /// running and the current one is dead. Mirrors the meeting-side
    /// reconnect (v1.0.3) that survives VPN blips via sheer persistence —
    /// but on each rebuild the ENTIRE session buffer is resent, and
    /// collected finals are discarded, so the fresh connection owns the
    /// whole transcript (no seams, no duplicates).
    ///
    /// Whisper never enters this loop: it's local, its `connect()` cannot
    /// fail transiently.
    private func armRetryLoop() {
        guard STTSettings.shared.currentProvider == .deepgram else { return }
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            while let self, self.running, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
                guard self.running, !Task.isCancelled else { return }
                guard self.connectionDead else { continue }

                self.retryAttempt += 1
                self.connectionDead = false
                self.deepgramClosed = false
                self.deepgramOpened = false
                // The dead connection may have already emitted some finals.
                // The fresh connection re-transcribes the full buffer, so
                // they must not CO-EXIST with its output (duplicate overlap)
                // — but they must survive in the stash in case this retry
                // never opens (v1.2.0 wiped them here and pasted 0 chars).
                // The stash is cleared in onOpen, the moment the fresh
                // connection takes ownership of the transcript.
                if !self.finalSegments.isEmpty || !self.lastInterim.isEmpty {
                    self.stashedFinals = self.finalSegments
                    self.stashedInterim = self.lastInterim
                }
                self.finalSegments.removeAll()
                self.lastInterim = ""

                let fresh = self.prepareSTT(apiKey: self.apiKey)
                self.stt?.disconnect()
                self.stt = fresh
                fresh.connect()
                // Full-buffer replay: DeepgramClient queues audio sent
                // during the handshake internally, so ordering with the
                // live chunks that follow via the tap is preserved.
                let replay = self.audioTap.attachReplacing(fresh)
                TrayLog.append("local: retry #\(self.retryAttempt) — reconnecting with \(replay) bytes replayed")
            }
        }
    }

    private func armWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkHealth() }
        }
    }

    // MARK: - Event handlers

    private func handleTranscript(_ t: STTTranscript) {
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
        // Any provider error while the session runs marks the connection
        // dead — the retry loop rebuilds it with a full-buffer replay.
        if running { connectionDead = true }
        onError?(err)
    }

    private func checkHealth() {
        guard running, let startedAt = sessionStartedAt else { return }
        // The watchdog exists to catch a Deepgram socket that opened but is
        // silently swallowing audio (no partials, no finals). For batch
        // providers like Local Whisper there are no mid-session transcripts
        // by design — inference runs on ``finish()``. Firing STALLED on
        // Whisper is a false alarm that makes the tray icon strobe red 4 s
        // into every dictation, which the user sees as "the app is broken".
        // Skip the check entirely for batch providers.
        //
        // NOTE (v1.1.0): WhisperLocalClient is now chunked (30 s cadence)
        // so on long meetings segments DO arrive mid-session. But for
        // dictation this still returns before the first tick, so we keep
        // the skip.
        if STTSettings.shared.currentProvider == .whisperLocal { return }
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
        let providerLabel = STTSettings.shared.currentProvider.rawValue
        TrayLog.append("local: stop — provider=\(providerLabel), opened=\(deepgramOpened), transcripts=\(transcriptsReceived)")

        // Post-roll: trailing audio still in the engine pipeline needs to land
        // on the provider before we close. Whisper-local also benefits — gives
        // it a clean tail before batch inference.
        try? await Task.sleep(nanoseconds: UInt64(postRollSeconds * 1_000_000_000))
        if let sub = audioSubscription {
            AudioCapture.shared.unsubscribe(sub)
            audioSubscription = nil
        }
        stt?.finish()  // streaming: CloseStream; batch: triggers inference

        // Wait for the provider to close — Deepgram closes after flushing
        // finals; Whisper-local closes when inference finishes.
        //
        // v1.2.1: the deadline EXTENDS if the connection opens mid-drain.
        // Field data (2026-08-19): a retry connection completed its
        // handshake ~1 s after the fixed 5 s deadline expired — its finals
        // (the whole dictation, re-transcribed from the replay buffer)
        // arrived just after we'd already pasted 0 chars. Now: when we see
        // the open happen during the drain, we re-send finish() (the one
        // sent pre-open may have been swallowed by the handshake) and give
        // the connection 4 more seconds to flush.
        var deadline = Date().addingTimeInterval(deepgramFlushDeadline)
        var sawOpenDuringDrain = deepgramOpened
        while !deepgramClosed, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !sawOpenDuringDrain && deepgramOpened {
                sawOpenDuringDrain = true
                stt?.finish()
                deadline = max(deadline, Date().addingTimeInterval(4.0))
                TrayLog.append("local: connection opened during drain — extending wait for its finals")
            }
        }
        if !deepgramClosed {
            TrayLog.append("local: \(providerLabel) close timeout — pasting what we have (opened=\(deepgramOpened), transcripts=\(transcriptsReceived))")
        }

        stt?.disconnect()
        stt = nil
        audioTap.setTarget(nil)

        var text = finalSegments.joined(separator: " ")
        if text.isEmpty { text = lastInterim }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Last resort (v1.2.0): the streaming path produced nothing — the
        // WS never opened (or died and no retry landed in time). We still
        // hold the entire session's audio in the tap; POST it to Deepgram's
        // REST endpoint in one shot. A single short HTTPS request survives
        // VPN conditions that kill long-lived sockets. Same engine, same
        // params — identical transcription quality, just +1–2 s latency.
        if text.isEmpty, STTSettings.shared.currentProvider == .deepgram {
            let pcm = audioTap.snapshot()
            // Skip if there's nothing worth sending (~< 300 ms of audio).
            if pcm.count > 10_000 {
                TrayLog.append("local: streaming produced 0 chars — trying REST fallback (\(pcm.count) bytes)")
                // Up to 3 attempts, 1 s apart. One attempt proved too
                // fragile in the field — the same VPN blip that killed the
                // WS often eats the first POST too, while the second lands.
                for attempt in 1...3 {
                    do {
                        text = try await DeepgramRESTClient.transcribe(pcm: pcm, apiKey: apiKey)
                        TrayLog.append("local: REST fallback OK (attempt \(attempt)) — \(text.count) chars")
                        break
                    } catch {
                        TrayLog.append("local: REST fallback attempt \(attempt) failed — \(error.localizedDescription)")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                    }
                }
            }
        }

        // Second-to-last resort: a dead connection's parked finals. They
        // cover the dictation only up to the moment that connection died —
        // partial, but real text beats pasting nothing. Only reached when
        // the live finals, the interim, AND the REST fallback all came up
        // empty.
        if text.isEmpty, !stashedFinals.isEmpty || !stashedInterim.isEmpty {
            var stashed = stashedFinals.joined(separator: " ")
            if stashed.isEmpty { stashed = stashedInterim }
            text = stashed.trimmingCharacters(in: .whitespacesAndNewlines)
            TrayLog.append("local: using \(stashedFinals.count) parked finals from the dead connection (\(text.count) chars, may be partial)")
        }

        TrayLog.append("local: pasting \(text.count) chars (finals=\(finalSegments.count), lastInterim=\(lastInterim.count) chars)")

        onFinish?(text)
        if !text.isEmpty { PasteDelivery.paste(text) }

        // On-demand mic: shut the engine back down so the menubar mic
        // indicator goes away between sessions.
        AudioCapture.shared.stop()
        LightControl.shared.setIdleReflectingMic()
    }
}

// MARK: - Dictation audio tap

/// Thread-safe accumulator + router between the audio render thread and
/// the current STT provider. Two jobs:
///
/// 1. **Accumulate** the full session's PCM so the retry loop can replay
///    it into a fresh connection, and the REST fallback can POST it.
/// 2. **Route** live chunks to whatever provider is currently attached —
///    the indirection lets `LocalCaptureSession` swap providers
///    mid-session (on reconnect) without touching the audio subscription.
///
/// Deliberately NOT MainActor: `ingest` runs on the audio render thread
/// and must not hop actors. All state is guarded by one lock; the
/// critical sections are tiny (append + pointer read).
final class DictationAudioTap {

    private let lock = NSLock()
    private var buffer = Data()
    private var target: STTProvider?

    /// Hard cap so a forgotten-running dictation can't eat unbounded RAM.
    /// 20 MB ≈ 10+ minutes of 16 kHz mono Int16 — far beyond any sane
    /// dictation. Beyond the cap: live forwarding continues, accumulation
    /// stops (retry/REST would replay a truncated head, which is still
    /// better than nothing).
    private let maxBufferBytes = 20 * 1024 * 1024

    /// Render-thread entry point: buffer + forward.
    func ingest(_ chunk: Data) {
        lock.lock()
        if buffer.count < maxBufferBytes { buffer.append(chunk) }
        let t = target
        lock.unlock()
        t?.sendAudio(chunk)
    }

    /// Pre-roll seeding (already sent to the first provider by the caller —
    /// only recorded here so retry/REST replays include it).
    func seed(_ preRoll: Data) {
        lock.lock()
        buffer.append(preRoll)
        lock.unlock()
    }

    func setTarget(_ provider: STTProvider?) {
        lock.lock()
        target = provider
        lock.unlock()
    }

    /// Atomically: replay the full buffer into `provider` and make it the
    /// live target. Both happen under one lock so no live chunk can slip
    /// in between the replay and the retarget (which would put audio out
    /// of order on the new connection). The provider's `sendAudio` only
    /// enqueues internally, so holding the lock across it is fine — worst
    /// case the render thread waits a few ms once per reconnect.
    ///
    /// The replay is sliced into 64 KB pieces: DeepgramClient forwards
    /// each `sendAudio` call as one WebSocket frame once open, and a
    /// single multi-megabyte frame is exactly the kind of edge case
    /// proxies/VPNs love to drop. 64 KB × N behaves like normal streaming.
    /// Returns the number of bytes replayed (for logging).
    @discardableResult
    func attachReplacing(_ provider: STTProvider) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let sliceSize = 64 * 1024
        var offset = 0
        while offset < buffer.count {
            let end = min(offset + sliceSize, buffer.count)
            provider.sendAudio(buffer.subdata(in: offset..<end))
            offset = end
        }
        target = provider
        return buffer.count
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: false)
        target = nil
        lock.unlock()
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
