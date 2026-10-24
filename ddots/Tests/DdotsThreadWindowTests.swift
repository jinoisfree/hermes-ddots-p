import Foundation

@main struct DdotsThreadWindowTests {
    static func main() {
        let ids = (0..<850).map(String.init)
        var window = DdotsThreadWindow()
        precondition(Array(window.visibleIDs(ids)) == Array(ids.suffix(50)))
        precondition(!window.older(loadedCount: 850, hasEarlier: true))
        precondition(window.visibleIDs(ids).count == 100)
        for _ in 0..<15 { precondition(!window.older(loadedCount: 850, hasEarlier: true)) }
        precondition(window.visibleIDs(ids).count == 850)
        precondition(window.older(loadedCount: 850, hasEarlier: true))
        precondition(window.visibleIDs(((-100)..<0).map(String.init) + ids).count == 900)
        window.reset()
        precondition(window.visibleIDs(ids, revealing: "42").contains("42"))
        window.reset()
        precondition(window.visibleIDs(ids).count == 50)
        precondition(window.visibleIDs(ids + ["new"]).count == 51)
        precondition(ids.count == 850) // Presentation never mutates the source used by unread/search.
        print("DdotsThreadWindowTests passed")
    }
}
