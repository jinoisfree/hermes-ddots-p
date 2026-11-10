import Foundation

/// Apps installed on the Mac mini that has Hermes, as `hermes-connections apps --json` lists them.
/// Each app carries the Hermes connections it maps to; nothing here launches or controls an app.
struct InstalledAppDocument: Codable {
    let schema: String, scanned_at: String
    let apps: [InstalledApp]
    var agents: [InstalledAgentApps]? = nil
    static func decode(_ data: Data) throws -> Self {
        guard data.count < 2_000_000, let document = try? JSONDecoder().decode(Self.self, from: data),
              document.schema == "hermes-installed-apps/1",
              Set(document.apps.map(\.bundle_id)).count == document.apps.count else { throw ConnectionFailure.invalid }
        return document
    }
    /// Apps that map to at least one Hermes connection, and the rest (which have no feature in this app).
    var connectable: [InstalledApp] { apps.filter { $0.connectable } }
    var others: [InstalledApp] { apps.filter { !$0.connectable } }
}

struct InstalledApp: Codable, Identifiable {
    struct Features: Codable { let applescript: Bool, app_intents: Bool, url_schemes: Bool }
    struct Link: Codable, Hashable { let profile: String, connection: String; let state: AgentConnectionItem.State }
    let name: String, bundle_id: String, kind: String
    let features: Features
    let links: [Link]
    var route: String? = nil
    var can_do: String? = nil
    var reason: String? = nil
    var connectable: Bool { route.map { $0 != "none" && $0 != "excluded" } ?? !links.isEmpty }
    var id: String { bundle_id }
    /// Pressing the app opens the first connection that is on, else the first one.
    var primaryLink: Link? { links.first { $0.state != .off } ?? links.first }
    /// Information only: what the app itself offers to other programs.
    var infoTags: [String] { (features.app_intents ? ["단축어"] : []) + (features.applescript ? ["AppleScript"] : []) }
}

enum InstalledAppsText {
    static let noDirectFeature = "이 앱과 직접 연동하는 기능은 아직 없어요."
    static let unreadable = "앱 목록을 읽지 못했어요. "
}

/// Per-employee app grants come directly from Hermes, independently of legacy status links.
struct InstalledAgentApps: Codable, Identifiable {
    let profile: String
    let role_hint: String?
    let connected: [EmployeeApp]
    let connectable: [EmployeeApp]
    let unavailable: [EmployeeApp]
    var id: String { profile }
    var all: [EmployeeApp] { connected + connectable + unavailable }
}
struct EmployeeApp: Codable, Identifiable {
    let bundle_id: String, name: String, state: String
    let route: String?
    var service: String? = nil
    let can_do: String?
    let rules: [String]?
    let reason: String?
    let scope: String?
    let tools: [String]?
    let connection_key: String?
    var progress: AppConnectionReply? = nil
    var id: String { bundle_id }
    var key: String { connection_key ?? bundle_id }
    var connected: Bool { state == "connected" || state == "app_missing" }
    var available: Bool { route != "none" && route != "excluded" && state != "app_missing" }
}
struct AppConnectionReply: Codable {
    /// Only a different facility input stage should discard unsent edits.
    struct InputStage: Equatable {
        let profile: String, app: String, kind: String
        let steps: [String], fields: [String], secureFields: [String]
    }
    struct Step: Codable, Identifiable {
        let id: String, label: String, state: String
        let reason: String?, hint: String?
        let needs_user: Bool
    }
    struct Option: Codable, Identifiable {
        let id: String, label: String
        let disabled: Bool?
        let hint: String?, server_path: String?, mac_path: String?
    }
    struct Next: Codable {
        struct Settings: Codable {
            let kind: String, pane: String, url: String, hint: String
        }
        let kind: String
        var action: String? = nil
        let pane: String?, target: String?, hint: String?, resume_key: String?
        let account_settings: Settings?
        let options: [Option]?
        let fields: [AgentActionReply.Field]?
        let guide: AgentActionReply.Guide?
        let input_error: String?
        let multi: Bool?, needs_default: Bool?, other_account: Bool?
        let url: String?
        var prefilledValues: [String: String] {
            Dictionary(uniqueKeysWithValues: (fields ?? []).filter { !$0.secure && $0.value != nil }.map { ($0.id, $0.value!) })
        }
        func canSubmit(_ values: [String: String]) -> Bool {
            guard let fields, !fields.isEmpty, guide?.error(values) == nil else { return false }
            return fields.allSatisfy { !values[$0.id, default: ""].isEmpty }
        }
        var settingsURL: URL? {
            guard let url, url.hasPrefix("x-apple.systempreferences:"), URL(string: url)?.user == nil else { return nil }
            return URL(string: url)
        }
        var loginURL: URL? {
            guard let url, let address = URL(string: url), address.scheme == "https",
                  address.host != nil, address.user == nil, address.password == nil else { return nil }
            return address
        }
    }
    let profile: String, app: String, outcome: String, reason: String
    let steps: [Step]
    let next: Next
    let undo_until: Double?
    let role_hint: String?
    var inputStage: InputStage {
        InputStage(profile: profile, app: app, kind: next.kind,
                   steps: steps.filter(\.needs_user).map(\.id).sorted(),
                   fields: (next.fields ?? []).map(\.id).sorted(),
                   secureFields: (next.fields ?? []).filter(\.secure).map(\.id).sorted())
    }
    func acceptsProgress(_ incoming: Self) -> Bool {
        let currentDone = Set(steps.filter { $0.state == "done" }.map(\.id))
        let incomingDone = Set(incoming.steps.filter { $0.state == "done" }.map(\.id))
        if (next.kind == "secret_set" || next.kind.hasPrefix("choose_")), incoming.next.kind == "resume",
           incomingDone.isSubset(of: currentDone) { return false }
        return next.kind == "resume" || incomingDone != currentDone
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count < 2_000_000, let reply = try? JSONDecoder().decode(Self.self, from: data),
              Set(reply.steps.map(\.id)).count == reply.steps.count else { throw ConnectionFailure.invalid }
        return reply
    }
}
enum AppConnectionCommands {
    static func apps(selfID: String) -> [String] { ["apps", "--json", "--self", selfID] }
    /// Selections are explicit; credentials travel only through stdin.
    static func action(_ action: String, profile: String, app: String, accounts: [String] = [], scopes: [String] = [],
                       defaultID: String? = nil, resume: String? = nil, values: Bool = false) -> [String] {
        var args = ["app", action, "--profile", profile, "--app", app, "--json"]
        for id in accounts { args += ["--account", id] }
        for id in scopes { args += ["--scope", id] }
        if let defaultID { args += ["--default", defaultID] }
        if let resume { args += ["--resume", resume] }
        if values { args += ["--values-stdin"] }
        return args
    }
}
