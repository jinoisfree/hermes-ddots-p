import Foundation

@main struct ThreadLayoutDiagnosticsPolicyTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        typealias P = ThreadLayoutDiagnosticsPolicy
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-layout-policy-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        // One automatic record every ten minutes.
        expect(P.mayRecordAutomatically(in: folder, now: start), "an empty folder allows the first record")
        func write(_ date: Date, manual: Bool) { try! Data("{}".utf8).write(to: folder.appendingPathComponent(P.fileName(date, manual: manual))) }
        write(start, manual: false)
        expect(!P.mayRecordAutomatically(in: folder, now: start.addingTimeInterval(1)), "no second record at once")
        expect(!P.mayRecordAutomatically(in: folder, now: start.addingTimeInterval(599)), "none just before ten minutes")
        expect(P.mayRecordAutomatically(in: folder, now: start.addingTimeInterval(600)), "one at ten minutes")
        write(start.addingTimeInterval(1), manual: true)
        expect(!P.mayRecordAutomatically(in: folder, now: start.addingTimeInterval(300)), "a record the owner asked for does not move the automatic clock")
        expect(P.fileName(start, manual: true).hasSuffix("-manual.json") && P.fileName(start, manual: false).hasSuffix("-auto.json"), "file names say how they were made")
        expect(P.lastAutomatic(in: folder).map { abs($0.timeIntervalSince(start)) < 1 } == true, "the clock is read back from the newest automatic name")

        // The newest twenty automatic records stay; the owner's own are kept.
        for index in 1...30 { write(start.addingTimeInterval(Double(index) * 1000), manual: false) }
        P.pruneAutomatic(in: folder)
        let names = try! FileManager.default.contentsOfDirectory(atPath: folder.path)
        let autos = names.filter { $0.hasSuffix("-auto.json") }.sorted()
        expect(autos.count == 20, "twenty automatic records stay: \(autos.count)")
        expect(autos.last == P.fileName(start.addingTimeInterval(30_000), manual: false), "the newest stays")
        expect(!autos.contains(P.fileName(start, manual: false)) && !autos.contains(P.fileName(start.addingTimeInterval(10_000), manual: false)), "the oldest go first")
        expect(names.contains(P.fileName(start.addingTimeInterval(1), manual: true)), "a record the owner asked for is never pruned")

        // A violation must still be there at a later look, more than 0.3 s on.
        var confirmation = P.Confirmation()
        expect(confirmation.look([], at: 0).isEmpty, "nothing seen")
        expect(confirmation.look(["a"], at: 10).isEmpty && confirmation.waiting, "a first sighting waits")
        expect(confirmation.look(["a"], at: 10.2).isEmpty, "a second look under 0.3 s later does not confirm")
        expect(confirmation.look(["a", "b"], at: 10.4) == ["a"], "the same violation 0.3+ s later is confirmed, only the shared one")
        expect(!confirmation.waiting, "confirming starts afresh")
        _ = confirmation.look(["a"], at: 20)
        expect(confirmation.look([], at: 20.5).isEmpty && !confirmation.waiting, "a look that finds none forgets the sighting")
        _ = confirmation.look(["a"], at: 30)
        expect(confirmation.look(["b"], at: 30.5).isEmpty && confirmation.waiting, "a different violation does not confirm the first")
        expect(confirmation.look(["b"], at: 30.9) == ["b"], "but stays on watch and confirms itself")

        // The setting: on unless switched off.
        let suite = "ddots.layout-policy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        expect(P.enabled(defaults), "on by default")
        defaults.set(false, forKey: P.setting)
        expect(!P.enabled(defaults), "off when set to false")
        defaults.set(true, forKey: P.setting)
        expect(P.enabled(defaults), "on when set to true")
        defaults.set("NO", forKey: P.setting)
        expect(!P.enabled(defaults), "off when the command line says NO")
        P.forced = true; defaults.set(false, forKey: P.setting)
        expect(P.enabled(defaults), "a check's own switch wins")
        P.forced = nil
        print("ThreadLayoutDiagnosticsPolicyTests: \(checks) checks passed")
    }
}
