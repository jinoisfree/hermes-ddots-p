import Foundation

/// Local preview of the exported Hermes contract; the server still owns thread/approval routing.
enum DdotsRoute {
    typealias Decision = HermesRouting.Decision
    static func direct(_ text:String)->String { HermesRouting.direct(text) }
    static func leadingCall(_ text:String)->(profile:String,call:String)? {
        var best:(profile:String,call:String)?
        for (name,profile) in HermesRouting.aliases(DdotsConfig.shared.contract(hub:false)) where !name.hasPrefix("@") {
            guard text.hasPrefix("@"+name),name.count>(best?.call.count ?? 1)-1 else{continue}
            if let next=text.dropFirst(name.count+1).first,next.isLetter || next.isNumber{continue}
            best=(profile,"@"+name)
        };return best
    }
    static func preview(_ text:String)->Decision { HermesRouting.decide(text,contract:DdotsConfig.shared.contract(hub:true)) }
    static func decide(_ text:String,fallback:String=Ddots.defaultTarget)->Decision {
        let result=HermesRouting.decide(text,contract:DdotsConfig.shared.contract(hub:false))
        return result.profile.isEmpty ? Decision(profile:fallback,reason:"fallback"):result
    }
}
