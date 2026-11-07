import Foundation

/// Reads a mail file (.eml): headers (RFC 2047 words decoded) and the body text. `text/plain` wins over `text/html`;
/// attachments are named, never read. The text format matches team-kit's `read_eml`: header lines, a blank line, the
/// body, then one `첨부: 이름` line per attachment.
enum FileDropMail {
    struct Result { var text: String; var complete: Bool }

    private struct Part {
        var headers: [(name: String, value: String)]
        var body: Data
        func header(_ name: String) -> String? { headers.first { $0.name == name }?.value }
    }

    static func read(_ data: Data) -> Result? {
        let root = parse(data)
        guard !root.headers.isEmpty else { return nil }
        var plain: [String] = [], rich: [String] = [], attachments: [String] = []
        walk(root, plain: &plain, rich: &rich, attachments: &attachments)
        let body = (plain.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ? plain.joined(separator: "\n") : rich.map(FileDropSignals.htmlText).joined(separator: "\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = [("보낸 사람", "from"), ("받는 사람", "to"), ("참조", "cc"), ("날짜", "date"), ("제목", "subject")].compactMap { label, name -> String? in
            let values = root.headers.filter { $0.name == name }.map { words($0.value).split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { !$0.isEmpty }
            return values.isEmpty ? nil : label + ": " + values.joined(separator: ", ")
        }
        var text = lines.joined(separator: "\n") + "\n\n" + String(body.prefix(FileDropSignals.contentLimit))
        if !attachments.isEmpty { text += "\n\n" + attachments.map { "첨부: " + $0 }.joined(separator: "\n") }
        return Result(text: text, complete: !lines.isEmpty && body.count <= FileDropSignals.contentLimit)
    }

    private static func walk(_ part: Part, plain: inout [String], rich: inout [String], attachments: inout [String]) {
        let type = (part.header("content-type") ?? "text/plain").lowercased()
        if type.hasPrefix("multipart/"), let boundary = parameter("boundary", in: part.header("content-type") ?? "") {
            for child in split(part.body, boundary: boundary) { walk(parse(child), plain: &plain, rich: &rich, attachments: &attachments) }
            return
        }
        if let name = filename(part) { attachments.append(name); return }
        guard type.hasPrefix("text/plain") || type.hasPrefix("text/html") else { return }
        let text = decode(part.body, transfer: part.header("content-transfer-encoding") ?? "", charset: parameter("charset", in: part.header("content-type") ?? ""))
        if type.hasPrefix("text/plain") { plain.append(text) } else { rich.append(text) }
    }

    /// Headers up to the first blank line (unfolded, names lowercased), then the body bytes.
    private static func parse(_ data: Data) -> Part {
        let separators = [Data("\r\n\r\n".utf8), Data("\n\n".utf8)]
        let cut = separators.compactMap { data.range(of: $0) }.min { $0.lowerBound < $1.lowerBound }
        let head = cut.map { data[..<$0.lowerBound] } ?? data[...]
        let body = cut.map { data[$0.upperBound...] } ?? Data()
        var headers: [(name: String, value: String)] = []
        for raw in String(decoding: head, as: UTF8.self).components(separatedBy: .newlines) {
            if raw.first == " " || raw.first == "\t" { if !headers.isEmpty { headers[headers.count - 1].value += " " + raw.trimmingCharacters(in: .whitespaces) } }
            else if let colon = raw.firstIndex(of: ":") {
                headers.append((String(raw[..<colon]).trimmingCharacters(in: .whitespaces).lowercased(), String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        return Part(headers: headers, body: Data(body))
    }

    private static func split(_ body: Data, boundary: String) -> [Data] {
        let marker = Data(("--" + boundary).utf8)
        var parts: [Data] = [], start: Data.Index?, cursor = body.startIndex
        while let hit = body.range(of: marker, in: cursor..<body.endIndex) {
            if let start { parts.append(Data(body[start..<hit.lowerBound])) }
            let after = hit.upperBound
            if body[after...].starts(with: Data("--".utf8)) { start = nil; break }
            // Skip the rest of the boundary line.
            start = body[after...].firstIndex(of: 0x0A).map { $0 + 1 } ?? body.endIndex
            cursor = start ?? body.endIndex
        }
        return parts
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == name { return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }

    /// `filename*=UTF-8''%EA...` (RFC 2231), `filename="=?UTF-8?B?...?="` (RFC 2047) or a plain/raw name.
    private static func filename(_ part: Part) -> String? {
        let disposition = part.header("content-disposition") ?? "", type = part.header("content-type") ?? ""
        for header in [disposition, type] {
            for piece in header.split(separator: ";").dropFirst() {
                let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { continue }
                let key = pair[0].lowercased(), value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if key == "filename*" || key == "name*" {
                    let tail = value.components(separatedBy: "'")
                    if tail.count >= 3, let decoded = tail[2...].joined(separator: "'").removingPercentEncoding { return decoded }
                } else if key == "filename" || key == "name" { return words(value) }
            }
        }
        return nil
    }

    /// RFC 2047 encoded words (`=?charset?B|Q?text?=`) in a header value.
    static func words(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return value }
        var result = "", cursor = value.startIndex, previousWasWord = false
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let whole = Range(match.range, in: value), let charset = Range(match.range(at: 1), in: value),
                  let kind = Range(match.range(at: 2), in: value), let payload = Range(match.range(at: 3), in: value) else { continue }
            let between = String(value[cursor..<whole.lowerBound])
            // Whitespace between two encoded words is not part of the text.
            if !(previousWasWord && between.allSatisfy(\.isWhitespace)) { result += between }
            let bytes: Data? = value[kind].lowercased() == "b"
                ? Data(base64Encoded: String(value[payload]))
                : quotedPrintable(Data(String(value[payload]).replacingOccurrences(of: "_", with: " ").utf8))
            result += bytes.flatMap { text($0, charset: String(value[charset])) } ?? String(value[whole])
            cursor = whole.upperBound; previousWasWord = true
        }
        return result + value[cursor...]
    }

    private static func decode(_ body: Data, transfer: String, charset: String?) -> String {
        let bytes: Data
        switch transfer.lowercased().trimmingCharacters(in: .whitespaces) {
        case "base64": bytes = Data(base64Encoded: String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }) ?? body
        case "quoted-printable": bytes = quotedPrintable(body)
        default: bytes = body
        }
        return text(bytes, charset: charset ?? "utf-8") ?? String(decoding: bytes, as: UTF8.self)
    }

    private static func quotedPrintable(_ input: Data) -> Data {
        var out = Data(), index = input.startIndex
        func hex(_ byte: UInt8) -> UInt8? { Character(UnicodeScalar(byte)).hexDigitValue.map(UInt8.init) }
        while index < input.endIndex {
            let byte = input[index]
            if byte == 0x3D {
                let next = input.index(after: index)
                if next < input.endIndex, input[next] == 0x0A { index = input.index(after: next); continue }
                if next < input.endIndex, input[next] == 0x0D { let end = input.index(after: next); index = (end < input.endIndex && input[end] == 0x0A) ? input.index(after: end) : end; continue }
                if input.distance(from: next, to: input.endIndex) >= 2, let high = hex(input[next]), let low = hex(input[input.index(after: next)]) {
                    out.append(high << 4 | low); index = input.index(next, offsetBy: 2); continue
                }
            }
            out.append(byte); index = input.index(after: index)
        }
        return out
    }

    /// UTF-8 first when the label says so; the Korean labels map to the EUC-KR/CP949/ISO-2022-KR code pages.
    static func text(_ bytes: Data, charset: String) -> String? {
        let label = charset.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        func encoding(_ value: CFStringEncodings) -> String.Encoding { .init(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue))) }
        let candidates: [String.Encoding]
        switch label {
        case "euc-kr", "euc_kr", "ks_c_5601-1987", "ks_c_5601", "ksc5601", "x-windows-949", "cp949", "korean": candidates = [encoding(.dosKorean), encoding(.EUC_KR), .utf8]
        case "iso-2022-kr": candidates = [encoding(.ISO_2022_KR), .utf8]
        case "iso-8859-1", "latin1": candidates = [.isoLatin1]
        default: candidates = [.utf8, encoding(.dosKorean)]
        }
        for candidate in candidates { if let value = String(data: bytes, encoding: candidate) { return value } }
        return nil
    }
}
