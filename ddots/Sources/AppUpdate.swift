import AppKit
import Sparkle
import CoreGraphics

@MainActor
final class AppUpdate: NSObject, SPUUpdaterDelegate {
    /// Live update check only (`--ui-smoke-update-live`): a token from the environment instead of the keychain,
    /// and a report of how Sparkle's cycle ended. Normal runs never set these.
    static var liveCheckToken: String?
    /// Live check: answer the found update as the notice's 업데이트 does, download and verify, stop before replacing.
    static var liveCheckStopsBeforeInstall = false
    var liveReport: ((String) -> Void)?
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) { liveReport?("found " + item.displayVersionString) }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { liveReport?("none " + error.localizedDescription) }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { liveReport?("abort " + error.localizedDescription) }
    private let client = UpdateReleaseClient()
    private let reminder = UpdateReminder()
    private let settings = SilentUpdateSettings()
    var activity: () -> UpdateIdlePolicy.Activity = {
        .init(idleSeconds: 0, hasDrafts: true, transferring: true)
    }
    var notifyInstalled: (String) -> Void = { _ in }
    private var idleTimer: Timer?
    private var readyReply: ((SPUUserUpdateChoice) -> Void)?
    private var readyAt: Date?
    private var preparingIdle = false
    private var pendingManualCheck = false
    private var cycleSilent = false
    private var cycleFailed = false
    private var cancelledCycle = false
    private var preparationGeneration = 0
    private var installingVersion: (String, String)?

    private let work = DispatchQueue(label: "ddots.updates", qos: .utility)
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var generation = 0
    private var stopped = false
    private var busy = false
    private var release: UpdateRelease?
    private var updater: SPUUpdater?
    private var driver: UpdateUserDriver?
    private var restoring = false
    private var executable: String { Bundle.main.executablePath! }

    func start() {
        guard LoginLaunch.isInstalled() else { return }
        restoreRelay()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        if settings.installed(version: version, build: build) { notifyInstalled("ddots \(version)으로 업데이트됨") }
        // The feed asset changes for each GitHub release. Resolve it before every
        // cycle, rather than letting Sparkle repeatedly poll an old asset URL.
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.check(manual: false) }
        }
        timer.fireDate = Date().addingTimeInterval(30)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        cancelIdle(reply: true)
        stopped = true; generation += 1
        timer?.invalidate(); timer = nil
        task?.cancel(); task = nil
        client.close()
    }

    @objc func checkNow() { check(manual: true) }
    func check(manual: Bool) {
        guard !stopped, reminder.allowsCheck(manual: manual) else { return }
        guard LoginLaunch.isInstalled() else {
            if manual { inform("응용 프로그램 폴더에 설치한 뒤 업데이트할 수 있어요.") }
            return
        }
        if let updater, updater.sessionInProgress {
            if manual {
                // Let the in-flight relay pause unwind before opening manual UI.
                if preparingIdle { pendingManualCheck = true; preparationGeneration += 1; return }
                preparationGeneration += 1
                cycleSilent = false; driver?.silent = false; driver?.consented = false; driver?.approved = false
                if let reply = readyReply {
                    cancelIdle(reply: false)
                    driver?.showReady(toInstallAndRelaunch: reply)
                } else { updater.checkForUpdates() }
            }
            return
        }
        guard !busy, !restoring else { return }
        cycleSilent = UpdateIdlePolicy.silent(enabled: settings.enabled, manual: manual, failures: settings.failures)
        cycleFailed = false; cancelledCycle = false; installingVersion = nil; pendingManualCheck = false
        busy = true
        generation += 1
        let generation = generation
        work.async { [weak self] in
            let token: String? = UpdateRelease.requiresToken ? (Self.liveCheckToken ?? UpdateCredential.read()) : ""
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == generation else { return }
                guard let token else {
                    self.busy = false
                    if manual { self.connect() }
                    return
                }
                self.task = self.client.latest(token: token) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, !self.stopped, self.generation == generation else { return }
                        self.busy = false; self.task = nil
                        switch result {
                        case .success(let release):
                            if manual {
                                do { try self.begin(release, token: token, manual: true, consented: Self.liveCheckStopsBeforeInstall) }
                                catch { self.inform(error.localizedDescription) }
                            } else { self.announce(release, token: token) }
                        case .failure(let error):
                            if manual { self.inform(error.localizedDescription) }
                            else { self.recordFailure(error) }
                        }
                    }
                }
            }
        }
    }

    /// Automatic discovery downloads silently unless opted out or repeated failures
    /// require the existing confirmation UI. Both paths retain Sparkle verification.
    private func announce(_ release: UpdateRelease, token: String) {
        guard !stopped, reminder.allowsCheck(manual: false),
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              SUStandardVersionComparator().compareVersion(release.version, toVersion: current) == .orderedDescending else { return }
        if cycleSilent {
            guard FileManager.default.isWritableFile(atPath: Bundle.main.bundlePath),
                  FileManager.default.isWritableFile(atPath: Bundle.main.bundleURL.deletingLastPathComponent().path) else {
                recordFailure(NSError(domain: "앱 폴더 쓰기 권한 없음", code: 1)); return
            }
            do { try begin(release, token: token, manual: false) }
            catch { recordFailure(error) }
            return
        }
        busy = true
        defer { busy = false }
        let alert = Self.automaticAlert(version: release.version)
        if settings.enabled && settings.failures >= 3 {
            alert.informativeText += "\n조용한 업데이트가 3회 연속 실패해 확인 방식으로 돌아왔어요. " + settings.reason
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard !stopped else { return }
        if response == .alertSecondButtonReturn { reminder.hideToday() }
        else if response == .alertFirstButtonReturn {
            do { try begin(release, token: token, manual: true, consented: true) }
            catch { inform(error.localizedDescription) }
        }
    }

    static func automaticAlert(version: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "ddots 새 버전 \(version)"
        alert.informativeText = "새 업데이트가 있어요. 지금 업데이트할까요?\n업데이트하면 새 버전을 받아 지금 앱과 바꾸고 다시 실행해요. 설정과 대화 기록은 그대로예요."
        alert.addButton(withTitle: "업데이트")
        alert.addButton(withTitle: "오늘 다시 보지 않음")
        alert.addButton(withTitle: "나중에")
        alert.buttons[2].keyEquivalent = "\u{1b}"
        return alert
    }

    private func begin(_ release: UpdateRelease, token: String, manual: Bool, consented: Bool = false) throws {
        self.release = release
        if updater == nil {
            let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
            driver.prepare = { [weak self] done in self?.prepareInstall(done) ?? done(false) }
            driver.cancelled = { [weak self] in
                self?.settings.cancelled(); self?.restoreRelay()
            }
            driver.waitForIdle = { [weak self] reply in self?.waitUntilIdle(reply) ?? reply(.skip) }
            if Self.liveCheckStopsBeforeInstall {
                // Never touch the real relay agent or replace anything during the live check.
                driver.prepare = { $0(true) }
                driver.stopBeforeInstall = { [weak self] in self?.liveReport?("ready: downloaded and verified") }
            }
            self.driver = driver
            let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
            // Scheduling belongs to the release resolver above. Silent installation is
            // left disabled in Info.plist: our user driver must enforce the idle gate.
            updater.automaticallyChecksForUpdates = false
            try updater.start()
            self.updater = updater
        }
        driver?.silent = cycleSilent
        driver?.approved = false
        driver?.consented = consented
        updater?.httpHeaders = UpdateRelease.headers(token: token)
        if manual { updater?.checkForUpdates() } else { updater?.checkForUpdatesInBackground() }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { release?.feedURL.absoluteString }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !stopped, release != nil else { throw UpdateFailure.closing }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        installingVersion = (item.displayVersionString, item.versionString)
        guard !stopped, let release,
              release.allows(file: item.fileURL, version: item.displayVersionString, size: item.contentLength,
                             installation: item.installationType, notes: item.releaseNotesURL,
                             information: item.infoURL, hasDeltas: !(item.deltaUpdates?.isEmpty ?? true)) else {
            throw UpdateFailure.invalidRelease
        }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        liveReport?("cycle " + (error?.localizedDescription ?? "ok"))
        cancelIdle(reply: false)
        if let error, !cancelledCycle {
            let ns = error as NSError
            if ns.domain != SUSparkleErrorDomain || (ns.code != Int(SUError.noUpdateError.rawValue) && ns.code != Int(SUError.installationCanceledError.rawValue)) { recordFailure(error) }
        }
        // Sparkle can finish a cycle after scheduling installation, before relaunch.
        // Keep the marker until the new build starts; clear only failed/cancelled installs.
        if error != nil || cancelledCycle || driver?.approved != true {
            settings.cancelled()
            if !stopped { restoreRelay() }
        }
        driver?.consented = false
        updater.httpHeaders = nil
    }

    private func prepareInstall(_ done: @escaping (Bool) -> Void) {
        guard !stopped else { done(false); return }
        // Drafts are memory-only. A silent update never terminates with any unsaved draft.
        if cycleSilent && UpdateIdlePolicy.decide(activity(), elapsed: 0) != .install { done(false); return }
        let executable = executable, item = RelayAgent.plistURL
        let preparation = preparationGeneration
        work.async { [weak self] in
            let result = Result { try UpdateRelay.suspend(executable: executable, item: item) }
            DispatchQueue.main.async {
                guard let self else { done(false); return }
                guard !self.stopped, self.preparationGeneration == preparation else {
                    self.restoreRelay(); done(false); return
                }
                switch result {
                case .success:
                    if self.cycleSilent && UpdateIdlePolicy.decide(self.activity(), elapsed: 0) != .install {
                        self.restoreRelay(); done(false); return
                    }
                    if let (version, build) = self.installingVersion { self.settings.preparing(version: version, build: build) }
                    done(true)
                case .failure(let error):
                    self.recordFailure(error); done(false)
                    if !self.cycleSilent { self.inform(error.localizedDescription) }
                }
            }
        }
    }
    private func restoreRelay() {
        guard !restoring else { return }
        restoring = true
        let executable = executable, item = RelayAgent.plistURL
        work.async { [weak self] in
            let result = Result { try UpdateRelay.restore(executable: executable, item: item) }
            DispatchQueue.main.async {
                guard let self, !self.stopped else { return }
                self.restoring = false
                if case .failure = result, !self.cycleSilent { self.inform("업데이트 뒤 대화 공유를 다시 켜지 못했어요. ‘다른 Mac과 대화 공유’에서 확인해 주세요.") }
            }
        }
    }

    @objc func connect() {
        if !UpdateRelease.requiresToken { check(manual: true); return }
        guard !stopped, !busy, updater?.sessionInProgress != true else { return }
        busy = true
        let alert = NSAlert()
        alert.messageText = "ddots 업데이트 연결"
        alert.informativeText = "비공개 GitHub 저장소의 새 버전을 자동으로 확인합니다. \(UpdateRelease.repository)에 Contents 읽기 권한이 있는 접근 토큰을 입력해 주세요. 토큰은 이 Mac의 키체인에만 저장합니다. 자동 업데이트는 사용하지 않는 동안 조용히 설치하며 수동 확인은 설치 전에 묻습니다."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "GitHub 접근 토큰"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "연결")
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "연결 해제")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard !stopped else { return }
        busy = false
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = ""
        if response == .alertThirdButtonReturn {
            busy = true; generation += 1
            let generation = generation
            work.async { [weak self] in
                let result = Result { try UpdateCredential.remove() }
                DispatchQueue.main.async {
                    guard let self, !self.stopped, self.generation == generation else { return }
                    self.busy = false
                    if case .failure(let error) = result { self.inform(error.localizedDescription) }
                    else {
                        self.updater?.httpHeaders = nil
                        self.release = nil
                        self.inform("업데이트 연결을 해제했어요.")
                    }
                }
            }
            return
        }
        guard response == .alertFirstButtonReturn else { return }
        guard UpdateCredential.validInput(token) else { inform("접근 토큰을 확인해 주세요."); return }
        busy = true; generation += 1
        let generation = generation
        task = client.validate(token: token) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == generation else { return }
                self.task = nil
                switch result {
                case .failure(let error): self.busy = false; self.inform(error.localizedDescription)
                case .success:
                    self.work.async { [weak self] in
                        let saved = Result { try UpdateCredential.save(token) }
                        DispatchQueue.main.async {
                            guard let self, !self.stopped, self.generation == generation else { return }
                            self.busy = false
                            switch saved {
                            case .success: self.check(manual: true)
                            case .failure(let error): self.inform(error.localizedDescription)
                            }
                        }
                    }
                }
            }
        }
    }
    private func recordFailure(_ error: Error) {
        guard !cycleFailed else { return }
        cycleFailed = true
        let ns = error as NSError
        settings.failed("받기·검증·설치 실패 (\(ns.domain), \(ns.code))")
    }
    private func cancelIdle(reply: Bool) {
        idleTimer?.invalidate(); idleTimer = nil
        let pending = readyReply; readyReply = nil; readyAt = nil
        if reply, let pending {
            preparationGeneration += 1; cancelledCycle = true
            settings.cancelled(); pending(.skip); restoreRelay()
        }
    }
    private func waitUntilIdle(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
        cancelIdle(reply: true)
        cancelledCycle = false; readyReply = reply; readyAt = Date()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.attemptSilentInstall() }
        }
        RunLoop.main.add(timer, forMode: .common); idleTimer = timer
        attemptSilentInstall()
    }
    private func attemptSilentInstall() {
        guard !stopped, !preparingIdle, let reply = readyReply, let since = readyAt else { return }
        if !settings.enabled { cancelIdle(reply: true); return }
        switch UpdateIdlePolicy.decide(activity(), elapsed: Date().timeIntervalSince(since)) {
        case .wait: return
        case .expire: cancelIdle(reply: true) // .skip at ready cancels this installer, not the version.
        case .install:
            preparingIdle = true
            prepareInstall { [weak self] ready in
                guard let self else { return }
                self.preparingIdle = false
                guard !self.stopped, self.readyReply != nil else { return }
                if self.pendingManualCheck {
                    self.pendingManualCheck = false; self.check(manual: true); return
                }
                if ready {
                    self.cancelIdle(reply: false); self.driver?.approved = true; reply(.install)
                } else if self.cycleFailed {
                    self.cancelIdle(reply: true); self.restoreRelay()
                }
                // Input can resume while suspending the relay. Keep the original
                // deadline and minute timer in that case; do not discard the download.
            }
        }
    }

    private func inform(_ message: String) {
        let alert = NSAlert(); alert.messageText = "ddots 업데이트"; alert.informativeText = message
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
