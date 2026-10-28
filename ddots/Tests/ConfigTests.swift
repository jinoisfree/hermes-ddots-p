import Foundation
@main struct ConfigTests {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),home=root.appendingPathComponent("hermes"),record=root.appendingPathComponent("record")
        try FileManager.default.createDirectory(at:record,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let c=DdotsConfig(root:record,hermes:home,home:root)
        precondition(c.members.isEmpty && c.order.isEmpty && c.excluded.isEmpty)
        func write(_ value:[String:Any],_ path:URL)throws{try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true);try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:path,options:.atomic)}
        try write(["agents":["work-assistant","llm-wiki","system-doctor"],"default":"llm-wiki","destinations":["llm-wiki":".","work-assistant":"profiles/work-assistant","system-doctor":"profiles/system-doctor"]],home.appendingPathComponent(".starter/receipts/0001.json"))
        c.refresh();precondition(c.members.count==3 && c.recipient=="default")
        let config:[String:Any] = ["schemaVersion":1,"members":[["profile":"helper","displayName":"Helper","slackUserID":"B1"],["profile":"doctor","displayName":"Doctor","slackUserID":"B2"]],"routing":[:],"solo":["team_bots":["B1","B2"],"listener_bots":["B2"],"excluded_rooms":["HOME"]]]
        try write(config,record.appendingPathComponent("ddots-config.json"));c.refresh();precondition(c.members.count==2)
        precondition(c.matching("Helper")=="helper" && c.roomOwner(id:"ROOM",name:"room",users:["B1","B2"])=="helper")
        precondition(c.roomOwner(id:"ROOM",name:"room",users:["B2"])==nil && c.roomOwner(id:"HOME",name:"home",users:["B1"])==nil)
        try Data("broken".utf8).write(to:record.appendingPathComponent("ddots-config.json"));c.refresh();precondition(c.members.count==2 && !c.status.isEmpty)
        try write(["schemaVersion":1,"order":["helper"],"excluded":["doctor"],"colors":["helper":"#112233"]],record.appendingPathComponent("ddots-local.json"));c.refresh();precondition(c.order==["helper"] && c.excluded==["doctor"])
        try write(config,record.appendingPathComponent("ddots-config.json"));c.refresh();precondition(c.status.isEmpty)
        try FileManager.default.removeItem(at:record.appendingPathComponent("ddots-config.json"));c.refresh();precondition(c.members.count==3)
        try FileManager.default.removeItem(at:record.appendingPathComponent("ddots-local.json"));c.refresh()
        precondition(c.order.isEmpty && c.excluded.isEmpty && c.appearance.isEmpty)
        var changed=config;changed["members"]=[["profile":"helper","displayName":"Renamed","slackUserID":"B1"]]
        changed["routing"]=["base":["patterns":["broken":"(?P<invalid"]]]
        try write(changed,record.appendingPathComponent("ddots-config.json"));c.refresh()
        precondition(c.matching("Renamed")=="helper" && c.matching("Doctor")==nil && c.status.contains("base.broken"))
        if CommandLine.arguments.count > 1 {
            let installed=DdotsConfig(root:root.appendingPathComponent("absent-record"),hermes:URL(fileURLWithPath:CommandLine.arguments[1]),home:root)
            precondition(installed.members.count==3 && installed.recipient=="default")
            precondition(Set(installed.members.compactMap{$0["profile"] as? String})==["default","work-assistant","system-doctor"])
        }
        try ConversationRulesTests.run()
        print("ConfigTests passed: absent, starter, present, invalid preservation, reload, local values, solo membership changes")
    }
}

enum ConversationRulesTests {
    static func run() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = DdotsConfig(root: root, hermes: root.appendingPathComponent("home"), home: root)
        let initial = config.conversation
        precondition(initial.list("settled") == ["답변 완료", "종결"])
        precondition(initial.matches("approval1", "승인해줘"))
        precondition(initial.text("checklistSkip") == "건너뛰기")
        func write(_ conversation: [String: Any]) throws {
            let doc: [String: Any] = ["schemaVersion": 1, "members": [], "routing": [:], "conversation": conversation]
            try JSONSerialization.data(withJSONObject: doc).write(to: root.appendingPathComponent("ddots-config.json"), options: .atomic)
            config.refresh()
        }
        try write(["schema": 1, "sets": ["yes": ["go"], "settled": ["끝"]],
                   "patterns": ["approval1": "결재해", "mailDraft": "["]])
        precondition(config.conversation.list("yes") == ["go"])
        precondition(config.conversation.list("settled") == ["끝"])
        precondition(config.conversation.matches("approval1", "결재해"))
        precondition(!config.conversation.matches("approval1", "승인해줘"))
        precondition(config.conversation.matches("mailDraft", "메일 초안"))
        precondition(config.status.contains("conversation.patterns.mailDraft"))
        let cached = config.conversation, generation = config.generation
        config.refresh()
        precondition(config.conversation === cached && config.generation == generation)
        try write(["schema": 1, "numbers": ["alertWindow": -1, "longThread": true],
                   "colors": ["askingColor": "not a color"], "sets": ["yes": 10]])
        precondition(config.conversation.number("alertWindow") == 86400)
        precondition(config.conversation.number("longThread") == 50)
        precondition(config.conversation.color("askingColor") == "#E01E5A")
        precondition(config.conversation.list("yes").contains("승인"))
        try write(["schema": 2, "texts": ["checklistSkip": "ignored"]])
        precondition(config.conversation.text("checklistSkip") == "건너뛰기")
        try write(["schema": 1.5, "texts": ["checklistSkip": "ignored"]])
        precondition(config.conversation.text("checklistSkip") == "건너뛰기" && config.status.contains("conversation.schema"))
        print("ConversationRulesTests passed: defaults, overrides, isolated fallback, status, revision compilation cache, invalid types")
    }
}
