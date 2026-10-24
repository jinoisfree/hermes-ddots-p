import Foundation
import CoreFoundation

/// Main-thread measurements. Names are fixed at call sites; never pass user text or identifiers.
final class StallTrace {
    static let shared = StallTrace()
    static let writer = DispatchQueue(label: "ddots.stall-log", qos: .utility)
    struct Response { let name: String; let start: Double }
    private var destination: URL?
    private var observer: CFRunLoopObserver?
    private var commitObserver: CFRunLoopObserver?
    private var commitStart: Double?
    private var began: Double?
    private var longest = (name: "unknown", ms: 0.0)
    private var covered: [(start: Double, end: Double)] = []
    private var changes = Set<String>()
    private var details: [String: Double] = [:]
    private var ready: [Response] = []
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    func start(destination: URL) {
        self.destination = destination
        guard observer == nil else { return }
        // AppKit/SwiftUI/CA commonly commit display work in beforeWaiting observers.
        // Measure the observer phase itself; this is not physical screen presentation.
        commitObserver = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self] _, _ in
            self?.commitStart = Self.now
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commitObserver, .commonModes)
        let activities: CFRunLoopActivity = [.entry, .afterWaiting, .beforeWaiting, .exit]
        observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.max) { [weak self] _, activity in
            guard let self else { return }
            if activity == .beforeWaiting, let start = self.commitStart {
                self.record("runloop.beforeWaiting", since: start)
                self.commitStart = nil
            }
            let now = Self.now
            if activity == .entry || activity == .afterWaiting {
                if self.began == nil { self.began = now; self.longest = ("unknown", 0); self.covered.removeAll(keepingCapacity: true); self.details.removeAll(keepingCapacity: true); self.changes.removeAll(keepingCapacity: true) }
            } else {
                if let start = self.began {
                    if var row = Self.stall(durationMS: (now-start)*1000, work: self.longest.name, workMS: self.longest.ms) {
                        let measured = self.covered.reduce(0) { $0 + max(0, $1.end-$1.start)*1000 }
                        row["other_ms"] = max(0, (now-start)*1000-measured)
                        row["sections_ms"] = self.details
                        row["changed_fields"] = self.changes.sorted()
                        self.write(row)
                    }
                    self.began = nil
                }
                let responses = self.ready; self.ready.removeAll(keepingCapacity: true)
                for response in responses {
                    self.write(Self.row(kind: "response", name: response.name, durationMS: (now-response.start)*1000))
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
    func record(_ name: String, since start: Double) {
        guard destination != nil, Thread.isMainThread else { return }
        let end = Self.now
        let elapsed = (end-start)*1000
        if let began {
            var lower = max(began, start)
            while let last = covered.last, last.end >= lower { lower = min(lower, last.start); covered.removeLast() }
            covered.append((lower, end))
        }
        if elapsed > longest.ms { longest = (name, elapsed) }
    }
    /// Fixed section names only; values contain no account or message identifiers.
    func changed(_ fields: [String]) { changes.formUnion(fields) }
    func detail(_ name: String, milliseconds: Double) { details[name, default: 0] += milliseconds }
    func measure<T>(_ name: String, _ work: () -> T) -> T {
        let start = Self.now
        defer { record(name, since: start) }
        return work()
    }
    func response(_ name: String) -> Response? {
        guard destination != nil, Thread.isMainThread else { return nil }
        return Response(name: name, start: Self.now)
    }
    /// Call only once the local result has been published. The next run-loop display pass is our endpoint,
    /// not network completion or a claim of physical presentation on the monitor.
    func finish(_ response: Response?) {
        guard let response else { return }
        record(response.name, since: response.start)
        DispatchQueue.main.async { [weak self] in self?.ready.append(response) }
    }
    static func row(kind: String, name: String, durationMS: Double, workMS: Double? = nil) -> [String: Any] {
        var row: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "kind": kind, "name": name, "duration_ms": durationMS]
        if let workMS { row["work_ms"] = workMS }
        return row
    }
    static func stall(durationMS: Double, work: String, workMS: Double) -> [String: Any]? {
        guard durationMS > 50 else { return nil }
        return row(kind: "stall", name: work, durationMS: durationMS, workMS: workMS)
    }
    private func write(_ row: [String: Any]) {
        guard let destination else { return }
        Self.append(row, to: destination)
    }
    static func append(_ row: [String: Any], to destination: URL) {
        writer.async {
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8) else { return }
            let old = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            let rows = (old.split(separator: "\n").map(String.init) + [line]).suffix(200)
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (rows.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
        }
    }
}
