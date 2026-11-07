import Foundation
import Network

@main struct FileDropRelayTests {
    static func check(_ value: @autoclosure () -> Bool, _ name: String) {
        guard value() else { fputs("FAIL \(name)\n", stderr); exit(1) }; print("PASS \(name)")
    }
    static func wait(_ condition: () -> Bool) {
        for _ in 0..<500 { if condition() { return }; Thread.sleep(forTimeInterval: 0.01) }
        check(false, "relay condition within 5 seconds")
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-drop-wire-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(repeating: 37, count: 1_600_001), original = root.appendingPathComponent("합성.hwpx")
        try body.write(to: original)
        let token = String(repeating: "ab", count: 32)
        let server = HermesRelayServer(home: root, token: token, interval: 0.1, syncFolder: root.appendingPathComponent("sync"), readUsage: { nil })
        let lock = NSLock(); var received = -1; var temporary: [URL] = []
        let reply = Data("{\"suggestions\":[],\"summary\":\"합성 결과\",\"confidence\":1,\"works\":[]}".utf8)
        server.dropOriginalsAllowed = { _ in true }
        server.dropSuggest = { data in
            let request = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            check((request["signals"] as? [String: Any])?["today"] as? String == "2026-11-07(토)", "AC-53 relay preserves the originating device today")
            let paths = (request["files"] as! [String]).map { URL(fileURLWithPath: $0) }
            let sizes = try paths.map { try Data(contentsOf: $0).count }
            if !paths.isEmpty { check(try! Data(contentsOf: paths[0]) == body, "encrypted route reconstructs every original byte") }
            lock.lock(); received = sizes.reduce(0, +); temporary = paths; lock.unlock()
            return reply
        }
        let port = try server.start(host: "127.0.0.1", port: 0); defer { server.stop() }
        let client = RemoteHermes(host: "127.0.0.1", port: port, token: token, includeMessages: false)
        client.dropOriginalsAllowed = { _ in false }; client.start(); defer { client.stop() }
        wait { client.supportsDrop }
        let request = try JSONSerialization.data(withJSONObject: ["signals": ["today": "2026-11-07(토)", "names": ["합성.hwpx"], "kinds": ["hwpx"], "partial": true, "content": ""], "files": [original.path]])
        let signalReply = try client.suggestDrop(request, files: [original])
        check(signalReply == reply, "signal-only relay works without message sharing")
        lock.lock(); let withoutOriginal = received; lock.unlock()
        check(withoutOriginal == 0, "AC-36 nonencrypted route sends zero original bytes")
        client.dropOriginalsAllowed = { _ in true }
        let fileReply = try client.suggestDrop(request, files: [original])
        check(fileReply == reply, "encrypted route returns correlated response")
        lock.lock(); let bytes = received, paths = temporary; lock.unlock()
        check(bytes == body.count, "multi-frame original reaches server only on verified route")
        wait { paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
        check(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "response removes server temporary originals")
        let bad = RemoteHermes(host: "127.0.0.1", port: port, token: String(repeating: "cd", count: 32), includeMessages: false)
        bad.start(); defer { bad.stop() }; Thread.sleep(forTimeInterval: 0.1)
        do { _ = try bad.suggestDrop(request, files: [original]); check(false, "unauthorized request rejected") } catch { print("PASS existing relay authentication denies request") }
        let tooLarge = Data(repeating: 0, count: 65 * 1024)
        do { _ = try client.suggestDrop(tooLarge, files: []); check(false, "64KB signals enforced") } catch { print("PASS 64KB signal bound") }
        let manifest = try JSONSerialization.data(withJSONObject: ["signals": ["partial": true], "uploads": [["name": "safe.pdf", "size": 1]]])
        do { _ = try FileDropUpload(data: manifest, originals: false); check(false, "server encryption boundary") } catch { print("PASS server rejects originals on unverified route") }
        let traversal = try JSONSerialization.data(withJSONObject: ["signals": [:], "uploads": [["name": "../escape.pdf", "size": 1]]])
        do { _ = try FileDropUpload(data: traversal, originals: true); check(false, "server path traversal") } catch { print("PASS traversal filename rejected") }
        let upload = try FileDropUpload(data: manifest, originals: true)
        try upload.append(Data([1]), file: 0, part: 0)
        do { try upload.append(Data([1]), file: 0, part: 0); check(false, "duplicate frame rejected") } catch { print("PASS duplicate/oversize upload frame rejected") }
        let localHistory = FileDropHistory(store: SettingsStore(user: "SYNTHETIC", folder: root.appendingPathComponent("history-cache"))!, device: "A")
        localHistory.send = { user, entries in client.sendDropSync(user: user, entries: entries) }
        for index in 0..<3 {
            localHistory.begin(id: "wire" + String(index), feature: "pdf|synthetic.app||", engine: "mac", names: ["합성.pdf"], shown: ["summarize", "compare", "explain"], profile: "work-assistant")
            localHistory.select("summarize", profile: "work-assistant")
        }
        let secondHistory = FileDropHistory(store: SettingsStore(user: "SYNTHETIC", folder: root.appendingPathComponent("history-other"))!, device: "B")
        let observer = RemoteHermes(host: "127.0.0.1", port: port, token: token, includeMessages: false)
        let historyLock = NSLock()
        observer.onDropSync = { _, entries in historyLock.withLock { secondHistory.receive(entries) } }
        observer.start(); defer { observer.stop() }; wait { observer.linked }
        observer.sendDropSync(user: "SYNTHETIC", entries: [:])
        wait { historyLock.withLock { secondHistory.habits(feature: "pdf|synthetic.app||")["summarize"] == 3 } }
        check(historyLock.withLock { secondHistory.habits(feature: "pdf|synthetic.app||")["summarize"] == 3 }, "AC-20 separate history document synchronizes through authenticated relay")
        check(FileManager.default.fileExists(atPath: FileDropHistory.folder(home: root).appendingPathComponent("SYNTHETIC.json").path) && !FileManager.default.fileExists(atPath: root.appendingPathComponent("sync/SYNTHETIC.json").path), "drop statistics use mini SSD original, never the screen-settings document")
        client.stop()
        localHistory.begin(id: "offline", feature: "pdf|synthetic.app||", engine: "mac", names: [], shown: ["summarize"], profile: "work-assistant")
        localHistory.select("summarize", profile: "work-assistant")
        let reconnected = RemoteHermes(host: "127.0.0.1", port: port, token: token, includeMessages: false)
        localHistory.send = { user, entries in reconnected.sendDropSync(user: user, entries: entries) }
        reconnected.onLinked = { localHistory.sendAll() }; reconnected.start(); defer { reconnected.stop() }
        wait { historyLock.withLock { secondHistory.habits(feature: "pdf|synthetic.app||")["summarize"] == 4 } }
        print("PASS AC-20 offline cached card is sent after reconnect without duplicate counts")
        // A relay without the suggestion capability retains the old welcome contract.
        let old = HermesRelayServer(home: root, token: token, interval: 0.1, syncFolder: root.appendingPathComponent("old-sync"), readUsage: { nil })
        let oldPort = try old.start(host: "127.0.0.1", port: 0); defer { old.stop() }
        let oldClient = RemoteHermes(host: "127.0.0.1", port: oldPort, token: token, includeMessages: false)
        oldClient.start(); defer { oldClient.stop() }; wait { oldClient.linked }
        do { _ = try oldClient.suggestDrop(request, files: [original]); check(false, "old relay rejected") } catch { print("PASS AC-11 old relay safely keeps fallback") }
    }
}
