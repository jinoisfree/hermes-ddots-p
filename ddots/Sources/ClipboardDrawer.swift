import Foundation
import CoreGraphics

/// Shelf geometry is independent of conversation dimensions and clipboard payload storage.
enum ClipboardDrawer {
    static let rowHeight: CGFloat = 28
    static let footerHeight: CGFloat = 44
    static let defaultSize = CGSize(width: 356, height: 454)
    static let minimumSize = CGSize(width: 246, height: 318)
    static func regions(in bounds: CGRect, rowHeight: CGFloat, below: Bool) -> (row: CGRect, content: CGRect) {
        let height = min(bounds.height, rowHeight)
        return (CGRect(x: bounds.minX, y: below ? bounds.maxY - height : bounds.minY, width: bounds.width, height: height),
                CGRect(x: bounds.minX, y: below ? bounds.minY : bounds.minY + height, width: bounds.width, height: max(0, bounds.height - height)))
    }
    /// The continuous crossing corridor includes the thought dots and the gap between head and glass.
    static func containsPointer(_ point: CGPoint, head: CGRect, bubble: CGRect) -> Bool {
        head.union(bubble).insetBy(dx: -8, dy: -8).contains(point)
    }
    static func resizeEdge(at point: CGPoint, bubble: CGRect, below: Bool) -> PetLayout.ResizeEdge {
        guard bubble.insetBy(dx: -1, dy: -1).contains(point) else { return [] }
        var edge: PetLayout.ResizeEdge = []
        if point.x <= bubble.minX + 6 { edge.insert(.left) }
        if point.x >= bubble.maxX - 6 { edge.insert(.right) }
        if below ? point.y <= bubble.minY + 6 : point.y >= bubble.maxY - 6 { edge.insert(.far) }
        return edge
    }
    static func load(_ defaults: UserDefaults = .standard) -> CGSize {
        let width = defaults.object(forKey: "clipboardShelfWidth") == nil ? defaultSize.width : defaults.double(forKey: "clipboardShelfWidth")
        let height = defaults.object(forKey: "clipboardShelfHeight") == nil ? defaultSize.height : defaults.double(forKey: "clipboardShelfHeight")
        return constrained(CGSize(width: width, height: height))
    }
    static func constrained(_ size: CGSize, screen: CGSize = CGSize(width: 10000, height: 10000)) -> CGSize {
        CGSize(width: min(max(minimumSize.width, size.width.isFinite ? size.width : defaultSize.width), max(minimumSize.width, screen.width - 24)),
               height: min(max(minimumSize.height, size.height.isFinite ? size.height : defaultSize.height), max(minimumSize.height, screen.height - 24)))
    }
    static func save(_ size: CGSize, defaults: UserDefaults = .standard) {
        let size = constrained(size)
        defaults.set(size.width, forKey: "clipboardShelfWidth"); defaults.set(size.height, forKey: "clipboardShelfHeight")
    }
    static let opacityKey = "clipboardOpacity"
    static func opacity(_ defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: opacityKey) == nil ? BubbleOpacity.defaultPercent : BubbleOpacity.clamped(defaults.double(forKey: opacityKey))
    }
    static func columns(width: CGFloat) -> Int { max(2, Int((width - 36 + 10) / 110)) }
}

