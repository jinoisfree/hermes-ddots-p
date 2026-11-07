import AppKit

/// Retains the existing controls and actions while laying out each settings category independently.
private final class SettingsDocument: NSView {
    override var isFlipped: Bool { true }
    func resized(_ child: NSView, by delta: CGFloat) {
        for view in subviews where view !== child && view.frame.minY > child.frame.minY {
            view.frame.origin.y += delta
        }
        frame.size.height += delta
    }
}

enum SettingsPages {
    static func make(blocks: [[NSView]]) -> NSScrollView {
        let spacing: CGFloat = 22
        let heights = blocks.map { block in
            (block.map { $0.frame.maxY }.max() ?? 0) - (block.map { $0.frame.minY }.min() ?? 0)
        }
        let height = max(540, heights.reduce(0, +) + spacing * CGFloat(blocks.count + 1))
        let document = SettingsDocument(frame: NSRect(x: 0, y: 0, width: 580, height: height))
        var top = spacing
        for (block, blockHeight) in zip(blocks, heights) {
            let originalTop = block.map { $0.frame.maxY }.max() ?? 0
            for view in block {
                view.removeFromSuperview()
                view.frame.origin.x += 110
                view.frame.origin.y = top + originalTop - view.frame.maxY
                document.addSubview(view)
            }
            top += blockHeight + spacing
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 580))
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = document
        document.scroll(.zero)
        return scroll
    }
}

import SwiftUI

private struct PreviewTextFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue(), uniquingKeysWith: { _, new in new }) }
}

private struct AppearancePreview: View {
    let name: String
    let agent: CharacterPalette
    let mine: UserBubblePalette
    let size: CGFloat
    let opacity: Double
    let dark: Bool
    var measured: ([String: CGRect]) -> Void
    private var themeWindowBackground: NSColor {
        var color = NSColor.white
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        return color
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(String(name.prefix(1))).font(.system(size: 12, weight: .bold))
                    .frame(width: 26, height: 26).background(Color(nsColor: agent.name.nsColor).opacity(0.25)).cornerRadius(7)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name).font(.system(size: ChatMetrics.auxiliaryFont, weight: .semibold)).foregroundColor(Color(nsColor: agent.name.nsColor))
                    Text("오늘 나눌 이야기를 정리했어요. 함께 살펴볼까요?")
                        .font(.system(size: size)).foregroundColor(Color(nsColor: agent.foreground.nsColor))
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { proxy in Color.clear.preference(key: PreviewTextFrames.self, value: ["agent": proxy.frame(in: .named("appearancePreview"))]) })
                        .padding(10).background(Color(nsColor: agent.background.nsColor)).cornerRadius(14)
                }.frame(maxWidth: 330, alignment: .leading)
                Spacer(minLength: 0)
            }
            HStack { Spacer(); Text("좋아, 첫 번째 이야기부터 보여 줘")
                .font(.system(size: size)).foregroundColor(Color(nsColor: mine.foreground.nsColor))
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in Color.clear.preference(key: PreviewTextFrames.self, value: ["mine": proxy.frame(in: .named("appearancePreview"))]) })
                .padding(.horizontal, 12).padding(.vertical, 8).background(Color(nsColor: mine.background.nsColor)).cornerRadius(16) }
            Text("오후 3:12").font(.system(size: ChatMetrics.auxiliaryFont)).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(16).frame(width: 536).frame(minHeight: 184)
            .coordinateSpace(name: "appearancePreview")
            .onPreferenceChange(PreviewTextFrames.self, perform: measured)
            .background(
                (dark ? Color(white: 0.08) : Color(white: 0.93))
                    .opacity(BubbleOpacity.alpha(progress: 1, percent: opacity, reduceTransparency: false))
                    .background(Color(nsColor: themeWindowBackground)))
            .cornerRadius(10).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

private final class AppearanceSwatch: NSButton {
    var color: UserBubbleColor = .blue
    var darkColors = false
    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 4, dy: 4))
        color.resolved(dark: darkColors).nsColor.setFill(); circle.fill()
        if state == .on {
            NSColor.labelColor.setStroke()
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); ring.lineWidth = 2; ring.stroke()
        }
        if color == .blue {
            let text = "기본" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), withAttributes: attributes)
        }
    }
}

private final class AppearanceSection: NSView {
    var dividers = false
    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        NSColor(white: dark ? 0.165 : 0.94, alpha: 1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        if dividers {
            NSColor.labelColor.withAlphaComponent(0.12).setStroke()
            for y: CGFloat in [42, 84] { let line = NSBezierPath(); line.move(to: NSPoint(x: 0, y: y)); line.line(to: NSPoint(x: bounds.width, y: y)); line.lineWidth = 0.5; line.stroke() }
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// Keeps existing theme/opacity controls and their actions, grouping their shared preview above them.
final class ChatAppearanceControls: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); bounds.fill()
    }
    private let theme: NSSegmentedControl
    private let opacity: NSSlider
    private let name: String
    private let palette: (Bool) -> CharacterPalette
    private var preview: NSHostingView<AppearancePreview>!
    private(set) var previewTextFrames: [String: CGRect] = [:]
    var previewSize: CGSize { preview.bounds.size }
    let fontSlider = NSSlider(value: 2, minValue: 0, maxValue: 6, target: nil, action: nil)
    private let fontValue = NSTextField(labelWithString: "기본")
    private let colorValue = NSTextField(labelWithString: "기본")
    private var swatches: [AppearanceSwatch] = []
    init(theme: NSSegmentedControl, opacity: NSSlider, opacityValue: NSTextField, resetSize: NSButton,
         name: String, palette: @escaping (Bool) -> CharacterPalette, persist: Bool) {
        self.theme = theme; self.opacity = opacity; self.name = name; self.palette = palette
        super.init(frame: NSRect(x: -88, y: 0, width: 536, height: 580))
        if !persist {
            ChatAppearance.preferences = UserDefaults(suiteName: "ddots-appearance-preview-" + UUID().uuidString)!
            ChatAppearance.transient = true
        }
        func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, bold: Bool = false, size: CGFloat? = nil, secondary: Bool = false) {
            let view = NSTextField(labelWithString: text); view.font = .systemFont(ofSize: size ?? (bold ? 13 : 12), weight: bold ? .semibold : .regular)
            view.textColor = secondary ? .secondaryLabelColor : .labelColor
            view.frame = NSRect(x: x, y: y, width: width, height: 20); addSubview(view)
        }
        func card(_ rect: NSRect) {
            let box = AppearanceSection(frame: rect); box.dividers = rect.height == 126; addSubview(box)
        }
        label("대화창 모양", 0, 526, 300, bold: true)
        preview = NSHostingView(rootView: makePreview()); preview.frame = NSRect(x: 0, y: 328, width: 536, height: 184); addSubview(preview)
        label("미리보기", 240, 301, 100, size: 11, secondary: true)
        card(NSRect(x: 0, y: 166, width: 536, height: 126))
        label("테마", 14, 257, 180); theme.frame = NSRect(x: 310, y: 252, width: 212, height: 28); addSubview(theme)
        label("불투명도", 14, 215, 180); opacity.frame = NSRect(x: 254, y: 213, width: 210, height: 24); addSubview(opacity)
        opacityValue.frame = NSRect(x: 470, y: 215, width: 50, height: 20); opacityValue.alignment = .right; addSubview(opacityValue)
        label("글씨 크기", 14, 175, 160); label("가", 220, 175, 20); label("가", 448, 175, 20, size: 18)
        fontSlider.frame = NSRect(x: 244, y: 170, width: 194, height: 28); fontSlider.numberOfTickMarks = 7
        fontSlider.allowsTickMarkValuesOnly = true; fontSlider.isContinuous = true
        fontSlider.target = self; fontSlider.action = #selector(changeFont); fontSlider.setAccessibilityLabel("대화창 글씨 크기")
        addSubview(fontSlider); fontValue.frame = NSRect(x: 480, y: 175, width: 40, height: 20); fontValue.alignment = .right; addSubview(fontValue)
        card(NSRect(x: 0, y: 36, width: 536, height: 118))
        label("내 말풍선 색", 14, 126, 200); colorValue.frame = NSRect(x: 440, y: 126, width: 80, height: 20); colorValue.alignment = .right; addSubview(colorValue)
        for (index, color) in UserBubbleColor.allCases.enumerated() {
            let button = AppearanceSwatch(frame: NSRect(x: 10 + (index % 7) * 39, y: 83 - (index / 7) * 36, width: 34, height: 34))
            button.setButtonType(.toggle); button.color = color; button.title = ""; button.tag = index; button.target = self; button.action = #selector(changeColor(_:))
            button.setAccessibilityLabel(color.title); button.toolTip = color.title; addSubview(button); swatches.append(button)
        }
        // Add a dedicated explanatory row without squeezing the swatches or values.
        for view in subviews { view.frame.origin.y += 32 }
        if let colors = subviews.first(where: { $0 is AppearanceSection && $0.frame.minY == 68 }) {
            colors.frame.origin.y = 36; colors.frame.size.height = 150
        }
        label("글자가 잘 보이도록 글자색은 자동으로 정해져요. 에이전트 말풍선은 지금처럼 캐릭터 색을 따릅니다.", 14, 43, 510, size: 10, secondary: true)
        resetSize.frame = NSRect(x: 0, y: 0, width: 148, height: 28); addSubview(resetSize)
        let reset = NSButton(title: "기본값으로", target: self, action: #selector(resetAppearance)); reset.bezelStyle = .rounded
        reset.frame = NSRect(x: 156, y: 0, width: 100, height: 28); addSubview(reset)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private var previewDark: Bool {
        let selected = ChatTheme.allCases.indices.contains(theme.selectedSegment) ? ChatTheme.allCases[theme.selectedSegment] : .system
        return (selected.appearance ?? effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    private func makePreview() -> AppearancePreview {
        let dark = previewDark
        return AppearancePreview(name: name, agent: palette(dark), mine: UserBubblePalette(dark: dark), size: ChatMetrics.bodyFont, opacity: opacity.doubleValue, dark: dark, measured: { [weak self] in self?.previewTextFrames = $0 })
    }
    func refresh() {
        fontSlider.integerValue = ChatAppearance.fontSizes.firstIndex(of: ChatMetrics.bodyFont) ?? 2
        fontValue.stringValue = ChatMetrics.bodyFont == 14 ? "기본" : "\(Int(ChatMetrics.bodyFont))pt"
        fontSlider.setAccessibilityValueDescription("\(Int(ChatMetrics.bodyFont))pt")
        colorValue.stringValue = ChatAppearance.color().title
        for button in swatches { button.darkColors = previewDark; button.state = button.color == ChatAppearance.color() ? .on : .off; button.needsDisplay = true }
        preview?.rootView = makePreview()
        if let preview {
            let height = ceil(preview.fittingSize.height)
            let delta = height - preview.frame.height
            if delta != 0 {
                let oldTop = preview.frame.maxY
                preview.frame.size.height = height
                for view in subviews where view !== preview && view.frame.minY >= oldTop { view.frame.origin.y += delta }
                frame.size.height += delta
                (superview as? SettingsDocument)?.resized(self, by: delta)
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    @objc private func changeFont() { ChatAppearance.setFontSize(ChatAppearance.fontSizes[min(6, max(0, fontSlider.integerValue))]); refresh() }
    @objc private func changeColor(_ sender: NSButton) { ChatAppearance.setColor(UserBubbleColor.allCases[sender.tag]); refresh() }
    @objc func resetAppearance() {
        theme.selectedSegment = 0; theme.sendAction(theme.action, to: theme.target)
        opacity.doubleValue = BubbleOpacity.defaultPercent; opacity.sendAction(opacity.action, to: opacity.target)
        ChatAppearance.setFontSize(14); ChatAppearance.setColor(.blue); refresh()
    }
}
