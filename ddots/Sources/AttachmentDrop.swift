import AppKit
import SwiftUI

struct AttachmentDrop: NSViewRepresentable {
    let model: SlackModel
    @Binding var targeted: Bool
    func makeNSView(context: Context) -> AttachmentDropView { AttachmentDropView() }
    func updateNSView(_ view: AttachmentDropView, context: Context) {
        view.model = model
        view.onTarget = { value in DispatchQueue.main.async { targeted = value } }
        if !model.canAttach { view.setTargeted(false) }
    }
    static func dismantleNSView(_ view: AttachmentDropView, coordinator: ()) { view.setTargeted(false) }
}

/// AppKit supplies the original pasteboard, including Finder file URLs and screenshot image data.
final class AttachmentDropView: NSView {
    weak var model: SlackModel?
    var onTarget: ((Bool) -> Void)?
    private(set) var targeted = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }
    func setTargeted(_ value: Bool) {
        guard targeted != value else { return }
        targeted = value; onTarget?(value)
    }
    func updateDrag(from board: NSPasteboard, at point: NSPoint, operation: NSDragOperation = .copy) -> NSDragOperation {
        let accepts = model?.canAttach == true && window != nil && !isHiddenOrHasHiddenAncestor && bounds.contains(convert(point, from: nil))
            && operation.contains(.copy) && ClipboardAttachments.containsAttachments(board)
        setTargeted(accepts)
        return accepts ? .copy : []
    }
    func drop(from board: NSPasteboard, at point: NSPoint, operation: NSDragOperation = .copy) -> Bool {
        let accepts = updateDrag(from: board, at: point, operation: operation) == .copy
        setTargeted(false)
        guard accepts, let model, model.pasteAttachments(from: board) else { return false }
        if !model.attachments.isEmpty { window?.makeKeyAndOrderFront(nil) }
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateDrag(from: sender.draggingPasteboard, at: sender.draggingLocation, operation: sender.draggingSourceOperationMask)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingEntered(sender) == .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        drop(from: sender.draggingPasteboard, at: sender.draggingLocation, operation: sender.draggingSourceOperationMask)
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { setTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setTargeted(false) }
}

private typealias DropTargetState = SwiftUI.State<Bool>

private struct AttachmentDropModifier: ViewModifier {
    @ObservedObject var model: SlackModel
    @DropTargetState private var targeted = false
    func body(content: Content) -> some View {
        content.overlay {
            AttachmentDrop(model: model, targeted: $targeted).accessibilityHidden(true)
        }.overlay {
            if targeted && model.canAttach {
                RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor, lineWidth: 2).padding(5)
                    .overlay(alignment: .top) {
                        Label("여기에 놓아 첨부", systemImage: "paperclip")
                            .font(.system(size: ChatMetrics.auxiliaryFont, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule()).padding(.top, 14)
                    }.allowsHitTesting(false)
            }
        }
    }
}

extension View {
    func attachmentDrop(_ model: SlackModel) -> some View { modifier(AttachmentDropModifier(model: model)) }
}
