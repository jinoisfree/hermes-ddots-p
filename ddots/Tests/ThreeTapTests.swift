import Foundation

@main struct ThreeTapTests {
    static var checks = 0
    static func check(_ value: Bool, _ text: String) { guard value else { fatalError(text) }; checks += 1 }
    @MainActor static func main() throws {
        func fingers(_ n: Int, drift: Double = 0) -> [TapContact] { (0..<n).map { TapContact(id: $0, x: 0.2+Double($0)*0.1+drift, y: 0.5) } }
        func sequence(_ frames: [(Double, Int, Double)]) -> [Bool] {
            var gesture = ThreeTapGesture()
            return frames.map { gesture.receive(fingers($0.1, drift: $0.2), at: $0.0) }
        }
        check(sequence([(0,3,0),(0.1,0,0)]).last == true, "three fingers tap")
        check(sequence([(0,2,0),(0.1,0,0)]).last == false, "two fingers do not tap")
        check(sequence([(0,3,0),(0.05,4,0),(0.1,3,0),(0.2,0,0)]).last == false, "a fourth finger rejects the whole gesture")
        check(sequence([(0,3,0),(0.31,0,0)]).last == false, "long press rejected")
        check(sequence([(0,3,0),(0.1,3,0.1),(0.2,0,0)]).last == false, "swipe rejected")
        check(sequence([(0,1,0),(0.02,2,0),(0.04,3,0),(0.08,2,0),(0.1,1,0),(0.12,0,0)]).last == true, "staggered landing and lift")
        check(sequence([(0,3,0),(0.1,0,0),(0.2,3,0),(0.3,0,0),(0.6,3,0),(0.7,0,0)]).filter { $0 }.count == 2, "cooldown")
        check(sequence([(0,3,0),(0.1,3,.nan),(0.2,0,0)]).last == false, "invalid location rejected")
        let raw = (0..<3).map { ThreeTapContact(id: $0, state: 4, x: 0.2+Double($0)*0.1, y: 0.5) }
        var frames = ThreeTapFrames()
        check(frames.receive(raw, count: 3, at: 0) == .valid(tapped: false), "valid frame starts a gesture")
        check(frames.receive(nil, count: 20, at: 0.05) == .ignored, "one bad frame is ignored")
        check(frames.receive([], count: 0, at: 0.1) == .valid(tapped: false), "interrupted gesture cannot tap")
        _ = frames.receive(raw, count: 3, at: 0.2)
        check(frames.receive([], count: 0, at: 0.3) == .valid(tapped: true), "tap after a bad frame works")
        frames = ThreeTapFrames()
        for i in 0..<29 { check(frames.receive(nil, count: -1, at: Double(i)) == .ignored, "bad frames below the limit") }
        check(frames.receive(nil, count: -1, at: 29) == .failed("접촉 프레임 검사: 개수"), "thirty bad startup frames fail")
        frames = ThreeTapFrames()
        for i in 0..<29 { _ = frames.receive(nil, count: 20, at: Double(i)) }
        _ = frames.receive([], count: 0, at: 29)
        check(frames.receive(nil, count: 20, at: 30) == .ignored, "valid frame resets the failure streak")
        frames = ThreeTapFrames()
        let edge = [ThreeTapContact(id: 1, state: 4, x: -0.04, y: 1.04)]
        check(frames.receive(edge, count: 1, at: 0) == .valid(tapped: false), "edge tolerance is accepted and clamped")
        check(frames.receive(raw, count: 3, at: 1) == .valid(tapped: false), "valid frame before clock reset")
        check(frames.receive(raw, count: 3, at: 0.1) == .ignored, "backwards time resets without fault")
        check(frames.receive([], count: 0, at: 0.2) == .valid(tapped: false), "clock reset cancels the old gesture")
        _ = frames.receive(raw, count: 3, at: 0.3)
        check(frames.receive([], count: 0, at: 0.4) == .valid(tapped: true), "tap works on restarted clock")
        for (bad, reason) in [([ThreeTapContact(id: 0, state: 8, x: 0, y: 0)], "상태"),
                              ([ThreeTapContact(id: 0, state: 4, x: 1.06, y: 0)], "좌표"),
                              ([raw[0], raw[0]], "ID 중복")] {
            frames = ThreeTapFrames()
            for _ in 0..<29 { _ = frames.receive(bad, count: bad.count, at: 0) }
            check(frames.receive(bad, count: bad.count, at: 0) == .failed("접촉 프레임 검사: " + reason), "fault identifies the failed validation")
        }
        let old = [ThreeTapDeviceIdentity(pointer: 1, id: 10)], same = [ThreeTapDeviceIdentity(pointer: 2, id: 10)]
        check(ThreeTapDeviceIdentity.keep(old, same, allRunning: true, cfEqual: false), "same ID with a new pointer keeps registration")
        check(!ThreeTapDeviceIdentity.keep(old, [], allRunning: true, cfEqual: false), "device removal refreshes")
        check(!ThreeTapDeviceIdentity.keep(old, same + [.init(pointer: 3, id: 20)], allRunning: true, cfEqual: false), "device addition refreshes")
        check(!ThreeTapDeviceIdentity.keep(old, [.init(pointer: 2, id: 20)], allRunning: true, cfEqual: false), "known replacement refreshes even at equal count")
        check(!ThreeTapDeviceIdentity.keep(old, same, allRunning: false, cfEqual: true), "stopped devices restart")
        check(ThreeTapDeviceIdentity.keep([.init(pointer: 1, id: nil)], [.init(pointer: 2, id: nil)], allRunning: true, cfEqual: true), "CF equality keeps registration without optional ID")
        check(ThreeTapDeviceIdentity.keep([.init(pointer: 1, id: nil)], [.init(pointer: 2, id: nil)], allRunning: true, cfEqual: false), "unknown identities retain running devices at equal count")
        var state = ThreeTapCheck(); state.begin(os: "one")
        check(state.receive(.absent, os: "one", failureKey: "") == nil && state.lastOS == "one", "no trackpad is quiet")
        check(state.receive(.checking, os: "one", failureKey: "") == nil, "registration alone is not proof of callbacks")
        check(state.receive(.ready, os: "one", failureKey: "") == nil, "first launch does not announce an update")
        state.begin(os: "two")
        check(state.receive(.absent, os: "two", failureKey: "") == nil && state.pendingUpdate, "missing device preserves pending OS check")
        state = ThreeTapCheck(lastOS: state.lastOS, failures: state.failures, pendingUpdate: state.pendingUpdate)
        state.begin(os: "two")
        check(state.receive(.ready, os: "two", failureKey: "") == .healthy, "first working callback after update announces success")
        check(state.receive(.ready, os: "two", failureKey: "") == nil, "success announced once")
        check(state.receive(.failed("missing"), os: "two", failureKey: "two-app-missing") == .failure, "fault announced")
        state.begin(os: "two")
        check(state.receive(.failed("missing"), os: "two", failureKey: "two-app-missing") == nil, "same failure suppressed after restart")
        check(state.receive(.failed("missing"), os: "two", failureKey: "two-newapp-missing") == .failure, "new app version may report again")
        let failure = ThreeTapFailure(mac: "검사용 Mac", os: "27.0.1", build: "26A434", app: "1.6.36", appBuild: "74", stage: "기호 없음: MTDeviceStart")
        check(failure.valid && failure.request.contains("26A434") && failure.request.contains("74") && failure.request.contains("ThreeTapReader.swift"), "complete copy request")
        var invalid = failure; invalid.stage = "MEDIA:/private/example"
        check(!invalid.valid, "relay facts cannot become Hermes attachments")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = home.appendingPathComponent("fake-hermes")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$TAP_TEST_DIR/args\"\nprintf '%s' \"$HERMES_HOME\" > \"$TAP_TEST_DIR/home\"\ncat > \"$TAP_TEST_DIR/input\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var command = ThreeTapCommand.make(failure, executable: executable, home: home)!
        command.environment["TAP_TEST_DIR"] = home.path
        check(command.run() == 0, "fake command executes")
        check(try String(contentsOf: home.appendingPathComponent("args"), encoding: .utf8) == "-p\nsystem-doctor\nsend\n--to\nslack:\(ThreeTapCommand.channel)\n--file\n-\n--quiet\n", "fixed profile and channel, no DM")
        check(try String(contentsOf: home.appendingPathComponent("home"), encoding: .utf8) == home.appendingPathComponent(".hermes/profiles/system-doctor").path, "profile environment")
        check(try Data(contentsOf: home.appendingPathComponent("input")) == command.input, "body through stdin")
        let early = home.appendingPathComponent("early-exit")
        try "#!/bin/sh\nexit 7\n".write(to: early, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: early.path)
        var brokenPipe = command; brokenPipe.executable = early; brokenPipe.input = Data(repeating: 65, count: 131072)
        check(brokenPipe.run() != 0, "an early child exit cannot terminate ddots through SIGPIPE")
        check(ThreeTapCommand.make(invalid, executable: executable, home: home) == nil, "bad relay input does not execute")
        let suite = "ddots.three-tap.test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = ThreeTapController(defaults: defaults, live: false)
        controller.toggle()
        check(!controller.enabled && defaults.object(forKey: "threeTapEnabled") as? Bool == false, "off preference saved in isolated defaults")
        let restored = ThreeTapController(defaults: defaults, live: false)
        check(!restored.enabled, "off preference restored")
        let profile = home.appendingPathComponent(".hermes/profiles/system-doctor")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable, to: bin.appendingPathComponent("hermes"))
        let lock = NSLock(), sent = DispatchSemaphore(value: 0)
        var commands = 0
        let sender = ThreeTapSender(defaults: defaults, home: home) { command in
            lock.lock(); commands += 1; lock.unlock(); sent.signal(); return 7
        }
        sender.send(failure)
        check(sent.wait(timeout: .now()+2) == .success, "fake failure sender invoked")
        sender.send(failure)
        check(sent.wait(timeout: .now()+0.15) == .timedOut, "failed delivery is attempted only once")
        var upgraded = failure; upgraded.appBuild = "75"
        sender.send(upgraded)
        check(sent.wait(timeout: .now()+2) == .success, "new version gets one new attempt")
        lock.lock(); let total = commands; lock.unlock()
        check(total == 2, "no unexpected maintenance execution")
        print("PASS: \(checks) three-finger gesture, health, request and fake maintenance command checks")
    }
}
