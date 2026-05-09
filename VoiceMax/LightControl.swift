import Foundation

/// Pings the Matter Lamp daemon at `http://{host}:{port}/mode/{name}` on each
/// recording-lifecycle transition. Fire-and-forget — errors are logged but
/// never block the audio path.
final class LightControl {

    static let shared = LightControl()

    enum Phase {
        case recording      // FN-down
        case processing     // FN-up until paste
        case idle           // mic available, ready
        case disconnected   // selected mic unavailable

        var mode: String {
            switch self {
            case .recording:    return "red"
            case .processing:   return "standby"  // brief breathing pause
            case .idle:         return "blue"     // breathing blue (config has breathing_profile)
            case .disconnected: return "standby"
            }
        }
    }

    /// Picks `idle` or `disconnected` based on AudioCapture's current mic state.
    /// Use this whenever ending a session or reflecting baseline state.
    func setIdleReflectingMic() {
        set(AudioCapture.shared.isAvailable ? .idle : .disconnected)
    }

    private struct Keys {
        static let host    = "VoiceMaxLightHost"
        static let port    = "VoiceMaxLightPort"
        static let enabled = "VoiceMaxLightEnabled"
    }

    /// Empty by default — lamp integration is opt-in, configured via the
    /// tray menu's Light → Configure host… dialog. The expected daemon is
    /// the open-source Matter Lamp HTTP shim (https://localhost:7420/mode/<name>).
    private let defaultHost = ""
    private let defaultPort = 7420

    var host: String {
        get { (UserDefaults.standard.string(forKey: Keys.host) ?? defaultHost) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.host) }
    }

    var port: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: Keys.port)
            return v > 0 ? v : defaultPort
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.port) }
    }

    var enabled: Bool {
        get {
            // Default OFF — lamp integration is opt-in. Each user enables
            // it in the Light submenu after configuring their host.
            UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? false
        }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.0
        cfg.timeoutIntervalForResource = 2.0
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // Circuit breaker: after `failureThreshold` consecutive failures, suspend
    // requests for `cooldown` seconds. Resets on success. Keeps the log clean
    // and stops wasted dials when the lamp host is unreachable (foreign
    // network, daemon down, mDNS hiccup).
    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var suspendedUntil: Date = .distantPast
    private let failureThreshold = 3
    private let cooldown: TimeInterval = 60

    /// `bypassBreaker = true` ignores the cooldown and reports back via the
    /// callback. Use for explicit user-driven calls (Test button, toggling
    /// Enabled) so a stuck breaker can always be probed.
    func set(_ phase: Phase, bypassBreaker: Bool = false) {
        guard enabled, !host.isEmpty else { return }
        if !bypassBreaker, isSuspended() { return }
        let mode = phase.mode
        guard let url = URL(string: "http://\(host):\(port)/mode/\(mode)") else { return }
        let task = session.dataTask(with: url) { [weak self] _, response, error in
            guard let self else { return }
            if let error {
                self.recordFailure(mode: mode, reason: error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                self.recordFailure(mode: mode, reason: "HTTP \(http.statusCode)")
                return
            }
            self.recordSuccess()
        }
        task.resume()
    }

    /// Manually reset the circuit breaker (e.g. user toggled Enabled or moved networks).
    func resetBreaker() {
        lock.lock()
        consecutiveFailures = 0
        suspendedUntil = .distantPast
        lock.unlock()
    }

    private func isSuspended() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Date() < suspendedUntil
    }

    private func recordFailure(mode: String, reason: String) {
        lock.lock()
        consecutiveFailures += 1
        let count = consecutiveFailures
        let shouldSuspend = count == failureThreshold
        if shouldSuspend {
            suspendedUntil = Date().addingTimeInterval(cooldown)
        }
        lock.unlock()
        DispatchQueue.main.async {
            if shouldSuspend {
                TrayLog.append("light: \(count) consecutive failures (last: \(reason)) — suspending lamp calls for \(Int(self.cooldown))s")
            } else if count == 1 {
                // Log only the first failure of a streak; suppress repeats until threshold or recovery.
                TrayLog.append("light: \(mode) failed — \(reason)")
            }
        }
    }

    private func recordSuccess() {
        lock.lock()
        let wasSuspended = consecutiveFailures >= failureThreshold
        consecutiveFailures = 0
        suspendedUntil = .distantPast
        lock.unlock()
        if wasSuspended {
            DispatchQueue.main.async { TrayLog.append("light: lamp reachable again — resuming") }
        }
    }
}
