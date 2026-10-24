import AppKit
import SwiftUI

struct WebTabTargets: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) { value += nextValue() }
}

struct WebTabBlankRegion: NSViewRepresentable {
    let web: WebPaneModel
    let occupied: [CGRect]
    func makeNSView(context: Context) -> WebTabBlankView { WebTabBlankView() }
    func updateNSView(_ view: WebTabBlankView, context: Context) { view.web = web; view.occupied = occupied }
}

/// Observe only the unused area; single clicks still reach the original scroll view.
/// Dragging from it moves the whole window, as dragging the conversation's header does.
final class WebTabBlankView: NSView {
    weak var web: WebPaneModel?
    var occupied: [CGRect] = []
    private var monitor: Any?
    private var pressed: CGPoint?
    private var pressedOnScreen: CGPoint?
    private var dragged = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if dragged { web?.onWindowDragEnded?() }
        pressed = nil; pressedOnScreen = nil; dragged = false
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event) == true ? nil : event
        }
    }
    func blank(_ point: CGPoint) -> Bool {
        guard bounds.contains(point), !occupied.contains(where: { $0.contains(point) }) else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let pet = view as? PetView, let placement = pet.placement {
                let local = pet.convert(point, from: self)
                return !pet.spriteContains(local) && PetLayout.resizeEdge(at: local, bubble: placement.bubbleRect, below: placement.bubbleBelow).isEmpty
            }
            ancestor = view.superview
        }
        return true
    }
    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, !isHiddenOrHasHiddenAncestor, web?.open == true else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let screen = window?.convertPoint(toScreen: event.locationInWindow)
        switch event.type {
        case .leftMouseDown:
            pressed = blank(point) ? point : nil; pressedOnScreen = pressed == nil ? nil : screen; dragged = false
        case .leftMouseDragged:
            guard let pressed, let start = pressedOnScreen, let screen else { return false }
            if !dragged, hypot(point.x-pressed.x, point.y-pressed.y) > 4 { dragged = true; web?.onWindowDragBegan?(start) }
            if dragged { web?.onWindowDragChanged?(screen); return true }
        case .leftMouseUp:
            defer { pressed = nil; pressedOnScreen = nil; dragged = false }
            if dragged { web?.onWindowDragEnded?(); return true }
            if pressed != nil, blank(point), event.clickCount == 2 { web?.close(); return true }
        default: break
        }
        return false
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
