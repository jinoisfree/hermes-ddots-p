import Foundation
import AppKit

@main struct ClipboardFeaturesTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--stored-enabled" {
            let defaults = UserDefaults(suiteName: CommandLine.arguments[2])!
            guard ClipboardSettings.load(defaults).enabled == (CommandLine.arguments[3] == "true") else { exit(1) }
            print("PASS: T-64 new process reads persisted complete-feature switch"); return
        }
        if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--stored-layout" {
            let defaults = UserDefaults(suiteName: CommandLine.arguments[2])!
            let expected = CGSize(width: Double(CommandLine.arguments[3])!, height: Double(CommandLine.arguments[4])!)
            guard ClipboardDrawer.load(defaults) == expected else { exit(1) }
            print("PASS: T-45 new process reads persisted shelf dimensions"); return
        }
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fputs("FAIL: " + message + "\n", stderr); exit(1) }; print("PASS: " + message)
        }
        func entry(_ text: String, secret: Bool = false) -> ClipboardEntry {
            ClipboardEntry(kind: .text, text: text, digest: text, copiedAt: Date(), source: "fixture", secret: secret)
        }
        let suite = "ddots-clipboard-layout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for enabled in [false, true] {
            var settings = ClipboardSettings(); settings.enabled = enabled
            defaults.set(try JSONEncoder().encode(settings), forKey: ClipboardSettings.key); defaults.synchronize()
            let restart = Process(); restart.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            restart.arguments = ["--stored-enabled", suite, String(enabled)]
            try restart.run(); restart.waitUntilExit()
            check(restart.terminationStatus == 0, "T-64 off/on settings survive process restart")
        }
        let bounds = CGRect(x: 0, y: 0, width: 356, height: 454)
        for below in [false, true] {
            for height in [ClipboardDrawer.rowHeight, ClipboardDrawer.footerHeight] {
                let r = ClipboardDrawer.regions(in: bounds, rowHeight: height, below: below)
                check(r.row.height == height && r.content.height + height == bounds.height && !r.content.intersects(r.row), "T-65 row/content tile the same surface without overlap")
                check(below ? r.row.maxY == bounds.maxY : r.row.minY == bounds.minY, "T-65 row stays on the pet edge")
            }
            let edge = CGPoint(x: bounds.midX, y: below ? bounds.minY : bounds.maxY)
            let opposite = CGPoint(x: bounds.midX, y: below ? bounds.maxY : bounds.minY)
            check(ClipboardDrawer.resizeEdge(at: edge, bubble: bounds, below: below) == .far && ClipboardDrawer.resizeEdge(at: opposite, bubble: bounds, below: below).isEmpty, "T-65 only the far vertical edge resizes")
            let head = CGRect(x: 130, y: below ? 490 : -80, width: 90, height: 55)
            let bridge = CGPoint(x: head.midX, y: below ? 475 : -10)
            check(ClipboardDrawer.containsPointer(bridge, head: head, bubble: bounds) && !ClipboardDrawer.containsPointer(CGPoint(x: 380, y: 230), head: head, bubble: bounds), "T-65 bridge included and physical outside excluded")
        }
        check(ClipboardDrawer.columns(width: 356) == 3 && ClipboardDrawer.columns(width: 476) == 4 && ClipboardDrawer.columns(width: 1) == 2, "T-45 fixed card pitch changes only column count")
        ClipboardDrawer.save(CGSize(width: 476, height: 600), defaults: defaults)
        check(ClipboardDrawer.load(defaults) == CGSize(width: 476, height: 600), "T-45 user dimensions persist")
        defaults.synchronize()
        let restart = Process(); restart.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); restart.arguments = ["--stored-layout", suite, "476", "600"]
        try restart.run(); restart.waitUntilExit()
        check(restart.terminationStatus == 0, "T-45 restart process retains the user's dimensions")
        check(ClipboardDrawer.constrained(.zero) == ClipboardDrawer.minimumSize, "T-45 two-column one-row minimum")
        var tiff = entry("fixture"); tiff.kind = .image; tiff.dataType = "public.tiff"
        check(tiff.exportExtension == "tiff", "T-47 preview and drag keep TIFF extension")
        tiff.kind = .video; tiff.dataType = "com.apple.quicktime-movie"
        check(tiff.exportExtension == "mov", "T-47 QuickTime preview and drag keep MOV extension")
        let original = entry("saved before v12")
        let encoded = try JSONEncoder().encode(original)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "pinOrder")
        let decoded = try JSONDecoder().decode(ClipboardEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        check(decoded.text == original.text && decoded.pinOrder == nil && decoded.id == original.id, "T-52 pre-v12 encrypted archive entry decodes with no pin order")
        var undo = ClipboardUndo(); let group = UUID(), now = Date()
        for i in 0..<3 { _ = undo.append(entry("batch \(i)"), index: i, now: now, group: group) }
        check(undo.popGroup().map(\.index) == [0, 1, 2] && undo.items.isEmpty, "T-51 one undo restores a complete selected group")
        _ = undo.append(original, index: 0, now: now)
        _ = undo.append(entry("separate"), index: 1, now: now)
        check(undo.popGroup().count == 1 && undo.items.count == 1, "T-51 independent deletes remain independent")
        var transformed = ClipboardHistory()
        let sourceInput = ClipboardInput(kind: .text, text: "ABC", source: "fixture")
        let originalTransform = try transformed.insert(sourceInput).0
        let unchangedResult = try transformed.insert(ClipboardInput(kind: .text, text: "ABC", source: "ddots"), deduplicating: false).0
        check(unchangedResult.id != originalTransform.id && transformed.entries.last == originalTransform, "T-55 even unchanged transform preserves original metadata as separate item")
        let duplicates = transformed.entries
        _ = transformed.remove { _ in true }
        let restoring = Set(duplicates.map(\.id))
        for (index, saved) in duplicates.enumerated() { _ = transformed.restore(saved, at: index, preservingIDs: restoring) }
        check(transformed.entries == duplicates, "T-51 group undo preserves distinct derived cards with equal text")
        _ = try transformed.insert(ClipboardInput(kind: .text, text: "password", source: "fixture", secret: true))
        let collision = try transformed.insert(ClipboardInput(kind: .text, text: "password", source: "ddots"), deduplicating: false).0
        check(collision.secret, "T-55 transform never removes known concealed classification")
        check(ClipboardTextTransform.whitespace.apply("  a  b \n c ") == "a b c", "T-55 whitespace")
        check(ClipboardTextTransform.singleLine.apply("a\nb") == "a b", "T-55 single line")
        check(ClipboardTextTransform.uppercase.apply("ab") == "AB" && ClipboardTextTransform.lowercase.apply("AB") == "ab", "T-55 case")
        check(ClipboardTextTransform.json.apply("oops") == nil && ClipboardTextTransform.json.apply("{\"a\":1}")?.contains("\n") == true, "T-55 valid JSON only")
        for percent in [55.0, 65, 100] {
            defaults.set(percent, forKey: ClipboardDrawer.opacityKey)
            check(ClipboardDrawer.opacity(defaults) == percent, "T-60 opacity preference independent")
            for dark in [false, true] { check(BubbleOpacity.worstContrast(alpha: BubbleOpacity.alpha(progress: 1, percent: percent, reduceTransparency: false), darkAppearance: dark) >= 4.5, "T-60 worst wallpaper contrast") }
        }
        func contrast(_ foreground: Double, _ background: [Double]) -> Double {
            func linear(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            let luminance = zip([0.2126, 0.7152, 0.0722], background).reduce(0) { $0 + $1.0 * linear($1.1) }
            return foreground == 1 ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
        }
        for percent in stride(from: 55.0, through: 100.0, by: 1) {
            for dark in [false, true] {
                let ink = ClipboardAppearance.primary(dark: dark).usingColorSpace(.deviceRGB)!
                check(ink.alphaComponent == 1, "T-60 glass text alpha is fully opaque")
                let alpha = percent / 100
                let base = dark ? [0.015, 0.02, 0.04].map { 1 - alpha + alpha * $0 } : [alpha, alpha, alpha]
                for hover in [0.0, 0.5, 1] {
                    let shaded = base.map { $0 * (1 - (dark ? ClipboardAppearance.darkHoverShade * hover : 0)) }
                    let hovered = shaded.map { $0 * (1 - 0.12 * hover) + (dark ? 0.12 * hover : 0) }
                    let preview = hovered.map { $0 * (dark ? 1 - ClipboardAppearance.darkPreviewShade : 1) * 0.91 + 0.09 }
                    check(contrast(dark ? 1 : 0, hovered) >= 4.5 && contrast(dark ? 1 : 0, preview) >= 4.5, "T-60 card/time contrast at all hover stages")
                }
                let selection = ClipboardAppearance.selection(dark: dark).usingColorSpace(.deviceRGB)!
                let selected = base.map { $0 * (1 - selection.alphaComponent) + selection.redComponent * selection.alphaComponent }
                check(contrast(dark ? 1 : 0, selected) >= 4.5, "T-60 selected tab contrast")
            }
        }
        var inputs = 0
        let publicEntry = entry("서울시 강남구 합성로 10"), secret = entry("never-feed-secret", secret: true)
        var recognized = entry(""); recognized.kind = .image; recognized.text = nil; recognized.recognizedText = "이미지 속 합성 주소"
        var secretImage = entry("", secret: true); secretImage.kind = .image; secretImage.text = nil; secretImage.recognizedText = "never-feed-secret"
        let imageCandidate = recognized, concealedImage = secretImage
        let engine = ClipboardSemanticSearch(available: true) { query, candidates in
            await MainActor.run {
                check(!candidates.contains { $0.id == secret.id || $0.id == concealedImage.id || $0.text.contains("never-feed-secret") }, "T-56 zero secret model inputs")
                check(candidates.contains { $0.id == imageCandidate.id && $0.text == "이미지 속 합성 주소" }, "T-56 image OCR text reaches only the non-secret candidate boundary")
                inputs += 1
            }
            return [0, 99]
        }
        engine.search("주소", entries: [secret, publicEntry], enabled: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        check(inputs == 0 && engine.ids.isEmpty, "T-56 disabled search sends no model input")
        engine.search("주소", entries: [secret, concealedImage, publicEntry, imageCandidate], enabled: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        check(inputs == 1 && engine.ids == [publicEntry.id], "T-56 valid semantic result excludes invalid IDs")
        let slow = ClipboardSemanticSearch(available: true) { _, _ in try? await Task.sleep(nanoseconds: 2_300_000_000); return [0] }
        let start = ProcessInfo.processInfo.systemUptime
        slow.search("주소", entries: [publicEntry], enabled: true)
        try await Task.sleep(nanoseconds: 2_450_000_000)
        check(slow.ids.isEmpty && ProcessInfo.processInfo.systemUptime - start < 2.8, "T-56 late engine cannot replace literal-only fallback")
        let unavailable = ClipboardSemanticSearch(available: false) { _, _ in fatalError("unavailable engine called") }
        unavailable.search("주소", entries: [publicEntry], enabled: true)
        check(unavailable.ids.isEmpty && !unavailable.available, "T-56 unavailable model has no invocation")
        print("METRIC actual on-device model available=\(ClipboardSemanticSearch.isAvailable)")
        if ClipboardSemanticSearch.isAvailable {
            let candidates = [publicEntry, entry("https://www.apple.com"), entry("회의 안건과 일정")].map {
                ClipboardSemanticSearch.Candidate(id: $0.id, text: $0.text!, kind: "text", copiedAt: $0.copiedAt)
            }
            let began = ProcessInfo.processInfo.systemUptime
            let indices = try await ClipboardSemanticSearch.rankOnDevice("주소", candidates: candidates)
            print("METRIC actual on-device address search seconds=\(ProcessInfo.processInfo.systemUptime - began), returnedIndices=\(indices)")
            check(indices.contains(0), "T-56 actual Apple model recognizes Korean address")
            // Warm model still uses the product's strict two-second deadline.
            let real = ClipboardSemanticSearch()
            real.search("주소", entries: [secret, publicEntry], enabled: true)
            try await Task.sleep(nanoseconds: 2_150_000_000)
            print("METRIC real product semantic match=\(real.ids.contains(publicEntry.id)); literal fallback retained after 2s")
        }
        defaults.removePersistentDomain(forName: suite)
    }
}
