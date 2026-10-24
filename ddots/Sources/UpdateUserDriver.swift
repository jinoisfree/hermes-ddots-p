import Sparkle
import Foundation

/// The install button is consent to download, quit, replace and relaunch. Sparkle
/// owns the actual installer; ddots only pauses its separate relay before it runs.
@MainActor
class UpdateUserDriver: SPUStandardUserDriver {
    var prepare: (@escaping (Bool) -> Void) -> Void = { $0(true) }
    var cancelled: () -> Void = {}
    var approved = false
    var silent = false
    var waitForIdle: (@escaping (SPUUserUpdateChoice) -> Void) -> Void = { $0(.skip) }

    /// Set when the user already chose 업데이트 in ddots' own notice; Sparkle's found-update window is skipped.
    var consented = false

    func choose(_ choice: SPUUserUpdateChoice, state: SPUUserUpdateState,
                reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard choice == .install else {
            approved = false; cancelled()
            // Never leave an installer waiting to replace the app on an unrelated quit.
            reply(state.stage == .installing ? .skip : choice); return
        }
        prepare { [weak self] ready in
            self?.approved = ready
            // A temporary preparation failure must not permanently skip this release.
            reply(ready ? .install : (state.stage == .installing ? .skip : .dismiss))
        }
    }
    override func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
                                  reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if silent {
            if state.stage == .installing { waitForIdle(reply) }
            else { reply(.install) } // Download/verify now; relay stays up until ready.
            return
        }
        if consented { choose(.install, state: state, reply: reply); return }
        super.showUpdateFound(with: appcastItem, state: state) { [weak self] choice in
            guard let self else { reply(.skip); return }
            self.choose(choice, state: state, reply: reply)
        }
    }
    /// Live update check only: report that the archive arrived and passed verification, then decline installing.
    var stopBeforeInstall: (() -> Void)?
    override func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if let stop = stopBeforeInstall { stop(); reply(.skip); return }
        if silent { waitForIdle(reply); return }
        if approved { reply(.install) }
        else {
            // A recovered download still needs consent in this session.
            super.showReady(toInstallAndRelaunch: { [weak self] choice in
                guard let self else { reply(.skip); return }
                guard choice == .install else { self.cancelled(); reply(.skip); return }
                self.prepare { ready in self.approved = ready; reply(ready ? .install : .skip) }
            })
        }
    }

    // Silence only our automatic cycle; manual checks retain Sparkle UI.
    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        if !silent { super.showDownloadInitiated(cancellation: cancellation) }
    }
    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        if !silent { super.showDownloadDidReceiveExpectedContentLength(expectedContentLength) }
    }
    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        if !silent { super.showDownloadDidReceiveData(ofLength: length) }
    }
    override func showDownloadDidStartExtractingUpdate() {
        if !silent { super.showDownloadDidStartExtractingUpdate() }
    }
    override func showExtractionReceivedProgress(_ progress: Double) {
        if !silent { super.showExtractionReceivedProgress(progress) }
    }
    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if silent { acknowledgement() } else { super.showUpdaterError(error, acknowledgement: acknowledgement) }
    }
    override func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if silent { acknowledgement() } else { super.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement) }
    }
    override func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !silent { super.showInstallingUpdate(withApplicationTerminated: applicationTerminated, retryTerminatingApplication: retryTerminatingApplication) }
    }
    override func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        if silent { acknowledgement() } else { super.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement) }
    }
}
