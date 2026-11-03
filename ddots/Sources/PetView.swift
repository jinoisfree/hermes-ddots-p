import AppKit
import QuartzCore
import CoreVideo
import SwiftUI

final class PetPanel: NSPanel {
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        (contentView as? PetView)?.updateAnimationVisibility()
    }
    override func orderFrontRegardless() {
        super.orderFrontRegardless()
        (contentView as? PetView)?.updateAnimationVisibility()
    }
    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        (contentView as? PetView)?.updateAnimationVisibility()
    }
    /// Placement constrains the visible artwork; its transparent cell may cross the screen edge.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    var chatExpanded = false
    var clipboardPresented = false
    var onClipboardKey: ((NSEvent) -> Bool)?
    var onCollapse: (() -> Void)?
    var onChatKey: ((NSEvent) -> Bool)?
    /// A shortcut for the page beside the conversation, when the keyboard is in it.
    var onPageKey: ((NSEvent) -> Bool)?
    var onPasteAttachments: (() -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if clipboardPresented, event.type == .keyDown, onClipboardKey?(event) == true { return }
        if clipboardPresented, event.type == .leftMouseDown || event.type == .rightMouseDown,
           let pet = contentView as? PetView, pet.clipboardContains(event.locationInWindow) { makeKey() }
        // Let selectable text receive the first press instead of spending it on key-window focus.
        if chatExpanded, !isKeyWindow, event.type == .leftMouseDown,
           let pet = contentView as? PetView,
           let host = pet.subviews.compactMap({ $0 as? NSHostingView<ChatView> }).first,
           let hit = pet.hitTest(event.locationInWindow), hit === host || hit.isDescendant(of: host) {
            makeKey()
        }
        if chatExpanded, event.type == .keyDown, onChatKey?(event) == true { return }
        super.sendEvent(event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if clipboardPresented, onClipboardKey?(event) == true { return true }
        if chatExpanded, onPageKey?(event) == true { return true }
        if chatExpanded, event.modifierFlags.contains(.command), Self.shortcutKey(event) == "f", onChatKey?(event) == true { return true }
        if chatExpanded, Self.editAction(for: event) == #selector(NSText.paste(_:)), onPasteAttachments?() == true { return true }
        if chatExpanded || clipboardPresented, let action = Self.editAction(for: event), NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
    /// The letter a shortcut stands for. A Korean or other non-Latin input source can report its own character,
    /// so fall back to where the key sits on the keyboard.
    static func shortcutKey(_ event: NSEvent) -> String? {
        if let key = event.charactersIgnoringModifiers?.lowercased(), key.unicodeScalars.allSatisfy(\.isASCII), !key.isEmpty { return key }
        return [0: "a", 3: "f", 6: "z", 7: "x", 8: "c", 9: "v"][event.keyCode]
    }
    /// The pet has no menu bar, so the usual Edit shortcuts never reach the text unless they are routed here.
    static func editAction(for event: NSEvent) -> Selector? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = shortcutKey(event)
        if flags == [.command, .shift] { return key == "z" ? Selector(("redo:")) : nil }
        guard flags == .command else { return nil }
        switch key {
        case "c": return #selector(NSText.copy(_:))
        case "v": return #selector(NSText.paste(_:))
        case "x": return #selector(NSText.cut(_:))
        case "a": return #selector(NSText.selectAll(_:))
        case "z": return Selector(("undo:"))
        default: return nil
        }
    }
    override var canBecomeKey: Bool { chatExpanded || clipboardPresented }
    override func cancelOperation(_ sender: Any?) { if clipboardPresented { (contentView as? PetView)?.dismissClipboard() } else { onCollapse?() } }
    override var canBecomeMain: Bool { false }
}

@available(macOS 26.0, *)
final class PetGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetVibrancyView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A local visual overlay. It never mutates the normal headline/subtitle or a chat model.
final class ClipboardCopyTextView: NSView {
    private var notice: ClipboardCopyNotice.Frame?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    func present(_ frame: ClipboardCopyNotice.Frame?) {
        let changed = notice?.text != frame?.text
        notice = frame; isHidden = frame == nil
        if changed {
            setAccessibilityElement(frame != nil); setAccessibilityRole(.staticText)
            setAccessibilityLabel(frame?.text)
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let notice else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let area = bounds.insetBy(dx: 12, dy: 10)
        func text(_ value: String, alpha: Double) {
            (value as NSString).draw(in: area, withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor.withAlphaComponent(alpha), .paragraphStyle: paragraph])
        }
        let combined = max(0.001, notice.alpha + notice.previousAlpha)
        if let previous = notice.previous { text(previous, alpha: notice.previousAlpha / combined) }
        text(notice.text, alpha: notice.previous == nil ? 1 : notice.alpha / combined)
    }
}

final class BubbleTextView: NSView {
    var avatar: ProfileAvatar? { didSet { needsDisplay = true } }
    var avatarName: String? { didSet { updateStatusIndicator(); needsDisplay = true } }
    var unreadCount = 0 { didSet { updateStatusIndicator(); needsDisplay = true } }
    var badgeRect: CGRect { CGRect(x: 16, y: 27 + textBase, width: 22, height: 22) }
    var statusDotVisible: Bool { !statusDot.isHidden }
    var headline = "ddots" { didSet { needsDisplay = true } }
    var subtitle = "AI 작업을 살펴보고 있어요" { didSet { needsDisplay = true } }
    var state: WorkState = .idle { didSet { updateStatusIndicator(); needsDisplay = true } }
    var actionTitles: [String] = [] { didSet { needsDisplay = true } }
    private var textBase: CGFloat { bounds.height - PetLayout.bubbleSize.height }
    private let statusDot = CALayer()
    private var pulseAllowed = true
    private let pulseKey = "workingStatusPulse"
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        statusDot.frame = CGRect(x: 16, y: 35, width: 6, height: 6)
        statusDot.cornerRadius = 3
        layer?.addSublayer(statusDot)
        updateStatusIndicator()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        statusDot.frame = CGRect(x: 16, y: 35 + textBase, width: 6, height: 6)
        CATransaction.commit()
        needsDisplay = true
    }

    func setPulseAllowed(_ allowed: Bool) {
        guard pulseAllowed != allowed else { return }
        pulseAllowed = allowed; updateStatusIndicator()
    }
    private func updateStatusIndicator() {
        let color: NSColor = state == .waiting ? .systemOrange : state == .failed ? .systemRed : state == .running ? .systemGreen : .systemTeal
        CATransaction.begin(); CATransaction.setDisableActions(true)
        statusDot.backgroundColor = color.cgColor
        statusDot.isHidden = unreadCount > 0 || avatarName != nil
        statusDot.opacity = 1
        CATransaction.commit()
        if state == .running && pulseAllowed && !statusDot.isHidden {
            guard statusDot.animation(forKey: pulseKey) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.35
            pulse.duration = 0.8; pulse.autoreverses = true; pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            statusDot.add(pulse, forKey: pulseKey)
        } else { statusDot.removeAnimation(forKey: pulseKey) }
    }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        if unreadCount > 0 {
            NSColor.systemBlue.setFill(); NSBezierPath(ovalIn: badgeRect).fill()
            let text = UnreadReplies.badge(unreadCount) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: badgeRect.midX-size.width/2, y: badgeRect.midY-size.height/2), withAttributes: attributes)
        }
        let avatarX: CGFloat = unreadCount > 0 ? badgeRect.maxX + 8 : 16
        if let name = avatarName {
            (avatar ?? ProfileAvatar()).draw(in: NSRect(x: avatarX, y: 37 + textBase - ChatMetrics.notificationAvatar/2, width: ChatMetrics.notificationAvatar, height: ChatMetrics.notificationAvatar), name: name)
        }
        let textX: CGFloat = avatarName == nil ? (unreadCount > 0 ? badgeRect.maxX + 8 : 30) : avatarX + ChatMetrics.notificationAvatar + ChatMetrics.avatarNameGap
        drawText(headline, rect: NSRect(x: textX, y: 27 + textBase, width: max(0, bounds.width-16-textX), height: 19), size: ChatMetrics.nameFont, color: .labelColor, bold: true)
        drawText(subtitle, rect: NSRect(x: 16, y: 10 + textBase, width: max(0, bounds.width-32), height: 16), size: ChatMetrics.auxiliaryFont, color: .secondaryLabelColor, bold: false)
        for (rect, title) in zip(PetLayout.actionRects(count: actionTitles.count), actionTitles) {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: rect.insetBy(dx: 6, dy: 5), withAttributes: [.font: NSFont.systemFont(ofSize: ChatMetrics.auxiliaryFont, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        }
    }
    private func drawText(_ text: String, rect: NSRect, size: CGFloat, color: NSColor, bold: Bool) {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

/// The count of unread answers beside the pet while the bubble is put away: white on a blue circle.
/// Holds transition pictures over the conversation; never takes a click.
final class PetCoverView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PetBadgeView: NSView {
    static let height: CGFloat = 13
    var text = "" { didSet { needsDisplay = true } }
    private static let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 8.5), .foregroundColor: NSColor.white]
    static func size(_ text: String) -> CGSize {
        CGSize(width: max(height, ceil((text as NSString).size(withAttributes: attributes).width) + 6), height: height)
    }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let edge = bounds.insetBy(dx: 0.5, dy: 0.5)
        let circle = NSBezierPath(roundedRect: edge, xRadius: edge.height / 2, yRadius: edge.height / 2)
        NSColor.systemBlue.setFill(); circle.fill()
        NSColor.white.setStroke(); circle.lineWidth = 1; circle.stroke()
        let size = (text as NSString).size(withAttributes: Self.attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: Self.attributes)
    }
}

final class PetSpriteView: NSView {
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    override var isOpaque: Bool { false }
    var onDraw: ((CGRect) -> Void)?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        onDraw?(bounds)
    }
}

/// Keep SwiftUI's retained view and viewport, but defer its AppKit layout while the picture is moving.
final class GenieChatHost: NSHostingView<ChatView> {
    var holdsGenieLayout = false
    var prepareEntryViewport: (() -> Bool)?
    override func layout() {
        guard !holdsGenieLayout else { return }
        let started = StallTrace.now
        defer { StallTrace.shared.record("chat.viewUpdate.layout", since: started) }
        super.layout()
        _ = prepareEntryViewport?()
    }
}

/// The shelf is entered through hover, so its first press must reach SwiftUI even before it has key focus.
final class ClipboardShelfHost: NSHostingView<ClipboardShelf> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PetView: NSView {
    let atlas: SpriteAtlas
    private let spriteSurface = PetSpriteView()
    var identity: PetIdentity { didSet { updateIdentityDescription() } }
    let bubbleText = BubbleTextView()
    let clipboardCopyText = ClipboardCopyTextView()
    private var clipboardCopyNotice = ClipboardCopyNotice()
    private(set) var clipboardCopyFrame: ClipboardCopyNotice.Frame?
    private var bubbleSurface: NSView!
    /// Small circles rising from the pet's head to the bubble, the way a thought balloon is drawn in a comic.
    private var thoughtDots: [(surface: NSView, tint: NSView)] = []
    static let thoughtDotSizes: [CGFloat] = [7, 11, 16]
    private let surfaceContent = NSView()
    private let scrim = NSView()
    var chatOpacityPercent = BubbleOpacity.defaultPercent { didSet { updateScrim() } }
    private var chatHost: GenieChatHost?
    private weak var slackModel: SlackModel?
    private var chatPetBehavior = ChatPetBehavior()
    private var seenPetHop = 0, seenPetWave = 0
    var chatSize = PetLayout.expandedSize { didSet { if chatSize != oldValue { invalidateGeniePicture() } } }
    /// While the window eases between its iMessage and Slack widths, the conversation is laid out at the width shown so far.
    private let genie = GenieView()
    var geniePage: (image: NSImage, view: NSView)?
    var genieActive: Bool { genie.image != nil }
    var genieStripCount: Int { genie.stripCount }
    var genieProgress: CGFloat { genie.progress }
    var genieBlur: CGFloat { genie.blurAmount }
    var genieHasBlurredImage: Bool { genie.blurredImage != nil }
    weak var genieTrace: GenieTrace?
    private(set) var genieCaptures = 0
    private(set) var openingEntryPending = false
    private var closingPicture: (key: GeniePictureKey, sharp: NSImage, soft: CGImage?)?
    private var genieGeneration = 0
    private static let genieQueue = DispatchQueue(label: "ddots.genie-blur", qos: .userInitiated)
    func invalidateGeniePicture() { closingPicture = nil; genieGeneration += 1 }
    func canReuseGenie(size: CGSize) -> Bool {
        !resting && !reducesMotion && closingPicture?.key == GeniePictureKey(size: size,
            dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, scale: petScale)
    }
    func captureGenie(size: CGSize, opening: Bool = false) {
        let beganCapture = StallTrace.now
        defer { StallTrace.shared.record("captureGenie", since: beganCapture) }
        endGenie()
        guard !resting, !reducesMotion, let host = chatHost else { return }
        let key = GeniePictureKey(size: size, dark: effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, scale: petScale)
        if closingPicture?.key != key { invalidateGeniePicture() }
        if opening, let picture = closingPicture {
            genieTrace?.path = "reused"
            genie.image = picture.sharp; genie.blurredImage = picture.soft
            mountGenie()
            return
        }
        invalidateGeniePicture()
        let generation = genieGeneration
        genieTrace?.path = "captured"
        let began = ProcessInfo.processInfo.systemUptime
        genieCaptures += 1
        morphing = false; settleMorph()
        host.isHidden = false; host.alphaValue = 1; host.layer?.filters = nil
        host.frame.size = size; host.layer?.mask = nil
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        openingEntryPending = opening && !(host.prepareEntryViewport?() ?? true)
        genieTrace?.layoutMS = (ProcessInfo.processInfo.systemUptime - began) * 1000
        let captureBegan = ProcessInfo.processInfo.systemUptime
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        genieTrace?.captureMS = (ProcessInfo.processInfo.systemUptime - captureBegan) * 1000
        let compositeBegan = ProcessInfo.processInfo.systemUptime
        // Composite in the captured bitmap itself: no second focus surface or image round trip.
        guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let rect = CGRect(origin: .zero, size: size)
        let context = graphics.cgContext
        context.scaleBy(x: CGFloat(bitmap.pixelsWide) / size.width, y: CGFloat(bitmap.pixelsHigh) / size.height)
        context.setBlendMode(.destinationOver)
        context.setFillColor((key.dark ? NSColor(white: 0.09, alpha: 1) : NSColor(white: 0.94, alpha: 1)).cgColor)
        context.fill(rect); context.setBlendMode(.normal)
        if let page = geniePage {
            let local = page.view.convert(page.view.bounds, to: host)
            page.image.draw(in: CGRect(x: local.minX, y: host.isFlipped ? size.height-local.maxY : local.minY, width: local.width, height: local.height))
        }
        // Clear only the area outside the rounded boundary.
        context.addRect(rect)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil))
        context.clip(using: .evenOdd); context.clear(rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let captured = bitmap.cgImage else { return }
        let sharp = NSImage(cgImage: captured, size: size)
        genie.image = sharp
        genieTrace?.compositeMS = (ProcessInfo.processInfo.systemUptime - compositeBegan) * 1000
        if !opening { closingPicture = (key, sharp, nil) }
        mountGenie()
        let trace = genieTrace
        Self.genieQueue.async { [weak self] in
            let blurBegan = ProcessInfo.processInfo.systemUptime
            let soft = Self.blurred(captured, width: size.width)
            let elapsed = (ProcessInfo.processInfo.systemUptime - blurBegan) * 1000
            DispatchQueue.main.async {
                guard let self, self.genieGeneration == generation else { return }
                trace?.blurMS = elapsed
                let applyBegan = ProcessInfo.processInfo.systemUptime
                if self.closingPicture?.key == key { self.closingPicture?.soft = soft }
                if self.genieActive { self.genie.blurredImage = soft }
                trace?.blurApplyMS = (ProcessInfo.processInfo.systemUptime - applyBegan) * 1000
            }
        }
    }
    private func mountGenie() {
        if genie.superview == nil {
            genie.wantsLayer = true; addSubview(genie, positioned: .below, relativeTo: spriteSurface)
        }
        genie.isHidden = false
        // The glass is detached; the separate hosting view retains its viewport without laying out.
        chatHost?.holdsGenieLayout = true
        bubbleSurface.removeFromSuperview()
        bubbleSurface.isHidden = true; chatHost?.isHidden = true; bubbleText.isHidden = true
    }
    /// SwiftUI may still be applying the entry when the click's input turn finishes. Keep the unfolding at
    /// its starting point until the live layout can supply a picture of the requested conversation.
    func prepareOpeningEntry(size: CGSize) -> Bool {
        guard openingEntryPending, let host = chatHost else { return true }
        host.holdsGenieLayout = false
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        guard host.prepareEntryViewport?() ?? true else {
            host.holdsGenieLayout = true
            return false
        }
        captureGenie(size: size, opening: true)
        startWidthClock()
        return !openingEntryPending
    }
    func updateGenie(rect: CGRect, target: CGPoint, progress: CGFloat, below: Bool) {
        guard genieActive else { return }
        genie.frame = bounds; genie.rect = rect; genie.target = target
        genie.progress = progress; genie.below = below; genie.updateStrips()
        bubbleSurface.removeFromSuperview()
        bubbleSurface.isHidden = true; chatHost?.isHidden = true; bubbleText.isHidden = true
    }
    func prepareGenieCapture(_ capturing: Bool) { genie.capturing = capturing; genie.needsDisplay = true }
    func endGenie() {
        chatHost?.holdsGenieLayout = false
        chatHost?.needsLayout = true
        if genieActive, chatExpanded {
            // Finish live layout underneath the opaque picture before removing it.
            layoutChatContent(in: placement?.bubbleRect ?? bubbleSurface.frame)
            chatHost?.layoutSubtreeIfNeeded()
            chatHost?.displayIfNeeded()
        }
        genie.clearStrips()
        genie.image = nil; genie.blurredImage = nil; genie.isHidden = true
        morphing = false
        if widthPicture == nil { widthClock?.stop(); widthClock = nil }
        if bubbleSurface != nil, bubbleSurface.superview == nil { addSubview(bubbleSurface,positioned:.below,relativeTo:spriteSurface) }
        bubbleSurface.isHidden = bubbleStowed
        settleMorph(); needsLayout = true
    }
    var chatWidthFollowsGlass = false
    var onResizeBegan: (() -> Void)?
    var onResize: ((CGSize, CGPoint?) -> Void)?
    var onResizeEnded: (() -> Void)?
    var onResetChatSize: (() -> Void)?
    /// The width of the page open at the conversation's right. Its outer edge sizes the page, not the conversation.
    var paneWidth: CGFloat = 0
    var onResizePane: ((CGFloat) -> Void)?
    var onResetPaneSize: (() -> Void)?
    private var resizeDrag: (point: CGPoint, placement: PetPlacement, screen: CGRect, fullScreen: CGRect, edge: PetLayout.ResizeEdge, pane: CGFloat)?
    var unreadCount = 0 { didSet { bubbleText.unreadCount = isPaused ? 0 : unreadCount; updateIdentityDescription(); updatePetBadge() } }
    private let petBadge = PetBadgeView()
    private var reveal = BubbleReveal()
    /// The folded bubble is on screen. Put away, it takes no clicks and the count of unread answers moves beside the pet.
    private(set) var bubbleShown = true
    var bubbleAlwaysShown = false { didSet { updateBubbleShown() } }
    var petBadgeVisible: Bool { !petBadge.isHidden }
    var petBadgeRect: CGRect { petBadge.frame }
    /// Something asks for attention: the bubble comes out for a while.
    func revealBubble() { clipboardCopyNotice.clear(); reveal.alert(now: ProcessInfo.processInfo.systemUptime); updateBubbleShown() }
    private var canShowClipboardCopyNotice: Bool {
        clipboardLibrary?.settings.enabled != false && !chatExpanded && !morphing && !genieActive && !clipboardPresented && !isPaused && !resting
            && window?.isVisible == true && !isHiddenOrHasHiddenAncestor && !didDrag
            && state != .waiting && state != .failed && slackModel?.needsPetApproval != true
            && actions.isEmpty && previewRow == nil && !previewLook
    }
    func showClipboardCopyNotice(_ message: String) {
        guard canShowClipboardCopyNotice else { return }
        clipboardCopyNotice.show(message, now: ProcessInfo.processInfo.systemUptime)
        updateBubbleShown()
    }
    func cancelClipboardCopyNotice() {
        guard clipboardCopyFrame != nil else { return }
        clipboardCopyNotice.clear(); updateBubbleShown()
    }
    private func updateClipboardCopyNotice(now: TimeInterval) -> Bool {
        let wasShown = clipboardCopyFrame != nil
        if !canShowClipboardCopyNotice { clipboardCopyNotice.clear() }
        clipboardCopyFrame = clipboardCopyNotice.update(now: now, reducedMotion: reducesMotion)
        clipboardCopyText.present(clipboardCopyFrame)
        guard let frame = clipboardCopyFrame else {
            if wasShown {
                CATransaction.begin(); CATransaction.setDisableActions(true)
                bubbleSurface.layer?.setAffineTransform(.identity)
                ([bubbleSurface!] + thoughtDots.map(\.surface)).forEach { $0.alphaValue = 1 }
                CATransaction.commit()
                bubbleText.isHidden = clipboardPresented || chatExpanded
            }
            return wasShown
        }
        bubbleText.isHidden = true
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bubbleSurface.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: frame.offset))
        ([bubbleSurface!] + thoughtDots.map(\.surface)).forEach { $0.alphaValue = min(1, frame.alpha + frame.previousAlpha) }
        CATransaction.commit()
        return false
    }
    /// The pointer came onto the pet and has not left it or the bubble it brought out.
    private var hovering = false
    var clipboardAvailable = false { didSet { updateBubbleShown() } }
    private(set) var clipboardPresented = false
    private var clipboardDismissed = false
    private var clipboardRequested = false
    private var clipboardSurfaceActive = false
    private var clipboardShortcutAwaitingEntry = false
    func toggleClipboardFromShortcut() {
        if clipboardPresented { dismissClipboard(); return }
        guard clipboardLibrary?.settings.enabled == true, !chatExpanded, !clipboardAttention else { return }
        clipboardRequested = true; clipboardDismissed = false; hovering = true; clipboardShortcutAwaitingEntry = true
        updateBubbleShown()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.clipboardPresented, let panel = self.window as? PetPanel else { return }
            panel.makeKey()
            if let field = self.clipboardHost.flatMap({ ClipboardSearch.field(in: $0) }) { panel.makeFirstResponder(field) }
        }
    }
    private var clipboardRowEntered: TimeInterval?
    private let clipboardRow = ClipboardDrawerRow(frame: .zero)
    private weak var clipboardLibrary: ClipboardLibrary?
    var onClipboardGeometry: (() -> Void)?
    var onClipboardResize: ((CGSize) -> Void)?
    var onResetClipboardSize: (() -> Void)?
    var clipboardOpacityPercent = BubbleOpacity.defaultPercent { didSet { updateScrim() } }
    private(set) var clipboardResizing = false
    var clipboardOpenHeight: CGFloat = ClipboardDrawer.defaultSize.height
    var clipboardRowVisible: Bool { clipboardRow.superview != nil && !clipboardRow.isHidden }
    func clipboardPreviewEnded() { clipboardExitDeadline = nil }
    var clipboardTintAlpha: CGFloat { scrim.layer?.backgroundColor?.alpha ?? 0 }
    var clipboardPreviewRect: CGRect { clipboardHost?.frame ?? .zero }
    var clipboardRowRect: CGRect { clipboardRow.convert(clipboardRow.bounds, to: self) }
    var clipboardAttention: Bool {
        state == .waiting || state == .failed || slackModel?.needsPetApproval == true || !actions.isEmpty
            || reveal.update(now: ProcessInfo.processInfo.systemUptime, held: false)
    }
    func openClipboard() {
        guard clipboardAvailable, !chatExpanded, !clipboardAttention else { return }
        clipboardRequested = true; clipboardDismissed = false; hovering = true
        clipboardRowEntered = nil; updateBubbleShown()
    }
    func dismissClipboard() { clipboardRequested = false; clipboardShortcutAwaitingEntry = false; clipboardRowEntered = nil; clipboardDismissed = true; clipboardExitDeadline = nil; clipboardHolding = false; window?.makeFirstResponder(nil); window?.resignKey(); updateClipboardPresentation() }
    private var clipboardHolding = false
    private var clipboardIncoming = false
    private var clipboardDrop: ClipboardDrop?
    private var clipboardHost: NSHostingView<ClipboardShelf>?
    private var clipboardLocalEvents: Any?
    private var clipboardGlobalEvents: Any?
    private var clipboardExitDeadline: TimeInterval?
    var clipboardExitTime: TimeInterval? { clipboardExitDeadline }
    /// Coordinates are in the content view; the sprite always keeps its existing click/drag route.
    func clipboardContains(_ point: NSPoint) -> Bool {
        !spriteContains(point) && clipboardPresented && bubbleSurface.frame.contains(point)
    }
    private func clipboardPointerEvent(_ event: NSEvent) {
        guard let window, clipboardLibrary?.settings.enabled == true else { return }
        let point = pointerLocation()
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        let head = atlas.interactionRect(in: spriteRect)
        if event.type == .flagsChanged { clipboardLibrary?.commandHeld = event.modifierFlags.contains(.command); return }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if clipboardLibrary?.preview.owns(event.window) == true { return }
            if clipboardPresented {
                if head.contains(local) || clipboardContains(local) {
                    clipboardExitDeadline = nil
                } else { dismissClipboard() }
            }
            return
        }
        let onHead = head.insetBy(dx: -8, dy: -8).contains(local)
        if !onHead { hoverArmed = true }
        if clipboardPresented {
            if ClipboardDrawer.containsPointer(local, head: head, bubble: bubbleSurface.frame) {
                clipboardExitDeadline = nil; hovering = true
                if bubbleSurface.frame.contains(local) { clipboardShortcutAwaitingEntry = false }
            } else if !clipboardShortcutAwaitingEntry && clipboardLibrary?.preview.isOpen != true && clipboardExitDeadline == nil {
                clipboardExitDeadline = ProcessInfo.processInfo.systemUptime + 0.3
            }
        } else if !onHead {
            clipboardDismissed = false
        }
        updateBubbleShown()
    }
    private func installClipboardEvents() {
        if let clipboardLocalEvents { NSEvent.removeMonitor(clipboardLocalEvents) }
        if let clipboardGlobalEvents { NSEvent.removeMonitor(clipboardGlobalEvents); self.clipboardGlobalEvents = nil }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown]
        clipboardLocalEvents = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.clipboardPointerEvent(event); return event
        }
    }
    private func updateClipboardEventScope() {
        let needed = clipboardLibrary?.settings.enabled == true && window?.isVisible == true && !chatExpanded && (bubbleShown || hovering || clipboardPresented)
        if needed && clipboardGlobalEvents == nil {
            let mask: NSEvent.EventTypeMask = [.flagsChanged, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseDown, .rightMouseDown]
            clipboardGlobalEvents = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in self?.clipboardPointerEvent(event) }
        } else if !needed, let monitor = clipboardGlobalEvents { NSEvent.removeMonitor(monitor); clipboardGlobalEvents = nil }
    }
    var onClipboardPresentation: ((Bool) -> Void)?
    func installClipboard(_ library: ClipboardLibrary) {
        clipboardHost?.removeFromSuperview()
        clipboardLibrary = library
        if clipboardRow.superview == nil { surfaceContent.addSubview(clipboardRow) }
        clipboardRow.activate = { [weak self] collapse in
            guard let self else { return }
            if self.clipboardPresented {
                if collapse { self.dismissClipboard() }
                else if self.clipboardAttention { self.dismissClipboard(); self.onClick?(1) }
            } else { self.openClipboard() }
        }
        installClipboardEvents()
        clipboardDrop = ClipboardDrop(library: library)
        if !chatExpanded { registerForDraggedTypes(ClipboardPasteboard.supported) }
        let host = ClipboardShelfHost(rootView: ClipboardShelf(library: library, holding: { [weak self] value in
            self?.clipboardHolding = value; self?.updateBubbleShown()
        }))
        host.sizingOptions = []; host.isHidden = true
        addSubview(host); clipboardHost = host
    }
    private func updateClipboardPresentation() {
        let enabled = clipboardLibrary?.settings.enabled == true
        if !enabled {
            clipboardRequested = false; clipboardIncoming = false; clipboardHolding = false
            clipboardShortcutAwaitingEntry = false; clipboardRowEntered = nil; clipboardExitDeadline = nil
            if clipboardResizing { clipboardResizing = false; resizeDrag = nil }
        }
        let shown = enabled && !clipboardDismissed && (clipboardRequested || clipboardIncoming) && !chatExpanded && !morphing && !genieActive
            && previewRow == nil && !previewLook && !didDrag
        let rowShown = enabled && (shown || (clipboardAvailable && !clipboardAttention && !chatExpanded && !morphing && !genieActive && (hovering || clipboardCopyFrame != nil)))
        let rowChanged = clipboardRow.isHidden == rowShown
        if rowShown { clipboardSurfaceActive = true }
        clipboardRow.isHidden = !rowShown
        clipboardRow.expanded = shown; clipboardRow.attention = shown && clipboardAttention
        if shown {
            clipboardRow.text = (clipboardAttention ? "📱 " : "") + headline
            clipboardRow.detail = subtitle; clipboardRow.avatar = bubbleText.avatar; clipboardRow.avatarName = bubbleText.avatarName
        } else if let library = clipboardLibrary {
            if library.permissionNeeded { clipboardRow.text = "📋 붙여넣기 허용이 필요해요" }
            else if library.paused { clipboardRow.text = "📋 기록 멈춤 · \(library.entries.count)" }
            else {
                let recent = library.entries.first.map { ClipboardCopyNotice.name($0) } ?? ""
                clipboardRow.text = "📋 클립보드 \(library.entries.count)  \(recent)"
            }
        }
        if shown != clipboardPresented {
            clipboardPresented = shown
            if !shown { clipboardExitDeadline = nil; clipboardRequested = false }
            clipboardHost?.isHidden = !shown; bubbleText.isHidden = shown || chatExpanded
            (window as? PetPanel)?.clipboardPresented = shown
            if !shown, !chatExpanded { window?.makeFirstResponder(nil); window?.resignKey() }
            onClipboardPresentation?(shown); needsLayout = true
        }
        if rowChanged { onClipboardGeometry?(); needsLayout = true }
        updateClipboardEventScope()
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !chatExpanded, sender.draggingSourceOperationMask.contains(.copy), clipboardDrop?.accepts(sender.draggingPasteboard) == true else { return [] }
        clipboardIncoming = true; updateBubbleShown(); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { clipboardIncoming = false; updateBubbleShown() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !chatExpanded && clipboardDrop?.accepts(sender.draggingPasteboard) == true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clipboardIncoming = false; updateBubbleShown() }
        guard !chatExpanded else { return false }
        return clipboardDrop?.receive(sender.draggingPasteboard) == true
    }
    /// Folding the conversation leaves the pointer on the pet or where the bubble lands. That is not a visit:
    /// the pointer has to be seen off the pet once before it can bring the bubble out again.
    private var hoverArmed = true
    private func updateBubbleShown() {
        // The glass is still on its way down from the conversation's size. This goes by the glass itself, not by
        // whether the fold was ever marked as finished.
        let folding = !clipboardPresented && (bubbleSurface.frame.height > foldedHeight + 1 || bubbleSurface.frame.width > PetLayout.bubbleSize.width + 1)
        if morphing, !chatExpanded, !folding { finishMorph() }
        var held = chatExpanded || folding || previewRow != nil || previewLook || didDrag
            || (!isPaused && (state == .waiting || slackModel?.needsPetApproval == true))
        if !chatExpanded, let window, window.isVisible {
            let head = atlas.interactionRect(in: spriteRect), pointer = pointerLocation()
            func over(_ rect: CGRect) -> Bool { window.convertToScreen(convert(rect, to: nil)).contains(pointer) }
            let onHead = over(head)
            if !onHead { hoverArmed = true }
            // Once it is out for the pointer, the pointer can cross over to it and press what it offers.
            if clipboardPresented {
                // Only pointer events arm this deadline. Geometry, focus and timer ticks cannot invent an exit.
                if let deadline = clipboardExitDeadline, ProcessInfo.processInfo.systemUptime >= deadline, !clipboardHolding, clipboardLibrary?.preview.isOpen != true {
                    clipboardExitDeadline = nil; hovering = false; clipboardRequested = false; clipboardDismissed = true
                    window.makeFirstResponder(nil); window.resignKey()
                }
            } else {
                hovering = hoverArmed && (onHead || (hovering && bubbleShown && over(head.union(bubbleSurface.frame))))
            }
            if !clipboardPresented && !clipboardDismissed && clipboardRowVisible && !clipboardAttention && over(clipboardRowRect) {
                let now = ProcessInfo.processInfo.systemUptime
                if clipboardRowEntered == nil { clipboardRowEntered = now }
                if now - clipboardRowEntered! >= 0.3 { clipboardRequested = true; clipboardDismissed = false; clipboardRowEntered = nil }
            } else { clipboardRowEntered = nil }
            held = held || hovering || clipboardHolding || clipboardIncoming || clipboardPresented
        } else { hovering = false }
        updateClipboardPresentation()
        let copyEnded = updateClipboardCopyNotice(now: ProcessInfo.processInfo.systemUptime)
        let shown = reveal.update(now: ProcessInfo.processInfo.systemUptime, held: held || clipboardCopyFrame != nil) || bubbleAlwaysShown
        if clipboardCopyFrame != nil {
            bubbleShown = true; stowBubble(false); updatePetBadge(); return
        }
        if copyEnded {
            // The copy overlay has already faded; do not add the ordinary bubble's second fade.
            bubbleShown = shown; stowBubble(!shown); updatePetBadge(); return
        }
        guard shown != bubbleShown else { return }
        bubbleShown = shown
        let surfaces = [bubbleSurface!] + thoughtDots.map(\.surface)
        if shown { stowBubble(false) }
        if reducesMotion {
            surfaces.forEach { $0.alphaValue = shown ? 1 : 0 }
            stowBubble(!shown)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.18
                surfaces.forEach { $0.animator().alphaValue = shown ? 1 : 0 }
            }, completionHandler: { [weak self] in
                // Faded out, it is taken off the screen altogether, unless it was called back meanwhile.
                if let self, !self.bubbleShown { self.stowBubble(true) }
            })
        }
        updatePetBadge()
    }
    private(set) var bubbleStowed = false
    private func stowBubble(_ stowed: Bool) {
        guard stowed != bubbleStowed else { return }
        bubbleStowed = stowed; bubbleSurface.isHidden = stowed; surfaceContent.isHidden = stowed
        layoutThoughtDots()
    }
    private func updatePetBadge() {
        let text = UnreadReplies.badge(unreadCount)
        if petBadge.text != text { petBadge.text = text }
        // At the upper right of the head, kept inside the pet's own square so it is never cut off.
        let head = atlas.interactionRect(in: spriteRect), size = PetBadgeView.size(text)
        let frame = CGRect(origin: CGPoint(x: floor(min(head.maxX - size.width / 2, spriteRect.maxX - size.width)),
                                           y: floor(min(head.maxY - size.height / 2, spriteRect.maxY - size.height))), size: size)
        if petBadge.frame != frame { petBadge.frame = frame }
        petBadge.isHidden = !(unreadCount > 0 && !isPaused && !chatExpanded && !bubbleShown)
    }
    var chatAnimation: PetAnimation?
    private var replyJump = false
    private var chatPlayback = PetChatPlayback()
    func requestReplyJump() { replyJump = true }
    var animationFrame: PetAnimationFrame { displayedFrame }
    var badgeVisible: Bool { unreadCount > 0 && !isPaused && !chatExpanded && window?.isVisible == true }
    var badgeRect: CGRect { bubbleText.convert(bubbleText.badgeRect, to: self) }
    private func resizeEdge(_ point: CGPoint) -> PetLayout.ResizeEdge {
        guard let placement else { return [] }
        if clipboardPresented {
            return ClipboardDrawer.resizeEdge(at: point, bubble: placement.bubbleRect, below: placement.bubbleBelow)
        }
        guard chatExpanded else { return [] }
        return PetLayout.resizeEdge(at: point, bubble: placement.bubbleRect, below: placement.bubbleBelow)
    }
    /// The folded bubble's height just now, which is where the conversation's opening starts from.
    var foldedHeight = PetLayout.bubbleSize.height
    private var morphing = false
    private var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || CommandLine.arguments.contains("--ui-smoke-reduce-motion") }
    /// The blur the conversation is drawn with right now; 0 when it is sharp. The peak is the most it was blurred
    /// during the last fold or opening, which a check can read after the fact without racing the animation.
    private(set) var chatBlur: CGFloat = 0
    private(set) var chatBlurPeak: CGFloat = 0
    var chatHasBlurFilter: Bool { !(chatHost?.layer?.filters?.isEmpty ?? true) }
    private static let widthImageContext = CIContext()
    private let widthHeader = ChatDragView()
    private var widthPicture: CALayer?
    private var widthSharp: CALayer?
    private var widthBlurred: CALayer?
    private var widthClock: WidthDisplayClock?
    private var widthStartingOpacity: Float = 1
    var hasWidthPicture: Bool { widthPicture != nil }
    private(set) var widthPictureImage: CGImage?
    var widthPictureVisible: Bool { (widthPicture?.opacity ?? 0) > 0 }
    private(set) var widthFilterApplications = 0
    private(set) var contentLayouts = 0
    private(set) var filterApplications = 0
    private(set) var widthCaptureMS: Double = 0
    private static func blurred(_ image: CGImage, width: CGFloat) -> CGImage? {
        let scale = min(1, max(1, width) * 0.5 / CGFloat(image.width))
        let input = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let radius = 12 * CGFloat(image.width) / max(1, width) * scale
        let soft = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: input.extent)
        return widthImageContext.createCGImage(soft, from: input.extent)
    }
    func beginWidthPicture(page: (NSImage, NSView)? = nil) -> Bool {
        if let widthPicture { widthStartingOpacity = widthPicture.opacity; chatHost?.isHidden = true; return true }
        guard let host = chatHost, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        let started = ProcessInfo.processInfo.systemUptime
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let base = bitmap.cgImage else { return false }
        var captured: CGImage? = base
        if let (pageImage, view) = page {
            let composite = NSImage(size: host.bounds.size)
            composite.lockFocus()
            NSImage(cgImage: base, size: host.bounds.size).draw(in: host.bounds)
            let local = view.convert(view.bounds, to: host)
            let rect = CGRect(x: local.minX, y: host.isFlipped ? host.bounds.height-local.maxY : local.minY, width: local.width, height: local.height)
            pageImage.draw(in: rect)
            composite.unlockFocus()
            captured = composite.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        guard let image = captured, let output = Self.blurred(image, width: host.bounds.width) else { return false }
        let picture = CALayer(), sharp = CALayer(), soft = CALayer()
        picture.cornerRadius = PetLayout.cornerRadius; picture.masksToBounds = true
        picture.backgroundColor = nil
        sharp.contents = image; soft.contents = output; soft.opacity = 0
        widthPictureImage = output
        picture.addSublayer(sharp); picture.addSublayer(soft)
        coverLayer.addSublayer(picture)
        widthStartingOpacity = 1
        widthPicture = picture; widthSharp = sharp; widthBlurred = soft
        host.isHidden = true; widthHeader.isHidden = false
        updateWidthPicture(progress: 0, fade: 0)
        widthCaptureMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return true
    }
    private var panePageLayer: CALayer?
    private var panePageSharp: CALayer?
    private var panePageBase: CGFloat = 0
    private var panePageTop: CGFloat = 78
    /// The pictures shown while the window changes width live in a view of their own, right over the conversation.
    /// AppKit re-sorts the layers of subviews on layout, so a layer added to this view's own layer by hand ends up under the glass.
    private let coverHost = PetCoverView()
    private var coverLayer: CALayer {
        if coverHost.superview == nil {
            coverHost.wantsLayer = true; coverHost.frame = bounds; coverHost.autoresizingMask = [.width, .height]
            if let chatHost { addSubview(coverHost, positioned: .above, relativeTo: chatHost) } else { addSubview(coverHost) }
        }
        return coverHost.layer!
    }
    var hasPanePagePicture: Bool { panePageLayer?.contents != nil }
    /// Where the page's picture is drawn, in this view's coordinates; nil when there is none.
    var panePageRect: CGRect? {
        guard let page = panePageLayer, let picture = widthPicture, page.contents != nil else { return nil }
        return page.frame.offsetBy(dx: picture.frame.minX, dy: picture.frame.minY)
    }
    func setPanePagePicture(_ image: WebPicture?, base: CGFloat, top: CGFloat = 78, closing: Bool = false) {
        guard let picture = widthPicture else { return }
        panePageLayer?.removeFromSuperlayer(); panePageLayer = nil; panePageSharp = nil
        panePageBase = base; panePageTop = top
        guard let image else { return }
        let page = CALayer(); page.contents = image.soft; page.masksToBounds = true
        picture.addSublayer(page); panePageLayer = page
        if closing { let sharp = CALayer(); sharp.contents = image.sharp; page.addSublayer(sharp); panePageSharp = sharp }
        updateWidthPicture(progress: 0, fade: 0)
    }
    func beginPanePicture() -> Bool {
        if let widthPicture { widthStartingOpacity = widthPicture.opacity; chatHost?.isHidden = true; return true }
        let picture = CALayer()
        picture.cornerRadius = PetLayout.cornerRadius; picture.masksToBounds = true
        coverLayer.addSublayer(picture)
        widthPicture = picture; widthStartingOpacity = 1; widthCaptureMS = 0
        chatHost?.isHidden = true; widthHeader.isHidden = false
        updateWidthPicture(progress: 0, fade: 0)
        return true
    }
    func prepareWidthContent() {
        guard let host = chatHost else { return }
        host.frame = CGRect(x: bubbleSurface.frame.minX, y: bubbleSurface.frame.maxY - chatSize.height, width: chatSize.width, height: chatSize.height)
        host.layer?.mask = nil
        host.layoutSubtreeIfNeeded()
    }
    func startWidthClock() {
        guard widthClock == nil, !resting else { return }
        let created = ProcessInfo.processInfo.systemUptime
        var first = true
        widthClock = WidthDisplayClock(view: self) { [weak self] in
            if first { self?.genieTrace?.linkFirstMS = (ProcessInfo.processInfo.systemUptime-created)*1000; first = false }
            self?.onDisplayTick?()
        }
    }
    func updateWidthPicture(progress: CGFloat, fade: CGFloat) {
        guard let picture = widthPicture else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        picture.frame = placement?.bubbleRect ?? bubbleSurface.frame
        widthSharp?.frame = picture.bounds; widthBlurred?.frame = picture.bounds
        panePageLayer?.frame = CGRect(x: panePageBase, y: 0, width: max(0, picture.bounds.width-panePageBase), height: max(0, picture.bounds.height-panePageTop))
        panePageSharp?.frame = panePageLayer?.bounds ?? .zero
        panePageSharp?.opacity = Float(1 - ChatWidthSlide.cover(progress))
        widthHeader.frame = CGRect(x: picture.frame.minX, y: picture.frame.maxY - PetLayout.headerHeight, width: min(picture.frame.width, max(0, chatSize.width-paneWidth)), height: PetLayout.headerHeight)
        widthBlurred?.opacity = max(widthBlurred?.opacity ?? 0, Float(ChatWidthSlide.cover(progress)))
        widthSharp?.opacity = 1 - (widthBlurred?.opacity ?? 0)
        picture.opacity = (widthStartingOpacity + (1 - widthStartingOpacity) * Float(ChatWidthSlide.cover(progress))) * Float(1 - min(1, max(0, fade)))
        if fade > 0, chatHost?.isHidden == true {
            layoutChatContent(in: placement?.bubbleRect ?? bubbleSurface.frame)
        }
        chatHost?.alphaValue = min(1, max(0, fade))
        chatHost?.isHidden = fade <= 0
        CATransaction.commit()
    }
    func endWidthPicture() {
        if !genieActive { widthClock?.stop(); widthClock = nil }
        widthPicture?.removeFromSuperlayer(); widthPicture = nil; widthSharp = nil; widthBlurred = nil; widthPictureImage = nil
        panePageLayer = nil; panePageSharp = nil
        widthHeader.isHidden = true
        // The window may have shed its transition frame since the content was prepared.
        if chatExpanded && !genieActive { layoutChatContent(in: placement?.bubbleRect ?? bubbleSurface.frame) }
        chatHost?.isHidden = !chatExpanded || genieActive; chatHost?.alphaValue = 1
        needsLayout = true
    }
    var chatAlpha: CGFloat { chatHost?.alphaValue ?? 0 }
    var chatVisibilityProbe: (surface: NSView, host: NSView?, clipboardActive: Bool) {
        (bubbleSurface, chatHost, clipboardSurfaceActive)
    }
    var widthPictureTransparent: Bool { (widthPicture?.backgroundColor?.alpha ?? 0) == 0 }
    var onAnimationWork: ((Double, Double) -> Void)?
    var chatShown: Bool { chatHost?.isHidden == false }
    /// The conversation's height as last laid out, or nil while a new size still waits for its layout pass.
    var chatLaidOutHeight: CGFloat? {
        guard let host = chatHost, !needsLayout, !host.needsLayout else { return nil }
        return host.frame.height
    }
    /// The glass has stopped moving: a folded conversation is put away, an open one is left sharp.
    func finishMorph() {
        guard morphing else { return }
        morphing = false
        settleMorph()
    }
    /// At rest nothing is blurred or faint: whichever of the two is on screen is drawn plainly and the other is put away.
    private func settleMorph() {
        chatHost?.isHidden = !chatExpanded; bubbleText.isHidden = chatExpanded
        chatHost?.alphaValue = 1; bubbleText.alphaValue = 1
        chatHost?.layer?.filters = nil; chatBlur = 0
    }
    private func applyMorph(progress: CGFloat) {
        guard let host = chatHost else { return }
        let look = ChatMorph.look(progress: progress)
        host.alphaValue = look.alpha; bubbleText.alphaValue = look.bubbleAlpha
        chatBlurPeak = max(chatBlurPeak, look.blur)
        guard look.blur != chatBlur else { return }
        chatBlur = look.blur
        if widthPicture != nil { widthFilterApplications += 1 }
        if look.blur == 0 { host.layer?.filters = nil; return }
        filterApplications += 1
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return }
        filter.setValue(look.blur, forKey: kCIInputRadiusKey)
        host.layer?.filters = [filter]
    }
    var chatExpanded = false { didSet {
        guard chatExpanded != oldValue else { return }
        if clipboardDrop != nil {
            if chatExpanded { unregisterDraggedTypes() }
            else { registerForDraggedTypes(ClipboardPasteboard.supported) }
        }
        // Both stay on screen while the glass moves; each is put away when it has faded. With motion turned down nothing lingers.
        morphing = !reducesMotion
        updateClipboardPresentation()
        chatBlurPeak = 0
        if morphing { chatHost?.isHidden = false; bubbleText.isHidden = false } else { settleMorph() }
        updateScrim()
        setAccessibilityElement(!chatExpanded)
        if !chatExpanded { hoverArmed = false; hovering = false }
        updateBubbleShown()
        needsLayout = true
    } }
    func installChat(_ model: ChatModel, slack: SlackModel, web: WebPaneModel) {
        slackModel = slack
        seenPetHop = slack.petHop; seenPetWave = slack.petWave
        let host = GenieChatHost(rootView: ChatView(model: model, slack: slack, web: web))
        host.prepareEntryViewport = { [weak model, weak slack] in
            guard let model, let slack else { return true }
            return slack.source == .slack ? slack.prepareEntryViewport() : model.prepareEntryViewport()
        }
        host.sizingOptions = []
        host.wantsLayer = true
        host.layer?.cornerRadius = PetLayout.cornerRadius
        host.layer?.masksToBounds = true
        host.layerUsesCoreImageFilters = true
        host.isHidden = true
        addSubview(host)
        chatHost = host
        widthHeader.model = model; widthHeader.isHidden = true; addSubview(widthHeader)
    }
    func spriteContains(_ point: CGPoint) -> Bool {
        atlas.opaque(at:point,in:spriteRect,row:displayedFrame.row,frame:displayedFrame.column)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if spriteContains(local) { return self }
        guard (bubbleShown ? spriteRect.union(bubbleSurface.frame) : spriteRect).insetBy(dx: -12, dy: -12).contains(local) else { return nil }
        if !resizeEdge(local).isEmpty { return self }
        if hasWidthPicture { return widthHeader.frame.contains(local) ? widthHeader : self }
        if clipboardRowVisible, clipboardRowRect.contains(local) { return clipboardRow }
        if clipboardPresented, let host = clipboardHost, host.frame.contains(local) { return host.hitTest(local) ?? host }
        if chatExpanded, bubbleSurface.frame.contains(local), let host = chatHost {
            return host.hitTest(local) ?? host
        }
        // A conversation that is still fading away takes no clicks.
        if chatExpanded || morphing { return self }
        return super.hitTest(point)
    }
    var placement: PetPlacement? { didSet {
        needsLayout = true
        if placement?.spriteRect != oldValue?.spriteRect { needsDisplay = true }
    } }
    /// Layer geometry as submitted to Core Animation, separately from placement intent.
    var spriteLayerFrame: CGRect { spriteSurface.layer?.frame ?? spriteSurface.frame }
    var spritePresentationFrame: CGRect { spriteSurface.layer?.presentation()?.frame ?? spriteLayerFrame }
    var spriteDrawnScreenRect: CGRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(spritePresentationFrame, to: nil))
    }
    var spriteRect: CGRect { placement?.spriteRect ?? PetLayout(scale: petScale).spriteRect }
    var petScale: CGFloat = 1 { didSet { if petScale != oldValue { invalidateGeniePicture() }; needsLayout = true; needsDisplay = true } }
    var state: WorkState = .idle { didSet { bubbleText.state = state; if state == .waiting || state == .failed { cancelClipboardCopyNotice() } } }
    var headline = "ddots" { didSet { bubbleText.headline = headline; updateIdentityDescription() } }
    var subtitle = "AI 작업을 살펴보고 있어요" { didSet { bubbleText.subtitle = subtitle } }
    var actions: [String] = [] { didSet { bubbleText.actionTitles = actions; updateIdentityDescription(); if !actions.isEmpty { cancelClipboardCopyNotice() } } }
    var onAction: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var onPress: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onMoved: (() -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    var onClockFallback: (() -> Void)?
    var onResting: (() -> Void)?
    var onDisplayTick: (() -> Void)?
    var onAnimationTick: (() -> Void)?
    var isPaused = false { didSet {
        if isPaused { cancelClipboardCopyNotice() }
        animationStarted = ProcessInfo.processInfo.systemUptime; pointerInteraction.reset(); replyJump = false; chatPlayback = PetChatPlayback(); doze = PetDoze(); needsDisplay = true
        bubbleText.unreadCount = isPaused ? 0 : unreadCount
        bubbleText.setPulseAllowed(!isPaused && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        updatePetBadge()
    } }
    var screenFocus: ScreenFocus?
    var previewRow: Int? { didSet { animationStarted = ProcessInfo.processInfo.systemUptime } }
    var previewLook = false
    private var displayedFrame = PetAnimationFrame(row: 0, column: 0)
    private var currentAnimation: PetAnimation = .idle
    private var animationStarted = ProcessInfo.processInfo.systemUptime
    private var dragAnimation: PetAnimation = .right
    private var pointerInteraction = PetPointerInteraction()
    private let windowResolver = ScreenWindowResolver()
    private var spriteTracking: NSTrackingArea?
    private var wasLooking = false
    private var doze = PetDoze()
    /// The pet has nodded off; the bubble says so.
    private(set) var isDozing = false
    var onDozeChanged: (() -> Void)?
    private let dozeDelay: TimeInterval = CommandLine.arguments.contains("--ui-smoke-doze") ? 1 : PetDoze.delay
    private var dragStart: NSPoint?
    private var windowStart: NSPoint?
    /// Where the pointer is on the screen right now. A pet being carried goes by this and not by the event's place in
    /// the window: the window moves and changes size under the pointer on the way, so a place measured inside it is
    /// out of date by the time it is read, and the pet slips out from under a fast pointer.
    var pointerLocation: () -> NSPoint = { NSEvent.mouseLocation }
    private var didDrag = false
    private var previousDragMouse: NSPoint?
    private var timer: Timer?

    init(atlas: SpriteAtlas, identity: PetIdentity) {
        self.atlas = atlas
        self.identity = identity
        super.init(frame: NSRect(origin: .zero, size: PetLayout(scale: 1).windowSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        scrim.wantsLayer = true
        scrim.layer?.cornerRadius = PetLayout.cornerRadius
        scrim.layer?.masksToBounds = true
        surfaceContent.addSubview(scrim)
        surfaceContent.addSubview(bubbleText)
        clipboardCopyText.present(nil); surfaceContent.addSubview(clipboardCopyText)
        if #available(macOS 26.0, *) {
            let glass = PetGlassView()
            glass.style = .clear
            glass.cornerRadius = PetLayout.cornerRadius
            glass.contentView = surfaceContent
            bubbleSurface = glass
        } else {
            let glass = PetVibrancyView()
            glass.material = .popover
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = PetLayout.cornerRadius
            glass.layer?.masksToBounds = true
            glass.addSubview(surfaceContent)
            bubbleSurface = glass
        }
        addSubview(bubbleSurface)
        for _ in Self.thoughtDotSizes {
            let tint = NSView(); tint.wantsLayer = true
            let surface: NSView
            if #available(macOS 26.0, *) {
                let glass = PetGlassView(); glass.style = .clear; glass.contentView = tint; surface = glass
            } else {
                let glass = PetVibrancyView(); glass.material = .popover; glass.blendingMode = .behindWindow; glass.state = .active
                glass.wantsLayer = true; glass.layer?.masksToBounds = true; glass.addSubview(tint); surface = glass
            }
            addSubview(surface)
            thoughtDots.append((surface, tint))
        }
        spriteSurface.wantsLayer = true
        spriteSurface.onDraw = { [weak self] cell in self?.drawSprite(in: cell) }
        addSubview(spriteSurface)
        spriteSurface.layer?.zPosition = 1
        petBadge.wantsLayer = true; petBadge.layer?.zPosition = 2; petBadge.isHidden = true
        addSubview(petBadge)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        headline = identity.greeting
        bubbleText.headline = headline
        updateIdentityDescription()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(displayOptionsChanged),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    /// True while the screen is off or locked: nobody sees the pet, so nothing is drawn sixty times a second.
    var resting = false {
        didSet {
            guard resting != oldValue else { return }
            updateAnimationVisibility()
        }
    }
    private weak var animationWindow: NSWindow?
    var animationTimerActive: Bool { timer?.isValid == true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let animationWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: animationWindow)
        }
        animationWindow = window
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(updateAnimationVisibility), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updateAnimationVisibility()
    }
    /// Hidden windows still receive timer callbacks unless the timer itself is stopped. Keep data polling separate.
    @objc func updateAnimationVisibility() {
        if resting || window?.isVisible != true {
            cancelClipboardCopyNotice()
            let wasAnimating = timer != nil
            timer?.invalidate(); timer = nil
            pointerInteraction.reset(); bubbleText.setPulseAllowed(false)
            if wasAnimating { onResting?() }
            widthClock?.stop(); widthClock = nil
        } else if timer == nil {
            startAnimating()
        }
    }
    private func startAnimating() {
        timer?.invalidate()
        let animationTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.advanceAnimation()
        }
        timer = animationTimer
        RunLoop.main.add(animationTimer, forMode: .common)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let clipboardLocalEvents { NSEvent.removeMonitor(clipboardLocalEvents) }; if let clipboardGlobalEvents { NSEvent.removeMonitor(clipboardGlobalEvents) }; timer?.invalidate(); widthClock?.stop(); NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    @objc private func displayOptionsChanged() { updateScrim() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); invalidateGeniePicture(); updateScrim()
    }
    /// Dark appearance tints toward black, light toward white, deepening as the bubble grows into the conversation.
    private func updateScrim() {
        let collapsedHeight = PetLayout.bubbleSize(actionCount: 1).height
        let progress = chatSize.height > collapsedHeight
            ? Double((bubbleSurface.frame.height - collapsedHeight) / (chatSize.height - collapsedHeight)) : 0
        let shelfProgress = min(1, max(0, Double((bubbleSurface.frame.height - foldedHeight) / max(1, clipboardOpenHeight - foldedHeight))))
        if !clipboardPresented && !clipboardRowVisible && bubbleSurface.frame.height <= foldedHeight + 1 { clipboardSurfaceActive = false }
        if chatExpanded { clipboardSurfaceActive = false }
        let drawerMaterial = !chatExpanded && clipboardSurfaceActive
        let alpha = BubbleOpacity.alpha(progress: drawerMaterial ? shelfProgress : progress,
                                        percent: drawerMaterial ? clipboardOpacityPercent : chatOpacityPercent,
                                        reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || CommandLine.arguments.contains("--ui-smoke-reduce-transparency"))
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let tint: NSColor = drawerMaterial && dark ? NSColor(calibratedRed: 0.015, green: 0.02, blue: 0.04, alpha: 1) : (dark ? .black : .white)
        scrim.layer?.backgroundColor = tint.withAlphaComponent(alpha).cgColor
        let radius: CGFloat = drawerMaterial ? 24 : PetLayout.cornerRadius
        scrim.layer?.cornerRadius = radius
        if #available(macOS 26, *), let glass = bubbleSurface as? PetGlassView { glass.cornerRadius = radius }
        else { bubbleSurface.layer?.cornerRadius = radius }
        bubbleSurface.layer?.shadowOpacity = drawerMaterial ? 0.25 : 0
        bubbleSurface.layer?.shadowColor = NSColor.black.cgColor
        bubbleSurface.layer?.shadowRadius = 14
        bubbleSurface.layer?.shadowOffset = CGSize(width: 0, height: -6)
        bubbleSurface.layer?.shadowPath = drawerMaterial ? CGPath(roundedRect: bubbleSurface.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil) : nil
        if drawerMaterial {
            scrim.layer?.borderWidth = 1 / (window?.backingScaleFactor ?? 2)
            scrim.layer?.borderColor = NSColor.white.withAlphaComponent(dark ? 0.2 : 0.6).cgColor
        } else { scrim.layer?.borderWidth = 0 }
        for dot in thoughtDots {
            // The circles are too small for the glass to read on its own, so they carry a little more tint than the bubble.
            dot.tint.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(min(1, alpha + 0.15)).cgColor
            dot.tint.layer?.borderColor = (dark ? NSColor.white : NSColor.black).withAlphaComponent(0.18).cgColor
            dot.tint.layer?.borderWidth = 0.5
        }
        CATransaction.commit()
    }
    private func updateIdentityDescription() {
        let buttons = actions.isEmpty ? "" : " · 버튼: \(actions.joined(separator: ", "))"
        setAccessibilityLabel("ddots · \(identity.name) · \(headline)\(buttons) · 안 읽은 답 \(unreadCount)개")
        toolTip = "\(identity.name) · 클릭: 열기 · 드래그: 이동 · 오른쪽 클릭: 메뉴"
    }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        let previousSize = spriteSurface.frame.size
        spriteSurface.frame = spriteRect
        if spriteSurface.frame.size != previousSize { spriteSurface.needsDisplay = true }
        bubbleSurface.frame = placement?.bubbleRect ?? PetLayout(scale: petScale).bubbleRect
        surfaceContent.frame = NSRect(origin: .zero, size: bubbleSurface.frame.size)
        scrim.frame = surfaceContent.bounds
        let rowHeight: CGFloat = clipboardRowVisible ? (clipboardPresented ? ClipboardDrawer.footerHeight : ClipboardDrawer.rowHeight) : 0
        let below = placement?.bubbleBelow == true
        let regions = ClipboardDrawer.regions(in: surfaceContent.bounds, rowHeight: rowHeight, below: below)
        bubbleText.frame = regions.content
        clipboardCopyText.frame = bubbleText.frame
        clipboardRow.below = below; clipboardRow.frame = regions.row
        clipboardHost?.frame = regions.content.offsetBy(dx: bubbleSurface.frame.minX, dy: bubbleSurface.frame.minY)
        layoutThoughtDots()
        updatePetBadge()
        updateScrim()
        if morphing && !genieActive { applyMorph(progress: ChatMorph.progress(height: bubbleSurface.frame.height, folded: foldedHeight, open: chatSize.height)) }
        if widthPicture == nil && !genieActive, chatExpanded || morphing {
            layoutChatContent(in: bubbleSurface.frame)
        }
        if genieActive { bubbleSurface.isHidden = true; chatHost?.isHidden = true; bubbleText.isHidden = true }
        updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }
    private func layoutChatContent(in rect: CGRect) {
        guard let host = chatHost else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Keep the full conversation dimensions while the glass grows; hide rather than destroy on collapse.
        let before = host.frame.size
        host.frame = NSRect(x: morphing ? rect.midX-chatSize.width/2 : rect.minX, y: rect.maxY - chatSize.height,
                            width: chatWidthFollowsGlass ? rect.width : chatSize.width, height: chatSize.height)
        if host.frame.size != before { contentLayouts += 1 }
        let visibleHeight = min(chatSize.height, rect.height)
        let mask = CAShapeLayer()
        mask.path = CGPath(roundedRect: CGRect(x: morphing ? max(0,(chatSize.width-rect.width)/2) : 0, y: host.isFlipped ? 0 : chatSize.height - visibleHeight,
                                              width: chatWidthFollowsGlass ? rect.width : min(chatSize.width, rect.width), height: visibleHeight),
                           cornerWidth: 20, cornerHeight: 20, transform: nil)
        host.layer?.mask = mask
        CATransaction.commit()
    }
    /// The circles grow from the pet's head toward the bubble and drift a little to one side, smallest nearest the head.
    /// With no room between the two they are left out.
    var perched = false { didSet {
        guard perched != oldValue else { return }
        // Glass surfaces are detached below while perched, including during transitions.
        for dot in thoughtDots { dot.surface.alphaValue = perched ? 0 : (bubbleShown ? 1 : 0) }
        layoutThoughtDots()
    } }
    var thoughtDotsVisible: Bool { thoughtDots.contains { !$0.surface.isHidden && $0.surface.alphaValue > 0 } }
    private func layoutThoughtDots() {
        let bubble = bubbleSurface.frame
        let head = atlas.interactionRect(in: spriteRect)
        let below = placement?.bubbleBelow == true
        let start = below ? head.minY : head.maxY, end = below ? bubble.maxY : bubble.minY
        let gap = abs(end - start)
        let room = gap >= 26 && !bubbleStowed && !perched
        // The trail leans toward the bubble's middle, but never far from the head.
        let lean = max(-18, min(18, (bubble.midX - head.midX) * 0.25 + 12))
        for (index, dot) in thoughtDots.enumerated() {
            dot.surface.isHidden = !room
            if perched { dot.surface.removeFromSuperview() }
            else if dot.surface.superview == nil { addSubview(dot.surface) }
            guard room else { continue }
            let size = Self.thoughtDotSizes[index]
            let along = [0.14, 0.44, 0.78][index]
            let y = start + (end - start) * along
            let x = head.midX + lean * CGFloat(along)
            dot.surface.frame = NSRect(x: (x - size / 2).rounded(), y: (y - size / 2).rounded(), width: size, height: size)
            dot.tint.frame = dot.surface.bounds
            dot.tint.layer?.cornerRadius = size / 2
            if #available(macOS 26.0, *), let glass = dot.surface as? PetGlassView { glass.cornerRadius = size / 2 }
            else { dot.surface.layer?.cornerRadius = size / 2 }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let spriteTracking { removeTrackingArea(spriteTracking) }
        let area = NSTrackingArea(rect: atlas.interactionRect(in: spriteRect),
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area); spriteTracking = area
    }
    override func mouseEntered(with event: NSEvent) { advanceAnimation() }
    override func mouseExited(with event: NSEvent) { advanceAnimation() }

    private func advanceAnimation() {
        let began = ProcessInfo.processInfo.systemUptime
        defer { onAnimationWork?(began, ProcessInfo.processInfo.systemUptime - began) }
        guard let window, window.isVisible else { pointerInteraction.reset(); bubbleText.setPulseAllowed(false); return }
        if widthClock == nil { onAnimationTick?() } else { onClockFallback?() }
        updateBubbleShown()
        bubbleText.setPulseAllowed(!isPaused && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard !isPaused else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let mouse = NSEvent.mouseLocation
        let rect = window.convertToScreen(convert(atlas.interactionRect(in: spriteRect), to: nil))
        let display = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? window.screen
        let reduced = reducesMotion
        let pointer = pointerInteraction.update(pointer: mouse, sprite: rect, display: display?.frame ?? .zero,
                                                now: now, enabled: !didDrag && previewRow == nil && !previewLook,
                                                reducedMotion: reduced)
        let pointerElapsed: TimeInterval?
        if case .jumping(let elapsed) = pointer { pointerElapsed = elapsed } else { pointerElapsed = nil }
        let slackApproval = slackModel?.needsPetApproval == true
        let replyWaiting = chatAnimation == .replyWaiting || (slackModel.map { $0.source == .slack && $0.isWriting } ?? false)
        let animationState: WorkState = state == .failed ? .failed : slackApproval ? .waiting : state
        let urgent = animationState == .waiting || animationState == .failed
        let jump = chatPlayback.update(now: now, reply: replyJump, pointerElapsed: pointerElapsed,
                                       enabled: !didDrag && previewRow == nil && !previewLook && !urgent)
        replyJump = false
        let animation = PetChatPlayback.animation(state:animationState,typing:replyWaiting && !previewLook,jumping:jump != nil,
                                                  drag:didDrag ? dragAnimation : nil,preview:previewRow.flatMap(PetAnimation.init(rawValue:)))
        if currentAnimation != animation { currentAnimation = animation; animationStarted = now }
        var frame = PetAnimationTimeline.frame(for: animation, elapsed: jump ?? (now - animationStarted),
                                               reducedMotion: reduced,
                                               loop: didDrag || previewRow != nil || animation == .replyWaiting)
        var behavior = animation.name
        var looking = false
        if previewRow == PetAnimationTimeline.dozeRow {
            frame = PetAnimationTimeline.dozeFrame(elapsed: now - animationStarted, reducedMotion: reduced)
            behavior = "조는 중 미리보기"
        } else if let row = previewRow, row >= 9 {
            frame = PetAnimationFrame(row: row, column: Int((now - animationStarted) / 0.25) % 8)
            behavior = "시선 미리보기"
        } else if previewRow == nil, !didDrag, !urgent, jump == nil, !replyWaiting || previewLook {
            var target: CGPoint?
            switch pointer {
            case .jumping: break // Shared playback above owns all jumps.
            case .looking:
                target = mouse; behavior = "커서 따라보기 · dot"
            case .inactive:
                if previewLook { target = mouse; behavior = "마우스 시선 미리보기" }
                else if animation.allowsLook, let focus = screenFocus, focus.expiresAt > Date() {
                    target = windowResolver.resolve(focus, now: now)
                    behavior = target == nil ? "\(focus.provider.name) · 대상 창 확인 중" : "\(focus.provider.name) · 먼저 시작한 작업 창 보기"
                }
            }
            if let target, let look = PetAnimationTimeline.lookFrame(from: CGPoint(x: rect.midX, y: rect.midY), toward: target,
                                                                   previous: wasLooking ? displayedFrame : nil) {
                frame = look; looking = true
            }
        }
        if wasLooking && !looking { animationStarted = now }
        wasLooking = looking
        // Left alone with the conversation folded and nothing to do, look at or react to, the pet nods off.
        let quiet = animation == .idle && previewRow == nil && !previewLook && !looking && pointer == .inactive && !chatExpanded
        let dozing = doze.update(now: now, quiet: quiet, after: dozeDelay)
        if let dozing {
            frame = PetAnimationTimeline.dozeFrame(elapsed: dozing, reducedMotion: reduced)
            behavior = "조는 중"
        } else if isDozing { animationStarted = now }
        if isDozing != (dozing != nil) { isDozing = dozing != nil; onDozeChanged?() }
        if let slack = slackModel {
            if chatExpanded, slack.source == .slack, slack.isDdots, !urgent, !didDrag, previewRow == nil, !previewLook {
                let writing = slack.isWriting
                let conversation = window.convertToScreen(convert(bubbleSurface.frame, to: nil))
                let elapsed = chatPetBehavior.update(now: now, touching: rect.contains(mouse), cursorNear: conversation.contains(mouse),
                    writing: writing, hop: slack.petHop != seenPetHop, wave: slack.petWave != seenPetWave)
                switch chatPetBehavior.pose {
                case .approval: frame = PetAnimationTimeline.frame(for: .waiting, elapsed: elapsed, reducedMotion: reduced)
                case .jump: frame = PetAnimationTimeline.frame(for: .jumping, elapsed: elapsed, reducedMotion: reduced, loop: true)
                case .replyWaiting: frame = PetAnimationTimeline.frame(for: .replyWaiting, elapsed: elapsed, reducedMotion: reduced, loop: true)
                case .wave: frame = PetAnimationTimeline.frame(for: .waving, elapsed: elapsed, reducedMotion: reduced, loop: true)
                case .idle: frame = PetAnimationTimeline.frame(for: .idle, elapsed: elapsed, reducedMotion: reduced)
                case .look:
                    frame = PetAnimationTimeline.lookFrame(from: CGPoint(x: rect.midX, y: rect.midY), toward: mouse,
                        previous: (9...10).contains(displayedFrame.row) ? displayedFrame : nil) ?? frame
                }
                behavior = "대화 · \(chatPetBehavior.pose)"
            } else { chatPetBehavior.reset() }
            seenPetHop = slack.petHop; seenPetWave = slack.petWave
        }
        if displayedFrame != frame { displayedFrame = frame; spriteSurface.needsDisplay = true }
        let side = placement?.bubbleBelow == true ? "아래" : "위"
        let help = "클릭: 열기 · 드래그: 이동 · 오른쪽 클릭: 메뉴 · 동작: \(behavior) · 행 \(frame.row), 프레임 \(frame.column) · 말풍선: \(side)"
        if accessibilityHelp() != help { setAccessibilityHelp(help) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
    }
    private func drawSprite(in cell: CGRect) {
        atlas.draw(row: displayedFrame.row, frame: displayedFrame.column, in: cell, view: spriteSurface)
        if displayedFrame.row == PetAnimationTimeline.dozeRow { drawZs(PetAnimationTimeline.dozeZs(column: displayedFrame.column), in: cell) }
    }
    /// Each z is written white with a dark edge, like the pet's own outline, in the square it is given.
    private func drawZs(_ squares: [CGRect], in cell: CGRect) {
        let unit = cell.width / PetSpritePresentation.cellSize.width
        for square in squares {
            let left = cell.minX + square.minX * unit, right = cell.minX + square.maxX * unit
            let top = cell.maxY - square.minY * unit, bottom = cell.maxY - square.maxY * unit
            let z = NSBezierPath()
            z.move(to: NSPoint(x: left, y: top)); z.line(to: NSPoint(x: right, y: top))
            z.line(to: NSPoint(x: left, y: bottom)); z.line(to: NSPoint(x: right, y: bottom))
            z.lineCapStyle = .round; z.lineJoinStyle = .round
            for (width, color) in [(4.0, NSColor(red: 16/255, green: 12/255, blue: 12/255, alpha: 1)), (1.9, NSColor.white)] {
                color.setStroke(); z.lineWidth = width * unit; z.stroke()
            }
        }
    }
    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow,from:nil)
        // Hosting views forward unhandled presses in their blank space through the responder chain.
        let edge: PetLayout.ResizeEdge = spriteContains(local) ? [] : resizeEdge(local)
        if !edge.isEmpty, let placement, let window, let screen = window.screen {
            clearDrag()
            if clipboardPresented {
                if event.clickCount == 2 { onResetClipboardSize?(); return }
                clipboardResizing = true; clipboardHolding = true
                resizeDrag = (window.convertPoint(toScreen:event.locationInWindow),placement,screen.visibleFrame,screen.frame,edge,0)
                return
            }
            if event.clickCount == 2 { if paneWidth > 0, edge.contains(.right) { onResetPaneSize?() } else { onResetChatSize?() }; return }
            resizeDrag = (window.convertPoint(toScreen:event.locationInWindow),placement,screen.visibleFrame,screen.frame,edge,paneWidth)
            onResizeBegan?(); return
        }
        if clipboardPresented && clipboardContains(local) { clipboardLibrary?.selectedIDs.removeAll(); clearDrag(); return }
        if isExpandedBubbleEvent(event) { clearDrag(); return }
        dragStart = window?.convertPoint(toScreen: event.locationInWindow); previousDragMouse = dragStart
        windowStart = placement?.anchorOrigin; didDrag = false
    }
    override func mouseDragged(with event: NSEvent) {
        if let resizeDrag, let window {
            let point = window.convertPoint(toScreen:event.locationInWindow)
            let delta = CGPoint(x:point.x-resizeDrag.point.x,y:point.y-resizeDrag.point.y)
            if clipboardResizing {
                let start = resizeDrag.placement.globalBubble.size
                let width = start.width + (resizeDrag.edge.contains(.right) ? 2 * delta.x : resizeDrag.edge.contains(.left) ? -2 * delta.x : 0)
                let height = start.height + (resizeDrag.edge.contains(.far) ? (resizeDrag.placement.bubbleBelow ? -delta.y : delta.y) : 0)
                onClipboardResize?(CGSize(width: width, height: height)); return
            }
            var edge = resizeDrag.edge
            if resizeDrag.pane > 0, edge.contains(.right) { onResizePane?(resizeDrag.pane+delta.x); edge.remove(.right) }
            if !edge.isEmpty || resizeDrag.pane == 0 {
                let size = PetLayout.resized(resizeDrag.placement,edge:edge,delta:delta,screen:resizeDrag.screen,trailing:resizeDrag.pane,screenFrame:resizeDrag.fullScreen)
                let origin = edge.contains(.near) ? PetLayout.resizedSpriteOrigin(resizeDrag.placement,edge:edge,size:size) : nil
                onResize?(size,origin)
            }
            return
        }
        // A pet that was picked up stays in the hand wherever the pointer goes, across its own conversation too.
        // A press that began in the conversation never set a start, so it still moves nothing.
        guard let start = dragStart, let origin = windowStart else { return }
        let mouse = pointerLocation()
        if hypot(mouse.x - start.x, mouse.y - start.y) > 4 { didDrag = true }
        dragAnimation = PetAnimationTimeline.dragAnimation(horizontalDelta: mouse.x - (previousDragMouse?.x ?? start.x), previous: dragAnimation)
        previousDragMouse = mouse
        onDragMove?(NSPoint(x: origin.x + mouse.x - start.x, y: origin.y + mouse.y - start.y))
        advanceAnimation()
    }
    override func mouseUp(with event: NSEvent) {
        if resizeDrag != nil {
            resizeDrag = nil
            if clipboardResizing { clipboardResizing = false; clipboardHolding = false; clipboardExitDeadline = nil }
            else { onResizeEnded?() }
            return
        }
        if dragStart != nil { onDragEnded?() }
        // Let go over the conversation, a pet that was being carried is still set down where it is.
        if !didDrag, isExpandedBubbleEvent(event) { clearDrag(); return }
        guard dragStart != nil else { return }
        if didDrag { onMoved?() }
        else if bubbleShown, let index = actionIndex(at: convert(event.locationInWindow, from: nil)) { onAction?(index) }
        else { onClick?(event.clickCount) }
        clearDrag()
        updateTrackingAreas(); advanceAnimation()
    }
    private func isExpandedBubbleEvent(_ event: NSEvent) -> Bool {
        chatExpanded && bubbleSurface.frame.contains(convert(event.locationInWindow, from: nil)) && !spriteContains(convert(event.locationInWindow,from:nil))
    }
    private func clearDrag() {
        didDrag = false; dragStart = nil; windowStart = nil; previousDragMouse = nil
    }
    private func actionIndex(at point: NSPoint) -> Int? {
        let origin = bubbleSurface.frame.origin
        return PetLayout.actionRects(count: actions.count).firstIndex {
            $0.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: -3).contains(point)
        }
    }
    private static func diagonalCursor(_ rising: Bool) -> NSCursor {
        let image = NSImage(size:NSSize(width:20,height:20),flipped:false) { _ in
            let path = NSBezierPath()
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x:x,y:rising ? y : 20-y) }
            path.move(to:point(4,4)); path.line(to:point(16,16))
            path.move(to:point(4,10)); path.line(to:point(4,4)); path.line(to:point(10,4))
            path.move(to:point(10,16)); path.line(to:point(16,16)); path.line(to:point(16,10))
            NSColor.white.setStroke(); path.lineWidth = 4; path.stroke()
            NSColor.black.setStroke(); path.lineWidth = 2; path.stroke(); return true
        }
        return NSCursor(image:image,hotSpot:NSPoint(x:10,y:10))
    }
    private static let risingResizeCursor = diagonalCursor(true), fallingResizeCursor = diagonalCursor(false)
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let placement else { return }
        if clipboardPresented {
            let r = placement.bubbleRect
            addCursorRect(CGRect(x: r.minX, y: r.minY + ClipboardDrawer.footerHeight, width: 6, height: max(0, r.height - ClipboardDrawer.footerHeight)), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: r.maxX - 6, y: r.minY + ClipboardDrawer.footerHeight, width: 6, height: max(0, r.height - ClipboardDrawer.footerHeight)), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: r.minX + 6, y: r.maxY - 6, width: r.width - 12, height: 6), cursor: .resizeUpDown)
            return
        }
        guard chatExpanded else { return }
        for region in PetLayout.resizeRegions(bubble: placement.bubbleRect, below: placement.bubbleBelow) {
            let cursor: NSCursor
            if region.edge == .far { cursor = .resizeUpDown }
            else if !region.edge.contains(.far) && !region.edge.contains(.near) { cursor = .resizeLeftRight }
            else {
                let rising = (region.edge.contains(.left) == placement.bubbleBelow) != region.edge.contains(.near)
                cursor = rising ? Self.risingResizeCursor : Self.fallingResizeCursor
            }
            addCursorRect(region.rect, cursor: cursor)
        }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?(event) }
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}


private final class WidthDisplayClock: NSObject {
    private var modern: AnyObject?
    private var legacy: CVDisplayLink?
    private var signal: DispatchSourceUserDataAdd?
    private let tick: () -> Void
    init(view: NSView, tick: @escaping () -> Void) {
        self.tick = tick
        super.init()
        if #available(macOS 14.0, *) {
            let link = view.displayLink(target: self, selector: #selector(step))
            modern = link; link.add(to: .main, forMode: .common)
        } else {
            let source = DispatchSource.makeUserDataAddSource(queue: .main)
            signal = source; source.setEventHandler { [weak self] in self?.tick() }; source.resume()
            CVDisplayLinkCreateWithActiveCGDisplays(&legacy)
            if let legacy {
                CVDisplayLinkSetOutputCallback(legacy, { _, _, _, _, _, context in
                    guard let context else { return kCVReturnError }
                    Unmanaged<WidthDisplayClock>.fromOpaque(context).takeUnretainedValue().signal?.add(data: 1)
                    return kCVReturnSuccess
                }, Unmanaged.passUnretained(self).toOpaque())
                CVDisplayLinkStart(legacy)
            }
        }
    }
    @objc private func step() { tick() }
    func stop() {
        if #available(macOS 14.0, *) { (modern as? CADisplayLink)?.invalidate(); modern = nil }
        if let legacy { CVDisplayLinkStop(legacy); self.legacy = nil }
        signal?.cancel(); signal = nil
    }
    deinit { stop() }
}
