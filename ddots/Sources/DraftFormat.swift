import AppKit
import SwiftUI

final class DraftFormatController: ObservableObject {
    weak var editor: DraftTextView?
    struct Selection: Equatable { var size = 13; var bold = false; var underline = false }
    @Published private(set) var selection = Selection()
    func refresh() {
        guard let editor else { return }
        let range = editor.selectedRange()
        let attrs = range.length > 0 && range.location < editor.textStorage!.length ? editor.textStorage!.attributes(at: range.location, effectiveRange: nil) : editor.typingAttributes
        let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: MessageFormat.baseSize)
        let next = Selection(size: Int(font.pointSize), bold: NSFontManager.shared.traits(of: font).contains(.boldFontMask), underline: (attrs[.underlineStyle] as? Int ?? 0) != 0)
        DispatchQueue.main.async { [weak self] in if self?.selection != next { self?.selection = next } }
    }
    private func change(_ name: String, _ transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        guard let editor else { return }
        if editor.hasMarkedText() { editor.unmarkText() }
        editor.breakUndoCoalescing()
        let range = editor.selectedRange()
        if range.length == 0 { editor.typingAttributes = transform(editor.typingAttributes) }
        else if let storage = editor.textStorage {
            let before = NSAttributedString(attributedString: storage)
            storage.beginEditing()
            before.enumerateAttributes(in: range) { attrs, part, _ in storage.setAttributes(transform(attrs), range: part) }
            storage.endEditing()
            editor.registerFormatUndo(before, selection: range, name: name)
            editor.didChangeText()
        }
        editor.window?.makeFirstResponder(editor); refresh()
    }
    func size(_ size: CGFloat) {
        change("글자 크기") { attrs in
            var next = attrs
            next[.font] = NSFontManager.shared.convert(attrs[.font] as? NSFont ?? .systemFont(ofSize: 13), toSize: size)
            next.removeValue(forKey: NSAttributedString.Key("NSOriginalFont"))
            return next
        }
    }
    func color(_ hex: String?) {
        change("글자 색") { attrs in
            var next = attrs; MessageFormat.clearColor(in: &next)
            next.merge(MessageFormat.colorAttributes(hex.flatMap(MessageFormat.color))) { _, new in new }
            return next
        }
    }
    func bold() {
        let active = !selection.bold
        change("굵게") { attrs in
            var next = attrs; let font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 13)
            next[.font] = active ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
            next.removeValue(forKey: NSAttributedString.Key("NSOriginalFont"))
            return next
        }
    }
    func underline() {
        let active = !selection.underline
        change("밑줄") { attrs in var next = attrs; next[.underlineStyle] = active ? NSUnderlineStyle.single.rawValue : 0; return next }
    }
    func heading(_ level: Int) {
        guard let editor else { return }
        if !editor.string.isEmpty { editor.setSelectedRange((editor.string as NSString).paragraphRange(for: editor.selectedRange())) }
        change(level == 0 ? "본문" : "제목") { attrs in
            var next = attrs
            next[.font] = NSFont.systemFont(ofSize: level == 0 ? 13 : [24.0, 20.0, 16.0][level - 1], weight: level == 0 ? .regular : .bold)
            next.removeValue(forKey: NSAttributedString.Key("NSOriginalFont"))
            return next
        }
    }
    func clear() { change("서식 지우기") { _ in MessageFormat.Style().attributes } }
    enum Lines { case indent, outdent, bullet, numbered, checkbox }
    func lines(_ action: Lines) {
        guard let editor else { return }
        if editor.hasMarkedText() { editor.unmarkText() }
        let string = editor.string as NSString
        let range = string.paragraphRange(for: editor.selectedRange())
        let selected = string.substring(with: range), finalNewline = selected.hasSuffix("\n")
        var lines = selected.components(separatedBy: "\n")
        if finalNewline { lines.removeLast() }
        let result = NSMutableAttributedString(attributedString: editor.attributedString().attributedSubstring(from: range))
        var start = 0
        let positioned = lines.enumerated().map { index, line -> (Int, Int, String) in
            defer { start += (line as NSString).length + 1 }
            return (index, start, line)
        }
        for (index, start, line) in positioned.reversed() {
            var offset = start, remove = 0, prefix = ""
            switch action {
            case .indent: prefix = "    "
            case .outdent: remove = line.hasPrefix("\t") ? 1 : min(4, line.prefix(while: { $0 == " " }).count)
            case .bullet:
                if line.hasPrefix("• ") { remove = 2 } else { prefix = "• " }
            case .numbered: prefix = "\(index + 1). "
            case .checkbox:
                let indent = String(line.prefix { $0 == " " || $0 == "\t" }), rest = String(line.dropFirst(indent.count))
                offset += (indent as NSString).length
                if rest.hasPrefix("☐ ") { remove = 2; prefix = "☑ " }
                else if rest.hasPrefix("☑ ") { remove = 2 }
                else { prefix = "☐ " }
            }
            let attributes = offset < result.length ? result.attributes(at: offset, effectiveRange: nil) : editor.typingAttributes
            result.replaceCharacters(in: NSRange(location: offset, length: remove), with: NSAttributedString(string: prefix, attributes: attributes))
        }
        let before = NSAttributedString(attributedString: editor.attributedString()), selection = editor.selectedRange()
        editor.breakUndoCoalescing()
        editor.textStorage?.replaceCharacters(in: range, with: result)
        editor.registerFormatUndo(before, selection: selection, name: "문단 서식")
        editor.setSelectedRange(NSRange(location: range.location, length: result.length))
        editor.didChangeText()
        editor.window?.makeFirstResponder(editor); refresh()
    }
}

extension DraftTextView {
    func registerFormatUndo(_ before: NSAttributedString, selection: NSRange, name: String) {
        undoManager?.registerUndo(withTarget: self) { editor in
            let current = NSAttributedString(attributedString: editor.attributedString())
            editor.registerFormatUndo(current, selection: editor.selectedRange(), name: name)
            editor.textStorage?.setAttributedString(before)
            editor.setSelectedRange(NSRange(location: min(selection.location, before.length), length: min(selection.length, max(0, before.length - selection.location))))
            editor.didChangeText()
        }
        undoManager?.setActionName(name)
    }
}
