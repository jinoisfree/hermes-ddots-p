import AppKit

extension AppDelegate {
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
