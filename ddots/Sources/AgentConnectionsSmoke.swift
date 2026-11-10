import AppKit
import SwiftUI
import Carbon
import Vision

enum AgentConnectionsSmoke {
    static var document: AgentConnectionDocument {
        let states: [AgentConnectionItem.State] = [.needsReconnect, .connected, .unknown, .off, .notConnected]
        let rows = states.enumerated().map { index, state in
            AgentConnectionItem(id: "item-\(index)", service: ["google", "notion", "mail_read", "synology", "slack"][index], label: ["Google · 회사", "Notion", "Mail 앱", "시놀로지", "Slack 봇"][index],
                reason: state == .unknown ? "MAC_PERMISSION_UNVERIFIED" : "SCOPE_MISSING", checked_at: "2026-11-07T00:00:00Z",
                group: index == 2 ? .mac : index == 4 ? .channel : .account, state: state,
                account: "example@example.test", scope: .company, reconnect: index == 0 ? .company : nil,
                capabilities: ["연결 상태를 확인합니다."], rules: ["소유자의 동의는 브라우저에서 직접 진행합니다."],
                connect_kind: ["oauth", "secret", "mac_permission", "secret", "channel"][index], verified_by: "config",
                actions: [[ConnectionAction(id: "oauth_connect", label: "다시 연결", primary: true), ConnectionAction(id: "check", label: "확인", primary: false)],
                          [ConnectionAction(id: "check", label: "확인", primary: true), ConnectionAction(id: "secret_set", label: "토큰 바꾸기", primary: false)],
                          [ConnectionAction(id: "permission_request", label: "권한 요청", primary: true), ConnectionAction(id: "check", label: "확인", primary: false)],
                          [],
                          [ConnectionAction(id: "gateway_restart", label: "다시 시작", primary: true), ConnectionAction(id: "check", label: "확인", primary: false)]][index])
        }
        return AgentConnectionDocument(schema: "hermes-connections/1", checked_at: "2026-11-07T00:00:00Z",
            agents: (1...6).map { AgentConnectionProfile(profile: "agent-\($0)", display_name: "시험 에이전트 \($0)", connections: rows) })
    }
}

extension AppDelegate {
    @MainActor func verifyAgentConnections(destination: URL) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            smokeCheck(menuItem(titled: "에이전트 연결…") != nil, "Agent connections has a pet menu entry")
            for (title, key) in [("설정…", ","), ("ddots 종료", "q"), ("에이전트 연결…", "")] {
                smokeCheck(menuItem(titled: title)?.keyEquivalent == key, "Menu shortcut: " + title)
            }
            if !chatExpanded { showChat() }
            panel.makeKeyAndOrderFront(nil)
            showAgentConnections()
            try? await Task.sleep(nanoseconds: 400_000_000)
            smokeCheck((agentConnectionsWindow?.level.rawValue ?? 0) > panel.level.rawValue, "Connections stays above the floating conversation")
            let panelLevel = panel.level
            for _ in 0..<2 {
                NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
                smokeCheck(agentConnectionsWindow?.level == .normal, "Inactive connections returns to normal level")
                NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                smokeCheck((agentConnectionsWindow?.level.rawValue ?? 0) > panel.level.rawValue, "Active connections returns above conversation")
            }
            agentConnectionsWindow?.close()
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
            smokeCheck(agentConnectionsWindow?.level == .normal, "Closed connections is not raised on activation")
            showAgentConnections()
            smokeCheck(panel.level == panelLevel, "Connection activation never changes conversation level")
            let first = agentConnectionsWindow
            showOptions()
            settingsTabs?.selectTabViewItem(withIdentifier: "연결과 동기화")
            @MainActor func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == "에이전트 연결…" { return button }
                for child in view.subviews { if let button = find(child) { return button } }
                return nil
            }
            var button: NSButton?
            if let content = optionsWindow?.contentView { button = find(content) }
            smokeCheck(button != nil, "Agent connections has a settings entry")
            button?.performClick(nil)
            smokeCheck(first === agentConnectionsWindow, "Both entries open the same window")
            optionsWindow?.orderOut(nil)
            try? await Task.sleep(nanoseconds: 400_000_000)
            smokeCheck(agentConnectionsWindow?.isKeyWindow == true, "Connections activates when opened")
            smokeCheck(agentConnectionsModel?.document?.agents.count == 6, "Synthetic roster renders six agents")
            @MainActor func captureWindow(_ name: String) {
                guard let view = agentConnectionsWindow?.contentView else { return }
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent(name + ".png"))
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                agentConnectionsWindow?.appearance = NSAppearance(named: appearance)
                try? await Task.sleep(nanoseconds: 200_000_000)
                captureWindow(name)
            }
            agentConnectionsModel?.detail = "item-0"
            try? await Task.sleep(nanoseconds: 200_000_000)
            captureWindow("detail")
            agentConnectionsModel?.selection = "mac"
            agentConnectionsModel?.loadPermissions()
            try? await Task.sleep(nanoseconds: 400_000_000)
            captureWindow("permissions")
            // Real model orchestration, fake command and browser boundary only.
            let lock = NSLock(); var actions: [String] = [], opened = 0
            let fake = AgentConnectionsModel(remote: nil, readOnly: false, fixture: AgentConnectionsSmoke.document,
                runCommand: { arguments, _, _ in
                    lock.lock(); actions.append(arguments[1]); lock.unlock()
                    return Data((arguments[1] == "start" ?
                        #"{"state":"running","url":"https://accounts.google.com/o/oauth2/auth?state=synthetic"}"# :
                        #"{"state":"connected"}"#).utf8)
                }, openLogin: { _ in opened += 1; return true })
            fake.reconnect(AgentConnectionsSmoke.document.agents[0].connections[0])
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            smokeCheck(actions == ["start", "status"] && opened == 1 && fake.reconnecting.isEmpty,
                       "Reconnect runs start, opens a validated URL once, polls status, then stops")
            // Action buttons against the real model, with a fake command: busy rows, results, secrets, restart.
            let doc = AgentConnectionsSmoke.document
            let agentA = doc.agents[0], notion = agentA.connections[1], mail = agentA.connections[2], slack = agentA.connections[4]
            let canary = "SECRET-CANARY-smoke-" + UUID().uuidString
            let commandLock = NSLock(); var runs: [[String]] = [], stdins: [Data?] = []
            let gate = DispatchSemaphore(value: 0); var hold = false, settingsOpened: [URL] = [], restartAsked = 0, restartAnswer = false
            let actionModel = AgentConnectionsModel(remote: nil, readOnly: false, fixture: doc,
                runCommand: { arguments, input, _ in
                    commandLock.lock(); runs.append(arguments); stdins.append(input); let wait = hold; commandLock.unlock()
                    if wait { gate.wait() }
                    switch (arguments[0], arguments[1]) {
                    case ("check", "--profile"):
                        if arguments.contains("--all") {
                            return Data(#"{"action":"check","outcome":"done","reason":"OK","results":[{"action":"check","connection":"item-1","outcome":"done","reason":"OK","check":{"state":"connected","reason":"NOTION_VERIFIED"}},{"action":"check","connection":"item-2","outcome":"done","reason":"OK","check":{"state":"not_connected","reason":"PERMISSION_DENIED"}}]}"#.utf8)
                        }
                        return Data(#"{"action":"check","outcome":"done","reason":"OK","check":{"state":"connected","reason":"NOTION_VERIFIED"}}"#.utf8)
                    case ("secret", "guide"):
                        return Data(#"{"action":"secret_guide","outcome":"done","reason":"OK","fields":[{"id":"token","label":"Integration 비밀값","secure":true}],"guide":{"steps":["복사해요."],"link":"https://example.test/integrations"}}"#.utf8)
                    case ("secret", "set"):
                        let typed = String(data: input ?? Data(), encoding: .utf8) ?? ""
                        return Data((typed.contains(canary) && typed.contains("good") ?
                            #"{"action":"secret_set","outcome":"done","reason":"OK","saved_names":["NOTION_API_KEY"],"restart_required":false,"undo_until":"2099-01-01T00:00:00Z"}"# :
                            #"{"action":"secret_set","outcome":"refused","reason":"TOKEN_INVALID"}"#).utf8)
                    case ("permission", "settings"):
                        return Data(#"{"action":"open_settings","outcome":"done","reason":"OK","url":"x-apple.systempreferences:com.apple.preference.security?Privacy_Automation","instruction":"목록에서 켜 주세요."}"#.utf8)
                    case ("permission", "request"):
                        return Data(#"{"action":"permission_request","outcome":"done","reason":"OK","check":{"state":"connected","reason":"PERMISSION_GRANTED"}}"#.utf8)
                    case ("gateway", "restart"):
                        return Data(#"{"action":"gateway_restart","outcome":"done","reason":"OK","connected":7}"#.utf8)
                    default: throw ConnectionFailure.command
                    }
                }, openSettings: { settingsOpened.append($0); return true }, confirmRestart: { restartAsked += 1; return restartAnswer })
            actionModel.document = doc
            @MainActor func settle(_ what: String, _ condition: () -> Bool) async {
                for _ in 0..<40 { if condition() { return }; try? await Task.sleep(nanoseconds: 50_000_000) }
                smokeCheck(false, "Timed out: " + what)
            }
            hold = true
            let checkAction = notion.action(.check)!
            actionModel.perform(checkAction, item: notion, agent: agentA)
            actionModel.perform(checkAction, item: notion, agent: agentA)
            smokeCheck(actionModel.isBusy(agentA, notion) && !actionModel.isBusy(agentA, mail), "A pressed row is busy and no other row is")
            try? await Task.sleep(nanoseconds: 150_000_000)
            commandLock.lock(); let started = runs.count; commandLock.unlock()
            smokeCheck(started == 1, "A busy row ignores a second press")
            hold = false; gate.signal()
            await settle("check result") { actionModel.results["agent-1/item-1"] != nil }
            smokeCheck(actionModel.results["agent-1/item-1"] == ActionNotice(success: true, text: "연결을 확인했어요.") && !actionModel.isBusy(agentA, notion), "Check ends with one sentence and frees the row")
            smokeCheck(runs[0] == ["check", "--profile", "agent-1", "--connection", "item-1", "--json"], "Check runs the connection's own command line")
            actionModel.checkAll(agentA)
            await settle("check all") { actionModel.results["agent-1/*"] != nil }
            smokeCheck(runs.last?.contains("--all") == true && actionModel.results["agent-1/item-2"]?.success == false && actionModel.results["agent-1/*"]?.success == false, "Check all fills each row and a summary")
            actionModel.perform(mail.action(.permissionRequest)!, item: mail, agent: agentA)
            await settle("permission request") { actionModel.results["agent-1/item-2"]?.text == "Mac 권한이 허용됐어요." }
            actionModel.perform(ConnectionAction(id: "open_settings", label: "시스템 설정", primary: true), item: mail, agent: agentA)
            await settle("open settings") { !settingsOpened.isEmpty }
            smokeCheck(settingsOpened.first?.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_") == true, "Settings opens a privacy pane")
            let before = runs.count
            actionModel.perform(slack.action(.gatewayRestart)!, item: slack, agent: agentA)
            smokeCheck(restartAsked == 1 && runs.count == before, "Restart asks first and does nothing when declined")
            restartAnswer = true
            actionModel.perform(slack.action(.gatewayRestart)!, item: slack, agent: agentA)
            await settle("restart") { actionModel.results["agent-1/item-4"]?.success == true }
            smokeCheck(runs.last == ["gateway", "restart", "--json"], "Confirmed restart runs the gateway command")
            // Secret entry: values travel as stdin only and are wiped on success.
            var clipboardScope: [Bool] = []
            actionModel.secretEntryScope = { clipboardScope.append($0) }
            actionModel.perform(notion.action(.secretSet)!, item: notion, agent: agentA)
            await settle("secret guide") { actionModel.secretEntry != nil }
            smokeCheck(clipboardScope == [true] && actionModel.secretEntry?.fields.first?.secure == true, "Entry window opens with a secure field and pauses clipboard history")
            actionModel.secretEntry?.input.values = ["token": canary + " wrong"]
            actionModel.submitSecret(actionModel.secretEntry!.input.values)
            await settle("refused") { actionModel.secretEntry?.error != nil }
            smokeCheck(actionModel.secretEntry?.submitting == false && actionModel.secretEntry?.error?.contains("저장하지 않았어요") == true, "A refused value keeps the window open with the reason")
            actionModel.secretEntry?.input.values = ["token": canary + " good"]
            actionModel.submitSecret(actionModel.secretEntry!.input.values)
            await settle("saved") { actionModel.secretEntry == nil && actionModel.undoable["agent-1/item-1"] != nil }
            smokeCheck(clipboardScope == [true, false] && actionModel.results["agent-1/item-1"]?.text.contains("저장했어요") == true, "Saved value closes the window, restores clipboard history and offers undo")
            commandLock.lock(); let setIndex = runs.lastIndex { $0.first == "secret" && $0[1] == "set" }!; commandLock.unlock()
            smokeCheck(!runs.joined().joined().contains(canary) && stdins[setIndex].flatMap { String(data: $0, encoding: .utf8) }?.contains(canary) == true, "The secret reached the command through stdin only")
            actionModel.undoSecret(agent: agentA, item: notion)
            await settle("undo") { runs.last == ["secret", "undo", "--profile", "agent-1", "--connection", "item-1", "--json"] }
            smokeCheck(actionModel.undoable["agent-1/item-1"] == nil, "Undo clears the offer")
            // Installed apps: the page reads only the apps command, leads to the connection page, and is absent on another Mac.
            let appsJSON = #"{"schema":"hermes-installed-apps/1","scanned_at":"2026-11-07T00:00:00Z","apps":[{"name":"Mail","bundle_id":"com.apple.mail","kind":"mac","features":{"applescript":true,"app_intents":true,"url_schemes":true},"links":[{"profile":"agent-1","connection":"item-2","state":"unknown"},{"profile":"agent-2","connection":"item-2","state":"off"}]},{"name":"Synology Drive Client","bundle_id":"com.example.drive","kind":"mac","features":{"applescript":false,"app_intents":false,"url_schemes":false},"links":[{"profile":"agent-1","connection":"item-3","state":"off"}]},{"name":"Safari","bundle_id":"com.apple.Safari","kind":"mac","features":{"applescript":true,"app_intents":false,"url_schemes":true},"links":[]},{"name":"Calculator","bundle_id":"com.apple.calculator","kind":"mac","features":{"applescript":false,"app_intents":true,"url_schemes":false},"links":[]}]}"#
            var appRuns: [[String]] = [], appsFail = false
            let appModel = AgentConnectionsModel(remote: nil, readOnly: false, fixture: doc, runCommand: { arguments, _, _ in
                commandLock.lock(); appRuns.append(arguments); commandLock.unlock()
                if appsFail { throw ConnectionFailure.command }
                guard arguments == AppConnectionCommands.apps(selfID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID) else { throw ConnectionFailure.command }
                return Data(appsJSON.utf8)
            })
            appModel.document = doc
            appModel.loadApps()
            await settle("apps list") { appModel.apps != nil }
            smokeCheck(appModel.apps?.connectable.map(\.name) == ["Mail", "Synology Drive Client"] && appModel.apps?.others.count == 2 && appRuns == [AppConnectionCommands.apps(selfID: Bundle.main.bundleIdentifier ?? AppIdentity.bundleID)],
                       "Installed apps are read once with the apps command and grouped")
            appModel.openApp(InstalledApp.Link(profile: "agent-2", connection: "item-2", state: .off))
            smokeCheck(appModel.selection == "agent-2" && appModel.detail == "item-2", "An app row opens that agent's connection page")
            appModel.openApp(InstalledApp.Link(profile: "ghost", connection: "item-2", state: .off))
            appModel.openApp(InstalledApp.Link(profile: "agent-1", connection: "gone", state: .off))
            smokeCheck(appModel.selection == "agent-1" && appModel.detail == nil, "A stale link never opens a missing connection")
            appsFail = true; appModel.apps = nil; appModel.loadApps()
            await settle("apps failure") { appModel.appsError != nil }
            smokeCheck(appModel.appsError?.hasPrefix("앱 목록을 읽지 못했어요.") == true && appModel.apps == nil, "A failed read says so with the reason")
            appsFail = false; appModel.appsError = nil; appModel.loadApps()
            await settle("apps reload") { appModel.apps != nil }
            appModel.selection = "apps"; appModel.otherAppsOpen = true
            agentConnectionsWindow?.contentView = NSHostingView(rootView: AgentConnectionsView(model: appModel))
            try? await Task.sleep(nanoseconds: 500_000_000)
            captureWindow("apps")
            // Phase 2 uses the real model and views with only the CLI boundary replaced.
            let groupedJSON = #"""
            {"schema":"hermes-installed-apps/1","scanned_at":"now","apps":[],"agents":[
              {"profile":"agent-1","role_hint":"직책 안내 · 연결할 앱은 직접 골라요","connected":[],"unavailable":[],"connectable":[
                {"bundle_id":"test.fixture.app","name":"시험 앱","state":"connectable","route":"sdef","can_do":"시험 항목 읽기·만들기","rules":["앱 고유 안내"],"tools":["mac_app"]}]}]}
            """#
            let flowJSON = #"""
            {"profile":"agent-1","app":"test.fixture.app","outcome":"waiting","reason":"CHOOSE_SCOPE","steps":[
              {"id":"enable","label":"연결 켜기","state":"done","needs_user":false},
              {"id":"values","label":"쓸 곳 고르기","state":"todo","reason":"직접 골라 주세요","needs_user":true,"hint":"쓸 곳을 골라 주세요. 모두 선택할 수도 있어요."},
              {"id":"check","label":"실제로 확인","state":"todo","needs_user":false}],
             "next":{"kind":"choose_scope","multi":true,"options":[{"id":"one","label":"시험 폴더"},{"id":"two","label":"동기화 필요","disabled":true,"hint":"이 Mac에 먼저 동기화해 주세요"}]},"undo_until":null}
            """#
            var appArguments: [[String]] = []
            var pendingAppsJSON: Data? = nil
            let flowModel = AgentConnectionsModel(remote: nil, readOnly: false, fixture: doc, runCommand: { arguments, _, _ in
                if arguments.first == "apps" { return pendingAppsJSON ?? Data(groupedJSON.utf8) }
                appArguments.append(arguments); return Data(flowJSON.utf8)
            })
            flowModel.document = doc; flowModel.selection = "agent-1"; flowModel.loadApps()
            await settle("employee apps") { flowModel.apps?.agents?.count == 1 }
            agentConnectionsWindow?.contentView = NSHostingView(rootView: AgentConnectionsView(model: flowModel))
            try? await Task.sleep(nanoseconds: 300_000_000)
            captureWindow("employee-apps")
            let fixtureApp = flowModel.apps!.agents![0].connectable[0]
            flowModel.appDetail = fixtureApp
            flowModel.appAction("connect", app: fixtureApp, profile: "agent-1")
            await settle("app connect stages") { flowModel.appReply != nil }
            smokeCheck(appArguments == [AppConnectionCommands.action("connect", profile: "agent-1", app: fixtureApp.key)], "App connect uses only the app CLI and no implicit selections")
            smokeCheck(flowModel.appReply?.steps[1].needs_user == true && flowModel.appReply?.next.options?.last?.disabled == true,
                       "Needs-user progress and disabled unsynced choices reach the view")
            try? await Task.sleep(nanoseconds: 300_000_000)
            captureWindow("employee-app-scope")
            // Reopening, foregrounding and refresh all consume facility progress;
            // the app does not inspect gateway processes, logs or limiter files.
            var pendingDocument = try! JSONSerialization.jsonObject(with: Data(groupedJSON.utf8)) as! [String: Any]
            var pendingAgents = pendingDocument["agents"] as! [[String: Any]]
            var pendingRows = pendingAgents[0]["connectable"] as! [[String: Any]]
            var pendingReply = try! JSONSerialization.jsonObject(with: Data(flowJSON.utf8)) as! [String: Any]
            pendingReply["next"] = ["kind": "resume", "action": "connect"]
            pendingReply["steps"] = [
                ["id": "enable", "label": "연결 켜기", "state": "done", "needs_user": false],
                ["id": "restart", "label": "다시 시작", "state": "done", "needs_user": false],
                ["id": "permission", "label": "권한 허용", "state": "todo", "needs_user": true]]
            pendingRows[0]["progress"] = pendingReply; pendingAgents[0]["connectable"] = pendingRows
            pendingDocument["agents"] = pendingAgents
            pendingAppsJSON = try! JSONSerialization.data(withJSONObject: pendingDocument)
            flowModel.appReply = nil; flowModel.loadApps()
            await settle("pending progress reread") { flowModel.appReply?.next.kind == "resume" }
            smokeCheck(flowModel.appReply?.steps.first(where: { $0.id == "restart" })?.state == "done", "Reopened detail draws the facility's completed restart")
            try? await Task.sleep(nanoseconds: 300_000_000)
            captureWindow("employee-app-resume")
            pendingAppsJSON = nil
            flowModel.appAction("connect", app: fixtureApp, profile: "agent-1")
            await settle("pending resume command") { !flowModel.appWorking && appArguments.count == 2 }
            smokeCheck(appArguments.last == AppConnectionCommands.action("connect", profile: "agent-1", app: fixtureApp.key), "Continue resumes the same app connect without a restart request")
            // Synthetic credentials only: exercise native editors, refresh and real stage transitions.
            let loginJSON = #"""
            {"profile":"agent-1","app":"test.fixture.app","outcome":"waiting","reason":"VALUES_REQUIRED","steps":[
              {"id":"address","label":"주소","state":"done","needs_user":false},
              {"id":"login","label":"로그인","state":"todo","needs_user":true}],
             "next":{"kind":"secret_set","fields":[{"id":"user","label":"시험 아이디","secure":false},{"id":"password","label":"시험 비밀번호","secure":true}]}}
            """#
            flowModel.appReply = try! AppConnectionReply.decode(Data(loginJSON.utf8))
            guard let inputWindow = agentConnectionsWindow else { smokeFailed("Missing connections window") }
            inputWindow.setContentSize(NSSize(width: 760, height: 850))
            NSApp.activate(ignoringOtherApps: true); inputWindow.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            @MainActor func inputFields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? view.subviews.flatMap { inputFields($0) }
            }
            @MainActor func editors() -> [NSTextField] { inputFields(inputWindow.contentView!) }
            smokeCheck(editors().count == 2, "Synthetic login exposes two native input editors")
            smokeCheck(!(editors()[0] is NSSecureTextField) && editors()[1] is NSSecureTextField,
                       "Facility keeps the ID plain and the password protected")
            // Source selection is confined to this isolated smoke and restored afterwards.
            let originalSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
            defer { TISSelectInputSource(originalSource) }
            let sources = TISCreateInputSourceList([kTISPropertyInputSourceIsEnabled: true] as CFDictionary, false).takeRetainedValue() as! [TISInputSource]
            func inputSource(_ id: String) -> TISInputSource {
                guard let source = sources.first(where: {
                    guard let property = TISGetInputSourceProperty($0, kTISPropertyInputSourceID) else { return false }
                    return (Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String) == id
                }) else { smokeFailed("Missing input source for input guidance smoke: " + id) }
                return source
            }
            @MainActor func hintVisible(_ view: NSView) -> Bool {
                // SwiftUI's drawn Text is absent from this host's native accessibility children.
                // Read the synthetic screen, never a field's stringValue or any real credential.
                view.layoutSubtreeIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { smokeFailed("Hint screen bitmap missing") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let image = bitmap.cgImage else { smokeFailed("Hint screen image missing") }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.recognitionLanguages = ["ko-KR", "en-US"]
                request.usesLanguageCorrection = false; request.minimumTextHeight = 0.008
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { smokeFailed("Synthetic hint recognition failed") }
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().filter { !$0.isWhitespace }
                return text.contains("한글입력") && text.contains("비밀번호") && text.contains("ABC")
            }
            let koreanSource = inputSource("com.apple.inputmethod.Korean.2SetKorean")
            let asciiSource = inputSource("com.apple.keylayout.ABC")
            smokeCheck(TISSelectInputSource(koreanSource) == noErr, "Smoke selects its Korean fixture source")
            smokeCheck(inputWindow.makeFirstResponder(editors()[1]), "Password editor accepts focus")
            await settle("password Korean source hint") { hintVisible(inputWindow.contentView!) }
            captureWindow("employee-app-password-korean-hint")
            smokeCheck(TISSelectInputSource(asciiSource) == noErr, "Smoke selects its ASCII fixture source")
            await settle("password ASCII source hides hint") { !hintVisible(inputWindow.contentView!) }
            captureWindow("employee-app-password-ascii")
            smokeCheck(TISSelectInputSource(koreanSource) == noErr, "Smoke restores Korean fixture for focus check")
            await settle("password hint returns on source notification") { hintVisible(inputWindow.contentView!) }
            smokeCheck(inputWindow.makeFirstResponder(editors()[0]), "Plain ID editor accepts focus")
            await settle("plain ID does not show password hint") { !hintVisible(inputWindow.contentView!) }
            // The account-entry sheet uses the same focus/source component.
            let hintWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
            hintWindow.isReleasedWhenClosed = false
            let entry = SecretEntry(profile: "agent-1", agent: "시험 직원", connection: "fixture-secret", label: "시험 계정",
                fields: [AgentActionReply.Field(id: "password", label: "시험 비밀번호", secure: true)], guide: nil)
            hintWindow.contentView = NSHostingView(rootView: SecretEntryView(entry: entry, input: entry.input, submit: { _ in }, cancel: {}))
            hintWindow.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(hintWindow.makeFirstResponder(inputFields(hintWindow.contentView!)[0]), "Account secret editor accepts focus")
            await settle("account secret Korean source hint") { hintVisible(hintWindow.contentView!) }
            smokeCheck(TISSelectInputSource(asciiSource) == noErr, "Smoke changes its source for account hint")
            await settle("account secret ASCII hides hint") { !hintVisible(hintWindow.contentView!) }
            hintWindow.close()
            TISSelectInputSource(originalSource)
            inputWindow.makeKeyAndOrderFront(nil)
            let idEditor = editors()[0]
            smokeCheck(inputWindow.makeFirstResponder(idEditor), "Login editor accepts first responder")
            for (character, code) in [("t", UInt16(17)), ("e", UInt16(14)), ("s", UInt16(1)), ("t", UInt16(17))] {
                let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: inputWindow.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!
                NSApp.sendEvent(key)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            let typed = editors()[0].stringValue == "test"
            let diagnostic: [String: Any] = ["active": NSApp.isActive, "key": inputWindow.isKeyWindow, "main": inputWindow.isMainWindow,
                "syntheticTypingAccepted": typed, "fieldCount": editors().count]
            try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("app-input-diagnostic.json"))
            smokeCheck(typed, "Native key events reach the login binding")
            smokeCheck(!flowModel.appReply!.next.canSubmit([:]) && !flowModel.appReply!.next.canSubmit(["user": "test"]),
                       "Continue rejects empty required fields and ID without password")
            flowModel.appReply = try! AppConnectionReply.decode(Data(loginJSON.utf8))
            flowModel.refresh(); flowModel.loadApps()
            try? await Task.sleep(nanoseconds: 500_000_000)
            smokeCheck(editors()[0].stringValue == "test", "Equal pending response preserves typed input")
            // Reason text may change during retries while the facility still asks for the same fields.
            flowModel.appReply = try! AppConnectionReply.decode(Data(loginJSON.replacingOccurrences(of: "VALUES_REQUIRED", with: "AUTH_FAILED").utf8))
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(editors()[0].stringValue == "test", "Same input stage preserves text when the reason changes")
            var observations: [[String: Any]] = []
            let inputStart = Date()
            for seconds in [0.0, 2, 5, 10] {
                let wait = seconds - Date().timeIntervalSince(inputStart)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                observations.append(["seconds": seconds, "active": NSApp.isActive, "key": inputWindow.isKeyWindow,
                    "main": inputWindow.isMainWindow, "testRetained": editors()[0].stringValue == "test",
                    "inputStageUnchanged": flowModel.appReply?.inputStage == (try? AppConnectionReply.decode(Data(loginJSON.utf8)))?.inputStage])
                smokeCheck(editors()[0].stringValue == "test", "Pending input survives time and refresh")
            }
            try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("app-input-retention.json"))
            captureWindow("employee-app-input-preserved")
            let changedStage = loginJSON.replacingOccurrences(of: "\"id\":\"user\"", with: "\"id\":\"other\"")
            flowModel.appReply = try! AppConnectionReply.decode(Data(changedStage.utf8))
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(editors()[0].stringValue.isEmpty, "Different input fields clear the previous stage")
            flowModel.appReply = try! AppConnectionReply.decode(Data(loginJSON.utf8))
            try? await Task.sleep(nanoseconds: 300_000_000)
            smokeCheck(editors()[0].stringValue.isEmpty, "Returning to previous fields never restores discarded input")
            flowModel.appReply = try! AppConnectionReply.decode(Data(flowJSON.utf8))
            await settle("leaving synthetic secure entry") { !flowModel.appSecretActive }
            var secretScopes: [Bool] = []
            flowModel.secretEntryScope = { secretScopes.append($0) }
            flowModel.updateAppSecretScope(true); flowModel.updateAppSecretScope(true); flowModel.updateAppSecretScope(false)
            smokeCheck(secretScopes == [true, false], "Secret steps pause clipboard once and restore its earlier state once")
            smokeCheck(ReplyButtonPolicy.allowed(["확인", "되돌리기"], body: "*🔴 앱 쓰기 결과*"), "App write result buttons use the conversation button policy")
            let settingsJSON = #"""
            {"profile":"agent-1","app":"test.fixture.app","outcome":"waiting","reason":"ACCOUNT_LOGIN_REQUIRED","steps":[
              {"id":"values","label":"계정 추가","state":"todo","needs_user":true,"hint":"직접 계정을 추가해 주세요"}],
             "next":{"kind":"open_settings","pane":"internet_accounts","url":"x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension","hint":"인터넷 계정에서 직접 추가하고 돌아와 주세요"},"undo_until":null}
            """#
            var openedSettings: [URL] = [], accountResumes: [[String]] = []
            let accountModel = AgentConnectionsModel(remote: nil, readOnly: false, fixture: doc,
                runCommand: { arguments, _, _ in
                    if arguments.first == "apps" { return Data(groupedJSON.utf8) }
                    accountResumes.append(arguments); return Data(flowJSON.utf8)
                }, openSettings: { openedSettings.append($0); return true })
            accountModel.document = doc; accountModel.selection = "agent-1"; accountModel.appDetail = fixtureApp
            accountModel.appReply = try? AppConnectionReply.decode(Data(settingsJSON.utf8))
            agentConnectionsWindow?.contentView = NSHostingView(rootView: AgentConnectionsView(model: accountModel))
            try? await Task.sleep(nanoseconds: 300_000_000)
            captureWindow("internet-accounts")
            accountModel.openAppSettings(accountModel.appReply!.next, app: fixtureApp, profile: "agent-1")
            accountModel.resumeAppSettings(); accountModel.resumeAppSettings()
            await settle("settings foreground resume") { !accountModel.appWorking && !accountResumes.isEmpty }
            smokeCheck(openedSettings.count == 1 && accountResumes == [AppConnectionCommands.action("connect", profile: "agent-1", app: fixtureApp.key)],
                       "Settings URL comes from the facility; return resumes once without an account or scope selection")
            let hidden = AgentConnectionsModel(remote: nil, readOnly: true, fixture: doc, runCommand: { _, _, _ in fatalError("Another Mac never reads the app list") })
            hidden.loadApps()
            smokeCheck(!hidden.showsInstalledApps && hidden.apps == nil && !hidden.appsLoading, "Another Mac neither shows nor reads installed apps")
            let remote = AgentConnectionsModel(remote: nil, readOnly: true, fixture: AgentConnectionsSmoke.document,
                runCommand: { _, _, _ in fatalError("Read-only relay must not run a local command") })
            remote.reconnect(AgentConnectionsSmoke.document.agents[0].connections[0])
            smokeCheck(remote.reconnecting.isEmpty, "Remote connection cannot start login")
            for connection in agentA.connections {
                for action in connection.actions ?? [] where action.kind != .check {
                    remote.perform(action, item: connection, agent: agentA)
                }
            }
            smokeCheck(remote.busy.isEmpty && remote.secretEntry == nil && remote.results.isEmpty, "Read-only Mac runs no local action but check")
            let remoteItem = agentA.connections[1]
            remote.perform(remoteItem.action(.check)!, item: remoteItem, agent: agentA)
            smokeCheck(remote.results["agent-1/item-1"]?.text.contains("업데이트") == true, "An old sharing Mac gets update guidance")
            var asked: [String] = []
            remote.results = [:]
            remote.remoteCheck = { profile, connection in
                asked.append(profile + "/" + (connection ?? "*"))
                let reply = #"{"action":"check","connection":"item-1","outcome":"done","reason":"OK","check":{"state":"connected","reason":"NOTION_VERIFIED"}}"#
                return [try AgentActionReply.decode(Data(reply.utf8))]
            }
            remote.perform(remoteItem.action(.check)!, item: remoteItem, agent: agentA)
            remote.checkAll(agentA)
            try? await Task.sleep(nanoseconds: 600_000_000)
            smokeCheck(asked == ["agent-1/item-1", "agent-1/*"] && remote.results["agent-1/item-1"]?.success == true && remote.results["agent-1/*"] != nil,
                       "Read-only Mac asks the sharing Mac to check one connection and all of them")
            agentConnectionsWindow?.contentView = NSHostingView(rootView: AgentConnectionsView(model: remote))
            try? await Task.sleep(nanoseconds: 300_000_000)
            captureWindow("remote")
            if let path = ProcessInfo.processInfo.environment["DDOTS_INPUT_GUIDE_FIXTURES"],
               let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let fixtures = try? JSONDecoder().decode([String: AgentActionReply].self, from: data) {
                NSApp.appearance = NSAppearance(named: .aqua)
                agentConnectionsWindow?.appearance = NSAppearance(named: .aqua)
                for name in fixtures.keys.sorted() {
                    let reply = fixtures[name]!
                    smokeCheck(reply.guide?.items.isEmpty == false, "Facility input guide has numbered steps")
                    let entry = SecretEntry(profile: "agent-1", agent: "시험 직원", connection: name, label: name,
                        fields: reply.fields ?? [], guide: reply.guide)
                    entry.input.values = ["token": "wrong", "bot_token": "wrong", "app_token": "wrong", "api_base": "wrong"]
                    agentConnectionsWindow?.setContentSize(NSSize(width: 760, height: 800))
                    agentConnectionsWindow?.contentView = NSHostingView(rootView: SecretEntryView(entry: entry, input: entry.input, submit: { _ in }, cancel: {}))
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    captureWindow("guide-" + name)
                    if name == "ddots_slack" {
                        let dialog = SlackConnectDialog(connected: false, clipboard: NSPasteboard(name: .init("guide-smoke")), guideReply: reply)
                        dialog.field.stringValue = "wrong"
                        dialog.controlTextDidChange(Notification(name: NSText.didChangeNotification))
                        smokeCheck(dialog.alert.buttons.first?.isEnabled == false && dialog.status.stringValue.contains("4번"), "Real Slack dialog rejects a malformed token with the facility step number")
                        dialog.alert.layout()
                        dialog.alert.window.appearance = NSAppearance(named: .aqua)
                        let view = dialog.alert.window.contentView!
                        view.layoutSubtreeIfNeeded()
                        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: bitmap)
                            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("guide-ddots-dialog.png"))
                        }
                        dialog.alert.window.orderOut(nil)
                    }

                }
            }
            try? "PASS: shared entry points, six profiles, five states, light/dark, details, reconnect fake lifecycle, action buttons (check, check all, permission, settings, restart confirm, secret via stdin, undo), installed apps page (list, open connection, failure, hidden on another Mac), read-only remote (check relayed, nothing else). No real login or messages.\n".write(
                to: destination.appendingPathComponent("connections.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
