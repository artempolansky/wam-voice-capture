import AppKit
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held strongly so the status item is not torn down when `applicationDidFinishLaunching` returns.
    private var status: StatusBarController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Defensive: ``LSMinimumSystemVersion`` already gates the install on
        // macOS 14+, but if someone bypasses that (sideloaded onto a 13.x
        // box) we want a clear alert rather than a confusing AVAudioEngine
        // / EventKit crash mid-flow. Quits the app on dismissal — there's
        // no path to recovery without an OS upgrade.
        if !ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "macOS 14 (Sonoma) or later is required"
            alert.informativeText = "WAM Voice Capture relies on EventKit APIs and audio features introduced in macOS 14. Please upgrade your system to use it."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

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
        UpdateNotifier.shared.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
