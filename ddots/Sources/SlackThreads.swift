import Foundation

struct SlackRoom: Identifiable, Equatable, Codable {
    var id: String
    var name: String
    var direct = false
}

/// One Slack message as the Web API returns it. Bodies are kept in memory, and in the cache on this Mac that a start is shown from.
struct SlackMessage: Equatable, Codable {
    var ts: String
    var threadTS: String?
    var user: String
    var name: String
    var text: String
    var replyCount = 0
    var latestReply: String?
    var broadcast = false
    /// Coloured notes attached to the post. A post is repainted when its status changes, so these are compared too.
    var marks: [ChatMark] = []
    var files: [ChatFile] = []
    var hermesReplyState: HermesReplyState? {
        didSet { if oldValue != hermesReplyState { hermesReplyEvidence = nil } }
    }
    var hermesReplyEvidence: HermesReplyEvidence?
    var effectiveHermesReplyState: HermesReplyState? {
        if let evidence = hermesReplyEvidence { return evidence.state() }; return hermesReplyState
    }
    var hermesButtons: [String]?
    var hermesChecklist: [String]?
    var hermesChecklistSelected: [String]?
    var hermesChecklistCanSkip: Bool?
    /// Colour of the bar beside each block attachment's quoted lines, in order, as Slack draws it; "" for grey.
    var quoteColors: [String]?
    var time: Double { Double(ts) ?? 0 }
    var isRoot: Bool { threadTS == nil || threadTS == ts }

    private static let shownSubtypes: Set<String> = ["bot_message", "file_share", "thread_broadcast", "me_message"]

    init(ts: String, threadTS: String? = nil, user: String = "", name: String = "", text: String, replyCount: Int = 0, latestReply: String? = nil, marks: [ChatMark] = [], broadcast: Bool = false) {
        self.ts = ts; self.threadTS = threadTS; self.user = user; self.name = name; self.text = text
        self.replyCount = replyCount; self.latestReply = latestReply; self.marks = marks; self.broadcast = broadcast
    }

    /// Joins, topic changes and other housekeeping lines are not conversation.
    init?(json: [String: Any]) {
        guard let ts = json["ts"] as? String else { return nil }
        if let subtype = json["subtype"] as? String, !Self.shownSubtypes.contains(subtype) { return nil }
        let fallback = json["text"] as? String ?? ""
        // TalkTalk carries customer text in literal blocks to keep mentions inert in Slack.
        // Its short fallback is for notifications, not the conversation shown in ddots.
        let talkBody = fallback == "네이버 톡톡 처리 알림" ? (json["blocks"] as? [[String: Any]] ?? []).compactMap { block -> String? in
            guard block["type"] as? String == "section", let body = block["text"] as? [String: Any],
                  body["type"] as? String == "plain_text" else { return nil }
            return body["text"] as? String
        }.joined(separator: "\n") : ""
        // Slack keeps only a one-line fallback when a post has Block Kit layout, so the readable
        // body (headings, lists, quotes) is rebuilt from the blocks. A block attachment stays quoted
        // under its own bar, in its colour.
        let attachments = (json["attachments"] as? [[String: Any]] ?? []).filter { $0["blocks"] is [[String: Any]] }
        let allBlocks = (json["blocks"] as? [[String: Any]] ?? []) + attachments.flatMap { $0["blocks"] as? [[String: Any]] ?? [] }
        let statuses = allBlocks.filter { $0["block_id"] as? String == "hermes_report_status" }
        let statusText = statuses.flatMap { $0["elements"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: " ")
        let buttons = allBlocks.filter { $0["block_id"] as? String == "hermes_reply_buttons" }
        hermesButtons = buttons.flatMap { $0["elements"] as? [[String: Any]] ?? [] }.compactMap {
            guard $0["type"] as? String == "button" else { return nil }
            return ($0["text"] as? [String: Any])?["text"] as? String
        }.filter { !$0.isEmpty }
        let checklist = allBlocks.filter {
            let id = $0["block_id"] as? String ?? ""
            return id == "hermes_reply_checklist" || id.hasPrefix("hermes_reply_checklist:")
        }
        let checklistElements = checklist.flatMap { $0["elements"] as? [[String: Any]] ?? [] }
        hermesChecklistCanSkip = checklistElements.contains {
            $0["type"] as? String == "button" && $0["action_id"] as? String == "hermes_reply_checklist_skip"
        }
        let legacyOptions = checklistElements.filter { $0["type"] as? String == "checkboxes" }
        let toggles = checklistElements.filter {
            ($0["action_id"] as? String ?? "").hasPrefix("hermes_reply_checklist_toggle_") && $0["type"] as? String == "button"
        }
        hermesChecklist = legacyOptions.flatMap { $0["options"] as? [[String: Any]] ?? [] }.compactMap { $0["value"] as? String }
            + toggles.compactMap { $0["value"] as? String }
        hermesChecklistSelected = legacyOptions.flatMap { $0["initial_options"] as? [[String: Any]] ?? [] }.compactMap { $0["value"] as? String }
            + toggles.filter { $0["style"] as? String == "primary" }.compactMap { $0["value"] as? String }
        hermesReplyEvidence = HermesReplyEvidence(statusText: statusText, hasStatus: !statuses.isEmpty,
            hasControls: !buttons.isEmpty || !checklist.isEmpty,
            color: attachments.count == 1 ? SlackText.hexColor(attachments[0]["color"] as? String ?? "") : nil)
        hermesReplyState = hermesReplyEvidence?.state()
        var own = json["blocks"] as? [[String: Any]] ?? [], quoted = attachments.map { $0["blocks"] as? [[String: Any]] ?? [] }
        let title = own.first?["type"] as? String == "header" ? (own.first?["text"] as? [String: Any])?["text"] as? String : nil
        // A titled report without an attachment (its title had no status mark) gets the bar too in ddots:
        // the words under the title go behind it, grey unless the title says otherwise.
        if quoted.isEmpty, title != nil, own.count > 1 { quoted = [Array(own.dropFirst())]; own = [own[0]] }
        let laid = talkBody.isEmpty ? SlackBlockText.mrkdwn(own, attachments: quoted) : (text: "", kept: [])
        let laidOut = laid.text
        let text = !talkBody.isEmpty ? talkBody : laidOut.isEmpty ? fallback : laidOut
        // Preserve explicit tombstones so the conversation has a readable placeholder.
        files = (json["files"] as? [[String: Any]] ?? []).compactMap { file in
            guard let id = file["id"] as? String else { return nil }
            let deleted = file["mode"] as? String == "tombstone" || file["is_deleted"] as? Bool == true
            let url = (file["url_private_download"] as? String) ?? (file["url_private"] as? String) ?? ""
            guard deleted || !url.isEmpty else { return nil }
            return ChatFile(id: id, name: (file["name"] as? String) ?? (file["title"] as? String) ?? id,
                            mimetype: file["mimetype"] as? String ?? "", size: file["size"] as? Int ?? 0,
                            url: url, thumb: (file["thumb_1024"] as? String) ?? (file["thumb_720"] as? String) ?? (file["thumb_480"] as? String) ?? (file["thumb_360"] as? String) ?? (file["thumb_pdf"] as? String) ?? "", deleted: deleted)
        }
        marks = (json["attachments"] as? [[String: Any]] ?? []).compactMap { attachment in
            // Block attachments are already part of the rebuilt body above.
            if !laidOut.isEmpty, attachment["blocks"] != nil, attachment["text"] == nil { return nil }
            let note = (attachment["text"] as? String) ?? (attachment["fallback"] as? String) ?? ""
            let color = SlackText.hexColor(attachment["color"] as? String ?? "")
            return note.isEmpty && color.isEmpty ? nil : ChatMark(color: color, text: note)
        }
        guard !text.isEmpty || !marks.isEmpty || !files.isEmpty else { return nil }
        self.ts = ts; self.text = text
        if !laidOut.isEmpty, !laid.kept.isEmpty {
            // An attachment without a colour of its own takes the title's status colour, else grey.
            let status = title.flatMap(SlackBlockText.statusColor) ?? ""
            quoteColors = laid.kept.map { index in
                let own = index < attachments.count ? SlackText.hexColor(attachments[index]["color"] as? String ?? "") : ""
                return own.isEmpty ? status : own
            }
        }
        broadcast = json["subtype"] as? String == "thread_broadcast"
        threadTS = json["thread_ts"] as? String
        user = json["user"] as? String ?? ""
        name = ((json["bot_profile"] as? [String: Any])?["name"] as? String) ?? (json["username"] as? String) ?? ""
        replyCount = json["reply_count"] as? Int ?? 0
        latestReply = json["latest_reply"] as? String
    }
}

/// Block Kit layout written back as the Slack markup ddots already shows, one line per line.
enum SlackBlockText {
    /// A report title's status mark and the bar colour it stands for, as Hermes' reports choose them:
    /// red for a failure or something urgent, yellow for a warning, green for done or checked, blue for information.
    /// A title without one is an ordinary report, whose bar stays grey.
    static let statusColors: [(color: String, marks: [String])] = [
        ("#E01E5A", ["🔴", "❌", "🚨", "⛔", ":red_circle:", ":x:", ":rotating_light:", ":no_entry:"]),
        ("#ECB22E", ["🟡", "🟠", "⚠", ":warning:", ":large_yellow_circle:", ":large_orange_circle:"]),
        ("#2EB67D", ["🟢", "✅", "☑", "✔", ":large_green_circle:", ":white_check_mark:", ":ballot_box_with_check:", ":heavy_check_mark:"]),
        ("#1D9BD1", ["🔵", "ℹ", "📌", ":large_blue_circle:", ":information_source:", ":pushpin:"]),
    ]
    static func statusColor(_ title: String) -> String? {
        // ⚠️ and ⚠ are one mark; the emoji selector would keep Swift from finding one in the other.
        let plain = title.replacingOccurrences(of: "\u{FE0F}", with: "")
        return statusColors.first { entry in entry.marks.contains { plain.contains($0) } }?.color
    }

    /// Empty when the blocks carry no layout worth more than the plain fallback.
    /// Each attachment's blocks follow the post's own, every line quoted, as Slack sets them behind a bar.
    /// `kept` lists the attachments that had words, in the order their quotes appear.
    static func mrkdwn(_ blocks: [[String: Any]], attachments: [[[String: Any]]] = []) -> (text: String, kept: [Int]) {
        let laidOut: Set<String> = ["header", "rich_text", "divider", "table"]
        guard (blocks + attachments.joined()).contains(where: { laidOut.contains($0["type"] as? String ?? "") }) else { return ("", []) }
        let bodies = attachments.map { text($0) }
        let kept = bodies.indices.filter { !bodies[$0].isEmpty }
        let quoted = kept.map { bodies[$0].components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n") }
        // Under a bar the colour tells the status, so the title's own status mark is left off.
        return (([text(blocks, bareTitle: !quoted.isEmpty)] + quoted).filter { !$0.isEmpty }.joined(separator: "\n\n"), kept)
    }

    /// A title without the status mark it starts with, such as "🔵 " or ":warning: ".
    static func withoutStatus(_ title: String) -> String {
        var scalars = Substring(title).unicodeScalars[...]
        for mark in statusColors.flatMap(\.marks) where scalars.starts(with: mark.unicodeScalars) {
            scalars = scalars.dropFirst(mark.unicodeScalars.count).drop { $0 == "\u{FE0F}" }
            let rest = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? title : rest
        }
        return title
    }

    private static func text(_ blocks: [[String: Any]], bareTitle: Bool = false) -> String {
        var parts: [String] = []
        for block in blocks {
            switch block["type"] as? String {
            case "header":
                // A header is Slack's large title line.
                let title = ((block["text"] as? [String: Any])?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty { parts.append("### " + escape(bareTitle ? withoutStatus(title) : title)) }
            case "section":
                if let body = block["text"] as? [String: Any], let text = body["text"] as? String, !text.isEmpty {
                    parts.append(body["type"] as? String == "plain_text" ? escape(text) : text)
                }
            case "context":
                let notes = (block["elements"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                if !notes.isEmpty { parts.append(notes.joined(separator: " · ")) }
            case "divider":
                parts.append("────────")
            case "table":
                if let table = table(block) { parts.append(table) }
            case "rich_text":
                let lines = (block["elements"] as? [[String: Any]] ?? []).flatMap(element)
                if !lines.isEmpty { parts.append(lines.joined(separator: "\n")) }
            default:
                continue
            }
        }
        return parts.joined(separator: "\n\n")
    }

    /// A table as Markdown pipe rows under a row of column alignments. A bar inside a cell is written ∣,
    /// so it cannot split the cell.
    private static func table(_ block: [String: Any]) -> String? {
        let rows = (block["rows"] as? [[[String: Any]]] ?? []).map { row in
            row.map { cell -> String in
                let words = cell["type"] as? String == "raw_text" ? escape(cell["text"] as? String ?? "")
                    : (cell["elements"] as? [[String: Any]] ?? []).flatMap(element).joined(separator: " ")
                return words.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "∣").trimmingCharacters(in: .whitespaces)
            }
        }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return nil }
        let settings = block["column_settings"] as? [Any] ?? []
        let aligns = (0..<columns).map { index -> String in
            switch (index < settings.count ? settings[index] as? [String: Any] : nil)?["align"] as? String {
            case "center": return ":---:"
            case "right": return "---:"
            default: return "---"
            }
        }
        func line(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |" }
        return ([line(rows[0]), line(aligns)] + rows.dropFirst().map(line)).joined(separator: "\n")
    }

    private static func element(_ element: [String: Any]) -> [String] {
        let children = element["elements"] as? [[String: Any]] ?? []
        switch element["type"] as? String {
        case "rich_text_section":
            return [inline(children)]
        case "rich_text_list":
            let indent = String(repeating: "    ", count: max(0, element["indent"] as? Int ?? 0))
            let ordered = element["style"] as? String == "ordered"
            let start = element["offset"] as? Int ?? 0
            return children.enumerated().map { index, item in
                indent + (ordered ? "\(start + index + 1). " : "• ") + inline(item["elements"] as? [[String: Any]] ?? [])
            }
        case "rich_text_quote":
            return inline(children).components(separatedBy: "\n").map { "> " + $0 }
        case "rich_text_preformatted":
            return ["```"] + inline(children, plain: true).components(separatedBy: "\n") + ["```"]
        default:
            return []
        }
    }

    private static func inline(_ elements: [[String: Any]], plain: Bool = false) -> String {
        elements.map { item -> String in
            let style = item["style"] as? [String: Bool] ?? [:]
            switch item["type"] as? String {
            case "text":
                let raw = item["text"] as? String ?? ""
                if plain { return raw }
                if style["code"] == true { return "`" + escape(raw) + "`" }
                return styled(escape(raw), style)
            case "link":
                let url = item["url"] as? String ?? ""
                let label = (item["text"] as? String).map { "|" + escape($0) } ?? ""
                return styled("<" + url + label + ">", style)
            case "user": return "<@" + (item["user_id"] as? String ?? "") + ">"
            case "channel": return "<#" + (item["channel_id"] as? String ?? "") + ">"
            case "usergroup": return "<!subteam^" + (item["usergroup_id"] as? String ?? "") + ">"
            case "broadcast": return "<!" + (item["range"] as? String ?? "here") + ">"
            case "emoji": return ":" + (item["name"] as? String ?? "") + ":"
            default: return item["text"] as? String ?? ""
            }
        }.joined()
    }

    /// Marks go inside the line's own spaces, which Slack markup needs to see them.
    private static func styled(_ text: String, _ style: [String: Bool]) -> String {
        let core = text.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty, let range = text.range(of: core) else { return text }
        var marked = core
        // Doubled, since ddots reads a single ~ as written (10~12시).
        if style["strike"] == true { marked = "~~" + marked + "~~" }
        if style["italic"] == true { marked = "_" + marked + "_" }
        if style["bold"] == true { marked = "*" + marked + "*" }
        return String(text[..<range.lowerBound]) + marked + String(text[range.upperBound...])
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Someone in a room. `user` is empty when only a name seen in the conversation is known.
struct SlackMember: Identifiable, Equatable {
    var profile: String
    var name: String
    var user = ""
    var id: String { user.isEmpty ? profile + "/" + name : user }

    /// Hermes characters first, in their usual order, then everyone else by name.
    static func ordered(_ members: [SlackMember]) -> [SlackMember] {
        let order = ChatCharacter.preferred
        func rank(_ member: SlackMember) -> Int { member.profile.isEmpty ? order.count + 1 : order.firstIndex(of: member.profile) ?? order.count }
        return members.sorted { (rank($0), $0.name) < (rank($1), $1.name) }
    }
}

enum SlackMention {
    /// Mention buttons appear only when there is someone to choose between.
    static let minimumMembers = 2
    private static func ranges(of name: String, in text: String) -> [Range<String.Index>] {
        guard !name.isEmpty, let regex = try? NSRegularExpression(pattern: "@" + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }
    /// Clicking a face puts "@이름 " in front of the draft, or takes that mention out again.
    static func toggled(_ draft: String, name: String) -> String {
        let found = ranges(of: name, in: draft)
        guard !found.isEmpty else { return "@" + name + " " + draft }
        var text = draft
        for range in found.reversed() {
            var end = range.upperBound
            if end < text.endIndex, text[end] == " " { end = text.index(after: end) }
            text.removeSubrange(range.lowerBound..<end)
        }
        return text
    }
    /// Resolve exactly the mentions that outgoing converts, including its name boundaries and ordering.
    static func profiles(in text: String, members: [SlackMember]) -> Set<String> {
        let users = Set(SlackText.mentions(outgoing(text, members: members)))
        return Set(members.filter { !$0.user.isEmpty && !$0.profile.isEmpty && users.contains($0.user) }.map(\.profile))
    }
    /// What is sent: typed text made literal for Slack, with "@이름" turned into a real mention.
    static func outgoing(_ text: String, members: [SlackMember]) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        for member in members.filter({ !$0.user.isEmpty }).sorted(by: { $0.name.count > $1.name.count }) {
            for range in ranges(of: member.name, in: result).reversed() { result.replaceSubrange(range, with: "<@\(member.user)>") }
        }
        return result
    }
}

struct SlackThread: Identifiable, Equatable {
    var id: String
    var room: String
    var ts: String
    var root: ChatMessage
    var replies: [ChatMessage]
    var replyCount: Int
    /// False while only the reply count is known.
    var loaded: Bool
    var latest: Double
    var latestFromUser: Bool
    var broadcastTime: Double = 0
    var position: Date { max(root.date, Date(timeIntervalSince1970: broadcastTime)) }
    var messages: [ChatMessage] { [root] + replies }
}

/// One line of a room's notice: posts that share a status and still wait for something.
struct SlackNoticeItem: Identifiable, Equatable {
    var id: String
    var title: String
    var color: String
    /// Oldest first.
    var threads: [String]
}

enum SlackNotice {
    private static var rules: ConversationRules { DdotsConfig.shared.conversation }
    /// Statuses that need nothing more are left out of the notice.
    static var settled: Set<String> { Set(rules.list("settled")) }
    static var settledText: String { rules.text("settledText") }
    /// Only presentation and clipboard text use this spelling; source marks keep their original words.
    static func displayStatus(_ text: String) -> String { isSettled(text) ? settledText : text }
    private static let leadingEmoji = try? NSRegularExpression(pattern: #"^:[a-zA-Z0-9_+\-]+:"#)
    /// Slack shortcodes and displayed emoji can decorate a status, but the remaining words must match exactly.
    static func isSettled(_ text: String) -> Bool {
        var words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while !words.isEmpty {
            if let match = leadingEmoji?.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
               let range = Range(match.range, in: words) {
                words.removeSubrange(range)
            } else if let first = words.first, first.unicodeScalars.contains(where: { ($0.properties.isEmoji && $0.value > 0x7F) || $0.value == 0x20E3 }) {
                words.removeFirst()
            } else { break }
            words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return settled.contains(words)
    }
    /// A later approval request reopens a thread; finishing the request itself or a later post settles it.
    static func isSettled(_ thread: SlackThread, confirmed: Set<String> = []) -> Bool {
        if let state = hermesState(thread) { return state == .closed || (state == .asking && pendingApproval(thread).map { confirmed.contains($0.id) } == true) }
        if let request = pendingApproval(thread), confirmed.contains(request.id) { return true }
        guard thread.loaded else { return false }
        let spoken = thread.messages.filter { $0.fromUser || !SlackText.isThinking($0.body) }
        guard let stated = spoken.lastIndex(where: { $0.marks.count == 1 && !$0.marks[0].color.isEmpty && !$0.marks[0].text.isEmpty }),
              isSettled(spoken[stated].marks[0].text) else { return false }
        guard let request = pendingApproval(thread), let asked = spoken.lastIndex(where: { $0.id == request.id }) else { return true }
        return stated >= asked
    }
    static var unanswered: String { rules.text("unanswered") }
    static var draft: String { rules.text("draft") }
    static let questionID = "question"
    static var questionColor: String { rules.color("questionColor") }

    /// A character asks outright ("승인해줘", "승인하면 보낼게") or names the word to answer with ("`승인`이라고 답해줘").
    /// A report of what already happened ("승인받고 보냈어", "`승인`이라고 답해서 보냈어") is not a request.
    /// The words the buttons send. Hermes reads "승인" as yes and "거부" as no; "거절" is not on its list.
    static var approveText: String { rules.text("approveText") }
    static var denyText: String { rules.text("denyText") }
    /// Hermes's own command: it opens a new thread that carries this conversation on, with everything said so far.
    static var branchText: String { rules.text("branchText") }
    /// From this many replies on, a thread's button for carrying it on stands out.
    static var longThread: Int { Int(rules.number("longThread")) }

    static func requestsApproval(_ body: String) -> Bool {
        let own = body.split(whereSeparator: { $0.isNewline }).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.joined(separator: "\n")
        if rules.matches("nothingWaiting", own) { return false }
        return rules.matches("approval1", own) || rules.matches("approval2", own)
    }

    /// Patterns are immutable and shared: row rendering must not compile them for every message.
    static func isLearningReport(_ body: String) -> Bool {
        let own = body.split(whereSeparator: { $0.isNewline }).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.joined(separator: "\n")
        if rules.matches("sentLearning", own) { return false }
        return rules.matches("learningReport1", own) || rules.matches("learningReport2", own)
    }

    static func isLearningReport(_ thread: SlackThread) -> Bool {
        pendingApproval(thread).map { isLearningReport($0.body) } ?? false
    }

    /// A mail draft laid out for the user that has not gone out yet ("메일 초안 … 발송하지 않았습니다", "발송은 승인 전").
    /// It names no answer word, so the buttons say in plain words what to do with the mail.
    static func isMailDraft(_ body: String) -> Bool {
        guard rules.matches("mailDraft", body), rules.matches("mailWaiting", body) else { return false }
        return !rules.matches("mailSent", body)
    }
    static func isMailDraft(_ thread: SlackThread) -> Bool {
        pendingApproval(thread).map { isMailDraft($0.body) } ?? false
    }
    static var mailApproveText: String { rules.text("mailApproveText") }
    static var mailDenyText: String { rules.text("mailDenyText") }

    static func answerText(_ thread: SlackThread, approve: Bool) -> String {
        if isLearningReport(thread) { return approve ? rules.text("learningApprove") : rules.text("learningDeny") }
        if isMailDraft(thread) { return approve ? mailApproveText : mailDenyText }
        return approve ? approveText : denyText
    }

    /// The approval request in a thread that the user has not answered yet, if there is one.
    static func pendingApproval(_ thread: SlackThread, confirmed: Set<String> = []) -> ChatMessage? {
        assessment(thread, confirmed: confirmed).pending
    }

    /// A notification's colour or learning-report heading alone must not wave the phone.
    /// The request must still be unanswered and explicitly ask the owner to act.
    static func requestsPetReply(_ message: ChatMessage) -> Bool {
        guard !message.fromUser else { return false }
        if message.effectiveHermesReplyState == .working || message.effectiveHermesReplyState == .closed { return false }
        if !message.hermesButtons.isEmpty || !message.hermesChecklist.isEmpty { return true }
        let own = message.body.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }.joined(separator: "\n")
        return own.contains("[[버튼:") || requestsApproval(own) || isMailDraft(own)
            || rules.matches("learningReport2", own)
    }

    /// Hide the old draft status after confirmation without changing the source or copied conversation.
    static func displayed(_ thread: SlackThread, confirmed: Set<String>) -> SlackThread {
        var shown = thread
        if let exchange = approvalExchange(thread), exchange.finished {
            func repaint(_ message: inout ChatMessage) {
                guard message.id == exchange.request.id else { return }
                message.quoteColors = message.quoteColors.map { [rules.color("workingColor"), rules.color("askingColor")].contains($0.uppercased()) ? approvedColor : $0 }
            }
            repaint(&shown.root)
            for index in shown.replies.indices { repaint(&shown.replies[index]) }
        }
        if let request = pendingApproval(thread), confirmed.contains(request.id) {
            shown.root.marks.removeAll { $0.text == draft }
            for index in shown.replies.indices { shown.replies[index].marks.removeAll { $0.text == draft } }
        }
        return shown
    }

    static var approvedColor: String { rules.color("approvedColor") }
    private static var yes: Set<String> { Set(rules.list("yes").map { $0.lowercased() }) }
    private static func approvalExchange(_ thread: SlackThread) -> (request: ChatMessage, answer: ChatMessage?, finished: Bool)? {
        guard thread.loaded else { return nil }
        let spoken = thread.messages.filter { $0.fromUser || !SlackText.isThinking($0.body) }
        guard let asked = spoken.lastIndex(where: { !$0.fromUser && ($0.effectiveHermesReplyState != nil || $0.body.contains("[[버튼:") || isLearningReport($0.body) || requestsApproval($0.body) || isMailDraft($0.body)) }) else { return nil }
        let answered = spoken[(asked + 1)...].firstIndex(where: \.fromUser)
        let answer = answered.map { spoken[$0] }
        let said = answer?.body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).lowercased() ?? ""
        let finished = yes.contains(said) && answered.map { index in
            spoken[(index + 1)...].contains { !$0.fromUser }
        } == true
        return (spoken[asked], answer, finished)
    }
    /// A later ordinary request reopens an older Hermes exchange too.
    static func hermesState(_ thread: SlackThread) -> HermesReplyState? {
        guard let exchange = approvalExchange(thread) else { return nil }
        return exchange.finished ? .closed : exchange.request.effectiveHermesReplyState
    }
    static func replyLabels(_ thread: SlackThread) -> [String] {
        pendingApproval(thread)?.hermesButtons ?? []
    }
    static func checklistLabels(_ thread: SlackThread) -> [String] {
        pendingApproval(thread)?.hermesChecklist ?? []
    }
    static func checklistSkipAnswer(_ thread: SlackThread) -> String? {
        guard let request = pendingApproval(thread), !request.hermesChecklist.isEmpty,
              request.hermesChecklistCanSkip else { return nil }
        return rules.text("checklistSkip")
    }
    static func checklistToggle(labels: [String], selected: Set<String>, label: String, isOn: Bool) -> Set<String> {
        var next = selected.intersection(labels)
        guard labels.contains(label) else { return next }
        if isOn { next.insert(label) } else { next.remove(label) }
        guard labels.count > 1, labels.first == rules.text("checklistAll") else { return next }
        if label == rules.text("checklistAll") { return isOn ? Set(labels) : [] }
        if Set(labels.dropFirst()).isSubset(of: next) { next.insert(rules.text("checklistAll")) }
        else { next.remove(rules.text("checklistAll")) }
        return next
    }
    static func checklistAnswer(_ thread: SlackThread, selected: Set<String>) -> String? {
        let labels = checklistLabels(thread).filter { selected.contains($0) }
        guard !labels.isEmpty else { return nil }
        return rules.text("checklistPrefix") + (labels.contains(rules.text("checklistAll")) ? rules.text("checklistAll") : labels.joined(separator: ", "))
    }
    static func hermesAnswer(_ thread: SlackThread, label: String) -> String? {
        replyLabels(thread).contains(label) ? label : nil
    }
    /// Both decorations share the same approval request and answer lookup.
    /// A request the user marked as seen waits on nothing more, though no answer was written.
    static func assessment(_ thread: SlackThread, confirmed: Set<String> = []) -> (pending: ChatMessage?, state: ChatMark?) {
        guard let exchange = approvalExchange(thread) else { return (nil, nil) }
        if exchange.finished { return (nil, ChatMark(color: approvedColor, text: settledText)) }
        switch exchange.request.effectiveHermesReplyState {
        case .working: return (nil, ChatMark(color: questionColor, text: rules.text("workingText")))
        case .closed: return (nil, ChatMark(color: approvedColor, text: settledText))
        default: break
        }
        guard let answer = exchange.answer else {
            return confirmed.contains(exchange.request.id) ? (nil, nil) : (exchange.request, ChatMark(color: questionColor, text: rules.text("waitingText")))
        }
        let said = answer.body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
        return (nil, (yes.contains(said) || (isLearningReport(exchange.request.body) && said == rules.text("learningApprove"))) ? ChatMark(color: approvedColor, text: rules.text("approvedText")) : nil)
    }
    /// What a thread waits on, as a coloured note: a question still open, or a request the user approved.
    static func state(_ thread: SlackThread, confirmed: Set<String> = []) -> ChatMark? { assessment(thread, confirmed: confirmed).state }

    static let alertID = "alert"
    /// The lines of the notice that a thread's bell can mark as read.
    static func hasBell(_ item: SlackNoticeItem) -> Bool { item.id == alertID || item.id.hasPrefix(questionID + ":") }
    static var alertColor: String { rules.color("alertColor") }
    /// How long a character's own post keeps counting as a notification when nobody answers it.
    static var alertWindow: TimeInterval { rules.number("alertWindow") }

    /// What still waits for the user in a room, oldest first within each line: customer messages nobody answered,
    /// each character's approval requests (the ones that offer 승인·거절·의견), notifications (threads a character
    /// opened in the last day that the user has not answered), and any other open status.
    /// Anything the user has answered since is taken as handled, so its count drops as soon as the reply is sent.
    /// `dismissed` holds, per thread, how far it had got when the user marked it read with its bell;
    /// a notification or question stays off the count until something newer happens in that thread.
    static func items(_ threads: [SlackThread], now: Date = Date(), dismissed: [String: Double] = [:], confirmed: Set<String> = []) -> [SlackNoticeItem] {
        var order: [String] = [], found: [String: SlackNoticeItem] = [:]
        func add(_ id: String, title: String, color: String, thread: String) {
            if found[id] == nil { order.append(id); found[id] = SlackNoticeItem(id: id, title: title, color: color, threads: []) }
            found[id]?.threads.append(thread)
        }
        // Replies that have not been read yet could hold the answer, so such a thread is not counted until they are.
        for thread in threads.sorted(by: { $0.root.date < $1.root.date }) where thread.loaded && !thread.latestFromUser {
            if hermesState(thread) == .working || isSettled(thread, confirmed: confirmed) { continue }
            let read = (dismissed[thread.id] ?? -.infinity) >= thread.latest
            if let request = pendingApproval(thread) {
                if read { continue }
                add(questionID + ":" + request.speaker, title: request.speaker + " 질문", color: questionColor, thread: thread.id)
                continue
            }
            // A "생각 중" line is not a message yet.
            let spoken = thread.messages.filter { $0.fromUser || !SlackText.isThinking($0.body) }
            let answered = spoken.lastIndex { $0.fromUser } ?? -1
            // The newest post that carries one status speaks for the thread. A digest with a bar per line is a summary, not a post to answer.
            guard let stated = spoken.lastIndex(where: { $0.marks.count == 1 && !$0.marks[0].color.isEmpty && !$0.marks[0].text.isEmpty }) else {
                // A character spoke first and the user has not answered: a notification, for a day.
                let root = thread.root
                if !read, !root.fromUser, !SlackText.isThinking(root.body), answered < 0, now.timeIntervalSince(root.date) < alertWindow, now >= root.date {
                    add(alertID, title: "알림", color: alertColor, thread: thread.id)
                }
                continue
            }
            let status = spoken[stated].marks[0]
            if status.text != draft, !isSettled(status.text), answered < stated {
                add(status.text, title: status.text == unanswered ? "답 안 한 DM" : status.text, color: status.color, thread: thread.id)
            }
        }
        func rank(_ id: String) -> Int { id == unanswered ? 0 : id.hasPrefix(questionID + ":") ? 1 : id == alertID ? 2 : 3 }
        return order.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.compactMap { found[$0.element] }
    }
}

/// A new post in the ddots channel, as it is shown while it is sent and as it goes to Slack.
struct DdotsPost: Equatable {
    /// The words with whoever is called named in front: "@개인비서 내일 일정".
    var shown: String
    /// The same for Slack, the call a real mention: "<@U123> 내일 일정".
    var sent: String
    /// Everyone the post calls, by Slack ID.
    var called: [String]
}

/// A character in ddots, with the direct conversation that carries what is said to it.
struct DdotsMember: Identifiable, Equatable {
    var profile: String
    var name: String
    var room: String
    var id: String { profile }
}

/// ddots shows every character's direct conversation as one room, kept at the top of the list of rooms.
/// The direct conversations stay what they are in Slack, so whatever is written on either side is the same message on the other.
enum Ddots {
    /// On unless it was switched off (`defaults write … ddotsEnabled -bool false`).
    /// UI checks go by their own flag alone, whatever this Mac has saved.
    static var enabled = CommandLine.arguments.contains("--ui-smoke-ddots")
        || (!CommandLine.arguments.contains("--ui-smoke") && UserDefaults.standard.object(forKey: "ddotsEnabled") as? Bool ?? true)
    /// Stable internal room ID, independent of its displayed name. It is not a room in Slack.
    static let room = "ddots"
    static var roomName: String {
        let label = HermesRouting.str(DdotsConfig.shared.appearance["homeLabel"])
        return label.isEmpty ? "ddots" : label
    }
    /// The Slack channel every character is in. When the user is in it, a new post in ddots is written there and
    /// Hermes picks who answers; the direct conversations are still shown beside it.
    static var channel: String { HermesRouting.str(HermesRouting.dict(DdotsConfig.shared.document["features"])["homeRoom"]) }
    /// A room's own face; its members still supply mentions and accessibility descriptions.
    static func representative(_ place: SlackRoom, users: Set<String> = []) -> (profile: String, name: String)? {
        guard !place.direct, place.id != room, place.id != stack else { return nil }
        if let profile = DdotsConfig.shared.roomOwner(id: place.id, name: place.name, users: users) {
            return (profile, DdotsConfig.shared.memberName(profile))
        }
        if let label = (DdotsConfig.shared.appearance["roomLabels"] as? [String:String])?[place.id]
            ?? (DdotsConfig.shared.appearance["roomLabels"] as? [String:String])?[place.name] { return ("", label) }
        return nil
    }
    static func hub(_ rooms: [SlackRoom]) -> String? {
        guard !channel.isEmpty else { return nil }
        return rooms.first { !$0.direct && ($0.id == channel || $0.name == channel) }?.id
    }
    /// Whose thread each one in the channel is, by the thread's stamp: the first character to speak in it.
    /// A thread nobody has answered yet is nobody's.
    static func owners(_ messages: [ChatMessage]) -> [String: String] {
        var result: [String: String] = [:]
        for message in messages.sorted(by: { $0.date < $1.date }) where !message.fromUser && !message.profile.isEmpty && !message.sessionID.isEmpty {
            if result[message.sessionID] == nil { result[message.sessionID] = message.profile }
        }
        return result
    }
    /// The words with the character they are for called in front.
    static func addressed(_ text: String, to name: String) -> String { text.isEmpty ? "@" + name : "@" + name + " " + text }
    /// How a new post in the channel goes out, so that whoever it is for is really called there.
    /// A post that already calls someone by the name Slack knows is left as typed. A call by another of a character's
    /// names ("@개인비서") becomes a call by that name. Otherwise a call is put in front only when requested.
    /// `users` gives each character's Slack ID by profile, from its own conversation, so the call does not depend on
    /// the channel's list of members having been read; `members` is that list.
    static func post(_ text: String, to who: DdotsMember, cast: [DdotsMember], users: [String: String], members: [SlackMember], prependCall: Bool = true) -> DdotsPost {
        var callable = members.filter { !$0.user.isEmpty }
        for member in cast {
            guard let user = users[member.profile], !user.isEmpty, !callable.contains(where: { $0.user == user }) else { continue }
            callable.append(SlackMember(profile: member.profile, name: member.name, user: user))
        }
        var shown = text
        if let call = DdotsRoute.leadingCall(text), let member = cast.first(where: { $0.profile == call.profile }), users[member.profile]?.isEmpty == false {
            // What follows the call is never a letter, so the name can stand right where the other one stood.
            shown = "@" + member.name + text.dropFirst(call.call.count)
        }
        var sent = SlackMention.outgoing(shown, members: callable)
        if prependCall, SlackText.mentions(sent).isEmpty, users[who.profile]?.isEmpty == false {
            shown = addressed(shown, to: who.name)
            sent = SlackMention.outgoing(shown, members: callable)
        }
        return DdotsPost(shown: shown, sent: sent, called: SlackText.mentions(sent))
    }
    /// "이" after a name that ends in a consonant, "가" after one that ends in a vowel: "진단담당이", "SNS담당가".
    static func particle(_ name: String) -> String {
        guard let last = name.unicodeScalars.last?.value, (0xAC00...0xD7A3).contains(last) else { return "이(가)" }
        return (last - 0xAC00) % 28 == 0 ? "가" : "이"
    }
    /// The first character a post calls who is not in the channel to hear it. Nil when everyone called is there,
    /// and when who is in the channel could not be read: then there is nothing to go by and the post is sent.
    static func absent(_ post: DdotsPost, cast: [DdotsMember], users: [String: String], members: [SlackMember]) -> DdotsMember? {
        let there = Set(members.map(\.user).filter { !$0.isEmpty })
        guard !there.isEmpty else { return nil }
        return cast.first { member in users[member.profile].map { post.called.contains($0) && !there.contains($0) } ?? false }
    }
    /// What the top of the open window says: the name and the version running. What the pet has to say stays in its bubble.
    static var title: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty ? "DDots" : "DDots " + version
    }
    /// Characters explicitly hidden by the local appearance file.
    /// Each still has its own room in the list, where it can be talked to as before.
    static var excluded: Set<String> { DdotsConfig.shared.excluded }
    /// A new post goes here unless another face is picked.
    static var defaultTarget: String { DdotsConfig.shared.recipient }

    /// The small pet over the conversation is meant for a phone, where no pet sits beside the window.
    /// On the Mac the pet itself is right there, so it is not shown.
    static let showsPet = false
    /// The one tab direct conversations are kept behind. Like ddots it is a way of showing rooms, not a room in Slack.
    static let stack = "dm-stack"
    /// Under ddots the list falls in sections: the ones the user makes and fills by dragging channels in (a channel put
    /// in none is in the first), and the direct conversations last. These are the sections' numbers and their tabs' ids.
    static let defaultSections = [1, 2, 3]
    static let directZone = 4
    static func group(_ zone: Int) -> String { "ZONE\(zone)" }
    static func groupZone(_ id: String) -> Int? {
        guard id.hasPrefix("ZONE"), let zone = Int(id.dropFirst(4)), zone > 0, zone != directZone else { return nil }
        return zone
    }
    /// The section a tab stands for, the direct conversations' tab among them.
    static func sectionZone(_ id: String) -> Int? { id == stack ? directZone : groupZone(id) }
    /// A section's picture is kept under this name, as a room's is under its id.
    static func sectionPicture(_ zone: Int) -> String { group(zone) }
    /// Every tab that stands for rooms folded behind it rather than for a room.
    static func isTab(_ id: String) -> Bool { id == stack || groupZone(id) != nil }

    /// The direct conversations that go behind the one tab, characters first in their usual order, then the rest by name.
    /// One the user pinned to a place of its own stays out in that place.
    static func stacked(_ rooms: [SlackRoom], pins: [String], members: [String: [SlackMember]]) -> [SlackRoom] {
        let order = ChatCharacter.preferred
        func rank(_ room: SlackRoom) -> Int {
            let profile = members[room.id]?.first?.profile ?? ""
            return profile.isEmpty ? order.count + 1 : order.firstIndex(of: profile) ?? order.count
        }
        return rooms.filter { $0.direct && !pins.contains($0.id) }.sorted { (rank($0), $0.name, $0.id) < (rank($1), $1.name, $1.id) }
    }

    /// Each character's direct conversation, by profile.
    static func rooms(_ rooms: [SlackRoom], members: [String: [SlackMember]]) -> [String: String] {
        var result: [String: String] = [:]
        for room in rooms where room.direct {
            guard let profile = members[room.id]?.first?.profile, !profile.isEmpty, !excluded.contains(profile), result[profile] == nil else { continue }
            result[profile] = room.id
        }
        return result
    }

    /// The characters that can be talked to, in their usual order.
    static func members(_ rooms: [String: String], characters: [ChatCharacter]) -> [DdotsMember] {
        ChatCharacter.ordered(characters).compactMap { character in
            rooms[character.id].map { DdotsMember(profile: character.id, name: character.name, room: $0) }
        }
    }

    /// What Slack shows now, with what the record keeps from before placed ahead of it. A thread both hold is shown as Slack has it.
    static func joined(live: [SlackThread], kept: [SlackThread]) -> [SlackThread] {
        guard !kept.isEmpty else { return live }
        // A thread whose replies Slack has not handed over yet shows the ones the record already holds,
        // so its last line is there at once instead of only a count.
        let written = Dictionary(kept.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let live = live.map { thread -> SlackThread in
            guard !thread.loaded, let old = written[thread.id], !old.replies.isEmpty else { return thread }
            var filled = thread
            filled.replies = old.replies; filled.loaded = true; filled.replyCount = max(thread.replyCount, old.replies.count)
            return filled
        }
        let have = Set(live.map(\.id))
        // A line still being sent has no stamp of its own yet and stays last.
        let settled = (kept.filter { !have.contains($0.id) } + live.filter { !$0.ts.isEmpty }).sorted { ($0.position, $0.id) < ($1.position, $1.id) }
        return settled + live.filter(\.ts.isEmpty)
    }

    /// Replies bring a settled thread to the foot; new posts still being sent stay after it.
    static func byActivity(_ threads: [SlackThread]) -> [SlackThread] {
        threads.filter { !$0.ts.isEmpty }.sorted { ($0.latest, $0.id) < ($1.latest, $1.id) } + threads.filter(\.ts.isEmpty)
    }

    /// Threads from several rooms in one line of time, oldest first.
    static func merged(_ threads: [String: [SlackThread]], rooms: [String]) -> [SlackThread] {
        let all = rooms.flatMap { threads[$0] ?? [] }
        return rooms.count < 2 ? all : all.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }
}

/// Whose thread it is, for the colour of its outline.
enum SlackOwner {
    /// Optional per-profile colors from the local appearance file.
    static var hex: [String: String] { DdotsConfig.shared.appearance["colors"] as? [String:String] ?? [:] }
    /// The character of a direct conversation, else whoever opened the thread, else the first character to answer in it.
    static func profile(_ thread: SlackThread, members: [DdotsMember]) -> String {
        if let own = members.first(where: { $0.room == thread.room })?.profile { return own }
        if !thread.root.fromUser, !thread.root.profile.isEmpty { return thread.root.profile }
        return thread.replies.first { !$0.fromUser && !$0.profile.isEmpty }?.profile ?? ""
    }
}

enum SlackRoomOrder {
    static let slots = 5
    /// Rooms with the newest activity first, except that a pinned room keeps its place from the top.
    static func sorted(_ rooms: [SlackRoom], pins: [String], latest: [String: Date]) -> [SlackRoom] {
        let present = Set(rooms.map(\.id))
        let held = pins.prefix(slots).map { present.contains($0) ? $0 : "" }
        var free = rooms.enumerated().filter { !held.contains($0.element.id) }.sorted {
            let a = latest[$0.element.id], b = latest[$1.element.id]
            if a != b { return (a ?? .distantPast) > (b ?? .distantPast) }
            return $0.offset < $1.offset
        }.map(\.element)[...]
        var result: [SlackRoom] = []
        for position in 0..<rooms.count {
            if position < held.count, !held[position].isEmpty, let room = rooms.first(where: { $0.id == held[position] }) { result.append(room) }
            else if let next = free.popFirst() { result.append(next) }
        }
        // Pinned places beyond the last free room close up, so no room is lost.
        return result + rooms.filter { room in !result.contains { $0.id == room.id } }
    }
}

enum SlackSearch {
    /// Lines already read from Slack that contain the words, newest first.
    static func hits(_ query: String, in threads: [String: [SlackThread]], limit: Int = 30) -> [ChatMessage] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !term.isEmpty else { return [] }
        func text(_ message: ChatMessage) -> String {
            let extras: [String] = message.marks.map(\.text) + message.files.map(\.name)
            return ([message.body] + extras + [message.speaker]).joined(separator: "\n").precomposedStringWithCanonicalMapping
        }
        let all: [ChatMessage] = threads.values.flatMap { $0.flatMap(\.messages) }
        let found = all.filter { text($0).range(of: term, options: .caseInsensitive) != nil }
        return Array(found.sorted { $0.date > $1.date }.prefix(limit))
    }
}

/// A thread put on the clipboard: its address in Slack, or every line of it as text.
enum SlackCopy {
    private static let stampShape = try? NSRegularExpression(pattern: #"^\d+\.\d+$"#)
    private static let bareAddress = try? NSRegularExpression(pattern: #"<((?:https?://|mailto:)[^<>\s]+)>"#)

    /// The address Slack itself gives for a thread: the workspace, the room, and the first message's stamp without its point.
    /// `workspace` is the address `auth.test` reports. A line still being sent has no stamp, and so no address.
    static func link(workspace: String, room: String, ts: String) -> String? {
        guard let host = URL(string: workspace)?.host, !room.isEmpty,
              stampShape?.firstMatch(in: ts, range: NSRange(ts.startIndex..., in: ts)) != nil else { return nil }
        return "https://\(host)/archives/\(room)/p\(ts.filter { $0 != "." })?thread_ts=\(ts)&cid=\(room)"
    }

    /// The room and thread an address of this workspace points at, as Slack writes it for a message or a thread:
    /// `…/archives/<room>/p<stamp without its point>?thread_ts=<the thread's stamp>`. Nil for any other address.
    static func place(of url: URL, workspace: String) -> (room: String, ts: String)? {
        guard let host = url.host?.lowercased(), !host.isEmpty, host == URL(string: workspace)?.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 3, parts[0] == "archives", !parts[1].isEmpty, parts[2].hasPrefix("p") else { return nil }
        let digits = parts[2].dropFirst()
        guard digits.count > 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let own = digits.dropLast(6) + "." + digits.suffix(6)
        let thread = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "thread_ts" }?.value
        if let thread, stampShape?.firstMatch(in: thread, range: NSRange(thread.startIndex..., in: thread)) != nil { return (parts[1], thread) }
        return (parts[1], String(own))
    }

    /// The first message and every reply, oldest first, each under its time and speaker. A "생각 중" line is not something said and is left out.
    /// `place` is the room as it is written, such as "#SNS담당방"; `mine` is what the user's own lines go by.
    static func text(_ thread: SlackThread, place: String, link: String?, mine: String = "나", zone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX"); stamp.timeZone = zone; stamp.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = thread.messages.filter { $0.fromUser || !SlackText.isThinking($0.body) }
        let title = (place.isEmpty ? "" : place + " ") + "스레드 · 글 \(lines.count)개"
        let said = lines.map { message -> String in
            // An address kept in angle brackets for Markdown is written plainly.
            var body = message.body
            if let bareAddress { body = bareAddress.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "$1") }
            let extras = message.marks.map { SlackNotice.displayStatus($0.text) }.filter { !$0.isEmpty }.map { "[" + $0 + "]" } + message.files.map { "📎 " + $0.name }
            let head = "[" + stamp.string(from: message.date) + "] " + (message.fromUser ? mine : message.speaker)
            return ([head] + (body.isEmpty ? [] : [body]) + extras).joined(separator: "\n")
        }
        return ([([title] + (link.map { [$0] } ?? [])).joined(separator: "\n")] + said).joined(separator: "\n\n")
    }
}

enum SlackStack {
    static let inlineLimit = 2
    /// A short thread is shown whole; a long one keeps its newest reply and stacks the rest until opened.
    static func visible(_ thread: SlackThread, expanded: Bool) -> (hidden: Int, replies: [ChatMessage]) {
        guard thread.loaded else { return (thread.replyCount, []) }
        if expanded || thread.replies.count <= inlineLimit { return (0, thread.replies) }
        return (thread.replies.count - 1, Array(thread.replies.suffix(1)))
    }
}

enum SlackUnread {
    /// Lines from someone else that arrived after the room was last read, counted one by one as a messenger does.
    /// A thread whose newest reply has not been read from Slack yet counts as one line until it is.
    static func count(_ threads: [SlackThread], lastRead: Double, roomRead: Double = 0, threadRead: [String: Double] = [:]) -> Int {
        threads.reduce(0) { total, thread in
            let replyRead = threadRead[thread.id] ?? 0
            let fresh = thread.messages.filter { message in
                let remote = message.id == thread.root.id ? roomRead : max(replyRead, message.slackBroadcast ? roomRead : 0)
                return !message.fromUser && !SlackText.isThinking(message.body) && message.date.timeIntervalSince1970 > max(lastRead, remote)
            }.count
            let newestKnown = thread.messages.map { $0.date.timeIntervalSince1970 }.max() ?? 0
            let unseen = thread.latest > max(lastRead, replyRead) && thread.latest > newestKnown + 0.0005 && !thread.latestFromUser
            return total + fresh + (unseen ? 1 : 0)
        }
    }
    static func read(_ thread: SlackThread, roomRead: Double, threadRead: [String: Double], threadUnfollowed: Set<String> = [], ownRead: [String: Double] = [:]) -> Bool {
        if thread.replyCount == 0 { return roomRead >= thread.latest && (ownRead[thread.room] ?? 0) < thread.latest }
        if let read = threadRead[thread.id] { return read >= thread.latest && (ownRead[thread.id] ?? 0) < thread.latest }
        return threadUnfollowed.contains(thread.id) && roomRead >= thread.latest && (ownRead[thread.room] ?? 0) < thread.latest
    }
    static func quiet(_ threads: [SlackThread], notices: [SlackNoticeItem], roomRead: [String: Double], threadRead: [String: Double], threadUnfollowed: Set<String>, remoteQuiet: [String: Double], ownRead: [String: Double] = [:]) -> [SlackThread] {
        let ringing = Set(notices.filter(SlackNotice.hasBell).flatMap(\.threads))
        return threads.filter { ringing.contains($0.id) && (remoteQuiet[$0.id] ?? 0) < $0.latest && read($0, roomRead: roomRead[$0.room] ?? 0, threadRead: threadRead, threadUnfollowed: threadUnfollowed, ownRead: ownRead) }
    }
    static func badge(_ count: Int) -> String { count > 99 ? "99+" : count > 0 ? String(count) : "" }
}

enum SlackSpeakers {
    private static func key(_ text: String) -> String { text.filter { !$0.isWhitespace && $0 != "-" && $0 != "_" }.lowercased() }
    /// A Slack bot is matched to its Hermes character by name, so the avatar and colors carry over.
    static func profile(_ name: String, characters: [ChatCharacter]) -> String {
        let wanted = key(name); guard !wanted.isEmpty else { return "" }
        if let configured = DdotsConfig.shared.matching(name) { return configured }
        if let exact = characters.first(where: { key($0.name) == wanted || key($0.id) == wanted }) { return exact.id }
        return characters.first(where: { key($0.name).count >= 2 && (wanted.contains(key($0.name)) || key($0.name).contains(wanted)) })?.id ?? ""
    }
}

enum SlackText {
    private static let token = try? NSRegularExpression(pattern: #"<([^<>\n]+)>"#)
    private static let bold = try? NSRegularExpression(pattern: #"(?<![*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![*\w])"#)
    private static let shortcode = try? NSRegularExpression(pattern: #":([a-z0-9_+\-]+):"#)
    private static let emoji: [String: String] = [
        "thread": "🧵", "white_check_mark": "✅", "heavy_check_mark": "✔️", "x": "❌", "warning": "⚠️", "red_circle": "🔴",
        "large_yellow_circle": "🟡", "large_green_circle": "🟢", "large_blue_circle": "🔵", "white_circle": "⚪️",
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "eyes": "👀", "pray": "🙏", "fire": "🔥", "tada": "🎉", "rocket": "🚀",
        "bell": "🔔", "memo": "📝", "calendar": "📅", "hourglass": "⌛️", "hourglass_flowing_sand": "⏳", "bulb": "💡",
        "sparkles": "✨", "point_right": "👉", "robot_face": "🤖", "thinking_face": "🤔", "email": "✉️", "envelope": "✉️",
        "speech_balloon": "💬", "thought_balloon": "💭", "mag": "🔍", "pushpin": "📌", "link": "🔗", "moneybag": "💰", "cow": "🐮", "no_entry": "⛔️",
        "question": "❓", "exclamation": "❗️", "clock3": "🕒", "alarm_clock": "⏰", "smile": "😄", "sob": "😭", "heart": "❤️",
        "books": "📚", "floppy_disk": "💾", "stopwatch": "⏱️", "inbox_tray": "📥", "outbox_tray": "📤",
        "blush": "😊", "woman-bowing": "🙇‍♀️", "birthday": "🎂", "zap": "⚡️", "arrow_right_hook": "↪️",
    ]

    /// Compiled once per configuration revision, including the fast-path vocabulary.
    static func isThinking(_ body: String) -> Bool {
        let first = String(body.drop(while: { $0.isNewline }).prefix(while: { !$0.isNewline }))
        return !first.isEmpty && DdotsConfig.shared.conversation.matches("thinking", first)
    }

    /// Slack's attachment colours as `#RRGGBB`: its three named ones, or a hex value with or without the mark.
    static func hexColor(_ raw: String) -> String {
        let named = ["good": "#2EB67D", "warning": "#ECB22E", "danger": "#E01E5A"]
        if let known = named[raw.lowercased()] { return known }
        let digits = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit) else { return "" }
        return "#" + digits.uppercased()
    }

    /// The ID before any label in a user mention such as `<@U123|name>`.
    static func mentions(_ raw: String) -> [String] {
        guard let token else { return [] }
        return token.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: raw), raw[range].hasPrefix("@") else { return nil }
            return String(raw[range].dropFirst().split(separator: "|").first ?? "")
        }
    }

    private static func replacing(_ text: String, _ regex: NSRegularExpression?, _ transform: (String) -> String?) -> String {
        guard let regex else { return text }
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let inner = Range(match.range(at: 1), in: text),
                  let replacement = transform(String(text[inner])) else { continue }
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    /// Slack's own markup turned into the Markdown the chat window already renders.
    static func display(_ raw: String, users: [String: String]) -> String {
        var text = replacing(raw, token) { inner in
            let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
            guard let head = parts.first else { return nil }
            let label = parts.count > 1 ? parts[1] : nil
            if head.hasPrefix("@") { return "@" + (users[String(head.dropFirst())] ?? label ?? String(head.dropFirst())) }
            if head.hasPrefix("#") { return "#" + (label ?? String(head.dropFirst())) }
            if head.hasPrefix("!") { return label ?? "@" + String(head.dropFirst().prefix { $0 != "^" }) }
            guard head.contains("://") || head.hasPrefix("mailto:") else { return nil }
            if let label, label != head { return "[\(label)](\(head))" }
            // Kept in angle brackets so Markdown takes the address whole; bare, its underscores would be read as emphasis.
            return "<\(head)>"
        }
        text = text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
        text = replacing(text, bold) { "**\($0)**" }
        return replacing(text, shortcode) { emoji[$0] }
    }
}

/// Everything read from Slack so far. Pure data so grouping can be tested without a network.
struct SlackState: Codable {
    var me = ""
    var users: [String: String] = [:]
    var history: [String: [SlackMessage]] = [:]
    /// Latest reply seen in the channel flow, even after it leaves the history page.
    var channelTimes: [String: [String: Double]] = [:]
    /// First messages of threads older than the listed history, read because something happened in them lately.
    var extra: [String: [String: SlackMessage]] = [:]
    /// Replies per room and thread, without the thread's first message.
    var replies: [String: [String: [SlackMessage]]] = [:]

    func chat(_ message: SlackMessage, room: String, characters: [ChatCharacter]) -> ChatMessage {
        let mine = !me.isEmpty && message.user == me
        let slackName = mine ? "" : (message.name.isEmpty ? users[message.user] ?? "Slack" : message.name)
        let profile = mine ? "" : SlackSpeakers.profile(slackName, characters: characters)
        // A bot matched to a character goes by the character's own name, whatever the bot is called in Slack.
        let name = characters.first { $0.id == profile }?.name ?? slackName
        var result = ChatMessage(id: "slack:\(room):\(message.ts)", fromUser: mine, speaker: name, body: SlackText.display(message.text, users: users),
                                 date: Date(timeIntervalSince1970: message.time), sessionID: message.threadTS ?? message.ts,
                                 profile: profile)
        result.slackUserID = message.user
        result.slackBroadcast = message.broadcast
        result.files = message.files
        result.marks = message.marks.map { ChatMark(color: $0.color, text: SlackText.display($0.text, users: users)) }
        result.hermesReplyState = message.effectiveHermesReplyState
        result.hermesReplyEvidence = message.hermesReplyEvidence
        result.hermesButtons = message.hermesButtons ?? []
        result.hermesChecklist = message.hermesChecklist ?? []
        result.hermesChecklistSelected = message.hermesChecklistSelected ?? []
        result.hermesChecklistCanSkip = message.hermesChecklistCanSkip ?? false
        result.quoteColors = message.quoteColors ?? []
        return result
    }

    func threads(room: String, characters: [ChatCharacter]) -> [SlackThread] {
        let listed = (history[room] ?? []).filter(\.isRoot)
        let known = Set(listed.map(\.ts))
        let broadcasts = Dictionary(grouping: (history[room] ?? []).filter { !$0.isRoot }, by: { $0.threadTS ?? "" })
        return (listed + (extra[room] ?? [:]).values.filter { !known.contains($0.ts) }).sorted { $0.time < $1.time }.map { root in
            let cached = replies[room]?[root.ts]
            let answers = (cached ?? []).sorted { $0.time < $1.time }
            // The newest line is only known once the replies read so far reach the stamp Slack reports.
            let stamp = Double(root.latestReply ?? "") ?? 0
            let newest = answers.last ?? root
            let known = (cached != nil || root.replyCount == 0) && newest.time >= stamp
            return SlackThread(id: "slack:\(room):\(root.ts)", room: room, ts: root.ts,
                               root: chat(root, room: room, characters: characters),
                               replies: answers.map { chat($0, room: room, characters: characters) },
                               replyCount: max(root.replyCount, answers.count), loaded: cached != nil || root.replyCount == 0,
                               latest: max(newest.time, stamp), latestFromUser: known && !me.isEmpty && newest.user == me,
                               broadcastTime: max(channelTimes[room]?[root.ts] ?? 0, (answers.filter(\.broadcast) + (broadcasts[root.ts] ?? [])).map(\.time).max() ?? 0))
        }.sorted { ($0.position, $0.id) < ($1.position, $1.id) }
    }

    /// People whose names are still unknown, from authors and mentions alike.
    func unknownUsers(room: String) -> [String] {
        let all = (history[room] ?? []) + (replies[room]?.values.flatMap { $0 } ?? []) + Array((extra[room] ?? [:]).values)
        var seen = Set<String>()
        return all.flatMap { ($0.name.isEmpty && !$0.user.isEmpty ? [$0.user] : []) + SlackText.mentions($0.text) }
            .filter { !$0.isEmpty && users[$0] == nil && seen.insert($0).inserted }
    }
}

/// Bounded memo for edited-in-place Slack status messages. Confined to the Slack queue.
struct SlackThinkingMemo {
    private var rulesGeneration = -1
    private mutating func refreshRules() {
        let generation = DdotsConfig.shared.generation
        if rulesGeneration != generation { entries.removeAll(); rulesGeneration = generation }
    }
    private var entries: [String: (text: String, value: Bool)] = [:]
    private(set) var evaluations = 0
    mutating func value(ts: String, text: String) -> Bool {
        refreshRules()
        if let cached = entries[ts], cached.text == text { return cached.value }
        if entries.count >= 8192 { entries.removeAll(keepingCapacity: true) }
        let result = SlackText.isThinking(text)
        evaluations += 1; entries[ts] = (text, result)
        return result
    }
}

/// Diagnostic text contains elapsed times, so refresh periodically even on an unchanged snapshot.
/// 새우튀김 page and whole-list clicks, structure only (never message text), in `page-log.txt` next to the other logs.
enum PageTrace {
    private static let lock = NSLock()
    static var enabled = Bundle.main.bundlePath.hasSuffix(".app") && !CommandLine.arguments.contains("--ui-smoke") && !CommandLine.arguments.contains("--relay")
    static func log(_ line: String) {
        guard enabled, let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("ddots") else { return }
        lock.lock(); defer { lock.unlock() }
        let file = folder.appendingPathComponent("page-log.txt")
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(String(format: "%.1f ", Date().timeIntervalSince1970) + line)
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}

struct SlackDiagnosticsGate {
    private var room: String?
    private var last = -Double.infinity
    mutating func shouldBuild(room: String, now: Double) -> Bool {
        guard self.room != room || now - last >= 10 || now < last else { return false }
        self.room = room; last = now
        return true
    }
}

/// Value cache: copies can be prepared on the Slack queue before publishing on main.
/// Retains only the current room/thread data and never hides a newly received message.
struct SlackPublishCache {
    private var rulesGeneration = -1
    private mutating func refreshRules() {
        let generation = DdotsConfig.shared.generation
        if rulesGeneration != generation { rooms.removeAll(); latest.removeAll(); incoming = []; rulesGeneration = generation }
    }
    private struct Room {
        var threads: [SlackThread]
        var latest: ChatMessage?
        var incoming: [ChatMessage]
    }
    private var rooms: [String: Room] = [:]
    private var excluded = Set<String>()
    private(set) var latest: [String: ChatMessage] = [:]
    private(set) var incoming: [ChatMessage] = []
    private(set) var roomBuilds = 0
    mutating func prepare(_ threads: [String: [SlackThread]], excluding: Set<String>) {
        refreshRules()
        var changed = excluded != excluding
        excluded = excluding
        for room in Array(rooms.keys) where threads[room] == nil { rooms[room] = nil; latest[room] = nil; changed = true }
        for (room, values) in threads where rooms[room]?.threads != values {
            let messages = values.flatMap(\.messages)
            let last = messages.max { $0.date < $1.date }
            rooms[room] = Room(threads: values, latest: last, incoming: messages.filter { !$0.fromUser && !SlackText.isThinking($0.body) })
            latest[room] = last; roomBuilds += 1; changed = true
        }
        if changed {
            incoming = rooms.filter { !excluded.contains($0.key) }.values.flatMap(\.incoming).sorted(by: ChatTimeline.ordered)
        }
    }
}

struct SlackUnreadCache {
    private var rulesGeneration = -1
    private mutating func refreshRules() {
        let generation = DdotsConfig.shared.generation
        if rulesGeneration != generation { entries.removeAll(); rulesGeneration = generation }
    }
    private struct Entry {
        var thread: SlackThread
        var lastRead: Double, roomRead: Double, replyRead: Double
        var count: Int
    }
    private var entries: [String: Entry] = [:]
    private(set) var evaluations = 0
    mutating func count(_ thread: SlackThread, lastRead: Double, roomRead: Double, threadRead: [String: Double]) -> Int {
        refreshRules()
        let replyRead = threadRead[thread.id] ?? 0
        if let old = entries[thread.id], old.thread == thread, old.lastRead == lastRead, old.roomRead == roomRead, old.replyRead == replyRead { return old.count }
        let value = SlackUnread.count([thread], lastRead: lastRead, roomRead: roomRead, threadRead: threadRead)
        entries[thread.id] = Entry(thread: thread, lastRead: lastRead, roomRead: roomRead, replyRead: replyRead, count: value)
        evaluations += 1
        return value
    }
    mutating func retain(_ ids: Set<String>) { entries = entries.filter { ids.contains($0.key) } }
}

/// Main-owner value cache. Time-dependent items are valid only between root/expiry boundaries.
struct SlackNoticeMemo {
    private var rulesGeneration = -1
    private mutating func refreshRules() {
        let generation = DdotsConfig.shared.generation
        if rulesGeneration != generation { entries.removeAll(); previous = []; interval = nil; petApprovalInput = nil; rulesGeneration = generation }
    }
    private struct Entry {
        var thread: SlackThread; var confirmed: Set<String>
        var assessment: (pending: ChatMessage?, state: ChatMark?)
        var settled: Bool
    }
    private var entries: [String: Entry] = [:]
    private var previous: [SlackThread] = []
    private var dismissed: [String: Double] = [:]
    private var confirmed: Set<String> = []
    private var interval: Range<Double>?
    private var value: [SlackNoticeItem] = []
    private(set) var itemEvaluations = 0
    private struct PetApprovalInput: Equatable {
        var threads: [SlackThread]
        var rooms: Set<String>
        var confirmed: Set<String>
    }
    private var petApprovalInput: PetApprovalInput?
    private var petApproval = false
    private(set) var petApprovalEvaluations = 0
    var count: Int { entries.count }
    private mutating func entry(_ thread: SlackThread, confirmed: Set<String>) -> Entry {
        refreshRules()
        if let old = entries[thread.id], old.thread == thread, old.confirmed == confirmed { return old }
        let result = Entry(thread: thread, confirmed: confirmed, assessment: SlackNotice.assessment(thread, confirmed: confirmed), settled: SlackNotice.isSettled(thread, confirmed: confirmed))
        if entries.count >= 512 { entries.removeAll(keepingCapacity: true) }
        entries[thread.id] = result
        return result
    }
    mutating func assessment(_ thread: SlackThread, confirmed: Set<String>) -> (pending: ChatMessage?, state: ChatMark?) { entry(thread, confirmed: confirmed).assessment }
    mutating func isSettled(_ thread: SlackThread, confirmed: Set<String>) -> Bool { entry(thread, confirmed: confirmed).settled }
    /// Both pet timers read this. Reuse the whole decision until its inputs change, even when the room has more
    /// threads than the per-thread cache can retain. A completed request may still offer buttons, but never waves.
    mutating func needsPetApproval(_ threads: [SlackThread], rooms: Set<String>, confirmed: Set<String>) -> Bool {
        refreshRules()
        let input = PetApprovalInput(threads: threads, rooms: rooms, confirmed: confirmed)
        if petApprovalInput == input { return petApproval }
        petApproval = threads.contains { thread in
            guard rooms.contains(thread.room) else { return false }
            let notice = entry(thread, confirmed: confirmed)
            return notice.assessment.pending.map(SlackNotice.requestsPetReply) == true && !notice.settled
        }
        petApprovalInput = input
        petApprovalEvaluations += 1
        return petApproval
    }
    mutating func items(_ threads: [SlackThread], now: Date = Date(), dismissed: [String: Double], confirmed: Set<String>) -> [SlackNoticeItem] {
        refreshRules()
        let stamp = now.timeIntervalSince1970
        if let interval, interval.contains(stamp), previous == threads, self.dismissed == dismissed, self.confirmed == confirmed { return value }
        let result = SlackNotice.items(threads, now: now, dismissed: dismissed, confirmed: confirmed)
        itemEvaluations += 1
        guard threads.count <= 2048 else { interval = nil; previous = []; value = []; return result }
        let boundaries = threads.flatMap { [$0.root.date.timeIntervalSince1970, $0.root.date.timeIntervalSince1970 + SlackNotice.alertWindow] }
        let lower = boundaries.filter { $0 <= stamp }.max() ?? -.infinity
        let upper = boundaries.filter { $0 > stamp }.min() ?? .infinity
        interval = lower..<upper; previous = threads; self.dismissed = dismissed; self.confirmed = confirmed; value = result
        return result
    }
}
