import AppKit
import SwiftUI

/// The typed values live only in this object and are wiped when the window closes or the save succeeds.
final class SecretInput: ObservableObject {
    @Published var values: [String: String] = [:]
    func clear() { values = [:] }
}

/// What the secure entry window shows.
struct SecretEntry: Identifiable {
    let id = UUID()
    let input = SecretInput()
    let profile: String, agent: String, connection: String, label: String
    let fields: [AgentActionReply.Field]
    let guide: AgentActionReply.Guide?
    var error: String?
    var submitting = false
}

extension AgentConnectionsModel {
    func key(_ profile: String, _ connection: String) -> String { profile + "/" + connection }

    /// A connection is busy while its own command runs, or while its Google account is being reconnected.
    func isBusy(_ agent: AgentConnectionProfile, _ item: AgentConnectionItem) -> Bool {
        busy.contains(key(agent.profile, item.id)) || busy.contains(agent.profile + "/*")
            || (item.reconnect.map { reconnecting.contains($0.rawValue) } ?? false)
    }

    func perform(_ action: ConnectionAction, item: AgentConnectionItem, agent: AgentConnectionProfile) {
        guard let kind = action.kind, !isBusy(agent, item) else { return }
        if readOnly {
            if kind == .check { checkRemote(profile: agent.profile, connection: item.id, label: item.label) }
            return
        }
        let name = key(agent.profile, item.id)
        switch kind {
        case .oauthConnect: reconnect(item)
        case .check:
            execute(name, label: item.label, arguments: ConnectionCommands.check(agent.profile, item.id))
        case .secretSet: beginSecret(agent: agent, item: item)
        case .permissionRequest:
            execute(name, label: item.label, arguments: ConnectionCommands.permission("request", agent.profile, item.id))
        case .openSettings:
            execute(name, label: item.label, arguments: ConnectionCommands.permission("settings", agent.profile, item.id)) { [weak self] reply in
                if let url = reply.settingsURL { _ = self?.openSettings(url) }
            }
        case .gatewayRestart:
            guard confirmRestart() else { return }
            execute(name, label: item.label, arguments: ConnectionCommands.restart)
        }
    }

    func checkAll(_ agent: AgentConnectionProfile) {
        let name = agent.profile + "/*"
        guard !busy.contains(name) else { return }
        if readOnly { checkRemote(profile: agent.profile, connection: nil, label: agent.display_name); return }
        busy.insert(name); results[name] = nil
        run(arguments: ConnectionCommands.checkAll(agent.profile)) { [weak self] result in
            guard let self else { return }
            self.busy.remove(name)
            self.apply(result, agent: agent.profile, name: name, label: agent.display_name)
        }
    }

    private func kind(_ profile: String, _ connection: String?) -> String? {
        document?.agents.first { $0.profile == profile }?.connections.first { $0.id == connection }?.connect_kind
    }
    private func apply(_ result: Result<AgentActionReply, Error>, agent: String, name: String, label: String) {
        switch result {
        case .failure(let error): results[name] = ActionNotice(success: false, text: "하지 못했어요. " + error.localizedDescription)
        case .success(let reply):
            if let list = reply.results {
                for part in list {
                    guard let connection = part.connection else { continue }
                    let row = document?.agents.first { $0.profile == agent }?.connections.first { $0.id == connection }
                    results[key(agent, connection)] = ConnectionSentence.notice(part, label: row?.label ?? connection, kind: row?.connect_kind)
                }
                results[name] = ConnectionSentence.summary(list)
            } else { results[name] = ConnectionSentence.notice(reply, label: label, kind: kind(agent, reply.connection)) }
        }
        refresh()
    }

    private func run(arguments: [String], input: Data? = nil, done: @escaping (Result<AgentActionReply, Error>) -> Void) {
        let command = runCommand, timeout = ConnectionCommands.timeout(arguments)
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try AgentActionReply.decode(command(arguments, input, timeout)) }
            DispatchQueue.main.async { done(result) }
        }
    }

    func execute(_ name: String, label: String, arguments: [String], input: Data? = nil,
                 after: ((AgentActionReply) -> Void)? = nil) {
        busy.insert(name); results[name] = nil
        run(arguments: arguments, input: input) { [weak self] result in
            guard let self else { return }
            self.busy.remove(name)
            self.apply(result, agent: name.components(separatedBy: "/").first ?? "", name: name, label: label)
            if case .success(let reply) = result { after?(reply) }
        }
    }

    private func checkRemote(profile: String, connection: String?, label: String) {
        let name = key(profile, connection ?? "*")
        guard !busy.contains(name) else { return }
        guard let check = remoteCheck else {
            results[name] = ActionNotice(success: false, text: "맥미니 ddots를 업데이트하면 확인할 수 있어요."); return
        }
        busy.insert(name); results[name] = nil
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try check(profile, connection) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy.remove(name)
                switch result {
                case .failure(let error): self.results[name] = ActionNotice(success: false, text: "하지 못했어요. " + error.localizedDescription)
                case .success(let replies):
                    if connection == nil {
                        for part in replies {
                            guard let id = part.connection else { continue }
                            let row = self.document?.agents.first { $0.profile == profile }?.connections.first { $0.id == id }
                            self.results[self.key(profile, id)] = ConnectionSentence.notice(part, label: row?.label ?? id, kind: row?.connect_kind)
                        }
                        self.results[name] = ConnectionSentence.summary(replies)
                    } else if let reply = replies.first { self.results[name] = ConnectionSentence.notice(reply, label: label, kind: self.kind(profile, reply.connection)) }
                }
                self.refresh()
            }
        }
    }

    // MARK: secret entry

    func beginSecret(agent: AgentConnectionProfile, item: AgentConnectionItem) {
        let name = key(agent.profile, item.id)
        busy.insert(name); results[name] = nil
        run(arguments: ConnectionCommands.secret("guide", agent.profile, item.id)) { [weak self] result in
            guard let self else { return }
            self.busy.remove(name)
            switch result {
            case .failure(let error): self.results[name] = ActionNotice(success: false, text: "하지 못했어요. " + error.localizedDescription)
            case .success(let reply):
                guard reply.outcome == "done", let fields = reply.fields, !fields.isEmpty else {
                    self.results[name] = ConnectionSentence.notice(reply, label: item.label); return
                }
                self.secretEntry = SecretEntry(profile: agent.profile, agent: agent.display_name, connection: item.id,
                                               label: item.label, fields: fields, guide: reply.guide)
                self.secretEntryScope(true)
            }
        }
    }

    func cancelSecret() { secretEntry?.input.clear(); secretEntry = nil; secretEntryScope(false) }

    /// `values` go to the command's standard input as one JSON object and are not kept here.
    func submitSecret(_ values: [String: String]) {
        guard var entry = secretEntry, !entry.submitting,
              let input = try? JSONSerialization.data(withJSONObject: values) else { return }
        entry.submitting = true; entry.error = nil; secretEntry = entry
        let name = key(entry.profile, entry.connection), label = entry.label
        run(arguments: ConnectionCommands.secret("set", entry.profile, entry.connection), input: input) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.secretEntry?.submitting = false
                self.secretEntry?.error = "하지 못했어요. " + error.localizedDescription
            case .success(let reply):
                let notice = ConnectionSentence.notice(reply, label: label)
                if reply.outcome == "done" {
                    self.secretEntry?.input.clear(); self.secretEntry = nil; self.secretEntryScope(false)
                    self.results[name] = notice
                    if let deadline = reply.undoDeadline {
                        self.undoable[name] = deadline
                        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow)) { [weak self] in self?.undoable[name] = nil }
                    }
                    self.refresh()
                } else {
                    self.secretEntry?.submitting = false
                    self.secretEntry?.error = notice.text
                }
            }
        }
    }

    func undoSecret(agent: AgentConnectionProfile, item: AgentConnectionItem) {
        let name = key(agent.profile, item.id)
        guard !busy.contains(name), !readOnly else { return }
        undoable[name] = nil
        execute(name, label: item.label, arguments: ConnectionCommands.secret("undo", agent.profile, item.id))
    }
}

struct SecretEntryView: View {
    let entry: SecretEntry
    @ObservedObject var input: SecretInput
    let submit: ([String: String]) -> Void
    let cancel: () -> Void
    private var complete: Bool { entry.fields.allSatisfy { !(input.values[$0.id] ?? "").isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(entry.agent) · \(entry.label) 연결").font(.title3.bold())
            if let guide = entry.guide {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)").font(.caption.weight(.bold)).frame(width: 18, height: 18)
                                .background(Color.secondary.opacity(0.2)).clipShape(Circle())
                            Text(step).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let text = guide.link, let url = URL(string: text), url.scheme == "https" {
                        Button("설정 페이지 열기") { NSWorkspace.shared.open(url) }.buttonStyle(.link)
                    }
                }
            }
            ForEach(entry.fields, id: \.id) { field in
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.caption).foregroundColor(.secondary)
                    Group {
                        if field.secure { SecureField("", text: binding(field.id)) } else { TextField("", text: binding(field.id)) }
                    }.textFieldStyle(.roundedBorder).disabled(entry.submitting).accessibilityLabel(field.label)
                }
            }
            Text("입력한 값은 확인을 통과해야 저장해요. 화면과 기록에는 남기지 않아요.").font(.caption).foregroundColor(.secondary)
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("취소") { cancel() }.keyboardShortcut(.cancelAction).disabled(entry.submitting)
                Button(entry.submitting ? "확인 중…" : "확인하고 저장") { submit(input.values) }
                    .keyboardShortcut(.defaultAction).disabled(!complete || entry.submitting)
            }
        }.padding(22).frame(width: 440).onDisappear { input.clear() }
    }
    private func binding(_ id: String) -> Binding<String> {
        Binding(get: { input.values[id] ?? "" }, set: { input.values[id] = $0 })
    }
}
