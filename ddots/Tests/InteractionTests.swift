import Foundation
import CoreGraphics

@main
struct InteractionTests {
    static var passed = 0
    static func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        guard condition() else { fputs("FAIL: \(description)\n", stderr); exit(1) }
        passed += 1
    }
    static func main() {
        let sprite = CGRect(x: 200, y: 200, width: 80, height: 90)
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        var pointer = PetPointerInteraction()
        func move(_ point: CGPoint, _ time: Double, enabled: Bool = true, reduced: Bool = false) -> PetPointerInteraction.Phase {
            pointer.update(pointer: point, sprite: sprite, display: display, now: time, enabled: enabled, reducedMotion: reduced)
        }
        let inside = CGPoint(x: 230, y: 230), outside = CGPoint(x: 1500, y: 800)
        check(move(outside, 0) == .inactive, "proximity alone does not arm")
        check(move(inside, 1) == .jumping(0), "entry starts exactly one jump")
        check(move(outside, 1.5) == .jumping(0.5), "jump finishes even when cursor leaves sprite")
        check(move(outside, 1 + PetPointerInteraction.jumpDuration) == .looking, "one full cycle then look")
        check(move(inside, 2) == .looking, "reentry while tracking never repeats jump")
        check(move(outside, 11.9) == .looking, "reentry refreshes ten second timer")
        check(move(outside, 12) == .inactive, "tracking expires at ten seconds")
        check(move(inside, 13) == .jumping(0), "fresh interaction can greet again")
        check(move(inside, 23) == .inactive && move(inside, 24) == .inactive, "stationary hover never loops or rearms")
        _ = move(outside, 25)
        check(move(inside, 26, reduced: true) == .looking, "reduce motion skips jump")
        check(move(CGPoint(x: -1, y: 200), 27) == .inactive, "leaving pet display cancels")
        check(move(inside, 28) == .jumping(0), "new display entry can greet")
        check(move(inside, 29, enabled: false) == .inactive, "drag or pause cancels interaction")
        for scale in [0.25, 0.39, 1, 2] {
            var small = PetPointerInteraction()
            let rect = CGRect(x: -1000, y: -200, width: 160 * scale, height: 160 * scale)
            let screen = CGRect(x: -1920, y: -1080, width: 1920, height: 1080)
            check(small.update(pointer: CGPoint(x: rect.midX, y: rect.midY), sprite: rect, display: screen, now: 0) == .jumping(0), "scaled entry on negative monitor")
            check(small.update(pointer: CGPoint(x: -1800, y: -900), sprite: rect, display: screen, now: 1) == .looking, "dot has no artificial radius at any scale")
        }

        let date = Date()
        let target = ScreenTarget(appName: "ddots", windowTitle: "AI 작업")
        func focus(_ id: String, _ started: Double?, _ expiry: Double = 60, target: ScreenTarget? = nil) -> ScreenFocus {
            ScreenFocus(taskID: id, turnID: "t1", provider: id == "first" ? .claude : .codex,
                        taskStartedAt: started.map { date.addingTimeInterval($0) }, firstObservedAt: date,
                        expiresAt: date.addingTimeInterval(expiry), target: target)
        }
        let first = focus("first", -100, target: target), later = focus("later", -50)
        check(ScreenFocus.select([later, first], now: date)?.taskID == "first", "overall task start beats screen call order")
        check(ScreenFocus.select([first, later], now: date)?.taskID == "first", "input ordering is irrelevant")
        check(ScreenFocus.select([focus("first", -100), focus("later", -50, target: target)], now: date)?.target == nil, "unknown target never steals another task window")
        check(ScreenFocus.select([focus("first", -100, -1), later], now: date)?.taskID == "later", "expired first task hands off")
        check(ScreenFocus.select([], now: date) == nil, "no active screen task clears focus")
        check(ScreenFocus.select([focus("b", -100), focus("a", -100)], now: date)?.taskID == "a", "deterministic equal-start tie")
        check(ScreenFocus.select([focus("unknown", nil)], now: date)?.taskStartedAt == nil, "partial transcript does not invent a start time")

        let output: [[String: Any]] = [["type": "input_text", "text": "Window: \"AI 작업\", App: ddots.\nPRIVATE BODY"], ["type": "image", "data": "PRIVATE IMAGE"]]
        check(ScreenTarget.fromOutput(output) == target, "observation header preserves dots in app name")
        check(ScreenTarget.fromOutput("PRIVATE BODY") == nil, "arbitrary output is not a target")
        check(ScreenTarget.fromOutput("Window: \"a\", App: A.\nWindow: \"b\", App: B.") == nil, "multi-app observation is ambiguous")
        let rect = CGRect(x: -800, y: 80, width: 600, height: 400)
        let a = ScreenWindow(id: 1, appName: "ddots", title: "AI 작업", bounds: rect)
        let b = ScreenWindow(id: 2, appName: "ddots", title: "옵션", bounds: rect)
        let hiddenTitle = ScreenWindow(id: 3, appName: "ddots", title: nil, bounds: rect)
        check(ScreenWindowSelection.select(target: target, windows: [b, a])?.id == 1, "exact title beats frontmost window")
        check(ScreenWindowSelection.select(target: target, windows: [b]) == nil, "closed target does not switch to another title")
        check(ScreenWindowSelection.select(target: target, windows: [hiddenTitle])?.id == 3, "unique app window works when macOS omits titles")
        check(ScreenWindowSelection.select(target: target, windows: [hiddenTitle, b]) == nil, "missing title and multiple windows stays unknown")
        check(ScreenWindowSelection.select(target: ScreenTarget(appName: "ddots", windowTitle: nil), windows: [a,b]) == nil, "app alone never guesses among windows")
        let converted = ScreenWindowSelection.appKitBounds(rect, primaryTop: 1080)
        check(converted.minX == -800 && converted.minY == 600, "Quartz to AppKit coordinates across displays")
        print("PASS: \(passed) cursor, focus and window checks")
    }
}
