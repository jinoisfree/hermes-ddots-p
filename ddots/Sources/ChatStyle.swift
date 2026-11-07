import AppKit

/// A local preference; nil appearance follows macOS automatically.
enum ChatTheme: String, CaseIterable {
    case system, light, dark
    static let settingsKey = "chatTheme"
    static func load(_ defaults: UserDefaults = .standard) -> ChatTheme {
        ChatTheme(rawValue: defaults.string(forKey: settingsKey) ?? "") ?? .system
    }
    var title: String {
        switch self { case .system: return "시스템 설정"; case .light: return "라이트 모드"; case .dark: return "다크 모드" }
    }
    var appearance: NSAppearance? {
        switch self { case .system: return nil; case .light: return NSAppearance(named: .aqua); case .dark: return NSAppearance(named: .darkAqua) }
    }
}

/// These two preferences stay on this Mac, outside the relay settings store.
enum ChatAppearance {
    static let colorKey = "chatUserBubbleColor"
    static let fontKey = "chatBodyFontSize"
    static var preferences = UserDefaults.standard
    static var transient = false
    static func store(_ value: Any, key: String, defaults: UserDefaults) {
        if transient && defaults === preferences {
            var domain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            domain[key] = value; defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
        } else { defaults.set(value, forKey: key) }
    }
    static var revision: UInt64 = 0
    static let didChange = Notification.Name("ddots.chatAppearanceChanged")
    static let fontSizes: [CGFloat] = [12, 13, 14, 15, 16, 18, 20]
    static func fontSize(_ defaults: UserDefaults = preferences) -> CGFloat {
        let value = CGFloat(defaults.double(forKey: fontKey))
        return fontSizes.contains(value) ? value : 14
    }
    static func color(_ defaults: UserDefaults = preferences) -> UserBubbleColor {
        UserBubbleColor(rawValue: defaults.string(forKey: colorKey) ?? "") ?? .blue
    }
    static func setFontSize(_ value: CGFloat, defaults: UserDefaults = preferences) {
        store(fontSizes.contains(value) ? Double(value) : 14, key: fontKey, defaults: defaults)
        revision &+= 1
        NotificationCenter.default.post(name: didChange, object: nil)
    }
    static func setColor(_ value: UserBubbleColor, defaults: UserDefaults = preferences) {
        store(value.rawValue, key: colorKey, defaults: defaults)
        revision &+= 1
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

enum UserBubbleColor: String, CaseIterable {
    case blue, indigo, purple, pink, red, orange, yellow, green, mint, teal, cyan, brown, gray, lightGray
    var title: String {
        switch self {
        case .blue: return "기본"; case .indigo: return "남색"; case .purple: return "보라"
        case .pink: return "분홍"; case .red: return "빨강"; case .orange: return "주황"
        case .yellow: return "노랑"; case .green: return "초록"; case .mint: return "민트"
        case .teal: return "청록"; case .cyan: return "하늘"; case .brown: return "갈색"
        case .gray: return "회색"; case .lightGray: return "밝은 회색"
        }
    }
    private var systemColor: NSColor {
        switch self {
        case .blue: return .systemBlue; case .indigo: return .systemIndigo
        case .purple: return .systemPurple; case .pink: return .systemPink
        case .red: return .systemRed; case .orange: return .systemOrange
        case .yellow: return .systemYellow; case .green: return .systemGreen
        case .mint: return .systemMint; case .teal: return .systemTeal
        case .cyan: return .systemCyan; case .brown: return .systemBrown
        case .gray: return .systemGray
        // A fixed sRGB 82% gray stays visibly distinct from the light conversation surface.
        case .lightGray: return NSColor(srgbRed: 0.82, green: 0.82, blue: 0.82, alpha: 1)
        }
    }
    func resolved(dark: Bool) -> PaletteRGB {
        var rgb = PaletteRGB.black
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let color = systemColor.usingColorSpace(.sRGB)!
            rgb = PaletteRGB(r: Double(color.redComponent), g: Double(color.greenComponent), b: Double(color.blueComponent))
        }
        // Keep systemBlue's hue and saturation; lower HSV brightness only as far
        // as necessary for white text, with a 4.55 margin for 8-bit rounding. Scaling sRGB channels preserves their ratios.
        if self == .blue, PaletteRGB.contrast(rgb, .white) < 4.55 {
            let source = rgb
            var low = 0.0, high = 1.0
            for _ in 0..<64 {
                let scale = (low + high) / 2
                let candidate = PaletteRGB(r: source.r * scale, g: source.g * scale, b: source.b * scale)
                if PaletteRGB.contrast(candidate, .white) >= 4.55 { low = scale } else { high = scale }
            }
            rgb = PaletteRGB(r: source.r * low, g: source.g * low, b: source.b * low)
        }
        return rgb
    }
}

/// Both renderers and the settings preview use these exact resolved colors.
struct UserBubblePalette {
    let background: PaletteRGB
    let foreground: PaletteRGB
    let alpha: Double
    let compositedBackground: PaletteRGB
    var link: PaletteRGB { foreground } // Links also carry an underline.
    var contrast: Double { PaletteRGB.contrast(compositedBackground, foreground) }
    init(color: UserBubbleColor = ChatAppearance.color(), dark: Bool, pending: Bool = false) {
        background = color.resolved(dark: dark)
        alpha = pending ? 0.6 : 1
        // Conversation surface reference used by the pending contrast contract.
        let surface = dark ? 0.15 : 0.93
        compositedBackground = PaletteRGB(r: background.r * alpha + surface * (1 - alpha),
            g: background.g * alpha + surface * (1 - alpha), b: background.b * alpha + surface * (1 - alpha))
        if color == .blue && !pending { foreground = .white }
        else {
            foreground = PaletteRGB.contrast(compositedBackground, .black) >= PaletteRGB.contrast(compositedBackground, .white) ? .black : .white
        }
    }
}

enum ChatMetrics {
    static let avatar: CGFloat = 34
    /// Corner radius of a character picture as a share of its side.
    static let avatarCorner: CGFloat = 0.24
    static let callerAvatar: CGFloat = 24
    static let notificationAvatar: CGFloat = 20
    static let thumbnailPixels = 64
    static let nameFont: CGFloat = 14
    static let auxiliaryFont: CGFloat = 11
    static var bodyFont: CGFloat { ChatAppearance.fontSize() }
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


/// Shared by native and SwiftUI thread renderers. Background tint lives below these
/// surfaces, so the opacity slider never fades text, controls or status colours.
enum ThreadAppearance {
    static let inset: CGFloat = 18
    static let radius: CGFloat = 16
    static let statusWidth: CGFloat = 4
    static func surface(dark: Bool) -> NSColor {
        dark ? NSColor(white: 0.15, alpha: 0.55) : NSColor.white.withAlphaComponent(0.38)
    }
    static func replySurface(dark: Bool) -> NSColor {
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.09 : 0.055)
    }
    /// Reports, lists, quotes, code and long prose keep the full reading width.
    static func isConversational(_ body: String) -> Bool {
        let lines = body.components(separatedBy: "\n")
        return !body.isEmpty && body.count <= 240 && lines.count <= 4 &&
            !lines.contains { line in
                let text = line.trimmingCharacters(in: .whitespaces)
                return ["```", "|", ">", "#", "- ", "* ", "•", "1."].contains { text.hasPrefix($0) }
            }
    }
}
