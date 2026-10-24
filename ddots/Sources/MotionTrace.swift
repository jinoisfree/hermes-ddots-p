import AppKit

/// Synthetic UI checks only: preparation and frame scheduling are kept separate.
final class MotionTrace {
    private(set) var lastLayouts = 0, lastFilters = 0, lastPageLayouts = 0
    private var direction = "", began = 0.0
    private var rows: [(Double, Double, CGRect, Int, Int, CGSize?)] = []
    private var summary = "direction\tframes\tmean_ms\tmax_ms\tover_20ms\tmax_width_delta\tprepare_ms\tlayouts\tfilters\tpage_layouts\tsnapshot_ms\tsettle_ms\n"
    private var raw = "direction\tuptime\tadvance_ms\twidth\theight\tlayouts\tfilters\tpage_width\tpage_height\n"
    func begin(_ direction: String) { self.direction = direction; began = ProcessInfo.processInfo.systemUptime; rows = [] }
    func sample(time: Double, cost: Double, bubble: CGRect, layouts: Int, filters: Int, page: CGSize?) {
        rows.append((time, cost, bubble, layouts, filters, page))
    }
    func end(snapshotMS: Double = 0, settleMS: Double = 0) {
        let gaps = zip(rows, rows.dropFirst()).map { ($1.0 - $0.0) * 1000 }
        let jumps = zip(rows, rows.dropFirst()).map { abs($1.2.width - $0.2.width) }
        let pages = zip(rows, rows.dropFirst()).filter { $0.5 != nil && $1.5 != nil && $0.5 != $1.5 }.count
        lastLayouts = (rows.last?.3 ?? 0)-(rows.first?.3 ?? 0)
        lastFilters = (rows.last?.4 ?? 0)-(rows.first?.4 ?? 0)
        lastPageLayouts = pages
        summary += "\(direction)\t\(rows.count)\t\(gaps.reduce(0,+) / Double(max(1,gaps.count)))\t\(gaps.max() ?? 0)\t\(gaps.filter { $0 > 20 }.count)\t\(jumps.max() ?? 0)\t\(((rows.first?.0 ?? began)-began)*1000)\t\((rows.last?.3 ?? 0)-(rows.first?.3 ?? 0))\t\((rows.last?.4 ?? 0)-(rows.first?.4 ?? 0))\t\(pages)\t\(snapshotMS)\t\(settleMS)\n"
        for r in rows { raw += "\(direction)\t\(r.0)\t\(r.1*1000)\t\(r.2.width)\t\(r.2.height)\t\(r.3)\t\(r.4)\t\(r.5?.width ?? 0)\t\(r.5?.height ?? 0)\n" }
    }
    func write(to url: URL) { try? (summary + "\n" + raw).write(to: url, atomically: true, encoding: .utf8) }
}
