import Foundation

extension SlackSearch {
    struct Group: Identifiable, Equatable {
        var room: String
        var ts: String
        var root: ChatMessage
        var matches: [ChatMessage]
        var exact: Bool
        var id: String { "slack:\(room):\(ts)" }
        var latest: Date { matches.first?.date ?? root.date }
    }
    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }
    static func words(_ message: ChatMessage) -> String {
        ([message.body] + message.marks.map(\.text) + message.files.map(\.name) + [message.speaker]).joined(separator: "\n")
    }
    /// Ranges refer to the original string, including decomposed Unicode. Advancing one character finds overlaps too.
    static func highlights(_ text: String, query: String) -> [Range<String.Index>] {
        let term = normalized(query)
        guard !term.isEmpty else { return [] }
        let terms = text.range(of: term, options: .caseInsensitive) != nil ? [term] : term.split(whereSeparator: \.isWhitespace).map(String.init)
        var found: [Range<String.Index>] = []
        for word in terms {
            var start = text.startIndex
            while start < text.endIndex, let range = text.range(of: word, options: .caseInsensitive, range: start..<text.endIndex) {
                found.append(range); start = text.index(after: range.lowerBound)
            }
        }
        var merged: [Range<String.Index>] = []
        for range in found.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { merged.append(range) }
        }
        return merged
    }
    static func snippet(_ text: String, query: String) -> String {
        guard let match = highlights(text, query: query).first else { return String(text.prefix(60)) }
        let start = text.index(match.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + String(text[start..<end]).replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
    }
    struct Preview: Equatable {
        struct Note: Equatable { var text: String; var file: Bool }
        var body: String
        var notes: [Note]
    }
    /// Metadata explains a match only when the body alone does not contain every search word.
    static func preview(_ query: String, in message: ChatMessage) -> Preview {
        let terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let body = normalized(message.body)
        guard !terms.isEmpty, !terms.allSatisfy({ body.contains($0) }) else { return Preview(body: message.body, notes: []) }
        let notes = message.files.map { Preview.Note(text: $0.name, file: true) } + message.marks.map { Preview.Note(text: $0.text, file: false) }
        return Preview(body: message.body, notes: notes.filter { note in terms.contains { normalized(note.text).contains($0) } })
    }
    /// Earlier sources win when a line is present more than once. Ranking is by phrase, then newest match.
    static func groups(_ query: String, sources: [[SlackThread]], hidden: Set<String> = [], limit: Int = 200) -> [Group] {
        let term = normalized(query), terms = normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !term.isEmpty else { return [] }
        var seen = Set<String>(), roots: [String: ChatMessage] = [:]
        var found: [(room: String, ts: String, message: ChatMessage, exact: Bool)] = []
        for thread in sources.flatMap({ $0 }) where !hidden.contains(thread.room) {
            if roots[thread.id] == nil || (roots[thread.id]?.id != thread.id && (thread.root.id == thread.id || thread.root.date < roots[thread.id]!.date)) { roots[thread.id] = thread.root }
            for line in thread.messages where !line.pending && !SlackText.isThinking(line.body) {
                guard seen.insert(line.id).inserted else { continue }
                let text = normalized(words(line)), exact = text.contains(term)
                if exact || terms.allSatisfy({ text.contains($0) }) { found.append((thread.room, thread.ts, line, exact)) }
            }
        }
        found.sort { ($0.message.date, $0.message.id) > ($1.message.date, $1.message.id) }
        var result: [String: Group] = [:]
        for hit in found.prefix(max(0, limit)) {
            let id = "slack:\(hit.room):\(hit.ts)"
            if result[id] == nil { result[id] = Group(room: hit.room, ts: hit.ts, root: roots[id] ?? hit.message, matches: [], exact: false) }
            result[id]?.matches.append(hit.message)
            if hit.exact { result[id]?.exact = true }
        }
        return result.values.sorted {
            if $0.exact != $1.exact { return $0.exact }
            return ($0.latest, $0.id) > ($1.latest, $1.id)
        }
    }
    static func recorded(_ lines: [DdotsLine], members: [DdotsMember], hub: String?, archive: DdotsArchive) -> [SlackThread] {
        var rooms: [String: [DdotsLine]] = [:]
        for line in lines {
            let room = line.hub == true ? hub : members.first { $0.profile == line.profile }?.room
            if let room { rooms[room, default: []].append(line) }
        }
        return rooms.flatMap { DdotsLine.threads($0.value, room: $0.key, archive: archive) }
    }
    static func failure(_ error: SlackAPI.Failure) -> String {
        if case .api(let code) = error, code.hasPrefix("missing_scope") { return "슬랙 전체 검색은 search:read 권한이 필요해요" }
        if case .rateLimited = error { return "슬랙 검색이 잠시 제한됐어요" }
        return SlackAPI.message(error)
    }
    static func remote(_ query: String, api: SlackAPI, workspace: String, rooms: Set<String>, hidden: Set<String>, me: String,
                       users: [String: String], characters: [ChatCharacter]) -> Result<[SlackThread], SlackAPI.Failure> {
        api.call("search.messages", ["query": query, "count": "50", "sort": "timestamp", "sort_dir": "desc"]).map { json in
            let messages = json["messages"] as? [String: Any] ?? [:]
            var state = SlackState(); state.me = me; state.users = users
            var grouped: [String: [ChatMessage]] = [:], places: [String: (String, String)] = [:]
            for raw in messages["matches"] as? [[String: Any]] ?? [] {
                guard let channel = raw["channel"] as? [String: Any], let room = channel["id"] as? String,
                      rooms.contains(room), !hidden.contains(room), var message = SlackMessage(json: raw) else { continue }
                if let link = raw["permalink"] as? String, let url = URL(string: link), let place = SlackCopy.place(of: url, workspace: workspace), place.room == room {
                    message.threadTS = place.ts
                }
                let ts = message.threadTS ?? message.ts, id = "slack:\(room):\(ts)"
                grouped[id, default: []].append(state.chat(message, room: room, characters: characters)); places[id] = (room, ts)
            }
            return grouped.compactMap { id, lines in
                guard let place = places[id], let first = lines.first(where: { $0.id == id }) ?? lines.min(by: { $0.date < $1.date }) else { return nil }
                let replies = lines.filter { $0.id != first.id }
                return SlackThread(id: id, room: place.0, ts: place.1, root: first, replies: replies, replyCount: replies.count, loaded: false,
                                   latest: lines.map { $0.date.timeIntervalSince1970 }.max() ?? 0, latestFromUser: false)
            }
        }
    }
}
