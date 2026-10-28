import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ChatSource: String { case imessage, slack }

extension Ddots {
    /// The room's own picture, shown on its tab in place of a character's face.
    static var picture: NSImage? { (DdotsConfig.shared.appearance["homePicture"] as? String).flatMap { Bundle.main.url(forResource: $0, withExtension: "png") }.flatMap { NSImage(contentsOf: $0) } }
    /// Channels with a picture of their own, by name, shown on the tab in place of their members' faces.
    static var roomPictures: [String:NSImage] {
        (DdotsConfig.shared.appearance["roomPictures"] as? [String:String] ?? [:])
            .compactMapValues { name in Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) } }
    }
    static var senderPictures: [String: NSImage] {
        (DdotsConfig.shared.appearance["senderPictures"] as? [String:String] ?? [:])
            .compactMapValues { name in Bundle.main.url(forResource: name, withExtension: "png").flatMap { NSImage(contentsOf: $0) } }
    }
    static func avatar(_ profile: ProfileAvatar?, name: String) -> ProfileAvatar? {
        guard profile?.image == nil, let picture = senderPictures[name] else { return profile }
        var result = profile ?? ProfileAvatar()
        result.image = picture
        return result
    }

}

/// Lets a room in the first two zones be dragged, and a room, line or gap of those zones take one into its zone.
struct SlackZoneDrag: ViewModifier {
    let slack: SlackModel
    let room: String?
    let zone: Int?

    @ViewBuilder func body(content: Content) -> some View {
        if let zone, slack.sections.contains(zone) {
            let over = Binding(get: { slack.dropZone == zone }, set: { over in
                if over { slack.dropZone = zone } else if slack.dropZone == zone { slack.dropZone = nil }
            })
            let target = content.onDrop(of: [.plainText], isTargeted: over) { providers in
                guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                _ = provider.loadObject(ofClass: NSString.self) { item, _ in
                    guard let id = item as? String else { return }
                    DispatchQueue.main.async { slack.move(id, toZone: zone) }
                }
                return true
            }
            if let room, room != Ddots.room, !Ddots.isTab(room) { target.onDrag { NSItemProvider(object: room as NSString) } } else { target }
        } else {
            content
        }
    }
}

enum SlackSidebar {
    /// The strip as square tabs. Dragged wider it becomes a list like the one in Messages; dragged shut it hides.
    static let width: CGFloat = 68
    static let expandedWidth: CGFloat = 212
    static let tabHeight: CGFloat = 72
    static let listMinimum: CGFloat = 180
    static let listMaximum: CGFloat = 300
    static let rowHeight: CGFloat = 74
    static let searchHeight: CGFloat = 38
    /// The line between two zones of the room list.
    static let dividerHeight: CGFloat = SlackZones.dividerHeight
    /// A strip at least this wide is laid out as a list.
    static let listThreshold: CGFloat = 124
    static let hideThreshold: CGFloat = 34
    static func isList(_ width: CGFloat) -> Bool { width >= listThreshold }
    /// Where a dragged width comes to rest: hidden, square tabs, or a list of any width in its range.
    static func snapped(_ dragged: CGFloat) -> CGFloat {
        if dragged < hideThreshold { return 0 }
        if dragged < listThreshold { return width }
        return min(listMaximum, max(listMinimum, dragged))
    }
    static let topInset: CGFloat = 4
    static let inset: CGFloat = 6
    static let corner: CGFloat = 14
    static let flare: CGFloat = 7
    static let faces: CGFloat = 34
    /// Room left above and below an opened thread when the window grows to fit it.
    static let threadMargin: CGFloat = 28
    /// How far replies sit in from the thread's edge: the picture and the gap beside it.
    static let threadIndent: CGFloat = ChatMetrics.avatar + 9

    /// The chosen tab's outline, open on the right with flared corners so it runs into the conversation.
    static func contour(_ path: inout Path, in rect: CGRect, y: CGFloat, height: CGFloat) {
        let left = rect.minX + inset, right = rect.maxX, top = y + flare, bottom = y + height - flare
        path.addLine(to: CGPoint(x: right, y: y))
        path.addQuadCurve(to: CGPoint(x: right - flare, y: top), control: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: left + corner, y: top))
        path.addQuadCurve(to: CGPoint(x: left, y: top + corner), control: CGPoint(x: left, y: top))
        path.addLine(to: CGPoint(x: left, y: bottom - corner))
        path.addQuadCurve(to: CGPoint(x: left + corner, y: bottom), control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - flare, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: y + height), control: CGPoint(x: right, y: bottom))
    }
}

/// The veil over the tab strip with the chosen tab left clear. Animating `y` slides the opening between tabs.
struct SlackSidebarVeil: Shape {
    var y: CGFloat
    var height: CGFloat
    var hasTab: Bool
    var animatableData: AnimatablePair<CGFloat, CGFloat> { get { .init(y, height) } set { y = newValue.first; height = newValue.second } }
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        guard hasTab else { return path }
        path.move(to: CGPoint(x: rect.maxX, y: y))
        SlackSidebar.contour(&path, in: rect, y: y, height: height)
        path.closeSubpath()
        return path
    }
}

/// The hairline between the strip and the conversation, bending around the chosen tab.
struct SlackSidebarEdge: Shape {
    var y: CGFloat
    var height: CGFloat
    var hasTab: Bool
    var animatableData: AnimatablePair<CGFloat, CGFloat> { get { .init(y, height) } set { y = newValue.first; height = newValue.second } }
    func path(in rect: CGRect) -> Path {
        let line = rect.insetBy(dx: 0.5, dy: 0)
        var path = Path()
        path.move(to: CGPoint(x: line.maxX, y: rect.minY))
        if hasTab { SlackSidebar.contour(&path, in: line, y: y, height: height) }
        path.addLine(to: CGPoint(x: line.maxX, y: rect.maxY))
        return path
    }
}

/// Only the editor observes every syllable as it is being composed.
final class SlackDraft: ObservableObject {
    @Published var text = "" { willSet { if text != newValue { onChange?(text, newValue) } } }
    var onChange: ((String, String) -> Void)?
}

final class SlackResizeRows: ObservableObject {
    var sizes: [String: CGSize] = [:]
    var live: Set<String> = []
}

/// A thread in the list. While the window's edge is dragged, one that is out of sight keeps its place as empty space
/// of the height it had, so only what is on screen is laid out again at each step.
private struct SlackResizeRow<Content: View>: View {
    @ObservedObject var rows: SlackResizeRows
    let id: String
    let content: () -> Content
    var body: some View {
        let held = rows.live.contains(id) ? nil : rows.sizes[id]
        Group {
            if let held { Color.clear.frame(height: held.height).frame(maxWidth: .infinity) } else { content() }
        }
        .onAppear { if SlackResizeSmoke.records { SlackResizeSmoke.renderedHolds[id] = held != nil } }
        .onChange(of: held != nil) { if SlackResizeSmoke.records { SlackResizeSmoke.renderedHolds[id] = $0 } }
    }
}

/// A retained row's rendering inputs. Callbacks stay live through their model references;
/// values used to draw the row are copied so equality never reads a mutated model.
struct SlackThreadInputs: Equatable {
    var conversationGeneration = DdotsConfig.shared.generation
    var threadID: String
    var threadRevision: UInt64
    var expanded: Bool, picked: Bool, target: Bool, isDdots: Bool, dark: Bool, reduceMotion: Bool
    var vaultActive: Bool
    var chatSearch: [String?]
    var bell: Bool?
    var confirmed: Set<String>, expandedReplies: Set<String>
    var writing: [TypingIndicator]
    var flash: String?, highlighted: String?, findTerm: String?
    var copied: String?, copyWaiting: Bool, branching: Bool, confirmingDelete: Bool
    var removing: SlackBridge.Removal?
    var workspace: String
    var members: [DdotsMember]
    var avatars: [String: ProfileAvatar]
    var palettes: [String: CharacterPalette]
    var events: [CalendarEntry]
    var bubbleWidth: CGFloat
    var vaultConfiguration: [String?]
    var vaultSent: Set<String>, driveSent: Set<String>
    var driveDone: [String: Double], driveChosen: [String: String]
    var pendingPages: [String: Int]
    var thumbnails: [String: ObjectIdentifier]
    var failedFiles: Set<String>, busyFiles: Set<String>
    var stopped: Bool
}

struct SlackLineInputs: Equatable {
    var message: ChatMessage
    var selectable: Bool, opensThread: Bool, dark: Bool, reduceMotion: Bool, expanded: Bool, highlighted: Bool, flashed: Bool
    var findTerm: String?, chatSearch: [String?]
    var events: [CalendarEntry], avatars: [String: ProfileAvatar], palettes: [String: CharacterPalette]
    var bubbleWidth: CGFloat
    var vaultConfiguration: [String?], pendingPage: Int?
    var thumbnails: [String: ObjectIdentifier], failedFiles: Set<String>, busyFiles: Set<String>
}
struct EqualSlackLine<Content: View>: View, Equatable {
    let inputs: SlackLineInputs
    var showsSpeaker = false
    let content: () -> Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.showsSpeaker == rhs.showsSpeaker && lhs.inputs == rhs.inputs }
    var body: some View { content() }
}

private struct EqualSlackThread<Content: View>: View, Equatable {
    let inputs: SlackThreadInputs
    let content: () -> Content
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.inputs == rhs.inputs }
    var body: some View { let _ = ChatPerfProbe.hit("slack.row"); content() }
}

final class SlackModel: ObservableObject {
    var noticeMemo = SlackNoticeMemo()
    let nativeInputs = NativeThreadInputsCache()
    func prepareNativeInputs(chat: ChatModel, dark: Bool, reduceMotion: Bool, vault: [String?]) {
        let model = self
        let next = NativeThreadInputsCache.Key(dark:dark,reduceMotion:reduceMotion,isDdots:model.isDdots,
            selected:model.selected,target:model.target?.id,picked:model.picked,flash:model.flash,highlighted:chat.highlightedID,
            copied:model.copied,copyWaiting:model.copyWaiting,branching:model.branching,confirmingDelete:model.confirmingDelete,
            open:model.open,confirmed:model.confirmed,expandedReplies:chat.expandedReplies,stopped:model.stopped,
            bells:model.bells,typing:model.typing,removing:model.removing,workspace:model.workspace,
            search:chat.rowSearchInputs,find:[model.findHighlight?.thread,model.findHighlight?.term],vault:vault,
            members:model.ddotsMembers,avatars:chat.avatars,palettes:dark ? chat.darkPalettes:chat.lightPalettes,
            events:chat.calendarEvents,bubbleWidth:chat.bubbleWidth,vaultSent:model.vaultSent,driveSent:model.driveSent,
            driveDone:model.driveDone,driveChosen:model.driveChosen,pages:model.shrimpPendingPages,
            thumbnails:model.thumbs.mapValues(ObjectIdentifier.init),failed:model.failedThumbs,busy:model.busyFiles)
        nativeInputs.prepare(next, ids: Set(renderedThreads.map { $0.thread.id }))
    }

    /// Only approvals in the conversation on screen can ask for the user's attention. Checking the room again
    /// also excludes the previous room's threads during a selection change, before the next publish arrives.
    var approvalThreads: [SlackThread]?
    var onNeedThread: ((String) -> Void)?
    /// The pet asks this on every animation frame. Over a whole kept record that is hundreds of threads each matched
    /// against every project, so the answer is reused while nothing it reads has changed, and for at most a second,
    /// which is how late an approval's expiry may show.
    struct PetApproval { var message: ChatMessage; var reason: String }
    private var petApprovalMemo: (signature: [Int], at: TimeInterval, value: PetApproval?)?
    var needsPetApproval: Bool { petApproval != nil }
    var petApproval: PetApproval? {
        let signature = [DdotsConfig.shared.generation, (approvalThreads ?? threads).count, threads.count, Int(truncatingIfNeeded: nextThreadRevision), projects.count,
                         confirmed.count, (selected ?? "").hashValue, source.hashValue, isDdots ? 1 : 0]
        let now = ProcessInfo.processInfo.systemUptime
        if let memo = petApprovalMemo, memo.signature == signature, now - memo.at < 1 { return memo.value }
        let value = computePetApproval()
        petApprovalMemo = (signature, now, value)
        return value
    }
    private func computePetApproval() -> PetApproval? {
        let threads = approvalThreads ?? self.threads
        guard source == .slack, let selected else { return nil }
        let rooms = isDdots ? Set(ddotsShown) : Set([selected])
        // Match the project cards actually shown in ddots, including their exact room/thread lookup.
        // `pending` also checks expiry, so do not retain this decision in the message-text cache.
        for thread in threads where rooms.contains(thread.room) {
            if isDdots, let project = project(thread),
               let approval = project.approvals?.first(where: \.pending) {
                let reason = approval.previewText?.trimmingCharacters(in: .whitespacesAndNewlines)
                return PetApproval(message: thread.root, reason: reason?.isEmpty == false ? reason! : project.title)
            }
            if let request = SlackNotice.pendingApproval(thread, confirmed: confirmed),
               SlackNotice.requestsPetReply(request),
               !SlackNotice.isSettled(thread, confirmed: confirmed) {
                return PetApproval(message: request, reason: request.body)
            }
        }
        return nil
    }
    /// Compared once when the published timeline changes, never while SwiftUI compares rows.
    struct ThreadRenderMemo {
        var thread: SlackThread
        var revision: UInt64
        var messages: Set<String>
        var files: Set<String>
    }
    private var threadRenderMemos: [String: ThreadRenderMemo] = [:]
    private(set) var renderedThreads: [ThreadRenderMemo] = []
    private var nextThreadRevision: UInt64 = 0
    private func refreshThreadRenderMemos() {
        let ids = Set(threads.map(\.id))
        threadRenderMemos = threadRenderMemos.filter { ids.contains($0.key) }
        for thread in threads where threadRenderMemos[thread.id]?.thread != thread {
            nextThreadRevision &+= 1
            let messages = thread.messages
            threadRenderMemos[thread.id] = ThreadRenderMemo(thread: thread, revision: nextThreadRevision,
                messages: Set(messages.map(\.id)), files: Set(messages.flatMap(\.files).map(\.id)))
        }
        renderedThreads = threads.compactMap { threadRenderMemos[$0.id] }
    }
    func rowInputs(_ memo: ThreadRenderMemo, chat: ChatModel, dark: Bool, reduceMotion: Bool, target: Bool, vaultConfiguration: [String?]? = nil) -> SlackThreadInputs {
        let _ = ChatPerfProbe.hit("slack.inputs")
        // Keep the revision and content in the same value, including retained SwiftUI closures.
        let thread = memo.thread
        let messages = memo.messages, files = memo.files
        let config = vaultConfiguration ?? { let config = vault; return [config.root, config.bot, config.unavailable] }()
        return SlackThreadInputs(threadID: thread.id, threadRevision: memo.revision, expanded: open.contains(thread.id), picked: picked == thread.id,
            target: target, isDdots: isDdots, dark: dark, reduceMotion: reduceMotion, vaultActive: source == .slack && selected == thread.room,
            chatSearch: chat.rowSearchInputs, bell: bells[thread.id],
            confirmed: confirmed.intersection(messages), expandedReplies: chat.expandedReplies.intersection(messages),
            writing: typing[thread.id] ?? [], flash: flash.flatMap { $0 == thread.id || messages.contains($0) ? $0 : nil },
            highlighted: chat.highlightedID.flatMap { messages.contains($0) ? $0 : nil },
            findTerm: findHighlight?.thread == thread.id ? findHighlight?.term : nil,
            copied: copied == "link-" + thread.id || copied == "copy-" + thread.id ? copied : nil,
            copyWaiting: copyWaiting == thread.id, branching: branching == thread.id, confirmingDelete: confirmingDelete == thread.id,
            removing: removing[thread.id], workspace: workspace, members: ddotsMembers, avatars: chat.avatars,
            palettes: dark ? chat.darkPalettes : chat.lightPalettes, events: chat.calendarEvents, bubbleWidth: chat.bubbleWidth,
            vaultConfiguration: config, vaultSent: vaultSent, driveSent: driveSent,
            driveDone: driveDone, driveChosen: Dictionary(uniqueKeysWithValues: messages.compactMap { id in driveChosen[id].map { (id, $0) } }),
            pendingPages: Dictionary(uniqueKeysWithValues: messages.compactMap { id in shrimpPendingPages[id].map { (id, $0) } }),
            thumbnails: Dictionary(uniqueKeysWithValues: files.compactMap { id in thumbs[id].map { (id, ObjectIdentifier($0)) } }),
            failedFiles: failedThumbs.intersection(files), busyFiles: busyFiles.intersection(files),
            stopped: stopped.contains(thread.id))
    }

    let composer = SlackDraft()
    init() {
        composer.onChange = { [weak self] old, new in
            guard let self else { return }
            if self.draftEffect(old) != self.draftEffect(new) { self.objectWillChange.send() }
        }
    }
    private struct DraftEffect: Equatable {
        var profile: String
        var lit: String?
        var target: String?
        var empty: Bool
    }
    private func draftEffect(_ text: String) -> DraftEffect {
        DraftEffect(profile: postProfile(for: text), lit: DdotsFaceLight.routed(route(text), faces: ddotsMembers), target: target(for: text)?.id,
                    empty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var sourceResponse: StallTrace.Response?
    @Published var source = IMessageFeature.enabled ? ChatSource.imessage : .slack {
        willSet { if source != newValue { sourceResponse = StallTrace.shared.response("sourceTab") } }
        didSet {
            if !IMessageFeature.enabled && source == .imessage { source = .slack }
            if source != oldValue { pageHold = nil; cancelEntry(); cancelFollowup(); onSource?(source) }
            StallTrace.shared.finish(sourceResponse); sourceResponse = nil
        }
    }
    @Published var connected = false
    /// The characters in ddots, each with the direct conversation that reaches it.
    @Published var ddotsMembers: [DdotsMember] = []
    @Published var projects: [ThreadProject] = []
    func project(_ thread: SlackThread) -> ThreadProject? {
        projects.first { $0.chatId == thread.room && $0.threadId == thread.ts }
    }
    /// Who a new post in ddots goes to. It returns to the usual character when the window is folded.
    @Published var ddotsTarget = Ddots.defaultTarget
    var isDdots: Bool { source == .slack && selected == Ddots.room }
    /// The Slack channel new posts in ddots are written to, when there is one.
    @Published var ddotsHub: String?
    /// What ddots shows: the channel alone when there is one, so the room is the same conversation Slack shows there;
    /// else every character's own conversation together.
    var ddotsShown: [String] { ddotsHub.map { [$0] } ?? ddotsMembers.map(\.room) }
    /// Every conversation the ddots record is kept from, shown in the room or not.
    var ddotsRooms: Set<String> { Set(ddotsMembers.map(\.room) + (ddotsHub.map { [$0] } ?? [])) }
    /// True once a face was pressed for the next message. Without it the words themselves say who the message is for,
    /// by the rules the shared room goes by.
    @Published var ddotsPicked = false
    /// Who a new post goes to: the pressed face, else whoever the words are for, else the usual character.
    var postProfile: String { postProfile(for: draft) }
    private func postProfile(for text: String) -> String {
        if ddotsPicked { return ddotsTarget }
        let choice = route(text).profile
        if ddotsMembers.contains(where: { $0.profile == choice }) { return choice }
        return ddotsMembers.first(where: { $0.profile == Ddots.defaultTarget })?.profile ?? ddotsMembers.first?.profile ?? ""
    }
    /// The hub's server is authoritative. A named recipient remains explicit;
    /// an ordinary request must reach the server without a synthetic mention.
    private func route(_ text: String) -> DdotsRoute.Decision {
        // Do not use postRoom here: it depends on postProfile, which calls route again.
        let room = isDdots ? ddotsHub ?? selected : selected
        var callable = room.flatMap { members[$0] } ?? []
        if isDdots && callable.isEmpty {
            callable = ddotsMembers.map { SlackMember(profile: $0.profile, name: $0.name, user: "preview-" + $0.profile) }
        }
        let mentioned = SlackMention.profiles(in: text, members: callable)
        if !mentioned.isEmpty {
            let profile = mentioned.count == 1 ? mentioned.first! : HermesRouting.str(HermesRouting.dict(DdotsConfig.shared.contract(hub: ddotsHub != nil)["cross_owner"])["profile"])
            if !profile.isEmpty { return DdotsRoute.Decision(profile: profile, reason: "mention") }
        }
        return ddotsHub != nil ? DdotsRoute.preview(text) : DdotsRoute.decide(text)
    }
    /// The room a new post lands in. ddots is not a room in Slack: it is the channel when there is one,
    /// else that character's own conversation.
    var postRoom: String? { isDdots ? ddotsHub ?? ddotsMembers.first { $0.profile == postProfile }?.room : selected }
    /// Whose thread it is in ddots: the character of a direct conversation, else whoever spoke first in a thread of the channel.
    func ddotsOwner(_ thread: SlackThread) -> DdotsMember? {
        if let own = ddotsMembers.first(where: { $0.room == thread.room }) { return own }
        let profile = project(thread)?.currentProfile ?? SlackOwner.profile(thread, members: ddotsMembers)
        return ddotsMembers.first { $0.profile == profile }
    }
    /// Who the next message in ddots reaches: the thread's own character when answering, else whoever a new post is for.
    var recipient: DdotsMember? {
        if let thread = target { return ddotsOwner(thread) }
        return ddotsMembers.first { $0.profile == postProfile }
    }
    /// Empty automatic drafts light nobody; explicit selections and replies retain their recipient.
    /// An unpressed new post lights only the character its words are about.
    var litRecipientProfile: String? {
        let shown = target == nil && !ddotsPicked ? DdotsFaceLight.routed(route(draft), faces: ddotsMembers) : recipient?.profile
        return DdotsFaceLight.profile(draft: draft, picked: ddotsPicked, replying: target != nil, recipient: shown)
    }
    /// Each character's Slack ID, from its own conversation.
    var ddotsUsers: [String: String] {
        Dictionary(ddotsMembers.compactMap { member in members[member.room]?.first.map { (member.profile, $0.user) } }, uniquingKeysWith: { first, _ in first })
    }
    /// How a new post in the channel goes out. The usual character answers without a call; a pressed face or
    /// another character chosen by the words gets a mention. Explicit calls are always converted.
    /// Nil outside ddots, without the channel, and when answering in a thread.
    func hubPost(_ text: String) -> DdotsPost? {
        guard isDdots, let hub = ddotsHub, target == nil, let who = recipient else { return nil }
        return Ddots.post(text, to: who, cast: ddotsMembers, users: ddotsUsers, members: members[hub] ?? [],
                          prependCall: ddotsPicked)
    }
    /// The character the post calls who is not in the channel, so would never hear it.
    func absent(from post: DdotsPost) -> DdotsMember? {
        guard let hub = ddotsHub else { return nil }
        return Ddots.absent(post, cast: ddotsMembers, users: ddotsUsers, members: members[hub] ?? [])
    }
    func projectChoice(_ thread: SlackThread, approval: ThreadProject.Approval, approve: Bool) {
        guard connected, approval.pending, project(thread)?.approvals?.contains(approval) == true else { return }
        onSend?("프로젝트 " + (approve ? "승인 " : "거부 ") + approval.id, thread.room, thread, [])
    }
    /// What the line being sent shows.
    func outgoing(_ text: String) -> String { hubPost(text)?.shown ?? text }
    /// Pressing a face aims the next new post at that character. Pressing the pressed face again lets the words decide.
    func aim(_ member: DdotsMember) {
        cancelFollowup()
        let letGo = ddotsPicked && ddotsTarget == member.profile && target == nil
        // The words being written for a thread stay with it; the face is pressed for the new post's own draft.
        moveDraft { Self.animated { replyTo = nil; picked = nil; newPost = true } }
        Self.animated {
            if letGo { ddotsPicked = false }
            else { ddotsTarget = member.profile; ddotsPicked = true }
        }
        focusRevision += 1
    }
    /// Direct conversations sit behind one tab that unfolds when pressed. These are the rooms behind it.
    @Published var stacked: [SlackRoom] = []
    @Published var stackOpen = false { didSet { if stackOpen != oldValue { onStack?() } } }
    var onStack: (() -> Void)?
    func toggleStack() {
        let response = StallTrace.shared.response(stackOpen ? "listClose" : "listOpen")
        defer { StallTrace.shared.finish(response) }
        Self.animated { stackOpen.toggle() }
    }
    /// The tab drawn as chosen: the room's own, or the stack's while the room is folded away behind it.
    var chosenTab: String? {
        guard let selected else { return nil }
        if stackFolds && !stackOpen && stacked.contains(where: { $0.id == selected }) { return Ddots.stack }
        if let zone = sections.first(where: { groupFolds($0) && !groupsOpen.contains($0) && (groups[$0] ?? []).contains { $0.id == selected } }) { return Ddots.group(zone) }
        return selected
    }
    /// Folded, the stack only says that something new waits behind it; how much shows on each room once it is unfolded.
    var stackWaiting: Bool { stacked.contains { (unread[$0.id] ?? 0) > 0 && !muted.contains($0.id) } }
    /// The pet at the top of ddots: its sprites, and counts that go up when an answer lands or a message goes out.
    var atlas: SpriteAtlas?
    @Published var petHop = 0
    @Published var petWave = 0
    @Published var rooms: [SlackRoom] = []
    @Published var selected: String? { didSet { if selected != oldValue { pageHold = nil; cancelFollowup(); copyWaiting = nil; opening = nil; findHighlight = nil; rendering.removeAll() } } }
    @Published var threads: [SlackThread] = [] { didSet { refreshThreadRenderMemos(); entryContentRevision += 1; pruneEntryRows(); rowGeometry = rowGeometry.filter { key, _ in threads.contains { $0.id == key } }; pruneRendering(); updateWriting(); selectAnsweredPost(); finishCopy(); finishOpening(); if let pageHold, !threads.contains(where: { thread in thread.id == pageHold || thread.messages.contains { "page-anchor:" + $0.id == pageHold } }) { self.pageHold = nil }; refreshEntryViewport() } }
    private struct RenderKey: Equatable {
        var body: String
        var dark: Bool
        var link: PaletteRGB
        var trusted: Bool
    }
    private var rendering: [String: (RenderKey, [SlackRenderedBlock])] = [:]
    private func pruneRendering() {
        let ids = Set(threads.flatMap { $0.messages.map(\.id) })
        rendering = rendering.filter { ids.contains($0.key) }
    }
    func presentation(_ id: String, body: String, dark: Bool, link: PaletteRGB, trusted: Bool = false,
                      style: (String) -> AttributedString) -> [SlackRenderedBlock] {
        let key = RenderKey(body: body, dark: dark, link: link, trusted: trusted)
        if let cached = rendering[id], cached.0 == key { return cached.1 }
        let blocks = SlackBlock.split(body).map { SlackRenderedBlock(id: $0.id, quote: $0.quote, text: style($0.text)) }
        if rendering.count >= 800 { rendering.removeAll() }
        rendering[id] = (key, blocks)
        return blocks
    }
    @Published var unread: [String: Int] = [:]
    /// Who has spoken in each room, for the faces on its tab.
    @Published var members: [String: [SlackMember]] = [:]
    /// Characters writing a reply right now, by thread.
    @Published var typing: [String: [TypingIndicator]] = [:] { didSet { updateWriting() } }
    /// Threads whose run the user stopped; each offers the undo request until it is sent or the user writes there.
    @Published var stopped = Set<String>()
    func stop(_ thread: SlackThread) {
        guard !stopped.contains(thread.id) else { return }
        stopped.insert(thread.id)
        onSend?(AgentStop.command, thread.room, thread, [])
    }
    func askUndo(_ thread: SlackThread) {
        guard stopped.remove(thread.id) != nil else { return }
        onSend?(AgentStop.undoRequest, thread.room, thread, [])
    }
    private(set) var isWriting = false
    private func updateWriting() {
        isWriting = typing.values.contains { !$0.isEmpty } || threads.contains { thread in
            thread.messages.contains { !$0.fromUser && SlackText.isThinking($0.body) }
        }
    }
    /// The newest line in each room, for the list's preview.
    @Published var latest: [String: ChatMessage] = [:]
    /// The strip's resting width: 0 hidden, square tabs, or a list.
    @Published var sidebarWidth = SlackSidebar.width { didSet { if sidebarWidth != oldValue { onLayout?() } } }
    private var shownSidebarWidth = SlackSidebar.width
    var onSidebar: ((CGFloat) -> Void)?
    /// Up to five rooms kept at fixed places from the top; an empty string is a free place.
    @Published var pins = Array(repeating: "", count: SlackRoomOrder.slots)
    @Published var findHighlight: (thread: String, term: String)?
    @Published var findOpen = false
    @Published var findQuery = "" { didSet { if findQuery != oldValue { onFind?() } } }
    @Published var findGroups: [SlackSearch.Group] = []
    @Published var findBusy = false
    /// What whole search could not read, said in the results; empty when nothing is missing.
    @Published var findGaps: [String] = []
    /// How far the record has been read while search is open.
    @Published var findProgress: String?
    @Published var findNotice: String?
    @Published var findSelection = 0
    @Published var findFocus = 0
    var onFind: (() -> Void)?
    var onFindOpen: (() -> Void)?
    var onFindSubmit: (() -> Void)?
    var onFindReveal: ((SlackSearch.Group, ChatMessage) -> Void)?
    @Published var query = "" { didSet {
        if query != oldValue {
            if SlackSearch.normalized(query).isEmpty { findHighlight = nil }
            onQuery?()
        }
    } }
    @Published var hits: [ChatMessage] = []
    var onPins: (() -> Void)?
    var onQuery: (() -> Void)?
    var onReveal: ((String) -> Void)?
    func pin(_ room: String, slot: Int?) {
        Self.animated {
            pins = pins.map { $0 == room ? "" : $0 }
            if let slot, pins.indices.contains(slot) { pins[slot] = room }
            onPins?()
        }
    }
    /// Where a drag of the strip's edge began: the pointer on the screen and the strip's width.
    var sidebarDrag: (pointer: CGFloat, width: CGFloat)?
    func dragSidebar(to width: CGFloat) { sidebarWidth = SlackSidebar.snapped(width) }
    func finishSidebarDrag() { if sidebarWidth > 0 { shownSidebarWidth = sidebarWidth }; onSidebar?(sidebarWidth) }
    func cycleSidebarWidth() {
        guard sidebarDrag == nil else { return }
        sidebarWidth = sidebarWidth == SlackSidebar.width ? SlackSidebar.expandedWidth : SlackSidebar.width
        finishSidebarDrag()
    }
    func toggleSidebar() {
        if sidebarWidth > 0 { shownSidebarWidth = sidebarWidth; sidebarWidth = 0 } else { sidebarWidth = shownSidebarWidth }
        onSidebar?(sidebarWidth)
    }
    /// Threads the user opened to see every reply.
    @Published var open = Set<String>() { didSet { if let highlight = findHighlight, oldValue.contains(highlight.thread), !open.contains(highlight.thread) { findHighlight = nil } } }
    @Published var replyTo: String?
    var draft: String { get { composer.text } set { composer.text = newValue } }
    @Published var notice: String?
    @Published var loading = false
    @Published var hasOlder = false
    @Published var scrollRevision = 0
    @Published var focusRevision = 0
    var scrollTarget = "slack-bottom"
    /// The thread opened last; the window grows to show it whole.
    @Published var focusThread: String?
    /// Measured by the view, read by the window layout.
    var viewportHeight: CGFloat = 0
    var threadHeights: [String: CGFloat] = [:]
    var onLayout: (() -> Void)?
    /// The room's notice, and where the last press on each of its counts landed.
    @Published var notices: [SlackNoticeItem] = []
    @Published var flash: String?
    /// Threads with a bell: true while the notification or question is unread, false once the user marked it read.
    @Published var bells: [String: Bool] = [:]
    var onBell: ((SlackThread) -> Void)?
    @Published var confirmed: Set<String> = []
    var onRead: ((SlackThread) -> Void)?
    var onConfirm: ((SlackThread) -> Void)?
    func confirm(_ thread: SlackThread) { onConfirm?(thread) }
    var onReadAll: (() -> Void)?
    /// The user clicked into a thread, or went to it from the notice: a plain notification there counts as seen.
    var onSeen: ((SlackThread) -> Void)?
    /// What waits in each tab of the strip, for its marks: notifications and questions, not unread lines.
    @Published var roomNotices: [String: RoomNotice] = [:]
    struct RoomNotice: Equatable { var alerts = 0, questions = 0 }
    var alertCount: Int { notices.first { $0.id == SlackNotice.alertID }?.threads.count ?? 0 }
    private var noticeCursor: [String: Int] = [:]
    /// Each press goes to the next waiting post, starting from the oldest.
    func jump(_ item: SlackNoticeItem) {
        cancelFollowup()
        guard !item.threads.isEmpty else { return }
        // Visiting a notification clears it, so the oldest one left is always next.
        let next = item.id == SlackNotice.alertID ? 0 : (noticeCursor[item.id] ?? -1) + 1
        let index = next % item.threads.count
        noticeCursor[item.id] = index
        go(to: item.threads[index])
    }
    /// Brings one thread into view, opened, picked and marked for a moment.
    func go(to target: String) {
        if !threads.contains(where: { $0.id == target }) { onNeedThread?(target) }
        cancelFollowup()
        // The request and its buttons may sit among folded replies, so the thread is opened on the way.
        if let thread = threads.first(where: { $0.id == target }), !open.contains(target) {
            Self.animated { open = [target]; focusThread = target }
            onOpen?(thread); onLayout?()
        }
        if let thread = threads.first(where: { $0.id == target }) { onRead?(thread); onSeen?(thread) }
        // Going to a waiting thread picks it and readies a reply to it. Words written for another place stay there.
        moveDraft { Self.animated { picked = target; replyTo = nil; newPost = false } }
        focusRevision += 1
        requestScroll(target)
        Self.animated { flash = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.flash == target { Self.animated { self?.flash = nil } }
        }
    }
    /// Pictures already fetched, files being saved, and files picked for the next message.
    @Published var failedThumbs = Set<String>()
    @Published var thumbs: [String: NSImage] = [:]
    @Published var busyFiles = Set<String>()
    @Published var attachments: [URL] = []
    var composerFocused = false
    var privateFiles: SlackTemporaryFiles?
    private let clipboardFiles = ClipboardAttachments(area: SlackModel.pasteArea)
    /// UI checks use a folder of their own, or the one a check names to see a later run recover what an earlier one left.
    static let pasteArea: URL = {
        let args = CommandLine.arguments
        guard args.contains("--ui-smoke") else { return ClipboardAttachments.defaultArea }
        if let index = args.firstIndex(of: "--ui-smoke-paste-area"), index + 1 < args.count { return URL(fileURLWithPath: args[index + 1], isDirectory: true) }
        let area = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-pasted-images-smoke-" + UUID().uuidString, isDirectory: true)
        SmokeLeftovers.note(area)
        return area
    }()
    func recoverPastedImages(done: ((Int) -> Void)? = nil) { clipboardFiles.recoverLeftovers(done: done) }
    func closeClipboardFiles() -> URL? { clipboardFiles.close() }
    var canAttach: Bool { source == .slack && connected && (target?.room ?? postRoom) != nil }
    @discardableResult func pasteAttachments(from board: NSPasteboard = .general) -> Bool {
        guard source == .slack, (target?.room ?? postRoom) != nil,
              let result = clipboardFiles.read(board, available: Self.mostAttachments - attachments.count, temporary: unkept.contains(target?.room ?? postRoom ?? "") ? privateFiles : nil) else { return false }
        if !result.files.isEmpty { attach(result.files) }
        if let notice = result.notice { self.notice = notice }
        return true
    }
    var onThumb: ((ChatFile) -> Void)?
    var onFile: ((ChatFile, ChatMessage) -> Void)?
    var onAttach: (() -> Void)?
    /// Threads being deleted from Slack, by id, with how far each has got.
    @Published var removing: [String: SlackBridge.Removal] = [:]
    /// The thread whose 삭제 was pressed once; pressing again within a moment deletes it.
    @Published var confirmingDelete: String?
    var onDelete: ((SlackThread) -> Void)?
    /// Deleting cannot be undone in Slack, so the first press only asks.
    func delete(_ thread: SlackThread) {
        guard !thread.ts.isEmpty, removing[thread.id] == nil, thread.replyCount > 0 || thread.root.fromUser else { return }
        guard confirmingDelete == thread.id else {
            Self.animated { confirmingDelete = thread.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                if self?.confirmingDelete == thread.id { Self.animated { self?.confirmingDelete = nil } }
            }
            return
        }
        Self.animated { confirmingDelete = nil }
        onDelete?(thread)
    }
    /// The thread a carry-on was just asked for, so the button is not pressed twice while Hermes opens the new one.
    @Published var branching: String?
    /// Asks Hermes to carry a thread on in a new one, with what was said so far.
    func branch(_ thread: SlackThread) {
        guard branching != thread.id, !thread.ts.isEmpty else { return }
        onSend?(SlackNotice.branchText, thread.room, thread, [])
        Self.animated { branching = thread.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.branching == thread.id { Self.animated { self?.branching = nil } }
        }
    }
    /// Answers an approval request in its thread with one word.
    /// A mail draft reported outside shared room is not heard where it was posted, so sending it is asked of its
    /// character in shared room instead, and the draft's buttons are put away.
    func answer(_ thread: SlackThread, approve: Bool) {
        if approve, let relay = mailRelay(thread, ask: "그대로 발송해줘. 수신자·제목·본문은 초안과 같게.") {
            if let missing = absent(from: relay.post) {
                onRefuse?("\(missing.name)\(Ddots.particle(missing.name)) #\(Ddots.channel) 채널에 없어요. 슬랙에서 채널에 초대한 뒤 다시 보내 주세요.")
                return
            }
            relayed = (relay.text, relay.post)
            onSend?(relay.text, relay.room, nil, [])
            relayed = nil
            confirm(thread)
            select(Ddots.room)
            return
        }
        onSend?(SlackNotice.answerText(thread, approve: approve), thread.room, thread, [])
    }
    func answerHermes(_ thread: SlackThread, label: String) {
        guard let text = SlackNotice.hermesAnswer(thread, label: label) else { return }
        onSend?(text, thread.room, thread, [])
    }
    func skipHermesChecklist(_ thread: SlackThread) {
        guard let text = SlackNotice.checklistSkipAnswer(thread) else { return }
        onSend?(text, thread.room, thread, [])
    }
    func answerHermesChecklist(_ thread: SlackThread, selected: Set<String>) {
        guard let text = SlackNotice.checklistAnswer(thread, selected: selected) else { return }
        onSend?(text, thread.room, thread, [])
    }
    /// Asking for changes to such a draft opens a new post in shared room to its character, naming the draft.
    func revise(_ thread: SlackThread) {
        guard let relay = mailRelay(thread, ask: "이렇게 고쳐서 초안 다시 보여줘: ") else { reply(thread); return }
        select(Ddots.room)
        writeNewPost()
        Self.animated { ddotsTarget = relay.member.profile; ddotsPicked = true }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { draft = relay.text }
    }
    /// A post made for the user, sent as worked out here rather than from the composer.
    private(set) var relayed: (text: String, post: DdotsPost)?
    func relayedPost(_ text: String) -> DdotsPost? { relayed.flatMap { $0.text == text ? $0.post : nil } }
    /// Who in shared room a mail draft posted elsewhere is for, and the words that ask them about it.
    func mailRelay(_ thread: SlackThread, ask: String) -> (member: DdotsMember, room: String, text: String, post: DdotsPost)? {
        guard !ddotsRooms.contains(thread.room), let request = SlackNotice.pendingApproval(thread), SlackNotice.isMailDraft(request.body),
              let member = ddotsMembers.first(where: { $0.profile == request.profile }) ?? ddotsMembers.first(where: { $0.profile == DdotsConfig.shared.role("data_operations") }),
              let room = ddotsHub ?? Optional(member.room), !room.isEmpty else { return nil }
        let place = rooms.first { $0.id == thread.room }?.name ?? "다른 방"
        let title = request.body.split(whereSeparator: \.isNewline).lazy
            .map { $0.drop(while: { $0 == "#" || $0 == ">" || $0 == " " || $0 == "*" }).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }.map { $0.count > 60 ? String($0.prefix(60)) + "…" : $0 } ?? "메일 초안"
        let link = SlackCopy.link(workspace: workspace, room: thread.room, ts: thread.ts).map { " (" + $0 + ")" } ?? ""
        let text = "\(place)에 올린 「\(title)」\(link) \(ask)"
        let post = Ddots.post(text, to: member, cast: ddotsMembers, users: ddotsUsers, members: ddotsHub.flatMap { members[$0] } ?? [], prependCall: ddotsHub != nil)
        return (member, room, text, post)
    }
    // Test seams and selection state remain memory-only.
    var onShowFile: ((URL) -> Bool)?
    var vaultOverride: ShrimpVault?
    var vaultOpen: ((String) -> String?)?
    var vaultReveal: ((String) -> String?)?
    var vault: ShrimpVault { vaultOverride ?? ShrimpVault.configured }
    @Published private var vaultSent = Set<String>()
    var vaultPicker: (() -> URL?)?
    var vaultSettings: ShrimpVaultSettings?
    func chooseVaultFolder() {
        let chosen: URL?
        if let vaultPicker { chosen = vaultPicker() }
        else {
            let panel = NSOpenPanel()
            panel.title = "새우튀김 보관함 폴더 지정"
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
            chosen = panel.runModal() == .OK ? panel.url : nil
        }
        guard let chosen else { return }
        do {
            try (vaultSettings ?? .standard).save(chosen.path)
            if vaultOverride != nil { vaultOverride?.root = chosen.path }
            objectWillChange.send()
            notice = nil
        } catch { notice = "보관함 폴더 설정을 저장하지 못했어요." }
    }
    func vaultSelections(_ thread: SlackThread) -> [ShrimpVault.Selection] {
        guard source == .slack, selected == thread.room,
              let current = threads.first(where: { $0.id == thread.id }) else { return [] }
        return vault.selections(current).filter { !vaultSent.contains($0.message + ":종결") }
    }
    func vaultSelection(_ thread: SlackThread) -> ShrimpVault.Selection? { vaultSelections(thread).last }
    @discardableResult func vaultPath(_ url: URL, message: ChatMessage) -> Bool {
        guard url.isFileURL, vault.pathLines(message).contains(url.path) else { return false }
        if let vaultReveal { notice = vaultReveal(url.path) }
        else { notice = vault.perform(url.path, reveal: true, absolute: true) }
        if notice == nil, let thread = threads.first(where: { $0.messages.contains(where: { $0.id == message.id }) }) { onRead?(thread) }
        return true
    }
    func vaultAlreadySent(_ selection: ShrimpVault.Selection, _ command: String) -> Bool {
        selection.sent.contains(command) || vaultSent.contains(selection.message + ":" + command)
    }
    func vaultAction(_ action: String, thread: SlackThread, selection: ShrimpVault.Selection) {
        guard let live = vaultSelections(thread).first(where: { $0.message == selection.message }),
              let current = threads.first(where: { $0.id == thread.id }) else { return }
        switch action {
        case "경로 줘", "다운로드", "표", "수정", "종결":
            if action == "수정" && !live.editable { return }
            if action == "표" && !live.table { return }
            guard !vaultAlreadySent(live, action), let send = onSend else { return }
            // Retain claims for visible selections; never clear live claims at a size threshold.
            let liveIDs = Set(threads.flatMap { vault.selections($0).map(\.message) })
            vaultSent = vaultSent.filter { claim in liveIDs.contains { claim.hasPrefix($0 + ":") } }
            vaultSent.insert(live.message + ":" + action)
            if action == "수정" { reply(current) }
            keepOpen(current)
            send(ShrimpVault.command(action, for: live), current.room, current, [])
        case "파일오픈":
            if let vaultOpen { notice = vaultOpen(live.relative) }
            else {
                notice = vault.perform(live.relative, reveal: false, open: { [self] url in
                    onShowFile?(url) == true || NSWorkspace.shared.open(url)
                })
            }
            if notice == nil { onRead?(current) }
        default: break
        }
    }
    // Synology links. Which file of a message the buttons act on and what was asked are kept only while the app runs;
    // a message put away with 확인 is remembered for as long as its buttons would have shown.
    static let driveDoneKey = "synologyConfirmed"
    @Published var driveChosen: [String: String] = [:]
    @Published private var driveSent = Set<String>()
    @Published private var driveDone: [String: Double] = CommandLine.arguments.contains("--ui-smoke") ? [:]
        : UserDefaults.standard.dictionary(forKey: SlackModel.driveDoneKey) as? [String: Double] ?? [:]
    @Published var driveListMessage: String?
    /// Closes the list at the right; the window draws back to the conversation.
    var onListClose: (() -> Void)?
    /// The list at the right belongs to one thread. Turning to another thread puts it away.
    private func leaveList(for thread: SlackThread) {
        let owner = shrimpListThread ?? driveListMessage.flatMap { id in threads.first { $0.messages.contains { $0.id == id } }?.id }
        guard let owner, owner != thread.id else { return }
        shrimpListThread = nil; driveListMessage = nil
        onListClose?()
    }
    var driveShow: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    func driveItems(_ message: ChatMessage, now: Date = Date()) -> [SynologyLink.Item] {
        guard source == .slack, !message.fromUser, now.timeIntervalSince(message.date) < ShrimpVault.lifetime, driveDone[message.id] == nil else { return [] }
        return SynologyLink.links(in: message.body)
    }
    /// The one file a message links to, or of several the one last pressed or picked from the list.
    func driveSelection(_ message: ChatMessage, items: [SynologyLink.Item]) -> SynologyLink.Item? {
        items.count == 1 ? items[0] : items.first { $0.path == driveChosen[message.id] }
    }
    func driveList() -> [ShrimpCandidates.Candidate] {
        guard let id = driveListMessage, let message = threads.lazy.flatMap(\.messages).first(where: { $0.id == id }) else { return [] }
        return driveItems(message).enumerated().map { ShrimpCandidates.Candidate(number: $0.offset + 1, file: $0.element.name, folder: $0.element.folder, location: "") }
    }
    func driveChoose(_ number: Int) {
        guard let id = driveListMessage, let message = threads.lazy.flatMap(\.messages).first(where: { $0.id == id }) else { return }
        let items = driveItems(message)
        if items.indices.contains(number - 1) { driveChosen[id] = items[number - 1].path }
    }
    /// A link pressed in a message that has several becomes the file its buttons act on.
    func driveNote(_ url: URL, message: ChatMessage) {
        guard let path = SynologyLink.components(of: url)?.joined(separator: "/") else { return }
        if driveItems(message).contains(where: { $0.path == path }) { driveChosen[message.id] = path }
    }
    func driveAlreadySent(_ action: String, item: SynologyLink.Item, message: ChatMessage, thread: SlackThread) -> Bool {
        guard let command = SynologyLink.commands[action] else { return false }
        let text = command + ": " + item.path
        return driveSent.contains(message.id + ":" + text)
            || thread.messages.contains { $0.fromUser && $0.date >= message.date && $0.body.trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }
    func driveAction(_ action: String, item: SynologyLink.Item, message: ChatMessage, thread: SlackThread) {
        guard let current = threads.first(where: { $0.id == thread.id }), driveItems(message).contains(item) else { return }
        switch action {
        case "경로":
            switch SynologyLink.target(for: item.url) {
            case .open(let file)?, .reveal(let file)?, .folder(let file)?: driveShow(file); notice = nil; onRead?(current)
            case nil: notice = "이 Mac의 시놀로지 드라이브 폴더에 없는 파일이에요."
            }
        case "다운", "수정":
            guard let command = SynologyLink.commands[action], !driveAlreadySent(action, item: item, message: message, thread: current), let send = onSend else { return }
            let text = command + ": " + item.path
            driveSent.insert(message.id + ":" + text)
            if action == "수정" { reply(current) }
            keepOpen(current)
            send(text, current.room, current, [])
        case "확인":
            let now = Date().timeIntervalSince1970
            driveDone = driveDone.filter { now - $0.value < ShrimpVault.lifetime }
            driveDone[message.id] = now
            driveChosen[message.id] = nil
            driveSent = driveSent.filter { !$0.hasPrefix(message.id + ":") }
            if driveListMessage == message.id { driveListMessage = nil }
            if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(driveDone, forKey: Self.driveDoneKey) }
            onRead?(current)
        default: break
        }
    }
    // Only thread identity and short-lived send claims; candidate bodies stay in the live snapshot.
    @Published var shrimpListThread: String? { didSet { if oldValue != shrimpListThread { shrimpListPage = 1 }; if shrimpListThread != nil { driveListMessage = nil } } }
    @Published var shrimpListPage = 1
    @Published var shrimpPendingPages: [String: Int] = [:]
    var onPageSend: ((String, SlackThread, @escaping () -> Void) -> Void)?
    func clickCard(_ thread: SlackThread, foldable: Bool) { pick(thread, foldable: foldable) }
    func clickConversationSpace() { foldAll() }
    @Published var pageTopPadding: CGFloat = 0
    @Published var pageHold: String? { didSet { if pageHold != nil { cancelEntry() } } }
    private var pageHoldOffset: CGFloat = 0
    private var pageHoldScrolls = 0
    func holdPage(_ message: ChatMessage) { holdPageAnchor("page-anchor:" + message.id) }
    func holdThreadPage(_ id: String) { holdPageAnchor(id) }
    private func holdPageAnchor(_ id: String) {
        guard let frame = rowFrame(id), let scroll = scrollView else { return }
        if pageHold == nil { pageTopPadding = 0 }
        pageHoldOffset = frame.minY - scroll.contentView.bounds.minY
        pageHoldScrolls = userScrolls
        pageHold = id
    }
    func restorePage() {
        guard let id = pageHold else { return }
        for delay in [0.0, 0.06, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pageHold == id, self.userScrolls == self.pageHoldScrolls,
                      let frame = self.rowFrame(id), let scroll = self.scrollView, let document = scroll.documentView else { return }
                let bounds = scroll.contentView.bounds
                let wanted = frame.minY - self.pageHoldOffset
                // A shorter first page can put the old button position below the new document top.
                // Reserve that missing space instead of asking NSClipView for a negative origin.
                if wanted < document.bounds.minY - 0.5 {
                    self.pageTopPadding += document.bounds.minY - wanted
                    return
                }
                let y = min(max(wanted, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - bounds.height))
                scroll.contentView.scroll(to: CGPoint(x: bounds.minX, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
    private var shrimpPageTasks: [String: DispatchWorkItem] = [:]
    private var shrimpPageBusy = Set<String>()
    private var shrimpAllBusy = Set<String>()
    private var shrimpPageQueued: [String: (String, ChatMessage)] = [:]
    private var shrimpPageClaims: [String: Date] = [:]
    func shrimpThread(_ message: ChatMessage) -> SlackThread? { threads.first { $0.messages.contains { $0.id == message.id } } }
    func shrimpAll(_ threadID: String?) -> [ShrimpCandidates.Candidate] {
        guard let thread = threads.first(where: { $0.id == threadID }) else { return [] }
        return vault.allList(thread)
    }

    func shrimpPageCommand(_ command: String, message: ChatMessage) {
        let kind = command == "전체 보기" ? "all" : command.hasPrefix("쪽: ") ? "page" : "pick"
        let current = shrimpThread(message)
        guard source == .slack, vault.trusted(message), let current,
              selected == current.room || isDdots && ddotsShown.contains(current.room),
              current.messages.contains(where: { $0.id == message.id && $0.body == message.body }),
              ShrimpPage.parse(message.body) != nil || ShrimpAllHeader.parse(message.body) != nil,
              let send = onSend else {
            PageTrace.log("model \(kind) refused slack=\(source == .slack) trusted=\(vault.trusted(message)) thread=\(current != nil) ddots=\(isDdots) room_selected=\(current.map { selected == $0.room } ?? false) room_in_ddots=\(current.map { ddotsShown.contains($0.room) } ?? false) same_body=\(current?.messages.contains(where: { $0.id == message.id && $0.body == message.body }) ?? false) controls=\(ShrimpPage.parse(message.body) != nil) all_header=\(ShrimpAllHeader.parse(message.body) != nil) send=\(onSend != nil)")
            return
        }
        keepOpen(current)
        if command == "전체 보기", let onPageSend {
            let present = shrimpAll(current.id).count
            PageTrace.log("model all present=\(present) busy=\(shrimpPageBusy.contains(current.id)) queued=\(shrimpPageTasks[current.id] != nil) \(vault.allDiagnosis(current))")
            guard present == 0 else { return }
            // Serialize with page navigation; a repeat click while loading sends nothing.
            guard !shrimpPageBusy.contains(current.id), shrimpPageTasks[current.id] == nil else { return }
            shrimpPageBusy.insert(current.id)
            shrimpAllBusy.insert(current.id)
            onPageSend(command, current) { [weak self] in
                self?.shrimpPageBusy.remove(current.id)
                self?.shrimpAllBusy.remove(current.id)
                if let self, let live = self.threads.first(where: { $0.id == current.id }) {
                    PageTrace.log("model all done present=\(self.shrimpAll(live.id).count) \(self.vault.allDiagnosis(live))")
                }
                self?.shrimpPageQueued[current.id] = nil
            }
            return
        }
        if let target = Int(command.hasPrefix("쪽: ") ? String(command.dropFirst(3)) : ""), let onPageSend {
            guard !shrimpAllBusy.contains(current.id), let page = ShrimpPage.parse(message.body), (1...page.pages).contains(target) else { return }
            if !shrimpPageBusy.contains(current.id) && page.current == target {
                shrimpPageTasks.removeValue(forKey: current.id)?.cancel()
                shrimpPageQueued[current.id] = nil
                shrimpPendingPages[message.id] = nil; return
            }
            holdPage(message)
            shrimpPendingPages[message.id] = target
            shrimpPageQueued[current.id] = (command, message)
            shrimpPageTasks[current.id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.shrimpPageBusy.contains(current.id),
                      let queued = self.shrimpPageQueued.removeValue(forKey: current.id) else { return }
                self.shrimpPageTasks[current.id] = nil
                self.shrimpPageBusy.insert(current.id)
                onPageSend(queued.0, current) { [weak self] in
                    guard let self else { return }
                    self.shrimpPageBusy.remove(current.id)
                    if let next = self.shrimpPageQueued.removeValue(forKey: current.id),
                       let live = self.shrimpThread(next.1)?.messages.first(where: { $0.id == next.1.id }) {
                        self.shrimpPageCommand(next.0, message: live)
                    } else { self.shrimpPendingPages[queued.1.id] = nil }
                }
            }
            shrimpPageTasks[current.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            return
        }
        let now = Date()
        shrimpPageClaims = shrimpPageClaims.filter { now.timeIntervalSince($0.value) < 2 }
        let key = message.id + ":" + message.body + ":" + command
        guard shrimpPageClaims[key] == nil else { return }
        shrimpPageClaims[key] = now
        pageHold = nil
        send(command, current.room, current, [])
    }

    static let mostAttachments = 10
    func attach(_ urls: [URL]) {
        Self.animated { for url in urls where !attachments.contains(url) && attachments.count < Self.mostAttachments { attachments.append(url) } }
        focusRevision += 1
    }
    func detach(_ url: URL) { Self.animated { attachments.removeAll { $0 == url } } }
    var rowGeometry: [String: CGRect] = [:]
    var resizeGeometryOffset = CGPoint.zero
    func resizeFrame(_ id: String) -> CGRect? {
        rowGeometry[id].map { $0.offsetBy(dx: resizeGeometryOffset.x, dy: resizeGeometryOffset.y) }
    }
    let resizingRows = SlackResizeRows()
    var resizeRows: [String: CGSize] { resizingRows.sizes }
    var resizeLive: Set<String> { resizingRows.live }
    func beginRowResize() {
        guard source == .slack, SlackResizeSmoke.holdsRows else { return }
        if let id = visibleThreads.first, let native = rowFrame(id), let frame = rowGeometry[id] {
            resizeGeometryOffset = CGPoint(x: native.minX - frame.minX, y: native.minY - frame.minY)
        }
        resizingRows.objectWillChange.send()
        resizingRows.sizes = Dictionary(uniqueKeysWithValues: threads.compactMap { thread in
            resizeFrame(thread.id).map { (thread.id, $0.size) }
        })
        updateRowResize()
    }
    @discardableResult func updateRowResize() -> Bool {
        guard !resizeRows.isEmpty, let scroll = scrollView else { return false }
        let bounds = scroll.contentView.bounds
        let margin = bounds.insetBy(dx: 0, dy: -bounds.height / 2)
        let live = Set(threads.compactMap { thread -> String? in
            guard let frame = resizeFrame(thread.id) else { return thread.id }
            return frame.intersects(margin) ? thread.id : nil
        })
        let next = resizeLive.union(live)
        guard next != resizeLive else { return false }
        resizingRows.objectWillChange.send(); resizingRows.live = next
        return true
    }
    struct ResizePlace {
        var id: String?
        var offset: CGFloat
        var bottom: Bool
        var scrolls: Int
        var revision: Int
    }
    func rowResizePlace() -> ResizePlace? {
        guard !resizeRows.isEmpty, let scroll = scrollView, let document = scroll.documentView else { return nil }
        let bounds = scroll.contentView.bounds
        let id = threads.first { resizeFrame($0.id)?.intersects(bounds) == true }?.id
        return ResizePlace(id: id, offset: id.flatMap(resizeFrame).map { $0.minY - bounds.minY } ?? 0,
                           bottom: document.bounds.maxY - bounds.maxY <= 2, scrolls: userScrolls, revision: scrollRevision)
    }
    func restoreRowResize(_ place: ResizePlace?) {
        guard let place, place.scrolls == userScrolls, place.revision == scrollRevision,
              let scroll = scrollView, let document = scroll.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let bounds = scroll.contentView.bounds
        let wanted: CGFloat
        if place.bottom { wanted = document.bounds.maxY - bounds.height }
        else if let id = place.id, let frame = resizeFrame(id) { wanted = frame.minY - place.offset }
        else { return }
        let y = min(max(wanted, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: bounds.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func endRowResize() {
        guard !resizeRows.isEmpty else { return }
        resizingRows.objectWillChange.send(); resizingRows.sizes = [:]; resizingRows.live = []
    }
    var measuringResize = false
    func measured(viewport: CGFloat? = nil, thread: String? = nil, height: CGFloat = 0) {
        if let viewport { guard abs(viewport - viewportHeight) > 0.5 else { return }; viewportHeight = viewport }
        if let thread { guard abs(height - (threadHeights[thread] ?? 0)) > 0.5 else { return }; threadHeights[thread] = height }
        guard !measuringResize, pageHold == nil else { restorePage(); return }
        if SlackResizeSmoke.measuring { SlackResizeSmoke.layouts += 1 }
        onLayout?()
    }
    var onSource: ((ChatSource) -> Void)?
    var onConnect: (() -> Void)?
    var onSelect: ((String) -> Void)?
    var onOpen: ((SlackThread) -> Void)?
    var onOlder: (() -> Void)?
    /// The words go as typed; whoever sends works out what is added for the channel while the pressed face still stands.
    var onSend: ((_ text: String, _ room: String, _ thread: SlackThread?, _ files: [URL]) -> Void)?
    /// A post that was not sent, with why.
    var onRefuse: ((String) -> Void)?

    /// Muted rooms keep collecting their own count but raise no bubble and stay out of the pet's badge.
    /// ddots repeats what its characters' own rooms already count, so it is left out; muting it quiets those rooms too.
    var unreadTotal: Int {
        let hushed = muted.contains(Ddots.room) ? Set(ddotsShown) : []
        return unread.filter { $0.key != Ddots.room && !muted.contains($0.key) && !hushed.contains($0.key) }.values.reduce(0, +)
    }
    @Published var muted = Set<String>()
    /// Rooms taken off the list. They stay in Slack untouched and can be put back.
    @Published var unkept = Set<String>()
    var onUnkept: (() -> Void)?
    func toggleUnkept(_ room: String) {
        if unkept.contains(room) { unkept.remove(room) } else { unkept.insert(room) }
        onUnkept?()
    }
    @Published var hidden = Set<String>()
    @Published var hiddenRooms: [SlackRoom] = []
    var onHidden: (() -> Void)?
    func hide(_ room: String) { Self.animated { hidden.insert(room); pins = pins.map { $0 == room ? "" : $0 }; onHidden?() } }
    func restore(_ room: String) { Self.animated { hidden.remove(room); onHidden?() } }
    /// The list falls in four zones parted by lines: the rooms, two groups the user fills by dragging rooms into them,
    /// and the direct conversations. Each group folds behind its own tab, as the direct conversations do, and has a
    /// name and a picture of the user's. Rooms are ordered by their newest message within their own zone.
    /// The zone of each room dragged into a group, by room; a room not here is in the first zone.
    @Published var zoneOf: [String: Int] = [:]
    /// The rooms in each group, in their order; set with `rooms`.
    @Published var groups: [Int: [SlackRoom]] = [:]
    @Published var groupsOpen = Set<Int>()
    @Published var groupNames: [Int: String] = [:]
    /// The zone a dragged room is held over, to be marked.
    @Published var dropZone: Int?
    var onZones: (() -> Void)?
    var onGroupRename: ((Int) -> Void)?
    /// The name the user gave a section, or its place from the top.
    func groupName(_ zone: Int) -> String {
        if let name = groupNames[zone], !name.isEmpty { return name }
        return "section \((sections.firstIndex(of: zone) ?? sections.count) + 1)"
    }
    /// The section of each row of `rooms`; set with them.
    @Published var rowZones: [String: Int] = [:]
    /// A section of two rooms or more folds behind its tab; one room alone is shown as itself.
    func groupFolds(_ zone: Int) -> Bool { (groups[zone]?.count ?? 0) >= 2 }
    var stackFolds: Bool { stacked.count >= 2 }
    func toggleGroup(_ zone: Int) {
        Self.animated { if groupsOpen.contains(zone) { groupsOpen.remove(zone) } else { groupsOpen.insert(zone) }; onZones?() }
    }
    /// Folded, a group only says that something new waits behind it, as the direct conversations' tab does.
    func groupWaiting(_ zone: Int) -> Bool { (groups[zone] ?? []).contains { (unread[$0.id] ?? 0) > 0 && !muted.contains($0.id) } }
    /// Rooms folded behind the groups' tabs.
    var grouped: [SlackRoom] { sections.flatMap { groups[$0] ?? [] } }
    /// The channel sections, from the top. The direct conversations' section always follows them.
    @Published var sections = Ddots.defaultSections
    var onDeleteSection: ((Int) -> Void)?
    /// The section a channel is in: the one it was dragged into, or the first.
    func section(of room: String) -> Int {
        if let zone = zoneOf[room], sections.contains(zone) { return zone }
        return sections.first ?? Ddots.defaultSections[0]
    }
    /// Adds an empty section at the bottom of the channel sections, to drag channels into.
    func addSection() {
        let next = (sections + [Ddots.directZone]).max()! + 1
        Self.animated { sections.append(next); onZones?() }
    }
    /// Takes a section away. Its channels go back to the first section; nothing changes in Slack. One section always stays.
    func removeSection(_ zone: Int) {
        guard sections.count > 1, sections.contains(zone) else { return }
        Self.animated {
            sections.removeAll { $0 == zone }
            zoneOf = zoneOf.filter { $0.value != zone }
            groupNames[zone] = nil; groupsOpen.remove(zone)
            onZones?()
        }
    }
    /// Moves a room into the first zone or a group. ddots, the tabs and the direct conversations keep their places.
    func move(_ room: String, toZone zone: Int) {
        dropZone = nil
        guard sections.contains(zone), room != Ddots.room, !Ddots.isTab(room), !stacked.contains(where: { $0.id == room }),
              rooms.contains(where: { $0.id == room }) || grouped.contains(where: { $0.id == room }), section(of: room) != zone else { return }
        Self.animated { zoneOf[room] = zone == sections.first ? nil : zone; onZones?() }
    }
    /// Pictures the user gave channels, by room. Slack keeps no picture for a channel, so they stay on this Mac.
    @Published var roomPictures: [String: NSImage] = [:]
    var onPicture: ((String) -> Void)?
    var onClearPicture: ((String) -> Void)?
    var onRename: ((String) -> Void)?
    /// Channels put away in Slack, to be brought back from the add menu.
    @Published var archivedRooms: [SlackRoom] = []
    /// Making a channel, asking people into one, putting one away or back, and deleting one, each asked for here and done by the controller.
    var onCreateRoom: (() -> Void)?
    var onInvite: ((String) -> Void)?
    var onInviteAgents: ((String) -> Void)?
    var onArchive: ((String) -> Void)?
    var onUnarchive: ((String) -> Void)?
    var onDeleteRoom: ((String) -> Void)?
    /// The iMessage conversation's own switch.
    @Published var chatMuted = false
    var onMute: (() -> Void)?
    var shownMuted: Bool { source == .slack ? selected.map(muted.contains) ?? false : chatMuted }
    func toggleMute(room: String? = nil) {
        if let room = room ?? (source == .slack ? selected : nil) {
            if muted.contains(room) { muted.remove(room) } else { muted.insert(room) }
        } else { chatMuted.toggle() }
        onMute?()
    }
    var room: SlackRoom? { rooms.first { $0.id == selected } ?? stacked.first { $0.id == selected } ?? grouped.first { $0.id == selected } }
    var replyThread: SlackThread? { threads.first { $0.id == replyTo } }
    /// True once the user has asked for a new post instead of a reply, until the room or the target changes.
    @Published var newPost = false
    /// When a character spoke last by opening a thread, what the user types next is taken as the answer to it.
    var defaultReply: SlackThread? {
        guard let newest = threads.filter({ !$0.ts.isEmpty }).max(by: { $0.latest < $1.latest }), !newest.root.fromUser else { return nil }
        return newest
    }
    /// The thread the user clicked last. It is what "답글" answers.
    @Published var picked: String?
    var pickedThread: SlackThread? { threads.first { $0.id == picked } }
    /// The thread the "답글" side of the switch answers: the one picked, else the one a character just opened.
    var replyCandidate: SlackThread? { replyThread ?? pickedThread ?? defaultReply ?? newestThread }
    /// Where the next message goes. "새 글" always means the room itself.
    /// ddots starts on a new post; a thread there is answered only once it is picked.
    var target: SlackThread? { target(for: draft) }
    private func target(for text: String) -> SlackThread? {
        guard !newPost else { return nil }
        let thread = replyThread ?? pickedThread ?? (isDdots ? nil : defaultReply)
        return thread
    }
    /// The thread chosen automatically for the answer to a new post; it stays the destination until the user chooses another.
    private var automaticReply: String?
    /// Only the latest successful new post can select its reply, until the user chooses another destination.
    private var followup: (room: String, ts: String?, files: Set<String>)?
    private(set) var composeRevision = 0
    func cancelFollowup() { composeRevision += 1; followup = nil; automaticReply = nil }
    func beginPost() -> Int { cancelFollowup(); return composeRevision }
    func followPost(room: String, ts: String?, files: Set<String> = [], revision: Int) {
        guard revision == composeRevision, ts != nil || !files.isEmpty else { return }
        followup = (room, ts, files)
        selectAnsweredPost()
    }
    private func selectAnsweredPost() {
        guard let followup, source == .slack,
              let thread = threads.first(where: { thread in
                  thread.room == followup.room && (followup.ts.map { thread.ts == $0 }
                    ?? !Set(thread.root.files.map(\.id)).isDisjoint(with: followup.files))
              }), thread.replies.contains(where: { !$0.fromUser && !SlackText.isThinking($0.body) }) else { return }
        // A draft or attachment may already be for a different new post; never redirect that work.
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, attachments.isEmpty else { cancelFollowup(); return }
        self.followup = nil
        moveDraft { Self.animated { automaticReply = thread.id; newPost = false; picked = thread.id; replyTo = thread.id } }
    }
    /// Drafts and failed sends of every place, while the app runs.
    @Published private(set) var drafts = SlackDrafts()
    /// The place the words in the draft belong to. It changes only when the user goes to write somewhere else.
    private var writing: SlackDraftPlace?
    /// Where the words being typed belong: a thread chosen to answer, a new post, or whatever the room answers by itself.
    var draftPlace: SlackDraftPlace {
        let shown = selected ?? "", ddots = source == .slack && selected == Ddots.room
        let aim: String
        if !newPost, let thread = replyTo ?? picked { aim = SlackDraftPlace.thread(thread) }
        else if newPost || ddots { aim = SlackDraftPlace.new(ddots ? ddotsHub ?? "" : shown) }
        else { aim = SlackDraftPlace.auto }
        return SlackDraftPlace(workspace: workspace, shown: shown, aim: aim)
    }
    var currentDraft: SlackSavedDraft { SlackSavedDraft(text: draft, files: attachments, pick: ddotsPicked ? ddotsTarget : nil) }
    private func show(_ saved: SlackSavedDraft) {
        draft = saved.text; attachments = saved.files
        if let pick = saved.pick { ddotsTarget = pick; ddotsPicked = true } else { ddotsPicked = false }
    }
    /// Carries out a change of where the user writes. What was being written stays with the place it was written for
    /// and the next place's own words come back. When the message would still go to the same thread of the same room,
    /// and nothing waits there, the words go along.
    /// `carry` takes the words along whenever nothing waits at the next place, for a place that is gone.
    private func moveDraft(carry: Bool = false, _ change: () -> Void) {
        let before = writing ?? draftPlace, aimed = target?.id, room = selected
        change()
        let next = draftPlace
        writing = next
        guard before != next else { return }
        if (carry || (room == selected && aimed == target?.id)), drafts.draft(at: next).isEmpty { return }
        // A room left with words in it is entered again at the same place, its thread or its new post.
        if before.shown != next.shown { lastAim[Self.roomKey(before)] = currentDraft.isEmpty ? nil : before.aim }
        drafts.put(currentDraft, at: before)
        show(drafts.take(at: next))
    }
    /// Where the user was writing in each room they left with words unsent.
    private var lastAim: [String: String] = [:]
    private static func roomKey(_ place: SlackDraftPlace) -> String { place.workspace + "\u{1}" + place.shown }
    /// Entering a room: no thread picked, unless the room was left with words for a thread or a new post.
    private func enter(_ room: String?) {
        selected = room; replyTo = nil; picked = nil; newPost = false
        guard let aim = lastAim[Self.roomKey(SlackDraftPlace(workspace: workspace, shown: room ?? "", aim: ""))] else { return }
        if aim.hasPrefix("thread:") { let id = String(aim.dropFirst("thread:".count)); replyTo = id; picked = id }
        else if aim.hasPrefix("new:") { newPost = true }
    }
    /// The room shown changes without the user choosing it: the first room once the list is read, or the room
    /// a bubble was about. What was being written stays with its own room.
    func show(room: String?) {
        guard selected != room else { return }
        moveDraft { enter(room) }
    }
    /// A thread that is gone can no longer be answered; what was being written for it moves to wherever the room now points.
    func release(thread id: String) {
        guard picked == id || replyTo == id else { return }
        moveDraft(carry: true) { if picked == id { picked = nil }; if replyTo == id { replyTo = nil } }
    }
    /// After a send the draft is empty; if the send moved the room to a new post, its own words come back.
    private func settleWriting() {
        let place = draftPlace
        guard writing != place else { return }
        writing = place
        show(drafts.take(at: place))
    }
    /// A new connection may be another workspace: what was being written is put away with the workspace it was for.
    func changeConnection() {
        if let writing { drafts.put(currentDraft, at: writing) }
        writing = nil; replyTo = nil; picked = nil; newPost = false
        show(SlackSavedDraft())
    }
    /// Once Slack says which workspace this is, an empty draft takes up what was left there.
    private func adoptWorkspace() {
        guard writing?.workspace != workspace else { return }
        let place = draftPlace, kept = drafts.take(at: place), typed = currentDraft
        writing = place
        guard !kept.isEmpty else { return }
        // Words typed while the connection changed are kept behind what was left there.
        var files = kept.files
        for file in typed.files where !files.contains(file) { files.append(file) }
        show(SlackSavedDraft(text: [kept.text, typed.text].filter { !$0.isEmpty }.joined(separator: "\n"), files: files, pick: typed.pick ?? kept.pick))
    }

    /// Messages that did not go and wait in the room shown, and how many wait in other rooms of this workspace.
    var failedHere: [SlackFailedSend] { drafts.failures(workspace: workspace, shown: selected) }
    var failedElsewhere: [SlackFailedSend] { drafts.elsewhere(workspace: workspace, shown: selected) }
    func recordFailure(_ failure: SlackFailedSend) { drafts.fail(failure) }
    /// Told when a failure was brought back or let go, so the room stops saying it.
    var onFailureSettled: (() -> Void)?
    func discardFailure(_ id: UUID) { drafts.discard(id); onFailureSettled?() }
    /// Goes to the room a failed message waits in.
    func showFailure(_ failure: SlackFailedSend) {
        guard failure.workspace == workspace else { return }
        select(failure.shown)
    }
    /// Brings a failed message back into the draft where it was going: its own thread, or a new post of its room,
    /// with the face that was pressed for it. It is not sent again until the user sends it.
    func restoreFailure(_ id: UUID) {
        guard let failure = drafts.failures.first(where: { $0.id == id }), failure.workspace == workspace else { return }
        guard selected == failure.shown else { showFailure(failure); return }
        if let thread = failure.thread {
            guard let live = threads.first(where: { $0.id == thread }) else { notice = "그 스레드를 아직 불러오지 못했어요. 잠시 뒤 다시 눌러 주세요."; return }
            reply(live)
        } else {
            writeNewPost()
        }
        switch drafts.restore(id, into: currentDraft) {
        case .success(let restored): show(restored); notice = nil; onFailureSettled?()
        case .failure(.tooManyFiles): notice = "첨부가 \(SlackDrafts.mostFiles)개를 넘어 되살리지 못했어요. 지금 첨부를 줄인 뒤 다시 눌러 주세요."
        case .failure(.gone): break
        }
        focusRevision += 1
    }
    /// Clicking a thread picks it; a thread with folded replies also opens, or folds again if it was open.
    func pick(_ thread: SlackThread, foldable: Bool) {
        cancelEntry()
        leaveList(for: thread)
        cancelFollowup()
        // Picking a thread means answering it, so the switch goes to 답글.
        moveDraft { Self.animated { picked = thread.id; replyTo = nil; newPost = false } }
        if foldable { toggle(thread) } else { foldOthers(than: thread) }
        onSeen?(thread)
    }
    /// A new post belongs to no thread, so choosing it lets go of the picked one.
    func writeNewPost() { cancelFollowup(); moveDraft { Self.animated { replyTo = nil; picked = nil; newPost = true } }; focusRevision += 1 }
    /// The thread with the newest line, whoever opened it, replies included. Of two as new, the one lower in the list.
    var newestThread: SlackThread? { threads.filter { !$0.ts.isEmpty }.reduce(nil) { best, thread in best.map { thread.latest >= $0.latest ? thread : $0 } ?? thread } }
    /// Where entering a room takes the reader: the newest line, or the thread an older post's new reply moved, which can
    /// sit far up in a room kept in posting order. An opened thread is shown from its newest reply. Nothing is opened or picked.
    var entryTarget: String {
        guard let newest = newestThread, newest.id != threads.last(where: { !$0.ts.isEmpty })?.id else { return "slack-bottom" }
        return open.contains(newest.id) ? Self.end(newest.id) : newest.id
    }
    /// The request made on entering the room. Any later request, from a click, a search or a link, takes over from it,
    /// and so does picking or folding a card, which asks for no place of its own.
    private(set) var entryRevision = -1
    var entryHolds: Bool { entryRevision == scrollRevision }
    func scrollToEntry() {
        guard requestScroll(entryTarget, entering: true) else { return }
        entryRevision = scrollRevision
        refreshEntryViewport()
    }
    /// The user chose something on screen: entering no longer moves the view, including passes still on their way.
    func cancelEntry() {
        entryRevision = -1
        entryViewport = nil
        scrollView?.alphaValue = 1
    }
    /// A render stamp prevents a shared thread ID, or a view left over from the preceding room, from supplying geometry.
    struct EntryViewportStamp: Equatable {
        var room: String?
        var request: Int
        var content: Int
    }
    private var entryContentRevision = 0
    var entryViewportStamp: EntryViewportStamp { EntryViewportStamp(room: selected, request: scrollRevision, content: entryContentRevision) }
    private struct EntryViewport {
        var stamp: EntryViewportStamp
        var target: String
        var scrolls: Int
        var ready = false
        /// Shown once at its place. Hiding is only for the first picture; afterwards a moment of waiting
        /// (a resize, a late table layout) keeps what is on screen instead of blanking it for a frame.
        var revealed = false
    }
    /// How often a revealed entry would have been hidden again; read by the pet-drag check.
    private(set) var entryRehides = 0
    private var entryViewport: EntryViewport?
    private var renderedEntryStamp: EntryViewportStamp?
    private var entryRowStamps: [String: EntryViewportStamp] = [:]
    private func pruneEntryRows() {
        let ids = Set(threads.flatMap { [$0.id, Self.end($0.id)] } + ["slack-bottom"])
        entryRowStamps = entryRowStamps.filter { ids.contains($0.key) }
    }
    private var preparingEntryViewport = false
    var entryViewportPending: Bool { entryViewport.map { !$0.ready } ?? false }
    /// UI checks observe the instant content becomes visible; waiting a second after entry misses a visible jump.
    var onEntryViewportVisible: (() -> Void)?
    var onEntryViewportFrame: (() -> Void)?
    private func refreshEntryViewport() {
        guard entryHolds, requestScrolls == userScrolls, source == .slack, pageHold == nil else { return }
        // New content in the room already on screen keeps it on screen while it settles at its place again;
        // only a first picture (a room entered, the window opened) waits hidden.
        let shown = entryViewport.map { $0.revealed && $0.stamp.room == entryViewportStamp.room } ?? false
        entryViewport = EntryViewport(stamp: entryViewportStamp, target: entryTarget, scrolls: userScrolls, revealed: shown)
        entryRowStamps.removeAll(keepingCapacity: true)
        if !shown { scrollView?.alphaValue = 0 }
        scrollView?.needsLayout = true
    }
    func recordEntryRow(_ view: NSView, id: String, stamp: EntryViewportStamp?) {
        rowViews.setObject(view, forKey: id as NSString)
        entryRowStamps[id] = stamp
    }
    func connectEntryViewport(_ scroll: NSScrollView, stamp: EntryViewportStamp) {
        // During a room transition the departing SwiftUI probe can still lay out after
        // the new table. Only the selected list is allowed to own this weak connection.
        let wantsNative = source == .slack && NativeListFeature.enabled
        guard wantsNative == (scroll is NativeThreadList.Scroll) else { return }
        if scrollView !== scroll { renderedEntryStamp = nil; nativeGeometry = nil }
        scrollView = scroll
        renderedEntryStamp = stamp
        scroll.alphaValue = entryViewportPending && entryViewport?.revealed != true ? 0 : 1
    }
    /// Called after the hosting view has laid out. Entry uses final native geometry, before showing the conversation.
    /// No timer or animated scroll is involved. Layout refinements stay anchored until actual user input takes over.
    @discardableResult func prepareEntryViewport() -> Bool {
        guard let entry = entryViewport else { return true }
        guard entryHolds, entry.stamp == entryViewportStamp, entry.scrolls == userScrolls,
              source == .slack, pageHold == nil else { cancelEntry(); return true }
        guard !preparingEntryViewport else { return !entryViewportPending }
        func waitingForLayout() -> Bool {
            entryViewport?.ready = false
            if entryViewport?.revealed == true { entryRehides += 1 } else { scrollView?.alphaValue = 0 }
            return false
        }
        guard let scroll = scrollView, let document = scroll.documentView,
              renderedEntryStamp == entry.stamp, scroll.contentView.bounds.height > 0, document.bounds.height > 0,
              (nativeGeometry?.isReady(stamp: entry.stamp) ?? (entryRowStamps["slack-bottom"] == entry.stamp &&
              threads.allSatisfy({ entryRowStamps[$0.id] == entry.stamp && rowFrame($0.id) != nil }))) else { return waitingForLayout() }
        let bounds = scroll.contentView.bounds
        // SwiftUI can update the probes before resizing its document. A fresh stamp alone cannot make the old
        // document's scroll range usable: every laid-out row and the bottom marker must fit the current document.
        func insideDocument(_ id: String) -> CGRect? {
            if let nativeGeometry { return nativeGeometry.frame(for: id) }
            guard let view = rowViews.object(forKey: id as NSString), view.isDescendant(of: document), view.bounds.height > 0 else { return nil }
            let frame = view.convert(view.bounds, to: document)
            return frame.minY >= document.bounds.minY - 1 && frame.maxY <= document.bounds.maxY + 1 ? frame : nil
        }
        guard let bottom = insideDocument("slack-bottom"), threads.allSatisfy({ insideDocument($0.id) != nil }) else { return waitingForLayout() }
        if document.bounds.height > bounds.height + 1,
           abs(document.bounds.maxY - bottom.maxY - Self.conversationInset) > 2 { return waitingForLayout() }
        let wanted: CGFloat
        if entry.target == "slack-bottom" {
            wanted = document.isFlipped ? document.bounds.maxY - bounds.height : document.bounds.minY
        } else {
            guard (nativeGeometry?.isReady(stamp: entry.stamp) ?? (entryRowStamps[entry.target] == entry.stamp)), let frame = rowFrame(entry.target), frame.height > 0 else { return waitingForLayout() }
            if entry.target.hasPrefix(Self.endMark) {
                wanted = document.isFlipped ? frame.maxY - bounds.height : frame.minY
            } else { wanted = frame.midY - bounds.height / 2 }
        }
        let y = min(max(wanted, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - bounds.height))
        preparingEntryViewport = true
        defer { preparingEntryViewport = false }
        if abs(bounds.minY - y) > 0.5 {
            scroll.contentView.scroll(to: NSPoint(x: bounds.minX, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        guard abs(scroll.contentView.bounds.minY - y) <= 1 else { return waitingForLayout() }
        if entry.target != "slack-bottom", let newest = newestThread, let frame = rowFrame(newest.id) {
            let visible = frame.intersection(scroll.contentView.bounds).height
            guard visible >= min(frame.height, bounds.height / 2) - 2 else { return waitingForLayout() }
        }
        entryViewport?.ready = true
        entryViewport?.revealed = true
        scrolledRevision = entry.stamp.request
        scroll.alphaValue = 1
        if !entry.ready { onEntryViewportVisible?() }
        return true
    }
    /// Clicking the room already shown is a fresh start there, even from a page held in place.
    var onEnterAgain: (() -> Void)?
    /// 답글 answers the picked thread; with none picked it picks the newest one and brings it into view.
    func writeReply() {
        cancelFollowup()
        let chosen = replyThread ?? pickedThread ?? newestThread
        moveDraft { Self.animated { newPost = false; if picked == nil, replyTo == nil { picked = chosen?.id } } }
        if let chosen { requestScroll(chosen.id) }
        focusRevision += 1
    }
    /// False when a page held in place keeps the view where it is.
    @discardableResult func requestScroll(_ id: String, entering: Bool = false) -> Bool {
        guard pageHold == nil else { return false }
        if !entering { cancelEntry() }
        scrollTarget = id; requestScrolls = userScrolls; scrollRevision += 1
        // The view normally hears of this through its own update. A request made right after an animated change
        // can miss that update, so it is also handed over directly; whichever comes first does the scrolling.
        DispatchQueue.main.async { [weak self] in self?.scroller?() }
        return true
    }
    /// How often the user had scrolled by hand when the waiting request was made; a later scroll by hand cancels it.
    private(set) var requestScrolls = 0
    /// Set by the conversation while it is on screen: carries out the request that is waiting.
    var scroller: (() -> Void)?
    /// The request the conversation has already begun to carry out.
    var scrolledRevision = -1
    /// The foot of a thread as a place to go to: its newest reply, with the room the window leaves under an opened thread.
    static let endMark = "slack-end:"
    static let conversationInset: CGFloat = 14
    static func end(_ thread: String) -> String { endMark + thread }
    /// A thread opened before its replies were read, and how often the user had scrolled by hand by then.
    private var opening: (thread: String, scrolls: Int)?
    /// Replies read after their thread was opened make it taller, so it is taken to its newest reply once more,
    /// unless the user has scrolled by hand or folded it in the meantime.
    private func finishOpening() {
        guard let opening, let thread = threads.first(where: { $0.id == opening.thread }) else { return }
        guard open.contains(thread.id), userScrolls == opening.scrolls else { self.opening = nil; return }
        if thread.loaded { self.opening = nil; requestScroll(Self.end(thread.id)) }
    }
    /// The conversation's own scroll view, found once it is on screen.
    weak var nativeGeometry: NativeThreadGeometry?
    weak var scrollView: NSScrollView?
    /// Goes up each time the user scrolls by hand. Nothing moves the view on its own after that.
    /// Raised for every trackpad event. Assigning a published value notifies even when unchanged, and each notice
    /// rebuilds the whole conversation, so the hold is cleared only when there is one.
    /// Uptime of the latest trackpad or wheel event over the list, momentum included. Not published.
    var scrollInputAt: TimeInterval = 0
    static let scrollQuiet: TimeInterval = 0.25
    var userScrolls = 0 { didSet { if oldValue != userScrolls { if pageHold != nil { pageHold = nil }; cancelEntry() } } }
    /// Within this distance of the newest line the reader is taken to be following the conversation.
    static let followDistance: CGFloat = 120
    /// Where the reader is, measured up from the newest line.
    let rowViews = NSMapTable<NSString, NSView>(keyOptions: .strongMemory, valueOptions: .weakMemory)
    func rowFrame(_ id: String) -> CGRect? {
        if let nativeGeometry { return nativeGeometry.frame(for: id) }
        guard let view = rowViews.object(forKey: id as NSString), let scroll = scrollView,
              view.window != nil, view.isDescendant(of: scroll) else { return nil }
        return view.convert(view.bounds, to: scroll.contentView)
    }
    var visibleThreads: [String] {
        guard let scroll = scrollView else { return [] }
        return threads.compactMap { thread in
            guard let frame = rowFrame(thread.id), frame.intersects(scroll.contentView.bounds) else { return nil }
            return thread.id
        }
    }
    struct Place { var fromBottom: CGFloat; var scrolls: Int; var revision: Int }
    func place() -> Place? {
        guard let scroll = scrollView, let document = scroll.documentView else { return nil }
        let visible = scroll.contentView.bounds
        let fromBottom = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        return Place(fromBottom: fromBottom, scrolls: userScrolls, revision: scrollRevision)
    }
    /// Puts the reader back the same distance from the newest line after the conversation changed around them:
    /// older lines filled in above, or a reply made a thread taller. Without this the lines on screen slide away
    /// by themselves. It gives way if the user scrolled, or something asked for a place of its own, in the meantime.
    func keep(_ place: Place) {
        for delay in [0.0, 0.06, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pageHold == nil, self.userScrolls == place.scrolls, self.scrollRevision == place.revision,
                      let scroll = self.scrollView, let document = scroll.documentView else { return }
                document.layoutSubtreeIfNeeded()
                let visible = scroll.contentView.bounds
                let wanted = document.isFlipped ? document.bounds.maxY - place.fromBottom - visible.height : document.bounds.minY + place.fromBottom
                let y = min(max(wanted, document.bounds.minY), max(document.bounds.minY, document.bounds.maxY - visible.height))
                guard abs(y - visible.minY) > 0.5 else { return }
                scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
    }
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") }
    static let motion = Animation.easeInOut(duration: 0.24)
    /// Every change the user sets off eases in; nothing snaps unless motion is turned down.
    static func animated(_ change: () -> Void) {
        if reducesMotion { change() } else { withAnimation(motion, change) }
    }
    /// The user's own click on a room. Clicking the room already shown takes the reader back to its newest conversation.
    func choose(_ room: String) {
        guard selected == room else { select(room); return }
        pageHold = nil
        onEnterAgain?()
        scrollToEntry()
    }
    func select(_ room: String) {
        guard selected != room else { return }
        let response = StallTrace.shared.response("roomSelect")
        defer { StallTrace.shared.finish(response) }
        moveDraft { Self.animated { enter(room); onSelect?(room) } }
    }
    func toggle(_ thread: SlackThread) {
        cancelEntry()
        let response = StallTrace.shared.response(open.contains(thread.id) ? "threadClose" : "threadOpen")
        defer { StallTrace.shared.finish(response) }
        pageHold = nil
        Self.animated {
            if open.contains(thread.id) { open.remove(thread.id); if focusThread == thread.id { focusThread = nil } }
            // One thread is open at a time: opening another folds the one that was open.
            else { open = [thread.id]; focusThread = thread.id; onOpen?(thread) }
        }
        // An opened thread is read from its newest reply, the one its pile kept on top.
        let opened = open.contains(thread.id)
        if opened { requestScroll(Self.end(thread.id)) }
        opening = opened && !thread.loaded ? (thread.id, userScrolls) : nil
        onLayout?()
    }
    /// What I send into a thread keeps it unfolded: its answer would otherwise make a short thread long enough to be
    /// piled up, which looks as if the button just pressed had folded it.
    func keepOpen(_ thread: SlackThread) {
        guard !open.contains(thread.id) else { return }
        Self.animated { open = [thread.id]; focusThread = thread.id }
        if !thread.loaded { onOpen?(thread) }
        onLayout?()
    }
    /// A click on a thread that has nothing to unfold still folds whichever other thread was open.
    func foldOthers(than thread: SlackThread) {
        guard !open.subtracting([thread.id]).isEmpty else { return }
        Self.animated { open = open.intersection([thread.id]); if focusThread != thread.id { focusThread = nil } }
        onLayout?()
    }
    /// Clicking away from an opened thread, or folding the window, puts every thread back in its pile.
    func foldAll(animated: Bool = true) {
        cancelEntry()
        pageHold = nil
        findHighlight = nil
        cancelFollowup()
        guard !open.isEmpty || focusThread != nil || replyTo != nil || picked != nil else { return }
        let response = StallTrace.shared.response("threadClose")
        defer { StallTrace.shared.finish(response) }
        // The thread being answered is let go; what was written for it waits there until it is picked again.
        let change = { self.open = []; self.focusThread = nil; self.replyTo = nil; self.picked = nil }
        moveDraft { if animated { Self.animated(change) } else { change() } }
        onLayout?()
    }
    func reply(_ thread: SlackThread) {
        leaveList(for: thread)
        cancelFollowup()
        moveDraft { Self.animated { replyTo = thread.id; picked = thread.id; newPost = false } }
        Self.animated {
            if !open.contains(thread.id) { open = [thread.id]; focusThread = thread.id; onOpen?(thread) }
        }
        focusRevision += 1; onLayout?()
    }

    /// The workspace's own address in Slack; empty until Slack has said what it is.
    @Published var workspace = "" { didSet { if workspace != oldValue { adoptWorkspace() } } }
    /// The copy button pressed last, as `link-` or `copy-` and the thread, while it still says so.
    @Published var copied: String?
    /// A thread whose replies were still being read when its copy was asked for.
    @Published var copyWaiting: String?
    /// Where copies go. UI checks use a board of their own, so the user's clipboard is left alone.
    var clipboard = NSPasteboard.general
    /// The room a thread is in, as it is written: "#SNS담당방", or "@SNS담당" for a direct conversation.
    func place(of thread: SlackThread) -> String {
        // The channel behind ddots is in no list of rooms.
        if thread.room == ddotsHub { return "#" + Ddots.channel }
        return (rooms + stacked + grouped + hiddenRooms).first { $0.id == thread.room }.map { ($0.direct ? "@" : "#") + $0.name } ?? ""
    }
    func link(to thread: SlackThread) -> String? { SlackCopy.link(workspace: workspace, room: thread.room, ts: thread.ts) }
    func copyLink(_ thread: SlackThread) {
        if let link = link(to: thread) { put(link, mark: "link-" + thread.id) }
    }
    /// Puts every line of the thread on the clipboard. Replies not read from Slack yet are asked for first
    /// and the copy is made once they are in, so it is never short of them.
    func copy(_ thread: SlackThread) {
        guard thread.loaded else { copyWaiting = thread.id; onOpen?(thread); return }
        copyWaiting = nil
        put(SlackCopy.text(thread, place: place(of: thread), link: link(to: thread)), mark: "copy-" + thread.id)
    }
    private func finishCopy() {
        if let waiting = copyWaiting, let thread = threads.first(where: { $0.id == waiting }), thread.loaded { copy(thread) }
    }
    private func put(_ text: String, mark: String) {
        clipboard.clearContents(); clipboard.setString(text, forType: .string)
        Self.animated { copied = mark }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.copied == mark { Self.animated { self?.copied = nil } }
        }
    }
    func mention(_ member: SlackMember) {
        draft = SlackMention.toggled(draft, name: member.name); focusRevision += 1
    }
    private var sendResponse: StallTrace.Response?
    func didPublishEcho() {
        StallTrace.shared.finish(sendResponse); sendResponse = nil
    }
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, let room = target?.room ?? postRoom else { return }
        // A character who is not in the channel would never hear the call. The words stay where they were typed.
        if let post = hubPost(text), let missing = absent(from: post) {
            onRefuse?("\(missing.name)\(Ddots.particle(missing.name)) #\(Ddots.channel) 채널에 없어요. 슬랙에서 채널에 초대한 뒤 다시 보내 주세요.")
            return
        }
        // A pressed face is for the one message; the next goes by its own words again.
        sendResponse = StallTrace.shared.response("sendEcho")
        let destination = target
        // Commit a routed new post before the callback clears follow-up state or the draft is emptied.
        if destination == nil, automaticReply != nil {
            newPost = true; picked = nil; replyTo = nil; automaticReply = nil
        }
        if let destination { keepOpen(destination); stopped.remove(destination.id) }
        onSend?(text, room, destination, attachments); sendResponse = nil; draft = ""; attachments = []; ddotsPicked = false
        settleWriting()
        focusRevision += 1
    }
}

extension ChatView {
    func slackPane(strip: CGFloat) -> some View {
        // The tab strip is there before Slack is connected too, so the window takes the same shape either way.
        HStack(spacing: 0) {
            slackRooms(width: strip).frame(width: strip, alignment: .trailing).clipped()
                .overlay(alignment: .trailing) { if strip > 0 { slackSidebarHandle } }
            if slack.connected {
                VStack(spacing: 0) {
                    if !slack.findOpen {
                        slackNoticeBar.chatMeasure("slack-notices", model: model)
                            .onDisappear { model.recordFrame("slack-notices", .zero) }
                    }
                    if slack.findOpen { slackFindResults } else { slackConversation }
                    if let notice = slack.notice {
                        Label(notice, systemImage: "info.circle").font(.system(size: ChatMetrics.auxiliaryFont))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.primary.opacity(0.06))
                    }
                    Divider()
                    slackComposer
                }.attachmentDrop(slack)
            } else {
                VStack(spacing: 10) {
                    Text("슬랙을 연결하면 왼쪽에 방이 나오고, 방의 글을 스레드로 보며 여기서 바로 답글을 달 수 있어요.")
                        .font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).multilineTextAlignment(.center)
                    Button("슬랙 연결…") { slack.onConnect?() }.buttonStyle(.bordered)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Room tabs down the left. Narrow, each is a square of faces over the room's name; wide, a row with the
    /// newest line beside the faces, under a search field. The layout follows the width shown at this moment,
    /// so it changes as the strip is dragged.
    private func slackRooms(width strip: CGFloat) -> some View {
        let list = SlackSidebar.isList(strip)
        // While sliding in or out the strip is narrower than a tab; the tabs keep their size and slide with it.
        let width = max(strip, SlackSidebar.width)
        let row = list ? SlackSidebar.rowHeight : SlackSidebar.tabHeight
        let searching = list && !slack.query.trimmingCharacters(in: .whitespaces).isEmpty
        let rooms = searching ? slack.rooms.filter { $0.name.localizedCaseInsensitiveContains(slack.query.trimmingCharacters(in: .whitespaces)) } : slack.rooms
        let index = rooms.firstIndex { $0.id == slack.chosenTab }
        // Lines part the zones: the first rooms, the two groups, and the direct conversations.
        // While searching the list is one run of matches, without zones.
        let zones = searching ? nil : SlackZones(rooms: rooms.map(\.id), zoneOf: slack.rowZones)
        let y = SlackSidebar.topInset + (list ? SlackSidebar.searchHeight : 0) + CGFloat(index ?? 0) * row + (zones?.above(index ?? 0) ?? 0)
        return GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if list { slackSearchField(width: width) }
                    ForEach(Array(rooms.enumerated()), id: \.element.id) { offset, room in
                        if let zones, zones.breaks(offset) { slackDivider(zone: zones.zone(offset)) }
                        Group {
                            if room.id == Ddots.stack { slackStack(list: list, width: width) }
                            else if let zone = Ddots.groupZone(room.id) { slackGroup(zone, list: list, width: width) }
                            else if list { slackRow(room, width: width) } else { slackTab(room) }
                        }
                            .chatMeasure("room-" + room.id, model: model)
                            .modifier(SlackZoneDrag(slack: slack, room: room.id, zone: zones?.zone(offset)))
                            // The rooms unfolded from the stack or a group are marked down their left side as belonging together.
                            .overlay(alignment: .leading) {
                                if !Ddots.isTab(room.id), (slack.stacked + slack.grouped).contains(where: { $0.id == room.id }) {
                                    Capsule().fill(Color.primary.opacity(dark ? 0.3 : 0.2)).frame(width: 2).padding(.vertical, 6).padding(.leading, 3)
                                        .allowsHitTesting(false)
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                if slack.unkept.contains(room.id == Ddots.room ? slack.ddotsHub ?? room.id : room.id) {
                                    Image(systemName: "lock.fill").font(.system(size: 9)).padding(3).accessibilityLabel("보관하지 않는 방")
                                }
                            }
                            .contextMenu {
                                if !Ddots.isTab(room.id), let retentionRoom = room.id == Ddots.room ? slack.ddotsHub : room.id {
                                    Toggle("이 방은 보관하지 않기", isOn: Binding(get: { slack.unkept.contains(retentionRoom) }, set: { _ in slack.toggleUnkept(retentionRoom) }))
                                    Divider()
                                }
                                if room.id == Ddots.stack {
                                    Button(slack.stackOpen ? "접기" : "펼치기") { slack.toggleStack() }
                                    Divider()
                                    Button("이름 바꾸기…") { slack.onGroupRename?(Ddots.directZone) }
                                    Button("사진 바꾸기…") { slack.onPicture?(Ddots.sectionPicture(Ddots.directZone)) }
                                    if slack.roomPictures[Ddots.sectionPicture(Ddots.directZone)] != nil { Button("사진 지우기") { slack.onClearPicture?(Ddots.sectionPicture(Ddots.directZone)) } }
                                } else if let zone = Ddots.groupZone(room.id) {
                                    Button(slack.groupsOpen.contains(zone) ? "접기" : "펼치기") { slack.toggleGroup(zone) }
                                    Divider()
                                    Button("이름 바꾸기…") { slack.onGroupRename?(zone) }
                                    Button("사진 바꾸기…") { slack.onPicture?(Ddots.sectionPicture(zone)) }
                                    if slack.roomPictures[Ddots.sectionPicture(zone)] != nil { Button("사진 지우기") { slack.onClearPicture?(Ddots.sectionPicture(zone)) } }
                                    Divider()
                                    Button("섹션 삭제…") { slack.onDeleteSection?(zone) }.disabled(slack.sections.count <= 1)
                                } else
                                // ddots keeps its place at the top and cannot be taken off the list; only its alerts can be turned off.
                                if room.id == Ddots.room {
                                    if let hub = slack.ddotsHub {
                                        Button("에이전트 추가…") { slack.onInviteAgents?(hub) }
                                        Divider()
                                    }
                                    Button(slack.muted.contains(room.id) ? "알림 켜기" : "알림 끄기") { slack.toggleMute(room: room.id) }
                                } else {
                                slackPinMenu(room.id)
                                Divider()
                                Button(slack.muted.contains(room.id) ? "알림 켜기" : "알림 끄기") { slack.toggleMute(room: room.id) }
                                Divider()
                                if !room.direct {
                                    Button("이름 바꾸기…") { slack.onRename?(room.id) }
                                    Button("사진 바꾸기…") { slack.onPicture?(room.id) }
                                    if slack.roomPictures[room.id] != nil { Button("사진 지우기") { slack.onClearPicture?(room.id) } }
                                    Divider()
                                    Button("에이전트 추가…") { slack.onInviteAgents?(room.id) }
                                    Button("사람 추가…") { slack.onInvite?(room.id) }
                                }
                                Button("목록에서 빼기") { slack.hide(room.id) }
                                if !room.direct {
                                    Button("보관…") { slack.onArchive?(room.id) }
                                    Button("삭제…") { slack.onDeleteRoom?(room.id) }
                                }
                                }
                            }
                    }
                    if searching { slackHits(width: width) } else { slackAddRoom(list: list, width: width) }
                    slackSidebarBlank
                }
                .padding(.top, SlackSidebar.topInset)
                // Without rooms yet the strip still needs its own width.
                .frame(width: width).frame(minHeight: max(0, geometry.size.height-28), alignment: .top)
                // A light veil keeps the glass showing through; only a hairline marks where the strip ends.
                .background(SlackSidebarVeil(y: y, height: row, hasTab: index != nil).fill(Color.black.opacity(dark ? 0.32 : 0.05), style: FillStyle(eoFill: true)))
                .overlay(SlackSidebarEdge(y: y, height: row, hasTab: index != nil).stroke(Color.primary.opacity(dark ? 0.26 : 0.12), lineWidth: 1).allowsHitTesting(false))
                .animation(shouldReduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: slack.selected)
                .animation(shouldReduceMotion ? nil : SlackModel.motion, value: slack.unread)
                .animation(shouldReduceMotion ? nil : SlackModel.motion, value: list)
                // Rooms trade places smoothly when a newer message or a pin reorders them.
                .animation(shouldReduceMotion ? nil : SlackModel.motion, value: rooms)
                .animation(shouldReduceMotion ? nil : SlackModel.motion, value: slack.stackWaiting)
            }
            // Keep a blank click target available even when the wide list fills the viewport.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                slackSidebarBlank.frame(height: 28)
                    .background(Color.black.opacity(dark ? 0.32 : 0.05))
                    .chatMeasure("sidebar-blank", model: model)
            }
        }.frame(width: width)
    }

    /// The line above a zone. Over a group it takes a dragged room into that group, and lights while one is held over it.
    private func slackDivider(zone: Int) -> some View {
        let lit = slack.dropZone == zone && zone < 4
        return Rectangle().fill(lit ? Color.accentColor : Color.primary.opacity(dark ? 0.26 : 0.14)).frame(height: lit ? 2 : 1)
            .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: SlackSidebar.dividerHeight).contentShape(Rectangle()).accessibilityHidden(true)
            .modifier(SlackZoneDrag(slack: slack, room: nil, zone: zone))
    }

    /// A place from the top to hold a room in, whatever comes in elsewhere.
    @ViewBuilder private func slackPinMenu(_ room: String) -> some View {
        ForEach(0..<SlackRoomOrder.slots, id: \.self) { slot in
            Button((slot == 0 ? "맨 위에 고정" : "\(slot + 1)번째 자리에 고정") + (slack.pins[slot] == room ? " ✓" : "")) { slack.pin(room, slot: slot) }
        }
        if slack.pins.contains(room) { Divider(); Button("고정 해제") { slack.pin(room, slot: nil) } }
    }

    private var slackSidebarBlank: some View {
        // A single click here is too easy to make by accident on the way to a room; the width changes on a double click.
        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .onTapGesture(count: 2) { slack.cycleSidebarWidth() }
            .help("빈 공간 더블클릭: 방 목록 너비 전환")
            .accessibilityElement().accessibilityAddTraits(.isButton)
            .accessibilityLabel("방 목록 너비 전환").accessibilityAction { slack.cycleSidebarWidth() }
    }

    /// Makes a new channel, puts back rooms that were taken off the list, and brings back channels put away in Slack.
    private func slackAddRoom(list: Bool, width: CGFloat) -> some View {
        Menu {
            Button("새 채널 만들기…") { slack.onCreateRoom?() }
            Button("새 섹션 만들기") { slack.addSection() }
            Divider()
            Section("목록에서 뺀 방") {
                if slack.hiddenRooms.isEmpty { Text("뺀 방이 없어요") }
                ForEach(slack.hiddenRooms) { room in
                    Button((room.direct ? "@" : "#") + room.name) { slack.restore(room.id) }
                }
            }
            if !slack.archivedRooms.isEmpty {
                Menu("보관된 방 (\(slack.archivedRooms.count))") {
                    ForEach(slack.archivedRooms) { room in
                        Button("#" + room.name + " 보관 해제") { slack.onUnarchive?(room.id) }
                    }
                }
            }
        } label: {
            if list {
                Label(slack.hiddenRooms.isEmpty ? "방 추가" : "방 추가 (\(slack.hiddenRooms.count))", systemImage: "plus.circle").font(.system(size: 12, weight: .medium))
            } else {
                Image(systemName: "plus.circle").font(.system(size: 17))
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundColor(quiet)
        .help("새 채널·섹션 만들기, 뺀 방·보관된 방 다시 넣기").accessibilityLabel("방 추가").accessibilityIdentifier("slack-add-room")
        .padding(.leading, list ? SlackSidebar.inset + 10 : SlackSidebar.inset)
        .frame(width: width, height: 40, alignment: list ? .leading : .center)
    }

    private func slackSearchField(width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(quiet)
            TextField("검색", text: $slack.query).textFieldStyle(.plain).font(.system(size: 12))
                .accessibilityLabel("방과 글 검색").accessibilityIdentifier("slack-search")
            if !slack.query.isEmpty {
                Button { slack.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundColor(quiet).accessibilityLabel("검색 지우기")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.09)))
        .padding(.leading, SlackSidebar.inset + 6).padding(.trailing, 10)
        .frame(width: width, height: SlackSidebar.searchHeight)
    }

    /// Messages that match, under the rooms that match. Choosing one opens its thread.
    private func slackHits(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(slack.hits.isEmpty ? "찾는 글이 없어요" : "글 \(slack.hits.count)건").font(.system(size: 10, weight: .medium)).foregroundColor(quiet)
                .padding(.leading, SlackSidebar.inset + 10).padding(.top, 10).padding(.bottom, 2)
            ForEach(slack.hits) { hit in
                Button { slack.onReveal?(hit.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(hit.fromUser ? "나" : hit.speaker).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                            Text((slack.rooms + slack.stacked + slack.grouped).first { hit.id.hasPrefix("slack:\($0.id):") }?.name ?? (slack.ddotsHub.map { hit.id.hasPrefix("slack:\($0):") } == true ? Ddots.roomName : ""))
                                .font(.system(size: 10)).foregroundColor(quiet).lineLimit(1)
                        }
                        Text(SlackSearch.highlighted(AttributedString(SlackSearch.snippet(hit.body, query: slack.query)), query: slack.query)).font(.system(size: 11)).foregroundColor(quiet)
                            .lineLimit(2).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, SlackSidebar.inset + 10).padding(.trailing, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("hit-" + hit.id)
            }
        }.frame(width: width, alignment: .leading)
    }

    /// The edge between the strip and the conversation can be dragged, as in Messages.
    private var slackSidebarHandle: some View {
        Color.clear.frame(width: 8).contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { _ in
                    // The window itself moves as it widens, so the pointer is followed on the screen, not in the window.
                    let pointer = NSEvent.mouseLocation.x
                    if slack.sidebarDrag == nil { slack.sidebarDrag = (pointer, slack.sidebarWidth) }
                    if let start = slack.sidebarDrag { slack.dragSidebar(to: start.width + pointer - start.pointer) }
                }
                .onEnded { _ in slack.sidebarDrag = nil; slack.finishSidebarDrag() })
            .accessibilityHidden(true)
    }

    private func slackRoomLabel(_ room: SlackRoom, members: [SlackMember], count: Int) -> String {
        room.name + (count > 0 ? ", 새 글 \(count)개" : "") + (members.isEmpty ? "" : ", " + members.map(\.name).joined(separator: ", "))
    }

    private func slackTab(_ room: SlackRoom) -> some View {
        let chosen = room.id == slack.selected
        let members = slack.members[room.id] ?? []
        let count = slack.unread[room.id] ?? 0
        return Button { slack.choose(room.id) } label: {
            VStack(spacing: 5) {
                slackFaces(members, room: room).overlay(alignment: .topTrailing) { slackBadge(count) }
                    .overlay(alignment: .topLeading) { if slack.pins.contains(room.id) { slackPinMark.offset(x: -8, y: -4) } }
                    .overlay(alignment: .bottomLeading) { if slack.muted.contains(room.id) { slackMuteMark.offset(x: -8, y: 3) } }
                    .overlay(alignment: .topTrailing) { slackNoticeMarks(room.id).offset(x: 7, y: 12) }
                Text(room.name).font(.system(size: 10, weight: chosen ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundColor(chosen || count > 0 ? .primary : quiet)
                    .frame(width: SlackSidebar.width - SlackSidebar.inset - 8)
            }
            .padding(.leading, SlackSidebar.inset)
            .frame(width: SlackSidebar.width, height: SlackSidebar.tabHeight)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).chatMeasure("room-" + room.id, model: model).accessibilityIdentifier("room-" + room.id).accessibilityLabel(slackRoomLabel(room, members: members, count: count))
    }

    /// The wide form of a tab: faces, then the room's name with the time and the newest line under it.
    private func slackRow(_ room: SlackRoom, width: CGFloat) -> some View {
        let chosen = room.id == slack.selected
        let members = slack.members[room.id] ?? []
        let count = slack.unread[room.id] ?? 0
        let newest = slack.latest[room.id]
        return Button { slack.choose(room.id) } label: {
            HStack(spacing: slack.roomNotices[room.id] == nil ? 9 : 14) {
                slackFaces(members, room: room).overlay(alignment: .topTrailing) { slackNoticeMarks(room.id).offset(x: 7, y: -4) }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(room.name).font(.system(size: 13, weight: chosen || count > 0 ? .semibold : .medium)).lineLimit(1)
                        if slack.pins.contains(room.id) { slackPinMark }
                        if slack.muted.contains(room.id) { slackMuteMark }
                        Spacer(minLength: 0)
                        if let newest {
                            Text(Calendar.current.isDateInToday(newest.date) ? Self.time.string(from: newest.date) : Self.day.string(from: newest.date))
                                .font(.system(size: 10)).foregroundColor(quiet).lineLimit(1).fixedSize()
                        }
                    }
                    // The count of unread lines sits at the right under the time, as in a messenger's list.
                    HStack(alignment: .top, spacing: 6) {
                        Text(newest.map { ($0.fromUser ? "나" : $0.speaker) + ": " + slackPreview($0) } ?? " ")
                            .font(.system(size: 11)).foregroundColor(count > 0 ? .primary : quiet).lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 27, alignment: .topLeading).multilineTextAlignment(.leading)
                        VStack(alignment: .trailing, spacing: 3) {
                            if count > 0 {
                                Text(SlackUnread.badge(count)).font(.system(size: 10, weight: .bold)).foregroundColor(.white)
                                    .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                    .background(Capsule().fill(Color.red))
                                    .transition(.scale.combined(with: .opacity))
                                    .accessibilityLabel("안 읽은 글 \(count)개")
                            }
                        }
                    }
                }
            }
            .padding(.leading, SlackSidebar.inset + 10).padding(.trailing, 12)
            .frame(width: width, height: SlackSidebar.rowHeight)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).chatMeasure("room-" + room.id, model: model).accessibilityIdentifier("room-" + room.id).accessibilityLabel(slackRoomLabel(room, members: members, count: count))
    }

    /// The one tab direct conversations are kept behind. It shows their faces; pressing it unfolds them underneath
    /// and pressing again folds them back. Folded, a dot without a number says something new waits in one of them.
    private func slackStack(list: Bool, width: CGFloat) -> some View {
        slackFolded(id: Ddots.stack, title: slack.groupName(Ddots.directZone), rooms: slack.stacked, open: slack.stackOpen, waiting: slack.stackWaiting, direct: true, list: list, width: width) { slack.toggleStack() }
    }

    /// A group's tab: its picture or its rooms' faces, under the name the user gave it. Rooms dragged onto it go into it.
    private func slackGroup(_ zone: Int, list: Bool, width: CGFloat) -> some View {
        let rooms = slack.groups[zone] ?? []
        return slackFolded(id: Ddots.group(zone), title: slack.groupName(zone), rooms: rooms, open: slack.groupsOpen.contains(zone), waiting: slack.groupWaiting(zone), direct: false, list: list, width: width) { slack.toggleGroup(zone) }
            .overlay { if slack.dropZone == zone { RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 2).padding(.leading, SlackSidebar.inset + 2).padding(4).allowsHitTesting(false) } }
    }

    private func slackFolded(id: String, title: String, rooms: [SlackRoom], open: Bool, waiting folded: Bool, direct: Bool, list: Bool, width: CGFloat, toggle: @escaping () -> Void) -> some View {
        let chosen = slack.chosenTab == id
        let members = slack.members[id] ?? []
        let waiting = !open && folded
        let dot = Circle().fill(Color.red).frame(width: 9, height: 9).overlay(Circle().stroke(dark ? Color.black.opacity(0.7) : Color.white, lineWidth: 1.5))
        let arrow = Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundColor(quiet).rotationEffect(.degrees(open ? 180 : 0))
        let pseudo = SlackRoom(id: id, name: title, direct: direct)
        return Button { toggle() } label: {
            Group {
                if list {
                    HStack(spacing: 9) {
                        slackFaces(members, room: pseudo).overlay(alignment: .topTrailing) { if waiting { dot.offset(x: 4, y: -3).transition(.scale.combined(with: .opacity)) } }
                            .overlay(alignment: .topTrailing) { if !open { slackNoticeMarks(id).offset(x: 7, y: 8) } }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(title).font(.system(size: 13, weight: chosen ? .semibold : .medium)).lineLimit(1)
                                Text("\(rooms.count)").font(.system(size: 10)).foregroundColor(quiet)
                                if slack.pins.contains(id) { slackPinMark }
                                Spacer(minLength: 0)
                                arrow
                            }
                            Text(rooms.isEmpty && !direct ? "채널을 끌어다 넣으세요" : rooms.map(\.name).joined(separator: ", ")).font(.system(size: 11)).foregroundColor(quiet).lineLimit(2)
                                .frame(maxWidth: .infinity, minHeight: 27, alignment: .topLeading).multilineTextAlignment(.leading)
                        }
                    }
                    .padding(.leading, SlackSidebar.inset + 10).padding(.trailing, 12)
                    .frame(width: width, height: SlackSidebar.rowHeight)
                } else {
                    VStack(spacing: 5) {
                        slackFaces(members, room: pseudo).overlay(alignment: .topTrailing) { if waiting { dot.offset(x: 4, y: -3).transition(.scale.combined(with: .opacity)) } }
                            .overlay(alignment: .topLeading) { if slack.pins.contains(id) { slackPinMark.offset(x: -8, y: -4) } }
                            .overlay(alignment: .topTrailing) { if !open { slackNoticeMarks(id).offset(x: 7, y: 12) } }
                        HStack(spacing: 3) {
                            Text(title).lineLimit(1).font(.system(size: 10, weight: chosen ? .semibold : .medium)).foregroundColor(chosen || waiting ? .primary : quiet)
                            arrow
                        }
                    }
                    .padding(.leading, SlackSidebar.inset)
                    .frame(width: SlackSidebar.width, height: SlackSidebar.tabHeight)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("room-" + id)
            .accessibilityLabel("\(title) \(rooms.count)개" + (waiting ? ", 새 글 있음" : "") + (open ? ", 펼쳐짐" : ", 접힘"))
            .help(open ? "\(title) 접기" : "\(title) 펼치기")
    }

    /// Questions (yellow) and notifications (blue) waiting in a tab, in the notice bar's own colours, stacked down
    /// the icon's right edge under the red count of unread lines.
    @ViewBuilder private func slackNoticeMarks(_ tab: String) -> some View {
        if let notice = slack.roomNotices[tab] {
            VStack(spacing: 2) {
                if notice.questions > 0 { slackNoticeMark(notice.questions, color: SlackNotice.questionColor, dark: true, label: "답을 기다리는 질문") }
                if notice.alerts > 0 { slackNoticeMark(notice.alerts, color: SlackNotice.alertColor, dark: false, label: "읽지 않은 알림") }
            }.transition(.scale.combined(with: .opacity))
        }
    }
    private func slackNoticeMark(_ count: Int, color: String, dark text: Bool, label: String) -> some View {
        Text(SlackUnread.badge(count)).font(.system(size: 9, weight: .bold)).foregroundColor(text ? .black : .white)
            .frame(minWidth: 15, minHeight: 15).padding(.horizontal, count > 9 ? 3 : 0)
            .background(Capsule().fill(Self.color(hex: color) ?? .accentColor))
            .overlay(Capsule().stroke(dark ? Color.black.opacity(0.7) : Color.white, lineWidth: 1.5))
            .accessibilityLabel("\(label) \(count)개")
    }

    private var slackMuteMark: some View {
        Image(systemName: "bell.slash.fill").font(.system(size: 8)).foregroundColor(quiet).accessibilityLabel("알림 꺼짐")
    }
    private var slackPinMark: some View {
        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundColor(quiet).rotationEffect(.degrees(45)).accessibilityLabel("고정됨")
    }

    /// White on red for every room. A muted room is told apart by its bell mark, not by a duller number.
    @ViewBuilder private func slackBadge(_ count: Int) -> some View {
        if count > 0 {
            Text(SlackUnread.badge(count)).font(.system(size: 9, weight: .bold)).foregroundColor(.white)
                .frame(minWidth: 15, minHeight: 15).padding(.horizontal, count > 9 ? 3 : 0)
                .background(Capsule().fill(Color.red))
                .overlay(Capsule().stroke(dark ? Color.black.opacity(0.7) : Color.white, lineWidth: 1.5))
                .offset(x: 7, y: -5).transition(.scale.combined(with: .opacity))
        }
    }

    /// One face alone, two overlapping, three in a triangle or four in a square, like a group conversation's picture.
    @ViewBuilder private func slackFaces(_ members: [SlackMember], room: SlackRoom) -> some View {
        let box = SlackSidebar.faces, small: CGFloat = 16
        Group {
            if let zone = Ddots.sectionZone(room.id), let picture = slack.roomPictures[Ddots.sectionPicture(zone)] {
                Image(nsImage: picture).resizable().interpolation(.high).scaledToFill().frame(width: box - 4, height: box - 4).clipShape(Self.face(box - 4))
            } else if room.id == Ddots.room, let picture = Ddots.picture {
                Image(nsImage: picture).resizable().interpolation(.high).scaledToFill().frame(width: box - 4, height: box - 4).clipShape(Self.face(box - 4))
            } else if !room.direct, !Ddots.isTab(room.id), let picture = slack.roomPictures[room.id] ?? Ddots.roomPictures[room.id] ?? Ddots.roomPictures[room.name] {
                Image(nsImage: picture).resizable().interpolation(.high).scaledToFill().frame(width: box - 4, height: box - 4).clipShape(Self.face(box - 4))
            } else if let who = Ddots.representative(room, users: Set(members.map(\.user))) {
                avatarBadge(who.name, profile: who.profile, size: box - 4)
            } else if room.direct, members.isEmpty, Ddots.senderPictures[room.name] != nil {
                avatarBadge(room.name, profile: "", size: box - 4)
            } else {
            switch members.count {
            case 0:
                Group {
                    if Ddots.groupZone(room.id) != nil { Image(systemName: "folder").font(.system(size: 15, weight: .medium)) }
                    else { Text(room.direct ? "@" : "#").font(.system(size: 16, weight: .medium)) }
                }.foregroundColor(quiet)
                    .frame(width: box - 4, height: box - 4).background(Self.face(box - 4).fill(Color.primary.opacity(0.1)))
            case 1: avatarBadge(members[0].name, profile: members[0].profile, size: box - 4)
            case 2:
                ZStack {
                    avatarBadge(members[0].name, profile: members[0].profile, size: 21).offset(x: -6, y: -5)
                    avatarBadge(members[1].name, profile: members[1].profile, size: 21)
                        .overlay(Self.face(21).stroke(dark ? Color.black.opacity(0.6) : Color.white, lineWidth: 1.5)).offset(x: 6, y: 5)
                }
            case 3:
                VStack(spacing: 1) {
                    avatarBadge(members[0].name, profile: members[0].profile, size: small)
                    HStack(spacing: 2) { ForEach(members.dropFirst()) { avatarBadge($0.name, profile: $0.profile, size: small) } }
                }
            default:
                let shown = members.count > 4 ? Array(members.prefix(3)) : members
                VStack(spacing: 2) {
                    HStack(spacing: 2) { ForEach(shown.prefix(2)) { avatarBadge($0.name, profile: $0.profile, size: small) } }
                    HStack(spacing: 2) {
                        ForEach(shown.dropFirst(2)) { avatarBadge($0.name, profile: $0.profile, size: small) }
                        if members.count > 4 {
                            Text("+\(members.count - 3)").font(.system(size: 8, weight: .semibold)).foregroundColor(.primary.opacity(0.8))
                                .frame(width: small, height: small).background(Self.face(small).fill(Color.primary.opacity(0.14)))
                        }
                    }
                }
            }
            }
        }.frame(width: box, height: box)
    }

    @ViewBuilder private var slackConversation: some View {
        if NativeListFeature.enabled { nativeConversation }
        else { legacySlackConversation }
    }

    private var nativeConversation: some View {
        let _ = SlackInputSmoke.countConversation()
        let targetID = slack.target?.id
        let vault = slack.vault
        let configuration = [vault.root, vault.bot, vault.unavailable]
        slack.prepareNativeInputs(chat: model, dark: dark, reduceMotion: shouldReduceMotion, vault: configuration)
        var rows: [NativeThreadRow] = []
        func space(_ id: String, _ height: CGFloat) {
            if height > 0 { rows.append(NativeThreadRow(id: id, fixedHeight: height, content: { AnyView(Color.clear.contentShape(Rectangle()).onTapGesture { slack.clickConversationSpace() }) })) }
        }
        // The first line of ddots starts under its pet; other rooms start at the top.
        space("native-top", SlackModel.conversationInset + (Ddots.showsPet && slack.isDdots ? slack.atlas.map(ChatPetMetrics.reserved) ?? 0 : 0))
        if slack.pageHold != nil && slack.pageTopPadding > 0 { space("native-held-top", slack.pageTopPadding) }
        if slack.hasOlder {
            rows.append(NativeThreadRow(id: "native-older", token: String(slack.loading), content: {
                AnyView(Button(slack.loading ? "불러오는 중…" : "이전 글 보기") { slack.onOlder?() }
                    .buttonStyle(.borderless).font(.system(size: ChatMetrics.auxiliaryFont)).disabled(slack.loading)
                    .frame(maxWidth: .infinity))
            }))
            space("native-after-older", 18)
        }
        if slack.threads.isEmpty {
            rows.append(NativeThreadRow(id: "native-empty", token: String(slack.loading), content: {
                AnyView(Text(slack.loading ? "불러오는 중…" : "아직 표시할 글이 없어요.")
                    .font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                    .frame(maxWidth: .infinity).padding(.top, 40))
            }))
            space("native-after-empty", 18)
        }
        for (index, memo) in slack.renderedThreads.enumerated() {
            let thread = memo.thread
            let date = slack.isDdots ? Date(timeIntervalSince1970: thread.latest) : thread.position
            if index == 0 || !Calendar.current.isDate(slack.isDdots ? Date(timeIntervalSince1970: slack.threads[index - 1].latest) : slack.threads[index - 1].position, inSameDayAs: date) {
                let label = Self.day.string(from: date)
                rows.append(NativeThreadRow(id: "native-date:" + thread.id, token: label, content: {
                    AnyView(Text(label).font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).frame(maxWidth: .infinity))
                }))
                space("native-after-date:" + thread.id, 18)
            }
            let inputs = slack.nativeInputs.inputs(memo) { slack.rowInputs(memo, chat: model, dark: dark, reduceMotion: shouldReduceMotion,
                                         target: targetID == thread.id, vaultConfiguration: configuration) }
            let aliases = slack.nativeInputs.aliases(memo)
            let isTarget = targetID == thread.id
            rows.append(NativeThreadRow(id: thread.id, inputs: inputs, token: String(MessageChecklist.shared.revision) + ":" + String(slack.project(thread) != nil) + ":" + String(slack.connected), aliases: aliases, card: { nativeThreadContent(thread, inputs: inputs, target: isTarget) }, content: {
                AnyView(slackThread(thread, target: targetID == thread.id)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.linkPointerEnabled, !SlackResizeSmoke.without("links"))
                    .environment(\.openURL, OpenURLAction { url in model.onOpenLink?(url); return .handled }))
            }))
            space("native-after:" + thread.id, 18)
        }
        rows.append(NativeThreadRow(id: "slack-bottom", fixedHeight: slack.pageHold == nil ? 1 : max(1, slack.viewportHeight), content: { AnyView(Color.clear.contentShape(Rectangle()).onTapGesture { slack.clickConversationSpace() }) }))
        space("native-bottom-inset", SlackModel.conversationInset)
        return NativeThreadList(model: slack, rows: rows, stamp: slack.entryViewportStamp)
            .overlay(alignment: .top) { if Ddots.showsPet && slack.isDdots, let atlas = slack.atlas { ddotsPet(atlas).transition(.opacity) } }
    }

    private var legacySlackConversation: some View {
        let _ = SlackInputSmoke.countConversation()
        let targetID = slack.target?.id
        let entryStamp = slack.entryViewportStamp
        let vault = slack.vault
        let vaultConfiguration = [vault.root, vault.bot, vault.unavailable]
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if slack.pageHold != nil && slack.pageTopPadding > 0 { Color.clear.frame(height: max(0, slack.pageTopPadding - 18)) }
                    if slack.hasOlder {
                        Button(slack.loading ? "불러오는 중…" : "이전 글 보기") { slack.onOlder?() }
                            .buttonStyle(.borderless).font(.system(size: ChatMetrics.auxiliaryFont)).disabled(slack.loading)
                            .frame(maxWidth: .infinity)
                    }
                    if slack.threads.isEmpty {
                        Text(slack.loading ? "불러오는 중…" : "아직 표시할 글이 없어요.").font(.system(size: ChatMetrics.auxiliaryFont))
                            .foregroundColor(quiet).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    ForEach(Array(slack.renderedThreads.enumerated()), id: \.element.thread.id) { index, memo in
                        let thread = memo.thread
                        let date = slack.isDdots ? Date(timeIntervalSince1970: thread.latest) : thread.position
                        if index == 0 || !Calendar.current.isDate(slack.isDdots ? Date(timeIntervalSince1970: slack.threads[index - 1].latest) : slack.threads[index - 1].position, inSameDayAs: date) {
                            Text(Self.day.string(from: date)).font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                                .frame(maxWidth: .infinity)
                        }
                        SlackResizeRow(rows: slack.resizingRows, id: thread.id) {
                            EqualSlackThread(inputs: slack.rowInputs(memo, chat: model, dark: dark, reduceMotion: shouldReduceMotion, target: targetID == thread.id, vaultConfiguration: vaultConfiguration)) {
                                slackThread(thread, target: targetID == thread.id)
                            }.equatable()
                        }
                            .background(GeometryReader { geometry in
                                let rect = geometry.frame(in: .named("slack-list"))
                                Color.clear.onAppear { slack.rowGeometry[thread.id] = rect }
                                    .onChange(of: rect) { slack.rowGeometry[thread.id] = $0 }
                            })
                            .background(SlackRowProbe(model: slack, id: thread.id, entryStamp: entryStamp)).id(thread.id)
                            // Its foot is a place of its own a little under the card, so a thread brought there keeps room beneath it.
                            .padding(.bottom, SlackSidebar.threadMargin / 2)
                            .background(SlackRowProbe(model: slack, id: SlackModel.end(thread.id), entryStamp: entryStamp))
                            .id(SlackModel.end(thread.id)).padding(.bottom, -SlackSidebar.threadMargin / 2)
                    }
                    Color.clear.frame(height: slack.pageHold == nil ? 1 : max(1, slack.viewportHeight))
                        .background(SlackRowProbe(model: slack, id: "slack-bottom", entryStamp: entryStamp)).id("slack-bottom")
                }.padding(.horizontal, ChatMetrics.horizontalInset).padding(.vertical, SlackModel.conversationInset)
                    // The first line of ddots starts under its pet; later lines pass beneath it.
                    .padding(.top, Ddots.showsPet && slack.isDdots ? slack.atlas.map(ChatPetMetrics.reserved) ?? 0 : 0)
                    // Replies that arrive or finish loading ease into place instead of popping in.
                    .animation(shouldReduceMotion ? nil : SlackModel.motion, value: slack.threads.map { $0.replies.count })
                    .animation(shouldReduceMotion ? nil : SlackModel.motion, value: slack.isDdots ? slack.threads.map(\.id) : [])
                    .animation(shouldReduceMotion ? nil : SlackModel.motion, value: slack.typing)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .coordinateSpace(name: "slack-list")
                    // A click on the empty space around an opened thread folds it again.
                    .contentShape(Rectangle()).onTapGesture { slack.clickConversationSpace() }
                    .background(SlackScrollProbe(model: slack, stamp: entryStamp))
                    .transaction { if slack.pageHold != nil || slack.entryViewportPending { $0.animation = nil; $0.disablesAnimations = true } }
            }
            .background(GeometryReader { geometry in
                Color.clear.onAppear { slack.measured(viewport: geometry.size.height) }
                    .onChange(of: geometry.size.height) { slack.measured(viewport: $0) }
            })
            .onAppear {
                let model = slack, scroll = { slackScroll(proxy) }
                model.scroller = { if model.scrolledRevision != model.scrollRevision { scroll() } }
                slackScroll(proxy)
            }
            .onDisappear { slack.scroller = nil }
            .onChange(of: slack.scrollRevision) { _ in if slack.scrolledRevision != slack.scrollRevision { slackScroll(proxy) } }
            .overlay(alignment: .top) { if Ddots.showsPet, slack.isDdots, let atlas = slack.atlas { ddotsPet(atlas).transition(.opacity) } }
        }
    }

    private func slackScroll(_ proxy: ScrollViewProxy) {
        let target = slack.scrollTarget, revision = slack.scrollRevision
        let entry = revision == slack.entryRevision
        // Entry is positioned by the hosting view's layout pass before its content becomes visible.
        if entry { return }
        slack.scrolledRevision = revision
        let arrives = target == "slack-bottom" || SlackModel.reducesMotion
        // The newest line, and an opened thread's newest reply, come to the foot of the view; anything else to its middle.
        let anchor: UnitPoint = target == "slack-bottom" || target.hasPrefix(SlackModel.endMark) ? .bottom : .center
        let scrolls = slack.requestScrolls
        // Later passes land after a newly opened thread has been laid out and the window has grown for it.
        // They stop as soon as the user scrolls by hand. Room entry does not use this animated path.
        for delay in [0, 0.15, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // A newer request, such as another room's, replaces this one; so does scrolling by hand.
                // So does choosing a card, which cancels the room's entry.
                guard slack.pageHold == nil, slack.scrollRevision == revision,
                      slack.userScrolls == scrolls else { return }
                // Arriving at the newest line is instant; travelling to a thread is a glide.
                if arrives { proxy.scrollTo(target, anchor: anchor) }
                else { withAnimation(SlackModel.motion) { proxy.scrollTo(target, anchor: anchor) } }
            }
        }
    }

    /// A button's picture with its word, or the picture alone where there is no room for the word.
    private struct FootLabel: LabelStyle {
        var compact: Bool
        func makeBody(configuration: Configuration) -> some View {
            // The whole label is the button, the gap between its picture and its word included.
            Group { if compact { configuration.icon } else { Label { configuration.title } icon: { configuration.icon } } }.contentShape(Rectangle())
        }
    }

    /// A thread's own buttons. `compact` leaves the words off the ones for taking it elsewhere, for a narrow window.
    @ViewBuilder private func slackFoot(_ thread: SlackThread, target: Bool, compact: Bool) -> some View {
        let expanded = slack.open.contains(thread.id)
        let linkCopied = slack.copied == "link-" + thread.id
        let textCopied = slack.copied == "copy-" + thread.id
        // Both widths are laid out to see which fits, so each is measured under its own name.
        let footKey = compact ? "compact-" : ""
        HStack(spacing: compact ? 12 : 14) {
            // For taking the thread elsewhere: its address in Slack, and every line of it as text.
            if slack.link(to: thread) != nil {
                Button { slack.copyLink(thread) } label: { Label(linkCopied ? "복사됨" : "링크", systemImage: linkCopied ? "checkmark" : "link").labelStyle(FootLabel(compact: compact)) }
                    .foregroundColor(linkCopied ? .accentColor : quiet).help("Slack에서 이 스레드를 여는 링크 복사")
                    .accessibilityLabel("스레드 링크 복사").accessibilityIdentifier("copy-link-" + thread.id).chatMeasure(footKey + "copy-link-" + thread.id, model: model)
            }
            Button { slack.copy(thread) } label: {
                Label(textCopied ? "복사됨" : slack.copyWaiting == thread.id ? "불러오는 중…" : "복사", systemImage: textCopied ? "checkmark" : "doc.on.doc").labelStyle(FootLabel(compact: compact))
            }.foregroundColor(textCopied ? .accentColor : quiet).help("이 스레드의 첫 글과 답글을 모두 복사")
                .accessibilityLabel("스레드 전체 복사").accessibilityIdentifier("copy-" + thread.id).chatMeasure(footKey + "copy-" + thread.id, model: model)
            // Only a character can carry its thread on, so the button is there once one has spoken in it.
            if !thread.ts.isEmpty, thread.messages.contains(where: { !$0.fromUser && !$0.profile.isEmpty }) {
                let asked = slack.branching == thread.id, long = thread.replyCount >= SlackNotice.longThread
                Button { slack.branch(thread) } label: {
                    Label("분기", systemImage: asked ? "checkmark" : "arrow.triangle.branch").labelStyle(FootLabel(compact: compact))
                }.disabled(asked).foregroundColor(asked ? .accentColor : long ? .orange : quiet)
                    .help(long ? "답글이 \(thread.replyCount)개예요. 지금까지의 대화를 그대로 가진 새 스레드에서 이어가요." : "지금까지의 대화를 그대로 가진 새 스레드를 열어요.")
                    .accessibilityLabel("새 스레드로 이어가기").accessibilityIdentifier("branch-" + thread.id)
            }
            Button { slack.reply(thread) } label: {
                Label(target ? "답글 쓰는 중" : "답글", systemImage: "arrowshape.turn.up.left").labelStyle(FootLabel(compact: false))
            }.disabled(target || thread.ts.isEmpty).foregroundColor(target ? .accentColor : quiet)
                .accessibilityIdentifier("reply-" + thread.id).chatMeasure(footKey + "reply-" + thread.id, model: model)
            // Deleting is offered on the thread that is picked, and takes a second press.
            if let going = slack.removing[thread.id] {
                Label(going.total > 0 ? "삭제 중 \(going.done)/\(going.total)" : "삭제 중…", systemImage: "trash").foregroundColor(.red)
                    .accessibilityIdentifier("deleting-" + thread.id)
            } else if !thread.ts.isEmpty, (thread.replyCount == 0 ? thread.root.fromUser : slack.picked == thread.id) {
                let sure = slack.confirmingDelete == thread.id
                Button { slack.delete(thread) } label: {
                    Label(sure ? "정말 삭제" : "삭제", systemImage: "trash").labelStyle(FootLabel(compact: compact && !sure))
                }.foregroundColor(sure ? .red : quiet)
                    .help(thread.replyCount == 0 ? (sure ? "한 번 더 누르면 이 글을 삭제해요. 되돌릴 수 없어요." : "내 글을 슬랙에서도 삭제") : (sure ? "한 번 더 누르면 슬랙에서 이 스레드의 글과 답글을 모두 지워요. 되돌릴 수 없어요." : "이 스레드를 슬랙에서도 삭제"))
                    .accessibilityLabel(sure ? "스레드 삭제 확인" : "스레드 삭제").accessibilityIdentifier("delete-" + thread.id)
            }
            if expanded && thread.loaded && thread.replies.count > SlackStack.inlineLimit {
                Button { slack.toggle(thread) } label: { Label("접기", systemImage: "chevron.up").labelStyle(FootLabel(compact: false)) }.foregroundColor(quiet)
                    .accessibilityIdentifier("fold-" + thread.id).chatMeasure(footKey + "fold-" + thread.id, model: model)
            }
        }.buttonStyle(.plain).font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium)).lineLimit(1).fixedSize().threadControls()
    }

    @ViewBuilder private func slackThread(_ original: SlackThread, target: Bool) -> some View {
        let thread = slack.vault.hidingPageCommands(original)
        let displayed = SlackNotice.displayed(thread, confirmed: slack.confirmed)
        let _ = SlackInputSmoke.countThread()
        let expanded = slack.open.contains(thread.id)
        let shown = SlackStack.visible(displayed, expanded: expanded)
        // A character whose "생각 중" line is already in the thread is not shown writing twice.
        let thinkers = Set(thread.messages.filter { !$0.fromUser && SlackText.isThinking($0.body) }.map(\.profile))
        let writing = (slack.typing[thread.id] ?? []).filter { !thinkers.contains($0.profile) }
        let answered = thread.replyCount > 0 || !writing.isEmpty
        // What the thread waits on colours its bar: yellow while a question is open, green once it was approved.
        // Otherwise a post that carries a status colour lends it. The card's outline is the character's own colour.
        let notice = slack.noticeMemo.assessment(thread, confirmed: slack.confirmed)
        let state = notice.state
        let tone = state.flatMap { Self.color(hex: $0.color) } ?? displayed.root.marks.lazy.compactMap { Self.color(hex: $0.color) }.first
        let edge = SlackOwner.color(SlackOwner.profile(thread, members: slack.ddotsMembers))
        let carded = answered || tone != nil
        let foldable = thread.replyCount > SlackStack.inlineLimit || !thread.loaded
        let pending = notice.pending?.id
        let vaultLayout = slack.vault.presentation(thread, active: slack.vaultSelections(thread), visible: Set([displayed.root.id] + shown.replies.map(\.id)), pending: pending)
        let mine = thread.root.fromUser
        let picked = slack.picked == thread.id
        // Text stays selectable when folded; a text click opens it without taking its drag gesture.
        let selectable = true
        let textClick: (() -> Void)? = foldable && !expanded ? {
            if !slack.open.contains(thread.id), let live = slack.threads.first(where: { $0.id == thread.id }) { slack.pick(live, foldable: true) }
        } : nil
        VStack(alignment: .leading, spacing: 6) {
            // In ddots every character is in the room, so my own first line says who it went to.
            if slack.isDdots, let project = slack.project(thread) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.title).font(.system(size: ChatMetrics.auxiliaryFont, weight: .semibold))
                    Text(project.statusText).font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                    DisclosureGroup("공동 기록") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("목표 · " + project.goal)
                            ForEach(Array((project.facts ?? []).enumerated()), id: \.offset) { _, fact in Text("공통 사실 · " + fact.text) }
                            ForEach(Array((project.decisions ?? []).enumerated()), id: \.offset) { _, decision in Text("확정 · " + decision.text) }
                            ForEach(project.tasks) { task in
                                let owner = slack.ddotsMembers.first { $0.profile == task.profile }?.name ?? "담당자"
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title + " · " + owner + " · " + task.statusText).fontWeight(.medium)
                                    if !task.summary.isEmpty { Text(task.summary) }
                                    if let next = task.nextStep, !next.isEmpty { Text("다음 · " + next) }
                                    ForEach(task.references ?? [], id: \.self) { reference in
                                        if let url = URL(string: reference), ["https", "http"].contains(url.scheme) { Link("원본 보기", destination: url) }
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.font(.system(size: ChatMetrics.auxiliaryFont))
                    ForEach((project.approvals ?? []).filter(\.pending)) { approval in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("승인 대기 · " + (slack.ddotsMembers.first { $0.profile == approval.profile }?.name ?? "담당자"))
                            Text(approval.previewText ?? "스레드의 변경안을 확인해 주세요.").textSelection(.enabled)
                            HStack {
                                Button("이 변경 승인") { slack.projectChoice(thread, approval: approval, approve: true) }
                                Button("거부") { slack.projectChoice(thread, approval: approval, approve: false) }
                            }.disabled(!slack.connected)
                        }.font(.system(size: ChatMetrics.auxiliaryFont)).padding(6)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if mine, slack.isDdots, let who = slack.ddotsOwner(thread) {
                HStack(spacing: 4) {
                    avatarBadge(who.name, profile: who.profile, size: 14)
                    Text("처리: " + who.name).font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium)).foregroundColor(quiet)
                }.frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 4).padding(.bottom, -2)
            }
            if !vaultLayout.hidden.contains(displayed.root.id) { slackLine(displayed.root, selectable: selectable, textClick: textClick).id(thread.root.id == thread.id ? "slack-root:" + thread.id : thread.root.id) }
            if let state, displayed.root.marks.isEmpty {
                markNote(state, message: thread.root).font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium)).padding(.leading, mine ? 4 : ChatMetrics.avatar + 9)
                    .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading).transition(.opacity)
            }
            if pending == thread.root.id { slackApproval(thread) }
            if let selection = vaultLayout.anchors[displayed.root.id] {
                vaultButtons(thread, selection: selection)
            }
            driveButtons(thread, message: displayed.root)
            if answered {
                VStack(alignment: .leading, spacing: 6) {
                    if shown.hidden > 0 { slackStack(thread, hidden: shown.hidden, expanded: expanded).transition(.opacity) }
                    ForEach(shown.replies) { reply in
                        if !vaultLayout.hidden.contains(reply.id) { slackLine(reply, selectable: selectable, textClick: textClick).id(reply.id).transition(.opacity) }
                        if pending == reply.id { slackApproval(thread).transition(.opacity) }
                        if let selection = vaultLayout.anchors[reply.id] {
                            vaultButtons(thread, selection: selection)
                        }
                        driveButtons(thread, message: reply)
                    }
                    ForEach(writing) { typingBubble($0).transition(.opacity) }
                    if let control = AgentStop.control(working: AgentStop.working(thread, typing: writing), stopped: slack.stopped.contains(thread.id)) {
                        stopControl(original, control: control).transition(.opacity)
                    }
                }
                // Under a character's post the answers step in behind a rail that starts where its words start.
                // Under my own first line there is no picture to step in from, so the answers start at the left edge.
                .padding(.leading, mine ? 0 : 11)
                .overlay(alignment: .leading) {
                    Capsule().fill(target ? Color.accentColor : (tone?.opacity(0.75) ?? Color.primary.opacity(0.2))).frame(width: 2).opacity(mine ? 0 : 1)
                }
                .padding(.leading, mine ? 0 : SlackSidebar.threadIndent)
            }
            // Every button with its word where there is room, else the ones for taking the thread elsewhere as pictures alone.
            Group {
                if SlackResizeSmoke.without("fitting") { slackFoot(thread, target: target, compact: false) }
                else { ViewThatFits(in: .horizontal) { slackFoot(thread, target: target, compact: false); slackFoot(thread, target: target, compact: true) } }
            }
                // The thread's own buttons sit at its right end, clear of the words.
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        }
        // A thread with replies sits on its own card, so its pile of replies plainly belongs to it;
        // opening the thread draws the card's outline.
        // Every thread is a card once it is picked, so a plain post can be chosen as a reply target too.
        .padding(carded || picked ? 8 : 0)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(picked ? 0.1 : !carded ? 0 : expanded ? 0.08 : 0.045)))
        // The outline is always there, firms up when the thread is opened, and is drawn boldest on the thread that is picked.
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(slack.flash == thread.id ? Color.accentColor : picked ? (edge ?? tone ?? Color.accentColor)
                                                           : (edge ?? tone ?? Color.primary).opacity(!carded ? 0 : edge != nil ? (expanded ? 0.95 : 0.6) : tone != nil ? (expanded ? 1 : 0.6) : (expanded ? 0.6 : 0.24)),
                                                           lineWidth: slack.flash == thread.id ? 2.5 : picked ? 2.2 : expanded || edge != nil ? 1.5 : 1))
        .overlay(alignment: .topTrailing) {
            if let unread = slack.bells[thread.id] {
                // Yellow while the notification or question is unread; pressing it marks the thread read, and again unread.
                Button { slack.onBell?(thread) } label: {
                    Image(systemName: unread ? "bell.fill" : "bell").font(.system(size: 12, weight: .semibold))
                        .foregroundColor(unread ? Color(red: 0.98, green: 0.78, blue: 0.18) : quiet.opacity(0.6))
                        .padding(7).contentShape(Rectangle())
                }.buttonStyle(.plain).help(unread ? "읽음으로 표시" : "읽지 않음으로 되돌리기")
                    .accessibilityLabel(unread ? "읽지 않은 알림, 눌러서 읽음으로 표시" : "읽은 알림, 눌러서 되돌리기")
                    .accessibilityIdentifier("bell-" + thread.id).transition(.opacity)
            }
        }
        .background(GeometryReader { geometry in
            Color.clear.onAppear { if expanded { slack.measured(thread: thread.id, height: geometry.size.height) } }
                .onChange(of: geometry.size.height) { if slack.open.contains(thread.id) { slack.measured(thread: thread.id, height: $0) } }
                .onChange(of: expanded) { if $0 { slack.measured(thread: thread.id, height: geometry.size.height) } }
        })
        // Only the card's empty space folds or opens it: every row of controls keeps the clicks that land on it (`threadControls`).
        .contentShape(Rectangle()).onTapGesture { slack.clickCard(thread, foldable: foldable) }

    }

    /// Under a character at work: stop its run here. Once stopped: ask it to put back what it already changed.
    func stopControl(_ thread: SlackThread, control: AgentStop.Control) -> some View {
        HStack(spacing: 6) {
            switch control {
            case .stop:
                Button { slack.stop(thread) } label: { Label("중지", systemImage: "stop.fill") }
                    .help("이 스레드에서 하던 작업을 멈춰요")
                    .accessibilityIdentifier("stop-" + thread.id)
            case .undo:
                Text("중지를 요청했어요").foregroundColor(quiet)
                Button("되돌리기") { slack.askUndo(thread) }
                    .help("이미 바꾼 것을 먼저 목록으로 보여 달라고 하고, 확인한 뒤 원래대로 되돌리게 해요")
                    .accessibilityIdentifier("undo-" + thread.id)
            }
        }.buttonStyle(.bordered).controlSize(.small).font(.system(size: ChatMetrics.auxiliaryFont))
            .disabled(!slack.connected).padding(.leading, 4)
    }

    /// A line of the conversation. Hermes's "생각 중..." placeholder is drawn as the writing dots the iMessage side uses.
    func lineInputs(_ message: ChatMessage, selectable: Bool, opensThread: Bool, vaultConfiguration: [String?]? = nil) -> SlackLineInputs {
        let files = Set(message.files.map(\.id))
        let config = vaultConfiguration ?? { let config = slack.vault; return [config.root, config.bot, config.unavailable] }()
        return SlackLineInputs(message: message, selectable: selectable, opensThread: opensThread,
            dark: dark, reduceMotion: shouldReduceMotion, expanded: model.expandedReplies.contains(message.id),
            highlighted: model.highlightedID == message.id, flashed: slack.flash == message.id,
            findTerm: slack.findTerm(message), chatSearch: model.rowSearchInputs, events: model.calendarEvents,
            avatars: model.avatars, palettes: dark ? model.darkPalettes : model.lightPalettes, bubbleWidth: model.bubbleWidth,
            vaultConfiguration: config, pendingPage: slack.shrimpPendingPages[message.id],
            thumbnails: slack.thumbs.filter { files.contains($0.key) }.mapValues(ObjectIdentifier.init),
            failedFiles: slack.failedThumbs.intersection(files), busyFiles: slack.busyFiles.intersection(files))
    }
    func slackLine(_ message: ChatMessage, selectable: Bool, textClick: (() -> Void)?) -> some View {
        let inputs = lineInputs(message, selectable: selectable, opensThread: textClick != nil)
        return EqualSlackLine(inputs: inputs) { slackLineContent(message, selectable: selectable, textClick: textClick) }.equatable()
    }
    @ViewBuilder private func slackLineContent(_ message: ChatMessage, selectable: Bool, textClick: (() -> Void)?) -> some View {
        let _ = SlackInputSmoke.countLine()
        Group {
            if !message.fromUser && SlackText.isThinking(message.body) {
                typingBubble(TypingIndicator(id: message.id, speaker: message.speaker, profile: message.profile))
            } else if message.fromUser {
                // My own lines stay as bubbles on the right, so the two sides are told apart at a glance.
                row(ChatRow(message: message, showsSpeaker: false, showsDay: false), selectable: selectable, textClick: textClick)
            } else {
                slackPost(message, selectable: selectable, textClick: textClick)
            }
        }.opacity(slack.vault.fallback(message) != nil ? 0.35 : 1).background {
            if CommandLine.arguments.contains("--ui-smoke"), (CommandLine.arguments.contains("--ui-smoke-room") || CommandLine.arguments.contains("--ui-smoke-selection")) {
                SlackRowProbe(model: slack, id: "message:" + message.id)
            }
        }.background(RoundedRectangle(cornerRadius: 8).fill(slack.flash == message.id ? Color.accentColor.opacity(0.18) : Color.clear))
    }

    /// Under an approval request: answer it, write an opinion, or confirm it without sending.
    func slackApproval(_ thread: SlackThread) -> some View {
        Group {
            if SlackResizeSmoke.without("fitting") { slackApproval(thread, compact: false) }
            else {
                ViewThatFits(in: .horizontal) {
                    slackApproval(thread, compact: false)
                    slackApproval(thread, compact: true)
                }
            }
        }.threadControls().padding(.leading, ChatMetrics.avatar + 9).padding(.top, 2)
            .onDisappear {
                if CommandLine.arguments.contains("--ui-smoke-chat") {
                    model.recordFrame("approval-" + thread.id, .zero)
                    model.recordFrame("confirm-" + thread.id, .zero)
                }
            }
    }
    func vaultButtons(_ thread: SlackThread, selection: ShrimpVault.Selection) -> some View {
        let actions = selection.actions
        return ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 4) {
                ForEach(actions, id: \.self) { action in
                    let disabled = (action == "파일오픈" && slack.vault.unavailable != nil) || slack.vaultAlreadySent(selection, action)
                    Button { slack.vaultAction(action, thread: thread, selection: selection) } label: {
                        ShrimpVaultIcons.label(action, disabled: disabled)
                    }
                    .disabled(disabled)
                    .accessibilityLabel(ShrimpVaultIcons.name(action))
                    .accessibilityIdentifier("vault-" + action + "-" + selection.message)
                    .help(action == "파일오픈" ? slack.vault.unavailable ?? action : ShrimpVaultIcons.name(action))
                    .chatMeasure("vault-" + action + "-" + selection.message, model: model)
                }
                if let reason = slack.vault.unavailable {
                    Text(reason).font(.system(size: 11)).foregroundColor(.secondary).fixedSize()
                    Button("폴더 지정…") { slack.chooseVaultFolder() }
                        .buttonStyle(.bordered).fixedSize().accessibilityIdentifier("vault-folder-" + selection.message)
                }
            }.fixedSize(horizontal: true, vertical: false).padding(.bottom, 3)
        }.buttonStyle(.plain).frame(height: 32).threadControls().padding(.top, 4).padding(.leading, ChatMetrics.avatar + 9)
    }
    /// Under a message that links to Synology files: the same buttons 새우튀김's file has, and for several files a list at the right.
    @ViewBuilder func driveButtons(_ thread: SlackThread, message: ChatMessage) -> some View {
        let items = slack.driveItems(message)
        if !items.isEmpty {
            let chosen = slack.driveSelection(message, items: items)
            VStack(alignment: .leading, spacing: 8) {
                if items.count > 1 {
                    Button("파일 \(items.count)건 — 오른쪽 창에서 보기") {
                        slack.shrimpListThread = nil; slack.shrimpListPage = 1
                        slack.driveListMessage = message.id; web.showShrimpList()
                    }.buttonStyle(.borderless).fixedSize().accessibilityIdentifier("drive-list-" + message.id)
                }
                if let chosen {
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 4) {
                            ForEach(SynologyLink.actions, id: \.name) { action in
                                let disabled = slack.driveAlreadySent(action.name, item: chosen, message: message, thread: thread)
                                Button {
                                    if action.name == "열기" { model.onOpenLink?(chosen.url); slack.onRead?(thread) }
                                    else {
                                        let listed = slack.driveListMessage == message.id
                                        slack.driveAction(action.name, item: chosen, message: message, thread: thread)
                                        if listed, slack.driveListMessage == nil { web.close() }
                                    }
                                } label: { ShrimpVaultIcons.label(action.icon, disabled: disabled) }
                                .disabled(disabled)
                                .accessibilityLabel(action.name)
                                .accessibilityIdentifier("drive-" + action.name + "-" + message.id)
                                .chatMeasure("drive-" + action.name + "-" + message.id, model: model)
                                .help(action.name)
                            }
                            // With several files, the row says which one its buttons act on.
                            if items.count > 1 { Text(chosen.name).font(.system(size: 11)).foregroundColor(.secondary).fixedSize().padding(.leading, 4) }
                        }.fixedSize(horizontal: true, vertical: false).padding(.bottom, 3)
                    }.buttonStyle(.plain).frame(height: 32)
                }
            }.threadControls().padding(.top, 4).padding(.leading, ChatMetrics.avatar + 9)
        }
    }
    private func slackApproval(_ thread: SlackThread, compact: Bool) -> some View {
        let learning = SlackNotice.isLearningReport(thread), mail = !learning && SlackNotice.isMailDraft(thread)
        let rules = DdotsConfig.shared.conversation
        let approve = learning ? rules.text("learningApprove") : mail ? rules.text("mailApproveLabel") : SlackNotice.approveText
        let deny = learning ? rules.text("learningDeny") : rules.text("denyLabel")
        let revise = rules.text(learning ? "learningReviseLabel" : mail ? "mailReviseLabel" : "reviseLabel")
        let labels = SlackNotice.replyLabels(thread)
        let checklist = SlackNotice.checklistLabels(thread)
        return HStack(spacing: 8) {
            if !checklist.isEmpty {
                HermesReplyChecklist(labels: checklist, initialSelection: Set(SlackNotice.pendingApproval(thread)?.hermesChecklistSelected ?? []),
                                     canSkip: SlackNotice.checklistSkipAnswer(thread) != nil,
                                     skip: { slack.skipHermesChecklist(thread) }) { slack.answerHermesChecklist(thread, selected: $0) }
                    .id(SlackNotice.pendingApproval(thread)?.id ?? thread.id)
            } else if !labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                            Button(label) { slack.answerHermes(thread, label: label) }
                                .accessibilityIdentifier("hermes-reply-" + thread.id + "-" + String(index))
                                .accessibilityLabel(label)
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .background(Capsule().fill(Color.primary.opacity(0.12)))
                        }
                    }
                }.frame(width: 320)
            } else {
                Button { slack.answer(thread, approve: true) } label: {
                    Label(approve, systemImage: "circle").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 5).background(Capsule().fill(Color.green))
                }.accessibilityIdentifier("approve-" + thread.id).accessibilityLabel(approve).help(approve)
                    .chatMeasure("approve-" + thread.id, model: model)
                Button { slack.answer(thread, approve: false) } label: {
                    Label(deny, systemImage: "xmark").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.12))).overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                }.accessibilityIdentifier("deny-" + thread.id).accessibilityLabel(deny).help(deny)
                // An opinion is a reply in the user's own words, so this aims the draft at the thread and waits for it to be typed.
                Button { slack.revise(thread) } label: {
                    Label(revise, systemImage: "text.bubble").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.12))).overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                }.accessibilityIdentifier("revise-" + thread.id).accessibilityLabel(revise).help(revise)
                Button { slack.confirm(thread) } label: {
                    Label("확인", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.12))).overlay(Capsule().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                }.accessibilityIdentifier("confirm-" + thread.id)
                    .chatMeasure("confirm-" + thread.id, model: model)
                    .accessibilityLabel("확인, 메시지를 보내지 않고 넘어가기")
                    .help("메시지를 보내지 않고 넘어가기")
            }
        }.buttonStyle(.plain).labelStyle(FootLabel(compact: compact)).fixedSize(horizontal: true, vertical: false)
            .chatMeasure("approval-" + thread.id, model: model)
    }

    /// The folded replies: who answered, how many, and two cards peeking out underneath like a pile.
    private func slackStack(_ thread: SlackThread, hidden: Int, expanded: Bool) -> some View {
        var seen = Set<String>()
        let faces = thread.replies.dropLast().filter { !$0.fromUser && seen.insert($0.profile + "/" + $0.speaker).inserted }.prefix(3)
        return Button { slack.toggle(thread) } label: {
            HStack(spacing: 7) {
                if !faces.isEmpty {
                    HStack(spacing: -5) { ForEach(Array(faces)) { avatarBadge($0.speaker, profile: $0.profile, size: 16) } }
                }
                Text(thread.loaded ? "이전 답글 \(hidden)개" : (expanded ? "답글 불러오는 중…" : "답글 \(hidden)개"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(quiet)
            }.font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium))
                .padding(.leading, faces.isEmpty ? 12 : 8).padding(.trailing, 11).padding(.vertical, 7)
                .background(ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)).padding(.horizontal, 12).offset(y: 8)
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.08)).padding(.horizontal, 6).offset(y: 4)
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.13))
                    RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1)
                })
                .padding(.bottom, 9)
        }.buttonStyle(.plain).accessibilityIdentifier("stack-" + thread.id).accessibilityLabel("답글 \(hidden)개 펼치기")
    }

    private var slackComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // What is typed next is either an answer in a thread or a new post in the room.
                HStack(spacing: 0) {
                    slackModeButton("답글", on: slack.target != nil, enabled: slack.replyCandidate != nil) { slack.writeReply() }
                    slackModeButton(slack.isDdots ? "새 대화" : "새 글", on: slack.target == nil, enabled: true) { slack.writeNewPost() }
                }
                .padding(2).background(Capsule().fill(Color.primary.opacity(0.1)))
                if slack.isDdots {
                    // One line holds both: the faces of who the message goes to sit beside the switch,
                    // and the lit face and the draft's own words say which thread is being answered.
                    Spacer(minLength: 4)
                    ddotsFaces
                } else {
                    if let thread = slack.target { slackReplyAim(thread) }
                    Spacer(minLength: 4)
                    // The faces sit where they do in ddots. Here pressing one is a Slack mention.
                    // With one other member there is nobody to single out, so they are left out.
                    if let members = slack.selected.flatMap({ slack.members[$0] }), members.count >= SlackMention.minimumMembers {
                        ViewThatFits(in: .horizontal) {
                            mentionFaces(members)
                            ScrollView(.horizontal, showsIndicators: false) { mentionFaces(members) }
                        }.layoutPriority(1).transition(.opacity)
                    }
                }
            }
            if !slack.failedHere.isEmpty || !slack.failedElsewhere.isEmpty { slackFailures }
            if !slack.attachments.isEmpty { slackAttachments }
            SlackComposerInput(composer: slack.composer, slack: slack, model: model,
                               focused: $slackFocused, prompt: slackPrompt, room: slackSendRoom,
                               hasAttachments: !slack.attachments.isEmpty, quiet: quiet)
        }.padding(10)
    }
    /// Messages that did not go. Each waits in the room it was sent from until it is brought back into the draft or let go.
    private var slackFailures: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(slack.failedHere) { failure in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
                    Text(slackFailureLabel(failure)).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Button("되살리기") { slack.restoreFailure(failure.id) }.buttonStyle(.borderless)
                        .help("보내지 못한 글을 원래 보내려던 곳의 입력창으로 되돌려요. 다시 보내기 전에는 보내지 않아요.")
                        .accessibilityIdentifier("slack-failed-restore-" + failure.id.uuidString)
                    Button("지우기") { slack.discardFailure(failure.id) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("slack-failed-discard-" + failure.id.uuidString)
                }.help(failure.reason)
            }
            if let first = slack.failedElsewhere.first {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundColor(.red)
                    Text("다른 방에서 보내지 못한 글 \(slack.failedElsewhere.count)개").lineLimit(1)
                    Spacer(minLength: 4)
                    Button("보러 가기") { slack.showFailure(first) }.buttonStyle(.borderless)
                        .accessibilityIdentifier("slack-failed-elsewhere")
                }
            }
        }.font(.system(size: ChatMetrics.auxiliaryFont)).padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.08)))
    }
    private func slackFailureLabel(_ failure: SlackFailedSend) -> String {
        let place: String
        if let id = failure.thread, let thread = slack.threads.first(where: { $0.id == id }) {
            place = "답글 · " + String(MessageFormat.plain(thread.root.body).prefix(16))
        } else { place = failure.thread == nil ? (slack.isDdots ? "새 대화" : "새 글") : "답글" }
        let words = failure.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = words.isEmpty ? "파일 \(failure.files.count)개" : String(words.prefix(40)) + (failure.files.isEmpty ? "" : " · 파일 \(failure.files.count)개")
        return "보내지 못함 · " + place + " · " + what
    }
    private func mentionFaces(_ members: [SlackMember]) -> some View {
        HStack(spacing: 2) {
            ForEach(members) { member in
                Button { slack.mention(member) } label: {
                    avatarBadge(member.name, profile: member.profile, size: ChatMetrics.callerAvatar).padding(4)
                }.buttonStyle(.plain).help("@" + member.name).accessibilityLabel(member.name + " 멘션")
                    .accessibilityIdentifier("mention-" + member.id)
            }
        }
    }
    private func slackModeButton(_ title: String, on: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: ChatMetrics.auxiliaryFont, weight: on ? .semibold : .regular))
                .foregroundColor(on ? .white : (enabled ? .primary : quiet.opacity(0.6)))
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(Capsule().fill(on ? Color.accentColor : Color.clear))
        }.buttonStyle(.plain).disabled(!enabled || on).accessibilityLabel(title + (on ? ", 선택됨" : ""))
            .accessibilityIdentifier("slack-mode-" + title)
    }
    private var slackSendRoom: String? { slack.target?.room ?? slack.postRoom }
    /// What the empty draft says: where the next message goes.
    private var slackPrompt: String {
        if slack.isDdots {
            if let thread = slack.target {
                return (slack.project(thread)?.title ?? String(MessageFormat.plain(thread.root.body).prefix(36))) + " · 이어서 말하기"
            }
            if !slack.ddotsPicked { return "workspace에 새 요청" }
            guard let who = slack.recipient else { return slack.target == nil ? Ddots.roomName : "스레드에 답글" }
            return slack.target == nil ? who.name + "에게 새 글" : who.name + " 스레드에 답글"
        }
        return slack.target == nil ? "\(slack.room.map { ($0.direct ? "@" : "#") + $0.name } ?? "Slack")에 새 글" : "스레드에 답글"
    }
    private func slackReplyAim(_ thread: SlackThread) -> some View {
        Text((thread.root.fromUser ? "내 글" : thread.root.speaker) + " · " + slackPreview(thread.root)).lineLimit(1)
            .font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).transition(.opacity)
    }
}

// MARK: ddots
extension ChatView {
    /// The pet at the top of ddots with the name of whoever the next message reaches, or of whoever is writing an answer.
    /// Clicks pass through it to the conversation underneath.
    func ddotsPet(_ atlas: SpriteAtlas) -> some View {
        var seen = Set<String>()
        let writers = slack.threads.flatMap { thread in
            (slack.typing[thread.id] ?? []).map(\.speaker) + thread.messages.filter { !$0.fromUser && SlackText.isThinking($0.body) }.map(\.speaker)
        }.filter { !$0.isEmpty && seen.insert($0).inserted }
        let label = writers.isEmpty ? (slack.recipient?.name ?? Ddots.roomName) : writers.joined(separator: ", ") + " 작성 중…"
        // The cell is mostly empty around the pet, so it is pulled up to the top and the name is pulled up under its feet.
        let body = ChatPetMetrics.body(atlas)
        return VStack(spacing: 0) {
            ChatPet(atlas: atlas, writing: !writers.isEmpty, hop: slack.petHop, wave: slack.petWave, reduced: shouldReduceMotion,
                    approval: slack.needsPetApproval)
                .frame(width: ChatPetMetrics.size.width, height: ChatPetMetrics.size.height)
                .padding(.top, -body.minY).padding(.bottom, body.maxY - ChatPetMetrics.size.height - 2)
            Text(label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                .padding(.horizontal, 11).frame(height: ChatPetMetrics.nameHeight)
                .background(Capsule().fill(dark ? Color(white: 0.11).opacity(0.94) : Color.white.opacity(0.96)))
                .overlay(Capsule().stroke(Color.primary.opacity(dark ? 0.22 : 0.12), lineWidth: 1))
                .shadow(color: .black.opacity(dark ? 0.45 : 0.14), radius: 5, y: 2)
                .animation(shouldReduceMotion ? nil : SlackModel.motion, value: label)
        }
        .padding(.top, ChatPetMetrics.top).allowsHitTesting(false)
        .accessibilityElement().accessibilityLabel("ddots · " + label)
    }

    /// The characters, above the draft as on the iMessage side. The bright face is who the next message reaches.
    /// It wears a ring only while that is the user's own choice — a pressed face, or the thread being answered —
    /// so once the message has gone and the choice is let go, the ring is gone too.
    var ddotsFaces: some View {
        let lit = slack.litRecipientProfile
        let chose = slack.ddotsPicked || slack.target != nil
        return HStack(spacing: 2) {
            ForEach(slack.ddotsMembers) { member in
                let chosen = member.profile == lit
                Button { slack.aim(member) } label: {
                    avatarBadge(member.name, profile: member.profile, size: ChatMetrics.callerAvatar)
                        .opacity(chosen ? 1 : 0.5)
                        .padding(3)
                        .overlay(Self.face(ChatMetrics.callerAvatar + 6).stroke(Color.accentColor, lineWidth: 2).opacity(chosen && chose ? 1 : 0))
                        .padding(1)
                }.buttonStyle(.plain).help(chosen && slack.ddotsPicked && slack.target == nil ? "다시 누르면 글 내용에 따라 받는 캐릭터를 정해요" : member.name + "에게 새 글")
                    .accessibilityLabel(member.name + (chosen ? ", 받는 캐릭터" : "에게 새 글"))
                    .accessibilityIdentifier("ddots-face-" + member.profile)
            }
        }.animation(shouldReduceMotion ? nil : SlackModel.motion, value: lit).animation(shouldReduceMotion ? nil : SlackModel.motion, value: chose)
    }

}

extension ChatView {
    /// What a file-only message is called where one line stands in for it.
    func slackPreview(_ message: ChatMessage) -> String {
        if !message.fromUser && SlackText.isThinking(message.body) { return "작성 중…" }
        let text = ChatText.preview(message.body)
        return text.isEmpty ? (message.files.first.map { "📎 " + $0.name } ?? message.marks.first.map { ChatText.preview($0.text) } ?? "") : text
    }

    /// A picture shows itself; anything else shows its name and size. Pressing either saves the file to the shared folder and opens it.
    func fileView(_ file: ChatFile, in message: ChatMessage) -> some View {
        let busy = slack.busyFiles.contains(file.id)
        return Button { slack.onFile?(file, message) } label: {
            if file.isDeleted {
                Label(file.isImage || slack.vault.trusted(message) ? "삭제된 사진" : "삭제된 파일", systemImage: "photo.badge.exclamationmark")
                    .foregroundColor(.secondary).padding(12)
            } else if file.isImage {
                ZStack {
                    if let image = slack.thumbs[file.id] {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)).frame(width: 160, height: 110)
                            .overlay(Group {
                                if slack.failedThumbs.contains(file.id) { Text("사진을 불러오지 못했어요").font(.system(size: 11)) }
                                else { Image(systemName: "photo").font(.system(size: 20)).opacity(0.7) }
                            })
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: slack.vault.trusted(message) ? .infinity : 220, maxHeight: slack.vault.trusted(message) ? nil : 180).clipShape(RoundedRectangle(cornerRadius: 10))
                .onAppear { slack.onThumb?(file) }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: file.isPDF ? "doc.richtext.fill" : "doc.fill").font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slackHighlight(AttributedString(file.name), message: message)).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text([SlackFileStore.sizeText(file.size), file.isPDF ? "PDF" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 10)).opacity(0.75)
                    }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.down.circle").font(.system(size: 14)).opacity(0.8) }
                }
                .padding(.horizontal, 10).padding(.vertical, 7).frame(maxWidth: 240, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.18)))
            }
        }.disabled(file.isDeleted).buttonStyle(.plain).filePointer().help("눌러서 저장하고 열기").accessibilityLabel(file.name + " 저장하고 열기")
            .accessibilityIdentifier("file-" + file.id)
    }

    /// Files picked for the next message, each removable before sending.
    var slackAttachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(slack.attachments, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(systemName: "paperclip").font(.system(size: 10))
                        Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150)
                        Button { slack.detach(url) } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundColor(quiet).accessibilityLabel(url.lastPathComponent + " 빼기")
                    }.padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.primary.opacity(0.1)))
                }
            }
        }.transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

extension ChatView {
    /// The room's notice, fixed above the conversation: how many posts are waiting, by status. Pressing a count goes to the next one.
    @ViewBuilder var slackNoticeBar: some View {
        if !slack.notices.isEmpty {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(quiet).rotationEffect(.degrees(45))
                        ForEach(slack.notices) { item in
                            Button { slack.jump(item) } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Self.color(hex: item.color) ?? Color.primary.opacity(0.4)).frame(width: 8, height: 8)
                                    Text(item.title).font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium))
                                    Text("\(item.threads.count)").font(.system(size: ChatMetrics.auxiliaryFont, weight: .bold))
                                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(quiet)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Capsule().fill((Self.color(hex: item.color) ?? Color.primary).opacity(0.16)))
                                .overlay(Capsule().stroke((Self.color(hex: item.color) ?? Color.primary).opacity(0.45), lineWidth: 1))
                            }.buttonStyle(.plain).help("눌러서 해당 글로 이동").accessibilityLabel("\(item.title) \(item.threads.count)건, 눌러서 이동")
                                .accessibilityIdentifier("notice-" + item.id)
                        }
                        if slack.alertCount > 0 {
                            // Every notification in the room marked read at once, as pressing each bell would.
                            Button { slack.onReadAll?() } label: {
                                Label("모두 읽음", systemImage: "checkmark.circle").font(.system(size: ChatMetrics.auxiliaryFont, weight: .medium))
                            }
                            .buttonStyle(.plain).foregroundColor(quiet)
                            .help("이 방의 알림 \(slack.alertCount)건을 모두 읽음으로").accessibilityLabel("알림 \(slack.alertCount)건 모두 읽음")
                            .accessibilityIdentifier("notice-read-all")
                        }
                    }.padding(.horizontal, 12).padding(.vertical, 7)
                }
                Divider()
            }
            .background(Color.primary.opacity(0.04))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

extension SlackOwner {
    static func color(_ profile: String) -> Color? {
        guard !profile.isEmpty else { return nil }
        if let chosen = hex[profile].flatMap(ChatView.color(hex:)) { return chosen }
        // Stable across devices and launches; Swift's randomized Hasher must not pick UI colors.
        let seed = profile.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return Color(nsColor: PaletteRGB.hsl(Double(seed % 360), 0.6, 0.55).nsColor)
    }
}

/// Tracks card geometry without publishing layout changes back into the conversation.
struct SlackRowProbe: NSViewRepresentable {
    let model: SlackModel
    let id: String
    var entryStamp: SlackModel.EntryViewportStamp? = nil
    func makeNSView(context: Context) -> NSView {
        let view = Probe(); view.configure(model: model, id: id, stamp: entryStamp); return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? Probe)?.configure(model: model, id: id, stamp: entryStamp) }
    final class Probe: NSView {
        weak var model: SlackModel?
        private var id = ""
        private var stamp: SlackModel.EntryViewportStamp?
        func configure(model: SlackModel, id: String, stamp: SlackModel.EntryViewportStamp?) {
            self.model = model; self.id = id; self.stamp = stamp
            // Configuration has the new identity, but its frame may still belong to the previous render.
            model.recordEntryRow(self, id: id, stamp: nil)
            needsLayout = true
        }
        override func layout() {
            super.layout()
            guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
            model?.recordEntryRow(self, id: id, stamp: stamp)
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }
    }
}

/// Finds the conversation's scroll view and notices when the user scrolls it by hand.
struct SlackScrollProbe: NSViewRepresentable {
    let model: SlackModel
    let stamp: SlackModel.EntryViewportStamp
    func makeNSView(context: Context) -> NSView { let view = Probe(); view.model = model; view.stamp = stamp; return view }
    func updateNSView(_ view: NSView, context: Context) {
        guard let probe = view as? Probe else { return }
        probe.stamp = stamp; probe.connect(); probe.prepareAfterLayout()
    }
    final class Probe: NSView {
        weak var model: SlackModel?
        var stamp: SlackModel.EntryViewportStamp?
        private var observer: NSObjectProtocol?
        private var boundsObserver: NSObjectProtocol?
        private var documentObserver: NSObjectProtocol?
        private var inputMonitor: Any?
        private weak var watched: NSScrollView?
        private var preparationQueued = false
        deinit { disconnect() }
        private func disconnect() {
            for token in [observer, boundsObserver, documentObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
            observer = nil; boundsObserver = nil; documentObserver = nil
            if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }; inputMonitor = nil
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect(); prepareAfterLayout() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        override func layout() { super.layout(); connect(); prepareAfterLayout() }
        override func viewWillDraw() { super.viewWillDraw(); model?.onEntryViewportFrame?() }
        func connect() {
            guard let scroll = enclosingScrollView, let stamp else { return }
            model?.connectEntryViewport(scroll, stamp: stamp)
            guard watched !== scroll else { return }
            disconnect(); watched = scroll
            observer = NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                self?.model?.userScrolls += 1
            }
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                _ = self?.model?.prepareEntryViewport()
            }
            if let document = scroll.documentView {
                document.postsFrameChangedNotifications = true
                documentObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: document, queue: .main) { [weak self] _ in
                    _ = self?.model?.prepareEntryViewport()
                }
            }
            // Offset changes also come from layout. Only actual input takes ownership from an entry;
            // wheel mice, scrollbars and keyboard navigation need not announce a live-scroll gesture.
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
                if reading {
                    if event.type == .scrollWheel { self.model?.scrollInputAt = ProcessInfo.processInfo.systemUptime }
                    self.model?.userScrolls += 1
                }
                return event
            }
        }
        func prepareAfterLayout() {
            guard !preparationQueued else { return }
            preparationQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preparationQueued = false
                self.connect()
                self.enclosingScrollView?.layoutSubtreeIfNeeded()
                self.model?.prepareEntryViewport()
            }
        }
    }
}

struct SlackRenderedBlock: Identifiable {
    var id: Int
    var quote: Bool
    var text: AttributedString
}

/// One stretch of a post: ordinary lines, or lines quoted from someone else.
struct SlackBlock: Identifiable {
    var id: Int
    var quote: Bool
    var text: String

    /// Consecutive quoted lines become one quote; everything between them stays together as written.
    static func split(_ body: String) -> [SlackBlock] {
        var blocks: [SlackBlock] = []
        for raw in body.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let quoted = line.hasPrefix(">")
            let text = quoted ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : raw
            if let last = blocks.last, last.quote == quoted { blocks[blocks.count - 1].text += "\n" + text }
            else { blocks.append(SlackBlock(id: blocks.count, quote: quoted, text: text)) }
        }
        return blocks.compactMap { block in
            let trimmed = block.text.trimmingCharacters(in: .newlines)
            return trimmed.isEmpty ? nil : SlackBlock(id: block.id, quote: block.quote, text: trimmed)
        }
    }
}

extension ChatView {
    /// A character's post laid out in steps, the way Slack shows it: the picture, then the name and time,
    /// then the words under the name, with quoted lines set in behind a bar.
    func slackPost(_ message: ChatMessage, selectable: Bool, textClick: (() -> Void)?) -> some View {
        let palette = model.palette(message.profile, dark: dark)
        let folded = slack.findTerm(message) == nil && LongReply.needsFolding(message.body) && !model.expandedReplies.contains(message.id)
        let blocks = slack.presentation(message.id, body: folded ? LongReply.preview(message.body) : message.body,
                                        dark: dark, link: palette.link, trusted: slack.vault.trusted(message)) {
            ShrimpCandidates.styled($0, trusted: slack.vault.trusted(message), accent: Color(nsColor: palette.link.nsColor))
                ?? (slack.vault.pathLines(message).isEmpty ? slackStyled($0, palette: palette) : AttributedString($0))
        }
        let actions = model.actions(for: message).filter { $0.isCalendar }
        return HStack(alignment: .top, spacing: 9) {
            avatarBadge(message.speaker, profile: message.profile, size: ChatMetrics.avatar)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.speaker).font(.system(size: ChatMetrics.nameFont, weight: .bold))
                        .foregroundColor(Color(nsColor: palette.name.nsColor))
                    Text(Self.time.string(from: message.date)).font(.system(size: 10)).foregroundColor(quiet)
                }
                VStack(alignment: .leading, spacing: 6) {
                    if slack.vault.trusted(message), let page = ShrimpPage.parse(message.body) {
                        // 새우튀김 answers only the newest list in a thread; buttons a later search replaced would move that one.
                        let stale = slack.shrimpThread(message).map { slack.vault.staleControls(message, in: $0) } ?? false
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                Button("◀") { slack.shrimpPageCommand("쪽: \(page.current-1)", message: message) }.disabled(page.current == 1)
                                ForEach(page.numbers, id: \.self) { n in
                                    Button("\(n)") { slack.shrimpPageCommand("쪽: \(n)", message: message) }.tint(n == (slack.shrimpPendingPages[message.id] ?? page.current) ? .accentColor : .secondary).chatMeasure("ux58-page-\(n)", model: model)
                                }
                                Button("▶") { slack.shrimpPageCommand("쪽: \(page.current+1)", message: message) }.disabled(page.current == page.pages)
                                Button("전체 보기") {
                                    slack.shrimpListThread = slack.shrimpThread(message)?.id; slack.shrimpListPage = 1; web.showShrimpList()
                                    slack.shrimpPageCommand("전체 보기", message: message)
                                }.chatMeasure("thread-all", model: model)
                            }.buttonStyle(.bordered).controlSize(.small).disabled(stale)
                        }.threadControls().background(SlackRowProbe(model: slack, id: "page-anchor:" + message.id))
                        HStack(spacing: 6) {
                            Text("\(page.current)/\(page.pages)쪽 · 총 \(page.total)건" + (stale ? " · 새 검색 결과가 아래에 있어요" : ""))
                            if slack.shrimpPendingPages[message.id] != nil {
                                ProgressView().controlSize(.small)
                                Text("이동 중")
                            }
                        }.font(.caption).foregroundColor(.secondary)
                    } else if slack.vault.trusted(message), let full = ShrimpAllHeader.parse(message.body) {
                        Button("전체 목록 \(full.total)건 — 오른쪽 창에서 보기") {
                            slack.shrimpListThread = slack.shrimpThread(message)?.id; slack.shrimpListPage = 1; web.showShrimpList()
                        }.buttonStyle(.borderless).threadControls()
                    } else {
                    ForEach(blocks) { block in
                        if block.quote {
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5).fill(SlackOwner.color(message.profile) ?? Color.primary.opacity(0.28)).frame(width: 3)
                                ChecklistText(slack.vault.linkified(slackHighlight(block.text, message: message), message: message), identity: message.id + ":block:\(block.id)", revision: message.body).onSelectedTextClick(textClick).foregroundColor(.primary.opacity(0.82))
                                    .fixedSize(horizontal: false, vertical: true)
                            }.fixedSize(horizontal: false, vertical: true)
                        } else {
                            ChecklistText(slack.vault.linkified(slackHighlight(block.text, message: message), message: message), identity: message.id + ":block:\(block.id)", revision: message.body).onSelectedTextClick(textClick).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    }
                    ForEach(Array(message.marks.enumerated()), id: \.offset) { _, mark in markNote(mark, message: message) }
                    ForEach(message.files) { fileView($0, in: message) }
                }
                .font(.system(size: ChatMetrics.bodyFont)).lineSpacing(2).selectableText(selectable && !SlackResizeSmoke.without("selection"))
                .tint(Color(nsColor: palette.link.nsColor))
                if LongReply.needsFolding(message.body) && !(slack.vault.trusted(message) && ShrimpAllHeader.parse(message.body) != nil) {
                    Button(folded ? "더 보기" : "접기") { model.toggleReply(message.id) }
                        .font(.system(size: ChatMetrics.auxiliaryFont)).buttonStyle(.borderless)
                        .foregroundColor(Color(nsColor: palette.name.nsColor))
                }
                if !actions.isEmpty { calendarButtons(actions) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .replyHeight(message, model: model)
        .environment(\.openURL, OpenURLAction { url in
            if !slack.vaultPath(url, message: message), ChatText.mayOpen(url) { slack.driveNote(url, message: message); model.onOpenLink?(url) }
            return .handled
        })
    }

    /// The calendar buttons under a post that names an event on the calendar.
    func calendarButtons(_ actions: [PetAction]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) { model.onAction?(action) }.buttonStyle(.bordered).controlSize(.small)
            }
        }.threadControls()
    }

    /// Inline Markdown with code set apart as Slack does: a tinted chip in a fixed-width face.
    func slackStyled(_ text: String, palette: CharacterPalette) -> AttributedString {
        let parsed = MessageFormat.render(text)
        var styled = SynologyLink.titled(ChatText.linkified(parsed))
        for run in styled.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                styled[run.range].font = .system(size: ChatMetrics.bodyFont - 1, design: .monospaced)
                styled[run.range].foregroundColor = dark ? Color(red: 0.96, green: 0.68, blue: 0.36) : Color(red: 0.76, green: 0.32, blue: 0.09)
                styled[run.range].backgroundColor = Color.primary.opacity(0.1)
            }
            if run.link != nil {
                styled[run.range].foregroundColor = Color(nsColor: palette.link.nsColor)
                styled[run.range].underlineStyle = Text.LineStyle(pattern: .solid)
            }
        }
        return styled
    }
}

/// Keeps per-keystroke updates below the conversation while sharing its existing focus binding.
private struct SlackComposerInput: View {
    @ObservedObject var composer: SlackDraft
    let slack: SlackModel
    let model: ChatModel
    var focused: Binding<Bool>
    let prompt: String
    let room: String?
    let hasAttachments: Bool
    let quiet: Color
    private var sendable: Bool { !composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments }
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button { slack.onAttach?() } label: { Image(systemName: "plus.circle.fill").font(.system(size: 24)) }
                .buttonStyle(.plain).foregroundColor(quiet).disabled(room == nil)
                .help("사진·파일 첨부").accessibilityLabel("사진·파일 첨부").accessibilityIdentifier("slack-attach")
            DraftEditor(prompt: prompt, text: $composer.text, focus: focused, onPaste: { slack.pasteAttachments() }, onSubmit: { slack.send() })
                .onChange(of: focused.wrappedValue) { slack.composerFocused = $0 }
                .onDisappear { slack.composerFocused = false }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.3)))
                .accessibilityIdentifier("slack-draft")
                .chatMeasure("slack-draft", model: model)
            Button { slack.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                .buttonStyle(.plain).foregroundColor(sendable ? .blue : quiet).disabled(!sendable || room == nil)
                .accessibilityLabel("보내기")
        }
    }
}

extension View {
    /// A row of a thread's controls keeps every click that lands on it. A click between two buttons, or on a button that is switched off,
    /// would otherwise fall through to the card and fold the thread.
    func threadControls() -> some View { contentShape(Rectangle()).onTapGesture {} }
}

/// A draft selection stays local until the owner presses 작성, then uses the normal thread reply.
private typealias HermesChecklistState = SwiftUI.State<Set<String>>

private struct HermesReplyChecklist: View {
    let labels: [String]
    let submit: (Set<String>) -> Void
    let canSkip: Bool
    let skip: () -> Void
    @HermesChecklistState private var selected: Set<String>

    init(labels: [String], initialSelection: Set<String>, canSkip: Bool, skip: @escaping () -> Void, submit: @escaping (Set<String>) -> Void) {
        self.labels = labels; self.submit = submit; self.canSkip = canSkip; self.skip = skip
        self._selected = HermesChecklistState(wrappedValue: initialSelection.intersection(labels))
    }

    private var choices: some View {
        ForEach(labels, id: \.self) { label in
            Button((selected.contains(label) ? "✅ " : "☐ ") + label) {
                selected = SlackNotice.checklistToggle(labels: labels, selected: selected, label: label,
                                                       isOn: !selected.contains(label))
            }.buttonStyle(.bordered).tint(selected.contains(label) ? .accentColor : .secondary).fixedSize()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { choices }.fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 8) { choices }
            }
            HStack(spacing: 8) {
                Button("작성") { submit(selected) }.disabled(selected.isEmpty)
                if canSkip { Button(DdotsConfig.shared.conversation.text("checklistSkip"), action: skip) }
            }
        }.font(.system(size: 12))
    }
}
