import AppKit
import SwiftUI

@main struct MessageFormatTests {
    static func main() {
        _ = NSApplication.shared
        for body in ["한글과 emoji 👩‍💻", "**굵게** _기울임_ [문서](https://example.invalid)", "# 제목\n- [ ] 확인\n- [x] 완료", "<span style=\"font-size:20px;color:#4285E8\">글</span>"] {
            precondition(MessageFormat.renderNative(body).string == String(MessageFormat.render(body).characters), "AppKit and SwiftUI display the same text")
        }
        let source = "위키담당, <span style=\"font-size:20px;color:#4285E8\"><b><u>한글 &amp; emoji 👩‍💻</u></b></span>\n☐ 확인"
        let native = MessageFormat.editor(source)
        precondition(native.string == "위키담당, 한글 & emoji 👩‍💻\n☐ 확인")
        let range = (native.string as NSString).range(of: "한글")
        let attrs = native.attributes(at: range.location, effectiveRange: nil)
        precondition((attrs[.font] as? NSFont)?.pointSize == 20)
        precondition(NSFontManager.shared.traits(of: attrs[.font] as! NSFont).contains(.boldFontMask))
        precondition((attrs[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
        precondition(MessageFormat.hex(attrs[.foregroundColor] as! NSColor) == "#4285E8")
        let restored = MessageFormat.editor(MessageFormat.serialize(native))
        precondition(restored.isEqual(to: native), "Rich text survives the text transport round trip")
        let raw = "SNS담당, a < b & c > d\n**굵게**\n    - [ ] 확인"
        precondition(MessageFormat.serialize(MessageFormat.editor(raw)) == raw, "Plain drafts keep their original bytes")
        let reply = MessageFormat.render("# 계획\n**굵게**와 <u>밑줄</u>\n    - [ ] 미완료\n- [x] 완료\n[문서](https://example.com)\n09:00~18:00")
        precondition(String(reply.characters) == "계획\n굵게와 밑줄\n    ☐ 미완료\n☑ 완료\n문서\n09:00~18:00")
        precondition(reply.runs.contains { $0.link == URL(string: "https://example.com") })
        precondition(reply.runs.contains { $0.underlineStyle != nil })
        let protected = MessageFormat.render("`<u>코드</u>`\n```html\n<span style=\"color:#4285E8\">코드</span>\n```")
        precondition(String(protected.characters).contains("<u>코드</u>") && String(protected.characters).contains("<span"), "Code never becomes formatting")
        let tooLarge = MessageFormat.editor("<span style=\"font-size:99999px;color:bad\">안전</span>")
        precondition((tooLarge.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 32)
        let unfinished = MessageFormat.editor("<u>아직 닫지 않음")
        precondition(unfinished.string == "<u>아직 닫지 않음")
        precondition(MessageFormat.editor("<u>닫힘</u> <u>열린 태그").string == "닫힘 <u>열린 태그")
        print("PASS: rich text transport, Korean/emoji, plain compatibility, agent Markdown, checkboxes, links, code and size bounds")
    }
}
