import Foundation

/// Disposable display state, never a Slack message or a persisted conversation.
struct StreamPreview: Codable, Equatable, Identifiable {
    var id: String
    var room: String
    var thread: String
    var since: Double
    var updated: Double
    var expires: Double
    var body: String
    var done: Bool
    var profile: String? = nil
    var status: String? = nil
    var input_id: String? = nil

    var displayedBody: String {
        let label: String?
        switch status {
        case "waiting": label = "추가 지시 반영 대기"
        case "redirecting", "applying": label = "추가 지시 반영 중"
        default: label = nil
        }
        guard let label, body != label else { return body }
        return label + "\n\n" + body
    }

    func valid(at now: Double) -> Bool {
        !id.isEmpty && !room.isEmpty && !thread.isEmpty && !body.isEmpty && body.utf8.count <= 256_000
            && since.isFinite && updated.isFinite && expires.isFinite
            && since <= updated && updated <= now + 5 && expires > now && expires <= updated + 121
    }

    static func read(home: URL, now: Date = Date()) -> [Self] {
        let files = FileManager.default
        let profiles = home.appendingPathComponent("profiles")
        let names = ((try? files.contentsOfDirectory(atPath: profiles.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "default" }.sorted()
        let roots = [("default", home)] + names.map { ($0, profiles.appendingPathComponent($0)) }
        var result: [Self] = []
        for (profile, root) in roots {
            let folder = root.appendingPathComponent("cache/ddots-streams")
            for file in ((try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])) ?? []).prefix(64) where file.pathExtension == "json" {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true, (values.fileSize ?? Int.max) <= 300_000,
                      let data = try? Data(contentsOf: file), var preview = try? JSONDecoder().decode(Self.self, from: data),
                      preview.valid(at: now.timeIntervalSince1970) else { continue }
                preview.profile = profile
                result.append(preview)
            }
        }
        return Array(result.sorted { $0.updated > $1.updated }.prefix(16)).sorted { $0.id < $1.id }
    }
}
