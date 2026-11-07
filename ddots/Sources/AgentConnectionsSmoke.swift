import AppKit
import SwiftUI

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
                guard arguments == ConnectionCommands.apps else { throw ConnectionFailure.command }
                return Data(appsJSON.utf8)
            })
            appModel.document = doc
            appModel.loadApps()
            await settle("apps list") { appModel.apps != nil }
            smokeCheck(appModel.apps?.connectable.map(\.name) == ["Mail", "Synology Drive Client"] && appModel.apps?.others.count == 2 && appRuns == [ConnectionCommands.apps],
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
            try? "PASS: shared entry points, six profiles, five states, light/dark, details, reconnect fake lifecycle, action buttons (check, check all, permission, settings, restart confirm, secret via stdin, undo), installed apps page (list, open connection, failure, hidden on another Mac), read-only remote (check relayed, nothing else). No real login or messages.\n".write(
                to: destination.appendingPathComponent("connections.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
