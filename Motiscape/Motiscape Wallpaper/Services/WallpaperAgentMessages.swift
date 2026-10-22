import Foundation

/// Only value data crosses the process boundary. Rendering and system changes
/// remain owned by their respective processes.
struct WallpaperAgentRequest: Codable {
    var wallpaper: WEWallpaper?
    var runtime: WallpaperRuntimeState?
    var properties: [String: WEProjectProperty]?
    var context: ScreenSaverManager.ConfigurationContext?
    var activeStates: [String: DisplayWallpaperState]?
    var displayIDs: [UInt32]?
    var displayID: UInt32?
    var displayKey: String?
    var snapshot: WallpaperRenderSnapshot?
    var position: WallpaperPosition?
    var fillMode: FillMode?
    var enabled: Bool?
    var input: String?
    var source: URL?
    var mappings: [String: String]?
    var fallbacks: [String: URL]?
    var systemFallbacks: [String: URL]?
    var fps: Int?
    var enableHDRVideo: Bool?
    var loadFromMemory: Bool?
    var language: String?
}

struct WallpaperAgentStatus: Codable {
    var installed = false
    var saverTitle: String?
    var saverWallpaperID: String?
    var dynamicSaverWallpaperID: String?
    var aEnabled = false
    var aConfirmed = false
    var aConfigured = false
    var aCanUse = false
    var aTitle: String?
    var aState = "disabled"
    var aError: String?
    var bEnabled = false
    var bConfirmed = false
    var bConfigured = false
    var bCanUse = false
    var bTitle: String?
    var bError: String?
    var mode: String?
    var fallbackDirectory: URL?
}

struct WallpaperAgentPreview: Codable {
    var token: UUID
    var expectedState: DisplayWallpaperState? = nil
    var wallpaper: WEWallpaper?
    var displayID: UInt32
    var options: RenderOptions?
    var path: String
}
