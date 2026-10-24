import AppKit
import UniformTypeIdentifiers

/// The dialogs for making a channel, asking people into one, and putting one away. They only ask; the controller goes to Slack.
enum SlackRoomDialogs {
    struct NewRoom: Equatable {
        var name: String
        var isPrivate: Bool
        var users: [String]
    }

    /// A list of checkboxes, agents above people, read from top to bottom.
    final class Picks: NSView {
        override var isFlipped: Bool { true }
        private(set) var boxes: [(id: String, box: NSButton)] = []
        static let row: CGFloat = 22

        init(people: [SlackBridge.Person], width: CGFloat, inside: Set<String> = []) {
            super.init(frame: .zero)
            let names = Dictionary(grouping: people, by: \.name)
            var y: CGFloat = 4
            func heading(_ text: String) {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 11, weight: .semibold); label.textColor = .secondaryLabelColor
                label.frame = NSRect(x: 4, y: y, width: width - 8, height: Self.row - 4)
                addSubview(label); y += Self.row
            }
            for (title, group) in [("에이전트", people.filter(\.agent)), ("사람", people.filter { !$0.agent })] where !group.isEmpty {
                heading(title)
                for person in group {
                    let account = (names[person.name]?.count ?? 0) > 1 ? " · " + (person.handle.isEmpty ? person.id : "@" + person.handle) : ""
                    let joined = inside.contains(person.id)
                    let title = person.name + account + (joined ? " (참여 중)" : "")
                    let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
                    box.isEnabled = !joined
                    box.toolTip = title
                    box.frame = NSRect(x: 10, y: y, width: width - 14, height: Self.row)
                    box.setAccessibilityLabel(title + (joined ? "" : " 초대"))
                    addSubview(box); boxes.append((person.id, box)); y += Self.row
                }
                y += 4
            }
            frame = NSRect(x: 0, y: 0, width: width, height: y)
        }
        required init?(coder: NSCoder) { nil }
        var chosen: [String] { boxes.filter { $0.box.isEnabled && $0.box.state == .on }.map(\.id) }
    }

    private static let width: CGFloat = 320

    /// The people to choose from in a scrolling box, or a line saying why there is no one.
    private static func pickList(_ people: [SlackBridge.Person], unreadable: String?, inside: Set<String> = [], agentsOnly: Bool = false) -> (view: NSView, picks: Picks) {
        let picks = Picks(people: people, width: width - 4, inside: inside)
        guard !people.isEmpty else {
            let subject = agentsOnly ? "에이전트" : "사람"
            let label = NSTextField(wrappingLabelWithString: unreadable.map { "초대할 \(subject) 목록을 읽지 못했어요. " + $0 }
                ?? (agentsOnly ? "초대할 수 있는 에이전트가 없어요." : "초대할 수 있는 에이전트나 사람이 없어요."))
            label.textColor = .secondaryLabelColor; label.preferredMaxLayoutWidth = width
            return (label, picks)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(220, picks.frame.height + 2)))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.drawsBackground = false
        scroll.documentView = picks
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: scroll.frame.height).isActive = true
        return (scroll, picks)
    }

    private static func stack(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.frame = NSRect(origin: .zero, size: NSSize(width: width, height: stack.fittingSize.height))
        return stack
    }

    /// Asks for the new channel's name, whether it is open to the workspace, and who to ask in. Nil when called off.
    static func create(people: [SlackBridge.Person], unreadable: String?) -> NewRoom? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.placeholderString = "채널 이름 (예: 새-프로젝트)"
        field.setAccessibilityLabel("채널 이름")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        let kind = NSSegmentedControl(labels: ["공개", "비공개"], trackingMode: .selectOne, target: nil, action: nil)
        kind.selectedSegment = 0
        kind.setAccessibilityLabel("공개 여부")
        let heading = NSTextField(labelWithString: "초대할 에이전트·사람")
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        let list = pickList(people, unreadable: unreadable)
        let accessory = stack([field, kind, heading, list.view])
        while true {
            let alert = NSAlert()
            alert.messageText = "새 채널 만들기"
            alert.informativeText = "슬랙에 채널을 만들고 함께할 에이전트나 사람을 초대해요. 이름은 소문자로 바뀌고 빈칸은 -가 돼요."
            alert.accessoryView = accessory
            alert.addButton(withTitle: "만들기"); alert.addButton(withTitle: "취소")
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let name = SlackBridge.channelName(field.stringValue)
            guard !name.isEmpty else { tell("방 이름을 넣어 주세요", "글자나 숫자가 들어간 이름이어야 해요."); continue }
            return NewRoom(name: name, isPrivate: kind.selectedSegment == 1, users: list.picks.chosen)
        }
    }

    /// Characters have their own picker; those already there stay visible and cannot be invited again.
    static func inviteDialog(room: String, people: [SlackBridge.Person], unreadable: String?, agentsOnly: Bool = false, inside: Set<String> = []) -> (alert: NSAlert, picks: Picks) {
        let people = people.filter { agentsOnly ? !$0.profile.isEmpty : !inside.contains($0.id) }
        let list = pickList(people, unreadable: unreadable, inside: inside, agentsOnly: agentsOnly)
        let alert = NSAlert()
        alert.messageText = "#\(room)에 \(agentsOnly ? "에이전트" : "사람") 추가"
        alert.informativeText = agentsOnly
            ? "이 채널에 함께할 에이전트를 고르세요. ‘참여 중’인 에이전트는 이미 이 채널에 있어요. 추가한 뒤 @이름으로 부를 수 있어요."
            : "이 방에 초대할 에이전트나 사람을 고르세요. 이미 방에 있는 사람은 빠져 있어요."
        alert.accessoryView = stack([list.view])
        alert.addButton(withTitle: "초대"); alert.addButton(withTitle: "취소")
        alert.buttons[0].isEnabled = unreadable == nil && list.picks.boxes.contains { $0.box.isEnabled }
        return (alert, list.picks)
    }

    /// Asks who to bring into a channel. Nil when called off or no one was chosen.
    static func invite(room: String, people: [SlackBridge.Person], unreadable: String?, agentsOnly: Bool = false, inside: Set<String> = []) -> [String]? {
        let dialog = inviteDialog(room: room, people: people, unreadable: unreadable, agentsOnly: agentsOnly, inside: inside)
        NSApp.activate(ignoringOtherApps: true)
        guard dialog.alert.runModal() == .alertFirstButtonReturn, !dialog.picks.chosen.isEmpty else { return nil }
        return dialog.picks.chosen
    }

    static func confirm(_ title: String, _ text: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = text; alert.alertStyle = .warning
        alert.addButton(withTitle: button); alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func tell(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }

    /// The room in Slack, on the workspace's own address, which Slack's app takes over when it is installed.
    static func address(workspace: String, room: String) -> URL? {
        guard let host = URL(string: workspace)?.host, !room.isEmpty else { return nil }
        return URL(string: "https://\(host)/archives/\(room)")
    }
}

extension SlackRoomDialogs {
    /// Asks for a channel's new name. Nil when called off or left empty.
    static func rename(_ old: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = old
        field.setAccessibilityLabel("새 채널 이름")
        while true {
            let alert = NSAlert()
            alert.messageText = "#\(old) 이름 바꾸기"
            alert.informativeText = "슬랙의 채널 이름이 바뀌어요. 이름은 소문자로 바뀌고 빈칸은 -가 돼요."
            alert.accessoryView = field
            alert.addButton(withTitle: "바꾸기"); alert.addButton(withTitle: "취소")
            alert.window.initialFirstResponder = field
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let name = SlackBridge.channelName(field.stringValue)
            guard !name.isEmpty else { tell("방 이름을 넣어 주세요", "글자나 숫자가 들어간 이름이어야 해요."); continue }
            return name
        }
    }

    /// Asks for a group's new name. It stays on this Mac. Nil when called off; empty brings back the usual name.
    static func renameGroup(_ old: String) -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
        field.stringValue = old
        field.setAccessibilityLabel("새 구역 이름")
        let alert = NSAlert()
        alert.messageText = "‘\(old)’ 이름 바꾸기"
        alert.informativeText = "이 묶음의 이름은 이 Mac의 ddots에만 저장돼요. 비우면 기본 이름으로 돌아가요."
        alert.accessoryView = field
        alert.addButton(withTitle: "바꾸기"); alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return String(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
    }

    static func pickPicture() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "방 사진 고르기"; panel.prompt = "넣기"
        panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

/// Pictures for channels' tabs, one small square PNG per room in the app's support folder.
enum SlackRoomPictures {
    static let side: CGFloat = 256
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder).appendingPathComponent("room-pictures", isDirectory: true)
    }
    private static func file(_ room: String) -> URL? {
        // Room ids are Slack's own letters and digits; anything else is no file name of ours.
        guard !room.isEmpty, room.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return folder.appendingPathComponent(room + ".png")
    }

    static func load() -> [String: NSImage] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: NSImage] = [:]
        for url in files where url.pathExtension == "png" {
            if let image = NSImage(contentsOf: url) { result[url.deletingPathExtension().lastPathComponent] = image }
        }
        return result
    }

    /// The picture cut to a square from its middle and made small, as it is kept and shown.
    static func squared(_ image: NSImage) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let edge = min(source.width, source.height)
        guard edge > 0, let cropped = source.cropping(to: CGRect(x: (source.width - edge) / 2, y: (source.height - edge) / 2, width: edge, height: edge)),
              let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let made = context.makeImage() else { return nil }
        return NSImage(cgImage: made, size: NSSize(width: side, height: side))
    }

    /// Keeps the picture for the room and gives back what is shown. Nil when it could not be read or written.
    static func save(_ image: NSImage, room: String) -> NSImage? {
        guard let url = file(room), let small = squared(image), let cg = small.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch { return nil }
        return small
    }

    static func remove(_ room: String) {
        if let url = file(room) { try? FileManager.default.removeItem(at: url) }
    }
}
