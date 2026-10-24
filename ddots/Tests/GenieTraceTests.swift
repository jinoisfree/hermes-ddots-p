import AppKit

@main struct GenieTraceTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("motion-log.txt")
        for index in 0..<105 {
            let trace = GenieTrace(opening: index % 2 == 0)
            trace.size = CGSize(width: 360, height: 670); trace.path = "reused"
            trace.observeSprite(CGRect(x: 10, y: 20, width: 100, height: 100), backing: 2)
            trace.observeSprite(CGRect(x: 13, y: 24, width: 100, height: 100), backing: 2)
            trace.observeSprite(CGRect(x: 10, y: 20, width: 100, height: 100), backing: 2)
            trace.motionStarted = trace.started + 0.021
            trace.inputFinished = trace.started + 0.003
            trace.frames = [trace.started + 0.005, trace.started + 0.021, trace.started + 0.047]
            trace.finish(settleMS: 2, destination: url)
        }
        GenieTrace.writer.sync {}
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 100)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        precondition(first["direction"] as? String == "close")
        precondition(first["picture"] as? String == "reused")
        precondition(first["over_20ms"] as? Int == 1)
        precondition(first["frames"] as? Int == 3)
        precondition(abs((first["first_frame_ms"] as! Double) - 5) < 0.01)
        precondition(abs((first["motion_start_ms"] as! Double) - 21) < 0.01)
        precondition(abs((first["first_gap_ms"] as! Double) - 16) < 0.01)
        precondition(abs((first["input_done_ms"] as! Double) - 3) < 0.01)
        precondition(abs((first["max_ms"] as! Double) - 26) < 0.01)
        precondition(first["sprite_shift_max"] as? Double == 5)
        precondition(first["backing_scale"] as? Double == 2)
        let keys: Set<String> = ["sprite_shift_max", "backing_scale", "time", "direction", "completed", "width", "height", "picture", "link_first_ms", "first_frame_ms", "motion_start_ms", "first_gap_ms", "input_done_ms", "work_ms", "blur_apply_ms", "page_ms", "layout_ms", "capture_ms", "composite_ms", "blur_ms", "frames", "max_ms", "over_20ms", "settle_ms"]
        precondition(Set(first.keys) == keys)
        let trace = GenieTrace(opening: true)
        trace.finish(settleMS: 0, destination: nil)
        GenieTrace.writer.sync {}
        let remaining = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
        precondition(remaining == 100)
        print("PASS: motion telemetry timings, numeric-only schema, 100-row retention and disabled writes")
    }
}
