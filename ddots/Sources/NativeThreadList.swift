import AppKit
import SwiftUI

/// Geometry supplied by the virtual list, including rows with no live cell.
protocol NativeThreadGeometry: AnyObject {
    var cardCounts: [String: Int] { get }
    func frame(for id: String) -> CGRect?
    func isReady(stamp: SlackModel.EntryViewportStamp) -> Bool
}

/// The AppKit list is the default for Slack rooms. `defaults write io.github.hermes-ddots-p.ddots nativeList -bool false`
/// (or `--legacy-list` in a check) brings back the SwiftUI list while it is still kept.
enum NativeListFeature {
    static let enabled: Bool = {
        if CommandLine.arguments.contains("--legacy-list") { return false }
        if CommandLine.arguments.contains("--native-list") { return true }
        return UserDefaults.standard.object(forKey: "nativeList") as? Bool ?? true
    }()
}

struct NativeThreadRow {
    let id: String
    var inputs: SlackThreadInputs? = nil
    var token = ""
    var aliases: [String] = []
    var fixedHeight: CGFloat? = nil
    var card: (() -> NativeThreadCard.Content)? = nil
    let content: () -> AnyView

    func sameContent(as other: Self) -> Bool {
        id == other.id && inputs == other.inputs && token == other.token && fixedHeight == other.fixedHeight
    }
}

/// Phase one keeps the existing SwiftUI card; only the scrolling document is native.
struct NativeThreadList: NSViewRepresentable {
    let model: SlackModel
    let rows: [NativeThreadRow]
    let stamp: SlackModel.EntryViewportStamp

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScroll() }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(rows: rows, stamp: stamp)
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.disconnect() }

    // Hosted SwiftUI cells and their geometry are updated on the main thread.
    // Do not let AppKit scroll a speculative document snapshot ahead of those updates.
    final class Scroll: NSScrollView {
        override class var isCompatibleWithResponsiveScrolling: Bool { false }
    }
    final class Table: NSTableView {
        var afterLayout: (() -> Void)?
        var beforeDraw: (() -> Void)?
        override func layout() { super.layout(); afterLayout?() }
        override func viewWillDraw() { super.viewWillDraw(); beforeDraw?() }
        override func mouseDown(with event: NSEvent) {
            // Cells own card/text/button events; empty table space has no row selection.
            super.mouseDown(with: event)
        }
    }
    final class Host: NSHostingView<AnyView> {
        var sizeChanged: (() -> Void)?
        override func layout() { super.layout(); sizeChanged?() }
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            sizeChanged?()
        }
    }
    final class Cell: NSTableCellView {
        let host = Host(rootView: AnyView(EmptyView()))
        var changed: (() -> Void)?
        override init(frame: NSRect) {
            super.init(frame: frame)
            addSubview(host)
            host.sizeChanged = { [weak self] in self?.changed?() }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func layout() {
            super.layout()
            host.frame = NSRect(x: ChatMetrics.horizontalInset, y: 0,
                                width: max(1, bounds.width - 2 * ChatMetrics.horizontalInset), height: bounds.height)
            changed?()
        }
        func configure(_ row: NativeThreadRow, width: CGFloat) {
            host.rootView = AnyView(row.content().id(row.id).frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NativeThreadGeometry {
        weak var model: SlackModel?
        let scroll = Scroll(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let table = Table()
        private let measuring = Cell(frame: .zero)
        private var rows: [NativeThreadRow] = []
        private var indices: [String: Int] = [:]
        private var heights: [String: CGFloat] = [:]
        private var textLayouts: [String: NativeThreadCard.Layout] = [:]
        private var width: CGFloat = 0
        private var stamp: SlackModel.EntryViewportStamp?
        private var updating = false
        private var queued = false
        private var rowCreated = 0, rowReused = 0, textCreated = 0, textReused = 0
        private var inputMonitor: Any?
        private var observers: [NSObjectProtocol] = []
        init(model: SlackModel) { self.model = model }
        deinit { disconnect() }

        func makeScroll() -> NSScrollView {
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.hasHorizontalScroller = false
            scroll.contentView.wantsLayer = true
            scroll.contentView.layer?.masksToBounds = true
            table.frame = NSRect(origin: .zero, size: scroll.contentSize)
            table.style = .plain
            table.autoresizingMask = [.width]
            table.headerView = nil
            table.backgroundColor = .clear
            table.selectionHighlightStyle = .none
            table.focusRingType = .none
            table.intercellSpacing = .zero
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.usesAutomaticRowHeights = false
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
            column.minWidth = 1; column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.dataSource = self; table.delegate = self
            scroll.documentView = table
            table.afterLayout = { [weak self] in self?.scheduleLayout() }
            table.beforeDraw = { [weak self] in
                self?.model?.prepareEntryViewport()
                self?.model?.onEntryViewportFrame?()
            }
            installInputMonitoring()
            return scroll
        }
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 1 }
            return heights[rows[row].id] ?? 1
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("native-conversation-row")
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableRowView {
                rowReused += 1
                return reused
            }
            rowCreated += 1
            let view = NSTableRowView(frame: .zero)
            view.identifier = id
            return view
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if let layout = textLayouts[rows[row].id] {
                let identifier = NSUserInterfaceItemIdentifier("native-thread-card")
                let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NativeThreadCard
                if reused == nil { textCreated += 1 } else { textReused += 1 }
                let cell = reused ?? NativeThreadCard(frame: .zero)
                cell.identifier = identifier
                let id = rows[row].id
                // A hosted piece that grows or shrinks (a disclosure, a progress mark) re-measures its own row.
                cell.hostedSizeChanged = { [weak self] in self?.scheduleRemeasure(id) }
                cell.register = { [weak self] key, view in self?.model?.rowViews.setObject(view, forKey: key as NSString) }
                cell.configure(layout)
                return cell
            }
            let identifier = NSUserInterfaceItemIdentifier("hosted-card")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell ?? Cell(frame: .zero)
            cell.identifier = identifier
            let item = rows[row]
            cell.configure(item, width: cardWidth)
            cell.changed = { [weak self, weak cell] in
                guard let self, let cell, self.indices[item.id] != nil else { return }
                self.scheduleHeightCheck(cell, id: item.id)
            }
            return cell
        }
        var cardCounts: [String: Int] { ["row_created": rowCreated, "row_reused": rowReused, "text_created": textCreated, "text_reused": textReused, "appkit": textLayouts.count, "hosted": rows.filter { $0.inputs != nil && $0.card == nil }.count] }
        private var cardWidth: CGFloat { max(1, width - 2 * ChatMetrics.horizontalInset) }
        private func measure(_ row: NativeThreadRow) -> CGFloat {
            if let fixed = row.fixedHeight { return max(1, fixed) }
            if let content = row.card?() {
                let layout = NativeThreadCard.layout(content, width: cardWidth)
                textLayouts[row.id] = layout
                report(layout)
                return layout.height
            }
            textLayouts.removeValue(forKey: row.id)
            measuring.configure(row, width: cardWidth)
            measuring.frame.size = NSSize(width: width, height: 1)
            measuring.layoutSubtreeIfNeeded()
            return max(1, ceil(measuring.host.fittingSize.height))
        }
        func update(rows next: [NativeThreadRow], stamp: SlackModel.EntryViewportStamp) {
            guard !updating else { return }
            updating = true
            let old = rows
            let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            let nextIDs = Set(next.map(\.id))
            let resized = abs(width - scroll.contentSize.width) > 0.5
            width = max(1, scroll.contentSize.width)
            rows = next
            indices.removeAll(keepingCapacity: true)
            for (index, row) in rows.enumerated() {
                indices[row.id] = index
                for alias in row.aliases { indices[alias] = index }
            }
            heights = heights.filter { nextIDs.contains($0.key) }
            textLayouts = textLayouts.filter { nextIDs.contains($0.key) }
            var changed = IndexSet()
            for (index, row) in rows.enumerated() {
                if resized || oldByID[row.id].map({ !row.sameContent(as: $0) }) ?? true {
                    heights[row.id] = measure(row); changed.insert(index)
                }
            }
            // CollectionDifference represents moves as remove/insert, so existing cells retain identity.
            let difference = next.map(\.id).difference(from: old.map(\.id))
            var removed = IndexSet(), inserted = IndexSet()
            for change in difference {
                switch change {
                case .remove(let offset, _, _): removed.insert(offset)
                case .insert(let offset, _, _): inserted.insert(offset)
                }
            }
            table.beginUpdates()
            table.removeRows(at: removed, withAnimation: [])
            table.insertRows(at: inserted, withAnimation: [])
            table.endUpdates()
            changed.subtract(inserted)
            // A card already on screen takes its new content in place, keeping its views, selection and focus.
            var reload = IndexSet()
            for index in changed {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeThreadCard, let layout = textLayouts[rows[index].id] {
                    cell.configure(layout)
                } else { reload.insert(index) }
            }
            if !reload.isEmpty { table.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0)) }
            table.noteHeightOfRows(withIndexesChanged: changed.union(inserted))
            table.tableColumns.first?.width = width
            self.stamp = stamp
            if model?.source == .slack {
                model?.connectEntryViewport(scroll, stamp: stamp)
                model?.nativeGeometry = self
                model?.scroller = { [weak self] in self?.performScroll() }
            }
            updating = false
            scheduleLayout()
        }
        private func scheduleHeightCheck(_ cell: Cell, id: String) {
            DispatchQueue.main.async { [weak self, weak cell] in
                guard let self, let cell, !self.updating, let index = self.indices[id],
                      self.table.row(for: cell) == index, self.rows[index].fixedHeight == nil else { return }
                let height = max(1, ceil(cell.host.fittingSize.height))
                guard abs(height - (self.heights[id] ?? 0)) > 0.5 else { return }
                self.heights[id] = height
                self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                self.scheduleLayout()
            }
        }
        private func scheduleLayout() {
            guard !queued, !updating else { return }; queued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.queued = false
                if abs(self.width - self.scroll.contentSize.width) > 0.5, let stamp = self.stamp {
                    self.update(rows: self.rows, stamp: stamp)
                }
                self.table.layoutSubtreeIfNeeded()
                // NSScrollView can resize its document when the notice strip changes the viewport.
                // The table's last row, not that viewport delta, owns the document extent.
                let contentHeight = self.rows.isEmpty ? 0 : self.table.rect(ofRow: self.rows.count - 1).maxY
                let documentHeight = max(self.scroll.contentSize.height, contentHeight)
                if abs(self.table.frame.height - documentHeight) > 0.5 {
                    if CommandLine.arguments.contains("--ui-smoke") {
                        print("native-list.extent actual=\(self.table.frame.height) rows=\(contentHeight) viewport=\(self.scroll.contentSize.height) target=\(documentHeight)")
                    }
                    self.table.setFrameSize(NSSize(width: self.width, height: documentHeight))
                }
                if let model = self.model {
                    model.measured(viewport: self.scroll.contentSize.height)
                    for row in self.rows where row.inputs != nil { model.rowGeometry[row.id] = self.frame(for: row.id) }
                    model.prepareEntryViewport()
                    self.performScroll()
                }
            }
        }
        /// What the SwiftUI card read back from its own geometry: the opened thread's height, a long post's height.
        private func report(_ layout: NativeThreadCard.Layout) {
            let expanded = layout.content.expanded ? (layout.content.id, layout.height) : nil
            let replies = layout.placed.compactMap { item -> (() -> Void)? in
                guard case .post(let post) = item.piece, let report = post.reportHeight else { return nil }
                let height = item.frame.height
                return { report(height) }
            }
            guard expanded != nil || !replies.isEmpty else { return }
            // Reported after the table update, as the SwiftUI card's geometry readers did; the window may resize in answer.
            DispatchQueue.main.async { [weak self] in
                guard let model = self?.model else { return }
                if let (id, height) = expanded { model.measured(thread: id, height: height) }
                replies.forEach { $0() }
            }
        }
        private var remeasuring = Set<String>()
        private func scheduleRemeasure(_ id: String) {
            guard remeasuring.insert(id).inserted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.remeasuring.remove(id)
                guard !self.updating, let index = self.indices[id], self.rows[index].id == id, self.rows[index].card != nil else { return }
                let height = self.measure(self.rows[index])
                if abs(height - (self.heights[id] ?? 0)) > 0.5 {
                    self.heights[id] = height
                    self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                }
                if let cell = self.table.view(atColumn: 0, row: index, makeIfNecessary: false) as? NativeThreadCard, let layout = self.textLayouts[id] {
                    cell.configure(layout)
                }
                self.scheduleLayout()
            }
        }
        func frame(for id: String) -> CGRect? {
            guard let index = indices[id], rows.indices.contains(index) else { return nil }
            // A message inside a native card has an exact place in the computed layout.
            // The thread's own ID is the whole card, even where its first message shares that ID.
            if id != rows[index].id, let layout = textLayouts[rows[index].id] {
                let key = id.hasPrefix("slack-root:") ? String(id.dropFirst("slack-root:".count)) : id.hasPrefix("page-anchor:") ? "line:" + id.dropFirst("page-anchor:".count) : id
                let anchor = layout.anchors[key] ?? (id.hasPrefix("slack-root:") ? layout.anchors.first { $0.key == rows[index].id }?.value : nil)
                if let anchor {
                    let row = table.rect(ofRow: index)
                    let rect = NSRect(x: row.minX + ChatMetrics.horizontalInset + anchor.minX, y: row.minY + anchor.minY, width: anchor.width, height: anchor.height)
                    return table.convert(rect, to: scroll.contentView)
                }
            }
            // Realized internal probes take precedence; offscreen internal IDs fall back to the card.
            if id != rows[index].id && !id.hasPrefix(SlackModel.endMark),
               let view = model?.rowViews.object(forKey: id as NSString), view.window != nil,
               view.isDescendant(of: table) {
                return view.convert(view.bounds, to: scroll.contentView)
            }
            var rect = table.rect(ofRow: index)
            rect.origin.x += ChatMetrics.horizontalInset
            rect.size.width = cardWidth
            if id.hasPrefix(SlackModel.endMark) { rect.size.height += SlackSidebar.threadMargin / 2 }
            return table.convert(rect, to: scroll.contentView)
        }
        func isReady(stamp: SlackModel.EntryViewportStamp) -> Bool {
            self.stamp == stamp && !updating && width > 1 && table.numberOfRows == rows.count
        }
        private func performScroll() {
            guard let model, model.scrolledRevision != model.scrollRevision,
                  model.scrollRevision != model.entryRevision else { return }
            let revision = model.scrollRevision, target = model.scrollTarget, scrolls = model.requestScrolls
            model.scrolledRevision = revision
            for delay in [0.0, 0.15, 0.45] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak model] in
                    guard let self, let model, model.nativeGeometry === self,
                          model.pageHold == nil, model.scrollRevision == revision, model.userScrolls == scrolls,
                          let frame = self.frame(for: target) else { return }
                    let bounds = self.scroll.contentView.bounds
                    let bottom = target == "slack-bottom" || target.hasPrefix(SlackModel.endMark)
                    let wanted = target == "slack-bottom" ? frame.maxY - bounds.height :
                        // ScrollViewReader's end ID excludes the compensating negative padding.
                        // Entry preparation still uses the full native end-probe geometry.
                        bottom ? frame.maxY - SlackSidebar.threadMargin / 2 - bounds.height : frame.midY - bounds.height / 2
                    let y = min(max(0, wanted), max(0, self.table.bounds.height - bounds.height))
                    if target == "slack-bottom" || SlackModel.reducesMotion {
                        self.scroll.contentView.scroll(to: NSPoint(x: bounds.minX, y: y))
                    } else {
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0.24
                            self.scroll.contentView.animator().setBoundsOrigin(NSPoint(x: bounds.minX, y: y))
                        }
                    }
                    self.scroll.reflectScrolledClipView(self.scroll.contentView)
                }
            }
        }
        private func installInputMonitoring() {
            observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification,
                object: scroll, queue: .main) { [weak self] _ in self?.model?.userScrolls += 1 })
            scroll.contentView.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main) { [weak self] _ in self?.model?.prepareEntryViewport() })
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
                guard let self, !self.scroll.isHiddenOrHasHiddenAncestor, event.window === self.scroll.window else { return event }
                let point = self.scroll.convert(event.locationInWindow, from: nil)
                var reading = (event.type == .scrollWheel || event.type == .leftMouseDown) && self.scroll.bounds.contains(point)
                if event.type == .keyDown, [49, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode),
                   let responder = self.scroll.window?.firstResponder as? NSView {
                    reading = responder === self.scroll || responder.isDescendant(of: self.scroll)
                }
                if reading {
                    if event.type == .scrollWheel { self.model?.scrollInputAt = ProcessInfo.processInfo.systemUptime }
                    self.model?.userScrolls += 1
                }
                return event
            }
        }
        func disconnect() {
            if model?.nativeGeometry === self {
                model?.nativeGeometry = nil
                if model?.scrollView === scroll { model?.scroller = nil; model?.scrollView = nil }
            }
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }; inputMonitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []
            table.afterLayout = nil; table.beforeDraw = nil
        }
    }
}
