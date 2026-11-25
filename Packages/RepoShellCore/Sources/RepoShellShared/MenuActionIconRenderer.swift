#if canImport(AppKit)
import AppKit

/// Renders non-template Retina (`@2x`) RGBA menu icons so palette colors survive FinderSync XPC serialization.
public enum MenuActionIconRenderer {
    private static let cacheLock = NSLock()
    private static var cache: [String: NSImage] = [:]

    public static func menuIcon(for action: MenuAction, size: CGFloat = 16) -> NSImage {
        let key = "action|\(action.rawValue)|\(Int((size * 10).rounded()))"
        return cachedImage(forKey: key, size: size) {
            let colors: [NSColor]
            switch action.iconStyle {
            case .badge(let fill):
                colors = [.white, nsColor(fill)]
            case .twoTone(let primary, let secondary):
                colors = [nsColor(primary), nsColor(secondary)]
            case .solid(let color):
                let c = nsColor(color)
                colors = [c, c.withAlphaComponent(0.82)]
            }
            return drawSymbolBitmap(symbolName: action.systemSymbolName, paletteColors: colors, pointSize: size)
        }
    }

    public static func submenuIcon(
        symbolName: String,
        color: RGBColor = RGBColor(r: 186, g: 118, b: 42),
        size: CGFloat = 16
    ) -> NSImage {
        let key = "submenu|\(symbolName)|\(color.r)-\(color.g)-\(color.b)|\(Int((size * 10).rounded()))"
        return cachedImage(forKey: key, size: size) {
            let c = nsColor(color)
            return drawSymbolBitmap(symbolName: symbolName, paletteColors: [c, c.withAlphaComponent(0.85)], pointSize: size)
        }
    }

    public static func appBrandMenuIcon(size: CGFloat = 16) -> NSImage {
        let key = "brand|\(Int((size * 10).rounded()))"
        return cachedImage(forKey: key, size: size) {
            renderBitmap(pointSize: size) { rect in
                let badgeRect = rect.insetBy(dx: 0.5, dy: 0.5)
                let rounded = NSBezierPath(roundedRect: badgeRect, xRadius: size * 0.24, yRadius: size * 0.24)
                let gradient = NSGradient(
                    starting: NSColor(srgbRed: 0.08, green: 0.66, blue: 0.68, alpha: 1.0),
                    ending: NSColor(srgbRed: 0.11, green: 0.44, blue: 0.92, alpha: 1.0)
                )
                gradient?.draw(in: rounded, angle: -45)

                if let glyph = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) {
                    let symCfg = NSImage.SymbolConfiguration(pointSize: size * 0.56, weight: .bold)
                        .applying(.init(paletteColors: [.white, .white]))
                    let configured = glyph.withSymbolConfiguration(symCfg) ?? glyph
                    drawCentered(configured, in: badgeRect.insetBy(dx: 2.0, dy: 2.0))
                }
            }
        }
    }

    // MARK: - Private Helpers

    private static func nsColor(_ c: RGBColor) -> NSColor {
        NSColor(
            srgbRed: CGFloat(max(0, min(255, c.r))) / 255.0,
            green: CGFloat(max(0, min(255, c.g))) / 255.0,
            blue: CGFloat(max(0, min(255, c.b))) / 255.0,
            alpha: 1.0
        )
    }

    private static func cachedImage(forKey key: String, size: CGFloat, builder: () -> NSImage) -> NSImage {
        cacheLock.lock()
        if let existing = cache[key] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        let created = builder()
        created.size = NSSize(width: size, height: size)
        created.isTemplate = false

        cacheLock.lock()
        cache[key] = created
        cacheLock.unlock()
        return created
    }

    private static func drawSymbolBitmap(
        symbolName: String,
        paletteColors: [NSColor],
        pointSize: CGFloat
    ) -> NSImage {
        renderBitmap(pointSize: pointSize) { rect in
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
            guard let symbol = symbol else { return }

            let cfg = NSImage.SymbolConfiguration(pointSize: pointSize * 0.84, weight: .semibold)
                .applying(.init(paletteColors: paletteColors))
            let configured = symbol.withSymbolConfiguration(cfg) ?? symbol
            drawCentered(configured, in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private static func renderBitmap(pointSize: CGFloat, draw: (NSRect) -> Void) -> NSImage {
        let pixelSide = max(16, Int((pointSize * 2.0).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSide,
            pixelsHigh: pixelSide,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            let fallback = NSImage(size: NSSize(width: pointSize, height: pointSize))
            fallback.isTemplate = false
            return fallback
        }

        rep.size = NSSize(width: pointSize, height: pointSize)
        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            NSColor.clear.set()
            let rect = NSRect(origin: .zero, size: rep.size)
            rect.fill()
            draw(rect)
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        img.isTemplate = false
        return img
    }

    private static func drawCentered(_ image: NSImage, in bounds: NSRect) {
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
            return
        }
        let scale = min(bounds.width / srcSize.width, bounds.height / srcSize.height)
        let drawW = srcSize.width * scale
        let drawH = srcSize.height * scale
        let dest = NSRect(
            x: bounds.midX - drawW * 0.5,
            y: bounds.midY - drawH * 0.5,
            width: drawW,
            height: drawH
        )
        image.draw(in: dest, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
}
#endif
