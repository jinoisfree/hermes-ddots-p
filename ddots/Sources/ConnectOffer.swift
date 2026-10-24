import Foundation

/// Connection suggestions use discovery results only; they never open a store or connect a service.
struct ConnectOffer {
    enum Kind: String {
        case hermes, slack
        var resolvedKey: String { "connectOfferResolved." + rawValue }
    }
    struct Input {
        var hermesDecided: Bool
        var relayConfigured: Bool
        var localHermesFound: Bool
        var slackConnected: Bool
        var slackAppInstalled: Bool
        var isSmoke: Bool
    }

    var defaults: UserDefaults = .standard
    private var firstShown: [Kind: Date] = [:]

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    mutating func next(_ input: Input, now: Date = Date()) -> Kind? {
        guard !input.isSmoke else { return nil }
        let candidates: [(Kind, Bool)] = [
            (.slack, !input.slackConnected && (input.slackAppInstalled || input.localHermesFound)),
            (.hermes, input.slackConnected && !input.hermesDecided && !input.relayConfigured && input.localHermesFound)
        ]
        for (kind, eligible) in candidates where eligible && !defaults.bool(forKey: kind.resolvedKey) {
            let began = firstShown[kind] ?? now
            firstShown[kind] = began
            if now.timeIntervalSince(began) < 60 { return kind }
        }
        return nil
    }

    func resolve(_ kind: Kind) { defaults.set(true, forKey: kind.resolvedKey) }
}
