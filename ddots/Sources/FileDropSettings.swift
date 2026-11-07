import AppKit
import SwiftUI

/// Who can take a dropped item. Nothing here is a fixed ID: the roles come from the organization (relay context),
/// the names from the ddots cast, and the lead from the configured default recipient.
struct FileDropCast: Equatable {
    var members: [String] = []
    var roles: [String: [String]] = [:]
    var fallback = ""
    static let kinds = ["work", "personal"]
    /// Profiles that hold a work or personal role and are in the ddots cast, in cast order.
    var holders: [String] { members.filter { !(roles[$0] ?? []).filter(Self.kinds.contains).isEmpty } }
    /// The default recipient when it is in the cast, otherwise the first agent.
    var lead: String { members.contains(fallback) ? fallback : (members.first ?? "") }
    var candidates: Set<String> { holders.isEmpty ? Set(members.isEmpty ? [] : [lead]) : Set(holders) }
    func profile(role: String) -> String { holders.first { (roles[$0] ?? []).contains(role) } ?? holders.first ?? lead }
    var rolesInCast: [String: [String]] { Dictionary(uniqueKeysWithValues: holders.map { ($0, (roles[$0] ?? []).filter(Self.kinds.contains)) }) }
}

final class FileDropSettings: ObservableObject {
    static let enabledKey = "fileDropEnabled", rolesKey = "fileDropAgentRoles"
    @Published private(set) var enabled: Bool
    @Published var comparisons: [FileDropHistory.Comparison] = []
    /// The organization's roles per profile as last heard from the relay context. They decide who can take a drop,
    /// so the first card after a restart already knows them.
    private(set) var roles: [String: [String]] = [:]
    private let defaults: UserDefaults?
    var onEnabled: ((Bool) -> Void)?
    var onClear: (() -> Void)?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        enabled = defaults?.object(forKey: Self.enabledKey) as? Bool ?? true
        if let data = defaults?.data(forKey: Self.rolesKey), let stored = try? JSONDecoder().decode([String: [String]].self, from: data) { roles = stored }
    }
    func learn(roles incoming: [String: [String]]) {
        guard Thread.isMainThread else { DispatchQueue.main.async { self.learn(roles: incoming) }; return }
        let kept = incoming.mapValues { $0.filter(FileDropCast.kinds.contains) }.filter { !$0.value.isEmpty }
        guard !kept.isEmpty, kept != roles else { return }
        roles = kept
        if let data = try? JSONEncoder().encode(kept) { defaults?.set(data, forKey: Self.rolesKey) }
    }
    func setEnabled(_ value: Bool) { enabled = value; defaults?.set(value, forKey: Self.enabledKey); onEnabled?(value) }
}

struct FileDropSettingsView: View {
    @ObservedObject var settings: FileDropSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("파일·글 끌어놓기 제안", isOn: Binding(get: { settings.enabled }, set: settings.setEnabled))
            Text("Claude는 공유 Mac에서 파일 내용을 읽고 제안해요. 맥미니에 연결되지 않거나 늦으면 기본 제안을 보여줘요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack { Text("제안 비교").font(.headline); Spacer(); Text("Claude").frame(width: 72) }
            stat("카드 표시", \.cards); stat("첫 번째 선택", \.first); stat("두·세 번째 선택", \.other)
            stat("알아서 봐줘", \.auto); stat("의견", \.opinion); stat("내 지시", \.custom)
            stat("닫기만 함", \.closed); stat("제안 못 받음", \.failures)
            HStack {
                Text("응답 시간 중앙값"); Spacer()
                Text(settings.comparisons.first { $0.engine == "claude" }?.median.map { String(format: "%.2f초", $0) } ?? "—").frame(width: 72)
            }
            Divider()
            Button("습관 지우기…") { settings.onClear?() }
            Text("기능을 끄면 접힌 펫에 놓은 것을 기존 클립보드 보관함으로 받아요.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.font(.system(size: 13)).padding(18).frame(width: 460, alignment: .leading)
    }
    func stat(_ title: String, _ key: KeyPath<FileDropHistory.Comparison, Int>) -> some View {
        HStack {
            Text(title); Spacer()
            Text(String(settings.comparisons.first { $0.engine == "claude" }?[keyPath: key] ?? 0)).monospacedDigit().frame(width: 72)
        }
    }
}
