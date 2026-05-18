import Foundation

/// One-shot migration from VoiceMax 1.0.0 layout to WAM Voice Capture.
///
/// Runs at app launch before any other component touches UserDefaults or
/// Application Support paths. Idempotent — guarded by a flag in UserDefaults.
///
/// Migrated:
/// - `UserDefaults` keys with `VoiceMax*` prefix → `WAM*`
/// - `~/Library/Application Support/VoiceMax/` → `~/Library/Application Support/WAM Voice Capture/`
///   (includes `tdlib/`, `tdlib-files/`, and the legacy log file)
///
/// **Not** migrated (intentional):
/// - `~/Documents/VoiceMax-Recordings/` — left in place; user can move it
///   manually or rely on the new default `WAM Voice Capture Recordings/`
///   for new recordings.
///
/// Keychain migration is handled lazily inside `KeychainHelper` per key.
enum Migration {

    private static let flagKey = "wam-voice-capture.migrated.from-voicemax-1.0.0"

    /// Pairs of (old UserDefaults key, new key) preserved across the rename.
    private static let userDefaultsKeyPairs: [(old: String, new: String)] = [
        ("VoiceMaxMicDeviceUID", "WAMMicDeviceUID"),
        ("VoiceMaxLightHost",    "WAMLightHost"),
        ("VoiceMaxLightPort",    "WAMLightPort"),
        ("VoiceMaxLightEnabled", "WAMLightEnabled"),
        // Reserved for any future legacy keys (Telegram routes, etc.).
        ("VoiceMaxSelectedRoute",  "WAMSelectedRoute"),
        ("VoiceMaxFavoriteRoutes", "WAMFavoriteRoutes"),
        ("VoiceMaxRouteTitles",    "WAMRouteTitles"),
        ("VoiceMaxGroupID",        "WAMGroupID"),
    ]

    /// Run once. Subsequent calls are no-ops.
    /// Must be called before `TrayLog.append` triggers — `TrayLog` writes into
    /// the *new* directory, so without prior `mv` of the legacy dir we'd end
    /// up with two directories on disk.
    static func runOnce() {
        let defaults = UserDefaults.standard

        // TDLib cleanup runs every launch (cheap, idempotent). Run UNGUARDED
        // by the flag because users who already migrated from VoiceMax 1.0.0
        // (flag is set) still need this one-off TDLib removal on upgrade.
        // Subsequent launches no-op once the dirs are gone.
        cleanupRetiredTDLibArtifacts()

        guard !defaults.bool(forKey: flagKey) else { return }

        migrateUserDefaults(defaults: defaults)
        migrateApplicationSupportDirectory()

        defaults.set(true, forKey: flagKey)
        // Direct stderr — TrayLog isn't safe yet on the very first call after
        // a fresh upgrade because its file path resolves to the just-renamed dir.
        fputs("WAM: legacy migration from VoiceMax 1.0.0 completed\n", stderr)
    }

    /// Remove TDLib leftovers (encrypted SQLite DB + downloaded files + Keychain
    /// keys) from VoiceMax 1.0.0 / early WAM builds. TDLib-based delivery was
    /// retired in favor of file-sync (Phase 7a) so these artifacts only waste
    /// disk space and a Keychain slot.
    private static func cleanupRetiredTDLibArtifacts() {
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupport = base.appendingPathComponent("WAM Voice Capture", isDirectory: true)
            for name in ["tdlib", "tdlib-files"] {
                let dir = appSupport.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: dir.path) {
                    try? fm.removeItem(at: dir)
                    fputs("WAM: removed retired TDLib dir \(name)\n", stderr)
                }
            }
        }
        KeychainHelper.removeLegacyTelegramAndTDLibKeys()
    }

    private static func migrateUserDefaults(defaults: UserDefaults) {
        for (old, new) in userDefaultsKeyPairs {
            // Preserve any value the user has under the old key; never clobber a new one.
            if defaults.object(forKey: new) == nil,
               let value = defaults.object(forKey: old) {
                defaults.set(value, forKey: new)
            }
            defaults.removeObject(forKey: old)
        }
    }

    private static func migrateApplicationSupportDirectory() {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let oldDir = base.appendingPathComponent("VoiceMax", isDirectory: true)
        let newDir = base.appendingPathComponent("WAM Voice Capture", isDirectory: true)

        let oldExists = fm.fileExists(atPath: oldDir.path)
        let newExists = fm.fileExists(atPath: newDir.path)

        if oldExists && !newExists {
            // Atomic mv — preserves tdlib/, tdlib-files/, log file.
            try? fm.moveItem(at: oldDir, to: newDir)
        } else if oldExists && newExists {
            // Edge case: user re-imported VoiceMax after running new build once.
            // Don't merge to avoid corrupting newer state; leave legacy alone.
            fputs("WAM: legacy 'VoiceMax' Application Support dir present alongside new 'WAM Voice Capture' — leaving legacy untouched\n", stderr)
        }

        // Inside the (now-renamed) new dir: rename legacy log file if present.
        let legacyLog = newDir.appendingPathComponent("voicemax-tray.txt")
        let newLog    = newDir.appendingPathComponent("wam-voice-capture-tray.txt")
        if fm.fileExists(atPath: legacyLog.path) && !fm.fileExists(atPath: newLog.path) {
            try? fm.moveItem(at: legacyLog, to: newLog)
        }
    }
}
