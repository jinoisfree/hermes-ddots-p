import Foundation
import Darwin

/// Only the locally configured channel and profile are permitted; a relay peer supplies facts, never a command.
struct ThreeTapCommand {
    static var channel: String { HermesRouting.str(HermesRouting.dict(DdotsConfig.shared.appearance["threeTap"])["channel"]) }
    static var profile: String { HermesRouting.str(HermesRouting.dict(DdotsConfig.shared.appearance["threeTap"])["profile"]) }
    var executable: URL, arguments: [String], environment: [String: String], input: Data
    static func make(_ failure: ThreeTapFailure, executable: URL, home: URL) -> ThreeTapCommand? {
        guard failure.valid, !channel.isEmpty, !profile.isEmpty, profile.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = (profile == "default" ? home.appendingPathComponent(".hermes") : home.appendingPathComponent(".hermes/profiles/" + profile)).path
        return ThreeTapCommand(executable: executable, arguments: ["-p", profile, "send", "--to", "slack:" + channel, "--file", "-", "--quiet"],
                               environment: environment, input: Data(failure.slackText.utf8))
    }
    func run() -> Int32 {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = pipe; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        pipe.fileHandleForReading.closeFile()
        do { try pipe.fileHandleForWriting.write(contentsOf: input); try pipe.fileHandleForWriting.close() } catch {
            try? pipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        if process.isRunning, done.wait(timeout: .now()+15) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now()+1) == .timedOut, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

final class ThreeTapSender {
    private let queue = DispatchQueue(label: "ddots.three-tap-notice")
    private let defaults: UserDefaults
    private let home: URL
    private let execute: (ThreeTapCommand) -> Int32
    private(set) var lastStatus: Int32?
    init(defaults: UserDefaults = .standard, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         execute: @escaping (ThreeTapCommand) -> Int32 = { $0.run() }) {
        self.defaults = defaults; self.home = home; self.execute = execute
    }
    var executable: URL? {
        guard FileManager.default.fileExists(atPath: (ThreeTapCommand.profile == "default" ? home.appendingPathComponent(".hermes") : home.appendingPathComponent(".hermes/profiles/" + ThreeTapCommand.profile)).path) else { return nil }
        return [home.appendingPathComponent(".local/bin/hermes"), URL(fileURLWithPath: "/opt/homebrew/bin/hermes"), URL(fileURLWithPath: "/usr/local/bin/hermes")]
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
    func send(_ failure: ThreeTapFailure) {
        queue.async { [self] in
            guard failure.valid, let executable, let command = ThreeTapCommand.make(failure, executable: executable, home: home) else { lastStatus = -1; return }
            var seen = defaults.stringArray(forKey: "threeTapSlackNotices") ?? []
            let key = failure.mac + "|" + failure.key
            guard !seen.contains(key) else { return }
            // Record before executing: a timeout or lost reply must not post the same notice twice.
            seen.append(key); defaults.set(seen, forKey: "threeTapSlackNotices")
            lastStatus = execute(command)
            if lastStatus != 0 { NSLog("three-tap maintenance notice failed (%d)", lastStatus ?? -1) }
        }
    }
}
