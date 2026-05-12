import Foundation

/// Deepgram Nova-3 streaming STT via WebSocket.
/// Feed Int16 PCM 16kHz mono via `sendAudio`. Listen for partial/final
/// transcripts via `onTranscript`.
///
/// State machine:
///
///   idle → connecting → open → (closing) → closed
///                       │  ↑                 ↑
///                       └──┴── failure ──────┘
///
/// `sendAudio` buffers chunks while `connecting` and flushes them once
/// `didOpenWithProtocol` arrives — the WebSocket handshake commonly takes
/// 200–500 ms and previously dropped any audio that landed in that window.
final class DeepgramClient: NSObject {

    /// One word from Deepgram's `alternatives[0].words[]` array. Populated only
    /// when `diarize=true` is enabled. `speaker` is Deepgram's session-local
    /// speaker ID (0, 1, 2, ...) within the channel — meaningless across
    /// sessions or channels.
    struct Word {
        let text: String
        let speaker: Int?
        let start: Double
        let end: Double
    }

    struct Transcript {
        let text: String
        let isFinal: Bool
        /// Channel-index from Deepgram when `multichannel=true`. nil for mono.
        let channelIndex: Int?
        /// Per-word speaker assignments (when `diarize=true`). Empty if
        /// diarization is off, or if this was an interim result with no words.
        let words: [Word]
    }

    var onTranscript: ((Transcript) -> Void)?
    var onError: ((Error) -> Void)?
    var onClose: ((Int, String) -> Void)?
    var onOpen: (() -> Void)?

    private let apiKey: String
    private let language: String
    private let model: String
    private let channels: Int
    private let multichannel: Bool
    private let diarize: Bool

    private enum State {
        case idle, connecting, open, closing, closed, failed
    }

    private let lock = NSLock()
    private var state: State = .idle
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    /// Audio chunks buffered while the socket is still in handshake.
    /// Flushed in order on `didOpenWithProtocol`. Bounded to keep memory
    /// stable if the handshake never completes.
    private var pending: [Data] = []
    private var pendingBytes = 0
    private let pendingCap = 4 * 1024 * 1024 // 4 MB ≈ 65 s of 16 kHz Int16 mono

    /// Diagnostic counters. `_chunksSent` is the count actually shipped over
    /// the wire (not buffered). Read-only externally.
    private var _chunksSent = 0
    private var _bytesSent = 0
    var chunksSent: Int { lock.withLock { _chunksSent } }
    var bytesSent:  Int { lock.withLock { _bytesSent } }

    init(apiKey: String,
         language: String = "multi",
         model: String = "nova-3",
         channels: Int = 1,
         multichannel: Bool = false,
         diarize: Bool = false) {
        self.apiKey = apiKey
        self.language = language
        self.model = model
        self.channels = channels
        self.multichannel = multichannel
        self.diarize = diarize
        super.init()
    }

    // MARK: - Lifecycle

    func connect() {
        lock.lock()
        // Drop any prior session before starting a new one.
        teardownLocked(closeCode: .goingAway)
        guard let url = makeURL() else {
            lock.unlock()
            onError?(DGError.decodeFailed("invalid url"))
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        // Ephemeral configuration: no shared HTTP/2 connection pool with other
        // URLSessions in the process. Across multiple back-to-back meetings,
        // `.default` was handing back stale sockets from the connection pool —
        // new WebSocket tasks opened on a half-dead TCP, then died with
        // "Socket is not connected" / WS code 1011. Ephemeral gives each
        // DeepgramClient a clean transport stack.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: req)
        self.session = s
        self.task = t
        self.state = .connecting
        lock.unlock()

        t.resume()
        receiveNext(on: t)
    }

    func sendAudio(_ pcm: Data) {
        lock.lock()
        switch state {
        case .open:
            guard let t = task else { lock.unlock(); return }
            _chunksSent += 1
            _bytesSent  += pcm.count
            lock.unlock()
            // Retry transient ENOTCONN: URLSessionWebSocketTask sometimes
            // fires `didOpenWithProtocol` before the underlying BSD socket
            // is actually writable. First sends fail with "Socket is not
            // connected" (errno 57) on a cold socket — we retry up to twice
            // after small delays before surfacing the error.
            attemptSend(pcm: pcm, on: t, attempt: 0)
        case .connecting:
            // Buffer until handshake completes — but cap so a never-opening
            // socket can't grow memory unbounded.
            if pendingBytes + pcm.count <= pendingCap {
                pending.append(pcm)
                pendingBytes += pcm.count
            }
            lock.unlock()
        default:
            lock.unlock()
        }
    }

    private func attemptSend(pcm: Data, on task: URLSessionWebSocketTask, attempt: Int) {
        task.send(.data(pcm)) { [weak self] err in
            guard let self else { return }
            guard let err else { return }
            if attempt < 2 && Self.isRetryableSendError(err) {
                // Re-check state — task may have been torn down between
                // attempts. Capture the current task fresh so we don't write
                // into a stale closed handle.
                self.lock.lock()
                let stillOpen = (self.state == .open)
                let currentTask = self.task
                self.lock.unlock()
                guard stillOpen, let currentTask else { return }
                let delay: TimeInterval = 0.2 * Double(attempt + 1)
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.attemptSend(pcm: pcm, on: currentTask, attempt: attempt + 1)
                }
                return
            }
            // Either we ran out of retries or the error isn't retryable.
            // Surface to caller so the session-level reconnect logic kicks in.
            self.onError?(err)
        }
    }

    /// True if `err` matches the cold-socket race ("Socket is not connected").
    /// Both NSPOSIX 57 and URL-layer wrappers around it are accepted.
    private static func isRetryableSendError(_ err: Error) -> Bool {
        let nsErr = err as NSError
        if nsErr.domain == NSPOSIXErrorDomain && nsErr.code == 57 { return true }
        if let underlying = nsErr.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain && underlying.code == 57 {
            return true
        }
        // Belt-and-braces: localized description match for cases where the
        // error doesn't carry POSIX domain info (varies by macOS minor).
        let desc = err.localizedDescription.lowercased()
        return desc.contains("socket is not connected") || desc.contains("not connected")
    }

    /// Tell Deepgram we're done — server flushes pending finals then closes.
    func finish() {
        lock.lock()
        guard state == .open || state == .connecting, let t = task else {
            lock.unlock()
            return
        }
        state = .closing
        lock.unlock()

        let payload = try? JSONSerialization.data(withJSONObject: ["type": "CloseStream"])
        if let payload, let s = String(data: payload, encoding: .utf8) {
            t.send(.string(s)) { _ in }
        }
    }

    func disconnect() {
        lock.lock()
        teardownLocked(closeCode: .goingAway)
        lock.unlock()
    }

    private func teardownLocked(closeCode: URLSessionWebSocketTask.CloseCode) {
        state = .closed
        task?.cancel(with: closeCode, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        pending.removeAll()
        pendingBytes = 0
    }

    // MARK: - Private

    private func makeURL() -> URL? {
        var comps = URLComponents(string: "wss://api.deepgram.com/v1/listen")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "language", value: language),
            URLQueryItem(name: "encoding", value: "linear16"),
            URLQueryItem(name: "sample_rate", value: "16000"),
            URLQueryItem(name: "channels", value: String(channels)),
            URLQueryItem(name: "interim_results", value: "true"),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "endpointing", value: "300"),
        ]
        if multichannel {
            items.append(URLQueryItem(name: "multichannel", value: "true"))
        }
        if diarize {
            items.append(URLQueryItem(name: "diarize", value: "true"))
        }
        comps.queryItems = items
        return comps.url
    }

    private func flushPendingLocked() {
        guard let t = task else { return }
        let chunks = pending
        let totalBytes = pendingBytes
        pending.removeAll()
        pendingBytes = 0
        _chunksSent += chunks.count
        _bytesSent  += totalBytes
        // Send outside the lock — `t.send` is async with completion.
        DispatchQueue.global().async { [weak self] in
            for chunk in chunks {
                t.send(.data(chunk)) { [weak self] err in
                    if let err { self?.onError?(err) }
                }
            }
            _ = self  // silence unused-capture
        }
    }

    private func receiveNext(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.lock.lock()
                let wasOpen = self.state == .open || self.state == .connecting
                if wasOpen { self.state = .failed }
                self.lock.unlock()
                if wasOpen { self.onError?(err) }
            case .success(let msg):
                switch msg {
                case .string(let s):     self.handleText(s)
                case .data(let d):       if let s = String(data: d, encoding: .utf8) { self.handleText(s) }
                @unknown default:        break
                }
                self.lock.lock()
                let alive = self.state == .open || self.state == .connecting || self.state == .closing
                self.lock.unlock()
                if alive { self.receiveNext(on: t) }
            }
        }
    }

    private func handleText(_ s: String) {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let type = obj["type"] as? String ?? "Results"
        if type == "Results",
           let channel = obj["channel"] as? [String: Any],
           let alts = channel["alternatives"] as? [[String: Any]],
           let first = alts.first,
           let text = first["transcript"] as? String {
            let isFinal = obj["is_final"] as? Bool ?? false
            // multichannel: top-level `channel_index` is `[index, totalChannels]`.
            var channelIndex: Int?
            if let arr = obj["channel_index"] as? [Int], let idx = arr.first {
                channelIndex = idx
            }
            // Parse per-word speaker assignments when diarize=true.
            // Deepgram emits `words[]` only on final results — interims are
            // safe to ignore here; we'll still emit interim Transcripts with
            // empty words[] for any callers that watch them.
            var words: [Word] = []
            if let rawWords = first["words"] as? [[String: Any]] {
                words.reserveCapacity(rawWords.count)
                for w in rawWords {
                    guard let wText = (w["punctuated_word"] as? String) ?? (w["word"] as? String) else {
                        continue
                    }
                    let speaker = w["speaker"] as? Int
                    let start = (w["start"] as? Double) ?? 0
                    let end = (w["end"] as? Double) ?? 0
                    words.append(Word(text: wText, speaker: speaker, start: start, end: end))
                }
            }
            if !text.isEmpty || isFinal {
                onTranscript?(Transcript(text: text,
                                         isFinal: isFinal,
                                         channelIndex: channelIndex,
                                         words: words))
            }
        }
    }

    enum DGError: LocalizedError {
        case notConnected
        case decodeFailed(String)
        var errorDescription: String? {
            switch self {
            case .notConnected:        return "Deepgram WebSocket not connected"
            case .decodeFailed(let s): return "Failed to decode Deepgram response: \(s)"
            }
        }
    }
}

extension DeepgramClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        lock.lock()
        // Race guard: another teardown may have flipped us closed already.
        guard state == .connecting else { lock.unlock(); return }
        state = .open
        flushPendingLocked()
        lock.unlock()
        onOpen?()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        lock.lock()
        state = .closed
        lock.unlock()
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        onClose?(closeCode.rawValue, r)
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
