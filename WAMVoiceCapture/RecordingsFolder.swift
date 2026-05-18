import Foundation

/// User-configurable destination for meeting `.md` transcript files.
///
/// Persisted as a plain absolute path in `UserDefaults` under
/// `WAMRecordingsFolder`. We don't use security-scoped bookmarks because the
/// app is not sandboxed — direct file access works anywhere the user can
/// write to (iCloud Drive, Dropbox, external volumes, etc.).
///
/// Default: `~/Documents/WAM Voice Capture Recordings/`.
enum RecordingsFolder {

    private static let defaultsKey = "WAMRecordingsFolder"
    private static let defaultSubdir = "WAM Voice Capture Recordings"

    /// The current target directory. Creates it on disk if missing.
    /// Falls back silently to the default if the configured path is gone
    /// (e.g. external volume unmounted) — recording always works.
    static func currentURL() -> URL {
        if let configured = configuredURL(), exists(configured) {
            return configured
        }
        return defaultURL()
    }

    /// Path stored in UserDefaults, or nil if the user hasn't set one.
    /// `nil` is the signal "use default".
    static func configuredURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey),
              !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Built-in default. Always exists after the first call.
    static func defaultURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent(defaultSubdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Update the configured target. Pass `nil` to reset to default.
    /// The directory is created if it doesn't exist.
    static func setConfigured(_ url: URL?) {
        if let url {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            UserDefaults.standard.set(url.path, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    /// True if the configured path exists and is a directory we can write to.
    private static func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else {
            return false
        }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    /// Human-readable form for display in the tray menu.
    /// Returns "Default (~/Documents/.../)" for the default; absolute path otherwise.
    static func displayPath() -> String {
        if let url = configuredURL() {
            return url.path
        }
        return defaultURL().path
    }

    /// True if the user has set a custom path (not the default).
    static var isCustom: Bool { configuredURL() != nil }
}
