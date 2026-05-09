import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held strongly so the status item is not torn down when `applicationDidFinishLaunching` returns.
    private var status: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
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
