import AppKit

struct TrayState: Equatable {
    var recording: Bool = false
}

enum TrayIcon {

    static let red  = NSColor(calibratedRed: 1.00, green: 0.23, blue: 0.19, alpha: 1) // #FF3B30
    static let grey = NSColor(calibratedRed: 0.66, green: 0.66, blue: 0.66, alpha: 1) // #A9A9A9

    static let iconSize: CGFloat = 16

    /// Плавный кросс-фейд: `blend` 0 = серый, 1 = красный. Без пульсации.
    static func crossfadeImage(blend: CGFloat) -> NSImage {
        let b = max(0, min(1, blend))
        let size = iconSize
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: 1.5, dy: 1.5)
            let path = NSBezierPath(ovalIn: inset)
            grey.withAlphaComponent(1 - b).setFill()
            path.fill()
            red.withAlphaComponent(b).setFill()
            path.fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    static func idleImage() -> NSImage { crossfadeImage(blend: 0) }
}
