import AppKit

/// Menu bar mark: a cat's paw cut out of a filled circle. Drawn as a template so macOS tints it for light and dark bars.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    /// Coordinates are in an 18pt box with the origin at the bottom left.
    static func path() -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: 17, height: 17))
        // Large pad: rounded triangle with the two lower lobes a cat's pad has.
        path.move(to: NSPoint(x: 9, y: 9.3))
        path.curve(to: NSPoint(x: 12.9, y: 5.6), controlPoint1: NSPoint(x: 11.2, y: 9.3), controlPoint2: NSPoint(x: 12.9, y: 7.4))
        path.curve(to: NSPoint(x: 10.9, y: 3.9), controlPoint1: NSPoint(x: 12.9, y: 4.5), controlPoint2: NSPoint(x: 11.9, y: 3.9))
        path.curve(to: NSPoint(x: 9, y: 4.5), controlPoint1: NSPoint(x: 10.1, y: 3.9), controlPoint2: NSPoint(x: 9.6, y: 4.5))
        path.curve(to: NSPoint(x: 7.1, y: 3.9), controlPoint1: NSPoint(x: 8.4, y: 4.5), controlPoint2: NSPoint(x: 7.9, y: 3.9))
        path.curve(to: NSPoint(x: 5.1, y: 5.6), controlPoint1: NSPoint(x: 6.1, y: 3.9), controlPoint2: NSPoint(x: 5.1, y: 4.5))
        path.curve(to: NSPoint(x: 9, y: 9.3), controlPoint1: NSPoint(x: 5.1, y: 7.4), controlPoint2: NSPoint(x: 6.8, y: 9.3))
        path.close()
        // Four toe beans in an arc, the outer two leaning outward.
        for (x, y, width, height, degrees) in [(4.5, 9.7, 2.5, 3.2, 22.0), (7.2, 12.5, 2.6, 3.4, 6.0), (10.8, 12.5, 2.6, 3.4, -6.0), (13.5, 9.7, 2.5, 3.2, -22.0)] {
            let toe = NSBezierPath(ovalIn: NSRect(x: -width / 2, y: -height / 2, width: width, height: height))
            var transform = AffineTransform(translationByX: x, byY: y)
            transform.rotate(byDegrees: degrees)
            toe.transform(using: transform)
            path.append(toe)
        }
        path.windingRule = .evenOdd
        return path
    }
    static func image(description: String) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill(); path().fill(); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }
}
