import AppKit

/// Clipboard glass keeps primary text opaque; semantic label colors themselves contain transparency.
enum ClipboardAppearance {
    static let darkHoverShade = 0.16
    static let darkPreviewShade = 0.12
    static let darkSelectionShade = 0.35
    static func isDark(_ appearance: NSAppearance) -> Bool { appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    static func primary(dark: Bool) -> NSColor { dark ? .white : .black }
    static func primary(_ appearance: NSAppearance) -> NSColor { primary(dark: isDark(appearance)) }
    static func selection(dark: Bool) -> NSColor {
        guard dark else { return NSColor.white.withAlphaComponent(0.7) }
        // White 22% over the local dark shade; preserve 4.5:1 even over white wallpaper at 55% tint.
        let alpha = 0.22 + darkSelectionShade * 0.78
        return NSColor(white: 0.22 / alpha, alpha: alpha)
    }
}
