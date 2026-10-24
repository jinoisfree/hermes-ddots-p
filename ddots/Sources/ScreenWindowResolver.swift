import AppKit

/// Reads public window geometry only. No screenshots, accessibility control or private AI APIs.
final class ScreenWindowResolver {
    private var lastFocus: ScreenFocus?
    private var refreshedAt = -Double.infinity
    private var point: CGPoint?

    func resolve(_ focus: ScreenFocus?, now: TimeInterval) -> CGPoint? {
        guard let focus, focus.expiresAt > Date(), let target = focus.target else {
            lastFocus = nil; point = nil; return nil
        }
        if focus == lastFocus, now - refreshedAt < 0.2 { return point }
        lastFocus = focus; refreshedAt = now; point = nil
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return nil }
        let windows = list.compactMap { info -> ScreenWindow? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let raw = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: raw), rect.width > 1, rect.height > 1 else { return nil }
            return ScreenWindow(id: id, appName: owner, title: info[kCGWindowName as String] as? String,
                                bounds: ScreenWindowSelection.appKitBounds(rect, primaryTop: top))
        }
        if let window = ScreenWindowSelection.select(target: target, windows: windows) {
            point = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        }
        return point
    }
}
