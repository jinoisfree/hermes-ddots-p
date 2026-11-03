import Foundation
import AppKit
import CryptoKit

@main struct ClipboardHistoryTests {
    static func check(_ value: Bool, _ name: String) {
        guard value else { fputs("FAIL: \(name)\n", stderr); exit(1) }
        print("PASS: \(name)")
    }
    static func main() throws {
        setbuf(stdout, nil)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func text(_ value: String, secret: Bool = false) -> ClipboardInput { ClipboardInput(kind: .text, text: value, source: "Test App", secret: secret) }
        func noticeEntry(_ kind: ClipboardKind = .text, _ value: String = "", files: [String] = [], secret: Bool = false) -> ClipboardEntry {
            ClipboardEntry(kind: kind, text: value, files: files, digest: "fixture", copiedAt: now, source: "test", secret: secret)
        }
        for (entry, expected) in [
            (noticeEntry(.text, "회의 자료 정리"), "“회의 자료 정리”가 복사되었습니다"),
            (noticeEntry(.text, "책상"), "“책상”이 복사되었습니다"),
            (noticeEntry(.text, "책상".decomposedStringWithCanonicalMapping), "“책상”이 복사되었습니다"),
            (noticeEntry(.files, files: ["/synthetic/책상".decomposedStringWithCanonicalMapping]), "책상이 복사되었습니다"),
            (noticeEntry(.text, "  자료  정리 \n다음 줄"), "“자료 정리”가 복사되었습니다"),
            (noticeEntry(.text, "123456789012345678901"), "“12345678901234567890…”이(가) 복사되었습니다"),
            (noticeEntry(.text, "alpha"), "“alpha”이(가) 복사되었습니다"),
            (noticeEntry(.files, files: ["/synthetic/report.pdf"]), "report.pdf이(가) 복사되었습니다"),
            (noticeEntry(.files, files: ["/synthetic/“메모1"]), "“메모1이 복사되었습니다"),
            (noticeEntry(.files, files: ["/a", "/b", "/c"]), "파일 3개가 복사되었습니다"),
            (noticeEntry(.image), "이미지가 복사되었습니다"),
            (noticeEntry(.video), "동영상이 복사되었습니다"),
            (noticeEntry(.text, "pw-123", secret: true), "비밀 항목이 복사되었습니다")
        ] { check(ClipboardCopyNotice.message(entry) == expected, "T-38 exact copy name and particle") }
        for (number, particle) in [(0,"이"),(1,"이"),(2,"가"),(3,"이"),(4,"가"),(5,"가"),(6,"이"),(7,"이"),(8,"이"),(9,"가")] {
            check(ClipboardCopyNotice.message(noticeEntry(.text, "자료\(number)")) == "“자료\(number)”\(particle) 복사되었습니다", "T-38 spoken digit particle")
        }
        var feedback = ClipboardCopyNotice()
        feedback.show("first", now: 100)
        let entering = feedback.update(now: 100.125, reducedMotion: false)!
        check(entering.alpha > 0 && entering.alpha < 1 && entering.offset < 0, "T-38 eased entrance and upward movement")
        let steady = feedback.update(now: 100.25, reducedMotion: false)!
        check(steady.alpha == 1 && steady.offset == 0, "T-38 quarter-second entrance completes")
        check(feedback.update(now: 103.99, reducedMotion: false)?.alpha == 1, "T-38 four-second hold deadline")
        let leaving = feedback.update(now: 104.125, reducedMotion: false)!
        check(leaving.alpha > 0 && leaving.alpha < 1 && leaving.offset > 0, "T-38 eased exit")
        check(feedback.update(now: 104.25, reducedMotion: false) == nil, "T-38 fade completes within four seconds plus 0.3 tolerance")
        feedback.show("first", now: 200); feedback.show("second", now: 202)
        let replacedNotice = feedback.update(now: 202.125, reducedMotion: true)!
        check(replacedNotice.text == "second" && replacedNotice.previous == "first" && abs(replacedNotice.alpha + replacedNotice.previousAlpha - 1) < 0.001 && replacedNotice.offset == 0, "T-38 replacement crossfade without motion")
        check(feedback.update(now: 205, reducedMotion: true) != nil && feedback.update(now: 206.25, reducedMotion: true) == nil, "T-38 replacement restarts four-second deadline")
        feedback.show("rapid first", now: 300)
        let rapidBefore = feedback.update(now: 300.05, reducedMotion: false)!
        feedback.show("rapid second", now: 300.05)
        let rapidAfter = feedback.update(now: 300.05, reducedMotion: false)!
        check(abs(rapidBefore.alpha - rapidAfter.alpha - rapidAfter.previousAlpha) < 0.001 && abs(rapidBefore.offset - rapidAfter.offset) < 0.001, "T-38 rapid replacement preserves opacity and position continuously")
        var history = ClipboardHistory()
        let a = try history.insert(text("alpha"), now: now).0
        _ = try history.insert(text("beta"), now: now)
        history.update(a.id) { $0.pinned = true }
        _ = try history.insert(text("alpha"), now: now.addingTimeInterval(1))
        check(history.entries.count == 2 && history.entries[0].id == a.id && history.entries[0].pinned, "T-08 duplicate order and pin")
        let secret = try history.insert(text("pw-123", secret: true), now: now).0
        check(secret.preview == "••••••" && secret.title == "비밀" && !secret.matches("pw-123") && secret.matches("test app"), "T-04 concealed display and search")
        _ = try history.insert(text("알파"), now: now)
        check(history.entries.filter { $0.matches("ALPHA") }.count == 1 && history.entries.filter { $0.matches("알파") }.count == 1, "T-16 literal case and Korean search")
        let old = now.addingTimeInterval(-25 * 3600)
        var expired = ClipboardHistory()
        let pin = try expired.insert(text("pin"), now: old).0
        expired.update(pin.id) { $0.pinned = true }
        _ = try expired.insert(text("old"), now: old)
        check(expired.prune(now: now).count == 1 && expired.entries.map(\.id) == [pin.id], "T-15 one-day expiry preserves pin")
        var counted = ClipboardHistory(limits: ClipboardLimits(days: 0))
        for i in 0..<101 { _ = try counted.insert(text("item-\(i)"), now: now.addingTimeInterval(Double(i))) }
        check(counted.entries.count == 100 && counted.entries.last?.text == "item-1", "T-15 count eviction oldest first")
        var bounded = ClipboardHistory(limits: ClipboardLimits(days: 0, totalBytes: 8))
        _ = try bounded.insert(text("1234"), now: now)
        _ = try bounded.insert(text("56789"), now: now)
        check(bounded.entries.count == 1 && bounded.entries[0].text == "56789", "T-15 total byte limit")
        bounded.limits.dataBytes = 5
        do {
            _ = try bounded.insert(ClipboardInput(kind: .video, data: Data(repeating: 0, count: 6), source: "test"))
            check(false, "T-15 per-item size rejection")
        } catch ClipboardHistoryError.tooLarge { check(true, "T-15 per-item size rejection (injected cap)") }
        var actualLimit = ClipboardHistory()
        do {
            _ = try actualLimit.insert(ClipboardInput(kind: .video, data: Data(repeating: 0, count: 500 * 1024 * 1024 + 1), source: "test"))
            check(false, "T-15 actual 500MB limit")
        } catch ClipboardHistoryError.tooLarge { check(actualLimit.entries.isEmpty, "T-15 actual 500MB limit rejects before hashing") }
        var tabs = ClipboardTabs()
        check(tabs.items.map(\.name) == ["전체", "글자", "비밀번호", "사진·영상"], "T-24 default tab names and order")
        var typed = ClipboardHistory()
        _ = try typed.insert(text("글자"), now: now)
        _ = try typed.insert(text("암호", secret: true), now: now)
        _ = try typed.insert(ClipboardInput(kind: .image, data: Data([1]), source: "test"), now: now)
        _ = try typed.insert(ClipboardInput(kind: .files, files: ["/synthetic/movie.mp4"], source: "test"), now: now)
        _ = try typed.insert(ClipboardInput(kind: .files, files: ["/synthetic/report.pdf"], source: "test"), now: now)
        check(tabs.items.map { tab in typed.entries.filter(tab.contains).count } == [5, 1, 1, 2], "T-24 default tab filters")
        let firstID = tabs.items[0].id
        try tabs.rename(firstID, name: "모두")
        check(tabs.items[0].name == "모두", "T-25 rename")
        for invalid in [" ", "글자"] {
            do { try tabs.rename(firstID, name: invalid); check(false, "T-25 invalid name rejected") }
            catch ClipboardTabError.invalidName { check(true, "T-25 invalid name rejected") }
        }
        let fileTab = try tabs.add(name: "문서", kind: .files)
        tabs.move(fileTab, before: firstID)
        check(tabs.items[0].id == fileTab && typed.entries.filter(tabs.items[0].contains).count == 2, "T-26 add file filter and reorder")
        let custom1 = try tabs.add(name: "모음1", kind: .custom), custom2 = try tabs.add(name: "모음2", kind: .custom)
        let selected = Array(typed.entries.prefix(2))
        for entry in selected { typed.update(entry.id) { $0.memberships = [custom1, custom2] } }
        let tab1 = tabs.items.first { $0.id == custom1 }!, tab2 = tabs.items.first { $0.id == custom2 }!
        check(typed.entries.filter(tab1.contains).count == 2 && typed.entries.filter(tab2.contains).count == 2, "T-27 entry in two custom tabs")
        typed.update(selected[0].id) { $0.memberships.remove(custom1) }
        check(typed.entries.filter(tab1.contains).count == 1 && typed.entries.count == 5, "T-27 remove membership preserves entry")
        let roundtrip = try JSONDecoder().decode(ClipboardTabs.self, from: JSONEncoder().encode(tabs))
        check(roundtrip.items == tabs.items && roundtrip.selected == tabs.selected, "T-25 T-26 tab restart persistence")
        let before = typed.entries.count
        try tabs.remove(custom1)
        check(typed.entries.count == before, "T-26 deleting tab keeps entries")
        while tabs.items.count > 1 { try tabs.remove(tabs.items.last!.id) }
        do { try tabs.remove(tabs.items[0].id); check(false, "T-26 last tab retained") }
        catch ClipboardTabError.lastTab { check(tabs.items.count == 1, "T-26 last tab retained") }
        var kept = ClipboardHistory(limits: ClipboardLimits(days: 1, count: 0))
        let customEntry = try kept.insert(text("saved"), now: old) // cap zero initially removes the entry
        kept = ClipboardHistory(entries: [customEntry.0], limits: ClipboardLimits(days: 1, count: 0))
        kept.update(customEntry.0.id) { $0.memberships = [custom2] }
        check(kept.prune(now: now).isEmpty && kept.entries.count == 1, "T-28 membership protects expiry and count")
        kept.update(customEntry.0.id) { $0.memberships.removeAll() }
        check(kept.prune(now: now).count == 1, "T-28 released membership restores ordinary rules")
        let textTab = ClipboardTab(name: "글", kind: .text)
        check(typed.entries.filter { textTab.contains($0) && $0.matches("글자") }.count == 1, "T-29 search within current tab")
        _ = typed.remove { textTab.contains($0) && !$0.pinned }
        check(typed.entries.count == 4 && typed.entries.contains { $0.secret }, "T-29 clear text tab preserves other kinds")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-clipboard-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let keychain = ClipboardKeychain(service: "ddots.clipboard.test." + UUID().uuidString)
        defer { try? keychain.delete(); try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("clipboard"), temp = base.appendingPathComponent("exports")
        let store = ClipboardStore(root: root, temporary: temp, keychain: keychain)
        _ = try store.load()
        var archive = ClipboardArchive(entries: history.entries)
        let input = ClipboardInput(kind: .image, data: Data([1, 2, 3, 4]), dataType: "public.png", source: "test")
        let image = try history.insert(input, now: now).0
        try store.saveData(input.data!, id: image.dataID!)
        archive.entries = history.entries
        try store.save(archive)
        // Pre-v12 ciphertext has no optional pinOrder key; open it through the actual AES-GCM store.
        let legacyRoot = base.appendingPathComponent("legacy-clipboard")
        try FileManager.default.copyItem(at: root, to: legacyRoot)
        var legacyArchive = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as! [String: Any]
        legacyArchive["entries"] = (legacyArchive["entries"] as! [[String: Any]]).map { value -> [String: Any] in var item = value; item.removeValue(forKey: "pinOrder"); return item }
        let legacyKey = SymmetricKey(data: try keychain.read()!)
        let legacyCipher = try AES.GCM.seal(JSONSerialization.data(withJSONObject: legacyArchive), using: legacyKey).combined!
        try legacyCipher.write(to: legacyRoot.appendingPathComponent("index.aes"))
        let oldArchive = try ClipboardStore(root: legacyRoot, temporary: base.appendingPathComponent("legacy-exports"), keychain: keychain).load()
        check(oldArchive.entries == archive.entries && oldArchive.tabs.items == archive.tabs.items, "T-52 actual pre-v12 encrypted archive preserves all data and tabs")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        for file in files {
            let bytes = try Data(contentsOf: file)
            check(bytes.range(of: Data("alpha".utf8)) == nil && bytes.range(of: Data("pw-123".utf8)) == nil, "T-05 archive ciphertext")
            check((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "T-03 ciphertext permissions")
        }
        check((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "T-05 directory permissions")
        // T-34: the value is never written unencrypted, even during the undo window.
        let secretBytes = Data("undo-secret-bytes".utf8), trashID = UUID()
        try store.saveData(secretBytes, id: trashID)
        try store.trashData(trashID)
        let trashFile = store.trash.appendingPathComponent(trashID.uuidString + ".aes")
        check(try Data(contentsOf: trashFile).range(of: secretBytes) == nil, "T-34 trash remains encrypted")
        check((try FileManager.default.attributesOfItem(atPath: store.trash.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "T-34 trash directory permissions")
        try store.restoreData(trashID)
        check(try store.data(trashID) == secretBytes, "T-34 blob restored exactly")
        try store.trashData(trashID)
        var undo = ClipboardUndo()
        var saved = secret; saved.pinned = true; saved.memberships = [UUID()]
        _ = undo.append(saved, index: 1, now: now)
        undo.closed(now: now.addingTimeInterval(25))
        check(!undo.expired(now: now.addingTimeInterval(31)) && undo.expired(now: now.addingTimeInterval(35)), "T-34 later of last-delete 30s and close 10s")
        check(undo.reservedBytes == saved.byteCount, "T-34 undo reserves stored capacity")
        let restored = undo.pop()!
        check(undo.reservedBytes == 0, "T-34 restoration releases reserved capacity")
        var restoring = ClipboardHistory(entries: [a, image]); restoring.restore(restored.entry, at: restored.index)
        check(restoring.entries[1] == saved, "T-34 restore order pin and memberships")
        var recopied = ClipboardHistory()
        _ = try recopied.insert(text("pw-123"), now: now)
        let replaced = recopied.restore(saved, at: 0)
        check(replaced.count == 1 && recopied.entries == [saved], "T-08 T-34 recopy during undo merges and preserves secret pin membership")
        for index in 0..<11 { _ = undo.append(saved, index: index, now: now) }
        check(undo.items.count == 10 && undo.items.first?.index == 1, "T-34 recent ten deletions")
        let reopened = ClipboardStore(root: root, temporary: temp, keychain: keychain)
        check(try reopened.load().entries == archive.entries, "T-20 encrypted restart preserves entries and pin")
        check(!FileManager.default.fileExists(atPath: store.trash.path), "T-34 startup purges trash")
        // Interrupted deletion after index commit must keep unrelated records, removing only owned orphans.
        var interrupted = archive
        interrupted.entries.removeAll { $0.id == image.id }
        try reopened.save(interrupted)
        check(try reopened.load().entries == interrupted.entries, "T-34 interrupted deletion preserves unrelated records")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent(image.dataID!.uuidString + ".aes").path), "T-34 interrupted deletion disposes only orphan ciphertext")
        try reopened.saveData(input.data!, id: image.dataID!)
        try reopened.save(archive)
        let orphan = UUID()
        try reopened.saveData(Data([7, 8, 9]), id: orphan)
        _ = try reopened.load()
        check(!FileManager.default.fileExists(atPath: reopened.root.appendingPathComponent(orphan.uuidString + ".aes").path), "Unreferenced owned ciphertext recovered after interrupted save")
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let linkedRoot = base.appendingPathComponent("linked-root")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
        do {
            _ = try ClipboardStore(root: linkedRoot, temporary: temp, keychain: keychain).load()
            check(false, "T-14 rejects a redirected ownership root")
        } catch ClipboardStoreError.unsafePath {
            check(try Data(contentsOf: sentinel) == Data("keep".utf8), "T-14 redirected root preserves external files")
        }
        try FileManager.default.createSymbolicLink(at: store.trash, withDestinationURL: outside)
        do { try store.clearTrash(); check(false, "T-34 rejects redirected trash") }
        catch ClipboardStoreError.unsafePath { check(try Data(contentsOf: sentinel) == Data("keep".utf8), "T-34 redirected trash preserves external originals") }
        try FileManager.default.removeItem(at: store.trash)
        let original = base.appendingPathComponent("original.txt")
        try Data("untouched".utf8).write(to: original)
        _ = try history.insert(ClipboardInput(kind: .files, files: [original.path], source: "test"), now: now)
        let exported = try store.export(Data([4, 5]), extension: "png")
        let removed = history.remove { !$0.pinned }
        for entry in removed { if let id = entry.dataID { try store.removeData(id) } }
        try store.clearTemporary()
        check(history.entries.count == 1 && FileManager.default.fileExists(atPath: original.path) && !FileManager.default.fileExists(atPath: exported.path), "T-14 clear owns blobs and exports, preserves original and pin")
        _ = history.remove { _ in true }; check(history.entries.isEmpty, "T-14 clear including pins")
        try keychain.delete()
        let missingKey = ClipboardStore(root: root, temporary: temp, keychain: keychain)
        check(try missingKey.load().entries.isEmpty && missingKey.recoveredUnreadable, "T-05 missing key quarantines archive")
        check(try FileManager.default.contentsOfDirectory(atPath: base.path).contains { $0.hasPrefix(".unreadable-") }, "T-05 quarantine exists")

        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let monitor = ClipboardMonitor(board: board, allowed: { true })
        var reads = 0, collected = 0
        monitor.reader = { _, _, _ in reads += 1; return text("test") }
        monitor.onInput = { _ in collected += 1 }
        monitor.start()
        for type in [ClipboardPasteboard.transient, ClipboardPasteboard.generated, ClipboardPasteboard.legacyTransient] {
            board.clearContents(); board.setString("internal", forType: type); monitor.poll()
        }
        check(reads == 0 && collected == 0, "T-07 transient and autogenerated never read")
        monitor.excludedApps = ["excluded"]
        board.clearContents(); board.setString("excluded", forType: ClipboardPasteboard.source); board.setString("test", forType: .string); monitor.poll()
        check(reads == 0, "T-07 excluded app never reads payload")
        monitor.excludedApps = []
        monitor.allowed = { false }
        board.clearContents(); board.setString("test", forType: .string); monitor.poll()
        check(reads == 0, "T-19 denied permission never reads payload")
        var requests = 0
        monitor.canRequestPermission = { true }
        monitor.permissionReader = {
            requests += 1; _ = board.string(forType: .string)
            monitor.allowed = { true }; monitor.poll() // Permission dialogs may run nested timers.
            monitor.allowed = { false }
        }
        monitor.requestPermission()
        check(requests == 1 && reads == 0 && collected == 0, "T-33 explicit permission read once and discarded")
        monitor.canRequestPermission = { false }; monitor.requestPermission()
        check(requests == 1, "T-33 alwaysDeny cannot request")
        monitor.allowed = { true }
        board.clearContents(); board.setString("after allow", forType: .string); monitor.poll()
        check(reads == 1 && collected == 1, "T-33 next allowed poll collects")
        monitor.stop(); check(!monitor.polling, "T-18 stop disables polling")
        let actualMonitor = ClipboardMonitor(board: board, allowed: { true })
        var actualInput: ClipboardInput?
        actualMonitor.onInput = { actualInput = $0 }
        actualMonitor.start()
        board.clearContents(); board.setString("pw-123", forType: .string); board.setString("1", forType: ClipboardPasteboard.concealed)
        actualMonitor.poll()
        check(actualInput?.kind == .text && actualInput?.text == "pw-123" && actualInput?.secret == true, "T-04 real pasteboard concealed text payload")
        for type in ClipboardPasteboard.legacySecrets {
            actualInput = nil
            board.clearContents(); board.setString("pw-123", forType: .string); board.setString("1", forType: type); actualMonitor.poll()
            check(actualInput?.secret == true && actualInput?.text == "pw-123", "T-35 legacy concealed marker")
        }
        actualInput = nil
        actualMonitor.performOwnWrite {
            board.clearContents(); board.setString("self", forType: .string)
            actualMonitor.poll() // A nested pasteboard event cannot collect a partially written value.
        }
        actualMonitor.poll()
        check(actualInput == nil, "T-09 nested own write never collects")
        actualMonitor.stop()
        // T-30 uses the real Vision engine, with an independent literal expectation.
        let picture = NSImage(size: NSSize(width: 1000, height: 240))
        picture.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 1000, height: 240).fill()
        ("송장 1234\nINVOICE" as NSString).draw(at: NSPoint(x: 40, y: 35), withAttributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black])
        picture.unlockFocus()
        let recognized = try ClipboardOCR.recognize(data: picture.tiffRepresentation!) ?? ""
        check(recognized.contains("송장") && recognized.lowercased().contains("invoice"), "T-30 real Vision Korean and English recognition")
        history.update(a.id) { $0.recognizedText = recognized }
        try store.save(ClipboardArchive(entries: history.entries))
        check(try Data(contentsOf: store.root.appendingPathComponent("index.aes")).range(of: Data("송장".utf8)) == nil, "T-30 recognized text encrypted")
        print("ClipboardHistoryTests passed")
    }
}
