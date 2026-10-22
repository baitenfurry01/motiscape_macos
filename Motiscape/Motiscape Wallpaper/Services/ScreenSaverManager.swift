import AppKit
import Foundation

/// Main-process facade. All system screen-saver mutations run in Wallpaper Agent.
final class ScreenSaverManager {
    static let shared = ScreenSaverManager()
    struct ConfigurationContext: Codable, Sendable {
        let positions: [String: WallpaperPosition]
        let selectedPosition: WallpaperPosition
        let fps: Int
        let enableHDRVideo: Bool
        let loadFromMemory: Bool
        let language: String
        var runtimeByDisplay: [String: WallpaperRenderSnapshot] = [:]
        var sourceDisplayKey: String? = nil
        var capturedAt = ProcessInfo.processInfo.systemUptime

        init(positions: [String: WallpaperPosition], selectedPosition: WallpaperPosition,
             fps: Int, enableHDRVideo: Bool, loadFromMemory: Bool, language: String) {
            self.positions = positions
            self.selectedPosition = selectedPosition
            self.fps = fps
            self.enableHDRVideo = enableHDRVideo
            self.loadFromMemory = loadFromMemory
            self.language = language
        }

        init(wallpaperID: String, runtime: WallpaperRuntimeState, fps: Int,
             sourceDisplay: DisplayKey? = nil) {
            let model = AppDelegate.shared.wallpaperViewModel
            let settings = AppDelegate.shared.globalSettingsViewModel.settings
            let positions = model.positions(for: wallpaperID)
            self.init(positions: positions,
                      selectedPosition: positions[(sourceDisplay ?? model.selectedDisplayKey).rawValue] ?? runtime.position,
                      fps: fps, enableHDRVideo: settings.shouldEnableHDRVideo,
                      loadFromMemory: (settings.wallpaperLoadSource ?? .disk) == .memory,
                      language: MotiscapeLocalization.shared.locale.identifier)
            sourceDisplayKey = (sourceDisplay ?? model.selectedDisplayKey).rawValue
            runtimeByDisplay = model.renderSnapshots(for: wallpaperID)
        }
    }
    init(configurationDirectory: URL? = nil) {}
    var isInstalled: Bool { WallpaperAgentClient.status.installed }
    func install() throws { try WallpaperAgentClient.call("saver.install") }
    func uninstall() throws { try WallpaperAgentClient.call("saver.uninstall") }
    func configure(with wallpaper: WEWallpaper, runtime: WallpaperRuntimeState,
                   properties: [String: WEProjectProperty], fps: Int,
                   forDynamicLockScreen: Bool = false, context: ConfigurationContext? = nil) throws {
        var request = WallpaperAgentRequest()
        request.wallpaper = wallpaper; request.runtime = runtime; request.properties = WallpaperViewModel.resolveProperties(properties, for: wallpaper)
        request.context = context ?? ConfigurationContext(wallpaperID: wallpaper.id, runtime: runtime, fps: fps)
        request.enabled = forDynamicLockScreen
        try WallpaperAgentClient.call("saver.configure", request)
    }
    func updateRuntimeIfConfigured(wallpaper: WEWallpaper, runtime: WallpaperRuntimeState,
                                   properties: [String: WEProjectProperty], context: ConfigurationContext) {
        var request = WallpaperAgentRequest()
        request.wallpaper = wallpaper; request.runtime = runtime; request.properties = WallpaperViewModel.resolveProperties(properties, for: wallpaper); request.context = context
        WallpaperAgentClient.send("saver.runtime", request)
    }
    func updateGlobalSettings(_ settings: GlobalSettings, languageIdentifier: String) {
        var request = WallpaperAgentRequest()
        request.fps = Int(settings.fps); request.enableHDRVideo = settings.shouldEnableHDRVideo
        request.loadFromMemory = (settings.wallpaperLoadSource ?? .disk) == .memory
        request.language = languageIdentifier
        WallpaperAgentClient.send("settings", request)
    }
    func flushConfigurationUpdates() { WallpaperAgentClient.send("flush") }
    func configuredWallpaperID() -> String? { WallpaperAgentClient.status.saverWallpaperID }
    func configuredDynamicLockScreenWallpaperID() -> String? { WallpaperAgentClient.status.dynamicSaverWallpaperID }
    func configuredWallpaperTitle() -> String? { WallpaperAgentClient.status.saverTitle }
    func remapPersistedPaths(_ mappings: [String: String]) {
        var request = WallpaperAgentRequest(); request.mappings = mappings
        WallpaperAgentClient.send("saver.remap", request)
    }
    func openSystemSettings() { WallpaperAgentClient.send("saver.settings") }
}
