import Foundation

/// Screen-only, bounded copy feedback. Never feed this text to a conversation or diagnostics.
struct ClipboardCopyNotice {
    static let duration: TimeInterval = 4
    static let transition: TimeInterval = 0.25
    struct Frame {
        var text: String
        var previous: String?
        var alpha: Double
        var previousAlpha: Double
        var offset: Double
    }
    private var text: String?
    private var previous: String?
    private var previousAlpha = 0.0
    private var previousOffset = -4.0
    private var began: TimeInterval = 0

    static func message(_ entry: ClipboardEntry) -> String {
        let name = Self.name(entry)
        let ending = entry.kind == .text && !entry.secret && name.first == "“" ? String(name.dropFirst().dropLast()) : name
        return name + particle(ending) + " 복사되었습니다"
    }
    static func name(_ entry: ClipboardEntry) -> String {
        if entry.secret { return "비밀 항목" }
        switch entry.kind {
        case .text:
            let clean = (entry.text ?? "").components(separatedBy: .newlines).first?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            return clean.isEmpty ? "글자" : "“" + String(clean.prefix(20)) + (clean.count > 20 ? "…" : "") + "”"
        case .files: return entry.files.count == 1 ? URL(fileURLWithPath: entry.files[0]).lastPathComponent : "파일 \(entry.files.count)개"
        case .image: return "이미지"
        case .video: return "동영상"
        }
    }
    private static func particle(_ name: String) -> String {
        guard let last = name.precomposedStringWithCanonicalMapping.unicodeScalars.last else { return "이(가)" }
        if (0xAC00...0xD7A3).contains(last.value) { return (last.value - 0xAC00) % 28 == 0 ? "가" : "이" }
        if (48...57).contains(last.value) { return [0, 1, 3, 6, 7, 8].contains(Int(last.value - 48)) ? "이" : "가" }
        return "이(가)"
    }
    mutating func show(_ message: String, now: TimeInterval) {
        let old = frame(now: now, reducedMotion: false)
        previous = old?.text; previousAlpha = min(1, (old?.alpha ?? 0) + (old?.previousAlpha ?? 0))
        previousOffset = old?.offset ?? -4
        text = message; began = now
    }
    mutating func clear() { text = nil; previous = nil; previousAlpha = 0 }
    /// The four-second deadline starts on capture; the final fade completes at 4.25s (AC-38 ±0.3s).
    mutating func update(now: TimeInterval, reducedMotion: Bool) -> Frame? {
        guard let value = frame(now: now, reducedMotion: reducedMotion) else { clear(); return nil }
        if now - began >= Self.transition { previous = nil }
        return value
    }
    private func frame(now: TimeInterval, reducedMotion: Bool) -> Frame? {
        let elapsed = max(0, now - began)
        guard let text, elapsed < Self.duration + Self.transition else { return nil }
        let entrance = min(1, elapsed / Self.transition)
        let enter = 1 - pow(1 - entrance, 3)
        let exit = min(1, max(0, (elapsed - Self.duration) / Self.transition))
        let fade = exit * exit * (3 - 2 * exit)
        return Frame(text: text, previous: previous, alpha: enter * (1 - fade),
                     previousAlpha: previousAlpha * (1 - enter),
                     offset: reducedMotion ? 0 : (previous == nil ? -4 : previousOffset) * (1 - enter) + 4 * fade)
    }
}
