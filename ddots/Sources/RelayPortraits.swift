import Foundation
import Darwin

/// Only names and relay thumbnails survive a restart. All disk work is confined to a utility queue.
final class RelayPortraits {
    private struct Saved: Codable {
        var version = 1
        var characters: [RelayFrame.Character] = []
        var avatars: [String: RelayFrame.Avatar] = [:]
    }
    private static let maximumBytes = 16 << 20
    private let url: URL
    private let queue = DispatchQueue(label: AppIdentity.bundleID + ".portraits", qos: .utility)
    private var loaded = false
    private var saved = Saved()
    private var encoded: Data?
    private var avatars: [String: ProfileAvatar] = [:]
    init(url: URL) { self.url = url }

    private func load() {
        guard !loaded else { return }; loaded = true
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Saved.self, from: data),
              value.version == 1, Self.valid(value.avatars) else { return }
        saved = value; encoded = data; avatars = value.avatars.mapValues(\.avatar)
    }
    private static func valid(_ values: [String: RelayFrame.Avatar]) -> Bool {
        values.values.allSatisfy { value in
            (value.png == nil || value.avatar.thumbnail != nil)
                && (value.color == nil || (value.color!.count == 3 && value.color!.allSatisfy { (0...1).contains($0) }))
        }
    }
    /// Omitted fields mean unchanged; an explicit empty field replaces the previous contents.
    func receive(_ frame: RelayFrame, fromRelay: Bool) {
        guard fromRelay, frame.op == "state", frame.characters != nil || frame.avatars != nil else { return }
        queue.sync {
            load()
            var next = saved
            if let characters = frame.characters { next.characters = characters }
            if let incoming = frame.avatars { guard Self.valid(incoming) else { return }; next.avatars = incoming }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(next), data.count <= Self.maximumBytes, data != encoded else { return }
            saved = next; avatars = next.avatars.mapValues(\.avatar)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let temporary = url.deletingLastPathComponent().appendingPathComponent(".portraits-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                      rename(temporary.path, url.path) == 0 else { return }
                encoded = data
            } catch { /* The live portraits still work if their backup cannot be written. */ }
        }
    }
    func merging(_ source: HermesBridge.PollResult) -> HermesBridge.PollResult {
        queue.sync {
            load()
            var result = source
            result.avatars.merge(avatars) { current, _ in current }
            if result.characters.isEmpty { result.characters = saved.characters.map { ChatCharacter(id: $0.id, name: $0.name) } }
            return result
        }
    }
}
