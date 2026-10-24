import Foundation

/// The characters of a copied web page, read without WebKit, so nothing is fetched or run.
/// Only the text is kept: lines from <br> and block edges, tabs between table cells, <pre> spacing as written.
enum HTMLText {
    private static let skipped: Set<String> = ["head", "script", "style", "title", "template", "noscript"]
    private static let blocks: Set<String> = ["p", "div", "li", "ul", "ol", "dl", "dt", "dd", "h1", "h2", "h3", "h4", "h5", "h6", "table", "caption",
                                              "blockquote", "pre", "section", "article", "header", "footer", "nav", "aside", "main", "figure",
                                              "figcaption", "address", "details", "summary", "fieldset", "form", "hr"]

    static func text(_ html: String) -> String {
        let source = Array(html.unicodeScalars)
        var result = "", space = false, newline = false, pre = 0, preStart = false
        var cells: [Int] = []
        func breakLine() {
            if !result.isEmpty, !result.hasSuffix("\n") { result += "\n" }
            newline = false; space = false
        }
        func emit(_ text: String) {
            if newline { breakLine() }
            if space, !result.isEmpty, !result.hasSuffix("\n"), !result.hasSuffix("\t") { result += " " }
            space = false
            result += text
        }
        func characters(_ raw: String) {
            let text = decode(raw)
            if pre > 0 {
                var kept = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                if preStart, kept.hasPrefix("\n") { kept.removeFirst() }
                preStart = false
                if !kept.isEmpty { emit(kept) }
                return
            }
            var word = ""
            for scalar in text.unicodeScalars {
                if [" ", "\t", "\n", "\r", "\u{C}"].contains(scalar) {
                    if !word.isEmpty { emit(word); word = "" }
                    space = true
                } else { word.unicodeScalars.append(scalar) }
            }
            if !word.isEmpty { emit(word) }
        }
        func isNameStart(_ index: Int) -> Bool { index < source.count && source[index].properties.isAlphabetic && source[index].isASCII }
        var index = 0, run = String.UnicodeScalarView()
        func flush() { if !run.isEmpty { characters(String(run)); run = String.UnicodeScalarView() } }
        func skip(past end: String, from start: Int) -> Int {
            let target = Array(end.unicodeScalars)
            var at = start
            while at + target.count <= source.count {
                if Array(source[at..<at + target.count]) == target { return at + target.count }
                at += 1
            }
            return source.count
        }
        while index < source.count {
            let scalar = source[index]
            guard scalar == "<", index + 1 < source.count else { run.append(scalar); index += 1; continue }
            let next = source[index + 1]
            if next == "!" || next == "?" {
                flush()
                let comment = index + 3 < source.count && source[index + 2] == "-" && source[index + 3] == "-"
                index = skip(past: comment ? "-->" : ">", from: index + (comment ? 4 : 2))
                continue
            }
            let closing = next == "/"
            guard isNameStart(index + (closing ? 2 : 1)) else { run.append(scalar); index += 1; continue }
            flush()
            var at = index + (closing ? 2 : 1), name = ""
            while at < source.count, source[at].isASCII, source[at].properties.isAlphabetic || source[at].properties.numericType != nil || source[at] == "-" {
                name.unicodeScalars.append(source[at]); at += 1
            }
            name = name.lowercased()
            // Attributes end at the first > outside a quoted value, so title="a>b" stays inside the tag.
            var quote: Unicode.Scalar?, previous: Unicode.Scalar = " ", selfClosing = false
            while at < source.count {
                let current = source[at]
                if let open = quote { if current == open { quote = nil } }
                else if (current == "\"" || current == "'") && previous == "=" { quote = current }
                else if current == ">" { break }
                if !current.properties.isWhitespace { previous = current }
                at += 1
            }
            selfClosing = previous == "/"
            index = min(at + 1, source.count)
            if !closing, !selfClosing, skipped.contains(name) {
                // Skip to the matching end tag; a nested tag of the same name cannot occur in these elements.
                var end = index
                while true {
                    end = skip(past: "</", from: end)
                    guard end < source.count else { index = source.count; break }
                    let candidate = String(String.UnicodeScalarView(source[end..<min(end + name.unicodeScalars.count, source.count)])).lowercased()
                    let after = end + name.unicodeScalars.count
                    if candidate == name, after >= source.count || !(source[after].isASCII && source[after].properties.isAlphabetic) {
                        index = skip(past: ">", from: after); break
                    }
                }
                continue
            }
            switch name {
            case "br": if newline { breakLine() }; result += "\n"; space = false
            case "tr":
                if closing { _ = cells.popLast() } else { cells.append(0) }
                newline = true
            case "td", "th":
                guard !closing, let count = cells.last else { break }
                if newline { breakLine() }
                if count > 0 { result += "\t" }
                space = false
                cells[cells.count - 1] = count + 1
            default:
                if blocks.contains(name) { newline = true }
            }
            if name == "pre" {
                if closing { pre = max(0, pre - 1) } else if !selfClosing { pre += 1; preStart = true }
            }
        }
        flush()
        return result.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Character references: decimal, hexadecimal and the HTML 4 names. Anything else is left as written.
    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = "", rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(32).firstIndex(of: ";") {
                let key = after[..<semi]
                var value: UInt32?
                if key.hasPrefix("#x") || key.hasPrefix("#X") { value = UInt32(key.dropFirst(2), radix: 16) }
                else if key.hasPrefix("#") { value = UInt32(key.dropFirst()) }
                else { value = entities[String(key)] }
                if let value, value != 0, let scalar = Unicode.Scalar(value) {
                    result.unicodeScalars.append(scalar)
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            result += "&"
            rest = after
        }
        return result + rest
    }

    private static let entities: [String: UInt32] = {
        let table =
        "quot=22 amp=26 lt=3C gt=3E nbsp=A0 iexcl=A1 cent=A2 pound=A3 curren=A4 yen=A5 brvbar=A6 sect=A7 uml=A8 copy=A9 ordf=AA laquo=AB " +
        "not=AC shy=AD reg=AE macr=AF deg=B0 plusmn=B1 sup2=B2 sup3=B3 acute=B4 micro=B5 para=B6 middot=B7 cedil=B8 sup1=B9 ordm=BA " +
        "raquo=BB frac14=BC frac12=BD frac34=BE iquest=BF Agrave=C0 Aacute=C1 Acirc=C2 Atilde=C3 Auml=C4 Aring=C5 AElig=C6 Ccedil=C7 " +
        "Egrave=C8 Eacute=C9 Ecirc=CA Euml=CB Igrave=CC Iacute=CD Icirc=CE Iuml=CF ETH=D0 Ntilde=D1 Ograve=D2 Oacute=D3 Ocirc=D4 Otilde=D5 " +
        "Ouml=D6 times=D7 Oslash=D8 Ugrave=D9 Uacute=DA Ucirc=DB Uuml=DC Yacute=DD THORN=DE szlig=DF agrave=E0 aacute=E1 acirc=E2 atilde=E3 " +
        "auml=E4 aring=E5 aelig=E6 ccedil=E7 egrave=E8 eacute=E9 ecirc=EA euml=EB igrave=EC iacute=ED icirc=EE iuml=EF eth=F0 ntilde=F1 " +
        "ograve=F2 oacute=F3 ocirc=F4 otilde=F5 ouml=F6 divide=F7 oslash=F8 ugrave=F9 uacute=FA ucirc=FB uuml=FC yacute=FD thorn=FE yuml=FF " +
        "OElig=152 oelig=153 Scaron=160 scaron=161 Yuml=178 fnof=192 circ=2C6 tilde=2DC Alpha=391 Beta=392 Gamma=393 Delta=394 Epsilon=395 " +
        "Zeta=396 Eta=397 Theta=398 Iota=399 Kappa=39A Lambda=39B Mu=39C Nu=39D Xi=39E Omicron=39F Pi=3A0 Rho=3A1 Sigma=3A3 Tau=3A4 " +
        "Upsilon=3A5 Phi=3A6 Chi=3A7 Psi=3A8 Omega=3A9 alpha=3B1 beta=3B2 gamma=3B3 delta=3B4 epsilon=3B5 zeta=3B6 eta=3B7 theta=3B8 " +
        "iota=3B9 kappa=3BA lambda=3BB mu=3BC nu=3BD xi=3BE omicron=3BF pi=3C0 rho=3C1 sigmaf=3C2 sigma=3C3 tau=3C4 upsilon=3C5 phi=3C6 " +
        "chi=3C7 psi=3C8 omega=3C9 thetasym=3D1 upsih=3D2 piv=3D6 ensp=2002 emsp=2003 thinsp=2009 zwnj=200C zwj=200D lrm=200E rlm=200F " +
        "ndash=2013 mdash=2014 lsquo=2018 rsquo=2019 sbquo=201A ldquo=201C rdquo=201D bdquo=201E dagger=2020 Dagger=2021 bull=2022 " +
        "hellip=2026 permil=2030 prime=2032 Prime=2033 lsaquo=2039 rsaquo=203A oline=203E frasl=2044 euro=20AC image=2111 weierp=2118 " +
        "real=211C trade=2122 alefsym=2135 larr=2190 uarr=2191 rarr=2192 darr=2193 harr=2194 crarr=21B5 lArr=21D0 uArr=21D1 rArr=21D2 " +
        "dArr=21D3 hArr=21D4 forall=2200 part=2202 exist=2203 empty=2205 nabla=2207 isin=2208 notin=2209 ni=220B prod=220F sum=2211 " +
        "minus=2212 lowast=2217 radic=221A prop=221D infin=221E ang=2220 and=2227 or=2228 cap=2229 cup=222A int=222B there4=2234 sim=223C " +
        "cong=2245 asymp=2248 ne=2260 equiv=2261 le=2264 ge=2265 sub=2282 sup=2283 nsub=2284 sube=2286 supe=2287 oplus=2295 otimes=2297 " +
        "perp=22A5 sdot=22C5 lceil=2308 rceil=2309 lfloor=230A rfloor=230B lang=2329 rang=232A loz=25CA spades=2660 clubs=2663 hearts=2665 " +
        "diams=2666 apos=27"
        var map: [String: UInt32] = [:]
        for pair in table.split(separator: " ") {
            let parts = pair.split(separator: "=")
            map[String(parts[0])] = UInt32(parts[1], radix: 16)
        }
        return map
    }()
}
