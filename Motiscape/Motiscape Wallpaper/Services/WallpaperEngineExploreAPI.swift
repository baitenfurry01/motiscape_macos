import Foundation

#if !STEAM_AGENT
final class WallpaperEngineExploreAPI {
    static let shared = WallpaperEngineExploreAPI()
    func fetch(force: Bool = false) async throws -> [WEExploreDefinition] {
        try await SteamAgentClient.shared.call(.explore(force: force))
    }
}

#endif

enum WallpaperEngineExploreError: LocalizedError {
    case invalidResponse
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return L("Wallpaper Engine 发现页返回了无效响应")
        case .httpError(let code): return L("Wallpaper Engine 发现页请求失败：HTTP %@", String(code))
        }
    }
}
