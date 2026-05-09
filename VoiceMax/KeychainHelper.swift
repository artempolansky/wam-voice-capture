import Foundation
import Security

/// Tiny Keychain reader for VoiceMax secrets.
/// Convention: service `voicemax.<name>`, account matches the service tail
/// (e.g. service `voicemax.deepgram.api_key`, account `deepgram`).
enum KeychainHelper {

    enum Service {
        static let deepgramAPIKey    = "voicemax.deepgram.api_key"
        static let legacyDeepgram    = "openclaw.deepgram.api_key"
        static let telegramAPIID     = "voicemax.telegram.api_id"
        static let telegramAPIHash   = "voicemax.telegram.api_hash"
        static let tdlibDatabaseKey  = "voicemax.tdlib_db_key"
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

    /// Reads `voicemax.deepgram.api_key`. On first call after upgrading from the legacy
    /// `openclaw.deepgram.api_key`, copies the value forward and removes the old item.
    /// Transparent to the user — no re-entry needed.
    static func deepgramAPIKey() throws -> String {
        if let key = try? readString(service: Service.deepgramAPIKey, account: "deepgram"),
           !key.isEmpty {
            return key
        }
        let legacy = try readString(service: Service.legacyDeepgram, account: "deepgram")
        try? writeString(service: Service.deepgramAPIKey, account: "deepgram", value: legacy)
        _ = deleteItem(service: Service.legacyDeepgram, account: "deepgram")
        return legacy
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
        _ = deleteItem(service: Service.legacyDeepgram, account: "deepgram")
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
        guard
            let idStr = try? readString(service: Service.telegramAPIID, account: "telegram"),
            let id = Int32(idStr.trimmingCharacters(in: .whitespacesAndNewlines)),
            let hash = try? readString(service: Service.telegramAPIHash, account: "telegram"),
            !hash.isEmpty
        else { return nil }
        return TelegramCredentials(apiID: id, apiHash: hash)
    }

    static func setTelegramCredentials(apiID: Int32, apiHash: String) throws {
        try writeString(service: Service.telegramAPIID,  account: "telegram", value: String(apiID))
        try writeString(service: Service.telegramAPIHash, account: "telegram", value: apiHash)
    }

    static func clearTelegramCredentials() {
        _ = deleteItem(service: Service.telegramAPIID,  account: "telegram")
        _ = deleteItem(service: Service.telegramAPIHash, account: "telegram")
    }

    // MARK: - TDLib database key

    /// 32 random bytes used as `database_encryption_key` for TDLib.
    /// Generated once, stored base64 in Keychain. Losing it = losing the session.
    static func tdlibDatabaseKey() throws -> Data {
        if let b64 = try? readString(service: Service.tdlibDatabaseKey, account: "tdlib"),
           let data = Data(base64Encoded: b64), data.count == 32 {
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
    }
}
