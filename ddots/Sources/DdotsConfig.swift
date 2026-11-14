import Foundation
import CoreFoundation

/// Local metadata only. No credential files or network requests are read here.
final class DdotsConfig {
    static let shared = DdotsConfig()
    let root: URL, hermes: URL
    private let lock=NSRecursiveLock()
    private var config:[String:Any]=[:], local:[String:Any]=[:]
    private var lastCheck=Date.distantPast
    private var problems:[String:String]=[:]
    private var revision=0
    private var conversationRules = ConversationRules(raw: nil)
    private var conversationDocument: Data?
    var conversation: ConversationRules { lock.lock(); defer { lock.unlock() }; refresh(force: false); return conversationRules }
    var generation:Int { lock.lock();defer{lock.unlock()};refresh(force:false);return revision }
    init(root:URL?=nil,hermes:URL?=nil,home:URL=FileManager.default.homeDirectoryForCurrentUser) {
        let env=ProcessInfo.processInfo.environment
        let cloud=home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var folder:ObjCBool=false
        let base=FileManager.default.fileExists(atPath:cloud.path,isDirectory:&folder) && folder.boolValue ? cloud:home.appendingPathComponent("Downloads")
        self.root=root ?? env["DDOTS_CONFIG_ROOT"].map{URL(fileURLWithPath:$0)} ?? base.appendingPathComponent("HermesWorkspace/ddots")
        // The same Hermes home the bridge reads (HERMES_HOME, saved choice, gateway LaunchAgent, ~/.hermes).
        self.hermes=hermes ?? HermesLocator.shared.locate() ?? HermesLocator.shared.fallbackHome
        refresh()
    }
    var status:String { lock.lock();defer{lock.unlock()};refresh(force:false);return problems.keys.sorted().compactMap{problems[$0]}.joined(separator:" · ") }
    var document:[String:Any] { lock.lock();defer{lock.unlock()};refresh(force:false);return config }
    var appearance:[String:Any] { lock.lock();defer{lock.unlock()};refresh(force:false);return local }
    func refresh(force:Bool=true) {
        lock.lock();defer{lock.unlock()}
        if !force && Date().timeIntervalSince(lastCheck)<1 {return};lastCheck=Date()
        let beforeConfig=config as NSDictionary, beforeLocal=local as NSDictionary
        for (name,isConfig) in [("ddots-config.json",true),("ddots-local.json",false)] {
            let url=root.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:url.path) {
                if isConfig {
                    config=[:]
                    problems[name]="Hermes에서 ddots 설정을 아직 내보내지 않았어요.\n1. 설치 도우미를 --update로 실행하세요.\n2. 그래도 없으면 Hermes 저장소에서 수동 실행하세요: PYTHONPATH=\"$HOME/.hermes/plugin-store/team-kit/lib\" \"$GATEWAY_PYTHON\" ddots/scripts/export_config.py --output \"\(url.path)\" (GATEWAY_PYTHON은 Hermes Python 경로)"
                } else {local=[:];problems[name]=nil}
                continue
            }
            do {
                let raw=try JSONSerialization.jsonObject(with:Data(contentsOf:url))
                guard let value=raw as? [String:Any],value["schemaVersion"] as? Int == 1 else{throw ConfigError.invalid}
                if isConfig {
                    guard value["members"] is [[String:Any]], value["routing"] is [String:Any] else{throw ConfigError.invalid}
                    config=value
                } else {local=value}
                problems[name]=nil
            } catch {problems[name]="\(name) 설정을 읽지 못해 마지막 정상값을 유지합니다."}
        }
        let rulesDocument = try? JSONSerialization.data(withJSONObject: [config["conversation"] ?? NSNull()], options: [.sortedKeys])
        let conversationChanged = conversationDocument != rulesDocument
        if conversationChanged {
            conversationRules = ConversationRules(raw: config["conversation"])
            conversationDocument = rulesDocument
        }
        problems["conversation"] = conversationRules.problems.isEmpty ? nil :
            "사용할 수 없는 대화 규칙(기본값 사용): " + conversationRules.problems.joined(separator: ", ")
        if conversationChanged || !beforeConfig.isEqual(to:config) || !beforeLocal.isEqual(to:local) {revision += 1}
    }
    enum ConfigError:Error {case invalid}
    var members:[[String:Any]] {document["members"] as? [[String:Any]] ?? []}
    var recipient:String {HermesRouting.str(HermesRouting.dict(document["defaults"])["recipient"])}
    var excluded:Set<String> {Set(HermesRouting.strings(appearance["excluded"]))}
    var order:[String] {HermesRouting.strings(appearance["order"])}
    func role(_ name:String)->String {HermesRouting.str(HermesRouting.dict(contract(hub:true)["profiles"])[name])}
    func contract(hub:Bool)->[String:Any] {HermesRouting.dict(HermesRouting.dict(document["routing"])[hub ? "hub":"base"])}
    func memberName(_ profile:String)->String {members.first{HermesRouting.str($0["profile"])==profile}.map{HermesRouting.str($0["displayName"])} ?? profile}
    func matching(_ name:String,user:String="")->String? {
        func key(_ s:String)->String{s.filter{!$0.isWhitespace && $0 != "-" && $0 != "_"}.lowercased()}
        return members.first { member in
            (!user.isEmpty && HermesRouting.str(member["slackUserID"])==user) ||
            ([HermesRouting.str(member["profile"]),HermesRouting.str(member["displayName"])]+HermesRouting.strings(member["aliases"])).contains{!key($0).isEmpty && key($0)==key(name)}
        }.map{HermesRouting.str($0["profile"])}
    }
    func roomOwner(id:String,name:String,users:Set<String>)->String? {
        let doc=document,rooms=HermesRouting.dict(doc["rooms"])
        if let owner=(rooms[id] ?? rooms[name]) as? String{return owner}
        let solo=HermesRouting.dict(doc["solo"]),excluded=Set(HermesRouting.strings(solo["excluded_rooms"]))
        guard !id.hasPrefix("D"),!excluded.contains(id),!excluded.contains(name) else{return nil}
        let speakers=users.intersection(HermesRouting.strings(solo["team_bots"])).subtracting(HermesRouting.strings(solo["listener_bots"]))
        guard speakers.count==1,let user=speakers.first else{return nil}
        return members.first{HermesRouting.str($0["slackUserID"])==user}.map{HermesRouting.str($0["profile"])}
    }
}

/// An immutable revision snapshot. Compiled expressions are shared by every row.
final class ConversationRules {
    static let defaults: [String: Any] = try! JSONSerialization.jsonObject(with: Data(defaultJSON.utf8)) as! [String: Any]
    private static let defaultJSON = #"""
{
  "schema": 1,
  "texts": {
    "settledText": "✅ 답변 완료",
    "unanswered": "아직 답 안 함",
    "draft": "초안 올려놨어. 승인 기다리는 중",
    "approveText": "승인",
    "denyText": "거절",
    "branchText": "/branch",
    "mailApproveText": "승인, 발송해",
    "mailDenyText": "거절, 발송하지 마",
    "checklistSkip": "건너뛰기",
    "checklistAll": "전체",
    "checklistPrefix": "선택: ",
    "learningApprove": "학습승인",
    "learningDeny": "학습거절",
    "workingText": "처리 중",
    "waitingText": "답을 기다리는 중",
    "approvedText": "승인됨",
    "denyLabel": "거절",
    "mailApproveLabel": "발송 승인",
    "reviseLabel": "의견",
    "mailReviseLabel": "수정",
    "learningReviseLabel": "수정의견"
  },
  "colors": {
    "questionColor": "#ECB22E",
    "approvedColor": "#2EB67D",
    "alertColor": "#36C5F0",
    "askingColor": "#E01E5A",
    "workingColor": "#ECB22E",
    "closedColor": "#2EB67D"
  },
  "patterns": {
    "nothingWaiting": "승인(을|이)?\\s*(기다리는|해\\s*주실|해\\s*줄|할|받을|드릴)[^\\n.!?]{0,14}없",
    "sentLearning": "승인 없이 보낸 답장 중 내가 직접 쓴 것\\s+[0-9]+건이야",
    "mailDraft": "메일\\s*초안",
    "mailWaiting": "(발송|전송|보내)\\s*(하지|지)\\s*않았|(발송|전송)(은|이)?\\s*(승인\\s*)?전|승인\\s*전|아직\\s*(안\\s*)?(발송|전송|보내|보냈)|발송\\s*대기",
    "mailSent": "(발송|전송)(을|이|은)?\\s*(했|완료|됐|마쳤|끝났)|(?<!안\\s)(?<!안)보냈(어|습니다|어요|다)",
    "thinking": "^[◐◓◑◒🤔\\s]*생각\\s*중\\s*(\\.{2,}|…)?\\s*$",
    "approval1": "승인(을|이)?\\s*((만|좀|다시|한\\s*번\\s*더)\\s*)*(하면|해\\s*줘(?!서)|해\\s*주|해\\s*줄래|해\\s*\\?|부탁|기다|필요|요청|할래|할까|바라|받아야|줘(?!서)|주면)",
    "approval2": "승인[^\\n.!?]{0,14}?(이?라고|한\\s*마디)만?\\s*((다시|한\\s*번(\\s*더|만)?|정확히|꼭|바로|그냥)\\s*)*(((답(장|변)?|말씀?|입력)\\s*)?(해((?![가-힣])|\\s*(줘(?!서)|주))|하면)|(보내|적어|남겨|써|알려)((?![가-힣])|\\s*(줘(?!서)|주))|보내면|적으면|남기면|쓰면)",
    "learningReport1": "(?:답변 원칙|배운 일하는 방법|배워서 바로 반영한 내용)\\s+[0-9]+건이야",
    "learningReport2": "(?<![가-힣A-Za-z])학습승인(?=[^가-힣A-Za-z]|이라고|으로|이라|은)[^\\n]{0,160}(?:답해(?!서)|답하면|알려\\s*줘(?!서)|남겨\\s*줘(?!서)|적어\\s*줘(?!서)|검토해(?!서))"
  },
  "sets": {
    "settled": [
      "답변 완료",
      "종결"
    ],
    "yes": [
      "승인",
      "전송",
      "발송",
      "발송해",
      "승인, 발송해",
      "응",
      "응응",
      "ㅇㅇ",
      "네",
      "예",
      "좋아",
      "진행",
      "그래",
      "오케이",
      "ok",
      "yes"
    ],
    "workingStatus": [
      "답변 받음"
    ],
    "closedStatus": [
      "✅ 처리 완료",
      "처리 완료 · 종결"
    ]
  },
  "numbers": {
    "longThread": 50,
    "alertWindow": 86400
  }
}
"""#
    private var values: [String: Any]
    private let expressions: [String: NSRegularExpression]
    let problems: [String]
    init(raw: Any?) {
        var result = Self.defaults
        var errors: [String] = []
        let input = raw as? [String: Any] ?? [:]
        let version = input["schema"] as? NSNumber
        let supported = version?.doubleValue == 1 && version.map { CFGetTypeID($0) != CFBooleanGetTypeID() } == true
        if raw != nil && !supported { errors.append("conversation.schema") }
        if supported {
            for group in ["texts", "colors", "sets", "numbers", "patterns"] {
                guard let supplied = input[group] else { continue }
                guard let supplied = supplied as? [String: Any] else { errors.append("conversation." + group); continue }
                var entries = Self.defaults[group] as! [String: Any]
                for key in entries.keys {
                    guard let value = supplied[key] else { continue }
                    var valid = false
                    switch group {
                    case "texts", "patterns": valid = (value as? String).map { !$0.isEmpty } ?? false
                    case "colors":
                        valid = (value as? String).map { $0.count == 7 && $0.first == "#" && $0.dropFirst().allSatisfy { $0.isHexDigit } } ?? false
                    case "sets": valid = value is [String]
                    case "numbers":
                        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                            valid = number.doubleValue.isFinite && number.doubleValue > 0 &&
                                (key != "longThread" || (number.doubleValue.rounded() == number.doubleValue && number.doubleValue < Double(Int.max)))
                        }
                    default: break
                    }
                    if valid { entries[key] = value } else { errors.append("conversation." + group + "." + key) }
                }
                result[group] = entries
            }
        }
        var compiled: [String: NSRegularExpression] = [:]
        var patterns = result["patterns"] as! [String: String]
        for (key, pattern) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) { compiled[key] = regex }
            else {
                errors.append("conversation.patterns." + key)
                let fallback = (Self.defaults["patterns"] as! [String: String])[key]!
                patterns[key] = fallback
                compiled[key] = try! NSRegularExpression(pattern: fallback)
            }
        }
        result["patterns"] = patterns
        values = result; expressions = compiled; problems = errors.sorted()
    }
    func text(_ key: String) -> String { (values["texts"] as! [String: String])[key]! }
    func color(_ key: String) -> String { (values["colors"] as! [String: String])[key]!.uppercased() }
    func list(_ key: String) -> [String] { (values["sets"] as! [String: [String]])[key]! }
    func number(_ key: String) -> Double { ((values["numbers"] as! [String: Any])[key] as! NSNumber).doubleValue }
    func matches(_ key: String, _ text: String) -> Bool {
        expressions[key]?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
