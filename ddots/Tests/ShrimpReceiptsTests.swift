import Foundation

enum ShrimpReceiptsTests {
    static func run() throws -> Int {
        var count = 0
        func check(_ value: Bool, _ label: String) { count += 1; if !value { fatalError(label) } }
        let bot = ShrimpVault.defaultBot, me = "UFAKE", room = "CFAKE"
        let now = Date(timeIntervalSince1970: 1800000100)
        let sourceTS = "1800000000.000001", replyTS = "1800000001.000001"
        let text = "저장했어요 — 가짜 서류/가짜.txt\n올린 원본: \(sourceTS)"
        let multi = "저장했어요 — 2개\n- 가짜.txt\n- 다른.txt\n올린 원본: \(sourceTS)"
        check(ShrimpReceipts.parse(text)?.count == 1, "single receipt")
        check(ShrimpReceipts.parse(multi)?.count == 2, "multi receipt")
        for bad in ["저장하지 않았어요\n올린 원본: \(sourceTS)", text + "\n", text + "\n올린 원본: \(sourceTS)", text.replacingOccurrences(of: sourceTS, with: "nan"), multi.replacingOccurrences(of: "2개", with: "3개"), text.replacingOccurrences(of: "가짜 서류/가짜.txt", with: "../outside"), text.replacingOccurrences(of: "가짜 서류/가짜.txt", with: "/absolute"), "```\n" + text + "\n```", text.replacingOccurrences(of: "올린 원본:", with: "인용 원본:")] {
            check(ShrimpReceipts.parse(bad) == nil, "malformed receipt refused")
        }
        func thread(body: String = "", sender: String = "", fromUser: Bool = false, dateTS: String = "", channel: String = "") -> SlackThread {
            let channel = channel.isEmpty ? room : channel, ts = dateTS.isEmpty ? replyTS : dateTS
            var root = ChatMessage(id: "slack:\(channel):\(sourceTS)", fromUser: true, speaker: "본인", body: "저장", date: now)
            root.slackUserID = me; root.files = [ChatFile(id: "FFAKE", name: "가짜.txt")]
            var reply = ChatMessage(id: "slack:\(channel):\(ts)", fromUser: fromUser, speaker: "봇", body: body.isEmpty ? text : body, date: now)
            reply.slackUserID = sender.isEmpty ? bot : sender
            return SlackThread(id: "slack:\(channel):\(sourceTS)", room: channel, ts: sourceTS, root: root, replies: [reply], replyCount: 1, loaded: true, latest: now.timeIntervalSince1970, latestFromUser: false)
        }
        var source: [String: Any] = [:], confirmation: [String: Any] = [:]
        var info: [String: Any] = [:], calls: [(String,[String:String])] = []
        var failure: SlackAPI.Failure? = nil
        func reset() {
            source = ["ts":sourceTS,"user":me,"files":[["id":"FFAKE"]]]
            confirmation = ["ts":replyTS,"thread_ts":sourceTS,"user":bot,"text":text]
            info = ["id":"FFAKE","user":me,"mode":"hosted"]
            calls=[]; failure=nil
        }
        let api = SlackAPI(transport: { method, params in
            calls.append((method,params))
            if let failure { return .failure(failure) }
            var result: [String: Any] = ["ok":true]
            if method == "auth.test" { result["user_id"] = me }
            if method == "conversations.replies" { result["messages"] = [source,confirmation] }
            if method == "files.info" {
                var value=info; value["id"]=params["file"]
                if params["file"] == "FOTHER" { value["user"] = "OTHER" }
                result["file"]=value
            }
            return .success(try! JSONSerialization.data(withJSONObject: result))
        })
        func deletedCalls() -> Int { calls.filter { $0.0 == "files.delete" }.count }
        reset(); let worker=ShrimpReceipts()
        let result=worker.process(threads:[thread()],me:me,bot:bot,api:api,now:now)
        check(result.deleted == ["FFAKE"] && deletedCalls()==1, "one matching delete")
        check(calls[1].1["channel"]==room && calls[1].1["ts"]==sourceTS, "fresh exact channel/thread")
        _=worker.process(threads:[thread()],me:me,bot:bot,api:api,now:now)
        check(deletedCalls()==1, "memory dedup")
        reset(); info["mode"]="tombstone"
        _=ShrimpReceipts().process(threads:[thread()],me:me,bot:bot,api:api,now:now)
        check(deletedCalls()==0, "restart verifies deleted file")
        reset(); _=ShrimpReceipts().process(threads:[thread()],me:me,bot:bot,api:api,enabled:false,now:now)
        check(calls.isEmpty, "setting off")
        for t in [thread(sender:"OTHER"),thread(fromUser:true),thread(dateTS:"1700000000.0"),thread(dateTS:"1900000000.0"),thread(body:"保存しました")] {
            reset(); _=ShrimpReceipts().process(threads:[t],me:me,bot:bot,api:api,now:now)
            check(calls.isEmpty,"untrusted or expired no calls")
        }
        for mutation in 0..<9 {
            reset()
            switch mutation {
            case 0: source["user"]="OTHER"
            case 1: source["thread_ts"]="OTHER"
            case 2: source["ts"]="1800000000.999999"
            case 3: confirmation["user"]="OTHER"
            case 4: confirmation["thread_ts"]="OTHER"
            case 5: confirmation["text"]="저장하지 않았어요"
            case 6: source["channel"]="OTHER"
            case 7: confirmation["channel"]="OTHER"
            default: info["user"]="OTHER"
            }
            _=ShrimpReceipts().process(threads:[thread()],me:me,bot:bot,api:api,now:now)
            check(deletedCalls()==0,"fresh mismatch no delete")
        }
        reset(); source["files"]=[["id":"FFAKE"],["id":"FOTHER"]]
        _=ShrimpReceipts().process(threads:[thread()],me:me,bot:bot,api:api,now:now)
        check(deletedCalls()==0,"partial save count mismatch")
        confirmation["text"]=multi
        _=ShrimpReceipts().process(threads:[thread(body:multi)],me:me,bot:bot,api:api,now:now)
        check(deletedCalls()==0,"preflight all owners before deletion")
        reset(); source["files"]=[["id":"FFAKE"],["id":"FFAKE2"]]; confirmation["text"]=multi
        _=ShrimpReceipts().process(threads:[thread(body:multi)],me:me,bot:bot,api:api,now:now)
        check(deletedCalls()==2,"multiple saved files")
        reset(); failure = .api("missing_scope:files:write"); let denied=ShrimpReceipts()
        check(denied.process(threads:[thread()],me:me,bot:bot,api:api,now:now).notice?.contains("권한") == true,"scope guidance")
        check(denied.process(threads:[thread()],me:me,bot:bot,api:api,now:now).notice == nil && calls.count==1,"permission failure no retry/no duplicate notice")
        check(ShrimpReceipts.recent(sourceTS,now:Date(timeIntervalSince1970:Double(sourceTS)!+ShrimpReceipts.lifetime)),"seven day boundary")
        check(!ShrimpReceipts.recent(sourceTS,now:Date(timeIntervalSince1970:Double(sourceTS)!+ShrimpReceipts.lifetime+1)),"seven days exceeded")
        return count
    }
}
