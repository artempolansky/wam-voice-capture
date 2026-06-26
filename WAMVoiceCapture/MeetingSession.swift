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
        case finalizingPreviousMeeting
        case fileCreate(String)
        case systemAudio(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let s):         return "Deepgram API key unavailable: \(s)"
            case .alreadyRunning:               return "Meeting already in progress"
            case .finalizingPreviousMeeting:    return "Previous meeting is still being transcribed. Please wait a few seconds."
            case .fileCreate(let s):            return "Failed to create transcript file: \(s)"
            case .systemAudio(let s):           return "System audio capture failed: \(s)"
            }
        }
    }

    private(set) var isRunning = false
    /// True between `stop()` returning to the UI and the STT provider actually
    /// finishing inference + flushing the transcript to disk. Local Whisper is
    /// batch-mode: a 5-minute meeting can take 30-60 s of single-shot
    /// inference to transcribe. Mic capture and the meeting UI go idle the
    /// moment the user clicks Stop (so the mic indicator disappears
    /// immediately), but the next `start()` is blocked while finalization
    /// runs — otherwise in-flight onTranscript callbacks would write into the
    /// new meeting's file.
    private(set) var isFinalizing = false
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

    // STT provider (Deepgram or local Whisper)
    private var stt: STTProvider?
    private var apiKey: String = ""
    private var reconnectAttempt = 0
    /// Set in the provider's onClose callback. Polled by `stop()` so we
    /// don't close the transcript file before the provider has had a chance
    /// to emit final transcripts. Critical for batch providers like
    /// Local Whisper where inference takes several seconds.
    private var sttClosed = false
    private let maxReconnectDelay: TimeInterval = 30
    private var reconnectTask: Task<Void, Never>?
    private var stoppingDeliberately = false

    // Error log debouncing (v1.0.3). A single dead Deepgram WebSocket
    // produced 50+ identical "Operation canceled" log lines per second in
    // the 2026-06-25 16:00 outage as the mixer timer kept pushing audio
    // into a closed socket. This collapses runs of the same error message
    // within a 10 s window into "first line + count flushed when message
    // changes or window expires".
    private var lastErrorMessage: String?
    private var lastErrorLoggedAt: Date?
    private var suppressedErrorCount: Int = 0
    private let errorDebounceWindow: TimeInterval = 10

    // File
    private var fileHandle: FileHandle?

    // Constants
    private let chunkFrames = 320
    private let bytesPerSample = 2
    private var monoChunkBytes: Int { chunkFrames * bytesPerSample }
    private var stereoChunkBytes: Int { chunkFrames * bytesPerSample * 2 }

    // MARK: - Lifecycle

    /// Start a meeting. If `event` is nil, the caller didn't pick one — but
    /// MeetingSession still tries to auto-detect one via CalendarBridge if the
    /// calendar permission is granted. Either way, the event (if any) is used
    /// for filename and YAML frontmatter.
    func start(event: CalendarBridge.Event? = nil) throws {
        guard !isRunning else { throw SessionError.alreadyRunning }
        // Whisper batch inference from the *previous* meeting may still be
        // running in the background. Starting now would re-bind `self.stt`
        // and `self.fileHandle`, causing in-flight transcripts to write into
        // the new meeting's file (or get dropped). Block until done.
        guard !isFinalizing else { throw SessionError.finalizingPreviousMeeting }

        do {
            apiKey = try KeychainHelper.deepgramAPIKey()
        } catch {
            throw SessionError.missingAPIKey(error.localizedDescription)
        }

        try AudioCapture.shared.ensureRunning()

        // Resolve event: explicit > auto-detected from "now ± 5 min".
        let resolvedEvent = event ?? CalendarBridge.shared.currentEvent()

        let url = try makeTranscriptURL(event: resolvedEvent)
        transcriptURL = url
        guard let handle = try? openTranscriptFile(at: url, event: resolvedEvent) else {
            throw SessionError.fileCreate(url.path)
        }
        fileHandle = handle

        startedAt = Date()
        stoppingDeliberately = false
        reconnectAttempt = 0
        sttClosed = false
        // Reset error-log debounce — a previous meeting's tail-end
        // suppression count must not bleed into this one.
        lastErrorMessage = nil
        lastErrorLoggedAt = nil
        suppressedErrorCount = 0
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

        // Begin STT finalization. For Deepgram this triggers a CloseStream
        // round-trip (~1 s). For Local Whisper this kicks off the batch
        // inference, which can take 5 s for a one-minute meeting up to
        // several minutes for an hour-long one.
        stt?.finish()

        // UI/audio cleanup happens **immediately** — the user's mental model
        // is "I pressed stop, the meeting is over." The mic indicator must
        // turn off now, the tray menu must go back to the idle state. We
        // mark `isFinalizing = true` to gate the next `start()` call, so a
        // user who clicks Start a second later gets a clean error rather
        // than racing the previous meeting's onTranscript callbacks.
        isRunning = false
        isFinalizing = true
        AudioCapture.shared.stop()
        onStateChange?(false)
        let provider = STTSettings.shared.currentProvider.rawValue
        TrayLog.append("meeting: stopped (finalizing \(provider) transcript)")

        Task { @MainActor [self] in
            // Wait for the provider to actually signal close. v1.0.1 removed
            // the previous hard 30 s deadline because batch-mode Whisper
            // legitimately takes minutes for a long meeting; truncating
            // there produced empty transcripts. v1.0.2 adds a much more
            // generous 10-minute upper bound as a safety net for cases
            // where neither `onClose` nor the `handleError`-driven
            // sttClosed-flip ever fires (process hang, kernel panic in
            // whisper-cli, network-layer error not surfaced through
            // delegate, etc.). Without it the meeting stays in
            // `isFinalizing` state forever and blocks every subsequent
            // `start()` call — the 11:03 outage we hit in 1.0.1.
            //
            // Log progress every 10 s so the tray log shows inference is
            // still alive (vs. hung).
            let waitStart = Date()
            let waitDeadline = waitStart.addingTimeInterval(600)  // 10 min hard ceiling
            var lastTick = waitStart
            while !self.sttClosed, Date() < waitDeadline {
                try? await Task.sleep(nanoseconds: 250_000_000)  // 250 ms
                let now = Date()
                if now.timeIntervalSince(lastTick) >= 10 {
                    let elapsed = Int(now.timeIntervalSince(waitStart))
                    TrayLog.append("meeting: \(provider) still transcribing (\(elapsed)s elapsed)…")
                    lastTick = now
                }
            }
            if !self.sttClosed {
                // Safety-net timeout. Whatever the provider was doing, we're
                // proceeding to close the file with what we have so the user
                // can start a new meeting. The mic and engine are already
                // idle since the stop-button click; only the provider
                // resources leak (a stuck whisper-cli process or a dead
                // WebSocket task; both are reclaimed when the next session
                // overwrites `self.stt` or when the app quits).
                TrayLog.append("meeting: \(provider) finalize timeout (>10 min) — proceeding to close the transcript file with what arrived")
            }
            self.stt?.disconnect()
            self.stt = nil
            self.closeFile()
            // Final sync + .done marker on every enabled target. This happens
            // AFTER closeFile() so the file on disk is fully flushed before
            // rsync runs.
            if let url = self.transcriptURL {
                AgentSyncRegistry.shared.noteSessionEnded(file: url, kind: .meeting)
            }
            self.isFinalizing = false
            TrayLog.append("meeting: transcript finalized")
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
        guard let dg = stt else { return }
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
        let provider = STTSettings.shared.makeProvider(
            apiKey: apiKey,
            channels: 2,
            multichannel: true,
            diarize: true
        )
        let label = STTSettings.shared.currentProvider.rawValue
        provider.onOpen = { [weak self] in
            Task { @MainActor [weak self] in
                self?.reconnectAttempt = 0
                // v1.0.3: a fresh socket is open — clear the
                // error-driven sttClosed flag so a future `stop()` waits
                // for THIS provider's actual close instead of exiting the
                // wait loop immediately on the stale flag from the dead
                // socket that preceded this reconnect.
                self?.sttClosed = false
                TrayLog.append("meeting: \(label) opened (multichannel)")
            }
        }
        provider.onTranscript = { [weak self] t in
            Task { @MainActor [weak self] in self?.handleTranscript(t) }
        }
        provider.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.handleError(err) }
        }
        provider.onClose = { [weak self] code, reason in
            Task { @MainActor [weak self] in self?.handleClose(code: code, reason: reason) }
        }
        provider.connect()
        stt = provider
    }

    private func handleTranscript(_ t: STTTranscript) {
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
        let provider = STTSettings.shared.currentProvider.rawValue
        let msg = err.localizedDescription
        logErrorDebounced(provider: provider, message: msg)

        // Treat error as effective close for the *current* provider — the
        // finalize wait in `stop()` must not hang if `onClose` never arrives
        // (the v1.0.2 invariant we still rely on). A successful reconnect
        // below resets this flag back to false in `provider.onOpen`.
        sttClosed = true

        // v1.0.3: trigger reconnect on provider errors too, not only on
        // `onClose`. Real-world outage 2026-06-25 16:00 showed Deepgram
        // emits a stream of URLSession-level errors ("Connection reset by
        // peer", "Operation canceled") without ever firing the WebSocket
        // protocol close — meaning `handleClose` never ran and the meeting
        // went silent for the rest of its duration while still appearing
        // healthy to the user. We were 11 minutes in; the remaining 49 min
        // of audio captured nothing.
        //
        // `scheduleReconnect()` cancels any in-flight reconnect task before
        // queueing a new one, so a 50-error storm collapses into a single
        // pending reconnect with the exponential backoff that's already in
        // place. The `reconnectAttempt` counter resets in `provider.onOpen`
        // once the new socket is healthy.
        guard isRunning, !stoppingDeliberately else { return }
        scheduleReconnect()
    }

    /// Log a provider error with debouncing — collapse runs of the same
    /// message within a 10s window. Called only by handleError.
    private func logErrorDebounced(provider: String, message: String) {
        let now = Date()
        let isSame = (message == lastErrorMessage)
        let withinWindow = (lastErrorLoggedAt.map { now.timeIntervalSince($0) < errorDebounceWindow } ?? false)

        if isSame && withinWindow {
            suppressedErrorCount += 1
            return
        }

        // Either a new message or the window expired — flush any suppressed
        // count from the previous burst before emitting the next line.
        if suppressedErrorCount > 0, let prev = lastErrorMessage {
            TrayLog.append("meeting: \(provider) error — \"\(prev)\" repeated \(suppressedErrorCount) more times")
            suppressedErrorCount = 0
        }
        TrayLog.append("meeting: \(provider) error — \(message)")
        lastErrorMessage = message
        lastErrorLoggedAt = now
    }

    private func handleClose(code: Int, reason: String) {
        // Surface the close reason — Deepgram puts an explanation here for
        // server-side closes (code 1011 etc), and silently dropping it has
        // been hiding root causes when sockets die between meetings.
        let reasonNote = reason.isEmpty ? "" : " — \(reason)"
        TrayLog.append("meeting: \(STTSettings.shared.currentProvider.rawValue) closed (code=\(code))\(reasonNote)")
        // Signal to `stop()`'s poll loop that the provider is done emitting
        // transcripts. Critical for batch providers (Whisper) whose
        // inference can take 5–15 s after `finish()`.
        sttClosed = true
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
                self.stt = nil
                self.connectDeepgram()
            }
        }
    }

    // MARK: - File

    private func makeTranscriptURL(event: CalendarBridge.Event?) throws -> URL {
        let dir = RecordingsFolder.currentURL()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Seconds in the stem so two meetings started within the same minute
        // don't overwrite each other (a real bug in earlier builds).
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let stem = fmt.string(from: Date())
        // Event-aware name: "2026-05-18-143012-standup-with-anya.md".
        // Without an event: "2026-05-18-143012-meeting.md".
        let suffix: String
        if let event, !event.filenameSlug.isEmpty {
            suffix = event.filenameSlug
        } else {
            suffix = "meeting"
        }
        return dir.appendingPathComponent("\(stem)-\(suffix).md")
    }

    private func openTranscriptFile(at url: URL, event: CalendarBridge.Event?) throws -> FileHandle {
        let header = renderHeader(at: url, event: event)
        try header.write(to: url, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    /// File header. With an event, includes YAML frontmatter + title; without,
    /// the legacy `# Meeting <stem>` line for backwards compatibility with
    /// existing agent watchers.
    private func renderHeader(at url: URL, event: CalendarBridge.Event?) -> String {
        guard let event else {
            return "# Meeting \(url.deletingPathExtension().lastPathComponent)\n\n"
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "HH:mm"
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "yyyy-MM-dd"

        var lines: [String] = ["---"]
        lines.append("title: \(yamlSafe(event.title))")
        lines.append("date: \(dateFmt.string(from: event.startDate))")
        lines.append("start: \(timeFmt.string(from: event.startDate))")
        lines.append("end: \(timeFmt.string(from: event.endDate))")
        if !event.attendees.isEmpty {
            let attendees = event.attendees.map { yamlSafe($0) }.joined(separator: ", ")
            lines.append("attendees: [\(attendees)]")
        }
        if let conf = event.conferenceURL {
            lines.append("link: \(conf.absoluteString)")
        }
        lines.append("calendar: \(yamlSafe(event.calendarSource))")
        lines.append("calendar_event_id: \(event.identifier)")
        lines.append("---")
        lines.append("")
        lines.append("# \(event.title)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Quote-and-escape a value if it contains characters YAML treats specially.
    /// Keeps simple values bare so a `cat <file>` of the transcript still reads cleanly.
    private func yamlSafe(_ value: String) -> String {
        let needsQuote = value.contains(":") || value.contains("#") || value.contains("\n") ||
                         value.contains(",") || value.hasPrefix("[") || value.hasPrefix("{") ||
                         value.hasPrefix("-") || value.contains("\"")
        if needsQuote {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            return "\"\(escaped)\""
        }
        return value
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
