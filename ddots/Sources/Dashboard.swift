import SwiftUI

final class DashboardModel: ObservableObject {
    @Published var identity = PetIdentity.load()
    @Published var tasks: [WorkItem] = []
    @Published var connections: [ConnectionInfo] = []
    @Published var paused = false
    @Published var warning: String?
    @Published var lastScan: Date?
    @Published var selectedID: String?
    @Published var hermesDetail: String?
    @Published var filter = "전체"
    var onSelect: ((String?) -> Void)?
    var onRefresh: (() -> Void)?
    var onPause: (() -> Void)?
    var onPreview: (() -> Void)?
    var onHooks: (() -> Void)?
}

struct Dashboard: View {
    @ObservedObject var model: DashboardModel
    private let ink = Color(red: 0.08, green: 0.13, blue: 0.15)
    var filtered: [WorkItem] { model.tasks.filter { model.filter == "전체" || $0.provider.name == model.filter } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ddots").font(.system(size: 29, weight: .bold, design: .rounded))
                    Text(model.identity.dashboardIntroduction).font(.system(size: 13)).foregroundColor(.secondary)
                }
                Spacer()
                Button(model.paused ? "다시 살펴보기" : "잠시 쉬기") { model.onPause?() }
                    .buttonStyle(.bordered)
            }.padding(.bottom, 23)
            HStack(spacing: 12) {
                metric("작업 중", count: model.tasks.filter { $0.state == .running }.count, color: .teal)
                metric("확인 필요", count: model.tasks.filter { $0.state == .waiting }.count, color: .orange)
                metric("최근 응답", count: model.tasks.filter { $0.state == .responded }.count, color: .blue)
            }.padding(.bottom, 20)
            HStack {
                Text("작업 목록").font(.system(size: 16, weight: .semibold))
                Spacer()
                Picker("서비스", selection: $model.filter) {
                    ForEach(["전체", "Codex", "Claude Code"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 260)
            }.padding(.bottom, 10)
            if let warning = model.warning {
                Text(warning).font(.caption).foregroundColor(.orange).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "cup.and.saucer").font(.system(size: 30)).foregroundColor(.teal)
                            Text(model.paused ? "지금은 쉬고 있어요" : "아직 표시할 작업이 없어요").font(.headline)
                            Text("Codex나 Claude Code에서 작업을 시작하면 여기에 나타납니다.").font(.caption).foregroundColor(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 32)
                    }
                    ForEach(filtered) { item in
                        Button { model.onSelect?(model.selectedID == item.id ? nil : item.id) } label: {
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 3).fill(color(item.state)).frame(width: 4, height: 42)
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text(item.provider.name).font(.system(size: 12, weight: .bold))
                                        Text(item.project.isEmpty ? "작업 공간" : item.project).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                                        if model.selectedID == item.id { Image(systemName: "pin.fill").font(.caption).foregroundColor(.teal) }
                                    }
                                    Text("\(item.shortID) · \(item.source)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                }
                                Spacer(minLength: 6)
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(item.state.label).font(.system(size: 12, weight: .medium)).foregroundColor(color(item.state))
                                    Text(item.updatedAt, style: .time).font(.system(size: 10)).foregroundColor(.secondary)
                                }
                            }.padding(12).background(Color.white.opacity(0.85)).cornerRadius(12)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selectedID == item.id ? Color.teal.opacity(0.6) : Color.black.opacity(0.04)))
                        }.buttonStyle(.plain)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(model.connections) { info in
                    HStack(spacing: 6) {
                        Circle().fill(info.available ? Color.teal : Color.gray).frame(width: 5, height: 5)
                        Text(info.provider.name).fontWeight(.medium)
                        Text(info.detail).foregroundColor(.secondary).lineLimit(1)
                    }.font(.system(size: 10))
                }
                if let detail = model.hermesDetail {
                    HStack(spacing: 6) {
                        Circle().fill(detail.hasPrefix("연결됨") ? Color.teal : Color.gray).frame(width: 5, height: 5)
                        Text("Hermes 대화").fontWeight(.medium)
                        Text(detail).foregroundColor(.secondary).lineLimit(1)
                    }.font(.system(size: 10))
                }
                HStack {
                    Text("이 Mac의 최근 기록 · 응답 종료는 작업 성공을 뜻하지 않습니다.").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer()
                    Button("새로고침") { model.onRefresh?() }.font(.caption)
                }
                HStack {
                    Button("동작 미리보기") { model.onPreview?() }
                    Button("승인 알림 연결 안내") { model.onHooks?() }
                    Spacer()
                    if let date = model.lastScan { Text(date, style: .time).foregroundColor(.secondary) }
                }.font(.system(size: 10))
            }.padding(.top, 15)
        }.padding(26).frame(minWidth: 680, minHeight: 560)
            .foregroundColor(ink).background(Color(red: 0.95, green: 0.96, blue: 0.93)).environment(\.colorScheme, .light)
    }
    func metric(_ title: String, count: Int, color: Color) -> some View {
        HStack { VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundColor(.secondary)
            Text("\(count)").font(.system(size: 27, weight: .semibold, design: .rounded)).foregroundColor(color)
        }; Spacer() }.padding(15).frame(maxWidth: .infinity).background(Color.white.opacity(0.7)).cornerRadius(14)
    }
    func color(_ state: WorkState) -> Color {
        switch state {
        case .running: return .teal
        case .waiting: return .orange
        case .failed: return .red
        case .responded: return .blue
        default: return .secondary
        }
    }
}
