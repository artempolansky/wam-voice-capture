import Foundation

#if TELEGRAM_BUILD

/// Thin TDLib wrapper: one client, one background receive loop, auth state machine.
/// Messaging helpers land in a follow-up PR.
@MainActor
final class TelegramClient {

    static let shared = TelegramClient()

    enum Status: Equatable {
        case idle                       // not started
        case needCredentials            // api_id/api_hash missing
        case waitingPhone
        case waitingCode
        case waitingPassword
        case ready(username: String)
        case error(String)

        var menuText: String {
            switch self {
            case .idle:               return "not connected"
            case .needCredentials:    return "app credentials missing"
            case .waitingPhone:       return "waiting for phone…"
            case .waitingCode:        return "waiting for code…"
            case .waitingPassword:    return "waiting for 2FA password…"
            case .ready(let name):    return "@\(name) ✓"
            case .error(let msg):     return "error: \(msg)"
            }
        }
    }

    private(set) var status: Status = .idle {
        didSet { onStatusChange?(status) }
    }
    var onStatusChange: ((Status) -> Void)?

    private var clientId: Int32 = 0
    private var receiveThread: Thread?
    private var running = false

    private let databaseDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WAM Voice Capture/tdlib", isDirectory: true)
    }()
    private let filesDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WAM Voice Capture/tdlib-files", isDirectory: true)
    }()

    // MARK: - Startup

    /// Boots the TDLib client and drives it toward `ready` if session exists.
    /// Safe to call multiple times — idempotent.
    func start() {
        guard !running else { return }
        guard let creds = KeychainHelper.telegramCredentials() else {
            status = .needCredentials
            return
        }
        try? FileManager.default.createDirectory(at: databaseDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)

        clientId = td_create_client_id()
        running = true
        spawnReceiveLoop()
        TrayLog.append("tg: client \(clientId) booted")
        // Kick the auth state machine by asking for current state.
        send(["@type": "getAuthorizationState"])
        self.pendingCredentials = creds
    }

    private var pendingCredentials: KeychainHelper.TelegramCredentials?

    /// Fully shuts down TDLib, wipes session on disk + keychain key.
    func logoutAndWipe() {
        guard running else {
            wipeOnDisk()
            return
        }
        send(["@type": "logOut"])
        // authorizationStateClosed will arrive — we wipe there.
    }

    private func wipeOnDisk() {
        running = false
        try? FileManager.default.removeItem(at: databaseDir)
        try? FileManager.default.removeItem(at: filesDir)
        KeychainHelper.clearTDLibDatabaseKey()
        status = .idle
    }

    // MARK: - Auth step inputs (from UI)

    func submitPhone(_ phone: String) {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        send(["@type": "setAuthenticationPhoneNumber", "phone_number": trimmed])
    }

    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        send(["@type": "checkAuthenticationCode", "code": trimmed])
    }

    func submitPassword(_ password: String) {
        send(["@type": "checkAuthenticationPassword", "password": password])
    }

    // MARK: - Receive loop

    private func spawnReceiveLoop() {
        let t = Thread { [weak self] in
            while true {
                guard let self else { break }
                let raw = td_receive(1.0)
                guard let raw, self.running else {
                    if !(self.running) { break }
                    continue
                }
                let json = String(cString: raw)
                Task { @MainActor [weak self] in
                    self?.handleEvent(json)
                }
            }
        }
        t.name = "WAMVoiceCapture.TDLib.Receive"
        t.qualityOfService = .utility
        t.start()
        receiveThread = t
    }

    private func send(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else { return }
        s.withCString { td_send(clientId, $0) }
    }

    // MARK: - Event handling

    private func handleEvent(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["@type"] as? String else { return }

        switch type {
        case "updateAuthorizationState":
            if let authState = obj["authorization_state"] as? [String: Any] {
                handleAuthState(authState)
            }
        case "authorizationState":
            handleAuthState(obj)
        case "error":
            let msg = (obj["message"] as? String) ?? "unknown error"
            TrayLog.append("tg: error — \(msg)")
            status = .error(msg)
        case "user":
            consumeUserIfNeeded(obj)
        default:
            break
        }
    }

    private func handleAuthState(_ obj: [String: Any]) {
        guard let stateType = obj["@type"] as? String else { return }
        TrayLog.append("tg: auth state \(stateType)")

        switch stateType {
        case "authorizationStateWaitTdlibParameters":
            sendTdlibParameters()
        case "authorizationStateWaitPhoneNumber":
            status = .waitingPhone
        case "authorizationStateWaitCode":
            status = .waitingCode
        case "authorizationStateWaitPassword":
            status = .waitingPassword
        case "authorizationStateReady":
            fetchMe()
        case "authorizationStateLoggingOut":
            TrayLog.append("tg: logging out")
        case "authorizationStateClosing":
            break
        case "authorizationStateClosed":
            running = false
            wipeOnDisk()
        default:
            break
        }
    }

    private func sendTdlibParameters() {
        guard let creds = pendingCredentials ?? KeychainHelper.telegramCredentials() else {
            status = .needCredentials
            return
        }
        let dbKey: String
        do {
            dbKey = try KeychainHelper.tdlibDatabaseKey().base64EncodedString()
        } catch {
            status = .error("failed to create DB key: \(error.localizedDescription)")
            return
        }
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0"
        send([
            "@type": "setTdlibParameters",
            "use_test_dc": false,
            "database_directory": databaseDir.path,
            "files_directory": filesDir.path,
            "database_encryption_key": dbKey,
            "use_file_database": true,
            "use_chat_info_database": true,
            "use_message_database": false,
            "use_secret_chats": false,
            "api_id": creds.apiID,
            "api_hash": creds.apiHash,
            "system_language_code": "en",
            "device_model": "Mac",
            "system_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "application_version": appVersion,
        ])
    }

    private func fetchMe() {
        // Simple approach: one-shot query, parse response by @type match in the main event stream.
        send(["@type": "getMe"])
    }

    // Intercept getMe response by adding to handleEvent
}

// MARK: - getMe response hook

extension TelegramClient {
    fileprivate func consumeUserIfNeeded(_ obj: [String: Any]) {
        guard obj["@type"] as? String == "user" else { return }
        let username: String
        if let usernames = obj["usernames"] as? [String: Any],
           let active = (usernames["active_usernames"] as? [String])?.first {
            username = active
        } else if let u = obj["username"] as? String, !u.isEmpty {
            username = u
        } else {
            let first = (obj["first_name"] as? String) ?? "user"
            username = first
        }
        status = .ready(username: username)
    }
}

#else

/// TDLib not compiled in. Menu shows "not installed" and no client is created.
@MainActor
final class TelegramClient {
    static let shared = TelegramClient()

    enum Status: Equatable {
        case unavailable
        var menuText: String { "TDLib not installed" }
    }

    let status: Status = .unavailable
    var onStatusChange: ((Status) -> Void)?

    func start() {}
    func logoutAndWipe() {}
    func submitPhone(_ phone: String) {}
    func submitCode(_ code: String) {}
    func submitPassword(_ password: String) {}
}

#endif
