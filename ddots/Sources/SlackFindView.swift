import SwiftUI

extension ChatView {
    var slackFindResults: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // What is found first is shown while the rest of the record is still being read.
                    Text(slack.findBusy && slack.findGroups.isEmpty ? "찾는 중…" : "스레드 \(slack.findGroups.count)개 · 글 \(slack.findGroups.reduce(0) { $0 + $1.matches.count })건" + (slack.findBusy ? " · 더 찾는 중…" : ""))
                        .font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                    if let progress = slack.findProgress {
                        Text(progress).font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet).accessibilityIdentifier("find-progress")
                    }
                    if slack.findGroups.isEmpty && !slack.findBusy {
                        Text("찾는 글이 없어요").font(.system(size: ChatMetrics.auxiliaryFont)).padding(.vertical, 20)
                    }
                    ForEach(Array(slack.findGroups.enumerated()), id: \.element.id) { index, group in
                        VStack(alignment: .leading, spacing: 8) {
                            Button { if let line = group.matches.first { slack.onFindReveal?(group, line) } } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(findRoom(group.room)).fontWeight(.semibold)
                                        Spacer()
                                        Text(group.latest, style: .date).foregroundColor(quiet)
                                    }.font(.system(size: ChatMetrics.auxiliaryFont))
                                    Text(findPreview(group.root.body)).font(.system(size: ChatMetrics.nameFont, weight: .medium)).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            ForEach(group.matches.prefix(3)) { line in
                                Button { slack.onFindReveal?(group, line) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(line.fromUser ? "나" : line.speaker)
                                            Text(line.date, style: .time).foregroundColor(quiet)
                                        }.font(.system(size: ChatMetrics.auxiliaryFont))
                                        let preview = SlackSearch.preview(slack.findQuery, in: line)
                                        if !preview.body.isEmpty {
                                            Text(findPreview(preview.body)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                                        }
                                        ForEach(Array(preview.notes.enumerated()), id: \.offset) { _, note in
                                            HStack(spacing: 4) {
                                                if note.file { Image(systemName: "paperclip") }
                                                Text(note.file ? findPreview(note.text) : findStatusPreview(note.text)).lineLimit(1)
                                            }.font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            if group.matches.count > 3 { Text("+\(group.matches.count - 3)건").font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet) }
                        }.padding(12)
                            .background(Color.primary.opacity(index == slack.findSelection ? 0.10 : 0.035))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(index == slack.findSelection ? 0.22 : 0.06)))
                            .id(group.id)
                    }
                    if let notice = slack.findNotice { Text(notice).font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet) }
                    ForEach(slack.findGaps, id: \.self) { gap in
                        Label(gap, systemImage: "exclamationmark.triangle").font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(quiet)
                    }
                }.padding(.horizontal, ChatMetrics.horizontalInset).padding(.vertical, 12)
            }.onChange(of: slack.findSelection) { index in
                if slack.findGroups.indices.contains(index) { proxy.scrollTo(slack.findGroups[index].id, anchor: .center) }
            }
        }
    }
    private func findPreview(_ text: String) -> AttributedString {
        SlackSearch.highlighted(AttributedString(SlackSearch.snippet(text, query: slack.findQuery)), query: slack.findQuery)
    }
    private func findStatusPreview(_ text: String) -> AttributedString {
        let shown = SlackNotice.displayStatus(text)
        let query = shown != text && !SlackSearch.highlights(text, query: slack.findQuery).isEmpty ? shown : slack.findQuery
        return SlackSearch.highlighted(AttributedString(SlackSearch.snippet(shown, query: query)), query: query)
    }
    private func findRoom(_ id: String) -> String {
        if slack.ddotsShown.contains(id) { return Ddots.roomName }
        guard let room = (slack.rooms + slack.stacked + slack.grouped).first(where: { $0.id == id }) else { return id }
        return (room.direct ? "@" : "#") + room.name
    }
}

// Kept separate from iMessage and sidebar previews. Styling is applied last so links and code stay black on yellow.
extension SlackSearch {
    static func highlighted(_ text: AttributedString, query: String) -> AttributedString {
        var result = text
        let plain = String(text.characters)
        for range in highlights(plain, query: query) {
            let start = result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.lowerBound))
            let end = result.characters.index(result.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: range.upperBound))
            result[start..<end].backgroundColor = Color.yellow
            result[start..<end].foregroundColor = Color.black
        }
        return result
    }
}

extension ChatView {
    func slackHighlight(_ text: AttributedString, message: ChatMessage) -> AttributedString {
        var text = text
        if message.streaming {
            let native = NSMutableAttributedString(attributedString: NSAttributedString(text))
            MessageFormat.uniformSize(native, size: ChatMetrics.bodyFont)
            text = AttributedString(native)
        }
        guard let term = slack.findTerm(message) else { return text }
        return SlackSearch.highlighted(text, query: term)
    }
}
