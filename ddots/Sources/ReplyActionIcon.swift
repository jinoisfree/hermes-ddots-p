import SwiftUI

/// Shared 24-unit geometry gives ○, ×, pen and ✓ the same optical size and stroke.
struct ReplyActionGlyph: Shape {
    let word: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        switch word {
        case "승인": p.addEllipse(in: CGRect(x: 4, y: 4, width: 16, height: 16))
        case "거절":
            p.move(to: CGPoint(x: 4, y: 4)); p.addLine(to: CGPoint(x: 20, y: 20))
            p.move(to: CGPoint(x: 20, y: 4)); p.addLine(to: CGPoint(x: 4, y: 20))
        case "의견":
            p.move(to: CGPoint(x: 4, y: 20)); p.addLine(to: CGPoint(x: 5, y: 14))
            p.addLine(to: CGPoint(x: 15, y: 4)); p.addLine(to: CGPoint(x: 20, y: 9))
            p.addLine(to: CGPoint(x: 10, y: 19)); p.closeSubpath()
            p.move(to: CGPoint(x: 13, y: 6)); p.addLine(to: CGPoint(x: 18, y: 11))
        default:
            p.move(to: CGPoint(x: 4, y: 12)); p.addLine(to: CGPoint(x: 10, y: 18)); p.addLine(to: CGPoint(x: 20, y: 6))
        }
        return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

struct ReplyActionLabel: View {
    let word: String
    var symbol: String? = nil
    var body: some View {
        Group {
            if ["승인", "거절", "의견", "확인"].contains(word) {
                ReplyActionGlyph(word: word).stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 16)
            } else if let symbol { Image(systemName: symbol).font(.system(size: 14)).frame(width: 16, height: 16) }
            else { Text(word).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10) }
        }.frame(minWidth: 36, minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18), lineWidth: 1))
    }
}
