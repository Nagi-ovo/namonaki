import AppKit

/// The menu bar glyph, drawn in code rather than shipped as an asset.
///
/// It has to be a template image: the menu bar inverts it for dark mode and tints it
/// while the menu is open, and only a template gets that for free. That also rules out
/// using the app icon here — a colour illustration would look wrong and read as mush at
/// 18pt.
@MainActor
enum MenuBarIcon {
    static func make(pointSize: CGFloat = 18) -> NSImage {
        let size = NSSize(width: pointSize, height: pointSize)
        let image = NSImage(size: size, flipped: false) { _ in
            let s = pointSize
            let path = NSBezierPath(
                roundedRect: NSRect(x: s * 0.10, y: s * 0.30, width: s * 0.80, height: s * 0.58),
                xRadius: s * 0.20,
                yRadius: s * 0.20
            )

            // The tail, matching the app icon's shape language: it leaves the body from
            // the lower left and tapers down.
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: s * 0.30, y: s * 0.36))
            tail.curve(
                to: NSPoint(x: s * 0.20, y: s * 0.10),
                controlPoint1: NSPoint(x: s * 0.30, y: s * 0.26),
                controlPoint2: NSPoint(x: s * 0.26, y: s * 0.16)
            )
            tail.curve(
                to: NSPoint(x: s * 0.48, y: s * 0.32),
                controlPoint1: NSPoint(x: s * 0.32, y: s * 0.18),
                controlPoint2: NSPoint(x: s * 0.42, y: s * 0.28)
            )
            tail.close()
            path.append(tail)

            path.lineWidth = max(s * 0.085, 1)
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
