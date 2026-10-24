import AppKit
import Sparkle

@main struct UpdateDriverTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let driver = UpdateUserDriver(hostBundle: .main, delegate: nil)
        driver.silent = true
        var pending: ((SPUUserUpdateChoice) -> Void)?
        var replies: [SPUUserUpdateChoice] = []
        var preparations = 0
        driver.prepare = { done in preparations += 1; done(true) }
        driver.waitForIdle = { pending = $0 }
        driver.showReady { replies.append($0) }
        precondition(replies.isEmpty && pending != nil && preparations == 0, "ready waits without preparing relay or showing UI")
        pending?(.install); pending = nil
        precondition(replies == [.install], "idle gate authorizes installer")
        driver.showReady { replies.append($0) }
        pending?(.skip); pending = nil
        precondition(replies == [.install, .skip], "timeout/quit cancels staged install")
        var acknowledgements = 0
        driver.showUpdaterError(NSError(domain: "Synthetic", code: 1)) { acknowledgements += 1 }
        driver.showUpdateNotFoundWithError(NSError(domain: "Synthetic", code: 2)) { acknowledgements += 1 }
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        precondition(acknowledgements == 3, "silent terminal callbacks do not open windows")
        driver.showDownloadInitiated(cancellation: { preconditionFailure("not a download failure") })
        driver.showDownloadDidReceiveExpectedContentLength(10)
        driver.showDownloadDidReceiveData(ofLength: 10)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(1)
        driver.showInstallingUpdate(withApplicationTerminated: false, retryTerminatingApplication: {})
        driver.stopBeforeInstall = {}
        driver.showReady { replies.append($0) }
        precondition(replies.last == .skip, "live-check hook cannot leave a quit-time installer")
        print("PASS UpdateDriverTests: 6 assertions, 0 failures; actual Sparkle driver, no network/install")
    }
}
