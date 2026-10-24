import AppKit
import Darwin
import ServiceManagement

/// Keep status interpretation separate from registration and the filesystem.
enum LoginLaunchState: String {
    case enabled, requiresApproval, notRegistered, notFound, unknown
}
struct LoginLaunchPresentation: Equatable {
    let checked: Bool
    let canChange: Bool
    let message: String
    let showsSettings: Bool

    static func resolve(_ state: LoginLaunchState, installed: Bool, failed: Bool = false) -> Self {
        guard installed else {
            return Self(checked: false, canChange: false,
                        message: "응용 프로그램 폴더에 설치한 뒤 사용할 수 있어요", showsSettings: false)
        }
        if failed {
            return Self(checked: state == .enabled, canChange: true,
                        message: "등록을 마치지 못했어요. 로그인 항목 설정을 확인해 주세요.", showsSettings: true)
        }
        switch state {
        case .enabled:
            return Self(checked: true, canChange: true, message: "로그인하면 펫이 자동으로 나타나요.", showsSettings: false)
        case .requiresApproval:
            return Self(checked: false, canChange: true, message: "시스템 설정에서 로그인 항목을 허용해 주세요.", showsSettings: true)
        case .notRegistered:
            return Self(checked: false, canChange: true, message: "로그인 시 자동으로 실행하지 않아요.", showsSettings: false)
        case .notFound, .unknown:
            return Self(checked: false, canChange: true, message: "로그인 항목을 확인하지 못했어요. 설정을 확인해 주세요.", showsSettings: true)
        }
    }
}

enum LoginLaunch {
    static func isInstalled(bundle: URL = Bundle.main.bundleURL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parent = bundle.resolvingSymlinksInPath().deletingLastPathComponent().path
        return bundle.pathExtension == "app" && [home.appendingPathComponent("Applications").resolvingSymlinksInPath().path, "/Applications"].contains(parent)
    }
    static var state: LoginLaunchState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }
    static func setEnabled(_ enabled: Bool) throws {
        guard isInstalled() else { throw NSError(domain: "ddots.LoginLaunch", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "응용 프로그램 폴더에 설치한 뒤 사용할 수 있어요"]) }
        if enabled {
            if state != .enabled { try SMAppService.mainApp.register() }
        } else { try SMAppService.mainApp.unregister() }
    }
    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Read-only diagnostics and explicit maintenance commands run before the single-instance guard.
enum AppMaintenance {
    static func run(arguments: [String]) -> Bool {
        if arguments.contains("--check-automation") {
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.MobileSMS")
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
                let description: String
                switch status {
                case noErr: description = "허용됨"
                case -1744: description = "사용자 승인 필요"
                case -1743: description = "허용되지 않음"
                case -600: description = "대상 앱이 실행 중이 아님"
                default: description = "확인하지 못함"
                }
                print("automation=\(status) (\(description)); askUserIfNeeded=false; 발송 없음")
                finished.signal()
            }
            finished.wait()
            return true
        }
        if arguments.contains("--login-status") || arguments.contains("--enable-login") || arguments.contains("--disable-login") {
            if arguments.contains("--enable-login") || arguments.contains("--disable-login") {
                do { try LoginLaunch.setEnabled(arguments.contains("--enable-login")) }
                catch { fputs("로그인 항목 변경 실패: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            print("login=\(LoginLaunch.state.rawValue); installed=\(LoginLaunch.isInstalled())")
            return true
        }
        if arguments.contains("--quit-running") {
            quit(AppIdentity.otherPets())
            return true
        }
        // Quit only the processes running from that app folder.
        if let index = arguments.firstIndex(of: "--quit-app"), arguments.count > index + 1 {
            let folder = URL(fileURLWithPath: arguments[index + 1])
            quit(NSWorkspace.shared.runningApplications.filter {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && AppIdentity.runs($0.bundleURL, from: folder)
            })
            return true
        }
        return false
    }
    private static func quit(_ apps: [NSRunningApplication]) {
        for app in apps where !app.isTerminated {
            guard app.terminate() else { fputs("펫의 정상 종료 요청이 거부됐어요.\n", stderr); exit(1) }
        }
        // NSRunningApplication.isTerminated can remain cached without an NSApplication event loop.
        // Signal 0 observes process existence without sending a termination signal.
        func alive(_ app: NSRunningApplication) -> Bool {
            kill(app.processIdentifier, 0) == 0 || errno != ESRCH
        }
        let deadline = Date().addingTimeInterval(15)
        while apps.contains(where: alive) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !apps.contains(where: alive) else { fputs("펫 종료를 기다리다 중단했어요. 파일은 교체하지 않습니다.\n", stderr); exit(1) }
        print("펫 정상 종료 확인")
    }
}
