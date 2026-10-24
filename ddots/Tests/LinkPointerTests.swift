import AppKit
import SwiftUI

@main
struct LinkPointerTests {
    static func check(_ value: Bool, _ message: String) {
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func main() {
        guard #available(macOS 15, *) else { print("SKIP: link geometry requires macOS 15"); return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var opened: [URL] = []
        let text = try! AttributedString(markdown: "Plain text before [a long linked label that wraps over several lines](https://example.com/first) and [second link](https://example.com/second).")
        let view = LinkText(text).font(.system(size: 16)).textSelection(.enabled)
            .frame(width: 190, alignment: .leading)
            .environment(\.openURL, OpenURLAction { opened.append($0); return .handled })
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 230, height: 180), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        window.contentView = host
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        func regions(_ view: NSView) -> [LinkCursorView] {
            (view as? LinkCursorView).map { [$0] } ?? view.subviews.flatMap(regions)
        }
        guard let region = regions(host).first, region.rects.count >= 3 else {
            check(false, "Real SwiftUI layout exposes wrapped links"); return
        }
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        for rect in region.rects {
            let point = region.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            check(host.hitTest(point) === region, "Visible link glyphs own the hit target")
            let count = opened.count
            app.postEvent(event(.leftMouseUp, point), atStart: true)
            region.mouseDown(with: event(.leftMouseDown, point))
            check(opened.count == count + 1, "Each wrapped link segment opens exactly once")
        }
        check(Set(opened.map(\.absoluteString)) == ["https://example.com/first", "https://example.com/second"], "Adjacent links keep their distinct URLs")
        let rect = region.rects[0]
        let point = region.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let count = opened.count
        app.postEvent(event(.leftMouseUp, .zero), atStart: true)
        region.mouseDown(with: event(.leftMouseDown, point))
        check(opened.count == count, "Releasing outside the link does not navigate")
        region.enabled = false
        check(host.hitTest(point) !== region, "Inactive conversations cannot intercept links")
        region.enabled = true
        region.isHidden = true
        check(host.hitTest(point) !== region, "Hidden links cannot intercept clicks")
        region.isHidden = false
        let plain = region.convert(NSPoint(x: 5, y: 5), to: nil)
        check(host.hitTest(plain) !== region, "Plain text remains available to native selection")
        window.close()
        print("PASS: wrapped link hit targets, exact-once navigation, distinct URLs, cancelled clicks, inactive/hidden links, plain text passthrough")
    }
}
