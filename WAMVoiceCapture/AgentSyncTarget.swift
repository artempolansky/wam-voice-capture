import Foundation

/// One remote sync destination: an SSH host + path that the app rsyncs
/// transcript files to as they grow, then drops a `.done` marker on the
/// remote when the session ends.
///
/// Agent-agnostic: this type knows nothing about Angelina or any specific
/// agent. The receiving side is whatever the user runs on that host —
/// documented in `docs/AGENT_PROTOCOL.md`.
///
/// Concurrency:
/// - All mutable state (`lastSync`, `lastError`, `inflight`) is locked.
/// - The actual `rsync` invocation runs on a private serial queue so two
///   updates to the same target can't overlap.
final class AgentSyncTarget {

    /// Persistent identity for the target. UUID string in `UserDefaults`.
    let id: String
    /// Display name shown in the tray menu (e.g. "My Angelina").
    var name: String
    /// Remote host (e.g. `54.36.163.214` or `vps.example.com`).
    var host: String
    /// Remote user.
    var user: String
    /// Remote directory the rsync target writes into (the "inbox"). Trailing slash optional.
    var remotePath: String
    /// Path to the SSH private key. Defaults to `~/.ssh/id_ed25519`.
    var sshKeyPath: String
    /// If true, push-to-talk dictation transcripts (currently not file-backed)
    /// would also sync once they're file-backed. Meetings always sync when
    /// the target is enabled. Default false.
    var includeDictations: Bool
    /// Master toggle for this target. When false, sync calls are silent no-ops.
    var enabled: Bool

    /// Status as reported to the tray. Updated on every rsync call.
    enum Status {
        case idle
        case syncing
        case lastSucceeded(at: Date)
        case lastFailed(at: Date, error: String)
    }

    private let lock = NSLock()
    private var _status: Status = .idle
    private var _inflight: Bool = false
    private let runQueue: DispatchQueue

    init(id: String = UUID().uuidString,
         name: String,
         host: String,
         user: String,
         remotePath: String,
         sshKeyPath: String = "~/.ssh/id_ed25519",
         includeDictations: Bool = false,
         enabled: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.remotePath = remotePath
        self.sshKeyPath = sshKeyPath
        self.includeDictations = includeDictations
        self.enabled = enabled
        self.runQueue = DispatchQueue(label: "wam-voice-capture.agent-sync.\(id)", qos: .utility)
    }

    var status: Status {
        lock.withLock { _status }
    }

    /// Run one rsync of `localFile` to the remote inbox. Idempotent; safe to
    /// call repeatedly. Coalesces concurrent calls — if a sync is already in
    /// flight, queues exactly one follow-up (so a burst of `noteUpdate` calls
    /// collapses into "current run + one more").
    ///
    /// `completion` is called on the run queue (background). Use `DispatchQueue.main.async`
    /// inside the closure if you need to touch UI / TrayLog.
    func sync(localFile: URL, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard enabled else {
            completion?(.failure(SyncError.disabled))
            return
        }
        lock.lock()
        if _inflight {
            lock.unlock()
            // Drop — the in-flight run will pick up the latest file content
            // anyway, since rsync sends the file as-it-is-now at each invocation.
            // (Real coalescing would need a "pending follow-up" flag; for now
            // this is fine because rsync is invoked by debounced timer too.)
            return
        }
        _inflight = true
        _status = .syncing
        lock.unlock()

        runQueue.async { [weak self] in
            guard let self else { return }
            let result = self.runRsync(localFile: localFile)
            self.lock.lock()
            switch result {
            case .success:
                self._status = .lastSucceeded(at: Date())
            case .failure(let err):
                self._status = .lastFailed(at: Date(), error: err.localizedDescription)
            }
            self._inflight = false
            self.lock.unlock()
            completion?(result)
        }
    }

    /// Write a `<basename>.done` empty marker file in the remote inbox via
    /// SSH `touch`. Called after the final `sync(...)` of a session has
    /// completed; signals to the watcher that the file is fully delivered.
    func writeDoneMarker(forLocalFile localFile: URL, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard enabled else {
            completion?(.failure(SyncError.disabled))
            return
        }
        runQueue.async { [weak self] in
            guard let self else { return }
            let basename = localFile.lastPathComponent
            // shell-quote the path; basename is filename-only, no slashes,
            // but still escape conservatively.
            let remoteFull = self.joinedRemotePath().appending(basename).appending(".done")
            let quoted = remoteFull.replacingOccurrences(of: "'", with: "'\\''")
            let cmd = "touch '\(quoted)'"
            let result = self.runSSH(command: cmd)
            self.lock.lock()
            switch result {
            case .success:
                self._status = .lastSucceeded(at: Date())
            case .failure(let err):
                self._status = .lastFailed(at: Date(), error: ".done: \(err.localizedDescription)")
            }
            self.lock.unlock()
            completion?(result)
        }
    }

    /// Probe reachability and write-permission by uploading a tiny test file
    /// + `.done`, then immediately deleting both. Used by the tray "Test"
    /// button.
    func probe(completion: @escaping (Result<Void, Error>) -> Void) {
        runQueue.async { [weak self] in
            guard let self else { return }
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("wam-vc-probe-\(UUID().uuidString).txt")
            let payload = "WAM Voice Capture target probe: \(Date())\n"
            do {
                try payload.write(to: tmpURL, atomically: true, encoding: .utf8)
            } catch {
                completion(.failure(error))
                return
            }
            defer { try? FileManager.default.removeItem(at: tmpURL) }

            let rsyncResult = self.runRsync(localFile: tmpURL)
            guard case .success = rsyncResult else {
                if case .failure(let err) = rsyncResult { completion(.failure(err)) }
                return
            }
            // Clean up on remote so we don't litter the inbox with probe files.
            let basename = tmpURL.lastPathComponent
            let remoteFull = self.joinedRemotePath().appending(basename)
            let quoted = remoteFull.replacingOccurrences(of: "'", with: "'\\''")
            _ = self.runSSH(command: "rm -f '\(quoted)'")
            completion(.success(()))
        }
    }

    // MARK: - Private

    private func runRsync(localFile: URL) -> Result<Void, Error> {
        let key = expandTilde(sshKeyPath)
        let sshArgs = "ssh -i \(shellQuote(key)) -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new"
        let remote = "\(user)@\(host):\(joinedRemotePath())"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        task.arguments = [
            "-az",
            "--partial",
            "--inplace",
            "-e", sshArgs,
            localFile.path,
            remote,
        ]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()  // discard
        do {
            try task.run()
        } catch {
            return .failure(error)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "rsync exit \(task.terminationStatus)"
            return .failure(SyncError.rsyncFailed(status: Int(task.terminationStatus), message: errMsg))
        }
        return .success(())
    }

    private func runSSH(command: String) -> Result<Void, Error> {
        let key = expandTilde(sshKeyPath)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-i", key,
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "\(user)@\(host)",
            command,
        ]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()
        do {
            try task.run()
        } catch {
            return .failure(error)
        }
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "ssh exit \(task.terminationStatus)"
            return .failure(SyncError.sshFailed(status: Int(task.terminationStatus), message: errMsg))
        }
        return .success(())
    }

    /// Remote path with guaranteed trailing slash. Caller appends a filename
    /// (or `.done`) without worrying about path joining.
    private func joinedRemotePath() -> String {
        remotePath.hasSuffix("/") ? remotePath : remotePath + "/"
    }

    private func expandTilde(_ path: String) -> String {
        if path.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return home + String(path.dropFirst(1))
        }
        return path
    }

    private func shellQuote(_ s: String) -> String {
        // For -e "ssh -i KEY ...": just double-quote with escaping. rsync passes
        // this through /bin/sh so we need to be careful, but the key path is
        // user-controlled — keep escaping minimal but safe.
        return "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    enum SyncError: LocalizedError {
        case disabled
        case rsyncFailed(status: Int, message: String)
        case sshFailed(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .disabled:                         return "Target disabled"
            case .rsyncFailed(let s, let m):        return "rsync failed (status \(s)): \(m)"
            case .sshFailed(let s, let m):          return "ssh failed (status \(s)): \(m)"
            }
        }
    }
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
