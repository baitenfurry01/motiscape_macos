import AppKit
import Combine
import Foundation

@MainActor
enum WallpaperAgentAdapter {
    nonisolated(unsafe) static var connection: AgentConnection?
    private static var observers: [NSObjectProtocol] = []
    private static var subscriptions: Set<AnyCancellable> = []
    private static var stopping = false
    private static var started = false

    static func install(on connection: AgentConnection) {
        self.connection = connection
        connection.onRequest = { method, data, completion in
            Task { @MainActor in
                do { completion(.success(try await handle(method, data: data))) }
                catch DynamicLockScreenError.fullDiskAccessRequired {
                    completion(.failure(AgentTransportError.message("wallpaper.fullDiskAccessRequired"))); publish()
                }
                catch { completion(.failure(error)); publish() }
            }
        }
        connection.onEvent = { method, data in
            Task { @MainActor in
                do { _ = try await handle(method, data: data) }
                catch { publishError(error); publish() }
            }
        }
        // Recover a previous interrupted cleanup before modifying system settings.
        do { try WallpaperAgentSession.shared.recover() }
        catch { publishError(error); publish(); return }
        started = true
        let a = DynamicLockScreenManager.shared
        let b = ScreenSaverDynamicLockScreenManager.shared
        a.objectWillChange.sink { _ in DispatchQueue.main.async { publish() } }.store(in: &subscriptions)
        b.objectWillChange.sink { _ in DispatchQueue.main.async { publish() } }.store(in: &subscriptions)
        if a.isEnabled || b.isEnabled || UserDefaults.standard.bool(forKey: "WallpaperAgent.SaverInstalled") {
            do {
                try WallpaperAgentSession.shared.begin()
                try WallpaperAgentSession.shared.captureSaver()
                if UserDefaults.standard.bool(forKey: "WallpaperAgent.SaverInstalled") { try ScreenSaverManager.shared.install() }
                if b.isEnabled { try ScreenSaverManager.shared.installDynamicLockScreen() }
                a.setEnabled(a.isEnabled)
                b.setEnabled(b.isEnabled)
            } catch { publishError(error) }
        }
        installObservers()
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue == true {
            Task { await locked() }
        }
        publish()
    }

    private static func handle(_ method: String, data: Data) async throws -> Data {
        if method == "lockA.permissions" {
            DynamicLockScreenManager.shared.openFullDiskAccessSettings()
            return Data()
        }
        guard started, !stopping else { throw NSError(domain: "WallpaperAgent", code: 3,
            userInfo: [NSLocalizedDescriptionKey: L("屏保与锁屏插件暂不可用。")]) }
        let request = data.isEmpty ? WallpaperAgentRequest() : try JSONDecoder().decode(WallpaperAgentRequest.self, from: data)
        applyContext(request)
        let saver = ScreenSaverManager.shared
        let a = DynamicLockScreenManager.shared
        let b = ScreenSaverDynamicLockScreenManager.shared
        let systemOperations = ["saver.install", "saver.uninstall", "saver.configure", "lockA.confirm", "lockA.enable",
            "lockA.configure", "lockA.retry", "lockA.settings", "lockB.confirm", "lockB.enable", "lockB.configure"]
        if systemOperations.contains(method) { try WallpaperAgentSession.shared.begin() }
        if ["lockB.confirm", "lockB.enable"].contains(method) { try WallpaperAgentSession.shared.captureSaver() }
        switch method {
        case "status": break
        case "saver.install":
            try WallpaperAgentSession.shared.captureSaver(); try saver.install()
            UserDefaults.standard.set(true, forKey: "WallpaperAgent.SaverInstalled")
        case "saver.uninstall":
            try WallpaperAgentSession.shared.captureSaver(); try saver.uninstall()
            UserDefaults.standard.set(false, forKey: "WallpaperAgent.SaverInstalled")
        case "saver.configure":
            guard let wallpaper = request.wallpaper, let runtime = request.runtime, let context = request.context else { throw invalidRequest() }
            try saver.configure(with: wallpaper, runtime: runtime, properties: request.properties ?? [:], fps: context.fps,
                forDynamicLockScreen: request.enabled ?? false, context: context)
        case "saver.runtime":
            guard let wallpaper = request.wallpaper, let runtime = request.runtime, let context = request.context else { throw invalidRequest() }
            saver.updateRuntimeIfConfigured(wallpaper: wallpaper, runtime: runtime, properties: request.properties ?? [:], context: context)
        case "saver.remap": saver.remapPersistedPaths(request.mappings ?? [:])
        case "saver.settings": saver.openSystemSettings()
        case "settings": saver.updateGlobalSettings(AppDelegate.shared.globalSettingsViewModel.settings,
            languageIdentifier: request.language ?? MotiscapeLocalization.shared.locale.identifier)
        case "lockA.confirm": _ = a.confirmAndEnable(input: request.input ?? "")
        case "lockA.enable": a.setEnabled(request.enabled ?? false)
        case "lockA.configure":
            guard let wallpaper = request.wallpaper, let runtime = request.runtime, let context = request.context else { throw invalidRequest() }
            try await a.configureCurrentWallpaper(wallpaper, runtime: runtime, properties: request.properties ?? [:],
                fps: context.fps, displayIDs: request.displayIDs ?? [])
        case "lockA.runtime":
            guard let snapshot = request.snapshot, let wallpaper = request.wallpaper,
                  let displayID = request.displayID, let displayKey = request.displayKey else { throw invalidRequest() }
            a.updateRuntime(snapshot, wallpaper: wallpaper, displayKey: displayKey, displayID: displayID)
        case "lockA.position":
            guard let position = request.position, let fillMode = request.fillMode,
                  let wallpaperID = request.input, let displayID = request.displayID else { throw invalidRequest() }
            a.updatePosition(position, fillMode: fillMode, wallpaperID: wallpaperID, displayID: displayID)
        case "lockA.memory": a.updateLoadFromMemory(request.enabled ?? false)
        case "lockA.fallback":
            guard let source = request.source, let displayID = request.displayID else { throw invalidRequest() }
            _ = try a.updateDesktopFallback(from: source, forDisplay: displayID)
        case "lockA.fallbacks": a.refreshDesktopFallbacks()
        case "lockA.restoreFallbacks": a.restoreSystemDesktopFallbacks()
        case "lockA.clear": a.clearConfiguration()
        case "lockA.settings": a.openSystemSettings()
        case "lockA.permissions": a.openFullDiskAccessSettings()
        case "lockA.retry": a.retryConnection()
        case "lockA.refresh": a.refreshExtension()
        case "lockB.confirm": _ = b.confirmAndEnable(input: request.input ?? "")
        case "lockB.enable": b.setEnabled(request.enabled ?? false)
        case "lockB.configure":
            guard let wallpaper = request.wallpaper, let runtime = request.runtime, let context = request.context else { throw invalidRequest() }
            try WallpaperAgentSession.shared.captureSaver()
            try await b.configureCurrentWallpaper(wallpaper, runtime: runtime, properties: request.properties ?? [:], fps: context.fps)
        case "lockB.memory": b.updateLoadFromMemory(request.enabled ?? false)
        case "flush": saver.flushConfigurationUpdates(); a.flushConfigurationUpdates()
        default: throw invalidRequest()
        }
        publish()
        return try JSONEncoder().encode(status())
    }

    private static func invalidRequest() -> NSError {
        NSError(domain: "WallpaperAgent", code: 4, userInfo: [NSLocalizedDescriptionKey: L("Invalid wallpaper agent request")])
    }
    private static func applyContext(_ request: WallpaperAgentRequest) {
        let model = AppDelegate.shared.wallpaperViewModel
        if let context = request.context {
            model.context = context
            model.selectedDisplayKey = DisplayKey(rawValue: context.sourceDisplayKey ?? "")
            AppDelegate.shared.globalSettingsViewModel.settings.fps = context.fps
            AppDelegate.shared.globalSettingsViewModel.settings.shouldEnableHDRVideo = context.enableHDRVideo
            AppDelegate.shared.globalSettingsViewModel.settings.wallpaperLoadSource = context.loadFromMemory ? .memory : .disk
            MotiscapeLocalization.shared.locale = Locale(identifier: context.language)
        }
        if let value = request.activeStates { model.activeStates = value }
        if let value = request.fps { AppDelegate.shared.globalSettingsViewModel.settings.fps = value }
        if let value = request.enableHDRVideo { AppDelegate.shared.globalSettingsViewModel.settings.shouldEnableHDRVideo = value }
        if let value = request.loadFromMemory { AppDelegate.shared.globalSettingsViewModel.settings.wallpaperLoadSource = value ? .memory : .disk }
        if let value = request.language { MotiscapeLocalization.shared.locale = Locale(identifier: value) }
        if let value = request.fallbacks { DesktopOverrideService.shared.fallbacks = value }
        if let value = request.systemFallbacks { DesktopOverrideService.shared.systemFallbacks = value }
    }
    static func languageDidChange() { publish() }

    private static func status() -> WallpaperAgentStatus {
        let saver = ScreenSaverManager.shared, a = DynamicLockScreenManager.shared, b = ScreenSaverDynamicLockScreenManager.shared
        var value = WallpaperAgentStatus()
        value.installed = saver.isInstalled; value.saverTitle = saver.configuredWallpaperTitle()
        value.saverWallpaperID = saver.configuredWallpaperID(); value.dynamicSaverWallpaperID = saver.configuredDynamicLockScreenWallpaperID()
        value.aEnabled = a.isEnabled; value.aConfirmed = a.hasConfirmedWarning; value.aConfigured = a.isConfigured
        value.aCanUse = a.canUse; value.aTitle = a.configuredWallpaperTitle; value.aError = MotiscapeLocalization.shared.relocalized(a.registrationErrorMessage)
        value.aState = String(describing: a.connectionState)
        value.bEnabled = b.isEnabled; value.bConfirmed = b.hasConfirmedWarning; value.bConfigured = b.isConfigured
        value.bCanUse = b.canUse; value.bTitle = b.configuredWallpaperTitle; value.bError = MotiscapeLocalization.shared.relocalized(b.recoveryErrorMessage)
        value.mode = DynamicLockScreenModeStore.active?.rawValue
        value.fallbackDirectory = a.configurationURL?.deletingLastPathComponent().appendingPathComponent("DynamicLockScreen/DesktopFallbacks")
        return value
    }
    private static func publishError(_ error: Error) {
        NSLog("[WallpaperAgent] %@", error.localizedDescription)
        if let data = try? JSONEncoder().encode(error.localizedDescription) { connection?.send("wallpaper.error", payload: data) }
    }
    private static func publish() {
        var value = started ? status() : WallpaperAgentStatus()
        if !started { value.aError = L("无法恢复上次的系统设置，请检查插件权限后重试"); value.bError = value.aError }
        guard let data = try? JSONEncoder().encode(value) else { return }
        connection?.send("wallpaper.status", payload: data)
    }
    private static func installObservers() {
        let center = DistributedNotificationCenter.default()
        observers += [
            center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in Task { @MainActor in await locked() } },
            center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in Task { @MainActor in unlocked() } }
        ]
        let workspace = NSWorkspace.shared.notificationCenter
        for (event, signal) in [(NSWorkspace.screensDidSleepNotification, MotiscapeLockBridge.sleepNotification),
            (NSWorkspace.didWakeNotification, MotiscapeLockBridge.wakeNotification),
            (NSWorkspace.screensDidWakeNotification, MotiscapeLockBridge.wakeNotification)] {
            observers.append(workspace.addObserver(forName: event, object: nil, queue: .main) { _ in MotiscapeLockBridge.post(signal) })
        }
    }
    private static func locked() async {
        guard !stopping else { return }
        let a = DynamicLockScreenManager.shared, b = ScreenSaverDynamicLockScreenManager.shared
        let modeA = a.isEnabled && a.isConfigured, modeB = b.isEnabled && b.isConfigured
        guard modeA || modeB, let connection,
              let reply = try? await connection.request("host.prepareLock"),
              (try? JSONDecoder().decode(Bool.self, from: reply)) == true else { return }
        if modeB && !b.enterLockedState() { connection.send("host.resume"); return }
        if modeA { MotiscapeLockBridge.post(MotiscapeLockBridge.lockedNotification) }
    }
    private static func unlocked() {
        if ScreenSaverDynamicLockScreenManager.shared.isLocked { _ = ScreenSaverDynamicLockScreenManager.shared.leaveLockedState() }
        MotiscapeLockBridge.post(MotiscapeLockBridge.unlockedNotification)
        connection?.send("host.resume")
    }
    static func shutdown() async throws {
        if stopping { try WallpaperAgentSession.shared.restore(); return }
        stopping = true
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll(); subscriptions.removeAll()
        guard started else { try WallpaperAgentSession.shared.restore(); return }
        ScreenSaverManager.shared.flushConfigurationUpdates()
        DynamicLockScreenManager.shared.flushConfigurationUpdates()
        let aEnabled = DynamicLockScreenManager.shared.isEnabled
        let bEnabled = ScreenSaverDynamicLockScreenManager.shared.isEnabled
        let mode = DynamicLockScreenModeStore.active
        ScreenSaverDynamicLockScreenManager.shared.setEnabled(false)
        ScreenSaverDynamicLockScreenManager.shared.applicationWillTerminate()
        DynamicLockScreenManager.shared.setEnabled(false)
        // The active work is canceled, while the preference is retained for the
        // next main-app session. These defaults belong to the Agent bundle.
        UserDefaults.standard.set(aEnabled, forKey: "Motiscape.DynamicLockScreen.Enabled")
        UserDefaults.standard.set(bEnabled, forKey: "Motiscape.ScreenSaverDynamicLockScreen.Enabled")
        if let mode { DynamicLockScreenModeStore.activate(mode) }
        MotiscapeLockBridge.post(MotiscapeLockBridge.unlockedNotification)
        try WallpaperAgentSession.shared.restore()
    }
}
