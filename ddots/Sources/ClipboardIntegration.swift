import AppKit
import SwiftUI

extension AppDelegate {
    func prepareClipboard() {
        // Other smoke modes do not open the real clipboard or the production keychain.
        guard !isSmoke else { return }
        let parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(AppIdentity.supportFolder)
        do { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        catch { return }
        let library = ClipboardLibrary(root: parent.appendingPathComponent("clipboard"),
                                       temporary: parent.appendingPathComponent("clipboard-temporary"),
                                       keychain: ClipboardKeychain(service: AppIdentity.bundleID + ".clipboard"))
        connectClipboard(library)
    }
    func connectClipboard(_ library: ClipboardLibrary) {
        clipboardHotKey?.disable()
        let hotKey = ClipboardHotKey(); clipboardHotKey = hotKey
        hotKey.activate = { [weak self] in
            guard let self else { return }
            self.pet.toggleClipboardFromShortcut()
        }
        clipboard = library
        updateClipboardMenu()
        pet.installClipboard(library)
        library.onChange = { [weak self, weak library] in
            guard let self, let library else { return }
            self.clipboardHotKey?.configure(enabled: library.settings.enabled && library.settings.hotKeyEnabled,
                code: library.settings.hotKeyCode, modifiers: library.settings.hotKeyModifiers)
            library.hotKeyError = self.clipboardHotKey?.registrationStatus != 0
            self.pet.clipboardAvailable = library.available
            self.updateClipboardGeometry()
            self.updateClipboardMenu()
            if !library.settings.enabled || !library.settings.copyNotifications || library.paused || library.permissionNeeded {
                self.pet.cancelClipboardCopyNotice()
            }
        }
        library.onCaptured = { [weak self, weak library] entry in
            guard let self, let library, library.settings.enabled, library.settings.copyNotifications else { return }
            self.pet.showClipboardCopyNotice(ClipboardCopyNotice.message(entry))
        }
        library.onResetSize = { [weak self] in self?.resetClipboardSize() }
        pet.onClipboardResize = { [weak self, weak library] size in
            guard let self, let library else { return }
            var screen = self.panel.screen?.visibleFrame.size ?? size
            screen.height -= PetLayout(scale: self.pet.petScale).spriteSize.height + 16
            let size = ClipboardDrawer.constrained(size, screen: screen)
            if !self.isSmoke { ClipboardDrawer.save(size) }
            self.clipboardPreferredSize = size; library.shelfWidth = size.width
            self.bubbleSize = size; self.constrainPosition()
        }
        pet.onResetClipboardSize = { [weak self] in self?.resetClipboardSize() }
        pet.onClipboardGeometry = { [weak self] in self?.updateClipboardGeometry() }
        pet.onClipboardPresentation = { [weak self, weak library] shown in
            guard let self, let library else { return }
            library.shelfPresentation(shown)
            self.updateClipboardGeometry()
        }
    }
    func updateClipboardGeometry() {
        let folded = PetLayout.bubbleSize(actionCount: bubbleActions.count)
        // While chat is open only prepare its eventual folded geometry. The chat placement
        // and transition own the live frame; a hidden clipboard row cannot supply their height.
        if chatExpanded { bubbleSize = folded; pet.foldedHeight = folded.height; return }
        var size = folded
        if fileDrop.visible { size = fileDrop.size }
        else if pet.clipboardPresented {
            var screen = panel.screen?.visibleFrame.size ?? clipboardPreferredSize
            screen.height -= PetLayout(scale: pet.petScale).spriteSize.height + 16
            size = ClipboardDrawer.constrained(clipboardPreferredSize, screen: screen)
            if let library = clipboard, library.settings.fitsContents {
                let columns = ClipboardDrawer.columns(width: size.width)
                let rows = max(1, Int(ceil(Double(library.visibleShelfCount) / Double(columns))))
                size.height = min(size.height, ClipboardDrawer.minimumSize.height + CGFloat(rows - 1) * 104)
            }
            pet.clipboardOpenHeight = size.height
            clipboard?.shelfWidth = size.width
            pet.clipboardOpacityPercent = clipboard?.opacityPercent ?? ClipboardDrawer.opacity()
        }
        else if pet.clipboardRowVisible { size.height += ClipboardDrawer.rowHeight }
        pet.foldedHeight = folded.height + (pet.clipboardRowVisible ? ClipboardDrawer.rowHeight : 0)
        guard size != bubbleSize else { return }
        if !pet.clipboardResizing { bubbleMotion.slideWidth(now: ProcessInfo.processInfo.systemUptime, duration: clipboard?.settings.fitsContents == true ? 0.2 : 0.25) }
        bubbleSize = size; constrainPosition()
    }
    func resetClipboardSize() {
        clipboardPreferredSize = ClipboardDrawer.defaultSize
        if !isSmoke { ClipboardDrawer.save(clipboardPreferredSize) }
        updateClipboardGeometry()
    }
    @objc func toggleClipboardPause() { clipboard?.paused.toggle() }
    func updateClipboardMenu() {
        for action in [#selector(toggleClipboardPause), #selector(clearClipboard)] {
            menu?.items.first { $0.action == action }?.isHidden = clipboard?.settings.enabled != true
        }
    }
    @objc func clearClipboard() {
        guard let clipboard else { return }
        clipboard.confirmClear()
    }
}
