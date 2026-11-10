import Foundation
import Contacts
let status = CNContactStore.authorizationStatus(for: .contacts)
if status == .authorized { print("granted") }
else if status == .denied || status == .restricted { print("denied") }
else if CommandLine.arguments.last != "request" { print("not_determined") }
else {
    var finished = false
    CNContactStore().requestAccess(for: .contacts) { allowed, _ in
        print(allowed ? "granted" : "denied")
        finished = true
    }
    let deadline = Date().addingTimeInterval(40)
    while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    if !finished { print("failed") }
}
