import Foundation

/// The relay maps the same executable as the pet. Stop it before replacement and
/// restore it on cancellation or the next launch, without changing its settings.
enum UpdateRelay {
    static let restoreKey = "updateRelayExecutable"
    static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return -1 }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate(); return -1
        }
        return process.terminationStatus
    }
    static func suspend(executable: String, item: URL, defaults: UserDefaults = .standard,
                        command: ([String]) -> Int32 = run) throws {
        let service = "gui/\(getuid())/io.github.hermes-ddots-p.ddots.relay"
        let loaded = command(["print", service])
        guard loaded != -1 else { throw UpdateFailure.relay }
        guard loaded == 0 else { return }
        guard let data = try? Data(contentsOf: item),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String],
              arguments.first == executable else { throw UpdateFailure.relay }
        defaults.set(executable, forKey: restoreKey)
        // Persist the recovery marker before taking the share down.
        guard defaults.synchronize() else { throw UpdateFailure.relay }
        let removed = command(["bootout", service])
        let remaining = command(["print", service])
        guard removed == 0, remaining != 0, remaining != -1 else {
            try? restore(executable: executable, item: item, defaults: defaults, command: command)
            throw UpdateFailure.relay
        }
    }
    static func restore(executable: String, item: URL, defaults: UserDefaults = .standard,
                        command: ([String]) -> Int32 = run) throws {
        guard defaults.string(forKey: restoreKey) == executable else { return }
        // An explicit "sharing off" while an update downloads deletes this item.
        guard FileManager.default.fileExists(atPath: item.path) else {
            defaults.removeObject(forKey: restoreKey); return
        }
        guard let data = try? Data(contentsOf: item),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["ProgramArguments"] as? [String])?.first == executable else { throw UpdateFailure.relay }
        let service = "gui/\(getuid())/io.github.hermes-ddots-p.ddots.relay"
        guard command(["print", service]) == 0 ||
                command(["bootstrap", "gui/\(getuid())", item.path]) == 0 else { throw UpdateFailure.relay }
        defaults.removeObject(forKey: restoreKey)
    }
}
