import Foundation

/// On-device speech-to-text via the ``whisper-cli`` CLI from
/// ``brew install whisper-cpp``. Fully offline — no network calls,
/// no API keys, no VPN-related drops.
///
/// **v1.1.0: chunked inference during the meeting.**
///
/// Previously we accumulated the entire meeting into one buffer and ran
/// ``whisper-cli`` once at ``finish()``. That broke down on real usage:
/// a 60-minute meeting produced a 200+ MB WAV that reliably hung
/// ``whisper-cli`` inside miniaudio decoding (process in `S` state, near
/// zero CPU, never returned). The safety-net ceiling in
/// ``MeetingSession`` would eventually free the app, but the transcript
/// was empty and the user lost the meeting.
///
/// Now: a timer fires every ``flushInterval`` (30 s by default). On each
/// tick, whatever audio has accumulated since the last flush is swapped
/// out of the buffer atomically and enqueued to a serial inference
/// queue. Each chunk is a manageable ~1–2 MB WAV that ``whisper-cli``
/// processes in a few seconds. Segments arrive live on ``onTranscript``
/// and MeetingSession appends them to the transcript file as they come.
/// On ``finish()`` we invalidate the timer, enqueue the remaining
/// partial chunk, and then enqueue a synthetic-close task — the serial
/// queue guarantees the close fires after all pending chunks (in-flight
/// timer chunk + final partial) have completed.
///
/// Trade-offs vs. Deepgram:
///
/// - ✅ Offline; VPN-independent
/// - ✅ No per-minute API cost
/// - ✅ Live segments (chunked, not batch) — file grows during the meeting
/// - ❌ ~30-second buffering lag before segments show up
/// - ❌ No within-channel diarization (channel-based labeling still works)
/// - ❌ Small edge errors at chunk boundaries (words cut mid-utterance);
///   MVP accepts this, adding overlap is future work.
///
/// Model lives at
/// ``~/Library/Application Support/WAM Voice Capture/models/ggml-<name>.bin``.
final class WhisperLocalClient: NSObject, STTProvider {

    // MARK: STTProvider conformance

    var onTranscript: ((STTTranscript) -> Void)?
    var onError: ((Error) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((Int, String) -> Void)?

    // MARK: Static helpers — install detection

    /// Filesystem path of the ``whisper-cli`` binary, or nil if not installed.
    static var binaryPath: String? {
        for candidate in ["/opt/homebrew/bin/whisper-cli",
                          "/usr/local/bin/whisper-cli"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static var isInstalled: Bool { binaryPath != nil }

    /// Default model path. Dynamically picks the best ``ggml-*.bin`` available
    /// in the models directory. Quality order: large-v3 > large > medium >
    /// small > base > tiny. Users drop any model file into the directory and
    /// the client uses the best one without code changes.
    static var modelPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let dir = base.appendingPathComponent("WAM Voice Capture/models",
                                              isDirectory: true)
        let priority = ["large-v3", "large-v2", "large", "medium",
                         "small", "base", "tiny"]
        for stem in priority {
            for variant in ["\(stem).bin", "\(stem).en.bin"] {
                let p = dir.appendingPathComponent("ggml-\(variant)")
                if FileManager.default.fileExists(atPath: p.path) {
                    return p.path
                }
            }
        }
        // Fallback path — used only by `modelExists` to say "yes, this is
        // where we'd put it" when nothing is installed yet.
        return dir.appendingPathComponent("ggml-base.bin").path
    }

    static var modelExists: Bool {
        FileManager.default.fileExists(atPath: modelPath)
    }

    // MARK: - Configuration (per session)

    /// 1 for dictation (mic only), 2 for meetings (mic + system interleaved
    /// stereo). The session that interleaves into stereo is upstream; we
    /// just need to know how to write the WAV.
    let channels: Int

    /// Language hint for whisper-cli (``ru``, ``en``, ``auto``).
    let language: String

    /// How long each chunk of audio is before we invoke whisper-cli on it.
    /// 30 s matches whisper's native context window — larger risks the
    /// original hang bug, smaller wastes model-load overhead. Only Meeting
    /// sessions ever hit this timer; dictations always finish() before
    /// the first tick.
    private let flushInterval: TimeInterval = 30

    init(channels: Int, language: String = "ru") {
        self.channels = max(1, min(channels, 2))
        self.language = language
        super.init()
    }

    // MARK: - State

    private let lock = NSLock()

    private enum Phase {
        case idle
        case open       // accepting audio, timer flushing chunks
        case closing    // finish() called, final chunk + close in queue
        case closed
    }
    private var phase: Phase = .idle

    /// Audio accumulated since the last chunk flush. Interleaved-stereo
    /// (or mono) Int16 PCM at 16 kHz.
    private var pendingBuffer = Data()

    /// Serial queue that runs `whisper-cli` invocations one at a time.
    /// Guarantees onTranscript arrives in chronological order across
    /// chunks, and guarantees the synthetic-close task enqueued in
    /// `finish()` runs after every prior chunk has completed.
    private let inferenceQueue = DispatchQueue(
        label: "com.artempolansky.wam-voice-capture.whisper-inference",
        qos: .userInitiated
    )

    /// Timer fires every ``flushInterval`` seconds while the session is
    /// open, invoking `flushChunk` on the main queue.
    private var flushTimer: Timer?

    /// Monotonic counter for chunk logging only. Reset in connect().
    private var chunkCounter: Int = 0

    // MARK: - STTProvider methods

    func connect() {
        lock.lock()
        phase = .open
        pendingBuffer.removeAll(keepingCapacity: true)
        chunkCounter = 0
        lock.unlock()

        // Validate setup once at session start; if anything is missing,
        // fire onError + onClose synthetically so the session-level
        // reconnect/error UI catches it.
        guard Self.isInstalled else {
            onError?(WhisperError.notInstalled)
            onClose?(1011, "whisper-cli not installed")
            return
        }
        guard Self.modelExists else {
            onError?(WhisperError.modelMissing(Self.modelPath))
            onClose?(1011, "model file missing at \(Self.modelPath)")
            return
        }

        // Kick off the chunk flush timer. Timer runs on main runloop; its
        // callback dispatches the heavy WAV-write + whisper-cli work onto
        // the serial inference queue so main stays responsive.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushTimer?.invalidate()
            self.flushTimer = Timer.scheduledTimer(
                withTimeInterval: self.flushInterval,
                repeats: true
            ) { [weak self] _ in
                self?.flushChunk(isFinal: false)
            }
        }

        // Synthetic "opened" — we have no real connection but the session
        // expects this event to know it's safe to start streaming chunks.
        onOpen?()
    }

    func sendAudio(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .open else { return }
        pendingBuffer.append(pcm)
    }

    func finish() {
        lock.lock()
        guard phase == .open else { lock.unlock(); return }
        phase = .closing
        lock.unlock()

        // Stop firing new chunk flushes. The timer's own callback may already
        // be in-flight (running on main runloop) — that's fine; if it swaps
        // out a chunk after we invalidate here, it just gets processed in
        // order on the inference queue before our final chunk.
        DispatchQueue.main.async { [weak self] in
            self?.flushTimer?.invalidate()
            self?.flushTimer = nil
        }

        // Flush the last partial chunk (anything since the last timer tick).
        // Even if the timer never fired (short dictation), this handles the
        // whole session's audio.
        flushChunk(isFinal: true)

        // Enqueue a close notifier AFTER the final chunk. The serial queue
        // guarantees this runs after every prior runInference completes.
        // STRONG self capture — MeetingSession may release its reference to
        // us before this fires; we must keep ourselves alive long enough to
        // notify.
        inferenceQueue.async {
            self.lock.lock()
            self.phase = .closed
            self.pendingBuffer.removeAll(keepingCapacity: false)
            self.lock.unlock()
            self.onClose?(1000, "")
        }
    }

    func disconnect() {
        lock.lock()
        let wasOpen = phase != .closed
        phase = .closed
        pendingBuffer.removeAll(keepingCapacity: false)
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.flushTimer?.invalidate()
            self?.flushTimer = nil
        }

        if wasOpen {
            onClose?(1000, "")
        }
    }

    // MARK: - Chunking

    /// Atomically swap the pending buffer out, then dispatch inference on it
    /// via the serial queue. Safe to call from any thread; the swap under
    /// the lock is atomic and short.
    ///
    /// Called from:
    /// - `flushTimer` every `flushInterval` seconds while open
    /// - `finish()` once with `isFinal=true` to drain the tail
    ///
    /// A chunk with less than ~200 ms of audio (below `minChunkBytes`) is
    /// skipped — whisper-cli's model-load overhead alone dwarfs the value
    /// of transcribing a fragment that short, and it produces lots of
    /// hallucinations.
    private func flushChunk(isFinal: Bool) {
        lock.lock()
        let chunk = pendingBuffer
        pendingBuffer.removeAll(keepingCapacity: true)
        chunkCounter += 1
        let counter = chunkCounter
        lock.unlock()

        // Minimum audio to bother invoking whisper: 200 ms per channel.
        // 200 ms * 16000 Hz * 2 bytes/sample * channels = 6400 * channels.
        let minChunkBytes = 200 * 16 * 2 * channels
        if chunk.count < minChunkBytes {
            if isFinal {
                TrayLog.append("whisper: skip final chunk #\(counter) — only \(chunk.count) bytes")
            }
            return
        }

        // STRONG self capture — see comment in finish() for why.
        inferenceQueue.async {
            let ms = chunk.count / (16 * 2 * self.channels)
            let tag = isFinal ? "final" : "tick"
            TrayLog.append("whisper: chunk #\(counter) (\(tag), \(ms)ms audio) → inferring")
            let started = ProcessInfo.processInfo.systemUptime
            self.runInference(on: chunk)
            let took = ProcessInfo.processInfo.systemUptime - started
            TrayLog.append("whisper: chunk #\(counter) done in \(String(format: "%.1f", took))s")
        }
    }

    // MARK: - Inference

    /// Process a single chunk of interleaved-stereo (or mono) PCM through
    /// whisper-cli. Emits onTranscript per segment. Does NOT touch phase
    /// or fire onClose — the caller (flushChunk + close notifier in
    /// finish/disconnect) owns lifecycle.
    private func runInference(on pcm: Data) {
        if pcm.isEmpty { return }

        // Write a 16 kHz WAV with the chunk.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wam-whisper-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        do {
            try WAVWriter.write(pcm: pcm,
                                sampleRate: 16000,
                                channels: channels,
                                to: tmpURL)
        } catch {
            onError?(error)
            return
        }

        // For meetings with stereo input, run whisper twice (once per
        // channel) so we can label transcripts by channel. Otherwise
        // whisper would just mix both into one stream and we'd lose the
        // mic-vs-system distinction.
        if channels == 2 {
            do {
                let (left, right) = try WAVWriter.splitStereoToMono(
                    sourceWAV: tmpURL,
                    sampleRate: 16000
                )
                defer {
                    try? FileManager.default.removeItem(at: left)
                    try? FileManager.default.removeItem(at: right)
                }
                // Skip a channel entirely if it's effectively silent —
                // small models otherwise hallucinate "АПЛОДИСМЕНТЫ" etc.
                // on pure silence. Threshold of 80 is just above ambient
                // noise floor for our 16-bit PCM (max amplitude 32767).
                if WAVWriter.rms(of: left) >= 80 {
                    try invokeWhisper(wav: left, channelIndex: 0)
                }
                if WAVWriter.rms(of: right) >= 80 {
                    try invokeWhisper(wav: right, channelIndex: 1)
                }
            } catch {
                onError?(error)
            }
        } else {
            do {
                try invokeWhisper(wav: tmpURL, channelIndex: nil)
            } catch {
                onError?(error)
            }
        }
    }

    private func invokeWhisper(wav: URL, channelIndex: Int?) throws {
        guard let bin = Self.binaryPath else {
            throw WhisperError.notInstalled
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: bin)
        task.arguments = [
            "-m", Self.modelPath,
            "-f", wav.path,
            "-l", language,
            "--output-json",          // clean segment text, no raw tokens
            "--no-prints",            // suppress decoder progress on stderr
            "--threads", "8",
            "--processors", "1",
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errBytes = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WhisperError.cliFailed(status: Int(task.terminationStatus), message: msg)
        }

        // whisper-cli writes `<wav>.json` alongside the input.
        let jsonURL = URL(fileURLWithPath: wav.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            // Fallback: stdout might carry the text in plain mode. Read it
            // and emit as a single final transcript.
            let outBytes = stdout.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: outBytes, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                onTranscript?(STTTranscript(text: text, isFinal: true,
                                            channelIndex: channelIndex, words: []))
            }
            return
        }

        let payload = try Data(contentsOf: jsonURL)
        parseWhisperJSON(payload, channelIndex: channelIndex)
    }

    /// Parse whisper-cli's `--output-json` and emit one ``STTTranscript`` per
    /// segment.
    ///
    /// Two cleanups applied:
    ///
    /// 1. Strip any leftover `[_*_]` special tokens (BOS / EOT / timestamp
    ///    markers). They shouldn't appear with plain `--output-json`, but
    ///    we filter defensively.
    /// 2. Drop consecutive segments with identical text — small models
    ///    hallucinate on silence, repeating the same phrase many times.
    private func parseWhisperJSON(_ data: Data, channelIndex: Int?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcription = obj["transcription"] as? [[String: Any]] else {
            return
        }
        var lastEmitted: String? = nil
        for segment in transcription {
            guard let raw = segment["text"] as? String else { continue }
            let cleaned = Self.cleanSegmentText(raw)
            guard !cleaned.isEmpty else { continue }
            if cleaned == lastEmitted { continue }
            lastEmitted = cleaned

            onTranscript?(STTTranscript(
                text: cleaned,
                isFinal: true,
                channelIndex: channelIndex,
                words: []
            ))
        }
    }

    /// Strip ``[_BEG_]``, ``[_TT_350]`` and any other ``[_*_]`` markers that
    /// whisper.cpp sometimes leaves in segment text, then collapse runs of
    /// whitespace produced by removing them.
    private static let specialTokenRegex = try! NSRegularExpression(
        pattern: #"\[_[^\]]*_\]"#, options: []
    )

    static func cleanSegmentText(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        let stripped = specialTokenRegex.stringByReplacingMatches(
            in: raw, options: [], range: range, withTemplate: ""
        )
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if isHallucinationPhrase(collapsed) {
            return ""
        }
        return collapsed
    }

    /// Lowercased phrases that whisper-cli regularly hallucinates from
    /// nothing (silence, background noise, tail-end padding of a chunk).
    /// We match the trimmed lowercased candidate against this set exactly
    /// (after stripping trailing dots/dashes), so legitimate text that
    /// just happens to contain a fragment is not dropped.
    private static let hallucinationPhrases: Set<String> = [
        // Russian YouTube subtitle reflexes — the model was trained on
        // subtitled Russian video and reflexively closes silent segments
        // with these phrases. Most common failure mode by far.
        "продолжение следует",
        "продолжение следует в следующей серии",
        "спасибо за просмотр",
        "спасибо за внимание",
        "подписывайтесь на канал",
        "подписывайся на канал",
        "ставьте лайки",
        "субтитры подготовил",
        "субтитры сделал",
        // Russian TV-credits variants observed in field recovery runs
        // (2026-06-26 and 2026-08-19 meetings).
        "субтитры создавал dimatorzok",
        "субтитры делал dimatorzok",
        "редактор субтитров а.кулакова",
        "редактор субтитров н.закомолдина",
        "корректор а.егорова",
        // English equivalents
        "thanks for watching",
        "thank you for watching",
        "like and subscribe",
        "subscribe to my channel",
        "subtitles by the amara.org community",
        "subtitles by amara.org",
        // Caption-style noise tokens
        "(piano music)",
        "(applause)",
        "(music)",
        "(silence)",
        "[music]",
        "[applause]",
        "[silence]",
        "...",
        "…",
    ]

    private static func isHallucinationPhrase(_ text: String) -> Bool {
        let punctuation = CharacterSet(charactersIn: ".!?…-—:; ")
        let candidate = text
            .lowercased()
            .trimmingCharacters(in: punctuation.union(.whitespacesAndNewlines))
        return hallucinationPhrases.contains(candidate)
    }

    // MARK: - Errors

    enum WhisperError: LocalizedError {
        case notInstalled
        case modelMissing(String)
        case cliFailed(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "whisper-cli not installed. Run `brew install whisper-cpp`."
            case .modelMissing(let path):
                return "Model file missing: \(path). Download a ggml-* model from huggingface.co/ggerganov/whisper.cpp."
            case .cliFailed(let s, let m):
                return "whisper-cli failed (status \(s)): \(m)"
            }
        }
    }
}


// ---------------------------------------------------------------------------
// MARK: - WAV writer / stereo splitter
// ---------------------------------------------------------------------------

/// Minimal in-process WAV file writer + stereo→mono splitter for the
/// whisper-cli batch path. whisper-cli accepts WAV files, so this is the
/// glue between our in-memory Int16 PCM and the CLI binary.
enum WAVWriter {

    enum WAVError: LocalizedError {
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .readFailed(let s): return "WAV read failed: \(s)"
            }
        }
    }

    /// Write 16-bit Int16 PCM at the given sample rate + channel count
    /// to a standard RIFF WAV at ``url``.
    static func write(pcm: Data,
                      sampleRate: Int,
                      channels: Int,
                      to url: URL) throws {
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = pcm.count
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(uint32LE(UInt32(chunkSize)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(uint32LE(16))                     // fmt subchunk size
        header.append(uint16LE(1))                      // PCM
        header.append(uint16LE(UInt16(channels)))
        header.append(uint32LE(UInt32(sampleRate)))
        header.append(uint32LE(UInt32(byteRate)))
        header.append(uint16LE(UInt16(blockAlign)))
        header.append(uint16LE(UInt16(bitsPerSample)))
        header.append(contentsOf: Array("data".utf8))
        header.append(uint32LE(UInt32(dataSize)))

        var out = header
        out.append(pcm)
        try out.write(to: url, options: .atomic)
    }

    /// Read a 16 kHz stereo Int16 WAV and write two mono Int16 WAVs (left
    /// and right channels). Used so whisper-cli can transcribe mic and
    /// system audio separately. Returns paths to the two new files.
    static func splitStereoToMono(sourceWAV: URL,
                                  sampleRate: Int) throws -> (URL, URL) {
        let data = try Data(contentsOf: sourceWAV)
        // Skip 44-byte standard WAV header. Our writer above always uses
        // 44 bytes (no fact chunk, no LIST), so this is safe for files we
        // produced ourselves.
        guard data.count > 44 else {
            throw WAVError.readFailed("WAV too short: \(data.count) bytes")
        }
        let interleaved = data.subdata(in: 44..<data.count)

        var leftPCM  = Data(capacity: interleaved.count / 2)
        var rightPCM = Data(capacity: interleaved.count / 2)
        interleaved.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            let frames = ptr.count / 2  // stereo pair per frame
            for f in 0..<frames {
                var l = ptr[2 * f]
                var r = ptr[2 * f + 1]
                leftPCM.append(Data(bytes: &l, count: 2))
                rightPCM.append(Data(bytes: &r, count: 2))
            }
        }

        let dir = FileManager.default.temporaryDirectory
        let leftURL  = dir.appendingPathComponent("wam-whisper-L-\(UUID().uuidString).wav")
        let rightURL = dir.appendingPathComponent("wam-whisper-R-\(UUID().uuidString).wav")
        try write(pcm: leftPCM,  sampleRate: sampleRate, channels: 1, to: leftURL)
        try write(pcm: rightPCM, sampleRate: sampleRate, channels: 1, to: rightURL)
        return (leftURL, rightURL)
    }

    /// Read a mono Int16 WAV (with the 44-byte header we write above) and
    /// compute the root-mean-square amplitude. Used to skip whisper
    /// inference on silent channels — small models hallucinate badly on
    /// pure silence.
    static func rms(of url: URL) -> Double {
        guard let data = try? Data(contentsOf: url), data.count > 44 else {
            return 0
        }
        let pcm = data.subdata(in: 44..<data.count)
        var sumSq: Double = 0
        var count: Int = 0
        pcm.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            count = ptr.count
            for i in 0..<count {
                let v = Double(ptr[i])
                sumSq += v * v
            }
        }
        guard count > 0 else { return 0 }
        return (sumSq / Double(count)).squareRoot()
    }

    // MARK: - Little-endian primitive writers

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}
