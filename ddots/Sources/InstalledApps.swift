import Foundation

/// Apps installed on the Mac mini that has Hermes, as `hermes-connections apps --json` lists them.
/// Each app carries the Hermes connections it maps to; nothing here launches or controls an app.
struct InstalledAppDocument: Codable {
    let schema: String, scanned_at: String
    let apps: [InstalledApp]
    static func decode(_ data: Data) throws -> Self {
        guard data.count < 2_000_000, let document = try? JSONDecoder().decode(Self.self, from: data),
              document.schema == "hermes-installed-apps/1",
              Set(document.apps.map(\.bundle_id)).count == document.apps.count else { throw ConnectionFailure.invalid }
        return document
    }
    /// Apps that map to at least one Hermes connection, and the rest (which have no feature in this app).
    var connectable: [InstalledApp] { apps.filter { !$0.links.isEmpty } }
    var others: [InstalledApp] { apps.filter { $0.links.isEmpty } }
}

struct InstalledApp: Codable, Identifiable {
    struct Features: Codable { let applescript: Bool, app_intents: Bool, url_schemes: Bool }
    struct Link: Codable, Hashable { let profile: String, connection: String; let state: AgentConnectionItem.State }
    let name: String, bundle_id: String, kind: String
    let features: Features
    let links: [Link]
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
