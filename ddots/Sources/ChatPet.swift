import AppKit
import SwiftUI

enum ChatPetMetrics {
    /// One cell of the sprite sheet, kept in its own proportions. The pet itself fills about half of it.
    static let size = CGSize(width: 84, height: 91)
    static let nameHeight: CGFloat = 23
    static let top: CGFloat = 5
    /// The pet's own outline inside the cell, measured from the top-left as SwiftUI lays things out.
    static func body(_ atlas: SpriteAtlas) -> CGRect {
        let found = atlas.interactionRect(in: CGRect(origin: .zero, size: size))
        return CGRect(x: found.minX, y: size.height - found.maxY, width: found.width, height: found.height)
    }
    /// Room left at the top of the conversation for the pet and the name under it.
    static func reserved(_ atlas: SpriteAtlas) -> CGFloat { top + body(atlas).height + nameHeight + 10 }
}

/// The same pet, seen from inside the conversation: it turns to the cursor, works at the computer while a character
/// writes, hops when an answer lands and waves a message off. It takes no clicks.
final class ChatPetView: NSView {
    private let atlas: SpriteAtlas
    var writing = false
    var approval = false
    var reduced = false
    private var wantsHop = false
    private var wantsWave = false
    private var behavior = ChatPetBehavior()
    private var frame0 = PetAnimationFrame(row: 0, column: 0)
    private var timer: Timer?
    var shownFrame: PetAnimationFrame { frame0 }

    init(atlas: SpriteAtlas) {
        self.atlas = atlas
        super.init(frame: NSRect(origin: .zero, size: ChatPetMetrics.size))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func hop() { wantsHop = true }
    func wave() { wantsWave = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let tick = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.advance() }
        timer = tick
        RunLoop.main.add(tick, forMode: .common)
        advance()
    }

    private func advance() {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { behavior.reset(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let mouse = NSEvent.mouseLocation
        let sprite = window.convertToScreen(convert(atlas.interactionRect(in: bounds), to: nil))
        // The conversation is the hosting view this pet sits in; the big pet below it is outside.
        var host: NSView = self
        while let parent = host.superview, !(host is NSHostingView<ChatView>) { host = parent }
        let conversation = window.convertToScreen(host.convert(host.bounds, to: nil))
        let elapsed = behavior.update(now: now, touching: sprite.contains(mouse), cursorNear: conversation.contains(mouse),
                                      writing: writing, hop: wantsHop, wave: wantsWave, approval: approval)
        wantsHop = false; wantsWave = false
        var next: PetAnimationFrame
        switch behavior.pose {
        case .approval: next = PetAnimationTimeline.frame(for: .waiting, elapsed: elapsed, reducedMotion: reduced)
        case .jump: next = PetAnimationTimeline.frame(for: .jumping, elapsed: elapsed, reducedMotion: reduced, loop: true)
        case .replyWaiting: next = PetAnimationTimeline.frame(for: .replyWaiting, elapsed: elapsed, reducedMotion: reduced, loop: true)
        case .wave: next = PetAnimationTimeline.frame(for: .waving, elapsed: elapsed, reducedMotion: reduced, loop: true)
        case .idle: next = PetAnimationTimeline.frame(for: .idle, elapsed: elapsed, reducedMotion: reduced)
        case .look:
            let previous = (9...10).contains(frame0.row) ? frame0 : nil
            next = PetAnimationTimeline.lookFrame(from: CGPoint(x: sprite.midX, y: sprite.midY), toward: mouse, previous: previous)
                ?? PetAnimationTimeline.frame(for: .idle, elapsed: elapsed, reducedMotion: reduced)
        }
        if next != frame0 { frame0 = next; needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        atlas.draw(row: frame0.row, frame: frame0.column, in: bounds, view: self)
    }
}

struct ChatPet: NSViewRepresentable {
    let atlas: SpriteAtlas
    var writing: Bool
    /// Each goes up by one when the pet should hop or wave once.
    var hop: Int
    var wave: Int
    var reduced: Bool
    var approval: Bool = false

    final class Coordinator { var hop = 0, wave = 0 }
    func makeCoordinator() -> Coordinator { let seen = Coordinator(); seen.hop = hop; seen.wave = wave; return seen }
    func makeNSView(context: Context) -> ChatPetView {
        let view = ChatPetView(atlas: atlas)
        view.writing = writing; view.reduced = reduced; view.approval = approval
        return view
    }
    func updateNSView(_ view: ChatPetView, context: Context) {
        view.writing = writing; view.reduced = reduced; view.approval = approval
        if context.coordinator.hop != hop { context.coordinator.hop = hop; view.hop() }
        if context.coordinator.wave != wave { context.coordinator.wave = wave; view.wave() }
    }
}
