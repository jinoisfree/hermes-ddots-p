import Foundation
import AppKit

extension Result {
    var failureValue: Failure? { if case .failure(let failure) = self { return failure }; return nil }
}

/// A made-up workspace answered from memory; nothing here reaches Slack.
final class FakeSlack {
    var history: [String: [[String: Any]]] = [:]
    var replies: [String: [[String: Any]]] = [:]
    var infoFailure: SlackAPI.Failure?
    var memberFailure: SlackAPI.Failure?
    var keyWriteFailures: [String: SlackAPI.Failure] = [:]
    var infoRooms: [String] = []
    var roomReads: [String: String] = [:]
    var readMarks: [(String, [String: String])] = []
    var writeFailures: [String: SlackAPI.Failure] = [:]
    var failure: SlackAPI.Failure?
    /// Methods Slack refuses for pace, each with the Retry-After it gives, and what happens while it answers.
    var limited: [String: Double] = [:]
    /// Threads answered a page at a time, as `room:ts`, and the cursor of each page asked for ("0" for the first).
    var replyPages: [String: [[[String: Any]]]] = [:]
    var pageLog: [String] = []
    var answering: (() -> Void)?
    var posted: [[String: String]] = []
    var log: [String] = []
    var replyLog: [String] = []
    var historyLog: [String] = []
    var uploads: [String: Data] = [:]
    /// Rooms Slack refuses on their own account, with the code it gives.
    var refused: [String: String] = [:]
    /// Names Slack fails to give for now.
    var unreadable: [String: SlackAPI.Failure] = [:]
    var inactiveUsers = Set<String>()
    var userLookups: [String] = []
    var memberLists: [String: [String]] = [:]
    /// Threads that are gone, as `room:ts`.
    var gone = Set<String>()
    /// Messages deleted, in the order asked, and the ones Slack will not let this person delete.
    var deleted: [String] = []
    var undeletable = Set<String>()
    /// Rooms that come on a second page of the list.
    var nextPage: [[String: Any]] = []
    /// Channels put away that the user is still in, listed with the others.
    var archivedListing: [[String: Any]] = []
    /// What making, filling and putting away rooms asked for, and the codes Slack refuses them with.
    var roomChanges: [(String, [String: String])] = []
    var roomRefusals: [String: String] = [:]
    var raw: SlackAPI.Raw {
        { [unowned self] url, body in
            if let body { self.uploads[url.absoluteString.removingPercentEncoding ?? url.absoluteString] = body; return .success(Data("OK".utf8)) }
            return url.absoluteString.contains("denied") ? .failure(.api("missing_scope:files:read")) : .success(Data("bytes of \(url.lastPathComponent)".utf8))
        }
    }
    var api: SlackAPI {
        SlackAPI(transport: transport, raw: raw)
    }
    var transport: SlackAPI.Transport {
        { [unowned self] method, parameters in
            self.log.append(method)
            if method == "conversations.history" { self.historyLog.append(parameters["channel"] ?? "") }
            if method == "conversations.replies" { self.replyLog.append((parameters["channel"] ?? "") + ":" + (parameters["ts"] ?? "")) }
            if let failure = self.failure { return .failure(failure) }
            if let wait = self.limited[method] { self.answering?(); return .failure(.rateLimited(wait)) }
            var body: [String: Any] = ["ok": true]
            let asked = parameters["channel"] ?? ""
            if ["conversations.history", "conversations.replies"].contains(method) {
                if let code = self.refused[asked] { return .success((try? JSONSerialization.data(withJSONObject: ["ok": false, "error": code])) ?? Data()) }
                if method == "conversations.replies", self.gone.contains(asked + ":" + (parameters["ts"] ?? "")) { return .success(Data("{\"ok\":false,\"error\":\"thread_not_found\"}".utf8)) }
            }
            if ["conversations.mark", "subscriptions.thread.mark"].contains(method) {
                self.readMarks.append((method, parameters))
                if let failure = self.keyWriteFailures[parameters["channel"] ?? ""] { return .failure(failure) }
                if let failure = self.writeFailures[method] { return .failure(failure) }
            }
            if method == "conversations.info" { self.infoRooms.append(asked) }
            if method == "conversations.info", let failure = self.infoFailure { return .failure(failure) }
            if method == "conversations.members", let failure = self.memberFailure { return .failure(failure) }
            switch method {
            case "conversations.mark", "subscriptions.thread.mark": break
            case "conversations.info": body["channel"] = ["last_read": self.roomReads[asked] ?? "0"]
            case "auth.test": body["user_id"] = "UME"; body["url"] = "https://team.slack.test/"
            case "users.conversations":
                if parameters["cursor"] == "page2" { body["channels"] = self.nextPage; break }
                body["channels"] = [["id": "CCOW", "name": "SNS담당방"], ["id": "CTRUTH", "name": "진실의방"], ["id": "DJARVIS", "is_im": true, "user": "UJARVIS"]] + self.archivedListing
                if !self.nextPage.isEmpty { body["response_metadata"] = ["next_cursor": "page2"] }
            case "users.info":
                self.userLookups.append(parameters["user"] ?? "")
                if let failure = self.unreadable[parameters["user"] ?? ""] { return .failure(failure) }
                let names = ["UJARVIS": "개인비서", "UOLDJARVIS": "개인비서", "UGUEST": "손님", "UCOWBOT": "SNS담당"]
                guard let name = names[parameters["user"] ?? ""] else { body = ["ok": false, "error": "user_not_found"]; break }
                body["user"] = ["real_name": name, "profile": ["display_name": ""], "deleted": self.inactiveUsers.contains(parameters["user"] ?? "")]
            case "conversations.members": body["members"] = self.memberLists[asked] ?? ["CCOW": ["UME", "UCOWBOT", "UGUEST"], "CTRUTH": ["UJARVIS", "UME", "UGONE"]][asked] ?? []
            case "conversations.history": body["messages"] = self.history[parameters["channel"] ?? ""] ?? []; body["has_more"] = false
            case "conversations.replies":
                let key = (parameters["channel"] ?? "") + ":" + (parameters["ts"] ?? "")
                if let pages = self.replyPages[key] {
                    let index = Int(parameters["cursor"] ?? "0") ?? 0
                    self.pageLog.append(String(index))
                    let deleted = Set(self.deleted)
                    body["messages"] = pages[index].filter { !deleted.contains($0["ts"] as? String ?? "") }
                    body["response_metadata"] = ["next_cursor": index + 1 < pages.count ? String(index + 1) : ""]
                    break
                }
                body["messages"] = self.replies[key] ?? []
            case "files.getUploadURLExternal":
                body["upload_url"] = "https://upload.test/" + (parameters["filename"] ?? ""); body["file_id"] = "F" + (parameters["length"] ?? "")
            case "files.completeUploadExternal": self.posted.append(parameters)
            case "users.list":
                body["members"] = [["id": "UME", "real_name": "나"], ["id": "USLACKBOT", "name": "slackbot", "is_bot": true],
                                   ["id": "UGUEST", "real_name": "손님"], ["id": "UCOWBOT", "real_name": "SNS담당", "name": "cow-agent", "is_bot": true],
                                   ["id": "UTOOL", "name": "tool", "is_bot": true], ["id": "UGONE", "real_name": "떠난 사람", "deleted": true]]
            case "conversations.create", "conversations.invite", "conversations.archive", "conversations.unarchive", "conversations.rename":
                self.roomChanges.append((method, parameters))
                if let code = self.roomRefusals[method] { body = ["ok": false, "error": code]; break }
                if ["conversations.create", "conversations.rename"].contains(method) { body["channel"] = ["id": parameters["channel"] ?? "CNEW", "name": parameters["name"] ?? ""] }
            case "chat.delete":
                let ts = parameters["ts"] ?? ""
                self.deleted.append(ts)
                if self.undeletable.contains(ts) { body = ["ok": false, "error": "cant_delete_message"]; break }
                self.history[asked]?.removeAll { $0["ts"] as? String == ts }
                for key in self.replies.keys where key.hasPrefix(asked + ":") { self.replies[key]?.removeAll { $0["ts"] as? String == ts } }
            case "chat.postMessage":
                self.posted.append(parameters)
                var message: [String: Any] = ["ts": "900.000001", "user": "UME", "text": parameters["text"] ?? ""]
                if let thread = parameters["thread_ts"] { message["thread_ts"] = thread }
                body["message"] = message
            default: body = ["ok": false, "error": "unknown_method"]
            }
            return .success((try? JSONSerialization.data(withJSONObject: body)) ?? Data())
        }
    }
}

@main struct SlackTests {
    static func check(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    /// Making a channel and asking people in, putting it away and back, in a made-up workspace.
    static func roomChanges() {
        check(SlackBridge.channelName("  #새 프로젝트 Room!! ") == "새-프로젝트-room" && SlackBridge.channelName("###").isEmpty, "A typed name becomes one Slack takes")
        let fake = FakeSlack()
        fake.archivedListing = [["id": "COLD", "name": "지난방", "is_archived": true]]
        let bridge = SlackBridge(api: fake.api), now = Date(timeIntervalSince1970: 900)
        let cow = ChatCharacter(id: "sns-manager", name: "SNS담당")
        _ = bridge.sync(SlackBridge.Request(active: "CCOW", open: true, characters: [cow]), now: now)
        check(!bridge.current.rooms.contains { $0.id == "COLD" } && bridge.current.archived == [SlackRoom(id: "COLD", name: "지난방")], "Archived channels are set apart, not listed: \(bridge.current.rooms)")
        check(!fake.historyLog.contains("COLD") && !fake.infoRooms.contains("COLD"), "An archived channel is never read")
        guard case .success(let people) = bridge.people() else { return check(false, "people are read") }
        check(people.map(\.id) == ["UCOWBOT", "UTOOL", "UGUEST"] && people[0].profile == "sns-manager" && people[0].agent && people[1].agent && !people[2].agent,
              "Characters, then other apps, then people; never the user, Slack's bot or someone gone: \(people)")
        check(people[0].handle == "cow-agent", "The Slack account handle is available to distinguish agents with the same name")
        let made = bridge.createRoom(name: "새방", isPrivate: true, inviting: ["UCOWBOT", "UME", "UGUEST"])
        check(made.room == SlackRoom(id: "CNEW", name: "새방") && made.problem == nil, "The new room is given back")
        check(fake.roomChanges.map(\.0) == ["conversations.create", "conversations.invite"] && fake.roomChanges[0].1["is_private"] == "true"
              && fake.roomChanges[1].1["users"] == "UCOWBOT,UGUEST" && fake.roomChanges[1].1["channel"] == "CNEW", "A private channel is made and the chosen, not the user, asked in")
        let channelOrder = [("CNEW", "새방"), ("CTRUTH", "진실의방"), ("CCOW", "SNS담당방")].sorted { $0.1 < $1.1 }.map(\.0) + ["DJARVIS"]
        check(bridge.current.rooms.map(\.id) == channelOrder && Set(bridge.current.members["CNEW"]?.map(\.user) ?? []) == ["UCOWBOT", "UGUEST"],
              "The new room shows among the channels with its members at once: \(bridge.current.rooms)")
        check(bridge.archive(room: "CNEW") == nil && !bridge.current.rooms.contains { $0.id == "CNEW" } && bridge.current.archived.map(\.id) == ["CNEW", "COLD"], "Archiving moves the room among the archived")
        check(bridge.unarchive(room: "COLD") == nil && bridge.current.rooms.contains { $0.id == "COLD" } && bridge.current.archived.map(\.id) == ["CNEW"], "Bringing one back lists it again")
        check(bridge.rename(room: "COLD", to: "가나다") == nil && bridge.current.rooms.first { $0.id == "COLD" }?.name == "가나다"
              && bridge.current.rooms.filter { !$0.direct }.map(\.name) == bridge.current.rooms.filter { !$0.direct }.map(\.name).sorted(), "A renamed room keeps its id and takes its place by the new name")
        fake.roomRefusals = ["conversations.rename": "name_taken"]
        check(bridge.rename(room: "COLD", to: "SNS담당방")?.contains("같은 이름") == true && bridge.current.rooms.first { $0.id == "COLD" }?.name == "가나다", "A refused rename leaves the name")
        fake.roomRefusals = ["conversations.create": "name_taken", "conversations.archive": "restricted_action"]
        let taken = bridge.createRoom(name: "SNS담당방", isPrivate: false, inviting: [])
        check(taken.room == nil && taken.problem?.contains("같은 이름") == true, "A taken name is said plainly")
        check(bridge.archive(room: "CCOW")?.contains("관리자") == true && bridge.current.rooms.contains { $0.id == "CCOW" }, "A refused archive leaves the room where it was")
        fake.roomRefusals = ["conversations.invite": "missing_scope"]
        let half = bridge.createRoom(name: "반쪽", isPrivate: false, inviting: ["UGUEST"])
        check(half.room != nil && half.problem?.hasPrefix("방은 만들었지만") == true, "A room made whose invite failed is still given back, with why")
    }

    static func agentInvitations() {
        _ = NSApplication.shared
        let people = [SlackBridge.Person(id: "UJARVIS", name: "개인비서", profile: "personal-secretary", bot: true, handle: "jarvis"),
                      SlackBridge.Person(id: "UJ2", name: "개인비서", profile: "personal-secretary", bot: true, handle: "jarvis-new"),
                      SlackBridge.Person(id: "UC", name: "SNS담당", profile: "sns-manager", bot: true),
                      SlackBridge.Person(id: "UTOOL", name: "Calendar", bot: true),
                      SlackBridge.Person(id: "UPERSON", name: "손님")]
        let dialog = SlackRoomDialogs.inviteDialog(room: "합성채널", people: people, unreadable: nil, agentsOnly: true, inside: ["UC"])
        check(dialog.alert.messageText == "#합성채널에 에이전트 추가" && dialog.picks.boxes.map(\.id) == ["UJARVIS", "UJ2", "UC"], "Only Hermes characters are offered by the agent action")
        check(dialog.picks.boxes[0].box.title.contains("@jarvis") && dialog.picks.boxes[1].box.title.contains("@jarvis-new"), "Same-named accounts can be distinguished before inviting")
        check(!dialog.picks.boxes[2].box.isEnabled && dialog.picks.boxes[2].box.title.contains("참여 중"), "An agent already in the channel stays visible and cannot be invited again")
        dialog.picks.boxes[0].box.state = .on; dialog.picks.boxes[2].box.state = .on
        check(dialog.picks.chosen == ["UJARVIS"], "Only enabled, selected account IDs are invited")
        let allInside = SlackRoomDialogs.inviteDialog(room: "합성채널", people: people, unreadable: nil, agentsOnly: true, inside: ["UJARVIS", "UJ2", "UC"])
        check(!allInside.alert.buttons[0].isEnabled, "No invite is offered when every character is already inside")
        let noAgents = SlackRoomDialogs.inviteDialog(room: "합성채널", people: Array(people.suffix(2)), unreadable: nil, agentsOnly: true)
        check(noAgents.picks.boxes.isEmpty && !noAgents.alert.buttons[0].isEnabled, "An integration or a person alone is not an available character")
        let failed = SlackRoomDialogs.inviteDialog(room: "합성채널", people: [], unreadable: "권한 부족", agentsOnly: true)
        check(failed.picks.chosen.isEmpty && !failed.alert.buttons[0].isEnabled, "An unreadable list cannot invite anyone")
        let general = SlackRoomDialogs.inviteDialog(room: "합성채널", people: people, unreadable: nil, inside: ["UC"])
        check(general.picks.boxes.map(\.id) == ["UJARVIS", "UJ2", "UTOOL", "UPERSON"], "The existing people action keeps integrations and people, excluding current members")

        let fake = FakeSlack(), bridge = SlackBridge(api: fake.api)
        _ = bridge.sync(.init(characters: [ChatCharacter(id: "personal-secretary", name: "개인비서")]), now: Date(timeIntervalSince1970: 900))
        check(bridge.invite(room: "CCOW", users: dialog.picks.chosen) == nil && fake.roomChanges.last?.0 == "conversations.invite"
              && fake.roomChanges.last?.1["channel"] == "CCOW" && fake.roomChanges.last?.1["users"] == "UJARVIS"
              && bridge.current.members["CCOW"]?.contains { $0.user == "UJARVIS" } == true, "The chosen account is invited into the existing channel and appears among its members")
        check(fake.posted.isEmpty && !fake.log.contains("conversations.create"), "Adding an agent does not post a message or create a channel")
    }

    static func deletedAgents() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-deleted-agents-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent(SlackCache.fileName), fake = FakeSlack()
        fake.nextPage = [["id": "DOLD", "is_im": true, "user": "UOLDJARVIS"]]
        fake.memberLists["CTRUTH"] = ["UJARVIS", "UOLDJARVIS", "UME"]
        fake.inactiveUsers = ["UOLDJARVIS"]
        fake.history["CTRUTH"] = [["ts": "800.0", "user": "UOLDJARVIS", "text": "이전 답변은 남아 있어요"]]
        fake.history["DJARVIS"] = [["ts": "801.0", "user": "UJARVIS", "text": "현재 답변"]]
        let cast = [ChatCharacter(id: "personal-secretary", name: "개인비서")]
        let request = SlackBridge.Request(active: "CTRUTH", open: true, watch: ["DJARVIS", "DOLD"], characters: cast)
        let start = Date(timeIntervalSince1970: 900), bridge = SlackBridge(api: fake.api, cache: file)
        var view = bridge.sync(request, now: start)
        check(view.rooms.filter(\.direct).map(\.id) == ["DJARVIS"] && !fake.historyLog.contains("DOLD"), "A deleted same-named bot's DM is neither shown nor polled")
        check(view.members["CTRUTH"]?.map(\.user) == ["UJARVIS"] && view.threads["CTRUTH"]?.first?.root.body == "이전 답변은 남아 있어요", "Deleted agents leave the member picker while earlier channel messages stay readable")

        fake.unreadable["UJARVIS"] = .network("일시 오류")
        view = bridge.sync(request, now: start.addingTimeInterval(301))
        check(view.rooms.contains { $0.id == "DJARVIS" && $0.name == "개인비서" }, "A transient lookup error keeps a known live account and its name")
        fake.unreadable = [:]; fake.inactiveUsers.insert("UJARVIS")
        view = bridge.sync(request, now: start.addingTimeInterval(602))
        check(!view.rooms.contains(where: \.direct) && view.threads["DJARVIS"] == nil && view.members["CTRUTH"]?.isEmpty == true,
              "A bot deleted after its name was cached disappears on the next room refresh")
        bridge.flush(now: start.addingTimeInterval(603))
        let cache = SlackCache.read(file)!
        check(cache.deletedUsers == ["UJARVIS", "UOLDJARVIS"] && !cache.rooms.contains(where: \.direct), "Deletion state is saved, including when there are no remaining DMs")
        var stale = cache
        stale.rooms.append(SlackRoom(id: "DJARVIS", name: "개인비서", direct: true))
        stale.imUsers["DJARVIS"] = "UJARVIS"
        stale.memberIDs["DJARVIS"] = ["UJARVIS"]
        stale.state.history["DJARVIS"] = [SlackMessage(ts: "801.0", user: "UJARVIS", text: "이전 캐시")]
        check(SlackCache.write(try! JSONEncoder().encode(stale), to: file), "Synthetic stale cache is written")
        let next = SlackBridge(api: fake.api, cache: file)
        let restored = next.restore(characters: cast)!
        check(!restored.rooms.contains(where: \.direct) && restored.threads["DJARVIS"] == nil, "A restart filters stale rooms and messages for accounts already known to be deleted")
        fake.inactiveUsers.remove("UJARVIS")
        view = next.sync(request, now: start.addingTimeInterval(903))
        check(view.rooms.filter(\.direct).map(\.id) == ["DJARVIS"], "An explicitly reactivated account becomes available again")

        var legacy = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(cache)) as! [String: Any]
        legacy.removeValue(forKey: "deletedUsers")
        check(SlackCache.write(try! JSONSerialization.data(withJSONObject: legacy), to: file) && SlackCache.read(file) != nil, "Caches from before deletion tracking remain readable")

        fake.unreadable["UOLDJARVIS"] = .api("user_not_found")
        let transport = fake.transport
        let empty = SlackBridge(api: SlackAPI(transport: { method, parameters in
            if method == "users.conversations" {
                fake.log.append(method)
                return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "channels": [["id": "DOLD", "is_im": true, "user": "UOLDJARVIS"]]]))
            }
            return transport(method, parameters)
        }))
        check(empty.sync(.init(characters: cast), now: start).rooms.isEmpty, "A permanently removed user is hidden even when Slack no longer returns a user object")
        let listings = fake.log.filter { $0 == "users.conversations" }.count
        _ = empty.sync(.init(characters: cast), now: start.addingTimeInterval(1))
        check(fake.log.filter { $0 == "users.conversations" }.count == listings, "An empty list after deleted accounts were filtered does not cause a polling loop")
    }
    static func fastPages() {
        for command in ["쪽: 2", "전체 보기"] {
        for mode in ["ok", "timeout", "foreign", "channel", "text", "phone", "old", "rate", "delete-rate", "delete-permission", "delete-channel"] {
            let fake = FakeSlack(), root: [String: Any] = ["ts": "800.0", "user": "UCOWBOT", "text": "list", "reply_count": 2, "latest_reply": "801.0"]
            let control: [String: Any] = ["ts": "901.0", "thread_ts": "800.0", "user": "UCOWBOT", "text": command == "전체 보기" ? "전체 목록 1/1 · 총 25건\n\n1. 가짜.xlsx" : "쪽 2/3 · 총 25건 — 이전 · 다음 · 전체 보기 · 'N쪽'처럼 글로 보내도 됩니다"]
            fake.history["CCOW"] = [root]; fake.replies["CCOW:800.0"] = [root]
            let transport = fake.transport
            let api = SlackAPI(transport: { method, params in
                if mode == "delete-channel" && method == "chat.delete" { fake.log.append(method); return .failure(.api("channel_not_found")) }
                if mode == "delete-permission" && method == "chat.delete" { fake.log.append(method); return .failure(.api("missing_scope")) }
                if mode == "delete-rate" && method == "chat.delete" { fake.log.append(method); return .failure(.rateLimited(60)) }
                return transport(method, params)
            })
            let bridge = SlackBridge(api: api), now = Date(timeIntervalSince1970: 900)
            _ = bridge.sync(SlackBridge.Request(active: "CCOW", open: true), now: now)
            fake.log = []; fake.replyLog = []
            let start = mode == "old" ? now.addingTimeInterval(100) : now
            let sent = bridge.beginPage(room: "CCOW", thread: "800.0", bot: "UCOWBOT", command: command, now: start)
            if mode == "old" { check(!sent && fake.deleted.isEmpty, "Old send receipt never registered for deletion"); continue }
            check(sent, "Page send registered")
            check(!bridge.beginPage(room: "CCOW", thread: "800.0", bot: "UCOWBOT", command: "전체 보기", now: now), "Concurrent navigation request refused")
            var source: [String: Any] = ["ts": "900.000001", "thread_ts": "800.0", "user": "UME", "text": command]
            if mode == "foreign" { source["user"] = "OTHER" }
            if mode == "channel" { source["channel"] = "OTHER" }
            if mode == "text" { source["text"] = "일반 글" }
            if mode == "phone" { source["ts"] = "900.5" }
            fake.replies["CCOW:800.0"] = [root,source] + (mode == "timeout" ? [] : [control])
            if mode == "rate" { fake.failure = .rateLimited(60) }
            var done = false
            for offset in [0.4,1.0,2.0,4.0] where !done { done = bridge.observePage(now: now.addingTimeInterval(offset)) }
            check(done && bridge.pageRequest == nil, "Bounded page job finishes")
            check(fake.log.filter { $0 == "conversations.replies" }.count == (mode == "timeout" ? 4 : 1), "Only bounded thread reads")
            check(fake.replyLog.allSatisfy { $0 == "CCOW:800.0" }, "Only target thread read")
            check(fake.deleted == (["ok","timeout"].contains(mode) ? ["900.000001"] : []), "Only own recent exact sent command deleted")
            if ["delete-permission","delete-channel"].contains(mode) { check(bridge.current.status == .connected && bridge.current.problems.isEmpty, "Delete failure is silent") }
            if mode == "ok" {
                check(bridge.current.threads["CCOW"]?.first?.replyCount == 1, "Deleted command leaves only the actual bot reply count")
            }
            let count = fake.log.count
            _ = bridge.observePage(now: now.addingTimeInterval(5))
            check(fake.log.count == count, "Finished jobs do not poll")
            if mode == "rate" {
                // Slack refused reading the thread: that reading waits out its Retry-After, and only that.
                _ = bridge.sync(SlackBridge.Request(active: "CCOW", open: true), now: now.addingTimeInterval(6))
                check(!fake.log[count...].contains("conversations.replies") && bridge.current.status == .failed(SlackAPI.message(.rateLimited(60))),
                      "Retry-After of a thread reading is respected and said: \(fake.log[count...]) \(bridge.current.status)")
            }
            if mode == "delete-rate" {
                check(!bridge.beginPage(room: "CCOW", thread: "800.0", bot: "UCOWBOT", command: "쪽: 3", now: now.addingTimeInterval(6)), "Retry-After blocks sends too")
                _ = bridge.sync(SlackBridge.Request(active: "CCOW", open: true), now: now.addingTimeInterval(6))
                check(fake.log.count == count, "Retry-After respected without deletion retry")
            }
        }
    }
    }
    /// Slack refuses one method for pace: that method alone waits, from when Slack answered, and nothing held back is lost.
    static func methodLimits() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let limitNotice = SlackBridge.Status.failed(SlackAPI.message(.rateLimited(0)))
        // A thread the user just wrote in is watched, so its replies are read on every turn.
        func room(_ fake: FakeSlack) {
            let root: [String: Any] = ["ts": "999990.000001", "user": "UME", "text": "질문", "reply_count": 1, "latest_reply": "999995.000001"]
            fake.history["CCOW"] = [root]
            fake.replies["CCOW:999990.000001"] = [root, ["ts": "999995.000001", "thread_ts": "999990.000001", "user": "UCOWBOT", "text": "생각 중"]]
            fake.history["CTRUTH"] = [["ts": "999000.000001", "user": "UGUEST", "text": "진실"]]
            fake.history["DJARVIS"] = [["ts": "998000.000001", "user": "UME", "text": "예전", "reply_count": 1, "thread_ts": "998000.000001", "latest_reply": "999100.000001"]]
            fake.replies["DJARVIS:998000.000001"] = [["ts": "998000.000001", "user": "UME", "text": "예전"], ["ts": "999100.000001", "thread_ts": "998000.000001", "user": "UJARVIS", "text": "기록할 답"]]
        }
        var request = SlackBridge.Request(active: "CCOW", open: true, watch: ["CCOW", "CTRUTH"])

        // Listings refused: thread readings go on, every listing waits, the notice stays, and listings come back after the wait.
        let fake = FakeSlack(); room(fake)
        let bridge = SlackBridge(api: fake.api)
        _ = bridge.sync(request, now: t0)
        check(bridge.current.status == .connected && Set(fake.historyLog) == ["CCOW", "CTRUTH", "DJARVIS"], "the rooms are read first: \(fake.historyLog)")
        fake.limited["conversations.history"] = 10
        request.scan = ["DJARVIS": 999_000]
        let refusedAt = t0.addingTimeInterval(4)
        _ = bridge.sync(request, now: refusedAt)
        check(fake.historyLog.count == 4 && bridge.calls.filter { $0 == "conversations.history" }.count == 1, "one refused listing, and no other listing in the same round: \(bridge.calls)")
        check(bridge.current.status == limitNotice && bridge.current.threads["CCOW"]?.first?.replies.count == 1, "the wait is said and what was read stays: \(bridge.current.status)")
        check(bridge.diagnostics(room: "CCOW").contains("history_wait=") && !bridge.diagnostics(room: "CCOW").contains("history_wait=0 "), "the wait is written down")
        fake.limited = [:]
        let listed = fake.historyLog.count, read = fake.replyLog.count
        for step in 1...19 { _ = bridge.sync(request, now: refusedAt.addingTimeInterval(Double(step) * 0.5)) }
        check(fake.historyLog.count == listed, "no listing of any room, nor the scan's page, before the wait is over: \(fake.historyLog[listed...])")
        check(fake.replyLog.count > read, "while thread readings go on: \(fake.replyLog.count - read)")
        check(bridge.current.status == limitNotice, "and the other readings do not clear the notice while the wait lasts")
        check(bridge.takeScanned().through.isEmpty, "the scan held back is not finished")
        _ = bridge.sync(request, now: refusedAt.addingTimeInterval(10.1))
        check(fake.historyLog.count > listed && fake.historyLog[listed] == "CCOW", "after the wait the room on screen is listed first: \(fake.historyLog[listed...])")
        check(bridge.current.status == .connected, "and the notice goes once the wait is over: \(bridge.current.status)")
        for step in 1...40 { _ = bridge.sync(request, now: refusedAt.addingTimeInterval(10.1 + Double(step))) }
        let scanned = bridge.takeScanned()
        check(scanned.through["DJARVIS"] != nil && scanned.messages["DJARVIS"]?.map(\.body) == ["기록할 답"], "the scan held back finishes later with what it was to find: \(scanned)")

        // A slow answer: the wait counts from when the refusal arrived, not from when the round began.
        var up = 100.0
        let slow = FakeSlack(); room(slow)
        let late = SlackBridge(api: slow.api, uptime: { up })
        request.scan = [:]
        _ = late.sync(request, now: t0)
        slow.limited["conversations.history"] = 10
        slow.answering = { up += 8 }
        _ = late.sync(request, now: refusedAt)
        slow.answering = nil; slow.limited = [:]
        let slowListed = slow.historyLog.count
        for at in [10.0, 12, 15, 17.9] { _ = late.sync(request, now: refusedAt.addingTimeInterval(at)) }
        check(slow.historyLog.count == slowListed, "nothing is listed until ten seconds after the refusal arrived: \(slow.historyLog[slowListed...])")
        _ = late.sync(request, now: refusedAt.addingTimeInterval(18.1))
        check(slow.historyLog.count > slowListed, "and listings come back then")

        // Thread readings refused: listings go on, and the threads held back are read later, not counted as read.
        let threads = FakeSlack(); room(threads)
        let held = SlackBridge(api: threads.api)
        _ = held.sync(request, now: t0)
        threads.limited["conversations.replies"] = 30
        threads.history["CCOW"]?[0]["reply_count"] = 2; threads.history["CCOW"]?[0]["latest_reply"] = "1000003.000001"
        threads.replies["CCOW:999990.000001"]?.append(["ts": "1000003.000001", "thread_ts": "999990.000001", "user": "UCOWBOT", "text": "답이 왔어"])
        _ = held.sync(request, now: t0.addingTimeInterval(4))
        threads.limited = [:]
        let threadReads = threads.replyLog.count, listings = threads.historyLog.count
        for step in 1...25 { _ = held.sync(request, now: t0.addingTimeInterval(4 + Double(step))) }
        check(threads.replyLog.count == threadReads && threads.historyLog.count > listings, "listings go on while thread readings wait: \(threads.replyLog.count - threadReads) \(threads.historyLog.count - listings)")
        check(held.current.threads["CCOW"]?.first?.replies.count == 1 && held.current.status == limitNotice, "the thread keeps what it had while it waits")
        _ = held.sync(request, now: t0.addingTimeInterval(34.5))
        check(held.current.threads["CCOW"]?.first?.replies.map(\.body).contains("답이 왔어") == true, "the thread held back is read after the wait: \(String(describing: held.current.threads["CCOW"]?.first?.replies.map(\.body)))")
        // A deletion reads its thread first: that reading waits with the others, and the deletion is kept, not dropped.
        threads.limited["conversations.replies"] = 10
        held.delete(room: "CCOW", ts: "999990.000001")
        _ = held.sync(request, now: t0.addingTimeInterval(40))
        threads.limited = [:]
        let beforeDelete = threads.replyLog.count
        for step in 1...9 { _ = held.sync(request, now: t0.addingTimeInterval(40 + Double(step))) }
        check(threads.replyLog.count == beforeDelete && threads.deleted.isEmpty && held.current.removing["slack:CCOW:999990.000001"] != nil, "a deletion waits with the thread readings, and is not dropped")
        for step in 1...10 { _ = held.sync(request, now: t0.addingTimeInterval(50.5 + Double(step) * 1.5)) }
        check(threads.deleted.contains("999990.000001"), "and so is the deletion that waited: \(threads.deleted)")

        // Many rooms never read: the listings are spread over the passes, not asked for at once.
        let many = FakeSlack()
        many.nextPage = (1...14).map { ["id": "CMANY\($0)", "name": "방\($0)"] }
        let rooms = ["CCOW", "CTRUTH", "DJARVIS"] + (1...14).map { "CMANY\($0)" }
        for id in rooms { many.history[id] = [["ts": "100.000001", "user": "UGUEST", "text": id]] }
        let spread = SlackBridge(api: many.api)
        let wide = SlackBridge.Request(active: "CCOW", open: true, watch: rooms, scan: Dictionary(uniqueKeysWithValues: rooms.map { ($0, 0) }))
        var perPass: [Int] = []
        for step in 0..<40 {
            let before = many.historyLog.count
            _ = spread.sync(wide, now: t0.addingTimeInterval(Double(step) * 0.75))
            perPass.append(many.historyLog.count - before)
        }
        check(perPass.max() ?? 0 <= Int(SlackBridge.gated["conversations.history"]?.burst ?? 0) && perPass.dropFirst(3).allSatisfy { $0 <= 1 },
              "a few listings at once at most, then one at a time: \(perPass)")
        check(Set(many.historyLog).isSuperset(of: rooms), "and every room is read all the same: \(Set(rooms).subtracting(many.historyLog))")
    }

    /// A thread too long for one page is gathered a page at a time across passes, and nothing is deleted until all of it is in.
    static func longDeletions() {
        let t0 = Date(timeIntervalSince1970: 2_000_000), id = "slack:CCOW:1000.000000"
        func stamp(_ n: Int) -> String { String(format: "%d.%06d", 1000 + n / 1_000_000, n % 1_000_000) }
        // `count` pages of `size`; the first message is the thread's own, every fifth reply is someone else's, and each page repeats the last of the one before.
        func thread(_ fake: FakeSlack, pages count: Int, size: Int) -> [String] {
            var all: [String] = [], pages: [[[String: Any]]] = []
            for page in 0..<count {
                var lines: [[String: Any]] = page > 0 ? [pages[page - 1].last!] : []
                for i in 0..<(size - lines.count) {
                    let n = page * size + i
                    lines.append(["ts": stamp(n), "thread_ts": stamp(0), "user": n > 0 && n % 5 == 0 ? "UGUEST" : "UME", "text": "합성 \(n)"])
                    all.append(stamp(n))
                }
                pages.append(lines)
            }
            fake.replyPages["CCOW:" + stamp(0)] = pages
            return all
        }
        let request = SlackBridge.Request()

        // Seven pages of two hundred: more than can be read at once, so the rest come one a pass, each from where the last ended.
        let big = FakeSlack(), all = thread(big, pages: 7, size: 200)
        let bigBridge = SlackBridge(api: big.api)
        _ = bigBridge.sync(request, now: t0)
        bigBridge.delete(room: "CCOW", ts: stamp(0))
        var step = 0.0
        while bigBridge.current.removing[id]?.total == 0, step < 60 {
            step += 0.75
            _ = bigBridge.sync(request, now: t0.addingTimeInterval(step))
            check(big.deleted.isEmpty, "nothing is deleted before every page is read: \(big.pageLog)")
        }
        check(big.pageLog == (0..<7).map(String.init), "each page is read once, in order: \(big.pageLog)")
        check(bigBridge.current.removing[id]?.total == all.count, "every message is to go, each once: \(String(describing: bigBridge.current.removing[id])) \(all.count)")
        for _ in 0..<3 { step += 1.4; _ = bigBridge.sync(request, now: t0.addingTimeInterval(step)) }
        let newestOther = all.dropFirst().filter { Int($0.split(separator: ".")[1])! % 5 == 0 }.sorted { Double($0)! > Double($1)! }
        check(big.deleted == Array(newestOther.prefix(3)), "others' messages go first, newest first: \(big.deleted)")

        // Refused after the first page: the wait is kept, and the reading goes on from the second page, never the first.
        let refused = FakeSlack(), small = thread(refused, pages: 9, size: 2)
        var once = true
        let api = SlackAPI(transport: { method, parameters in
            if method == "conversations.replies", parameters["cursor"] == "1", once { once = false; refused.pageLog.append("1:refused"); return .failure(.rateLimited(5)) }
            return refused.transport(method, parameters)
        })
        let refusedBridge = SlackBridge(api: api)
        _ = refusedBridge.sync(request, now: t0)
        refusedBridge.delete(room: "CCOW", ts: stamp(0))
        _ = refusedBridge.sync(request, now: t0.addingTimeInterval(1))
        check(refused.pageLog == ["0", "1:refused"], "the second page is refused: \(refused.pageLog)")
        for at in [2.0, 4, 5.9] { _ = refusedBridge.sync(request, now: t0.addingTimeInterval(at)) }
        check(refused.pageLog.count == 2 && refused.deleted.isEmpty && refusedBridge.current.removing[id] != nil, "nothing is asked or deleted during the wait: \(refused.pageLog)")
        var at = 6.1
        while refusedBridge.current.removing[id] != nil, at < 120 { _ = refusedBridge.sync(request, now: t0.addingTimeInterval(at)); at += 1.4 }
        check(refused.pageLog == ["0", "1:refused"] + (1..<9).map(String.init), "after the wait it goes on from the refused page, a page at a time: \(refused.pageLog)")
        check(refusedBridge.current.removing[id] == nil && Set(refused.deleted) == Set(small) && refused.deleted.count == small.count && refused.deleted.last == stamp(0),
              "then the whole thread goes, each message once and the first message last: \(refused.deleted)")

        // Longer than the pages read: nothing is deleted, the first message least of all.
        let long = FakeSlack(); _ = thread(long, pages: SlackBridge.deletePages + 1, size: 2)
        let longBridge = SlackBridge(api: long.api)
        _ = longBridge.sync(request, now: t0)
        longBridge.delete(room: "CCOW", ts: stamp(0))
        var removed: [String: String?] = [:]
        for step in 1...40 { removed.merge(longBridge.sync(request, now: t0.addingTimeInterval(Double(step) * 1.4)).removed) { $1 } }
        check(long.pageLog == (0..<SlackBridge.deletePages).map(String.init) && long.deleted.isEmpty && longBridge.current.removing[id] == nil,
              "a thread past the last page is left whole: \(long.pageLog) \(long.deleted)")
        check(removed[id] == .some("스레드가 너무 길어 삭제를 멈췄어요. 지운 글은 없어요."), "and the user is told why: \(String(describing: removed[id]))")
    }

    static func pageRefresh() {
        var counts: [[String]] = []
        for edited in [false, true] {
            let fake = FakeSlack(), root: [String: Any] = ["ts": "999.0", "user": "UME", "text": "쪽: 3", "reply_count": 1, "latest_reply": "999.1"]
            var answer: [String: Any] = ["ts": "999.1", "thread_ts": "999.0", "user": "UCOWBOT", "text": "1/3쪽 · 총 25건"]
            fake.history["CCOW"] = [root]; fake.replies["CCOW:999.0"] = [root, answer]
            let bridge = SlackBridge(api: fake.api), request = SlackBridge.Request(active: "CCOW", open: true)
            _ = bridge.sync(request, now: Date(timeIntervalSince1970: 1000))
            if edited { answer["text"] = "3/3쪽 · 총 25건"; fake.replies["CCOW:999.0"] = [root, answer] }
            let result = bridge.sync(request, now: Date(timeIntervalSince1970: 1002))
            counts.append(bridge.calls)
            check(result.threads["CCOW"]?.first?.replies.first?.body == (edited ? "3/3쪽 · 총 25건" : "1/3쪽 · 총 25건"), "Same-ts page edit refreshed within existing live interval")
        }
        check(counts[0] == counts[1], "Edited page uses exactly baseline polling calls")
    }
    static func readSync() {
        let fake = FakeSlack(), room = "CCOW", ts = "100.000001", reply = "120.000009"
        let root: [String: Any] = ["ts": ts, "text": "root", "reply_count": 1, "latest_reply": reply]
        let answer: [String: Any] = ["ts": reply, "thread_ts": ts, "text": "answer"]
        fake.history[room] = [root]; fake.replies[room + ":" + ts] = [root, answer]
        let bridge = SlackBridge(api: fake.api), now = Date(timeIntervalSince1970: 1000)
        var request = SlackBridge.Request(active: room, open: true)
        request.readRooms = [room]; request.readThreads = [room + ":" + ts]
        fake.roomReads[room] = "150.000000"
        var snap = bridge.sync(request, now: now)
        let thread = snap.threads[room]!.first!
        check(SlackUnread.count([thread], lastRead: 0) == 2, "legacy unread default stays the same")
        check(SlackUnread.count([thread], lastRead: 0, roomRead: 150) == 1, "room receipt leaves thread replies unread")
        var broadcast = thread; broadcast.replies[0].slackBroadcast = true
        check(SlackUnread.count([broadcast], lastRead: 0, roomRead: 150) == 0, "channel receipt includes broadcasts")
        check(SlackUnread.count([thread], lastRead: 0, threadRead: [thread.id: 150]) == 1, "thread receipt does not read the root")
        check(!SlackUnread.read(thread, roomRead: 150, threadRead: [thread.id: 110]), "subscribed thread needs its own receipt")
        var parent = root; parent["last_read"] = reply
        fake.replies[room + ":" + ts] = [parent, answer]
        snap = bridge.sync(request, now: now.addingTimeInterval(20))
        check(snap.threadRead[thread.id] == Double(reply), "unchanged reply stamp still refreshes last_read")
        check(SlackUnread.count([thread], lastRead: 0, roomRead: 150, threadRead: snap.threadRead) == 0, "both receipts clear unread")
        check(SlackUnread.read(thread, roomRead: 0, threadRead: snap.threadRead), "full thread receipt quiets bell")
        check(!SlackNotice.items([thread], now: now).isEmpty, "unread fixture has an alert")
        check(SlackNotice.items([thread], now: now, dismissed: [thread.id: thread.latest], confirmed: []).isEmpty, "read thread leaves alert list")
        request.writesRead = true
        _ = bridge.sync(request, now: now.addingTimeInterval(21))
        check(fake.readMarks.isEmpty, "remote receipts never echo into writes")

        var subscribed = root; subscribed["last_read"] = "0"
        let writer = FakeSlack(); writer.history[room] = [root]; writer.replies[room + ":" + ts] = [subscribed, answer]
        let writing = SlackBridge(api: writer.api)
        var local = SlackBridge.Request(active: room, open: true)
        local.localRead = [room: 200]; local.localThreads = [room + ":" + ts: 200]
        _ = writing.sync(local, now: now)
        check(writer.readMarks.isEmpty, "smoke requests cannot write receipts")
        local.writesRead = true
        _ = writing.sync(local, now: now.addingTimeInterval(1))
        check(writer.readMarks.count == 2 && writer.readMarks.first { $0.0 == "conversations.mark" }?.1["ts"] == ts, "writes use original channel timestamp")
        check(writer.readMarks.first { $0.0 == "subscriptions.thread.mark" }?.1["ts"] == reply, "thread write uses original reply timestamp")
        _ = writing.sync(local, now: now.addingTimeInterval(2))
        check(writer.readMarks.count == 2, "repeated local read writes once")
        writer.history[room]!.append(["ts": "130.000007", "text": "new"])
        _ = writing.sync(local, now: now.addingTimeInterval(4))
        check(writer.readMarks.count == 2, "new receipts coalesce for five seconds")
        _ = writing.sync(local, now: now.addingTimeInterval(6))
        check(writer.readMarks.count == 3 && writer.readMarks.last?.1["ts"] == "130.000007", "latest pending channel receipt flushes")
        _ = writing.sync(local, now: now.addingTimeInterval(12))
        check(writer.readMarks.count == 3, "same timestamp never sent twice")

        let denied = FakeSlack(); denied.history[room] = [root]; denied.replies[room + ":" + ts] = [subscribed, answer]
        denied.writeFailures = ["conversations.mark": .api("missing_scope:channels:write"), "subscriptions.thread.mark": .api("unknown_method")]
        let refusing = SlackBridge(api: denied.api)
        snap = refusing.sync(local, now: now)
        check(snap.problems.isEmpty && snap.status == .connected, "write denial never changes room health")
        let historyCalls = denied.log.filter { $0 == "conversations.history" }.count
        _ = refusing.sync(local, now: now.addingTimeInterval(6))
        check(denied.readMarks.count == 2, "API failure disables only each write feature for this connection")
        check(denied.log.filter { $0 == "conversations.history" }.count > historyCalls, "denied writes do not rest room reads")
        check(refusing.diagnostics(room: room).contains("unknown_method"), "diagnostics retain thread error code")

        let limited = FakeSlack(); limited.history[room] = [root]; limited.replies[room + ":" + ts] = [subscribed, answer]
        limited.writeFailures["conversations.mark"] = .rateLimited(30)
        let retry = SlackBridge(api: limited.api)
        snap = retry.sync(local, now: now)
        check(snap.status == .connected, "write rate limit does not pause reading")
        limited.writeFailures = [:]
        _ = retry.sync(local, now: now.addingTimeInterval(10))
        check(limited.readMarks.filter { $0.0 == "conversations.mark" }.count == 1, "write respects Retry-After")
        _ = retry.sync(local, now: now.addingTimeInterval(30))
        check(limited.readMarks.filter { $0.0 == "conversations.mark" }.count == 2, "write resumes after Retry-After")
        let polling = FakeSlack(), polls = SlackBridge(api: polling.api)
        polling.nextPage = (1...7).map { ["id": "C" + String($0), "name": "room"] }
        polling.history[room] = [root]
        var pollingRequest = SlackBridge.Request(active: room, open: true)
        pollingRequest.readRooms = Set(["CCOW", "CTRUTH", "DJARVIS"] + (1...7).map { "C" + String($0) })
        pollingRequest.localRead = [room: 200]; pollingRequest.writesRead = true
        _ = polls.sync(pollingRequest, now: now)
        check(polling.infoRooms == [room], "pending room write gets the first global receipt slot")
        for second in 1..<5 { _ = polls.sync(pollingRequest, now: now.addingTimeInterval(Double(second))) }
        check(polling.infoRooms.count == 1, "global receipt throttle waits five seconds")
        _ = polls.sync(pollingRequest, now: now.addingTimeInterval(5))
        check(polling.infoRooms.count == 2 && polling.infoRooms.last != room, "receipt polling rotates after five seconds")
        for second in 6..<60 { _ = polls.sync(pollingRequest, now: now.addingTimeInterval(Double(second))) }
        check(polling.infoRooms.count == 12, "ten eligible rooms use at most twelve info calls in sixty seconds")
        let single = FakeSlack(), singleBridge = SlackBridge(api: single.api)
        var singleRequest = SlackBridge.Request(); singleRequest.readRooms = [room]
        for second in 0..<10 { _ = singleBridge.sync(singleRequest, now: now.addingTimeInterval(Double(second))) }
        check(single.infoRooms.count == 1, "one room still waits ten seconds")
        _ = singleBridge.sync(singleRequest, now: now.addingTimeInterval(10))
        check(single.infoRooms.count == 2, "one room resumes at ten seconds")
        let finishedInfo = writer.infoRooms.count
        _ = writing.sync(local, now: now.addingTimeInterval(30))
        check(writer.infoRooms.count == finishedInfo, "completed local room read does not keep polling")
        writer.history[room]!.append(["ts": "150", "text": "newer"])
        _ = writing.sync(local, now: now.addingTimeInterval(40))
        check(writer.infoRooms.count == finishedInfo + 1, "new pending flow message requests a fresh room receipt")

        let background = FakeSlack(), refreshing = SlackBridge(api: background.api)
        var backgroundRequest = SlackBridge.Request(active: room, open: true)
        for index in 1...8 {
            let stamp = String(index), latest = String(index + 10)
            let parent: [String: Any] = ["ts": stamp, "text": "root", "reply_count": 1, "latest_reply": latest]
            background.history[room, default: []].append(parent)
            background.replies[room + ":" + stamp] = [parent, ["ts": latest, "thread_ts": stamp, "text": "reply"]]
        }
        _ = refreshing.sync(backgroundRequest, now: now)
        // The room's threads are read a few at a time, so they are all in after a few seconds.
        for second in 1..<20 { _ = refreshing.sync(backgroundRequest, now: now.addingTimeInterval(Double(second))) }
        check(Set(background.replyLog).count == 8, "every thread of the opened room is read: \(background.replyLog)")
        let before = background.replyLog.count
        backgroundRequest.readThreads = Set((1...8).map { room + ":" + String($0) })
        for second in 21..<81 { _ = refreshing.sync(backgroundRequest, now: now.addingTimeInterval(Double(second))) }
        check(background.replyLog.count - before == 4, "unchanged thread refreshes use at most four calls per minute")
        let refreshed = Array(background.replyLog.suffix(4))
        check(Set(refreshed).count == 4, "receipt refreshes rotate waiting threads")
        let readBefore = fake.replyLog.count
        _ = bridge.sync(request, now: now.addingTimeInterval(39))
        check(fake.replyLog.count == readBefore, "same thread receipt waits twenty seconds")
        _ = bridge.sync(request, now: now.addingTimeInterval(40))
        check(fake.replyLog.count == readBefore + 1, "same thread receipt resumes at twenty seconds")

        check(!SlackUnread.read(thread, roomRead: 200, threadRead: [:]), "unknown subscription never uses room cursor")
        check(SlackUnread.read(thread, roomRead: 200, threadRead: [:], threadUnfollowed: [thread.id]), "confirmed unfollowed thread uses room cursor")
        var noReplies = thread; noReplies.replyCount = 0
        check(SlackUnread.read(noReplies, roomRead: 200, threadRead: [:]), "root-only thread uses room cursor")
        var silent = thread; silent.id = "silent"; silent.root.fromUser = true
        let notices = SlackNotice.items([thread, silent], now: now)
        let quiet = SlackUnread.quiet([thread, silent], notices: notices, roomRead: [room: 200], threadRead: [thread.id: 200, silent.id: 200], threadUnfollowed: [], remoteQuiet: [:])
        check(quiet.map(\.id) == [thread.id], "only an existing ringing bell is dismissed, never a silent thread")
        check(SlackUnread.quiet([thread], notices: notices, roomRead: [room: 200], threadRead: [thread.id: 200], threadUnfollowed: [], remoteQuiet: [thread.id: thread.latest]).isEmpty, "reopened bell stays open")
        check(snap.threadUnfollowed.isEmpty, "subscribed receipt is not unfollowed")
        let unfollowed = FakeSlack(); unfollowed.history[room] = [root]; unfollowed.replies[room + ":" + ts] = [root, answer]
        let unfollowBridge = SlackBridge(api: unfollowed.api)
        let unfollowSnap = unfollowBridge.sync(local, now: now)
        check(unfollowSnap.threadUnfollowed.contains(thread.id) && unfollowed.readMarks.allSatisfy { $0.0 != "subscriptions.thread.mark" }, "unfollowed thread is recorded and never written")
        unfollowed.replies[room + ":" + ts] = [subscribed, answer]
        var followingRequest = local; followingRequest.readThreads = [room + ":" + ts]
        let followedSnap = unfollowBridge.sync(followingRequest, now: now.addingTimeInterval(20))
        check(!followedSnap.threadUnfollowed.contains(thread.id) && followedSnap.threadRead[thread.id] == Double(reply), "later subscription replaces unfollowed state and write advances snapshot")

        let many = FakeSlack(), manyBridge = SlackBridge(api: many.api)
        var manyRequest = SlackBridge.Request(); manyRequest.writesRead = true
        for index in 1...30 { manyRequest.localThreads[room + ":" + String(index)] = 200 }
        _ = manyBridge.sync(manyRequest, now: now)
        check(many.readMarks.isEmpty, "thirty unknown thread cursors cause no blind writes")
        for index in 1...30 {
            let stamp = String(index)
            many.replies[room + ":" + stamp] = [["ts": stamp, "text": "root", "last_read": "0"], ["ts": "100", "thread_ts": stamp, "text": "reply"]]
        }
        for second in 1...4 {
            let before = many.readMarks.count
            _ = manyBridge.sync(manyRequest, now: now.addingTimeInterval(Double(second)))
            check(many.readMarks.count - before <= 2, "combined writes stay within two per pass")
        }
        check(!many.readMarks.isEmpty && many.replyLog.count <= 4, "unknown local threads learn receipts within refresh budget before writing")

        let behind = FakeSlack(); behind.history[room] = [root]; behind.roomReads[room] = "300"
        behind.infoFailure = .network("offline")
        let behindBridge = SlackBridge(api: behind.api)
        _ = behindBridge.sync(local, now: now)
        check(behind.readMarks.isEmpty && behind.log.contains("conversations.info"), "unknown room cursor is queried without writing")
        behind.infoFailure = nil
        _ = behindBridge.sync(local, now: now.addingTimeInterval(10))
        check(behind.readMarks.isEmpty, "remote cursor ahead of local is never moved backwards")
        behind.history[room]!.append(["ts": "400", "text": "later"])
        var later = local; later.localRead[room] = 500
        behind.infoFailure = .rateLimited(100)
        _ = behindBridge.sync(later, now: now.addingTimeInterval(41))
        check(behind.readMarks.isEmpty, "stale room cursor cannot authorize a write")
        let infoCount = behind.log.filter { $0 == "conversations.info" }.count
        let histories = behind.log.filter { $0 == "conversations.history" }.count
        let rateSnap = behindBridge.sync(later, now: now.addingTimeInterval(60))
        check(behind.log.filter { $0 == "conversations.info" }.count == infoCount && behind.log.filter { $0 == "conversations.history" }.count > histories && rateSnap.status == .connected, "info Retry-After pauses only receipt polling")
        behind.infoFailure = nil
        _ = behindBridge.sync(later, now: now.addingTimeInterval(141))
        check(behind.readMarks.first?.1["ts"] == "400", "fresh info allows forward write after Retry-After")

        let roomErrors = FakeSlack(); roomErrors.history[room] = [root]; roomErrors.history["CTRUTH"] = [root]
        roomErrors.keyWriteFailures[room] = .api("not_in_channel")
        let roomErrorBridge = SlackBridge(api: roomErrors.api)
        var roomWrites = SlackBridge.Request(active: room, open: true, watch: ["CTRUTH"])
        roomWrites.localRead = [room: 200, "CTRUTH": 200]; roomWrites.writesRead = true
        _ = roomErrorBridge.sync(roomWrites, now: now)
        let roomErrorSnap = roomErrorBridge.sync(roomWrites, now: now.addingTimeInterval(5))
        check(roomErrors.readMarks.count == 2 && roomErrorSnap.roomRead["CTRUTH"] == Double(ts) && roomErrorSnap.problems.isEmpty, "room-specific write error allows other room write")
        check(roomErrorBridge.diagnostics(room: room).contains("not_in_channel"), "other room success retains last write error in diagnostics")
        _ = roomErrorBridge.sync(roomWrites, now: now.addingTimeInterval(6))
        check(roomErrors.readMarks.count == 2, "failed room alone waits ten minutes")
        roomErrors.keyWriteFailures = [:]
        _ = roomErrorBridge.sync(roomWrites, now: now.addingTimeInterval(605))
        check(roomErrors.readMarks.count == 3, "room-specific write retries after ten minutes")
        denied.writeFailures = [:]
        _ = refusing.sync(local, now: now.addingTimeInterval(599))
        check(denied.readMarks.count == 2, "missing scope blocks all method writes before ten minutes")
        _ = refusing.sync(local, now: now.addingTimeInterval(600))
        check(denied.readMarks.count == 3 && denied.readMarks.last?.0 == "conversations.mark", "missing scope retries but unknown method stays disabled")

        // The handled thread stays queued even after switching rooms or folding the window.
        let handled = FakeSlack(); handled.history[room] = [root, ["ts": "180", "text": "unseen root"]]
        handled.replies[room + ":" + ts] = [subscribed, answer, ["ts": "190", "thread_ts": ts, "text": "arrived after handling"]]
        let handling = SlackBridge(api: handled.api)
        _ = handling.sync(SlackBridge.Request(active: room, open: true), now: now)
        var done = SlackBridge.Request(active: "CTRUTH", open: false)
        done.writesRead = true; done.localRead = [room: Double(ts)!]; done.localThreads = [room + ":" + ts: Double(reply)!]
        _ = handling.sync(done, now: now.addingTimeInterval(1))
        check(handled.readMarks.count == 2, "handled thread sends both receipts after room switch and window folding")
        check(handled.readMarks.first { $0.0 == "conversations.mark" }?.1 == ["channel": room, "ts": ts], "handled root does not advance to an unseen newer root")
        check(handled.readMarks.first { $0.0 == "subscriptions.thread.mark" }?.1 == ["channel": room, "thread_ts": ts, "ts": reply, "read": "1"], "handled reply does not include later unseen replies")
        check(handled.readMarks.allSatisfy { $0.1["channel"] == room }, "switching rooms does not mark the unseen destination")
        let last = handling.diagnostics(room: "CTRUTH").split(separator: "\n").first { $0.hasPrefix("read sync last:") } ?? ""
        check(last.contains("subscriptions.thread.mark") && last.contains("working") && last.contains("1001") && !last.contains(room) && !last.contains(ts), "last attempt diagnostic survives room switch without IDs or content")
        let tokenDenied = FakeSlack(); tokenDenied.history[room] = [root]; tokenDenied.replies[room + ":" + ts] = [subscribed, answer]
        tokenDenied.writeFailures["subscriptions.thread.mark"] = .api("not_allowed_token_type")
        let tokenBridge = SlackBridge(api: tokenDenied.api)
        _ = tokenBridge.sync(local, now: now)
        _ = tokenBridge.sync(local, now: now.addingTimeInterval(700))
        check(tokenDenied.readMarks.filter { $0.0 == "subscriptions.thread.mark" }.count == 1, "token type denial does not repeatedly call the unofficial method")
        check(tokenBridge.diagnostics(room: room).contains("thread_write=not_allowed_token_type"), "token type denial is diagnosed")

        let unkept = FakeSlack(); unkept.history[room] = [root]; unkept.replies[room + ":" + ts] = [subscribed, answer]
        let retention = SlackRetention(); retention.update([room], hidden: [])
        let unkeptBridge = SlackBridge(api: unkept.api, retention: retention)
        _ = unkeptBridge.sync(local, now: now)
        check(unkept.readMarks.count == 2, "unkept rooms still synchronize read receipts without caching content")
        let privateDiagnostic = unkeptBridge.diagnostics(room: room)
        check(privateDiagnostic.contains("read sync last:") && !privateDiagnostic.contains(room) && !privateDiagnostic.contains(ts), "unkept diagnostics contain only the method result and time")

        let selfRead = [thread.id: thread.latest]
        check(SlackUnread.quiet([thread], notices: notices, roomRead: [:], threadRead: selfRead, threadUnfollowed: [], remoteQuiet: [:], ownRead: selfRead).isEmpty, "own thread write never quiets its bell")
        check(SlackUnread.quiet([thread], notices: notices, roomRead: [:], threadRead: selfRead, threadUnfollowed: [], remoteQuiet: [:], ownRead: [thread.id: thread.latest - 1]).count == 1, "external read beyond own write quiets the bell")
        check(SlackUnread.quiet([noReplies], notices: notices, roomRead: [room: thread.latest], threadRead: [:], threadUnfollowed: [], remoteQuiet: [:], ownRead: [room: thread.latest]).isEmpty, "own room write leaves root-only bell alone")
        check(SlackUnread.quiet([thread], notices: notices, roomRead: [room: thread.latest], threadRead: [:], threadUnfollowed: [thread.id], remoteQuiet: [:], ownRead: [room: thread.latest]).isEmpty, "own room write leaves unfollowed thread bell alone")
        check(writing.current.ownRead[room] == 150 && writing.current.ownRead[thread.id] == Double(reply), "successful writes carry original room and thread keys in ownRead")
        check(refusing.current.ownRead[thread.id] == nil && refusing.current.ownRead[room] == Double(ts), "failed writes never populate ownRead; later success does")
        check(unfollowBridge.diagnostics(room: room).contains("unfollowed=0") && unfollowBridge.diagnostics(room: room).contains("room_read=known"), "diagnostics expose received room and subscription state")
        check(SlackBridge(api: FakeSlack().api).diagnostics(room: room).contains("room_read=unknown"), "unreceived room cursor is diagnosed as unknown")

        let old = Data(#"{"me":"U","users":{},"history":{"C":[{"ts":"1.000001","user":"U","name":"","text":"old","replyCount":0,"broadcast":false,"marks":[],"files":[]}]},"channelTimes":{},"extra":{},"replies":{}}"#.utf8)
        check((try? JSONDecoder().decode(SlackState.self, from: old))?.history["C"]?.first?.ts == "1.000001", "previous cache format still decodes")
    }
    static func retentionChecks() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-retention-test-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "ddots-retention-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["PRIVATE"], forKey: SlackRetention.key)
        let policy = SlackRetention()
        policy.update(Set(defaults.stringArray(forKey: SlackRetention.key) ?? []), hidden: ["HIDDEN"])
        var cache = SlackCache()
        cache.state.me = "UFAKE"
        for (room, marker) in [("PRIVATE", "PRIVATE-MARKER"), ("HIDDEN", "HIDDEN-MARKER"), ("PUBLIC", "PUBLIC-MARKER")] {
            let body = room == "PRIVATE" ? "선택: " + marker + ".md\n" + root.appendingPathComponent(marker + ".md").path
                + "\n경로 줘 · 열어줘 · 다운로드 · 수정 · 종결 — 글로 보내도 됩니다\n- 메모: PRIVATE-FIELD-VALUE\n저장했어요 — PRIVATE-RECEIPT.md\n올린 원본: 100.000001" : marker
            let line = SlackMessage(json: ["ts": "100.000001", "user": "UFAKE", "text": body])!
            cache.state.history[room] = [line]; cache.state.extra[room] = [line.ts: line]
            cache.state.replies[room] = [line.ts: [line]]; cache.readAt[room] = 100
            cache.rooms.append(SlackRoom(id: room, name: room))
        }
        let url = root.appendingPathComponent("cache.json")
        check(SlackCache.write(cache.fitted()!, to: url), "seed an existing synthetic cache")
        let fake = FakeSlack()
        let bridge = SlackBridge(api: fake.api, cache: url, retention: policy)
        bridge.removeUnkeptCache()
        let bytes = try! String(contentsOf: url, encoding: .utf8)
        check(!bytes.contains("PRIVATE-RECEIPT") && !bytes.contains("올린 원본:") && !bytes.contains("PRIVATE-FIELD-VALUE") && !bytes.contains("PRIVATE-MARKER") && !bytes.contains("HIDDEN-MARKER") && bytes.contains("PUBLIC-MARKER"), "purging removes private and hidden content, keeps other rooms")
        let restored = bridge.restore(characters: [])!
        check(restored.threads["PRIVATE"] == nil, "restart does not restore excluded content")
        check(policy.filtered(["PRIVATE": 1, "slack:PRIVATE:100": 2, "PUBLIC": 3]) == ["PUBLIC": 3], "read receipts for excluded rooms are not persisted")
        policy.update([], hidden: [])
        check(SlackCache.write(cache.fitted()!, to: url), "write ordinary cache after disabling")
        bridge.removeUnkeptCache()
        check((try! String(contentsOf: url, encoding: .utf8)).contains("PRIVATE-MARKER"), "turning the choice off restores ordinary retention")

        let live = FakeSlack()
        live.history["CCOW"] = [["ts": "100.000001", "text": "LIVE-PRIVATE", "user": "UME"]]
        live.history["CTRUTH"] = [["ts": "100.000002", "text": "LIVE-PUBLIC", "user": "UME"]]
        let livePolicy = SlackRetention(); livePolicy.update(["CCOW"], hidden: [])
        let liveURL = root.appendingPathComponent("live.json")
        let reader = SlackBridge(api: live.api, cache: liveURL, retention: livePolicy)
        var request = SlackBridge.Request(active: "CCOW", open: true)
        let now = Date()
        let view = reader.sync(request, now: now)
        request.active = "CTRUTH"
        _ = reader.sync(request, now: now.addingTimeInterval(4))
        reader.flush(now: now)
        let saved = try! String(contentsOf: liveURL, encoding: .utf8)
        check(!saved.contains("LIVE-PRIVATE") && saved.contains("LIVE-PUBLIC"), "normal periodic and final cache saves apply the exclusion")
        check(view.threads["CCOW"]?.first?.root.body == "LIVE-PRIVATE", "excluded messages remain visible in memory")

        let archive = DdotsArchive(root: root.appendingPathComponent("archive"), retention: policy)
        let names = ["fake": "가짜캐릭터"]
        let message = ChatMessage(id: "slack:PRIVATE:100.000001", fromUser: true, speaker: "", body: "ARCHIVE-PRIVATE", date: Date(timeIntervalSince1970: 100))
        let line = DdotsLine(message, profile: "fake", names: names)!
        try! archive.append([line], names: names)
        policy.update(["PRIVATE"], hidden: [])
        try! archive.removeUnkept()
        let recordBytes = try! String(contentsOf: archive.recordURL(name: names["fake"]!, month: DdotsArchive.month(message.date)), encoding: .utf8)
        check(!recordBytes.contains("ARCHIVE-PRIVATE"), "all old serialized record content is removed")
        try! archive.append([line], names: names)
        check(archive.read(month: DdotsArchive.month(message.date)).isEmpty, "old and queued archive lines are excluded")
        var legacy = line; legacy.room = nil
        policy.map(profiles: ["fake": "PRIVATE"], hub: nil)
        try! archive.append([legacy], names: names)
        check(archive.read(month: DdotsArchive.month(message.date)).isEmpty, "legacy records follow the room mapping")
        policy.update([], hidden: [])
        try! archive.append([line], names: names)
        check(archive.read(month: DdotsArchive.month(message.date)).count == 1, "disabling restores archive writes")

        let temporary = SlackTemporaryFiles(root: root.appendingPathComponent("private-temp"))
        let file = try! temporary.save(Data("FAKE-FILE".utf8), name: "가짜.pdf")
        check(file.path.hasPrefix(temporary.root.path + "/") && !file.path.contains("HermesWorkspace"), "private files stay in local temporary storage")
        let mode = (try! FileManager.default.attributesOfItem(atPath: temporary.root.path)[.posixPermissions] as! NSNumber).intValue
        check(mode == 0o700, "temporary storage is private")
        check((try! temporary.root.resourceValues(forKeys: [.isExcludedFromBackupKey])).isExcludedFromBackup == true, "temporary files excluded from backups")
        try! temporary.clear()
        check(!FileManager.default.fileExists(atPath: file.path), "temporary files cleared on shutdown and next start")

        closingChecks(root: root)
        pastedLeftovers(root: root)
    }

    /// Closing with a slow disk: the stand-in sleeps inside the real save and removal, longer than the limit.
    static func closingChecks(root: URL) {
        func spin(until done: () -> Bool, within seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        }
        final class Box: @unchecked Sendable { var answers: [Bool] = []; var beats = 0; var lateSave: Result<URL, Error>? }
        let original = root.appendingPathComponent("사용자 원본.pdf")
        try! Data("ORIGINAL".utf8).write(to: original)

        // A save under way: closing does not wait for its write, and the copy it finishes is taken away again.
        let files = SlackTemporaryFiles(root: root.appendingPathComponent("closing-temp"))
        let opened = try! files.save(Data("FAKE-FILE".utf8), name: "열린.pdf")
        let writing = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), saved = DispatchSemaphore(value: 0)
        let box = Box()
        files.stall = { step in if step == "write" { writing.signal(); release.wait() } }
        DispatchQueue.global().async { box.lateSave = Result { try files.save(Data("LATE".utf8), name: "늦은.pdf") }; saved.signal() }
        check(writing.wait(timeout: .now() + 2) == .success, "the slow save has begun before closing")
        var began = Date()
        files.close()
        check(Date().timeIntervalSince(began) < 0.05 && files.isClosed, "closing marks the files closed without waiting on the write under way")
        check((try? files.save(Data("NEW".utf8), name: "새.pdf")) == nil, "nothing new is saved once closing has begun")
        try! files.clear()
        check(!FileManager.default.fileExists(atPath: opened.path), "closing removes the copies already there")
        release.signal(); saved.wait()
        if case .success = box.lateSave! { check(false, "a save that finished after closing began reports a failure") }
        check(!FileManager.default.fileExists(atPath: files.root.path), "the late save takes its copy away and leaves no folder")

        // A removal slower than the limit: closing is answered once, at the limit, while the main loop keeps running.
        let slow = SlackTemporaryFiles(root: root.appendingPathComponent("slow-remove"))
        let left = try! slow.save(Data("FAKE-FILE".utf8), name: "남은.pdf")
        let removing = DispatchSemaphore(value: 0)
        slow.stall = { step in if step == "remove" { removing.signal(); Thread.sleep(forTimeInterval: 1.5) } }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in box.beats += 1 }
        RunLoop.main.add(timer, forMode: .common)
        began = Date()
        let run = ClosingRun(limit: 0.5) { late in box.answers.append(late) }
        slow.close()
        run.add(on: .global()) { try? slow.clear() }
        run.start()
        check(removing.wait(timeout: .now() + 1) == .success, "the slow removal is under way")
        spin(until: { !box.answers.isEmpty }, within: 3)
        let answeredAfter = Date().timeIntervalSince(began)
        check(box.answers == [true] && answeredAfter < 0.8, "closing is answered at its limit while a removal is still slow (\(answeredAfter)s)")
        // macOS may coalesce 50 ms timers; responsiveness does not require a particular tick count.
        check(box.beats > 0 && FileManager.default.fileExists(atPath: left.path), "the main loop handles events while removal is still waiting (beats: \(box.beats))")
        spin(until: { !FileManager.default.fileExists(atPath: left.path) }, within: 3)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        timer.invalidate()
        check(box.answers == [true], "closing is answered only once, even when the slow step ends later")

        // Work that finishes in time answers at once, not at the limit.
        box.answers = []
        began = Date()
        let quick = ClosingRun(limit: 2) { late in box.answers.append(late) }
        quick.add(on: .global()) {}
        quick.start()
        spin(until: { !box.answers.isEmpty }, within: 3)
        check(box.answers == [false] && Date().timeIntervalSince(began) < 0.5, "closing goes on as soon as its work is done")

        // Closing asked for from a block on the main queue, with the wait inside it as AppKit does: still answered.
        final class Nested: @unchecked Sendable { var answers: [Bool] = []; var seenInside: [Bool]? }
        let nested = Nested()
        DispatchQueue.main.async {
            let inside = ClosingRun(limit: 1) { late in nested.answers.append(late) }
            inside.add(on: .global()) {}
            inside.start()
            spin(until: { !nested.answers.isEmpty }, within: 3)
            nested.seenInside = nested.answers
        }
        spin(until: { nested.seenInside != nil }, within: 5)
        check(nested.seenInside == [false], "closing is answered while the main queue waits inside a block")

        // A copy left by an app that ended mid-save is cleared by the next start, which saves again; the user's own file stays.
        try! FileManager.default.createDirectory(at: files.root.appendingPathComponent("cut-short"), withIntermediateDirectories: true)
        let nextStart = SlackTemporaryFiles(root: files.root)
        try! nextStart.clear()
        check(!FileManager.default.fileExists(atPath: files.root.path), "the next start clears what an ended app left")
        check((try? nextStart.save(Data("FAKE-FILE".utf8), name: "다음.pdf")) != nil, "the next start saves private copies again")
        try! nextStart.clear()
        check(FileManager.default.fileExists(atPath: original.path), "the user's own file is never removed")
    }

    /// Pictures pasted in a run that ended before removing them are removed by the next start, and nothing else is.
    static func pastedLeftovers(root: URL) {
        let area = root.appendingPathComponent("pasted-area"), outside = root.appendingPathComponent("outside")
        let fm = FileManager.default
        let left = area.appendingPathComponent("run-" + UUID().uuidString)
        try! fm.createDirectory(at: left, withIntermediateDirectories: true); try! Data("PNG".utf8).write(to: left.appendingPathComponent("a.png"))
        for name in ["run-not-a-uuid", "other"] { try! fm.createDirectory(at: area.appendingPathComponent(name), withIntermediateDirectories: true) }
        try! Data("KEEP".utf8).write(to: area.appendingPathComponent("keep.txt"))
        try! fm.createDirectory(at: outside, withIntermediateDirectories: true); try! Data("USER".utf8).write(to: outside.appendingPathComponent("사용자.png"))
        let linked = area.appendingPathComponent("run-" + UUID().uuidString)
        try! fm.createSymbolicLink(at: linked, withDestinationURL: outside)
        check(ClipboardAttachments.runFolders(in: area).map(\.lastPathComponent) == [left.lastPathComponent], "only real run folders count as left over")

        final class Done: @unchecked Sendable { var removed: Int? }
        let done = Done()
        ClipboardAttachments.stall = { if $0 == "recover" { Thread.sleep(forTimeInterval: 0.5) } }
        defer { ClipboardAttachments.stall = nil }
        let next = ClipboardAttachments(area: area)
        next.recoverLeftovers { done.removed = $0 }
        // A picture pasted while the start is still removing gets a folder of its own, which is left alone.
        let board = NSPasteboard.withUniqueName()
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png)
        let fresh = next.read(board, available: 1)?.files.first
        check(fresh != nil && done.removed == nil, "a picture can be pasted while the start is still removing")
        let end = Date().addingTimeInterval(3)
        while done.removed == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(done.removed == 1 && !fm.fileExists(atPath: left.path), "the start removes the folder an ended run left")
        check(fm.fileExists(atPath: fresh!.path), "the picture pasted meanwhile stays")
        check(fm.fileExists(atPath: area.appendingPathComponent("keep.txt").path) && fm.fileExists(atPath: area.appendingPathComponent("other").path)
              && fm.fileExists(atPath: area.appendingPathComponent("run-not-a-uuid").path), "nothing else in the folder is touched")
        check(fm.fileExists(atPath: outside.appendingPathComponent("사용자.png").path), "a link to somewhere else is not followed")
        next.cleanup()
        check(!fm.fileExists(atPath: fresh!.path), "this run's own folder goes when it is done with")
    }

    static func hermesReplies() {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/hermes-reply-states.json")
        let fixtures = try! JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: [String: Any]]
        var store = SlackState()
        store.me = "UME"
        func thread(_ raw: [String: Any]) -> SlackThread {
            let root = store.chat(SlackMessage(json: raw)!, room: "CCOW", characters: [])
            return SlackThread(id: root.id, room: "CCOW", ts: "100.0", root: root, replies: [], replyCount: 0, loaded: true, latest: 100, latestFromUser: false)
        }
        var pet = SlackNoticeMemo()
        for location in ["attachment", "top"] {
            let asking = thread(fixtures["asking-" + location]!)
            let working = thread(fixtures["working-" + location]!)
            let closed = thread(fixtures["closed-" + location]!)
            for label in ["close", "complete"] {
                let answered = thread(fixtures["working-" + label + "-label-" + location]!)
                check(answered.root.hermesReplyState == .working && !SlackNotice.isSettled(answered)
                      && SlackNotice.state(answered)?.text == "처리 중" && SlackNotice.pendingApproval(answered) == nil,
                      "a completion word in the clicked label stays working: " + label + "-" + location)
            }
            check(SlackNotice.pendingApproval(asking) != nil && SlackNotice.items([asking]).first?.id.hasPrefix("question:") == true, "Hermes buttons count as a question: " + location)
            check(SlackNotice.replyLabels(asking) == ["진행해", "보류"] && SlackNotice.hermesAnswer(asking, label: "보류") == "보류" && SlackNotice.hermesAnswer(asking, label: "승인") == nil, "Hermes labels are the exact outgoing reply")
            check(pet.needsPetApproval([asking], rooms: ["CCOW"], confirmed: []), "asking waves the phone")
            check(SlackNotice.pendingApproval(working) == nil && SlackNotice.state(working)?.text == "처리 중" && SlackNotice.items([working]).isEmpty, "working clears question and bell: " + location)
            check(!pet.needsPetApproval([working], rooms: ["CCOW"], confirmed: []), "edited working state clears pet memo")
            check(SlackNotice.isSettled(closed) && SlackNotice.pendingApproval(closed) == nil && SlackNotice.items([closed]).isEmpty, "closed settles the thread: " + location)
            check(!pet.needsPetApproval([closed], rooms: ["CCOW"], confirmed: []), "closed does not wave")
            var later = asking
            var reply = closed.root; reply.id = "later"; reply.date = Date(timeIntervalSince1970: 101)
            later.replies = [reply]
            check(SlackNotice.isSettled(later) && SlackNotice.pendingApproval(later) == nil, "later Hermes status closes earlier question")
            reply.hermesReplyState = nil; reply.hermesButtons = []; reply.body = "새 초안 승인해줘"
            later = closed; later.replies = [reply]
            check(!SlackNotice.isSettled(later) && SlackNotice.pendingApproval(later)?.id == "later", "new ordinary request reopens a closed exchange")
            var retained = fixtures["working-" + location]!
            retained["blocks"] = (retained["blocks"] as! [[String: Any]]) + (fixtures["asking-top"]!["blocks"] as! [[String: Any]])
            check(SlackMessage(json: retained)?.hermesReplyState == .working, "status takes precedence over retained follow-up buttons")
        }
        let checklistBlock: [String: Any] = ["type": "actions", "block_id": "hermes_reply_checklist", "elements": [
            ["type": "checkboxes", "action_id": "hermes_reply_checklist_toggle", "options": ["전체", "노션", "일정", "메모"].map { ["value": $0, "text": ["type": "plain_text", "text": $0]] }],
            ["type": "button", "text": ["type": "plain_text", "text": "작성"], "value": "submit"]]]
        for attached in [false, true] {
            var raw: [String: Any] = ["ts": "100.0", "user": "UCOWBOT", "text": "업무 등록"]
            var revised = checklistBlock
            if attached { revised["block_id"] = "hermes_reply_checklist:revision2" }
            if attached { raw["attachments"] = [["color": "#E01E5A", "blocks": [revised]]] }
            else { raw["blocks"] = [revised] }
            let asking = thread(raw)
            check(asking.root.hermesReplyState == .asking && SlackNotice.pendingApproval(asking) != nil, "checklist is a pending question")
            check(SlackNotice.checklistLabels(asking) == ["전체", "노션", "일정", "메모"] && SlackNotice.replyLabels(asking).isEmpty, "parse checklist options separately from buttons")
            check(SlackNotice.checklistAnswer(asking, selected: ["일정", "노션"]) == "선택: 노션, 일정", "submit uses Slack option order")
            check(SlackNotice.checklistAnswer(asking, selected: ["전체", "일정"]) == "선택: 전체", "all option wins")
            check(SlackNotice.checklistAnswer(asking, selected: []) == nil && SlackNotice.checklistAnswer(asking, selected: ["forged"]) == nil, "empty and unknown selection cannot submit")
            var working = asking; working.root.hermesReplyState = .working
            check(SlackNotice.checklistLabels(working).isEmpty && SlackNotice.state(working)?.text == "처리 중", "working state removes checklist controls")
            working.root.hermesReplyState = .closed
            check(SlackNotice.isSettled(working) && SlackNotice.checklistAnswer(working, selected: ["전체"]) == nil, "closed checklist cannot submit")
        }
        for attached in [false, true] {
            let options = ["전체", "노션", "일정", "메모"]
            let selected: Set<String> = ["노션", "일정"]
            let toggles: [[String: Any]] = options.enumerated().map { index, label in
                var value: [String: Any] = ["type": "button", "action_id": "hermes_reply_checklist_toggle_" + String(index),
                    "value": label, "text": ["type": "plain_text", "text": (selected.contains(label) ? "✅ " : "☐ ") + label]]
                if selected.contains(label) { value["style"] = "primary" }
                return value
            }
            let blocks: [[String: Any]] = [
                ["type": "actions", "block_id": "hermes_reply_checklist:revision", "elements": toggles],
                ["type": "actions", "block_id": "hermes_reply_checklist:submit", "elements": [
                    ["type": "button", "action_id": "hermes_reply_checklist_submit", "value": "submit", "text": ["type": "plain_text", "text": "작성"]]]]]
            var raw: [String: Any] = ["ts": "100.0", "user": "UCOWBOT", "text": "업무 등록"]
            if attached { raw["attachments"] = [["color": "#E01E5A", "blocks": blocks]] } else { raw["blocks"] = blocks }
            let asking = thread(raw)
            check(SlackNotice.checklistLabels(asking) == options, "horizontal buttons retain plain label order without submit or checkbox glyphs")
            check(asking.root.hermesChecklistSelected == ["노션", "일정"], "primary button selection survives Slack redraw and cache conversion")
            check(SlackNotice.checklistAnswer(asking, selected: Set(asking.root.hermesChecklistSelected)) == "선택: 노션, 일정", "restored horizontal selection uses normal owner reply text")
            check(asking.root.hermesButtons.isEmpty && asking.root.hermesReplyState == .asking, "horizontal checklist remains an unanswered question, separate from ordinary reply buttons")
        }
        let labels = ["전체", "노션", "일정", "메모"]
        let toggle = SlackNotice.checklistToggle
        check(toggle(labels, [], "전체", true) == Set(labels), "master on selects every destination")
        check(toggle(labels, Set(labels), "전체", false).isEmpty, "master off clears every destination")
        check(toggle(labels, Set(labels), "일정", false) == ["노션", "메모"], "unchecking one destination clears master")
        check(toggle(labels, ["노션", "일정"], "메모", true) == Set(labels), "checking final destination checks master")
        check(toggle(["노션", "일정"], [], "노션", true) == ["노션"], "ordinary checklist remains independent")
        check(toggle(["노션", "전체", "메모"], [], "전체", true) == ["전체"], "only first-label master is special")
        check(toggle(labels, ["노션"], "forged", true) == ["노션"], "unknown toggles do not affect selection")
        let legacy = thread(["ts": "100.0", "user": "UCOWBOT", "text": "초안 승인 부탁해", "attachments": [["color": "#2EB67D", "text": "참고"]]])
        check(legacy.root.hermesReplyState == nil && SlackNotice.pendingApproval(legacy) != nil, "ordinary coloured approvals retain regex behavior")
        let old = SlackMessage(ts: "1", text: "old")
        let encoded = try! JSONEncoder().encode(old)
        check((try! JSONDecoder().decode(SlackMessage.self, from: encoded)).hermesReplyState == nil, "old cache without Hermes fields decodes")
        let fake = FakeSlack()
        var root = fixtures["asking-attachment"]!
        root["reply_count"] = 1; root["latest_reply"] = "101.0"
        fake.history["CCOW"] = [root]
        var reply = fixtures["asking-top"]!; reply["ts"] = "101.0"; reply["thread_ts"] = "100.0"
        fake.replies["CCOW:100.0"] = [root, reply]
        let bridge = SlackBridge(api: fake.api)
        let request = SlackBridge.Request(active: "CCOW", open: true, characters: [])
        _ = bridge.sync(request, now: Date(timeIntervalSince1970: 1000))
        check(bridge.watchedThreads("CCOW", now: Date(timeIntervalSince1970: 1001)).contains { $0.ts == "100.0" && $0.every == 60 }, "old Hermes threads are watched at bounded cadence")
        var finished = fixtures["closed-attachment"]!; finished["reply_count"] = 1; finished["latest_reply"] = "101.0"
        var done = fixtures["closed-top"]!; done["ts"] = "101.0"; done["thread_ts"] = "100.0"
        // History deliberately stays stale; replies must refresh both root and child.
        fake.replies["CCOW:100.0"] = [finished, done]
        let snapshot = bridge.sync(request, now: Date(timeIntervalSince1970: 1061))
        check(snapshot.threads["CCOW"]?.first?.root.hermesReplyState == .closed && snapshot.threads["CCOW"]?.first?.replies.first?.hermesReplyState == .closed, "chat.update without latest_reply change refreshes root and reply")
    }

    static func main() {
        hermesReplies()
        if CommandLine.arguments.contains("--hermes-replies-only") { print("PASS: Hermes states, labels, pet, legacy and chat.update refresh"); return }
        var memo = SlackThinkingMemo()
        let original = memo.value(ts: "1", text: "생각 중")
        check(memo.value(ts: "1", text: "생각 중") == original && memo.evaluations == 1, "unchanged status is evaluated once")
        check(memo.value(ts: "1", text: "완료한 답변") == SlackText.isThinking("완료한 답변") && memo.evaluations == 2, "edited status is reevaluated")
        var gate = SlackDiagnosticsGate()
        check(gate.shouldBuild(room: "synthetic", now: 0), "first diagnostics are immediate")
        check(!gate.shouldBuild(room: "synthetic", now: 0.75), "unchanged room avoids formatting every tick")
        check(gate.shouldBuild(room: "synthetic", now: 10), "time dependent diagnostics refresh")
        check(gate.shouldBuild(room: "other", now: 10.1), "room change refreshes diagnostics")
        agentInvitations()
        deletedAgents()
        retentionChecks()
        readSync()
        pageRefresh()
        fastPages()
        methodLimits()
        longDeletions()

        let faces = [("secret", "", "새우튀김"), ("SNS담당방", "sns-manager", "SNS담당"), ("업무비서방", "work-assistant", "업무비서"),
                     ("maintencance", "system-doctor", "진단담당"), ("maintenance", "system-doctor", "진단담당")]
        for (name, profile, character) in faces {
            let face = Ddots.representative(SlackRoom(id: "CFACE", name: name, direct: false))
            check(face?.profile == profile && face?.name == character, "the room shows its own character: \(name)")
            check(Ddots.representative(SlackRoom(id: "DFACE", name: name, direct: true)) == nil, "direct conversations keep their members: \(name)")
        }
        let maintenance = Ddots.representative(SlackRoom(id: ThreeTapCommand.channel, name: "renamed", direct: false))
        check(maintenance?.profile == "system-doctor" && maintenance?.name == "진단담당", "maintenance keeps its face after a rename")
        for room in [SlackRoom(id: "COTHER", name: "일반", direct: false),
                     SlackRoom(id: Ddots.room, name: "SNS담당방", direct: false),
                     SlackRoom(id: Ddots.stack, name: "업무비서방", direct: false),
                     SlackRoom(id: ThreeTapCommand.channel, name: "maintenance", direct: true)] {
            check(Ddots.representative(room) == nil, "other rooms and virtual tabs keep their existing faces: \(room.id)")
        }
        let characters = [ChatCharacter(id: "default", name: "위키담당"), ChatCharacter(id: "sns-manager", name: "SNS담당"), ChatCharacter(id: "personal-secretary", name: "개인비서")]

        // Text
        check(SlackText.display("<@UJARVIS> 봐줘 &gt; <https://example.com/a|문서> <https://example.org> <#C1|일반> <!here>", users: ["UJARVIS": "개인비서"])
              == "@개인비서 봐줘 > [문서](https://example.com/a) <https://example.org> #일반 @here", "mentions, links and entities become readable text")
        let address = "https://example.com/my_file_name/a*b*c?x=1&y=2"
        let shown = (try? AttributedString(markdown: ChatText.normalizedMarkdown(SlackText.display("자료야 <\(address.replacingOccurrences(of: "&", with: "&amp;"))> 봐줘", users: [:])), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString()
        check(shown.runs.compactMap(\.link).map(\.absoluteString) == [address] && String(shown.characters) == "자료야 \(address) 봐줘", "a received address stays whole and clickable, underscores and all: \(String(shown.characters))")
        check(SlackMention.outgoing("여기 봐 \(address)", members: []) == "여기 봐 " + address.replacingOccurrences(of: "&", with: "&amp;"), "a typed address is sent as it is, for Slack to link")
        check(SlackText.display(":white_check_mark: *답변 완료* 09:00~18:00 :unknown_code: 2 * 3 * 4", users: [:]) == "✅ **답변 완료** 09:00~18:00 :unknown_code: 2 * 3 * 4", "known emoji and bold are converted, the rest is kept")
        check(SlackText.display(":books: 위키 :floppy_disk: 백업 :stopwatch: 3분 :inbox_tray: 2 :outbox_tray: 1", users: [:]) == "📚 위키 💾 백업 ⏱️ 3분 📥 2 📤 1", "the signs the characters put on their reports are shown as emoji")
        check(SlackText.display(":blush: :woman-bowing: :birthday: :zap: :arrow_right_hook:", users: [:]) == "😊 🙇‍♀️ 🎂 ⚡️ ↪️", "emoji seen in customer messages are shown too")
        check(SlackText.mentions("<@U1> <@U2|이름> <https://a.b>") == ["U1", "U2"], "only user mentions are collected")
        check(SlackSpeakers.profile("SNS담당", characters: characters) == "sns-manager" && SlackSpeakers.profile("Personal Secretary", characters: characters) == "personal-secretary"
              && SlackSpeakers.profile("SNS담당 봇", characters: characters) == "sns-manager" && SlackSpeakers.profile("손님", characters: characters) == "", "bots are matched to characters by name")
        check(SlackMessage(json: ["ts": "1.0", "subtype": "channel_join", "text": "들어옴"]) == nil, "housekeeping lines are skipped")
        let withFiles = SlackMessage(json: ["ts": "1.0", "text": "", "files": [
            ["id": "F1", "name": "a.png", "mimetype": "image/png", "size": 2048, "url_private_download": "https://files.slack.com/a", "thumb_360": "https://files.slack.com/a-thumb"],
            ["id": "F2", "title": "안내문.pdf", "mimetype": "application/pdf", "url_private": "https://files.slack.com/b"],
            ["id": "F3", "name": "gone.png", "mode": "tombstone"]]])
        check(withFiles?.files.map(\.id) == ["F1", "F2", "F3"] && withFiles?.files[2].isDeleted == true && withFiles?.files[0].isImage == true && withFiles?.files[0].thumb == "https://files.slack.com/a-thumb"
              && withFiles?.files[1].isPDF == true && withFiles?.files[1].name == "안내문.pdf" && withFiles?.text == "", "a message that is only files still shows, and a withdrawn file retains a tombstone")
        let laidOut = SlackMessage(json: ["ts": "1.0", "text": "*🟡 제목*  본문 • 하나", "blocks": [
            ["type": "header", "text": ["type": "plain_text", "text": "🟡 제목 <x>"]],
            ["type": "section", "text": ["type": "mrkdwn", "text": "*맥락*"]],
            ["type": "divider"],
        ], "attachments": [["color": "#ECB22E", "blocks": [["type": "rich_text", "elements": [
            ["type": "rich_text_section", "elements": [["type": "text", "text": "마감 "], ["type": "text", "text": "10/20 ", "style": ["bold": true]],
                                                      ["type": "link", "url": "https://a.b", "text": "메일"]]],
            ["type": "rich_text_list", "style": "bullet", "indent": 0, "elements": [["type": "rich_text_section", "elements": [["type": "text", "text": "하나"]]]]],
            ["type": "rich_text_list", "style": "ordered", "indent": 1, "elements": [["type": "rich_text_section", "elements": [["type": "text", "text": "둘", "style": ["code": true]]]]]],
            ["type": "rich_text_quote", "elements": [["type": "text", "text": "원문"]]],
        ]]]]]])
        check(laidOut?.text == "### 제목 &lt;x&gt;\n\n*맥락*\n\n────────\n\n> 마감 *10/20* <https://a.b|메일>\n> • 하나\n>     1. `둘`\n> > 원문" && laidOut?.marks.isEmpty == true,
              "Block Kit posts keep their lines instead of Slack's one-line fallback: \(laidOut?.text ?? "")")
        check(laidOut?.quoteColors == ["#ECB22E"] && SlackMessage(json: ["ts": "1.0", "text": "a", "blocks": [["type": "divider"]]])?.quoteColors == nil,
              "a coloured block attachment keeps its colour for the bar beside its quoted lines")
        let grey = SlackMessage(json: ["ts": "1.0", "text": "a", "blocks": [["type": "header", "text": ["type": "plain_text", "text": "주간 정리"]],
            ["type": "rich_text", "elements": [["type": "rich_text_section", "elements": [["type": "text", "text": "본문"]]]]]]])
        let urgent = SlackMessage(json: ["ts": "1.0", "text": "a", "blocks": [["type": "header", "text": ["type": "plain_text", "text": "🚨 실패"]],
            ["type": "section", "text": ["type": "mrkdwn", "text": "원인"]]]])
        check(grey?.text == "### 주간 정리\n\n> 본문" && grey?.quoteColors == [""] && urgent?.text == "### 실패\n\n> 원인" && urgent?.quoteColors == ["#E01E5A"]
              && SlackBlockText.statusColor("✅ 확인 필요 없음") == "#2EB67D" && SlackBlockText.statusColor("⚠️ 주의") == "#ECB22E"
              && SlackBlockText.withoutStatus("⚠️ 주의") == "주의" && SlackBlockText.withoutStatus(":large_blue_circle: 정보") == "정보" && SlackBlockText.withoutStatus("✅") == "✅"
              && SlackBlockText.withoutStatus("요약 🔵") == "요약 🔵",
              "a titled report keeps its words behind a bar coloured by the title's status, grey without one: \(grey?.text ?? "")")
        let report = SlackMessage(json: ["ts": "1.0", "text": "a", "blocks": [["type": "header", "text": ["type": "plain_text", "text": "보고"]]], "attachments": [
            ["blocks": [["type": "section", "text": ["type": "mrkdwn", "text": "일반"]]]], ["color": "#2EB67D", "blocks": [["type": "divider"]]],
            ["color": "good", "blocks": [["type": "actions", "elements": []]]], ["color": "#E01E5A", "blocks": [["type": "section", "text": ["type": "mrkdwn", "text": "긴급"]]]]]])
        check(report?.text == "### 보고\n\n> 일반\n\n> ────────\n\n> 긴급" && report?.quoteColors == ["", "#2EB67D", "#E01E5A"],
              "each attachment with words keeps its own colour, grey without one: \(report?.text ?? "") \(String(describing: report?.quoteColors))")
        let tabled = SlackMessage(json: ["ts": "1.0", "text": "a", "blocks": [["type": "table", "column_settings": [["align": "left"], ["align": "right"]], "rows": [
            [["type": "raw_text", "text": "항목"], ["type": "rich_text", "elements": [["type": "rich_text_section", "elements": [["type": "text", "text": "값", "style": ["bold": true]]]]]]],
            [["type": "raw_text", "text": "a|b"]]]]]])
        check(tabled?.text == "| 항목 | *값* |\n| --- | ---: |\n| a∣b |  |", "a Slack table becomes pipe rows ddots lays out as a table: \(tabled?.text ?? "")")
        let struck = SlackMessage(json: ["ts": "1.0", "text": "a", "blocks": [["type": "rich_text", "elements": [["type": "rich_text_section", "elements": [["type": "text", "text": "취소", "style": ["strike": true]]]], ["type": "rich_text_preformatted", "elements": [["type": "text", "text": "x"]]]]]]])
        check(struck?.text == "~~취소~~\n```\nx\n```", "struck words and code keep Slack's marks in a form ddots draws: \(struck?.text ?? "")")
        check(SlackMessage(json: ["ts": "1.0", "text": "그냥 글", "blocks": [["type": "section", "text": ["type": "mrkdwn", "text": "그냥 글"]]]])?.text == "그냥 글",
              "a post without layout blocks keeps its text")
        let painted = SlackMessage(json: ["ts": "1.0", "text": "문의", "attachments": [["color": "2eb67d", "text": "*답변 완료*"], ["color": "danger", "fallback": "급함"], ["text": "색 없는 메모"], ["color": "nonsense"]]])
        check(painted?.marks == [ChatMark(color: "#2EB67D", text: "*답변 완료*"), ChatMark(color: "#E01E5A", text: "급함"), ChatMark(color: "", text: "색 없는 메모")], "attachments keep their colour and note: \(String(describing: painted?.marks))")
        check(SlackMessage(json: ["ts": "1.0", "text": "", "attachments": [["color": "#ECB22E", "text": "목록"]]])?.marks.count == 1 && painted != SlackMessage(json: ["ts": "1.0", "text": "문의"]), "a post that is only attachments still shows, and a repaint counts as a change")
        check(SlackAPI.validToken(" xoxp-1234567890-abcdefghij ") == "xoxp-1234567890-abcdefghij" && SlackAPI.validToken("xoxb-1234567890-abcdefghij") == nil && SlackAPI.validToken("xoxp-12 34") == nil, "only a user token is accepted")

        // Grouping
        let slack = FakeSlack()
        func bot(_ ts: String, _ text: String, thread: String? = nil, replies: Int = 0, latest: String? = nil) -> [String: Any] {
            var message: [String: Any] = ["ts": ts, "user": "UCOWBOT", "bot_profile": ["name": "SNS담당"], "text": text]
            if let thread { message["thread_ts"] = thread }
            if replies > 0 { message["reply_count"] = replies; message["latest_reply"] = latest ?? ts; message["thread_ts"] = ts }
            return message
        }
        func mine(_ ts: String, _ text: String, thread: String? = nil) -> [String: Any] {
            var message: [String: Any] = ["ts": ts, "user": "UME", "text": text]
            if let thread { message["thread_ts"] = thread }
            return message
        }
        // A channel broadcast brings its old thread to the broadcast's place in the room.
        func broadcast(_ ts: String, thread: String) -> [String: Any] {
            var line = bot(ts, "채널에도 보낸 답", thread: thread)
            line["subtype"] = "thread_broadcast"
            return line
        }
        // Same transport as the TalkTalk bridge: separate IDs have separate roots, while a
        // returning customer's broadcast raises their existing thread with readable literal blocks.
        var talkRoot = bot("100.0", "네이버 톡톡 처리 알림")
        talkRoot["blocks"] = [["type": "section", "text": ["type": "plain_text", "text": "톡톡 NT-one · 승인 대기\n받은 글: 첫 문의"]]]
        var talkReply = broadcast("300.0", thread: "100.0")
        talkReply["text"] = "네이버 톡톡 처리 알림"
        talkReply["blocks"] = [["type": "section", "text": ["type": "plain_text", "text": "받은 글: 추가 문의\n답장 초안: 안내 답장\n승인 또는 ㅇㅇ"]]]
        let talkChannel = FakeSlack()
        talkChannel.history["CCOW"] = [talkRoot, bot("200.0", "톡톡 NT-two · 새 문의"), talkReply]
        talkChannel.replies["CCOW:100.0"] = [talkRoot, talkReply]
        let talkView = SlackBridge(api: talkChannel.api).sync(.init(active: "CCOW", open: true, characters: characters), now: Date(timeIntervalSince1970: 10_000))
        check(talkView.threads["CCOW"]?.map(\.ts) == ["200.0", "100.0"], "TalkTalk IDs remain separate and same-ID broadcasts raise the existing thread")
        check(SlackMessage(json: talkReply)?.text.contains("답장 초안: 안내 답장") == true && SlackMessage(json: talkReply)?.broadcast == true,
              "TalkTalk literal blocks expose the received question, draft and approval in ddots")
        check(SlackMessage(json: bot("400.0", "네이버 톡톡 처리 알림"))?.text == "네이버 톡톡 처리 알림", "missing TalkTalk blocks preserve fallback")
        var oldTalkCache = SlackCache()
        oldTalkCache.state.replies["CCOW"] = ["100.0": [SlackMessage(ts: "300.0", text: "네이버 톡톡 처리 알림")]]
        oldTalkCache.fetched = ["CCOW:100.0": "300.0", "COTHER:1.0": "2.0"]
        let oldTalkURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try! JSONEncoder().encode(oldTalkCache).write(to: oldTalkURL)
        let refreshedTalk = SlackCache.read(oldTalkURL)
        try? FileManager.default.removeItem(at: oldTalkURL)
        check(refreshedTalk?.fetched["CCOW:100.0"] == "naver-blocks-refresh" && refreshedTalk?.fetched["COTHER:1.0"] == "2.0",
              "legacy title-only TalkTalk cache is refreshed without clearing other conversations")
        let channel = FakeSlack()
        let oldRoot = bot("100.0", "오래된 문의", replies: 1, latest: "300.0")
        channel.history["CCOW"] = [bot("200.0", "새 문의"), broadcast("300.0", thread: "100.0")]
        channel.replies["CCOW:100.0"] = [oldRoot, broadcast("300.0", thread: "100.0")]
        let broadcasts = SlackBridge(api: channel.api)
        let channelTime = Date(timeIntervalSince1970: 10_000)
        var channelRequest = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
        var channelView = broadcasts.sync(channelRequest, now: channelTime)
        check(channelView.threads["CCOW"]?.map(\.ts) == ["200.0", "100.0"] && channelView.threads["CCOW"]?.last?.replies.count == 1,
              "a broadcast alone finds the old root and places its thread last")
        check(channel.log.filter { $0 == "conversations.replies" }.count == 1, "an old broadcast is read without any Hermes session")
        _ = broadcasts.sync(channelRequest, now: channelTime.addingTimeInterval(4))
        check(channel.log.filter { $0 == "conversations.replies" }.count == 1, "the same broadcast is not read twice")
        channel.history["CCOW"]?.append(broadcast("400.0", thread: "100.0"))
        channel.replies["CCOW:100.0"]?.append(broadcast("400.0", thread: "100.0"))
        channelRequest.recent = ["CCOW:100.0": 400]
        channelView = broadcasts.sync(channelRequest, now: channelTime.addingTimeInterval(8))
        check(channel.log.filter { $0 == "conversations.replies" }.count == 2 && channelView.threads["CCOW"]?.last?.position == Date(timeIntervalSince1970: 400),
              "a newer broadcast and Hermes activity share one new read and update its place")
        channel.history["CCOW"] = [bot("200.0", "새 문의")]
        channelView = broadcasts.sync(channelRequest, now: channelTime.addingTimeInterval(12))
        check(channelView.threads["CCOW"]?.last?.position == Date(timeIntervalSince1970: 400), "cached broadcast replies keep the place after leaving history")

        let listedChannel = FakeSlack()
        listedChannel.history["CCOW"] = [oldRoot, bot("200.0", "새 문의"), broadcast("300.0", thread: "100.0")]
        // History still supplies the broadcast stamp if the replies response has no subtype.
        listedChannel.replies["CCOW:100.0"] = [oldRoot, bot("300.0", "답", thread: "100.0")]
        let listedBroadcasts = SlackBridge(api: listedChannel.api)
        var listedView = listedBroadcasts.sync(channelRequest, now: channelTime)
        check(listedView.threads["CCOW"]?.map(\.ts) == ["200.0", "100.0"], "a listed root moves to its history broadcast's time")
        let shifted = listedView.threads["CCOW"] ?? []
        check(Ddots.merged(["CCOW": shifted, "OTHER": []], rooms: ["CCOW", "OTHER"]).map(\.ts) == ["200.0", "100.0"]
              && Ddots.joined(live: shifted, kept: [shifted[0]]).map(\.ts) == ["200.0", "100.0"], "merged and joined live rooms use broadcast time")
        listedChannel.history["CCOW"] = [oldRoot, bot("200.0", "새 문의"), bot("300.0", "일반 답", thread: "100.0")]
        listedView = listedBroadcasts.sync(channelRequest, now: channelTime.addingTimeInterval(4))
        check(listedView.threads["CCOW"]?.map(\.ts) == ["200.0", "100.0"], "a channel reply without a subtype still keeps its place")
        let ordinaryChannel = FakeSlack()
        ordinaryChannel.history["CCOW"] = [oldRoot, bot("200.0", "새 문의")]
        ordinaryChannel.replies["CCOW:100.0"] = [oldRoot, bot("300.0", "일반 답", thread: "100.0")]
        let ordinaryBridge = SlackBridge(api: ordinaryChannel.api)
        let ordinaryView = ordinaryBridge.sync(channelRequest, now: channelTime)
        check(ordinaryView.threads["CCOW"]?.map(\.ts) == ["100.0", "200.0"], "a reply only read through replies leaves its thread at the root's time")
        check(SlackMessage(json: broadcast("300.0", thread: "100.0"))?.broadcast == true
              && SlackMessage(json: broadcast("300.0", thread: "100.0")) != SlackMessage(json: bot("300.0", "채널에도 보낸 답", thread: "100.0")), "broadcast subtype participates in equality")

        for subtype in ["", "bot_message"] {
            let unmarked = FakeSlack()
            var line = bot("300.0", "PRIVATE_BODY", thread: "100.0")
            if !subtype.isEmpty { line["subtype"] = subtype }
            line["edited"] = ["user": "PRIVATE_USER", "ts": "301.0"]
            line["root"] = ["text": "PRIVATE_ROOT"]
            line["bot_id"] = "PRIVATE_BOT"
            line["attachments"] = [["text": "PRIVATE_ATTACHMENT"]]
            unmarked.history["CCOW"] = [bot("200.0", "PRIVATE_OTHER"), line,
                ["ts": "250.0", "subtype": "channel_join", "text": "PRIVATE_DISCARDED", "user": "PRIVATE_USER"]]
            unmarked.replies["CCOW:100.0"] = [oldRoot, bot("300.0", "PRIVATE_REPLY", thread: "100.0")]
            let unmarkedBridge = SlackBridge(api: unmarked.api)
            let unmarkedRequest = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
            var unmarkedView = unmarkedBridge.sync(unmarkedRequest, now: channelTime)
            check(unmarkedView.threads["CCOW"]?.map(\.ts) == ["200.0", "100.0"], "a history reply needs no broadcast subtype: \(subtype)")
            let structure = unmarkedBridge.diagnostics(room: "CCOW")
            check(!structure.contains("PRIVATE_") && !structure.contains("오래된 문의") && !structure.contains("SNS담당"), "diagnostics never contain text or names")
            check(structure.contains("ts=300.0 thread_ts=100.0 subtype=\(subtype.isEmpty ? "-" : subtype)")
                  && structure.contains("edited=true root=true bot_id=true attachments=true discarded=false")
                  && structure.contains("subtype=channel_join") && structure.contains("discarded=true")
                  && structure.contains("ts=100.0 status=read") && structure.contains("position=300.0") && structure.contains("extra=true"), "diagnostics include raw discarded rows, order and read state")
            unmarked.history["CCOW"] = [bot("200.0", "새 문의")]
            unmarkedView = unmarkedBridge.sync(unmarkedRequest, now: channelTime.addingTimeInterval(4))
            check(unmarkedView.threads["CCOW"]?.last?.position == Date(timeIntervalSince1970: 300), "the channel position survives history eviction without a reply subtype")
            check(unmarked.log.filter { $0 == "conversations.replies" }.count == 1, "an unmarked channel reply is not repeatedly read")
        }

        let goneChannel = FakeSlack()
        goneChannel.history["CCOW"] = [broadcast("300.0", thread: "100.0")]
        goneChannel.gone = ["CCOW:100.0"]
        let goneBroadcasts = SlackBridge(api: goneChannel.api)
        _ = goneBroadcasts.sync(channelRequest, now: channelTime)
        _ = goneBroadcasts.sync(channelRequest, now: channelTime.addingTimeInterval(4))
        check(goneChannel.log.filter { $0 == "conversations.replies" }.count == 1, "a missing broadcast thread is remembered, including the Hermes path")
        check(goneBroadcasts.diagnostics(room: "CCOW").contains("ts=100.0 status=thread_not_found"), "diagnostics distinguish a missing thread")
        goneChannel.history["CCOW"]?.append(broadcast("400.0", thread: "100.0"))
        _ = goneBroadcasts.sync(channelRequest, now: channelTime.addingTimeInterval(8))
        check(goneChannel.log.filter { $0 == "conversations.replies" }.count == 2, "new evidence retries a missing thread once")

        // Hidden candidates keep the background allowance; shown ones use the on-screen allowance.
        for open in [false, true] {
            let crowdedChannel = FakeSlack()
            crowdedChannel.history["CCOW"] = (1...40).map { broadcast("\(200 + $0).0", thread: "\($0).0") }
            let crowdedBroadcasts = SlackBridge(api: crowdedChannel.api)
            let crowdedRequest = SlackBridge.Request(active: "CCOW", open: open, characters: characters)
            let allowance = open ? SlackBridge.shownRepliesPerSync : SlackBridge.repliesPerSync
            // A hidden room may follow another room's history on the first pass.
            _ = crowdedBroadcasts.sync(crowdedRequest, now: channelTime)
            if crowdedChannel.replyLog.isEmpty { _ = crowdedBroadcasts.sync(crowdedRequest, now: channelTime.addingTimeInterval(1)) }
            check(crowdedChannel.replyLog.count == allowance, "candidates use their own stage's budget: \(open)")
            check(crowdedBroadcasts.diagnostics(room: "CCOW").contains("skipped_budget=\(40 - allowance)") && crowdedBroadcasts.diagnostics(room: "CCOW").contains("status=waiting")
                  && crowdedBroadcasts.diagnostics(room: "CCOW").contains("status=failed"), "diagnostics show waiting, budget skips and missing roots in successful responses")
            // Spent a few at a time, so the minute's allowance is reached over the minute rather than in its first seconds.
            var most = 0
            for step in 2...59 {
                let before = crowdedChannel.replyLog.count
                _ = crowdedBroadcasts.sync(crowdedRequest, now: channelTime.addingTimeInterval(Double(step)))
                if step >= 5 { most = max(most, crowdedChannel.replyLog.count - before) }
                if step == 21 { check(crowdedChannel.replyLog.count < SlackBridge.callsPerMinute - SlackBridge.reservedCalls, "the allowance is not spent at once: \(crowdedChannel.replyLog.count)") }
            }
            check(most <= 2, "after the first few, thread readings come one or two a pass: \(most)")
            check(crowdedChannel.replyLog.count == SlackBridge.callsPerMinute - SlackBridge.reservedCalls,
                  "both stages preserve the reserved per-minute allowance")
            check(crowdedBroadcasts.diagnostics(room: "CCOW").contains("skipped_calls=10") && crowdedBroadcasts.diagnostics(room: "CCOW").contains("replies_last_minute=30"), "diagnostics expose the per-minute limit")
        }

        let queuedRooms = FakeSlack()
        for room in ["CTRUTH", "DJARVIS"] {
            queuedRooms.history[room] = (1...20).map { bot("\(1000 + $0).0", "밀린 글", replies: 1, latest: "2000.0") }
        }
        let priority = SlackBridge(api: queuedRooms.api)
        for step in 0...2 { _ = priority.sync(SlackBridge.Request(active: nil, open: false, characters: characters), now: channelTime.addingTimeInterval(Double(step))) }
        queuedRooms.history["CCOW"] = [bot("200.0", "새 문의"), broadcast("3000.0", thread: "100.0")]
        queuedRooms.replies["CCOW:100.0"] = [oldRoot, broadcast("3000.0", thread: "100.0")]
        let beforePriority = queuedRooms.replyLog.count
        var priorityRequest = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
        priorityRequest.recent = ["CCOW:100.0": 3000]
        let priorityView = priority.sync(priorityRequest, now: channelTime.addingTimeInterval(4))
        check(priorityView.threads["CCOW"]?.last?.ts == "100.0" && priorityView.threads["CCOW"]?.last?.loaded == true,
              "a shown old thread loads on the first pass despite several rooms of queuedRooms")
        check(queuedRooms.replyLog.dropFirst(beforePriority).first == "CCOW:100.0" && queuedRooms.replyLog.filter { $0 == "CCOW:100.0" }.count == 1,
              "the shown candidate precedes background work and shares its read with Hermes")
        check(priority.diagnostics(room: "CCOW").contains("ts=100.0 status=read delay_seconds=0.0"), "an immediately read candidate reports zero pass delay")

        let delayed = FakeSlack()
        delayed.history["CCOW"] = (1...6).map { broadcast("\(300 + $0).0", thread: "\($0).0") }
        for n in 1...6 { delayed.replies["CCOW:\(n).0"] = [bot("\(n).0", "원글"), broadcast("\(300 + n).0", thread: "\(n).0")] }
        let delayedBridge = SlackBridge(api: delayed.api)
        let delayRequest = SlackBridge.Request(active: nil, open: false, watch: ["CCOW"], characters: characters)
        _ = delayedBridge.sync(delayRequest, now: channelTime)
        check(delayed.replyLog == ["CCOW:6.0", "CCOW:5.0", "CCOW:4.0", "CCOW:3.0"], "watched candidates run newest first without a second background allowance")
        _ = delayedBridge.sync(delayRequest, now: channelTime.addingTimeInterval(4))
        check(delayedBridge.diagnostics(room: "CCOW").contains("ts=1.0 status=read delay_seconds=4.0") && Set(delayed.replyLog).count == delayed.replyLog.count,
              "the next pass records the initial wait and never duplicates a candidate")
        _ = delayedBridge.sync(delayRequest, now: channelTime.addingTimeInterval(8))
        check(delayedBridge.diagnostics(room: "CCOW").contains("ts=1.0 status=read delay_seconds=4.0"), "completed delay stays fixed")

        // A live thread must not consume the share needed to discover a shown old thread.
        let flowing = FakeSlack()
        flowing.history["CCOW"] = [bot("9900.0", "◐ 생각 중...", replies: 1, latest: "9901.0")]
        flowing.replies["CCOW:9900.0"] = [bot("9900.0", "◐ 생각 중..."), bot("9901.0", "PRIVATE_LIVE_BODY", thread: "9900.0")]
        let fair = SlackBridge(api: flowing.api)
        let fairRequest = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
        var windows: [(at: Double, count: Int)] = []
        func fairSync(_ seconds: Double) -> SlackBridge.Snapshot {
            let before = flowing.replyLog.count
            let view = fair.sync(fairRequest, now: channelTime.addingTimeInterval(seconds))
            windows.append((seconds, flowing.replyLog.count - before))
            check(windows.filter { seconds - $0.at < 60 }.reduce(0) { $0 + $1.count } <= SlackBridge.callsPerMinute, "the rolling minute never exceeds the shared allowance")
            return view
        }
        for step in 0...30 { _ = fairSync(Double(step) * 1.5) }
        check(flowing.replyLog.count == 31, "without waiting work the live thread keeps its 1.5-second pace beyond thirty calls")
        flowing.history["CCOW"]?.append(broadcast("9999.0", thread: "100.0"))
        flowing.replies["CCOW:100.0"] = [oldRoot, broadcast("9999.0", thread: "100.0")]
        var discovered: Double?
        for step in 31...49 {
            let seconds = Double(step) * 1.5
            if fairSync(seconds).threads["CCOW"]?.last?.ts == "100.0", discovered == nil { discovered = seconds }
        }
        check(discovered != nil && discovered! - 46.5 < 30, "a shown candidate is discovered within thirty seconds while urgent work continues")
        let fairDiagnostic = fair.diagnostics(room: "CCOW")
        check(fairDiagnostic.contains(" urgent=") && fairDiagnostic.contains(" nonurgent=1") && fairDiagnostic.contains("thread=CCOW:9900.0")
              && fairDiagnostic.contains("thinking=") && !fairDiagnostic.contains("PRIVATE_LIVE_BODY") && !fairDiagnostic.contains("생각 중"), "diagnostics report urgency, thread and reason without words")
        // Keep both classes waiting for multiple rolling minutes.
        for n in 1...40 {
            flowing.history["CCOW"]?.append(broadcast("\(11000 + n).0", thread: "\(n).0"))
            flowing.replies["CCOW:\(n).0"] = [bot("\(n).0", "원글"), broadcast("\(11000 + n).0", thread: "\(n).0")]
        }
        for step in 50...140 { _ = fairSync(Double(step) * 1.5) }
        check(Set(flowing.replyLog.filter { $0 != "CCOW:9900.0" }).count == 41, "both classes eventually make progress")

        let laggingHistory = FakeSlack()
        laggingHistory.history["CCOW"] = [bot("100.0", "원글", replies: 1, latest: "150.0")]
        laggingHistory.replies["CCOW:100.0"] = [bot("100.0", "원글"), bot("200.0", "새 답", thread: "100.0")]
        let laggingBridge = SlackBridge(api: laggingHistory.api)
        _ = laggingBridge.sync(fairRequest, now: channelTime)
        _ = laggingBridge.sync(fairRequest, now: channelTime.addingTimeInterval(4))
        check(laggingHistory.replyLog.count == 1 && laggingBridge.staleThreads("CCOW", wanted: [], eager: 0).isEmpty, "a newer replies stamp does not keep stale history changed")
        laggingHistory.history["CCOW"] = [bot("100.0", "원글", replies: 1, latest: "200.0")]
        _ = laggingBridge.sync(fairRequest, now: channelTime.addingTimeInterval(8))
        _ = laggingBridge.sync(fairRequest, now: channelTime.addingTimeInterval(12))
        check(laggingHistory.replyLog.count == 2 && laggingBridge.staleThreads("CCOW", wanted: [], eager: 0).isEmpty
              && laggingBridge.diagnostics(room: "CCOW").contains("changed=1"), "when history catches up it is changed once, not every pass")
        check(broadcasts.staleThreads("CCOW", wanted: [], eager: 0).isEmpty, "extra-only roots never enter changed")

        slack.history["CCOW"] = [
            bot("300.0", "세 번째 문의"),
            bot("200.0", "두 번째 문의", replies: 4, latest: "204.0"),
            ["ts": "150.0", "subtype": "channel_join", "user": "UME", "text": "joined"],
            bot("100.0", "첫 문의", replies: 1, latest: "101.0"),
            mine("204.0", "방에도 보낸 답글", thread: "200.0"),
        ]
        slack.replies["CCOW:100.0"] = [bot("100.0", "첫 문의", replies: 1, latest: "101.0"), mine("101.0", "확인했어", thread: "100.0")]
        slack.replies["CCOW:200.0"] = [bot("200.0", "두 번째 문의", replies: 4, latest: "204.0"), mine("201.0", "하나", thread: "200.0"),
                                       bot("202.0", "둘", thread: "200.0"), ["ts": "203.0", "user": "UGUEST", "text": "셋", "thread_ts": "200.0"], bot("204.0", "넷", thread: "200.0")]
        slack.history["CTRUTH"] = [bot("50.0", "진실의방 글")]

        let bridge = SlackBridge(api: slack.api)
        let start = Date(timeIntervalSince1970: 1_000)
        var request = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
        var snapshot = bridge.sync(request, now: start)
        let listedChannels = ["진실의방", "SNS담당방"].sorted()
        check(snapshot.status == .connected && snapshot.rooms.map(\.name) == listedChannels + ["개인비서"] && snapshot.rooms.last?.direct == true, "rooms are listed with direct conversations last")
        let cow = snapshot.threads["CCOW"] ?? []
        check(cow.map(\.ts) == ["100.0", "200.0", "300.0"], "threads are ordered oldest first and replies never appear as their own thread")
        check(cow[0].replies.map(\.body) == ["확인했어"] && cow[0].replies[0].fromUser && cow[0].latestFromUser, "my own reply is recognized")
        check(cow[1].replies.map(\.body) == ["하나", "둘", "셋", "넷"] && cow[1].replyCount == 4 && !cow[1].latestFromUser && cow[1].latest == 204, "replies are in order without the first message")
        check(cow[1].root.profile == "sns-manager" && cow[1].root.speaker == "SNS담당" && cow[1].replies[2].speaker == "손님" && cow[1].replies[2].profile == "", "speakers carry their character or their Slack name")
        check(cow[2].loaded && cow[2].replies.isEmpty && cow[1].root.id == "slack:CCOW:200.0", "a thread without replies needs no extra read")
        check(snapshot.threads["CTRUTH"]?.count == 1, "one other room is read on the same pass")

        // Copying a thread
        check(snapshot.workspace == "https://team.slack.test/", "the workspace's address comes with the token's owner")
        check(SlackCopy.link(workspace: snapshot.workspace, room: "CCOW", ts: "1759646700.123456") == "https://team.slack.test/archives/CCOW/p1759646700123456?thread_ts=1759646700.123456&cid=CCOW",
              "a thread's address is the workspace, the room and the first message's stamp without its point")
        check(SlackCopy.link(workspace: "", room: "CCOW", ts: "200.0") == nil && SlackCopy.link(workspace: snapshot.workspace, room: "CCOW", ts: "") == nil
              && SlackCopy.link(workspace: snapshot.workspace, room: "", ts: "200.0") == nil, "without the workspace, the room or a stamp there is no address")
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        check(SlackCopy.text(cow[1], place: "#SNS담당방", link: "https://team.slack.test/x", zone: seoul)
              == "#SNS담당방 스레드 · 글 5개\nhttps://team.slack.test/x\n\n[1970-01-01 09:03] SNS담당\n두 번째 문의\n\n[1970-01-01 09:03] 나\n하나\n\n[1970-01-01 09:03] SNS담당\n둘\n\n[1970-01-01 09:03] 손님\n셋\n\n[1970-01-01 09:03] SNS담당\n넷",
              "a copied thread is its first message and every reply in order, each under its time and speaker: \(SlackCopy.text(cow[1], place: "#SNS담당방", link: nil, zone: seoul))")
        var dressed = cow[2]
        dressed.root.body = "자료야 <https://example.com/my_file> [원문](https://example.com/a)"
        dressed.root.marks = [ChatMark(color: "#2EB67D", text: "답변 완료"), ChatMark(color: "#E01E5A", text: "")]
        dressed.root.files = [ChatFile(id: "F1", name: "안내문.pdf")]
        dressed.replies = [ChatMessage(id: "slack:CCOW:301.0", fromUser: false, speaker: "SNS담당", body: "◐ 생각 중...", date: Date(timeIntervalSince1970: 301), profile: "sns-manager")]
        check(SlackCopy.text(dressed, place: "", link: nil, mine: "starter_user", zone: seoul)
              == "스레드 · 글 1개\n\n[1970-01-01 09:05] SNS담당\n자료야 https://example.com/my_file [원문](https://example.com/a)\n[✅ 답변 완료]\n📎 안내문.pdf",
              "an address is written plainly, status notes and file names follow the words, and a thinking line is left out: \(SlackCopy.text(dressed, place: "", link: nil, mine: "starter_user", zone: seoul))")

        // Members and mentions
        check(snapshot.members["CCOW"]?.map(\.name) == ["SNS담당", "손님"] && snapshot.members["CCOW"]?.first?.profile == "sns-manager" && snapshot.members["CTRUTH"]?.map(\.user) == ["UJARVIS"]
              && snapshot.members["DJARVIS"]?.map(\.name) == ["개인비서"], "everyone in a room but me is listed, characters first, unreadable names left out: \(snapshot.members)")
        check(SlackMention.toggled("확인해줘", name: "SNS담당") == "@SNS담당 확인해줘" && SlackMention.toggled("@SNS담당 확인해줘", name: "SNS담당") == "확인해줘"
              && SlackMention.toggled("@SNS담당방 봐", name: "SNS담당") == "@SNS담당 @SNS담당방 봐", "a mention is added in front and taken out again, never out of a longer word")
        check(SlackMention.outgoing("@SNS담당 a<b & @손님, @SNS담당방 @없는이", members: snapshot.members["CCOW"] ?? []) == "<@UCOWBOT> a&lt;b &amp; <@UGUEST>, @SNS담당방 @없는이", "typed text is literal and known names become real mentions")

        let mentionCast = [SlackMember(profile: "one", name: "도우미", user: "UONE"),
                           SlackMember(profile: "two", name: "다른이", user: "UTWO"),
                           SlackMember(profile: "", name: "손님", user: "UHUMAN"),
                           SlackMember(profile: "unknown", name: "미확인")]
        check(SlackMention.profiles(in: "본문 @도우미, @도우미", members: mentionCast) == ["one"], "preview resolves repeated mentions anywhere to one profile")
        check(SlackMention.profiles(in: "@도우미방 @도우미2 @손님 @미확인", members: mentionCast).isEmpty, "preview respects outgoing boundaries and excludes humans and missing user IDs")
        check(SlackMention.profiles(in: "@다른이 @도우미", members: mentionCast) == ["one", "two"], "preview retains the complete distinct mention set for hub cross-owner routing")

        // Thinking placeholder and character names
        check(SlackText.isThinking("◐ 생각 중...") && SlackText.isThinking("◒ 생각 중…") && SlackText.isThinking("생각 중…\n- 일정 확인") && !SlackText.isThinking("생각 중인 내용을 정리했어") && !SlackText.isThinking(""), "only Hermes's placeholder line counts as thinking")
        check(SlackText.isThinking("\n\r\n◐ 생각 중...\n추가 설명") && !SlackText.isThinking("\n답변 완료\n생각 중...")
              && !SlackText.isThinking(" \n생각 중...") && !SlackText.isThinking("답변\n완료"), "thinking checks only the first nonempty line, preserving whitespace-only lines")
        var named = SlackState(); named.history["R"] = [SlackMessage(ts: "1.0", user: "UB", name: "personal-secretary", text: "확인했어"), SlackMessage(ts: "2.0", user: "UX", name: "외부 봇", text: "알림")]
        let spoken = named.threads(room: "R", characters: characters).map(\.root)
        check(spoken[0].speaker == "개인비서" && spoken[0].profile == "personal-secretary" && spoken[1].speaker == "외부 봇" && spoken[1].profile == "", "a bot matched to a character goes by the character's name")

        // Room order and search
        let listed = [SlackRoom(id: "A", name: "가"), SlackRoom(id: "B", name: "나"), SlackRoom(id: "C", name: "다"), SlackRoom(id: "D", name: "라")]
        let seen = ["B": Date(timeIntervalSince1970: 30), "C": Date(timeIntervalSince1970: 50), "D": Date(timeIntervalSince1970: 10)]
        check(SlackRoomOrder.sorted(listed, pins: ["", "", "", "", ""], latest: seen).map(\.id) == ["C", "B", "D", "A"], "rooms with newer activity come first and silent rooms last")
        check(SlackRoomOrder.sorted(listed, pins: ["A", "", "D", "", ""], latest: seen).map(\.id) == ["A", "C", "D", "B"], "a pinned room keeps its place from the top")
        check(SlackRoomOrder.sorted(listed, pins: ["", "", "", "", "A"], latest: seen).map(\.id) == ["C", "B", "D", "A"] && SlackRoomOrder.sorted(listed, pins: ["Z", "B", "", "", ""], latest: seen).map(\.id) == ["C", "B", "D", "A"], "a place past the end or a room that is gone never loses a room")
        check(SlackSearch.hits("확인", in: snapshot.threads).map(\.body) == ["확인했어"] && SlackSearch.hits("  ", in: snapshot.threads).isEmpty && SlackSearch.hits("손님", in: snapshot.threads).map(\.body) == ["셋"], "search finds read lines by their words or their speaker")

        func highlightedPieces(_ text: String, _ query: String) -> [String] {
            SlackSearch.highlights(text, query: query).map { String(text[$0]) }
        }
        check(highlightedPieces("주차 위치, 주차 위치", "주차 위치") == ["주차 위치", "주차 위치"], "all literal phrase occurrences are highlighted")
        check(highlightedPieces("주차와 위치, 위치와 주차", "주차 위치") == ["주차", "위치", "위치", "주차"], "without a phrase every occurrence of each word is highlighted")
        check(highlightedPieces("ababa", "aba bab") == ["ababa"], "overlapping word ranges merge")
        check(highlightedPieces("TEST test TeSt", "test") == ["TEST", "test", "TeSt"], "highlight ignores case")
        check(highlightedPieces("cafe\u{301} CAFÉ", "café").count == 2 && highlightedPieces("café", "cafe\u{301}") == ["café"], "highlight matches NFC and NFD and maps back to the original string")
        check(highlightedPieces("주차장 주차", "차") == ["차", "차"] && highlightedPieces("abc", "  ").isEmpty, "one Korean letter and an empty query")
        check(highlightedPieces("100%_ 100%_", "%_") == ["%_", "%_"], "highlight treats punctuation literally")
        let farMatch = String(repeating: "앞\n", count: 100) + "주차" + String(repeating: " 뒤", count: 100)
        check(SlackSearch.snippet(farMatch, query: "주차").contains("주차") && !SlackSearch.snippet(farMatch, query: "주차").contains("\n"), "preview keeps its match visible without preceding blank lines")

        // Whole search uses literal words, canonical Unicode and one group per thread.
        func findThread(_ room: String, _ stamp: Int, _ body: String, _ replies: [ChatMessage] = []) -> SlackThread {
            let ts = "\(stamp).000000"
            let line = ChatMessage(id: "slack:\(room):\(ts)", fromUser: false, speaker: "SNS담당", body: body, date: Date(timeIntervalSince1970: Double(stamp)), sessionID: ts)
            return SlackThread(id: line.id, room: room, ts: ts, root: line, replies: replies, replyCount: replies.count, loaded: true, latest: Double(stamp), latestFromUser: false)
        }
        let phrase = findThread("R", 10, "주차 위치 안내 CAFÉ 100%_\\")
        let scattered = findThread("R", 30, "위치와 주차 안내")
        let newerPhrase = findThread("R", 20, "주차 위치")
        let corpus = [phrase, scattered, newerPhrase]
        check(SlackSearch.groups("  주차 위치  ", sources: [corpus]).map(\.ts) == ["20.000000", "10.000000", "30.000000"], "literal phrase ranks before all words, each by newest match")
        check(SlackSearch.groups("차", sources: [corpus]).count == 3 && SlackSearch.groups(" ", sources: [corpus]).isEmpty, "one Korean letter matches inside a word; empty query does not")
        check(SlackSearch.groups("cafe\u{301}", sources: [corpus]).count == 1 && SlackSearch.groups("%_\\", sources: [corpus]).count == 1, "NFC, case-insensitive and literal punctuation")
        let reply = ChatMessage(id: "slack:R:40.000000", fromUser: true, speaker: "", body: "주차 위치 답변", date: Date(timeIntervalSince1970: 40), sessionID: phrase.ts)
        var withReply = phrase; withReply.replies = [reply]; withReply.replyCount = 1
        let combined = SlackSearch.groups("주차", sources: [[withReply], [phrase, withReply]])
        check(combined.count == 1 && combined[0].matches.map(\.id) == [reply.id, phrase.root.id] && combined[0].root == phrase.root, "replies group under their root and duplicate sources count once")
        check(SlackSearch.groups("주차", sources: [corpus], hidden: ["R"]).isEmpty, "hidden rooms never match")
        let manyMatches = (1...220).map { findThread("R", $0, "주차") }
        let capped = SlackSearch.groups("주차", sources: [manyMatches])
        check(capped.count == 200 && capped.first?.ts == "220.000000" && capped.last?.ts == "21.000000", "only the newest 200 matching lines are kept")
        var pendingMatch = phrase; pendingMatch.root.pending = true
        check(SlackSearch.groups("주차", sources: [[pendingMatch]]).isEmpty && SlackSearch.groups("생각", sources: [[findThread("R", 1, "생각 중…")]]).isEmpty, "pending and thinking lines are excluded")
        var extras = phrase; extras.root.body = ""; extras.root.marks = [ChatMark(color: "green", text: "승인 완료")]
        extras.root.files = [ChatFile(id: "F", name: "안내.pdf", mimetype: "application/pdf", size: 1, url: "", thumb: "")]
        check(["승인", "안내.pdf", "SNS담당"].allSatisfy { SlackSearch.groups($0, sources: [[extras]]).count == 1 }, "marks, file names and speaker are searchable")
        var previewLine = extras.root; previewLine.body = "본문 앞부분"
        check(SlackSearch.preview("본문", in: previewLine) == .init(body: "본문 앞부분", notes: []), "body match previews only the body")
        check(SlackSearch.preview("안내", in: previewLine) == .init(body: "본문 앞부분", notes: [.init(text: "안내.pdf", file: true)]), "file-only match has a separate attachment note")
        check(SlackSearch.preview("승인", in: previewLine) == .init(body: "본문 앞부분", notes: [.init(text: "승인 완료", file: false)]), "status-only match has a separate status note")
        check(SlackSearch.preview("SNS담당", in: previewLine) == .init(body: "본문 앞부분", notes: []), "speaker-only match never appends the speaker to the body")
        previewLine.body = "승인 뒤 완료된 본문"
        check(SlackSearch.preview("승인 완료", in: previewLine).notes.isEmpty, "all words in the body need no metadata even when separated")
        previewLine.body = ""
        check(SlackSearch.preview("안내", in: previewLine) == .init(body: "", notes: [.init(text: "안내.pdf", file: true)]), "an empty body leaves only its matching metadata")
        let benchThreads = (0..<2000).map { index -> SlackThread in
            var thread = findThread("BENCH", index * 10 + 1, "주차 위치와 안내 자료를 정리한 합성 대화입니다.")
            thread.replies = (2...10).map { offset in
                let ts = "\(index * 10 + offset).000000"
                return ChatMessage(id: "slack:BENCH:" + ts, fromUser: false, speaker: "SNS담당", body: "주차 안내 자료를 확인했습니다. 위치와 이동 경로는 첨부한 문서에 정리되어 있습니다.", date: Date(timeIntervalSince1970: Double(index * 10 + offset)), sessionID: thread.ts)
            }
            thread.replyCount = thread.replies.count
            return thread
        }
        let findStarted = ProcessInfo.processInfo.systemUptime
        let benchFound = SlackSearch.groups("주차 위치", sources: [benchThreads])
        let findMilliseconds = (ProcessInfo.processInfo.systemUptime - findStarted) * 1000
        print(String(format: "BENCH find 20000 lines: %.3f ms", findMilliseconds))
        check(benchFound.reduce(0) { $0 + $1.matches.count } == 200, "the measured search still returns its capped result")

        let searchShelf = DdotsArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("ddots-find-test-\(UUID().uuidString)"))
        let oldLine = DdotsLine(ts: "10.000000", thread: "10.000000", profile: "sns-manager", name: "SNS담당", mine: false, at: 10, text: "옛 기록")
        var hubLine = oldLine; hubLine.ts = "11.000000"; hubLine.hub = true
        let recordGroups = SlackSearch.recorded([oldLine, hubLine], members: [DdotsMember(profile: "sns-manager", name: "SNS담당", room: "DCOW")], hub: "CHUB", archive: searchShelf)
        check(Set(recordGroups.map(\.room)) == ["DCOW", "CHUB"] && SlackSearch.recorded([hubLine], members: [], hub: nil, archive: searchShelf).isEmpty, "record lines map to character rooms, shared lines only to the hub")
        let placeholder = searchShelf.recordURL(name: "SNS담당", month: "2020-01").deletingLastPathComponent().appendingPathComponent(".2020-01.jsonl.icloud")
        try! FileManager.default.createDirectory(at: placeholder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data().write(to: placeholder)
        check(searchShelf.hasUndownloadedMonths() && searchShelf.months().isEmpty && searchShelf.read(month: "2020-01").isEmpty, "iCloud placeholders are skipped and reported")
        try! FileManager.default.removeItem(at: searchShelf.root)
        let searchAPI = SlackAPI { method, parameters in
            check(method == "search.messages" && parameters == ["query": "주차", "count": "50", "sort": "timestamp", "sort_dir": "desc"], "server search uses its own method and timestamp ordering")
            let matches: [[String: Any]] = [
                ["channel": ["id": "R"], "ts": "40.000000", "text": "주차 답변", "user": "UME", "permalink": "https://find.slack.com/archives/R/p40000000?thread_ts=10.000000"],
                ["channel": ["id": "HIDDEN"], "ts": "50.000000", "text": "주차"],
                ["channel": ["id": "UNKNOWN"], "ts": "60.000000", "text": "주차"]]
            return .success(try! JSONSerialization.data(withJSONObject: ["ok": true, "messages": ["matches": matches]]))
        }
        func remoteFind(_ api: SlackAPI) -> Result<[SlackThread], SlackAPI.Failure> {
            SlackSearch.remote("주차", api: api, workspace: "https://find.slack.com/", rooms: ["R", "HIDDEN"], hidden: ["HIDDEN"], me: "UME", users: [:], characters: [])
        }
        if case .success(let found) = remoteFind(searchAPI) {
            check(found.count == 1 && found[0].ts == "10.000000" && found[0].root.fromUser && found[0].root.id == "slack:R:40.000000", "server permalink resolves reply thread, self and allowed rooms")
        } else { check(false, "fake server search succeeded") }
        let missingAPI = SlackAPI { _, _ in .success(Data(#"{"ok":false,"error":"missing_scope","needed":"search:read"}"#.utf8)) }
        if case .failure(let failure) = remoteFind(missingAPI) { check(SlackSearch.failure(failure) == "슬랙 전체 검색은 search:read 권한이 필요해요", "missing_scope tells which permission is needed") }
        else { check(false, "missing scope fails") }
        if case .failure(let failure) = remoteFind(SlackAPI { _, _ in .failure(.rateLimited(30)) }) { check(SlackSearch.failure(failure) == "슬랙 검색이 잠시 제한됐어요", "search rate limit has its own notice") }
        else { check(false, "rate limit fails") }

        // Stack and unread
        check(SlackStack.visible(cow[0], expanded: false).hidden == 0 && SlackStack.visible(cow[0], expanded: false).replies.count == 1, "a short thread is shown whole")
        let stacked = SlackStack.visible(cow[1], expanded: false)
        check(stacked.hidden == 3 && stacked.replies.map(\.body) == ["넷"], "a long thread keeps its newest reply and stacks the rest")
        check(SlackStack.visible(cow[1], expanded: true).hidden == 0 && SlackStack.visible(cow[1], expanded: true).replies.count == 4, "opening shows every reply")
        var unloaded = cow[1]; unloaded.loaded = false; unloaded.replies = []
        check(SlackStack.visible(unloaded, expanded: true).hidden == 4, "an unread thread shows only its count")
        check(SlackUnread.count(cow, lastRead: 0) == 6 && SlackUnread.count(cow, lastRead: 202.5) == 3 && SlackUnread.count(cow, lastRead: 250) == 1 && SlackUnread.count(cow, lastRead: 300) == 0, "unread counts every line from someone else since the room was read, never my own")
        var behind = cow[1]; behind.loaded = false; behind.replies = []; behind.latestFromUser = false
        check(SlackUnread.count([behind], lastRead: 201) == 1 && SlackUnread.count([behind], lastRead: 204) == 0 && SlackUnread.badge(0) == "" && SlackUnread.badge(42) == "42" && SlackUnread.badge(150) == "99+", "a thread with replies not read from Slack yet counts once, and large counts are capped")

        // Polling stays quiet when nothing changed
        snapshot = bridge.sync(request, now: start.addingTimeInterval(1))
        check(bridge.calls == ["conversations.history"] && snapshot.threads["DJARVIS"] != nil, "the remaining room is read on the next pass: \(bridge.calls)")
        snapshot = bridge.sync(request, now: start.addingTimeInterval(2))
        check(bridge.calls.isEmpty, "nothing is asked again inside the interval: \(bridge.calls)")
        snapshot = bridge.sync(request, now: start.addingTimeInterval(4))
        check(bridge.calls == ["conversations.history"], "only the open room is read again: \(bridge.calls)")

        // A new reply is noticed through the room's own listing
        slack.history["CCOW"]?[0] = bot("300.0", "세 번째 문의", replies: 1, latest: "301.0")
        slack.replies["CCOW:300.0"] = [bot("300.0", "세 번째 문의"), bot("301.0", "추가 안내", thread: "300.0")]
        snapshot = bridge.sync(request, now: start.addingTimeInterval(8))
        check(bridge.calls == ["conversations.history", "conversations.replies"] && snapshot.threads["CCOW"]?.last?.replies.map(\.body) == ["추가 안내"], "a changed thread is read once: \(bridge.calls)")

        // A thread older than the listed history is read when Hermes records activity in it
        slack.replies["CCOW:10.0"] = [bot("10.0", "오래된 문의", replies: 1, latest: "310.0"), bot("310.0", "오래된 스레드의 새 답", thread: "10.0")]
        request.recent = ["CCOW:10.0": 310, "CCOW:300.0": 301, "CNONE:1.0": 5]
        snapshot = bridge.sync(request, now: start.addingTimeInterval(9))
        check(bridge.calls == ["conversations.replies"] && snapshot.threads["CCOW"]?.map(\.ts) == ["10.0", "100.0", "200.0", "300.0"]
              && snapshot.threads["CCOW"]?.first?.replies.map(\.body) == ["오래된 스레드의 새 답"], "an older thread with new activity joins the room: \(bridge.calls)")
        snapshot = bridge.sync(request, now: start.addingTimeInterval(10))
        check(bridge.calls.isEmpty, "and is not read again until its activity changes: \(bridge.calls)")
        request.recent = [:]

        // An answer that replaces its "생각 중" line in place is picked up without the room's listing changing
        let thinker = FakeSlack()
        thinker.history["CCOW"] = [mine("500.0", "오늘 일정", thread: nil)]
        thinker.history["CCOW"]?[0]["reply_count"] = 1; thinker.history["CCOW"]?[0]["latest_reply"] = "501.0"; thinker.history["CCOW"]?[0]["thread_ts"] = "500.0"
        thinker.replies["CCOW:500.0"] = [mine("500.0", "오늘 일정"), bot("501.0", "◐ 생각 중...", thread: "500.0")]
        let watching = SlackBridge(api: thinker.api)
        let later = Date(timeIntervalSince1970: 800)
        var view = watching.sync(request, now: later)
        check(view.threads["CCOW"]?.first?.replies.map(\.body) == ["◐ 생각 중..."] && watching.liveThreads("CCOW", now: later) == ["500.0"], "a thread with a thinking line is live")
        thinker.replies["CCOW:500.0"] = [mine("500.0", "오늘 일정"), bot("501.0", "오늘은 일정이 없어.", thread: "500.0")]
        view = watching.sync(request, now: later.addingTimeInterval(1))
        check(watching.calls.filter { $0 == "conversations.replies" }.isEmpty, "a live thread is not read more often than the room itself")
        view = watching.sync(request, now: later.addingTimeInterval(2))
        check(view.threads["CCOW"]?.first?.replies.map(\.body) == ["오늘은 일정이 없어."], "the answer shows as soon as it replaces the thinking line: \(watching.calls)")
        view = watching.sync(request, now: later.addingTimeInterval(8))
        check(!watching.calls.contains("conversations.replies") && watching.liveThreads("CCOW", now: later.addingTimeInterval(8)).isEmpty, "a settled thread goes back to being read only when it changes: \(watching.calls)")

        check(watching.selfPosts["CCOW"] == ["500.0 no marks"], "the marks on my own posts are noted without their words: \(watching.selfPosts)")

        // Sending
        check(bridge.post(room: "CCOW", thread: "300.0", text: "답글 & 확인") == nil && slack.posted.last ?? [:] == ["channel": "CCOW", "thread_ts": "300.0", "text": "답글 & 확인"], "a reply goes to its thread")
        check(bridge.postedRootTS == nil, "Reply sends do not expose a new-post receipt")
        let replied = bridge.current.threads["CCOW"]?.last
        check(replied?.replies.last?.body == "답글 & 확인" && replied?.replies.last?.fromUser == true && replied?.replyCount == 2 && replied?.latestFromUser == true, "the sent reply shows at once")
        check(bridge.post(room: "CTRUTH", thread: nil, text: "새 글") == nil && slack.posted.last?["thread_ts"] == nil && bridge.current.threads["CTRUTH"]?.count == 2, "a room message starts a new thread")

        check(bridge.postedRootTS == "900.000001", "New-post receipt identifies the exact root thread")

        // Files
        check(bridge.upload(room: "CCOW", thread: "300.0", text: "사진 보낼게", files: [("주차장.png", Data(repeating: 1, count: 12)), ("안내.pdf", Data(repeating: 2, count: 7))]) == nil, "files are sent")
        check(slack.uploads["https://upload.test/주차장.png"]?.count == 12 && slack.uploads["https://upload.test/안내.pdf"]?.count == 7, "each file's bytes go to the address Slack gave for it")
        let finished = slack.posted.last ?? [:]
        check(finished["channel_id"] == "CCOW" && finished["thread_ts"] == "300.0" && finished["initial_comment"] == "사진 보낼게"
              && finished["files"]?.contains("F12") == true && finished["files"]?.contains("F7") == true && finished["files"]?.contains("주차장.png") == true, "the files are attached to the thread with the text as their caption: \(finished)")
        check(bridge.upload(room: "CCOW", thread: nil, text: "", files: [("a.txt", Data([1]))]) == nil && slack.posted.last?["initial_comment"] == nil && slack.posted.last?["thread_ts"] == nil, "a file can go to the room on its own")
        check(bridge.uploadedFileIDs == ["F1"], "Upload receipt contains only the latest successful send")
        if case .success(let fetched) = slack.api.raw(URL(string: "https://files.slack.com/report.pdf")!, nil) { check(String(data: fetched, encoding: .utf8) == "bytes of report.pdf", "a file is fetched by its address") } else { check(false, "a file is fetched") }
        check(SlackAPI.takesToken(URL(string: "https://files.slack.com/files-pri/T1-F1/a.pdf")!) && SlackAPI.takesToken(URL(string: "https://slack.com/api/x")!)
              && !SlackAPI.takesToken(URL(string: "https://evilslack.com/a.pdf")!) && !SlackAPI.takesToken(URL(string: "http://files.slack.com/a.pdf")!) && !SlackAPI.takesToken(URL(string: "https://files.slack.com.evil.example/a")!),
              "the token goes only to Slack's own servers, over https")
        check(slack.api.raw(URL(string: "https://files.slack.com/denied")!, nil) == .failure(.api("missing_scope:files:read")) && SlackAPI.message(.api("missing_scope:files:read")).contains("files:read"), "a refused file names the missing permission")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-slack-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SlackFileStore(root: folder)
        let sentAt = Date(timeIntervalSince1970: 1_790_000_000)
        let target = store.destination(room: "SNS담당/방", name: "../안내:문.pdf", date: sentAt)
        check(target.deletingLastPathComponent().lastPathComponent == "SNS담당_방" && target.lastPathComponent.hasSuffix(" _._안내_문.pdf") && target.path.hasPrefix(folder.path + "/"), "names are made safe and stay inside the store: \(target.path)")
        let saved = try? store.save(Data("내용".utf8), room: "SNS담당방", name: "메모.txt", date: sentAt)
        check(saved.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "내용" && saved == store.destination(room: "SNS담당방", name: "메모.txt", date: sentAt), "a saved file lands where the same message's file is looked for")
        check((try? store.keep(copyOf: saved!, room: "다른방", date: sentAt)) == saved, "a file already in the store is not copied again")
        let first = store.destination(room: "SNS담당방", name: "image.png", date: sentAt, id: "F0AAA111"), second = store.destination(room: "SNS담당방", name: "image.png", date: sentAt, id: "F0BBB222")
        check(first != second && first.lastPathComponent.hasSuffix(" image (F0AAA111).png") && store.destination(room: "SNS담당방", name: "image.png", date: sentAt).lastPathComponent.hasSuffix(" image.png"),
              "two files of one name in the same minute are told apart by Slack's ID, and a name without one is as before: \(first.lastPathComponent)")
        let long = SlackFileStore.named(String(repeating: "가", count: 200) + ".pdf", id: "F1/..")
        check(long.hasSuffix(" (F1).pdf") && long.utf8.count <= SlackFileStore.nameBytes && !long.contains("/") && SlackFileStore.named(".숨김", id: "F2") == "_숨김 (F2)" && SlackFileStore.named("", id: "F3") == "이름 없음 (F3)",
              "a long name keeps its extension and fits in a folder: \(long.utf8.count) bytes")
        let outside = folder.deletingLastPathComponent().appendingPathComponent("ddots-slack-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try? FileManager.default.createDirectory(at: outside.appendingPathComponent("a"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outside.appendingPathComponent("b"), withIntermediateDirectories: true)
        try? Data("하나".utf8).write(to: outside.appendingPathComponent("a/image.png")); try? Data("둘".utf8).write(to: outside.appendingPathComponent("b/image.png"))
        let one = try? store.keep(copyOf: outside.appendingPathComponent("a/image.png"), room: "보낸방", date: sentAt)
        let two = try? store.keep(copyOf: outside.appendingPathComponent("b/image.png"), room: "보낸방", date: sentAt)
        let again = try? store.keep(copyOf: outside.appendingPathComponent("b/image.png"), room: "보낸방", date: sentAt)
        check(one != nil && two != nil && one != two && two == again && two?.lastPathComponent.hasSuffix(" image 2.png") == true
              && one.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "하나" && two.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "둘",
              "two sent files of one name are both kept, and the same file is kept once: \(String(describing: two?.lastPathComponent))")
        check(SlackFileStore.sizeText(0) == "" && SlackFileStore.sizeText(900) == "900B" && SlackFileStore.sizeText(2048) == "2.0KB" && SlackFileStore.sizeText(48_213) == "47KB" && SlackFileStore.sizeText(1_240_000) == "1.2MB", "sizes read naturally")
        check(SlackFileStore.standard(home: folder).path == folder.appendingPathComponent("Downloads/HermesWorkspace").path, "without iCloud Drive the folder goes under Downloads")

        // Notice
        func status(_ ts: String, _ color: String, _ label: String) -> [String: Any] { var message = bot(ts, "DM \(ts)"); message["attachments"] = [["color": color, "text": label]]; return message }
        var noticed = SlackState(); noticed.me = "UME"
        noticed.history["N"] = [status("1.0", "#E01E5A", "아직 답 안 함"), status("2.0", "#ECB22E", "초안 올려놨어. 승인 기다리는 중"), status("3.0", "#E01E5A", "아직 답 안 함"),
                                status("4.0", "#2EB67D", "답변 완료"), status("5.0", "#123456", "확인 필요"), bot("6.0", "그냥 글"), bot("7.0", "이 건 환불할지 정해줘."),
                                bot("8.0", "> 손님: 승인 부탁해요\n손님 문의 전달해."), bot("9.0", "정리했어", replies: 1, latest: "9.5"), status("10.0", "#E01E5A", "아직 답 안 함")].compactMap(SlackMessage.init(json:))
        noticed.history["N"]?[9].replyCount = 1; noticed.history["N"]?[9].latestReply = "10.5"
        noticed.replies["N"] = ["9.0": [SlackMessage(ts: "9.5", threadTS: "9.0", user: "UCOWBOT", name: "SNS담당", text: "배포해도 될지 승인 부탁해")],
                                "10.0": [SlackMessage(ts: "10.5", threadTS: "10.0", user: "UME", text: "이렇게 답해줘")]]
        var notice = SlackNotice.items(noticed.threads(room: "N", characters: characters))
        check(notice.map(\.title) == ["답 안 한 DM", "SNS담당 질문", "확인 필요"] && notice.map(\.threads.count) == [2, 1, 1] && notice[0].threads == ["slack:N:1.0", "slack:N:3.0"] && notice[0].color == "#E01E5A"
              && notice[1].threads == ["slack:N:9.0"],
              "the notice counts unanswered messages, approval requests by character, and other open statuses; a plain request, a quoted line, a draft with no request and a thread the user answered last are left out: \(notice)")
        noticed.replies["N"]?["9.0"]?.append(SlackMessage(ts: "9.7", threadTS: "9.0", user: "UME", text: "승인"))
        noticed.replies["N", default: [:]]["7.0"] = [SlackMessage(ts: "7.5", threadTS: "7.0", user: "UJARVIS", name: "개인비서", text: "내가 처리해도 될지 승인 부탁해")]
        noticed.history["N"]?[6].replyCount = 1; noticed.history["N"]?[6].latestReply = "7.5"
        noticed.replies["N", default: [:]]["6.0"] = [SlackMessage(ts: "6.5", threadTS: "6.0", user: "UCOWBOT", name: "SNS담당", text: "> 초안\n승인하면 이대로 보낼게.")]
        noticed.history["N"]?[5].replyCount = 1; noticed.history["N"]?[5].latestReply = "6.5"
        notice = SlackNotice.items(noticed.threads(room: "N", characters: characters))
        check(notice.map(\.title) == ["답 안 한 DM", "SNS담당 질문", "개인비서 질문", "확인 필요"] && notice[1].threads == ["slack:N:6.0"] && notice[2].threads == ["slack:N:7.0"],
              "each character's approval requests are counted under that character, and answering takes one off: \(notice.map(\.title))")
        // A thread a character opened counts as a notification for a day, until the user answers in it.
        var told = SlackState(); told.me = "UME"
        told.history["T"] = [bot("1000.0", "어제 점검 끝났어"), bot("90000.0", "오늘 일정 공유할게", replies: 1, latest: "90010.0"), bot("90100.0", "백업 끝났어", replies: 1, latest: "90110.0"),
                             mine("90200.0", "내가 연 글"), status("90300.0", "#2EB67D", "답변 완료"), bot("90400.0", "◐ 생각 중...")].compactMap(SlackMessage.init(json:))
        told.replies["T"] = ["90000.0": [SlackMessage(ts: "90010.0", threadTS: "90000.0", user: "UJARVIS", name: "개인비서", text: "나도 봤어")],
                             "90100.0": [SlackMessage(ts: "90110.0", threadTS: "90100.0", user: "UME", text: "고마워"), SlackMessage(ts: "90120.0", threadTS: "90100.0", user: "UCOWBOT", name: "SNS담당", text: "응")]]
        let alerts = SlackNotice.items(told.threads(room: "T", characters: characters), now: Date(timeIntervalSince1970: 91_000))
        check(alerts.map(\.title) == ["알림"] && alerts[0].threads == ["slack:T:90000.0"] && alerts[0].color == SlackNotice.alertColor,
              "a notification is a thread a character opened within a day that the user has not answered; old ones, answered ones, my own posts, status posts and thinking lines are not: \(alerts)")
        let toldThreads = told.threads(room: "T", characters: characters)
        check(SlackNotice.items(toldThreads, now: Date(timeIntervalSince1970: 91_000), dismissed: ["slack:T:90000.0": 90_010]).isEmpty
              && SlackNotice.items(toldThreads, now: Date(timeIntervalSince1970: 91_000), dismissed: ["slack:T:90000.0": 90_005]).count == 1 && SlackNotice.hasBell(alerts[0]),
              "a notification marked read stays off the count until something newer happens in its thread")
        for needed in ["승인 부탁해", "승인하면 이대로 보낼게.", "이 작업은 승인이 필요해", "승인해줘", "승인이라고 답해줘", "이 스레드에 `승인`이라고 답하면 백업하고, `거부`면 건너뛸게요.",
                       "아직 보내지 않았어. `승인` 또는 `전송`이라고 해줘.", "그대로 진행하려면 `승인` 또는 `삭제`라고 답해.", "실행하려면 **승인**이라고 답해.", "이 글 바로 다음에 \"승인\"이라고만 남겨줘.",
                       "다시 보내려면 `승인`이라고 한 번 더 해줘.", "이 문장 그대로 보내려면 `승인`이나 `전송`이라고 정확히 적어줘.", "정말 지울 거면 `삭제 승인`이라고 답해.",
                       "이 메시지 바로 다음 줄에 \"승인\" 한마디만 다시 남겨줘.", "승인이라고 답해 주세요.", "삭제할 거면 승인만 다시 줘.", "승인을 부탁해", "이 초안 게시 승인해?", "이대로 승인해줄래?", "초안 올렸고 승인 기다리는 중이야.",
                       "정리본이에요. 승인해 주시면 전략기획실 업무에 바로 만들어요."] {
            check(SlackNotice.requestsApproval(needed), "an approval request: \(needed)")
        }
        for other in ["승인받고 `guest`한테 보냈어.", "감사 인사만 보내서 승인 없이 답했어.", "> 승인 부탁해요\n전달했어", "몇 시로 잡을지 알려줘", "일정만 볼까, 합쳐서 볼까?", "무슨 일이야?",
                      "`guest`에게 `승인` 보냈어.", "네가 `승인`이라고 답해서 바로 보냈어.", "`승인`이라고 답했는데 안 보내졌어.", "지금 승인 대기 중인 새 초안은 없어.", "삭제 승인 받아서 처리했어.",
                      "승인 응답이 없어 실행되지 않았어.", "승인은 됐는데, 발송 기능이 없어.", "- 미리알림: `승인 설명 검증용 미리알림`", "아직 게시 승인은 안 했어. **이 두 초안 게시해**라고 하면 올릴게.",
                      "> `승인`이라고 답해줘\n위 글은 전달만 했어", "승인해 줘서 고마워. 이 건은 승인 주체가 따로 있어.", "승인해줄 사람이 없어서 막아놨어.",
                      "어, 왔어. `wwcost2022` 건은 다 나갔고, 지금 이 스레드에 승인 기다리는 초안은 없어. 시킬 일 있으면 말해.", "승인을 기다리는 건 이제 없습니다.",
                      "승인 감사해요! 히히. 그런데 지금은 승인해 주실 작업이 없어요. 새 항목을 만들 준비를 아직 안 했거든요.\n\n이제 넣을 업무 내용만 주시면 돼요. 제목이랑 원문을 보내 주시면 그 기준대로 정리해서 먼저 보여 드릴게요. 승인해 주시면 그때 전략기획실 업무에 바로 만들어요. 첫 건은 뭐예요?",
                      "지금은 승인할 건 없어요. 원문 주시면 정리해서 보여 드릴게요. 승인해 주시면 그때 만들어요."] {
            check(!SlackNotice.requestsApproval(other), "not an approval request: \(other)")
        }
        // A request the user answered stays off the count even after the character speaks again, and statuses on replies are read too.
        var heard = SlackState(); heard.me = "UME"
        heard.history["H"] = [bot("1.0", "DM 왔어", replies: 3, latest: "1.3"), bot("2.0", "DM 왔어", replies: 2, latest: "2.2"), bot("3.0", "DM 왔어", replies: 1, latest: "3.1"), bot("4.0", "DM 왔어", replies: 2, latest: "4.2")].compactMap(SlackMessage.init(json:))
        heard.replies["H"] = [
            "1.0": [SlackMessage(ts: "1.1", threadTS: "1.0", user: "UCOWBOT", name: "SNS담당", text: "> 초안\n승인하면 이대로 보낼게."), SlackMessage(ts: "1.2", threadTS: "1.0", user: "UME", text: "승인"),
                    SlackMessage(ts: "1.3", threadTS: "1.0", user: "UCOWBOT", name: "SNS담당", text: "승인받고 `guest`한테 보냈어.")],
            "2.0": [SlackMessage(ts: "2.1", threadTS: "2.0", user: "UCOWBOT", name: "SNS담당", text: "> 초안\n승인하면 이대로 보낼게."),
                    SlackMessage(ts: "2.2", threadTS: "2.0", user: "UCOWBOT", name: "SNS담당", text: "`guest`가 스티커를 보냈어. 답할 건 없어.")],
            "3.0": [SlackMessage(ts: "3.1", threadTS: "3.0", user: "UCOWBOT", name: "SNS담당", text: "`guest`가 또 보냈어.", marks: [ChatMark(color: "#E01E5A", text: "아직 답 안 함")])],
            "4.0": [SlackMessage(ts: "4.1", threadTS: "4.0", user: "UCOWBOT", name: "SNS담당", text: "`guest`가 또 보냈어.", marks: [ChatMark(color: "#E01E5A", text: "아직 답 안 함")]),
                    SlackMessage(ts: "4.2", threadTS: "4.0", user: "UCOWBOT", name: "SNS담당", text: "우리 쪽 답장이 나갔어.", marks: [ChatMark(color: "#2EB67D", text: "답변 완료")])]]
        let open = SlackNotice.items(heard.threads(room: "H", characters: characters))
        check(open.map(\.title) == ["답 안 한 DM", "SNS담당 질문"] && open[0].threads == ["slack:H:3.0"] && open[1].threads == ["slack:H:2.0"], "an answered request and a settled thread are off the count; an open request and an unanswered message stay: \(open)")
        let waiting = heard.threads(room: "H", characters: characters)
        check(SlackNotice.pendingApproval(waiting[0]) == nil && SlackNotice.pendingApproval(waiting[1])?.id == "slack:H:2.1" && SlackNotice.pendingApproval(waiting[2]) == nil,
              "an approval request offers its buttons until the user answers, even when the character has said more since")
        let confirmed: Set<String> = ["slack:H:2.1"]
        check(SlackNotice.pendingApproval(waiting[1], confirmed: confirmed) == nil
              && SlackNotice.state(waiting[1], confirmed: confirmed) == nil
              && SlackNotice.isSettled(waiting[1], confirmed: confirmed), "confirming the request removes its buttons and waiting state")
        check(SlackNotice.items([waiting[1]], now: Date(timeIntervalSince1970: 3), confirmed: confirmed).isEmpty,
              "a confirmed question does not fall through to a notification")
        var markedQuestion = waiting[1]
        markedQuestion.root.marks = [ChatMark(color: SlackNotice.questionColor, text: SlackNotice.draft)]
        check(SlackNotice.displayed(markedQuestion, confirmed: confirmed).root.marks.isEmpty
              && markedQuestion.root.marks.count == 1, "confirmation hides the old draft status without altering the source")
        check(SlackNotice.displayed(markedQuestion, confirmed: []).root.marks == markedQuestion.root.marks,
              "an unconfirmed request keeps its original draft status")
        var newer = waiting[1]
        newer.latest = 4
        check(SlackNotice.items([newer], now: Date(timeIntervalSince1970: 4), confirmed: confirmed).isEmpty,
              "a newer thread timestamp does not reopen a confirmed request")
        var nextRequest = newer.replies[0]; nextRequest.id = "slack:H:2.4"
        newer.replies.append(nextRequest)
        check(SlackNotice.pendingApproval(newer, confirmed: confirmed)?.id == nextRequest.id
              && SlackNotice.state(newer, confirmed: confirmed)?.color == SlackNotice.questionColor
              && !SlackNotice.isSettled(newer, confirmed: confirmed)
              && SlackNotice.items([newer], confirmed: confirmed).first?.threads == [newer.id],
              "a different approval request in the same thread reopens its buttons, state and count")
        check(SlackNotice.approveText == "승인" && SlackNotice.denyText == "거부", "the buttons send the words Hermes reads as yes and no")
        check(SlackNotice.items(waiting, dismissed: ["slack:H:2.0": 2.2, "slack:H:3.0": 9]).map(\.title) == ["답 안 한 DM"], "a question marked read leaves the count, but an unanswered customer message cannot be waved away")
        var unread = heard; unread.replies["H"]?["2.0"] = nil
        check(SlackNotice.items(unread.threads(room: "H", characters: characters)).count == 1, "a thread whose replies are not read yet is not counted")

        for label in ["답변 완료", "종결", "  답변 완료\n", ":white_check_mark: 답변 완료", ":large_green_circle: 종결",
                      ":white_check_mark: :large_green_circle: 종결", "✅ 답변 완료", "🟢 종결", "✔️✅ 종결", "👩🏽‍💻 종결", "1️⃣ 종결"] {
            check(SlackNotice.isSettled(label), "A decorated completed status settles: \(label)")
            check(SlackNotice.isSettled(SlackText.display(label, users: [:])), "Displayed emoji keep a completed status settled: \(label)")
        }
        for label in [":white_check_mark: `guest`에게 보냈어", "✅ 답변 완료 뒤에 다른 글", "종결 아님", "1종결", "답변 완료 ✅", "", ":white_check_mark:"] {
            check(!SlackNotice.isSettled(label), "Only the whole status after its leading emoji can settle: \(label)")
        }
        for raw in ["답변 완료", "종결", ":white_check_mark: 답변 완료", ":large_green_circle: 종결"] {
            let shown = SlackNotice.displayStatus(SlackText.display(raw, users: [:]))
            check(shown == SlackNotice.settledText && SlackNotice.isSettled(shown), "All completed marks share one displayed status: \(raw)")
        }
        let ordinaryStatus = SlackText.display(":white_check_mark: `guest`에게 보냈어", users: [:])
        check(SlackNotice.displayStatus(ordinaryStatus) == ordinaryStatus, "Other marks retain their displayed text")
        var finishedStatus = SlackState(); finishedStatus.me = "UME"
        finishedStatus.history["F"] = [
            SlackMessage(ts: "1.0", user: "UCOWBOT", name: "SNS담당", text: "승인하면 보낼게", marks: [ChatMark(color: "#2EB67D", text: ":white_check_mark: 답변 완료")]),
            SlackMessage(ts: "2.0", user: "UCOWBOT", name: "SNS담당", text: "끝났어", marks: [ChatMark(color: "#2EB67D", text: ":large_green_circle: 종결")]),
            SlackMessage(ts: "3.0", user: "UCOWBOT", name: "SNS담당", text: "승인 부탁해", marks: [ChatMark(color: "#ECB22E", text: "확인 필요")]),
            SlackMessage(ts: "4.0", user: "UCOWBOT", name: "SNS담당", text: "승인 부탁해", replyCount: 1, latestReply: "4.1")]
        finishedStatus.replies["F"] = ["4.0": [SlackMessage(ts: "4.1", threadTS: "4.0", user: "UCOWBOT", name: "SNS담당", text: "처리했어",
                                                      marks: [ChatMark(color: "#2EB67D", text: ":white_check_mark: 답변 완료")])]]
        let finishedThreads = finishedStatus.threads(room: "F", characters: characters)
        check(finishedThreads[0].root.marks[0].text == "✅ 답변 완료" && finishedThreads[1].root.marks[0].text == "🟢 종결",
              "The real SlackState presentation path converts status emoji before counting")
        check(SlackNotice.items(finishedThreads).flatMap(\.threads) == ["slack:F:3.0"],
              "Completion on the request or a later reply and a closed status leave every chip; an unfinished request remains")
        check(SlackCopy.text(finishedThreads[1], place: "합성", link: nil).contains("[✅ 답변 완료]")
              && finishedThreads[1].root.marks[0].text == "🟢 종결"
              && finishedStatus.history["F"]?[1].marks[0].text == ":large_green_circle: 종결",
              "Clipboard status is unified while displayed model and source storage keep the original status")
        check(!SlackSearch.groups("종결", sources: [finishedThreads]).isEmpty, "Search still finds the original closed status")
        check(SlackNotice.pendingApproval(finishedThreads[0]) != nil && SlackNotice.state(finishedThreads[0])?.color == SlackNotice.questionColor,
              "Automatic reading preserves approval controls and the thread state")
        check(SlackNotice.isSettled(finishedThreads[0]) && SlackNotice.isSettled(finishedThreads[3]), "Finished requests suppress bells too")
        finishedStatus.history["F"]?[0].replyCount = 1; finishedStatus.history["F"]?[0].latestReply = "1.1"
        finishedStatus.replies["F"]?["1.0"] = [SlackMessage(ts: "1.1", threadTS: "1.0", user: "UCOWBOT", name: "SNS담당", text: "새 초안 승인 부탁해")]
        let reopenedStatus = finishedStatus.threads(room: "F", characters: characters)
        check(SlackNotice.items(reopenedStatus).flatMap(\.threads) == ["slack:F:1.0", "slack:F:3.0"] && !SlackNotice.isSettled(reopenedStatus[0]),
              "A new approval request after the completed status reopens the question and bell")

        let memberLimited = FakeSlack(); memberLimited.memberFailure = .rateLimited(60)
        let memberBridge = SlackBridge(api: memberLimited.api)
        _ = memberBridge.sync(request, now: start)
        check(memberLimited.log.filter { $0 == "conversations.members" }.count == 1, "Member rate limit stops further member calls")
        let memberCalls = memberLimited.log.count
        _ = memberBridge.sync(request, now: start.addingTimeInterval(30))
        check(memberLimited.log.count == memberCalls, "Member Retry-After waits without polling")
        memberLimited.memberFailure = nil
        _ = memberBridge.sync(request, now: start.addingTimeInterval(61))
        check(memberLimited.log.count > memberCalls, "Members resume after Retry-After")

        // Failures
        slack.failure = .api("invalid_auth")
        check(bridge.post(room: "CCOW", thread: nil, text: "실패") == SlackAPI.message(.api("invalid_auth")), "a failed post reports why")
        check(bridge.postedRootTS == nil, "Failed send cannot reuse a previous post receipt")
        snapshot = bridge.sync(request, now: start.addingTimeInterval(20))
        check(snapshot.status == .failed(SlackAPI.message(.api("invalid_auth"))) && snapshot.threads["CCOW"]?.count == 4, "a refused token is reported and shown threads stay")
        snapshot = bridge.sync(request, now: start.addingTimeInterval(22))
        check(bridge.calls.isEmpty, "a failure is not retried on every pass")
        slack.failure = nil
        snapshot = bridge.sync(request, now: start.addingTimeInterval(40))
        check(snapshot.status == .connected, "reading resumes after the failure clears")
        slack.failure = .rateLimited(60)
        snapshot = bridge.sync(request, now: start.addingTimeInterval(50))
        slack.failure = nil
        _ = bridge.sync(request, now: start.addingTimeInterval(80))
        check(bridge.calls.isEmpty, "a rate limit is waited out")

        // Names
        check(bridge.state.users["UGUEST"] == "손님" && bridge.state.users["UME"] == "알 수 없음", "an unreadable name is skipped without stopping the room")

        // A "생각 중" line whose answer never came does not keep its thread live for good
        let stuck = FakeSlack()
        stuck.history["CCOW"] = [mine("500.0", "오늘 일정", thread: nil)]
        stuck.history["CCOW"]?[0]["reply_count"] = 1; stuck.history["CCOW"]?[0]["latest_reply"] = "501.0"; stuck.history["CCOW"]?[0]["thread_ts"] = "500.0"
        stuck.replies["CCOW:500.0"] = [mine("500.0", "오늘 일정"), bot("501.0", "◐ 생각 중...", thread: "500.0")]
        let lingering = SlackBridge(api: stuck.api)
        let old = Date(timeIntervalSince1970: 501 + SlackBridge.thinkingWindow + 100)
        _ = lingering.sync(request, now: old)
        check(lingering.liveThreads("CCOW", now: old).isEmpty && lingering.watchedThreads("CCOW", now: old).map(\.every) == [SlackBridge.lingerInterval]
              && lingering.watchedThreads("CCOW", now: old.addingTimeInterval(90_000)).map(\.every) == [SlackBridge.longLingerInterval], "a thinking line left standing is looked at now and then, not at every turn")
        var rereads = 0
        for step in 1...80 {
            _ = lingering.sync(request, now: old.addingTimeInterval(Double(step) * 0.75))
            rereads += lingering.calls.filter { $0 == "conversations.replies" }.count
        }
        check(rereads == 1, "in a minute its thread is read once, not at every turn: \(rereads) reads")
        stuck.replies["CCOW:500.0"] = [mine("500.0", "오늘 일정"), bot("501.0", "늦었지만 답이야.", thread: "500.0")]
        var lateAnswer: [String] = []
        for step in 81...170 { lateAnswer = lingering.sync(request, now: old.addingTimeInterval(Double(step) * 0.75)).threads["CCOW"]?.first?.replies.map(\.body) ?? [] }
        check(lateAnswer == ["늦었지만 답이야."] && lingering.watchedThreads("CCOW", now: old.addingTimeInterval(130)).isEmpty, "an answer that was only slow still shows, and the thread is then left alone")

        // A name that could not be read for a passing reason is asked for again
        let flaky = FakeSlack()
        flaky.history["CCOW"] = [bot("100.0", "첫 문의")]
        flaky.unreadable["UCOWBOT"] = .network("시간 초과")
        let patient = SlackBridge(api: flaky.api)
        var reread = patient.sync(request, now: start)
        check(reread.status == .connected && reread.members["CCOW"]?.contains { $0.user == "UCOWBOT" } != true && patient.state.users["UCOWBOT"] == SlackBridge.unknownName, "a name that fails does not stop the rooms, and its owner is left out for now")
        flaky.unreadable = [:]
        reread = patient.sync(request, now: start.addingTimeInterval(SlackBridge.nameWait - 1))
        check(!patient.calls.contains("users.info"), "it is not asked for again at once")
        reread = patient.sync(request, now: start.addingTimeInterval(SlackBridge.nameWait + 1))
        check(reread.members["CCOW"]?.first { $0.user == "UCOWBOT" }?.profile == "sns-manager" && reread.threads["CCOW"]?.first?.root.speaker == "SNS담당", "after a wait it is, and the character is back: \(String(describing: reread.members["CCOW"]))")
        let missingLookups = flaky.userLookups.filter { $0 == "UGONE" }.count
        reread = patient.sync(request, now: start.addingTimeInterval(SlackBridge.nameWait * 10))
        check(flaky.userLookups.filter { $0 == "UGONE" }.count == missingLookups && patient.state.users["UGONE"] == SlackBridge.unknownName, "someone Slack says is not there is not asked for again while DM partners are rechecked")

        // A new post in the ddots channel calls whoever it is for by a real mention
        let jarvis = DdotsMember(profile: "personal-secretary", name: "개인비서", room: "DJ"), cowboy = DdotsMember(profile: "sns-manager", name: "SNS담당", room: "DC"), auditor = DdotsMember(profile: "system-doctor", name: "진단담당", room: "DA")
        let troupe = [jarvis, cowboy, auditor], ids = ["personal-secretary": "UJ", "sns-manager": "UC", "system-doctor": "UA"]
        let inChannel = [SlackMember(profile: "personal-secretary", name: "개인비서", user: "UJ"), SlackMember(profile: "sns-manager", name: "SNS담당", user: "UC"), SlackMember(profile: "", name: "손님", user: "UG")]
        check(Ddots.post("안녕", to: jarvis, cast: troupe, users: ids, members: inChannel, prependCall: false) == DdotsPost(shown: "안녕", sent: "안녕", called: []), "the usual character needs no automatic mention")
        check(Ddots.post("", to: jarvis, cast: troupe, users: ids, members: inChannel, prependCall: false) == DdotsPost(shown: "", sent: "", called: []), "a file alone needs no automatic mention for the usual character")
        check(Ddots.post("@개인비서 안녕", to: jarvis, cast: troupe, users: ids, members: inChannel, prependCall: false).sent == "<@UJ> 안녕", "explicit aliases are converted without an automatic mention")
        check(Ddots.post("내일 일정 알려줘", to: jarvis, cast: troupe, users: ids, members: inChannel) == DdotsPost(shown: "@개인비서 내일 일정 알려줘", sent: "<@UJ> 내일 일정 알려줘", called: ["UJ"]), "a post is sent with the character it is for called in front")
        check(Ddots.post("", to: cowboy, cast: troupe, users: ids, members: inChannel).sent == "<@UC>", "a file sent with no words still calls its character")
        check(Ddots.post("@SNS담당 이거 봐줘", to: jarvis, cast: troupe, users: ids, members: inChannel) == DdotsPost(shown: "@SNS담당 이거 봐줘", sent: "<@UC> 이거 봐줘", called: ["UC"]), "a post that already calls someone is left as typed")
        check(Ddots.post("@손님 확인 부탁해요", to: jarvis, cast: troupe, users: ids, members: inChannel).called == ["UG"], "calling a person in the channel adds no character")
        check(Ddots.post("@개인비서 내일 일정", to: jarvis, cast: troupe, users: ids, members: inChannel) == DdotsPost(shown: "@개인비서 내일 일정", sent: "<@UJ> 내일 일정", called: ["UJ"])
              && Ddots.post("@SNS담당야, 피드 봐줘", to: cowboy, cast: troupe, users: ids, members: inChannel).sent == "<@UC>, 피드 봐줘"
              && Ddots.post("@어둠의 개인비서 메모", to: jarvis, cast: troupe, users: ids, members: inChannel).sent == "<@UJ> 메모", "another name a character answers to becomes the same call")
        check(Ddots.post("@here 다들 봐", to: jarvis, cast: troupe, users: ids, members: inChannel).sent == "<@UJ> @here 다들 봐" && Ddots.post("@SNS담당가 한 말", to: jarvis, cast: troupe, users: ids, members: inChannel).sent == "<@UJ> @SNS담당가 한 말",
              "an @ that calls nobody does not stand in for the call")
        check(Ddots.post("a < b & c", to: jarvis, cast: troupe, users: ids, members: inChannel).sent == "<@UJ> a &lt; b &amp; c" && Ddots.post("<@UC> 흉내", to: jarvis, cast: troupe, users: ids, members: inChannel).called == ["UJ"], "typed marks stay text; only the call is a mention")
        let toAuditor = Ddots.post("토큰 얼마나 썼어?", to: auditor, cast: troupe, users: ids, members: inChannel)
        check(toAuditor.sent == "<@UA> 토큰 얼마나 썼어?" && Ddots.absent(toAuditor, cast: troupe, users: ids, members: inChannel) == auditor, "a character is called by the ID its own conversation gives, and found missing from the channel")
        check(Ddots.absent(toAuditor, cast: troupe, users: ids, members: []) == nil && Ddots.absent(toAuditor, cast: troupe, users: ids, members: [SlackMember(profile: "system-doctor", name: "진단담당")]) == nil
              && Ddots.absent(Ddots.post("안녕", to: jarvis, cast: troupe, users: ids, members: inChannel), cast: troupe, users: ids, members: inChannel) == nil, "nobody is called missing when who is there is not known, or when they are there")
        check(Ddots.post("안녕", to: auditor, cast: troupe, users: [:], members: inChannel) == DdotsPost(shown: "안녕", sent: "안녕", called: []), "without an ID to call by the words go as typed")
        check(DdotsRoute.leadingCall("@개인비서 일정")?.profile == "personal-secretary" && DdotsRoute.leadingCall("@어둠의 개인비서")?.call == "@어둠의 개인비서" && DdotsRoute.leadingCall("@SNS담당야")?.call == "@SNS담당야"
              && DdotsRoute.leadingCall("@SNS담당가") == nil && DdotsRoute.leadingCall("개인비서 일정") == nil && DdotsRoute.leadingCall("@here") == nil, "a call at the front is read under any of a character's names")
        check(Ddots.particle("책상") == "이" && Ddots.particle("나무") == "가" && Ddots.particle("바다") == "가" && Ddots.particle("사람") == "이" && Ddots.particle("Bot") == "이(가)", "the particle follows the name's last sound")

        // A room Slack refuses on its own account rests; the others are read as usual
        let partly = FakeSlack()
        partly.history["CCOW"] = [bot("100.0", "첫 문의")]; partly.history["CTRUTH"] = [bot("50.0", "진실의방 글")]
        partly.refused["CTRUTH"] = "not_in_channel"
        let steady = SlackBridge(api: partly.api)
        var both = steady.sync(request, now: start)
        check(both.status == .connected && both.threads["CCOW"]?.count == 1 && both.threads["CTRUTH"] == nil && both.problems["CTRUTH"] == SlackAPI.message(.api("not_in_channel")) && both.problems["CCOW"] == nil,
              "one room's refusal is said for that room and stops nothing else: \(both.status) \(both.problems)")
        partly.history["CCOW"]?.append(bot("110.0", "다음 문의"))
        both = steady.sync(request, now: start.addingTimeInterval(4))
        check(both.threads["CCOW"]?.count == 2 && both.status == .connected && both.problems["CTRUTH"] != nil, "the other room goes on being read while the refused one rests: \(steady.calls)")
        partly.refused = [:]
        both = steady.sync(request, now: start.addingTimeInterval(SlackBridge.roomRest - 5))
        check(both.threads["CTRUTH"] == nil, "the refused room is left alone until its rest is over")
        both = steady.sync(request, now: start.addingTimeInterval(SlackBridge.roomRest + 1))
        check(both.threads["CTRUTH"]?.count == 1 && both.problems.isEmpty, "then it is read again and its notice goes")
        check(SlackBridge.roomOnly("missing_scope:groups:history") && SlackBridge.roomOnly("channel_not_found") && !SlackBridge.roomOnly("invalid_auth") && !SlackBridge.roomOnly("ratelimited"), "a refused token or a rate limit is never one room's matter")

        // A thread that is gone is not asked for on every pass
        let holed = FakeSlack()
        holed.history["CCOW"] = [bot("200.0", "지워질 스레드", replies: 2, latest: "202.0"), bot("300.0", "남는 글")]
        holed.gone = ["CCOW:200.0"]
        let calm = SlackBridge(api: holed.api)
        var holedView = calm.sync(request, now: start)
        check(holedView.status == .connected && holedView.threads["CCOW"]?.count == 2 && holedView.problems.isEmpty, "a thread that is gone leaves its room as it is")
        holedView = calm.sync(request, now: start.addingTimeInterval(4))
        check(!calm.calls.contains("conversations.replies") && holedView.status == .connected, "and is not asked for again: \(calm.calls)")

        // Rooms beyond the first page of the list are there too
        let many = FakeSlack()
        many.nextPage = [["id": "CHUB", "name": "workspace"]]
        many.history["CHUB"] = [bot("10.0", "채널 글")]
        let paged = SlackBridge(api: many.api).sync(SlackBridge.Request(active: "CHUB", open: true, characters: characters), now: start)
        check(paged.rooms.map(\.id).contains("CHUB") && Ddots.hub(paged.rooms) == "CHUB" && paged.threads["CHUB"]?.count == 1, "a room on the second page is listed and read: \(paged.rooms.map(\.id))")

        // A room taken off the list is not read
        request.skipped = ["CTRUTH", "DJARVIS"]
        let trimmed = SlackBridge(api: slack.api)
        _ = trimmed.sync(request, now: start); _ = trimmed.sync(request, now: start.addingTimeInterval(1))
        check(trimmed.current.threads["CCOW"]?.isEmpty == false && (trimmed.current.threads["CTRUTH"] ?? []).isEmpty && trimmed.current.rooms.count == 3, "skipped rooms stay listed for putting back but are not read")
        request.skipped = []

        // ddots: every character's direct conversation as one room
        let cast = characters + [ChatCharacter(id: "research-assistant", name: "연구담당")]
        let places = [SlackRoom(id: "CCOW", name: "SNS담당방"), SlackRoom(id: "DJ", name: "개인비서", direct: true), SlackRoom(id: "DC", name: "SNS담당", direct: true),
                      SlackRoom(id: "DR", name: "연구담당", direct: true), SlackRoom(id: "DG", name: "손님", direct: true)]
        let who = ["CCOW": [SlackMember(profile: "sns-manager", name: "SNS담당", user: "U1")], "DJ": [SlackMember(profile: "personal-secretary", name: "개인비서", user: "U2")],
                   "DC": [SlackMember(profile: "sns-manager", name: "SNS담당", user: "U1")], "DR": [SlackMember(profile: "research-assistant", name: "연구담당", user: "U3")],
                   "DG": [SlackMember(profile: "", name: "손님", user: "U4")]]
        let ddots = Ddots.rooms(places, members: who)
        check(ddots == ["personal-secretary": "DJ", "sns-manager": "DC"], "only a character's own direct room counts, and the one left out stays out: \(ddots)")
        let withKnight = Ddots.rooms(places + [SlackRoom(id: "DK", name: "보관담당", direct: true)], members: who.merging(["DK": [SlackMember(profile: "archive-helper", name: "보관담당", user: "U5")]]) { first, _ in first })
        check(withKnight == ddots && Ddots.excluded == ["research-assistant", "archive-helper"], "the coordinator is left out for now as well")
        check(Ddots.members(ddots, characters: cast).map(\.profile) == ["personal-secretary", "sns-manager"] && Ddots.members(ddots, characters: cast).map(\.room) == ["DJ", "DC"], "characters come in their usual order")
        func made(_ room: String, _ ts: Double) -> SlackThread {
            let root = ChatMessage(id: "slack:\(room):\(ts)", fromUser: false, speaker: room, body: "x", date: Date(timeIntervalSince1970: ts), profile: "")
            return SlackThread(id: root.id, room: room, ts: String(ts), root: root, replies: [], replyCount: 0, loaded: true, latest: ts, latestFromUser: false)
        }
        let spread = ["DJ": [made("DJ", 10), made("DJ", 40)], "DC": [made("DC", 20)], "CCOW": [made("CCOW", 30)]]
        check(Ddots.merged(spread, rooms: ["DJ", "DC"]).map(\.latest) == [10, 20, 40], "threads from several rooms run in one line of time")
        check(Ddots.merged(spread, rooms: ["CCOW"]).count == 1 && Ddots.merged(spread, rooms: []).isEmpty, "one room is shown as it is")
        var revived = made("DJ", 10); revived.latest = 50
        var pending = made("pending", 1); pending.ts = ""
        var secondPending = made("pending", 0); secondPending.ts = ""
        let activity = Ddots.byActivity([pending, made("DJ", 40), revived, made("DC", 40), secondPending])
        check(activity.map(\.id) == [made("DC", 40).id, made("DJ", 40).id, revived.id, pending.id, secondPending.id],
              "activity uses reply time, breaks ties by ID, and keeps pending posts last in their original order")
        check(Ddots.byActivity([]).isEmpty, "empty activity stays empty")
        // The channel all characters share
        let renamedHub = SlackRoom(id: "CHUB", name: "workspace")
        let legacyHub = SlackRoom(id: "COLD", name: "ddots")
        check(Ddots.room == "ddots" && Ddots.roomName == "workspace", "display name is separate from the stable room ID")
        check(Ddots.hub(places + [renamedHub]) == "CHUB" && Ddots.hub(places) == nil, "the renamed channel is the hub")
        check(Ddots.hub(places + [legacyHub]) == nil, "An unconfigured old channel is not implicitly a hub")
        check(Ddots.hub([legacyHub, renamedHub]) == "CHUB" && Ddots.hub([renamedHub, legacyHub]) == "CHUB", "the renamed channel takes precedence in either order")
        check(Ddots.hub([SlackRoom(id: "DX", name: "workspace", direct: true), SlackRoom(id: "DY", name: "ddots", direct: true)]) == nil, "direct conversations are never the hub")
        check(Ddots.hub([SlackRoom(id: "DX", name: "workspace", direct: true), legacyHub]) == nil, "Only a configured public channel is the hub")
        func inHub(_ ts: Double, _ profile: String, thread: Double? = nil) -> ChatMessage {
            ChatMessage(id: "slack:CHUB:\(ts)", fromUser: profile.isEmpty, speaker: profile, body: "x", date: Date(timeIntervalSince1970: ts), sessionID: String(thread ?? ts), profile: profile)
        }
        let whose = Ddots.owners([inHub(30, "sns-manager", thread: 10), inHub(10, ""), inHub(20, "personal-secretary", thread: 10), inHub(40, ""), inHub(50, "system-doctor")])
        check(whose == ["10.0": "personal-secretary", "50.0": "system-doctor"], "a thread there is the first character's to speak in it, and nobody's until then: \(whose)")
        check(Ddots.addressed("이거 봐줘", to: "진단담당") == "@진단담당 이거 봐줘" && Ddots.addressed("", to: "진단담당") == "@진단담당"
              && SlackMention.outgoing(Ddots.addressed("이거 봐줘", to: "진단담당"), members: [SlackMember(profile: "system-doctor", name: "진단담당", user: "U9")]) == "<@U9> 이거 봐줘",
              "a pressed face is sent as a mention of that character")

        // Threads of the rooms on screen are read first, newest first
        let busy = FakeSlack()
        busy.history["CCOW"] = (1...6).map { ["ts": "10\($0).000001", "user": "UGUEST", "text": "채널 글 \($0)", "reply_count": 1, "thread_ts": "10\($0).000001", "latest_reply": "20\($0).000001"] }
        busy.history["DJARVIS"] = [["ts": "150.000001", "user": "UME", "text": "예전 글", "reply_count": 1, "thread_ts": "150.000001", "latest_reply": "160.000001"],
                                    ["ts": "900.000001", "user": "UME", "text": "새 글", "reply_count": 1, "thread_ts": "900.000001", "latest_reply": "910.000001"]]
        busy.history["CTRUTH"] = []
        busy.replies["DJARVIS:900.000001"] = [["ts": "910.000001", "thread_ts": "900.000001", "user": "UJARVIS", "text": "새 답"]]
        busy.replies["DJARVIS:150.000001"] = [["ts": "160.000001", "thread_ts": "150.000001", "user": "UJARVIS", "text": "예전 답"]]
        let prompt = SlackBridge(api: busy.api)
        let shownFirst = prompt.sync(SlackBridge.Request(active: nil, open: false, watch: ["DJARVIS"], characters: characters), now: start.addingTimeInterval(5000))
        check(shownFirst.threads["DJARVIS"]?.allSatisfy(\.loaded) == true && shownFirst.threads["DJARVIS"]?.last?.replies.map(\.body) == ["새 답"],
              "the threads on screen have their replies after the first pass, whatever else waits: \(String(describing: shownFirst.threads["DJARVIS"]?.map(\.loaded)))")
        check((shownFirst.threads["CCOW"] ?? []).filter(\.loaded).count <= SlackBridge.repliesPerSync, "the other rooms still take their turn a little at a time")

        // What a thread waits on, and whose it is
        func talk(_ lines: [(Bool, String)], room: String = "CX", profile: String = "sns-manager") -> SlackThread {
            let all = lines.enumerated().map { ChatMessage(id: "slack:\(room):\($0.offset)", fromUser: $0.element.0, speaker: $0.element.0 ? "" : "SNS담당", body: $0.element.1, date: Date(timeIntervalSince1970: Double($0.offset)), profile: $0.element.0 ? "" : profile) }
            return SlackThread(id: "slack:\(room):0", room: room, ts: "0", root: all[0], replies: Array(all.dropFirst()), replyCount: all.count - 1, loaded: true, latest: Double(all.count), latestFromUser: all.last?.fromUser ?? false)
        }
        check(SlackNotice.state(talk([(false, "승인하면 이대로 보낼게")]))?.color == SlackNotice.questionColor, "an open question is yellow")
        check(SlackNotice.state(talk([(false, "승인하면 이대로 보낼게"), (true, "승인")]))?.color == SlackNotice.approvedColor && SlackNotice.state(talk([(false, "승인하면 이대로 보낼게"), (true, "네!"), (false, "보냈어")]))?.text == SlackNotice.settledText, "an approved request is green")
        check(SlackNotice.state(talk([(false, "승인하면 이대로 보낼게"), (true, "거부")])) == nil && SlackNotice.state(talk([(false, "그냥 알림이야")])) == nil, "a refusal or a plain post carries neither")
        for originalState: HermesReplyState? in [nil, .asking, .working] {
            var legacy = talk([(false, "🟡 숙박 불가 답장 초안 등록, 승인 대기\n[[버튼: 승인 | 수정 | 보류]]\n────────────────────\n⏱ 3s"),
                               (true, "승인"), (false, "승인받고 보냈어.")])
            legacy.root.hermesReplyState = originalState
            legacy.root.quoteColors = ["#ECB22E", "#E01E5A", "#36C5F0"]
            check(SlackNotice.state(legacy)?.text == SlackNotice.settledText && SlackNotice.hermesState(legacy) == .closed,
                  "A positive answer followed by the bot closes legacy, asking and working questions")
            let displayed = SlackNotice.displayed(legacy, confirmed: [])
            check(displayed.root.quoteColors == [SlackNotice.approvedColor, SlackNotice.approvedColor, "#36C5F0"],
                  "Completed question bars turn green only in presentation")
            check(legacy.root.quoteColors[0] == "#ECB22E" && displayed.root.body == legacy.root.body,
                  "Source conversation and body stay untouched")
            legacy.replies.removeLast()
            check(SlackNotice.hermesState(legacy) != .closed, "Approval alone does not imply completion")
            legacy.replies.append(ChatMessage(id: "new-question", fromUser: false, speaker: "SNS담당", body: "새 초안 승인해줘", date: Date(timeIntervalSince1970: 4)))
            check(SlackNotice.pendingApproval(legacy)?.id == "new-question", "A newer question reopens the thread")
        }
        let reports = ["학습승인이라고 답해줘.", "학습승인으로 답해 줘.", "이 스레드에 `학습승인`, `학습거절`로 답해 줘.", "새로 기억하거나 바꾼 답변 원칙 2건이야.",
                       "배운 일하는 방법 12건이야.", "배워서 바로 반영한 내용 1건이야. 승인하면 확정할게."]
        for body in reports {
            let thread = talk([(false, body)])
            check(SlackNotice.isLearningReport(body) && SlackNotice.pendingApproval(thread) != nil, "learning reports wait for review")
            check(SlackNotice.answerText(thread, approve: true) == "학습승인" && SlackNotice.answerText(thread, approve: false) == "학습거절", "learning words take priority")
            check(SlackNotice.state(thread)?.text == "답을 기다리는 중", "learning review has the question state")
            let confirmed: Set<String> = [thread.root.id]
            check(SlackNotice.pendingApproval(thread, confirmed: confirmed) == nil
                  && SlackNotice.state(thread, confirmed: confirmed) == nil
                  && SlackNotice.isSettled(thread, confirmed: confirmed)
                  && SlackNotice.items([thread], confirmed: confirmed).isEmpty,
                  "confirming a learning report removes its request, state and notice")
            var marked = thread
            marked.root.marks = [ChatMark(color: SlackNotice.questionColor, text: SlackNotice.draft)]
            check(SlackNotice.displayed(marked, confirmed: confirmed).root.marks.isEmpty && !marked.root.marks.isEmpty,
                  "confirmed learning reports hide the old draft mark without changing the source")
            for word in ["학습승인", "학습거절", "2번을 고쳐줘"] {
                let answered = talk([(false, body), (true, word)])
                check(SlackNotice.pendingApproval(answered) == nil, "a user reply ends the pending learning review")
                check((SlackNotice.state(answered)?.text == "승인됨") == (word == "학습승인"), "only a learning approval turns green")
            }
            check(SlackNotice.pendingApproval(talk([(true, body)])) == nil, "user text is not a learning request")
        }
        for body in ["승인 없이 보낸 답장 중 내가 직접 쓴 것 2건이야. 이 스레드에 `학습승인`으로 답해 줘.",
                     "승인하면 보낼게", "평범한 글", "> 답변 원칙 2건이야.\n전달만 했어", "> `학습승인`으로 답해 줘.\n전달했어", "학습승인으로 답했어.", "`학습승인`이라고 답해서 확정했어."] {
            check(!SlackNotice.isLearningReport(body), "not a learning report: \(body)")
        }
        let ordinary = talk([(false, "승인하면 보낼게")])
        check(SlackNotice.answerText(ordinary, approve: true) == "승인" && SlackNotice.answerText(ordinary, approve: false) == "거부", "ordinary approval words stay unchanged")
        let drafts = ["### 안내 메일 초안\n\n> 예약 실행이라 발송하지 않았습니다. 발송은 승인 전입니다.\n> *할 일*\n> 이 초안의 발송을 요청해 주세요.",
                      "회의 안내 메일 초안 만들었어. 아직 안 보냈어.", "메일 초안이야. 발송 대기 중이야."]
        for body in drafts {
            let thread = talk([(false, body)])
            check(SlackNotice.isMailDraft(body) && SlackNotice.pendingApproval(thread) != nil, "a mail draft waiting to go out offers buttons: \(body)")
            check(SlackNotice.answerText(thread, approve: true) == SlackNotice.mailApproveText && SlackNotice.answerText(thread, approve: false) == SlackNotice.mailDenyText, "mail buttons say what to do with the mail")
            check(SlackNotice.state(talk([(false, body), (true, SlackNotice.mailApproveText)]))?.text == "승인됨" && SlackNotice.state(talk([(false, body), (true, "발송해")]))?.text == "승인됨", "sending the mail counts as approval")
            check(SlackNotice.pendingApproval(talk([(false, body), (true, "제목 바꿔줘")])) == nil, "an edit request answers the draft")
        }
        for body in ["안내 메일 초안 그대로 발송했어.", "메일 초안 승인받고 보냈습니다.", "메일 보냈어", "초안은 아직 안 만들었어", "메일 발송 완료. 원래 메일 초안은 승인 전이었어."] {
            check(!SlackNotice.isMailDraft(body), "not a mail draft waiting: \(body)")
        }
        let own = [DdotsMember(profile: "personal-secretary", name: "개인비서", room: "DJ")]
        check(SlackOwner.profile(talk([(true, "안녕")], room: "DJ"), members: own) == "personal-secretary" && SlackOwner.profile(talk([(false, "문의 왔어")]), members: own) == "sns-manager"
              && SlackOwner.profile(talk([(true, "봐줘"), (false, "봤어")]), members: own) == "sns-manager" && SlackOwner.profile(talk([(true, "혼잣말")]), members: own).isEmpty,
              "a thread belongs to its conversation's character, else to who opened it, else to who answered first")
        check(Set(SlackOwner.hex.keys) == ["sns-manager", "personal-secretary", "default", "system-doctor"], "each character in the room has a colour")

        // Direct conversations behind one tab
        let behindTab = Ddots.stacked(places + [SlackRoom(id: "DK", name: "보관담당", direct: true)], pins: ["", "DC", "", "", ""],
                                      members: who.merging(["DK": [SlackMember(profile: "archive-helper", name: "보관담당", user: "U5")]]) { first, _ in first })
        check(behindTab.map(\.id) == ["DJ", "DK", "DR", "DG"], "every direct conversation goes behind the tab, characters first in their usual order, a pinned one left out: \(behindTab.map(\.id))")
        check(Ddots.stacked([SlackRoom(id: "CCOW", name: "SNS담당방")], pins: [], members: [:]).isEmpty, "a channel never does")

        // Watched rooms are read in turn while ddots is on screen
        let turns = FakeSlack()
        for room in ["CCOW", "CTRUTH", "DJARVIS"] { turns.history[room] = [["ts": "100.000001", "user": "UGUEST", "text": room]] }
        let taking = SlackBridge(api: turns.api)
        let turnRequest = SlackBridge.Request(active: nil, open: false, watch: ["CCOW", "CTRUTH", "DJARVIS"], characters: characters)
        // Two watched rooms that were never read go first, and the usual one-room-per-pass rule takes the third.
        let readSoFar = taking.sync(turnRequest, now: start)
        check(Set(readSoFar.threads.keys) == ["CCOW", "CTRUTH", "DJARVIS"], "rooms never read are read right away: \(readSoFar.threads.keys)")
        let slow = SlackBridge(api: turns.api)
        check(slow.sync(SlackBridge.Request(characters: characters), now: start).threads.count == 1, "a room is not listed as empty before it is read")
        _ = taking.sync(turnRequest, now: start.addingTimeInterval(1))
        check(!taking.calls.contains("conversations.history"), "then nothing is read before the next turn")
        var order: [Int] = []
        for step in 0..<40 { _ = taking.sync(turnRequest, now: start.addingTimeInterval(2 + Double(step) * 0.75)); order.append(taking.calls.filter { $0 == "conversations.history" }.count) }
        check(order.reduce(0, +) <= 16 && order.max() == 1, "one watched room at a time, about every two seconds: \(order.reduce(0, +)) in thirty seconds")

        // The listing of rooms keeps inside what Slack allows, whatever is on screen
        let crowd = FakeSlack()
        crowd.nextPage = (1...14).map { ["id": "CMORE\($0)", "name": "방\($0)"] }
        for room in ["CCOW", "CTRUTH", "DJARVIS"] + (1...14).map({ "CMORE\($0)" }) { crowd.history[room] = [["ts": "100.000001", "user": "UGUEST", "text": room]] }
        let paced = SlackBridge(api: crowd.api)
        let pacedRequest = SlackBridge.Request(active: nil, open: false, watch: ["CCOW"], characters: characters)
        var pacedLog: [(at: Double, rooms: [String])] = []
        func pacedSync(_ seconds: Double) {
            let before = crowd.historyLog.count
            _ = paced.sync(pacedRequest, now: start.addingTimeInterval(seconds))
            pacedLog.append((seconds, Array(crowd.historyLog[before...])))
        }
        func listings(_ from: Double, _ to: Double, of room: String? = nil) -> Int {
            pacedLog.filter { $0.at > from && $0.at <= to }.reduce(0) { $0 + $1.rooms.filter { room == nil || $0 == room }.count }
        }
        for step in 0..<360 { pacedSync(Double(step) * 0.75) }
        check((0..<210).allSatisfy { listings(Double($0), Double($0) + 60) <= SlackBridge.historyPerMinute }, "no minute holds more listings than the allowance: \(listings(120, 180))")
        check(listings(120, 180, of: "CCOW") >= 19, "the room on screen is read at its own pace all the same: \(listings(120, 180, of: "CCOW"))")
        check(listings(120, 180) - listings(120, 180, of: "CCOW") >= SlackBridge.backgroundHistory - 2, "and the other rooms take what is theirs: \(listings(120, 180))")
        // A refusal for pace halves every allowance, and it comes back a step at a time.
        func paceLine() -> String { paced.diagnostics(room: "CCOW").split(separator: "\n").first { $0.hasPrefix("pace:") }.map(String.init) ?? "" }
        check(paceLine().hasPrefix("pace: level=1.0 history_last_minute="), "the pace is written down: \(paceLine())")
        crowd.failure = .rateLimited(20)
        var refusedAt = 270.0
        while paced.pace("conversations.history") == 1 { refusedAt += 0.75; pacedSync(refusedAt) }
        pacedSync(refusedAt + 0.75)
        check(pacedLog.last?.rooms.isEmpty == true, "nothing is asked while Slack says to wait")
        crowd.failure = nil
        check(paced.pace("conversations.history") == 0.5 && paceLine().contains("refused_last_hour=1 conversations.history=1 last=conversations.history"), "a refusal is counted with what was asked: \(paceLine())")
        let resumed = refusedAt + 21
        for step in 0..<240 { pacedSync(resumed + Double(step) * 0.75) }
        check((0..<119).allSatisfy { listings(resumed + Double($0), resumed + Double($0) + 60) <= SlackBridge.historyPerMinute / 2 }, "after a refusal half as many are asked for: \(listings(resumed + 60, resumed + 120))")
        check(listings(resumed + 60, resumed + 120) >= SlackBridge.historyPerMinute / 2 - 3 && listings(resumed + 60, resumed + 120, of: "CCOW") >= 10,
              "and reading goes on at that pace, on screen first: \(listings(resumed + 60, resumed + 120)) \(listings(resumed + 60, resumed + 120, of: "CCOW"))")
        pacedSync(refusedAt + SlackBridge.paceRest + 1)
        check(paced.pace("conversations.history") == 0.75, "the pace comes back a step after a quiet while: \(paced.pace("conversations.history"))")
        pacedSync(refusedAt + SlackBridge.paceRest * 3)
        check(paced.pace("conversations.history") == 0.75, "but not to the pace Slack refused: \(paced.pace("conversations.history"))")
        pacedSync(refusedAt + SlackBridge.paceMemory + SlackBridge.paceRest * 4)
        check(paced.pace("conversations.history") == 1, "until that is long past: \(paced.pace("conversations.history"))")

        // The ddots record: a line per message, a file per month, a later line standing for a changed message
        let shelf = DdotsArchive(root: FileManager.default.temporaryDirectory.appendingPathComponent("ddots-record-test-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: shelf.root) }
        let folders = ["personal-secretary": "개인비서", "sns-manager": "SNS담당"]
        let october = 1_791_000_000.0, september = october - 20 * 86_400
        func said(_ ts: Double, _ text: String, thread: Double? = nil, mine: Bool = false, room: String = "DJ") -> ChatMessage {
            ChatMessage(id: "slack:\(room):\(ts)", fromUser: mine, speaker: mine ? "" : "개인비서", body: text, date: Date(timeIntervalSince1970: ts),
                        sessionID: String(thread ?? ts), profile: mine ? "" : "personal-secretary")
        }
        var withFile = said(october + 30, "자료야")
        withFile.files = [ChatFile(id: "F1", name: "보고서.pdf", mimetype: "application/pdf", size: 1200, url: "https://files.slack.com/a.pdf"),
                          ChatFile(id: "F2", name: "큰 영상.mov", mimetype: "video/quicktime", size: SlackFileStore.largest + 1, url: "https://files.slack.com/b.mov")]
        withFile.marks = [ChatMark(color: "#2EB67D", text: "답변 완료")]
        let recordSpoken = [said(september, "지난달 글", mine: true), said(october, "첫 글", mine: true), said(october + 10, "답이야", thread: october), withFile]
        let written = recordSpoken.compactMap { DdotsLine($0, profile: "personal-secretary", names: folders) }
        check(written.count == 4 && written[2].thread == String(october) && written[2].name == "개인비서" && written[0].mine && written[0].name.isEmpty, "a message is written down with its thread and who said it")
        let keptPaths: [String] = written[3].files.map { $0.path }
        let expectedPath: String = "파일/개인비서/" + shelf.fileURL(written[3].files[0].path).lastPathComponent
        check(keptPaths == [expectedPath, ""] && expectedPath.hasSuffix(" 보고서 (F1).pdf"), "a file gets its place in the record unless it is too large to keep: \(keptPaths)")
        var twoShots = said(october + 31, "화면 두 장")
        twoShots.files = [ChatFile(id: "FA1", name: "image.png", mimetype: "image/png", size: 10, url: "https://files.slack.com/1.png"), ChatFile(id: "FA2", name: "image.png", mimetype: "image/png", size: 10, url: "https://files.slack.com/2.png")]
        let shotPaths = DdotsLine(twoShots, profile: "personal-secretary", names: folders)?.files.map(\.path) ?? []
        check(shotPaths.count == 2 && shotPaths[0] != shotPaths[1] && DdotsArchive.filePath(name: "개인비서", file: "image.png", id: "", date: twoShots.date).hasSuffix(" image.png"),
              "two files of one name in one message each get a place: \(shotPaths)")
        check(written[3].marks == [DdotsLine.Mark(color: "#2EB67D", text: "답변 완료")], "a status is written with its message")
        check(DdotsLine(said(october + 40, "◐ 생각 중..."), profile: "personal-secretary", names: folders) == nil, "a thinking line is not a message yet")
        var pendingLine = said(october + 50, "보내는 중", mine: true); pendingLine.pending = true
        check(DdotsLine(pendingLine, profile: "personal-secretary", names: folders) == nil && DdotsLine(ChatMessage(id: "slack-pending:x", fromUser: true, speaker: "", body: "x", date: Date()), profile: "personal-secretary", names: folders) == nil,
              "nothing is written for a line still being sent")
        let sharedLine = DdotsLine(said(october + 60, "채널에서 한 말", room: "CHUB"), profile: "personal-secretary", names: folders, hub: true)
        check(sharedLine?.hub == true && written.allSatisfy { $0.hub == nil }, "a line said in the channel is marked as such")
        let apart = [written[1], written[2]] + (sharedLine.map { [$0] } ?? [])
        check(DdotsLine.threads(apart.filter { $0.hub ?? false }, room: "CHUB", archive: shelf).map(\.id) == ["slack:CHUB:\(october + 60)"]
              && DdotsLine.threads(apart.filter { !($0.hub ?? false) }, room: "DJ", archive: shelf).count == 1, "and is read back as a thread of the channel")
        var pen = DdotsWriter()
        var fresh = pen.fresh(written)
        check(fresh.count == 4 && pen.fresh(written).isEmpty, "each message is written once")
        do { try shelf.append(fresh, names: folders) } catch { check(false, "the record can be written: \(error)") }
        var changed = written[2]; changed.text = "고친 답이야"
        fresh = pen.fresh([changed, written[1]])
        check(fresh == [changed], "a changed message is written again, an unchanged one is not")
        try? shelf.append(fresh, names: folders)
        try? shelf.append([DdotsLine(said(october + 5, "SNS담당 글", room: "DC"), profile: "sns-manager", names: folders)!], names: folders)
        let months = shelf.months()
        check(months.count == 2 && months == months.sorted() && DdotsArchive.previous(months[1]) == months[0], "months are listed oldest first: \(months)")
        check(FileManager.default.fileExists(atPath: shelf.recordURL(name: "개인비서", month: months[1]).path) && FileManager.default.fileExists(atPath: shelf.recordURL(name: "SNS담당", month: months[1]).path),
              "each character has a folder and each month a file")
        try? "not a line\n".data(using: .utf8)!.write(to: shelf.recordURL(name: "SNS담당", month: months[1]).deletingLastPathComponent().appendingPathComponent("\(months[1]).jsonl.broken"))
        if let handle = try? FileHandle(forWritingTo: shelf.recordURL(name: "SNS담당", month: months[1])) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("{broken\n".utf8)); try? handle.close() }
        let back = shelf.read(month: months[1])
        check(back.count == 4 && back.map(\.text) == ["첫 글", "SNS담당 글", "고친 답이야", "자료야"], "a month reads back in order, the later line standing and a broken line passed over: \(back.map(\.text))")
        var reopened = DdotsWriter(back)
        check(reopened.fresh([changed]).isEmpty && reopened.fresh([written[2]]).count == 1, "what is already written is known after a restart")
        let regrouped = DdotsLine.threads(back.filter { $0.profile == "personal-secretary" }, room: "DNEW", archive: shelf)
        check(regrouped.count == 2 && regrouped[0].id == "slack:DNEW:\(october)" && regrouped[0].replies.map(\.body) == ["고친 답이야"] && regrouped[0].root.fromUser && regrouped[0].loaded && !regrouped[0].latestFromUser,
              "lines become threads of the room that reaches the character now")
        check(regrouped[1].root.files.first?.url == shelf.fileURL(written[3].files[0].path).absoluteString && regrouped[1].root.files.last?.url == "" && regrouped[1].root.marks.first?.text == "답변 완료",
              "a kept file opens from the record")
        let orphan = DdotsLine.threads([written[2]], room: "DNEW", archive: shelf)
        check(orphan.count == 1 && orphan[0].root.body == "답이야" && orphan[0].replies.isEmpty, "a reply whose first message was never kept still shows")
        let live = [made("DNEW", october + 500)]
        var sending = made("DNEW", 0); sending.ts = ""
        check(Ddots.joined(live: live + [sending], kept: regrouped + live).map(\.ts) == [String(october), String(october + 30), String(october + 500), ""], "kept threads go ahead of what Slack shows, each thread once, a line being sent last")
        check(Ddots.joined(live: live, kept: []) == live, "with nothing kept the room is as Slack shows it")
        var notHanded = regrouped[0]; notHanded.replies = []; notHanded.loaded = false; notHanded.replyCount = 1
        let filledIn = Ddots.joined(live: [notHanded], kept: regrouped)
        let filledBodies: [String] = filledIn.first?.replies.map { $0.body } ?? []
        check(filledIn.first?.loaded == true && filledBodies == ["고친 답이야"] && filledIn.count == 2,
              "a thread Slack has not handed its replies over for shows the ones the record holds")
        var handed = regrouped[0]; handed.replies = []; handed.loaded = true
        check(Ddots.joined(live: [handed], kept: regrouped).first?.replies.isEmpty == true, "once Slack has handed them over, what Slack says stands")
        // A month's file is only ever added to
        let monthFile = shelf.recordURL(name: "개인비서", month: months[1])
        let before = (try? Data(contentsOf: monthFile)) ?? Data()
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: monthFile.path)
        let late = DdotsLine(said(october + 70, "늦게 적는 글", mine: true), profile: "personal-secretary", names: folders)!
        let other = DdotsLine(said(october + 71, "SNS담당에게 한 글", mine: true, room: "DC"), profile: "sns-manager", names: folders)!
        var refused: DdotsArchive.Unwritten?
        do { try shelf.append([late, other], names: folders) } catch let failure as DdotsArchive.Unwritten { refused = failure } catch {}
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: monthFile.path)
        check(refused?.lines == [late] && refused?.reason.isEmpty == false && (try? Data(contentsOf: monthFile)) == before && shelf.read(month: months[1]).contains { $0.text == "SNS담당에게 한 글" },
              "a file that cannot be opened is left as it is and its lines are handed back, the rest are written: \(String(describing: refused?.lines.map(\.text)))")
        var future = late; future.ts = "9"; future.at = 1_925_000_000
        let futureMonth = DdotsArchive.month(Date(timeIntervalSince1970: future.at))
        let away = monthFile.deletingLastPathComponent().appendingPathComponent(".\(futureMonth).jsonl.icloud")
        try? Data().write(to: away)
        check((try? shelf.append([future], names: folders)) == nil && !FileManager.default.fileExists(atPath: shelf.recordURL(name: "개인비서", month: futureMonth).path), "a month iCloud has put away is not started anew")
        try? FileManager.default.removeItem(at: away)
        if let handle = try? FileHandle(forWritingTo: monthFile) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data("{\"cut\":".utf8)); try? handle.close() }
        try? shelf.append([late], names: folders)
        check(shelf.read(month: months[1]).contains { $0.text == "늦게 적는 글" }, "a line cut short by a crash does not swallow the next one")

        // What waits to be written: one line for each message, the newest version last
        var older = late; older.text = "먼저 쓴 글"
        var backlog = DdotsBacklog()
        backlog.add([older, other]); backlog.add([late])
        check(backlog.lines == [other, late], "a newer version takes the place of one still waiting")
        let taken = backlog.take()
        backlog.add([late]); backlog.putBack([older, other])
        check(taken == [other, late] && backlog.lines == [other, late] && !backlog.isEmpty, "lines that could not be written go back in front, but not over a newer version: \(backlog.lines.map(\.text))")

        // Starting again: only the newest months are read back, and a line of an older one waits until its month is read
        var third = late; third.ts = "8"; third.at = october + 40 * 86_400; third.text = "다음 달 글"
        try? shelf.append([third], names: folders)
        let allMonths = shelf.months()
        let startMonths = DdotsArchive.atStart(allMonths)
        check(allMonths.count == 3 && startMonths == Array(allMonths.suffix(2)), "the newest two months are read at start: \(allMonths)")
        let everything = allMonths.flatMap { shelf.read(month: $0) }
        var restarted = DdotsWriter(startMonths.flatMap { shelf.read(month: $0) }, unread: Set(allMonths).subtracting(startMonths))
        let heldBack = everything.filter { restarted.waits($0) }
        check(heldBack.map { $0.text } == ["지난달 글"] && restarted.fresh(everything.filter { !restarted.waits($0) }).isEmpty,
              "a line of a month not read back waits, and the rest is not written again: \(heldBack.map { $0.text })")
        restarted.learn(shelf.read(month: allMonths[0]), months: [allMonths[0]])
        check(restarted.unread.isEmpty && !everything.contains { restarted.waits($0) } && restarted.fresh(everything).isEmpty,
              "once its month is read back the heldBack line is known and nothing is written twice")
        var edited = third; edited.text = "다음 달 글 고침"
        check(restarted.fresh([edited]) == [edited], "a changed message is written again")
        restarted.learn(shelf.read(month: allMonths[2]), months: [allMonths[2]])
        check(restarted.fresh([edited]).isEmpty, "reading a month back does not stand over what was written since")
        // Months read further back are let go again, down to the newest two
        let held = Dictionary(grouping: everything, by: { (line: DdotsLine) in line.profile })
        let letGo = DdotsArchive.newest(held, months: allMonths)
        check(letGo?.months == startMonths && letGo?.kept.values.flatMap { $0 }.contains { $0.text == "지난달 글" } == false
              && letGo?.kept.values.flatMap { $0 }.count == everything.count - 1 && DdotsArchive.newest(held, months: startMonths) == nil
              && DdotsArchive.newest(held, months: allMonths, from: allMonths[0]) == nil && DdotsArchive.newest(held, months: allMonths, from: allMonths[2])?.months == [allMonths[2]],
              "only the months from the first one read at start stay in memory; with none before it there is nothing to let go")
        check(DdotsArchive.shows(allMonths[2], read: startMonths) && DdotsArchive.shows(allMonths[1], read: startMonths) && !DdotsArchive.shows(allMonths[0], read: startMonths)
              && DdotsArchive.shows("1999-01", read: []) && DdotsArchive.shows("2099-01", read: startMonths), "a line of a month not read yet does not pass for that month")

        // The record's files: fetched once, tried again later when that failed
        var fetches = DdotsFetches()
        let begun = Date(timeIntervalSince1970: october)
        let wantedFile = DdotsFetches.Item(path: "파일/개인비서/a (F1).pdf", from: URL(string: "https://files.slack.com/a.pdf")!, old: "파일/개인비서/a.pdf")
        check(fetches.isNew(wantedFile.path) && !fetches.isNew(""), "a file not seen yet is new; a file too large to keep has no place")
        fetches.want(wantedFile)
        check(!fetches.isNew(wantedFile.path) && fetches.due(now: begun) == [wantedFile] && fetches.due(now: begun).isEmpty, "a file is asked for once while it is on its way")
        fetches.finish(wantedFile.path, saved: false, now: begun)
        check(fetches.due(now: begun.addingTimeInterval(DdotsFetches.firstWait - 1)).isEmpty && fetches.due(now: begun.addingTimeInterval(DdotsFetches.firstWait)) == [wantedFile], "one that failed is tried again after a wait")
        fetches.finish(wantedFile.path, saved: false, now: begun)
        check(fetches.due(now: begun.addingTimeInterval(DdotsFetches.firstWait * 2 - 1)).isEmpty && fetches.due(now: begun.addingTimeInterval(DdotsFetches.firstWait * 2)) == [wantedFile], "and after a longer one the next time")
        fetches.finish(wantedFile.path, saved: true, now: begun)
        fetches.want(wantedFile)
        check(!fetches.isNew(wantedFile.path) && fetches.due(now: begun.addingTimeInterval(86_400)).isEmpty, "once it is in its place it is not fetched again")

        try? shelf.writeCast([.init(profile: "personal-secretary", name: "개인비서", user: "U2")])
        check(shelf.readCast() == [.init(profile: "personal-secretary", name: "개인비서", user: "U2")] && DdotsArchive(root: shelf.root.appendingPathComponent("none")).readCast().isEmpty, "who is in ddots is kept beside the record")

        // Reading back through a room for the record
        let past = FakeSlack()
        past.history["DJARVIS"] = [["ts": "900.000001", "user": "UME", "text": "새 첫 글"], ["ts": "500.000001", "user": "UME", "text": "예전 첫 글", "reply_count": 2, "thread_ts": "500.000001", "latest_reply": "950.000001"],
                                   ["ts": "400.000001", "user": "UME", "text": "더 예전 글", "reply_count": 1, "thread_ts": "400.000001", "latest_reply": "450.000001"],
                                   ["ts": "300.000001", "subtype": "assistant_app_thread", "text": "", "reply_count": 1, "thread_ts": "300.000001", "latest_reply": "920.000001"]]
        past.replies["DJARVIS:500.000001"] = [["ts": "500.000001", "user": "UME", "text": "예전 첫 글"], ["ts": "510.000001", "thread_ts": "500.000001", "user": "UJARVIS", "text": "예전 답"],
                                              ["ts": "950.000001", "thread_ts": "500.000001", "user": "UJARVIS", "text": "새 답"]]
        past.replies["DJARVIS:300.000001"] = [["ts": "920.000001", "thread_ts": "300.000001", "user": "UJARVIS", "text": "예전 방식 대화의 새 답"]]
        let reader = SlackBridge(api: past.api)
        var backRequest = SlackBridge.Request(scan: ["DJARVIS": 800], characters: characters)
        _ = reader.sync(backRequest, now: start)
        var found = reader.takeScanned()
        check(found.through.isEmpty && found.messages["DJARVIS"]?.map(\.body) == ["새 첫 글"], "a scan first takes the first messages newer than the record: \(String(describing: found.messages["DJARVIS"]?.map(\.body)))")
        _ = reader.sync(backRequest, now: start.addingTimeInterval(1))
        found = reader.takeScanned()
        check(found.messages["DJARVIS"]?.map(\.body) == ["새 답", "예전 방식 대화의 새 답"] && found.through["DJARVIS"] == start.timeIntervalSince1970,
              "then only threads that hold something newer are opened, and the room is read through as of when the scan began: \(String(describing: found.messages["DJARVIS"]?.map(\.body)))")
        check(found.messages["DJARVIS"]?.first?.sessionID == "500.000001", "a reply keeps the thread it belongs to")
        _ = reader.sync(backRequest, now: start.addingTimeInterval(20))
        found = reader.takeScanned()
        check(found.through.isEmpty && found.messages.isEmpty, "a finished scan is not run again")
        backRequest.scan = ["DJARVIS": start.timeIntervalSince1970]
        _ = reader.sync(backRequest, now: start.addingTimeInterval(40))
        check(reader.takeScanned().through["DJARVIS"] == start.timeIntervalSince1970 + 40, "a later scan from where the last one began finds nothing new and finishes")

        // Expectations are generated by the independent Hermes Python router.
        let routeSamples = DdotsConfig.shared.document["routing_samples"] as? [[String:String]] ?? []
        check(routeSamples.count >= 30, "The oracle corpus is present")
        for row in routeSamples {
            let text = row["text"]!
            check(DdotsRoute.decide(text).profile == row["base"], "Base contract: " + text)
            check(DdotsRoute.preview(text).profile == row["hub"], "Hub contract: " + text)
        }

        // A single own post deletes only its ts, even if replies arrive after the UI snapshot.
        do {
            let fake = FakeSlack()
            fake.history["CCOW"] = [mine("100.0", "가짜 낱개 글"), bot("200.0", "가짜 봇 글")]
            fake.replies["CCOW:100.0"] = [mine("100.0", "가짜 낱개 글"), bot("110.0", "뒤늦은 답", thread: "100.0")]
            let bridge = SlackBridge(api: fake.api)
            let request = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
            let now = Date(timeIntervalSince1970: 80_000)
            _ = bridge.sync(request, now: now)
            bridge.delete(room: "CCOW", ts: "200.0", singleOnly: true)
            bridge.delete(room: "OTHER", ts: "100.0", singleOnly: true)
            check(bridge.current.removing.isEmpty, "Single deletion refuses bot and unknown channel")
            bridge.delete(room: "CCOW", ts: "100.0", singleOnly: true)
            _ = bridge.sync(request, now: now.addingTimeInterval(2))
            check(fake.deleted == ["100.0"], "Only own single ts deleted; late reply untouched")
        }

        // Deleting a thread from Slack
        do {
            let wipe = FakeSlack()
            wipe.history["CCOW"] = [bot("100.0", "지울 문의", replies: 3, latest: "130.0"), bot("200.0", "남길 문의", replies: 1, latest: "210.0")]
            wipe.replies["CCOW:100.0"] = [bot("100.0", "지울 문의"), bot("110.0", "초안", thread: "100.0"), mine("120.0", "승인", thread: "100.0"), bot("130.0", "보냈어", thread: "100.0")]
            wipe.replies["CCOW:200.0"] = [bot("200.0", "남길 문의"), bot("210.0", "답", thread: "200.0")]
            let wiper = SlackBridge(api: wipe.api)
            let wipeRequest = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
            let wipeStart = Date(timeIntervalSince1970: 70_000)
            var wipeView = wiper.sync(wipeRequest, now: wipeStart)
            wiper.delete(room: "CCOW", ts: "100.0"); wiper.delete(room: "CCOW", ts: "100.0")
            wipeView = wiper.sync(wipeRequest, now: wipeStart.addingTimeInterval(1))
            check(wipe.deleted.isEmpty && wipeView.removing["slack:CCOW:100.0"] == SlackBridge.Removal(done: 0, total: 4), "first the whole thread is counted, and nothing is gone yet")
            wipeView = wiper.sync(wipeRequest, now: wipeStart.addingTimeInterval(2))
            wipeView = wiper.sync(wipeRequest, now: wipeStart.addingTimeInterval(2.5))
            check(wipe.deleted == ["130.0"] && wipeView.removing["slack:CCOW:100.0"]?.done == 1, "then a message at a time, no faster than Slack allows: \(wipe.deleted)")
            for step in 0..<6 { wipeView = wiper.sync(wipeRequest, now: wipeStart.addingTimeInterval(4 + Double(step) * 1.5)) }
            check(wipe.deleted == ["130.0", "110.0", "120.0", "100.0"], "others' messages go first, then mine, and the first message last: \(wipe.deleted)")
            check(wipeView.removing.isEmpty && wipeView.threads["CCOW"]?.map(\.ts) == ["200.0"] && wiper.state.replies["CCOW"]?["100.0"] == nil, "and the thread is gone from the room")
            let ended = (0..<12).map { wiper.sync(wipeRequest, now: wipeStart.addingTimeInterval(20 + Double($0))).removed.count }
            check(wipe.deleted.count == 4 && ended.allSatisfy { $0 == 0 }, "nothing more is deleted afterwards")

            let held = FakeSlack()
            held.history["CCOW"] = [bot("100.0", "남의 글", replies: 2, latest: "120.0")]
            held.replies["CCOW:100.0"] = [bot("100.0", "남의 글"), mine("110.0", "내 답", thread: "100.0"), bot("120.0", "봇 답", thread: "100.0")]
            held.undeletable = ["120.0", "100.0"]
            let holder = SlackBridge(api: held.api)
            _ = holder.sync(wipeRequest, now: wipeStart)
            holder.delete(room: "CCOW", ts: "100.0")
            var stopped: [String: String?] = [:]
            for step in 1...6 { let view = holder.sync(wipeRequest, now: wipeStart.addingTimeInterval(Double(step) * 1.5)); stopped.merge(view.removed) { _, new in new }; wipeView = view }
            check(held.deleted == ["120.0"] && (stopped["slack:CCOW:100.0"] ?? nil)?.contains("관리자") == true && wipeView.removing.isEmpty,
                  "a message that may not be deleted stops it before anything of mine is gone, and says why: \(held.deleted) \(stopped)")
            check(wipeView.threads["CCOW"]?.first?.replies.count == 2 && wipeView.status == .connected, "the thread stays as it is and the room is read as usual")

            let vanished = FakeSlack()
            vanished.history["CCOW"] = [bot("200.0", "남은 글")]
            vanished.gone = ["CCOW:50.0"]
            let sweeper = SlackBridge(api: vanished.api)
            _ = sweeper.sync(wipeRequest, now: wipeStart)
            sweeper.delete(room: "CCOW", ts: "50.0")
            var swept: [String: String?] = [:]
            for step in 1...4 { swept.merge(sweeper.sync(wipeRequest, now: wipeStart.addingTimeInterval(Double(step) * 1.5)).removed) { _, new in new } }
            check(vanished.deleted == ["50.0"] && swept.keys.contains("slack:CCOW:50.0") && (swept["slack:CCOW:50.0"] ?? nil) == nil, "a thread Slack no longer has counts as deleted: \(swept)")
        }

        // Where a Slack address of the workspace points
        do {
            func place(_ address: String) -> String? { URL(string: address).flatMap { SlackCopy.place(of: $0, workspace: "https://team.slack.test/") }.map { $0.room + " " + $0.ts } }
            check(place("https://team.slack.test/archives/CCOW/p1791000000123456?thread_ts=1791000000.123456&cid=CCOW") == "CCOW 1791000000.123456", "a thread's address gives its room and stamp")
            check(place("https://team.slack.test/archives/CCOW/p1791000500000100?thread_ts=1791000000.123456&cid=CCOW") == "CCOW 1791000000.123456", "a reply's address gives the thread it is in")
            check(place("https://team.slack.test/archives/CCOW/p1791000000123456") == "CCOW 1791000000.123456", "an address with no thread named is the message's own")
            check(place("https://other.slack.test/archives/CCOW/p1791000000123456") == nil && place("https://team.slack.test/files/U1/F1/a.png") == nil
                  && place("https://team.slack.test/archives/CCOW/p12") == nil && place("https://team.slack.test/archives/CCOW/pabcdefgh") == nil
                  && place("https://m.place.naver.com/restaurant/1/menu") == nil, "another workspace, a file or any other address is not a thread here")
            check(SlackCopy.link(workspace: "https://team.slack.test/", room: "CCOW", ts: "1791000000.123456").flatMap(place) == "CCOW 1791000000.123456", "the link this app copies leads back to its thread")
        }

        // A thread that has settled is read less often, and a repaint seen in the listing needs no reading
        do {
            let pace = FakeSlack()
            let begun = Date(timeIntervalSince1970: 50_000)
            func stamp(_ offset: Double) -> String { String(format: "%.6f", begun.timeIntervalSince1970 + offset) }
            var noticed = broadcast(stamp(-1), thread: stamp(-5))
            noticed["attachments"] = [["color": "#ECB22E", "text": "초안 올려놨어. 승인 기다리는 중"]]
            pace.history["CCOW"] = [bot(stamp(-5), "문의", replies: 1, latest: stamp(-1)), noticed]
            pace.replies["CCOW:" + stamp(-5)] = [bot(stamp(-5), "문의"), noticed]
            let pacer = SlackBridge(api: pace.api)
            let paceRequest = SlackBridge.Request(active: "CCOW", open: true, characters: characters)
            var paceView = pacer.sync(paceRequest, now: begun)
            check(pacer.watchedThreads("CCOW", now: begun.addingTimeInterval(3)).map(\.every) == [SlackBridge.liveInterval], "a thread that has just changed is read at every turn")
            check(pacer.watchedThreads("CCOW", now: begun.addingTimeInterval(30)).map(\.every) == [SlackBridge.calmInterval] && pacer.liveThreads("CCOW", now: begun.addingTimeInterval(30)) == [stamp(-5)],
                  "once nothing has changed for a while it is read less often, and its room is still watched")
            for step in 1...80 { paceView = pacer.sync(paceRequest, now: begun.addingTimeInterval(Double(step) * 0.75)) }
            let settled = pace.replyLog.count
            check(settled <= 20, "a settled thread costs a fraction of what reading it at every turn would: \(settled)")
            pace.replies["CCOW:" + stamp(-5)]?.append(bot(stamp(61), "이어 쓰는 답", thread: stamp(-5)))
            pace.history["CCOW"]?[0]["latest_reply"] = stamp(61); pace.history["CCOW"]?[0]["reply_count"] = 2
            paceView = pacer.sync(paceRequest, now: begun.addingTimeInterval(64))
            check(pacer.watchedThreads("CCOW", now: begun.addingTimeInterval(66)).map(\.every) == [SlackBridge.liveInterval], "a change puts it back to every turn")
            check(pacer.watchedThreads("CCOW", now: begun.addingTimeInterval(300)).isEmpty, "and after the window it is left alone")
            let before = pace.replyLog.count
            noticed["attachments"] = [["color": "#2EB67D", "text": "답변 완료"]]
            pace.history["CCOW"]?[1] = noticed
            paceView = pacer.sync(paceRequest, now: begun.addingTimeInterval(400))
            check(pace.replyLog.count == before && paceView.threads["CCOW"]?.first?.replies.first?.marks.map(\.text) == ["답변 완료"],
                  "a channel reply repainted in the listing is repainted in its thread without reading the thread: \(String(describing: paceView.threads["CCOW"]?.first?.replies.first?.marks))")
        }

        // What a run keeps on this Mac for the next start
        do {
            let shelfFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-slack-cache-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: shelfFolder) }
            let keptFile = shelfFolder.appendingPathComponent(SlackCache.fileName)
            func stocked() -> FakeSlack {
                let fake = FakeSlack()
                fake.history["CCOW"] = (1...5).map { bot("15\($0).0", "밀린 문의 \($0)", replies: 1, latest: "16\($0).0") } + [bot("200.0", "새 문의"), broadcast("300.0", thread: "100.0")]
                for index in 1...5 { fake.replies["CCOW:15\(index).0"] = [bot("15\(index).0", "밀린 문의 \(index)"), bot("16\(index).0", "밀린 답", thread: "15\(index).0")] }
                fake.replies["CCOW:100.0"] = [oldRoot, broadcast("300.0", thread: "100.0")]
                fake.history["CTRUTH"] = (1...3).map { bot("5\($0).0", "다른 방 글 \($0)", replies: 1, latest: "6\($0).0") }
                for index in 1...3 { fake.replies["CTRUTH:5\(index).0"] = [bot("5\(index).0", "다른 방 글 \(index)"), bot("6\(index).0", "다른 방 답", thread: "5\(index).0")] }
                return fake
            }
            let keeping = stocked()
            let keepTime = Date(timeIntervalSince1970: 20_000)
            let closedRequest = SlackBridge.Request(active: "CCOW", open: false, characters: characters)
            let writer = SlackBridge(api: keeping.api, cache: keptFile)
            check(writer.restore(characters: characters, now: keepTime) == nil, "with nothing kept a start is what it always was")
            var keptView = SlackBridge.Snapshot()
            for step in 0..<12 { keptView = writer.sync(closedRequest, now: keepTime.addingTimeInterval(Double(step))) }
            check(keeping.replyLog.first { $0.hasPrefix("CCOW:") } == "CCOW:100.0", "with the window closed the chosen room's older thread is read before its other threads: \(keeping.replyLog)")
            check(keeping.replyLog.count == 9 && Set(keeping.replyLog).count == 9, "every thread is read once: \(keeping.replyLog)")
            check(keptView.threads["CCOW"]?.last?.ts == "100.0" && keptView.threads["CCOW"]?.last?.position == Date(timeIntervalSince1970: 300), "the older thread stands at its channel reply's time")
            writer.flush(now: keepTime.addingTimeInterval(12))
            let keptMode = (try? FileManager.default.attributesOfItem(atPath: keptFile.path))?[.posixPermissions] as? NSNumber
            check(keptMode?.intValue == 0o600, "what is kept can be read by the user alone: \(String(describing: keptMode))")
            let report = writer.diagnostics(room: "CCOW")
            check(report.contains("cache=none") && report.contains("open=false") && report.contains("ts=100.0 status=read")
                  && !report.contains("문의") && !report.contains("보낸 답") && !report.contains("SNS담당"), "the report names stamps and states, never words: \(report)")
            guard let good = SlackCache.read(keptFile) else { fatalError("what was kept reads back") }
            check(good.state.replies["CCOW"]?.count == 6 && good.state.extra["CCOW"]?["100.0"] != nil && good.rooms.count == 3, "rooms, threads and the older thread are all in it")

            let again = stocked()
            let reader = SlackBridge(api: again.api, cache: keptFile)
            let restoredView = reader.restore(characters: characters, now: keepTime.addingTimeInterval(100))
            check(again.log.isEmpty && restoredView?.threads["CCOW"]?.map(\.ts) == keptView.threads["CCOW"]?.map(\.ts)
                  && restoredView?.threads["CCOW"]?.last?.position == Date(timeIntervalSince1970: 300) && restoredView?.threads["CCOW"]?.last?.replies.count == 1
                  && restoredView?.threads["CCOW"]?.allSatisfy(\.loaded) == true && restoredView?.rooms.map(\.id) == keptView.rooms.map(\.id),
                  "a start shows what was kept, the older thread in its place, before Slack is asked anything")
            check(reader.diagnostics(room: "CCOW").contains("cache=restored") && reader.diagnostics(room: "CCOW").contains("ts=100.0 status=kept\n"), "the report says the start was from what was kept")
            for step in 0..<8 { keptView = reader.sync(closedRequest, now: keepTime.addingTimeInterval(100 + Double(step))) }
            check(again.replyLog.isEmpty && again.log.filter { $0 == "auth.test" }.count == 1 && again.log.contains("conversations.history") && keptView.status == .connected,
                  "then the rooms are listed again and no thread that stands as it was is read: \(again.replyLog)")
            again.history["CCOW"]?[0]["latest_reply"] = "171.0"; again.history["CCOW"]?[0]["reply_count"] = 2
            again.replies["CCOW:151.0"]?.append(bot("171.0", "새로 달린 답", thread: "151.0"))
            again.history["CCOW"]?.append(broadcast("400.0", thread: "100.0"))
            again.replies["CCOW:100.0"]?.append(broadcast("400.0", thread: "100.0"))
            for step in 0..<8 { keptView = reader.sync(closedRequest, now: keepTime.addingTimeInterval(140 + Double(step))) }
            check(again.replyLog.sorted() == ["CCOW:100.0", "CCOW:151.0"] && keptView.threads["CCOW"]?.last?.position == Date(timeIntervalSince1970: 400)
                  && keptView.threads["CCOW"]?.first { $0.ts == "151.0" }?.replies.count == 2, "only the thread that changed and the older thread with a new channel reply are read: \(again.replyLog)")

            // What is left out of it
            let pruneNow = keepTime.timeIntervalSince1970 + 60
            var trimmed = good
            trimmed.prune(listed: ["CCOW", "DJARVIS"], recent: [], now: pruneNow)
            check(trimmed.state.history["CTRUTH"] == nil && trimmed.state.replies["CTRUTH"] == nil && !trimmed.rooms.contains { $0.id == "CTRUTH" }
                  && !trimmed.fetched.keys.contains { $0.hasPrefix("CTRUTH:") } && trimmed.state.history["CCOW"] != nil, "a room no longer listed is left out, stamps and all")
            trimmed = good
            trimmed.state.replies["CCOW"]?["1.0"] = [SlackMessage(ts: "2.0", threadTS: "1.0", text: "주인 없는 답")]; trimmed.fetched["CCOW:1.0"] = "2.0"
            trimmed.state.users["UGONE"] = SlackBridge.unknownName
            trimmed.prune(listed: nil, recent: [], now: pruneNow)
            check(trimmed.state.replies["CCOW"]?["1.0"] == nil && trimmed.fetched["CCOW:1.0"] == nil && trimmed.state.replies["CCOW"]?.count == 6 && trimmed.state.users["UGONE"] == nil,
                  "replies whose first message is gone are left out, and a name that could not be read is not kept as unknown")
            trimmed = good
            trimmed.state.history["CCOW"]?.removeAll { !$0.isRoot }
            var spared = trimmed
            trimmed.prune(listed: nil, recent: [], now: pruneNow)
            spared.prune(listed: nil, recent: ["CCOW:100.0"], now: pruneNow)
            check(trimmed.state.extra["CCOW"]?["100.0"] == nil && trimmed.state.replies["CCOW"]?["100.0"] == nil && trimmed.broadcastStamp["CCOW:100.0"] == nil
                  && spared.state.extra["CCOW"]?["100.0"] != nil && spared.state.replies["CCOW"]?["100.0"] != nil,
                  "an older thread whose channel line has left the listing is left out, unless Hermes worked in it lately")
            trimmed = good
            trimmed.readAt["CCOW"] = pruneNow - SlackCache.roomAge - 1
            trimmed.prune(listed: nil, recent: [], now: pruneNow)
            check(trimmed.state.history["CCOW"] == nil && trimmed.state.history["CTRUTH"] != nil, "a room not read for a month is left out")
            trimmed = good
            trimmed.readAt["CTRUTH"] = 1
            let whole = trimmed.fitted()?.count ?? 0
            let fitted = trimmed.fitted(limit: whole - 1)
            check(whole > 0 && fitted != nil && (fitted?.count ?? whole) < whole && trimmed.state.history["CTRUTH"] == nil && trimmed.state.history["CCOW"] != nil
                  && trimmed.fitted(limit: 10) == nil, "over the size limit the room read longest ago goes first, and nothing is written that does not fit")

            // Whose it is, and a file that cannot be used
            var foreign = good
            foreign.state.me = "UOTHER"
            foreign.state.history["CCOW"]?.append(SlackMessage(ts: "999.0", text: "남의 글"))
            check(SlackCache.write((try? JSONEncoder().encode(foreign)) ?? Data(), to: keptFile), "a file is written")
            let stranger = stocked()
            let strangerBridge = SlackBridge(api: stranger.api, cache: keptFile)
            check(strangerBridge.restore(characters: characters, now: keepTime.addingTimeInterval(200))?.threads["CCOW"]?.contains { $0.ts == "999.0" } == true, "what was kept is shown until Slack says whose token this is")
            keptView = strangerBridge.sync(closedRequest, now: keepTime.addingTimeInterval(200))
            check(!FileManager.default.fileExists(atPath: keptFile.path) && !keptView.threads.values.joined().contains { $0.ts == "999.0" } && strangerBridge.state.me == "UME",
                  "another person's is thrown away, file and all, the moment the owner is known")
            var newer = good
            newer.version = SlackCache.version + 1
            check(SlackCache.write((try? JSONEncoder().encode(newer)) ?? Data(), to: keptFile) && SlackCache.read(keptFile) == nil
                  && SlackBridge(api: stranger.api, cache: keptFile).restore(characters: characters) == nil, "a file from another version is not used")
            try? Data("{ not json".utf8).write(to: keptFile)
            check(SlackCache.read(keptFile) == nil && SlackBridge(api: stranger.api, cache: keptFile).restore(characters: characters) == nil, "a file that cannot be read is not used")
            SlackCache.delete(keptFile)
            check(!FileManager.default.fileExists(atPath: keptFile.path), "disconnecting leaves nothing behind")
            let loose = stocked()
            let unkept = SlackBridge(api: loose.api)
            for step in 0..<4 { _ = unkept.sync(closedRequest, now: keepTime.addingTimeInterval(Double(step))) }
            unkept.flush()
            check(!FileManager.default.fileExists(atPath: keptFile.path) && (try? FileManager.default.contentsOfDirectory(atPath: shelfFolder.path))?.isEmpty != false, "without a place to keep it nothing is written")
        }

        // Closed window: rooms take turns
        request.open = false
        let quiet = SlackBridge(api: slack.api)
        _ = quiet.sync(request, now: start)
        check(quiet.calls.filter { $0 == "conversations.history" }.count == 1, "one room per pass while closed")
        check(SlackAPI(transport: { _, _ in .success(Data("{\"ok\":false,\"error\":\"missing_scope\",\"needed\":\"groups:history\"}".utf8)) }).call("x").map { _ in true }
              == .failure(.api("missing_scope:groups:history")) && SlackAPI.message(.api("missing_scope:groups:history")).contains("groups:history"), "a missing permission is named")
        do {
            var root = ChatMessage(id: "slack:test:1", fromUser: false, speaker: "test", body: "hello", date: Date(timeIntervalSince1970: 1))
            var thread = SlackThread(id: root.id, room: "test", ts: "1", root: root, replies: [], replyCount: 0, loaded: true, latest: 1, latestFromUser: false)
            var cache = SlackPublishCache(), unread = SlackUnreadCache()
            cache.prepare(["test": [thread]], excluding: [])
            precondition(cache.roomBuilds == 1 && cache.incoming == [root] && cache.latest["test"] == root)
            cache.prepare(["test": [thread]], excluding: [])
            precondition(cache.roomBuilds == 1)
            for stamp in [0.0, 1.0, 2.0] {
                for remote in [0.0, 2.0] {
                    let expected = SlackUnread.count([thread], lastRead: stamp, roomRead: remote)
                    precondition(unread.count(thread, lastRead: stamp, roomRead: remote, threadRead: [:]) == expected)
                }
            }
            let count = unread.evaluations
            _ = unread.count(thread, lastRead: 2, roomRead: 2, threadRead: [:])
            precondition(unread.evaluations == count)
            root.body = "생각 중이에요"; thread.root = root
            cache.prepare(["test": [thread]], excluding: [])
            precondition(cache.roomBuilds == 2)
            precondition(cache.incoming == [root].filter { !SlackText.isThinking($0.body) })
            cache.prepare(["test": [thread]], excluding: ["test"])
            precondition(cache.incoming.isEmpty && cache.roomBuilds == 2)
            cache.prepare([:], excluding: [])
            precondition(cache.latest.isEmpty && cache.incoming.isEmpty)
            var snapshot = SlackBridge.Snapshot()
            precondition(snapshot.changedFields(from: snapshot).isEmpty)
            let old = snapshot; snapshot.threads = ["test": [thread]]
            precondition(snapshot.changedFields(from: old) == ["threads"])
        }
        do {
            let date = Date(timeIntervalSince1970: 1000)
            var root = ChatMessage(id: "notice-cache", fromUser: false, speaker: "합성", body: "알림", date: date)
            var thread = SlackThread(id: root.id, room: "r", ts: "1000", root: root, replies: [], replyCount: 0, loaded: true, latest: 1000, latestFromUser: false)
            var memo = SlackNoticeMemo()
            for offset in [-1.0, 0, 1, 86399, 86400, 86401, 5] {
                let now = date.addingTimeInterval(offset)
                check(memo.items([thread], now: now, dismissed: [:], confirmed: []) == SlackNotice.items([thread], now: now), "Notice cache matches at start, expiry, and backwards time")
            }
            let count = memo.itemEvaluations
            _ = memo.items([thread], now: date.addingTimeInterval(6), dismissed: [:], confirmed: [])
            check(memo.itemEvaluations == count, "Notice cache reuses within its validity interval")
            for dismissed in [[:], [thread.id: 1000.0]] {
                check(memo.items([thread], now: date, dismissed: dismissed, confirmed: []) == SlackNotice.items([thread], now: date, dismissed: dismissed), "Notice cache invalidates dismissal")
            }
            root.body = "승인해줘"; thread.root = root
            for confirmed: Set<String> in [[], [root.id]] {
                let cached = memo.assessment(thread, confirmed: confirmed), direct = SlackNotice.assessment(thread, confirmed: confirmed)
                check(cached.pending == direct.pending && cached.state == direct.state, "Assessment cache preserves edits and confirmation")
                check(memo.isSettled(thread, confirmed: confirmed) == SlackNotice.isSettled(thread, confirmed: confirmed), "Settled cache matches direct result")
                check(memo.items([thread], now: date, dismissed: [:], confirmed: confirmed) == SlackNotice.items([thread], now: date, confirmed: confirmed), "Items cache preserves confirmation")
            }
            var unread = SlackUnreadCache()
            _ = unread.count(thread, lastRead: 0, roomRead: 0, threadRead: [:])
            let evaluated = unread.evaluations
            _ = unread.count(thread, lastRead: 0, roomRead: 0, threadRead: ["unrelated": 1000])
            check(unread.evaluations == evaluated, "Another thread read stamp does not recount this thread")
            _ = unread.count(thread, lastRead: 0, roomRead: 0, threadRead: [thread.id: 1000])
            check(unread.evaluations == evaluated+1, "Own read stamp recounts the thread")
        }
        do {
            let request = ChatMessage(id: "pet-approval:request", fromUser: false, speaker: "SNS담당", body: "이 초안 승인 부탁해", date: Date(timeIntervalSince1970: 1))
            let pending = SlackThread(id: "pet-approval", room: "selected-room", ts: "1", root: request, replies: [], replyCount: 0,
                                      loaded: true, latest: 1, latestFromUser: false)
            var memo = SlackNoticeMemo()
            check(memo.needsPetApproval([pending], rooms: ["selected-room"], confirmed: []), "The selected room's pending request makes the pet ask for approval")
            let before = memo.petApprovalEvaluations
            for _ in 0..<60 { _ = memo.needsPetApproval([pending], rooms: ["selected-room"], confirmed: []) }
            check(memo.petApprovalEvaluations == before, "Pet animation ticks reuse the approval decision without parsing the same conversation")
            check(!memo.needsPetApproval([pending], rooms: ["other-room"], confirmed: []), "Changing rooms cannot show the old room's approval while its threads are still present")
            check(!memo.needsPetApproval([pending], rooms: [], confirmed: []), "No selected room has no approval to animate")
            check(memo.needsPetApproval([pending], rooms: ["selected-room", "hub-room"], confirmed: []), "A combined conversation includes only its explicitly shown rooms")
            check(!memo.needsPetApproval([pending], rooms: ["selected-room"], confirmed: [request.id]), "Confirming a request ends the pet's approval without sending a reply")
            var answered = pending
            answered.replies = [ChatMessage(id: "pet-approval:answer", fromUser: true, speaker: "", body: "수정해줘", date: Date(timeIntervalSince1970: 2))]
            check(!memo.needsPetApproval([answered], rooms: ["selected-room"], confirmed: []), "Any answer to the request stops asking for that approval")
            var completed = pending
            completed.root.marks = [ChatMark(color: "#2EB67D", text: "답변 완료")]
            check(SlackNotice.pendingApproval(completed) != nil && !memo.needsPetApproval([completed], rooms: ["selected-room"], confirmed: []),
                  "Completed requests may retain approval controls but never animate a pending approval")
            var laterCompleted = pending
            var finished = ChatMessage(id: "pet-approval:finished", fromUser: false, speaker: "SNS담당", body: "처리했어", date: Date(timeIntervalSince1970: 2))
            finished.marks = [ChatMark(color: "#2EB67D", text: "종결")]
            laterCompleted.replies = [finished]
            check(!memo.needsPetApproval([laterCompleted], rooms: ["selected-room"], confirmed: []), "A later completed status also stops the approval animation")
            var reopened = laterCompleted
            reopened.replies.append(ChatMessage(id: "pet-approval:new", fromUser: false, speaker: "SNS담당", body: "새 초안 승인해줘", date: Date(timeIntervalSince1970: 3)))
            check(memo.needsPetApproval([reopened], rooms: ["selected-room"], confirmed: [request.id]), "A new request after completion or confirmation asks again")
            var unloaded = pending; unloaded.loaded = false
            check(!memo.needsPetApproval([unloaded], rooms: ["selected-room"], confirmed: []), "Unread replies cannot be assumed to leave an approval unanswered")
            var edited = pending; edited.root.body = "승인을 기다리는 건 이제 없습니다."
            check(!memo.needsPetApproval([edited], rooms: ["selected-room"], confirmed: []), "Editing away the request invalidates the approval decision")
            let many = (0..<513).map { index -> SlackThread in
                var thread = edited; thread.id = "pet-idle:\(index)"; thread.root.id = thread.id
                return thread
            }
            check(!memo.needsPetApproval(many, rooms: ["selected-room"], confirmed: []), "A long room without approvals stays quiet")
            let longBefore = memo.petApprovalEvaluations
            _ = memo.needsPetApproval(many, rooms: ["selected-room"], confirmed: [])
            check(memo.petApprovalEvaluations == longBefore, "Rooms beyond the per-thread cache limit still reuse the pet decision each tick")
        }
        do {
            let message = ChatMessage(id: "slack:room:1", fromUser: false, speaker: "합성", body: "기록", date: Date(timeIntervalSince1970: 1), profile: "synthetic")
            let thread = SlackThread(id: message.id, room: "room", ts: "1", root: message, replies: [], replyCount: 0, loaded: true, latest: 1, latestFromUser: false)
            var input = DdotsRecordMemo.Input(threads: ["room": [thread]], scanned: [:], members: [DdotsMember(profile: "synthetic", name: "합성", room: "room")], excluded: [])
            var memo = DdotsRecordMemo()
            check(memo.candidates(input) == DdotsRecordMemo.convert(input), "Record memo matches uncached conversion")
            let before = memo.evaluations
            _ = memo.candidates(input)
            check(memo.evaluations == before, "Unchanged record inputs reuse conversion")
            input.threads["room"]![0].root.body = "수정"
            check(memo.candidates(input) == DdotsRecordMemo.convert(input) && memo.evaluations == before+1, "Record memo invalidates edits")
            input.members[0].name = "새 이름"
            check(memo.candidates(input) == DdotsRecordMemo.convert(input), "Record memo invalidates character names")
            input.scanned = ["room": [message]]
            check(memo.candidates(input) == DdotsRecordMemo.convert(input), "Record memo includes rescanned messages")
            input.excluded = ["room"]
            check(memo.candidates(input).isEmpty, "Record memo invalidates retention exclusions")
        }
        // Drafts and failed sends stay with the place they were written for.
        do {
            let a = SlackDraftPlace(workspace: "W", shown: "CA", aim: SlackDraftPlace.auto)
            let aThread = SlackDraftPlace(workspace: "W", shown: "CA", aim: SlackDraftPlace.thread("slack:CA:1.0"))
            let b = SlackDraftPlace(workspace: "W", shown: "CB", aim: SlackDraftPlace.new("CB"))
            let other = SlackDraftPlace(workspace: "X", shown: "CA", aim: SlackDraftPlace.auto)
            var drafts = SlackDrafts()
            let fileB = URL(fileURLWithPath: "/synthetic/b.txt"), fileA = URL(fileURLWithPath: "/synthetic/a.txt")
            drafts.put(SlackSavedDraft(text: "B방 초안", files: [fileB]), at: b)
            drafts.put(SlackSavedDraft(text: "A 스레드 초안"), at: aThread)
            drafts.put(SlackSavedDraft(text: "다른 워크스페이스"), at: other)
            check(drafts.draft(at: b).files == [fileB] && drafts.draft(at: a).isEmpty && drafts.draft(at: aThread).text == "A 스레드 초안", "each room, thread and new post keeps its own draft")
            check(drafts.draft(at: other).text == "다른 워크스페이스" && drafts.draft(at: SlackDraftPlace(workspace: "W", shown: "CA", aim: SlackDraftPlace.auto)).isEmpty, "a draft of one workspace is never another's")
            drafts.put(SlackSavedDraft(), at: b)
            check(drafts.saved[b] == nil, "an emptied draft is let go")
            check(SlackSavedDraft(pick: "system-doctor").isEmpty == false, "a pressed face alone is kept")

            let first = SlackFailedSend(workspace: "W", shown: "CA", room: "CA", thread: nil, text: "첫 실패", files: [fileA], pick: nil, reason: "슬랙 오류: x")
            let second = SlackFailedSend(workspace: "W", shown: "CA", room: "CA", thread: "slack:CA:1.0", text: "둘째 실패", files: [], pick: nil, reason: "슬랙 오류: y")
            let third = SlackFailedSend(workspace: "W", shown: "DDOTS", room: "CHUB", thread: nil, text: "셋째", files: [], pick: "system-doctor", reason: "z")
            let foreign = SlackFailedSend(workspace: "X", shown: "CA", room: "CA", thread: nil, text: "남의 것", files: [], pick: nil, reason: "z")
            for failure in [first, second, third, foreign] { drafts.fail(failure) }
            check(drafts.failures(workspace: "W", shown: "CA").map(\.text) == ["첫 실패", "둘째 실패"], "failures wait in their room in the order they were sent")
            check(drafts.elsewhere(workspace: "W", shown: "CA").map(\.text) == ["셋째"] && drafts.failures(workspace: "X", shown: "CA").map(\.text) == ["남의 것"], "another room's and another workspace's failures stay apart")
            check(first.place == SlackDraftPlace(workspace: "W", shown: "CA", aim: SlackDraftPlace.new("CA")) && second.place.aim == SlackDraftPlace.thread("slack:CA:1.0"), "a failure goes back to its own thread or new post")
            // Brought back into a draft that already has new words: the failed words come first and nothing typed since is lost.
            let typed = SlackSavedDraft(text: "새로 쓰는 글", files: [fileB])
            guard case .success(let restored) = drafts.restore(first.id, into: typed) else { check(false, "a failure can be brought back"); return }
            check(restored.text == "첫 실패\n새로 쓰는 글" && restored.files == [fileA, fileB], "the failed words and files go ahead of what was typed since: \(restored)")
            check(drafts.failures(workspace: "W", shown: "CA").map(\.text) == ["둘째 실패"], "only the restored failure is let go")
            guard case .success(let picked) = drafts.restore(third.id, into: SlackSavedDraft()) else { check(false, "the ddots failure comes back"); return }
            check(picked.pick == "system-doctor" && picked.text == "셋째", "the face pressed for a failed post comes back with it")
            let many = (0..<9).map { URL(fileURLWithPath: "/synthetic/\($0).txt") }
            let heavy = SlackFailedSend(workspace: "W", shown: "CA", room: "CA", thread: nil, text: "", files: [fileA, fileB], pick: nil, reason: "z")
            drafts.fail(heavy)
            check(drafts.restore(heavy.id, into: SlackSavedDraft(files: many)) == .failure(.tooManyFiles) && drafts.failures.contains { $0.id == heavy.id }, "more than ten files are not brought back and the failure keeps waiting")
            check(drafts.restore(UUID(), into: SlackSavedDraft()) == .failure(.gone), "a failure already let go cannot come back")
            drafts.discard(second.id)
            check(!drafts.failures.contains { $0.id == second.id }, "a failure can be let go")
        }
        // Files are checked by their size before any is read, then read and sent one at a time.
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-upload-test-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let small = folder.appendingPathComponent("작은.txt"), big = folder.appendingPathComponent("큰.bin"), gone = folder.appendingPathComponent("없는.txt")
            try? Data(repeating: 7, count: 5).write(to: small)
            try? Data(repeating: 1, count: 4).write(to: big)
            var loads: [String] = []
            let sizes: (URL) -> Int? = { $0 == big ? SlackFileStore.largest + 1 : SlackOutgoingFile.size(of: $0) }
            let loader: (URL) throws -> Data = { loads.append($0.lastPathComponent); return try Data(contentsOf: $0) }
            check(SlackOutgoingFile.prepare([small, big], size: sizes, load: loader).failureValue == .tooLarge("큰.bin") && loads.isEmpty, "a file over 200MB is refused by its size before anything is read")
            check(SlackOutgoingFile.prepare([small, gone], load: loader).failureValue == .missing("없는.txt") && loads.isEmpty, "a missing file is refused before anything is read")
            check(SlackOutgoingFile.prepare([folder]).failureValue == .missing(folder.lastPathComponent), "a folder is not a file to send")
            guard case .success(let ready) = SlackOutgoingFile.prepare([small], load: loader) else { check(false, "a small file is ready"); return }
            check(ready.first?.size == 5 && loads.isEmpty, "checking reads only the size")

            let fake = FakeSlack(), bridge = SlackBridge(api: fake.api)
            var order: [String] = []
            let raw = fake.raw
            let api = SlackAPI(transport: { method, parameters in
                if method.hasPrefix("files.") { order.append(method + ":" + (parameters["filename"] ?? "")) }
                return fake.transport(method, parameters)
            }, raw: { url, body in order.append("bytes:" + url.lastPathComponent); return raw(url, body) })
            let uploader = SlackBridge(api: api)
            func file(_ name: String, _ size: Int, actual: Int? = nil, fails: Bool = false) -> SlackOutgoingFile {
                SlackOutgoingFile(name: name, size: size, load: {
                    order.append("read:" + name)
                    if fails { throw CocoaError(.fileReadNoPermission) }
                    return Data(repeating: 3, count: actual ?? size)
                })
            }
            check(uploader.upload(room: "CCOW", thread: "300.0", text: "세 파일", files: [file("a.txt", 2), file("b.txt", 3), file("c.txt", 4)]) == nil, "three files are sent")
            check(order == ["read:a.txt", "files.getUploadURLExternal:a.txt", "bytes:a.txt", "read:b.txt", "files.getUploadURLExternal:b.txt", "bytes:b.txt",
                            "read:c.txt", "files.getUploadURLExternal:c.txt", "bytes:c.txt", "files.completeUploadExternal:"],
                  "each file is read only after the one before it was sent, and all are attached at the end: \(order)")
            check(fake.posted.last?["thread_ts"] == "300.0" && fake.posted.last?["files"]?.contains("F3") == true && uploader.uploadedFileIDs == ["F2", "F3", "F4"], "the files keep their IDs and their thread")
            order = []
            check(uploader.upload(room: "CCOW", thread: nil, text: "", files: [file("a.txt", 2), file("b.txt", 3, fails: true), file("c.txt", 4)]) == "파일을 읽지 못했어요: b.txt"
                  && order == ["read:a.txt", "files.getUploadURLExternal:a.txt", "bytes:a.txt", "read:b.txt"] && uploader.uploadedFileIDs.isEmpty, "a file that cannot be read stops the send before it is attached: \(order)")
            order = []
            check(uploader.upload(room: "CCOW", thread: nil, text: "", files: [file("a.txt", 2, actual: 9)]) == "보내는 사이 파일이 바뀌었어요. 다시 보내 주세요: a.txt"
                  && order == ["read:a.txt"], "a file that changed since it was checked is not sent")
            order = []
            let failing = SlackAPI(transport: fake.transport, raw: { url, body in
                order.append("bytes:" + url.lastPathComponent)
                return url.lastPathComponent == "b.txt" ? .failure(.network("끊김")) : raw(url, body)
            })
            let sentBefore = fake.posted.count
            check(SlackBridge(api: failing).upload(room: "CCOW", thread: nil, text: "", files: [file("a.txt", 2), file("b.txt", 3), file("c.txt", 4)]) == "슬랙에 연결하지 못했어요. 끊김"
                  && order == ["read:a.txt", "bytes:a.txt", "read:b.txt", "bytes:b.txt"] && fake.posted.count == sentBefore, "a file that fails midway stops the rest and nothing is attached: \(order)")
            _ = bridge
        }
        // Search reads the record a month at a time and says what it could not read.
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ddots-scan-test-\(UUID().uuidString)")
            defer { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("기록/SNS담당/2026-07.jsonl").path); try? FileManager.default.removeItem(at: root) }
            let shelf = DdotsArchive(root: root)
            func line(_ ts: String, _ profile: String, _ text: String, month: Int) -> DdotsLine {
                let at = DateComponents(calendar: Calendar.current, year: 2026, month: month, day: 10).date!.timeIntervalSince1970 + (Double(ts) ?? 0)
                return DdotsLine(ts: ts, thread: ts, profile: profile, name: "합성", mine: false, at: at, text: text)
            }
            try? shelf.append([line("1", "personal-secretary", "칠월 첫 글", month: 7), line("2", "sns-manager", "칠월 SNS담당", month: 7),
                               line("3", "personal-secretary", "팔월 글", month: 8), line("4", "personal-secretary", "구월 옛 글", month: 9)],
                              names: ["personal-secretary": "개인비서", "sns-manager": "SNS담당"])
            // A later version of a message, a garbled line and a line cut short by a crash.
            try? shelf.append([line("4", "personal-secretary", "구월 고친 글", month: 9)], names: ["personal-secretary": "개인비서"])
            let september = root.appendingPathComponent("기록/개인비서/2026-09.jsonl")
            if let handle = try? FileHandle(forWritingTo: september) { handle.seekToEndOfFile(); handle.write(Data("{이건 줄이 아니야\n\n{\"ts\":\"5\"".utf8)); handle.closeFile() }
            check(shelf.months() == ["2026-07", "2026-08", "2026-09"], "the record's months are listed: \(shelf.months())")
            let nine = shelf.scan(month: "2026-09")
            check(nine.lines.map(\.text) == ["구월 고친 글"] && nine.damaged == 2 && nine.unreadable == 0 && nine.away == 0, "the latest version stands and damaged lines are counted, not read: \(nine)")
            check(shelf.scan(month: "2026-08") == DdotsArchive.MonthRead(lines: shelf.read(month: "2026-08")) && shelf.scan(month: "2026-08").lines.count == 1, "a character with nothing that month is no gap")
            let cow = root.appendingPathComponent("기록/SNS담당/2026-07.jsonl")
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cow.path)
            let seven = shelf.scan(month: "2026-07")
            check(seven.unreadable == 1 && seven.lines.map(\.text) == ["칠월 첫 글"], "a file that cannot be opened is counted while the others are still searched: \(seven)")
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: cow.path)
            try? Data().write(to: root.appendingPathComponent("기록/SNS담당/.2026-08.jsonl.icloud"))
            check(shelf.scan(month: "2026-08").away == 1 && shelf.hasUndownloadedMonths(), "a month iCloud has not brought down is counted apart")
            check(DdotsArchive(root: root.appendingPathComponent("none")).scan(month: "2026-07") == DdotsArchive.MonthRead(), "no record at all is no gap")
            // Listing the months: a record that is not there is empty, a folder that cannot be listed is counted.
            check(DdotsArchive(root: root.appendingPathComponent("none")).listMonths() == DdotsArchive.MonthList(), "a record that is not there lists nothing and no gap")
            let records = root.appendingPathComponent("기록"), cowFolder = records.appendingPathComponent("SNS담당")
            try? Data("{}".utf8).write(to: records.appendingPathComponent(".DS_Store"))
            let whole = shelf.listMonths()
            check(whole.months == ["2026-07", "2026-08", "2026-09"] && whole.unlisted == 0 && whole.away, "every folder lists; a stray file is no folder and no gap: \(whole)")
            try? FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: cowFolder.path)
            let partial = shelf.listMonths()
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cowFolder.path)
            check(partial.unlisted == 1 && partial.months == ["2026-07", "2026-08", "2026-09"] && !partial.away && shelf.months() == whole.months,
                  "a character's folder that cannot be listed is counted while the others still list: \(partial)")
            try? FileManager.default.setAttributes([.posixPermissions: 0o300], ofItemAtPath: records.path)
            let none = shelf.listMonths(), plain = shelf.months(), awayFlag = shelf.hasUndownloadedMonths()
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: records.path)
            check(none.unlisted == 1 && none.months.isEmpty && plain.isEmpty && !awayFlag, "a record folder that cannot be listed is one gap, not an empty record: \(none)")
        }
        for empty in ["", " ", "\n\t "] {
            check(DdotsFaceLight.profile(draft: empty, picked: false, replying: false, recipient: Ddots.defaultTarget) == nil, "An automatic empty draft lights nobody")
        }
        let hubFaces = [DdotsMember(profile: "personal-secretary", name: "개인비서", room: "DJ"), DdotsMember(profile: "sns-manager", name: "SNS담당", room: "DC")]
        for text in ["안녕", "노션", "노션 정리해줘", "random 값"] {
            check(DdotsFaceLight.routed(DdotsRoute.preview(text), faces: hubFaces) == nil, "Words about no face here light nobody: " + text)
        }
        for row in routeSamples {
            let text = row["text"]!, expected = row["hub"]!
            let decision = DdotsRoute.preview(text)
            let visible = decision.reason != "fallback" && hubFaces.contains(where: { $0.profile == expected }) ? expected : nil
            check(DdotsFaceLight.routed(decision, faces: hubFaces) == visible, "Face visibility follows oracle and Slack membership: " + text)
        }
        check(DdotsFaceLight.profile(draft: "", picked: true, replying: false, recipient: "sns-manager") == "sns-manager", "A pressed face stays lit without text")
        check(DdotsFaceLight.profile(draft: "", picked: false, replying: true, recipient: "system-doctor") == "system-doctor", "A reply keeps its owner lit")
        check(DdotsFaceLight.profile(draft: "안녕", picked: false, replying: false, recipient: nil) == nil, "Unknown recipient does not invent a lit face")
        do {
            let ask = ChatMessage(id: "slack:CHUB:1", fromUser: true, speaker: "", body: "메모 고쳐", date: Date(), profile: "")
            let thinking = ChatMessage(id: "slack:CHUB:2", fromUser: false, speaker: "업무비서", body: "생각 중...", date: Date(), profile: "work-assistant")
            let done = ChatMessage(id: "slack:CHUB:3", fromUser: false, speaker: "업무비서", body: "고쳤어요.", date: Date(), profile: "work-assistant")
            func thread(_ replies: [ChatMessage]) -> SlackThread {
                SlackThread(id: ask.id, room: "CHUB", ts: "1", root: ask, replies: replies, replyCount: replies.count, loaded: true, latest: 1, latestFromUser: false)
            }
            check(AgentStop.working(thread([thinking]), typing: []), "A standing 생각 중 line is a run at work")
            check(AgentStop.working(thread([]), typing: [TypingIndicator(id: "t", speaker: "업무비서")]), "A typing mark is a run at work")
            check(!AgentStop.working(thread([done]), typing: []), "A finished answer offers no stop")
            check(AgentStop.control(working: true, stopped: false) == .stop && AgentStop.control(working: false, stopped: false) == nil, "Stop shows only while a character works")
            check(AgentStop.control(working: true, stopped: true) == .undo && AgentStop.control(working: false, stopped: true) == .undo, "A stopped thread offers the undo request even if its 생각 중 line stays")
            check(AgentStop.command == "!stop" && SlackMention.outgoing(AgentStop.command, members: []) == "!stop", "The stop command reaches Slack unchanged, as Hermes reads it in threads")
            check(AgentStop.undoRequest.contains("목록") && AgentStop.undoRequest.contains("확인 전에는 아무것도 바꾸지 마"), "The undo request asks for the list first and no change before agreement")
        }
        roomChanges()
        print("SlackTests passed")
    }
}
