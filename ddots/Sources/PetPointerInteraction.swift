import Foundation
import CoreGraphics

/// Dot arms on entry and follows for ten seconds, without a distance radius.
/// The desktop equivalent of its host window is the display containing the pet.
struct PetPointerInteraction {
    static let trackingDuration: TimeInterval = 10
    static let jumpDuration: TimeInterval = 0.140 * 4 + 0.280
    enum Phase: Equatable { case inactive, jumping(TimeInterval), looking }
    private var wasInside = false
    private var jumpStarted: TimeInterval?
    private var trackingUntil: TimeInterval = -.infinity

    mutating func reset() {
        wasInside = false; jumpStarted = nil; trackingUntil = -.infinity
    }

    mutating func update(pointer: CGPoint, sprite: CGRect, display: CGRect, now: TimeInterval,
                         enabled: Bool = true, reducedMotion: Bool = false) -> Phase {
        guard enabled, pointer.x.isFinite, pointer.y.isFinite, display.contains(pointer) else {
            reset(); return .inactive
        }
        let inside = sprite.contains(pointer)
        if inside && !wasInside {
            if now >= trackingUntil { jumpStarted = now }
            trackingUntil = now + Self.trackingDuration
        }
        wasInside = inside
        guard now < trackingUntil else { return .inactive }
        if !reducedMotion, let start = jumpStarted, now - start < Self.jumpDuration {
            return .jumping(max(0, now - start))
        }
        return .looking
    }
}
