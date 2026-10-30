import Foundation

/// Sizes the content independently of AppKit's current display configuration.
enum OptionsLayout {
    static let contentHeight: CGFloat = 640
    static let screenMargin: CGFloat = 16

    static func viewportHeight(visibleHeight: CGFloat, titleBarHeight: CGFloat) -> CGFloat {
        min(contentHeight, max(0, visibleHeight - titleBarHeight - screenMargin * 2))
    }
}
