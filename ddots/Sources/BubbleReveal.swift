import Foundation

/// When the folded bubble is on screen. It is put away by default and comes out for as long as the pointer is on the pet,
/// or for a moment when something asks for attention.
struct BubbleReveal {
    static let alertStay: TimeInterval = 3
    static let settingsKey = "bubbleAlwaysShown"
    private var until: TimeInterval = -.infinity
    mutating func alert(now: TimeInterval) { until = max(until, now + Self.alertStay) }
    /// `held` is anything that keeps it out for as long as it lasts: the pointer on it, the conversation open, a preview.
    func update(now: TimeInterval, held: Bool) -> Bool {
        held || now < until
    }
}
