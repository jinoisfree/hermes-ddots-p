import Foundation

/// Presentation only: callers retain the full timeline for search, unread and notifications.
struct DdotsThreadWindow {
    static let pageSize = 50
    private(set) var limit = pageSize
    private var first: String?

    mutating func reset() { limit = Self.pageSize; first = nil }
    /// Returns whether another archive month must be read. Loaded hidden rows always come first.
    mutating func older(loadedCount: Int, hasEarlier: Bool) -> Bool {
        guard loadedCount > limit || hasEarlier else { return false }
        let needsMonth = loadedCount <= limit && hasEarlier
        limit += Self.pageSize
        return needsMonth
    }
    mutating func visibleIDs(_ ids: [String], revealing target: String? = nil) -> ArraySlice<String> {
        // Keep the oldest displayed row when new posts arrive at the end.
        if let first, let index = ids.firstIndex(of: first) { limit = max(limit, ids.count - index) }
        if let target, let index = ids.firstIndex(of: target) { limit = max(limit, ids.count - index) }
        let visible = ids.suffix(limit)
        first = visible.first
        return visible
    }
}
