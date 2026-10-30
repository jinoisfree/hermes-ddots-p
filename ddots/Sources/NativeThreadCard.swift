import AppKit
import SwiftUI

/// A whole thread drawn by AppKit: posts, my bubbles, status notes, the pile of folded replies and their rail,
/// the foot and the bell. The few intricate parts (project record, approval row, vault and drive buttons, files,
/// quoted or paged posts, writing dots, the stop control) are the existing SwiftUI views hosted in place.
/// Layout is computed without views, so the table knows every row's height before it is shown.
final class NativeThreadCard: NSTableCellView, NSTextViewDelegate {
    struct Action {
        var title: String
        var symbol: String
        var label: String
        var identifier: String
        var enabled = true
        var color: NSColor = .labelColor.withAlphaComponent(0.7)
        var alwaysLabel = false
        var invoke: () -> Void
    }
    struct Mark { var color: NSColor; var text: NSAttributedString }
    /// One message: a character's post (face, name, time, words) or my own bubble.
    struct Post {
        var id: String
        var mine: Bool
        var text: NSAttributedString
        var speaker: String
        var time: String
        var avatar: ProfileAvatar
        var nameColor: NSColor
        var conversational = false
        var pending = false
        var interrupted = false
        var marks: [Mark] = []
        var foldTitle: String?
        var fold: () -> Void = {}
        var flash = false
        var openLink: (URL) -> Void
        var reportHeight: ((CGFloat) -> Void)?
    }
    enum Piece {
        case owner(name: String, avatar: ProfileAvatar)
        case post(Post)
        /// What the thread waits on, under its first line.
        case note(Mark, mine: Bool)
        case stack(faces: [(String, ProfileAvatar)], title: String, toggle: () -> Void, identifier: String)
        case hosted(id: String, view: () -> AnyView)
    }
    struct Style {
        var inset: CGFloat
        var fill: CGFloat
        var stroke: NSColor?
        var lineWidth: CGFloat
        var background: NSColor? = nil
        var status: NSColor? = nil
        var replyBackground: NSColor? = nil
    }
    struct Content {
        var id: String
        var top: [Piece]
        var replies: [Piece]?
        var rail: NSColor?
        var actions: [Action]
        var deleting: String?
        var style: Style
        var bell: Bool?
        var onBell: () -> Void
        var clickCard: () -> Void
        /// Only a folded thread opens from a click on its words; elsewhere the words are for selecting.
        var textClick: (() -> Void)?
        var bubbleWidth: CGFloat
        var quiet: NSColor
        var expanded: Bool
        var summary: String = ""
        var statusTitle: String = ""
        var replyTarget = false
        var workspaceFooter: Bool { !summary.isEmpty }
    }
    struct Placed {
        var piece: Piece
        var frame: NSRect
        var text: NSRect = .zero
        var marks: [NSRect] = []
        var fold: NSRect = .zero
        var time: NSRect = .zero
        var aside: NSRect = .zero
        var bubble: NSRect = .zero
    }
    struct Layout {
        let identity = UUID()
        var content: Content
        var width: CGFloat
        var height: CGFloat
        var placed: [Placed]
        var rail: NSRect?
        var foot: NSRect
        var summary: NSRect
        var compact: Bool
        /// Where each message sits in the card, for scrolling to it.
        var anchors: [String: NSRect]
    }

    // MARK: Measuring without views

    /// NSTextView and the offscreen calculator use the same zero-padding TextKit container.
    static func textSize(_ text: NSAttributedString, width: CGFloat) -> NSSize {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager); manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        let size = manager.usedRect(for: container).size
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
    private static var symbolSizes: [String: NSSize] = [:]
    static func symbolSize(_ name: String) -> NSSize {
        if let size = symbolSizes[name] { return size }
        let size = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: ChatMetrics.auxiliaryFont, weight: .medium))?.size ?? NSSize(width: 14, height: 14)
        symbolSizes[name] = size
        return size
    }
    static let footFont = NSFont.systemFont(ofSize: ChatMetrics.auxiliaryFont, weight: .medium)
    static func actionWidth(_ action: Action, compact: Bool) -> CGFloat {
        let title = !compact || action.alwaysLabel ? action.title : ""
        return symbolSize(action.symbol).width + (title.isEmpty ? 0 : 8 + ceil(width(title, font: footFont)))
    }
    /// Names and labels repeat on every card; their widths are measured once, not on each draw.
    private static var widths: [String: CGFloat] = [:]
    static func width(_ string: String, font: NSFont) -> CGFloat {
        let key = font.fontName + "|" + String(describing: font.pointSize) + "|" + string
        if let known = widths[key] { return known }
        if widths.count > 2000 { widths.removeAll() }
        let measured = (string as NSString).size(withAttributes: [.font: font]).width
        widths[key] = measured
        return measured
    }
    /// Hosted pieces are measured with one offscreen controller; their size is all the layout needs.
    private static let measurer = NSHostingController(rootView: AnyView(EmptyView()))
    static func hostedSize(_ view: AnyView, width: CGFloat) -> NSSize {
        measurer.rootView = AnyView(view.frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        let size = measurer.sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude))
        return NSSize(width: width, height: ceil(max(0, size.height)))
    }
    static let stackFont = NSFont.systemFont(ofSize: ChatMetrics.auxiliaryFont, weight: .medium)
    static let noteFont = NSFont.systemFont(ofSize: ChatMetrics.auxiliaryFont, weight: .medium)
    static let stackLine: CGFloat = 14

    static func layout(_ content: Content, width: CGFloat) -> Layout {
        let inset = content.style.inset
        let usable = max(1, width - 2 * inset)
        var placed: [Placed] = []
        var anchors: [String: NSRect] = [:]
        let badgeWidth = (content.statusTitle.isEmpty ? 0 : Self.width(content.statusTitle, font: footFont) + 30)
            + (content.replyTarget ? Self.width("답글 작성 중", font: footFont) + 30 : 0)
        let inlineBadge: Bool
        if case .post(let post)? = content.top.first, !post.mine {
            let speakerWidth = ChatMetrics.avatar + 9 + Self.width(post.speaker, font: .systemFont(ofSize: ChatMetrics.nameFont, weight: .bold))
                + Self.width(post.time, font: .systemFont(ofSize: 10)) + 22
            inlineBadge = usable > speakerWidth + badgeWidth
        } else { inlineBadge = false }
        var y = inset + (badgeWidth == 0 || inlineBadge ? 0 : 30)
        var first = true
        func gap() { if !first { y += 10 }; first = false }
        func place(_ piece: Piece, x: CGFloat, width: CGFloat) {
            gap()
            switch piece {
            case .owner:
                placed.append(Placed(piece: piece, frame: NSRect(x: x, y: y, width: width, height: 14)))
                // The legacy label pulls the next line two points closer.
                y += 12
            case .post(let post):
                var item = Placed(piece: piece, frame: .zero)
                if post.mine {
                    let limit = max(1, min(width, content.bubbleWidth) - 24)
                    let size = textSize(post.text, width: limit)
                    let bubble = NSRect(x: x + width - size.width - 24, y: y, width: size.width + 24, height: size.height + 16)
                    item.text = bubble.insetBy(dx: 12, dy: 8)
                    item.aside = bubble
                    var bottom = bubble.maxY
                    if post.interrupted {
                        item.fold = NSRect(x: x, y: bottom + ChatMetrics.nameBodyGap, width: width - 10, height: 14)
                        bottom = item.fold.maxY
                    }
                    item.time = NSRect(x: x, y: bottom + ChatMetrics.nameBodyGap, width: width - 10, height: 14)
                    item.frame = NSRect(x: x, y: y, width: width, height: item.time.maxY - y)
                } else {
                    let textX = x + ChatMetrics.avatar + 9, textWidth = max(1, width - ChatMetrics.avatar - 9)
                    let bubble = post.conversational
                    let limit = bubble ? max(1, min(textWidth, content.bubbleWidth) - 24) : textWidth
                    let size = textSize(post.text, width: limit)
                    item.aside = NSRect(x: x, y: y, width: ChatMetrics.avatar, height: ChatMetrics.avatar)
                    item.time = NSRect(x: textX, y: y, width: textWidth, height: 16)
                    item.text = NSRect(x: textX + (bubble ? 12 : 0), y: y + 21 + (bubble ? 8 : 0),
                                       width: bubble ? size.width : textWidth, height: size.height)
                    if bubble { item.bubble = item.text.insetBy(dx: -12, dy: -8) }
                    var bottom = bubble ? item.bubble.maxY : item.text.maxY
                    for mark in post.marks {
                        let markSize = textSize(mark.text, width: max(1, textWidth - 10))
                        let frame = NSRect(x: textX, y: bottom + 6, width: textWidth, height: markSize.height)
                        item.marks.append(frame); bottom = frame.maxY
                    }
                    if post.foldTitle != nil {
                        item.fold = NSRect(x: textX, y: bottom + 5, width: 70, height: 14); bottom = item.fold.maxY
                    }
                    item.frame = NSRect(x: x, y: y, width: width, height: max(ChatMetrics.avatar, bottom - y))
                }
                anchors[post.id] = item.frame; anchors["message:" + post.id] = item.frame
                placed.append(item); y = item.frame.maxY
            case .note(let mark, let mine):
                let lead: CGFloat = mine ? 4 : ChatMetrics.avatar + 9
                let size = textSize(mark.text, width: max(1, width - lead - 10))
                let w = min(width - lead, size.width + 10)
                let frame = NSRect(x: mine ? x + width - w : x + lead, y: y, width: w, height: size.height)
                placed.append(Placed(piece: piece, frame: frame, text: NSRect(x: frame.minX + 10, y: y, width: w - 10, height: size.height)))
                y = frame.maxY
            case .stack(let faces, let title, _, _):
                let facesWidth: CGFloat = faces.isEmpty ? 0 : 16 + CGFloat(faces.count - 1) * 11 + 7
                let w = (faces.isEmpty ? 12 : 8) + facesWidth + ceil(Self.width(title, font: stackFont)) + 7 + 9 + 11
                let frame = NSRect(x: x, y: y, width: min(width, w), height: 7 + stackLine + 7)
                placed.append(Placed(piece: piece, frame: frame))
                y = frame.maxY + 9
            case .hosted(let id, let view):
                let size = hostedSize(view(), width: width)
                let frame = NSRect(x: x, y: y, width: width, height: size.height)
                placed.append(Placed(piece: piece, frame: frame))
                anchors[id] = frame
                y = frame.maxY
            }
        }
        for piece in content.top { place(piece, x: inset, width: usable) }
        var rail: NSRect?
        if let replies = content.replies, !replies.isEmpty {
            gap(); first = true
            let indent: CGFloat = 0
            let top = y
            for piece in replies { place(piece, x: inset + indent, width: max(1, usable - indent)) }
            if content.rail != nil { rail = NSRect(x: inset + SlackSidebar.threadIndent, y: top, width: 1, height: y - top) }
            first = false
        }
        gap()
        let summaryHeight: CGFloat = content.summary.isEmpty ? 0 : 28
        let replyWidth = content.workspaceFooter ? content.actions.first(where: { $0.identifier.hasPrefix("reply-") }).map { actionWidth($0, compact: false) + 12 } ?? 0 : 0
        let foldWidth = content.workspaceFooter ? content.actions.first(where: { $0.identifier.hasPrefix("fold-") }).map { actionWidth($0, compact: false) + 12 } ?? 0 : 0
        let summary = NSRect(x: inset + replyWidth, y: y + 4, width: max(0, usable - replyWidth - foldWidth), height: summaryHeight)
        y += summaryHeight
        let spacing: CGFloat = 14
        var full: CGFloat = CGFloat(max(0, content.actions.count - 1)) * spacing
        for action in content.actions { full += actionWidth(action, compact: false) }
        if let deleting = content.deleting { full += ceil(Self.width(deleting, font: footFont)) + 22 }
        let compact = full > usable - 6
        let foot = NSRect(x: inset, y: y, width: usable - 6, height: 16)
        y = foot.maxY
        return Layout(content: content, width: width, height: ceil(y + inset), placed: placed, rail: rail, foot: foot, summary: summary, compact: compact, anchors: anchors)
    }

    // MARK: Views

    final class Text: NSTextView {
        var clicked: (() -> Void)?
        var openLink: ((URL) -> Void)?
        fileprivate var linkOpened = false
        private var pendingClick: DispatchWorkItem?
        func cancelPendingClick() { pendingClick?.cancel(); pendingClick = nil }
        // The panel is often behind another app; the first click acts, as it does on the SwiftUI card.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        /// Quote bars and code boxes of a laid-out Slack post go behind its words.
        override func drawBackground(in rect: NSRect) { super.drawBackground(in: rect); SlackLayout.draw(in: self) }
        override func mouseDown(with event: NSEvent) {
            cancelPendingClick()
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            var link: URL?
            if let storage = textStorage, index < storage.length,
               let value = storage.attribute(.link, at: index, effectiveRange: nil) {
                link = value as? URL ?? (value as? String).flatMap(URL.init(string:))
            }
            linkOpened = false
            super.mouseDown(with: event)
            guard selectedRange().length == 0, event.clickCount == 1 else { return }
            // A click on a link opens it once and nothing else; a plain click (one that leaves no selection,
            // even if it cleared one) is a click on the card's words.
            if let link { if !linkOpened { linkOpened = true; openLink?(link) } }
            else {
                // Opening a folded thread changes window geometry. Wait out a possible
                // double click so the second click still selects the word under the pointer.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor,
                          self.selectedRange().length == 0 else { return }
                    self.clicked?()
                }
                pendingClick = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        }
    }
    final class Button: NSButton {
        var invoke: (() -> Void)?
        private struct RasterKey: Hashable {
            var symbol: String, color: String, appearance: String
            var scale: CGFloat, point: CGFloat, weight: CGFloat
        }
        private static var rasters: [RasterKey: NSImage] = [:]
        var symbolName = ""
        var symbolColor = NSColor.labelColor
        var symbolPoint = ChatMetrics.auxiliaryFont
        var symbolWeight = NSFont.Weight.medium
        private func raster() -> NSImage? {
            let scale = window?.backingScaleFactor ?? 2
            let resolved = symbolColor.usingColorSpace(.sRGB) ?? symbolColor
            let key = RasterKey(symbol: symbolName, color: resolved.description,
                appearance: effectiveAppearance.name.rawValue, scale: scale, point: symbolPoint, weight: symbolWeight.rawValue)
            if let image = Self.rasters[key] { return image }
            guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolPoint, weight: symbolWeight)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [resolved.withAlphaComponent(1)]))) else { return nil }
            let size = symbol.size
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width*scale)), pixelsHigh: Int(ceil(size.height*scale)),
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            // The size goes on before the context is made: the context takes its scale from it, and
            // without it the symbol fills only a quarter of the bitmap and shows at half size.
            bitmap.size = size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            symbol.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: resolved.alphaComponent)
            NSGraphicsContext.restoreGraphicsState()
            let result = NSImage(size: size); result.addRepresentation(bitmap)
            if Self.rasters.count > 128 { Self.rasters.removeAll(keepingCapacity: true) }
            Self.rasters[key] = result
            return result
        }
        init() {
            super.init(frame: .zero)
            target = self; action = #selector(pressed)
            isBordered = false; bezelStyle = .inline
            // Like the SwiftUI plain buttons they replace, these are not Tab stops; that also keeps a row
            // from rebuilding the window's key-view loop each time the table brings it on screen.
            refusesFirstResponder = true
            font = NativeThreadCard.footFont
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var allowsVibrancy: Bool { false }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            // Borderless NSButton applies an appearance-dependent title treatment. Draw
            // the plain SwiftUI-style label ourselves while retaining button semantics.
            let alpha: CGFloat = isEnabled ? 1 : 0.4
            let icon = symbolName.isEmpty ? nil : raster()
            if let image = icon {
                // Whole device pixels, as SwiftUI places symbols; a half-pixel origin blurs the thin strokes.
                let scale = window?.backingScaleFactor ?? 2
                let top = ((bounds.height-image.size.height)/2*scale).rounded()/scale
                let left = attributedTitle.length == 0 ? ((bounds.width-image.size.width)/2*scale).rounded()/scale : 0
                image.draw(in:NSRect(x:left,y:top,width:image.size.width,height:image.size.height),from:.zero,operation:.sourceOver,fraction:alpha,respectFlipped:true,hints:nil)
            }
            let size = attributedTitle.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)
            attributedTitle.draw(at:NSPoint(x:icon.map { $0.size.width + 8 } ?? 0,y:(bounds.height-size.height)/2))
            NSGraphicsContext.restoreGraphicsState()
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        @objc private func pressed() { invoke?() }
    }
    final class Host: NSHostingView<AnyView> {
        var sizeChanged: (() -> Void)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize(); sizeChanged?() }
    }
    /// The folded replies: who answered, how many, and two cards peeking out underneath like a pile.
    final class StackButton: NSControl {
        var faces: [(String, ProfileAvatar)] = []
        var title = ""
        var quiet = NSColor.secondaryLabelColor
        var toggle: (() -> Void)?
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { toggle?() }
        override func draw(_ dirtyRect: NSRect) {
            let card = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 9)
            func fill(_ rect: NSRect, _ alpha: CGFloat) { NSColor.labelColor.withAlphaComponent(alpha).setFill(); NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill() }
            fill(card.insetBy(dx: 12, dy: 0).offsetBy(dx: 0, dy: 8), 0.05)
            fill(card.insetBy(dx: 6, dy: 0).offsetBy(dx: 0, dy: 4), 0.08)
            fill(card, 0.13)
            NSColor.labelColor.withAlphaComponent(0.08).setStroke()
            let outline = NSBezierPath(roundedRect: card.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12); outline.lineWidth = 1; outline.stroke()
            var x: CGFloat = faces.isEmpty ? 12 : 8
            for (index, face) in faces.enumerated() {
                let rect = NSRect(x: x + CGFloat(index) * 11, y: (card.height - 16) / 2, width: 16, height: 16)
                face.1.draw(in: rect, name: face.0, clipPath: ChatView.face(16).path(in: rect).cgPath)
            }
            if !faces.isEmpty { x += 16 + CGFloat(faces.count - 1) * 11 + 7 }
            let font = NativeThreadCard.stackFont
            let size = (title as NSString).size(withAttributes: [.font: font])
            (title as NSString).draw(at: NSPoint(x: x, y: (card.height - size.height) / 2), withAttributes: [.font: font, .foregroundColor: NSColor.labelColor])
            x += ceil(size.width) + 7
            if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold).applying(.init(paletteColors: [quiet]))) {
                chevron.draw(in: NSRect(x: x, y: (card.height - chevron.size.height) / 2, width: chevron.size.width, height: chevron.size.height),
                             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    private var texts: [Text] = []
    private var hosts: [String: Host] = [:]
    private var stacks: [StackButton] = []
    private var buttons: [Button] = []
    private let bell = Button()
    private(set) var value: Layout?
    var hostedSizeChanged: (() -> Void)?
    /// Lets scrolling and checks find a message's words and the card itself, as the SwiftUI probes did.
    var register: ((String, NSView) -> Void)?
    var diagnosticButtonFrames: [String: CGRect] {
        guard let value else { return [:] }
        return Dictionary(zip(value.content.actions, buttons).map { ($0.0.identifier, $0.1.frame) }, uniquingKeysWith: { first, _ in first })
    }
    /// The words of the first post, for checks that drive selection and copying.
    var firstText: NSTextView? { texts.first { !$0.isHidden } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        bell.symbolPoint = 12; bell.symbolWeight = .semibold
        addSubview(area); addSubview(bell)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func textView(_ index: Int) -> Text {
        while texts.count <= index {
            // TextKit 1: a short message's first layout costs far less than TextKit 2's viewport machinery.
            let text = Text(usingTextLayoutManager: false)
            text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
            text.textContainerInset = .zero; text.textContainer?.lineFragmentPadding = 0
            text.isHorizontallyResizable = false; text.isVerticallyResizable = false
            text.delegate = self
            text.linkTextAttributes = [.cursor: NSCursor.pointingHand]
            texts.append(text); addSubview(text)
        }
        return texts[index]
    }
    private var textLinks: [ObjectIdentifier: (URL) -> Void] = [:]

    func configure(_ layout: Layout) {
        guard value?.identity != layout.identity else { return }
        let sameThread = value?.content.id == layout.content.id
        value = layout
        let c = layout.content
        var textIndex = 0, stackIndex = 0
        var usedHosts = Set<String>()
        textLinks.removeAll(keepingCapacity: true)
        func setText(_ string: NSAttributedString, link: @escaping (URL) -> Void) {
            let view = textView(textIndex); textIndex += 1
            view.isHidden = false
            let selection = view.selectedRange()
            if !view.attributedString().isEqual(to: string) { view.textStorage?.setAttributedString(string) }
            if sameThread, NSMaxRange(selection) <= string.length { view.setSelectedRange(selection) }
            else { view.setSelectedRange(NSRange(location: 0, length: 0)) }
            view.cancelPendingClick()
            view.clicked = c.textClick
            view.openLink = link
            textLinks[ObjectIdentifier(view)] = link
        }
        for item in layout.placed {
            switch item.piece {
            case .post(let post):
                setText(post.text, link: post.openLink)
                register?("message:" + post.id, texts[textIndex - 1])
                for mark in post.marks { setText(mark.text, link: post.openLink) }
            case .note(let mark, _):
                setText(mark.text, link: { _ in })
            case .stack(let faces, let title, let toggle, let identifier):
                while stacks.count <= stackIndex { let stack = StackButton(); stacks.append(stack); addSubview(stack) }
                let stack = stacks[stackIndex]; stackIndex += 1
                stack.isHidden = false; stack.faces = faces; stack.title = title; stack.toggle = toggle; stack.quiet = c.quiet
                stack.setAccessibilityRole(.button); stack.setAccessibilityLabel(title + " 펼치기"); stack.setAccessibilityIdentifier(identifier)
                stack.needsDisplay = true
            case .hosted(let id, let view):
                usedHosts.insert(id)
                let host = hosts[id] ?? {
                    let host = Host(rootView: AnyView(EmptyView()))
                    host.sizeChanged = { [weak self] in self?.hostedSizeChanged?() }
                    hosts[id] = host; addSubview(host); return host
                }()
                // Hosted pieces sit at the leading edge, as they do in the SwiftUI card's VStack.
                host.rootView = AnyView(view().frame(maxWidth: .infinity, alignment: .topLeading))
                host.isHidden = false
                register?(id, host)
            case .owner: break
            }
        }
        for index in textIndex..<texts.count { texts[index].isHidden = true }
        register?(c.id, area)
        for index in stackIndex..<stacks.count { stacks[index].isHidden = true }
        for (id, host) in hosts where !usedHosts.contains(id) { host.removeFromSuperview(); hosts[id] = nil }
        while buttons.count < c.actions.count { let button = Button(); buttons.append(button); addSubview(button) }
        for (index, button) in buttons.enumerated() {
            guard index < c.actions.count else { button.isHidden = true; continue }
            let action = c.actions[index]
            button.isHidden = false; button.isEnabled = action.enabled
            button.title = !layout.compact || action.alwaysLabel ? action.title : ""
            button.symbolName = action.symbol; button.symbolColor = action.color
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [.font: Self.footFont, .foregroundColor: action.color])
            button.invoke = action.invoke
            button.setAccessibilityLabel(action.label); button.setAccessibilityIdentifier(action.identifier)
            button.needsDisplay = true
        }
        bell.isHidden = c.bell == nil
        if let unread = c.bell {
            bell.symbolName = unread ? "bell.fill" : "bell"
            bell.symbolColor = unread ? NSColor(srgbRed: 0.98, green: 0.78, blue: 0.18, alpha: 1) : c.quiet.withAlphaComponent(c.quiet.alphaComponent * 0.6)
            bell.attributedTitle = NSAttributedString(string: "")
            bell.invoke = c.onBell
            bell.toolTip = unread ? "읽음으로 표시" : "읽지 않음으로 되돌리기"
            bell.setAccessibilityLabel(unread ? "읽지 않은 알림, 눌러서 읽음으로 표시" : "읽은 알림, 눌러서 되돌리기")
            bell.setAccessibilityIdentifier("bell-" + c.id)
            bell.needsDisplay = true
        }
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        guard let value else { return }
        let dx = ChatMetrics.horizontalInset
        var textIndex = 0, stackIndex = 0
        func put(_ view: NSView, _ frame: NSRect) { let moved = frame.offsetBy(dx: dx, dy: 0); if view.frame != moved { view.frame = moved } }
        func putText(_ frame: NSRect) {
            let view = texts[textIndex]; textIndex += 1
            put(view, frame)
            // A repeated scroll layout must not invalidate unchanged TextKit lines.
            let size = NSSize(width: frame.width, height: .greatestFiniteMagnitude)
            if view.textContainer?.containerSize != size { view.textContainer?.containerSize = size }
        }
        for item in value.placed {
            switch item.piece {
            case .post(let post):
                putText(item.text)
                for frame in item.marks { putText(NSRect(x: frame.minX + 10, y: frame.minY, width: frame.width - 10, height: frame.height)) }
                _ = post
            case .note: putText(item.text)
            case .stack: put(stacks[stackIndex], NSRect(x: item.frame.minX, y: item.frame.minY, width: item.frame.width, height: item.frame.height + 9)); stackIndex += 1
            case .hosted(let id, _): if let host = hosts[id] { put(host, item.frame) }
            case .owner: break
            }
        }
        let spacing: CGFloat = value.compact ? 12 : 14
        let c = value.content
        let footerIndices = c.actions.indices.filter { !c.workspaceFooter || (!c.actions[$0].identifier.hasPrefix("reply-") && !c.actions[$0].identifier.hasPrefix("fold-")) }
        let widths = footerIndices.map { Self.actionWidth(c.actions[$0], compact: value.compact) }
        let deleting = c.deleting.map { ceil(Self.width($0, font: Self.footFont)) + 22 + spacing } ?? 0
        var x = value.foot.maxX - widths.reduce(0, +) - CGFloat(max(0, widths.count - 1)) * spacing - deleting
        for (offset, index) in footerIndices.enumerated() {
            let height = max(14, Self.symbolSize(c.actions[index].symbol).height)
            put(buttons[index], NSRect(x: x, y: value.foot.midY - height / 2, width: widths[offset], height: height))
            x += widths[offset] + spacing
        }
        if c.workspaceFooter {
            for index in c.actions.indices {
                let action = c.actions[index]
                let width = Self.actionWidth(action, compact: false)
                if action.identifier.hasPrefix("reply-") {
                    put(buttons[index], NSRect(x: c.style.inset, y: value.summary.minY, width: width, height: 20))
                } else if action.identifier.hasPrefix("fold-") {
                    put(buttons[index], NSRect(x: value.width - c.style.inset - width, y: value.summary.minY, width: width, height: 20))
                }
            }
        }
        if !bell.isHidden { put(bell, NSRect(x: value.width - 26, y: 0, width: 26, height: 26)) }
        put(area, NSRect(x: 0, y: 0, width: value.width, height: value.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let value else { return }
        let c = value.content, dx = ChatMetrics.horizontalInset
        let card = NSRect(x: dx, y: 0, width: value.width, height: value.height)
        let path = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        if let background = c.style.background { background.setFill(); path.fill() }
        else if c.style.fill > 0 { NSColor.labelColor.withAlphaComponent(c.style.fill).setFill(); path.fill() }
        if let status = c.style.status {
            status.setFill()
            NSBezierPath(roundedRect: NSRect(x: dx + 5, y: 12, width: ThreadAppearance.statusWidth,
                                            height: max(0, value.height - 24)), xRadius: 2, yRadius: 2).fill()
        }
        if let stroke = c.style.stroke {
            stroke.setStroke()
            let outline = NSBezierPath(roundedRect: card.insetBy(dx: c.style.lineWidth / 2, dy: c.style.lineWidth / 2), xRadius: 16, yRadius: 16)
            outline.lineWidth = c.style.lineWidth; outline.stroke()
        }
        if let rail = value.rail, let color = c.rail {
            color.setFill(); NSBezierPath(roundedRect: rail.offsetBy(dx: dx, dy: 0), xRadius: 1, yRadius: 1).fill()
        }
        func label(_ string: String, frame: NSRect, font: NSFont, color: NSColor, right: Bool = false) {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = right ? .right : .left
            (string as NSString).draw(in: frame.offsetBy(dx: dx, dy: 0), withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        }
        var badgeRight = value.width - c.style.inset
        func badge(_ title: String, color: NSColor) {
            let w = min(value.width - 2 * c.style.inset, Self.width(title, font: Self.footFont) + 22)
            let rect = NSRect(x: badgeRight - w, y: 12, width: w, height: 24)
            color.withAlphaComponent(0.12).setFill()
            let pill = NSBezierPath(roundedRect: rect.offsetBy(dx: dx, dy: 0), xRadius: 12, yRadius: 12)
            pill.fill(); color.withAlphaComponent(0.65).setStroke(); pill.lineWidth = 0.7; pill.stroke()
            label(title, frame: rect.insetBy(dx: 11, dy: 5), font: Self.footFont, color: color)
            badgeRight -= w + 8
        }
        if c.replyTarget { badge("답글 작성 중", color: .systemBlue) }
        if !c.statusTitle.isEmpty { badge(c.statusTitle, color: c.style.status ?? c.quiet) }
        if !c.summary.isEmpty {
            c.quiet.withAlphaComponent(0.14).setFill()
            NSRect(x: dx + c.style.inset, y: value.summary.minY - 4, width: value.width - 2 * c.style.inset, height: 0.5).fill()
            let detail = c.summary.components(separatedBy: " · ").dropFirst().filter { $0 != "답글 작성 중" }.joined(separator: " · ")
            if value.summary.width > Self.width(detail, font: Self.footFont) {
                label(detail, frame: value.summary, font: Self.footFont, color: c.quiet)
            }
        }
        let nameFont = NSFont.systemFont(ofSize: ChatMetrics.nameFont, weight: .bold)
        for item in value.placed {
            switch item.piece {
            case .owner(let name, let avatar):
                let title = "처리: " + name
                let width = Self.width(title, font: Self.noteFont)
                let face = NSRect(x: dx + item.frame.maxX - 4 - width - 18, y: item.frame.minY, width: 14, height: 14)
                avatar.draw(in: face, name: name, clipPath: ChatView.face(14).path(in: face).cgPath)
                label(title, frame: NSRect(x: item.frame.minX, y: item.frame.minY, width: item.frame.width - 4, height: 14), font: Self.noteFont, color: c.quiet, right: true)
            case .post(let post):
                if post.flash {
                    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
                    NSBezierPath(roundedRect: item.frame.offsetBy(dx: dx, dy: 0), xRadius: 8, yRadius: 8).fill()
                }
                if post.mine {
                    NSColor.systemBlue.withAlphaComponent(post.pending ? 0.6 : 1).setFill()
                    NSBezierPath(roundedRect: item.aside.offsetBy(dx: dx, dy: 0), xRadius: 16, yRadius: 16).fill()
                    if post.interrupted { label("답이 중단됐어요", frame: item.fold, font: .systemFont(ofSize: ChatMetrics.auxiliaryFont), color: c.quiet, right: true) }
                    label(post.time, frame: item.time, font: .systemFont(ofSize: ChatMetrics.auxiliaryFont), color: c.quiet, right: true)
                } else {
                    if !item.bubble.isEmpty {
                        (c.style.replyBackground ?? NSColor.labelColor.withAlphaComponent(0.07)).setFill()
                        NSBezierPath(roundedRect: item.bubble.offsetBy(dx: dx, dy: 0), xRadius: 12, yRadius: 12).fill()
                    }
                    let face = item.aside.offsetBy(dx: dx, dy: 0)
                    post.avatar.draw(in: face, name: post.speaker, clipPath: ChatView.face(face.width).path(in: face).cgPath)
                    label(post.speaker, frame: item.time, font: nameFont, color: post.nameColor)
                    let nameWidth = Self.width(post.speaker, font: nameFont)
                    // The time sits on the name's baseline, as SwiftUI's .firstTextBaseline places it.
                    let timeFont = NSFont.systemFont(ofSize: 10)
                    let timeTop = item.time.minY + nameFont.ascender - timeFont.ascender
                    label(post.time, frame: NSRect(x: item.time.minX + nameWidth + 6, y: timeTop, width: max(1, item.time.width - nameWidth - 6), height: 14), font: timeFont, color: c.quiet)
                    for (index, frame) in item.marks.enumerated() where index < post.marks.count {
                        post.marks[index].color.setFill()
                        NSBezierPath(roundedRect: NSRect(x: dx + frame.minX, y: frame.minY, width: 3, height: frame.height), xRadius: 1.5, yRadius: 1.5).fill()
                    }
                    if let title = post.foldTitle {
                        label(title, frame: item.fold, font: .systemFont(ofSize: ChatMetrics.auxiliaryFont), color: post.nameColor)
                    }
                }
            case .note(let mark, _):
                mark.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: dx + item.frame.minX, y: item.frame.minY, width: 3, height: item.frame.height), xRadius: 1.5, yRadius: 1.5).fill()
            case .stack, .hosted: break
            }
        }
        if let deleting = c.deleting {
            let width = ceil(Self.width(deleting, font: Self.footFont))
            let x = value.foot.maxX - width
            label(deleting, frame: NSRect(x: x, y: value.foot.minY, width: width + 2, height: 16), font: Self.footFont, color: .systemRed)
            if let trash = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: ChatMetrics.auxiliaryFont, weight: .medium).applying(.init(paletteColors: [.systemRed]))) {
                trash.draw(in: NSRect(x: dx + x - trash.size.width - 8, y: value.foot.midY - trash.size.height / 2, width: trash.size.width, height: trash.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The card's own outline, for checks and scrolling that need the card rather than the row.
    final class Area: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    private let area = Area()
    override func mouseDown(with event: NSEvent) {
        guard let value else { return }
        let point = convert(event.locationInWindow, from: nil).applying(.init(translationX: -ChatMetrics.horizontalInset, y: 0))
        // The "더 보기"/"접기" words under a long post are drawn, not views.
        for item in value.placed {
            if case .post(let post) = item.piece, post.foldTitle != nil, item.fold.insetBy(dx: -2, dy: -2).contains(point) { post.fold(); return }
        }
        value.content.clickCard()
    }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        if let text = textView as? Text {
            guard !text.linkOpened else { return true }
            text.linkOpened = true
        }
        textLinks[ObjectIdentifier(textView)]?(url); return true
    }
}
