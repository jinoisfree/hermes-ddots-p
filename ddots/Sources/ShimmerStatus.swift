import SwiftUI

/// A moving highlight clipped to stable glyphs; it never changes text layout.
struct ShimmerStatus: View {
    let text: String
    let color: Color
    let active: Bool
    private var label: some View {
        Text(text).font(.system(size: ChatMetrics.auxiliaryFont)).lineLimit(1).truncationMode(.middle)
    }
    var body: some View {
        label.foregroundColor(color).overlay {
            if active {
                GeometryReader { geometry in
                    TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                        let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8
                        LinearGradient(colors: [.clear, .primary.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: max(36, geometry.size.width * 0.35))
                            .offset(x: (geometry.size.width + 100) * phase - 60)
                    }.mask(label.frame(maxWidth: .infinity, alignment: .leading)).allowsHitTesting(false)
                }
            }
        }.accessibilityLabel(text)
    }
}
