import AppKit
import ApplicationServices

/// Global hotkey tap. Despite the legacy `FNKeyTap` name (kept to minimize
/// diff with the VoiceMax 1.0.0 baseline), this class now watches the
/// **right Option (⌥) key** via `flagsChanged` events with tap semantics:
/// press-and-release-without-other-key-in-between → fire `onPress`.
///
/// Why right Option:
/// - Not bound to any macOS system shortcut (unlike F5 which is glued to
///   Dictation via the keyboard's mic icon — macOS keeps re-binding F5
///   even when the user changes the Dictation shortcut).
/// - Easy to find by feel (immediately right of the right Cmd / spacebar).
/// - Doesn't generate text by itself; modifier role for option-letter
///   combos (⌥+L = ¬, ⌥+G = ©) preserved because we pass through the
///   flagsChanged events instead of swallowing them.
///
/// "Tap" semantics:
///   right Option down → mark "tap pending"
///   any other keyDown → clear "tap pending" (this was an ⌥-combo)
///   right Option up   → if tap still pending, fire onPress
private enum HotkeyTapStorage {
    static var onPress: (() -> Void)?
    static var port: CFMachPort?
    /// `kVK_RightOption` from `Carbon/HIToolbox/Events.h`.
    static let targetKeycode: Int64 = 61
    /// `NX_DEVICERALTKEYMASK` from `IOLLEvent.h` — distinguishes right from
    /// left Option in `CGEvent.flags`. `.maskAlternate` is set for either side.
    static let rightOptionBit: UInt64 = 0x40

    /// Last known state of the right Option key, derived from
    /// `NX_DEVICERALTKEYMASK` in the flagsChanged event's flags.
    static var rightOptionDown: Bool = false
    /// `true` between a right-Option press and the next keyDown / release.
    /// Cleared by any non-Option keyDown — that turns the press into a
    /// modifier-combo (e.g. ⌥+L) and we must NOT fire `onPress` on release.
    static var tapPending: Bool = false
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

    if type == .keyDown {
        // Any other key while right Option is held cancels the pending tap —
        // this was an ⌥-combo, not a tap. We always pass keyDown through; we
        // never swallow regular keys.
        HotkeyTapStorage.tapPending = false
        return Unmanaged.passUnretained(event)
    }

    if type == .flagsChanged {
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        // flagsChanged fires for every modifier change. Only care about
        // right Option — left Option, ⌘, ⇧ etc. pass through unchanged.
        guard keycode == HotkeyTapStorage.targetKeycode else {
            return Unmanaged.passUnretained(event)
        }
        // Use the device-specific right-Option bit, not `.maskAlternate`,
        // which is also set when the LEFT Option is held.
        let isCurrentlyDown = (event.flags.rawValue & HotkeyTapStorage.rightOptionBit) != 0
        let wasDown = HotkeyTapStorage.rightOptionDown
        HotkeyTapStorage.rightOptionDown = isCurrentlyDown

        if isCurrentlyDown && !wasDown {
            // Press edge — start watching for tap-vs-combo.
            HotkeyTapStorage.tapPending = true
        } else if !isCurrentlyDown && wasDown {
            // Release edge — fire only if nothing intervened.
            if HotkeyTapStorage.tapPending {
                HotkeyTapStorage.tapPending = false
                DispatchQueue.main.async { HotkeyTapStorage.onPress?() }
            }
        }
        // Don't swallow: ⌥-combos (⌥+L = ¬ etc.) must still work for typing.
        return Unmanaged.passUnretained(event)
    }

    return Unmanaged.passUnretained(event)
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
            (1 << CGEventType.keyDown.rawValue) |          // detect ⌥-combos
            (1 << CGEventType.flagsChanged.rawValue) |     // right Option press/release
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
            TrayLog.append("Hotkey: CGEvent.tapCreate failed — requesting Accessibility access via system dialog")
            // Pop the system dialog so the user is taken straight to the
            // correct Privacy & Security page. Returns immediately; the
            // dialog is non-modal and the user must restart the app after
            // granting. This is the same pattern Rectangle / Hammerspoon use.
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts = [key: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(opts)
            TrayLog.append("Hotkey: AXIsProcessTrusted = \(trusted). Grant Accessibility, then relaunch app.")
            return false
        }

        port = tap
        HotkeyTapStorage.port = tap
        CGEvent.tapEnable(tap: tap, enable: true)

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        TrayLog.append("Hotkey: CGEventTap installed (keycode=\(HotkeyTapStorage.targetKeycode) [right Option ⌥], tap semantics, no swallow)")
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
        HotkeyTapStorage.rightOptionDown = false
        HotkeyTapStorage.tapPending = false
    }

    deinit { stop() }
}
