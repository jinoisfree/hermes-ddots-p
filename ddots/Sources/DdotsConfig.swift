import Foundation

/// Local metadata only. No credential files or network requests are read here.
final class DdotsConfig {
    static let shared = DdotsConfig()
    let root: URL, hermes: URL
    private let lock=NSRecursiveLock()
    private var config:[String:Any]=[:], local:[String:Any]=[:]
    private var lastCheck=Date.distantPast
    private var problems:[String:String]=[:]
    private var revision=0
    var generation:Int { lock.lock();defer{lock.unlock()};return revision }
    init(root:URL?=nil,hermes:URL?=nil,home:URL=FileManager.default.homeDirectoryForCurrentUser) {
        let env=ProcessInfo.processInfo.environment
        let cloud=home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        var folder:ObjCBool=false
        let base=FileManager.default.fileExists(atPath:cloud.path,isDirectory:&folder) && folder.boolValue ? cloud:home.appendingPathComponent("Downloads")
        self.root=root ?? env["DDOTS_CONFIG_ROOT"].map{URL(fileURLWithPath:$0)} ?? base.appendingPathComponent("HermesWorkspace/ddots")
        self.hermes=hermes ?? env["HERMES_HOME"].map{URL(fileURLWithPath:$0)} ?? home.appendingPathComponent(".hermes")
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
                if isConfig{config=starter()}else{local=[:]};problems[name]=nil;continue
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
        var invalid:[String]=[]
        for (room,raw) in HermesRouting.dict(config["routing"]) {
            for (key,p) in HermesRouting.dict(HermesRouting.dict(raw)["patterns"]) {
                if let pattern=p as? String,!pattern.isEmpty,HermesRouting.regex(pattern)==nil{invalid.append(room+"."+key)}
            }
        }
        problems["regex"]=invalid.isEmpty ? nil:"사용할 수 없는 수신 규칙: "+invalid.sorted().joined(separator:", ")
        if !beforeConfig.isEqual(to:config) || !beforeLocal.isEqual(to:local) {revision += 1}
    }
    enum ConfigError:Error {case invalid}
    private func starter()->[String:Any] {
        let receipts=hermes.appendingPathComponent(".starter/receipts")
        let files=((try? FileManager.default.contentsOfDirectory(at:receipts,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        var members:[[String:Any]]=[]
        if let latest=files.last,let data=try? Data(contentsOf:latest),let receipt=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
            let destinations=HermesRouting.dict(receipt["destinations"]),defaultAgent=HermesRouting.str(receipt["default"])
            for agent in HermesRouting.strings(receipt["agents"]) {
                let relative=HermesRouting.str(destinations[agent]);guard !relative.isEmpty else{continue}
                let target=hermes.appendingPathComponent(relative).standardizedFileURL
                // Malformed/untrusted receipt cannot make this loader read outside its Hermes home.
                guard target.path==hermes.standardizedFileURL.path || target.path.hasPrefix(hermes.standardizedFileURL.path+"/") else{continue}
                let profile=agent==defaultAgent ? "default":target.lastPathComponent
                members.append(["profile":profile,"displayName":displayName(target) ?? agent,"aliases":[]])
            }
        }
        if members.isEmpty {
            let roots=[hermes]+(((try? FileManager.default.contentsOfDirectory(at:hermes.appendingPathComponent("profiles"),includingPropertiesForKeys:nil)) ?? []).filter{!$0.lastPathComponent.hasPrefix(".")}.sorted{$0.lastPathComponent<$1.lastPathComponent})
            for path in roots {if let name=displayName(path){members.append(["profile":path==hermes ? "default":path.lastPathComponent,"displayName":name,"aliases":[]])}}
        }
        let fallback=members.first(where: { $0["profile"] as? String == "default" })?["profile"] as? String ?? members.first?["profile"] as? String ?? ""
        let contract:[String:Any]=["profiles":["fallback":fallback],"aliases":[:],"patterns":[:]]
        return ["schemaVersion":1,"members":members,"routing":["base":contract,"hub":contract],"defaults":["recipient":fallback]]
    }
    private func displayName(_ home:URL)->String? {
        guard let text=try? String(contentsOf:home.appendingPathComponent("profile.yaml"),encoding:.utf8),let line=text.components(separatedBy:.newlines).first(where:{$0.hasPrefix("display_name:")}) else{return nil}
        let name=line.dropFirst("display_name:".count).trimmingCharacters(in:CharacterSet(charactersIn:" \t'\""));return name.isEmpty ? nil:name
    }
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
