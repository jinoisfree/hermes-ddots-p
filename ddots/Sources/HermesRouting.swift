import Foundation

/// Model-free new-message preview. Does not claim threads, approve actions or send messages.
/// Port map (Hermes gateway): common_router.py 58 direct, 95 aliases, 128 assignment,
/// 190 fuzzy matching, 241 personal target, 257 classify, 449 select_profile;
/// common_router_intent.py 13–59 bounded assignment/write; project_requests.py 12–35 hub prose.
/// Pending approvals/locked threads are owned by the server and are not reclassified here.
enum HermesRouting {
    struct Decision: Equatable { var profile: String; var reason: String }
    static func dict(_ x: Any?) -> [String: Any] { x as? [String: Any] ?? [:] }
    static func str(_ x: Any?) -> String { x as? String ?? "" }
    static func strings(_ x: Any?) -> [String] { x as? [String] ?? [] }
    static func regex(_ p: String) -> NSRegularExpression? {
        guard !p.isEmpty else { return nil }
        // Python named captures and end-of-string spelling; ICU supports the exported lookbehinds.
        let p = p.replacingOccurrences(of: "(?P<", with: "(?<").replacingOccurrences(of: "\\Z", with: "\\z")
        return try? NSRegularExpression(pattern:p, options:[.caseInsensitive])
    }
    static func matches(_ p: String, _ s: String) -> [NSTextCheckingResult] {
        regex(p)?.matches(in:s,range:NSRange(s.startIndex...,in:s)) ?? []
    }
    static func has(_ p: String, _ s: String) -> Bool { !matches(p,s).isEmpty }
    static func replace(_ p: String, _ s: String, _ value: String = "") -> String {
        regex(p)?.stringByReplacingMatches(in:s,range:NSRange(s.startIndex...,in:s),withTemplate:value) ?? s
    }
    static func trim(_ s: String) -> String { s.trimmingCharacters(in:.whitespacesAndNewlines) }
    static func direct(_ s: String) -> String {
        trim(replace("```[\\s\\S]*?```",s).components(separatedBy:.newlines)
            .filter { !trim($0).isEmpty && !trim($0).hasPrefix(">") }.map { replace("`[^`]*`",$0) }.joined(separator:"\n"))
    }
    static func hubDirect(_ input: String) -> String {
        var s=input
        // Decode transport HTML entities before interpreting delimiters (no HTML execution).
        for (a,b) in [("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&amp;","&")] { s=s.replacingOccurrences(of:a,with:b) }
        for p in [#"\n\s*(?:[-=]{3,}\s*(?:\n|$)|<(?:html|body|div|table|span)\b)"#,
                  #"\n\s*(?:[-=]{2,}\s*(?:Original|Forwarded)|보낸\s*사람\s*:|From\s*:)"#] {
            if let m=matches(p,s).first, let r=Range(m.range,in:s) { s=String(s[..<r.lowerBound]) }
        }
        s=replace(#"(?s)<(html|body|div|table|style|blockquote)\b[^>]*>.*?</\1\s*>"#,s)
        return direct(s)
    }
    static func operation(_ s: String) -> String {
        var s=hubDirect(s)
        for p in [#"\([^()\n]*(?:연동|연결|참고)[^()\n]*\)"#,
                  #"기존\s+[^\n.!?]{0,100}?(?:연동|연결|참고)(?:만)?(?:\s*해줘)?"#,
                  #"(?:노션|notion)\s*(?:의\s*)?(?:내용|자료|기록)[^\n.!?]{0,30}?(?:참고|바탕|기반)(?:해서|으로|해)?"#] { s=replace(p,s) }
        return trim(replace(#"(?:메일|일정|메모)(?:이라는|라는|이라고\s*하는)\s*(?:열|칼럼|필드|속성)"#,s,"문서 열"))
    }
    static func aliases(_ c: [String:Any]) -> [(String,String)] {
        let mapping=dict(c["aliases"])
        let order=strings(c["alias_order"])
        let keys=order.isEmpty ? mapping.keys.sorted():order
        // Hermes appends profile identifiers AFTER all explicit aliases, and uses a stable length sort.
        let explicit=keys.flatMap { profile in strings(mapping[profile]).map { (trim($0),profile) } }
        let identifiers=keys.flatMap { [($0,$0),("@"+$0,$0)] }
        return (explicit+identifiers).filter{!$0.0.isEmpty}.enumerated().sorted {
            $0.element.0.count == $1.element.0.count ? $0.offset < $1.offset : $0.element.0.count > $1.element.0.count
        }.map{ $0.element }
    }

    static let assignmentAction = #"(?:해(?:줘|라|주세요)?|맡아(?:줘)?|담당해(?:줘)?|처리해(?:줘)?|확인해(?:줘)?|점검해(?:줘)?|찾아(?:줘)?|봐(?:줘)?|답해(?:줘)?|시켜(?:줘)?|알려줘|하고(?=\s*$))(?=$|[\s,.!?，。！？])"#
    static let artifact = #"(?:보낸|보내준|만든|알려준|올린|찾은|적은|읽은|(?:작성|정리|말|전달|공유|저장|등록|수정|검토|확인|추천|분석|요약|설명|첨부)(?:한|해준|해둔|했던|하던))\s+(?!(?:뒤|후|다음)(?:에|에는)?(?:\s|$))"#
    static func assigned(_ text: String, _ c: [String:Any]) -> Decision? {
        let text=direct(text), pairs=aliases(c)
        guard !text.isEmpty && !pairs.isEmpty else { return nil }
        let any=pairs.map { NSRegularExpression.escapedPattern(for:$0.0) }.joined(separator:"|")
        var found:[(String,String)]=[]
        func add(_ alias:String,_ reason:String) {
            let normalized=replace("\\s+",alias).lowercased()
            if let pair=pairs.first(where:{replace("\\s+",$0.0).lowercased()==normalized}) { found.append((pair.1,reason)) }
        }
        func capture(_ match:NSTextCheckingResult,_ name:String,_ s:String)->String {
            guard let r=Range(match.range(withName:name),in:s) else { return "" };return String(s[r])
        }
        for p in ["(?:^|\\s)이제\\s+(?<alias>\(any))(?:이|가)?\\s*(?:맡아|맡아줘|담당해)","담당자(?:를|는)?\\s+(?<alias>\(any))(?:으)?로\\s*(?:바꾸|변경)"] {
            for m in matches(p,text) { add(capture(m,"alias",text),"explicit_handoff") }
        }
        let lead="^(?<alias>\(any))(?:\\s*[,，:：!！?？]\\s*|\\s+|$)(?<rest>.*)$"
        let lines=text.components(separatedBy:.newlines).map(trim)
        for line in [lines.first,lines.last].compactMap({$0}) {
            guard let m=matches(lead,line).first else { continue }
            let rest=capture(m,"rest",line)
            if has("^(?:이랑|랑|와|과)\\s*(?:\(any))",rest) { continue }
            add(capture(m,"alias",line),"textual_profile")
            if let second=matches(lead,trim(rest)).first { add(capture(second,"alias",trim(rest)),"textual_profile") }
        }
        let subject="(?<![\\w])(?<subject>(?:\(any))(?:\\s*(?:이랑|랑|와|과)\\s*(?:\(any)))*)"
        for m in matches(subject+"(?:한테|에게|더러|보고|가|이|는|은|도)",text) {
            guard let range=Range(m.range,in:text) else { continue }
            var tail=String(text[range.upperBound...])
            if let next=matches("(?<![\\w])(?:\(any))",tail).first,let r=Range(next.range,in:tail) { tail=String(tail[..<r.lowerBound]) }
            if let stop=matches("[\\n.!?，。！？;]",tail).first,let r=Range(stop.range,in:tail) { tail=String(tail[..<r.lowerBound]) }
            guard let a=matches(assignmentAction,tail).first,let r=Range(a.range,in:tail),tail[..<r.upperBound].count<=64,
                  tail[..<r.lowerBound].split(whereSeparator:{$0.isWhitespace}).count<=6,!has(artifact,String(tail[..<r.lowerBound])) else {continue}
            let names=capture(m,"subject",text)
            for n in matches(any,names) { if let r=Range(n.range,in:names) { add(String(names[r]),"textual_profile") } }
        }
        if Set(found.map{$0.0}).count>1 { return Decision(profile:str(dict(c["profiles"])["fallback"]),reason:"ambiguous_explicit_profiles") }
        return found.first.map { Decision(profile:$0.0,reason:$0.1) }
    }
    static func distance(_ a:String,_ b:String)->Int {
        let b=Array(b);var previous=Array(0...b.count)
        for (i,x) in a.enumerated() {var next=[i+1];for (j,y) in b.enumerated(){next.append(min(next[j]+1,previous[j+1]+1,previous[j]+(x==y ? 0:1)))};previous=next}
        return previous.last ?? 0
    }
    static func typo(_ category:String,_ text:String,_ c:[String:Any])->Bool {
        let t=dict(c["typo_correction"]);guard t["enabled"] as? Bool == true else{return false}
        let limit=max(0,min(2,t["max_distance"] as? Int ?? 1)), minimum=max(3,t["min_term_length"] as? Int ?? 3)
        for term in strings(dict(t["terms"])[category]) {
            let target=replace("\\s+",term).lowercased();guard target.count>=minimum else{continue}
            for m in matches("[0-9A-Za-z가-힣]+",text.lowercased()) {
                let lower=text.lowercased();guard let r=Range(m.range,in:lower) else{continue};let segment=Array(lower[r])
                for width in max(1,target.count-limit)...(target.count+limit) where width<=segment.count {
                    for start in 0...(segment.count-width) {let candidate=String(segment[start..<(start+width)]);if candidate != target && distance(candidate,target)<=limit{return true}}
                }
            }
        };return false
    }
    static func writing(_ text:String,_ pattern:String)->Bool {
        for m in matches(pattern,text) {
            guard let r=Range(m.range,in:text) else{continue}
            if has(#"(?:^|\s)(?:안|못)\s*$"#,String(text[..<r.lowerBound])) {continue}
            if has(#"^\s*(?:여부|내역|이력|기록|상태|(?:하)?지\s*(?:말|않|마)|(?:하)?면\s*안\s*(?:돼|되)|(?:했|됐|되었|하였)(?:는지|는\s*지|던|다는)|(?:된|한|했던|됐던)(?=\s|$))"#,String(text[r.upperBound...])){continue}
            return true
        };return false
    }
    static func decide(_ input:String,contract c:[String:Any])->Decision {
        let profiles=dict(c["profiles"]),patterns=dict(c["patterns"]),hub=c["hub_request_routing"] as? Bool == true
        let normalized=hub ? hubDirect(input):trim(input)
        let prefixes=dict(c["address_prefixes"])
        if prefixes["enabled"] as? Bool == true {
            for key in dict(prefixes["profiles"]).keys.sorted() {
                let profile=str(dict(prefixes["profiles"])[key])
                if profiles.values.contains(where:{str($0)==profile}) && !key.isEmpty && has("^\\s*"+NSRegularExpression.escapedPattern(for:key)+"(?:[ \\t:：]+|\\r?\\n|$|(?=[가-힣]))",normalized){return Decision(profile:profile,reason:"address_prefix")}
            }
        }
        if let result=assigned(normalized,c){return result}
        let text=hub ? operation(direct(normalized)):direct(normalized)
        func match(_ key:String)->Bool{has(str(patterns[key]),text)}
        func fuzzy(_ key:String)->Bool{typo(key,text,c)}
        func role(_ key:String)->String{str(profiles[key])}
        func result(_ key:String,_ reason:String)->Decision{Decision(profile:role(key),reason:reason)}
        let wiki=match("wiki_target") || match("wiki") || fuzzy("wiki_target")
        let data = !role("data_operations").isEmpty && match("data_target"), dataAction=match("data_action")
        let personal=(match("personal_target") || match("personal_operations") || fuzzy("personal_target")) && (!(match("data_target") && dataAction) || patterns["personal_request"] == nil || match("personal_request"))
        let company = !role("company_operations").isEmpty && (match("company_target") || fuzzy("company_target"))
        let personalRole = !role("personal_review").isEmpty && !writing(text,str(patterns["personal_write"])) ? "personal_review":"personal_operations"
        let wikiAction=match("wiki_action") || wiki,personalAction=match("personal_action") || personal, companyAction=match("company_action")
        var owners=Set<String>()
        for (matched,owner) in [(wiki && wikiAction,role("wiki")),(personal && personalAction,role(personalRole)),(company && companyAction,role("company_operations")),(data && dataAction,role("data_operations"))] where matched && !owner.isEmpty { owners.insert(owner) }
        if match("document_conversion"){return result("personal_operations","document_conversion")}
        if owners.count>=2 && match("cross_owner_connector"){return Decision(profile:str(dict(c["cross_owner"])["profile"]),reason:"cross_owner")}
        if wiki && wikiAction{return result("wiki","wiki")}
        if data && dataAction{return result("data_operations","data_operations")}
        if company && companyAction{return result("company_operations","company_operations")}
        if personal && personalAction{return result(personalRole,"personal_operations")}
        if match("coordination") || fuzzy("coordination"){return result("coordination","coordination")}
        return result("fallback","fallback")
    }
}
