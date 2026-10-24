import Foundation

@main struct ConnectOfferTests {
    static func main() {
        let suite = "ddots-connect-offer-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_000)
        var input = ConnectOffer.Input(hermesDecided: false, relayConfigured: false, localHermesFound: false,
            slackConnected: false, slackAppInstalled: false, isSmoke: false)
        var policy = ConnectOffer(defaults: defaults)
        precondition(policy.next(input, now: now) == nil)
        input.slackAppInstalled = true
        precondition(policy.next(input, now: now) == .slack)
        input.slackAppInstalled = false; input.localHermesFound = true
        precondition(policy.next(input, now: now) == .slack)
        precondition(policy.next(input, now: now.addingTimeInterval(59)) == .slack)
        precondition(policy.next(input, now: now.addingTimeInterval(60)) == nil)
        precondition(!defaults.bool(forKey: "connectOfferResolved.slack"))
        policy = ConnectOffer(defaults: defaults)
        precondition(policy.next(input, now: now.addingTimeInterval(60)) == .slack)
        policy.resolve(.slack)
        policy = ConnectOffer(defaults: UserDefaults(suiteName: suite)!)
        precondition(policy.next(input, now: now) == nil)
        precondition(!defaults.bool(forKey: "connectOfferResolved.hermes"))
        input.slackConnected = true
        precondition(policy.next(input, now: now) == .hermes)
        defaults.set(false, forKey: "hermesChatEnabled")
        input.hermesDecided = defaults.object(forKey: "hermesChatEnabled") != nil
        precondition(policy.next(input, now: now) == nil)
        defaults.removeObject(forKey: "hermesChatEnabled"); input.hermesDecided = false
        input.relayConfigured = true
        precondition(policy.next(input, now: now) == nil)
        input.relayConfigured = false; input.localHermesFound = false
        precondition(policy.next(input, now: now) == nil)
        input.localHermesFound = true; input.isSmoke = true
        precondition(policy.next(input, now: now) == nil)
        input.isSmoke = false
        precondition(policy.next(input, now: now.addingTimeInterval(59)) == .hermes)
        precondition(policy.next(input, now: now.addingTimeInterval(60)) == nil)
        policy = ConnectOffer(defaults: defaults)
        precondition(policy.next(input, now: now) == .hermes)
        policy.resolve(.hermes)
        precondition(policy.next(input, now: now) == nil)
        precondition(defaults.bool(forKey: "connectOfferResolved.hermes"))
        defaults.removeObject(forKey: "connectOfferResolved.slack")
        for connected in [false, true] {
            for installed in [false, true] {
                for found in [false, true] {
                    for smoke in [false, true] {
                        let candidate = ConnectOffer.Input(hermesDecided: true, relayConfigured: false, localHermesFound: found,
                            slackConnected: connected, slackAppInstalled: installed, isSmoke: smoke)
                        var check = ConnectOffer(defaults: defaults)
                        precondition(check.next(candidate, now: now) == (!connected && (installed || found) && !smoke ? .slack : nil))
                    }
                }
            }
        }
        print("ConnectOfferTests passed: Slack first, app or local discovery, connected exclusion, Hermes after Slack, saved refusal, relay, resolution, timeout/restart, smoke")
    }
}
