import AppKit

enum ChatMetrics {
    static let avatar: CGFloat = 30
    /// Corner radius of a character picture as a share of its side.
    static let avatarCorner: CGFloat = 0.24
    static let callerAvatar: CGFloat = 24
    static let notificationAvatar: CGFloat = 20
    static let thumbnailPixels = 64
    static let nameFont: CGFloat = 13
    static let auxiliaryFont: CGFloat = 11
    static let bodyFont: CGFloat = 13
    static let avatarNameGap: CGFloat = 8
    static let nameBodyGap: CGFloat = 4
    static let speakerInset: CGFloat = 10
    static let replyInset: CGFloat = 0
    static let horizontalInset: CGFloat = 12
    static let minimumBubbleWidth: CGFloat = 240
    static let bubbleWidthFraction: CGFloat = 0.82
}

struct ChatCharacter: Identifiable, Equatable {
    var id: String
    var name: String
    static var preferred: [String] { DdotsConfig.shared.order }
    static func ordered(_ characters: [ChatCharacter]) -> [ChatCharacter] {
        characters.sorted {
            let a = preferred.firstIndex(of: $0.id) ?? preferred.count
            let b = preferred.firstIndex(of: $1.id) ?? preferred.count
            if a != b { return a < b }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id < $1.id
        }
    }
}

enum CharacterCall {
    /// Only recognized leading names followed by a comma are control text; the remaining body is kept verbatim.
    static func toggled(_ draft: String, name: String, characters: [ChatCharacter]) -> String {
        let leadingTrimmed = draft.drop(while: { $0.isWhitespace })
        for candidate in characters.map(\.name).sorted(by: { $0.count > $1.count }) {
            guard leadingTrimmed.hasPrefix(candidate) else { continue }
            let rest = leadingTrimmed.dropFirst(candidate.count).drop(while: { $0 == " " || $0 == "\t" })
            guard rest.first == "," else { continue }
            let body = String(rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" }))
            return candidate == name ? body : name + ", " + body
        }
        return name + ", " + String(leadingTrimmed)
    }
}

enum LongReply {
    static let lineLimit = 12
    static let characterLimit = 600
    static func needsFolding(_ text: String) -> Bool {
        text.count > characterLimit || text.components(separatedBy: "\n").count > lineLimit
    }
    /// Whole lines whenever possible. A single overlong line is cut at a grapheme boundary.
    /// The UI slices the already-parsed AttributedString at this boundary so emphasis/link spans stay valid.
    static func preview(_ text: String) -> String {
        guard needsFolding(text) else { return text }
        let lines = text.components(separatedBy: "\n")
        var result = ""
        for (index, line) in lines.prefix(lineLimit).enumerated() {
            let candidate = result + (index == 0 ? "" : "\n") + line
            if candidate.count > characterLimit {
                return index == 0 ? String(line.prefix(characterLimit)) : result
            }
            result = candidate
        }
        return result
    }
}

struct PaletteRGB: Equatable {
    var r: Double; var g: Double; var b: Double
    static let white = PaletteRGB(r: 1, g: 1, b: 1)
    static let black = PaletteRGB(r: 0, g: 0, b: 0)
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var hex: String { String(format: "#%02X%02X%02X", Int((r*255).rounded()), Int((g*255).rounded()), Int((b*255).rounded())) }
    var luminance: Double {
        func linear(_ x: Double) -> Double { x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4) }
        return 0.2126*linear(r) + 0.7152*linear(g) + 0.0722*linear(b)
    }
    static func contrast(_ a: PaletteRGB, _ b: PaletteRGB) -> Double {
        (max(a.luminance,b.luminance)+0.05)/(min(a.luminance,b.luminance)+0.05)
    }
    static func hsl(_ hue: Double, _ saturation: Double, _ lightness: Double) -> PaletteRGB {
        let h = (hue.truncatingRemainder(dividingBy: 360)+360).truncatingRemainder(dividingBy: 360)/60
        let c = (1-abs(2*lightness-1))*saturation, x = c*(1-abs(h.truncatingRemainder(dividingBy: 2)-1)), m = lightness-c/2
        let rgb: (Double,Double,Double)
        switch h { case ..<1: rgb=(c,x,0); case ..<2: rgb=(x,c,0); case ..<3: rgb=(0,c,x); case ..<4: rgb=(0,x,c); case ..<5: rgb=(x,0,c); default: rgb=(c,0,x) }
        return PaletteRGB(r:rgb.0+m,g:rgb.1+m,b:rgb.2+m)
    }
}

struct CharacterPalette: Equatable {
    var background: PaletteRGB
    var foreground: PaletteRGB
    var name: PaletteRGB
    var link: PaletteRGB
    var hue: Double?
    var contrast: Double { PaletteRGB.contrast(background, foreground) }
    var linkContrast: Double { PaletteRGB.contrast(background, link) }
    static func distance(_ a: Double, _ b: Double) -> Double { min(abs(a-b),360-abs(a-b)) }
    static func hues(characters: [ChatCharacter], colors: [String: NSColor]) -> [String: Double] {
        var result: [String: Double] = [:]
        for character in ChatCharacter.ordered(characters) {
            guard let color = colors[character.id]?.usingColorSpace(.sRGB) else { continue }
            var h: CGFloat=0, s: CGFloat=0, b: CGFloat=0, a: CGFloat=0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            var candidate = Double(h)*360
            var assigned = false
            // Nine distinct +40° positions. If a very large set exhausts them, use a free gap or gray.
            for _ in 0..<9 {
                if result.values.allSatisfy({ distance(candidate,$0) >= 25-0.000001 }) { assigned = true; break }
                candidate = (candidate+40).truncatingRemainder(dividingBy: 360)
            }
            if !assigned {
                if let free = (0..<360).map(Double.init).first(where: { value in result.values.allSatisfy { distance(value,$0) >= 25 } }) { candidate = free; assigned = true }
            }
            if assigned { result[character.id] = candidate }
        }
        return result
    }
    static func make(hue: Double?, dark: Bool) -> CharacterPalette {
        let foreground: PaletteRGB = dark ? .white : .black
        var lightness = dark ? 0.28 : 0.91
        var background = hue.map { PaletteRGB.hsl($0,dark ? 0.5 : 0.6,lightness) } ?? PaletteRGB(r:dark ? 0.26 : 0.93,g:dark ? 0.26 : 0.93,b:dark ? 0.26 : 0.93)
        while PaletteRGB.contrast(background,foreground) < 4.5 {
            lightness += dark ? -0.01 : 0.01
            background = PaletteRGB.hsl(hue ?? 0,hue == nil ? 0 : (dark ? 0.5 : 0.6),min(1,max(0,lightness)))
        }
        // Worst wallpaper at the supported minimum 55% chat tint. Brighter/darker tint only improves this.
        let worst = dark ? 1-BubbleOpacity.range.lowerBound/100 : BubbleOpacity.range.lowerBound/100
        let backdrop = PaletteRGB(r:worst,g:worst,b:worst)
        var nameLightness = dark ? 0.84 : 0.20
        var name = hue.map { PaletteRGB.hsl($0,0.65,nameLightness) } ?? foreground
        while PaletteRGB.contrast(name,backdrop) < 4.5 {
            nameLightness += dark ? 0.005 : -0.005
            name = PaletteRGB.hsl(hue ?? 0,hue == nil ? 0 : 0.65,min(1,max(0,nameLightness)))
        }
        // Keep a distinct sky-blue hue, adjusting brightness for readable text on each bubble.
        var linkLightness = dark ? 0.78 : 0.32
        var link = PaletteRGB.hsl(200, 0.9, linkLightness)
        while PaletteRGB.contrast(background, link) < 4.5 {
            linkLightness += dark ? 0.005 : -0.005
            link = PaletteRGB.hsl(200, 0.9, min(1, max(0, linkLightness)))
        }
        return CharacterPalette(background:background,foreground:foreground,name:name,link:link,hue:hue)
    }
}
