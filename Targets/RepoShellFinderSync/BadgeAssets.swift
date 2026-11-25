import Cocoa
import FinderSync
import RepoShellShared

enum BadgeAssets {
    static func registerBadges(on controller: FIFinderSyncController) {
        let specs: [(id: String, label: String, color: NSColor, symbol: String)] = [
            ("normal", "Normal", NSColor.systemGreen, "checkmark"),
            ("modified", "Modified", NSColor.systemOrange, "exclamationmark"),
            ("added", "Added", NSColor.systemPurple, "plus"),
            ("deleted", "Deleted", NSColor.systemRed, "minus"),
            ("conflict", "Conflict", NSColor.systemRed, "xmark"),
            ("untracked", "Untracked", NSColor.systemBlue, "questionmark"),
            ("ignored", "Ignored", NSColor.systemGray, "nosign"),
            ("external", "External", NSColor.systemTeal, "link"),
            ("locked", "Locked", NSColor.systemYellow, "lock.fill"),
            ("readonly", "ReadOnly", NSColor.darkGray, "lock")
        ]

        for spec in specs {
            let image = drawBadge(color: spec.color, symbolName: spec.symbol)
            controller.setBadgeImage(image, label: spec.label, forBadgeIdentifier: spec.id)
        }
    }

    static func toolbarIconImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            // Minimal git-branch + shell outline glyph
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.appendOval(in: NSRect(x: 3, y: 11, width: 4, height: 4))
            path.appendOval(in: NSRect(x: 3, y: 3, width: 4, height: 4))
            path.appendOval(in: NSRect(x: 11, y: 10, width: 4, height: 4))
            path.move(to: NSPoint(x: 5, y: 7))
            path.line(to: NSPoint(x: 5, y: 11))
            path.move(to: NSPoint(x: 7, y: 5))
            path.curve(to: NSPoint(x: 13, y: 10),
                       controlPoint1: NSPoint(x: 11, y: 5),
                       controlPoint2: NSPoint(x: 13, y: 7))
            path.stroke()
            _ = rect
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func drawBadge(color: NSColor, symbolName: String) -> NSImage {
        let size = NSSize(width: 32, height: 32)
        return NSImage(size: size, flipped: false) { rect in
            let insetRect = rect.insetBy(dx: 2, dy: 2)
            let circle = NSBezierPath(ovalIn: insetRect)

            // Outer white halo for contrast over any file icon
            NSColor.white.withAlphaComponent(0.92).setFill()
            circle.fill()

            let innerRect = insetRect.insetBy(dx: 2, dy: 2)
            let inner = NSBezierPath(ovalIn: innerRect)
            color.setFill()
            inner.fill()

            if let sym = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
                if let configured = sym.withSymbolConfiguration(cfg) {
                    let tinted = tintImage(configured, with: .white)
                    let symRect = NSRect(x: 8, y: 8, width: 16, height: 16)
                    tinted.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                }
            }
            return true
        }
    }

    private static func tintImage(_ image: NSImage, with color: NSColor) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.lockFocus()
        color.set()
        let rect = NSRect(origin: .zero, size: copy.size)
        rect.fill(using: .sourceAtop)
        copy.unlockFocus()
        return copy
    }
}
