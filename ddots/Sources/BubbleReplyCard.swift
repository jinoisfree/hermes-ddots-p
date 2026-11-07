import AppKit
import SwiftUI

/// The input under a pet bubble. It owns the typed words and when the input is out; the thread it speaks to is
/// told by the app, and the words go out through the conversation's own send path.
final class BubbleReplyCard: ObservableObject {
    @Published var open = false
    @Published var text = "" { didSet { if oldValue != text { draft.text = text } } }
    @Published var focused = false
    @Published var problem = "" { didSet { if (oldValue.isEmpty) != (problem.isEmpty) { onGeometry?() } } }
    @Published private(set) var placeholder = ""
    private(set) var target: BubbleReplyTarget?
    private(set) var fieldHeight = BubbleReplyCard.lineHeight
    var hover = BubbleReplyHover()
    private var draft = BubbleReplyDraft()
    /// Words sent and not yet known to have arrived, by thread.
    private var lastSent: (thread: String, text: String)?
    var onGeometry: (() -> Void)?
    /// Hands the words to the conversation's send. Returns false when the thread is gone.
    var onSend: ((BubbleReplyTarget, String) -> Bool)?
    var onFolded: (() -> Void)?

    static let lineHeight: CGFloat = ceil(NSFont.systemFont(ofSize: ChatMetrics.bodyFont).boundingRectForFont.height)
    static let chrome: CGFloat = 14 + 14      // capsule padding + outer padding
    static let problemLine: CGFloat = 18
    /// The row under the bubble: one line of input, up to three, and the reason a send failed when there is one.
    var height: CGFloat { Self.chrome + fieldHeight + (problem.isEmpty ? 0 : Self.problemLine) }
    var visible: Bool { open && target != nil }

    func setHeight(_ value: CGFloat) {
        let clamped = min(max(value, Self.lineHeight), Self.lineHeight * CGFloat(BubbleReply.maximumLines))
        guard abs(clamped - fieldHeight) > 0.5 else { return }
        fieldHeight = clamped; onGeometry?()
    }
    /// A bubble that speaks to no thread folds the input but keeps the words; speaking to another thread drops them.
    func aim(_ next: BubbleReplyTarget?) {
        target = next
        placeholder = next.map(BubbleReply.placeholder) ?? ""
        guard let next else { return }
        if next.thread != draft.thread {
            draft.retarget(next.thread)
            if text != draft.text { text = draft.text }
            problem = ""
        }
    }
    /// Words and focus keep the input out; the pointer alone does not.
    var holds: Bool { !text.isEmpty || focused }

    func submit() {
        guard let target, let words = BubbleReply.outgoing(text) else { return }
        problem = ""
        lastSent = (target.thread, text)
        text = ""
        // A sent line ends the typing: the field lets go of the keyboard so the input can fold.
        focused = false
        hover.foldSoon(now: ProcessInfo.processInfo.systemUptime)
        if onSend?(target, words) != true { restore("스레드를 찾지 못했어요", thread: target.thread) }
    }
    /// A send failed: the words come back into the field with the reason, and the input stays out.
    func restore(_ reason: String, thread: String) {
        guard let sent = lastSent, sent.thread == thread, target?.thread == thread else { return }
        lastSent = nil
        if text.isEmpty { text = sent.text } else { text = sent.text + "\n" + text }
        problem = reason
        hover.forceOpen(); open = true
        onGeometry?()
    }
    func escape() {
        hover.fold(); open = false; focused = false
        onFolded?(); onGeometry?()
    }
    /// VoiceOver and a click on the bubble's own hint.
    func openNow() {
        guard target != nil else { return }
        hover.forceOpen(); open = true; onGeometry?()
    }
}

struct BubbleReplyView: View {
    @ObservedObject var card: BubbleReplyCard
    @Environment(\.colorScheme) private var scheme
    private var sendable: Bool { BubbleReply.outgoing(card.text) != nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !card.problem.isEmpty {
                Text(card.problem).font(.system(size: 11)).foregroundColor(.red).lineLimit(1).padding(.horizontal, 14)
                    .frame(height: BubbleReplyCard.problemLine, alignment: .leading).accessibilityIdentifier("bubble-reply-problem")
            }
            HStack(alignment: .bottom, spacing: 6) {
                DraftEditor(prompt: card.placeholder, text: $card.text, focus: $card.focused, onSubmit: { card.submit() },
                            maxLines: BubbleReply.maximumLines, onHeight: { card.setHeight($0) })
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.primary.opacity(scheme == .dark ? 0.1 : 0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.18)))
                    .accessibilityLabel(BubbleReply.accessibilityName).accessibilityIdentifier("bubble-reply-field")
                Button { card.submit() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                        .frame(width: 28, height: 28).background(Circle().fill(sendable ? Color.blue : Color.blue.opacity(0.4)))
                }.buttonStyle(.plain).disabled(!sendable).accessibilityLabel(BubbleReply.sendName).accessibilityIdentifier("bubble-reply-send")
            }.padding(.horizontal, 10)
        }.padding(.top, 7).padding(.bottom, 7).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
