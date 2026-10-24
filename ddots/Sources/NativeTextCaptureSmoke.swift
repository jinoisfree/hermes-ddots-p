import AppKit

extension AppDelegate {
    /// The same in-memory timeline feeds both renderers; no send or record-write path is used.
    @MainActor func captureNativeTextComparisons(destination: URL) async {
        let model = slack.model
        let threads = model.threads, expanded = chat.expandedReplies
        let appearance = NSApp.appearance
        let highlight = model.findHighlight
        let savedSize = pet.chatSize
        let comparisonSize = CGSize(width: 400 + slackStrip, height: 400)
        let prefix = NativeListFeature.enabled ? "new" : "old"
        func settle() async { try? await Task.sleep(nanoseconds: 600_000_000) }
        func shot(_ name: String, top: String? = nil) async {
            resizeChat(to: comparisonSize)
            await settle()
            if let scroll = model.scrollView {
                model.scrollInputAt = ProcessInfo.processInfo.systemUptime; model.userScrolls += 1
                let end = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
                let target = top.flatMap { model.rowFrame($0)?.minY } ?? end
                let y = min(max(0, target.rounded()), end)
                scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                await settle()
            }
            let folder = destination.appendingPathComponent(name)
            capture(destination:folder)
            var frames = chat.smokeFrames.filter { $0.key.hasPrefix("copy-") || $0.key.hasPrefix("copy-link-") || $0.key.hasPrefix("reply-") }
            func collect(_ view: NSView) {
                if let card = view as? NativeThreadCard { frames.merge(card.diagnosticButtonFrames) { _, new in new } }
                for child in view.subviews { collect(child) }
            }
            if NativeListFeature.enabled, let scroll = model.scrollView { frames = [:]; collect(scroll) }
            var geometry = "window=\(pet.chatSize) viewport=\(String(describing: model.scrollView?.contentView.bounds))\n"
            for key in frames.keys.sorted() { geometry += "\(key)=\(frames[key]!)\n" }
            try? geometry.write(to: folder.appendingPathComponent("frames.txt"), atomically: true, encoding: .utf8)
            do { try Data(contentsOf:folder.appendingPathComponent("chat.png")).write(to:destination.deletingLastPathComponent().appendingPathComponent(name+".png")) }
            catch { smokeFailed("Cannot capture native text comparison: " + name) }
        }
        for (theme, named) in [("dark",NSAppearance.Name.darkAqua),("light",NSAppearance.Name.aqua)] {
            NSApp.appearance = NSAppearance(named:named)
            model.threads = threads; model.findHighlight = nil; chat.expandedReplies = expanded
            model.requestScroll("slack-bottom"); await settle()
            await shot("\(prefix)-\(theme)-entry")
            guard var last = threads.last else { smokeFailed("Text comparison needs a synthetic card") }
            last.root.body = "**합성 긴 글** · `코드`\n" + String(repeating:"접기와 펼침의 줄 간격을 비교합니다.\n",count:24)
            model.threads[model.threads.count-1] = last
            chat.expandedReplies.remove(last.root.id)
            model.requestScroll("slack-bottom"); await settle()
            await shot("\(prefix)-\(theme)-folded")
            chat.toggleReply(last.root.id)
            model.requestScroll("slack-bottom"); await settle()
            await shot("\(prefix)-\(theme)-expanded", top: last.id)
            last.root.body = "합성 검색어 강조\n링크와 **검색어**를 같은 색으로 표시해요.\n[합성 문서](https://example.invalid/native)"
            model.threads[model.threads.count-1] = last
            model.findHighlight = (last.id,"검색어")
            model.requestScroll("slack-bottom"); await settle()
            await shot("\(prefix)-\(theme)-search")
            model.findHighlight = nil
            last.root.fromUser = true; last.latestFromUser = true
            last.root.body = "내가 작성한 합성 글입니다.\n**굵은 글**과 [링크](https://example.invalid/native)를 확인해요."
            model.threads[model.threads.count-1] = last
            model.requestScroll("slack-bottom"); await settle()
            await shot("\(prefix)-\(theme)-mine")
        }
        resizeChat(to: savedSize)
        NSApp.appearance = appearance
        chat.expandedReplies = expanded; model.findHighlight = highlight; model.threads = threads
        model.requestScroll("slack-bottom"); await settle()
    }
}
