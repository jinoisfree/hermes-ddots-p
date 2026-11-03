import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

private typealias ShelfTextState = SwiftUI.State<String>
private typealias ShelfBoolState = SwiftUI.State<Bool>
private typealias ShelfIDState = SwiftUI.State<UUID?>
private typealias ShelfKindState = SwiftUI.State<ClipboardTabKind>
private typealias ShelfIntState = SwiftUI.State<Int>
private typealias ShelfFramesState = SwiftUI.State<[UUID: CGRect]>

enum ClipboardSearch {
    static let placeholder = "글자·파일 이름·이미지 속 글자 검색"
    @MainActor static func field(in root: NSView) -> NSTextField? {
        if let field = root as? NSTextField, (field.placeholderString ?? field.placeholderAttributedString?.string) == placeholder { return field }
        return root.subviews.lazy.compactMap { field(in: $0) }.first
    }
}

struct ClipboardShelf: View {
    @Environment(\.colorScheme) private var colorScheme
    private var ink: Color { Color(ClipboardAppearance.primary(dark: colorScheme == .dark)) }
    @ObservedObject var library: ClipboardLibrary
    @ObservedObject private var semantic: ClipboardSemanticSearch
    init(library: ClipboardLibrary, holding: @escaping (Bool) -> Void) {
        self.library = library; self.semantic = library.semantic; self.holding = holding
    }
    var holding: (Bool) -> Void
    @ShelfTextState private var query = ""
    @ShelfIDState private var editingTab: UUID?
    @ShelfTextState private var editedName = ""
    @ShelfBoolState private var addingTab = false
    @ShelfTextState private var newName = ""
    @ShelfKindState private var newKind = ClipboardTabKind.custom
    @ShelfIDState private var deletingTab: UUID?
    @ShelfIDState private var selected: UUID?
    @ShelfIDState private var targeted: UUID?
    @ShelfIntState private var focusRegion = 0
    @ShelfBoolState private var keyboardSelection = false
    @ShelfFramesState private var tabFrames: [UUID: CGRect] = [:]
    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") }
    private var filtered: [ClipboardEntry] {
        let all = library.entries.filter { library.tabs.current.contains($0) }
        let entries = all.filter { $0.matches(query) }
        let literal = ClipboardHistory.ordered(entries)
        let ids = Set(literal.map(\.id))
        return literal + all.filter { !$0.secret && semantic.ids.contains($0.id) && !ids.contains($0.id) }
    }
    private func searchMeaning() { library.searchMeaning(query, entries: library.entries.filter { library.tabs.current.contains($0) }) }
    private func select(_ entry: ClipboardEntry, flags: NSEvent.ModifierFlags) -> Bool {
        if flags.contains(.command) {
            if library.selectedIDs.contains(entry.id) { library.selectedIDs.remove(entry.id) } else { library.selectedIDs.insert(entry.id) }
            selected = entry.id; keyboardSelection = false; return false
        }
        if flags.contains(.shift), let anchor = filtered.firstIndex(where: { $0.id == selected }), let end = filtered.firstIndex(where: { $0.id == entry.id }) {
            library.selectedIDs.formUnion(filtered[min(anchor, end)...max(anchor, end)].map(\.id)); return false
        }
        if !library.selectedIDs.contains(entry.id) { library.selectedIDs.removeAll() }
        selected = entry.id; keyboardSelection = false; return true
    }
    private func group(_ entry: ClipboardEntry) -> String {
        if entry.pinned { return "고정" }
        if Calendar.current.isDateInToday(entry.copiedAt) { return "오늘" }
        if Calendar.current.isDateInYesterday(entry.copiedAt) { return "어제" }
        return entry.copiedAt.formatted(.dateTime.year().month().day())
    }
    private func rename() {
        guard let id = editingTab else { return }
        let name = editedName
        library.editTabs { try $0.rename(id, name: name) }; editingTab = nil; holding(false)
    }
    private func tab(_ tab: ClipboardTab) -> some View {
        Button { rename(); library.editTabs { $0.selected = tab.id } } label: {
            Text(tab.name).font(.system(size: 11)).lineLimit(1).truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.plain)
        .background(GeometryReader { geometry in Color.clear.preference(key: ClipboardTabFrames.self, value: [tab.id: geometry.frame(in: .named("clipboard-tabs"))]) })
        .overlay(Capsule().stroke(targeted == tab.id ? (tab.kind == .custom ? Color.accentColor : Color.secondary) : Color.clear, lineWidth: 2))
        .help(targeted == tab.id && tab.kind != .custom ? "이 종류의 탭에는 넣을 수 없어요" : tab.name)
        .accessibilityLabel("\(tab.name), \(tab.kind.title) 탭")
        .accessibilityAddTraits(library.tabs.current.id == tab.id ? .isSelected : [])
        .contextMenu {
            Button("이름 바꾸기") { editedName = tab.name; editingTab = tab.id; holding(true) }
            Menu("종류 바꾸기") { ForEach(ClipboardTabKind.allCases, id: \.self) { kind in Button(kind.title) { library.editTabs { try $0.changeKind(tab.id, kind: kind) } } } }
            if library.tabs.items.count > 1 { Button("삭제") { deletingTab = tab.id; holding(true) } }
        }
        .onDrag { NSItemProvider(item: Data(tab.id.uuidString.utf8) as NSData, typeIdentifier: "app.ddots.clipboard-tab") }
        .onDrop(of: ["app.ddots.clipboard-tab", "app.ddots.clipboard-entry"], delegate: ClipboardTabDrop(tab: tab, library: library, targeted: $targeted))
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(Array(library.tabs.items.prefix(6))) { tab($0) }
                if library.tabs.items.count > 6 {
                    Menu {
                        ForEach(Array(library.tabs.items.dropFirst(6))) { tab in
                            Button(tab.name) { library.editTabs { $0.selected = tab.id } }
                            Menu("\(tab.name) 관리") {
                                Button("이름 바꾸기") { editedName = tab.name; editingTab = tab.id; holding(true) }
                                Menu("종류 바꾸기") { ForEach(ClipboardTabKind.allCases, id: \.self) { kind in Button(kind.title) { library.editTabs { try $0.changeKind(tab.id, kind: kind) } } } }
                                Button("삭제") { deletingTab = tab.id; holding(true) }
                                Button("맨 앞으로") { library.editTabs { $0.move(tab.id, before: $0.items[0].id) } }
                            }
                        }
                    } label: { Text("더보기").font(.system(size: 10)) }
                    .menuStyle(.borderlessButton).fixedSize().frame(height: 28).layoutPriority(1).help("나머지 탭").accessibilityLabel("더보기")
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: ClipboardTabFrames.self,
                            value: library.tabs.items.dropFirst(6).contains { $0.id == library.tabs.current.id }
                                ? [library.tabs.current.id: geometry.frame(in: .named("clipboard-tabs"))] : [:])
                    })
                    .background { if CommandLine.arguments.contains("--ui-smoke-clipboard") { ClipboardControlFrame(identifier: "clipboard-more") } }
                }
                Button { rename(); newName = ""; addingTab.toggle(); holding(addingTab) } label: { Image(systemName: "plus").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).fixedSize().layoutPriority(2).help("탭 추가").accessibilityLabel("탭 추가")
                    .background { if CommandLine.arguments.contains("--ui-smoke-clipboard") { ClipboardControlFrame(identifier: "clipboard-add") } }
            }.padding(3).coordinateSpace(name: "clipboard-tabs")
                .onPreferenceChange(ClipboardTabFrames.self) { tabFrames = $0 }
                .background(ClipboardSelection(selected: library.tabs.current.id, frames: tabFrames, reduced: reducedMotion))
                .clipShape(Capsule())
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(focusRegion == 1 ? Color.accentColor : Color.clear, lineWidth: 2))
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ink)
                    TextField(ClipboardSearch.placeholder, text: $query, prompt: Text(ClipboardSearch.placeholder).foregroundColor(ink)).font(.system(size: 11))
                        .textFieldStyle(.plain).accessibilityLabel("클립보드 검색")
                }.padding(.horizontal, 8).frame(height: 32)
                    .background(ClipboardControlsMaterial()).clipShape(RoundedRectangle(cornerRadius: 12))
                ClipboardTrashButton(library: library) { rename(); holding(true); library.confirmClear(); holding(false) }
                    .frame(width: 32, height: 32)
            }
            if editingTab != nil {
                ClipboardRenameField(text: $editedName, commit: rename).frame(height: 28).accessibilityLabel("탭 이름")
            }
            if addingTab {
                VStack {
                    TextField("탭 이름", text: $newName).accessibilityLabel("새 탭 이름")
                    Picker("종류", selection: $newKind) { ForEach(ClipboardTabKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    Button("추가") { let name = newName, kind = newKind; library.editTabs { _ = try $0.add(name: name, kind: kind) }; addingTab = false; holding(false) }
                }
            }
            if library.permissionNeeded && library.settings.enabled && !library.paused {
                VStack(alignment: .leading, spacing: 6) {
                    Label("다른 앱에서 붙여넣기 허용이 필요해요", systemImage: "lock.fill").font(.system(size: 13))
                    Text("시스템 설정 → 개인정보 보호 및 보안 → 다른 앱에서 붙여넣기 → ddots 항상 허용").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if library.permissionRequestAvailable { Button("허용 요청") { library.requestPermission() } }
                        Button("설정 열기", action: ClipboardLibrary.openSettings)
                    }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            ClipboardGridTransition(tab: library.tabs.current.id, index: library.tabs.items.firstIndex { $0.id == library.tabs.current.id } ?? 0, reduced: reducedMotion, content: AnyView(grid))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                if !library.selectedIDs.isEmpty { Text("\(library.selectedIDs.count)개 선택").font(.system(size: 10)) }
                if let notice = library.notice { Text(notice).font(.system(size: 10)).foregroundStyle(ink).lineLimit(2).accessibilityLabel(notice) }
                if library.canUndo { Button("되돌리기", action: library.undoDelete).font(.system(size: 11)).help("삭제 되돌리기 (⌘Z)") }
            }.frame(height: 24)
        }.padding(14).foregroundStyle(ink)
        .background(ClipboardKeyBridge(handler: handleKey))
        .onAppear { library.visibleShelfCount = filtered.count; searchMeaning() }
        .onChange(of: query) { _ in searchMeaning() }
        .onChange(of: library.tabs.current.id) { _ in searchMeaning() }
        .onChange(of: library.entries) { _ in searchMeaning() }
        .onChange(of: library.settings.semanticSearch) { _ in searchMeaning() }
        .onChange(of: library.settings.enabled) { _ in searchMeaning() }
        .onChange(of: filtered.map(\.id)) { _ in
            library.visibleShelfCount = filtered.count
            library.selectedIDs.formIntersection(Set(filtered.map(\.id)))
        }
        .confirmationDialog("탭을 삭제할까요? 항목은 유지됩니다.", isPresented: Binding(get: { deletingTab != nil }, set: { if !$0 { deletingTab = nil; holding(false) } })) {
            Button("삭제") { if let id = deletingTab { library.editTabs { try $0.remove(id) } }; deletingTab = nil; holding(false) }
            Button("취소", role: .cancel) { deletingTab = nil; holding(false) }
        }
    }
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let groups = Array(NSOrderedSet(array: filtered.map(group))) as? [String] ?? []
                LazyVStack(alignment: .leading, spacing: 12) {
                    if filtered.isEmpty && !library.permissionNeeded { Text("아직 없어요").foregroundStyle(ink).frame(maxWidth: .infinity).padding(30) }
                    ForEach(groups, id: \.self) { section in
                        Text(section).font(.system(size: 13, weight: .semibold))
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(100), spacing: 10, alignment: .top), count: ClipboardDrawer.columns(width: library.shelfWidth)), spacing: 8) {
                            ForEach(filtered.filter { group($0) == section }) { entry in
                                ClipboardCard(entry: entry, library: library, holding: holding, selected: library.selectedIDs.contains(entry.id) || (keyboardSelection && focusRegion == 0 && selected == entry.id) || library.restoredID == entry.id, query: query, semanticMatch: semantic.ids.contains(entry.id) && !entry.matches(query), shortcutNumber: library.commandHeld ? filtered.firstIndex(where: { $0.id == entry.id }).flatMap { $0 < 9 ? $0 + 1 : nil } : nil, select: { select(entry, flags: $0) })
                                    .frame(width: 100, height: ClipboardCardView.height(for: entry)).id(entry.id)
                            }
                        }
                    }
                }.padding(4).frame(maxWidth: .infinity, alignment: .topLeading)
            }.onChange(of: selected) { id in if let id { proxy.scrollTo(id) } }
        }
    }
    private func handleKey(_ event: NSEvent, panel: PetPanel) -> Bool {
        if library.preview.isOpen && [49, 53].contains(event.keyCode) { library.preview.close(); return true }
        let command = event.modifierFlags.contains(.command)
        if command, let character = event.charactersIgnoringModifiers, let number = Int(character), (1...9).contains(number), number <= filtered.count {
            let entry = filtered[number - 1]
            if entry.secret { library.toggleReveal(entry.id) } else { library.copy(entry) }
            return true
        }
        if command && PetPanel.shortcutKey(event) == "z" && library.canUndo { library.undoDelete(); return true }
        if command && PetPanel.shortcutKey(event) == "f" { focusRegion = 2; ClipboardKeyView.focusSearch(panel); return true }
        if event.keyCode == 53 {
            if !library.selectedIDs.isEmpty { library.selectedIDs.removeAll(); return true }
            rename(); (panel.contentView as? PetView)?.dismissClipboard(); return true }
        if event.keyCode == 48 {
            if editingTab != nil { rename() }
            focusRegion = (focusRegion + (event.modifierFlags.contains(.shift) ? 2 : 1)) % 3
            if focusRegion == 2 { ClipboardKeyView.focusSearch(panel) }
            else { panel.makeFirstResponder(panel.contentView); if focusRegion == 0 { keyboardSelection = true; selected = selected ?? filtered.first?.id } }
            return true
        }
        if panel.firstResponder is NSTextView || panel.firstResponder is NSTextField { return false }
        if event.keyCode == 49 {
            if let entry = filtered.first(where: { $0.id == (library.hoveredID ?? selected) }) ?? filtered.first { library.preview.show(entry, library: library, in: panel) }
            return true
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            if focusRegion == 1 {
                let items = library.tabs.items, index = items.firstIndex { $0.id == library.tabs.current.id } ?? 0
                let step = [123, 126].contains(event.keyCode) ? -1 : 1
                let id = items[(index + step + items.count) % items.count].id
                library.editTabs { $0.selected = id }
            } else if !filtered.isEmpty {
                focusRegion = 0; keyboardSelection = true
                let index = filtered.firstIndex { $0.id == selected } ?? 0
                let step = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? ClipboardDrawer.columns(width: library.shelfWidth) : -ClipboardDrawer.columns(width: library.shelfWidth)
                selected = filtered[max(0, min(filtered.count - 1, index + step))].id
            }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !library.selectedIDs.isEmpty { library.copy(filtered.filter { library.selectedIDs.contains($0.id) }); return true }
            if let entry = filtered.first(where: { $0.id == selected }) ?? filtered.first { library.copy(entry) }
            return true
        }
        return false
    }
}

/// Separate drop destination: external payloads cannot trigger deletion.
private struct ClipboardTrashButton: NSViewRepresentable {
    let library: ClipboardLibrary
    let action: () -> Void
    func makeNSView(context: Context) -> ClipboardTrashView { ClipboardTrashView(library: library, action: action) }
    func updateNSView(_ view: ClipboardTrashView, context: Context) { view.onClear = action }
}
final class ClipboardTrashView: NSButton {
    let library: ClipboardLibrary
    var onClear: () -> Void
    private(set) var targeted = false
    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    init(library: ClipboardLibrary, action: @escaping () -> Void) {
        self.library = library; self.onClear = action
        super.init(frame: .zero)
        title = ""; bezelStyle = .circular; imagePosition = .imageOnly
        image = NSImage(systemSymbolName: "trash", accessibilityDescription: "비우기")
        toolTip = "비우기"; setAccessibilityLabel("비우기")
        target = self; self.action = #selector(clearClicked)
        registerForDraggedTypes([.init("app.ddots.clipboard-entry")])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func clearClicked() {
        if !library.selectedIDs.isEmpty { library.delete(library.entries.filter { library.selectedIDs.contains($0.id) }) }
        else { onClear() }
    }
    private func entry(_ board: NSPasteboard) -> ClipboardEntry? {
        guard let raw = board.string(forType: .init("app.ddots.clipboard-entry")), let id = UUID(uuidString: raw) else { return nil }
        return library.entries.first { $0.id == id }
    }
    func targetDrop(_ board: NSPasteboard?) -> NSDragOperation {
        targeted = board.flatMap(entry) != nil
        image = NSImage(systemSymbolName: targeted ? "trash.fill" : "trash", accessibilityDescription: "비우기")
        contentTintColor = targeted ? .controlAccentColor : nil
        return targeted ? .copy : []
    }
    @discardableResult func receive(_ board: NSPasteboard) -> Bool {
        guard let entry = entry(board) else { _ = targetDrop(nil); return false }
        _ = targetDrop(nil); library.delete(entry); return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { targetDrop(sender.draggingPasteboard) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { targetDrop(sender.draggingPasteboard) }
    override func draggingExited(_ sender: NSDraggingInfo?) { _ = targetDrop(nil) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { entry(sender.draggingPasteboard) != nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { receive(sender.draggingPasteboard) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { _ = targetDrop(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { _ = targetDrop(nil) }
}
private struct ClipboardControlsMaterial: View {
    var body: some View {
        Capsule().fill(Color.white.opacity(0.10))
            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.5))
    }
}
private struct ClipboardRenameField: NSViewRepresentable {
    @Binding var text: String
    var commit: () -> Void
    class Coordinator: NSObject, NSTextFieldDelegate {
        var owner: ClipboardRenameField
        var outsideClick: Any?
        deinit { if let outsideClick { NSEvent.removeMonitor(outsideClick) } }
        init(_ owner: ClipboardRenameField) { self.owner = owner }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSTextField { owner.text = field.stringValue } }
        func controlTextDidEndEditing(_ notification: Notification) { owner.commit() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text); field.placeholderString = "탭 이름"; field.delegate = context.coordinator
        context.coordinator.outsideClick = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak field, weak coordinator = context.coordinator] event in
            guard let field, let window = field.window, event.window === window,
                  !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) else { return event }
            window.makeFirstResponder(nil); coordinator?.owner.commit()
            return event
        }
        DispatchQueue.main.async { field.window?.makeKey(); field.window?.makeFirstResponder(field) }; return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { context.coordinator.owner = self; if field.currentEditor() == nil { field.stringValue = text } }
}
private struct ClipboardKeyBridge: NSViewRepresentable {
    let handler: (NSEvent, PetPanel) -> Bool
    func makeNSView(context: Context) -> ClipboardKeyView { ClipboardKeyView() }
    func updateNSView(_ view: ClipboardKeyView, context: Context) { view.handler = handler; view.install() }
}
private final class ClipboardKeyView: NSView {
    var handler: ((NSEvent, PetPanel) -> Bool)?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); install() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func install() { (window as? PetPanel)?.onClipboardKey = { [weak self] event in guard let self, let panel = self.window as? PetPanel else { return false }; return self.handler?(event, panel) ?? false } }
    static func focusSearch(_ panel: PetPanel) {
        if let root = panel.contentView, let field = ClipboardSearch.field(in: root) { panel.makeKey(); panel.makeFirstResponder(field) }
    }
}
private struct ClipboardTabDrop: DropDelegate {
    var tab: ClipboardTab
    var library: ClipboardLibrary
    @Binding var targeted: UUID?
    func validateDrop(info: DropInfo) -> Bool { true }
    func dropEntered(info: DropInfo) { targeted = tab.id }
    func dropExited(info: DropInfo) { if targeted == tab.id { targeted = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: info.hasItemsConforming(to: ["app.ddots.clipboard-tab"]) || tab.kind == .custom ? .copy : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        targeted = nil
        let moving = info.hasItemsConforming(to: ["app.ddots.clipboard-tab"])
        guard moving || tab.kind == .custom else { return false }
        let type = moving ? "app.ddots.clipboard-tab" : "app.ddots.clipboard-entry"
        let providers = info.itemProviders(for: [type])
        guard !providers.isEmpty else { return false }
        for provider in moving ? Array(providers.prefix(1)) : providers {
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                guard let data, let string = String(data: data, encoding: .utf8), let id = UUID(uuidString: string) else { return }
                DispatchQueue.main.async {
                    if moving { library.editTabs { $0.move(id, before: tab.id) } }
                    else { library.membership(id, tab: tab.id, add: true) }
                }
            }
        }
        return true
    }
}
struct ClipboardCard: NSViewRepresentable {
    var entry: ClipboardEntry
    var library: ClipboardLibrary
    var holding: (Bool) -> Void
    var selected = false
    var query = ""
    var semanticMatch = false
    var shortcutNumber: Int?
    var select: (NSEvent.ModifierFlags) -> Bool = { _ in true }
    func makeNSView(context: Context) -> ClipboardCardView { ClipboardCardView(entry: entry, library: library, holding: holding) }
    func updateNSView(_ view: ClipboardCardView, context: Context) {
        view.entry = entry
        view.selected = selected; view.select = select; view.query = query; view.semanticMatch = semanticMatch; view.shortcutNumber = shortcutNumber
        view.updateAccessibility()
        view.updateProgress(library.recognitionStatus[entry.id] == "pending")
        view.needsDisplay = true
    }
}

/// Native drag sessions keep the shelf visible until the destination completes or cancels the drag.
private final class ClipboardMenuAction: NSObject {
    let perform: () -> Void
    init(_ perform: @escaping () -> Void) { self.perform = perform }
}

final class ClipboardCardView: NSView, NSDraggingSource, NSMenuDelegate {
    static func height(for entry: ClipboardEntry) -> CGFloat { 96 }
    var previewRect: CGRect {
        let height: CGFloat = 60
        return CGRect(x: 6, y: bounds.height - height - 6, width: bounds.width - 12, height: height)
    }
    var contentRect: CGRect { previewRect.insetBy(dx: 8, dy: 8) }
    var timeRect: CGRect { CGRect(x: 6, y: previewRect.minY - 24, width: bounds.width - 12, height: 16) }
    var entry: ClipboardEntry
    let library: ClipboardLibrary
    let holding: (Bool) -> Void
    var selected = false
    var query = ""
    var semanticMatch = false
    var shortcutNumber: Int?
    var select: (NSEvent.ModifierFlags) -> Bool = { _ in true }
    private var hovered = false
    private(set) var hoverOpacity: CGFloat = 0
    private var hoverTimer: Timer?
    private func animateHover(_ value: CGFloat) {
        hoverTimer?.invalidate()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") {
            hoverOpacity = value; needsDisplay = true; return
        }
        let start = ProcessInfo.processInfo.systemUptime, from = hoverOpacity
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let fraction = min(1, (ProcessInfo.processInfo.systemUptime - start) / 0.15)
            self.hoverOpacity = from + (value - from) * (1 - pow(1 - fraction, 3)); self.needsDisplay = true
            if fraction == 1 { timer.invalidate(); self.hoverTimer = nil }
        }
    }
    private var tracking: NSTrackingArea?
    private let progress = NSProgressIndicator()
    private var revealObservation: AnyCancellable?
    private var thumbnailPending = true
    private var image: NSImage?
    private var duration: String?
    private(set) var revealsSecret = false
    private var startingPoint: NSPoint?
    private var copiesOnMouseUp = true
    private var dragging = false
    private var dragToken: UUID?
    private var activeDragSession = false
    init(entry: ClipboardEntry, library: ClipboardLibrary, holding: @escaping (Bool) -> Void) {
        self.entry = entry; self.library = library; self.holding = holding
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true; layer?.cornerRadius = 12
        registerForDraggedTypes([.init("app.ddots.clipboard-entry")])
        setAccessibilityElement(true); setAccessibilityRole(.button); updateAccessibility()
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("미리보기 준비 중"); addSubview(progress)
        revealObservation = library.$revealedID.sink { [weak self] id in
            guard let self else { return }; self.setRevealed(id == self.entry.id)
        }
        library.thumbnail(entry) { [weak self] image, duration in guard let self else { return }; self.image = image; self.duration = duration; self.thumbnailPending = false; self.updateProgress(self.library.recognitionStatus[self.entry.id] == "pending"); self.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { hoverTimer?.invalidate() }
    func updateAccessibility() {
        let name = entry.secret ? "비밀 · ••••••" : entry.title
        let source = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.source)?.deletingPathExtension().lastPathComponent ?? entry.source
        setAccessibilityLabel("\(name), \(source), \(entry.copiedAt.formatted()), \(entry.pinned ? "고정됨" : "고정 안 됨")" + (semanticMatch && !entry.secret ? ", AI 검색 결과" : ""))
        setAccessibilityValue(selected ? "선택됨" : nil)
        setAccessibilityHelp(entry.secret ? "클릭하여 비밀 보기 또는 숨기기, Return 또는 메뉴로 복사" : "Return으로 복사, 보조 메뉴에서 고정·탭에 넣기·삭제")
    }
    func updateProgress(_ recognizing: Bool) {
        let video = entry.kind == .video || entry.files.contains { ClipboardEntry.videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        if !entry.secret && (recognizing || (video && thumbnailPending)) { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
    }
    override func layout() { super.layout(); progress.frame = CGRect(x: bounds.width - 23, y: previewRect.minY + 4, width: 16, height: 16) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; animateHover(1); library.hoveredID = entry.id }
    override func mouseExited(with event: NSEvent) { hovered = false; animateHover(0); if library.hoveredID == entry.id { library.hoveredID = nil } }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { if entry.secret { library.toggleReveal(entry.id) } else { library.copy(entry) }; return true }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(); menu.delegate = self
        if !library.selectedIDs.isEmpty && library.selectedIDs.contains(entry.id) {
            let copy = NSMenuItem(title: "선택", action: nil, keyEquivalent: ""); copy.isEnabled = false
            copy.title = "\(library.selectedIDs.count)개 선택"; menu.addItem(copy)
        }
        func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(performMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = ClipboardMenuAction(action); return item
        }
        if entry.secret {
            menu.addItem(item("복사") { [self] in library.copy(library.selection(or: entry)) })
        }
        if entry.kind == .text { menu.addItem(item("서식 없이 복사") { [self] in library.copy(entry, plain: true) }) }
        menu.addItem(item(entry.pinned ? "고정 해제" : "고정") { [self] in library.pin(entry) })
        let custom = library.tabs.items.filter { $0.kind == .custom }
        if !custom.isEmpty {
            let parent = NSMenuItem(title: "탭에 넣기", action: nil, keyEquivalent: "")
            let tabs = NSMenu()
            for tab in custom { tabs.addItem(item(tab.name) { [self] in for selected in library.selection(or: entry) { library.membership(selected.id, tab: tab.id, add: true) } }) }
            parent.submenu = tabs; menu.addItem(parent)
        }
        if library.tabs.current.kind == .custom {
            let tab = library.tabs.current.id
            menu.addItem(item("이 탭에서 빼기") { [self] in library.membership(entry.id, tab: tab, add: false) })
        }
        if entry.kind == .files, entry.files.contains(where: { FileManager.default.fileExists(atPath: $0) }) { menu.addItem(item("Finder에서 보기") { [self] in NSWorkspace.shared.activateFileViewerSelecting(entry.files.map { URL(fileURLWithPath: $0) }) }) }
        menu.addItem(.separator())
        if entry.kind == .text && !entry.secret {
            let parent = NSMenuItem(title: "글자 정리", action: nil, keyEquivalent: ""), transforms = NSMenu()
            for transform in ClipboardTextTransform.allCases where transform.apply(entry.text ?? "") != nil {
                transforms.addItem(item(transform.rawValue) { [self] in library.transform(entry, using: transform) })
            }
            parent.submenu = transforms; menu.addItem(parent)
        }
        menu.addItem(item("삭제") { [self] in library.delete(library.selection(or: entry)) })
        return menu
    }
    @objc private func performMenu(_ item: NSMenuItem) { (item.representedObject as? ClipboardMenuAction)?.perform() }
    func menuWillOpen(_ menu: NSMenu) { holding(true) }
    func menuDidClose(_ menu: NSMenu) { holding(false) }
    var displaysThumbnail: Bool { image != nil }
    var missingOriginal: Bool { entry.kind == .files && !entry.files.contains { FileManager.default.fileExists(atPath: $0) } }
    var auxiliaryText: String { entry.copiedAt.formatted(.relative(presentation: .named)) }
    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let width = max(1, Int(bounds.width * scale)), height = max(1, Int(bounds.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale); context.clear(bounds)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        effectiveAppearance.performAsCurrentDrawingAppearance { drawContents() }
        NSGraphicsContext.restoreGraphicsState()
        layer?.contentsScale = scale; layer?.contents = context.makeImage()
    }
    private func drawContents() {
        let card = previewRect
        let dark = ClipboardAppearance.isDark(effectiveAppearance)
        let ink = ClipboardAppearance.primary(dark: dark)
        if hoverOpacity > 0 {
            let outer = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
            if dark { NSColor.black.withAlphaComponent(ClipboardAppearance.darkHoverShade * hoverOpacity).setFill(); outer.fill() }
            ink.withAlphaComponent(0.12 * hoverOpacity).setFill(); outer.fill()
            ink.withAlphaComponent(0.25 * hoverOpacity).setStroke(); outer.lineWidth = 0.5; outer.stroke()
        }
        let preview = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        if dark { NSColor.black.withAlphaComponent(ClipboardAppearance.darkPreviewShade).setFill(); preview.fill() }
        NSColor.white.withAlphaComponent(0.09).setFill(); preview.fill(); ink.withAlphaComponent(0.14).setStroke(); preview.lineWidth = 0.5; preview.stroke()
        if selected || window?.firstResponder === self {
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
            NSColor.keyboardFocusIndicatorColor.setStroke(); focus.lineWidth = 2; focus.stroke()
        }
        if let image, !entry.secret || revealsSecret {
            NSGraphicsContext.saveGraphicsState(); preview.addClip()
            let scale = max(card.width / max(1, image.size.width), card.height / max(1, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: card.midX - size.width / 2, y: card.midY - size.height / 2, width: size.width, height: size.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let textHeight = min(contentRect.height, previewContent.boundingRect(with: contentRect.size, options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
            NSColor.controlBackgroundColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: CGRect(x: contentRect.minX - 3, y: contentRect.maxY - textHeight - 2, width: contentRect.width + 6, height: textHeight + 4), xRadius: 3, yRadius: 3).fill()
        }
        previewContent.draw(in: contentRect)
        if entry.pinned { drawSymbol("pin.fill", in: CGRect(x: card.maxX - 15, y: card.maxY - 15, width: 10, height: 10)) }
        draw(auxiliaryText, in: timeRect, size: 10, centered: true, secondary: true)
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.source) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.draw(in: CGRect(x: 6, y: timeRect.minY, width: 16, height: 16))
        }
        if semanticMatch && !entry.secret {
            let badge = CGRect(x: card.maxX - 20, y: card.minY + 2, width: 18, height: 12)
            (dark ? NSColor.black : .white).setFill(); NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            draw("AI", in: badge, size: 9, centered: true)
        }
        if let number = shortcutNumber {
            let badge = CGRect(x: 0, y: bounds.height - 12, width: 12, height: 12)
            NSColor.black.setFill(); NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
            (String(number) as NSString).draw(in: badge, withAttributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.white])
        }
    }
    private func drawSymbol(_ symbol: String, in rect: CGRect) {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil),
              let mask = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState(); context.clip(to: rect, mask: mask)
        context.setFillColor(NSColor.labelColor.cgColor); context.fill(rect); context.restoreGState()
    }
    private func draw(_ text: String, in rect: CGRect, size: CGFloat, centered: Bool, secondary: Bool = false) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = centered ? .center : .left; paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: secondary ? .regular : .medium), .foregroundColor: ClipboardAppearance.primary(effectiveAppearance), .paragraphStyle: paragraph])
    }
    /// One top-leading text block for every kind; symbols are inline, never separate centred badges.
    var previewContent: NSAttributedString {
        let text: String, symbol: String?
        let video = entry.kind == .video || entry.files.contains { ClipboardEntry.videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        if entry.secret {
            symbol = "lock.fill"; text = revealsSecret ? (entry.text ?? "") : "••••••"
        } else {
            switch entry.kind {
            case .text: symbol = nil; text = entry.preview
            case .image: symbol = "photo"; text = entry.matchesRecognizedText(query) ? "이미지\n이미지 속 글자\n일치" : "이미지"
            case .video: symbol = "film"; text = "동영상\n▶ " + (duration ?? "—")
            case .files:
                symbol = displaysThumbnail ? nil : "doc"; text = entry.title + "\n\(entry.files.count)개" + (missingOriginal ? "\n원본 없음" : video ? " · ▶ " + (duration ?? "—") : "")
            }
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .left; paragraph.lineBreakMode = .byTruncatingTail
        let value = NSMutableAttributedString(string: "", attributes: [:])
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11, weight: .regular)) {
            image.size = NSSize(width: 12, height: 12)
            let attachment = NSTextAttachment(); attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
            value.append(NSAttributedString(attachment: attachment)); value.append(NSAttributedString(string: " "))
        }
        value.append(NSAttributedString(string: text))
        let range = NSRange(location: 0, length: value.length)
        value.addAttributes([.font: NSFont.systemFont(ofSize: 11), .foregroundColor: ClipboardAppearance.primary(effectiveAppearance), .paragraphStyle: paragraph], range: range)
        let newline = (value.string as NSString).range(of: "\n")
        value.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: NSRange(location: 0, length: newline.location == NSNotFound ? value.length : newline.location))
        if entry.kind == .text && !entry.secret, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: value.string, range: range) {
                value.addAttributes([.foregroundColor: ClipboardAppearance.primary(effectiveAppearance), .underlineColor: NSColor.controlAccentColor, .underlineStyle: NSUnderlineStyle.single.rawValue], range: match.range)
            }
        }
        if !entry.secret && !query.isEmpty {
            let string = value.string as NSString
            var remaining = NSRange(location: 0, length: string.length)
            while remaining.length > 0 {
                let found = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: remaining)
                if found.location == NSNotFound { break }
                value.addAttribute(.backgroundColor, value: NSColor.systemPink.withAlphaComponent(0.35), range: found)
                remaining = NSRange(location: found.location + found.length, length: string.length - found.location - found.length)
            }
        }
        return value
    }
    private func setRevealed(_ value: Bool) {
        guard revealsSecret != value else { return }
        revealsSecret = value; needsDisplay = true
        if !value && entry.secret { image = nil }
        if value { library.thumbnail(entry, reveal: true) { [weak self] image, duration in
            guard let self, self.revealsSecret else { return }; self.image = image; self.duration = duration; self.thumbnailPending = false
            self.updateProgress(self.library.recognitionStatus[self.entry.id] == "pending"); self.needsDisplay = true
        } }
    }
    override func mouseDown(with event: NSEvent) {
        copiesOnMouseUp = select(event.modifierFlags); startingPoint = convert(event.locationInWindow, from: nil)
        dragging = false; dragToken = nil; activeDragSession = false
    }
    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        if dragging && !activeDragSession { dragToken = nil; dragging = false; holding(false) }
        if !wasDragging && copiesOnMouseUp { if entry.secret { library.toggleReveal(entry.id) } else { library.copy(entry) } }
        startingPoint = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, !revealsSecret, let start = startingPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 3 else { return }
        dragging = true; holding(true)
        let token = UUID(); dragToken = token
        library.writers(library.selection(or: entry), forDrag: true) { [weak self] writers in
            guard let self else { return }
            guard self.dragToken == token else { return }
            guard !writers.isEmpty, self.window != nil, !self.isHiddenOrHasHiddenAncestor else {
                self.dragToken = nil; self.dragging = false; self.holding(false); return
            }
            let items = writers.map { writer -> NSDraggingItem in
                if let item = writer as? NSPasteboardItem, item.string(forType: .init("app.ddots.clipboard-entry")) == nil { item.setString(self.entry.id.uuidString, forType: .init("app.ddots.clipboard-entry")) }
                let item = NSDraggingItem(pasteboardWriter: writer)
                let preview = NSImage(size: self.bounds.size)
                preview.lockFocus()
                if let bitmap = self.bitmapImageRepForCachingDisplay(in: self.bounds) {
                    self.cacheDisplay(in: self.bounds, to: bitmap)
                    NSImage(cgImage: bitmap.cgImage!, size: self.bounds.size).draw(in: self.bounds, from: .zero, operation: .sourceOver, fraction: 0.65)
                }
                if writers.count > 1 {
                    let badge = CGRect(x: self.bounds.maxX - 28, y: 4, width: 24, height: 20)
                    NSColor.black.setFill(); NSBezierPath(roundedRect: badge, xRadius: 8, yRadius: 8).fill()
                    (String(writers.count) as NSString).draw(in: badge, withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white])
                }
                preview.unlockFocus()
                item.setDraggingFrame(CGRect(x: start.x, y: start.y, width: self.bounds.width, height: self.bounds.height), contents: preview)
                return item
            }
            self.activeDragSession = true
            self.beginDraggingSession(with: items, event: event, source: self)
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard entry.pinned, let raw = sender.draggingPasteboard.string(forType: .init("app.ddots.clipboard-entry")),
              let id = UUID(uuidString: raw), library.entries.contains(where: { $0.id == id && $0.pinned }) else { return [] }
        return .move
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .move, let raw = sender.draggingPasteboard.string(forType: .init("app.ddots.clipboard-entry")), let id = UUID(uuidString: raw) else { return false }
        library.reorderPinned(id, before: entry.id); return true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? [.copy, .move] : .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { holding(false); dragging = false; dragToken = nil; activeDragSession = false; startingPoint = nil }
}

/// Both tab feedback surfaces use the same clock and easing; no window geometry participates.
private enum ClipboardTabMotion {
    static let duration: TimeInterval = 0.22
    static func progress(_ start: TimeInterval) -> CGFloat {
        let t = CGFloat(min(1, max(0, (ProcessInfo.processInfo.systemUptime - start) / duration)))
        return t * t * (3 - 2 * t)
    }
}
private struct ClipboardTabFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, rhs in rhs }) }
}
private struct ClipboardSelection: NSViewRepresentable {
    var selected: UUID
    var frames: [UUID: CGRect]
    var reduced: Bool
    func makeNSView(context: Context) -> ClipboardSelectionView { ClipboardSelectionView() }
    func updateNSView(_ view: ClipboardSelectionView, context: Context) { view.select(selected, frames: frames, reduced: reduced) }
}
final class ClipboardSelectionView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private let highlight = NSView()
    private var timer: Timer?
    private var target = CGRect.zero
    private(set) var tabRects: [UUID: CGRect] = [:]
    var selectionRect: CGRect { highlight.frame }
    init() {
        super.init(frame: .zero)
        highlight.wantsLayer = true
        addSubview(highlight)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColor() }
    private func updateColor() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        highlight.layer?.backgroundColor = ClipboardAppearance.selection(dark: dark).cgColor
    }
    func select(_ selected: UUID, frames: [UUID: CGRect], reduced: Bool) {
        tabRects = frames
        guard let rect = frames[selected] else { return }
        guard !rect.isEmpty, rect != target else { return }
        timer?.invalidate(); target = rect; updateColor()
        highlight.layer?.cornerRadius = rect.height / 2
        let from = highlight.frame
        guard !from.isEmpty, !reduced else { highlight.frame = rect; return }
        let start = ProcessInfo.processInfo.systemUptime
        let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let p = ClipboardTabMotion.progress(start)
            self.highlight.frame = CGRect(x: from.minX + (rect.minX - from.minX) * p,
                                          y: from.minY + (rect.minY - from.minY) * p,
                                          width: from.width + (rect.width - from.width) * p,
                                          height: from.height + (rect.height - from.height) * p)
            if p == 1 { timer.invalidate(); self.timer = nil }
        }
        timer = tick; RunLoop.main.add(tick, forMode: .common)
    }
}
private struct ClipboardGridTransition: NSViewRepresentable {
    let tab: UUID
    let index: Int
    let reduced: Bool
    let content: AnyView
    func makeNSView(context: Context) -> ClipboardGridView { ClipboardGridView() }
    func updateNSView(_ view: ClipboardGridView, context: Context) { view.show(content, tab: tab, index: index, reduced: reduced) }
}
/// The outgoing bitmap is visual only. The incoming live view owns every click and accessibility child.
final class ClipboardGridView: NSView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var outgoing: NSImageView?
    private var timer: Timer?
    private var tab: UUID?
    private var index = 0
    private(set) var transitionStarted: TimeInterval?
    private(set) var transitionFinished: TimeInterval?
    private(set) var offset: CGFloat = 0
    var incomingAlpha: CGFloat { host.alphaValue }
    var outgoingAlpha: CGFloat { outgoing?.alphaValue ?? 0 }
    var isTransitioning: Bool { outgoing != nil }
    init() {
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
        host.sizingOptions = []; addSubview(host)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate() }
    override func layout() { super.layout(); host.frame = bounds.offsetBy(dx: offset, dy: 0); outgoing?.frame = bounds }
    func show(_ content: AnyView, tab: UUID, index: Int, reduced: Bool) {
        let changed = self.tab != nil && self.tab != tab
        let direction = index >= self.index ? 1 : -1
        self.tab = tab; self.index = index
        if changed {
            layoutSubtreeIfNeeded(); displayIfNeeded()
            var image: NSImage?
            if let bitmap = bitmapImageRepForCachingDisplay(in: bounds) {
                cacheDisplay(in: bounds, to: bitmap)
                let value = NSImage(size: bounds.size); value.addRepresentation(bitmap); image = value
            }
            timer?.invalidate(); outgoing?.removeFromSuperview()
            let snapshot = NSImageView(frame: bounds); snapshot.image = image; snapshot.imageScaling = .scaleAxesIndependently
            snapshot.setAccessibilityElement(false)
            outgoing = snapshot; addSubview(snapshot, positioned: .below, relativeTo: host)
            host.alphaValue = 0; offset = reduced ? 0 : CGFloat(direction) * 8
            host.frame = bounds.offsetBy(dx: offset, dy: 0)
            transitionStarted = ProcessInfo.processInfo.systemUptime; transitionFinished = nil
        }
        host.rootView = content
        if changed {
            let start = transitionStarted!
            let startOffset = offset
            let tick = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                let p = ClipboardTabMotion.progress(start)
                self.host.alphaValue = p; self.outgoing?.alphaValue = 1 - p
                self.offset = startOffset * (1 - p); self.host.frame = self.bounds.offsetBy(dx: self.offset, dy: 0)
                if p == 1 {
                    timer.invalidate(); self.timer = nil; self.outgoing?.removeFromSuperview(); self.outgoing = nil
                    self.transitionFinished = ProcessInfo.processInfo.systemUptime
                }
            }
            timer = tick; RunLoop.main.add(tick, forMode: .common)
        }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? host.hitTest(local) ?? host : nil
    }
}

/// A measurement probe for the native-event smoke; absent from the regular application's view tree.
private struct ClipboardControlFrame: NSViewRepresentable {
    let identifier: String
    func makeNSView(context: Context) -> NSView {
        let view = PetCoverView()
        if CommandLine.arguments.contains("--ui-smoke-clipboard") { view.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
