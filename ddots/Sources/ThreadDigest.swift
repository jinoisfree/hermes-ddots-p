import AppKit
import SwiftUI
import CryptoKit

/// Full-transcript identity, independent of folding, selection, or presentation formatting.
struct ThreadDigestInput {
    let key: String
    let fingerprint: String
    let data: Data
    let ready: Bool
    let loaded: Bool
    let revision: String
    init(_ thread: SlackThread) {
        key = thread.room + ":" + thread.id
        loaded = thread.loaded && thread.replies.count >= thread.replyCount
        revision = "\(thread.replyCount):\(thread.latest)"
        let messages = thread.messages.filter { !SlackText.isThinking($0.body) }.map {
            ["speaker": $0.fromUser ? "소유자" : $0.speaker, "body": $0.body,
             "files": $0.files.map(\.name).joined(separator: ", "), "date": String($0.date.timeIntervalSince1970),
             "state": $0.effectiveHermesReplyState?.rawValue ?? ""]
        }
        data = (try? JSONSerialization.data(withJSONObject: ["messages": messages], options: [.sortedKeys])) ?? Data()
        fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        ready = loaded && !thread.messages.contains { $0.streaming || $0.pending || SlackText.isThinking($0.body) }
    }
}

final class ThreadDigestEntry: ObservableObject {
    @Published var text = ""
    @Published var state = "대화 전체 요약 준비 중…"
    var fingerprint = ""
    var completed = ""
    var ready = false
    var loadingRevision = ""
    var task: Task<Void, Never>?
}

/// Only summaries and fingerprints live in memory; transcripts travel over stdin, never argv or logs.
final class ThreadDigestStore {
    static let shared = ThreadDigestStore()
    private var entries: [String: ThreadDigestEntry] = [:]
    func loadIfNeeded(_ input: ThreadDigestInput, load: () -> Void) {
        let entry = entry(input.key)
        if input.loaded { entry.loadingRevision = ""; return }
        guard entry.loadingRevision != input.revision else { return }
        entry.loadingRevision = input.revision; load()
    }
    private let queue = DispatchQueue(label: "ddots.thread-digest", qos: .utility)
    // Injected only by isolated UI checks. Production always uses the existing Hermes route.
    var testProvider: ((Data) -> Result<String, Error>)?
    func entry(_ key: String) -> ThreadDigestEntry {
        if let entry = entries[key] { return entry }
        let entry = ThreadDigestEntry(); entries[key] = entry; return entry
    }
    func request(_ input: ThreadDigestInput, force: Bool = false) {
        let entry = entry(input.key)
        let wasReady = entry.ready; entry.ready = input.ready
        if CommandLine.arguments.contains("--ui-smoke"), testProvider == nil {
            if entry.state != "요약 대기" { entry.state = "요약 대기" }; return
        }
        guard input.ready else {
            entry.task?.cancel(); entry.task = nil; entry.fingerprint = input.fingerprint
            if entry.state != "대화가 모두 준비되면 요약해요" { entry.state = "대화가 모두 준비되면 요약해요" }
            return
        }
        guard force || !wasReady || entry.fingerprint != input.fingerprint else { return }
        entry.task?.cancel(); entry.fingerprint = input.fingerprint
        if !force && entry.completed == input.fingerprint { entry.state = ""; return }
        entry.state = entry.text.isEmpty ? "대화 전체를 요약하고 있어요…" : "새 대화를 반영하고 있어요…"
        let provider = testProvider
        entry.task = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            try? await Task.sleep(nanoseconds: provider == nil ? 3_000_000_000 : 10_000_000)
            guard !Task.isCancelled else { return }
            let result: Result<String, Error> = await withCheckedContinuation { continuation in
                self.queue.async {
                    let current = DispatchQueue.main.sync { entry.fingerprint == input.fingerprint }
                    guard current else { continuation.resume(returning: .failure(DigestError.unavailable)); return }
                    continuation.resume(returning: provider?(input.data) ?? Self.generate(input.data))
                }
            }
            guard !Task.isCancelled, entry.fingerprint == input.fingerprint else { return }
            switch result {
            case .success(let text): entry.text = text; entry.completed = input.fingerprint; entry.state = ""
            case .failure: entry.state = "요약을 만들지 못했어요. 다시 시도해 주세요."
            }
            entry.task = nil
        }
    }
    enum DigestError: Error { case unavailable }
    private static func generate(_ data: Data) -> Result<String, Error> {
        guard !CommandLine.arguments.contains("--ui-smoke"),
              let home = HermesLocator.shared.locate(),
              let helper = Bundle.main.url(forResource: "thread_digest", withExtension: "py"),
              let python = python(home) else { return .failure(DigestError.unavailable) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = python; process.arguments = [helper.path]
        let source = home.appendingPathComponent("hermes-agent")
        process.currentDirectoryURL = source
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = home.path
        environment["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        environment["PYTHONPATH"] = source.path
        process.environment = environment
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return .failure(error) }
        try? input.fileHandleForWriting.write(contentsOf: data)
        try? input.fileHandleForWriting.close()
        if finished.wait(timeout: .now() + 150) == .timedOut {
            process.terminate()
            // A stalled provider must not hold the serial queue indefinitely.
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return .failure(DigestError.unavailable)
        }
        let result = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: result) as? [String: String],
              let summary = json["summary"], !summary.isEmpty, summary.count <= 600 else { return .failure(DigestError.unavailable) }
        return .success(summary)
    }
    /// Installer metadata supplies the gateway's Python environment; no fixed version or credentials.
    private static func python(_ home: URL) -> URL? {
        let files = FileManager.default
        let local = home.appendingPathComponent("hermes-agent/venv/bin/python")
        if files.isExecutableFile(atPath: local.path) { return local }
        let installs = home.appendingPathComponent("installs")
        let roots = ((try? files.contentsOfDirectory(at: installs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for root in roots {
            guard let data = try? Data(contentsOf: root.appendingPathComponent("facts.json")),
                  let facts = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let packages = facts["packages"] as? [String: Any], let venv = packages["venv"] as? [String: Any],
                  let path = venv["environment"] as? String else { continue }
            let candidate = URL(fileURLWithPath: path).appendingPathComponent("bin/python")
            if files.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}

struct ThreadDigestView: View {
    let input: ThreadDigestInput
    let loaded: Bool
    let canLoad: Bool
    let load: () -> Void
    @ObservedObject var entry: ThreadDigestEntry
    init(thread: SlackThread, load: @escaping () -> Void) {
        input = ThreadDigestInput(thread); loaded = input.loaded; canLoad = !thread.loaded; self.load = load
        entry = ThreadDigestStore.shared.entry(input.key)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("대화 전체 요약", systemImage: "text.alignleft").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 8)
                if loaded && input.ready {
                    Button { ThreadDigestStore.shared.request(input, force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).disabled(entry.task != nil).help("대화 전체 다시 요약")
                        .accessibilityLabel("대화 전체 다시 요약")
                }
            }
            if !entry.text.isEmpty {
                Text(entry.text).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if entry.completed != input.fingerprint { Text("이전 대화 기준 요약").font(.system(size: 10)).foregroundColor(.secondary) }
            }
            if !loaded {
                if canLoad {
                    Button("전체 대화를 불러와 요약") { load() }.buttonStyle(.borderless).font(.system(size: 12))
                } else {
                    Text("아직 일부 답글만 있어 전체 대화 요약을 만들 수 없어요.").font(.system(size: 12)).foregroundColor(.secondary)
                }
            } else if !entry.state.isEmpty {
                Text(entry.state).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.09)))
            .background(DigestActivation(input: input, load: load))
    }
}

/// Offscreen native height measurement must never start a model request.
private struct DigestActivation: NSViewRepresentable {
    let input: ThreadDigestInput
    let load: () -> Void
    final class Probe: NSView {
        var input: ThreadDigestInput?
        var load: (() -> Void)?
        var scheduled = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func layout() { super.layout(); schedule() }
        func schedule() {
            guard !scheduled, window != nil else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }; self.scheduled = false
                guard self.window != nil, !self.isHiddenOrHasHiddenAncestor, !self.visibleRect.isEmpty, let input = self.input else { return }
                ThreadDigestStore.shared.loadIfNeeded(input) { self.load?() }
                ThreadDigestStore.shared.request(input)
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let view = Probe(); view.input = input; view.load = load; return view }
    func updateNSView(_ view: Probe, context: Context) { view.input = input; view.load = load; view.schedule() }
}
