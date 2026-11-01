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
        let legacy: [String:Any] = ["profiles": ["fallback":"usual", "wiki":"guide"],
                                    "aliases": ["guide":["Guide"]], "patterns":["wiki":"위키"],
                                    "address_prefixes":["enabled":true,"profiles":["ㅎ":"guide"]]]
        for text in ["위키 찾아줘", "Guide 확인해줘", "이제 Guide 맡아줘", "ㅎ 일정 알려줘"] {
            precondition(HermesRouting.decide(text,contract:legacy).profile == "usual")
        }
        precondition(HermesRouting.decide("안녕",contract:legacy,explicitProfile:"mentioned",threadProfile:"owner").profile == "mentioned")
        precondition(HermesRouting.decide("승인",contract:legacy,threadProfile:"owner").profile == "owner")
        precondition(HermesRouting.decide("안녕",contract:legacy,fallback:"configured-default").profile == "configured-default")
        print("Routing contract: \(count) comparisons, \(failures) failures")
        if count < 60 || failures != 0 { exit(1) }
    }
}
