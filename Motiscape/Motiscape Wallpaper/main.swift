import Cocoa

AppIntegrationFixture.validateInvocation()
if AppIntegrationFixture.isLibraryUI {
    // Register this actual app, not a sandbox-exec wrapper, before restricting
    // local UI tests. No business model has been initialized at this point.
    _ = NSApplication.shared
    AppIntegrationFixture.installLibrarySandbox()
}
AppIntegrationFixture.record("entry")
if WEConditionEvaluator.runWorkerIfRequested() { exit(0) }

let motiscapeOpenWindowNotification = Notification.Name("com.BaiTenG.motiscape.openMainWindow")
let motiscapeLaunchAtLogin = ProcessInfo.processInfo.arguments.contains("--launch-at-login")

if let bundleID = Bundle.main.bundleIdentifier,
   NSWorkspace.shared.runningApplications.contains(where: {
       $0.bundleIdentifier == bundleID &&
       $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
   }) {
    if !motiscapeLaunchAtLogin && !AppIntegrationFixture.isEnabled {
        DistributedNotificationCenter.default().postNotificationName(
            motiscapeOpenWindowNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
    exit(0)
}


if LibraryMetadataRecovery.needsMaintenanceStartup {
    AppIntegrationFixture.record("maintenance-route")
    // Do not even initialize the production delegate's eager business models.
    let maintenanceDelegate = MainActor.assumeIsolated { LibraryMetadataRecoveryAppDelegate() }
    NSApplication.shared.delegate = maintenanceDelegate
    withExtendedLifetime(maintenanceDelegate) { NSApplication.shared.run() }
    exit(0)
}

if AppIntegrationFixture.isEnabled && !AppIntegrationFixture.isLibraryUI { AppIntegrationFixture.runReopenProbe() }

NSApplication.shared.delegate = AppDelegate.shared
NSApplication.shared.run()
