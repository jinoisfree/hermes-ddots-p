import Foundation
import CoreGraphics

enum PetAnimation: Int, CaseIterable {
    case idle = 0, right, left, waving, jumping, failed, waiting, running, replyWaiting

    init(state: WorkState) { self = PetAnimation(rawValue: state.row) ?? .idle }
    var name: String {
        ["쉬는 중", "오른쪽 이동", "왼쪽 이동", "손 흔들기", "점프", "오류", "승인 대기 · 폰 흔들기", "작업 중", "응답 대기 · 컴퓨터"][rawValue]
    }
    var allowsLook: Bool { self == .idle || self == .running || self == .waving }
    var repeatsWhileActive: Bool { self == .waiting || self == .replyWaiting }
}

struct PetAnimationFrame: Equatable {
    let row: Int
    let column: Int
}

/// Transient actions return to idle after three passes; approval and reply waits keep moving.
enum PetAnimationTimeline {
    private static let idleDurations: [Double] = [0.280, 0.110, 0.110, 0.140, 0.140, 0.320]

    private static let durationsByAnimation: [[Double]] = PetAnimation.allCases.map { animation in
        switch animation {
        case .idle: return idleDurations.map { $0 * 6 }
        case .right, .left: return Array(repeating: 0.120, count: 7) + [0.220]
        case .running: return Array(repeating: 0.120, count: 5) + [0.220]
        case .waving: return Array(repeating: 0.140, count: 3) + [0.280]
        case .jumping: return Array(repeating: 0.140, count: 4) + [0.280]
        case .failed: return Array(repeating: 0.140, count: 7) + [0.240]
        case .waiting: return Array(repeating: 0.120, count: 8)
        case .replyWaiting: return Array(repeating: 0.150, count: 5) + [0.280]
        }
    }

    static func frame(for animation: PetAnimation, elapsed: TimeInterval,
                      reducedMotion: Bool = false, loop: Bool = false) -> PetAnimationFrame {
        if reducedMotion { return PetAnimationFrame(row: animation.rawValue, column: 0) }
        let durations = durationsByAnimation[animation.rawValue]
        let cycle = durations.reduce(0, +)
        let time = max(0, elapsed.isFinite ? elapsed : 0)
        if animation != .idle && !animation.repeatsWhileActive && !loop && time >= cycle * 3 {
            return frame(for: .idle, elapsed: time - cycle * 3)
        }
        var remaining = time.truncatingRemainder(dividingBy: cycle)
        for (column, duration) in durations.enumerated() {
            if remaining < duration { return PetAnimationFrame(row: animation.rawValue, column: column) }
            remaining -= duration
        }
        return PetAnimationFrame(row: animation.rawValue, column: durations.count - 1)
    }

    /// AppKit global screen coordinates are bottom-up. Index 0 points up; clockwise in 22.5° steps.
    static func lookFrame(from origin: CGPoint, toward target: CGPoint, previous: PetAnimationFrame? = nil) -> PetAnimationFrame? {
        let dx = target.x - origin.x, dy = target.y - origin.y
        guard dx.isFinite, dy.isFinite else { return nil }
        let previousLook = previous.flatMap { (9...10).contains($0.row) && (0..<8).contains($0.column) ? $0 : nil }
        guard hypot(dx, dy) > 1 else { return previousLook }
        let angle = (atan2(dx, dy) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        if let previousLook {
            let center = Double((previousLook.row - 9) * 8 + previousLook.column) * 22.5
            let distance = (angle - center + 540).truncatingRemainder(dividingBy: 360) - 180
            // A small angular margin prevents noisy boundary crossings from flickering between poses.
            if abs(distance) <= 13.25 { return previousLook }
        }
        let direction = Int((angle / 22.5).rounded()) % 16
        return PetAnimationFrame(row: 9 + direction / 8, column: direction % 8)
    }

    static func dragAnimation(horizontalDelta: CGFloat, previous: PetAnimation = .right) -> PetAnimation {
        abs(horizontalDelta) < 0.5 ? previous : horizontalDelta < 0 ? .left : .right
    }

    /// Nodding off is the idle pose with only its head changing: eyes open, one closing, then both shut while the head
    /// nods forward three times and a z rises with each, then a start awake.
    static let dozeRow = 11
    /// Which drawing each step shows (0 eyes open, 1 one shut, 2 both shut, 3 and 4 the head lower and lowest), for how long, with how many z's.
    static let dozeSteps: [(image: Int, seconds: Double, zs: Int)] =
        [(0, 0.900, 0), (1, 0.450, 0)] + (1...3).flatMap { [(2, 0.600, $0), (3, 0.200, $0), (4, 0.440, $0), (3, 0.200, $0)] } + [(1, 0.150, 0)]
    static let dozeCycle = dozeSteps.reduce(0) { $0 + $1.seconds }
    /// With motion turned down the pet simply sleeps: the last step with its head up and all three z's.
    static let dozeStill = dozeSteps.lastIndex { $0.image == 2 } ?? 0
    static func dozeFrame(elapsed: TimeInterval, reducedMotion: Bool = false) -> PetAnimationFrame {
        if reducedMotion { return PetAnimationFrame(row: dozeRow, column: dozeStill) }
        var remaining = max(0, elapsed.isFinite ? elapsed : 0).truncatingRemainder(dividingBy: dozeCycle)
        for (column, step) in dozeSteps.enumerated() {
            if remaining < step.seconds { return PetAnimationFrame(row: dozeRow, column: column) }
            remaining -= step.seconds
        }
        return PetAnimationFrame(row: dozeRow, column: dozeSteps.count - 1)
    }
    /// The z's over a doze frame, each as the square it is written in, measured in the sprite cell from its top-left corner.
    static func dozeZs(column: Int) -> [CGRect] {
        guard dozeSteps.indices.contains(column) else { return [] }
        let start = CGPoint(x: 132, y: 56)
        return (0..<dozeSteps[column].zs).map { index in
            let size: CGFloat = [6, 8, 10.5][index]
            return CGRect(x: start.x + [0, 9.5, 21.5][index], y: start.y - [0, 12.5, 27.5][index], width: size, height: size)
        }
    }
}

/// The pet nods off once nothing has happened for a while, and anything happening wakes it.
struct PetDoze {
    static let delay: TimeInterval = 180
    private var quietSince: TimeInterval?
    /// `quiet` means the pet is idle with nothing to look at or react to. Returns how long it has been dozing.
    mutating func update(now: TimeInterval, quiet: Bool, after delay: TimeInterval = PetDoze.delay) -> TimeInterval? {
        guard quiet else { quietSince = nil; return nil }
        let since = quietSince ?? now
        quietSince = since
        return now - since >= delay ? now - since - delay : nil
    }
}

/// One shared jump for both a reply and pointer entry, never restarting an in-flight jump.
struct PetChatPlayback {
    static let jumpDuration: TimeInterval = 0.84
    private var started: TimeInterval?
    private var previousPointerElapsed: TimeInterval?
    mutating func update(now: TimeInterval, reply: Bool, pointerElapsed: TimeInterval?, enabled: Bool) -> TimeInterval? {
        let pointerStarted = pointerElapsed != nil && (previousPointerElapsed == nil || pointerElapsed! < previousPointerElapsed!)
        previousPointerElapsed = pointerElapsed
        guard enabled else { started = nil; return nil }
        if let start = started, now-start >= Self.jumpDuration { started = nil }
        if started == nil && (reply || pointerStarted) { started = now - (pointerStarted && !reply ? pointerElapsed! : 0) }
        guard let start = started, now-start < Self.jumpDuration else { return nil }
        return max(0,now-start)
    }
    static func animation(state: WorkState, typing: Bool, jumping: Bool, drag: PetAnimation?, preview: PetAnimation?) -> PetAnimation {
        if let preview { return preview }
        if let drag { return drag }
        if state == .waiting || state == .failed { return PetAnimation(state: state) }
        if jumping { return .jumping }
        return typing ? .replyWaiting : PetAnimation(state: state)
    }
}

/// What the pet at the top of ddots is doing. Kept apart from the view so the order of things can be tested.
struct ChatPetBehavior {
    enum Pose: Equatable { case idle, look, replyWaiting, approval, wave, jump }
    /// One pass of the wave, the same length the big pet's takes.
    static let waveDuration: TimeInterval = 0.140 * 3 + 0.280
    private var playback = PetChatPlayback()
    private var wasTouching = false
    private var waveStarted: TimeInterval?
    private(set) var pose = Pose.idle
    private(set) var started: TimeInterval = 0

    mutating func reset() { self = ChatPetBehavior() }

    /// `hop` asks for one jump (an answer landed), `wave` for one wave (a message went out).
    /// A hop also follows the cursor touching the pet. While the cursor is over the conversation the pet turns to it.
    /// Returns how long the pose shown has been playing.
    mutating func update(now: TimeInterval, touching: Bool, cursorNear: Bool, writing: Bool, hop: Bool, wave: Bool, approval: Bool = false) -> TimeInterval {
        let touched = touching && !wasTouching
        wasTouching = touching
        if wave { waveStarted = now }
        if let began = waveStarted, now - began >= Self.waveDuration { waveStarted = nil }
        if approval { waveStarted = nil }
        let jump = playback.update(now: now, reply: hop || touched, pointerElapsed: nil, enabled: !approval)
        let next: Pose = approval ? .approval : jump != nil ? .jump : writing ? .replyWaiting : waveStarted != nil ? .wave : cursorNear ? .look : .idle
        if next != pose { pose = next; started = next == .wave ? (waveStarted ?? now) : now }
        return jump ?? (now - started)
    }
}
