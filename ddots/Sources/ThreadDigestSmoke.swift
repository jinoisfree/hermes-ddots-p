import AppKit

extension AppDelegate {
    @MainActor func verifyThreadDigests(destination: URL) async {
        let store = ThreadDigestStore(), now = Date()
        let root = ChatMessage(id: "digest-root", fromUser: true, speaker: "나", body: "회의는 2시인가요?", date: now, profile: "")
        let reply = ChatMessage(id: "digest-reply", fromUser: false, speaker: "비서", body: "3시로 바뀌었어요.", date: now, profile: "test")
        var thread = SlackThread(id: "digest-test", room: "TEST", ts: "1", root: root, replies: [reply], replyCount: 1, loaded: false, latest: 1, latestFromUser: false)
        var calls = 0
        store.testProvider = { data in
            calls += 1
            let json = String(data: data, encoding: .utf8) ?? ""
            return .success(json.contains("4시") ? "회의가 최종 4시로 변경됐어요." : "회의가 2시에서 3시로 변경됐어요.")
        }
        var checks: [String] = []
        func check(_ condition: Bool, _ label: String) { smokeCheck(condition, label); checks.append("PASS: " + label) }
        func settle() async { try? await Task.sleep(nanoseconds: 150_000_000) }
        let incomplete = ThreadDigestInput(thread)
        var loads = 0
        store.loadIfNeeded(incomplete) { loads += 1 }; store.loadIfNeeded(incomplete) { loads += 1 }
        check(loads == 1, "Visible incomplete transcript is requested once")
        store.request(incomplete); await settle()
        check(calls == 0, "Incomplete threads never claim a full-conversation summary")
        thread.loaded = true
        var partial = thread; partial.replyCount = 2
        check(!ThreadDigestInput(partial).ready, "A cached partial page is never summarized as the whole conversation")
        let initial = ThreadDigestInput(thread)
        store.loadIfNeeded(initial) { loads += 1 }
        store.loadIfNeeded(incomplete) { loads += 1 }
        check(loads == 2, "Returning after transcript eviction can load again")
        check(String(data: initial.data, encoding: .utf8)?.contains("3시로 바뀌었어요") == true, "Summary input includes replies, not just the root")
        store.request(initial); await settle()
        check(store.entry(initial.key).text.contains("3시"), "Loading completes the pending summary")
        store.request(initial); await settle()
        check(calls == 1, "Unchanged thread reuses its summary")
        thread.replies[0].body = "4시로 바뀌었어요."
        let edited = ThreadDigestInput(thread)
        check(edited.fingerprint != initial.fingerprint, "Edits invalidate the full-transcript fingerprint")
        thread.replies[0].streaming = true
        store.request(ThreadDigestInput(thread)); await settle()
        check(calls == 1, "Streaming waits for the completed answer")
        thread.replies[0].streaming = false
        store.request(ThreadDigestInput(thread)); await settle()
        check(store.entry(edited.key).text.contains("4시") && calls == 2, "Final answer refreshes the summary")
        store.testProvider = { _ in .failure(ThreadDigestStore.DigestError.unavailable) }
        store.request(edited, force: true); await settle()
        check(store.entry(edited.key).text.contains("4시") && !store.entry(edited.key).state.isEmpty, "Failure keeps the previous summary and offers retry")
        store.testProvider = { _ in .success("다시 생성한 요약") }
        store.request(edited, force: true); await settle()
        check(store.entry(edited.key).text == "다시 생성한 요약", "Explicit retry replaces the failed result")
        store.testProvider = { data in
            let text = String(data: data, encoding: .utf8) ?? ""
            if text.contains("5시") { Thread.sleep(forTimeInterval: 0.2); return .success("오래된 요약") }
            return .success("최신 6시 요약")
        }
        thread.replies[0].body = "5시로 변경"
        store.request(ThreadDigestInput(thread)); try? await Task.sleep(nanoseconds: 40_000_000)
        thread.replies[0].body = "6시로 변경"
        store.request(ThreadDigestInput(thread)); try? await Task.sleep(nanoseconds: 350_000_000)
        check(store.entry(edited.key).text == "최신 6시 요약", "Late obsolete model response cannot overwrite the latest summary")
        let beforeStatus = ThreadDigestInput(thread)
        thread.replies[0].hermesReplyState = .closed
        check(ThreadDigestInput(thread).fingerprint != beforeStatus.fingerprint, "Status changes invalidate the summary too")
        for dark in [true, false] {
            let color = ThreadAppearance.surface(dark: dark).usingColorSpace(.sRGB)!
            check(abs(color.redComponent - color.blueComponent) < 0.001 && abs(color.redComponent - color.greenComponent) < 0.001, "Card background is neutral, dark=\(dark)")
        }
        try? checks.joined(separator: "\n").write(to: destination.appendingPathComponent("digest-checks.txt"), atomically: true, encoding: .utf8)
    }
}
