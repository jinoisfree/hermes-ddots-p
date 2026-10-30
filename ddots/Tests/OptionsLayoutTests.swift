import Foundation

@main
struct OptionsLayoutTests {
    static func main() {
        let titleBar: CGFloat = 28
        for screen: CGFloat in [650, 700, 1000] {
            let height = OptionsLayout.viewportHeight(visibleHeight: screen, titleBarHeight: titleBar)
            precondition(height + titleBar + OptionsLayout.screenMargin * 2 <= screen)
            precondition(height > 0 && height <= OptionsLayout.contentHeight)
        }
        precondition(OptionsLayout.viewportHeight(visibleHeight: 700, titleBarHeight: titleBar) == 640)
        precondition(OptionsLayout.viewportHeight(visibleHeight: 1000, titleBarHeight: titleBar) == 640)
        precondition(OptionsLayout.viewportHeight(visibleHeight: 20, titleBarHeight: titleBar) == 0)
        print("OptionsLayoutTests passed (9 checks, 0 failures)")
    }
}
