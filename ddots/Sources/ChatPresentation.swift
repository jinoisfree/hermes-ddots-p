import AppKit
import SwiftUI

struct ChatRow: Identifiable {
    var message: ChatMessage
    var showsSpeaker: Bool
    var showsDay: Bool
    var id: String { message.id }
}

final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] { didSet { rebuildRows() } }
    @Published var calendarEvents: [CalendarEntry] = []
    @Published var rows: [ChatRow] = []
    @Published var viewportWidth = PetLayout.expandedSize.width
    var bubbleWidth: CGFloat { max(ChatMetrics.minimumBubbleWidth,viewportWidth*ChatMetrics.bubbleWidthFraction) }
    private var resizingViewport: (point: CGPoint, bottom: Bool)?
    func beginResize() {
        if let scrollView { resizingViewport = (scrollView.contentView.bounds.origin,nearBottom) }
    }
    func adjustAfterResize() {
        guard let saved = resizingViewport else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.expanded, let scroll = self.scrollView, let document = scroll.documentView else { return }
            document.layoutSubtreeIfNeeded()
            let point = saved.bottom ? CGPoint(x:0,y:max(0,document.bounds.height-scroll.contentView.bounds.height)) : saved.point
            scroll.contentView.scroll(to:point); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    func finishResize() {
        adjustAfterResize()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in self?.adjustAfterResize(); self?.resizingViewport = nil }
    }
    @Published var draft = ""
    @Published var notice: String?
    @Published var canSend = false
    @Published var title = "Hermes"
    @Published var expanded = false { didSet { if !expanded { cancelEntryViewport() } } }
    @Published var sending = false
    @Published var needsAutomation = false
    @Published var avatars: [String: ProfileAvatar] = [:] { didSet { updatePalettes() } }
    @Published var characters: [ChatCharacter] = [] { didSet { updatePalettes() } }
    @Published var expandedReplies = Set<String>()
    @Published var focusDraftRevision = 0
    /// True while the caret is in the draft, so a key meant for it is not taken for one in the search field.
    var composerFocused = false
    @Published var darkPalettes: [String: CharacterPalette] = [:]
    @Published var lightPalettes: [String: CharacterPalette] = [:]
    private var searchHighlight = ""
    var rowSearchInputs: [String?] { [searchTargetID, searchHighlight] }
    private(set) var searchTargetID: String?
    struct SearchSegment: Identifiable {
        var id: String
        var text: AttributedString
        var match: Bool
    }
    func searchSegments(_ message: ChatMessage, text: AttributedString) -> [SearchSegment]? {
        guard searchTargetID == message.id, !searchHighlight.isEmpty,
              let match = text.range(of: searchHighlight, options: .caseInsensitive) else { return nil }
        let characters = text.characters
        var start = match.lowerBound, end = match.upperBound
        while start > text.startIndex {
            let previous = characters.index(before: start)
            if characters[previous] == "\n" { break }
            start = previous
        }
        while end < text.endIndex && characters[end] != "\n" { end = characters.index(after: end) }
        var segments: [SearchSegment] = []
        if start > text.startIndex {
            segments.append(SearchSegment(id:message.id+":before",text:AttributedString(text[..<characters.index(before:start)]),match:false))
        }
        segments.append(SearchSegment(id:message.id+":match",text:AttributedString(text[start..<end]),match:true))
        if end < text.endIndex {
            segments.append(SearchSegment(id:message.id+":after",text:AttributedString(text[characters.index(after:end)...]),match:false))
        }
        return segments
    }
    private(set) var smokeFrames: [String: CGRect] = [:]
    func recordFrame(_ key: String, _ frame: CGRect) { smokeFrames[key] = frame }
    func palette(_ profile: String, dark: Bool) -> CharacterPalette {
        (dark ? darkPalettes : lightPalettes)[profile] ?? CharacterPalette.make(hue: nil, dark: dark)
    }
    private func updatePalettes() {
        let colors = avatars.filter { $0.value.hasProfileColor }.mapValues(\.color)
        let hues = CharacterPalette.hues(characters: characters, colors: colors)
        darkPalettes = hues.mapValues { CharacterPalette.make(hue: $0, dark: true) }
        lightPalettes = hues.mapValues { CharacterPalette.make(hue: $0, dark: false) }
    }
    func callCharacter(_ character: ChatCharacter) {
        draft = CharacterCall.toggled(draft, name: character.name, characters: characters)
        if searchOpen { closeSearch() }
        focusDraftRevision += 1
    }
    private var replyHeights: [String: CGFloat] = [:]
    private var replyHeightBases: [String: CGFloat] = [:]
    var onReplyLayout: (() -> Void)?
    var replyExtraHeight: CGFloat {
        replyHeightBases.reduce(0) { $0 + max(0, (replyHeights[$1.key] ?? $1.value) - $1.value) }
    }
    func measureReply(_ id: String, height: CGFloat) {
        guard abs((replyHeights[id] ?? 0) - height) > 0.5 else { return }
        replyHeights[id] = height
        if replyHeightBases[id] != nil { onReplyLayout?() }
    }
    func releaseReplyHeight(_ id: String) {
        let had = replyHeightBases.removeValue(forKey: id) != nil
        replyHeights[id] = nil
        if had { onReplyLayout?() }
    }
    func acceptManualReplySize() { replyHeightBases = [:] }
    func toggleReply(_ id: String) {
        if expandedReplies.contains(id) {
            expandedReplies.remove(id); replyHeightBases[id] = nil
        } else {
            replyHeightBases[id] = replyHeights[id]
            expandedReplies.insert(id)
        }
        onReplyLayout?()
    }
    private struct DisplayKey: Equatable {
        var body: String
        var fromUser: Bool
        var expanded: Bool
        var highlight: String
    }
    private var foldingMemo: [String: (body: String, folds: Bool)] = [:]
    private var displayMemo: [String: (key: DisplayKey, text: AttributedString)] = [:]
    func needsFolding(_ message: ChatMessage) -> Bool {
        if let memo = foldingMemo[message.id], memo.body == message.body { return memo.folds }
        let folds = LongReply.needsFolding(message.body)
        if foldingMemo.count >= 800 { foldingMemo.removeAll(keepingCapacity: true) }
        foldingMemo[message.id] = (message.body, folds)
        return folds
    }
    func displayedText(_ message: ChatMessage) -> AttributedString {
        let key = DisplayKey(body: message.body, fromUser: message.fromUser,
                             expanded: expandedReplies.contains(message.id),
                             highlight: message.id == highlightedID ? searchHighlight : "")
        if let memo = displayMemo[message.id], memo.key == key { return memo.text }
        let full = renderedText(message)
        var text = full
        if !message.fromUser && !expandedReplies.contains(message.id) && needsFolding(message) {
            let preview = LongReply.preview(String(full.characters))
            let end = full.characters.index(full.characters.startIndex, offsetBy: preview.count)
            text = AttributedString(full[..<end])
        }
        if message.id == highlightedID, !searchHighlight.isEmpty {
            var start = text.startIndex
            while start < text.endIndex, let range = text[start...].range(of: searchHighlight, options: .caseInsensitive) {
                text[range].backgroundColor = Color.yellow
                text[range].foregroundColor = Color.black
                start = range.upperBound
            }
        }
        if displayMemo.count >= 800 { displayMemo.removeAll(keepingCapacity: true) }
        displayMemo[message.id] = (key, text)
        return text
    }
    @Published var typing: [TypingIndicator] = []
    @Published var searchOpen = false
    @Published var query = "" { didSet { onSearch?(query) } }
    @Published var results: [ChatMessage] = []
    @Published var searching = false
    @Published var selection = 0
    @Published var historical = false { didSet { if historical { cancelEntryViewport() } } }
    @Published var loadingOlder = false
    @Published var hasOlder = true
    @Published var highlightedID: String?
    @Published var scrollRevision = 0
    var scrollTarget = "chat-bottom"
    var didInitialScroll = false
    var nearBottom = true
    var userScrollGeneration = 0 { didSet { if oldValue != userScrollGeneration { cancelEntryViewport() } } }
    weak var scrollView: NSScrollView?
    private struct EntryViewport {
        let revision: Int
        let scrolls: Int
        let awaitingFirstData: Bool
        var pending: Bool
        var proxyIssued = false
    }
    private var entryViewport: EntryViewport?
    private weak var entryHiddenScroll: NSScrollView?
    private weak var entryBottom: NSView?
    private var entryBottomRevision = -1
    private var entryBottomID: String?
    private var aligningEntry = false
    var entryViewportActive: Bool { entryViewport != nil }
    var entryViewportPending: Bool { entryViewport?.pending == true }
    var entryViewportDiagnostic: String {
        "active=\(entryViewportActive) pending=\(entryViewportPending) revision=\(scrollRevision) marker=\(entryBottomRevision) scrolls=\(userScrollGeneration) alpha=\(scrollView?.alphaValue ?? -1)"
    }
    /// An entry owns subsequent layout corrections until the reader or another target takes over.
    /// Only the first layout is hidden; ordinary new replies continue to be visible while following.
    func beginEntryViewport(hideUntilReady: Bool = true) {
        entryViewport = EntryViewport(revision: scrollRevision, scrolls: userScrollGeneration,
                                      awaitingFirstData: hideUntilReady && messages.isEmpty,
                                      pending: hideUntilReady && !messages.isEmpty)
        if entryViewportPending, let scrollView { hideEntry(scrollView) }
        else { revealEntry() }
    }
    func takeEntryProxyRequest() -> Bool {
        guard var entry = entryViewport, entry.revision == scrollRevision, !entry.proxyIssued else { return false }
        entry.proxyIssued = true; entryViewport = entry
        return true
    }
    func realizeEntryProxy(_ work: () -> Void) {
        let wasAligning = aligningEntry; aligningEntry = true
        work()
        aligningEntry = wasAligning
    }
    /// An origin change can also be SwiftUI refining its lazy estimates. Actual input cancels ownership
    /// through the probe; bounds notifications only tell us when the viewport needs its layout aligned.
    func entryViewportChanged(from before: CGRect, to after: CGRect) {
        guard !aligningEntry else { return }
        if entryViewportPending || before.size != after.size { _ = prepareEntryViewport() }
    }
    private func hideEntry(_ scroll: NSScrollView) {
        if entryHiddenScroll !== scroll { revealEntry(); entryHiddenScroll = scroll }
        scroll.alphaValue = 0
    }
    private func revealEntry() { entryHiddenScroll?.alphaValue = 1; entryHiddenScroll = nil }
    private func cancelEntryViewport() { entryViewport = nil; revealEntry() }
    /// Called by the bottom marker after its current SwiftUI content has actually been laid out.
    func entryBottomLaidOut(_ view: NSView, revision: Int, lastID: String?) {
        entryBottom = view; entryBottomRevision = revision; entryBottomID = lastID
        _ = prepareEntryViewport()
    }
    /// Called after host/document layout, before capture or presentation. No timer chooses when to reveal text.
    @discardableResult func prepareEntryViewport() -> Bool {
        guard var entry = entryViewport else { return true }
        guard expanded, !historical, entry.revision == scrollRevision, entry.scrolls == userScrollGeneration else {
            cancelEntryViewport(); return true
        }
        guard !aligningEntry else { return !entry.pending }
        guard let scroll = scrollView, let document = scroll.documentView,
              scroll.contentView.bounds.height > 0, document.bounds.height > 0 else { return !entry.pending }
        if entry.pending { hideEntry(scroll) }
        aligningEntry = true
        defer { aligningEntry = false }
        let clip = scroll.contentView, before = document.bounds.size
        let y = document.isFlipped ? max(document.bounds.minY, document.bounds.maxY - clip.bounds.height) : document.bounds.minY
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if abs(clip.bounds.minY - y) > 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y)); scroll.reflectScrolledClipView(clip)
        }
        CATransaction.commit()
        // Moving the hidden viewport also realizes the lazy end if the initial proxy request preceded its layout.
        // Estimated height can guide that move, but only the current measured marker can reveal the content.
        guard let bottom = entryBottom, entryBottomRevision == entry.revision,
              entryBottomID == messages.last?.id, bottom.isDescendant(of: document), bottom.bounds.height > 0 else { return !entry.pending }
        let marker = bottom.convert(bottom.bounds, to: document)
        let visible = clip.documentVisibleRect
        guard document.bounds.size == before, abs(clip.bounds.minY - y) <= 1,
              marker.intersects(visible) else { return !entry.pending }
        entry.pending = false; entryViewport = entry; nearBottom = true
        revealEntry()
        return true
    }
    /// Opening the conversation or returning to its tab starts at the newest line, including a page still loading.
    /// Drafts and expanded replies belong to the conversation and are left alone.
    func enterLatest() {
        resetPage()
        nearBottom = true
        requestScroll("chat-bottom")
        beginEntryViewport()
    }
    private var latest: [ChatMessage] = []
    private var visibleTimelineMemo = ChatTimelineMemo()
    private var older: [ChatMessage] = []
    private var count = 40
    private var sessionToken = ""
    private var rendering: [String: (String, AttributedString)] = [:]
    var onCollapse: (() -> Void)?
    var onDragBegan: ((CGPoint) -> Void)?
    var onHeaderDoubleClick: (() -> Void)?
    var onDragChanged: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onAutomation: (() -> Void)?
    var onSend: ((String) -> Void)?
    var onAction: ((PetAction) -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onSetup: (() -> Void)?
    var onSearch: ((String) -> Void)?
    var onSelectResult: ((ChatMessage) -> Void)?
    var onOlder: ((ChatMessage?) -> Void)?

    func receive(_ messages: [ChatMessage], session: String = "") {
        let changedSession = !sessionToken.isEmpty && !session.isEmpty && session != sessionToken
        if !session.isEmpty { sessionToken = session }
        let newLast = latest.last?.id != messages.last?.id
        latest = messages
        if changedSession { older = []; count = 40; historical = false; hasOlder = true }
        guard !historical else { return }
        let merged = visibleTimelineMemo.merge(older + latest, pending: [], limit: max(count,latest.count + older.count))
        let visible = Array(merged.suffix(count))
        if self.messages != visible { self.messages = visible }
        if expanded, didInitialScroll, changedSession || (newLast && nearBottom) { requestScroll("chat-bottom") }
    }
    func resetPage() {
        let reset = historical || count > 40
        count = 40; older = []; historical = false; hasOlder = true; searchTargetID = nil
        receive(latest)
        if reset { requestScroll("chat-bottom") }
    }
    func previousPage(_ loaded: [ChatMessage]) {
        loadingOlder = false; hasOlder = loaded.count >= 40
        let anchor = messages.first?.id
        older = ChatTimeline.merge(older + loaded, pending: [], limit: older.count + loaded.count)
        count += 40; receive(latest)
        if let anchor { requestScroll(anchor) }
    }
    func loadOlder() {
        guard !loadingOlder else { return }
        loadingOlder = true; onOlder?(messages.first)
    }
    func showContext(_ context: [ChatMessage], target: String) {
        guard context.contains(where: { $0.id == target }) else { return }
        searchTargetID = target
        expandedReplies.insert(target); searchHighlight = query.trimmingCharacters(in: .whitespacesAndNewlines)
        historical = true; searchOpen = false; messages = context; highlightedID = target
        requestScroll(target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if self?.highlightedID == target { self?.highlightedID = nil }
        }
    }
    func requestScroll(_ id: String) {
        let continuingEntry = id == "chat-bottom" && entryViewportActive
        let hidden = entryViewportPending || entryViewport?.awaitingFirstData == true
        if !continuingEntry { cancelEntryViewport() }
        scrollTarget = id; scrollRevision += 1
        if continuingEntry { beginEntryViewport(hideUntilReady: hidden) }
    }
    func openSearch() { searchOpen = true; selection = 0; onSearch?(query) }
    func closeSearch() { searchOpen = false; onSearch?("") }
    func escape() { if searchOpen { closeSearch() } else { onCollapse?() } }
    func moveSelection(_ delta: Int) { selection = min(max(0,selection + delta),max(0,results.count-1)) }
    func chooseSelection() { if results.indices.contains(selection) { onSelectResult?(results[selection]) } }
    func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "f" || event.charactersIgnoringModifiers == "ㄹ" { openSearch(); return true }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        if event.keyCode == 53 { escape(); return true }
        guard searchOpen else { return false }
        if event.keyCode == 125 { moveSelection(1); return true }
        if event.keyCode == 126 { moveSelection(-1); return true }
        if event.keyCode == 36 { chooseSelection(); return true }
        return false
    }
    func presentation(_ message: ChatMessage) -> (AttributedString,[PetAction]) {
        (renderedText(message), actions(for: message))
    }
    private func renderedText(_ message: ChatMessage) -> AttributedString {
        if rendering[message.id]?.0 != message.body {
            let text = MessageFormat.render(message.body)
            rendering[message.id] = (message.body,ChatText.linkified(text))
        }
        return rendering[message.id]!.1
    }
    private var actionMemo = PetActionMemo()
    func actions(for message: ChatMessage) -> [PetAction] {
        actionMemo.actions(for: message, events: calendarEvents)
    }
    private func rebuildRows() {
        var previous: ChatMessage?
        rows = messages.map { message in
            let row = ChatRow(message:message,
                showsSpeaker: !message.fromUser && (previous?.fromUser != false || previous?.speaker != message.speaker || previous?.profile != message.profile),
                showsDay: previous.map { !Calendar.current.isDate($0.date,inSameDayAs: message.date) } ?? true)
            previous = message; return row
        }
        if rendering.count > 800 {
            let visible = Set(messages.map(\.id)); rendering = rendering.filter { visible.contains($0.key) }
        }
    }
}

/// Observe the real scroll viewport rather than treating every new message as permission to jump.
struct ChatScrollProbe: NSViewRepresentable {
    let model: ChatModel
    func makeNSView(context: Context) -> NSView { let view = ProbeView(); view.model = model; return view }
    func updateNSView(_ view: NSView, context: Context) { (view as? ProbeView)?.connect() }
    final class ProbeView: NSView {
        weak var model: ChatModel?
        private var observer: NSObjectProtocol?
        private var liveObserver: NSObjectProtocol?
        private var documentObserver: NSObjectProtocol?
        private var inputMonitor: Any?
        private weak var watched: NSScrollView?
        private var lastBounds = CGRect.zero
        deinit { disconnect() }
        private func disconnect() {
            for token in [observer, liveObserver, documentObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }; inputMonitor = nil
            observer = nil; liveObserver = nil; documentObserver = nil
        }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func layout() { super.layout(); connect(); _ = model?.prepareEntryViewport() }
        func connect() {
            guard let scroll = enclosingScrollView else { return }
            model?.scrollView = scroll
            guard watched !== scroll else { _ = model?.prepareEntryViewport(); return }
            disconnect(); watched = scroll
            lastBounds = scroll.contentView.bounds
            liveObserver = NotificationCenter.default.addObserver(forName:NSScrollView.willStartLiveScrollNotification,object:scroll,queue:.main) { [weak self] _ in self?.model?.userScrollGeneration += 1 }
            // Wheel mice, keyboard navigation and scrollbar clicks need not start a live-scroll gesture.
            // Observe only actual input for this viewport; layout/proxy offset changes are not user intent.
            inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self, weak scroll] event in
                guard let self, let scroll, !scroll.isHiddenOrHasHiddenAncestor, event.window === scroll.window else { return event }
                let point = scroll.convert(event.locationInWindow, from: nil)
                var reading = event.type == .scrollWheel && scroll.bounds.contains(point)
                if event.type == .leftMouseDown {
                    // Selecting text can autoscroll without a wheel event. A click starts the reader's interaction.
                    reading = scroll.bounds.contains(point)
                } else if event.type == .keyDown, [49, 115, 116, 119, 121, 123, 124, 125, 126].contains(event.keyCode),
                          let responder = scroll.window?.firstResponder as? NSView {
                    reading = responder === scroll || responder.isDescendant(of: scroll)
                }
                if reading { self.model?.userScrollGeneration += 1 }
                return event
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,object: scroll.contentView,queue: .main) { [weak self,weak scroll] _ in
                guard let self, let scroll, let document = scroll.documentView else { return }
                let before = self.lastBounds, after = scroll.contentView.bounds
                self.lastBounds = after
                self.model?.nearBottom = document.bounds.maxY - scroll.contentView.bounds.maxY <= 80
                self.model?.entryViewportChanged(from: before, to: after)
            }
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                documentObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,object: document,queue: .main) { [weak self] _ in
                    _ = self?.model?.prepareEntryViewport()
                }
            }
            _ = model?.prepareEntryViewport()
        }
    }
}

/// A measured end marker distinguishes the newest realized row from LazyVStack's estimated height.
struct ChatBottomProbe: NSViewRepresentable {
    let model: ChatModel
    let revision: Int
    let lastID: String?
    func makeNSView(context: Context) -> BottomView { let view = BottomView(); configure(view); return view }
    func updateNSView(_ view: BottomView, context: Context) { configure(view) }
    private func configure(_ view: BottomView) {
        view.model = model
        if view.revision != revision || view.lastID != lastID {
            view.revision = revision; view.lastID = lastID; view.needsLayout = true
        }
    }
    final class BottomView: NSView {
        weak var model: ChatModel?
        var revision = -1
        var lastID: String?
        override func layout() {
            super.layout()
            model?.entryBottomLaidOut(self, revision: revision, lastID: lastID)
        }
    }
}
