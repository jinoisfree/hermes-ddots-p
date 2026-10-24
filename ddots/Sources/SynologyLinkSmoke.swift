import AppKit

extension AppDelegate {
    /// Made-up links only. Nothing is sent, and neither Finder nor a file is opened.
    func verifySynologyLinks(destination: URL) {
        Task { @MainActor [self] in
            func link(_ path: String) -> String {
                var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._/")
                return "https://smoke.quickconnect.to/d/f/abc#drive=" + path.addingPercentEncoding(withAllowedCharacters: allowed)!
            }
            let model = slack.model
            var sent: [String] = [], shown: [URL] = []
            model.onSend = { text, _, _, _ in sent.append(text) }
            model.driveShow = { shown.append($0) }
            model.query = ""; model.draft = ""; model.replyTo = nil; model.picked = nil
            var one = ChatMessage(id: "drive-one", fromUser: false, speaker: "업무비서",
                body: "찾았어요! [시험 보고서.pdf](" + link("ddots 점검용 없는 폴더/시험 보고서.pdf") + ") 이 파일이에요.", date: Date(), profile: "work-assistant")
            one.slackUserID = "USMOKEHIPPO"
            var many = one; many.id = "drive-many"
            many.body = "폴더에 12개가 있어요.\n" + (1...12).map { "- " + link("ddots 점검용 없는 폴더/가짜 \($0).xlsx") }.joined(separator: "\n")
            let thread = SlackThread(id: "drive-thread", room: "CCOW", ts: "5", root: one, replies: [many],
                                     replyCount: 1, loaded: true, latest: Date().timeIntervalSince1970, latestFromUser: false)
            model.threads = [thread]; model.open = [thread.id]; model.reply(thread)
            let names = SynologyLink.actions.map(\.name)
            func frames(_ message: ChatMessage) -> [CGRect] { names.compactMap { chat.smokeFrames["drive-" + $0 + "-" + message.id] }.filter { $0.width > 0 } }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let first = frames(one)
            smokeCheck(first.count == 5 && first.allSatisfy { $0.width == 28 && $0.height == 24 }, "One linked file has five buttons the size of 새우튀김's")
            smokeCheck(first.count == 5 && first.map(\.midY).max()! - first.map(\.midY).min()! < 2, "The five buttons stay on one row")
            smokeCheck(model.driveItems(many).count == 12 && model.driveSelection(many, items: model.driveItems(many)) == nil, "Several files wait for one to be picked")
            capture(destination: destination.appendingPathComponent("one"))

            let item = model.driveItems(one)[0]
            model.driveAction("다운", item: item, message: one, thread: thread)
            model.driveAction("다운", item: item, message: one, thread: thread)
            smokeCheck(sent == ["다운로드: ddots 점검용 없는 폴더/시험 보고서.pdf"], "다운 asks once, in the thread, by the file's path")
            smokeCheck(model.driveAlreadySent("다운", item: item, message: one, thread: thread) && !model.driveAlreadySent("수정", item: item, message: one, thread: thread), "Only what was asked is spent")
            model.driveAction("경로", item: item, message: one, thread: thread)
            smokeCheck(shown.isEmpty && model.notice != nil, "A file that is not on this Mac is said to be missing")
            model.notice = nil

            model.shrimpListThread = nil; model.driveListMessage = many.id; web.showShrimpList()
            smokeCheck(model.driveList().count == 12 && model.driveList()[2].file == "가짜 3.xlsx", "The list at the right holds every linked file")
            model.driveChoose(3)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            smokeCheck(model.driveSelection(many, items: model.driveItems(many))?.name == "가짜 3.xlsx" && frames(many).count == 5, "A file picked from the list gets the five buttons")
            capture(destination: destination.appendingPathComponent("list"))

            model.driveAction("확인", item: item, message: one, thread: thread)
            try? await Task.sleep(nanoseconds: 600_000_000)
            smokeCheck(model.driveItems(one).isEmpty && model.driveItems(many).count == 12, "확인 puts away that message's buttons only")
            smokeCheck(sent.count == 1, "확인 sends nothing")
            capture(destination: destination.appendingPathComponent("confirmed"))
            NSApp.terminate(nil)
        }
    }
}
