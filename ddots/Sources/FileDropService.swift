import Foundation
import Darwin

enum FileDropServiceError: Error { case unavailable, sensitive }

/// The process boundary accepts/returns JSON only; diagnostics never contain input or stderr.
enum FileDropRunner {
    static func script(_ home: URL) -> URL { home.appendingPathComponent("plugin-store/team-kit/lib/hermes_team_services/file_drop_suggest.py") }
    static func available(_ home: URL) -> Bool {
        [script(home), home.appendingPathComponent("bin/hermes-run"), home.appendingPathComponent("hermes-agent/venv/bin/python"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude")].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
    static func run(_ data: Data, home: URL) throws -> Data {
        guard data.count <= 64 * 1024, FileManager.default.fileExists(atPath: script(home).path) else { throw CocoaError(.featureUnsupported) }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = home.appendingPathComponent("hermes-agent/venv/bin/python")
        process.arguments = [home.appendingPathComponent("bin/hermes-run").path, script(home).path, "--home", home.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HERMES_HOME"] = home.path; environment["HERMES_DISABLE_LAZY_INSTALLS"] = "1"
        process.environment = environment; process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let cutoff = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 17, execute: cutoff)
        defer { cutoff.cancel() }
        // Write and drain concurrently so neither a large stdin nor stdout can deadlock a pipe.
        DispatchQueue.global(qos: .utility).async { try? input.fileHandleForWriting.write(contentsOf: data + Data([10])); try? input.fileHandleForWriting.close() }
        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        if let error = (try? JSONSerialization.jsonObject(with: result)) as? [String: String], error["error"] == "sensitive_input" { throw FileDropServiceError.sensitive }
        guard process.terminationStatus == 0, result.count <= 64 * 1024 else { throw FileDropServiceError.unavailable }
        return result
    }
}

/// A numeric endpoint is trusted for originals only when the running Tailscale daemon lists it.
/// The injected verifier in relay tests represents an authenticated encrypted route.
enum FileDropEncryptedRoute {
    static func known(_ address: String) -> Bool {
        let executable = URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["status", "--json"]
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let cutoff = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1, execute: cutoff)
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); cutoff.cancel()
        guard process.terminationStatus == 0, data.count < 2_000_000,
              let status = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], status["BackendState"] as? String == "Running" else { return false }
        let peers = (status["Peer"] as? [String: [String: Any]])?.values.map { $0 } ?? []
        let own = status["Self"] as? [String: Any] ?? [:]
        return (peers + [own]).contains { ($0["TailscaleIPs"] as? [String] ?? []).contains(address) }
    }
    static func peer(_ fd: Int32, local: Bool = false) -> String? {
        var storage = sockaddr_storage(), size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { local ? getsockname(fd, $0, &size) : getpeername(fd, $0, &size) }
        }
        guard result == 0 else { return nil }
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let named = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getnameinfo($0, size, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) }
        }
        return named == 0 ? String(cString: name) : nil
    }
}

/// Authenticated relay upload. Names never become paths; each file is owned by this request.
final class FileDropUpload {
    struct File: Codable { var name: String; var size: Int }
    var request: [String: Any]
    let folder: URL
    private let manifest: [File]
    private var handles: [FileHandle] = []
    private var sizes: [Int] = []
    private var parts: [Int] = []
    private(set) var paths: [URL] = []
    init(data: Data, originals: Bool) throws {
        guard data.count <= 64 * 1024, let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let signals = request["signals"] as? [String: Any], signals["sensitive"] as? Bool != true,
              let files = request["uploads"] as? [[String: Any]], files.count <= 5, originals || files.isEmpty else { throw CocoaError(.fileReadNoPermission) }
        self.request = request
        manifest = try JSONDecoder().decode([File].self, from: JSONSerialization.data(withJSONObject: files))
        guard manifest.allSatisfy({ (0...20 * 1024 * 1024).contains($0.size) && !$0.name.isEmpty && $0.name.utf8.count <= 255 && !$0.name.contains("/") && !$0.name.contains("\\") && !$0.name.contains("\0") }) else { throw CocoaError(.fileReadCorruptFile) }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-relay-drop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for (index, entry) in manifest.enumerated() {
                let file = folder.appendingPathComponent(String(index) + "-" + entry.name)
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteNoPermission) }
                paths.append(file); handles.append(try FileHandle(forWritingTo: file)); sizes.append(0); parts.append(0)
            }
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    deinit { for handle in handles { try? handle.close() }; try? FileManager.default.removeItem(at: folder) }
    func append(_ data: Data, file: Int, part: Int) throws {
        guard manifest.indices.contains(file), data.count <= 512 * 1024, parts[file] == part, sizes[file] + data.count <= manifest[file].size else { throw CocoaError(.fileReadCorruptFile) }
        try handles[file].write(contentsOf: data); sizes[file] += data.count; parts[file] += 1
    }
    func finish() throws -> Data {
        guard manifest.indices.allSatisfy({ sizes[$0] == manifest[$0].size }) else { throw CocoaError(.fileReadCorruptFile) }
        for handle in handles { try handle.close() }; handles = []
        request["files"] = paths.map(\.path); request["uploads"] = nil
        return try JSONSerialization.data(withJSONObject: request)
    }
}
