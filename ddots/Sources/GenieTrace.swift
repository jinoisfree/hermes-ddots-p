import AppKit

/// Numeric transition telemetry only. Never includes conversation or account identifiers.
final class GenieTrace {
    static let writer = DispatchQueue(label: "ddots.motion-log", qos: .utility)
    let started = ProcessInfo.processInfo.systemUptime
    let date = Date()
    let opening: Bool
    var size = CGSize.zero
    var path = "none"
    private var initialSprite: CGRect?
    private(set) var spriteShiftMax = 0.0
    private(set) var backingScale = 1.0
    func observeSprite(_ rect: CGRect, backing: CGFloat) {
        backingScale = Double(backing)
        guard let initialSprite else { self.initialSprite = rect; return }
        let distance = max(hypot(rect.minX-initialSprite.minX, rect.minY-initialSprite.minY),
                           hypot(rect.maxX-initialSprite.maxX, rect.maxY-initialSprite.maxY))
        spriteShiftMax = max(spriteShiftMax, Double(distance))
    }
    var pageMS = 0.0, layoutMS = 0.0, captureMS = 0.0, compositeMS = 0.0, blurMS = 0.0
    var inputFinished: Double?
    var motionStarted: Double?
    var linkFirstMS: Double?
    var blurApplyMS = 0.0
    var workMS: [String: Double] = [:]
    var frames: [Double] = []
    private(set) var settleMS = 0.0
    init(opening: Bool) { self.opening = opening }
    func finish(settleMS: Double, destination: URL?, completed: Bool = true) {
        self.settleMS = settleMS
        guard let destination else { return }
        let gaps = zip(frames, frames.dropFirst()).map { ($1 - $0) * 1000 }
        let fields: [String: Any] = ["time": ISO8601DateFormatter().string(from: date), "direction": opening ? "open" : "close",
            "completed": completed, "sprite_shift_max": spriteShiftMax, "backing_scale": backingScale, "width": size.width, "height": size.height, "picture": path,
            "first_frame_ms": ((frames.first ?? started) - started) * 1000,
            "motion_start_ms": motionStarted.map { ($0 - started) * 1000 } ?? NSNull(),
            "first_gap_ms": gaps.first ?? 0, "input_done_ms": inputFinished.map { ($0 - started) * 1000 } ?? NSNull(),
            "link_first_ms": linkFirstMS ?? (NSNull() as Any), "work_ms": workMS, "blur_apply_ms": blurApplyMS,
            "page_ms": pageMS, "layout_ms": layoutMS, "capture_ms": captureMS, "composite_ms": compositeMS,
            "blur_ms": blurMS, "frames": frames.count, "max_ms": gaps.max() ?? 0,
            "over_20ms": gaps.filter { $0 > 20 }.count, "settle_ms": settleMS]
        Self.writer.async {
            guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return }
            let old = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            let rows = (old.split(separator: "\n").map(String.init) + [line]).suffix(100)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (rows.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
        }
    }
}
