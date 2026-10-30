import AppKit
import SwiftUI

/// Workspace chrome is independent of the message renderer and transport.
extension ChatView {
    func workspaceBrand(compact: Bool) -> some View {
        HStack(spacing: 10) {
            if !compact {
                Button { model.escape() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20).background(Circle().fill(Color.primary.opacity(0.08)))
                }.buttonStyle(.plain).help("펫으로 접기").accessibilityLabel("접기")
                Text("ddots").font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 0)
            } else {
                Text("d").font(.system(size: 21, weight: .bold)).frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, compact ? 0 : 16).frame(height: 72)
            .background { ChatDragRegion(model: model) }
            .overlay(alignment: .bottom) { Divider() }
    }

    @ViewBuilder var workspaceHeader: some View {
        HStack(spacing: 14) {
            if let room = slack.room {
                slackFaces(slack.members[room.id] ?? [], room: room)
                    .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(room.name).font(.system(size: 19, weight: .bold)).lineLimit(1)
                        .accessibilityIdentifier("current-room-title")
                    Text(room.direct ? "함께 나누는 대화" : "조직원들의 소식과 대화")
                        .font(.system(size: 12)).foregroundColor(quiet).lineLimit(1)
                }
            } else {
                Text("ddots").font(.system(size: 19, weight: .bold))
            }
            Spacer(minLength: 0)
            Button { slack.toggleMute() } label: {
                Image(systemName: slack.shownMuted ? "bell.slash" : "bell")
            }.help(slack.shownMuted ? "이 대화의 알림 켜기" : "이 대화의 알림 끄기")
                .accessibilityLabel("대화 알림 전환").accessibilityIdentifier("chat-mute")
            Button { slack.toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .help("방 목록 보이기 / 숨기기").accessibilityLabel("방 목록 보이기 / 숨기기")
            Button { slack.openFind() } label: { Image(systemName: "magnifyingglass") }
                .help("전체 검색 (⌘F)").accessibilityLabel("전체 검색").accessibilityIdentifier("slack-find")
            Menu {
                Button("방 목록 너비 전환") { slack.cycleSidebarWidth() }
                Button("모두 읽음") { slack.onReadAll?() }
                Divider()
                Button("펫으로 접기") { model.escape() }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("대화 메뉴")
        }.buttonStyle(.plain).font(.system(size: 17))
            .padding(.horizontal, 18).frame(height: 72)
            .background { ChatDragRegion(model: model) }
            .background(Color.primary.opacity(0.035))
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
