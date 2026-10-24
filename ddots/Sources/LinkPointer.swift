import AppKit
import SwiftUI

private struct LinkPointerEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var linkPointerEnabled: Bool {
        get { self[LinkPointerEnabledKey.self] }
        set { self[LinkPointerEnabledKey.self] = newValue }
    }
}

extension Text {
    init(linkPointer text: AttributedString) {
        if #available(macOS 15.0, *), text.runs.contains(where: { $0.link != nil }) {
            self = text.runs.reduce(Text(verbatim: "")) { result, run in
                let part = Text(AttributedString(text[run.range]))
                return result + (run.link == nil ? part : part.customAttribute(LinkPointerAttribute(url: run.link!)))
            }
        } else { self.init(text) }
    }
}

@available(macOS 15.0, *)
private struct LinkPointerAttribute: TextAttribute { let url: URL }

struct LinkText: View {
    let text: AttributedString
    init(_ text: AttributedString) {
        var styled = text
        for run in styled.runs where run.link != nil {
            styled[run.range].underlineStyle = Text.LineStyle(pattern: .solid)
            if run.foregroundColor == nil { styled[run.range].foregroundColor = Color(red: 0.3, green: 0.75, blue: 1) }
        }
        self.text = styled
    }
    @ViewBuilder var body: some View {
        if #available(macOS 15.0, *), text.runs.contains(where: { $0.link != nil }) {
            Text(linkPointer: text).linkPointer()
        } else { Text(text) }
    }
}

extension View {
    @ViewBuilder fileprivate func linkPointer() -> some View {
        if #available(macOS 15.0, *) {
            overlayPreferenceValue(Text.LayoutKey.self) { layouts in
                GeometryReader { geometry in
                    let regions = layouts.flatMap { anchored in
                        let origin = geometry[anchored.origin]
                        return anchored.layout.flatMap { line in
                            line.compactMap { run -> LinkRegion? in
                                guard let attribute = run[LinkPointerAttribute.self] else { return nil }
                                return LinkRegion(rect: run.typographicBounds.rect.offsetBy(dx: origin.x, dy: origin.y), url: attribute.url)
                            }
                        }
                    }
                    if !regions.isEmpty { LinkCursorRegion(regions: regions).accessibilityHidden(true) }
                }
            }
        } else { self }
    }

    @ViewBuilder func filePointer() -> some View {
        if #available(macOS 15.0, *) {
            background(GeometryReader { geometry in
                LinkCursorRegion(regions: [LinkRegion(rect: CGRect(origin: .zero, size: geometry.size), url: nil)]).accessibilityHidden(true)
            })
        } else { self }
    }
}

private struct LinkRegion: Equatable {
    var rect: CGRect
    var url: URL?
}

private struct LinkCursorRegion: NSViewRepresentable {
    let regions: [LinkRegion]
    @Environment(\.linkPointerEnabled) private var enabled
    @Environment(\.openURL) private var openURL
    func makeNSView(context: Context) -> LinkCursorView { LinkCursorView() }
    func updateNSView(_ view: LinkCursorView, context: Context) {
        view.openLink = { openURL($0) }
        if view.regions != regions || view.enabled != enabled {
            view.regions = regions
            view.enabled = enabled
            view.updateTrackingAreas()
            view.window?.invalidateCursorRects(for: view)
        }
    }
}

/// AppKit owns both the cursor and clicks over the same glyph rectangles.
/// The surrounding native text still owns selection, copy and accessibility.
final class LinkCursorView: NSView {
    fileprivate var regions: [LinkRegion] = []
    var rects: [CGRect] { regions.map(\.rect) }
    func rect(forLink url: URL) -> CGRect? { regions.first(where: { $0.url == url })?.rect }
    var enabled = true
    var openLink: ((URL) -> Void)?
    private var forwardingSelection = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard enabled, !forwardingSelection, !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return visibleRect.contains(local) && regions.contains(where: { $0.url != nil && $0.rect.contains(local) }) ? self : nil
    }
    override func resetCursorRects() {
        guard enabled else { return }
        for rect in rects {
            let visible = rect.intersection(visibleRect)
            if !visible.isEmpty { addCursorRect(visible, cursor: .pointingHand) }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard enabled else { return }
        for rect in rects {
            let visible = rect.intersection(visibleRect)
            if !visible.isEmpty {
                addTrackingArea(NSTrackingArea(rect: visible, options: [.cursorUpdate, .activeInActiveApp], owner: self, userInfo: nil))
            }
        }
    }
    override func cursorUpdate(with event: NSEvent) {
        if enabled { NSCursor.pointingHand.set() }
    }
    override func mouseDown(with event: NSEvent) {
        guard enabled, let window,
              let url = regions.first(where: { $0.rect.contains(convert(event.locationInWindow, from: nil)) })?.url else { return }
        // A click opens exactly once. A drag starting on a link is handed to native text selection.
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseDragged {
                if hypot(next.locationInWindow.x - event.locationInWindow.x, next.locationInWindow.y - event.locationInWindow.y) < 4 { continue }
                forwardingSelection = true
                defer { forwardingSelection = false }
                let target = window.contentView?.hitTest(event.locationInWindow)
                if let target, target !== self {
                    NSApp.postEvent(next, atStart: true)
                    target.mouseDown(with: event)
                }
                return
            }
            let point = convert(next.locationInWindow, from: nil)
            if enabled, visibleRect.contains(point), regions.contains(where: { $0.url == url && $0.rect.contains(point) }) {
                openLink?(url)
            }
            return
        }
    }
}
