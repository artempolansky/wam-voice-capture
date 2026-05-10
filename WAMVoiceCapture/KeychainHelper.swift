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
        static let telegramAPIID     = "wam-voice-capture.telegram.api_id"
        static let legacyTelegramID  = "voicemax.telegram.api_id"
        static let telegramAPIHash   = "wam-voice-capture.telegram.api_hash"
        static let legacyTelegramHash = "voicemax.telegram.api_hash"
        static let tdlibDatabaseKey  = "wam-voice-capture.tdlib_db_key"
        static let legacyTdlibDBKey  = "voicemax.tdlib_db_key"
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

    // MARK: - Telegram app credentials

    struct TelegramCredentials {
        let apiID: Int32
        let apiHash: String
    }

    static func telegramCredentials() -> TelegramCredentials? {
        // Read new keys; if missing, fall back to legacy `voicemax.*` and migrate forward.
        var idStr = try? readString(service: Service.telegramAPIID, account: "telegram")
        var hashStr = try? readString(service: Service.telegramAPIHash, account: "telegram")
        if idStr == nil || (idStr?.isEmpty ?? true) {
            if let legacyID = try? readString(service: Service.legacyTelegramID, account: "telegram"),
               !legacyID.isEmpty {
                try? writeString(service: Service.telegramAPIID, account: "telegram", value: legacyID)
                _ = deleteItem(service: Service.legacyTelegramID, account: "telegram")
                idStr = legacyID
            }
        }
        if hashStr == nil || (hashStr?.isEmpty ?? true) {
            if let legacyHash = try? readString(service: Service.legacyTelegramHash, account: "telegram"),
               !legacyHash.isEmpty {
                try? writeString(service: Service.telegramAPIHash, account: "telegram", value: legacyHash)
                _ = deleteItem(service: Service.legacyTelegramHash, account: "telegram")
                hashStr = legacyHash
            }
        }
        guard
            let idStr,
            let id = Int32(idStr.trimmingCharacters(in: .whitespacesAndNewlines)),
            let hash = hashStr,
            !hash.isEmpty
        else { return nil }
        return TelegramCredentials(apiID: id, apiHash: hash)
    }

    static func setTelegramCredentials(apiID: Int32, apiHash: String) throws {
        try writeString(service: Service.telegramAPIID,  account: "telegram", value: String(apiID))
        try writeString(service: Service.telegramAPIHash, account: "telegram", value: apiHash)
        _ = deleteItem(service: Service.legacyTelegramID,   account: "telegram")
        _ = deleteItem(service: Service.legacyTelegramHash, account: "telegram")
    }

    static func clearTelegramCredentials() {
        _ = deleteItem(service: Service.telegramAPIID,  account: "telegram")
        _ = deleteItem(service: Service.telegramAPIHash, account: "telegram")
        _ = deleteItem(service: Service.legacyTelegramID,   account: "telegram")
        _ = deleteItem(service: Service.legacyTelegramHash, account: "telegram")
    }

    // MARK: - TDLib database key

    /// 32 random bytes used as `database_encryption_key` for TDLib.
    /// Generated once, stored base64 in Keychain. Losing it = losing the session.
    static func tdlibDatabaseKey() throws -> Data {
        if let b64 = try? readString(service: Service.tdlibDatabaseKey, account: "tdlib"),
           let data = Data(base64Encoded: b64), data.count == 32 {
            return data
        }
        // Migrate from legacy `voicemax.tdlib_db_key` if present (preserves session).
        if let b64 = try? readString(service: Service.legacyTdlibDBKey, account: "tdlib"),
           let data = Data(base64Encoded: b64), data.count == 32 {
            try? writeString(service: Service.tdlibDatabaseKey, account: "tdlib", value: b64)
            _ = deleteItem(service: Service.legacyTdlibDBKey, account: "tdlib")
            return data
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw Error.osStatus("SecRandomCopyBytes", status)
        }
        let data = Data(bytes)
        try writeString(service: Service.tdlibDatabaseKey, account: "tdlib", value: data.base64EncodedString())
        return data
    }

    static func clearTDLibDatabaseKey() {
        _ = deleteItem(service: Service.tdlibDatabaseKey, account: "tdlib")
        _ = deleteItem(service: Service.legacyTdlibDBKey, account: "tdlib")
    }
}
