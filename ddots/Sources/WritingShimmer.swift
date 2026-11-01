import SwiftUI

/// A soft band travels beyond both edges before repeating; no clock or retained animation state.
enum WritingShimmer {
    static let period: TimeInterval = 1.8
    static let bandWidth = 0.28

    /// Band centre in text-width units. nil means there is no highlight to draw.
    static func phase(at time: TimeInterval, reduceMotion: Bool) -> Double? {
        guard !reduceMotion else { return nil }
        let elapsed = time - floor(time / period) * period
        return -bandWidth / 2 + elapsed / period * (1 + bandWidth)
    }
}

private struct WritingShimmerModifier: ViewModifier {
    let date: Date?
    let reduceMotion: Bool
    let highlight: Color

    func body(content: Content) -> some View {
        content.overlay {
            if let date, let phase = WritingShimmer.phase(at: date.timeIntervalSinceReferenceDate, reduceMotion: reduceMotion) {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, highlight, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * WritingShimmer.bandWidth, height: geometry.size.height)
                        .offset(x: geometry.size.width * (phase - WritingShimmer.bandWidth / 2))
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
                        .mask(content.accessibilityHidden(true))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func writingShimmer(at date: Date?, reduceMotion: Bool, highlight: Color) -> some View {
        modifier(WritingShimmerModifier(date: date, reduceMotion: reduceMotion, highlight: highlight))
    }
}

/// Six positions around the 2×3 cell, clockwise; the head leaves a fading three-dot tail.
enum WritingSpinner {
    struct Position: Equatable {
        let column: Int
        let row: Int
    }
    static let positions: [Position] = [
        .init(column: 0, row: 0), .init(column: 1, row: 0),
        .init(column: 1, row: 1), .init(column: 1, row: 2),
        .init(column: 0, row: 2), .init(column: 0, row: 1)
    ]
    static let stepDuration: TimeInterval = 0.16
    private static let tail = [1.0, 0.7, 0.5, 0.35]

    /// Levels follow the position table. Reducing motion fixes the head at the upper-left dot.
    static func levels(at time: TimeInterval, reduceMotion: Bool) -> [Double] {
        let count = positions.count
        let head = reduceMotion ? 0 : (Int(floor(time / stepDuration)) % count + count) % count
        return positions.indices.map { index in
            let age = (head - index + count) % count
            return age < tail.count ? tail[age] : 0
        }
    }
}
