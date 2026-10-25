import AppKit
import SwiftUI

@main
struct DdotsMain {
    static func main() {
        if AppMaintenance.run(arguments: CommandLine.arguments) { return }
        if RelayAgent.runCommand(arguments: CommandLine.arguments) { return }
        if CommandLine.arguments.contains("--hermes-locate") {
            let suite = "ddots-locate-diagnostic-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            if let saved = UserDefaults.standard.string(forKey: HermesLocator.homeKey) { defaults.set(saved, forKey: HermesLocator.homeKey) }
            let locator = HermesLocator(defaults: defaults)
            let expected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").resolvingSymlinksInPath()
            if let root = locator.locate() {
                print(root == expected ? "Hermes root: ~/.hermes; defaultMatch=true" : "Hermes root differs from ~/.hermes; defaultMatch=false")
            } else { print("Hermes root: not found") }
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--hook"), CommandLine.arguments.count > index + 1,
           let provider = Provider(rawValue: CommandLine.arguments[index + 1]) {
            var destination: URL?
            if let i = CommandLine.arguments.firstIndex(of: "--event-root"), CommandLine.arguments.count > i + 1 { destination = URL(fileURLWithPath: CommandLine.arguments[i + 1]) }
            HookBridge.run(provider: provider, destination: destination)
            return
        }
        if CommandLine.arguments.contains("--relay") { HermesRelayServer.runForever(arguments: CommandLine.arguments) }
        if CommandLine.arguments.contains("--snapshot") {
            let snapshot = StatusMonitor().poll(forceDiscovery: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) { FileHandle.standardOutput.write(data); print("") }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let smokeForeground = NSWorkspace.shared.frontmostApplication
    let model = DashboardModel()
    var panel: PetPanel!
    var pet: PetView!
    var dashboard: NSWindow?
    var optionsWindow: NSWindow?
    var paseoStatusLabel: NSTextField?
    var loginCheckbox: NSButton?
    /// What the bubble is out for, so the same thing does not bring it out twice.
    var bubbleAlert: String?, shownBubbleAlert: String?
    var loginStatusLabel: NSTextField?
    var loginSettingsButton: NSButton?
    var loginChangeFailed = false
    var sizeSlider: NSSlider?
    var opacitySlider: NSSlider?
    var opacityValueLabel: NSTextField?
    var sizeValueLabel: NSTextField?
    var petNameField: NSTextField?
    var petNameHint: NSTextField?
    var statusItem: NSStatusItem!
    var timer: Timer?
    var previewTimer: Timer?
    var menu: NSMenu!
    var isPreview = false
    var currentSnapshot: Snapshot?
    let monitor = StatusMonitor()
    let usage = UsageMonitor()
    let monitorQueue = DispatchQueue(label: AppIdentity.bundleID + ".monitor", qos: .utility)
    var polling = false
    var bubbleMotion = PetBubbleMotion()
    var lastGenieTrace: GenieTrace?
    var genieTrace: GenieTrace?
    var motionTrace: MotionTrace?
    private weak var petMenuItem: NSMenuItem?
    private weak var pauseMenuItem: NSMenuItem?
    private weak var vaultMenuItem: NSMenuItem?
    var paneSnapshotMS: Double = 0
    var paneSnapshotUsed = false
    private var paneLayoutDeferred = false
    var paneSettlementMS = 0.0
    var transitionWork: [(String, Double, Double)] = []
    var widthPhase: String { widthFadeStart == nil ? "move" : "fade" }
    func recordTransitionWork(_ name: String, since start: Double) {
        StallTrace.shared.record(name, since: start)
        if widthSample != nil { transitionWork.append((name, start, ProcessInfo.processInfo.systemUptime - start)) }
    }
    var widthSample: ((Double, Double, CGFloat, CGFloat) -> Void)?
    var widthSliding = false
    private var widthLayout: (size: CGSize, pane: CGFloat, column: CGFloat)?
    private var widthPreparing = false
    private var widthFadeStart: Double?
    var widthReflowMS: Double = 0
    var widthViewportChanges = 0
    private func applyWidthLayout(_ size: CGSize, pane: CGFloat, column: CGFloat) {
        pet.chatSize = size; pet.paneWidth = pane
        if chat.viewportWidth != column {
            if widthSliding && !widthPreparing { widthViewportChanges += 1 }
            chat.viewportWidth = column
        }
        if web.width != pane { web.width = pane }
        if pane > 0, web.layoutWidth != pane { web.layoutWidth = pane }
    }
    private func finishWidthSlide() {
        guard widthSliding else { return }
        settlePaneContent()
        widthSliding = false; widthPreparing = false; widthFadeStart = nil
        widthLayout = nil; paneStartingSprite = nil; bubbleMotion.cancelWidthSlide()
        pet.endWidthPicture(); chat.finishResize()
        if web.sliding { web.sliding = false; if !web.open { web.unload() } }
    }
    var placementTarget: PetPlacement?
    var transitionFrame: CGRect?
    let relayPortraits = RelayPortraits(url: RelaySettings.support.appendingPathComponent("relay-portraits.json"))
    var hermes: HermesSource = HermesBridge()
    var hermesRevision = 0
    var remoteHermes: RemoteHermes?
    var threeTap: ThreeTapController!
    private var tapMenuItem: NSMenuItem?
    private var tapCopyItem: NSMenuItem?
    private var tapSmokeDefaults: String?
    private let tapSender = ThreeTapSender()
    var refreshAgain = false
    var smokeHome: URL?
    var searchGeneration = 0
    var searchWork: DispatchWorkItem?
    var pageGeneration = 0
    var lastSearchMilliseconds = 0.0
    var calendar = MacCalendar(observe: !CommandLine.arguments.contains("--ui-smoke"))
    var calendarWindow: NSWindow?
    let chat = ChatModel()
    let slack = SlackController()
    let web = WebPaneModel()
    /// The page's width as the user last dragged it; nil while it follows the conversation's width.
    var savedPaneWidth: CGFloat?
    var savedPaneHeight: CGFloat?
    private var paneSizeAnchor: CGPoint?
    private var paneSizeBelow: Bool?
    private var paneHeightActive = false
    private var paneStartingSprite: CGRect?
    var lastSlackStrip: CGFloat = 0
    var slackTimer: Timer?
    var lastLayoutHeight = PetLayout.expandedSize.height
    var replySizeAnchor: CGPoint?
    var preferredChatSize = PetLayout.expandedSize
    var resizeStartOrigin: CGPoint?
    var resizingChat = false
    private var pendingResize: (size: CGSize?, origin: CGPoint?, pane: CGFloat?)?
    private var resizeWork: DispatchWorkItem?
    var chatDrag: (point: CGPoint, placement: PetPlacement)?
    /// The pet's place as a check run last saved it, in place of the settings.
    var smokePosition: [String: Double] = [:]
    var resizedBelow: Bool?
    /// Where the conversation's bottom edge stood when the pet was picked up with it open underneath.
    var petDragBottom: CGFloat?
    var unread = UnreadReplies()
    var replyActivity = ChatReplyActivity()
    var isSmoke: Bool { CommandLine.arguments.contains("--ui-smoke") }
    var chatExpanded = false
    var outsideLocalMonitor: Any?
    var hermesStatus = HermesBridge.Status.unavailable("")
    var storedMessages: [ChatMessage] = []
    var pendingMessages: [ChatMessage] = []
    var sendNotice: String?
    /// Messages typed while an earlier one is still going out; sent in order.
    var outbox: [String] = []
    var nudges = NudgeEngine(reminders: (UserDefaults.standard.dictionary(forKey: "hermesReminders") as? [String: Double] ?? [:])
        .mapValues { Date(timeIntervalSince1970: $0) })
    var bubbleActions: [PetAction] = []
    var connectOffer = ConnectOffer()
    var currentConnectOffer: ConnectOffer.Kind?
    var localHermesFound = false
    var connectOfferSmokeInput: ConnectOffer.Input?
    private var slackAppDiscovery: (at: Date, installed: Bool)?
    private var hermesLocationLabel: NSTextField?

    func slackAppInstalled(now: Date = Date()) -> Bool {
        guard !isSmoke else { return false }
        if let cached = slackAppDiscovery, now.timeIntervalSince(cached.at) < 300 { return cached.installed }
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap") != nil
        slackAppDiscovery = (now, installed)
        return installed
    }
    var foldedPerchAnchor: CGPoint?
    private var geniePreparing = false
    var genieStartProgress: CGFloat = 0
    var perchAwaitingTick = false
    private var perchArmedAt = 0.0
    private var perchUsesTimer = false
    var perchTransition: (start: TimeInterval, opening: Bool, placement: PetPlacement)? { didSet { if perchTransition == nil, oldValue != nil || pet?.genieActive == true { pet?.endGenie() } } }
    var bubbleSize = PetLayout.bubbleSize
    var hermesEnabled: Bool { UserDefaults.standard.bool(forKey: "hermesChatEnabled") }
    /// UI checks use a made-up number so they neither depend on saved settings nor can reach a real thread.
    var hermesHandle: String? { isSmoke ? "+15555550100" : UserDefaults.standard.string(forKey: "hermesHandle").flatMap(HermesBridge.validHandle) }

    @objc func screenPowerChanged() { restIfDark() }
    /// The pet stops moving while the screen is off or locked and goes on when it is back. UI checks always animate.
    func restIfDark() {
        guard !isSmoke else { return }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        pet.resting = locked || CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }
    /// How long closing waits for its file and cache work before the app ends anyway.
    static let closingLimit: TimeInterval = 2
    private var closingRun: ClosingRun?
    private var appUpdate: AppUpdate?
    private var installedUpdateNotice: (text: String, until: Date)?
    /// How many folders of pasted pictures the start removed, once it has finished.
    var pasteRecovered: Int?
    /// Set by the closing check: told when closing is answered, and whether it was cut off at the limit.
    var onClosingAnswered: ((_ late: Bool) -> Void)?
    /// Private copies, pasted pictures and the Slack cache are dealt with away from the main thread, which keeps
    /// drawing meanwhile. The app goes on closing once they are done, or at the limit, once.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard closingRun == nil else { return .terminateCancel }
        let run = ClosingRun(limit: Self.closingLimit) { [weak self] late in
            self?.onClosingAnswered?(late)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        closingRun = run
        appUpdate?.stop()
        // Nothing new is read from Slack while closing.
        slackTimer?.invalidate(); slackTimer = nil
        slack.prepareClose(run)
        if let pasted = slack.model.closeClipboardFiles() {
            run.add(on: .global(qos: .userInitiated)) { ClipboardAttachments.remove(pasted) }
        }
        run.start()
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        threeTap?.stop()
        if let tapSmokeDefaults { UserDefaults.standard.removePersistentDomain(forName: tapSmokeDefaults) }
        // Ending without being asked first saves nothing more privately; the next start clears what is left.
        if closingRun == nil { slack.temporaryFiles.close() }
        removeOutsideClickMonitors()
        if let smokeHome { try? FileManager.default.removeItem(at: smokeHome) }
        SmokeLeftovers.clear()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if !IMessageFeature.enabled { slack.model.source = .slack }
        if isSmoke {
            if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke"), CommandLine.arguments.count > index + 1 {
                StallTrace.shared.start(destination: URL(fileURLWithPath: CommandLine.arguments[index+1]).appendingPathComponent("stall-log.txt"))
            }
        } else {
            StallTrace.shared.start(destination: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("stall-log.txt"))
        }
        if CommandLine.arguments.contains("--ui-smoke-light") { NSApp.appearance = NSAppearance(named:.aqua) }
        if CommandLine.arguments.contains("--ui-smoke-dark") { NSApp.appearance = NSAppearance(named:.darkAqua) }
        if !AppIdentity.otherPets().isEmpty && !CommandLine.arguments.contains("--ui-smoke") {
            NSApp.terminate(nil); return
        }
        // Pasted pictures an earlier run could not remove in time go now (only once this is the one ddots running), off the main thread.
        if Self.closingKind == "paste-recover" { ClipboardAttachments.stall = { if $0 == "recover" { _ = Self.recoveryGate.wait(timeout: .now() + 60) } } }
        slack.model.recoverPastedImages { [weak self] removed in self?.pasteRecovered = removed }
        if !isSmoke {
            let defaults = UserDefaults.standard
            preferredChatSize = PetLayout.preferredSize(width:defaults.object(forKey:"chatWidth") as? Double,height:defaults.object(forKey:"chatHeight") as? Double)
            if let width = defaults.object(forKey: "webPaneWidth") as? Double, width.isFinite, width >= Double(PetLayout.minimumPaneWidth) { savedPaneWidth = CGFloat(width) }
            if let height = defaults.object(forKey: "webPaneHeight") as? Double, height.isFinite, height >= Double(PetLayout.minimumChatSize.height) { savedPaneHeight = CGFloat(height) }
            let read = (defaults.object(forKey:"chatLastRead") as? Double).map(Date.init(timeIntervalSince1970:))
            unread = UnreadReplies(lastRead:read)
            defaults.set(unread.lastRead.timeIntervalSince1970,forKey:"chatLastRead")
        }
        do {
            pet = PetView(atlas: try SpriteAtlas(), identity: model.identity); pet.chatOpacityPercent = BubbleOpacity.load()
            // UI checks look at the bubble itself, so it stays out for them unless one asks otherwise.
            pet.bubbleAlwaysShown = isSmoke ? !CommandLine.arguments.contains("--ui-smoke-bubble-hidden") : UserDefaults.standard.bool(forKey: BubbleReveal.settingsKey)
        }
        catch { let alert = NSAlert(error: error); alert.runModal(); NSApp.terminate(nil); return }
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: pet.bounds.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = pet
        pet.autoresizingMask = [.width, .height]
        pet.onClick = { [weak self] count in self?.petClicked(count: count) }
        pet.onPress = { [weak self] in
            guard let self else { return }
            if self.chatExpanded { self.collapseChat() } else { self.showChat() }
        }
        pet.onAction = { [weak self] index in
            guard let self, self.bubbleActions.indices.contains(index) else { return }
            self.perform(self.bubbleActions[index])
        }
        slack.model.atlas = pet.atlas
        web.persistent = !isSmoke
        pet.installChat(chat, slack: slack.model, web: web)
        chat.onReplyLayout = { [weak self] in
            guard let self else { return }
            if chat.replyExtraHeight > 0 && replySizeAnchor == nil { replySizeAnchor = paneSizeAnchor ?? placementTarget?.anchorOrigin }
            slackChanged()
            if chat.replyExtraHeight == 0 { replySizeAnchor = nil }
        }
        web.onLayout = { [weak self] in self?.webChanged() }
        web.onWindowDragBegan = { [weak self] point in self?.beginChatDrag(at: point) }
        web.onWindowDragChanged = { [weak self] point in self?.moveChatDrag(to: point) }
        web.onWindowDragEnded = { [weak self] in self?.endChatDrag() }
        slack.model.onListClose = { [weak self] in if self?.web.shrimpList == true || self?.web.shrimpCollapsed == true { self?.web.close() } }
        // A page's links leave for another app under the same rule as the conversation's; a saved file the user has open may too.
        web.onExternal = { url in if url.isFileURL || ChatText.mayOpen(url) { NSWorkspace.shared.open(url) } }
        slack.onShowFile = { [weak self] url in self?.showBeside(url) ?? false }
        slack.model.onShowFile = { [weak self] url in self?.showBeside(url) ?? false }
        slack.onShowTemporaryFile = { [weak self] url in self?.showBeside(url, ephemeral: true) ?? false }
        panel.onPageKey = { [weak self] event in
            guard let self, self.web.hasFocus(in: self.panel) else { return false }
            return self.web.handleShortcut(event)
        }
        pet.onResizePane = { [weak self] width in
            guard let self else { return }
            if resizingChat { queueResize(pane: width) } else { resizePane(to: width) }
        }
        pet.onResetPaneSize = { [weak self] in self?.resetPaneSize() }
        slack.onChange = { [weak self] in self?.slackChanged() }
        slack.onEnterIMessage = { [weak self] in
            guard let self else { return }
            self.pageGeneration += 1; self.chat.loadingOlder = false
            self.chat.enterLatest()
        }
        slack.model.onConnect = { [weak self] in self?.configureSlack() }
        slack.onPicked = { [weak self] in self?.panel.makeKeyAndOrderFront(nil) }
        panel.onPasteAttachments = { [weak self] in
            guard let self, self.slack.model.source == .slack, self.slack.model.composerFocused,
                  let editor = self.panel.firstResponder as? NSTextView, editor.isEditable else { return false }
            return self.slack.model.pasteAttachments()
        }
        panel.onCollapse = { [weak self] in
            if self?.slack.model.findOpen == true { self?.slack.model.closeFind() } else { self?.chat.escape() }
        }
        panel.onChatKey = { [weak self] event in
            guard let self else { return false }
            // Keys typed into a page or its address field are that page's, Esc and ⌘F included.
            if self.web.hasFocus(in: self.panel) { return false }
            if self.breakDraftLine(event) { return true }
            if self.slack.model.source == .slack, self.slack.model.handleFindKey(event) { return true }
            return self.chat.handleKey(event)
        }
        chat.onCollapse = { [weak self] in self?.collapseChat() }
        chat.onDragBegan = { [weak self] point in self?.beginChatDrag(at: point) }
        chat.onHeaderDoubleClick = { [weak self] in self?.toggleChatWidth() }
        chat.onDragChanged = { [weak self] point in self?.moveChatDrag(to: point) }
        chat.onDragEnded = { [weak self] in self?.endChatDrag() }
        chat.onAutomation = {
            guard IMessageFeature.enabled else { return }
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
        chat.onSearch = { [weak self] query in self?.searchChat(query) }
        chat.onSelectResult = { [weak self] message in self?.selectChatResult(message) }
        chat.onOlder = { [weak self] before in self?.loadOlderChat(before: before) }
        chat.onSend = { [weak self] text in self?.sendChat(text) }
        chat.onAction = { [weak self] action in self?.perform(action) }
        calendar.onChange = { [weak self] events in
            self?.chat.calendarEvents = events
            self?.updatePet()
        }
        if !isSmoke { calendar.refresh(requestAccess: true) }
        if !isSmoke { chat.onOpenLink = { [weak self] url in self?.openLink(url) } }
        slack.onUnfollowed = { [weak self] url in self?.openElsewhere(url) }
        chat.onSetup = { [weak self] in self?.configureHermes() }
        pet.onMoved = { [weak self] in self?.constrainPosition(); self?.savePosition() }
        pet.onDragEnded = { [weak self] in self?.endPetDrag() }
        pet.onDragMove = { [weak self] origin in self?.movePet(to: origin) }
        pet.onAnimationTick = { [weak self] in self?.advancePlacement() }
        pet.onDisplayTick = { [weak self] in
            guard let self, !(self.perchUsesTimer && self.perchTransition != nil) else { return }
            self.advancePlacement(displayTick: true)
        }
        pet.onClockFallback = { [weak self] in
            guard let self, self.perchTransition != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.perchAwaitingTick && now - self.perchArmedAt >= 0.05 {
                self.perchUsesTimer = true
                self.advancePlacement(displayTick: true)
                return
            }
            if self.perchUsesTimer { self.advancePlacement() }
        }
        pet.onResting = { [weak self] in
            guard let self else { return }
            self.finishWidthSlide()
            guard let transition = self.perchTransition else { return }
            self.perchAwaitingTick = false; self.perchUsesTimer = false
            self.perchTransition = (ProcessInfo.processInfo.systemUptime - ChatMorph.genieDuration, transition.opening, transition.placement)
            self.advancePlacement()
        }
        pet.onDozeChanged = { [weak self] in self?.updatePet() }
        pet.onResizeBegan = { [weak self] in self?.finishWidthSlide(); self?.perchTransition = nil; self?.resizeStartOrigin = self?.pet.placement?.globalSprite.origin; self?.resizingChat = true; self?.slack.model.measuringResize = true; self?.slack.model.beginRowResize(); self?.resizedBelow = self?.pet.placement?.bubbleBelow; self?.chat.beginResize() }
        pet.onResize = { [weak self] size, origin in self?.queueResize(size: size, origin: origin) }
        pet.onResizeEnded = { [weak self] in
            guard let self else { return }
            applyPendingResize()
            pet.layoutSubtreeIfNeeded()
            let reading = slack.model.rowResizePlace()
            slack.model.endRowResize()
            resizingChat = false; slack.model.measuringResize = false
            slackChanged()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                pet.layoutSubtreeIfNeeded(); slack.model.restoreRowResize(reading)
            }
            saveChatSize(); savePaneSize(); chat.finishResize()
            if let resizeStartOrigin, resizeStartOrigin != pet.placement?.globalSprite.origin { savePosition() }
            resizeStartOrigin = nil
        }
        pet.onResetChatSize = { [weak self] in self?.resetChatSize() }
        prepareThreeTap()
        buildMenu()
        installEditMenu()
        if !isSmoke {
            let updates = AppUpdate()
            updates.activity = { [weak self] in
                guard let self else { return .init(idleSeconds: 0, hasDrafts: true, transferring: true) }
                return .init(idleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!),
                             hasDrafts: !self.chat.draft.isEmpty || self.slack.updateHasDrafts,
                             transferring: self.chat.sending || !self.outbox.isEmpty || self.slack.updateHasTransfers || self.web.updateHasTransfers,
                             presenting: NSApp.presentationOptions.contains(.fullScreen) || self.web.presenting)
            }
            updates.notifyInstalled = { [weak self] text in
                self?.installedUpdateNotice = (text, Date().addingTimeInterval(10))
                self?.pet.revealBubble()
            }
            appUpdate = updates
            updates.start()
        }
        pet.onMenu = { [weak self] event in guard let self else { return }; NSMenu.popUpContextMenu(self.menu, with: event, for: self.pet) }
        model.onSelect = { [weak self] id in self?.model.selectedID = id; self?.updatePet() }
        model.onRefresh = { [weak self] in self?.refresh() }
        model.onPause = { [weak self] in self?.togglePause() }
        model.onPreview = { [weak self] in self?.preview() }
        model.onHooks = { [weak self] in self?.showHooksHelp() }
        restorePosition()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if !CommandLine.arguments.contains("--ui-smoke") { connectHermesSource(); slack.restore(); refresh() }
        threeTap.start()
        usage.onChange = { [weak self] in self?.updatePet(); self?.paseoStatusLabel?.stringValue = self?.usage.paseoStatus ?? "" }
        usage.fixture = isSmoke
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            let began = ProcessInfo.processInfo.systemUptime
            defer { self?.recordTransitionWork("poll2s", since: began) }
            self?.refresh()
            if let self { StallTrace.shared.measure("usage.tick") { self.usage.tick(paused: self.model.paused, smoke: self.isSmoke) } }
            // Looked at here as well as on the notices below, so a notice that was missed never leaves the pet still.
            self?.restIfDark()
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(self, selector: #selector(screenPowerChanged), name: name, object: nil)
        }
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            DistributedNotificationCenter.default().addObserver(self, selector: #selector(screenPowerChanged), name: Notification.Name(name), object: nil)
        }
        // The Slack side keeps its own, quicker beat so a character's answer shows soon after it is written.
        slackTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            let began = ProcessInfo.processInfo.systemUptime
            defer { self?.recordTransitionWork("slack075s", since: began) }
            if self?.model.paused == false, self?.isSmoke == false { self?.slack.tick() }
        }
        if CommandLine.arguments.contains("--show-dashboard") { showDashboard() }
        if CommandLine.arguments.contains("--show-calendar") { showCalendar() }
        if let index = CommandLine.arguments.firstIndex(of: "--ui-smoke"), CommandLine.arguments.count > index + 1 {
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            recordDisabledIMessageChecks(destination: destination)
            showDashboard()
            pet.headline = "헤이헤이 일끝났어"
            pet.subtitle = usage.subtitle
            placePet(at: NSPoint(x: 650, y: 30))
            if let flag = CommandLine.arguments.firstIndex(of: "--ui-smoke-row"), CommandLine.arguments.count > flag + 1 {
                pet.previewRow = Int(CommandLine.arguments[flag + 1])
            }
            if CommandLine.arguments.contains("--ui-smoke-chat") || CommandLine.arguments.contains("--ui-smoke-perch") {
                isPreview = true
                let fixture = ChatSmokeFixture.create(); smokeHome = fixture
                hermes = HermesBridge(home:fixture)
                let fixtureResult = monitorQueue.sync { (hermes as! HermesBridge).poll(includeMessages: IMessageFeature.enabled) }
                chat.characters = fixtureResult.characters
                chat.avatars = fixtureResult.avatars
                let fixtureMessages = fixtureResult.messages
                storedMessages = CommandLine.arguments.contains("--ui-smoke-late-history") ? [] : fixtureMessages
                let renderStart = ProcessInfo.processInfo.systemUptime
                showChat()
                DispatchQueue.main.async {
                    self.pet.layoutSubtreeIfNeeded()
                    if let bitmap = self.pet.bitmapImageRepForCachingDisplay(in:self.pet.bounds) {
                        self.pet.cacheDisplay(in:self.pet.bounds,to:bitmap)
                    }
                    let metric = "BENCH initial layout+raster ms \((ProcessInfo.processInfo.systemUptime-renderStart)*1000) rows \(self.chat.messages.count)\n"
                    try? FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
                    try? metric.write(to:destination.appendingPathComponent("render.txt"),atomically:true,encoding:.utf8)
                    print(metric)
                }
                chat.canSend = IMessageFeature.enabled
                if IMessageFeature.enabled {
                    chat.draft = "접어도 유지되는 작성 중인 글"
                    chat.notice = "메시지 제어 권한이 필요해요."
                    chat.needsAutomation = true
                }
                chat.onSend = nil // Smoke mode never sends a real message.
                if CommandLine.arguments.contains("--ui-smoke-slack") { startSlackSmoke() }
                else if CommandLine.arguments.contains("--ui-smoke-ddots") { startDdotsSmoke() }
                else if !IMessageFeature.enabled { startSlackSmoke() }
                if IMessageFeature.enabled && CommandLine.arguments.contains("--ui-smoke-late-history") {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { [self] in
                        smokeCheck(!chat.didInitialScroll,"Empty first opening cannot consume initial scrolling")
                        storedMessages = fixtureMessages; publishChat()
                    }
                }
            }
            if CommandLine.arguments.contains("--ui-smoke-options") { showOptions() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if CommandLine.arguments.contains("--ui-smoke-memory") {
                    self.dashboard?.orderOut(nil)
                    self.collapseChat()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        try? "ready".write(to: destination.appendingPathComponent("memory-ready.txt"), atomically: true, encoding: .utf8)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 610) { NSApp.terminate(nil) }
                    return
                }
                self.capture(destination: destination)
                if CommandLine.arguments.contains("--ui-smoke-update-reminder") { self.verifyUpdateReminder(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-connect-offer") { self.verifyConnectOffer(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-faces") { self.verifyDdotsFaces(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-stop") { self.verifyAgentStop(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-notices") { self.verifyRoomNotices(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-update-live") { self.verifyLiveUpdateCheck(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-menu") { self.verifyMenuPicture(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-pet-flicker") { self.verifyPetDragFlicker(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-pet-drag") { self.verifyPetDrag(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-pet-carry") { self.verifyPetCarry(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-chat-perf") { self.verifyChatPerformance(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-format") { self.verifyFormatting(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-composer-scroll") { self.verifyComposerScroll(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-stability") { self.verifyStability(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-publish") { self.verifyPublish(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-three-tap") { Task { @MainActor in await self.verifyThreeTap(destination: destination) } }
                else if CommandLine.arguments.contains("--ui-smoke-perch") { self.verifyPerch(destination:destination) }
                else if CommandLine.arguments.contains("--ui-smoke-portraits") { self.verifyRelayPortraits(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-selection") { self.verifySlackSelection(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-resize") { self.verifySlackResize(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-room") { self.verifySlackRoom(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-input") { self.verifySlackInput(destination: destination) { NSApp.terminate(nil) } }
                else if CommandLine.arguments.contains("--ui-smoke-calendar") { self.verifyCalendar(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-web") { self.verifyWeb(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-responses") { self.verifyResponses(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-slack") { Task { @MainActor in await self.measureHeaderSlide(destination: destination); self.verifySlack(destination: destination) } }
                else if CommandLine.arguments.contains("--ui-smoke-ddots") { self.verifyDdots(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-chat") { self.verifyChatInteraction(destination: destination) }
                else if CommandLine.arguments.contains("--ui-smoke-bubble-hidden") { self.verifyBubbleReveal(destination: destination) }
                else { NSApp.terminate(nil) }
            }
        }
    }

    func refresh() {
        guard !model.paused, !CommandLine.arguments.contains("--ui-smoke") else { return }
        StallTrace.shared.measure("calendar.refresh") { calendar.refresh() }
        // A relayed change that lands mid-poll is picked up right after it instead of at the next tick.
        guard !polling else { refreshAgain = true; return }
        polling = true; refreshAgain = false
        let readsChat = hermesEnabled
        let readsSlack = hermesEnabled && slack.connected
        let lastRead = unread.lastRead
        let source = hermes, revision = hermesRevision
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let located = HermesLocator.shared.locate()
            if let bridge = source as? HermesBridge, let located, bridge.home != located {
                DispatchQueue.main.async {
                    self.polling = false
                    if revision == self.hermesRevision { self.connectHermesSource() }
                    self.refresh()
                }
                return
            }
            let snapshot = self.monitor.poll()
            let conversation = readsChat ? ((source as? HermesBridge)?.poll(unreadSince: IMessageFeature.enabled ? lastRead : nil, includeMessages: IMessageFeature.enabled)
                ?? source.poll(unreadSince: IMessageFeature.enabled ? lastRead : nil)) : nil
            let empty = HermesBridge.PollResult(status: .unavailable(""), messages: [])
            // Disabling local chat must not let remote backups replace this Mac's own profiles.
            let localDisabled = !readsChat && (source as? HermesBridge)?.stores().isEmpty == false
            let portraits = localDisabled ? empty : self.relayPortraits.merging(conversation ?? empty)
            // Only this Mac's own Hermes record says who is writing in a Slack thread.
            let activity = readsSlack ? (source as? HermesBridge)?.slackActivity() : nil
            DispatchQueue.main.async {
                self.finishRefresh(snapshot: snapshot, conversation: conversation, portraits: portraits, activity: activity, localHermesFound: localDisabled || located != nil, revision: revision)
            }
        }
    }

    func finishRefresh(snapshot: Snapshot, conversation: HermesBridge.PollResult?, portraits: HermesBridge.PollResult,
                       activity: SlackActivity?, localHermesFound: Bool = false, revision: Int) {
        polling = false
        // A completed read can already be queued on the main thread when the user changes or disables the source.
        guard revision == hermesRevision else { refresh(); return }
        if !model.paused {
            self.localHermesFound = localHermesFound
            slack.activity = activity ?? SlackActivity()
            if slack.model.projects != (conversation?.projects ?? []) { slack.model.projects = conversation?.projects ?? [] }
            applyChat(conversation, portraits: portraits); apply(snapshot)
        }
        if refreshAgain { refresh() }
    }

    private var chatTimelineMemo = ChatTimelineMemo()
    func applyChat(_ result: HermesBridge.PollResult?, portraits: HermesBridge.PollResult? = nil) {
        let began = StallTrace.now
        defer { StallTrace.shared.record("applyChat", since: began) }
        let portraits = portraits ?? result
        hermesStatus = result?.status ?? .unavailable("")
        storedMessages = IMessageFeature.enabled ? (result?.messages ?? []) : []
        if case .unavailable(let reason) = hermesStatus, !storedMessages.isEmpty,
           let received = (hermes as? RemoteHermes)?.lastReceivedAt {
            hermesStatus = .unavailable(reason + " 마지막 수신: " + received.formatted(date: .numeric, time: .shortened) + " · 이전 대화를 표시 중이에요.")
        }
        if IMessageFeature.enabled, replyActivity.update(typing:result?.typing ?? [],messages:storedMessages,now:Date()) { pet.requestReplyJump() }
        StallTrace.shared.measure("chat.unread") { updateUnread(IMessageFeature.enabled ? (result?.receipts ?? []) : []) }
        StallTrace.shared.measure("chat.portraits") {
        if chat.characters != portraits?.characters ?? [] { chat.characters = portraits?.characters ?? [] }
        slack.characters = chat.characters
        if chat.avatars != portraits?.avatars ?? [:] { chat.avatars = portraits?.avatars ?? [:] }
        }
        let typing = IMessageFeature.enabled ? (result?.typing ?? []) : []
        if chat.typing != typing { chat.typing = typing }
        let merged = StallTrace.shared.measure("chat.merge") { chatTimelineMemo.merge(storedMessages,pending: pendingMessages) }
        StallTrace.shared.measure("chat.receive") { chat.receive(merged,session: result?.sessionToken ?? "") }
        let detail: String?
        switch result?.status {
        case .connected(let stores)?: detail = IMessageFeature.enabled ? "연결됨 · 기록 \(stores)곳 · 대화 \(storedMessages.count)건" : "연결됨 · 캐릭터 \(chat.characters.count)명"
        case .unavailable(let reason)?:
            if case .unavailable(let notice) = hermesStatus { detail = notice } else { detail = reason }
        case nil: detail = hermesEnabled ? "확인 중" : nil
        }
        if model.hermesDetail != detail { model.hermesDetail = detail }
        pendingMessages = ChatTimeline.unresolved(pendingMessages, stored: storedMessages)
        StallTrace.shared.measure("chat.publish") { publishChat() }
        let waiting = nudges.reminders.count
        _ = nudges.update(messages: nudgeMessages, now: Date(), chatOpen: chatExpanded, muted: !panel.isVisible)
        if nudges.reminders.count != waiting { saveReminders() }
    }
    /// Replies from either side can raise a bubble over the pet.
    var nudgeMessages: [ChatMessage] {
        guard IMessageFeature.enabled else { return slack.incoming }
        // With the iMessage conversation muted, only reminders the user asked for still come from it.
        let own = chatQuiet ? storedMessages.filter { nudges.reminders[$0.id] != nil } : storedMessages
        if own.isEmpty { return slack.incoming }
        return slack.incoming.isEmpty ? own : (own + slack.incoming).sorted(by: ChatTimeline.ordered)
    }
    var unreadTotal: Int { (chatQuiet ? 0 : unread.count) + slack.unreadTotal }
    /// True when ddots has the window to itself: it is on and Slack is connected, so there is no iMessage side to open.
    var ddotsOnly: Bool { Ddots.enabled && slack.connected }
    /// The iMessage conversation raises no bubble and no count when it is muted, and when it cannot be opened to be read.
    var chatQuiet: Bool { !IMessageFeature.enabled || slack.model.chatMuted || ddotsOnly }
    /// The Slack side is wider by its tab strip; the saved size is always the conversation's own.
    var slackWide: Bool { slack.model.source == .slack }
    var slackStrip: CGFloat { slackWide ? slack.model.sidebarWidth : 0 }
    var layoutChatSize: CGSize {
        CGSize(width: preferredChatSize.width + slackStrip,
               height: PetLayout.paneHeight(base: max(preferredChatSize.height + chat.replyExtraHeight, slackFitHeight ?? 0),
                                            open: paneWanted > 0, saved: savedPaneHeight))
    }
    /// The height that shows the opened thread whole: everything around the conversation stays as it is,
    /// and the conversation gets as tall as the thread. The screen still caps it.
    var slackFitHeight: CGFloat? {
        guard !slack.model.measuringResize else { return nil }
        let model = slack.model
        guard slackWide, slack.connected, chatExpanded, let id = model.focusThread, model.open.contains(id),
              let thread = model.threadHeights[id], model.viewportHeight > 0 else { return nil }
        return slackChromeHeight + thread + SlackSidebar.threadMargin
    }
    /// Everything in the conversation besides the list of threads. The list's own reading arrives one layout late, so
    /// paired with the size just placed it would add each change to the next and the height would swing without end.
    /// The scroll view and the conversation as AppKit last laid them out belong to the same pass.
    var slackChromeHeight: CGFloat {
        if let scroll = slack.model.scrollView, scroll.window === panel, let laidOut = pet.chatLaidOutHeight {
            return laidOut - scroll.frame.height
        }
        return pet.chatSize.height - slack.model.viewportHeight
    }
    /// ⇧Return in a draft starts a new line there; Return alone still sends. The field itself takes both for sending,
    /// so the line is put in here. A syllable still being composed is kept as typed first, then the line is broken after it.
    func breakDraftLine(_ event: NSEvent) -> Bool {
        guard [36, 76].contains(event.keyCode), event.modifierFlags.intersection([.command, .shift, .option, .control]) == .shift,
              slack.model.source == .slack ? slack.model.composerFocused : chat.composerFocused,
              let editor = panel.firstResponder as? NSTextView, editor.isEditable else { return false }
        if editor.hasMarkedText() { editor.unmarkText(); editor.inputContext?.discardMarkedText() }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return true
    }
    private var genieSlackConnected = false
    func slackChanged() {
        let workStart = StallTrace.now
        defer { StallTrace.shared.record("slack.changed", since: workStart) }
        if genieSlackConnected && !slack.connected { pet.invalidateGeniePicture() }
        genieSlackConnected = slack.connected
        let unreadStart = StallTrace.now
        let total = unreadTotal
        if pet.unreadCount != total { pet.unreadCount = total }
        StallTrace.shared.detail("slack.changed.unread", milliseconds: (StallTrace.now-unreadStart)*1000)
        guard !resizingChat else { return }
        let layoutStart = StallTrace.now
        placeForSlackLayout()
        StallTrace.shared.detail("slack.changed.layout", milliseconds: (StallTrace.now-layoutStart)*1000)
        guard !isSmoke, !model.paused else { return }
        let nudgeStart = StallTrace.now
        let waiting = nudges.reminders.count
        _ = nudges.update(messages: nudgeMessages, now: Date(), chatOpen: chatExpanded, muted: !panel.isVisible)
        if nudges.reminders.count != waiting { saveReminders() }
        StallTrace.shared.detail("slack.changed.nudges", milliseconds: (StallTrace.now-nudgeStart)*1000)
        let petStart = StallTrace.now
        updatePet()
        StallTrace.shared.detail("slack.changed.pet", milliseconds: (StallTrace.now-petStart)*1000)
    }
    private var slackPlacing = false, slackPlaceAgain = false
    /// Placing lays the conversation out, and that layout can report a new measurement before placing returns.
    /// Such a report is not placed inside the one under way; the latest is applied once after it, in the same turn.
    private func placeForSlackLayout() {
        if slackPlacing { slackPlaceAgain = true; return }
        slackPlacing = true; defer { slackPlacing = false }
        for _ in 0..<2 {
            slackPlaceAgain = false
            let size = layoutChatSize
            guard slackStrip != lastSlackStrip || abs(size.height - lastLayoutHeight) > 1 else { return }
            if slackStrip != lastSlackStrip, chatExpanded { pet.chatWidthFollowsGlass = true }
            lastSlackStrip = slackStrip; lastLayoutHeight = size.height
            // The bubble eases to its new size the same way it follows the pet.
            if let anchor = replySizeAnchor ?? placementTarget?.anchorOrigin { placePet(at: anchor) } else { constrainPosition() }
            guard slackPlaceAgain else { return }
        }
    }
    func updateUnread(_ receipts: [ChatReceipt]) {
        let previous = unread.lastRead
        unread.update(receipts,open:chatExpanded,now:Date())
        if pet.unreadCount != unreadTotal { pet.unreadCount = unreadTotal }
        statusItem.button?.toolTip = "ddots · \(model.identity.name) · 작업 중 \(model.tasks.filter { $0.state == .running }.count)개 · 안 읽은 답 \(unreadTotal)개"
        if previous != unread.lastRead && !isSmoke { UserDefaults.standard.set(unread.lastRead.timeIntervalSince1970,forKey:"chatLastRead") }
    }
    /// The default is twice the usual conversation width; a saved drag width takes precedence.
    var paneWanted: CGFloat {
        guard chatExpanded, web.open else { return 0 }
        return savedPaneWidth ?? PetLayout.defaultPaneWidth
    }
    func paneSplit(on screen: NSScreen) -> (base: CGFloat, pane: CGFloat) {
        PetLayout.paneSplit(base: layoutChatSize.width, minimumBase: PetLayout.minimumChatSize.width + slackStrip,
                            wanted: paneWanted, available: screen.visibleFrame.width - 24)
    }
    /// A link pressed in the conversation opens beside it. ⌘-click, another app's address, and a screen with no room
    /// for a page go to the browser as before.
    func openLink(_ url: URL) {
        guard ChatText.mayOpen(url) else { return }
        // A Synology link to a file synced to this Mac opens here, with no sign-in; with ⌘ it goes to the web as any link does.
        if !NSEvent.modifierFlags.contains(.command), let target = SynologyLink.target(for: url) {
            switch target {
            // A saved page could run its own script in the pane, so it goes to the browser.
            case .open(let file): if ["html", "htm", "svg"].contains(file.pathExtension.lowercased()) || !showBeside(file) { NSWorkspace.shared.open(file) }
            case .folder(let folder) where !NSWorkspace.shared.isFilePackage(atPath: folder.path): NSWorkspace.shared.open(folder)
            case .folder(let item), .reveal(let item): NSWorkspace.shared.activateFileViewerSelecting([item])
            }
            return
        }
        // A link to a thread of the connected workspace goes to that thread here; with ⌘ it opens outside as any link does.
        if chatExpanded, !NSEvent.modifierFlags.contains(.command), slack.follow(url) { return }
        openElsewhere(url)
    }
    private func openElsewhere(_ url: URL) {
        guard chatExpanded, WebAddress.isWeb(url), !NSEvent.modifierFlags.contains(.command), paneFits else { NSWorkspace.shared.open(url); return }
        web.open(url)
    }
    func showBeside(_ file: URL, ephemeral: Bool = false) -> Bool {
        guard chatExpanded, WebAddress.showsFile(file), paneFits else { return false }
        web.open(file, ephemeral: ephemeral); return true
    }
    var paneFits: Bool {
        guard let screen = panel.screen else { return false }
        let wanted = savedPaneWidth ?? PetLayout.defaultPaneWidth
        return PetLayout.paneSplit(base: layoutChatSize.width, minimumBase: PetLayout.minimumChatSize.width + slackStrip,
                                   wanted: wanted, available: screen.visibleFrame.width - 24).pane >= PetLayout.usablePaneWidth
    }
    /// The glass covers the page; page creation and layout wait until it has stopped moving.
    func webChanged() {
        paneSnapshotMS = 0; paneSnapshotUsed = false; paneSettlementMS = 0
        if web.open && !paneHeightActive {
            paneSizeAnchor = replySizeAnchor ?? placementTarget?.anchorOrigin
            paneSizeBelow = resizedBelow
        }
        let anchor = replySizeAnchor ?? paneSizeAnchor ?? placementTarget?.anchorOrigin
        if !web.open && paneHeightActive {
            if paneSizeAnchor != nil { resizedBelow = paneSizeBelow }
            paneSizeAnchor = nil; paneSizeBelow = nil
        }
        paneHeightActive = web.open
        guard chatExpanded else {
            if !web.open { web.unload(); if let anchor { placePet(at: anchor) } }
            return
        }
        web.sliding = true
        if beginSizeSlide(pane: true) {
            paneLayoutDeferred = true
            if let anchor { placePet(at: anchor) } else { constrainPosition() }
            let base = widthLayout.map { $0.size.width - $0.pane } ?? (pet.chatSize.width - pet.paneWidth)
            let tab = web.current
            let picture = tab?.picture
            if web.open { tab?.revealPreview = picture }
            pet.setPanePagePicture(picture, base: base, closing: !web.open)
            paneSnapshotUsed = picture != nil
            if picture == nil, !web.open, let tab {
                tab.allowsPicture = { true }
                tab.onPicture = { [weak self, weak tab] picture in
                    guard let self, let tab, self.widthSliding, self.web.sliding, !self.web.open, self.web.current === tab else { return }
                    self.pet.setPanePagePicture(picture, base: base)
                    self.paneSnapshotUsed = true; self.paneSnapshotMS = tab.snapshotMS
                }
                DispatchQueue.main.async { [weak tab] in tab?.takePicture() }
            }
            widthPreparing = false
            bubbleMotion.slideWidth(now: ProcessInfo.processInfo.systemUptime)
            pet.startWidthClock()
        } else {
            finishWidthSlide()
            let dragging = resizingChat; resizingChat = true
            if let anchor { placePet(at: anchor) } else { constrainPosition() }
            resizingChat = dragging
            web.finishTransition(); web.sliding = false
            if !web.open { web.unload() }
        }
    }
    private func settlePaneContent() {
        guard paneLayoutDeferred else { return }
        paneLayoutDeferred = false
        let began = ProcessInfo.processInfo.systemUptime
        widthPreparing = true
        if let layout = widthLayout { applyWidthLayout(layout.size, pane: layout.pane, column: layout.column) }
        web.finishTransition()
        pet.prepareWidthContent(); pet.layoutSubtreeIfNeeded()
        widthPreparing = false
        paneSettlementMS = (ProcessInfo.processInfo.systemUptime-began)*1000
    }
    func resizePane(to width: CGFloat) {
        savedPaneWidth = max(PetLayout.minimumPaneWidth, width)
        if let anchor = placementTarget?.anchorOrigin { placePet(at: anchor) } else { constrainPosition() }
    }
    func resetPaneSize() {
        finishWidthSlide()
        resizingChat = true; savedPaneWidth = nil; savedPaneHeight = nil
        if let anchor = placementTarget?.anchorOrigin { placePet(at: anchor) } else { constrainPosition() }
        resizingChat = false; savePaneSize()
    }
    func savePaneSize() {
        guard !isSmoke else { return }
        if let savedPaneWidth { UserDefaults.standard.set(Double(savedPaneWidth), forKey: "webPaneWidth") }
        else { UserDefaults.standard.removeObject(forKey: "webPaneWidth") }
        if let savedPaneHeight { UserDefaults.standard.set(Double(savedPaneHeight), forKey: "webPaneHeight") }
        else { UserDefaults.standard.removeObject(forKey: "webPaneHeight") }
    }
    func saveChatSize() {
        guard !isSmoke else { return }
        UserDefaults.standard.set(preferredChatSize.width,forKey:"chatWidth")
        UserDefaults.standard.set(preferredChatSize.height,forKey:"chatHeight")
    }
    /// All edges, including the page edge, share one latest update per main-loop turn.
    private func queueResize(size: CGSize? = nil, origin: CGPoint? = nil, pane: CGFloat? = nil) {
        if pendingResize == nil { pendingResize = (nil, nil, nil) }
        if let size { pendingResize?.size = size; pendingResize?.origin = origin }
        if let pane { pendingResize?.pane = pane }
        guard resizeWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.applyPendingResize() }
        resizeWork = work; DispatchQueue.main.async(execute: work)
    }
    private func applyPendingResize() {
        resizeWork?.cancel(); resizeWork = nil
        guard let pending = pendingResize else { return }
        pendingResize = nil
        slack.model.updateRowResize()
        if let pane = pending.pane { savedPaneWidth = max(PetLayout.minimumPaneWidth, pane) }
        if let size = pending.size { resizeChat(to: size, spriteOrigin: pending.origin) }
        else if let anchor = placementTarget?.anchorOrigin { placePet(at: anchor) }
        // Reflow can bring more rows into view. Reveal them before the window draws this step.
        for _ in 0..<slack.model.threads.count {
            guard slack.model.updateRowResize() else { break }
            pet.layoutSubtreeIfNeeded()
        }
    }
    func resizeChat(to size: CGSize, spriteOrigin: CGPoint? = nil) {
        slack.model.pageHold = nil
        replySizeAnchor = nil
        chat.acceptManualReplySize()
        slack.model.focusThread = nil
        // With a page open the conversation may be shown narrower than it is kept; a drag that leaves the width alone keeps it.
        let shown = pet.chatSize.width - web.width
        let width = web.width > 0 && abs(size.width - shown) < 0.5 ? preferredChatSize.width : size.width - slackStrip
        if paneWanted > 0, abs(size.height - pet.chatSize.height) > 0.5 { savedPaneHeight = max(PetLayout.minimumChatSize.height, size.height) }
        preferredChatSize = CGSize(width: max(PetLayout.minimumChatSize.width, width),
                                   height: paneWanted > 0 ? preferredChatSize.height : max(PetLayout.minimumChatSize.height, size.height))
        if let anchor = spriteOrigin ?? placementTarget?.anchorOrigin { placePet(at:anchor) } else { constrainPosition() }
        chat.adjustAfterResize()
    }
    /// A double click on the header: twice the usual width, and from there back to the usual one. The height is kept.
    func toggleChatWidth() {
        let response = StallTrace.shared.response("headerWidth")
        defer { StallTrace.shared.finish(response) }
        applyPendingResize()
        slack.model.endRowResize(); slack.model.measuringResize = false
        if paneLayoutDeferred { finishWidthSlide() }
        let animated = beginSizeSlide()
        if !animated { finishWidthSlide(); chat.beginResize(); resizingChat = true }
        let wide = PetLayout.expandedSize.width * 2
        preferredChatSize.width = abs(preferredChatSize.width - wide) < 1 ? PetLayout.expandedSize.width : wide; saveChatSize()
        if let anchor = placementTarget?.anchorOrigin { placePet(at:anchor) } else { constrainPosition() }
        if animated { commitSizeSlide() }
        else { resizingChat = false; chat.finishResize() }
    }
    private func beginSizeSlide(pane: Bool = false) -> Bool {
        guard chatExpanded, perchTransition == nil, !resizingChat,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !CommandLine.arguments.contains("--ui-smoke-reduce-motion") else { return false }
        pet.finishMorph(); pet.chatWidthFollowsGlass = false
        guard (pane ? pet.beginPanePicture() : pet.beginWidthPicture()) else { return false }
        if pane { paneStartingSprite = pet.placement?.globalSprite }
        if !widthSliding { chat.beginResize() }
        widthSliding = true; widthPreparing = true; widthFadeStart = nil; widthViewportChanges = 0
        return true
    }
    private func commitSizeSlide() {
        let started = ProcessInfo.processInfo.systemUptime
        if let layout = widthLayout { applyWidthLayout(layout.size, pane: layout.pane, column: layout.column) }
        pet.prepareWidthContent(); pet.layoutSubtreeIfNeeded()
        widthReflowMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        widthPreparing = false
        let began = ProcessInfo.processInfo.systemUptime
        bubbleMotion.slideWidth(now: began)
        widthSample?(began, 0, bubbleMotion.size.width, 0)
        pet.startWidthClock()
    }

    @objc func resetChatSize() {
        finishWidthSlide()
        applyPendingResize()
        slack.model.endRowResize(); slack.model.measuringResize = false
        chat.beginResize(); resizingChat = true
        preferredChatSize = PetLayout.expandedSize; saveChatSize()
        if let anchor = placementTarget?.anchorOrigin { placePet(at:anchor) } else { constrainPosition() }
        resizingChat = false; chat.finishResize()
    }
    func publishChat() {
        if !IMessageFeature.enabled {
            if !chat.messages.isEmpty { chat.receive([]) }
            chat.canSend = false; chat.needsAutomation = false; chat.notice = nil; chat.typing = []
            return
        }
        let merged = chatTimelineMemo.merge(storedMessages, pending: pendingMessages)
        chat.receive(merged)
        var notice = sendNotice
        if notice == nil, case .unavailable(let reason) = hermesStatus, !reason.isEmpty { notice = reason }
        if chat.notice != notice { chat.notice = notice }
        // Synthetic conversations retain their composer across reopenings; smoke never sends.
        let canSend = IMessageFeature.enabled && (isSmoke || hermesHandle != nil)
        if chat.canSend != canSend { chat.canSend = canSend }
        let title = pet.headline
        if chat.title != title { chat.title = title }
    }
    func saveReminders() {
        UserDefaults.standard.set(nudges.reminders.mapValues(\.timeIntervalSince1970), forKey: "hermesReminders")
    }
    func setBubbleActions(_ actions: [PetAction]) {
        guard actions != bubbleActions else { return }
        bubbleActions = actions; pet.actions = actions.map(\.title)
        bubbleSize = PetLayout.bubbleSize(actionCount: actions.count); pet.foldedHeight = bubbleSize.height
        constrainPosition()
    }
    /// One click opens the conversation and one click folds it; the second click of a double click does nothing more.
    func petClicked(count: Int) {
        guard count == 1 else { return }
        if chatExpanded { collapseChat() } else { showChat() }
    }
    func perform(_ action: PetAction) {
        switch action.kind {
        case .openLink(let url):
            if WebAddress.isWeb(url), !NSEvent.modifierFlags.contains(.command) {
                pendingBubbleLink = url
                showChat()
                finishBubbleLink()
            } else { NSWorkspace.shared.open(url) }
        case .showCalendar(let events):
            guard !isSmoke || CommandLine.arguments.contains("--ui-smoke-calendar") else { return }
            calendar.showRelated(events); presentCalendar()
        case .remindLater: nudges.remindLater(now: Date()); saveReminders(); updatePet(); return
        case .openChat: showChat(); return
        case .connectHermes:
            guard !isSmoke else { return }
            connectOffer.resolve(.hermes)
            HermesLocator.shared.invalidate()
            if let home = HermesLocator.shared.locate() {
                UserDefaults.standard.set(home.path, forKey: HermesLocator.homeKey)
                UserDefaults.standard.set(true, forKey: "hermesChatEnabled")
                connectHermesSource(); refresh()
            }
            updatePet(); return
        case .connectSlack:
            guard !isSmoke else { return }
            connectOffer.resolve(.slack); configureSlack(); updatePet(); return
        case .declineOffer:
            guard !isSmoke else { return }
            if let currentConnectOffer { connectOffer.resolve(currentConnectOffer) }
            updatePet(); return
        }
        nudges.dismiss(); updatePet()
    }
    func sendChat(_ text: String) {
        guard IMessageFeature.enabled, !isSmoke else { return }
        guard let handle = hermesHandle else { configureHermes(); return }
        if chat.sending { outbox.append(text); return }
        chat.sending = true; sendNotice = nil; chat.needsAutomation = false; publishChat()
        HermesBridge.send(text: text, handle: handle) { [weak self] failure in
            guard let self else { return }
            self.chat.sending = false
            if let failure {
                self.sendNotice = failure.message
                self.chat.needsAutomation = failure.automationDenied
                // Hand back everything unsent, keeping whatever is being typed right now.
                self.chat.draft = ([text] + self.outbox + [self.chat.draft]).filter { !$0.isEmpty }.joined(separator: "\n")
                self.outbox = []
            } else {
                self.pendingMessages.append(ChatMessage(id: "pending:\(UUID().uuidString)", fromUser: true,
                    speaker: "", body: text, date: Date(), pending: true))
                self.refresh()
            }
            self.publishChat()
            if failure == nil, !self.outbox.isEmpty { self.sendChat(self.outbox.removeFirst()) }
        }
    }

    func searchChat(_ query: String) {
        guard IMessageFeature.enabled else {
            chat.results = []; chat.searching = false
            if chat.searchOpen { chat.closeSearch() }
            return
        }
        searchGeneration += 1; let generation = searchGeneration
        searchWork?.cancel()
        guard chat.searchOpen, !HermesBridge.searchTerm(query).isEmpty else {
            chat.results = []; chat.searching = false; return
        }
        chat.searching = true
        let source = hermes
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let start = ProcessInfo.processInfo.systemUptime
            let results = source.search(query)
            let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == generation, self.chat.searchOpen else { return }
                self.chat.results = results; self.chat.selection = 0; self.chat.searching = false
                self.lastSearchMilliseconds = elapsed
            }
        }
        searchWork = work
        monitorQueue.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    func selectChatResult(_ message: ChatMessage) {
        guard IMessageFeature.enabled else { return }
        pageGeneration += 1; let generation = pageGeneration
        let source = hermes
        chat.closeSearch()
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let context = source.around(profile: message.profile, messageID: message.rowID)
            DispatchQueue.main.async {
                guard self.pageGeneration == generation, self.chatExpanded else { return }
                self.chat.showContext(context,target: message.id)
            }
        }
    }
    func loadOlderChat(before: ChatMessage?) {
        guard IMessageFeature.enabled else { chat.loadingOlder = false; return }
        let generation = pageGeneration
        let source = hermes
        monitorQueue.async { [weak self] in
            guard let self else { return }
            let messages = source.older(before: before)
            DispatchQueue.main.async {
                guard self.pageGeneration == generation, self.chatExpanded else { return }
                self.chat.previousPage(messages)
            }
        }
    }

    func apply(_ snapshot: Snapshot) {
        let workStart = StallTrace.now
        defer { StallTrace.shared.record("monitor.apply", since: workStart) }
        currentSnapshot = snapshot
        if model.tasks != snapshot.tasks { model.tasks = snapshot.tasks }
        if model.connections != snapshot.connections { model.connections = snapshot.connections }
        if model.warning != snapshot.warning { model.warning = snapshot.warning }
        model.lastScan = snapshot.observedAt
        pet.screenFocus = snapshot.screenFocus
        updatePet()
    }

    func updatePet() {
        let workStart = StallTrace.now
        defer { StallTrace.shared.record("updatePet", since: workStart) }
        defer {
            // A new message or a task that waits or failed brings the bubble out; anything else waits for the pointer.
            if bubbleAlert != shownBubbleAlert {
                shownBubbleAlert = bubbleAlert
                if bubbleAlert != nil { pet.revealBubble() }
            }
            if !chatExpanded, !chat.typing.isEmpty, !model.paused, pet.chatAnimation == .replyWaiting {
                let names = chat.typing.map(\.speaker).filter { !$0.isEmpty }.joined(separator: ", ")
                pet.subtitle = names.isEmpty ? "작성 중…" : "\(names) 작성 중…"
            }
            if chat.title != pet.headline { chat.title = pet.headline }
        }
        statusItem.button?.toolTip = "ddots · \(model.identity.name) · 작업 중 \(model.tasks.filter { $0.state == .running }.count)개 · 안 읽은 답 \(unreadTotal)개"
        guard !isPreview else { return }
        pet.bubbleText.avatarName = nil; pet.bubbleText.avatar = nil; pet.chatAnimation = nil
        bubbleAlert = nil
        currentConnectOffer = nil
        if model.paused {
            setBubbleActions([])
            pet.state = .idle; pet.headline = "\(model.identity.subject) 쉬고 있어요"; pet.subtitle = "메뉴에서 다시 시작할 수 있어요"; return
        }
        if let notice = installedUpdateNotice, Date() < notice.until {
            setBubbleActions([]); pet.state = .idle; pet.headline = notice.text; pet.subtitle = ""; return
        }
        installedUpdateNotice = nil
        let active = model.tasks.filter { $0.state == .running }.count
        let urgent = model.tasks.first { $0.state == .waiting || ($0.state == .failed && Date().timeIntervalSince($0.updatedAt) < 60) }
        if let urgent { bubbleAlert = "task:\(urgent.id):\(urgent.state)" }
        if urgent == nil, !chat.typing.isEmpty {
            pet.chatAnimation = .replyWaiting; setBubbleActions([])
            pet.state = .running; pet.headline = "답변을 생각하고 있어요"
            pet.subtitle = chat.typing.map(\.speaker).filter { !$0.isEmpty }.joined(separator:", ") + " 작성 중…"
            return
        }
        // A waiting or failed task is never covered by a chat nudge.
        let nudge = urgent == nil && !chatExpanded ? nudges.current : nil
        if let nudge {
            setBubbleActions(PetAction.bubble(for: nudge.message.body, events: chat.calendarEvents, at: nudge.message.date))
            bubbleAlert = "message:\(nudge.message.id):\(nudge.reminder)"
            pet.bubbleText.avatar = Ddots.avatar(chat.avatars[nudge.message.profile], name: nudge.message.speaker)
            pet.bubbleText.avatarName = nudge.message.speaker
            pet.state = .responded
            pet.headline = "\(nudge.message.speaker) · \(nudge.reminder ? "다시 알림" : "새 메시지")"
            pet.subtitle = ChatText.preview(nudge.message.body); return
        }
        if urgent == nil, !chatExpanded {
            let defaults = UserDefaults.standard
            let relayConfigured = !(defaults.string(forKey: RelaySettings.hostKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let actual = ConnectOffer.Input(hermesDecided: defaults.object(forKey: "hermesChatEnabled") != nil,
                relayConfigured: relayConfigured, localHermesFound: localHermesFound,
                slackConnected: slack.connected, slackAppInstalled: slackAppInstalled(), isSmoke: isSmoke)
            let input = isSmoke && CommandLine.arguments.contains("--ui-smoke-connect-offer") ? (connectOfferSmokeInput ?? actual) : actual
            let offer = connectOffer.next(input)
            if let offer {
                currentConnectOffer = offer
                bubbleAlert = "offer:" + offer.rawValue
                pet.state = .responded
                pet.headline = offer == .hermes ? "Hermes를 찾았어요" : "슬랙을 연결할까요?"
                pet.subtitle = offer == .hermes ? "슬랙에 캐릭터 이름·사진을 붙일까요?" : "안내대로 토큰만 복사하면 돼요"
                setBubbleActions([
                    PetAction(kind: offer == .hermes ? .connectHermes : .connectSlack, title: offer == .hermes ? "연결" : "토큰 넣기"),
                    PetAction(kind: .declineOffer, title: "괜찮아요")
                ])
                return
            }
        }
        setBubbleActions([])
        let selected = model.tasks.first { $0.id == model.selectedID }
        let focused = model.tasks.first { $0.id == currentSnapshot?.screenFocus?.taskID && $0.state == .running }
        let eligible = model.tasks.first { $0.state == .running || ($0.state == .responded && Date().timeIntervalSince($0.updatedAt) < 20) }
        if let item = urgent ?? selected ?? focused ?? eligible {
            pet.state = item.state
            pet.headline = "\(item.provider.name) · \(item.state.label)"
            pet.subtitle = active > 1 ? "\(active)개 작업 진행 중 · 클릭하면 대화창" : "\(item.project.isEmpty ? item.shortID : item.project) · 클릭하면 대화창"
            if urgent == nil, let headline = PetTaskSummary.runningHeadline(model.tasks) {
                pet.state = .running; pet.headline = headline
            } else if urgent != nil, active > 0 {
                pet.subtitle = "작업 중: \(PetTaskSummary.runningDetail(model.tasks))"
            }
        } else {
            pet.state = .idle
            let unknown = model.tasks.contains { $0.state == .unknown }
            pet.headline = unknown ? "헤이헤이 일끝났어" : pet.isDozing ? model.identity.dozeHeadline : model.identity.idleHeadline
            pet.subtitle = usage.subtitle
        }
    }

    @MainActor
    func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = MenuBarIcon.image(description: AppIdentity.name)
        menu = NSMenu()
        menu.delegate = self
        // What is used every day stays at the top; settings, connections and previews sit one level down.
        addMenu("대화 열기", #selector(showChat))
        addMenu("작업 목록", #selector(showDashboard))
        addMenu("내 캘린더…", #selector(showCalendar))
        menu.addItem(.separator())
        addMenu("펫 숨기기", #selector(togglePet)); petMenuItem = menu.items.last
        addMenu("잠시 쉬기", #selector(togglePause)); pauseMenuItem = menu.items.last
        menu.addItem(.separator())
        let view = addSubmenu("보기 설정")
        addMenu("말풍선 항상 보이기", #selector(toggleBubbleAlwaysShown), to: view)
        view.items.last?.state = pet.bubbleAlwaysShown ? .on : .off
        addMenu(ThreeTapController.title, #selector(toggleThreeTap), to: view); tapMenuItem = view.items.last
        addMenu("수정 요청문 복사", #selector(copyThreeTapRequest), to: view); tapCopyItem = view.items.last
        refreshThreeTapMenu()
        addMenu("위치 초기화", #selector(resetPosition), to: view)
        view.addItem(.separator())
        addMenu("옵션…", #selector(showOptions), to: view)
        let links = addSubmenu("연결")
        addMenu("Slack 연결…", #selector(configureSlack), to: links)
        addMenu("Hermes 연결…", #selector(configureHermes), to: links)
        addMenu("다른 Mac과 캐릭터 공유…", #selector(configureRelay), to: links)
        addMenu("업데이트 연결…", #selector(connectAppUpdate), to: links)
        links.addItem(.separator())
        addMenu("승인 알림 연결 안내", #selector(showHooksHelp), to: links)
        let vault = addSubmenu("새우튀김 보관함"); vaultMenuItem = menu.items.last
        vaultMenuItem?.isHidden = ShrimpVault.defaultBot.isEmpty
        addMenu("보관함 폴더 지정…", #selector(configureShrimpVault), to: vault)
        addMenu("보관함 저장 뒤 Slack 원본 삭제", #selector(toggleShrimpOriginalDeletion(_:)), to: vault)
        vault.items.last?.state = (UserDefaults.standard.object(forKey: ShrimpReceipts.setting) == nil || UserDefaults.standard.bool(forKey: ShrimpReceipts.setting)) ? .on : .off
        let previews = addSubmenu("미리보기")
        addMenu("동작 미리보기", #selector(preview), to: previews)
        addMenu("마우스 시선 미리보기", #selector(previewPointer), to: previews)
        menu.addItem(.separator())
        addMenu("업데이트 확인…", #selector(checkAppUpdate))
        addMenu("ddots 종료", #selector(quit))
        statusItem.menu = menu
    }
    @MainActor @objc func checkAppUpdate() { appUpdate?.checkNow() }
    @MainActor @objc func connectAppUpdate() { appUpdate?.connect() }
    @MainActor @objc func toggleShrimpOriginalDeletion(_ sender: NSMenuItem) {
        let next = sender.state != .on
        UserDefaults.standard.set(next, forKey: ShrimpReceipts.setting)
        sender.state = next ? .on : .off
    }
    @MainActor @objc func configureShrimpVault() { slack.model.chooseVaultFolder() }

    @MainActor
    private func prepareThreeTap() {
        let defaults: UserDefaults
        if isSmoke {
            let name = "ddots.three-tap.smoke." + UUID().uuidString
            defaults = UserDefaults(suiteName: name)!; defaults.removePersistentDomain(forName: name); tapSmokeDefaults = name
        } else { defaults = .standard }
        threeTap = ThreeTapController(defaults: defaults, live: !isSmoke)
        threeTap.onChange = { [weak self] in self?.refreshThreeTapMenu() }
        threeTap.onTap = { [weak self] in
            guard let self, self.panel.isVisible, !self.pet.resting else { return }
            self.petClicked(count: 1)
        }
        threeTap.onNotice = { [weak self] text, failure in
            guard let self, !self.isSmoke else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.threeTap.showNotice(text, failure: failure)
            }
        }
        threeTap.onFailure = { [weak self] failure in
            guard let self, !self.isSmoke else { return }
            if self.tapSender.executable != nil { self.tapSender.send(failure) }
            else { self.remoteHermes?.reportTapFailure(failure) }
        }
    }
    @MainActor
    private func refreshThreeTapMenu() {
        guard let threeTap else { return }
        let fault = threeTap.health.failure
        tapMenuItem?.state = threeTap.enabled && fault == nil ? .on : .off
        tapMenuItem?.isEnabled = fault == nil
        tapMenuItem?.toolTip = fault.map { "작동을 멈췄어요: " + $0 } ?? (threeTap.health == .absent ? "트랙패드가 연결되면 사용할 수 있어요." : "")
        tapCopyItem?.isHidden = fault == nil
        // NSMenu auto-enabling would undo the fault state because the target still responds.
        tapMenuItem?.action = fault == nil ? #selector(toggleThreeTap) : nil
    }
    @MainActor
    @objc func toggleThreeTap() { threeTap.toggle() }
    @MainActor
    @objc func copyThreeTapRequest() { if let failure = threeTap.failure { ThreeTapController.copy(failure) } }
    @objc func toggleBubbleAlwaysShown(_ sender: NSMenuItem) {
        pet.bubbleAlwaysShown.toggle()
        sender.state = pet.bubbleAlwaysShown ? .on : .off
        if !isSmoke { UserDefaults.standard.set(pet.bubbleAlwaysShown, forKey: BubbleReveal.settingsKey) }
    }
    func addMenu(_ title: String, _ selector: Selector, to parent: NSMenu? = nil) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; (parent ?? menu).addItem(item)
    }
    func addSubmenu(_ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""), sub = NSMenu(title: title)
        item.submenu = sub; menu.addItem(item); return sub
    }
    /// Any item of the menu or its submenus, by title.
    func menuItem(titled title: String, in parent: NSMenu? = nil) -> NSMenuItem? {
        for item in (parent ?? menu).items {
            if item.title == title { return item }
            if let sub = item.submenu, let found = menuItem(titled: title, in: sub) { return found }
        }
        return nil
    }
    @objc func showCalendar() {
        guard !isSmoke else { return }
        calendar.browse(); presentCalendar()
    }
    func presentCalendar() {
        if calendarWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "내 캘린더 · ddots"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MacCalendarView(model: calendar))
            window.minSize = NSSize(width: 660, height: 480); window.center(); calendarWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); calendarWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func showDashboard() {
        if dashboard == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 710, height: 610), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = model.identity.dashboardTitle; window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false; window.contentView = NSHostingView(rootView: Dashboard(model: model))
            window.minSize = NSSize(width: 680, height: 560); window.center(); dashboard = window
        }
        NSApp.activate(ignoringOtherApps: true); dashboard?.makeKeyAndOrderFront(nil)
    }
    private func finishGenieTrace(settleMS: Double = 0, completed: Bool = true) {
        if let genieTrace { lastGenieTrace = genieTrace }
        genieTrace?.finish(settleMS: settleMS,
            destination: isSmoke ? nil : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("motion-log.txt"), completed: completed)
        genieTrace = nil; pet.genieTrace = nil
    }
    private func startGenieTrace(opening: Bool) {
        finishGenieTrace(completed: false)
        genieTrace = GenieTrace(opening: opening); pet.genieTrace = genieTrace
        genieTrace?.observeSprite(pet.spriteDrawnScreenRect, backing: panel.backingScaleFactor)
    }
    private var geniePageGeneration = 0
    private var geniePageReady = false
    private func prepareGeniePage(opening: Bool) -> Bool {
        if geniePageReady { geniePageReady = false; return false }
        pet.geniePage = nil
        guard !pet.resting, web.open, let page = web.current?.view,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !CommandLine.arguments.contains("--ui-smoke-reduce-motion") else { return false }
        if let picture = web.current?.picture, picture.fresh {
            pet.geniePage = (NSImage(cgImage: picture.sharp, size: picture.size), page)
            return false
        }
        let generation = geniePageGeneration
        let pageBegan = ProcessInfo.processInfo.systemUptime
        var finished = false
        let complete: (NSImage?) -> Void = { [weak self, weak page] image in
            guard let self, !finished, self.geniePageGeneration == generation else { return }
            finished = true
            self.genieTrace?.pageMS = (ProcessInfo.processInfo.systemUptime - pageBegan) * 1000
            if let image, let page { self.pet.geniePage = (image, page) }
            self.geniePageReady = true
            if opening { self.showChat() } else { self.collapseChat() }
        }
        page.takeSnapshot(with: nil) { image, _ in complete(image) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { complete(nil) }
        return true
    }
    private var pendingBubbleLink: URL?
    /// Opening a page changes the window width, so wait until unfolding has finished its layout.
    private func finishBubbleLink() {
        guard pendingBubbleLink != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.chatExpanded, self.perchTransition == nil, !self.geniePreparing,
                  let url = self.pendingBubbleLink else { return }
            self.pendingBubbleLink = nil
            self.openLink(url)
        }
    }
    private var reopeningProgress: CGFloat?
    @objc func showChat() {
        if !IMessageFeature.enabled { slack.model.source = .slack; chat.closeSearch(); chat.needsAutomation = false }
        geniePageGeneration += 1
        guard !chatExpanded else { panel.makeKeyAndOrderFront(nil); return }
        if !geniePageReady { startGenieTrace(opening: true) }
        defer { genieTrace?.inputFinished = ProcessInfo.processInfo.systemUptime }
        if prepareGeniePage(opening:true) { return }
        geniePreparing = true
        let reopeningAnchor = foldedPerchAnchor
        foldedPerchAnchor = nil
        // Entry now chooses the newest conversation, so a picture of the old reading position is stale.
        reopeningProgress = perchTransition != nil && pet.genieActive ? pet.genieProgress : nil
        if pet.genieActive { pet.endGenie() }
        pet.invalidateGeniePicture()
        pageGeneration += 1; chat.loadingOlder = false; chat.resetPage()
        genieWork("publishChat") { publishChat() }
        bubbleMotion.glide(now: ProcessInfo.processInfo.systemUptime)
        chatExpanded = true; pet.chatExpanded = true; panel.chatExpanded = true
        // A plain opening starts at the newest line. A bubble or link below can still choose its own target.
        chat.expanded = true; slack.chatOpen = true
        // Opening from a bubble lands on the conversation the bubble was about.
        if let shown = nudges.current?.message {
            // With ddots on and Slack connected there is no iMessage side to go to; the window opens where it was.
            if shown.id.hasPrefix("slack:") { slack.reveal(shown.id) } else if IMessageFeature.enabled && !ddotsOnly { slack.model.source = .imessage }
        }
        nudges.dismiss(); updatePet()
        if let anchor = placementTarget?.anchorOrigin { placePet(at: anchor) } else { constrainPosition() }
        if let reopeningAnchor { resizedBelow = true; placePet(at:reopeningAnchor) }
        if let target = placementTarget { beginPerchTransition(opening:true,placement:target) }
        genieWork("makeKey") { panel.makeKeyAndOrderFront(nil) }
        updateUnread([])
        installOutsideClickMonitors()
        // Reduced motion has no transition-completion tick to restore the input focus.
        if perchTransition == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.chatExpanded else { return }
                self.chat.focusDraftRevision += 1
                self.finishBubbleLink()
            }
        }
    }
    func installOutsideClickMonitors() {
        removeOutsideClickMonitors()
        // Only ddots' own windows are watched. Double clicks in other apps or on the desktop leave the conversation alone.
        outsideLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleOutsideClick(event)
            return event
        }
    }
    func handleOutsideClick(_ event: NSEvent) {
        guard event.type == .leftMouseDown, event.clickCount >= 2 else { return }
        // Choosing files happens in another window; the conversation stays open behind it.
        guard chatExpanded, let window = event.window, window !== panel, !slack.picking, !web.presenting else { return }
        collapseChat()
    }
    func removeOutsideClickMonitors() {
        if let monitor = outsideLocalMonitor { NSEvent.removeMonitor(monitor) }
        outsideLocalMonitor = nil
    }
    func collapseChat() {
        pendingBubbleLink = nil
        geniePageGeneration += 1
        guard chatExpanded else { return }
        reopeningProgress = nil
        finishWidthSlide()
        if !geniePageReady { startGenieTrace(opening: false) }
        defer { genieTrace?.inputFinished = ProcessInfo.processInfo.systemUptime }
        if prepareGeniePage(opening:false) { return }
        geniePreparing = true
        endChatDrag()
        removeOutsideClickMonitors()
        resizeWork?.cancel(); resizeWork = nil; pendingResize = nil
        slack.model.endRowResize()
        resizingChat = false; slack.model.measuringResize = false; resizedBelow = nil; endPetDrag()
        guard chatExpanded else { return }
        let closingPlacement = placementTarget
        if let closingPlacement, !pet.genieActive { pet.captureGenie(size:closingPlacement.globalBubble.size) }
        foldedPerchAnchor = closingPlacement.flatMap { $0.effectiveScale < pet.petScale ? $0.anchorOrigin : nil }
        pageGeneration += 1; chat.closeSearch(); chat.loadingOlder = false
        genieWork("foldAll") { slack.model.foldAll(animated: false) }
        bubbleMotion.glide(now: ProcessInfo.processInfo.systemUptime)
        chatExpanded = false; chat.expanded = false; pet.chatExpanded = false; slack.chatOpen = false; pet.chatWidthFollowsGlass = false
        panel.makeFirstResponder(nil); panel.resignKey(); panel.chatExpanded = false
        updatePet()
        if let anchor = placementTarget?.anchorOrigin { placePet(at: anchor) } else { constrainPosition() }
        if let closingPlacement { beginPerchTransition(opening:false,placement:closingPlacement) }
    }
    func beginPerchTransition(opening: Bool, placement: PetPlacement) {
        genieTrace?.size = placement.globalBubble.size
        guard !pet.resting, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !CommandLine.arguments.contains("--ui-smoke-reduce-motion") else {
            perchTransition = nil; geniePreparing = false
            pet.finishMorph(); advancePlacement()
            finishGenieTrace()
            return
        }
        let continuing = perchTransition != nil && pet.genieActive
        if continuing { genieTrace?.path = "reused" }
        genieStartProgress = opening ? (reopeningProgress ?? (continuing ? pet.genieProgress : 0)) : (continuing ? pet.genieProgress : 1)
        reopeningProgress = nil
        if !pet.genieActive { pet.captureGenie(size:placement.globalBubble.size, opening:opening) }
        // Hold the initial picture until the input turn (including SwiftUI updates) finishes.
        perchAwaitingTick = true; perchUsesTimer = false
        perchArmedAt = ProcessInfo.processInfo.systemUptime
        perchTransition = (.infinity,opening,placement)
        geniePreparing = false
        let trace = motionTrace, telemetry = genieTrace; motionTrace = nil; genieTrace = nil
        let geometryBegan = ProcessInfo.processInfo.systemUptime
        advancePlacement()
        telemetry?.layoutMS += (ProcessInfo.processInfo.systemUptime - geometryBegan) * 1000
        motionTrace = trace; genieTrace = telemetry
        telemetry?.observeSprite(pet.spriteDrawnScreenRect, backing: panel.backingScaleFactor)
        pet.startWidthClock()
    }
    private func genieWork(_ name: String, _ work: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        work()
        genieTrace?.workMS[name, default: 0] += (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    /// Uses another Mac's relayed record when one is configured, otherwise this Mac's own.
    func connectHermesSource() {
        let defaults = UserDefaults.standard
        var source: HermesSource = HermesBridge(); var remote: RemoteHermes?
        if let host = defaults.string(forKey: RelaySettings.hostKey).flatMap(RelaySettings.validHost),
           let token = RelaySettings.readToken(RelaySettings.clientTokenURL) {
            let client = RemoteHermes(host: host, port: RelaySettings.port, token: token, portraits: relayPortraits, includeMessages: IMessageFeature.enabled)
            client.onChange = { [weak self] in DispatchQueue.main.async { self?.refresh() } }
            source = client; remote = client
        }
        let old = remoteHermes
        replaceHermesSource(source)
        remoteHermes = remote
        old?.stop()
        if hermesEnabled { remote?.start() }
    }
    /// Sources are selected on the main thread and captured by each background request, so switching never waits for I/O.
    func replaceHermesSource(_ source: HermesSource) {
        hermesRevision += 1; hermes = source
        localHermesFound = false
        searchGeneration += 1; pageGeneration += 1
        searchWork?.cancel(); searchWork = nil
        chat.closeSearch(); chat.results = []; chat.searching = false; chat.loadingOlder = false
        pendingMessages = []; nudges.dismiss()
        applyChat(nil); chat.resetPage(); updatePet()
    }
    @objc func configureRelay() {
        let alert = NSAlert()
        alert.messageText = "다른 Mac과 캐릭터 공유"
        let loaded = RelayAgent.isLoaded
        let address = RelaySettings.tailnetAddress()
        var lines = ["이 Mac의 Hermes 캐릭터 이름·사진을 Tailscale로 연결된 내 다른 Mac의 ddots에 공유합니다. 받는 ddots는 대화 메시지를 표시하지 않습니다. 읽기 전용이며 연결 코드를 아는 Mac만 받을 수 있습니다. 펫을 종료해도 공유는 계속됩니다.", ""]
        lines.append(loaded ? "상태: 공유 중" : "상태: 꺼짐")
        lines.append(address.map { "주소: \($0) · 포트 \(RelaySettings.port)" } ?? "주소: Tailscale 주소를 찾지 못했어요. Tailscale을 켜 주세요.")
        if !LoginLaunch.isInstalled() { lines.append("응용 프로그램 폴더에 설치한 뒤 켤 수 있어요.") }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: loaded ? "공유 끄기" : "공유 켜기")
        if loaded { alert.addButton(withTitle: "연결 코드 복사") }
        alert.addButton(withTitle: "닫기")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            do { try RelayAgent.setEnabled(!loaded) }
            catch {
                let failure = NSAlert(); failure.messageText = "공유 설정을 바꾸지 못했어요"; failure.informativeText = error.localizedDescription
                failure.runModal(); return
            }
            if !loaded { configureRelay() }
        } else if loaded, choice == .alertSecondButtonReturn, let token = RelaySettings.readToken(RelaySettings.serverTokenURL) {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string)
        }
    }
    private func confirmForgetRelay(_ host: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "다른 Mac 연결을 지울까요?"
        alert.informativeText = "Mac 이름이 비어 있습니다. 지우면 저장된 이름(\(host))과 연결 코드가 사라져 이 Mac의 기록만 읽으며, 다시 연결하려면 코드를 새로 입력해야 합니다."
        alert.addButton(withTitle: "연결 유지"); alert.addButton(withTitle: "지우기")
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc func configureHermes() {
        let alert = NSAlert()
        alert.messageText = "Hermes 연결"
        alert.informativeText = "슬랙에 Hermes 캐릭터 이름·사진·작성 중 표시를 붙입니다. Hermes 기록은 읽기만 합니다. 다른 Mac의 캐릭터를 받으려면 아래 Mac 이름과 연결 코드를 입력하세요."
        let location = NSTextField(wrappingLabelWithString: hermesLocationText())
        hermesLocationLabel = location
        defer { hermesLocationLabel = nil }
        let choose = NSButton(title: "폴더 직접 고르기", target: self, action: #selector(chooseHermesHome))
        let savedHost = UserDefaults.standard.string(forKey: RelaySettings.hostKey) ?? ""
        let hostField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        hostField.placeholderString = "공유하는 Mac의 Tailscale 이름 (선택)"; hostField.stringValue = savedHost
        hostField.setAccessibilityLabel("공유하는 Mac의 Tailscale 이름")
        let codeField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        codeField.placeholderString = savedHost.isEmpty ? "연결 코드 (선택)" : "연결 코드 (바꿀 때만 입력)"
        codeField.setAccessibilityLabel("연결 코드")
        let stack = NSStackView(views: [location, choose, hostField, codeField])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 144)
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: "연결"); alert.addButton(withTitle: "연결 끊기"); alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let hostInput = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if hostInput.isEmpty {
                // An emptied name would throw away the other Mac's name and code, so that is asked first.
                if savedHost.isEmpty || confirmForgetRelay(savedHost) {
                    UserDefaults.standard.removeObject(forKey: RelaySettings.hostKey)
                    try? FileManager.default.removeItem(at: RelaySettings.clientTokenURL)
                }
            } else if let host = RelaySettings.validHost(hostInput) {
                let typed = codeField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if let token = RelaySettings.validToken(typed), (try? RelaySettings.writeToken(token, to: RelaySettings.clientTokenURL)) != nil {
                    UserDefaults.standard.set(host, forKey: RelaySettings.hostKey)
                } else if typed.isEmpty, RelaySettings.readToken(RelaySettings.clientTokenURL) != nil {
                    UserDefaults.standard.set(host, forKey: RelaySettings.hostKey)
                } else { sendNotice = "연결 코드를 확인해 주세요. 공유하는 Mac에서 복사한 64자리 코드입니다." }
            } else { sendNotice = "Mac 이름 형식을 확인해 주세요." }
            UserDefaults.standard.set(true, forKey: "hermesChatEnabled")
            connectHermesSource()
        case .alertSecondButtonReturn:
            UserDefaults.standard.set(false, forKey: "hermesChatEnabled")
            remoteHermes?.stop()
            replaceHermesSource(HermesBridge())
            collapseChat(); pendingMessages = []; sendNotice = nil; applyChat(nil); updatePet()
        default: return
        }
        publishChat(); refresh()
    }
    private func hermesLocationText() -> String {
        HermesLocator.shared.locate().map { "찾은 위치: " + ($0.path as NSString).abbreviatingWithTildeInPath } ?? "이 Mac에서 Hermes 기록을 찾지 못했어요."
    }
    @objc private func chooseHermesHome() {
        guard !isSmoke else { return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.allowsMultipleSelection = false; picker.message = "Hermes 기록이 있는 폴더를 골라 주세요."
        guard picker.runModal() == .OK, let selected = picker.url,
              let root = HermesLocator.shared.normalize(selected.path) else { return }
        guard HermesLocator.shared.containsRecords(root) else {
            hermesLocationLabel?.stringValue = "이 폴더에서 Hermes 기록을 찾지 못했어요. 다른 폴더를 골라 주세요."; return
        }
        UserDefaults.standard.set(root.path, forKey: HermesLocator.homeKey)
        HermesLocator.shared.invalidate()
        hermesLocationLabel?.stringValue = hermesLocationText()
        connectHermesSource(); refresh()
    }
    @objc func togglePet() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func togglePause() {
        model.paused.toggle(); pet.isPaused = model.paused
        usage.tick(paused: model.paused, smoke: isSmoke)
        if !model.paused { refresh() }; updatePet()
    }
    @objc func showOptions() {
        if optionsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 712), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "ddots 옵션"; window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 712))
            let usageTitle = NSTextField(labelWithString: "사용량")
            usageTitle.font = .systemFont(ofSize: 14, weight: .semibold)
            usageTitle.frame = NSRect(x:24,y:669,width:312,height:24); content.addSubview(usageTitle)
            let paseoStatus = NSTextField(labelWithString: usage.paseoStatus)
            paseoStatus.font = .systemFont(ofSize:11); paseoStatus.textColor = .secondaryLabelColor
            paseoStatus.frame = NSRect(x:24,y:644,width:312,height:18); content.addSubview(paseoStatus)
            paseoStatusLabel = paseoStatus
            let opacityTitle = NSTextField(labelWithString: "대화창 불투명도")
            opacityTitle.font = .systemFont(ofSize: 14, weight: .semibold)
            opacityTitle.frame = NSRect(x: 24, y: 341, width: 200, height: 20); content.addSubview(opacityTitle)
            let opacityValue = NSTextField(labelWithString: "65%")
            opacityValue.alignment = .right; opacityValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            opacityValue.frame = NSRect(x: 254, y: 341, width: 82, height: 20); content.addSubview(opacityValue)
            let opacity = NSSlider(value: BubbleOpacity.defaultPercent, minValue: BubbleOpacity.range.lowerBound,
                                   maxValue: BubbleOpacity.range.upperBound, target: self, action: #selector(changeChatOpacity(_:)))
            opacity.frame = NSRect(x: 22, y: 304, width: 316, height: 26)
            opacity.isContinuous = true; opacity.setAccessibilityLabel("대화창 불투명도")
            opacity.toolTip = "55%부터 100%까지 · 낮출수록 배경이 더 비칩니다"
            content.addSubview(opacity)
            let opacityHint = NSTextField(labelWithString: "‘투명도 줄이기’가 켜져 있으면 항상 불투명하게 보입니다.")
            opacityHint.font = .systemFont(ofSize: 11); opacityHint.textColor = .secondaryLabelColor
            opacityHint.frame = NSRect(x: 24, y: 282, width: 312, height: 17); content.addSubview(opacityHint)
            opacitySlider = opacity; opacityValueLabel = opacityValue
            let nameLabel = NSTextField(labelWithString: "펫 이름")
            nameLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            nameLabel.frame = NSRect(x: 24, y: 241, width: 160, height: 20); content.addSubview(nameLabel)
            let nameField = NSTextField(string: model.identity.name)
            nameField.frame = NSRect(x: 24, y: 203, width: 220, height: 26)
            nameField.placeholderString = "펫 이름을 입력하세요"
            nameField.setAccessibilityLabel("펫 이름")
            nameField.target = self; nameField.action = #selector(savePetName)
            content.addSubview(nameField)
            let saveName = NSButton(title: "이름 저장", target: self, action: #selector(savePetName))
            saveName.bezelStyle = .rounded; saveName.frame = NSRect(x: 249, y: 200, width: 92, height: 32)
            content.addSubview(saveName)
            let nameHint = NSTextField(labelWithString: "1~20자 · 저장하면 모든 화면에 적용됩니다.")
            nameHint.font = .systemFont(ofSize: 11); nameHint.textColor = .secondaryLabelColor
            nameHint.frame = NSRect(x: 24, y: 175, width: 312, height: 17); content.addSubview(nameHint)
            petNameField = nameField; petNameHint = nameHint
            let title = NSTextField(labelWithString: "펫 크기")
            title.font = .systemFont(ofSize: 14, weight: .semibold)
            title.frame = NSRect(x: 24, y: 125, width: 160, height: 20); content.addSubview(title)
            let value = NSTextField(labelWithString: "100%")
            value.alignment = .right; value.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            value.frame = NSRect(x: 254, y: 125, width: 82, height: 20); content.addSubview(value)
            let slider = NSSlider(value: 100, minValue: 25, maxValue: 200, target: self, action: #selector(resizePet(_:)))
            slider.frame = NSRect(x: 22, y: 86, width: 316, height: 26)
            slider.isContinuous = true; slider.setAccessibilityLabel("펫 크기")
            slider.toolTip = "캐릭터만 25%부터 200%까지 조절 · 말풍선 크기는 고정"
            content.addSubview(slider)
            for (text, x) in [("25%", 24.0), ("200%", 294.0)] {
                let label = NSTextField(labelWithString: text); label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor; label.frame = NSRect(x: x, y: 65, width: 44, height: 16)
                content.addSubview(label)
            }
            let hint = NSTextField(labelWithString: "말풍선 크기는 그대로 유지됩니다.")
            hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 24, y: 26, width: 216, height: 17); content.addSubview(hint)
            let reset = NSButton(title: "기본 크기", target: self, action: #selector(resetPetSize))
            reset.bezelStyle = .rounded; reset.frame = NSRect(x: 247, y: 19, width: 94, height: 32)
            content.addSubview(reset)
            let resetChat = NSButton(title:"대화창 크기 초기화",target:self,action:#selector(resetChatSize))
            resetChat.bezelStyle = .rounded; resetChat.frame = NSRect(x:24,y:380,width:200,height:30)
            content.addSubview(resetChat)
            let login = NSButton(checkboxWithTitle: "로그인 시 실행", target: self, action: #selector(toggleLoginLaunch(_:)))
            login.frame = NSRect(x:24,y:510,width:312,height:24); content.addSubview(login)
            let loginStatus = NSTextField(wrappingLabelWithString: "")
            loginStatus.font = .systemFont(ofSize:11); loginStatus.textColor = .secondaryLabelColor
            loginStatus.frame = NSRect(x:24,y:460,width:312,height:44); content.addSubview(loginStatus)
            let loginSettings = NSButton(title:"로그인 항목 설정 열기",target:self,action:#selector(openLoginSettings))
            loginSettings.bezelStyle = .rounded; loginSettings.frame = NSRect(x:24,y:421,width:220,height:30)
            content.addSubview(loginSettings)
            loginCheckbox = login; loginStatusLabel = loginStatus; loginSettingsButton = loginSettings
            window.contentView = content; window.center()
            optionsWindow = window; sizeSlider = slider; sizeValueLabel = value
        }
        refreshLoginLaunch()
        paseoStatusLabel?.stringValue = usage.paseoStatus
        let opacityPercent = BubbleOpacity.load()
        opacitySlider?.doubleValue = opacityPercent; opacityValueLabel?.stringValue = "\(Int(opacityPercent))%"
        let percent = (pet.petScale * 100).rounded()
        sizeSlider?.doubleValue = percent; sizeValueLabel?.stringValue = "\(Int(percent))%"
        petNameField?.stringValue = model.identity.name
        petNameHint?.stringValue = "1~20자 · 저장하면 모든 화면에 적용됩니다."
        petNameHint?.textColor = .secondaryLabelColor
        NSApp.activate(ignoringOtherApps: true); optionsWindow?.makeKeyAndOrderFront(nil)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        refreshLoginLaunch()
        if !isSmoke { calendar.refresh(force: true) }
    }
    func refreshLoginLaunch() {
        let value = LoginLaunchPresentation.resolve(LoginLaunch.state, installed: LoginLaunch.isInstalled(), failed: loginChangeFailed)
        loginCheckbox?.state = value.checked ? .on : .off
        loginCheckbox?.isEnabled = value.canChange
        loginStatusLabel?.stringValue = value.message
        loginSettingsButton?.isHidden = !value.showsSettings
    }
    @objc func toggleLoginLaunch(_ sender: NSButton) {
        do { try LoginLaunch.setEnabled(sender.state == .on); loginChangeFailed = false }
        catch { loginChangeFailed = true }
        refreshLoginLaunch()
    }
    @objc func openLoginSettings() { LoginLaunch.openSettings() }
    @objc func savePetName() {
        guard let field = petNameField else { return }
        if let message = PetIdentity.validationMessage(for: field.stringValue) {
            petNameHint?.stringValue = message; petNameHint?.textColor = .systemRed; return
        }
        let identity = PetIdentity(name: PetIdentity.normalized(field.stringValue))
        identity.save(); model.identity = identity; pet.identity = identity
        field.stringValue = identity.name
        dashboard?.title = identity.dashboardTitle
        publishChat()
        if isPreview { updatePreviewSubtitle() }
        updatePet()
        petNameHint?.stringValue = "이름을 저장했어요. 모든 화면에 적용했습니다."
        petNameHint?.textColor = .secondaryLabelColor
    }
    @objc func changeChatOpacity(_ sender: NSSlider) {
        let percent = BubbleOpacity.clamped(sender.doubleValue)
        UserDefaults.standard.set(percent, forKey: BubbleOpacity.settingsKey)
        pet.chatOpacityPercent = percent; opacityValueLabel?.stringValue = "\(Int(percent))%"
    }
    @objc func resizePet(_ sender: NSSlider) { applyPetSize(sender.doubleValue) }
    @objc func resetPetSize() { applyPetSize(100) }
    func applyPetSize(_ value: Double) {
        perchTransition = nil; foldedPerchAnchor = nil
        let percent = min(200, max(25, value.isFinite ? value.rounded() : 100))
        let scale = CGFloat(percent) / 100
        let previous = panel.convertToScreen(pet.convert(pet.spriteRect, to: nil))
        pet.petScale = scale
        placePet(at: PetLayout.resizedSprite(previous,scale:scale).origin)
        sizeSlider?.doubleValue = percent; sizeValueLabel?.stringValue = "\(Int(percent))%"
        if !isSmoke { UserDefaults.standard.set(percent, forKey: "petScale") }
        constrainPosition(); savePosition()
    }
    @objc func resetPosition() {
        foldedPerchAnchor = nil
        guard let screen = NSScreen.main else { return }
        placePet(at: NSPoint(x: screen.visibleFrame.maxX - PetLayout(scale: pet.petScale).spriteSize.width - 30,
                            y: screen.visibleFrame.minY + 25))
        savePosition()
    }
    func restorePosition(from saved: [String:Double]? = nil) {
        let defaults = UserDefaults.standard
        func value(_ key: String) -> Double? {
            if let saved { return saved[key] }
            // Argument-domain numbers are strings. Honor smoke-only size overrides without saving settings.
            if isSmoke, key == "petScale", let text = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[key] as? String,
               let scale = Double(text), scale.isFinite { return scale }
            return defaults.object(forKey:key) as? Double
        }
        let requested = value("petScale") ?? 100
        let scale = min(200,max(25,requested.isFinite ? requested : 100))
        pet.petScale = CGFloat(scale/100)
        panel.setContentSize(PetLayout(scale:pet.petScale).windowSize)
        foldedPerchAnchor = nil
        if let x = value("petAnchorX") {
            let anchor = NSPoint(x:x,y:value("petAnchorY") ?? 0)
            placePet(at:anchor)
            let requested = CGRect(origin:anchor,size:PetLayout(scale:pet.petScale).spriteSize)
            if let screen = panel.screen, PetLayout.visibleSprite(in:requested).maxY > screen.frame.maxY {
                foldedPerchAnchor = anchor
            }
        } else if let x = value("petX") {
            panel.setFrameOrigin(NSPoint(x:x,y:value("petY") ?? 0)); constrainPosition()
        } else { resetPosition() }
    }
    func constrainPosition() {
        let cell = panel.convertToScreen(pet.convert(pet.spriteRect,to:nil))
        placePet(at:PetLayout.resizedSprite(cell,scale:pet.petScale).origin)
    }
    func placePet(at origin: NSPoint) {
        if SlackResizeSmoke.measuring { SlackResizeSmoke.places += 1; SlackResizeSmoke.placeCallers.append(Thread.callStackSymbols.dropFirst().prefix(7).joined(separator: "\n")) }
        guard chatDrag == nil else { return }
        let size = PetLayout(scale: pet.petScale).spriteSize
        let cell = CGRect(origin:origin,size:size), visible = PetLayout.visibleSprite(in:cell)
        let center = NSPoint(x:visible.midX,y:chatExpanded ? visible.minY : visible.midY)
        let screen = NSScreen.screens.min { a, b in
            func distance(_ frame: NSRect) -> CGFloat {
                let dx = max(0, max(frame.minX - center.x, center.x - frame.maxX))
                let dy = max(0, max(frame.minY - center.y, center.y - frame.maxY))
                return dx * dx + dy * dy
            }
            return distance(a.frame) < distance(b.frame)
        }
        guard let screen else { return }
        let split = paneSplit(on: screen)
        // Keep the fractional artwork anchor; only the enclosing window is aligned to backing pixels.
        let placement = PetPlacement(spriteOrigin: origin, scale: pet.petScale, visibleFrame: screen.visibleFrame, screenFrame: screen.frame, bubbleSize: bubbleSize, expanded: chatExpanded,
                                     preferredSize: CGSize(width: split.base, height: layoutChatSize.height), below: resizedBelow, trailing: split.pane, expandToFit: chat.replyExtraHeight > 0 || paneWanted > 0)
        placementTarget = placement
        if chatExpanded {
            // Bubbles keep the proportions of the conversation column, not of the window with its tab strip and page.
            let pane = max(0, placement.globalBubble.size.width - split.base)
            let column = placement.globalBubble.size.width - slackStrip - pane
            if widthSliding { widthLayout = (placement.globalBubble.size, pane, column) }
            else { applyWidthLayout(placement.globalBubble.size, pane: pane, column: column) }
        }
        bubbleMotion.retarget(placement.globalBubble.origin, visibleFrame: screen.visibleFrame,
                              now: ProcessInfo.processInfo.systemUptime,
                              immediately: resizingChat || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion"), size: placement.globalBubble.size, headerAtTop: placement.expanded && placement.bubbleBelow)
        advancePlacement()
    }
    var spriteProbe: ((String) -> Void)?
    func advancePlacement(displayTick: Bool = false) {
        let finishingSprite = pet.genieActive
        spriteProbe?(displayTick ? "display.before" : "advance.before")
        genieTrace?.observeSprite(pet.spriteDrawnScreenRect, backing: panel.backingScaleFactor)
        var finishedGenieMS: Double?
        defer {
            genieTrace?.observeSprite(pet.spriteDrawnScreenRect, backing: panel.backingScaleFactor)
            spriteProbe?(displayTick ? "display.after" : "advance.after")
            if let finishedGenieMS { finishGenieTrace(settleMS: finishedGenieMS) }
        }
        let began = StallTrace.now
        defer { StallTrace.shared.record("advancePlacement", since: began) }
        guard !widthPreparing && !geniePreparing else { return }
        let started = ProcessInfo.processInfo.systemUptime
        if displayTick, perchAwaitingTick, let transition = perchTransition {
            if transition.opening, !pet.prepareOpeningEntry(size: transition.placement.globalBubble.size) { return }
            perchAwaitingTick = false
            perchTransition = (started, transition.opening, transition.placement)
        }
        if let transition = perchTransition, transition.start.isFinite, started - transition.start < ChatMorph.genieDuration {
            genieTrace?.frames.append(started)
            if started > transition.start, genieTrace?.motionStarted == nil { genieTrace?.motionStarted = started }
        }
        let measured = widthSliding
        var moving = widthSliding || web.sliding || perchTransition != nil
        defer {
            if widthSliding { pet.updateWidthPicture(progress: bubbleMotion.widthProgress, fade: widthFadeStart.map { CGFloat((ProcessInfo.processInfo.systemUptime - $0) / ChatWidthSlide.fadeDuration) } ?? 0) }
            if moving && perchTransition?.start != .infinity { motionTrace?.sample(time: started, cost: ProcessInfo.processInfo.systemUptime - started, bubble: pet.placement?.globalBubble ?? .zero, layouts: pet.contentLayouts, filters: pet.filterApplications, page: web.current?.loadedView?.frame.size) }
            if measured { widthSample?(started, ProcessInfo.processInfo.systemUptime - started, bubbleMotion.size.width, bubbleMotion.widthProgress) } }
        guard let target = placementTarget else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var origin = bubbleMotion.step(now:now)
        if widthSliding {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") {
                if let screen = panel.screen { bubbleMotion.retarget(target.globalBubble.origin, visibleFrame: screen.visibleFrame, now: now, immediately: true, size: target.globalBubble.size, headerAtTop: target.expanded && target.bubbleBelow) }
                origin = bubbleMotion.position ?? origin
                finishWidthSlide()
            }
            if widthSliding, bubbleMotion.widthProgress >= 1 {
                if widthFadeStart == nil {
                    if paneLayoutDeferred { moving = false; settlePaneContent() }
                    widthFadeStart = ProcessInfo.processInfo.systemUptime
                }
                if web.sliding { moving = false }
                if now - widthFadeStart! >= ChatWidthSlide.fadeDuration { finishWidthSlide() }
            }
        }
        var drawnSprite = target.globalSprite
        if widthSliding, let start = paneStartingSprite {
            let p = bubbleMotion.widthProgress, eased = p * p * (3 - 2 * p)
            drawnSprite = CGRect(x: start.minX + (target.globalSprite.minX - start.minX) * eased,
                                 y: start.minY + (target.globalSprite.minY - start.minY) * eased,
                                 width: start.width + (target.globalSprite.width - start.width) * eased,
                                 height: start.height + (target.globalSprite.height - start.height) * eased)
        }
        var drawnBubble = NSRect(origin:origin,size:bubbleMotion.size)
        if let transition = perchTransition {
            let duration = ChatMorph.genieDuration
            let fraction = min(1,max(0,(now-transition.start)/duration))
            if fraction < 1 {
                drawnBubble = transition.placement.globalBubble
                drawnSprite = transition.placement.globalSprite
            } else {
                moving = false
                let settleBegan = ProcessInfo.processInfo.systemUptime
                perchTransition = nil
                pet.layoutSubtreeIfNeeded(); pet.displayIfNeeded()
                finishedGenieMS = (ProcessInfo.processInfo.systemUptime - settleBegan) * 1000
                if transition.opening { chat.focusDraftRevision += 1; finishBubbleLink() }
                if let screen = panel.screen {
                    bubbleMotion.retarget(target.globalBubble.origin,visibleFrame:screen.visibleFrame,now:now,
                                          immediately:true,size:target.globalBubble.size,headerAtTop:target.expanded && target.bubbleBelow)
                }
                drawnBubble = target.globalBubble
            }
            origin = drawnBubble.origin
        }
        pet.perched = (chatExpanded && target.bubbleBelow) || perchTransition != nil
        let placement = PetPlacement(globalSprite:drawnSprite,globalBubble:drawnBubble,
                                     userScale:pet.petScale,expanded:chatExpanded)
        if perchTransition != nil || origin != target.globalBubble.origin || bubbleMotion.size != target.globalBubble.size {
            if pet.placement?.globalSprite == target.globalSprite {
                transitionFrame = (transitionFrame ?? panel.frame).union(target.windowFrame).union(placement.windowFrame)
            } else { transitionFrame = nil }
        } else { transitionFrame = nil }
        let backing = panel.screen?.backingScaleFactor ?? panel.backingScaleFactor
        let frame = transitionFrame ?? placement.windowFrame
        let left = floor(frame.minX * backing) / backing, bottom = floor(frame.minY * backing) / backing
        let aligned = CGRect(x: left, y: bottom, width: ceil(frame.maxX * backing) / backing - left,
                             height: ceil(frame.maxY * backing) / backing - bottom)
        if let t = perchTransition {
            let r = t.placement.globalBubble.offsetBy(dx:-aligned.minX,dy:-aligned.minY)
            let foot = PetLayout.visibleSprite(in:t.placement.globalSprite)
            let aim = CGPoint(x:min(r.maxX,max(r.minX,foot.midX-aligned.minX)),y:t.placement.bubbleBelow ? r.maxY : r.minY)
            let fraction = CGFloat(min(1,max(0,(now-t.start)/ChatMorph.genieDuration)))
            pet.updateGenie(rect:r,target:aim,progress:ChatMorph.genieProgress(from:genieStartProgress,opening:t.opening,fraction:fraction),below:t.placement.bubbleBelow)
        }
        guard pet.placement?.windowFrame != aligned || pet.placement?.globalBubble != placement.globalBubble || pet.placement?.globalSprite != placement.globalSprite else {
            if pet.chatWidthFollowsGlass, bubbleMotion.size == target.globalBubble.size { pet.chatWidthFollowsGlass = false; pet.needsLayout = true }
            if perchTransition == nil, bubbleMotion.size == target.globalBubble.size {
                pet.finishMorph()
                // The page has finished sliding; one that slid away is let go.
                if !widthSliding {
                    if web.sliding { web.sliding = false }
                    if !web.open, !web.tabs.isEmpty { web.unload() }
                }
            }
            return
        }
        if let screen = panel.screen {
            panel.level = PetLayout.placementSprite(in:placement.globalSprite).maxY > screen.visibleFrame.maxY
                ? NSWindow.Level(rawValue:NSWindow.Level.mainMenu.rawValue+1) : .floating
        }
        // A reused picture has no synchronous capture pass to submit the sprite's new local position.
        // Hold the window update until its compensating layer geometry is submitted as well.
        let synchronizeSprite = (finishingSprite || pet.genieActive) && panel.frame != aligned
        if synchronizeSprite {
            panel.disableScreenUpdatesUntilFlush()
            CATransaction.begin(); CATransaction.setDisableActions(true)
        }
        // Move the window and redraw its contents together, using the frame AppKit actually applied.
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0; context.allowsImplicitAnimation = false
            pet.placement = PetPlacement(globalSprite: placement.globalSprite, globalBubble: placement.globalBubble, windowFrame: aligned,userScale:pet.petScale,expanded:chatExpanded)
            if panel.frame != aligned {
                if SlackResizeSmoke.measuring { SlackResizeSmoke.frames += 1 }
                panel.setFrame(aligned, display: !pet.genieActive && (!resizingChat || SlackResizeSmoke.without("deferred-display")))
            }
            if panel.frame != aligned {
                pet.placement = PetPlacement(globalSprite: placement.globalSprite, globalBubble: placement.globalBubble, windowFrame: panel.frame,userScale:pet.petScale,expanded:chatExpanded)
            }
            // Finish geometry in this turn; let the normal display pass paint the latest drag size.
            pet.layoutSubtreeIfNeeded()
            if (!resizingChat && !widthSliding && perchTransition == nil) || SlackResizeSmoke.without("deferred-display") { pet.displayIfNeeded() }
        }, completionHandler: nil)
        if synchronizeSprite { CATransaction.commit(); CATransaction.flush() }
    }
    func movePet(to origin: CGPoint) {
        paneSizeAnchor = nil; paneSizeBelow = nil; replySizeAnchor = nil
        finishWidthSlide()
        perchTransition = nil; foldedPerchAnchor = nil
        if chatExpanded, petDragBottom == nil, let target = placementTarget, target.bubbleBelow { petDragBottom = target.globalBubble.minY }
        resizedBelow = chatExpanded ? true : nil
        if chatExpanded, let petDragBottom { carryChatHeight(origin, bottom: petDragBottom) }
        placePet(at: origin)
    }
    /// The pet carried with the conversation under it keeps the conversation's bottom edge where it was.
    private func carryChatHeight(_ origin: CGPoint, bottom: CGFloat) {
        guard let screen = panel.screen else { return }
        let cell = CGRect(origin: origin, size: PetLayout(scale: pet.petScale).spriteSize)
        let height = PetLayout.carriedChatHeight(foot: PetLayout.visibleSprite(in: cell).minY, bottom: bottom,
                                                 visibleFrame: screen.visibleFrame, screenFrame: screen.frame)
        guard abs(height - layoutChatSize.height) > 0.5 else { return }
        slack.model.pageHold = nil; replySizeAnchor = nil
        chat.acceptManualReplySize()
        slack.model.focusThread = nil
        if paneWanted > 0 { savedPaneHeight = height } else { preferredChatSize.height = height }
    }
    func endPetDrag() {
        guard petDragBottom != nil else { return }
        petDragBottom = nil
        saveChatSize(); savePaneSize()
    }
    func beginChatDrag(at point: CGPoint) {
        finishWidthSlide()
        guard chatExpanded, !resizingChat, chatDrag == nil,
              let target = placementTarget, let screen = panel.screen else { return }
        perchTransition = nil
        // Finish an in-flight opening/size transition once, before capturing the drag anchor.
        applyChatDragPlacement(target, screen: screen)
        pet.finishMorph()
        chatDrag = (point, target)
        resizedBelow = target.bubbleBelow
    }
    func moveChatDrag(to point: CGPoint) {
        guard let drag = chatDrag else { return }
        // Use the pointer, not the constrained pet, so a pair can cross display boundaries.
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? panel.screen
        guard let screen else { return }
        let delta = CGPoint(x: point.x-drag.point.x, y: point.y-drag.point.y)
        if delta != .zero { paneSizeAnchor = nil; paneSizeBelow = nil; replySizeAnchor = nil }
        let placement = drag.placement.dragged(by: delta, visibleFrame: screen.visibleFrame, screenFrame: screen.frame)
        resizedBelow = placement.bubbleBelow
        applyChatDragPlacement(placement, screen: screen)
    }
    private func applyChatDragPlacement(_ placement: PetPlacement, screen: NSScreen) {
        placementTarget = placement
        pet.chatSize = placement.globalBubble.size
        let column = max(0, pet.chatSize.width-slackStrip-web.width)
        if chat.viewportWidth != column { chat.viewportWidth = column }
        pet.chatWidthFollowsGlass = false
        bubbleMotion.retarget(placement.globalBubble.origin, visibleFrame: screen.visibleFrame,
                              now: ProcessInfo.processInfo.systemUptime, immediately: true, size: placement.globalBubble.size, headerAtTop: placement.expanded && placement.bubbleBelow)
        advancePlacement()
    }
    func endChatDrag() {
        guard chatDrag != nil else { return }
        chatDrag = nil
        savePosition()
    }
    func savePosition() {
        let cell = panel.convertToScreen(pet.convert(pet.spriteRect,to:nil))
        let origin = foldedPerchAnchor ?? PetLayout.resizedSprite(cell,scale:pet.petScale).origin
        let place = ["petX": Double(panel.frame.minX), "petY": Double(panel.frame.minY), "petAnchorX": Double(origin.x), "petAnchorY": Double(origin.y)]
        // A check run shares the installed app's settings, and one that stopped halfway would leave the pet's place
        // changed for it. So a check keeps the place to itself.
        if isSmoke { smokePosition = place; return }
        for (key, value) in place { UserDefaults.standard.set(value, forKey: key) }
    }
    @objc func screensChanged() { perchTransition = nil; foldedPerchAnchor = nil; endChatDrag(); resizedBelow = nil; constrainPosition() }
    @objc func preview() {
        previewTimer?.invalidate(); isPreview = true; pet.previewLook = false
        let names = PetAnimation.allCases.map(\.name) + ["방향 보기 1", "방향 보기 2", "조는 중"]
        updatePreviewSubtitle()
        func show(_ row: Int) {
            guard row < names.count else { isPreview = false; pet.previewRow = nil; updatePet(); return }
            pet.previewRow = row; pet.headline = "미리보기 · \(names[row])"
            // Nodding off takes longer than the others to play through once.
            let seconds = row == PetAnimationTimeline.dozeRow ? PetAnimationTimeline.dozeCycle : 2
            previewTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in show(row + 1) }
        }
        show(0)
    }
    @objc func previewPointer() {
        previewTimer?.invalidate(); isPreview = true; pet.previewRow = nil; pet.previewLook = true
        pet.state = .idle; pet.headline = "미리보기 · 마우스 바라보기"
        updatePreviewSubtitle()
        previewTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.pet.previewLook = false; self?.isPreview = false; self?.updatePet()
        }
    }
    private func updatePreviewSubtitle() {
        pet.subtitle = pet.previewLook ? "\(model.identity.name) · 포인터를 움직여 보세요" : "\(model.identity.name)의 동작 · 실제 작업과 별개"
    }
    @objc func showHooksHelp() {
        let alert = NSAlert()
        alert.messageText = "승인 대기 알림 연결"
        alert.informativeText = "기본 연결은 Codex와 Claude Code의 로컬 작업 기록을 읽습니다. 승인 대기를 정확히 알리려면 공식 훅을 추가하세요. 앱에 포함된 연결 안내에서 적용할 설정을 먼저 확인할 수 있습니다."
        alert.addButton(withTitle: "연결 안내 열기"); alert.addButton(withTitle: "닫기")
        if alert.runModal() == .alertFirstButtonReturn, let url = Bundle.main.url(forResource: "연결안내", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
    @objc func quit() { NSApp.terminate(nil) }

    /// UI smoke uses synthetic messages only. Exercise the same panel and view lifetime as a real click.
    func verifyChatInteraction(destination: URL) {
        if !IMessageFeature.enabled { verifySlackOnlyChat(destination: destination); return }
        verifyPetEdges(destination: destination)
        // The Slack side has scroll views of its own, so ask for the one the conversation registered.
        guard let scroll = chat.scrollView, let document = scroll.documentView else {
            smokeFailed("Conversation scroll view missing")
        }
        smokeCheck(chat.didInitialScroll && chat.messages.last?.id == storedMessages.last?.id)
        let remaining = document.bounds.maxY - scroll.contentView.bounds.maxY
        try? "bottom gap: \(remaining), active: \(chat.entryViewportActive), pending: \(chat.entryViewportPending), scroll: \(scroll.contentView.bounds), document: \(document.bounds), openingPending: \(pet.openingEntryPending)\n\(chat.entryViewportDiagnostic)\n".write(to:destination.appendingPathComponent("first-open.txt"),atomically:true,encoding:.utf8)
        smokeCheck(remaining < 2,"First opening shows the last message in the viewport")
        smokeCheck(panel.canBecomeKey && !panel.canBecomeMain)
        func command(_ key: String, code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:.command,timestamp:0,windowNumber:panel.windowNumber,context:nil,characters:key,charactersIgnoringModifiers:key,isARepeat:false,keyCode:code)!
        }
        smokeCheck(PetPanel.editAction(for: command("c", code: 8)) == #selector(NSText.copy(_:)) && PetPanel.editAction(for: command("v", code: 9)) == #selector(NSText.paste(_:)), "Copy and paste shortcuts are routed")
        smokeCheck(PetPanel.editAction(for: command("ㅊ", code: 8)) == #selector(NSText.copy(_:)) && PetPanel.editAction(for: command("ㅍ", code: 9)) == #selector(NSText.paste(_:)), "Shortcuts work while typing Korean")
        // Nothing is focused in a window that is not key, which happens when another app keeps the focus during the run.
        smokeCheck(!panel.isKeyWindow || panel.performKeyEquivalent(with: command("a", code: 0)), "Select All reaches the focused text")
        let bubble = pet.placement!.bubbleRect
        smokeCheck(pet.hitTest(NSPoint(x: bubble.midX, y: bubble.midY)) !== pet, "Conversation receives clicks")
        chat.userScrollGeneration += 1
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height / 3))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin
        let draft = chat.draft
        func mouse(_ type: NSEvent.EventType, point: NSPoint, window: NSWindow, clicks: Int = 1) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
        }
        let inside = pet.convert(NSPoint(x: bubble.midX, y: bubble.midY), to: nil)
        let frame = panel.frame
        pet.mouseDown(with: mouse(.leftMouseDown, point: inside, window: panel))
        pet.mouseUp(with: mouse(.leftMouseUp, point: inside, window: panel))
        smokeCheck(chatExpanded, "Conversation background click keeps it open")
        pet.mouseDown(with: mouse(.leftMouseDown, point: inside, window: panel))
        pet.mouseDragged(with: mouse(.leftMouseDragged, point: NSPoint(x: inside.x + 15, y: inside.y + 15), window: panel))
        pet.mouseUp(with: mouse(.leftMouseUp, point: inside, window: panel))
        smokeCheck(chatExpanded && panel.frame == frame, "Conversation background drag does not move the pet")
        handleOutsideClick(mouse(.leftMouseDown, point: inside, window: panel))
        smokeCheck(chatExpanded, "Local monitor preserves clicks in the pet panel")
        smokeCheck(outsideLocalMonitor != nil, "Open chat watches ddots' own windows")
        dashboard?.makeKeyAndOrderFront(nil)
        // Post through AppKit's event loop so the registered local monitor actually receives it.
        func post(_ window: NSWindow, clicks: Int) {
            NSApp.postEvent(mouse(.leftMouseDown, point: NSPoint(x: 4, y: 4), window: window, clicks: clicks), atStart: false)
            NSApp.postEvent(mouse(.leftMouseUp, point: NSPoint(x: 4, y: 4), window: window, clicks: clicks), atStart: false)
        }
        post(dashboard!, clicks: 1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
            smokeCheck(chatExpanded, "Other window single click keeps the conversation open")
            handleOutsideClick(mouse(.rightMouseDown, point: .zero, window: dashboard!, clicks: 2))
            smokeCheck(chatExpanded, "Other window right click keeps the conversation open")
            // A click with no ddots window is what another app or the desktop would look like.
            let windowless = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1)!
            smokeCheck(windowless.window == nil, "Synthetic outside click has no window")
            handleOutsideClick(windowless)
            smokeCheck(chatExpanded, "Double click without a ddots window keeps the conversation open")
            handleOutsideClick(mouse(.leftMouseDown, point: inside, window: panel, clicks: 2))
            smokeCheck(chatExpanded, "Double click in the pet panel keeps the conversation open")
            slack.picking = true
            handleOutsideClick(mouse(.leftMouseDown, point: .zero, window: dashboard!, clicks: 2))
            slack.picking = false
            smokeCheck(chatExpanded, "Double click while choosing files keeps the conversation open")
            post(dashboard!, clicks: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                smokeCheck(!chatExpanded && !panel.canBecomeKey && chat.draft == draft, "Other ddots window double click collapses the conversation")
                smokeCheck(outsideLocalMonitor == nil, "Collapsed chat removes the monitor")
                capture(destination: destination.appendingPathComponent("collapsed"))
                func clickPet(_ count: Int) {
                    let sprite = pet.spriteRect
                    let point = pet.convert(NSPoint(x: sprite.midX, y: sprite.midY), to: nil)
                    pet.mouseDown(with: mouse(.leftMouseDown, point: point, window: panel, clicks: count))
                    pet.mouseUp(with: mouse(.leftMouseUp, point: point, window: panel, clicks: count))
                }
                showChat(); clickPet(1)
                smokeCheck(!chatExpanded, "Character single click collapses the open conversation")
                clickPet(2)
                smokeCheck(!chatExpanded, "The second click of a double click does not open it again")
                clickPet(1)
                smokeCheck(chatExpanded, "Character single click opens the closed conversation")
                clickPet(2)
                smokeCheck(chatExpanded, "The second click of a double click does not fold it again")
                _ = pet.accessibilityPerformPress()
                smokeCheck(!chatExpanded, "Accessibility press still collapses the conversation")
                _ = pet.accessibilityPerformPress()
                smokeCheck(chatExpanded, "Accessibility press still opens the conversation")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                    let diagnostic = "draft=\(chat.draft == draft), scrollBefore=\(offset), scrollAfter=\(scroll.contentView.bounds.origin), key=\(panel.canBecomeKey)\n"
                    try? diagnostic.write(to: destination.appendingPathComponent("interaction-debug.txt"), atomically: true, encoding: .utf8)
                    smokeCheck(chat.draft == draft, "Draft survives folding")
                    smokeCheck(document.bounds.maxY - scroll.contentView.bounds.maxY < 2, "Reopening shows the latest conversation")
                    smokeCheck(panel.canBecomeKey)
                    if let editor = panel.firstResponder as? NSTextView {
                        try? "selection=\(editor.selectedRange()), length=\((editor.string as NSString).length), key=\(panel.isKeyWindow)\n".write(to:destination.appendingPathComponent("caret.txt"),atomically:true,encoding:.utf8)
                        smokeCheck(editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0), "Reopening keeps the caret after the draft")
                    }
                    capture(destination: destination.appendingPathComponent("reopened"))
                    verifyEditKeys(destination: destination) { [self] in verifyChatSearch(destination:destination,draft:draft) }
                }
            }
        }
    }

    func capture(destination: URL) {
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var views = [(chatExpanded ? "chat" : "pet", pet as NSView), ("dashboard", dashboard!.contentView!)]
        if isSmoke, CommandLine.arguments.contains("--ui-smoke-options"), let frame = optionsWindow?.contentView?.superview { views.append(("options", frame)) }
        pet.prepareGenieCapture(true)
        defer { pet.prepareGenieCapture(false) }
        for (name, view) in views {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("\(name).png"))
        }
        if let snapshot = currentSnapshot {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try? encoder.encode(snapshot).write(to: destination.appendingPathComponent("snapshot.json"))
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// The pet and pause lines say the one thing they will do now.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        petMenuItem?.title = panel.isVisible ? "펫 숨기기" : "펫 보이기"
        pauseMenuItem?.title = model.paused ? "다시 시작" : "잠시 쉬기"
        // The vault belongs to 새우튀김; an organization without one (the public edition) has no such menu.
        vaultMenuItem?.isHidden = ShrimpVault.defaultBot.isEmpty
    }
}
