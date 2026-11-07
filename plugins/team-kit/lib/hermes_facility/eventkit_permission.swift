import EventKit
import Foundation

// Asks macOS for full calendar access once, from the gateway's own permission subject.
// It reads no events; the result is the only output.
@main
struct EventKitPermission {
    static func main() async {
        do {
            let granted = try await EKEventStore().requestFullAccessToEvents()
            print(granted ? "granted" : "denied")
        } catch {
            print("failed")
        }
    }
}
