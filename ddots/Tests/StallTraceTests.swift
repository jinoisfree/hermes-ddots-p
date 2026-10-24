import Foundation
import CoreFoundation

@main struct StallTraceTests {
    static func main() throws {
        precondition(StallTrace.stall(durationMS: 50, work: "unknown", workMS: 0) == nil)
        precondition(StallTrace.stall(durationMS: 49, work: "unknown", workMS: 0) == nil)
        let row = StallTrace.stall(durationMS: 50.01, work: "applyChat", workMS: 35)!
        precondition(Set(row.keys) == ["time", "kind", "name", "duration_ms", "work_ms"])
        precondition(row["kind"] as? String == "stall")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stall-log.txt")
        for index in 0..<205 {
            StallTrace.append(StallTrace.row(kind: "response", name: "roomSelect", durationMS: Double(index)), to: url)
        }
        StallTrace.writer.sync {}
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        precondition(lines.count == 200)
        let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as! [String: Any]
        precondition(Set(first.keys) == ["time", "kind", "name", "duration_ms"])
        precondition(first["duration_ms"] as? Double == 5)
        precondition(first["name"] as? String == "roomSelect")
        precondition(ISO8601DateFormatter().date(from: first["time"] as! String) != nil)
        let observed = folder.appendingPathComponent("observed.txt")
        let trace = StallTrace(); trace.start(destination: observed)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            let start = StallTrace.now
            Thread.sleep(forTimeInterval: 0.065)
            trace.record("synthetic", since: start)
        }
        CFRunLoopRunInMode(.defaultMode, 0.1, false)
        StallTrace.writer.sync {}
        let observedRows = try String(contentsOf: observed, encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let measured = observedRows.first { $0["name"] as? String == "synthetic" }!
        let other = measured["other_ms"] as! Double
        precondition(other >= 0 && other <= measured["duration_ms"] as! Double)
        precondition(measured["sections_ms"] is [String: Any] && measured["changed_fields"] is [String])
        print("PASS: stall threshold, numeric timings, JSON schema and 200-row retention")
    }
}
