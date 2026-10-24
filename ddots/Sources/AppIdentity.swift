import AppKit
import Darwin
import Foundation

/// The identifiers that keep this app apart from the public assistant-pet.
enum AppIdentity {
    static let name = "ddots"
    static let bundleID = "io.github.hermes-ddots-p.ddots"
    static let supportFolder = "Library/Application Support/ddots"
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
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter {
            guard $0.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
            return isPet(arguments(of: $0.processIdentifier))
        }
    }
    static func isPet(_ arguments: [String]) -> Bool { !arguments.contains("--relay") && !arguments.contains("--ui-smoke") }
}
