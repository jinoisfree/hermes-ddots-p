import AppKit
import SwiftUI
import QuickLookThumbnailing
import PDFKit

struct FileDropSuggestion: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var profile: String
    var confidence: Double = 1
    var instruction: String? = nil
}

/// The card owns the intake lifetime and the request generation, never the clipboard history.
final class FileDropCard: ObservableObject {
    @Published var visible = false
    @Published var dragging = false
    @Published var count = 0
    @Published var payload = FileDropIntake.Payload()
    @Published var proposals: [FileDropSuggestion] = []
    @Published var notice = ""
    @Published var status = ""
    @Published var editing = false
    @Published var draft = ""
    @Published var thumbnail: NSImage?
    @Published var fileDetails: [URL: String] = [:]
    @Published var confirmation: String?
    /// Where the proposals on screen came from: the engine's name, or "기본 제안이에요 · reason".
    @Published var origin = ""
    /// Why the last hand-over could not go out. Shown right above the buttons or the editor; empty when fine.
    @Published var problem = ""
    var enabled = true
    var request = UUID()
    var eventID = UUID().uuidString
    let intake: FileDropIntake
    var onGeometry: (() -> Void)?
    var onPayload: (() -> Void)?
    /// Returns false when the item could not go out; the card then keeps what the user typed and shows `problem`.
    var onSelect: ((FileDropSuggestion) -> Bool)?
    var onClose: (() -> Void)?
    var sending = false
    var onConfirm: ((Bool) -> Void)?
    var profileName: (String) -> String = { $0 == "app" ? "앱" : "에이전트" }
    var avatar: (String) -> ProfileAvatar? = { _ in nil }
    var cast: () -> FileDropCast = { FileDropCast() }
    var primaryProfile = ""
    var sensitive = false
    var signals = FileDropSignals()
    var summary = ""
    var outcomes: [String: String] = [:]
    var pasteboard: () -> NSPasteboard = { .general }
    var enrich: (inout FileDropSignals) -> Void = { _ in }
    typealias Engine = @MainActor (FileDropSignals, [URL]) async throws -> FileDropAnswer
    var engine: Engine = { _, _ in throw CocoaError(.featureUnsupported) }
    var onAnswer: ((Double, Bool) -> Void)?
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var analysisStarted: Double = 0
    private var droppedAt: Double?
    var readSignals: (FileDropIntake.Payload, FileDropSignals) -> FileDropSignals = { FileDropSignals.read($0, initial: $1) }
    static let footer: CGFloat = 56
    var size: CGSize {
        let rows = min(3, payload.files.count)
        let base: CGFloat = dragging ? 250 : payload.count == 0 ? 220 : (editing ? 264 : confirmation != nil ? 242 : 326) + CGFloat(rows) * 42
        return CGSize(width: 356, height: base + (notice.isEmpty ? 0 : 30) + (problem.isEmpty ? 0 : 30) + (origin.isEmpty ? 0 : 18) + (signals.works.isEmpty ? 0 : 20))
    }
    init(intake: FileDropIntake = FileDropIntake()) { self.intake = intake }
    func target(_ board: NSPasteboard) -> Bool {
        guard enabled, !sending else { return false }
        let count = FileDropIntake.count(board)
        guard count > 0 else { return false }
        self.count = count; dragging = true; visible = true; onGeometry?(); return true
    }
    func leave() {
        dragging = false
        if payload.count == 0 && !editing { visible = false }
        onGeometry?()
    }
    @discardableResult func receive(_ board: NSPasteboard, append: Bool = false) -> Bool {
        guard enabled, !sending else { return false }
        if FileDropIntake.concealed(board) {
            notice = "비밀번호 복사는 맡길 수 없어요"; visible = true; dragging = false; onGeometry?(); return false
        }
        if !append { close(notify: false) }
        visible = true; dragging = false; editing = false; status = "살펴보는 중"; onGeometry?()
        let generation = request
        let dropped = ProcessInfo.processInfo.systemUptime
        droppedAt = dropped; analysisStarted = dropped
        setAnalysisDeadline(dropped + FileDropTiming.legacySeconds)
        intake.read(board) { [weak self] incoming in
            guard let self, self.request == generation else { return }
            if append {
                let result = ClipboardAttachments.validate(self.payload.files + incoming.files, available: 10)
                self.payload.files = result.files
                self.payload.text = String((self.payload.text + "\n" + incoming.text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(100_000))
                self.payload.notice = result.notice ?? incoming.notice
            } else { self.payload = incoming }
            self.count = self.payload.count; self.notice = self.payload.notice
            self.loadThumbnail()
            if self.payload.count > 0 { self.analyze(); self.onPayload?() } else { self.status = "" }
            self.onGeometry?()
        }
        return true
    }
    func openText() {
        guard !sending else { return }
        close(notify: false); visible = true; editing = true; onGeometry?()
    }
    func submit() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = String(draft.prefix(100_000))
        if payload.count == 0 {
            draft = ""; editing = false
            payload.text = text; count = 1; status = "살펴보는 중"; analyze(); onPayload?()
        } else {
            // The editor and its text stay until the hand-over has really gone out; a failure only adds a reason.
            problem = ""
            if onSelect?(FileDropSuggestion(id: "opinion", label: text, profile: primaryProfile)) != true && problem.isEmpty { problem = "보낼 수 없어요" }
        }
        onGeometry?()
    }
    func escape() {
        if editing && payload.count > 0 { editing = false; onGeometry?() } else { close() }
    }
    func choose(_ suggestion: FileDropSuggestion) {
        if suggestion.id == "opinion" { editing = true; problem = ""; onGeometry?(); return }
        problem = ""
        if onSelect?(suggestion) != true && problem.isEmpty { problem = "보낼 수 없어요" }
        onGeometry?()
    }
    func close(notify: Bool = true) {
        if sending { visible = false; onGeometry?(); return }
        if notify && visible && payload.count > 0 { onClose?() }
        eventID = UUID().uuidString; droppedAt = nil
        request = UUID(); work?.cancel(); deadline?.cancel(); intake.close(); visible = false; dragging = false; editing = false
        payload = .init(); proposals = []; draft = ""; notice = ""; problem = ""; origin = ""; status = ""; thumbnail = nil; confirmation = nil
        onGeometry?()
    }
    func cancelAnalysis() { request = UUID(); work?.cancel(); deadline?.cancel() }
    func analyze() {
        let started = droppedAt ?? ProcessInfo.processInfo.systemUptime
        droppedAt = nil
        cancelAnalysis(); summary = ""; outcomes = [:]; sensitive = false; origin = ""
        signals = FileDropSignals.initial(payload); enrich(&signals); assign(&signals)
        primaryProfile = signals.profile
        proposals = FileDropRules.rules(signals, cast: cast())
        status = profileName(primaryProfile) + Ddots.particle(profileName(primaryProfile)) + " 읽는 중"
        let generation = request, payload = payload, initial = signals, invoke = engine, reader = readSignals
        analysisStarted = started
        work = Task { @MainActor [weak self] in
            var signals = await Task.detached { reader(payload, initial) }.value
            guard let self, self.request == generation, self.visible else { return }
            self.enrich(&signals); self.assign(&signals)
            self.primaryProfile = signals.profile
            self.status = self.profileName(signals.profile) + Ddots.particle(self.profileName(signals.profile)) + " 읽는 중"
            self.signals = signals; self.sensitive = signals.sensitive
            self.proposals = FileDropRules.rules(signals, cast: self.cast())
            self.onPayload?()
            if signals.sensitive {
                self.deadline?.cancel()
                self.notice = "비밀처럼 보여 밖으로 보내지 않았어요"; self.status = ""; self.origin = Self.basic("비밀 같은 내용이 있어 보내지 않았어요"); self.onGeometry?(); return
            }
            do {
                let answer = try await invoke(signals, payload.files)
                guard self.request == generation, self.visible, !Task.isCancelled else { return }
                self.deadline?.cancel(); self.status = ""
                var enriched = signals; enriched.works = answer.works
                self.signals = enriched
                // The Mac mini reader may have read what this app could not; its answer decides.
                if answer.partial ?? signals.partial { self.notice = Self.unreadNotice }
                self.summary = String(answer.summary.prefix(60)); self.outcomes = answer.outcomes ?? [:]
                let allowed = self.cast().candidates
                // An answer whose every proposal is discarded by the check is a failure, not a success.
                let asking = answer.confidence < 0.4 && answer.works.count == 1
                if !asking && FileDropRules.merge(answer.suggestions, signals: enriched, fallback: [], profiles: allowed).isEmpty {
                    self.origin = Self.basic("담당을 맞추지 못했어요")
                    self.onAnswer?(ProcessInfo.processInfo.systemUptime - started, true); self.onGeometry?(); return
                }
                self.proposals = FileDropRules.merge(answer.suggestions, signals: enriched, fallback: self.proposals, profiles: allowed)
                self.origin = "Claude가 읽고 골랐어요"
                if asking { self.confirmation = answer.works[0] }
                self.onAnswer?(ProcessInfo.processInfo.systemUptime - started, false); self.onGeometry?()
            } catch {
                guard self.request == generation else { return }
                self.deadline?.cancel(); self.status = ""
                if case FileDropServiceError.sensitive = error { self.sensitive = true; self.notice = "비밀처럼 보여 밖으로 보내지 않았어요"; self.origin = Self.basic("비밀 같은 내용이 있어 보내지 않았어요") }
                else if case FileDropServiceError.notConnected = error { self.origin = Self.basic("맥미니에 연결되지 않았어요") }
                else if case FileDropServiceError.connection(let reason) = error { self.origin = Self.basic(reason) }
                else if case FileDropServiceError.timeout = error { self.origin = Self.basic("시간 초과") }
                else if case FileDropServiceError.engineChanged = error { self.origin = Self.basic("설정이 바뀌는 중이었어요") }
                else { self.origin = Self.basic("Claude 연결 실패") }
                if signals.partial && !self.sensitive { self.notice = Self.unreadNotice }
                self.onAnswer?(ProcessInfo.processInfo.systemUptime - started, true); self.onGeometry?()
            }
        }
        setAnalysisDeadline(started + FileDropTiming.legacySeconds)
    }
    func setAnalysisDeadline(_ uptime: TimeInterval) {
        deadline?.cancel()
        let generation = request, started = analysisStarted
        let remaining = max(0, uptime - ProcessInfo.processInfo.systemUptime)
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
            guard let self, self.request == generation else { return }
            self.cancelAnalysis(); self.status = ""; self.origin = Self.basic("시간 초과")
            if self.signals.partial { self.notice = Self.unreadNotice }
            self.onAnswer?(ProcessInfo.processInfo.systemUptime - started, true); self.onGeometry?()
        }
    }
    static let unreadNotice = "내용을 다 읽지 못했어요"
    static func basic(_ reason: String) -> String { "기본 제안이에요 · " + reason }
    private func assign(_ signals: inout FileDropSignals) { signals.profile = cast().profile(role: FileDropSignals.role(signals.hint)) }
    private func loadThumbnail() {
        let files = payload.files
        fileDetails = [:]
        Task { @MainActor [weak self] in
            let details = await Task.detached {
                Dictionary(uniqueKeysWithValues: files.map { file in
                    let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let pages = file.pathExtension.lowercased() == "pdf" ? PDFDocument(url: file)?.pageCount : nil
                    return (file, (pages.map { "\($0)쪽 · " } ?? "") + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                })
            }.value
            guard let self, self.payload.files == files else { return }; self.fileDetails = details
        }
        guard let file = files.first else { return }
        thumbnail = NSWorkspace.shared.icon(forFile: file.path)
        let generation = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: .init(fileAt: file, size: CGSize(width: 48, height: 48), scale: 2, representationTypes: .thumbnail)) { [weak self] result, _ in
            DispatchQueue.main.async {
                guard let self, self.request == generation, let result else { return }
                self.thumbnail = result.nsImage
            }
        }
    }
}

/// The macOS window close button: a 12 pt red circle that shows its x under the pointer, with a 24 pt target.
struct FileDropCloseButton: View {
    var action: () -> Void
    private final class Hover: ObservableObject { @Published var on = false }
    @StateObject private var hover = Hover()
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).overlay(Circle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.5))
                if hover.on { Image(systemName: "xmark").font(.system(size: 7, weight: .heavy)).foregroundStyle(Color.black.opacity(0.6)) }
            }.frame(width: 12, height: 12).frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover.on = $0 }.accessibilityLabel("닫기").help("닫기 (esc)")
    }
}

/// The conversation's "writing" light band (WritingShimmer) on a line of text while Claude is reading. Plain text when
/// not active or when Reduce Motion is on; the band never intercepts clicks.
struct FileDropShimmerText: View {
    var text: String
    var active: Bool
    var highlight: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        if active && !reduceMotion && !CommandLine.arguments.contains("--ui-smoke-reduce-motion") {
            TimelineView(.periodic(from: .now, by: 1.0 / 24)) { context in
                Text(text).writingShimmer(at: context.date, reduceMotion: false, highlight: highlight)
            }
        } else { Text(text) }
    }
}

/// The agent's picture as the conversation shows it (same source, same soft square); a first-letter badge without one.
struct FileDropFace: View {
    var profile: String
    var name: String
    var avatar: ProfileAvatar?
    var size: CGFloat = 22
    var body: some View {
        Group {
            if profile == "app" { Image(systemName: "macwindow").font(.system(size: size * 0.9)).foregroundStyle(.secondary) }
            else {
                let face = avatar ?? ProfileAvatar()
                if let image = face.image { Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(ChatView.face(size)) }
                else {
                    ZStack {
                        Color(nsColor: face.color)
                        Text(ProfileAvatar.initial(name)).font(.system(size: size * 0.6, weight: .medium)).foregroundColor(Color(nsColor: face.foreground))
                    }.frame(width: size, height: size).clipShape(ChatView.face(size))
                }
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct FileDropCardView: View {
    @ObservedObject var card: FileDropCard
    @Environment(\.colorScheme) private var scheme
    private var fill: Color { Color.primary.opacity(scheme == .dark ? 0.075 : 0.055) }
    private var quiet: Color { Color.primary.opacity(0.28) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if card.dragging {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 24))
                    Text("놓으면 살펴볼게요").font(.system(size: 13, weight: .semibold))
                    Text("파일 \(card.count)개").font(.system(size: 11, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3).background(Color.blue.opacity(0.12), in: Capsule())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                HStack(spacing: 4) {
                    FileDropCloseButton { card.close() }.padding(.leading, -6)
                    Text(card.payload.count == 0 ? "글 붙여넣어 맡기기" : "파일 \(card.count)개").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                if !card.payload.files.isEmpty {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(card.payload.files, id: \.self) { file in FileDropFileRow(file: file, detail: card.fileDetails[file] ?? "", thumbnail: file == card.payload.files.first ? card.thumbnail : nil) }
                        }
                    }.frame(height: CGFloat(min(3, card.payload.files.count)) * 38 + CGFloat(max(0, min(3, card.payload.files.count) - 1)) * 6)
                }
                if !card.notice.isEmpty {
                    Text(card.notice).font(.system(size: 11)).foregroundStyle(card.sensitive ? Color.yellow : Color.secondary)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(card.sensitive ? Color.yellow.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                }
                if !card.problem.isEmpty {
                    Label(card.problem, systemImage: "exclamationmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.orange)
                        .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("file-drop-problem")
                }
                if card.editing {
                    if !card.status.isEmpty && card.sending {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(card.status).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        FileDropEditor(card: card).frame(height: 70).padding(8).background(fill, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12)))
                        let empty = card.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button { card.submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 24)) }
                            .buttonStyle(.plain).foregroundColor(empty ? quiet : .blue).disabled(empty).accessibilityLabel("보내기")
                    }
                } else if let work = card.confirmation {
                    Text("‘\(work)’ 건 자료예요?").font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text("맞으면 그 업무에 붙이고 마감을 확인할게요.").font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Button("아니오") { card.onConfirm?(false) }.frame(maxWidth: .infinity)
                        Button("예") { card.onConfirm?(true) }.frame(maxWidth: .infinity).keyboardShortcut(.defaultAction)
                    }.buttonStyle(.bordered).controlSize(.regular)
                } else {
                    if !card.status.isEmpty {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); FileDropShimmerText(text: card.status, active: !card.sending, highlight: .primary.opacity(0.5)).lineLimit(1) }.font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        if !card.origin.isEmpty { Text(card.origin).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1).help(card.origin).accessibilityIdentifier("file-drop-origin") }
                        if !card.summary.isEmpty { Text(card.summary).font(.system(size: 11)).lineLimit(1).help(card.summary) }
                    }
                    if !card.signals.works.isEmpty {
                        Text(card.signals.works.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(card.proposals.enumerated()), id: \.offset) { index, suggestion in action(suggestion, first: index == 0) }
                    }
                    if card.payload.count > 0 {
                        HStack(spacing: 8) {
                            Button { card.choose(.init(id: "auto", label: "알아서 봐줘", profile: card.primaryProfile)) } label: {
                                Text("알아서 봐줘").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 32).contentShape(Capsule())
                            }.buttonStyle(.plain).background(Color.blue.opacity(scheme == .dark ? 0.17 : 0.1), in: Capsule())
                            Button { card.choose(.init(id: "opinion", label: "의견", profile: card.primaryProfile)) } label: {
                                ReplyActionLabel(word: "의견").frame(width: 32, height: 32).contentShape(Circle())
                            }.buttonStyle(.plain).background(fill, in: Circle()).accessibilityLabel("의견")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Divider()
        }.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 0)
            .frame(width: card.size.width, height: card.size.height - FileDropCard.footer, alignment: .topLeading).clipped()
    }
    func action(_ suggestion: FileDropSuggestion, first: Bool) -> some View {
        Button { card.choose(suggestion) } label: {
            HStack(spacing: 8) {
                FileDropFace(profile: suggestion.profile, name: card.profileName(suggestion.profile), avatar: card.avatar(suggestion.profile))
                FileDropShimmerText(text: suggestion.label, active: !card.status.isEmpty && !card.sending, highlight: .primary.opacity(0.25)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                if card.sensitive && suggestion.profile != "app" { Image(systemName: "exclamationmark.triangle").foregroundStyle(.yellow) }
                Text(card.profileName(suggestion.profile)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 8).frame(height: 38).contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).background(fill.opacity(first ? 1.7 : 1), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(first ? 0.15 : 0), lineWidth: 1))
            .keyboardShortcut(first ? .defaultAction : nil)
            .help(suggestion.label)
    }
}

private struct FileDropFileRow: View {
    var file: URL
    var detail: String
    var thumbnail: NSImage?
    var body: some View {
        HStack(spacing: 8) {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit().frame(width: 24, height: 30) }
            else { Image(systemName: "doc.fill").font(.system(size: 24)).foregroundStyle(.secondary) }
            Text(file.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.horizontal, 8).frame(height: 38).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            .help(file.lastPathComponent)

    }
}

private final class FileDropTextView: NSTextView {
    weak var card: FileDropCard?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            ("⌘V로 붙여넣거나 적어 주세요" as NSString).draw(at: CGPoint(x: 4, y: 4), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func paste(_ sender: Any?) {
        guard let card else { return }
        let board = card.pasteboard()
        if FileDropIntake.concealed(board) { card.notice = "비밀번호 복사는 맡길 수 없어요"; return }
        if ClipboardAttachments.containsAttachments(board) { _ = card.receive(board, append: true); return }
        if let text = board.string(forType: .string) {
            let remaining = max(0, 100_000 - string.count)
            insertText(String(text.prefix(remaining)), replacementRange: selectedRange())
            if text.count > remaining { card.notice = "글은 100,000자까지 맡길 수 있어요" }
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { card?.escape(); return }
        if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() { card?.draft = string; card?.submit(); return }
        super.keyDown(with: event)
    }
}

private struct FileDropEditor: NSViewRepresentable {
    let card: FileDropCard
    final class Coordinator: NSObject, NSTextViewDelegate {
        let card: FileDropCard
        init(_ card: FileDropCard) { self.card = card }
        func textDidChange(_ notification: Notification) { if let text = notification.object as? NSTextView { card.draft = text.string } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(card) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.contentView.drawsBackground = false
        let text = FileDropTextView(); text.card = card; text.isRichText = false; text.font = .systemFont(ofSize: 13); text.drawsBackground = false
        text.textColor = .labelColor; text.insertionPointColor = .labelColor; text.textContainerInset = NSSize(width: 4, height: 4); text.textContainer?.lineFragmentPadding = 0
        text.string = card.draft; text.delegate = context.coordinator
        text.isVerticallyResizable = true; text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        DispatchQueue.main.async { text.window?.makeKeyAndOrderFront(nil); text.window?.makeFirstResponder(text) }
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
