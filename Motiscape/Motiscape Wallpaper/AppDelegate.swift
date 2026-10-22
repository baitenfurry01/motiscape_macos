import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    // Freeze proxy settings before any service initializes or settings UI opens.
    private let startupProxyPolicy = AppHTTPProxy.runtime

    var statusItem: NSStatusItem!

    var mainWindowController: MainWindowController!
    var settingsWindowController: SettingsWindowController!

    var contentViewModel = ContentViewModel()
    lazy var wallpaperViewModel = WallpaperViewModel(initialStates: AppIntegrationFixture.isLibraryUI ? [:] : nil)
    var globalSettingsViewModel = GlobalSettingsViewModel(observeSystemServices: !AppIntegrationFixture.isLibraryUI)
    var workshopViewModel = WorkshopViewModel(subscriptionCatalog: AppIntegrationFixture.isLibraryUI ? [] : nil)
    var navigationModel = MainNavigationModel()

    var importOpenPanel: NSOpenPanel!
    private var developerLogWindowController: DeveloperLogWindowController?
    private var developerLogWindowWasOpened = false
    private var localizationObserver: NSObjectProtocol?
    private var openWindowObserver: NSObjectProtocol?
    private var waitingForAgentsToQuit = false

    static var shared: AppDelegate = {
        AppIntegrationFixture.requireProductionStartupAllowed()
        return AppDelegate()
    }()

    private static let isLoginItemLaunch = ProcessInfo.processInfo.arguments.contains("--launch-at-login")

    func applicationWillFinishLaunching(_ notification: Notification) {
        globalSettingsViewModel.bindWorkshopSafeMode(workshop: workshopViewModel, library: contentViewModel)
        if AppIntegrationFixture.isLibraryUI {
            globalSettingsViewModel.isFirstLaunch = false
            navigationModel.selection = .installed
            setMainMenu()
            mainWindowController = MainWindowController()
            AppIntegrationFixture.record("library-ui-window")
            return
        }
        LegacyWorkshopMigration.runIfNeeded()
        if Self.isLoginItemLaunch {
            enterMenuBarMode()
        }
        setMainMenu()
        setStatusMenu()
        navigationModel.selection = globalSettingsViewModel.settings.startupSection
        self.mainWindowController = MainWindowController()
        self.settingsWindowController = SettingsWindowController(
            viewModel: globalSettingsViewModel)
        applyDeveloperMode(enabled: globalSettingsViewModel.settings.isDeveloperModeEnabled)
        localizationObserver = NotificationCenter.default.addObserver(
            forName: MotiscapeLocalization.didChangeNotification,
            object: MotiscapeLocalization.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshLocalizedChrome()
        }

        openWindowObserver = DistributedNotificationCenter.default().addObserver(
            forName: motiscapeOpenWindowNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.openMainWindow()
        }

        wallpaperViewModel.renderer.onProcessExit = { [weak self] screen, abnormal in
            guard abnormal, screen == 0 else { return }
            NSLog("[Motiscape] 渲染子进程异常退出（屏幕 \(screen)）")
            _ = self
        }

        // The renderer keeps a black window up when it cannot decode, so this
        // alert is the only thing that tells the user why.
        wallpaperViewModel.renderer.onVideoError = { [weak self] screen, wallpaper, message in
            VideoTranscodeProgressModel.shared.finish(screen: screen)
            self?.contentViewModel.screenSaverFeedback = ScreenSaverFeedback(
                title: L("视频无法播放"),
                message: L("“%@”无法播放：%@", wallpaper.project.title, message)
            )
        }

        wallpaperViewModel.renderer.onVideoTranscodeProgress = { screen, wallpaper, progress, done in
            let model = VideoTranscodeProgressModel.shared
            if done {
                model.finish(screen: screen)
                NSLog("[Motiscape] 视频转码结束: \(wallpaper.project.title)")
            } else {
                model.update(screen: screen,
                             title: wallpaper.project.title,
                             progress: progress)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppIntegrationFixture.isLibraryUI {
            contentViewModel.importSession.recoverAtLaunch { [weak self] in self?.contentViewModel.refresh() }
            contentViewModel.refresh()
            openMainWindow()
            AppIntegrationFixture.record("library-ui-started", fields: [
                "bundle": Bundle.main.bundleIdentifier ?? "nil",
                "runningBundle": NSRunningApplication.current.bundleIdentifier ?? "nil",
                "visible": String(mainWindowController.window.isVisible)
            ])
            AppIntegrationFixture.startPlaybackWatchdog()
            return
        }
        UserDefaults.standard.set(false, forKey: "Motiscape.DynamicLockScreen.Locked")
        // Before any wallpaper is applied and before the screen-saver check can
        // restart WallpaperAgent: undoes an override the previous run died
        // holding, and clears the pre-2026-08 staticWP_ placeholder cache.
        DesktopOverrideService.shared.recoverAtLaunch()
        contentViewModel.importSession.recoverAtLaunch { [weak self] in
            WEWallpaper.invalidateSizeCache()
            self?.contentViewModel.refresh()
        }

        DispatchQueue.main.async {
            self.contentViewModel.refresh()
        }

        SteamServiceManager.shared.start()

        if wallpaperViewModel.hasAnyWallpaper {
            wallpaperViewModel.restoreAllDisplays()
        }
        PluginManager.shared.beforeSteamStop = { [weak self] in try await self?.workshopViewModel.prepareForSteamAgentStop() }
        PluginManager.shared.afterSteamStop = { [weak self] in try await self?.workshopViewModel.finishSteamAgentStop() }
        PluginManager.shared.start()

        if !Self.isLoginItemLaunch {
            openMainWindow()
        } else {
            enterMenuBarMode()
        }

        PlaylistManager.shared.startRotators(wallpaperViewModel: wallpaperViewModel)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if AppIntegrationFixture.isLibraryUI { return }
        DispatchQueue.main.async { [weak self] in
            self?.globalSettingsViewModel.refreshLoginItemStatus(persist: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !self.mainWindowController.window.isVisible {
            openMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppIntegrationFixture.isLibraryUI { return .terminateNow }
        guard !waitingForAgentsToQuit else { return .terminateLater }
        waitingForAgentsToQuit = true
        PlaylistManager.shared.stopAllRotators()
        wallpaperViewModel.saveRuntime()
        wallpaperViewModel.flushPendingSaves()
        DesktopOverrideService.shared.finalizeForApplicationTermination()
        Task { @MainActor in
            do {
                try await PluginManager.shared.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                await handleAgentShutdownFailure(error, sender: sender)
            }
        }
        return .terminateLater
    }

    @MainActor
    private func handleAgentShutdownFailure(_ error: Error, sender: NSApplication) async {
        let prompt = NSAlert()
        prompt.messageText = L("插件恢复失败，已暂停退出")
        prompt.informativeText = L("%@\n\n请为屏保与锁屏插件检查系统权限，完成后重试。主程序会等待所有插件退出。取消后部分插件可能已停止，请处理错误后重新启动主程序。", error.localizedDescription)
        prompt.addButton(withTitle: L("打开权限设置"))
        prompt.addButton(withTitle: L("重试退出"))
        prompt.addButton(withTitle: L("取消退出"))
        let choice = prompt.runModal()
        if choice == .alertThirdButtonReturn { cancelAgentShutdown(sender); return }
        if choice == .alertFirstButtonReturn {
            PluginManager.shared.requestRecoveryPermissions()
            let retry = NSAlert()
            retry.messageText = L("完成插件授权后重试")
            retry.informativeText = L("权限属于屏保与锁屏插件。请在系统设置中完成授权，再返回此处重试。")
            retry.addButton(withTitle: L("重试退出"))
            retry.addButton(withTitle: L("取消退出"))
            if retry.runModal() != .alertFirstButtonReturn { cancelAgentShutdown(sender); return }
        }
        do {
            try await PluginManager.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        } catch {
            let failure = NSAlert()
            failure.messageText = L("仍无法恢复原配置")
            failure.informativeText = L("%@\n\n继续退出会停止所有插件，并保留恢复记录供下次启动重试；系统配置可能尚未恢复。", error.localizedDescription)
            failure.addButton(withTitle: L("仍然退出"))
            failure.addButton(withTitle: L("取消退出"))
            guard failure.runModal() == .alertFirstButtonReturn else { cancelAgentShutdown(sender); return }
            do {
                try await PluginManager.shared.exitAfterRecoveryFailure()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let pending = NSAlert()
                pending.messageText = L("尚未确认所有插件退出")
                pending.informativeText = error.localizedDescription
                pending.runModal()
                cancelAgentShutdown(sender)
            }
        }
    }

    @MainActor
    private func cancelAgentShutdown(_ sender: NSApplication) {
        waitingForAgentsToQuit = false
        PluginManager.shared.cancelShutdown()
        PlaylistManager.shared.startRotators(wallpaperViewModel: wallpaperViewModel)
        sender.reply(toApplicationShouldTerminate: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AppIntegrationFixture.isLibraryUI {
            if AppIntegrationFixture.isPlayback {
                wallpaperViewModel.renderer.stopAllAndWait()
                AppIntegrationFixture.record(AppIntegrationFixture.playbackEventPrefix + "-reaped")
            }
            AppIntegrationFixture.record("library-ui-quit")
            return
        }
        PlaylistManager.shared.stopAllRotators()
        if developerLogWindowWasOpened {
            MotiscapeLogService.shared.saveAutomatically()
        }
        wallpaperViewModel.saveRuntime()
        wallpaperViewModel.flushPendingSaves()
        // This method returns directly into process exit, so the renderers must
        // be reaped here and now. Anything deferred would never run and a hung
        // renderer would outlive the app as an orphan still drawing on the
        // desktop. Bounded to roughly two seconds in total.
        wallpaperViewModel.renderer.stopAllAndWait()

        SteamServiceManager.shared.shutdown()

        // Same constraint: a transient override is one Motiscape only took for
        // tint consistency, so the user's own picture goes back synchronously
        // before this returns. A persistent override is left in place.
        DesktopOverrideService.shared.restoreIfTransient()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @objc func openSettingsWindow() {
        AppIntegrationFixture.requireExternalEffectsAllowed("settings window")
        NSApp.setActivationPolicy(.regular)
        openMainWindow()
        guard let parent = mainWindowController.window,
              let settingsWindow = settingsWindowController.window else { return }
        if parent.attachedSheet === settingsWindow { return }
        guard parent.attachedSheet == nil else { return }
        globalSettingsViewModel.isSettingsPresented = true
        parent.beginSheet(settingsWindow)
    }

    func closeSettingsWindow(commit: Bool) {
        if commit {
            globalSettingsViewModel.save()
            _ = globalSettingsViewModel.commitWelcomeReset()
        } else {
            globalSettingsViewModel.reset()
        }
        globalSettingsViewModel.isSettingsPresented = false
        guard let settingsWindow = settingsWindowController?.window else { return }
        if let parent = settingsWindow.sheetParent {
            parent.endSheet(settingsWindow)
        } else {
            settingsWindow.orderOut(nil)
        }
    }

    @objc func openSteamAPIKeySettings() {
        globalSettingsViewModel.selection = 1
        openSettingsWindow()
    }

    @objc func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        if !self.mainWindowController.window.isVisible,
           UserDefaults.standard.string(forKey: "NSWindow Frame MainWindow") == nil {
            self.mainWindowController.window.center()
        }
        self.mainWindowController.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func restoreMainWindowFocus() {
        guard let window = mainWindowController?.window, window.isVisible else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hideDockIconIfNoWindowsAreVisible() {
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.isVisible }) else { return }
            self.enterMenuBarMode()
        }
    }

    func enterMenuBarMode() {
        NSApp.setActivationPolicy(.accessory)
    }

    func applyStatusItemVisibility(hidden: Bool) {
        statusItem?.isVisible = !hidden
    }

    func applyDeveloperMode(enabled: Bool) {
        if enabled {
            MotiscapeLogService.shared.start()
            developerLogWindowWasOpened = true
            if developerLogWindowController == nil {
                developerLogWindowController = DeveloperLogWindowController()
            }
            developerLogWindowController?.showWindow(nil)
        } else if developerLogWindowController?.window?.isVisible == true {
            developerLogWindowController?.close()
        }
    }

    @MainActor @objc func toggleFilter() {
        self.contentViewModel.isFilterReveal.toggle()
    }

    @objc func openSteamSetup() {
        contentViewModel.isSteamSetupPresented = true
    }

    private func refreshLocalizedChrome() {
        setMainMenu()
        setStatusMenu()
        mainWindowController?.refreshLocalizedTitle()
        settingsWindowController?.window?.title = L("设置")
        developerLogWindowController?.refreshLocalization()
    }
}
