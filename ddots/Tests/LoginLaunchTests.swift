import Foundation

@main struct LoginLaunchTests {
    static func main() {
        let enabled = LoginLaunchPresentation.resolve(.enabled, installed:true)
        precondition(enabled.checked && enabled.canChange && !enabled.showsSettings)
        let approval = LoginLaunchPresentation.resolve(.requiresApproval, installed:true)
        precondition(!approval.checked && approval.showsSettings)
        precondition(!LoginLaunchPresentation.resolve(.notRegistered, installed:true).checked)
        for state in [LoginLaunchState.notFound, .unknown] {
            precondition(LoginLaunchPresentation.resolve(state, installed:true).showsSettings)
        }
        for state in [LoginLaunchState.enabled, .requiresApproval, .notRegistered, .notFound, .unknown] {
            let dev = LoginLaunchPresentation.resolve(state, installed:false)
            precondition(!dev.checked && !dev.canChange && !dev.showsSettings)
        }
        precondition(LoginLaunchPresentation.resolve(.enabled, installed:true, failed:true).showsSettings)
        let home = URL(fileURLWithPath:"/tmp/ddots-login-test")
        precondition(LoginLaunch.isInstalled(bundle:home.appendingPathComponent("Applications/ddots.app"),home:home))
        precondition(LoginLaunch.isInstalled(bundle:URL(fileURLWithPath:"/Applications/ddots.app"),home:home))
        precondition(!LoginLaunch.isInstalled(bundle:home.appendingPathComponent("dist/ddots.app"),home:home))
        precondition(!LoginLaunch.isInstalled(bundle:home.appendingPathComponent("Applications/subdir/ddots.app"),home:home))
        let own = AppIdentity.arguments(of: ProcessInfo.processInfo.processIdentifier)
        precondition(own == CommandLine.arguments, "process arguments are read back exactly")
        precondition(AppIdentity.arguments(of: 1).isEmpty || !AppIdentity.arguments(of: 1).contains("--relay"))
        let installed = home.appendingPathComponent("Applications/ddots.app")
        precondition(AppIdentity.runs(home.appendingPathComponent("Applications/../Applications/ddots.app/"), from:installed))
        precondition(!AppIdentity.runs(home.appendingPathComponent("dist/ddots.app"), from:installed), "a different folder with the same identifier is left running")
        precondition(!AppIdentity.runs(nil, from:installed))
        print("Login launch status and installation path checks passed")
    }
}
