import AppKit
import SwiftUI

/// Formatted message words, kept per message so scrolling and unrelated updates never parse Markdown again.
private enum NativeBodyCache {
    struct Key: Equatable {
        var body: String, term: String?, linkColor: String, quoteColors: [String], bar: String
        var folded: Bool, dark: Bool, mine: Bool, streaming: Bool
        var checklist: UInt64
    }
    struct Entry { var key: Key; var text: NSAttributedString; var checks: [Int: Bool] }
    static var entries: [String: Entry] = [:]
}

extension ChatView {
    /// What the native card draws for one thread, built from the same model state the SwiftUI card reads.
    func nativeThreadContent(_ original: SlackThread, inputs: SlackThreadInputs, target: Bool) -> NativeThreadCard.Content {
        let thread = slack.vault.hidingPageCommands(original)
        let displayed = SlackNotice.displayed(thread, confirmed: slack.confirmed)
        let expanded = slack.open.contains(thread.id)
        let shown = SlackStack.visible(displayed, expanded: expanded)
        // A character whose "생각 중" line is already in the thread is not shown writing twice.
        let thinkers = Set(thread.messages.filter { !$0.fromUser && (SlackText.isThinking($0.body) || $0.streaming) }.map(\.profile))
        let writing = (slack.typing[thread.id] ?? []).filter { !thinkers.contains($0.profile) }
        let answered = thread.replyCount > 0 || !writing.isEmpty
        let notice = slack.noticeMemo.assessment(thread, confirmed: slack.confirmed)
        let state = notice.state.map { mark in
            ChatMark(color: SlackNotice.railColor(thread, pending: notice.pending, state: mark) ?? mark.color, text: mark.text)
        }
        let tone = SlackNotice.railColor(thread, pending: notice.pending, state: state).flatMap { MessageFormat.color($0) } ?? displayed.root.marks.lazy.compactMap { MessageFormat.color($0.color) }.first
        let edge = SlackOwner.color(SlackOwner.profile(thread, members: slack.ddotsMembers)).map(NSColor.init)
        let foldable = thread.replyCount > SlackStack.inlineLimit || !thread.loaded
        let pending = notice.pending?.id
        let vaultLayout = slack.vault.presentation(thread, active: slack.vaultSelections(thread), visible: Set([displayed.root.id] + shown.replies.map(\.id)), pending: pending)
        let mine = thread.root.fromUser
        let flash = slack.flash == thread.id
        let quiet = Self.nativeQuiet(dark: inputs.dark)
        let pick: () -> Void = { slack.clickCard(thread, foldable: foldable) }
        let textClick: (() -> Void)? = foldable && !expanded ? {
            if !slack.open.contains(thread.id), let live = slack.threads.first(where: { $0.id == thread.id }) { slack.pick(live, foldable: true) }
        } : nil
        func host(_ id: String, _ view: @escaping () -> some View) -> NativeThreadCard.Piece {
            .hosted(id: id) { AnyView(view()
                .environment(\.colorScheme, inputs.dark ? .dark : .light)
                .environment(\.linkPointerEnabled, !SlackResizeSmoke.without("links"))
                .environment(\.openURL, OpenURLAction { url in model.onOpenLink?(url); return .handled })) }
        }
        var nativeShown = Set<String>()
        func pieces(for message: ChatMessage) -> [NativeThreadCard.Piece] {
            var result: [NativeThreadCard.Piece] = []
            if !vaultLayout.hidden.contains(message.id) {
                if var post = nativePost(message, inputs: inputs, edge: edge) {
                    post.conversational = !message.streaming && message.id != displayed.root.id && !message.fromUser && message.marks.isEmpty && ThreadAppearance.isConversational(message.body)
                    result.append(.post(post)); nativeShown.insert(message.id)
                }
                else { result.append(host("line:" + message.id) { slackLine(message, selectable: true, textClick: textClick) }) }
            }
            return result
        }
        func extras(for message: ChatMessage) -> [NativeThreadCard.Piece] {
            var result: [NativeThreadCard.Piece] = []
            if pending == message.id { result.append(host("approval:" + message.id) { slackApproval(thread) }) }
            if let selection = vaultLayout.anchors[message.id] { result.append(host("vault:" + message.id) { vaultButtons(thread, selection: selection) }) }
            if !slack.driveItems(message).isEmpty { result.append(host("drive:" + message.id) { driveButtons(thread, message: message) }) }
            // A post drawn natively keeps its calendar buttons underneath, as the SwiftUI line has them.
            if nativeShown.contains(message.id) {
                let calendar = model.actions(for: message).filter { $0.isCalendar }
                if !calendar.isEmpty { result.append(host("calendar:" + message.id) { calendarButtons(calendar).padding(.leading, ChatMetrics.avatar + 9).padding(.top, 2) }) }
            }
            return result
        }

        var top: [NativeThreadCard.Piece] = []
        top.append(host("digest:" + thread.id) { ThreadDigestView(thread: original) { slack.onLoadSummary?(original) } })
        if slack.isDdots, let project = slack.project(thread) {
            top.append(host("project:" + thread.id) { nativeProject(thread, project: project) })
        }
        if mine, slack.isDdots, let who = slack.ddotsOwner(thread) {
            top.append(.owner(name: who.name, avatar: Ddots.avatar(model.avatars[who.profile], name: who.name) ?? ProfileAvatar()))
        }
        top += pieces(for: displayed.root)
        top += extras(for: displayed.root)

        var replies: [NativeThreadCard.Piece]?
        if answered {
            var list: [NativeThreadCard.Piece] = []
            if shown.hidden > 0 {
                var seen = Set<String>()
                let faces = thread.replies.dropLast().filter { !$0.fromUser && seen.insert($0.profile + "/" + $0.speaker).inserted }.prefix(3)
                    .map { ($0.speaker, Ddots.avatar(model.avatars[$0.profile], name: $0.speaker) ?? ProfileAvatar()) }
                let title = thread.loaded ? "이전 답글 \(shown.hidden)개" : (expanded ? "답글 불러오는 중…" : "답글 \(shown.hidden)개")
                list.append(.stack(faces: Array(faces), title: title, toggle: { slack.toggle(thread) }, identifier: "stack-" + thread.id))
            }
            for reply in shown.replies { list += pieces(for: reply) + extras(for: reply) }
            for indicator in writing { list.append(host("typing:" + indicator.id) { typingBubble(indicator) }) }
            if let control = AgentStop.control(working: AgentStop.working(thread, typing: writing), stopped: slack.stopped.contains(thread.id)) {
                list.append(host("stop:" + thread.id) { stopControl(original, control: control) })
            }
            replies = list
        }

        // The thread's own buttons, as the SwiftUI foot offers them.
        var actions: [NativeThreadCard.Action] = []
        let accent = NSColor.controlAccentColor
        if slack.link(to: thread) != nil {
            let copied = slack.copied == "link-" + thread.id
            actions.append(.init(title: copied ? "복사됨" : "링크", symbol: copied ? "checkmark" : "link", label: "스레드 링크 복사",
                                 identifier: "copy-link-" + thread.id, color: copied ? accent : quiet, invoke: { slack.copyLink(thread) }))
        }
        let textCopied = slack.copied == "copy-" + thread.id
        actions.append(.init(title: textCopied ? "복사됨" : slack.copyWaiting == thread.id ? "불러오는 중…" : "복사", symbol: textCopied ? "checkmark" : "doc.on.doc",
                             label: "스레드 전체 복사", identifier: "copy-" + thread.id, color: textCopied ? accent : quiet, invoke: { slack.copy(thread) }))
        if !thread.ts.isEmpty, thread.messages.contains(where: { !$0.fromUser && !$0.profile.isEmpty }) {
            let asked = slack.branching == thread.id, long = thread.replyCount >= SlackNotice.longThread
            actions.append(.init(title: "분기", symbol: asked ? "checkmark" : "arrow.triangle.branch", label: "새 스레드로 이어가기",
                                 identifier: "branch-" + thread.id, enabled: !asked, color: asked ? accent : long ? .systemOrange : quiet, invoke: { slack.branch(thread) }))
        }
        actions.append(.init(title: "답글 \(thread.replyCount)개", symbol: "bubble.left", label: "답글 \(thread.replyCount)개, 이 스레드에 답글 쓰기",
                             identifier: "reply-" + thread.id, enabled: !thread.ts.isEmpty, color: quiet, alwaysLabel: true,
                             invoke: { slack.reply(thread) }))
        var deleting: String?
        if let going = slack.removing[thread.id] {
            deleting = going.total > 0 ? "삭제 중 \(going.done)/\(going.total)" : "삭제 중…"
        } else if !thread.ts.isEmpty, (thread.replyCount == 0 ? thread.root.fromUser : slack.picked == thread.id) {
            let sure = slack.confirmingDelete == thread.id
            actions.append(.init(title: sure ? "정말 삭제" : "삭제", symbol: "trash", label: sure ? "스레드 삭제 확인" : "스레드 삭제",
                                 identifier: "delete-" + thread.id, color: sure ? .systemRed : quiet, alwaysLabel: sure, invoke: { slack.delete(thread) }))
        }
        if foldable {
            actions.append(.init(title: expanded ? "접기" : "펼치기", symbol: expanded ? "chevron.up" : "chevron.down", label: expanded ? "접기" : "펼치기", identifier: "fold-" + thread.id, color: quiet, alwaysLabel: true,
                                 invoke: { slack.toggle(thread) }))
        }

        // Status belongs to the entire thread, even when folded or written by the owner.
        // The reply target is an independent blue outline; never recolour a state rail blue.
        let style = NativeThreadCard.Style(inset: ThreadAppearance.inset,
                                           fill: 0,
                                           stroke: flash || target ? accent : NSColor.labelColor.withAlphaComponent(inputs.dark ? 0.16 : 0.12),
                                           lineWidth: flash ? 2 : target ? 1.5 : 1,
                                           background: ThreadAppearance.surface(dark: inputs.dark), status: tone,
                                           replyBackground: ThreadAppearance.replySurface(dark: inputs.dark))
        let rail: NSColor? = nil
        return NativeThreadCard.Content(id: thread.id, top: top, replies: replies, rail: rail, actions: actions, deleting: deleting,
                                        style: style, bell: slack.bells[thread.id], onBell: { slack.onBell?(thread) },
                                        clickCard: pick, textClick: textClick, bubbleWidth: model.bubbleWidth, quiet: quiet, expanded: expanded, summary: threadSummary(thread, target: target),
                                        statusTitle: state.map { SlackNotice.displayStatus($0.text) } ?? "", replyTarget: target)
    }

    /// The project record above a thread in ddots, as the SwiftUI card shows it.
    @ViewBuilder func nativeProject(_ thread: SlackThread, project: ThreadProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.title).font(.system(size: ChatMetrics.auxiliaryFont, weight: .semibold))
            Text(project.statusText).font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
            DisclosureGroup("공동 기록") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("목표 · " + project.goal)
                    ForEach(Array((project.facts ?? []).enumerated()), id: \.offset) { _, fact in Text("공통 사실 · " + fact.text) }
                    ForEach(Array((project.decisions ?? []).enumerated()), id: \.offset) { _, decision in Text("확정 · " + decision.text) }
                    ForEach(project.tasks) { task in
                        let owner = slack.ddotsMembers.first { $0.profile == task.profile }?.name ?? "담당자"
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.title + " · " + owner + " · " + task.statusText).fontWeight(.medium)
                            if !task.summary.isEmpty { Text(task.summary) }
                            if let next = task.nextStep, !next.isEmpty { Text("다음 · " + next) }
                            ForEach(task.references ?? [], id: \.self) { reference in
                                if let url = URL(string: reference), ["https", "http"].contains(url.scheme) { Link("원본 보기", destination: url) }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.font(.system(size: ChatMetrics.auxiliaryFont))
            ForEach((project.approvals ?? []).filter(\.pending)) { approval in
                VStack(alignment: .leading, spacing: 4) {
                    Text("승인 대기 · " + (slack.ddotsMembers.first { $0.profile == approval.profile }?.name ?? "담당자"))
                    Text(approval.previewText ?? "스레드의 변경안을 확인해 주세요.").textSelection(.enabled)
                    HStack {
                        Button("이 변경 승인") { slack.projectChoice(thread, approval: approval, approve: true) }
                        Button("거부") { slack.projectChoice(thread, approval: approval, approve: false) }
                    }.disabled(!slack.connected)
                }.font(.system(size: ChatMetrics.auxiliaryFont)).padding(6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    static func nativeQuiet(dark: Bool) -> NSColor {
        var quiet = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.595)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            if let primary = NSColor.labelColor.usingColorSpace(.sRGB) { quiet = primary.withAlphaComponent(primary.alphaComponent * 0.7) }
        }
        return quiet
    }

    /// A status note's words: Markdown, links, in the given face.
    func nativeMarkText(_ text: String, font: NSFont, dark: Bool) -> NSAttributedString {
        let native = NSMutableAttributedString(attributedString: ChatText.linkifiedNative(MessageFormat.renderNative(text)))
        let full = NSRange(location: 0, length: native.length)
        native.enumerateAttribute(.font, in: full) { value, range, _ in
            let traits = (value as? NSFont).map { NSFontManager.shared.traits(of: $0) } ?? []
            native.addAttribute(.font, value: traits.contains(.boldFontMask) ? NSFont.systemFont(ofSize: font.pointSize, weight: .bold) : font, range: range)
        }
        native.enumerateAttribute(.link, in: full) { value, range, _ in
            if value != nil { native.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor(srgbRed: 0.3, green: 0.75, blue: 1, alpha: 1)], range: range) }
        }
        if native.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil, native.length > 0 {
            native.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        }
        return native
    }

    /// One message drawn natively, or nil when it carries something only the SwiftUI line shows:
    /// files, 새우튀김's pages and paths, or the writing dots. Calendar buttons go under it as their own piece.
    /// `edge` is the thread's own colour, which the post's outermost bars take.
    func nativePost(_ message: ChatMessage, inputs: SlackThreadInputs, edge: NSColor? = nil) -> NativeThreadCard.Post? {
        if SlackText.isThinking(message.body) && !message.fromUser { return nil }
        if !message.files.isEmpty || message.body.isEmpty { return nil }
        if slack.vault.trusted(message) || slack.vault.fallback(message) != nil || !slack.vault.pathLines(message).isEmpty { return nil }
        if message.fromUser && !message.marks.isEmpty { return nil }
        let palette = model.palette(message.profile, dark: inputs.dark)
        let term = slack.findTerm(message)
        let foldable = !message.streaming && !message.fromUser && LongReply.needsFolding(message.body)
        let folded = term == nil && foldable && !model.expandedReplies.contains(message.id)
        let shown = folded ? LongReply.preview(message.body) : message.body
        let body = message.fromUser ? shown : shown.trimmingCharacters(in: .newlines)
        let identity = message.fromUser ? message.id : message.id + ":block:0"
        let key = MessageChecklist.key(identity, text: message.body)
        let bar = edge ?? SlackOwner.color(message.profile).map(NSColor.init)
        let bodyKey = NativeBodyCache.Key(body: message.body, term: term, linkColor: palette.link.nsColor.description, quoteColors: message.quoteColors, bar: bar?.description ?? "",
            folded: folded, dark: inputs.dark, mine: message.fromUser, streaming: message.streaming, checklist: MessageChecklist.shared.revision)
        let entry: NativeBodyCache.Entry
        if let cached = NativeBodyCache.entries[identity], cached.key == bodyKey { entry = cached }
        else {
            entry = nativeBody(body, message: message, palette: palette, term: term, key: key, cacheKey: bodyKey, dark: inputs.dark, bar: bar)
            if NativeBodyCache.entries.count > 512 { NativeBodyCache.entries.removeAll(keepingCapacity: true) }
            NativeBodyCache.entries[identity] = entry
        }
        let checks = entry.checks
        let marks = message.fromUser ? [] : message.marks.map { mark in
            NativeThreadCard.Mark(color: MessageFormat.color(mark.color) ?? NSColor.labelColor.withAlphaComponent(0.35),
                                  text: nativeMarkText(SlackNotice.displayStatus(mark.text), font: .systemFont(ofSize: ChatMetrics.bodyFont), dark: inputs.dark))
        }
        return NativeThreadCard.Post(
            id: message.id, mine: message.fromUser, text: entry.text, speaker: message.speaker,
            time: message.pending ? (message.id.hasPrefix("slack") ? "보내는 중" : "보냄 · 기록 확인 중") : Self.time.string(from: message.date),
            avatar: Ddots.avatar(model.avatars[message.profile], name: message.speaker) ?? ProfileAvatar(),
            nameColor: palette.name.nsColor, pending: message.pending, interrupted: message.fromUser && message.replyInterrupted,
            marks: marks, foldTitle: foldable ? (folded ? "더 보기" : "접기") : nil, fold: { model.toggleReply(message.id) },
            flash: slack.flash == message.id,
            openLink: { url in
                if url.scheme == "ddots-check", let index = Int(url.lastPathComponent), let original = checks[index] {
                    MessageChecklist.shared.toggle(key, offset: index, original: original)
                    // Checklist state does not change the message revision or send a message.
                    slack.objectWillChange.send()
                } else if !slack.vaultPath(url, message: message), ChatText.mayOpen(url) {
                    slack.driveNote(url, message: message); model.onOpenLink?(url)
                }
            },
            reportHeight: foldable ? { model.measureReply(message.id, height: $0) } : nil)
    }

    private func nativeBody(_ body: String, message: ChatMessage, palette: CharacterPalette, term: String?, key: String,
                            cacheKey: NativeBodyCache.Key, dark: Bool, bar: NSColor?) -> NativeBodyCache.Entry {
        // A character's post is laid out as Slack lays out its blocks; my own bubble stays plain.
        let layout = message.fromUser || message.streaming ? nil : SlackLayout.strip(body)
        let native = message.streaming ? NSMutableAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: ChatMetrics.bodyFont), .foregroundColor: NSColor.labelColor]) : NSMutableAttributedString(attributedString: ChatText.linkifiedNative(MessageFormat.renderNative(layout?.source ?? body)))
        // Synology links read as the file's name, as the SwiftUI line titles them.
        if !message.fromUser {
            native.enumerateAttribute(.link, in: NSRange(location: 0, length: native.length), options: .reverse) { value, range, _ in
                guard let url = value as? URL ?? (value as? String).flatMap(URL.init(string:)),
                      let name = SynologyLink.components(of: url)?.last,
                      (native.attributedSubstring(from: range).string.lowercased()).hasPrefix("http") else { return }
                let attributes = native.attributes(at: range.location, effectiveRange: nil)
                native.replaceCharacters(in: range, with: NSAttributedString(string: name, attributes: attributes))
            }
        }
        let full = NSRange(location: 0, length: native.length)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = message.fromUser ? 0 : 2
        native.addAttribute(.paragraphStyle, value: paragraph, range: full)
        if message.fromUser {
            native.enumerateAttributes(in: full) { attributes, range, _ in
                if attributes[NSAttributedString.Key("ddots.explicitColor")] == nil { native.addAttribute(.foregroundColor, value: NSColor.white, range: range) }
            }
        }
        native.enumerateAttributes(in: full) { attributes, range, _ in
            if !message.fromUser, let font = attributes[.font] as? NSFont, NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) {
                native.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: ChatMetrics.bodyFont - 1, weight: .regular),
                    .foregroundColor: dark ? NSColor(srgbRed: 0.96, green: 0.68, blue: 0.36, alpha: 1) : NSColor(srgbRed: 0.76, green: 0.32, blue: 0.09, alpha: 1),
                    .backgroundColor: NSColor.labelColor.withAlphaComponent(0.1)], range: range)
            }
            if attributes[.link] != nil {
                native.addAttributes([.foregroundColor: message.fromUser ? NSColor(srgbRed: 0.72, green: 0.9, blue: 1, alpha: 1) : palette.link.nsColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
        }
        if let layout { SlackLayout.apply(to: native, lines: layout.lines, bar: bar, statuses: SlackLayout.statuses(for: message.body, colors: message.quoteColors), lineSpacing: 2) }
        if let term, !term.isEmpty {
            let highlighted = SlackSearch.highlighted(AttributedString(native.string), query: term)
            var offset = 0
            for run in highlighted.runs {
                let count = (String(highlighted[run.range].characters) as NSString).length
                if run.backgroundColor != nil { native.addAttributes([.backgroundColor: NSColor(Color.yellow), .foregroundColor: NSColor.black], range: NSRange(location: offset, length: count)) }
                offset += count
            }
        }
        var checks: [Int: Bool] = [:]
        var utf16 = 0
        for (index, character) in native.string.enumerated() {
            let length = String(character).utf16.count
            if !message.streaming && (character == "☐" || character == "☑") {
                let original = character == "☑"; checks[index] = original
                native.replaceCharacters(in: NSRange(location: utf16, length: length), with: MessageChecklist.shared.checked(key, offset: index, original: original) ? "☑" : "☐")
                native.addAttribute(.link, value: URL(string: "ddots-check://toggle/\(index)")!, range: NSRange(location: utf16, length: 1))
            }
            utf16 += length
        }
        return NativeBodyCache.Entry(key: cacheKey, text: NSAttributedString(attributedString: native), checks: checks)
    }
}
