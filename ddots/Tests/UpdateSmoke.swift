import AppKit
import CryptoKit
import Sparkle

private func record(_ value: String) {
    let url = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "FixtureLog") as! String)
    if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.seekToEnd(); try! handle.write(contentsOf: Data((value + "\n").utf8)); try! handle.close()
}

@MainActor private final class SmokeDriver: UpdateUserDriver {
    override func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        record("found")
        let cancel = Bundle.main.object(forInfoDictionaryKey: "FixtureMode") as? String == "cancel"
        choose(cancel ? .dismiss : .install, state: state, reply: reply)
    }
    override func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
    override func showDownloadInitiated(cancellation: @escaping () -> Void) { record("download") }
    override func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) {}
    override func showDownloadDidReceiveData(ofLength length: UInt64) {}
    override func showDownloadDidStartExtractingUpdate() { record("extract") }
    override func showExtractionReceivedProgress(_ progress: Double) {}
    override func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) { record("install") }
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("error:\((error as NSError).code):\(error.localizedDescription)"); acknowledgement()
    }
    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        record("not-found"); acknowledgement()
    }
    override func dismissUpdateInstallation() {}
}

@MainActor private final class SmokeApp: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var updater: SPUUpdater?
    var driver: SmokeDriver?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        record("launched:\(version)")
        if version == "2" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            return
        }
        let driver = SmokeDriver(hostBundle: .main, delegate: nil)
        driver.prepare = { done in
            record("prepare")
            done(Bundle.main.object(forInfoDictionaryKey: "FixtureMode") as? String != "prepare-failure")
        }
        self.driver = driver
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        self.updater = updater
        updater.httpHeaders = ["Authorization": "Bearer synthetic-test", "Accept": "application/octet-stream"]
        do { try updater.start(); updater.checkForUpdates() }
        catch { record("start-error:\(error)"); NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { record("timeout"); NSApp.terminate(nil) }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        record("skipped:" + (UserDefaults.standard.string(forKey: "SUSkippedVersion") ?? "none"))
        record("finished"); DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

@main struct UpdateSmoke {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--public-key" {
            let seed = Data(base64Encoded: try! String(contentsOfFile: CommandLine.arguments[2]).trimmingCharacters(in: .whitespacesAndNewlines))!
            print(try! Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString())
            return
        }
        let app = NSApplication.shared
        let delegate = SmokeApp()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
