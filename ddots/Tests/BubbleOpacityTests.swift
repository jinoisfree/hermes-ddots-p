import Foundation

@main
struct BubbleOpacityTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        passed += 1
    }
    static func main() {
        check(BubbleOpacity.defaultPercent == 65, "default is 65 percent")
        for percent in stride(from: BubbleOpacity.range.lowerBound, through: BubbleOpacity.range.upperBound, by: 1) {
            let alpha = BubbleOpacity.alpha(progress: 1, percent: percent, reduceTransparency: false)
            check(BubbleOpacity.worstContrast(alpha: alpha, darkAppearance: true) >= 4.5, "dark text contrast at \(percent)%")
            check(BubbleOpacity.worstContrast(alpha: alpha, darkAppearance: false) >= 4.5, "light text contrast at \(percent)%")
        }
        check(BubbleOpacity.worstContrast(alpha: 0.5, darkAppearance: true) < 4.5, "the lower bound is where contrast starts failing")
        check(BubbleOpacity.clamped(10) == 55 && BubbleOpacity.clamped(140) == 100 && BubbleOpacity.clamped(.nan) == 65 && BubbleOpacity.clamped(70.4) == 70, "slider values are clamped and rounded")
        check(BubbleOpacity.alpha(progress: 0, percent: 65, reduceTransparency: false) == BubbleOpacity.collapsed, "status bubble keeps its light tint")
        check(abs(BubbleOpacity.alpha(progress: 1, percent: 65, reduceTransparency: false) - 0.65) < 1e-9, "open conversation uses the chosen opacity")
        let half = BubbleOpacity.alpha(progress: 0.5, percent: 65, reduceTransparency: false)
        check(half > BubbleOpacity.collapsed && half < 0.65, "tint deepens while the bubble grows")
        check(BubbleOpacity.alpha(progress: -3, percent: 65, reduceTransparency: false) == BubbleOpacity.collapsed
              && abs(BubbleOpacity.alpha(progress: 9, percent: 65, reduceTransparency: false) - 0.65) < 1e-9, "progress is clamped")
        check(BubbleOpacity.alpha(progress: 0, percent: 55, reduceTransparency: true) == 1, "reduce transparency is fully opaque")
        let suite = "ddots-opacity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        check(BubbleOpacity.load(from: defaults) == 65, "unset preference uses the default")
        defaults.set(20, forKey: BubbleOpacity.settingsKey)
        check(BubbleOpacity.load(from: defaults) == 55, "stored values are clamped on load")
        defaults.removePersistentDomain(forName: suite)
        print("PASS: \(passed) opacity, contrast, morph tint and reduce transparency checks")
    }
}
