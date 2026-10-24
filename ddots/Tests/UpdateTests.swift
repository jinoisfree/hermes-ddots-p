import Foundation

private final class UpdateResponse: URLProtocol {
    static var status = 200
    static var body = Data()
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status,
                            httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct UpdateTests {
    static func main() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
        }
        require(UpdateRelease.channel([:]).repository == "jinoisfree/hermes-ddots-p" && UpdateRelease.channel([:]).requiresToken, "missing channel preserves private defaults")
        let publicInfo: [String: Any] = ["DDotsUpdateRepository": "jinoisfree/hermes-ddots-p", "DDotsUpdateRequiresToken": false]
        require(UpdateRelease.channel(publicInfo).repository == "jinoisfree/hermes-ddots-p" && !UpdateRelease.channel(publicInfo).requiresToken, "explicit public channel")
        require(UpdateRelease.channel(["DDotsUpdateRepository": "untrusted/other", "DDotsUpdateRequiresToken": false]).requiresToken, "unrecognized channel cannot remove authentication")
        require(UpdateRelease.headers(token: "synthetic", requiresToken: false)["Authorization"] == nil, "public never forwards credentials")
        require(UpdateRelease.headers(token: "synthetic", requiresToken: true)["Authorization"] == "Bearer synthetic", "private authentication preserved")
        let fixture: [String: Any] = ["tag_name": "v1.7.0", "draft": false, "prerelease": false, "assets": [
            ["id": 101, "name": "appcast.xml", "state": "uploaded", "size": 500],
            ["id": 102, "name": "ddots-1.7.0-arm64.zip", "state": "uploaded", "size": 1234]]]
        func data(_ value: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: value) }
        let release = try UpdateRelease.decode(data(fixture))
        require(release.feedID == 101 && release.archiveID == 102, "release asset selection")
        for field in ["draft", "prerelease"] {
            var invalid = fixture; invalid[field] = true
            require((try? UpdateRelease.decode(data(invalid))) == nil, "unpublished releases are refused")
        }
        for version in ["v1.7.0-beta", "../1.7.0", "latest", "1"] {
            var invalid = fixture; invalid["tag_name"] = version
            require((try? UpdateRelease.decode(data(invalid))) == nil, "invalid release tag")
        }
        var duplicate = fixture
        var assets = fixture["assets"] as! [[String: Any]]; assets.append(assets[0]); duplicate["assets"] = assets
        require((try? UpdateRelease.decode(data(duplicate))) == nil, "ambiguous feed refused")
        var incomplete = fixture; incomplete["assets"] = []
        require((try? UpdateRelease.decode(data(incomplete))) == nil, "incomplete uploads refused")
        func allowed(file: URL? = nil, notes: URL? = nil, delta: Bool = false, kind: String = "application") -> Bool {
            release.allows(file: file ?? release.archiveURL, version: "1.7.0", size: 1234,
                           installation: kind, notes: notes, information: nil, hasDeltas: delta)
        }
        require(allowed(), "same release archive accepted")
        require(!allowed(file: URL(string: "https://api.github.com/repos/another/app/releases/assets/102")), "foreign repository refused")
        require(!allowed(file: URL(string: release.archiveURL.absoluteString + "?redirect=elsewhere")), "modified asset URL refused")
        require(!allowed(notes: URL(string: "https://example.invalid/notes")), "credentials never go to external notes")
        require(!allowed(delta: true) && !allowed(kind: "package"), "only full app archives allowed")
        require(UpdateCredential.validInput("synthetic_token_123"), "synthetic token accepted")
        require(!UpdateCredential.validInput("line\nbreak") && !UpdateCredential.validInput("한글"), "header injection rejected")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateResponse.self]
        let client = UpdateReleaseClient(configuration: configuration)
        defer { client.close() }
        for status in [200, 401, 403, 404, 302, 500] {
            UpdateResponse.status = status; UpdateResponse.body = data(fixture)
            let finished = DispatchSemaphore(value: 0)
            client.latest(token: "synthetic_token") { result in
                if status == 200 { require((try? result.get()) == release, "metadata decoded") }
                else { require((try? result.get()) == nil, "HTTP failure not an update") }
                finished.signal()
            }
            require(finished.wait(timeout: .now() + 3) == .success, "request completes")
        }
        for request in UpdateResponse.requests {
            require(request.url == UpdateRelease.latestURL, "only private repository metadata requested")
            require(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic_token", "private API authentication")
            require(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json", "JSON preflight")
        }

        let suite = "ddots.update-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let item = temporary.appendingPathComponent("relay.plist")
        let executable = temporary.appendingPathComponent("ddots.app/Contents/MacOS/ddots").path
        try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": [executable, "--relay"]],
                                           format: .xml, options: 0).write(to: item)
        var loaded = true, calls: [String] = []
        let command: ([String]) -> Int32 = { arguments in
            calls.append(arguments[0])
            if arguments[0] == "print" { return loaded ? 0 : 113 }
            if arguments[0] == "bootout" { loaded = false; return 0 }
            if arguments[0] == "bootstrap" { loaded = true; return 0 }
            return -1
        }
        try UpdateRelay.suspend(executable: executable, item: item, defaults: defaults, command: command)
        require(!loaded && defaults.string(forKey: UpdateRelay.restoreKey) == executable, "relay pauses with recovery marker")
        try UpdateRelay.restore(executable: executable, item: item, defaults: defaults, command: command)
        require(loaded && defaults.object(forKey: UpdateRelay.restoreKey) == nil, "relay restored on cancellation or relaunch")
        require(calls == ["print", "bootout", "print", "print", "bootstrap"], "only ddots service touched")
        do {
            try UpdateRelay.suspend(executable: executable, item: item, defaults: defaults, command: { _ in -1 })
            preconditionFailure("unobservable relay must block installation")
        } catch {}
        defaults.set(executable, forKey: UpdateRelay.restoreKey)
        try FileManager.default.removeItem(at: item)
        try UpdateRelay.restore(executable: executable, item: item, defaults: defaults, command: { _ in preconditionFailure("explicitly disabled relay stays off") })
        require(defaults.object(forKey: UpdateRelay.restoreKey) == nil, "disabled relay is not re-enabled")
        print("UpdateTests passed")
    }
}
