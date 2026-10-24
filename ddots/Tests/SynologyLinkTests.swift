import Foundation

@main
struct SynologyLinkTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("synology-link-\(UUID().uuidString)").resolvingSymlinksInPath()
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("SynologyDrive-test")
        try fm.createDirectory(at: root.appendingPathComponent("업무/2026 보고"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("도구.app/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("밖"), withIntermediateDirectories: true)
        for name in ["업무/2026 보고/결과.pdf", "업무/사진.JPG", "업무/run.sh", "업무/이름없음", "업무/영상.mp4", "업무/묶음.zip", "업무/설치.PKG", "도구.app/Contents/메모.txt"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("x".utf8).write(to: base.appendingPathComponent("밖/비밀.pdf"))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("업무/사진.JPG").path)
        try fm.createSymbolicLink(at: root.appendingPathComponent("업무/바로가기.pdf"), withDestinationURL: base.appendingPathComponent("밖/비밀.pdf"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("나가는길"), withDestinationURL: base.appendingPathComponent("밖"))

        func link(_ path: String, host: String = "sample.quickconnect.to", encoded: Bool = false) -> URL {
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._/")
            return URL(string: "https://\(host)/d/f/abc#drive=" + (encoded ? path : path.addingPercentEncoding(withAllowedCharacters: allowed)!))!
        }
        func target(_ path: String, host: String = "sample.quickconnect.to", encoded: Bool = false) -> SynologyLink.Target? {
            SynologyLink.target(for: link(path, host: host, encoded: encoded), roots: [root])
        }

        check(SynologyLink.components(of: link("업무/2026 보고/결과.pdf")) ?? [] == ["업무", "2026 보고", "결과.pdf"], "The path is read from the fragment")
        check(target("업무/2026 보고/결과.pdf") == .open(root.appendingPathComponent("업무/2026 보고/결과.pdf")), "A document here opens here")
        check(target("업무/사진.JPG") == .open(root.appendingPathComponent("업무/사진.JPG")), "A picture opens whatever its permission bits say")
        check(target("업무/2026 보고") == .folder(root.appendingPathComponent("업무/2026 보고")) && target("업무/2026 보고/") == target("업무/2026 보고"), "A folder opens in Finder")
        check(target("업무/run.sh") == .reveal(root.appendingPathComponent("업무/run.sh")), "A script is only shown")
        check(target("업무/이름없음") == .reveal(root.appendingPathComponent("업무/이름없음")), "A file of no kind is only shown")
        check(target("업무/영상.mp4") == .open(root.appendingPathComponent("업무/영상.mp4")) && target("업무/묶음.zip") == .open(root.appendingPathComponent("업무/묶음.zip")), "Every other kind opens")
        check(target("업무/설치.PKG") == .reveal(root.appendingPathComponent("업무/설치.PKG")), "An installer is only shown whatever its case")
        check(target("도구.app") == .reveal(root.appendingPathComponent("도구.app")), "An app is never opened as a folder")
        check(target("도구.app/Contents/메모.txt") == .reveal(root.appendingPathComponent("도구.app/Contents/메모.txt")), "Nothing inside an app is opened")
        check(target("업무/없는 파일.pdf") == nil, "A file that is not here goes to the web")

        for path in ["../밖/비밀.pdf", "업무/../../밖/비밀.pdf", "%2e%2e/%EB%B0%96/%EB%B9%84%EB%B0%80.pdf", "/etc/hosts", "업무//사진.JPG", "./업무/사진.JPG", ""] {
            check(target(path, encoded: path.contains("%")) == nil, "A path that leaves the folder is refused: \(path)")
        }
        check(target("%252e%252e/x", encoded: true) == nil, "A path is decoded once")
        check(target("업무/바로가기.pdf") == nil, "A symbolic link is refused")
        check(target("나가는길/비밀.pdf") == nil && target("나가는길") == nil, "A symbolic link on the way is refused")

        check(target("업무/사진.JPG", host: "quickconnect.to.example.com") == nil && target("업무/사진.JPG", host: "example.com") == nil
              && target("업무/사진.JPG", host: "quickconnect.to") == nil, "Only QuickConnect hosts count")
        check(target("업무/사진.JPG", host: "sample.quickconnect.to") != nil, "The host is matched whatever its case")
        check(SynologyLink.target(for: URL(string: "https://sample.quickconnect.to/d/f/abc")!, roots: [root]) == nil
              && SynologyLink.target(for: URL(string: "https://sample.quickconnect.to/d/f/abc#file=a.pdf")!, roots: [root]) == nil, "A link with no drive path goes to the web")
        check(SynologyLink.target(for: URL(string: "file:///x#drive=a.pdf")!, roots: [root]) == nil, "Only web addresses count")
        check(SynologyLink.target(for: link("업무/사진.JPG"), roots: [base.appendingPathComponent("없음"), root]) != nil, "Each synced folder is tried")
        check(SynologyLink.target(for: link("비밀.pdf"), roots: [root.appendingPathComponent("나가는길")]) == nil, "A folder that is itself a link is not a root")

        let body = "찾았어요!\n- [결과](" + link("업무/2026 보고/결과.pdf").absoluteString + ") 최신본\n- " + link("업무/사진.JPG").absoluteString + ".\n- <" + link("업무/사진.JPG").absoluteString
            + "|같은 사진>\n- https://sample.quickconnect.to/d/f/abc\n- https://example.com/a#drive=x.pdf\n- " + link("../밖/비밀.pdf", encoded: false).absoluteString
        let found = SynologyLink.links(in: body)
        check(found.map(\.path) == ["업무/2026 보고/결과.pdf", "업무/사진.JPG"], "A message's files are found once each, in order, without refused paths")
        check(found[0].name == "결과.pdf" && found[0].folder == "업무/2026 보고" && found[0].url == link("업무/2026 보고/결과.pdf"), "Each file keeps its address, name and folder")
        check(SynologyLink.links(in: "링크 없음").isEmpty, "A message with no such link has no buttons")
        check(SynologyLink.actions.map(\.name) == ["경로", "열기", "다운", "수정", "확인"], "The five buttons, in order")

        var written = AttributedString("파일: "), bare = AttributedString(link("업무/2026 보고/결과.pdf").absoluteString), named = AttributedString("최신본")
        bare.link = link("업무/2026 보고/결과.pdf"); named.link = link("업무/사진.JPG")
        var other = AttributedString("https://example.com/a"); other.link = URL(string: "https://example.com/a")
        written.append(bare); written.append(AttributedString(" · ")); written.append(named); written.append(AttributedString(" · ")); written.append(other)
        let shown = SynologyLink.titled(written)
        check(String(shown.characters) == "파일: 결과.pdf · 최신본 · https://example.com/a", "A written-out address is shown as its file's name")
        check(shown.runs.filter { $0.link != nil }.map { $0.link! } == [link("업무/2026 보고/결과.pdf"), link("업무/사진.JPG"), URL(string: "https://example.com/a")!], "The name still opens the same address")
        print("PASS: Synology links opened locally, refused paths, symbolic links, kinds only shown")
    }
}
