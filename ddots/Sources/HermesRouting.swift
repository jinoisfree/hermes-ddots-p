import Foundation

/// Model-free new-message preview. Does not claim threads, approve actions or send messages.
/// Mirrors team-kit hermes_router.common_router.select_profile.
/// The caller resolves real Slack mentions and thread ownership; pending approvals stay on the server.
enum HermesRouting {
    struct Decision: Equatable { var profile: String; var reason: String }
    static func dict(_ x: Any?) -> [String: Any] { x as? [String: Any] ?? [:] }
    static func str(_ x: Any?) -> String { x as? String ?? "" }
    static func strings(_ x: Any?) -> [String] { x as? [String] ?? [] }
    static func decide(_ input: String, contract: [String:Any], explicitProfile: String? = nil, threadProfile: String? = nil, fallback: String = "") -> Decision {
        if let profile = explicitProfile, !profile.isEmpty { return Decision(profile: profile, reason: "mention") }
        if let profile = threadProfile, !profile.isEmpty { return Decision(profile: profile, reason: "thread_continuation") }
        let recipient = fallback.isEmpty ? str(dict(contract["profiles"])["fallback"]) : fallback
        return Decision(profile: recipient, reason: "fallback")
    }
}
