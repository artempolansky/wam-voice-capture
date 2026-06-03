import Foundation

/// On-device speech-to-text via the ``whisper-cli`` CLI from
/// ``brew install whisper-cpp``. Fully offline — no network calls,
/// no API keys, no VPN-related drops.
///
/// Lifecycle differs from Deepgram:
///
/// - **Deepgram** is streaming. Each chunk goes over a WebSocket and
///   partial transcripts arrive while you speak.
/// - **Whisper-local** is batch. We accumulate every chunk into an
///   in-memory PCM buffer; when ``finish()`` is called we write a WAV
///   file and invoke ``whisper-cli`` once. The final transcript arrives
///   ~1–3 s later (single ``isFinal=true`` event).
///
/// Trade-offs vs. Deepgram:
///
/// - ✅ Offline; latency-spike resistant
/// - ✅ No per-minute API cost
/// - ❌ No streaming partials (paste only after speech ends)
/// - ❌ No diarization (no Speaker 2/3 within a channel; channel-based
///   labeling still works for meetings: mic = Speaker 1, system = Speaker 2)
/// - ❌ Initial inference latency on first call (Metal shader compile)
///
/// Model lives at
/// ``~/Library/Application Support/WAM Voice Capture/models/ggml-base.bin``.
/// First run requires manual download (we don't auto-download in v1 —
/// see ``docs/whisper-setup.md``).
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
    /// Deepgram defaults to ``ru`` per real-world testing; keep parity.
    let language: String

    init(channels: Int, language: String = "ru") {
        self.channels = max(1, min(channels, 2))
        self.language = language
        super.init()
    }

    // MARK: - State

    private let lock = NSLock()

    private enum Phase {
        case idle
        case open       // accepting audio
        case closing    // finish() called, inference in flight
        case closed
    }
    private var phase: Phase = .idle

    /// Accumulated interleaved-stereo (or mono) Int16 PCM at 16 kHz.
    /// One whisper-cli invocation processes everything since the last
    /// ``connect()``.
    private var buffer = Data()

    // MARK: - STTProvider methods

    func connect() {
        lock.lock()
        phase = .open
        buffer.removeAll(keepingCapacity: true)
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

        // Synthetic "opened" — we have no real connection but the session
        // expects this event to know it's safe to start streaming chunks.
        onOpen?()
    }

    func sendAudio(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard phase == .open else { return }
        buffer.append(pcm)
    }

    func finish() {
        lock.lock()
        guard phase == .open else { lock.unlock(); return }
        phase = .closing
        let snapshot = buffer
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        // STRONG self capture — the calling session typically drops its
        // reference to us soon after `finish()` (within 1–5 s on dictation,
        // immediately on meeting stop). With `[weak self]` the inference
        // background task would observe a dealloc'd self and silently drop
        // the recording — exactly the symptom that reproduced when meeting
        // transcripts came back empty. Holding a strong ref here guarantees
        // whisper-cli runs to completion, and the ``onTranscript`` /
        // ``onClose`` callbacks fire while the listeners (sessions) are
        // still alive (sessions are MainActor singletons).
        DispatchQueue.global(qos: .userInitiated).async {
            self.runInference(on: snapshot)
        }
    }

    func disconnect() {
        lock.lock()
        let wasOpen = phase != .closed
        phase = .closed
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()

        if wasOpen {
            onClose?(1000, "")
        }
    }

    // MARK: - Inference

    private func runInference(on pcm: Data) {
        defer {
            lock.lock(); phase = .closed; lock.unlock()
            onClose?(1000, "")
        }

        if pcm.isEmpty {
            // Nothing to transcribe — synthesize one empty final so callers
            // that wait for an isFinal event get unblocked.
            onTranscript?(STTTranscript(text: "", isFinal: true,
                                        channelIndex: nil, words: []))
            return
        }

        // Write a 16 kHz WAV with the buffer. For multichannel sessions our
        // upstream interleaves mic+system into stereo Int16 already, so we
        // honor the ``channels`` count.
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
                // tiny model otherwise hallucinates "АПЛОДИСМЕНТЫ" etc. on
                // pure silence. Threshold of 80 is just above ambient noise
                // floor for our 16-bit PCM (max amplitude is 32767).
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
    /// segment so the meeting transcript file streams in roughly the same
    /// shape Deepgram produces.
    ///
    /// Two cleanups applied:
    ///
    /// 1. Strip any leftover `[_*_]` special tokens (BOS / EOT / timestamp
    ///    markers). They shouldn't appear with plain `--output-json`, but
    ///    we filter defensively.
    /// 2. Drop consecutive segments with identical text. The ``tiny`` model
    ///    hallucinates on silence and on background noise, repeating the
    ///    same short phrase ("Так.", "АПЛОДИСМЕНТЫ") many times in a row.
    ///    For larger models this is rare; for tiny it's the dominant
    ///    failure mode and worth filtering at the source.
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
            // Drop consecutive duplicates from tiny-model hallucination loops.
            if cleaned == lastEmitted { continue }
            lastEmitted = cleaned

            onTranscript?(STTTranscript(
                text: cleaned,
                isFinal: true,
                channelIndex: channelIndex,
                words: []   // word-level info dropped — segment text is enough
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
        // Collapse runs of whitespace into a single space (whisper.cpp
        // sometimes inserts spaces around the stripped tokens).
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed
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
    /// inference on silent channels — tiny model hallucinates badly on
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
