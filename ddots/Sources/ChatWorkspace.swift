import AppKit
import SwiftUI

/// Workspace chrome is independent of the message renderer and transport.
extension ChatView {
    func workspaceBrand(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            (Text("d").foregroundColor(Color(nsColor: .systemBlue)) + Text("dots."))
                .font(.system(size: 14, weight: .semibold))
            Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                .font(.system(size: 10)).foregroundColor(quiet)
        }.chatMeasure("brand-d", model: model)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background { ChatDragRegion(model: model) }
            .contextMenu { Button("펫으로 접기") { model.escape() } }
            .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder var workspaceHeader: some View {
        HStack {
            if let room = slack.room {
                VStack(alignment: .leading, spacing: 1) {
                    Text(slack.headerTitle(room)).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        .accessibilityIdentifier("current-room-title")
                    Text(slack.headerDescription(room)).font(.system(size: 10)).foregroundColor(quiet).lineLimit(1)
                }
            } else { Text("ddots.").font(.system(size: 14, weight: .semibold)) }
            Spacer(minLength: 0)
        }.padding(.horizontal, 18).frame(height: 44)
            .background { ChatDragRegion(model: model) }
            .background(Color.primary.opacity(0.035))
            .contentShape(Rectangle())
            .contextMenu {
                if let room = slack.room { Button("제목과 설명 편집…") { slack.onEditHeader?(room.id) } }
                Divider()
                Button(slack.shownMuted ? "이 대화의 알림 켜기" : "이 대화의 알림 끄기") { slack.toggleMute() }
                Button("방 목록 보이기 / 숨기기") { slack.toggleSidebar() }
                Button("방 목록 너비 전환") { slack.cycleSidebarWidth() }
                Button("전체 검색 (⌘F)") { slack.openFind() }
                Button("모두 읽음") { slack.onReadAll?() }
                Divider()
                Button("펫으로 접기") { model.escape() }
            }
            .help("오른쪽 클릭: 제목·설명 편집 및 대화 메뉴")
            .overlay(alignment: .bottom) { Divider() }
        if slack.findOpen {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(quiet)
                TextField("단어나 문장으로 검색", text: $slack.findQuery).textFieldStyle(.plain)
                    .focused($slackFindFocused).onSubmit { slack.onFindSubmit?() }.accessibilityIdentifier("slack-find-field")
                Button { slack.closeFind() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).help("검색 닫기 (Esc)")
            }.padding(12)
        }
    }
}
