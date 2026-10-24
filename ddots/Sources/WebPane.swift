import SwiftUI
import WebKit

/// One page open beside the conversation.
final class WebTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    private(set) var loadedView: WKWebView?
    var pendingURL: URL?
    var picture: WebPicture?
    var revealPreview: WebPicture?
    var revealPending = false, revealCount = 0
    /// What the page picture and its reveal did, with times, kept for the UI checks' failure reports only.
    static let tracesReveal = CommandLine.arguments.contains("--ui-smoke")
    private(set) var revealTrace: [String] = []
    func traceReveal(_ event: @autoclosure () -> String) {
        guard Self.tracesReveal else { return }
        revealTrace.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + event())
    }
    var onPicture: ((WebPicture) -> Void)?
    var allowsPicture: () -> Bool = { true }
    private var pictureWork: DispatchWorkItem?
    private var pictureRevision = 0
    private var pictureBusy = false
    private(set) var snapshotMS = 0.0
    func invalidatePicture() { pictureRevision += 1; pictureWork?.cancel(); pictureWork = nil; picture = nil }
    func discardPicture() { invalidatePicture(); revealPreview = nil; onPicture = nil }
    func schedulePicture(delay: Double = 0.5) {
        pictureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.takePicture() }
        pictureWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    func takePicture() {
        guard !pictureBusy, allowsPicture(), let page = loadedView, !page.isLoading,
              page.bounds.width > 1, page.bounds.height > 1 else {
            traceReveal("picture skipped busy=\(pictureBusy) allowed=\(allowsPicture()) loading=\(loadedView?.isLoading ?? true) size=\(loadedView?.bounds.size ?? .zero)")
            return
        }
        traceReveal("picture begun")
        pictureBusy = true
        let revision = pictureRevision, size = page.bounds.size, url = page.url
        let began = ProcessInfo.processInfo.systemUptime
        let config = WKSnapshotConfiguration(); config.snapshotWidth = NSNumber(value: Double(min(512, size.width * 0.5)))
        page.takeSnapshot(with: config) { [weak self, weak page] image, _ in
            guard let self else { return }
            guard self.pictureRevision == revision, page?.url == url, page?.bounds.size == size,
                  let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { self.traceReveal("snapshot dropped"); self.pictureBusy = false; return }
            self.traceReveal("snapshot taken")
            WebPicture.soften(image, size: size) { [weak self] picture in
                guard let self else { return }; self.pictureBusy = false
                guard self.pictureRevision == revision, page?.url == url, let picture else { return }
                self.snapshotMS = (ProcessInfo.processInfo.systemUptime-began)*1000
                self.traceReveal("picture ready, waiting=\(self.onPicture != nil)")
                self.picture = picture; self.onPicture?(picture)
            }
        }
    }
    private let configuration: () -> WKWebViewConfiguration
    private(set) var creationMS = 0.0
    lazy var view: WKWebView = makeView()
    @Published var title = ""
    @Published var url: URL?
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    /// What the address field says. It follows the page except while the user is typing in it.
    @Published var address = ""
    /// A saved file shown in place of a page on the web.
    var file: URL?
    var editing = false
    private var watches: [NSKeyValueObservation] = []

    init(configuration: @escaping () -> WKWebViewConfiguration) {
        self.configuration = configuration
        super.init()
    }
    private func makeView() -> WKWebView {
        let began = ProcessInfo.processInfo.systemUptime
        let view = PictureWebView(frame: .zero, configuration: configuration())
        view.onActivity = { [weak self] in self?.schedulePicture() }
        loadedView = view
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        view.setAccessibilityIdentifier("web-page")
        watches = [
            view.observe(\.title) { [weak self] view, _ in self?.title = view.title ?? "" },
            view.observe(\.url) { [weak self] view, _ in self?.follow(view.url) },
            view.observe(\.isLoading) { [weak self] view, _ in self?.loading = view.isLoading },
            view.observe(\.canGoBack) { [weak self] view, _ in self?.canGoBack = view.canGoBack },
            view.observe(\.canGoForward) { [weak self] view, _ in self?.canGoForward = view.canGoForward },
        ]
        creationMS = (ProcessInfo.processInfo.systemUptime-began)*1000
        return view
    }
    private func follow(_ url: URL?) {
        self.url = url
        if !editing { address = shownAddress }
    }
    var shownAddress: String {
        if let file { return file.lastPathComponent }
        guard let url, url.scheme != "about" else { return "" }
        return url.absoluteString
    }
    var label: String {
        if !title.isEmpty { return title }
        if let file { return file.lastPathComponent }
        return url?.host ?? "새 탭"
    }
}

/// The pages open at the conversation's right, as tabs. The window grows by the pane's width while it is open.
final class WebPaneModel: NSObject, ObservableObject {
    /// Moving the whole window from the empty part of the tab strip, as from the conversation's header.
    var onWindowDragBegan: ((CGPoint) -> Void)?
    var onWindowDragChanged: ((CGPoint) -> Void)?
    var onWindowDragEnded: (() -> Void)?
    @Published private(set) var tabs: [WebTab] = []
    @Published var selected: UUID? { didSet { if selected != oldValue { current?.schedulePicture() } } }
    @Published private(set) var open = false
    @Published var shrimpList = false
    @Published var shrimpCollapsed = false
    @Published var shrimpQuery = ""
    var shrimpSearchFocused = false
    func showShrimpList() {
        let response = StallTrace.shared.response("webOpen")
        defer { StallTrace.shared.finish(response) }
        shrimpQuery = ""; shrimpCollapsed = false; shrimpList = true; show()
    }
    func toggleShrimpList() {
        let response = StallTrace.shared.response(shrimpCollapsed ? "webOpen" : "webClose")
        defer { StallTrace.shared.finish(response) }
        shrimpCollapsed.toggle()
        if shrimpCollapsed { open = false; onLayout?() } else { show() }
    }
    /// The pane's width in the window as it is laid out now; 0 while closed or folded away.
    @Published var width: CGFloat = 0
    /// The width the page itself is drawn at, so it is uncovered as the window grows instead of being squeezed.
    @Published var layoutWidth = PetLayout.expandedSize.width
    /// True while the window is still easing to or from the pane's width.
    @Published var sliding = false
    @Published private(set) var ready = false
    private(set) var loadMS = 0.0
    @Published var notice: String?
    @Published var addressFocus = 0
    var addressFocused = false
    /// True while a sheet of the page's own (an alert, a file chooser) is up, so a click in it is not taken for one outside.
    private(set) var presenting = false
    /// Checks keep their pages to themselves: nothing is kept between runs and nothing reaches the user's downloads.
    var persistent = true
    var onLayout: (() -> Void)?
    private var recentlyClosed: (URL, WebPicture)?
    private var discardingTab = false
    private var keepClosingPicture = false
    var onExternal: (URL) -> Void = { NSWorkspace.shared.open($0) }
    static let tabLimit = 12
    private var downloads: [ObjectIdentifier: URL] = [:]
    /// A restart must not discard a web download or navigation/upload in progress.
    var updateHasTransfers: Bool { !downloads.isEmpty || tabs.contains { $0.loadedView?.isLoading == true } }
    private var noticeRevision = 0

    private lazy var configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistent ? .default() : .nonPersistent()
        // Sites sort browsers by this; without it some refuse to sign in or serve a reduced page.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return configuration
    }()

    var current: WebTab? { tabs.first { $0.id == selected } }

    /// Shows a page or a saved file. One already open is brought forward instead of being opened twice.
    func open(_ url: URL, ephemeral: Bool = false) {
        let response = StallTrace.shared.response("webOpen")
        defer { StallTrace.shared.finish(response) }
        shrimpList = false; shrimpCollapsed = false
        if !open { unload() }
        if let tab = tabs.first(where: { $0.file == url || ($0.file == nil && $0.url == url) }) { selected = tab.id }
        else {
            // Confidential attachments never share the ordinary tabs' persistent store.
            let temporary = ephemeral ? WKWebViewConfiguration() : nil
            temporary?.websiteDataStore = .nonPersistent()
            load(url, in: add(configuration: temporary))
        }
        show()
    }
    func newTab() {
        let response = StallTrace.shared.response("webOpen")
        defer { StallTrace.shared.finish(response) }
        shrimpList = false; shrimpCollapsed = false
        if !open { unload() }
        _ = add(); show()
        addressFocus += 1
    }
    func go(_ typed: String) {
        guard let tab = current, let url = WebAddress.destination(for: typed) else { return }
        tab.editing = false
        load(url, in: tab)
        tab.view.window?.makeFirstResponder(tab.view)
    }
    func close() {
        guard open || shrimpCollapsed else { return }
        let response = StallTrace.shared.response("webClose")
        defer { StallTrace.shared.finish(response) }
        if !discardingTab, let tab = current, let url = tab.file ?? tab.url, let picture = tab.picture { recentlyClosed = (url, picture) }
        keepClosingPicture = !discardingTab
        open = false; notice = nil; shrimpList = false; shrimpCollapsed = false
        onLayout?()
    }
    /// Closing the last tab closes the pane; the tab stays until the pane has slid away.
    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        if recentlyClosed?.0 == (tab.file ?? tab.url) { recentlyClosed = nil }
        tab.discardPicture()
        if tabs.count == 1 { discardingTab = true; close(); discardingTab = false; return }
        tabs[index].loadedView?.stopLoading()
        tabs.remove(at: index)
        if selected == id { selected = tabs[min(index, tabs.count - 1)].id }
    }
    /// Lets the pages go. Called once a closed pane is out of sight.
    func unload() {
        if shrimpCollapsed { return } // Folding the native list must not discard existing web tabs.
        if keepClosingPicture, !open, let tab = current, let url = tab.file ?? tab.url, let picture = tab.picture { recentlyClosed = (url, picture) }
        keepClosingPicture = false
        for tab in tabs { tab.discardPicture(); tab.loadedView?.stopLoading(); tab.loadedView?.navigationDelegate = nil; tab.loadedView?.uiDelegate = nil }
        ready = false
        tabs = []; selected = nil
    }
    func openOutside() {
        guard let tab = current else { return }
        guard let url = tab.file ?? tab.url.flatMap({ WebAddress.isWeb($0) ? $0 : nil }) else { return }
        onExternal(url)
        close()
    }

    /// True when the keyboard is in a page or in the address field.
    func hasFocus(in window: NSWindow?) -> Bool {
        guard open, width > 0 else { return false }
        if addressFocused || shrimpList && shrimpSearchFocused { return true }
        guard let responder = window?.firstResponder as? NSView else { return false }
        return tabs.contains { tab in tab.loadedView.map { responder === $0 || responder.isDescendant(of: $0) } ?? false }
    }
    /// The browser's usual shortcuts, by where the key sits so a Korean input source does not change them.
    func handleShortcut(_ event: NSEvent) -> Bool {
        guard !shrimpList else { return false }
        guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
        switch event.keyCode {
        case 13: if let selected { closeTab(selected) }
        case 17: newTab()
        case 37: addressFocus += 1
        case 15: current?.view.reload()
        case 33: current?.view.goBack()
        case 30: current?.view.goForward()
        default: return false
        }
        return true
    }

    private func show() {
        guard !open else { return }
        open = true
        onLayout?()
        if !sliding { finishTransition() }
    }
    func finishTransition() {
        guard open else { return }
        for tab in tabs {
            tab.view.navigationDelegate = self; tab.view.uiDelegate = self
            if let url = tab.pendingURL { tab.pendingURL = nil; loadNow(url, in: tab) }
        }
        ready = true
    }
    private func add(configuration: WKWebViewConfiguration? = nil) -> WebTab {
        let tab = WebTab(configuration: { [unowned self] in configuration ?? self.configuration })
        if ready { tab.view.navigationDelegate = self; tab.view.uiDelegate = self }
        tab.allowsPicture = { [weak self, weak tab] in (self?.sliding == false || tab?.onPicture != nil) && !ChatView.reducesMotionForChecks }
        tabs.append(tab); selected = tab.id
        // The oldest page makes room; the one just opened and the one before it are never the oldest.
        if tabs.count > Self.tabLimit { tabs[0].loadedView?.stopLoading(); tabs.removeFirst() }
        return tab
    }
    private func load(_ url: URL, in tab: WebTab) {
        tab.discardPicture()
        if let closed = recentlyClosed, closed.0 == url, closed.1.fresh { tab.picture = closed.1 }
        tab.revealPending = !ready && !ChatView.reducesMotionForChecks
        if !ready {
            tab.pendingURL = url; tab.file = url.isFileURL ? url : nil
            tab.url = url; tab.address = tab.shownAddress
            return
        }
        loadNow(url, in: tab)
    }
    private func loadNow(_ url: URL, in tab: WebTab) {
        let began = ProcessInfo.processInfo.systemUptime
        defer { loadMS = (ProcessInfo.processInfo.systemUptime-began)*1000 }
        notice = nil
        if url.isFileURL {
            tab.file = url; tab.address = tab.shownAddress
            // A text file carries no word on its encoding, and a guess turns Korean into noise.
            if WebAddress.isText(url), let data = try? Data(contentsOf: url) {
                tab.view.load(data, mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: URL(string: "about:blank")!)
            } else { tab.view.loadFileURL(url, allowingReadAccessTo: url) }
        } else {
            tab.file = nil
            tab.view.load(URLRequest(url: url))
        }
    }
    private func tab(for view: WKWebView) -> WebTab? { tabs.first { $0.loadedView === view } }
    private func say(_ text: String) {
        notice = text; noticeRevision += 1
        let revision = noticeRevision
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.noticeRevision == revision { self?.notice = nil }
        }
    }
    private func sheet<T>(_ body: () -> T) -> T {
        presenting = true; defer { presenting = false }
        return body()
    }
}

extension WebPaneModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let scheme = url.scheme?.lowercased() ?? ""
        let local = scheme == "file" && tab(for: webView)?.file != nil
        guard ["http", "https", "about", "blob", "data"].contains(scheme) || local else {
            // Another app's address is followed only when the user pressed it, never because a page asked.
            if action.navigationType == .linkActivated, scheme != "file" { onExternal(url) }
            decisionHandler(.cancel); return
        }
        if action.shouldPerformDownload { decisionHandler(.download); return }
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command), WebAddress.isWeb(url) {
            let chosen = selected
            load(url, in: add())
            if tabs.contains(where: { $0.id == chosen }) { selected = chosen }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let attached = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(response.isForMainFrame && (attached || !response.canShowMIMEType) ? .download : .allow)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        tab(for: webView)?.schedulePicture(delay: tab(for: webView)?.onPicture != nil ? 0 : 0.5)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { tab(for: webView)?.invalidatePicture(); if tab(for: webView)?.id == selected { notice = nil } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    private func failed(_ webView: WKWebView, _ error: Error) {
        let error = error as NSError
        // A page left before it finished, or one that turned into a download, did not fail.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return }
        if tab(for: webView)?.id == selected { say("페이지를 열지 못했어요. \(error.localizedDescription)") }
    }
}

extension WebPaneModel: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = persistent ? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
                                : FileManager.default.temporaryDirectory
        let target = WebAddress.downloadTarget(folder: folder, suggested: suggestedFilename) { FileManager.default.fileExists(atPath: $0.path) }
        downloads[ObjectIdentifier(download)] = target
        completionHandler(target)
    }
    func downloadDidFinish(_ download: WKDownload) {
        if let target = downloads.removeValue(forKey: ObjectIdentifier(download)) { say("다운로드 폴더에 저장했어요: \(target.lastPathComponent)") }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads[ObjectIdentifier(download)] = nil
        say("파일을 내려받지 못했어요. \(error.localizedDescription)")
    }
}

extension WebPaneModel: WKUIDelegate {
    /// A link that asks for a window of its own gets a tab. It has to be made from the configuration handed over,
    /// so the page that opened it can still reach it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let opener = tab(for: webView)
        let tab = add(configuration: configuration)
        // A saved page may lead to the saved page next to it; a page from the web never reaches a file.
        if opener?.file != nil, let url = action.request.url, url.isFileURL { tab.file = url }
        return tab.view
    }
    func webViewDidClose(_ webView: WKWebView) { if let tab = tab(for: webView) { closeTab(tab.id) } }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        _ = ask(message, from: frame, choice: false); completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(ask(message, from: frame, choice: true))
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard persistent else { completionHandler(nil); return }
        let panel = NSOpenPanel()
        // The conversation floats above ordinary windows, so the chooser has to float above it.
        panel.level = .modalPanel
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection; panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(sheet { panel.runModal() == .OK ? panel.urls : nil })
    }
    private func ask(_ message: String, from frame: WKFrameInfo, choice: Bool) -> Bool {
        guard persistent else { return false }
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host.isEmpty ? "이 페이지의 알림" : frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "확인")
        if choice { alert.addButton(withTitle: "취소") }
        alert.window.level = .modalPanel
        return sheet { alert.runModal() == .alertFirstButtonReturn }
    }
}

/// Holds whichever tab's page is chosen. The pages themselves live in the model, so changing tabs keeps each where it was.
struct WebSurface: NSViewRepresentable {
    let tab: WebTab
    func makeNSView(context: Context) -> WebPictureSurface { WebPictureSurface() }
    func updateNSView(_ holder: WebPictureSurface, context: Context) { holder.install(tab) }
}

struct WebPaneView: View {
    @ObservedObject var web: WebPaneModel
    static let barHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let tab = web.current {
                WebToolbar(web: web, tab: tab)
                Divider()
                if let notice = web.notice {
                    Label(notice, systemImage: "info.circle").font(.system(size: ChatMetrics.auxiliaryFont))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.primary.opacity(0.06))
                        .accessibilityIdentifier("web-notice")
                }
                if web.ready { WebSurface(tab: tab) } else { Spacer(minLength: 0) }
            } else { Spacer(minLength: 0) }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1) }
        .accessibilityIdentifier("web-pane")
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) { ForEach(web.tabs) { WebTabChip(web: web, tab: $0).id($0.id).anchorPreference(key: WebTabTargets.self, value: .bounds) { [$0] } } }
                }
                .onChange(of: web.selected) { id in if let id { withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id) } } }
            }
            Button { web.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("새 탭 (⌘T)").accessibilityLabel("새 탭").accessibilityIdentifier("web-new-tab")
                .anchorPreference(key: WebTabTargets.self, value: .bounds) { [$0] }
            Button { web.close() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(.borderless).help("웹 칸 닫기").accessibilityLabel("웹 칸 닫기").accessibilityIdentifier("web-close")
                .anchorPreference(key: WebTabTargets.self, value: .bounds) { [$0] }
        }
        .padding(.leading, 8).padding(.trailing, 14).frame(height: Self.barHeight)
        .overlayPreferenceValue(WebTabTargets.self) { anchors in
            GeometryReader { geometry in WebTabBlankRegion(web: web, occupied: anchors.map { geometry[$0] }) }
        }
    }
}

private struct WebTabChip: View {
    @ObservedObject var web: WebPaneModel
    @ObservedObject var tab: WebTab
    var body: some View {
        let chosen = web.selected == tab.id
        HStack(spacing: 4) {
            Button { web.selected = tab.id } label: {
                HStack(spacing: 5) {
                    if tab.loading { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12) }
                    else { Image(systemName: tab.file == nil ? "globe" : "doc").font(.system(size: 10)).frame(width: 12, height: 12) }
                    Text(tab.label).font(.system(size: ChatMetrics.auxiliaryFont, weight: chosen ? .semibold : .regular)).lineLimit(1)
                }.frame(maxWidth: 150, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help(tab.label).accessibilityLabel(tab.label + (chosen ? ", 선택됨" : ""))
            Button { web.closeTab(tab.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).opacity(0.7).help("탭 닫기 (⌘W)").accessibilityLabel("\(tab.label) 탭 닫기")
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(chosen ? 0.14 : 0.05)))
    }
}

private struct WebToolbar: View {
    @ObservedObject var web: WebPaneModel
    @ObservedObject var tab: WebTab
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Button { tab.view.goBack() } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless).disabled(!tab.canGoBack).help("뒤로 (⌘[)").accessibilityLabel("뒤로")
            Button { tab.view.goForward() } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless).disabled(!tab.canGoForward).help("앞으로 (⌘])").accessibilityLabel("앞으로")
            Button { if tab.loading { tab.view.stopLoading() } else { tab.view.reload() } } label: { Image(systemName: tab.loading ? "xmark" : "arrow.clockwise") }
                .buttonStyle(.borderless).help(tab.loading ? "멈추기" : "새로고침 (⌘R)").accessibilityLabel(tab.loading ? "멈추기" : "새로고침")
            TextField("주소 또는 검색어", text: $tab.address)
                .textFieldStyle(.plain).font(.system(size: ChatMetrics.auxiliaryFont + 1)).lineLimit(1).focused($focused)
                .onSubmit { web.go(tab.address) }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.07)))
                .accessibilityLabel("주소").accessibilityIdentifier("web-address")
            Button { web.openOutside() } label: { Image(systemName: "arrow.up.forward.square") }
                .buttonStyle(.borderless).disabled(tab.file == nil && !(tab.url.map(WebAddress.isWeb) ?? false))
                .help("밖에서 열고 칸 닫기").accessibilityLabel("밖에서 열고 칸 닫기").accessibilityIdentifier("web-open-outside")
        }
        .padding(.leading, 12).padding(.trailing, 14).frame(height: 36)
        .onChange(of: focused) { inside in
            web.addressFocused = inside; tab.editing = inside
            if !inside { tab.address = tab.shownAddress }
        }
        .onChange(of: web.addressFocus) { _ in focused = true }
        // A tab with nothing in it yet is waiting for an address.
        .onAppear { if tab.url == nil && tab.file == nil { DispatchQueue.main.async { focused = true } } }
        .onDisappear { web.addressFocused = false; tab.editing = false }
    }
}
