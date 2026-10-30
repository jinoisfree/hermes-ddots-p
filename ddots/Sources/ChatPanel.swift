import AppKit
import SwiftUI

private typealias ChatDraftFocus = SwiftUI.State<Bool>

/// Only the header's non-interactive areas own these events; text and controls keep theirs.
struct ChatDragRegion: NSViewRepresentable {
    let model: ChatModel
    /// What a double-click does here instead of widening the window.
    var doubleClick: (() -> Void)? = nil
    func makeNSView(context: Context) -> ChatDragView { let view = ChatDragView(); view.model = model; view.doubleClick = doubleClick; return view }
    func updateNSView(_ view: ChatDragView, context: Context) { view.model = model; view.doubleClick = doubleClick }
}

final class ChatDragView: NSView {
    weak var model: ChatModel?
    var doubleClick: (() -> Void)?
    private var start: CGPoint?
    private var dragging = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "드래그: 채팅창과 펫 함께 이동 · 더블클릭: 가로 2배 / 기본"
        setAccessibilityLabel("채팅창과 펫 이동")
        setAccessibilityIdentifier("chat-drag")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        start = window?.convertPoint(toScreen: event.locationInWindow)
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let point = window?.convertPoint(toScreen: event.locationInWindow) else { return }
        if !dragging {
            guard hypot(point.x-start.x, point.y-start.y) > 4 else { return }
            dragging = true
            model?.onDragBegan?(start)
        }
        model?.onDragChanged?(point)
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { model?.onDragEnded?() }
        else if event.clickCount == 2 { if let doubleClick { doubleClick() } else { model?.onHeaderDoubleClick?() } }
        start = nil; dragging = false
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            if dragging { model?.onDragEnded?() }
            start = nil; dragging = false
        }
        super.viewWillMove(toWindow: newWindow)
    }
}

struct ChatView: View {
    @ObservedObject var model: ChatModel
    @ObservedObject var slack: SlackModel
    @ObservedObject var web: WebPaneModel
    @ChatDraftFocus private var focused = false
    @ChatDraftFocus var slackFocused = false
    @FocusState private var searchFocused: Bool
    @FocusState var slackFindFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var shouldReduceMotion: Bool { reduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") }
    static var reducesMotionForChecks: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") }
    /// Secondary text sits on a tinted glass, so it stays close to the body color instead of system gray.
    let quiet = Color.primary.opacity(0.7)
    var dark: Bool { colorScheme == .dark }
    static let time: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .none; formatter.timeStyle = .short; return formatter
    }()
    static let day: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true; return formatter
    }()

    var body: some View {
        let _ = SlackInputSmoke.countBody()
        return GeometryReader { window in
            // Whatever the window is wider than the conversation by is shared between the tab strip on the left
            // and the page on the right. While the page slides, the strip keeps its width and the page takes the rest.
            let extra = max(0, window.size.width - model.viewportWidth)
            let pane = min(web.layoutWidth, web.sliding ? max(0, extra - (slackActive ? slack.sidebarWidth : 0)) : min(web.width, extra))
            HStack(spacing: 0) {
                conversationSide.frame(width: max(0, window.size.width - pane))
                if pane > 0 {
                    // The page keeps its full width and is uncovered as the window grows.
                    Group {
                        if web.shrimpList {
                            ShrimpListPane(candidates: slack.driveListMessage != nil ? slack.driveList() : slack.shrimpAll(slack.shrimpListThread), choose: { number in
                                if slack.driveListMessage != nil { slack.driveChoose(number) }
                                else if let thread = slack.threads.first(where: { $0.id == slack.shrimpListThread }),
                                   let message = thread.messages.last(where: { slack.vault.trusted($0) && ShrimpAllHeader.parse($0.body) != nil }) {
                                    slack.shrimpPageCommand("\(number)번", message: message)
                                }
                            }, close: { slack.shrimpListThread = nil; slack.driveListMessage = nil; web.close() }, toggle: { web.toggleShrimpList() }, page: $slack.shrimpListPage, query: $web.shrimpQuery, searchFocus: { web.shrimpSearchFocused = $0 },
                               dragArea: AnyView(ChatDragRegion(model: model, doubleClick: { web.toggleShrimpList() })))
                        } else { WebPaneView(web: web) }
                    }.frame(width: web.layoutWidth).frame(width: pane, alignment: .leading).clipped()
                }
            }
            .frame(width: window.size.width, height: window.size.height, alignment: .leading)
        }
        .coordinateSpace(name: "chat-surface")
        .environment(\.openURL, OpenURLAction { url in model.onOpenLink?(url); return .handled })
    }
    private var conversationSide: some View {
        VStack(spacing: 0) {
            if !slackActive { header }
            if web.shrimpList && web.shrimpCollapsed {
                ShrimpListPane(candidates: slack.driveListMessage != nil ? slack.driveList() : slack.shrimpAll(slack.shrimpListThread), choose: { _ in },
                               close: { slack.shrimpListThread = nil; slack.driveListMessage = nil; web.close() }, collapsed: true,
                               toggle: { web.toggleShrimpList() }, page: $slack.shrimpListPage, query: $web.shrimpQuery, searchFocus: { web.shrimpSearchFocused = $0 })
            }
            if !slackActive { Divider() }
            GeometryReader { geometry in
                // The tab strip is exactly the width the window has gained so far, so the conversation column
                // keeps its width and the strip slides in step with the window.
                let strip = min(SlackSidebar.listMaximum, max(0, geometry.size.width - model.viewportWidth))
                ZStack(alignment: .trailing) {
                    // The iMessage side stays mounted so its scroll position and draft survive a visit to Slack.
                    if IMessageFeature.enabled { messagesPane.frame(width: slackActive && SlackResizeSmoke.without("imessage") ? 400 : geometry.size.width - strip)
                        .environment(\.linkPointerEnabled, !slackActive)
                        .opacity(slackActive ? 0 : 1).allowsHitTesting(!slackActive).accessibilityHidden(slackActive)
                    }
                    // The Slack side exists only while it shows or is still sliding away.
                    if slackActive || strip > 0 {
                        slackPane(strip: strip).opacity(slackActive ? 1 : 0).allowsHitTesting(slackActive).accessibilityHidden(!slackActive)
                            .environment(\.linkPointerEnabled, slackActive && !SlackResizeSmoke.without("links"))
                            .transition(.opacity)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .trailing)
                .animation(shouldReduceMotion ? nil : .easeInOut(duration: 0.2), value: slack.source)
            }
        }
        .onChange(of: model.focusDraftRevision) { _ in
            // A snapshot transition hides the host, so AppKit can lose focus while SwiftUI still considers it focused.
            // On the Slack side the field to give it back to is that side's, not the hidden iMessage one.
            if slackActive {
                slackFocused = false
                DispatchQueue.main.async { slackFocused = !slack.findOpen }
                return
            }
            focused = false
            DispatchQueue.main.async {
                focused = true
                DispatchQueue.main.async { Self.moveCaretToEnd(in: model.scrollView?.window) }
            }
        }
        .onChange(of: model.expanded) { expanded in
            focused = expanded && !slackActive; slackFocused = expanded && slackActive
            // Focusing a text field selects its contents; keep the caret after the saved draft instead.
            if expanded { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.moveCaretToEnd(in: model.scrollView?.window) } }
        }
        .onChange(of: slack.findFocus) { _ in slackFindFocused = slack.findOpen }
        .onChange(of: slack.findOpen) { open in slackFindFocused = open; slackFocused = !open && slackActive }
        .onChange(of: model.searchOpen) { open in searchFocused = open; focused = !open && !slackActive }
        .onChange(of: slack.source) { source in
            if source == .slack && model.searchOpen { model.closeSearch() }
            if source != .slack && slack.findOpen { slack.closeFind() }
            focused = source == .imessage; slackFocused = source == .slack
        }
        .onChange(of: slack.focusRevision) { _ in slackFocused = !slack.findOpen }
        .onExitCommand { if slackActive && slack.findOpen { slack.closeFind() } else { model.escape() } }
    }
    private var slackActive: Bool { !IMessageFeature.enabled || slack.source == .slack }
    private var messagesPane: some View {
        VStack(spacing: 0) {
            ZStack {
                conversation.opacity(model.searchOpen ? 0 : 1).allowsHitTesting(!model.searchOpen)
                if model.searchOpen { searchResults }
            }
            if let notice = model.notice {
                VStack(alignment: .leading, spacing: 5) {
                    Label(notice, systemImage: "info.circle").font(.system(size: ChatMetrics.auxiliaryFont))
                        .fixedSize(horizontal: false, vertical: true)
                    if IMessageFeature.enabled && model.needsAutomation {
                        Button("자동화 설정 열기") { model.onAutomation?() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color.primary.opacity(0.06))
            }
            Divider()
            if model.canSend {
                characterButtons
                HStack(alignment: .bottom, spacing: 8) {
                    DraftEditor(prompt: "iMessage", text: $model.draft, focus: $focused, onSubmit: send)
                        .onChange(of: focused) { model.composerFocused = $0 }
                        .onDisappear { model.composerFocused = false }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.3)))
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                        .buttonStyle(.plain).foregroundColor(trimmed.isEmpty ? quiet : .blue).disabled(trimmed.isEmpty)
                        .accessibilityLabel("보내기")
                }.padding(10)
            } else {
                Button("보내려면 Hermes iMessage 번호를 설정하세요") { model.onSetup?() }
                    .buttonStyle(.borderless).font(.system(size: ChatMetrics.auxiliaryFont)).padding(10)
            }
        }
    }

    static func moveCaretToEnd(in window: NSWindow? = nil) {
        guard let editor = (window ?? NSApp.windows.first(where: \.isKeyWindow))?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
    }
    private var trimmed: String { model.draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private func send() {
        guard !trimmed.isEmpty else { return }
        model.onSend?(trimmed); model.draft = ""
        // Keep the caret in the field so the next message can be typed right away.
        model.focusDraftRevision += 1
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12)).foregroundColor(quiet)
                .frame(width: 16, height: 22)
                .overlay(ChatDragRegion(model: model))
            if slackActive && slack.findOpen {
                TextField("단어나 문장으로 검색", text: $slack.findQuery).textFieldStyle(.plain).focused($slackFindFocused)
                    .onSubmit { slack.onFindSubmit?() }.accessibilityIdentifier("slack-find-field")
                Button { slack.closeFind() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("검색 닫기 (Esc)")
            } else if model.searchOpen {
                TextField("대화 검색", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
                    .onSubmit { model.chooseSelection() }.accessibilityLabel("대화 검색")
                Button { model.closeSearch() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
            } else {
                HStack(spacing: 0) {
                    Text(Ddots.title).font(.system(size: ChatMetrics.nameFont, weight: .semibold)).lineLimit(1)
                    if slackActive, let room = slack.room {
                        Text(" · ").foregroundColor(quiet)
                        Text(room.name).font(.system(size: ChatMetrics.nameFont, weight: .medium))
                            .lineLimit(1).help(room.name).accessibilityIdentifier("current-room-title")
                    }
                    Spacer(minLength: 0)
                }.frame(minHeight: 22).overlay(ChatDragRegion(model: model).padding(.vertical, -9))
                // With ddots on and Slack connected, the rooms are the whole of the window and there is nothing to switch between.
                if IMessageFeature.enabled && (!Ddots.enabled || !slack.connected) {
                    Picker("대화 종류", selection: $slack.source) {
                        Text("iMessage").tag(ChatSource.imessage)
                        Text(slack.unreadTotal > 0 ? "Slack \(SlackUnread.badge(slack.unreadTotal))" : "Slack").tag(ChatSource.slack)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
                }
                Button { slack.toggleMute() } label: { Image(systemName: slack.shownMuted ? "bell.slash.fill" : "bell") }
                    .buttonStyle(.borderless).foregroundColor(slack.shownMuted ? .orange : nil)
                    .help(slack.shownMuted ? "이 대화의 알림 켜기" : "이 대화의 알림 끄기")
                    .accessibilityLabel(slack.shownMuted ? "알림 꺼짐, 눌러서 켜기" : "알림 켜짐, 눌러서 끄기").accessibilityIdentifier("chat-mute")
                if slackActive {
                    Button { slack.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                        .buttonStyle(.borderless).help("방 목록 보이기 / 숨기기").accessibilityLabel("방 목록 보이기 / 숨기기")
                }
                if slackActive {
                    Button { slack.openFind() } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("전체 검색 (⌘F)").accessibilityLabel("전체 검색").accessibilityIdentifier("slack-find")
                } else {
                    Button { model.openSearch() } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).help("대화 검색 (⌘F)").accessibilityLabel("대화 검색")
                }
            }
            Button { if slack.findOpen { slack.closeFind() } else { model.escape() } } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).accessibilityLabel("접기")
        }.padding(.horizontal,14)
            .frame(height:PetLayout.headerHeight)
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.hasOlder && !model.historical && !model.messages.isEmpty {
                            Button(model.loadingOlder ? "불러오는 중…" : "이전 대화 보기") { model.loadOlder() }
                                .buttonStyle(.borderless).font(.system(size: ChatMetrics.auxiliaryFont)).disabled(model.loadingOlder)
                        }
                        if model.messages.isEmpty { Text("아직 표시할 대화가 없어요.").font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).padding(.top,40) }
                        ForEach(model.rows) { item in
                            if item.showsDay { Text(Self.day.string(from: item.message.date)).font(.system(size:ChatMetrics.auxiliaryFont)).foregroundColor(quiet).padding(.top,8) }
                            row(item).id(item.id)
                        }
                        if !model.historical {
                            ForEach(model.typing) { indicator in typingBubble(indicator) }
                        }
                        Color.clear.frame(height: 1)
                            .background(ChatBottomProbe(model: model, revision: model.scrollRevision, lastID: model.messages.last?.id))
                            .id("chat-bottom")
                    }.padding(.horizontal,ChatMetrics.horizontalInset).padding(.vertical,10)
                        .background(ChatScrollProbe(model: model))
                }
                .chatMeasure("viewport", model: model)
                if model.historical {
                    Button("최신 대화로") { model.resetPage() }.buttonStyle(.borderless).padding(7)
                }
            }
            .onAppear {
                initialScroll(proxy)
                if model.entryViewportActive { scroll(proxy, to: "chat-bottom") }
            }
            .onChange(of: model.expanded) { _ in initialScroll(proxy) }
            .onChange(of: model.messages.count) { _ in initialScroll(proxy) }
            .onChange(of: model.scrollRevision) { _ in scroll(proxy, to: model.scrollTarget) }
            .onChange(of: model.typing) { _ in if model.expanded && model.nearBottom { scroll(proxy,to:"chat-bottom") } }
        }
    }
    private func initialScroll(_ proxy: ScrollViewProxy) {
        guard model.expanded, !model.historical, !model.messages.isEmpty, !model.didInitialScroll else { return }
        model.didInitialScroll = true
        if !model.entryViewportActive { model.beginEntryViewport() }
        scroll(proxy,to:"chat-bottom")
    }
    private func scroll(_ proxy: ScrollViewProxy, to id: String) {
        if id == "chat-bottom" {
            guard model.expanded, !model.historical else { return }
            if !model.entryViewportActive { model.beginEntryViewport(hideUntilReady: false) }
            if model.scrollView == nil, model.takeEntryProxyRequest() {
                // Only mounting needs the proxy. Once connected, native layout realizes and aligns the
                // end together, avoiding a proxy request arriving later with an old estimated offset.
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                model.realizeEntryProxy { withTransaction(transaction) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            _ = model.prepareEntryViewport()
            return
        }
        let generation = model.userScrollGeneration, revision = model.scrollRevision
        func stillWanted() -> Bool { model.expanded && model.userScrollGeneration == generation && model.scrollRevision == revision }
        DispatchQueue.main.async {
            guard stillWanted() else { return }
            proxy.scrollTo(id,anchor: id == "chat-bottom" ? .bottom : .center)
            DispatchQueue.main.async { if stillWanted() { proxy.scrollTo(id,anchor: id == "chat-bottom" ? .bottom : .center) } }
            if model.searchTargetID == id {
                // Realize the lazy message first, then center the exact matching paragraph inside it.
                DispatchQueue.main.asyncAfter(deadline: .now()+0.2) {
                    guard stillWanted(), model.searchTargetID == id else { return }
                    proxy.scrollTo(id+":match",anchor:.center)
                }
            }
        }
    }
    /// Character pictures are soft squares, as Slack shows them.
    static func face(_ size: CGFloat) -> RoundedRectangle { RoundedRectangle(cornerRadius: size * ChatMetrics.avatarCorner, style: .continuous) }
    func avatarBadge(_ name: String, profile: String, size: CGFloat) -> some View {
        let avatar = Ddots.avatar(model.avatars[profile], name: name) ?? ProfileAvatar()
        return Group {
            if let image = avatar.image { Image(nsImage: image).resizable().scaledToFill() }
            else {
                ZStack {
                    Color(nsColor: avatar.color)
                    Text(ProfileAvatar.initial(name)).font(.system(size: size*0.6, weight: .medium)).foregroundColor(Color(nsColor: avatar.foreground))
                }
            }
        }.frame(width: size, height: size).clipShape(Self.face(size)).accessibilityHidden(true)
    }
    private var characterButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ChatMetrics.avatarNameGap) {
                ForEach(ChatCharacter.ordered(model.characters)) { character in
                    Button { model.callCharacter(character) } label: {
                        avatarBadge(character.name, profile: character.id, size: ChatMetrics.callerAvatar).chatMeasure("caller:" + character.id, model: model).padding(4)
                    }.buttonStyle(.plain).help(character.name).accessibilityLabel(character.name)
                        .accessibilityIdentifier("call-" + character.id)
                }
            }.padding(.horizontal, 10)
        }.frame(height: ChatMetrics.callerAvatar+8).padding(.top, 6)
    }
    private func speakerLabel(_ name: String, profile: String, key: String) -> some View {
        HStack(spacing: ChatMetrics.avatarNameGap) {
            avatarBadge(name, profile: profile, size: ChatMetrics.avatar)
                .chatMeasure("avatar:" + key, model: model)
            Text(name).font(.system(size: ChatMetrics.nameFont, weight: .semibold))
                .foregroundColor(Color(nsColor: model.palette(profile, dark: dark).name.nsColor))
        }.chatMeasure("name:" + key, model: model)
    }
    func typingBubble(_ indicator: TypingIndicator) -> some View {
        let palette = model.palette(indicator.profile, dark: dark)
        return VStack(alignment: .leading,spacing: ChatMetrics.nameBodyGap) {
            if !indicator.speaker.isEmpty {
                speakerLabel(indicator.speaker, profile: indicator.profile, key: "typing")
                    .padding(.leading, ChatMetrics.speakerInset)
            }
            Group {
                if shouldReduceMotion { Text("…").font(.title3) }
                else {
                    TimelineView(.animation(minimumInterval: 1.0 / 12, paused: !model.expanded)) { timeline in
                        HStack(spacing: 5) {
                            ForEach(0..<3) { index in
                                Circle().frame(width:6,height:6)
                                    .scaleEffect(0.8 + 0.35 * (1 + sin(timeline.date.timeIntervalSinceReferenceDate * 5 - Double(index) * 1.1)))
                            }
                        }.frame(height:16)
                    }
                }
            }.foregroundColor(Color(nsColor:palette.foreground.nsColor))
                .padding(.horizontal,14).padding(.vertical,10)
                .background(RoundedRectangle(cornerRadius:16).fill(Color(nsColor:palette.background.nsColor)))
                .chatMeasure("bubble:typing", model: model)
        }.padding(.leading, ChatMetrics.replyInset).frame(maxWidth:.infinity,alignment:.leading)
            .accessibilityLabel("\(indicator.speaker) 작성 중")
    }
    private var searchResults: some View {
        VStack(alignment: .leading,spacing: 6) {
            Text(model.searching ? "찾는 중…" : "\(model.results.count)건").font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
            if !model.searching && model.results.isEmpty { Text("찾는 대화가 없어요").font(.system(size: ChatMetrics.auxiliaryFont)).padding(.top,20) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading,spacing: 6) {
                        ForEach(model.results) { message in
                            Button { model.onSelectResult?(message) } label: {
                                VStack(alignment: .leading,spacing: 4) {
                                    Text("\(message.fromUser ? "나" : message.speaker) · \(Self.day.string(from:message.date)) \(Self.time.string(from:message.date))").font(.system(size:ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                                    Text(ChatText.searchPreview(message.body, query:model.query)).font(.system(size:12)).multilineTextAlignment(.leading)
                                }.frame(maxWidth:.infinity,alignment:.leading).padding(8)
                                    .background(RoundedRectangle(cornerRadius:8).fill((model.results.indices.contains(model.selection) && model.results[model.selection].id == message.id) ? Color.accentColor.opacity(0.2) : Color.clear))
                            }.buttonStyle(.plain).id(message.id)
                        }
                    }
                }.onChange(of:model.selection) { index in
                    if model.results.indices.contains(index) { proxy.scrollTo(model.results[index].id) }
                }
            }
        }.padding(12).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
    }

    /// Slack can open a folded thread on a text click while native text keeps drag selection.
    @ViewBuilder func row(_ item: ChatRow, selectable: Bool = true, textClick: (() -> Void)? = nil) -> some View {
        let _ = ChatPerfProbe.hit("chat.row")
        let message = item.message
        let presentation = model.presentation(message)
        let palette = model.palette(message.profile, dark: dark)
        VStack(alignment: message.fromUser ? .trailing : .leading, spacing: ChatMetrics.nameBodyGap) {
            if item.showsSpeaker {
                speakerLabel(message.speaker, profile: message.profile, key: message.profile).padding(.leading, ChatMetrics.speakerInset).padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !message.body.isEmpty { messageText(message, palette: palette).onSelectedTextClick(textClick) }
                ForEach(Array(message.marks.enumerated()), id: \.offset) { _, mark in markNote(mark, message: message) }
                ForEach(message.files) { fileView($0, in: message) }
            }.font(.system(size: ChatMetrics.bodyFont)).selectableText(selectable)
                .foregroundColor(message.fromUser ? .white : Color(nsColor:palette.foreground.nsColor))
                .tint(message.fromUser ? .white : Color(nsColor:palette.link.nsColor))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 16).fill(message.fromUser ? Color.blue : Color(nsColor:palette.background.nsColor)))
                .overlay(RoundedRectangle(cornerRadius:16).stroke(model.highlightedID == message.id ? Color.accentColor : .clear,lineWidth:2))
                .animation(shouldReduceMotion ? nil : .easeInOut(duration:0.2),value:model.highlightedID == message.id)
                .opacity(message.pending ? 0.6 : 1)
                .chatMeasure("bubble:" + message.profile, model: model)
            if !message.fromUser && model.needsFolding(message) {
                Button(model.expandedReplies.contains(message.id) ? "접기" : "더 보기") { model.toggleReply(message.id) }
                    .font(.system(size: ChatMetrics.auxiliaryFont)).buttonStyle(.borderless)
                    .foregroundColor(Color(nsColor:palette.name.nsColor))
                    .accessibilityIdentifier("fold-" + message.id)
                    .chatMeasure("fold:" + message.id, model: model)
            }
            if !message.fromUser {
                let actions = presentation.1
                if !actions.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                            Button(action.title) { model.onAction?(action) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }.padding(.leading, 4)
                }
            }
            if message.fromUser && message.replyInterrupted {
                Text("답이 중단됐어요").font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).padding(.horizontal, 10)
            }
            Text(message.pending ? (message.id.hasPrefix("slack") ? "보내는 중" : "보냄 · 기록 확인 중") : Self.time.string(from: message.date))
                .font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).padding(.horizontal, 10)
        }
        .replyHeight(message, model: model)
        .padding(.leading, message.fromUser ? 0 : ChatMetrics.replyInset)
        .frame(maxWidth: model.bubbleWidth, alignment: message.fromUser ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: message.fromUser ? .trailing : .leading)
    }

    /// A coloured bar with its note, the way Slack draws an attachment.
    func markNote(_ mark: ChatMark, message: ChatMessage? = nil) -> some View {
        let shown = SlackNotice.displayStatus(mark.text)
        let parsed = ChatText.linkified((try? AttributedString(markdown: ChatText.normalizedMarkdown(shown), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(shown))
        let term = message.flatMap { slack.findTerm($0) }.map { query in
            // A search for the old status still lights the note after its displayed words are unified.
            shown != mark.text && !SlackSearch.highlights(mark.text, query: query).isEmpty ? shown : query
        }
        let text = term.map { SlackSearch.highlighted(parsed, query: $0) } ?? parsed
        return HStack(alignment: .top, spacing: 7) {
            Capsule().fill(Self.color(hex: mark.color) ?? Color.primary.opacity(0.35)).frame(width: 3)
            LinkText(text)
                .fixedSize(horizontal: false, vertical: true)
        }.fixedSize(horizontal: false, vertical: true)
    }
    static func color(hex: String) -> Color? {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }

    @ViewBuilder private func messageText(_ message: ChatMessage, palette: CharacterPalette) -> some View {
        let text = bodyText(message, palette: palette)
        if let segments = model.searchSegments(message, text: text) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(segments) { segment in
                    LinkText(segment.text).fixedSize(horizontal: false, vertical: true).id(segment.id)
                        .chatMeasure(segment.match ? "search-match" : segment.id, model: model)
                }
            }
        } else { ChecklistText(text, identity: message.id, revision: message.body) }
    }
    private func bodyText(_ message: ChatMessage, palette: CharacterPalette) -> AttributedString {
        var text = slackHighlight(model.displayedText(message), message: message)
        for run in text.runs where run.link != nil {
            // Keep search highlights black on yellow; otherwise use the contrast-tested underlined link color.
            if run.backgroundColor == nil { text[run.range].foregroundColor = message.fromUser ? Color(red: 0.72, green: 0.9, blue: 1) : Color(nsColor:palette.link.nsColor) }
        }
        return text
    }

}

extension View {
    func onSelectedTextClick(_ action: (() -> Void)?) -> some View {
        simultaneousGesture(TapGesture().onEnded { action?() }, including: action == nil ? .none : .all)
    }

    @ViewBuilder func selectableText(_ on: Bool) -> some View {
        if on { textSelection(.enabled) } else { textSelection(.disabled) }
    }
}

private enum ChatMeasure {
    static let enabled = CommandLine.arguments.contains("--ui-smoke-chat")
}

/// Smoke-only geometry observation; production views do not install probes or read layout back into state.
extension View {
    @ViewBuilder func replyHeight(_ message: ChatMessage, model: ChatModel) -> some View {
        if !message.fromUser && model.needsFolding(message) {
            background(GeometryReader { geometry in
                Color.clear.onAppear { model.measureReply(message.id, height: geometry.size.height) }
                    .onChange(of: geometry.size.height) { model.measureReply(message.id, height: $0) }
                    .onDisappear { model.releaseReplyHeight(message.id) }
            })
        } else { self }
    }
    @ViewBuilder func chatMeasure(_ key: String, model: ChatModel) -> some View {
        if ChatMeasure.enabled {
            background(GeometryReader { geometry in
                Color.clear.onAppear { model.recordFrame(key, geometry.frame(in: .named("chat-surface"))) }
                    .onChange(of: geometry.frame(in: .named("chat-surface"))) { model.recordFrame(key, $0) }
            })
        } else { self }
    }
}
