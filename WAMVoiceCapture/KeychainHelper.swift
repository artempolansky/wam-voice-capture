import Foundation
import Security

/// Tiny Keychain reader for WAM Voice Capture secrets.
/// Convention: service `wam-voice-capture.<name>`, account matches the service tail
/// (e.g. service `wam-voice-capture.deepgram.api_key`, account `deepgram`).
///
/// Legacy chains (transparent migration): `voicemax.*` (VoiceMax 1.0.0) and
/// `openclaw.*` (pre-VoiceMax fork) are read as fallbacks; on first read the
/// value is copied to the new service and the old item is deleted.
enum KeychainHelper {

    enum Service {
        static let deepgramAPIKey    = "wam-voice-capture.deepgram.api_key"
        static let legacyDeepgramVM  = "voicemax.deepgram.api_key"
        static let legacyDeepgramOC  = "openclaw.deepgram.api_key"
        // Legacy Telegram/TDLib keys: TDLib delivery was retired in favor of
        // file-sync (Phase 7a). These are listed only so Migration can clean
        // them up on upgrade.
        static let legacyTelegramVMID     = "voicemax.telegram.api_id"
        static let legacyTelegramVMHash   = "voicemax.telegram.api_hash"
        static let legacyTelegramWAMID    = "wam-voice-capture.telegram.api_id"
        static let legacyTelegramWAMHash  = "wam-voice-capture.telegram.api_hash"
        static let legacyTdlibDBVM        = "voicemax.tdlib_db_key"
        static let legacyTdlibDBWAM       = "wam-voice-capture.tdlib_db_key"
    }

    enum Error: LocalizedError {
        case notFound(String)
        case osStatus(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .notFound(let key):        return "Keychain item not found: \(key)"
            case .osStatus(let key, let s): return "Keychain error for \(key): OSStatus \(s)"
            }
        }
    }

    static func readString(service: String, account: String) throws -> String {
        var query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      service,
            kSecAttrAccount:      account,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        // Synchronizable items may live in iCloud Keychain — try both.
        query[kSecAttrSynchronizable] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw Error.notFound("\(service)/\(account)")
        }
        guard status == errSecSuccess else {
            throw Error.osStatus("\(service)/\(account)", status)
        }
        guard let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            throw Error.notFound("\(service)/\(account)")
        }
        return str.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads `wam-voice-capture.deepgram.api_key`. On first call after upgrading from
    /// either VoiceMax 1.0.0 (`voicemax.deepgram.api_key`) or the older OpenClaw fork
    /// (`openclaw.deepgram.api_key`), copies the value forward and removes the old item.
    /// Transparent to the user — no re-entry needed.
    static func deepgramAPIKey() throws -> String {
        if let key = try? readString(service: Service.deepgramAPIKey, account: "deepgram"),
           !key.isEmpty {
            return key
        }
        // Try VoiceMax 1.0.0 first (more recent users), then OpenClaw.
        for legacyService in [Service.legacyDeepgramVM, Service.legacyDeepgramOC] {
            if let legacy = try? readString(service: legacyService, account: "deepgram"),
               !legacy.isEmpty {
                try? writeString(service: Service.deepgramAPIKey, account: "deepgram", value: legacy)
                _ = deleteItem(service: legacyService, account: "deepgram")
                return legacy
            }
        }
        throw Error.notFound("\(Service.deepgramAPIKey)/deepgram")
    }

    /// Upsert a generic password into the login keychain.
    static func writeString(service: String, account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw Error.osStatus("\(service)/\(account)", errSecParam)
        }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let update: [CFString: Any] = [
            kSecValueData:   data,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw Error.osStatus("\(service)/\(account)", addStatus)
            }
            return
        }
        throw Error.osStatus("\(service)/\(account)", status)
    }

    static func setDeepgramAPIKey(_ key: String) throws {
        try writeString(service: Service.deepgramAPIKey, account: "deepgram", value: key)
        _ = deleteItem(service: Service.legacyDeepgramVM, account: "deepgram")
        _ = deleteItem(service: Service.legacyDeepgramOC, account: "deepgram")
    }

    @discardableResult
    static func deleteItem(service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }

    // MARK: - Legacy cleanup

    /// Remove any leftover Telegram / TDLib Keychain entries from VoiceMax 1.0.0
    /// or the early WAM rebrand. Called once by `Migration.runOnce()`. Silent
    /// if nothing exists.
    static func removeLegacyTelegramAndTDLibKeys() {
        let pairs: [(String, String)] = [
            (Service.legacyTelegramVMID,    "telegram"),
            (Service.legacyTelegramVMHash,  "telegram"),
            (Service.legacyTelegramWAMID,   "telegram"),
            (Service.legacyTelegramWAMHash, "telegram"),
            (Service.legacyTdlibDBVM,       "tdlib"),
            (Service.legacyTdlibDBWAM,      "tdlib"),
        ]
        for (service, account) in pairs {
            _ = deleteItem(service: service, account: account)
        }
    }
}
