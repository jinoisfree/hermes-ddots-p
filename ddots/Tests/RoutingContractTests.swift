import Foundation
@main struct RoutingContractTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide exported configuration JSON") }
        let data=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))
        let config=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        let routing=HermesRouting.dict(config["routing"])
        var failures=0,count=0
        for sample in config["routing_samples"] as? [[String:String]] ?? [] {
            for room in ["base","hub"] {
                count += 1
                let result=HermesRouting.decide(sample["text"]!,contract:HermesRouting.dict(routing[room]))
                if result.profile != sample[room] { print("MISMATCH \(room): \(sample["text"]!) → \(result.profile); expected \(sample[room]!)");failures += 1 }
            }
        }
        print("Routing contract: \(count) comparisons, \(failures) failures")
        if count < 60 || failures != 0 { exit(1) }
    }
}
