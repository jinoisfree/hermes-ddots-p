import AppKit
import Darwin
import Foundation
import ImageIO

/// The chat reads either this Mac's Hermes record or the same record relayed from another Mac.
protocol HermesSource: AnyObject {
    func poll(unreadSince: Date?) -> HermesBridge.PollResult
    func search(_ text: String) -> [ChatMessage]
    func older(before message: ChatMessage?) -> [ChatMessage]
    func around(profile: String, messageID: Int64) -> [ChatMessage]
}
extension HermesBridge: HermesSource {
    func poll(unreadSince: Date?) -> PollResult { poll(limit: 200, now: Date(), unreadSince: unreadSince) }
    func older(before message: ChatMessage?) -> [ChatMessage] { older(before: message, limit: 40) }
    func around(profile: String, messageID: Int64) -> [ChatMessage] { around(profile: profile, messageID: messageID, count: 20) }
}

/// One JSON object per line. Every field except `op` is optional; a state frame carries only what changed.
struct RelayFrame: Codable {
    struct Message: Codable {
        var id: String, fromUser: Bool, speaker: String, body: String, date: Double, sessionID: String, interrupted: Bool, profile: String
        init(_ m: ChatMessage) {
            id = m.id; fromUser = m.fromUser; speaker = m.speaker; body = m.body; date = m.date.timeIntervalSince1970
            sessionID = m.sessionID; interrupted = m.replyInterrupted; profile = m.profile
        }
        var message: ChatMessage {
            ChatMessage(id: id, fromUser: fromUser, speaker: speaker, body: body, date: Date(timeIntervalSince1970: date),
                        sessionID: sessionID, replyInterrupted: interrupted, profile: profile)
        }
    }
    struct Typing: Codable { var id: String, speaker: String, profile: String }
    struct Character: Codable { var id: String, name: String }
    struct Receipt: Codable { var id: String, fromUser: Bool, date: Double }
    struct Avatar: Codable {
        var png: Data?, color: [Double]?
        init(_ avatar: ProfileAvatar) {
            // ImageIO only: AppKit drawing would register the windowless share as a running app.
            if let cg = avatar.thumbnail {
                let data = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, cg, nil)
                    if CGImageDestinationFinalize(destination) { png = data as Data }
                }
            }
            if avatar.hasProfileColor, let rgb = avatar.color.usingColorSpace(.sRGB) {
                color = [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
            }
        }
        var avatar: ProfileAvatar {
            var result = ProfileAvatar()
            // Thumbnails are at most 64px; anything larger is not something the relay sends.
            if let png, png.count <= 256 * 1024, let source = CGImageSourceCreateWithData(png as CFData, nil),
               let cg = CGImageSourceCreateImageAtIndex(source, 0, nil), cg.width <= 512, cg.height <= 512 {
                result.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)); result.thumbnail = cg
            }
            if let color, color.count == 3, color.allSatisfy({ (0...1).contains($0) }) {
                result.hasProfileColor = true
                result.color = NSColor(srgbRed: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]), alpha: 1)
            }
            return result
        }
    }
    var tapFailure: ThreeTapFailure?
    var op: String
    var id: Int?
    var token: String?
    var text: String?
    var unread: Double?
    var profile: String?
    var row: Int64?
    var before: Message?
    var stores: Int?
    var reason: String?
    var messages: [Message]?
    var typing: [Typing]?
    var session: String?
    var characters: [Character]?
    var avatars: [String: Avatar]?
    var receipts: [Receipt]?
    var projects: [ThreadProject]?
    var usage: RelayUsage?
    var streams: [StreamPreview]?
    var slack: SlackActivity?
    /// Shared screen choices of one Slack account (`sync`), and whether they make the sender's screen the standard.
    var user: String?
    var entries: [String: SyncEntry]?
    var replace: Bool?
    init(op: String) { self.op = op }

    static let maximumLine = 64 * 1024
    /// Shared choices may carry a picture, so a Mac that presented the code may send longer lines.
    static let maximumAuthorizedLine = 2 << 20
    func line() -> Data { ((try? JSONEncoder().encode(self)) ?? Data()) + Data([0x0A]) }
    /// Splits complete lines off the front of a receive buffer. Undecodable lines are reported as nil.
    static func take(from buffer: inout Data) -> [RelayFrame?] {
        var frames: [RelayFrame?] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<end)
            buffer.removeSubrange(buffer.startIndex...end)
            if !line.isEmpty { frames.append(try? JSONDecoder().decode(RelayFrame.self, from: line)) }
        }
        return frames
    }
}

enum RelaySettings {
    static let defaultPort: UInt16 = 47810
    /// `relayPort` is the port this Mac shares on. Each macOS account sharing from the same Mac keeps its own fixed one
    /// (2026-10-25: mac-mini-m4-homeserver 47810, moyo 47811). `hermesRemotePort` is the port of the Mac this one reads from.
    static let hostKey = "hermesRemoteHost", portKey = "relayPort", remotePortKey = "hermesRemotePort"
    static var support: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder) }
    static var serverTokenURL: URL { support.appendingPathComponent("relay-token") }
    static var clientTokenURL: URL { support.appendingPathComponent("relay-peer-token") }
    static var port: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: portKey)
        return (1024...65535).contains(saved) ? UInt16(saved) : defaultPort
    }
    static var remotePort: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: remotePortKey)
        return (1024...65535).contains(saved) ? UInt16(saved) : defaultPort
    }
    /// What another Mac enters to read this one: `name:port`.
    static func address(_ host: String, port: UInt16) -> String { host + ":" + String(port) }
    /// `name` or `name:port` as typed on the reading Mac. A missing port is the default one.
    static func parseAddress(_ input: String) -> (host: String, port: UInt16)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = text, port = defaultPort
        if let colon = text.lastIndex(of: ":") {
            guard let number = Int(text[text.index(after: colon)...]), (1024...65535).contains(number) else { return nil }
            host = String(text[..<colon]); port = UInt16(number)
        }
        return validHost(host).map { ($0, port) }
    }
    static func validToken(_ text: String) -> String? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return token.count == 64 && token.allSatisfy({ $0.isHexDigit }) ? token : nil
    }
    static func readToken(_ url: URL) -> String? { (try? String(contentsOf: url, encoding: .utf8)).flatMap(validToken) }
    /// The code is readable only by this user, like the Hermes record it protects.
    static func writeToken(_ token: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The new code is written beside the old one and takes its place in one step, so a failed write leaves the old code in use.
        let fresh = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + "." + UUID().uuidString)
        guard FileManager.default.createFile(atPath: fresh.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]),
              rename(fresh.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: fresh)
            throw NSError(domain: "ddots.Relay", code: 1, userInfo: [NSLocalizedDescriptionKey: "연결 코드를 저장하지 못했어요."])
        }
    }
    static func serverToken(create: Bool) throws -> String? {
        if let token = readToken(serverTokenURL) { return token }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw NSError(domain: "ddots.Relay", code: 2, userInfo: [NSLocalizedDescriptionKey: "연결 코드를 만들지 못했어요."])
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        try writeToken(token, to: serverTokenURL)
        return token
    }
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func validHost(_ input: String) -> String? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: ".-").union(.alphanumerics)
        guard (1...253).contains(host.count), host.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) else { return nil }
        return host
    }
    /// Tailscale hands out addresses in 100.64.0.0/10. The relay listens there and nowhere else.
    static func isTailnet(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
    /// Tailscale's own address among this Mac's: one in its range on a tunnel interface. A carrier or another VPN
    /// can hand out addresses in the same range on other interfaces; the relay must not listen there.
    static func tailnetAddress(among addresses: [(interface: String, address: String)]) -> String? {
        addresses.first { $0.interface.hasPrefix("utun") && isTailnet($0.address) }?.address
    }
    static func tailnetAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list, found: [(interface: String, address: String)] = []
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append((String(cString: entry.pointee.ifa_name), String(cString: host)))
        }
        return tailnetAddress(among: found)
    }
}

/// The relay runs as its own launchd job, so quitting, pausing or updating the pet does not cut other Macs off.
enum RelayAgent {
    static let label = AppIdentity.bundleID + ".relay"
    static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist") }
    /// What the share says about itself, and whatever stops it, is kept here. No conversation and no code is written to it.
    static var logURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ddots/relay.log") }
    static func plist(executable: String, port: UInt16, log: String = RelayAgent.logURL.path) -> [String: Any] {
        ["Label": label, "ProgramArguments": [executable, "--relay", "--relay-port", String(port)],
         "RunAtLoad": true, "KeepAlive": true, "ProcessType": "Background", "ThrottleInterval": 10,
         "StandardOutPath": log, "StandardErrorPath": log]
    }
    @discardableResult private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl"); process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit(); return process.terminationStatus
    }
    static var isLoaded: Bool { launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 }
    /// The port the installed share was started with, read from its launch item.
    static var installedPort: UInt16? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let arguments = plist["ProgramArguments"] as? [String], let index = arguments.firstIndex(of: "--relay-port"),
              arguments.count > index + 1 else { return nil }
        return UInt16(arguments[index + 1])
    }
    /// A share started before `relayPort` was changed is started again on the port now chosen.
    static func followPort() {
        guard isLoaded, let installed = installedPort, installed != RelaySettings.port else { return }
        try? setEnabled(true)
    }
    static func setEnabled(_ enabled: Bool, executable: String? = Bundle.main.executablePath) throws {
        // A build run from elsewhere must not take down the share the installed app keeps.
        guard LoginLaunch.isInstalled(), let executable else {
            throw NSError(domain: "ddots.Relay", code: 3, userInfo: [NSLocalizedDescriptionKey: "응용 프로그램 폴더에 설치한 뒤 사용할 수 있어요"])
        }
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        guard enabled else { try? FileManager.default.removeItem(at: plistURL); return }
        _ = try RelaySettings.serverToken(create: true)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The log starts again once it has grown past a megabyte; the share writes a line only when it starts or waits.
        if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 1_000_000 { try? FileManager.default.removeItem(at: logURL) }
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, port: RelaySettings.port), format: .xml, options: 0)
        try data.write(to: plistURL, options: .atomic)
        guard launchctl(["bootstrap", "gui/\(getuid())", plistURL.path]) == 0 else {
            throw NSError(domain: "ddots.Relay", code: 4, userInfo: [NSLocalizedDescriptionKey: "공유 항목을 시작하지 못했어요."])
        }
    }
    /// `--relay-status`, `--relay-enable`, `--relay-disable` and `--relay-code` let the share be set up without the menu.
    static func runCommand(arguments: [String]) -> Bool {
        if arguments.contains("--relay-status") || arguments.contains("--relay-enable") || arguments.contains("--relay-disable") {
            if arguments.contains("--relay-enable") || arguments.contains("--relay-disable") {
                do { try RelayAgent.setEnabled(arguments.contains("--relay-enable")) }
                catch { fputs("공유 설정 변경 실패: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            print("relay=\(RelayAgent.isLoaded ? "on" : "off"); address=\(RelaySettings.tailnetAddress() ?? "없음"); port=\(RelaySettings.port)")
            return true
        }
        if arguments.contains("--relay-code") {
            guard let token = RelaySettings.readToken(RelaySettings.serverTokenURL) else { fputs("연결 코드가 아직 없어요. 먼저 공유를 켜 주세요.\n", stderr); exit(1) }
            print(token)
            return true
        }
        return false
    }
}
