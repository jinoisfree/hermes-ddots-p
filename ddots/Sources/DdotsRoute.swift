import Foundation

/// Local preview of the exported Hermes contract; the server owns approval routing.
enum DdotsRoute {
    typealias Decision = HermesRouting.Decision
    /// Only an explicit @alias is a call. Plain names never select a recipient.
    static func leadingCall(_ text:String)->(profile:String,call:String)? {
        var best:(profile:String,call:String)?
        for member in DdotsConfig.shared.members {
            let profile = HermesRouting.str(member["profile"])
            let names = [profile, HermesRouting.str(member["displayName"])] + HermesRouting.strings(member["aliases"])
            for name in names where !name.isEmpty && !profile.isEmpty {
                guard text.hasPrefix("@"+name), name.count > (best?.call.count ?? 1)-1 else { continue }
                if let next=text.dropFirst(name.count+1).first, next.isLetter || next.isNumber { continue }
                best=(profile,"@"+name)
            }
        }
        return best
    }
    static func preview(_ text:String, explicitProfile:String? = nil, threadProfile:String? = nil)->Decision {
        HermesRouting.decide(text, contract:DdotsConfig.shared.contract(hub:true), explicitProfile:explicitProfile,
                             threadProfile:threadProfile, fallback:DdotsConfig.shared.recipient)
    }
    static func decide(_ text:String, fallback:String=Ddots.defaultTarget, explicitProfile:String? = nil, threadProfile:String? = nil)->Decision {
        HermesRouting.decide(text, contract:DdotsConfig.shared.contract(hub:false), explicitProfile:explicitProfile,
                             threadProfile:threadProfile, fallback:fallback)
    }
}
