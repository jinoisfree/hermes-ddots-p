import AppKit

/// Retains the existing controls and actions while laying out each settings category independently.
private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

enum SettingsPages {
    static func make(blocks: [[NSView]]) -> NSScrollView {
        let spacing: CGFloat = 22
        let heights = blocks.map { block in
            (block.map { $0.frame.maxY }.max() ?? 0) - (block.map { $0.frame.minY }.min() ?? 0)
        }
        let height = max(540, heights.reduce(0, +) + spacing * CGFloat(blocks.count + 1))
        let document = SettingsDocument(frame: NSRect(x: 0, y: 0, width: 580, height: height))
        var top = spacing
        for (block, blockHeight) in zip(blocks, heights) {
            let originalTop = block.map { $0.frame.maxY }.max() ?? 0
            for view in block {
                view.removeFromSuperview()
                view.frame.origin.x += 110
                view.frame.origin.y = top + originalTop - view.frame.maxY
                document.addSubview(view)
            }
            top += blockHeight + spacing
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 580))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = document
        document.scroll(.zero)
        return scroll
    }
}
