import AppKit

extension AppDelegate {
    func prepareFileDrop() {
        pet.installFileDrop(fileDrop)
        fileDropLocalEvents = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.fileDrop.visible else { return event }
            if event.window !== self.panel || !self.pet.fileDropContains(event.locationInWindow) { self.fileDrop.close() }
            return event
        }
        if !isSmoke { fileDrop.intake.recover() }
        fileDrop.onGeometry = { [weak self] in
            guard let self else { return }
            self.pet.updateFileDropPresentation(); self.updateClipboardGeometry()
            if self.fileDrop.visible {
                self.panel.makeKeyAndOrderFront(nil)
                if self.fileDropGlobalEvents == nil {
                    self.fileDropGlobalEvents = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.fileDrop.close() }
                }
            } else if let monitor = self.fileDropGlobalEvents { NSEvent.removeMonitor(monitor); self.fileDropGlobalEvents = nil }
        }
        fileDrop.profiles = { [weak self] in Set(self?.slack.model.ddotsMembers.map(\.profile) ?? []).intersection(FileDropRules.profiles) }
        fileDrop.profileName = { [weak self] profile in
            if profile == "app" { return "앱" }
            return self?.slack.model.ddotsMembers.first { $0.profile == profile }?.name ?? "에이전트"
        }
        fileDrop.avatar = { [weak self] profile in self?.chat.avatars[profile]?.image }
        fileDrop.onSelect = { [weak self] action in self?.performFileDrop(action) }
        fileDrop.onConfirm = { [weak self] yes in
            guard let self else { return }; self.fileDrop.confirmation = nil
            if yes { self.performFileDrop(.init(id: "attach_work", label: "업무에 붙이기", profile: self.fileDrop.primaryProfile)) }
            else { self.fileDrop.proposals = FileDropRules.rules(self.fileDrop.signals) }
        }
        fileDropEngines = [
            "mac": { [weak self] signals, _ in
                var enriched = signals
                if let context = try? await FileDropClaude.context(signals, home: DdotsConfig.shared.hermes, remote: self?.remoteHermes) {
                    enriched.memories = context.memories
                    if let roles = context.agentRoles { enriched.agentRoles = roles }
                    enriched.works = context.works ?? []
                    for (event, action) in context.outcomes { self?.fileDropHistory?.outcome(event: event, result: action) }
                }
                return try await FileDropRules.mac(enriched)
            },
            "claude": { [weak self] signals, files in
                try await FileDropClaude.request(signals, files: files, home: DdotsConfig.shared.hermes, remote: self?.remoteHermes)
            }
        ]
        fileDropSettings.onEnabled = { [weak self] value in self?.fileDrop.enabled = value; if !value { self?.fileDrop.close() } }
        fileDropSettings.onEngine = { [weak self] value in self?.configureFileDropEngine(value) }
        fileDropSettings.onClear = { [weak self] in
            guard let self else { return }
            let alert = NSAlert(); alert.messageText = "끌어놓기 습관을 지울까요?"; alert.informativeText = "쌓인 선택과 내 지시 버튼을 지워요. 다른 Mac에도 반영돼요."
            alert.addButton(withTitle: "지우기"); alert.addButton(withTitle: "취소")
            if alert.runModal() == .alertFirstButtonReturn { self.fileDropHistory?.clear() }
        }
        fileDrop.enabled = fileDropSettings.enabled
        fileDrop.onPayload = { [weak self] in
            guard let self, let history = self.fileDropHistory else { return }
            history.begin(id: self.fileDrop.eventID, feature: self.fileDrop.signals.feature, engine: self.fileDrop.engineKind, names: self.fileDrop.signals.names, shown: self.fileDrop.proposals.map(\.id), profile: self.fileDrop.primaryProfile)
        }
        fileDrop.onAnswer = { [weak self] elapsed, failed in
            guard let self else { return }
            for (event, action) in self.fileDrop.outcomes { self.fileDropHistory?.outcome(event: event, result: action) }
            self.fileDropHistory?.answer(summary: self.fileDrop.summary, shown: self.fileDrop.proposals.map(\.id), elapsed: elapsed, failed: failed, works: self.fileDrop.signals.works)
        }
        fileDrop.onClose = { [weak self] in self?.fileDropHistory?.close() }
        fileDrop.enrich = { [weak self] signals in
            guard let history = self?.fileDropHistory else { return }
            signals.account = history.store.user
            signals.habits = history.habits(feature: signals.feature)
            signals.custom = history.customs(feature: signals.feature)
            signals.recent = history.recent().map { row in ["names": row.names.joined(separator: ", "), "summary": row.summary, "action": row.action ?? "", "opinion": row.opinion ?? "", "profile": row.profile, "result": row.result ?? ""] }
        }
        updateFileDropDefaultEngine()
    }
    func configureFileDropEngine(_ kind: String) {
        fileDrop.engineKind = kind
        fileDrop.engine = fileDropEngines[kind] ?? { _, _ in throw CocoaError(.featureUnsupported) }
    }
    func performFileDrop(_ selected: FileDropSuggestion) {
        var action = selected
        let card = fileDrop
        if action.id == "custom_instruction" {
            let original = action.instruction ?? action.label
            guard card.signals.custom.contains(original) else { return }
            action.label = original
        }
        fileDropHistory?.select(action.id, opinion: action.id == "opinion" || action.id == "custom_instruction" ? action.label : nil, profile: action.profile)
        switch action.id {
        case "reveal": NSWorkspace.shared.activateFileViewerSelecting(card.payload.files); card.close()
        case "copy_text":
            let board = card.pasteboard(); board.clearContents(); board.setString(card.signals.content, forType: .string)
            board.setData(Data(), forType: ClipboardPasteboard.generated); card.close()
        default:
            guard slack.connected else { card.notice = "Slack 연결이 필요해요"; return }
            guard let room = slack.model.pins.first ?? slack.model.ddotsHub else { card.notice = "맨 위에 고정한 채널이 필요해요"; return }
            let profile = FileDropRules.profiles.contains(action.profile) && slack.model.ddotsMembers.contains(where: { $0.profile == action.profile }) ? action.profile : Ddots.defaultTarget
            guard FileDropRules.profiles.contains(profile), let who = slack.model.ddotsMembers.first(where: { $0.profile == profile }) else { card.notice = "담당 에이전트 설정이 필요해요"; return }
            let s = card.signals
            let text = "📎 ddots 파일 맡김\n지시: \(action.label)\n파일: \(s.names.joined(separator: ", ")) (\(s.names.count)개)\n출처: \(s.source) / \(s.hosts.joined(separator: ", ")) / \(s.folder)\n연결 업무 후보: \(s.works.isEmpty ? "없음" : s.works.joined(separator: ", "))\n지시와 파일이 맞지 않거나 애매하면 실행 전에 [[버튼: 승인 | 거절 | 의견]]으로 물어봐 주세요." + (card.payload.text.isEmpty ? "" : "\n\n맡긴 글:\n" + card.payload.text)
            let post = Ddots.post(text, to: who, cast: slack.model.ddotsMembers, users: slack.model.ddotsUsers, members: slack.model.members[room] ?? [], prependCall: true)
            if let absent = Ddots.absent(post, cast: slack.model.ddotsMembers, users: slack.model.ddotsUsers, members: slack.model.members[room] ?? []) { card.notice = absent.name + " 에이전트가 이 채널에 없어요"; return }
            guard !post.called.isEmpty else { card.notice = "에이전트 멘션을 확인할 수 없어요"; return }
            guard !card.sending else { return }
            card.cancelAnalysis(); card.sending = true; card.status = "보내는 중"
            let request = card.request
            slack.sendFiles(text, room: room, thread: nil, files: card.payload.files, routedPost: post, selectedProfile: profile) { [weak self] ts, files, failure in
                guard let self else { return }
                self.fileDrop.sending = false
                if failure == nil {
                    self.fileDropWatch.assignments.append(.init(room: room, ts: ts, files: files, profile: profile, label: action.label, event: self.fileDropHistory?.current))
                    self.fileDropWatch.onChange?()
                }
                if !self.fileDrop.visible { self.fileDrop.close(notify: false) }
                guard self.fileDrop.request == request else { return }
                if let failure { self.fileDrop.notice = failure; self.fileDrop.status = ""; return }
                self.fileDrop.status = who.name + "에게 맡겼어요"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    guard let self, self.fileDrop.request == request else { return }; self.fileDrop.close(notify: false)
                }
            }
        }
    }
    func updateFileDropDefaultEngine() {
        fileDropSettings.updateDefault(claudeAvailable: !isSmoke && (remoteHermes?.supportsDrop == true || FileDropRunner.available(DdotsConfig.shared.hermes)))
        configureFileDropEngine(fileDropSettings.engine)
    }
    func bindFileDropHistory(force: Bool = false, user: String? = nil, folder: URL? = nil, device: String? = nil) {
        let account = user ?? slack.settings?.user ?? "local"
        if !force, fileDropHistory?.store.user == account { return }
        let root = folder ?? (remoteHermes == nil ? FileDropHistory.folder(home: DdotsConfig.shared.hermes) : SettingsStore.folder.deletingLastPathComponent().appendingPathComponent("file-drop"))
        guard let store = SettingsStore(user: account, folder: root) else { return }
        let history = FileDropHistory(store: store, device: device ?? SlackController.syncDevice)
        fileDropHistory = history; fileDropWatch.device = history.device
        history.send = { [weak self] user, entries in self?.remoteHermes?.sendDropSync(user: user, entries: entries) }
        history.onChange = { [weak self, weak history] in
            guard let self, let history else { return }
            self.fileDropWatch.assignments = history.assignments()
            self.fileDropSettings.comparisons = history.comparisons()
        }
        fileDropWatch.onChange = { [weak self] in
            guard let self else { return }; self.fileDropHistory?.saveAssignments(self.fileDropWatch.assignments)
        }
        history.refresh(); fileDropWatch.assignments = history.assignments(); fileDropSettings.comparisons = history.comparisons()
        history.sendAll()
    }
    @objc func openFileDropText() {
        if chatExpanded { collapseChat() }
        fileDrop.openText()
    }
}
