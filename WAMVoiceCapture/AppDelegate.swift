import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held strongly so the status item is not torn down when `applicationDidFinishLaunching` returns.
    private var status: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Run migration BEFORE first TrayLog.append — TrayLog writes into the
        // post-migration directory. If we logged first, a fresh upgrade from
        // VoiceMax 1.0.0 would end up with two App Support dirs.
        Migration.runOnce()
        TrayLog.append("applicationWillFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
    }

    /// AppKit always calls this on the main thread; keep tray setup synchronous so the item appears immediately.
    func applicationDidFinishLaunching(_ notification: Notification) {
        TrayLog.append("applicationDidFinishLaunching (main-thread sync setup)")
        status = StatusBarController()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
