import Foundation

@main struct FileDropRunnerTests {
    static func main() throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1]), input = URL(fileURLWithPath: CommandLine.arguments[2])
        guard FileDropRunner.available(home) else { throw FileDropServiceError.unavailable }
        let start = Date()
        let output = try FileDropRunner.run(Data(contentsOf: input), home: home)
        let result = try JSONSerialization.jsonObject(with: output) as! [String: Any]
        let ids = (result["suggestions"] as! [[String: Any]]).compactMap { $0["id"] as? String }
        guard ids.contains("add_schedule"), (result["summary"] as? String)?.contains("마감") == true else { throw FileDropServiceError.unavailable }
        print("PASS real Foundation Process → stable hermes-run → installed gateway Python → synthetic Sonnet request")
        print("elapsed=\(Date().timeIntervalSince(start)) ids=\(ids.joined(separator: ","))")
    }
}
