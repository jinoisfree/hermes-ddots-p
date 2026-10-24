import Foundation

/// Where words are being written: the workspace, the room shown, and what the words answer.
/// `aim` is a thread's ID, `new:` and the room for a new post, or `auto` for whatever a room answers by itself.
struct SlackDraftPlace: Hashable {
    var workspace: String
    var shown: String
    var aim: String
    static func thread(_ id: String) -> String { "thread:" + id }
    static func new(_ room: String) -> String { "new:" + room }
    static let auto = "auto"
}

/// What one place of writing holds while the user is somewhere else: the words, the files, and a face pressed for them.
struct SlackSavedDraft: Equatable {
    var text = ""
    var files: [URL] = []
    /// The character a face was pressed for, in ddots.
    var pick: String?
    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty && pick == nil }
}

/// A message that did not go, with where it was meant to go. It waits there until the user brings it back or lets it go;
/// nothing sends it again by itself.
struct SlackFailedSend: Equatable, Identifiable {
    var id = UUID()
    var workspace: String
    /// The room that was shown when it was sent; it is listed there.
    var shown: String
    var room: String
    /// The thread it answered, by ID, or nil for a new post.
    var thread: String?
    var text: String
    var files: [URL]
    var pick: String?
    var reason: String
    var date = Date()
    /// The place of writing a brought-back message goes to: its own thread, or a new post in its room.
    var place: SlackDraftPlace {
        SlackDraftPlace(workspace: workspace, shown: shown, aim: thread.map(SlackDraftPlace.thread) ?? SlackDraftPlace.new(room))
    }
}

/// Every draft and every failed send while the app runs. Nothing here is written to disk.
struct SlackDrafts {
    static let mostFiles = 10
    private(set) var saved: [SlackDraftPlace: SlackSavedDraft] = [:]
    /// Oldest first, in the order they were sent.
    private(set) var failures: [SlackFailedSend] = []

    func draft(at place: SlackDraftPlace) -> SlackSavedDraft { saved[place] ?? SlackSavedDraft() }
    mutating func put(_ draft: SlackSavedDraft, at place: SlackDraftPlace) { saved[place] = draft.isEmpty ? nil : draft }
    mutating func take(at place: SlackDraftPlace) -> SlackSavedDraft { saved.removeValue(forKey: place) ?? SlackSavedDraft() }

    mutating func fail(_ failure: SlackFailedSend) { failures.append(failure) }
    /// The failures listed in a room of a workspace.
    func failures(workspace: String, shown: String?) -> [SlackFailedSend] {
        failures.filter { $0.workspace == workspace && $0.shown == shown }
    }
    /// Failures of the same workspace waiting in other rooms.
    func elsewhere(workspace: String, shown: String?) -> [SlackFailedSend] {
        failures.filter { $0.workspace == workspace && $0.shown != shown }
    }
    mutating func discard(_ id: UUID) { failures.removeAll { $0.id == id } }

    enum Refusal: Error, Equatable { case gone, tooManyFiles }
    /// Puts a failed message back into what is being written at its place: its words ahead of anything typed since,
    /// its files ahead of those attached since. The failure is let go only once it is back.
    mutating func restore(_ id: UUID, into current: SlackSavedDraft) -> Result<SlackSavedDraft, Refusal> {
        guard let failure = failures.first(where: { $0.id == id }) else { return .failure(.gone) }
        var files = failure.files
        for file in current.files where !files.contains(file) { files.append(file) }
        guard files.count <= Self.mostFiles else { return .failure(.tooManyFiles) }
        discard(id)
        let text = [failure.text, current.text].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        return .success(SlackSavedDraft(text: text, files: files, pick: current.pick ?? failure.pick))
    }
}

/// Face illumination is a preview only; it must not alter the recipient used for sending.
enum DdotsFaceLight {
    static func profile(draft: String, picked: Bool, replying: Bool, recipient: String?) -> String? {
        guard picked || replying || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return recipient
    }
    /// The face a new post's words light before anything is pressed: only the character they are about.
    /// Words that fit no one are left to Hermes, so no face lights for them, nor for one who has no face here.
    static func routed(_ decision: DdotsRoute.Decision, faces: [DdotsMember]) -> String? {
        guard decision.reason != "fallback", faces.contains(where: { $0.profile == decision.profile }) else { return nil }
        return decision.profile
    }
}
