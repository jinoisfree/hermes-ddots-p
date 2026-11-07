import AppKit
import SwiftUI

/// Like the existing chat models, published state is confined to the main thread.
final class AgentConnectionsModel: ObservableObject {
    typealias Runner = (_ arguments: [String], _ input: Data?, _ timeout: Double) throws -> Data
    @Published var selection: String?
    @Published var detail: String?
    @Published var document: AgentConnectionDocument?
    @Published var error: String?
    @Published var loading = false
    @Published var notices: [String: String] = [:]
    @Published var reconnecting: Set<String> = []
    @Published var busy: Set<String> = []
    @Published var results: [String: ActionNotice] = [:]
    @Published var undoable: [String: Date] = [:]
    @Published var secretEntry: SecretEntry?
    @Published var apps: InstalledAppDocument?
    @Published var appsError: String?
    @Published var appsLoading = false
    @Published var otherAppsOpen = false
    @Published var avatars: [String: ProfileAvatar] = [:]
    @Published var permissions: [(String, String, String)] = []
    let readOnly: Bool
    let runCommand: Runner
    let openLogin: (URL) -> Bool
    let openSettings: (URL) -> Bool
    let confirmRestart: () -> Bool
    /// Set by the app: pauses clipboard history while a secret is typed or pasted.
    var secretEntryScope: (Bool) -> Void = { _ in }
    /// Set for a Mac that reads another Mac's status; the Mac mini runs the check.
    var remoteCheck: ((_ profile: String, _ connection: String?) throws -> [AgentActionReply])?
    private let command: URL
    private let cache: AgentConnectionCache
    var timers: [String: Timer] = [:]
    var pendingChecks: Set<String> = []
    var starts: [String: Date] = [:]
    var opened: Set<String> = []
    private var refreshAgain = false
    init(remote: RemoteHermes?, readOnly: Bool, fixture: AgentConnectionDocument? = nil,
         runCommand: Runner? = nil, openLogin: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         openSettings: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         confirmRestart: @escaping () -> Bool = AgentConnectionsModel.askRestart) {
        self.readOnly = readOnly
        let home = HermesLocator.shared.locate() ?? HermesLocator.shared.fallbackHome
        command = home.appendingPathComponent("bin/hermes-connections")
        let executable = command
        self.runCommand = runCommand ?? { arguments, input, timeout in
            try AgentConnectionCommand.run(executable: executable, arguments: arguments, timeout: timeout, input: input)
        }
        self.openLogin = openLogin; self.openSettings = openSettings; self.confirmRestart = confirmRestart
        if readOnly, let remote {
            remoteCheck = { profile, connection in try remote.connectionCheck(profile: profile, connection: connection) }
        }
        cache = AgentConnectionCache {
            if let fixture { return fixture }
            if readOnly {
                guard let remote else { throw ConnectionFailure.oldRelay }
                return try remote.connectionStatus()
            }
            return try AgentConnectionDocument.decode(AgentConnectionCommand.run(executable: executable, arguments: ["status", "--json"]))
        }
    }
    static func askRestart() -> Bool {
        let alert = NSAlert()
        alert.messageText = "에이전트를 다시 시작할까요?"
        alert.informativeText = "모든 에이전트가 잠시(약 1분) 응답을 멈춰요. 처리 중인 대화가 있으면 시작하지 않아요."
        alert.addButton(withTitle: "다시 시작"); alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func refresh() {
        guard !loading else { refreshAgain = true; return }
        loading = true
        cache.read(force: true) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                switch result {
                case .success(let value): self.document = value; self.error = nil
                case .failure(let error): self.error = "연결 상태를 읽지 못했어요. " + error.localizedDescription
                }
                if self.refreshAgain { self.refreshAgain = false; self.refresh() }
            }
        }
    }
    /// The installed-app list belongs to the Mac that runs Hermes; another Mac does not show or read it.
    var showsInstalledApps: Bool { !readOnly }
    func loadApps() {
        guard showsInstalledApps, !appsLoading else { return }
        appsLoading = true
        let run = runCommand
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try InstalledAppDocument.decode(run(ConnectionCommands.apps, nil, 30)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.appsLoading = false
                switch result {
                case .success(let value): self.apps = value; self.appsError = nil
                case .failure(let error): self.appsError = InstalledAppsText.unreadable + error.localizedDescription
                }
            }
        }
    }
    /// An app row leads to the connection page it maps to, where the connection's own buttons are.
    func openApp(_ link: InstalledApp.Link) {
        guard let agent = document?.agents.first(where: { $0.profile == link.profile }) else { return }
        selection = agent.profile
        detail = agent.connections.contains { $0.id == link.connection } ? link.connection : nil
    }
    func loadPermissions() {
        // Existing permission readers only; none request access or read clipboard contents.
        let calendar = EventKitCalendarSource().access
        let board = ClipboardMonitor()
        let paste = board.allowed() ? "허용됨" : (board.canRequestPermission() ? "물어보기" : "허용 안 됨")
        let login = LoginLaunch.state == .enabled ? "켜짐" : "허용 안 됨"
        permissions = [("캘린더", calendar == .allowed ? "허용됨" : calendar == .unknown ? "물어보기" : "허용 안 됨", "Privacy_Calendars"),
                       ("자동화 · 메시지", "확인 중", "Privacy_Automation"),
                       ("붙여넣기", paste, "Privacy_Pasteboard"), ("로그인 시 실행", login, "login")]
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = AppMaintenance.automationStatus()
            DispatchQueue.main.async {
                guard let self, self.permissions.count == 4 else { return }
                self.permissions[1].1 = status == noErr ? "허용됨" : status == -1744 ? "물어보기" : "허용 안 됨"
            }
        }
    }
    func reconnect(_ item: AgentConnectionItem) {
        guard !readOnly, item.action(.oauthConnect) != nil, let account = item.reconnect?.rawValue,
              !reconnecting.contains(account) else { return }
        reconnecting.insert(account); starts[account] = Date(); opened.remove(account)
        notices[account] = "다시 연결을 준비하는 중"
        check(account, action: "start")
        timers[account] = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(account, action: "status") }
        }
    }
    private func check(_ account: String, action: String) {
        guard !pendingChecks.contains(account), reconnecting.contains(account) else { return }
        if Date().timeIntervalSince(starts[account] ?? .distantPast) >= 900 {
            finish(account, text: "동의 시간이 초과됐어요. 다시 연결을 눌러 시작할 수 있어요."); return
        }
        pendingChecks.insert(account)
        let run = runCommand
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try JSONDecoder().decode(AgentReconnectReply.self,
                from: run(["reconnect", action, "--account", account, "--json"], nil, 30)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingChecks.remove(account)
                guard self.reconnecting.contains(account) else { return }
                switch result {
                case .failure(let error): self.finish(account, text: "하지 못했어요. " + error.localizedDescription)
                case .success(let reply):
                    if reply.state == "refused" {
                        self.finish(account, text: "터미널에서 기존 연결 명령으로 연결해 주세요. (\(reply.reason ?? "확인 실패"))")
                    } else if reply.state == "connected" {
                        self.finish(account, text: "연결을 확인했어요.")
                    } else if reply.state == "running" {
                        if !self.opened.contains(account), let url = reply.loginURL {
                            guard self.openLogin(url) else { self.finish(account, text: "브라우저를 열지 못했어요."); return }
                            self.opened.insert(account)
                        }
                        self.notices[account] = self.opened.contains(account) ? "브라우저에서 동의를 기다리는 중" : "동의 주소를 기다리는 중"
                    } else {
                        self.finish(account, text: "다시 연결을 마치지 못했어요. (\(reply.reason ?? reply.state))")
                    }
                }
            }
        }
    }
    private func finish(_ account: String, text: String) {
        timers.removeValue(forKey: account)?.invalidate(); reconnecting.remove(account)
        notices[account] = text; refresh()
    }
    func close() { timers.values.forEach { $0.invalidate() }; timers = [:]; reconnecting = []; if secretEntry != nil { cancelSecret() } }
}

struct AgentConnectionsView: View {
    @ObservedObject var model: AgentConnectionsModel
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    private var card: Color { dark ? Color(red: 0.169, green: 0.169, blue: 0.18) : Color(nsColor: .controlBackgroundColor) }
    private var panel: Color { dark ? Color(red: 0.137, green: 0.137, blue: 0.145) : Color(nsColor: .windowBackgroundColor) }
    private var selection: Color { dark ? Color(red: 0.227, green: 0.227, blue: 0.247) : Color.black.opacity(0.08) }
    private let groups: [(AgentConnectionItem.Group, String)] = [(.account, "계정과 서비스"), (.mac, "Mac 권한 (맥미니의 Hermes)"), (.channel, "대화 채널")]
    private var selected: AgentConnectionProfile? {
        model.document?.agents.first { $0.profile == model.selection } ?? ((model.selection.map { ["mac", "apps"].contains($0) } ?? false) ? nil : model.document?.agents.first)
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("에이전트").font(.caption).foregroundColor(.secondary).padding(.horizontal, 8).padding(.bottom, 4)
                ForEach(model.document?.agents ?? []) { agent in
                    Button { model.selection = agent.profile; model.detail = nil } label: {
                        HStack(spacing: 10) {
                            avatar(agent, size: 28)
                            Text(agent.display_name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 0)
                            Circle().fill(agent.summary == "연결됨" ? Color.green : agent.summary == "다시 연결 필요" ? .yellow : .gray).frame(width: 7, height: 7)
                        }.padding(8).background(selected?.profile == agent.profile ? selection : .clear).cornerRadius(8)
                    }.buttonStyle(.plain).help(agent.summary).accessibilityLabel("\(agent.display_name), \(agent.summary)")
                }
                Spacer()
                Text("이 Mac").font(.caption).foregroundColor(.secondary).padding(.horizontal, 8)
                if model.showsInstalledApps {
                    Button { model.selection = "apps"; model.detail = nil; model.loadApps() } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "square.grid.2x2.fill").font(.system(size: 13)).frame(width: 28, height: 28)
                                .background(Color(white: 0.9)).foregroundColor(.black).clipShape(Circle())
                            Text("설치된 앱").font(.system(size: 12, weight: .medium)); Spacer()
                        }.padding(8).background(model.selection == "apps" ? selection : .clear).cornerRadius(8)
                    }.buttonStyle(.plain).accessibilityLabel("이 Mac, 설치된 앱")
                }
                Button { model.selection = "mac"; model.detail = nil; model.loadPermissions() } label: {
                    HStack(spacing: 10) {
                        Text("d").font(.headline).foregroundColor(.black).frame(width: 28, height: 28).background(Color(white: 0.9)).clipShape(Circle())
                        Text("ddots 권한").font(.system(size: 12, weight: .medium)); Spacer()
                    }.padding(8).background(model.selection == "mac" ? selection : .clear).cornerRadius(8)
                }.buttonStyle(.plain)
            }.padding(.horizontal, 8).padding(.vertical, 20).frame(width: 200).background(panel)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.selection == "mac" { permissions }
                    else if model.selection == "apps" && model.showsInstalledApps { InstalledAppsPage(model: model, card: card) }
                    else {
                        if model.readOnly {
                            Text("맥미니에서 받은 상태 · \(ConnectionTime.label(model.document?.checked_at)) · 확인은 맥미니가 실행해요 · 연결·권한·다시 시작은 맥미니 화면에서")
                                .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.blue.opacity(0.12)).cornerRadius(8)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.4)))
                        }
                        if let error = model.error { Text(error).foregroundColor(.red).textSelection(.enabled) }
                        if let agent = selected {
                            if let item = agent.connections.first(where: { $0.id == model.detail }) {
                                detail(item, agent: agent)
                            } else {
                                header(agent)
                                HStack(spacing: 8) {
                                    summary(agent, states: [.connected], title: "연결됨", color: .green)
                                    summary(agent, states: [.needsReconnect, .notConnected], title: "다시 연결 필요", color: .yellow)
                                    summary(agent, states: [.unknown], title: "확인 안 됨", color: .gray)
                                }
                                ForEach(groups, id: \.0.rawValue) { group, title in
                                    let items = agent.connections.filter { $0.group == group }
                                    if !items.isEmpty {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
                                            VStack(spacing: 0) {
                                                ForEach(items) { item in
                                                    row(item, agent: agent)
                                                    if item.id != items.last?.id { Divider().padding(.leading, 12) }
                                                }
                                            }.background(card).cornerRadius(10)
                                        }
                                    }
                                }
                            }
                        } else { Text(model.loading ? "연결 상태를 확인하는 중" : "아직 연결 상태가 없어요"); refreshButton }
                    }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.frame(minWidth: 760, minHeight: 500)
            .background(dark ? Color(white: 0.118) : Color(nsColor: .underPageBackgroundColor))
            .onAppear { model.refresh() }
            .sheet(item: $model.secretEntry) { entry in
                SecretEntryView(entry: entry, input: entry.input, submit: { model.submitSecret($0) }, cancel: { model.cancelSecret() })
            }
    }
    private func avatar(_ agent: AgentConnectionProfile, size: CGFloat) -> some View {
        Group {
            if let image = model.avatars[agent.profile]?.image { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(ProfileAvatar.initial(agent.display_name)).font(.headline).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor.opacity(0.35)) }
        }.frame(width: size, height: size).clipShape(Circle())
    }
    @ViewBuilder private func header(_ agent: AgentConnectionProfile) -> some View {
        HStack(spacing: 12) {
            avatar(agent, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.display_name).font(.system(size: 18, weight: .bold))
                let scopes = Set(agent.connections.compactMap { $0.scope?.rawValue })
                if scopes == ["personal"] { Text("개인비서 · 개인 범위").font(.caption).foregroundColor(.secondary) }
                else if scopes == ["company"] { Text("업무비서 · 회사 범위").font(.caption).foregroundColor(.secondary) }
            }
            Spacer(minLength: 8)
            Text(ConnectionTime.label(model.document?.checked_at)).font(.caption).foregroundColor(.secondary)
            checkAllButton(agent)
            refreshButton
        }
        if let notice = model.results[agent.profile + "/*"] { noticeLine(notice) }
    }
    private func checkAllButton(_ agent: AgentConnectionProfile) -> some View {
        let running = model.busy.contains(agent.profile + "/*")
        return Button(running ? "확인 중…" : "모두 확인") { model.checkAll(agent) }
            .disabled(running).accessibilityLabel("\(agent.display_name), 모두 확인" + (running ? ", 진행 중" : ""))
    }
    private func noticeLine(_ notice: ActionNotice) -> some View {
        Label(notice.text, systemImage: notice.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption).foregroundColor(notice.success ? .green : .red).fixedSize(horizontal: false, vertical: true)
    }
    private var refreshButton: some View {
        Button(model.loading ? "확인 중…" : model.readOnly ? "새로 받기" : "새로 확인") { model.refresh() }.disabled(model.loading)
    }
    private func summary(_ agent: AgentConnectionProfile, states: [AgentConnectionItem.State], title: String, color: Color) -> some View {
        let count = agent.connections.filter { states.contains($0.state) }.count
        return Group {
            if count > 0 {
                HStack(spacing: 5) { Circle().fill(color).frame(width: 6, height: 6); Text("\(title) \(count)") }
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal, 9).padding(.vertical, 4).background(card).clipShape(Capsule())
            }
        }
    }
    private func pill(_ state: AgentConnectionItem.State) -> some View {
        let color: Color = state == .connected ? .green : state == .needsReconnect ? .yellow : state == .notConnected ? .red : .secondary
        return Text(state.title).font(.system(size: 10, weight: .medium)).foregroundColor(color).padding(.horizontal, 8).padding(.vertical, 3)
            .background(state == .off ? Color.clear : color.opacity(0.12)).clipShape(Capsule())
            .overlay(Capsule().stroke(state == .off ? Color.secondary.opacity(0.4) : .clear))
    }
    private func tile(_ service: String, size: CGFloat = 30) -> some View {
        let spec: (String, Color, Color) = {
            switch service {
            case "google": return ("G", .white, .black)
            case "notion": return ("N", .white, .black)
            case "synology": return ("S", .blue, .white)
            case "slack": return ("#", .purple, .white)
            case "mail_read": return ("✉", .blue, .white)
            case "notes_read": return ("✎", .yellow, .black)
            case "calendar_read": return ("31", .red, .white)
            case "photon": return ("●", .green, .white)
            case "x": return ("X", .black, .white)
            case "instagram": return ("◎", .pink, .white)
            case "pasteboard": return ("▣", .gray, .white)
            default: return ("⇄", .indigo, .white)
            }
        }()
        return Group {
            if service == "photon" { Image(systemName: "bubble.left.fill") }
            else { Text(spec.0).font(.system(size: size * 0.48, weight: .semibold)) }
        }.foregroundColor(spec.2).frame(width: size, height: size).background(spec.1).cornerRadius(6)
    }
    private func row(_ item: AgentConnectionItem, agent: AgentConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { model.detail = item.id } label: {
                    HStack(spacing: 10) {
                        tile(item.service)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.label).font(.system(size: 12, weight: .semibold))
                            Text(item.account ?? item.explanation).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.buttonStyle(.plain).accessibilityLabel("\(agent.display_name), \(item.label), \(item.state.title)")
                pill(item.state)
                if let primary = item.primaryAction { actionButton(primary, item: item, agent: agent) }
                else { Button("›") { model.detail = item.id }.buttonStyle(.plain).foregroundColor(.secondary) }
            }
            resultLine(item, agent: agent)
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }
    private func actionButton(_ action: ConnectionAction, item: AgentConnectionItem, agent: AgentConnectionProfile) -> some View {
        let running = model.isBusy(agent, item)
        let blocked = model.readOnly && action.kind != .check
        return Button { model.perform(action, item: item, agent: agent) } label: {
            HStack(spacing: 5) {
                if running { ProgressView().controlSize(.small) }
                Text(running ? busyWord(action) : action.label)
            }.font(.system(size: 11, weight: .medium)).foregroundColor(action.resolves ? .white : .primary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(action.resolves ? Color.blue : Color.clear).cornerRadius(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(action.resolves ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1))
        }.buttonStyle(.plain).disabled(running || blocked).opacity(blocked ? 0.4 : 1)
            .accessibilityLabel("\(agent.display_name), \(item.label), \(action.label)" + (running ? ", 진행 중" : ""))
    }
    private func busyWord(_ action: ConnectionAction) -> String {
        switch action.kind {
        case .check: return "확인 중…"
        case .secretSet: return "여는 중…"
        case .permissionRequest: return "요청 중…"
        case .gatewayRestart: return "다시 시작 중…"
        case .oauthConnect: return "연결 중…"
        case .openSettings: return "여는 중…"
        case nil: return "…"
        }
    }
    private func resultLine(_ item: AgentConnectionItem, agent: AgentConnectionProfile) -> some View {
        let name = model.key(agent.profile, item.id)
        return VStack(alignment: .leading, spacing: 4) {
            if let notice = model.results[name] {
                HStack(spacing: 10) {
                    noticeLine(notice)
                    if notice.success, model.undoable[name] != nil, !model.readOnly {
                        Button("되돌리기") { model.undoSecret(agent: agent, item: item) }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            if let account = item.reconnect?.rawValue, let text = model.notices[account] { Text(text).font(.caption).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private func detail(_ item: AgentConnectionItem, agent: AgentConnectionProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("‹ \(agent.display_name)") { model.detail = nil }.buttonStyle(.plain).foregroundColor(.blue)
            HStack(spacing: 12) { tile(item.service, size: 44); VStack(alignment: .leading, spacing: 4) {
                Text(item.label).font(.title2.bold()); Text(item.account ?? item.state.title).font(.caption).foregroundColor(.secondary)
            } }
            Text(item.explanation).font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.13)).cornerRadius(8)
            Text("할 수 있는 일").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(item.capabilities, id: \.self) { value in HStack {
                    Circle().fill(Color.green).frame(width: 8, height: 8); Text(value).font(.callout); Spacer()
                }.padding(12) }
            }.background(card).cornerRadius(10)
            Text("지키는 규칙").font(.caption.weight(.semibold)).foregroundColor(.secondary)
            ForEach(item.rules, id: \.self) { Text($0).font(.caption).foregroundColor(.secondary) }
            if let actions = item.actions, !actions.isEmpty {
                Text("할 수 있는 동작").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(actions.filter { $0.kind != nil }, id: \.id) { actionButton($0, item: item, agent: agent) }
                }
            }
            resultLine(item, agent: agent)
            HStack { refreshButton; Spacer(); Text(ConnectionTime.label(item.checked_at)).font(.caption).foregroundColor(.secondary) }
        }
    }
    private func settingsButton(_ service: String) -> some View {
        Button { openSettings(service) } label: {
            Text("시스템 설정").font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
        }.buttonStyle(.plain)
    }
    private func openSettings(_ service: String) {
        if service == "login" { LoginLaunch.openSettings(); return }
        let pane = service == "calendar_read" ? "Privacy_Calendars" : service == "pasteboard" ? "Privacy_Pasteboard" : "Privacy_Automation"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Text("d").font(.title2.bold()).foregroundColor(.black).frame(width: 44, height: 44).background(Color(white: 0.9)).clipShape(Circle())
                VStack(alignment: .leading) { Text("ddots 권한").font(.title2.bold()); Text("이 Mac에서 ddots가 쓰는 권한").font(.caption).foregroundColor(.secondary) }
            }
            VStack(spacing: 0) {
                ForEach(model.permissions.indices, id: \.self) { index in
                    let row = model.permissions[index]
                    let service = ["calendar_read", "photon", "pasteboard", "login"][index]
                    HStack(spacing: 10) {
                        tile(service); Text(row.0).font(.system(size: 12, weight: .semibold)); Spacer()
                        Text(row.1).font(.caption).foregroundColor(row.1 == "허용됨" || row.1 == "켜짐" ? .green : row.1 == "물어보기" ? .yellow : .red)
                        if row.1 != "허용됨" && row.1 != "켜짐" { settingsButton(service) }
                    }.padding(12)
                    if index != model.permissions.count - 1 { Divider().padding(.leading, 12) }
                }
            }.background(card).cornerRadius(10)
            Text("권한은 macOS가 관리해요. 이 화면은 상태만 확인합니다.").font(.caption).foregroundColor(.secondary)
            Button("새로 확인") { model.loadPermissions() }
        }
    }
}
