import Foundation
import CoreGraphics

struct ScreenTarget: Codable, Equatable {
    let appName: String
    let windowTitle: String?
    enum Observation { case absent, known(ScreenTarget), ambiguous }

    static func fromOutput(_ output: Any?) -> ScreenTarget? {
        if case .known(let target) = observation(from: output) { return target }
        return nil
    }

    /// Only a screen tool's observation header is read; body text and images are never retained.
    static func observation(from output: Any?) -> Observation {
        let texts: [String]
        if let string = output as? String { texts = [string] }
        else if let blocks = output as? [[String: Any]] {
            texts = blocks.prefix(16).compactMap { block in
                ["text", "input_text"].contains(block["type"] as? String ?? "") ? block["text"] as? String : nil
            }
        } else { return .absent }
        let pattern = #"^Window: "(.*)", App: (.+)\.$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return .absent }
        var targets: [ScreenTarget] = []
        for text in texts {
            let header = String(text.prefix(16384)) as NSString
            for match in regex.matches(in: header as String, range: NSRange(location: 0, length: header.length)) {
                let app = header.substring(with: match.range(at: 2))
                let title = header.substring(with: match.range(at: 1))
                guard !app.isEmpty, app.count <= 200, title.count <= 500 else { continue }
                let target = ScreenTarget(appName: app, windowTitle: title.isEmpty ? nil : title)
                if !targets.contains(target) { targets.append(target) }
            }
        }
        if targets.count == 1 { return .known(targets[0]) }
        return targets.isEmpty ? .absent : .ambiguous
    }
}

struct ScreenFocus: Codable, Equatable {
    let taskID: String
    let turnID: String
    let provider: Provider
    let taskStartedAt: Date?
    let firstObservedAt: Date
    let expiresAt: Date
    let target: ScreenTarget?

    static func select(_ candidates: [ScreenFocus], now: Date) -> ScreenFocus? {
        candidates.filter { $0.expiresAt > now }.min {
            let left = $0.taskStartedAt ?? $0.firstObservedAt
            let right = $1.taskStartedAt ?? $1.firstObservedAt
            if left != right { return left < right }
            return ($0.taskID + ":" + $0.turnID) < ($1.taskID + ":" + $1.turnID)
        }
    }
}

struct ScreenWindow {
    let id: UInt32
    let appName: String
    let title: String?
    let bounds: CGRect
}

enum ScreenWindowSelection {
    static func select(target: ScreenTarget, windows: [ScreenWindow]) -> ScreenWindow? {
        let matches = windows.filter { $0.appName == target.appName }
        if let title = target.windowTitle {
            let exact = matches.filter { $0.title == title }
            if exact.count == 1 { return exact[0] }
            // macOS may omit titles without Screen Recording permission. Only one window is unambiguous.
            if exact.isEmpty, matches.count == 1, matches[0].title == nil { return matches[0] }
            return nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func appKitBounds(_ quartz: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: quartz.minX, y: primaryTop - quartz.maxY, width: quartz.width, height: quartz.height)
    }
}
