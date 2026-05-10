import AppKit
import ApplicationServices

/// Глобальный перехват **fn**: `CGEventTap` + `CGEventFlags.maskSecondaryFn`.
/// На MacBook встроенная клавиша fn часто **не** выставляет `NSEvent.ModifierFlags.function` в глобальном мониторе.
private enum FNKeyTapStorage {
    static var lastFnDown = false
    static var onPress: (() -> Void)?
    static var onRelease: (() -> Void)?
    static var port: CFMachPort?
}

private func fnFlagsChangedCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // macOS disables the tap on timeout / user input; we must re-enable it ourselves.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = FNKeyTapStorage.port {
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async {
                TrayLog.append("FN: tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input")")
            }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .flagsChanged else {
        return Unmanaged.passUnretained(event)
    }

    let cgFn = event.flags.contains(.maskSecondaryFn)
    var nsFn = false
    if let nse = NSEvent(cgEvent: event) {
        nsFn = nse.modifierFlags.contains(.function)
    }
    let fnNow = cgFn || nsFn

    if fnNow && !FNKeyTapStorage.lastFnDown {
        FNKeyTapStorage.lastFnDown = true
        DispatchQueue.main.async { FNKeyTapStorage.onPress?() }
    } else if !fnNow && FNKeyTapStorage.lastFnDown {
        FNKeyTapStorage.lastFnDown = false
        DispatchQueue.main.async { FNKeyTapStorage.onRelease?() }
    }

    return Unmanaged.passUnretained(event)
}

/// Устанавливает event tap на главном run loop (нужны права Accessibility / Ввод с клавиатуры).
final class FNKeyTap {
    private var port: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// `true` если tap установлен; иначе нужен fallback (`NSEvent`).
    /// `onRelease` is optional — fires on the FN-up edge for callers that
    /// need hold semantics (e.g. push-to-record-me during a meeting).
    @discardableResult
    func start(onPress: @escaping () -> Void,
               onRelease: (() -> Void)? = nil) -> Bool {
        stop()
        FNKeyTapStorage.onPress = onPress
        FNKeyTapStorage.onRelease = onRelease
        FNKeyTapStorage.lastFnDown = false

        // flagsChanged + tap-disabled notifications so we can re-enable on timeout / user input.
        let mask = CGEventMask(
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: fnFlagsChangedCallback,
            userInfo: nil
        ) else {
            TrayLog.append("FN: CGEvent.tapCreate failed — System Settings → Privacy → Accessibility & Input Monitoring → WAM Voice Capture")
            return false
        }

        port = tap
        FNKeyTapStorage.port = tap
        CGEvent.tapEnable(tap: tap, enable: true)

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        TrayLog.append("FN: CGEventTap installed (fn key)")
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
        FNKeyTapStorage.onPress = nil
        FNKeyTapStorage.onRelease = nil
        FNKeyTapStorage.lastFnDown = false
        FNKeyTapStorage.port = nil
    }

    deinit { stop() }
}
