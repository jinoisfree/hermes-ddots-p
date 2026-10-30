import AppKit
import Sparkle

extension AppDelegate {
    /// Isolated preferences and the real idle cancellation path; no updater session or relay command is started.
    @MainActor func verifyUpdateNotices(destination: URL) {
        let suite = "ddots-update-notices-smoke-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let originalSettings = updateNoticeSettings
        var restorations = 0
        let updates = AppUpdate(defaults: defaults, relayRestoration: { restorations += 1 })
        updateNoticeSettings = UpdateNoticeSettings(defaults: defaults)
        appUpdate = updates
        showOptions()
        guard let checkbox = updateNoticeCheckbox else { smokeFailed("Update notices checkbox exists") }
        guard let window = optionsWindow, let scroll = settingsScroll,
              let document = scroll.documentView else { smokeFailed("Options have a scrollable document") }
        window.setContentSize(NSSize(width: 620, height: 650))
        scrollOptionsToTop()
        smokeCheck(scroll.documentVisibleRect.contains(checkbox.frame), "Update checkbox fits in initial 650pt viewport")
        smokeCheck(abs(scroll.documentVisibleRect.minY) < 1, "Options initially show document top")
        if let bitmap = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
            scroll.cacheDisplay(in: scroll.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("options-650.png"))
        }
        let matches = scroll.documentView?.subviews.compactMap { $0 as? NSButton }.filter { $0.title == "업데이트 알림 받기" } ?? []
        smokeCheck(matches.count == 1 && checkbox.state == .on, "Exactly one update checkbox, enabled by default in either channel")
        defaults.set(2, forKey: "silentUpdateFailures")
        let silent = SilentUpdateSettings(defaults: defaults)
        silent.preparing(version: "9.9.9", build: "999")
        updates.activity = { .init(idleSeconds: 0, hasDrafts: true, transferring: false) }
        var replies: [SPUUserUpdateChoice] = []
        updates.waitUntilIdle { replies.append($0) }
        smokeCheck(replies.isEmpty, "Silent installation is waiting for idle")
        checkbox.performClick(nil)
        smokeCheck(!updateNoticeSettings.enabled && UserDefaults(suiteName: suite)?.bool(forKey: UpdateNoticeSettings.key) == false,
                   "Turning notices off persists immediately")
        smokeCheck(replies == [.skip] && restorations == 1, "Turning notices off cancels waiting installation and restores relay once")
        smokeCheck(silent.failures == 2 && defaults.object(forKey: "silentUpdatePendingVersion") == nil,
                   "Cancellation clears pending installation without recording a failure")
        updates.noticesChanged()
        smokeCheck(replies == [.skip] && restorations == 1, "Repeated notification cannot reply to a cancelled installer twice")
        document.scroll(NSPoint(x: 0, y: document.bounds.height))
        showOptions()
        smokeCheck(abs(scroll.documentVisibleRect.minY) < 1, "Reopening options returns to document top")
        smokeCheck(checkbox.state == .off, "Reopening options reads the saved preference")
        checkbox.performClick(nil)
        smokeCheck(updateNoticeSettings.enabled && replies == [.skip], "Turning notices on preserves the cancelled installer")
        updates.stop(); appUpdate = nil
        updateNoticeSettings = originalSettings
        showOptions()
        capture(destination: destination)
        try? "PASS: checkbox visible in initial 650pt viewport, one checkbox, default on, persisted off/on, actual pending idle installer cancelled once, failure count unchanged; no network or real relay\n".write(to: destination.appendingPathComponent("update-notices.txt"), atomically: true, encoding: .utf8)
        if CommandLine.arguments.contains("--ui-smoke-update-reminder") { verifyUpdateReminder(destination: destination) }
        else { NSApp.terminate(nil) }
    }

    @MainActor func verifyUpdateReminder(destination: URL) {
        let alert = AppUpdate.automaticAlert(version: "9.9.9")
        smokeCheck(alert.buttons.map(\.title) == ["업데이트", "오늘 다시 보지 않음", "나중에"], "Update reminder offers updating, today suppression and later")
        let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
            if let view = alert.window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("update-reminder.png"))
            }
            alert.buttons[1].performClick(nil)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        smokeCheck(response == .alertSecondButtonReturn, "Today suppression button returns the expected action without starting installation")
        try? "PASS: synthetic update popup and today button; no network or installer\n".write(to: destination.appendingPathComponent("update-reminder.txt"), atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}

/// Keeps the live check alive for the whole run.
private var liveUpdateCheck: AppUpdate?

extension AppDelegate {
    /// Against the real private releases: token from DDOTS_UPDATE_TOKEN, a manual check, and Sparkle's verdict on the
    /// feed and its signature. The found-update window is left unanswered, so nothing is downloaded or installed.
    @MainActor func verifyLiveUpdateCheck(destination: URL) {
        guard let token = ProcessInfo.processInfo.environment["DDOTS_UPDATE_TOKEN"], !token.isEmpty else { smokeFailed("DDOTS_UPDATE_TOKEN is needed") }
        AppUpdate.liveCheckToken = token
        AppUpdate.liveCheckStopsBeforeInstall = CommandLine.arguments.contains("--ui-smoke-update-download")
        let updates = AppUpdate()
        liveUpdateCheck = updates
        var log: [String] = []
        updates.liveReport = { line in
            log.append(line)
            try? log.joined(separator: "\n").write(to: destination.appendingPathComponent("update-live.txt"), atomically: true, encoding: .utf8)
        }
        updates.checkNow()
        Task { @MainActor in
            let download = AppUpdate.liveCheckStopsBeforeInstall
            for _ in 0..<120 where !log.contains(where: { (download ? $0.hasPrefix("ready") : $0.hasPrefix("found")) || $0.hasPrefix("abort") || $0.hasPrefix("none") || $0.hasPrefix("cycle") }) {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for window in NSApp.windows where window.isVisible {
                log.append("window " + window.title + " " + String(describing: type(of: window)))
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: destination.appendingPathComponent("window-\(log.count).png"))
                }
            }
            try? log.joined(separator: "\n").write(to: destination.appendingPathComponent("update-live.txt"), atomically: true, encoding: .utf8)
            smokeCheck(log.contains { $0.hasPrefix("found") }, "Sparkle finds the release through the signed feed: \(log)")
            if download { smokeCheck(log.contains { $0.hasPrefix("ready") }, "Sparkle downloads and verifies the archive: \(log)") }
            NSApp.terminate(nil)
        }
    }
}
