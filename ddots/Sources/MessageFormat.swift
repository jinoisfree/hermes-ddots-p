import AppKit
import SwiftUI

/// Text-only formatting shared by the composer and received messages. No HTML/WebKit is executed.
/// Markdown remains readable outside ddots; optional span/u tags carry size, colour and underline.
enum MessageFormat {
    static let baseSize: CGFloat = 13
    static let sizes: [CGFloat] = [11, 13, 16, 20, 24, 28]
    static let colors: [(String, String)] = [("빨강", "#E05252"), ("주황", "#CC7A29"), ("초록", "#309968"), ("파랑", "#4285E8"), ("보라", "#A16BDD")]
    private static let explicitColor = NSAttributedString.Key("ddots.explicitColor")
    private static let tag = try! NSRegularExpression(pattern: #"`[^`\n]*`|</?(?:b|strong|i|em|u|s|del|span)(?:\s+[^<>]*)?>"#, options: .caseInsensitive)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,3})\s+(.+)$"#)
    private static let check = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*] )?\[([ xX])\] +"#)
    private static let extended = try! NSRegularExpression(pattern: #"(?m)^(?:#{1,3}[ \t]+|[ \t]*(?:[-*] )?\[[ xX]\][ \t]+|[ \t]*```)|</?(?:b|strong|i|em|u|s|del|span)(?:\s|>)"#, options: .caseInsensitive)
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?<!\*)\*{3}([^*\n]+)\*{2}(?!\*)"#, with: "**$1**", options: .regularExpression)
            .replacingOccurrences(of: #"(?<![~\\])~(?!~)"#, with: #"\\~"#, options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^([ \t]*)[-*][ \t]+(?=\S)"#, with: "$1• ", options: .regularExpression)
    }

    struct Style {
        var size = baseSize
        var color: NSColor?
        var bold = false, italic = false, underline = false, strike = false, code = false
        var attributes: [NSAttributedString.Key: Any] {
            var font = code ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular) : NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
            if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var value: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color ?? NSColor.labelColor]
            if let color { value[explicitColor] = color }
            if underline { value[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if strike { value[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return value
        }
    }

    static func color(_ hex: String) -> NSColor? {
        guard hex.count == 7, hex.first == "#", let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    private static func property(_ name: String, in tag: String) -> String? {
        let pattern = NSRegularExpression.escapedPattern(for: name) + #"\s*:\s*([^;\"']+)"#
        guard let match = tag.range(of: pattern, options: [.regularExpression, .caseInsensitive]), let colon = tag[match].firstIndex(of: ":") else { return nil }
        return tag[tag.index(after: colon)..<match.upperBound].trimmingCharacters(in: .whitespaces)
    }
    private static func applying(_ token: String, to style: Style) -> Style {
        var next = style
        let name = token.dropFirst().prefix { $0.isLetter }.lowercased()
        switch name {
        case "b", "strong": next.bold = true
        case "i", "em": next.italic = true
        case "u": next.underline = true
        case "s", "del": next.strike = true
        case "span":
            if let value = property("font-size", in: token), let size = Double(value.replacingOccurrences(of: "px", with: "").replacingOccurrences(of: "pt", with: "")), size.isFinite { next.size = min(32, max(10, size)) }
            if let value = property("color", in: token), let color = color(value) { next.color = color }
        default: break
        }
        return next
    }

    /// The editor decodes only explicit rich spans, keeping typed Markdown and punctuation editable as written.
    static func editor(_ source: String) -> NSAttributedString { parse(source, markdown: false) }
    static func plain(_ source: String) -> String {
        guard source.contains("<") else { return source }
        return editor(source).string
    }
    private static func parse(_ source: String, markdown: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        var stack: [(String, Style)] = [], style = Style(), fenced = false
        func append(_ raw: String, style: Style, encoded: Bool) {
            let text = encoded ? unescape(raw) : raw
            guard markdown, !style.code else { output.append(NSAttributedString(string: text, attributes: style.attributes)); return }
            let parsed = (try? AttributedString(markdown: normalized(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
            for run in parsed.runs {
                var runStyle = style
                let intent = run.inlinePresentationIntent ?? []
                runStyle.bold = runStyle.bold || intent.contains(.stronglyEmphasized)
                runStyle.italic = runStyle.italic || intent.contains(.emphasized)
                runStyle.strike = runStyle.strike || intent.contains(.strikethrough)
                runStyle.code = runStyle.code || intent.contains(.code)
                var attributes = runStyle.attributes
                if let url = run.link { attributes[.link] = url }
                output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
        }
        let lines = source.components(separatedBy: "\n")
        for (number, original) in lines.enumerated() {
            if number > 0 { output.append(NSAttributedString(string: "\n", attributes: style.attributes)) }
            var line = original, lineStyle = style
            if markdown, original.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle(); continue
            }
            if fenced { lineStyle.code = true; append(line, style: lineStyle, encoded: false); continue }
            if markdown {
                let range = NSRange(line.startIndex..., in: line)
                if let match = heading.firstMatch(in: line, range: range) {
                    lineStyle.size = [24.0, 20.0, 18.0][match.range(at: 1).length - 1]; lineStyle.bold = true
                    line = (line as NSString).substring(with: match.range(at: 2))
                } else if let match = check.firstMatch(in: line, range: range) {
                    let checked = (line as NSString).substring(with: match.range(at: 2)).lowercased() == "x"
                    line = (line as NSString).replacingCharacters(in: match.range, with: (line as NSString).substring(with: match.range(at: 1)) + (checked ? "☑ " : "☐ "))
                }
            }
            var position = line.startIndex
            for match in tag.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                guard let range = Range(match.range, in: line) else { continue }
                append(String(line[position..<range.lowerBound]), style: stack.isEmpty ? lineStyle : style, encoded: !stack.isEmpty)
                let token = String(line[range]), closing = token.hasPrefix("</")
                let name = token.dropFirst(closing ? 2 : 1).prefix { $0.isLetter }.lowercased()
                if token.first == "`" {
                    append(token, style: stack.isEmpty ? lineStyle : style, encoded: !stack.isEmpty)
                } else if closing, let last = stack.last, last.0 == name {
                    style = last.1; stack.removeLast()
                } else if !closing, stack.count < 16,
                          (line[range.upperBound...].range(of: "</" + name + ">", options: .caseInsensitive) != nil
                           || lines.dropFirst(number + 1).contains(where: { $0.range(of: "</" + name + ">", options: .caseInsensitive) != nil })) {
                    stack.append((name, stack.isEmpty ? lineStyle : style)); style = applying(token, to: stack.last!.1)
                } else {
                    append(token, style: stack.isEmpty ? lineStyle : style, encoded: false)
                }
                position = range.upperBound
            }
            append(String(line[position...]), style: stack.isEmpty ? lineStyle : style, encoded: !stack.isEmpty)
            if stack.isEmpty { style = Style() }
        }
        return output
    }

    /// Native text cards use the same parser without a SwiftUI font conversion.
    static func renderNative(_ source: String) -> NSAttributedString { parse(source, markdown: true) }

    static func render(_ source: String) -> AttributedString {
        // Most conversation rows use ordinary Markdown; keep their original parsing and inherited fonts.
        if extended.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)) == nil {
            return (try? AttributedString(markdown: normalized(source), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        }
        let native = parse(source, markdown: true)
        var result = AttributedString()
        native.enumerateAttributes(in: NSRange(location: 0, length: native.length)) { attributes, range, _ in
            var part = AttributedString((native.string as NSString).substring(with: range))
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                var styled = Font.system(size: font.pointSize, weight: traits.contains(.boldFontMask) ? .bold : .regular, design: traits.contains(.fixedPitchFontMask) ? .monospaced : .default)
                if traits.contains(.italicFontMask) { styled = styled.italic() }
                part.font = styled
                var intent: InlinePresentationIntent = []
                if traits.contains(.fixedPitchFontMask) { intent.insert(.code) }
                if traits.contains(.boldFontMask) { intent.insert(.stronglyEmphasized) }
                if traits.contains(.italicFontMask) { intent.insert(.emphasized) }
                if !intent.isEmpty { part.inlinePresentationIntent = intent }
            }
            if let color = attributes[explicitColor] as? NSColor { part.foregroundColor = Color(nsColor: color) }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { part.underlineStyle = .single }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { part.strikethroughStyle = .single }
            if let url = attributes[.link] as? URL { part.link = url }
            result.append(part)
        }
        return result
    }

    /// Keep unformatted drafts byte-for-byte compatible. Formatting is text, so history/relay can preserve it.
    static func serialize(_ text: NSAttributedString) -> String {
        var result = ""
        var previousOpen = "", previousClose = "", pending = ""
        func flush() {
            guard !pending.isEmpty else { return }
            result += previousOpen + (previousOpen.isEmpty ? pending : escape(pending)) + previousClose
            pending = ""
        }
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let raw = (text.string as NSString).substring(with: range)
            let font = attrs[.font] as? NSFont ?? NSFont.systemFont(ofSize: baseSize)
            let traits = NSFontManager.shared.traits(of: font)
            var open = "", close = "", properties: [String] = []
            if abs(font.pointSize - baseSize) > 0.5 { properties.append("font-size:\(Int(font.pointSize))px") }
            if let color = attrs[explicitColor] as? NSColor, let value = hex(color) { properties.append("color:" + value) }
            if !properties.isEmpty { open += "<span style=\"" + properties.joined(separator: ";") + "\">"; close = "</span>" + close }
            for (active, name) in [(traits.contains(.boldFontMask), "b"), (traits.contains(.italicFontMask), "i"), ((attrs[.underlineStyle] as? Int ?? 0) != 0, "u"), ((attrs[.strikethroughStyle] as? Int ?? 0) != 0, "s")] where active {
                open += "<" + name + ">"; close = "</" + name + ">" + close
            }
            if open != previousOpen || close != previousClose { flush() }
            previousOpen = open; previousClose = close; pending += raw
        }
        flush()
        return result
    }
    static func colorAttributes(_ value: NSColor?) -> [NSAttributedString.Key: Any] {
        guard let value else { return [.foregroundColor: NSColor.labelColor] }
        return [.foregroundColor: value, explicitColor: value]
    }
    static func clearColor(in storage: NSMutableAttributedString, range: NSRange) { storage.removeAttribute(explicitColor, range: range) }
    static func clearColor(in attributes: inout [NSAttributedString.Key: Any]) { attributes.removeValue(forKey: explicitColor) }
}
