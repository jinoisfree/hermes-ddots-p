import AppKit
import SwiftUI

final class FileDropSettings: ObservableObject {
    static let enabledKey = "fileDropEnabled", engineKey = "fileDropEngine"
    @Published private(set) var enabled: Bool
    @Published private(set) var engine: String
    @Published var comparisons: [FileDropHistory.Comparison] = []
    private let defaults: UserDefaults?
    private var explicitEngine: Bool
    var onEnabled: ((Bool) -> Void)?
    var onEngine: ((String) -> Void)?
    var onClear: (() -> Void)?
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        enabled = defaults?.object(forKey: Self.enabledKey) as? Bool ?? true
        let saved = defaults?.string(forKey: Self.engineKey)
        engine = saved == "claude" ? "claude" : "mac"; explicitEngine = saved != nil
    }
    func setEnabled(_ value: Bool) { enabled = value; defaults?.set(value, forKey: Self.enabledKey); onEnabled?(value) }
    func selectEngine(_ value: String) {
        guard ["mac", "claude"].contains(value) else { return }
        explicitEngine = true; engine = value; defaults?.set(value, forKey: Self.engineKey); onEngine?(value)
    }
    func updateDefault(claudeAvailable: Bool) {
        guard !explicitEngine else { return }
        engine = claudeAvailable ? "claude" : "mac"; onEngine?(engine)
    }
}

struct FileDropSettingsView: View {
    @ObservedObject var settings: FileDropSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("파일·글 끌어놓기 제안", isOn: Binding(get: { settings.enabled }, set: settings.setEnabled))
            Picker("제안 엔진", selection: Binding(get: { settings.engine }, set: settings.selectEngine)) {
                Text("맥 AI").tag("mac")
                Text("에이전트 빠른 판단(Claude)").tag("claude")
            }
            Text("맥 AI는 기기 안에서 읽은 글 중 최대 2,500자로 판단해요. 긴 문서 전체를 읽지는 못해요. Claude는 공유 Mac에서 파일 내용을 읽고 제안해요. 연결되지 않거나 늦으면 기본 제안을 보여줘요.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            HStack { Text("제안 비교").font(.headline); Spacer(); Text("맥 AI").frame(width: 72); Text("Claude").frame(width: 72) }
            stat("카드 표시", \.cards); stat("첫 번째 선택", \.first); stat("두·세 번째 선택", \.other)
            stat("알아서 봐줘", \.auto); stat("의견", \.opinion); stat("내 지시", \.custom)
            stat("닫기만 함", \.closed); stat("제안 못 받음", \.failures)
            HStack {
                Text("응답 시간 중앙값"); Spacer()
                ForEach(["mac", "claude"], id: \.self) { engine in
                    Text(settings.comparisons.first { $0.engine == engine }?.median.map { String(format: "%.2f초", $0) } ?? "—").frame(width: 72)
                }
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
            ForEach(["mac", "claude"], id: \.self) { engine in
                Text(String(settings.comparisons.first { $0.engine == engine }?[keyPath: key] ?? 0)).monospacedDigit().frame(width: 72)
            }
        }
    }
}
