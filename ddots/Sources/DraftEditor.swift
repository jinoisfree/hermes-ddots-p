import AppKit
import SwiftUI

private typealias DraftHeightState = SwiftUI.State<CGFloat>
private typealias DraftFormatState = SwiftUI.StateObject<DraftFormatController>

/// A bounded composer with a real scroll view. SwiftUI's vertical TextField clips its field editor on macOS
/// without providing a scroll view, so the first lines of a long draft cannot be reached with the wheel.
struct DraftEditor: View {
    let prompt: String
    @Binding var text: String
    var focus: Binding<Bool>
    var onPaste: (() -> Bool)?
    var onSubmit: () -> Void
    @DraftHeightState private var height: CGFloat = 16
    @DraftFormatState private var formatting = DraftFormatController()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(prompt).font(.system(size: ChatMetrics.bodyFont)).foregroundColor(.secondary).allowsHitTesting(false)
                }
                NativeDraft(text: $text, focused: focus, height: $height, formatting: formatting,
                            prompt: prompt, onPaste: onPaste, onSubmit: onSubmit)
            }.frame(height: height)
        }
    }
}

private struct NativeDraft: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    @Binding var height: CGFloat
    let formatting: DraftFormatController
    let prompt: String
    var onPaste: (() -> Bool)?
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> DraftScrollView {
        let scroll = DraftScrollView()
        scroll.editor.delegate = context.coordinator
        formatting.editor = scroll.editor
        scroll.editor.formattingController = formatting
        scroll.onHeight = { [weak coordinator = context.coordinator] height in
            DispatchQueue.main.async {
                guard let coordinator, abs(coordinator.parent.height - height) > 0.5 else { return }
                coordinator.parent.height = height
            }
        }
        context.coordinator.scroll = scroll
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ scroll: DraftScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        let editor = scroll.editor
        editor.onPaste = onPaste
        editor.onFocus = { [weak coordinator] focused in coordinator?.parent.focused = focused }
        editor.setAccessibilityLabel(prompt)
        // Publishing a marked Korean syllable must not replace the text storage or end composition.
        if coordinator.published != text, !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            let wasAtEnd = NSMaxRange(selection) == (editor.string as NSString).length
            // Sending or changing rooms replaces the draft; old undo ranges no longer refer to this document.
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
            coordinator.published = text
            editor.textStorage?.setAttributedString(MessageFormat.editor(text))
            if text.isEmpty { editor.typingAttributes = MessageFormat.Style().attributes }
            let length = (editor.string as NSString).length
            let start = wasAtEnd ? length : min(selection.location, length)
            editor.setSelectedRange(NSRange(location: start, length: wasAtEnd ? 0 : min(selection.length, length - start)))
            scroll.measure()
        }
        DispatchQueue.main.async { [weak coordinator, weak scroll] in
            guard let coordinator, let scroll, let window = scroll.window else { return }
            if coordinator.parent.focused, !scroll.isHiddenOrHasHiddenAncestor, window.firstResponder !== scroll.editor {
                window.makeFirstResponder(scroll.editor)
                scroll.editor.setSelectedRange(NSRange(location: (scroll.editor.string as NSString).length, length: 0))
                scroll.editor.scrollRangeToVisible(scroll.editor.selectedRange())
            } else if !coordinator.parent.focused, window.firstResponder === scroll.editor {
                window.makeFirstResponder(nil)
            }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeDraft
        var published: String?
        weak var scroll: DraftScrollView?
        init(_ parent: NativeDraft) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let scroll else { return }
            let text = MessageFormat.serialize(scroll.editor.attributedString())
            published = text
            parent.text = text
            scroll.measure()
            scroll.editor.scrollRangeToVisible(scroll.editor.selectedRange())
            parent.formatting.refresh()
        }
        func textViewDidChangeSelection(_ notification: Notification) { parent.formatting.refresh() }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSTextView.insertNewline(_:)), !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            guard modifiers.intersection([.shift, .option]).isEmpty else { return false }
            parent.onSubmit()
            return true
        }
    }
}

final class DraftTextView: NSTextView {
    weak var formattingController: DraftFormatController?
    private let draftUndo = UndoManager()
    override var undoManager: UndoManager? { draftUndo }
    @objc func undo(_ sender: Any?) { if draftUndo.canUndo { draftUndo.undo() } }
    @objc func redo(_ sender: Any?) { if draftUndo.canRedo { draftUndo.redo() } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
            if event.keyCode == 11 { formattingController?.bold(); return true }
            if event.keyCode == 32 { formattingController?.underline(); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
    var onPaste: (() -> Bool)?
    var onFocus: ((Bool) -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocus?(false) }
        return accepted
    }
    override func paste(_ sender: Any?) {
        if onPaste?() == true { return }
        pastePlain(from: .general)
    }
    override func pasteAsRichText(_ sender: Any?) { paste(sender) }
    override func pasteAsPlainText(_ sender: Any?) { paste(sender) }
    /// Text copied elsewhere keeps its words, spaces and lines but takes the composer's usual size and colour,
    /// not the source's or the formatting around the caret. The formatting bar can still style it afterwards.
    func pastePlain(from board: NSPasteboard) {
        guard let text = Self.plainText(from: board), !text.isEmpty else { return }
        if hasMarkedText() { unmarkText() }
        breakUndoCoalescing()
        let range = selectedRange()
        let plain = MessageFormat.Style().attributes
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: plain))
        didChangeText()
        breakUndoCoalescing()
        undoManager?.setActionName("붙여넣기")
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        typingAttributes = plain
        scrollRangeToVisible(selectedRange())
    }
    /// Plain text first; rich text or a web page only for its characters. HTML is read without WebKit so nothing is fetched.
    static func plainText(from board: NSPasteboard) -> String? {
        var text: String?
        if let string = board.string(forType: .string) { text = string }
        else if let data = board.data(forType: .rtfd), let rich = NSAttributedString(rtfd: data, documentAttributes: nil) { text = rich.string }
        else if let data = board.data(forType: .rtf), let rich = NSAttributedString(rtf: data, documentAttributes: nil) { text = rich.string }
        else if let data = board.data(forType: .html), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) { text = HTMLText.text(html) }
        return text?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
    }
}

final class DraftScrollView: NSScrollView {
    let editor = DraftTextView(frame: .zero)
    var onHeight: ((CGFloat) -> Void)?
    private var measuring = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false; borderType = .noBorder
        hasVerticalScroller = true; hasHorizontalScroller = false
        autohidesScrollers = true; scrollerStyle = .overlay
        editor.isRichText = true; editor.importsGraphics = false
        editor.drawsBackground = false; editor.textColor = .labelColor
        editor.font = .systemFont(ofSize: ChatMetrics.bodyFont)
        editor.isEditable = true; editor.isSelectable = true; editor.allowsUndo = true
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.minSize = .zero; editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.setAccessibilityIdentifier("draft-editor")
        documentView = editor
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() { super.layout(); measure() }
    func measure() {
        guard !measuring, contentSize.width > 0, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        measuring = true
        defer { measuring = false }
        let width = max(1, contentSize.width)
        if abs(editor.frame.width - width) > 0.5 { editor.setFrameSize(NSSize(width: width, height: editor.frame.height)) }
        let size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if container.containerSize != size { container.containerSize = size }
        layout.ensureLayout(for: container)
        let line = ceil(layout.defaultLineHeight(for: .systemFont(ofSize: ChatMetrics.bodyFont)))
        let used = max(line, ceil(max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)))
        let height = max(used, contentSize.height)
        if abs(editor.frame.height - height) > 0.5 { editor.setFrameSize(NSSize(width: width, height: height)) }
        onHeight?(min(used, line * 5))
    }
}
