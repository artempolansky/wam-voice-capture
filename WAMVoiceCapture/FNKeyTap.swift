import AppKit
import ApplicationServices

/// Global hotkey tap. Despite the legacy `FNKeyTap` name (kept to minimize
/// diff with the VoiceMax 1.0.0 baseline), this class no longer listens to
/// the `fn` modifier — it watches for **F5** key-down events (`keyCode = 96`)
/// and **swallows them** so the focused app never sees F5 (e.g. Chrome won't
/// refresh, Notion won't run its own F5 binding).
///
/// File-level rename to `HotkeyTap.swift` is intentionally deferred.
private enum HotkeyTapStorage {
    static var onPress: (() -> Void)?
    static var port: CFMachPort?
    /// `kVK_F5` from `Carbon/HIToolbox/Events.h`.
    static let targetKeycode: Int64 = 96
}

private func hotkeyKeyDownCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // macOS disables the tap on timeout / user input; re-enable it ourselves.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = HotkeyTapStorage.port {
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async {
                TrayLog.append("Hotkey: tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    guard keycode == HotkeyTapStorage.targetKeycode else {
        // Not F5 — pass through untouched.
        return Unmanaged.passUnretained(event)
    }

    DispatchQueue.main.async { HotkeyTapStorage.onPress?() }

    // Return nil to drop the event so the focused app never sees F5.
    // Chrome / Slack / Finder etc. won't run their own F5 bindings.
    return nil
}

/// Installs a CGEventTap on the main run loop. Requires Accessibility +
/// Input Monitoring permissions in System Settings → Privacy & Security.
final class FNKeyTap {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// `true` if the tap was installed successfully.
    /// `onRelease` is kept in the signature for source compatibility with
    /// the VoiceMax 1.0.0 call site but is no longer invoked — F5 is a
    /// press-to-toggle hotkey, no key-up semantics needed.
    @discardableResult
    func start(onPress: @escaping () -> Void,
               onRelease: (() -> Void)? = nil) -> Bool {
        stop()
        HotkeyTapStorage.onPress = onPress

        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyKeyDownCallback,
            userInfo: nil
        ) else {
            TrayLog.append("Hotkey: CGEvent.tapCreate failed — System Settings → Privacy → Accessibility & Input Monitoring → WAM Voice Capture")
            return false
        }

        port = tap
        HotkeyTapStorage.port = tap
        CGEvent.tapEnable(tap: tap, enable: true)

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        TrayLog.append("Hotkey: CGEventTap installed (keycode=\(HotkeyTapStorage.targetKeycode) [F5], swallow=true)")
        return true
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = port {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            port = nil
        }
        HotkeyTapStorage.onPress = nil
        HotkeyTapStorage.port = nil
    }

    deinit { stop() }
}
