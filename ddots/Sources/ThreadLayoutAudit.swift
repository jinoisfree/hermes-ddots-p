import AppKit

/// Is every card of the Slack list where its row is, and nothing drawn where no row is? One check, three users: the
/// UI smoke, the "화면 상태 기록" menu item and the watch that writes a record when the list is wrong for good.
/// Light looks only at frames. Full also reads back what the words and the hosted pieces really draw.
/// What is recorded is ids, numbers and view classes; never a message's words, a name, a file's name or a link.
enum ThreadLayoutAudit {
    struct Violation {
        var code: String
        var row: Int
        var id: String
        var detail: String
        /// The same fault at a later look has the same key, whatever its numbers have become.
        var key: String { code + "@" + id }
    }
    struct Outcome {
        var violations: [Violation] = []
        var rows: [[String: Any]] = []
        var orphans: [[String: Any]] = []
        var shownRowViews = 0
        var rowCount = 0
    }

    private static func box(_ rect: NSRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map { Double($0) } }

    /// How tall a hosted piece really is at its real width and with its live state. The hosting view centres its
    /// content in whatever frame it has, so it is given a tall frame, painted, and the painted rows are read back.
    static func drawnHeight(_ host: NSView) -> CGFloat {
        let saved = host.frame
        host.frame.size.height = 1600
        host.layoutSubtreeIfNeeded()
        defer { host.frame = saved; host.layoutSubtreeIfNeeded() }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return -1 }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsHigh) / host.bounds.height
        func painted(_ y: Int) -> Bool { (0..<bitmap.pixelsWide).contains { (bitmap.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.04 } }
        guard let top = (0..<bitmap.pixelsHigh).first(where: painted), let bottom = (0..<bitmap.pixelsHigh).last(where: painted) else { return 0 }
        return CGFloat(bottom + 1 - top) / scale
    }

    /// `materialize` first asks the table for every row's view; without it only the views already there are looked at,
    /// so a view left in an old place is not replaced by a new one. `forceLayout` lays the table out first.
    static func inspect(_ coordinator: NativeThreadList.Coordinator, full: Bool, forceLayout: Bool, materialize: Bool = false) -> Outcome {
        let table = coordinator.table
        if forceLayout { table.layoutSubtreeIfNeeded() }
        let state = coordinator.diagnostics
        var outcome = Outcome()
        outcome.rowCount = table.numberOfRows
        func id(_ row: Int) -> String { state.rowIDs.indices.contains(row) ? state.rowIDs[row] : "?" }
        func violate(_ code: String, _ row: Int, _ detail: String) { outcome.violations.append(Violation(code: code, row: row, id: id(row), detail: detail)) }

        var previousMaxY: CGFloat = 0
        for index in 0..<table.numberOfRows {
            let rect = table.rect(ofRow: index)
            if rect.minY < previousMaxY - 0.5 { violate("rows-overlap", index, "starts at \(rect.minY), the row above ends at \(previousMaxY)") }
            previousMaxY = rect.maxY
            if materialize { _ = table.view(atColumn: 0, row: index, makeIfNecessary: true) }
        }
        var rowViews: [(row: Int, view: NSTableRowView)] = []
        table.enumerateAvailableRowViews { view, row in rowViews.append((row, view)) }
        var byRow: [Int: [String: Any]] = [:]
        for index in 0..<table.numberOfRows {
            byRow[index] = ["index": index, "id": id(index), "rect": box(table.rect(ofRow: index)),
                            "height": Double(state.heights[id(index)] ?? -1), "cardHeight": Double(state.cardHeights[id(index)] ?? -1), "hasRowView": false]
        }
        for (row, rowView) in rowViews where !rowView.isHidden {
            outcome.shownRowViews += 1
            let rect = table.rect(ofRow: row)
            var entry = byRow[row] ?? [:]
            entry["rowView"] = box(rowView.frame); entry["hasRowView"] = true
            if abs(rowView.frame.minY - rect.minY) > 1 || abs(rowView.frame.height - rect.height) > 1 {
                violate("rowview-position", row, "its row view stands at y=\(rowView.frame.minY) h=\(rowView.frame.height), the row is y=\(rect.minY) h=\(rect.height)")
            }
            guard let cell = rowView.subviews.first(where: { !$0.isHidden }) else { byRow[row] = entry; continue }
            let cellRow = table.row(for: cell)
            entry["cell"] = box(cell.frame); entry["cellRow"] = cellRow
            entry["cellKind"] = cell is NativeThreadCard ? "native" : cell is NativeThreadList.Cell ? "hosted" : "other"
            if cell.frame.minY < -1 || cell.frame.maxY > rowView.bounds.height + 1 {
                violate("cell-outside-rowview", row, "its cell (y=\(cell.frame.minY) h=\(cell.frame.height)) is not inside its row view (h=\(rowView.bounds.height))")
            }
            if cellRow != row { violate("cell-row-mismatch", row, "its cell answers to row \(cellRow)") }
            if let card = cell as? NativeThreadCard, let layout = card.value {
                if forceLayout { card.layoutSubtreeIfNeeded() }
                entry["layoutHeight"] = Double(layout.height); entry["layoutWidth"] = Double(layout.width); entry["cardWidth"] = Double(card.bounds.width)
                if layout.height > rect.height + 1 || layout.height > rowView.frame.height + 1 {
                    violate("card-taller-than-row", row, "its layout is \(layout.height) tall, the row \(rect.height), its row view \(rowView.frame.height)")
                }
                if layout.width + 2 * ChatMetrics.horizontalInset > card.bounds.width + 1 {
                    violate("card-wider-than-cell", row, "its layout is \(layout.width) wide, its cell \(card.bounds.width)")
                }
                if full {
                    let names = Dictionary(uniqueKeysWithValues: card.diagnosticHosts.map { (ObjectIdentifier($0.value), $0.key) })
                    var reach: CGFloat = 0
                    var parts: [[String: Any]] = []
                    for sub in card.subviews where !sub.isHidden && !(sub is NativeThreadCard.Area) {
                        var bottom = sub.frame.maxY
                        var part: [String: Any] = ["frame": box(sub.frame)]
                        if let text = sub as? NativeThreadCard.Text, let manager = text.layoutManager, let container = text.textContainer {
                            manager.ensureLayout(for: container)
                            let used = manager.usedRect(for: container).maxY
                            bottom = sub.frame.minY + used
                            part["kind"] = "Text"; part["usedHeight"] = Double(used)
                            if bottom > sub.frame.maxY + 1 { violate("words-overflow", row, "its words lay out to \(bottom) in a frame ending at \(sub.frame.maxY)") }
                        } else if let host = sub as? NativeThreadCard.Host {
                            let drawn = drawnHeight(host)
                            bottom = host.frame.midY + drawn / 2
                            part["kind"] = "Host"; part["hostID"] = names[ObjectIdentifier(host)] ?? "?"; part["slot"] = Double(host.frame.height); part["drawn"] = Double(drawn)
                            if drawn > host.frame.height + 1 { violate("host-overflow", row, "a hosted piece is \(drawn) tall in a slot of \(host.frame.height)") }
                        } else {
                            part["kind"] = sub is NativeThreadCard.StackButton ? "Stack" : sub is NativeThreadCard.Button ? "Button" : String(describing: type(of: sub))
                        }
                        part["hidden"] = sub.isHidden
                        parts.append(part)
                        reach = max(reach, bottom)
                    }
                    entry["parts"] = parts; entry["reach"] = Double(reach)
                    if reach > rect.height + 1 { violate("card-past-row", row, "it draws down to \(reach), the row is \(rect.height) tall") }
                }
            }
            byRow[row] = entry
        }
        outcome.rows = byRow.keys.sorted().compactMap { byRow[$0] }
        let visible = rowViews.filter { !$0.view.isHidden }.sorted { $0.view.frame.minY < $1.view.frame.minY }
        for (first, second) in zip(visible, visible.dropFirst()) where second.view.frame.minY < first.view.frame.maxY - 1 {
            violate("rowviews-overlap", first.row, "its row view ends at \(first.view.frame.maxY), the one of row \(second.row) starts at \(second.view.frame.minY)")
        }
        for sub in table.subviews where !sub.isHidden {
            if let rowView = sub as? NSTableRowView, table.row(for: rowView) < 0 {
                outcome.orphans.append(["kind": "rowView", "frame": box(rowView.frame)])
                outcome.violations.append(Violation(code: "orphan-rowview", row: -1, id: "-", detail: "a shown row view belongs to no row (y=\(rowView.frame.minY) h=\(rowView.frame.height))"))
            } else if sub is NativeThreadCard || sub is NativeThreadList.Cell, table.row(for: sub) < 0 {
                outcome.orphans.append(["kind": "cell", "frame": box(sub.frame)])
                outcome.violations.append(Violation(code: "orphan-cell", row: -1, id: "-", detail: "a shown cell sits straight in the table and belongs to no row (y=\(sub.frame.minY))"))
            }
        }
        return outcome
    }

    /// The whole record: the app, the model, the list, every row and card, the strays and what floats over the list.
    static func snapshot(_ coordinator: NativeThreadList.Coordinator, kind: String, outcome: Outcome? = nil) -> [String: Any] {
        let found = outcome ?? inspect(coordinator, full: true, forceLayout: true)
        let model = coordinator.model
        let scroll = coordinator.scroll
        let window = scroll.window
        let info = Bundle.main.infoDictionary ?? [:]
        var commit = "?"
        if let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "json"), let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { commit = json["commit"] as? String ?? "?" }
        let state = coordinator.diagnostics
        var record: [String: Any] = [
            "kind": kind, "written": ISO8601DateFormatter().string(from: Date()),
            "app": ["version": info["CFBundleShortVersionString"] as? String ?? "?", "build": info["CFBundleVersion"] as? String ?? "?", "commit": commit,
                    "screenScale": Double(window?.backingScaleFactor ?? 0), "window": window.map { box($0.frame) } ?? [],
                    "scrollBounds": box(scroll.contentView.bounds), "documentHeight": Double(coordinator.table.frame.height),
                    "source": model?.source.rawValue ?? "?", "room": model?.selected ?? "?"] as [String: Any],
            "model": ["picked": model?.picked ?? "-", "target": model?.target?.id ?? "-", "open": model?.open.count ?? 0,
                      "pageHold": model?.pageHold ?? "-", "followsStream": model?.followsStream ?? false, "scrollRevision": model?.scrollRevision ?? 0] as [String: Any],
            "coordinator": ["updating": state.updating, "queued": state.queued, "remeasuring": state.remeasuring, "ready": state.ready, "rows": state.rowIDs.count] as [String: Any],
            "rowViewsShown": found.shownRowViews, "rowCount": found.rowCount,
            "rows": found.rows, "orphans": found.orphans,
            "violations": found.violations.map { ["code": $0.code, "row": $0.row, "id": $0.id, "detail": $0.detail] },
        ]
        record["floating"] = floatingViews(coordinator)
        return record
    }

    /// Visible views over the list that are not part of the table: what could draw on top of a card.
    private static func floatingViews(_ coordinator: NativeThreadList.Coordinator) -> [[String: Any]] {
        guard let window = coordinator.scroll.window, let content = window.contentView else { return [] }
        let area = coordinator.scroll.convert(coordinator.scroll.bounds, to: nil)
        var skip = Set<ObjectIdentifier>()
        var up: NSView? = coordinator.table
        while let view = up { skip.insert(ObjectIdentifier(view)); up = view.superview }
        let structure: [NSView?] = [coordinator.scroll.verticalScroller, coordinator.scroll.horizontalScroller, coordinator.scroll.contentView]
        for case let view? in structure { skip.insert(ObjectIdentifier(view)) }
        var found: [[String: Any]] = []
        func walk(_ view: NSView) {
            guard found.count < 80, !view.isHidden, view.alphaValue > 0 else { return }
            if view === coordinator.table { return }
            if !skip.contains(ObjectIdentifier(view)), view.convert(view.bounds, to: nil).intersects(area) {
                var chain: [String] = [], parent = view.superview
                while let next = parent, chain.count < 3 { chain.append(String(describing: type(of: next))); parent = next.superview }
                found.append(["class": String(describing: type(of: view)), "frame": box(view.convert(view.bounds, to: nil)),
                              "alpha": Double(view.alphaValue), "hidden": view.isHidden, "parents": chain])
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(content)
        return found
    }
}

/// Where the records go and how they are written.
enum ThreadLayoutRecorder {
    /// `~/Library/Application Support/ddots/diagnostics`; a check may point it somewhere of its own.
    static var folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("ddots").appendingPathComponent("diagnostics")

    @discardableResult static func write(_ record: [String: Any], manual: Bool, now: Date = Date()) -> URL? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(ThreadLayoutDiagnosticsPolicy.fileName(now, manual: manual))
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        if !manual { ThreadLayoutDiagnosticsPolicy.pruneAutomatic(in: folder) }
        return url
    }
}

/// After the list has been laid out, a light look at most every two seconds. A fault that is still there at a look
/// more than 0.3 s later is written down once, at most one record in ten minutes. Switched off, nothing here runs.
final class ThreadLayoutWatch {
    /// How many light looks the list has had in this run; a check reads it to see that a switched-off watch never looked.
    private(set) static var looks = 0
    private var lastLook: TimeInterval = -.infinity
    private var confirmation = ThreadLayoutDiagnosticsPolicy.Confirmation()
    private var followUp: DispatchWorkItem?

    func layoutFinished(_ coordinator: NativeThreadList.Coordinator) {
        guard ThreadLayoutDiagnosticsPolicy.enabled() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = ThreadLayoutDiagnosticsPolicy.checkInterval - (now - lastLook)
        if remaining > 0 {
            // A quiet list may never lay out again. Keep one deferred look, or the already pending confirmation,
            // rather than dropping the only notification of a lasting fault.
            guard followUp == nil else { return }
            let work = DispatchWorkItem { [weak self, weak coordinator] in
                guard let self else { return }
                self.followUp = nil
                guard let coordinator else { return }
                self.layoutFinished(coordinator)
            }
            followUp = work
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
            return
        }
        look(coordinator, at: now)
    }
    func stop() { followUp?.cancel(); followUp = nil }

    private func look(_ coordinator: NativeThreadList.Coordinator, at now: TimeInterval) {
        lastLook = now; Self.looks += 1
        followUp?.cancel(); followUp = nil
        guard coordinator.scroll.window?.isVisible == true, !coordinator.diagnostics.updating else { return }
        let outcome = ThreadLayoutAudit.inspect(coordinator, full: false, forceLayout: false)
        let stayed = confirmation.look(Set(outcome.violations.map(\.key)), at: now)
        if !stayed.isEmpty {
            guard ThreadLayoutDiagnosticsPolicy.mayRecordAutomatically(in: ThreadLayoutRecorder.folder, now: Date()) else { return }
            var record = ThreadLayoutAudit.snapshot(coordinator, kind: "auto")
            record["confirmedKeys"] = stayed.sorted()
            ThreadLayoutRecorder.write(record, manual: false)
        } else if confirmation.waiting {
            let work = DispatchWorkItem { [weak self, weak coordinator] in
                guard let self, let coordinator, ThreadLayoutDiagnosticsPolicy.enabled() else { return }
                self.look(coordinator, at: ProcessInfo.processInfo.systemUptime)
            }
            followUp = work
            DispatchQueue.main.asyncAfter(deadline: .now() + ThreadLayoutDiagnosticsPolicy.confirmDelay + 0.05, execute: work)
        }
    }
}
