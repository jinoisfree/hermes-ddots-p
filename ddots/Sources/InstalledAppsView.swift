import AppKit
import SwiftUI

/// "설치된 앱": the Mac mini's apps, with the ones that map to a Hermes connection first.
/// Rows only lead to the connection page; no app is opened, controlled or scripted from here.
struct InstalledAppsPage: View {
    @ObservedObject var model: AgentConnectionsModel
    let card: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2.fill").font(.title3).foregroundColor(.black).frame(width: 44, height: 44)
                    .background(Color(white: 0.9)).clipShape(Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("설치된 앱").font(.title2.bold())
                    Text("Hermes가 설치된 이 Mac의 앱").font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                Button(model.appsLoading ? "읽는 중…" : "새로 읽기") { model.loadApps() }.disabled(model.appsLoading)
            }
            if let error = model.appsError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundColor(.red).font(.callout) }
            if let document = model.apps {
                section("연결할 수 있는 앱") {
                    if document.connectable.isEmpty { Text("이어진 앱이 없어요.").font(.caption).foregroundColor(.secondary).padding(12) }
                    ForEach(document.connectable) { app in
                        connectableRow(app)
                        if app.id != document.connectable.last?.id { Divider().padding(.leading, 12) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button { model.otherAppsOpen.toggle() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: model.otherAppsOpen ? "chevron.down" : "chevron.right").font(.caption2)
                            Text("그 밖의 앱 \(document.others.count)개").font(.caption.weight(.semibold))
                        }.foregroundColor(.secondary)
                    }.buttonStyle(.plain).accessibilityLabel("그 밖의 앱 \(document.others.count)개, " + (model.otherAppsOpen ? "펼침" : "접힘"))
                    if model.otherAppsOpen {
                        Text("연결할 수 없는 이유를 앱마다 보여 드려요.").font(.caption).foregroundColor(.secondary)
                        VStack(spacing: 0) {
                            ForEach(document.others) { app in
                                otherRow(app)
                                if app.id != document.others.last?.id { Divider().padding(.leading, 12) }
                            }
                        }.background(card).cornerRadius(10)
                    }
                }
            } else if model.appsError == nil {
                Text(model.appsLoading ? "설치된 앱을 읽는 중" : "아직 읽지 않았어요").foregroundColor(.secondary)
            }
        }.onAppear { if model.apps == nil { model.loadApps() } }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            VStack(spacing: 0) { content() }.background(card).cornerRadius(10)
        }
    }

    private func connectableRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: app.bundle_id, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 12, weight: .semibold))
                if let capability = app.can_do { Text(capability).font(.caption).foregroundColor(.secondary).lineLimit(2) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let agents = model.apps?.agents {
                Menu("직원 고르기") {
                    ForEach(agents) { group in
                        if let item = group.all.first(where: { $0.bundle_id == app.bundle_id }) {
                            Button(agentName(group.profile)) {
                                model.selection = group.profile; model.detail = nil
                                model.appDetail = item; model.appReply = nil; model.appFailure = nil
                            }
                        }
                    }
                }.disabled(model.appWorking)
            } else if let link = app.primaryLink {
                Button("연결 보기") { model.openApp(link) }
            }
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(app.links, id: \.self) { link in
                    Button { model.openApp(link) } label: { pill(link) }.buttonStyle(.plain)
                        .accessibilityLabel("\(agentName(link.profile)), \(link.state.title)")
                }
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func otherRow(_ app: InstalledApp) -> some View {
        HStack(spacing: 10) {
            AppIcon(bundleID: app.bundle_id, size: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 12))
                Text(app.reason ?? InstalledAppsText.noDirectFeature).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            ForEach(app.infoTags, id: \.self) { tag in
                Text(tag).font(.system(size: 10)).foregroundColor(.secondary).padding(.horizontal, 7).padding(.vertical, 2)
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.4)))
            }
        }.padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func agentName(_ profile: String) -> String {
        model.document?.agents.first { $0.profile == profile }?.display_name ?? profile
    }

    private func pill(_ link: InstalledApp.Link) -> some View {
        let color: Color = link.state == .connected ? .green : link.state == .needsReconnect ? .yellow : link.state == .notConnected ? .red : .secondary
        return Text("\(agentName(link.profile)) · \(link.state.title)").font(.system(size: 10, weight: .medium)).foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(link.state == .off ? Color.clear : color.opacity(0.12)).clipShape(Capsule())
            .overlay(Capsule().stroke(link.state == .off ? Color.secondary.opacity(0.4) : .clear))
    }
}

/// App icon and localized name through the system's own lookup; the app is never launched.
struct AppIcon: View {
    let bundleID: String, size: CGFloat
    private static var cache: [String: NSImage] = [:]
    var body: some View {
        Image(nsImage: Self.image(bundleID)).resizable().scaledToFit().frame(width: size, height: size)
    }
    static func image(_ bundleID: String) -> NSImage {
        if let hit = cache[bundleID] { return hit }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        cache[bundleID] = image
        return image
    }
    static func displayName(bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
    }
}
