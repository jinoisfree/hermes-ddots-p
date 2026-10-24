import AppKit

/// Slack's block layout in the native card: bars, code boxes, hanging list indents and the title size.
@main struct SlackLayoutTests {
    static func laid(_ body: String, bar: NSColor? = nil, statuses: [NSColor?] = []) -> NSAttributedString {
        let layout = SlackLayout.strip(body)
        let text = NSMutableAttributedString(attributedString: MessageFormat.renderNative(layout.source))
        SlackLayout.apply(to: text, lines: layout.lines, bar: bar, statuses: statuses, lineSpacing: 2)
        return text
    }
    static func style(_ text: NSAttributedString, at word: String) -> NSParagraphStyle? {
        let range = (text.string as NSString).range(of: word)
        precondition(range.location != NSNotFound, "missing \(word) in \(text.string)")
        return text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }
    static func main() {
        let stripped = SlackLayout.strip("제목\n> 하나\n>\n> > 둘\n> ```\n> x\n> ```")
        precondition(stripped.source == "제목\n하나\n\n둘\n```\nx\n```" && stripped.lines.map(\.depth) == [0, 1, 1, 2, 1, 1, 1]
                     && stripped.lines.map(\.code) == [false, false, false, false, false, true, false] && stripped.lines.map(\.hidden) == [false, false, false, false, true, false, true],
                     "quote marks come off and each line keeps its depth and fence: \(stripped)")

        let blue = NSColor(srgbRed: 0.11, green: 0.61, blue: 0.82, alpha: 1)
        let post = laid("### 🔵 제목\n\n> 날짜 줄\n>\n> *확인 범위*\n>     • 긴 항목\n> • 첫 단계\n> 1. 번호\n> > 원문\n> ```\n> bash x\n> ```\n끝", bar: blue)
        precondition(!post.string.contains(">") && !post.string.contains("```"), "no quote or fence marks are shown: \(post.string)")
        let title = post.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        precondition((title?.pointSize ?? 0) > ChatMetrics.bodyFont + 2, "a Slack header is larger than the words under it")

        func decoration(_ word: String) -> SlackLayout.Decoration? {
            post.attribute(SlackLayout.decoration, at: (post.string as NSString).range(of: word).location, effectiveRange: nil) as? SlackLayout.Decoration
        }
        let date = decoration("날짜 줄")!
        precondition(date.quotes.count == 1 && date.quotes[0].color == blue && date.box == nil, "an attachment's lines sit behind a bar in its colour")
        precondition(decoration("확인 범위")?.quotes.first?.run == date.quotes[0].run && decoration("긴 항목")?.quotes.first?.run == date.quotes[0].run, "the whole attachment shares one bar")
        let nested = decoration("원문")!
        precondition(nested.quotes.count == 2 && nested.quotes[0].run == date.quotes[0].run && nested.quotes[1].color != blue, "a quote inside it has a grey bar of its own")
        precondition(decoration("bash x")?.box != nil && decoration("bash x")?.quotes.count == 1, "code is set in a box inside the bar")
        let code = post.attribute(.font, at: (post.string as NSString).range(of: "bash x").location, effectiveRange: nil) as? NSFont
        precondition(code.map { NSFontManager.shared.traits(of: $0).contains(.fixedPitchFontMask) } == true, "code keeps a fixed-width face")
        precondition(decoration("끝") == nil && decoration("제목") == nil, "words outside the attachment have no bar")

        // TextKit lays the lines out beside the bar and inside the box, and the bar runs down the whole attachment.
        let laidOut = NSTextStorage(attributedString: post), lines = NSLayoutManager()
        let area = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)); area.lineFragmentPadding = 0
        laidOut.addLayoutManager(lines); lines.addTextContainer(area); lines.ensureLayout(for: area)
        func glyph(_ word: String) -> Int { lines.glyphIndexForCharacter(at: (post.string as NSString).range(of: word).location) }
        func left(_ word: String) -> CGFloat { lines.location(forGlyphAt: glyph(word)).x + lines.lineFragmentRect(forGlyphAt: glyph(word), effectiveRange: nil).minX }
        func line(_ word: String) -> NSRect { lines.lineFragmentRect(forGlyphAt: glyph(word), effectiveRange: nil) }
        precondition(left("날짜 줄") == SlackLayout.quoteStep && left("원문") == 2 * SlackLayout.quoteStep && left("bash x") > left("날짜 줄") && left("끝") == 0,
                     "bars and boxes move their lines in: \(left("날짜 줄")) \(left("원문")) \(left("bash x")) \(left("끝"))")
        let frames = SlackLayout.frames(laidOut, manager: lines, container: area)
        precondition(frames.bars.count == 2 && frames.boxes.count == 1, "one bar for the attachment, one for the quote in it, one box: \(frames)")
        let outer = frames.bars[0].0
        precondition(outer.minX == 0 && outer.minY <= line("날짜 줄").minY && outer.maxY >= line("bash x").maxY && outer.maxY <= line("끝").minY
                     && frames.bars[1].0.minX == SlackLayout.quoteStep, "the bar runs from the first quoted line to the last: \(outer)")
        let box = frames.boxes[0]
        precondition(box.minX == SlackLayout.quoteStep && box.maxX == 300 && box.minY < line("bash x").minY + 12 && box.contains(NSPoint(x: left("bash x"), y: line("bash x").midY)),
                     "the box holds the code: \(box) \(line("bash x"))")

        // The outermost bars take the thread's colour; each attachment's status is a short bar beside its first line.
        let purple = NSColor(srgbRed: 0.64, green: 0.4, blue: 0.96, alpha: 1)
        let green = MessageFormat.color("#2EB67D")!, red = MessageFormat.color("#E01E5A")!
        let full = "> 직접 인용\n\n> 일반\n\n>\n> *체크*\n> 체크 둘\n\n> 긴급\n> > 원문"
        let sections = laid(full, bar: purple, statuses: SlackLayout.statuses(for: full, colors: ["", "#2EB67D", "#E01E5A"]))
        func bars(_ word: String) -> [NSColor] {
            (sections.attribute(SlackLayout.decoration, at: (sections.string as NSString).range(of: word).location, effectiveRange: nil) as? SlackLayout.Decoration)?.quotes.map(\.color) ?? []
        }
        precondition(bars("직접 인용") == [purple] && bars("일반") == [purple] && bars("체크") == [purple, green] && bars("체크 둘") == [purple]
                     && bars("긴급") == [purple, red] && bars("원문").first == purple && bars("원문").count == 2 && bars("원문")[1] != red,
                     "statuses count from the last stretch and mark only its first line of words; inner quotes stay grey")
        let sectionStyle = sections.attribute(.paragraphStyle, at: (sections.string as NSString).range(of: "체크").location, effectiveRange: nil) as? NSParagraphStyle
        precondition(sectionStyle?.firstLineHeadIndent == 2 * SlackLayout.quoteStep, "the marked line sits beside its short bar")
        // A folded post shows the start of its body; its colours stay on their own stretches.
        let folded = laid("> 직접 인용\n\n> 일반\n\n> *체크*", bar: purple, statuses: SlackLayout.statuses(for: full, colors: ["", "#2EB67D", "#E01E5A"]))
        let foldedCheck = (folded.attribute(SlackLayout.decoration, at: (folded.string as NSString).range(of: "체크").location, effectiveRange: nil) as? SlackLayout.Decoration)?.quotes.map(\.color)
        precondition(foldedCheck == [purple, green], "colours count from the end of the whole body: \(String(describing: foldedCheck))")

        // A table: one TextKit cell per cell, the header in bold, the alignment row gone, inside the bar.
        let grid = laid("> 표 앞\n> | 작업 | 상태 | 비고 |\n> | --- | :---: | ---: |\n> | 메일 요약 | *완료* | 18시 정기 발송으로 길게 늘어진 설명 |\n> | 학습 |  |\n끝", bar: blue)
        precondition(!grid.string.contains("|") && !grid.string.contains("---"), "no pipes or alignment row are shown: \(grid.string.debugDescription)")
        func cell(_ word: String) -> NSTextTableBlock? {
            ((grid.attribute(.paragraphStyle, at: (grid.string as NSString).range(of: word).location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.first) as? NSTextTableBlock
        }
        precondition(cell("작업")?.startingRow == 0 && cell("비고")?.startingColumn == 2 && cell("메일 요약")?.startingRow == 1 && cell("학습")?.startingRow == 2
                     && cell("작업")?.table === cell("학습")?.table && cell("작업")?.table.numberOfColumns == 3, "cells sit at their row and column of one table")
        let headFont = grid.attribute(.font, at: (grid.string as NSString).range(of: "작업").location, effectiveRange: nil) as? NSFont
        precondition(headFont.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "the header row is bold")
        let rightStyle = grid.attribute(.paragraphStyle, at: (grid.string as NSString).range(of: "18시").location, effectiveRange: nil) as? NSParagraphStyle
        let centre = grid.attribute(.paragraphStyle, at: (grid.string as NSString).range(of: "완료").location, effectiveRange: nil) as? NSParagraphStyle
        precondition(rightStyle?.alignment == .right && centre?.alignment == .center, "column alignment is kept")
        precondition((grid.attribute(SlackLayout.decoration, at: (grid.string as NSString).range(of: "학습").location, effectiveRange: nil) as? SlackLayout.Decoration)?.quotes.first?.color == blue,
                     "the table stays behind the bar")
        let gridStorage = NSTextStorage(attributedString: grid), gridManager = NSLayoutManager()
        let gridArea = NSTextContainer(containerSize: NSSize(width: 260, height: CGFloat.greatestFiniteMagnitude)); gridArea.lineFragmentPadding = 0
        gridStorage.addLayoutManager(gridManager); gridManager.addTextContainer(gridArea); gridManager.ensureLayout(for: gridArea)
        let first = gridManager.lineFragmentRect(forGlyphAt: gridManager.glyphIndexForCharacter(at: (grid.string as NSString).range(of: "작업").location), effectiveRange: nil)
        let third = gridManager.lineFragmentRect(forGlyphAt: gridManager.glyphIndexForCharacter(at: (grid.string as NSString).range(of: "비고").location), effectiveRange: nil)
        precondition(first.minX >= SlackLayout.quoteStep && third.minX > first.maxX && abs(third.minY - first.minY) < 1 && gridManager.usedRect(for: gridArea).width <= 260,
                     "cells of a row sit side by side within the width: \(first) \(third)")

        // A box that ends the post is whole inside the text's height.
        let closing = laid("> 끝은 코드\n> ```\n> instagram_dm: waiting\n> ```", bar: blue)
        let closingStorage = NSTextStorage(attributedString: closing), closingManager = NSLayoutManager()
        let closingArea = NSTextContainer(containerSize: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude)); closingArea.lineFragmentPadding = 0
        closingStorage.addLayoutManager(closingManager); closingManager.addTextContainer(closingArea); closingManager.ensureLayout(for: closingArea)
        let closingBox = SlackLayout.frames(closingStorage, manager: closingManager, container: closingArea).boxes
        precondition(closingBox.count == 1 && closingBox[0].maxY <= closingManager.usedRect(for: closingArea).maxY, "a closing box fits: \(closingBox) \(closingManager.usedRect(for: closingArea))")

        // Wrapped lines of a list item continue under the item's words, not under the bullet.
        for (word, level) in [("긴 항목", 1), ("첫 단계", 0), ("번호", 0)] {
            let paragraph = style(post, at: word)!
            precondition(paragraph.firstLineHeadIndent == SlackLayout.quoteStep + 4 + CGFloat(level) * SlackLayout.indentStep
                         && paragraph.headIndent > paragraph.firstLineHeadIndent && paragraph.tabStops.first?.location == paragraph.headIndent,
                         "\(word): hanging indent at level \(level)")
        }
        let detail = laid("• 메일 제목\n    ↳ 보낸 사람: 아주 긴 미리보기 문장이 이어집니다")
        let detailStyle = style(detail, at: "보낸 사람")!
        precondition(detail.string.contains("↳\t보낸 사람") && detailStyle.firstLineHeadIndent == 4 + SlackLayout.indentStep && detailStyle.headIndent > detailStyle.firstLineHeadIndent,
                     "a ↳ detail line keeps its arrow and wraps under its words")
        let listed = laid("• 정산 서류\n    • ↳ 공문 3항 근거")
        precondition(listed.string.contains("↳\t공문") && !listed.string.contains("•\t↳"), "a list item opening with ↳ shows only the arrow: \(listed.string.debugDescription)")
        precondition(post.string.contains("◦\t긴 항목") && post.string.contains("•\t첫 단계") && post.string.contains("1.\t번호"), "Slack's bullet for each level: \(post.string)")

        let width: CGFloat = 220
        let long = laid("> • 최근 2일 받은편지함의 헤더·미리보기 기반 후보이며, 실제 회신 의무·공식 마감은 원문 확인이 필요하다.")
        let storage = NSTextStorage(attributedString: long), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude)); container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container); manager.ensureLayout(for: container)
        func x(_ glyph: Int) -> CGFloat { manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x }
        var starts: [CGFloat] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, _, _, glyphs, _ in starts.append(x(glyphs.location)) }
        let wordsX = x(manager.glyphIndexForCharacter(at: (long.string as NSString).range(of: "최근").location))
        precondition(starts.count > 1 && wordsX > starts[0] && starts.dropFirst().allSatisfy { abs($0 - wordsX) < 0.5 },
                     "at a narrow width every wrapped line starts where the item's words start: \(starts) vs \(wordsX)")
        let zones = SlackZones(rooms: ["ddots", "ZONE1", "C1", "C2", "C3", "ZONE3", "stack", "D1"],
                               zoneOf: ["ddots": 0, "ZONE1": 1, "C1": 1, "C2": 1, "C3": 2, "ZONE3": 3, "stack": 4, "D1": 4])
        precondition((0..<8).map(zones.zone) == [0, 1, 1, 1, 2, 3, 4, 4] && (0..<8).map(zones.breaks) == [false, true, false, false, true, true, true, false]
                     && zones.above(0) == 0 && zones.above(3) == SlackZones.dividerHeight && zones.above(7) == SlackZones.dividerHeight * 4,
                     "ddots stands alone above the sections, and a line parts each section from the next")
        let plain = SlackZones(rooms: ["C1", "C2"], zoneOf: [:])
        precondition(plain.zones == [1, 1] && !plain.breaks(1) && plain.above(1) == 0, "rooms given no section are one run without lines")
        print("SlackLayoutTests passed")
    }
}
