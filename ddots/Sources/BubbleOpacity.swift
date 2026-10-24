import Foundation

/// A tint laid over the glass so text stays readable on bright or busy wallpapers.
enum BubbleOpacity {
    static let settingsKey = "chatOpacity"
    static let defaultPercent = 65.0
    /// Below 55% the worst case (white wallpaper behind white text) drops under a 4.5:1 contrast ratio.
    static let range = 55.0...100.0
    static let collapsed = 0.35

    static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value.rounded())) : defaultPercent
    }

    static func load(from defaults: UserDefaults = .standard) -> Double {
        defaults.object(forKey: settingsKey) == nil ? defaultPercent : clamped(defaults.double(forKey: settingsKey))
    }

    /// Progress 0 is the status bubble, 1 the full conversation, so the tint deepens while the glass grows.
    static func alpha(progress: Double, percent: Double, reduceTransparency: Bool) -> Double {
        if reduceTransparency { return 1 }
        let fraction = min(1, max(0, progress.isFinite ? progress : 0))
        return collapsed + (clamped(percent) / 100 - collapsed) * fraction
    }

    /// Light text on a dark tint over a white wallpaper, or dark text on a light tint over a black one.
    static func worstContrast(alpha: Double, darkAppearance: Bool) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let background = linear(darkAppearance ? 1 - alpha : alpha)
        return darkAppearance ? 1.05 / (background + 0.05) : (background + 0.05) / 0.05
    }
}
