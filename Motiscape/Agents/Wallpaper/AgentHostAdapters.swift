import AppKit
import Combine
import Foundation

// This adapter supplies the host-owned values that the existing business code
// previously read from AppDelegate. It does not implement desktop playback.
final class AppDelegate {
    static let shared = AppDelegate()
    let wallpaperViewModel = WallpaperViewModel()
    let globalSettingsViewModel = AgentSettingsModel()
}
final class AgentSettingsModel { var settings = GlobalSettings() }
enum AgentLoadSource { case disk, memory }
struct GlobalSettings {
    var fps = 30
    var shouldEnableHDRVideo = false
    var wallpaperLoadSource: AgentLoadSource? = .disk
}
final class WallpaperViewModel {
    var context: ScreenSaverManager.ConfigurationContext?
    var activeStates: [String: DisplayWallpaperState] = [:]
    var selectedDisplayKey = DisplayKey(rawValue: "")
    let renderer = AgentPreviewRenderer()
    func positions(for id: String) -> [String: WallpaperPosition] { context?.positions ?? [:] }
    func renderSnapshots(for id: String) -> [String: WallpaperRenderSnapshot] { context?.runtimeByDisplay ?? [:] }
    func refreshScriptStorage(for wallpaper: WEWallpaper? = nil) async {}
    func saveRuntime() {}
    func state(for key: DisplayKey) -> DisplayWallpaperState? { activeStates[key.rawValue] }
    func effectiveProperties(for wallpaper: WEWallpaper, runtime: WallpaperRuntimeState) -> [String: WEProjectProperty] {
        if let entry = activeStates.first(where: { $0.value.wallpaper.id == wallpaper.id && $0.value.runtime == runtime }),
           let snapshot = context?.runtimeByDisplay[entry.key] { return snapshot.properties(for: wallpaper) }
        var properties = wallpaper.project.general?.properties?.items ?? [:]
        for (key, value) in runtime.propertyOverrides {
            guard var property = properties[key] else { continue }
            property.value = property.normalizedComboValue(value); properties[key] = property
        }
        return properties
    }
    static func resolveProperties(_ input: [String: WEProjectProperty], for wallpaper: WEWallpaper) -> [String: WEProjectProperty] {
        // Main app resolves file/shortcut properties before sending the context.
        input
    }
}
final class AgentPreviewRenderer {
    func snapshot(onDisplay display: UInt32, path: String, completion: @escaping (Bool) -> Void) {
        let expected = DisplayRegistry.shared.info(forDisplay: display).flatMap {
            AppDelegate.shared.wallpaperViewModel.state(for: $0.key)
        }
        _ = send(wallpaper: nil, onDisplay: display, options: nil, path: path, expectedState: expected, completion: completion)
    }
    func snapshot(wallpaper: WEWallpaper, onDisplay display: UInt32, options: RenderOptions,
                  path: String, completion: @escaping (Bool) -> Void) -> UUID {
        send(wallpaper: wallpaper, onDisplay: display, options: options, path: path, completion: completion)
    }
    private func send(wallpaper: WEWallpaper?, onDisplay display: UInt32, options: RenderOptions?,
                      path: String, expectedState: DisplayWallpaperState? = nil, completion: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        let value = WallpaperAgentPreview(token: token, expectedState: expectedState, wallpaper: wallpaper, displayID: display, options: options, path: path)
        Task {
            guard let connection = WallpaperAgentAdapter.connection,
                  let payload = try? JSONEncoder().encode(value),
                  let data = try? await connection.request("host.preview", payload: payload, timeout: 60),
                  let success = try? JSONDecoder().decode(Bool.self, from: data) else { completion(false); return }
            completion(success)
        }
        return token
    }
    func cancelPreview(_ token: UUID) {
        if let data = try? JSONEncoder().encode(token) { WallpaperAgentAdapter.connection?.send("host.cancelPreview", payload: data) }
    }
}
final class DesktopOverrideService {
    static let shared = DesktopOverrideService()
    var fallbacks: [String: URL] = [:]
    var systemFallbacks: [String: URL] = [:]
    func dynamicLockScreenFallbackURL(forDisplay display: UInt32) -> URL? { fallbacks[String(display)] }
    func dynamicLockScreenSystemFallbackURL(forDisplay display: UInt32) -> URL? { systemFallbacks[String(display)] }
}
enum AppIntegrationFixture {
    static let isEnabled = false
    static let supportDirectory: URL? = nil
}
final class MotiscapeLogService {
    static let shared = MotiscapeLogService()
    func append(_ value: String, source: String) { NSLog("[%@] %@", source, value) }
}
final class WallpaperLibrary {
    static let shared = WallpaperLibrary()
    var directories: [String: [URL]] = [:]
    func workshopItemDirectories(for id: String) -> [URL] { directories[id] ?? [] }
}
