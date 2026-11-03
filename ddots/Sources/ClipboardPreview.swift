import AppKit
import QuickLookUI

/// Text stays inside the shelf. Quick Look receives only explicitly selected file URLs.
final class ClipboardPreview: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private weak var shelf: PetPanel?
    private weak var previousResponder: NSResponder?
    private var overlay: NSScrollView?
    private var urls: [URL] = []
    private var owned: Set<URL> = []
    private var generation = UUID()
    private var quickLook: QLPreviewPanel?
    private var closing = false
    private var keyMonitor: Any?
    var isOpen: Bool { overlay != nil || quickLook != nil }
    var text: String? { (overlay?.documentView as? NSTextView)?.string }
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === quickLook }
    var exportedURLs: [URL] { Array(owned) }
    func show(_ entry: ClipboardEntry, library: ClipboardLibrary, in panel: PetPanel) {
        close(); generation = UUID()
        let request = generation
        shelf = panel
        let masked = entry.secret && library.revealedID != entry.id
        if entry.kind == .text || masked {
            guard let pet = panel.contentView as? PetView else { return }
            let scroll = NSScrollView(frame: pet.clipboardPreviewRect.insetBy(dx: 14, dy: 14))
            scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
            let view = NSTextView(frame: scroll.bounds)
            view.isEditable = false; view.isSelectable = true; view.isRichText = false
            view.font = NSFont.systemFont(ofSize: 13); view.textContainerInset = CGSize(width: 12, height: 12)
            view.string = masked ? "••••••" : (entry.text ?? "")
            view.isVerticallyResizable = true; view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
            scroll.documentView = view; pet.addSubview(scroll); overlay = scroll
            panel.makeKey(); panel.makeFirstResponder(view)
            return
        }
        library.previewURLs(entry) { [weak self] urls, owned in
            guard let self else { for url in owned { try? FileManager.default.removeItem(at: url) }; return }
            guard self.generation == request, (panel.contentView as? PetView)?.clipboardPresented == true else {
                for url in owned { try? FileManager.default.removeItem(at: url) }; return
            }
            guard !urls.isEmpty else { return }
            self.urls = urls; self.owned = Set(owned)
            self.previousResponder = panel.nextResponder; self.nextResponder = panel.nextResponder; panel.nextResponder = self
            let preview = QLPreviewPanel.shared()!
            self.quickLook = preview; preview.updateController(); preview.dataSource = self; preview.delegate = self
            preview.reloadData(); preview.makeKeyAndOrderFront(nil)
            // Quick Look consumes Escape itself before its delegate's unhandled-event callback.
            // Its preview owner therefore owns these two close keys at the window event boundary.
            self.keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak preview] event in
                guard let self, event.window === preview, [49, 53].contains(event.keyCode) else { return event }
                self.close(); return nil
            }
        }
    }
    func close() {
        guard !closing else { return }; closing = true
        defer { closing = false }
        generation = UUID()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        overlay?.removeFromSuperview(); overlay = nil
        if let panel = quickLook { panel.orderOut(nil); panel.dataSource = nil; panel.delegate = nil }; quickLook = nil
        if let shelf, shelf.nextResponder === self { shelf.nextResponder = previousResponder }
        nextResponder = nil; previousResponder = nil
        urls.removeAll()
        for url in owned { try? FileManager.default.removeItem(at: url) }; owned.removeAll()
        (shelf?.contentView as? PetView)?.clipboardPreviewEnded()
        if let shelf, (shelf.contentView as? PetView)?.clipboardPresented == true { shelf.makeKey(); shelf.makeFirstResponder(shelf.contentView) }
    }
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLook != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self; panel.delegate = self }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { close() }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { urls[index] as NSURL }
    func windowWillClose(_ notification: Notification) { close() }
}
