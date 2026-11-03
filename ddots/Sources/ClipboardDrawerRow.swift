import AppKit

/// Part of the retained bubble surface, never a second glass panel.
final class ClipboardDrawerRow: NSControl {
    var text = "" { didSet { setAccessibilityLabel(text); needsDisplay = true } }
    var expanded = false { didSet { needsDisplay = true } }
    var below = false { didSet { if oldValue != below { needsDisplay = true } } }
    var detail = "" { didSet { needsDisplay = true } }
    var avatar: ProfileAvatar?
    var avatarName: String?
    var attention = false { didSet { needsDisplay = true } }
    var activate: ((Bool) -> Void)?
    override init(frame: CGRect) {
        super.init(frame: frame); setAccessibilityElement(true); setAccessibilityRole(.button)
        setAccessibilityLabel("클립보드 열기"); identifier = NSUserInterfaceItemIdentifier("clipboard-drawer-row")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        let collapse = expanded && point.x >= bounds.maxX - 34
        if !expanded || collapse || attention { activate?(collapse) }
    }
    override func accessibilityPerformPress() -> Bool { activate?(expanded && !attention); return true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.35).setFill(); CGRect(x: 12, y: below ? 0.5 : bounds.maxY - 1, width: max(0, bounds.width - 24), height: 0.5).fill()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let color = ClipboardAppearance.primary(effectiveAppearance)
        let left: CGFloat = expanded && avatarName != nil ? 44 : 12
        if expanded, let name = avatarName { (avatar ?? ProfileAvatar()).draw(in: CGRect(x: 12, y: 10, width: 24, height: 24), name: name) }
        if expanded {
            (detail as NSString).draw(in: CGRect(x: left, y: 7, width: max(0, bounds.width - left - 34), height: 13),
                withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: color, .paragraphStyle: paragraph])
        }
        (text as NSString).draw(in: CGRect(x: left, y: expanded ? 23 : (bounds.height - 14) / 2, width: max(0, bounds.width - left - 34), height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: color, .paragraphStyle: paragraph])
        (((expanded != below) ? "⌄" : "⌃") as NSString).draw(at: CGPoint(x: bounds.maxX - 25, y: (bounds.height - 16) / 2),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: color])
    }
}
