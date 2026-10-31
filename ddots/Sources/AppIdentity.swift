import AppKit
import Darwin
import Foundation

/// The identifiers that keep this app apart from the public assistant-pet.
enum AppIdentity {
    static let name = "ddots"
    static let bundleID = "io.github.hermes-ddots-p.ddots"
    static let supportFolder = "Library/Application Support/ddots"
    /// Only an explicitly prepared transition build can read an earlier ddots identity.
    static func previousIdentifiers(_ info: [String: Any], current: String) -> [String] {
        guard let identifiers = info["DDotsPreviousBundleIdentifiers"] as? [String] else { return [] }
        return Array(Set(identifiers.filter {
            $0 != current && $0.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}$"#,
                                      options: .regularExpression) != nil
        })).sorted()
    }
    static var previousBundleIDs: [String] {
        previousIdentifiers(Bundle.main.infoDictionary ?? [:], current: bundleID)
    }
    /// Read earlier preferences as fallback; writes belong to the current app's domain.
    /// The old preferences remain available to the recovery installation.
    static func inheritPreferences(_ defaults: UserDefaults = .standard,
                                   previous: [String]? = nil) {
        for identifier in previous ?? previousBundleIDs { defaults.addSuite(named: identifier) }
    }
    /// Command line of another process of this user, or empty when it cannot be read.
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]; var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < count, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self)); index += 1
        }
        return result
    }
    /// Whether a running app was started from exactly this app folder, whatever its identifier.
    static func runs(_ bundle: URL?, from folder: URL) -> Bool {
        bundle?.resolvingSymlinksInPath().standardizedFileURL.path == folder.resolvingSymlinksInPath().standardizedFileURL.path
    }
    /// Other running pets. The conversation share runs from the same bundle but is not a pet:
    /// it must neither block a launch nor be asked to quit during an update. Neither is a build being put
    /// through its UI checks: it is gone in a moment, and the installed app must not quit at launch because of it.
    static func otherPets() -> [NSRunningApplication] {
        ([bundleID] + previousBundleIDs).flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter {
            guard $0.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            return isPet(arguments(of: $0.processIdentifier))
        }
    }
    static func isPet(_ arguments: [String]) -> Bool { !arguments.contains("--relay") && !arguments.contains("--ui-smoke") }
}
