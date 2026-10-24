import Foundation
import CryptoKit
import Darwin

/// A silent, local hook: never prints approval decisions or context to either agent.
enum HookBridge {
    static func item(provider: Provider, payload: [String: Any], now: Date = Date()) -> WorkItem? {
        guard let id = payload["session_id"] as? String, !id.isEmpty,
              let event = payload["hook_event_name"] as? String else { return nil }
        let state: WorkState
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse": state = .running
        case "PermissionRequest": state = .waiting
        case "Notification":
            guard payload["notification_type"] as? String == "permission_prompt" || payload["notification_type"] as? String == "idle_prompt" else { return nil }
            state = .waiting
        case "Stop":
            let background = payload["background_tasks"] as? [Any] ?? []
            let crons = payload["session_crons"] as? [Any] ?? []
            state = background.isEmpty && crons.isEmpty ? .responded : .running
        case "StopFailure": state = .failed
        case "Interrupt", "SessionEnd": state = .interrupted
        default: return nil
        }
        let cwd = payload["cwd"] as? String ?? ""
        return WorkItem(provider: provider, sessionID: String(id.prefix(200)), turnID: String((payload["turn_id"] as? String ?? "").prefix(200)),
                        project: cwd.isEmpty ? "" : URL(fileURLWithPath: cwd).lastPathComponent,
                        state: state, updatedAt: now, source: "공식 훅", event: event)
    }

    static func decodeEvent(_ object: [String: Any]) -> WorkItem? {
        guard object["version"] as? Int == 1,
              let rawProvider = object["provider"] as? String, let provider = Provider(rawValue: rawProvider),
              let session = object["sessionID"] as? String, !session.isEmpty, session.count <= 200,
              let stateName = object["state"] as? String, let state = WorkState(rawValue: stateName),
              let date = Dates.parse(object["updatedAt"]), date.timeIntervalSinceNow < 60 else { return nil }
        return WorkItem(provider: provider, sessionID: session, turnID: String((object["turnID"] as? String ?? "").prefix(200)),
                        project: String((object["project"] as? String ?? "").prefix(200)), state: state, updatedAt: date,
                        source: "공식 훅", event: String((object["event"] as? String ?? "").prefix(80)))
    }

    static func run(provider: Provider, destination: URL? = nil) {
        // Bound stdin to avoid hanging the agent or retaining large prompts.
        let data = FileHandle.standardInput.readData(ofLength: 1024 * 1024)
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let item = item(provider: provider, payload: payload) else { return }
        let root = destination ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder + "/events")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let filename = SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
            let object: [String: Any] = ["version": 1, "provider": provider.rawValue, "sessionID": item.sessionID,
                                        "turnID": item.turnID, "project": item.project, "state": item.state.rawValue,
                                        "updatedAt": Dates.fractional.string(from: item.updatedAt), "event": item.event]
            let url = root.appendingPathComponent(filename + ".json")
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* Notification failure must not block or change the agent's task. */ }
    }
}
