import Foundation

@main
struct WebAddressTests {
    static func main() {
        func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
        check(WebAddress.isWeb(URL(string: "https://map.naver.com/p/entry")!) && WebAddress.isWeb(URL(string: "HTTP://example.com")!), "Web pages open in the pane")
        check(!WebAddress.isWeb(URL(string: "slack://channel?id=C1")!) && !WebAddress.isWeb(URL(string: "mailto:a@example.com")!)
              && !WebAddress.isWeb(URL(fileURLWithPath: "/tmp/a.pdf")), "Other schemes belong to other apps")
        check(WebAddress.showsFile(URL(fileURLWithPath: "/tmp/보고서.PDF")) && WebAddress.showsFile(URL(fileURLWithPath: "/tmp/a.png"))
              && WebAddress.showsFile(URL(fileURLWithPath: "/tmp/메모.txt")), "PDFs, pictures and text are drawn in the pane")
        check(!WebAddress.showsFile(URL(fileURLWithPath: "/tmp/a.hwp")) && !WebAddress.showsFile(URL(fileURLWithPath: "/tmp/a.xlsx"))
              && !WebAddress.showsFile(URL(string: "https://example.com/a.pdf")!), "Other files go to their own app")
        check(WebAddress.isText(URL(fileURLWithPath: "/tmp/a.MD")) && !WebAddress.isText(URL(fileURLWithPath: "/tmp/a.pdf")), "Text is read as UTF-8")

        check(WebAddress.destination(for: " https://example.com/a?b=1 ")?.absoluteString == "https://example.com/a?b=1", "An address is kept as typed")
        check(WebAddress.destination(for: "map.naver.com/p")?.absoluteString == "https://map.naver.com/p", "A bare host gets https")
        check(WebAddress.destination(for: "localhost:8080")?.absoluteString == "https://localhost:8080", "localhost is a host")
        let search = WebAddress.destination(for: "선릉역 스타벅스")
        check(search?.host == "www.google.com" && URLComponents(url: search!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "선릉역 스타벅스", "Words are searched for")
        check(WebAddress.destination(for: "스타벅스")?.host == "www.google.com", "One word without a dot is searched for")
        check(WebAddress.destination(for: "slack://open")?.host == "www.google.com", "Another app's address is not followed from the field")
        check(WebAddress.destination(for: "   ") == nil, "Nothing typed, nowhere to go")

        let folder = URL(fileURLWithPath: "/tmp/내려받기")
        check(WebAddress.downloadTarget(folder: folder, suggested: "a.pdf") { _ in false }.lastPathComponent == "a.pdf", "A free name is used as it is")
        let taken: Set<String> = ["a.pdf", "a 2.pdf"]
        check(WebAddress.downloadTarget(folder: folder, suggested: "a.pdf") { taken.contains($0.lastPathComponent) }.lastPathComponent == "a 3.pdf", "A taken name gets a number")
        check(WebAddress.downloadTarget(folder: folder, suggested: "../x/y.txt") { _ in false }.deletingLastPathComponent().path == folder.path, "A download never leaves its folder")
        check(WebAddress.downloadTarget(folder: folder, suggested: "") { _ in false }.lastPathComponent == "내려받은 파일", "A nameless download is still named")
        print("PASS: web addresses, files shown in the pane, typed destinations, download names")
    }
}
