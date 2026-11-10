import AppKit
import SwiftUI

private typealias AppChoiceState = SwiftUI.State<Set<String>>
private typealias AppTextState = SwiftUI.State<String>
private typealias AppFieldsState = SwiftUI.State<[String: String]>
private typealias AppDisclosureState = SwiftUI.State<Bool>

extension AgentConnectionsModel {
    func openAppSettings(_ next: AppConnectionReply.Next, app: EmployeeApp, profile: String) {
        guard let url = next.settingsURL, openSettings(url) else { return }
        if next.pane == "internet_accounts" { appSettingsReturn = (app, profile) }
    }
    func resumeAppSettings() {
        guard !appWorking, let (app, profile) = appSettingsReturn else { return }
        appSettingsReturn = nil
        appAction("connect", app: app, profile: profile)
    }

    func updateAppSecretScope(_ active: Bool) {
        guard active != appSecretActive else { return }
        appSecretActive = active; secretEntryScope(active)
    }

    func appAction(_ verb: String, app: EmployeeApp, profile: String, accounts: [String] = [], scopes: [String] = [],
                   defaultID: String? = nil, resume: String? = nil, values: [String: String] = [:]) {
        guard !readOnly, !appWorking else { return }
        if resume == "gateway_restart" && !confirmRestart() { return }
        let input: Data?
        do { input = values.isEmpty ? nil : try JSONSerialization.data(withJSONObject: values) }
        catch { appFailure = "입력한 값을 전달하지 못했어요."; return }
        let arguments = AppConnectionCommands.action(verb, profile: profile, app: app.key, accounts: accounts, scopes: scopes,
                                                      defaultID: defaultID, resume: resume, values: input != nil)
        appRevision += 1
        appWorking = true; appFailure = nil; appVerb = verb
        let command = runCommand
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try AppConnectionReply.decode(command(arguments, input, 180)) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.appWorking = false
                switch result {
                case .success(let reply):
                    guard reply.profile == profile, reply.app == app.key else {
                        self.appFailure = "다른 연결의 결과가 왔어요. 새로 확인해 주세요."; return
                    }
                    self.appReply = reply
                    if resume == "internet_accounts" { self.openAppSettings(reply.next, app: app, profile: profile) }
                case .failure(let error):
                    self.appFailure = "연결 결과를 받지 못했어요. 다시 하면 저장된 단계부터 확인해요. " + error.localizedDescription
                }
                self.refresh(); self.loadApps()
            }
        }
    }
}

struct EmployeeAppsSection: View {
    @ObservedObject var model: AgentConnectionsModel
    let profile: String
    @AppDisclosureState private var unavailableOpen = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = model.appsError { Text(error).font(.caption).foregroundColor(.red) }
            if let group = model.apps?.agents?.first(where: { $0.profile == profile }) {
                section("연결된 앱", apps: group.connected)
                section("연결할 수 있는 앱 · 이 Mac에 설치됨", apps: group.connectable)
                DisclosureGroup("연결할 수 없음 · \(group.unavailable.count)개", isExpanded: $unavailableOpen) {
                    section(nil, apps: group.unavailable)
                }.font(.caption)
            } else if model.appsLoading { ProgressView("설치된 앱을 읽는 중…") }
            else { Text("직원별 앱 목록을 받지 못했어요. Hermes 연결 명령을 확인해 주세요.").font(.caption).foregroundColor(.secondary) }
        }
    }
    private func section(_ title: String?, apps: [EmployeeApp]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text("\(title) · \(apps.count)").font(.caption.weight(.semibold)).foregroundColor(.secondary) }
            if apps.isEmpty { Text("아직 없어요").font(.caption).foregroundColor(.secondary).padding(10) }
            ForEach(apps) { app in
                Button {
                    model.appDetail = app; model.appReply = app.progress; model.appFailure = nil
                    model.appVerb = app.progress?.next.action ?? "connect"
                } label: {
                    HStack(spacing: 10) {
                        AppIcon(bundleID: app.bundle_id, size: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name).font(.system(size: 12, weight: .semibold))
                            Text(app.reason ?? app.can_do ?? "").font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if app.connected {
                            Text(app.state == "app_missing" ? "앱이 없어요" : "연결됨").font(.caption).foregroundColor(.green)
                        } else if app.available { Image(systemName: "plus.circle").foregroundColor(.blue) }
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                    }.padding(12).background(Color.primary.opacity(0.045)).cornerRadius(10).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(app.name + (app.connected ? ", 연결됨, 상세" : ", 상세"))
            }
        }
    }
}

struct EmployeeAppDetail: View {
    @ObservedObject var model: AgentConnectionsModel
    let app: EmployeeApp
    let agent: AgentConnectionProfile
    @AppChoiceState private var choices: Set<String> = []
    @AppTextState private var defaultID = ""
    @AppFieldsState private var fields: [String: String] = [:]
    private var reply: AppConnectionReply? {
        guard let value = model.appReply, value.profile == agent.profile, value.app == app.key else { return nil }
        return value
    }
    private var next: AppConnectionReply.Next? { reply?.next }
    private var options: [AppConnectionReply.Option] { next?.options ?? [] }
    private var activeApp: EmployeeApp {
        model.apps?.agents?.first(where: { $0.profile == agent.profile })?.all.first(where: { $0.key == app.key }) ?? app
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("‹ \(agent.display_name)") { model.appDetail = nil; model.appReply = nil }.buttonStyle(.plain).disabled(model.appWorking)
                Spacer()
                Button(model.appsLoading ? "확인 중…" : "새로 확인") { model.loadApps() }.disabled(model.appsLoading || model.appWorking)
            }
            HStack(spacing: 14) {
                AppIcon(bundleID: app.bundle_id, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.title2.bold())
                    Text(agent.display_name).font(.callout).foregroundColor(.secondary)
                }
            }
            if let hint = reply?.role_hint ?? model.apps?.agents?.first(where: { $0.profile == agent.profile })?.role_hint {
                Text(hint).font(.caption).foregroundColor(.secondary)
            }
            Text("할 수 있는 일").font(.headline)
            Text(app.can_do ?? app.reason ?? "앱이 공개한 기능을 확인해 주세요.").textSelection(.enabled)
            if let rules = app.rules, !rules.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("지키는 규칙", systemImage: "checkmark.shield").font(.headline)
                    ForEach(rules, id: \.self) { Text($0).font(.callout) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.1)).cornerRadius(10)
            }
            if let reason = app.reason { Text(reason).font(.callout).foregroundColor(.secondary) }
            if let reply { progress(reply) }
            if let failure = model.appFailure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red).textSelection(.enabled)
                Button("다시 하기") { perform(model.appVerb) }.disabled(model.appWorking)
            }
            if model.appWorking { ProgressView("처리 중… 끝나면 실제 결과를 보여 드려요.") }
            if reply == nil || reply?.next.kind == "done" {
                HStack {
                    if activeApp.connected {
                        Button("해제") { perform("disconnect") }
                        if activeApp.available { Button("범위 바꾸기") { perform("connect") } }
                    } else if activeApp.available {
                        Button("연결") { perform("connect") }.buttonStyle(.borderedProminent)
                    }
                    if let deadline = reply?.undo_until, deadline > Date().timeIntervalSince1970 {
                        Button("되돌리기 (10분)") { perform("undo") }
                    }
                }.disabled(model.appWorking)
            }
        }
        .onChange(of: reply?.inputStage) { _ in
            choices = []; defaultID = ""; fields = [:]
            model.updateAppSecretScope(next?.fields?.contains(where: \.secure) == true)
        }
        .onAppear { model.updateAppSecretScope(next?.fields?.contains(where: \.secure) == true) }
        .onDisappear { fields = [:]; model.updateAppSecretScope(false) }
    }
    private var inputValues: [String: String] {
        (next?.prefilledValues ?? [:]).merging(fields) { _, edited in edited }
    }
    private func perform(_ verb: String, accounts: [String] = [], scopes: [String] = [], resume: String? = nil, values: [String: String] = [:]) {
        model.appAction(verb, app: app, profile: agent.profile, accounts: accounts, scopes: scopes,
                        defaultID: defaultID.isEmpty ? nil : defaultID, resume: resume, values: values)
        fields = [:]
    }
    private func progress(_ reply: AppConnectionReply) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.appVerb == "disconnect" ? "연결 해제" : "연결 진행").font(.headline)
            ForEach(reply.steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    Text(step.state == "done" ? "✓" : step.state == "failed" ? "!" : step.needs_user ? "●" : "○")
                        .foregroundColor(step.state == "done" ? .green : step.state == "failed" ? .red : step.needs_user ? .blue : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.label).font(.callout.weight(step.needs_user ? .semibold : .regular))
                        if let reason = step.reason { Text(reason).font(.caption).foregroundColor(step.state == "failed" ? .red : .secondary) }
                        if step.needs_user, let hint = step.hint, hint != step.reason { Text(hint).font(.callout) }
                    }
                }
            }
            if reply.outcome == "done" && reply.reason == "OK" {
                Label(model.appVerb == "disconnect" ? "해제했어요." : "마쳤어요.", systemImage: "checkmark.circle.fill").foregroundColor(.green)
            } else if reply.next.kind != "done" { input(reply.next) }
            else {
                Text("진행하지 못했어요 (\(reply.reason))").foregroundColor(.red)
                Button("다시 하기") { perform(model.appVerb) }.disabled(model.appWorking)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.045)).cornerRadius(12)
    }
    @ViewBuilder private func input(_ next: AppConnectionReply.Next) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let guide = next.guide, next.kind != "gateway_restart" { ConnectionGuideView(guide: guide, values: inputValues) }
            switch next.kind {
            case "resume":
                Button("이어가기") { perform(model.appVerb) }.buttonStyle(.borderedProminent).disabled(model.appWorking)
            case "choose_account", "choose_scope", "choose_sync_root":
                Label(next.kind == "choose_account" ? "계정 고르기 → 계속" : "쓸 곳 고르기 → 계속", systemImage: "checklist")
                if next.kind != "choose_sync_root" {
                    Button("모두 선택") { choices = Set(options.filter { $0.disabled != true }.map(\.id)) }
                }
                if options.isEmpty { Text("고를 수 있는 항목이 없어요. 앱의 계정과 쓸 곳을 확인해 주세요.").foregroundColor(.secondary) }
                ForEach(options) { option in
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle(option.label, isOn: Binding(get: { choices.contains(option.id) }, set: { checked in
                            if next.kind == "choose_sync_root" { choices = checked ? [option.id] : [] }
                            else if checked { choices.insert(option.id) } else { choices.remove(option.id) }
                            if !choices.contains(defaultID) { defaultID = "" }
                        })).disabled(option.disabled == true || model.appWorking)
                        if let server = option.server_path, let mac = option.mac_path {
                            Text("서버 \(server) → 이 Mac \(mac)").font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                        }
                        if let hint = option.hint { Text(hint).font(.caption).foregroundColor(.secondary) }
                    }
                }
                if next.needs_default == true {
                    Picker("기본 캘린더", selection: $defaultID) {
                        Text("직접 골라 주세요").tag("")
                        ForEach(options.filter { choices.contains($0.id) }) { Text($0.label).tag($0.id) }
                    }
                }
                if next.account_settings != nil {
                    Button("다른 계정으로 로그인") { perform("connect", resume: "internet_accounts") }.disabled(model.appWorking)
                }
                if next.kind == "choose_sync_root" || app.bundle_id == "com.apple.finder" {
                    Button("이 Mac에서 폴더 고르기…") { chooseFolders(syncRoot: next.kind == "choose_sync_root") }
                }
                Button("계속") {
                    let ids = options.filter { choices.contains($0.id) }.map(\.id)
                    if next.kind == "choose_sync_root", let id = ids.first { perform("connect", values: ["sync_root": id]) }
                    else if next.kind == "choose_account" { perform("connect", accounts: ids) }
                    else { perform("connect", scopes: ids) }
                }.buttonStyle(.borderedProminent).disabled(model.appWorking || choices.isEmpty || (next.needs_default == true && defaultID.isEmpty))
            case "secret_set":
                Label("입력 칸 → 계속", systemImage: "rectangle.and.pencil.and.ellipsis")
                ForEach(next.fields ?? [], id: \.id) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label).font(.caption)
                        ConnectionInputField(label: field.label, secure: field.secure, text: binding(field.id))
                    }
                }
                if let error = next.guide?.error(inputValues) ?? next.input_error { Text(error).foregroundColor(.red) }
                Button("계속") { perform("connect", values: inputValues) }.buttonStyle(.borderedProminent)
                    .disabled(model.appWorking || !next.canSubmit(inputValues))
            case "gateway_restart":
                Label("다시 시작 버튼 → 확인 창의 다시 시작", systemImage: "arrow.clockwise.circle")
                Button("다시 시작") { perform(model.appVerb, resume: "gateway_restart") }.disabled(model.appWorking)
            case "permission_request":
                settingsHint(next)
                Button("권한 창 열기") { perform("connect", resume: "permission_request") }.disabled(model.appWorking)
                Button("허용했어요 · 다시 확인") { perform("connect") }.disabled(model.appWorking)
            case "open_settings":
                settingsHint(next)
                if next.settingsURL != nil {
                    Button("시스템 설정 열기") { model.openAppSettings(next, app: app, profile: agent.profile) }
                } else {
                    Text("권한 설정의 위치를 받지 못했어요. 연결 안내를 확인해 주세요.").foregroundColor(.red)
                }
                Button("켰어요 · 다시 확인") { perform("connect") }.disabled(model.appWorking)
            case "oauth_connect":
                Label("로그인 페이지 → 직접 로그인 → 다시 확인", systemImage: "person.crop.circle.badge.checkmark")
                if let url = next.loginURL { Button("로그인 페이지 열기") { _ = model.openLogin(url) } }
                else { Text("로그인 주소를 받지 못했어요. 이 계정의 로그인 설정이 필요해요.").foregroundColor(.red) }
                Button("로그인했어요 · 다시 확인") { perform("connect") }.disabled(model.appWorking)
            default:
                Text("지금 단계는 이 버전에서 처리할 수 없어요 (\(next.kind))").foregroundColor(.red)
            }
            if next.account_settings != nil && !["choose_account", "choose_scope", "choose_sync_root"].contains(next.kind) {
                Button("다른 계정으로 로그인") { perform("connect", resume: "internet_accounts") }.disabled(model.appWorking)
            }
            if model.appVerb == "connect" { Button("취소 · 이전 설정으로") { perform("undo") }.disabled(model.appWorking) }
        }
    }
    private func settingsHint(_ next: AppConnectionReply.Next) -> some View {
        let symbol: String = {
            switch next.pane {
            case "automation": return "app.badge.checkmark"
            case "calendars": return "calendar.badge.checkmark"
            case "contacts": return "person.crop.rectangle"
            case "full_disk_access": return "externaldrive.badge.checkmark"
            case "internet_accounts": return "person.crop.circle.badge.plus"
            default: return "gearshape"
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundColor(.blue)
            if let target = next.target { Text(target).font(.callout.weight(.semibold)) }
            if let hint = next.hint { Text(hint).font(.callout) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.blue.opacity(0.08)).cornerRadius(8)
    }
    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { inputValues[id] ?? "" }, set: { fields[id] = $0 })
    }
    private func chooseFolders(syncRoot: Bool) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = !syncRoot; panel.prompt = "이 폴더 사용"
        guard panel.runModal() == .OK else { return }
        if syncRoot, let url = panel.urls.first { perform("connect", values: ["sync_root": url.path]) }
        else { perform("connect", scopes: panel.urls.map(\.path)) }
    }
}
