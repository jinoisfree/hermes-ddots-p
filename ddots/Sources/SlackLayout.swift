import AppKit

/// Slack's block layout for a character's post, drawn by TextKit 1: quoted lines behind a bar (in the colour
/// of the attachment they came from), code in a box, and list items whose wrapped lines stay under the item's
/// words rather than going back under the bullet (or the ↳ of a detail line), at any width of the window. Tables are TextKit tables,
/// whose cells wrap their own words.
enum SlackLayout {
    struct Line: Equatable {
        /// How many `>` marks the line had.
        var depth = 0
        /// A line inside a ``` fence.
        var code = false
        /// A fence, or a table's row of column alignments: it shapes the lines around it and is not shown.
        var hidden = false
        /// The table the line is a row of, numbered from 1 within the post.
        var table = 0
        var header = false
        var aligns: [NSTextAlignment] = []
    }

    static let indentStep: CGFloat = 20
    static let barWidth: CGFloat = 3
    private static let marker = try! NSRegularExpression(pattern: #"^([ \t]*)((?:[•◦▪][ \t]+)?↳|[•◦▪]|\d{1,3}[.)])[ \t]+(?=\S)"#)
    private static let alignments = try! NSRegularExpression(pattern: #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)

    /// The body without its quote marks, for the Markdown parser, and what each of its lines was.
    static func strip(_ body: String) -> (source: String, lines: [Line]) {
        var lines: [Line] = [], kept: [String] = [], fenced = false
        for raw in body.components(separatedBy: "\n") {
            var text = Substring(raw), line = Line()
            while text.drop(while: { $0 == " " }).first == ">" {
                text = text.drop(while: { $0 == " " }).dropFirst()
                if text.first == " " { text = text.dropFirst() }
                line.depth += 1
            }
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("```") { line.hidden = true; fenced.toggle() }
            else { line.code = fenced }
            lines.append(line); kept.append(String(text))
        }
        // A pipe row over a row of alignments starts a table; pipe rows at the same depth continue it.
        var tables = 0, index = 0
        func row(_ at: Int) -> Bool { !lines[at].code && !lines[at].hidden && kept[at].trimmingCharacters(in: .whitespaces).hasPrefix("|") }
        while index < lines.count {
            let next = index + 1
            guard row(index), next < lines.count, !lines[next].code, lines[next].depth == lines[index].depth,
                  kept[next].contains("-"), alignments.firstMatch(in: kept[next], range: NSRange(kept[next].startIndex..., in: kept[next])) != nil else { index += 1; continue }
            tables += 1
            let aligns = cells(kept[next]).map { cell -> NSTextAlignment in
                let mark = cell.trimmingCharacters(in: .whitespaces)
                return mark.hasPrefix(":") && mark.hasSuffix(":") ? .center : mark.hasSuffix(":") ? .right : .left
            }
            lines[index].table = tables; lines[index].header = true; lines[index].aligns = aligns
            lines[next].hidden = true
            index = next + 1
            while index < lines.count, row(index), lines[index].depth == lines[next].depth {
                lines[index].table = tables; lines[index].aligns = aligns; index += 1
            }
        }
        return (kept.joined(separator: "\n"), lines)
    }

    /// The cells of a pipe row, without the bars at its ends.
    private static func cells(_ row: String) -> [String] {
        var inner = row.trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner.components(separatedBy: "|")
    }

    /// What a paragraph sits in: the bars beside it, outermost first, and the code box, each by the run it belongs to.
    final class Decoration: NSObject {
        let quotes: [(run: Int, color: NSColor)]
        let box: Int?
        init(quotes: [(run: Int, color: NSColor)], box: Int?) { self.quotes = quotes; self.box = box }
    }
    static let decoration = NSAttributedString.Key("ddots.slackLayout")
    /// Room each bar takes from the left: the bar and the gap after it.
    static let quoteStep = barWidth + 10
    private static let boxPadding: CGFloat = 9, boxGap: CGFloat = 6

    /// Lays out `text`, which MessageFormat made from `strip(body).source` line for line. Bars and boxes take
    /// their room as paragraph indents and are drawn by `draw(in:)`; TextKit 1's own text blocks are not used,
    /// since they keep only the first paragraph of a run inside the block.
    /// `bar` colours every outermost bar: the colour of the thread's edge, so a post's bars read as its agent's.
    /// `statuses` belong to the stretches of first-level quoted lines in order, from the first (see `statuses(for:colors:)`).
    /// A stretch with a status gets a short bar of that colour beside its first line,
    /// as a status note has; bars inside the outermost one are grey, as Slack draws a quote.
    static func apply(to text: NSMutableAttributedString, lines: [Line], bar: NSColor?, statuses: [NSColor?] = [], lineSpacing: CGFloat) {
        let string = text.string as NSString
        var ranges: [NSRange] = [], start = 0
        for index in 0..<string.length where string.character(at: index) == 10 {
            ranges.append(NSRange(location: start, length: index + 1 - start)); start = index + 1
        }
        ranges.append(NSRange(location: start, length: string.length - start))
        guard ranges.count == lines.count, lines.contains(where: { $0.depth > 0 || $0.hidden })
                || lines.indices.contains(where: { marker.firstMatch(in: string as String, range: ranges[$0]) != nil }) else { return }

        // One run number per stretch of lines, so a bar or a box is drawn once around the whole stretch.
        let grey = NSColor.labelColor.withAlphaComponent(0.28)
        var decorations: [Decoration] = [], quotes: [(run: Int, color: NSColor)] = [], box: Int?, runs = 0, stretch = 0
        var status: NSColor?, extra = Array(repeating: 0, count: lines.count)
        for (index, line) in lines.enumerated() {
            if quotes.count != line.depth { box = nil }
            if quotes.count > line.depth { quotes.removeLast(quotes.count - line.depth) }
            while quotes.count < line.depth {
                runs += 1
                if quotes.isEmpty { status = stretch < statuses.count ? statuses[stretch] : nil; stretch += 1 }
                quotes.append((runs, quotes.isEmpty ? bar ?? grey : grey))
            }
            if line.code { if box == nil { runs += 1; box = runs } } else if !line.hidden { box = nil }
            var own = quotes
            // The stretch's status goes beside its first line of words, usually the section's title.
            if let colour = status, line.depth == 1, !line.code, !line.hidden, line.table == 0,
               !string.substring(with: ranges[index]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runs += 1; own.append((runs, colour)); extra[index] = 1; status = nil
            }
            decorations.append(Decoration(quotes: own, box: line.code ? box : nil))
        }
        let shown = lines.indices.filter { !lines[$0].hidden }
        var tables: [Int: NSTextTable] = [:], rows: [Int: Int] = [:]
        for line in lines where line.table > 0 && tables[line.table] == nil {
            let table = NSTextTable()
            table.numberOfColumns = max(1, line.aligns.count)
            table.setContentWidth(100, type: .percentageValueType)
            table.setWidth(CGFloat(line.depth) * quoteStep, type: .absoluteValueType, for: .margin, edge: .minX)
            table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
            table.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
            table.collapsesBorders = true
            tables[line.table] = table
        }
        for index in lines.indices where lines[index].table > 0 {
            rows[index] = lines[..<index].filter { $0.table == lines[index].table && !$0.hidden }.count
        }
        let code = NSFont.monospacedSystemFont(ofSize: ChatMetrics.bodyFont - 1, weight: .regular)
        var trailingHidden = false
        for index in lines.indices.reversed() {
            let line = lines[index], range = ranges[index]
            if line.hidden {
                // A fence marks only where the box starts and ends; the alignment row only how a table's columns sit.
                if range.length > 0 { text.deleteCharacters(in: range) }
                if index == lines.count - 1 { trailingHidden = true }
                continue
            }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            let left = CGFloat(line.depth + extra[index]) * quoteStep
            style.firstLineHeadIndent = left; style.headIndent = left
            var attributes: [NSAttributedString.Key: Any] = [.paragraphStyle: style]
            if line.depth > 0 || line.code { attributes[decoration] = decorations[index] }
            let blank = string.substring(with: range).trimmingCharacters(in: .newlines).isEmpty
            if line.table > 0, let table = tables[line.table], let row = rows[index] {
                text.replaceCharacters(in: range, with: tableRow(text.attributedSubstring(from: range), table: table, row: row, line: line,
                                                                  decoration: line.depth > 0 ? decorations[index] : nil))
                continue
            }
            if line.code {
                let position = shown.firstIndex(of: index)!
                let box = decorations[index].box
                style.firstLineHeadIndent = left + boxPadding; style.headIndent = left + boxPadding; style.tailIndent = -boxPadding
                style.lineSpacing = 1
                if position == 0 || decorations[shown[position - 1]].box != box { style.paragraphSpacingBefore = boxGap + 5 }
                if position == shown.count - 1 || decorations[shown[position + 1]].box != box { style.paragraphSpacing = boxGap + 5 }
                text.addAttributes([.font: code, .foregroundColor: NSColor.labelColor], range: range)
                text.removeAttribute(.backgroundColor, range: range)
            } else if blank, line.depth > 0 {
                // A blank line inside a quote is a small gap, as between Slack's blocks.
                style.lineSpacing = 0; style.maximumLineHeight = 7
            } else if let match = marker.firstMatch(in: string as String, range: range) {
                let leading = (string.substring(with: match.range(at: 1)) as String).reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
                let level = min(5, (leading + 3) / 4)
                var symbol = string.substring(with: match.range(at: 2))
                // A list item that starts with ↳ (a detail line in a report) shows only the arrow.
                if symbol.contains("↳") { symbol = "↳" }
                else if symbol.count == 1, "•◦▪".contains(symbol) { symbol = ["•", "◦", "▪"][level % 3] }
                let marked = text.attributes(at: match.range(at: 2).location, effectiveRange: nil)
                let font = marked[.font] as? NSFont ?? .systemFont(ofSize: ChatMetrics.bodyFont)
                let first = left + 4 + CGFloat(level) * indentStep
                let words = first + max(14, ceil((symbol as NSString).size(withAttributes: [.font: font]).width) + 6)
                style.firstLineHeadIndent = first; style.headIndent = words
                style.tabStops = [NSTextTab(textAlignment: .left, location: words)]
                text.replaceCharacters(in: match.range, with: NSAttributedString(string: symbol + "\t", attributes: marked))
                text.addAttributes(attributes, range: NSRange(location: range.location, length: range.length - match.range.length + (symbol as NSString).length + 1))
                continue
            }
            text.addAttributes(attributes, range: range)
        }
        if let last = shown.last, lines[last].code {
            // TextKit leaves the last paragraph's spacing out of the text's height, which would cut a closing
            // box short; a hairline line after it keeps the box whole.
            let end = NSMutableParagraphStyle(); end.maximumLineHeight = 1; end.minimumLineHeight = 1
            if text.length == 0 || (text.string as NSString).character(at: text.length - 1) != 10 { text.append(NSAttributedString(string: "\n")) }
            text.append(NSAttributedString(string: "\u{200B}", attributes: [.paragraphStyle: end, .font: NSFont.systemFont(ofSize: 1)]))
        } else if trailingHidden, text.length > 0, (text.string as NSString).character(at: text.length - 1) == 10 {
            // A hidden last line leaves the line before it ending in a break of its own.
            text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
        }
    }

    /// A post's attachment colours lined up with its stretches of first-level quotes, from the first.
    /// The colours belong to the last stretches of the whole body (an attachment's lines come after the post's own),
    /// so a folded post, which shows only the start of its body, keeps each colour on its own stretch.
    static func statuses(for body: String, colors: [String]) -> [NSColor?] {
        let lines = strip(body).lines
        let stretches = lines.indices.filter { lines[$0].depth > 0 && ($0 == 0 || lines[$0 - 1].depth == 0) }.count
        return Array(repeating: nil, count: max(0, stretches - colors.count)) + colors.map(MessageFormat.color)
    }

    /// One table row as TextKit wants it: a paragraph per cell, each in its own cell block. Table cells take no
    /// line spacing, which would make TextKit 1 drop the block.
    private static func tableRow(_ source: NSAttributedString, table: NSTextTable, row: Int, line: Line, decoration: Decoration?) -> NSAttributedString {
        let string = source.string as NSString
        let ends = string.hasSuffix("\n")
        var bars: [Int] = []
        for index in 0..<string.length where string.character(at: index) == 124 { bars.append(index) }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines) as NSString
        let opening = trimmed.hasPrefix("|"), closing = trimmed.hasSuffix("|") && trimmed.length > 1
        var edges = bars
        if !opening { edges.insert(-1, at: 0) }
        if !closing { edges.append(string.length - (ends ? 1 : 0)) }
        let result = NSMutableAttributedString()
        let columns = table.numberOfColumns
        for column in 0..<columns {
            var cell = NSAttributedString(string: " ", attributes: source.attributes(at: 0, effectiveRange: nil))
            if column + 1 < edges.count {
                let start = edges[column] + 1, end = edges[column + 1]
                let piece = NSMutableAttributedString(attributedString: source.attributedSubstring(from: NSRange(location: start, length: max(0, end - start))))
                while piece.length > 0, (piece.string as NSString).character(at: 0) == 32 { piece.deleteCharacters(in: NSRange(location: 0, length: 1)) }
                while piece.length > 0, (piece.string as NSString).character(at: piece.length - 1) == 32 { piece.deleteCharacters(in: NSRange(location: piece.length - 1, length: 1)) }
                if piece.length > 0 { cell = piece }
            }
            let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
            block.setWidth(1, type: .absoluteValueType, for: .border)
            block.setBorderColor(NSColor.labelColor.withAlphaComponent(0.2))
            block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(3, type: .absoluteValueType, for: .padding, edge: .maxY)
            block.verticalAlignment = .middleAlignment
            if line.header { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.07) }
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            style.alignment = column < line.aligns.count ? line.aligns[column] : .left
            let laid = NSMutableAttributedString(attributedString: cell)
            if column < columns - 1 || ends { laid.append(NSAttributedString(string: "\n", attributes: cell.attributes(at: max(0, cell.length - 1), effectiveRange: nil))) }
            let all = NSRange(location: 0, length: laid.length)
            laid.addAttribute(.paragraphStyle, value: style, range: all)
            if let decoration { laid.addAttribute(SlackLayout.decoration, value: decoration, range: all) }
            if line.header {
                laid.enumerateAttribute(.font, in: all) { value, range, _ in
                    let font = value as? NSFont ?? .systemFont(ofSize: ChatMetrics.bodyFont)
                    laid.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
                }
            }
            result.append(laid)
        }
        return result
    }

    /// Where each bar and box goes in a laid-out text, in the text container's coordinates.
    static func frames(_ storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer) -> (bars: [(NSRect, NSColor)], boxes: [NSRect]) {
        var bars: [Int: (rect: NSRect, color: NSColor, level: Int)] = [:], boxes: [Int: (rect: NSRect, level: Int)] = [:]
        storage.enumerateAttribute(decoration, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let item = value as? Decoration, range.length > 0 else { return }
            var rect = NSRect.null
            manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)) { fragment, _, _, _, _ in
                rect = rect.union(fragment)
            }
            guard !rect.isNull else { return }
            for (level, quote) in item.quotes.enumerated() {
                bars[quote.run] = (bars[quote.run]?.rect.union(rect) ?? rect, quote.color, level)
            }
            if let box = item.box { boxes[box] = (boxes[box]?.rect.union(rect) ?? rect, item.quotes.count) }
        }
        let width = container.size.width
        return (bars.keys.sorted().map { key in
                    let bar = bars[key]!
                    return (NSRect(x: CGFloat(bar.level) * quoteStep, y: bar.rect.minY, width: barWidth, height: bar.rect.height), bar.color)
                },
                boxes.keys.sorted().map { key in
                    let box = boxes[key]!, left = CGFloat(box.level) * quoteStep
                    return NSRect(x: left, y: box.rect.minY + boxGap, width: max(1, width - left), height: max(1, box.rect.height - 2 * boxGap))
                })
    }

    /// Draws the bars and code boxes behind a text view's words.
    static func draw(in view: NSTextView) {
        guard let storage = view.textStorage, storage.length > 0, let manager = view.layoutManager, let container = view.textContainer else { return }
        let found = frames(storage, manager: manager, container: container)
        guard !found.bars.isEmpty || !found.boxes.isEmpty else { return }
        let origin = view.textContainerOrigin
        for box in found.boxes {
            let path = NSBezierPath(roundedRect: box.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            NSColor.labelColor.withAlphaComponent(0.06).setFill(); path.fill()
            NSColor.labelColor.withAlphaComponent(0.16).setStroke(); path.lineWidth = 1; path.stroke()
        }
        for (rect, color) in found.bars {
            color.setFill()
            NSBezierPath(roundedRect: rect.offsetBy(dx: origin.x, dy: origin.y), xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

/// The sections of the room list, row by row: ddots alone at the top (section 0), then each section's rows. A line
/// stands wherever the section changes from the row above.
struct SlackZones: Equatable {
    static let dividerHeight: CGFloat = 13
    /// The section of each row, from the top.
    let zones: [Int]

    /// `zoneOf` gives each row's section; a row not in it is in the first.
    init(rooms: [String], zoneOf: [String: Int]) { zones = rooms.map { zoneOf[$0] ?? 1 } }

    func zone(_ offset: Int) -> Int { zones.indices.contains(offset) ? zones[offset] : 1 }
    /// True when a line stands just above the row at `offset`.
    func breaks(_ offset: Int) -> Bool { offset > 0 && zones.indices.contains(offset) && zones[offset] != zones[offset - 1] }
    /// How far the lines push down the row at `offset`.
    func above(_ offset: Int) -> CGFloat { CGFloat((0...max(0, offset)).filter(breaks).count) * Self.dividerHeight }
}
