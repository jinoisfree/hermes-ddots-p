import AppKit

/// Only the folded pet uses this destination; the expanded conversation keeps AttachmentDrop.
final class ClipboardDrop {
    let library: ClipboardLibrary
    init(library: ClipboardLibrary) { self.library = library }
    func accepts(_ board: NSPasteboard) -> Bool {
        library.ready && library.settings.enabled && !library.paused && board.availableType(from: ClipboardPasteboard.supported) != nil
    }
    @discardableResult func receive(_ board: NSPasteboard) -> Bool {
        guard accepts(board) else { return false }
        let types = Set(board.types ?? [])
        guard !types.contains(ClipboardPasteboard.transient), !types.contains(ClipboardPasteboard.generated), !types.contains(ClipboardPasteboard.legacyTransient) else { return false }
        let app = board.string(forType: ClipboardPasteboard.source) ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        guard !library.settings.excludedApps.contains(app), let input = ClipboardPasteboard.read(board, source: app, media: library.settings.media) else { return false }
        library.add(input)
        return true
    }
}
