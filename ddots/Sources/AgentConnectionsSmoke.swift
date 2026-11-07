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
                capabilities: ["연결 상태를 확인합니다."], rules: ["소유자의 동의는 브라우저에서 직접 진행합니다."])
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
                runCommand: { arguments in
                    lock.lock(); actions.append(arguments[1]); lock.unlock()
                    return Data((arguments[1] == "start" ?
                        #"{"state":"running","url":"https://accounts.google.com/o/oauth2/auth?state=synthetic"}"# :
                        #"{"state":"connected"}"#).utf8)
                }, openLogin: { _ in opened += 1; return true })
            fake.reconnect(AgentConnectionsSmoke.document.agents[0].connections[0])
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            smokeCheck(actions == ["start", "status"] && opened == 1 && fake.reconnecting.isEmpty,
                       "Reconnect runs start, opens a validated URL once, polls status, then stops")
            let remote = AgentConnectionsModel(remote: nil, readOnly: true, fixture: AgentConnectionsSmoke.document,
                runCommand: { _ in fatalError("Read-only relay must not reconnect") })
            remote.reconnect(AgentConnectionsSmoke.document.agents[0].connections[0])
            smokeCheck(remote.reconnecting.isEmpty, "Remote connection cannot start login")
            agentConnectionsWindow?.contentView = NSHostingView(rootView: AgentConnectionsView(model: remote))
            try? await Task.sleep(nanoseconds: 300_000_000)
            captureWindow("remote")
            try? "PASS: shared entry points, six profiles, five states, light/dark, details, reconnect fake lifecycle, read-only remote. No real login or messages.\n".write(
                to: destination.appendingPathComponent("connections.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}
