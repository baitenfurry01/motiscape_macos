import Foundation

/// Main-process transport. A request never falls back to launching Steam locally.
@MainActor
final class SteamAgentClient {
    static let shared = SteamAgentClient()
    private var preparedConnection: AgentConnection?
    private var preparedConfiguration: SteamAgentConfiguration?
    private var preparing: Task<Void, Error>?

    private func configuration() -> SteamAgentConfiguration {
        let settings = AppDelegate.shared.globalSettingsViewModel.settings
        var value = SteamAgentConfiguration()
        value.apiKey = settings.hasValidCustomSteamAPIKey ? settings.normalizedSteamAPIKey : ""
        value.apiBaseURL = settings.steamAPIEndpoint == .official ? "https://api.steampowered.com/" : "https://steams.524228.xyz/"
        value.proxy = AppHTTPProxy.runtime.settings
        value.downloadDirectory = WallpaperLibrary.shared.managedWorkshopDirectory
        value.previewDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "motiscape/SteamAgentPreviews", directoryHint: .isDirectory)
        return value
    }

    func call<T: Decodable>(_ operation: SteamAgentOperation) async throws -> T {
        guard let wire = PluginManager.shared.connection(for: .steam) else {
            throw AgentTransportError.message(L("Steam 服务插件未连接"))
        }
        let config = configuration()
        if preparedConnection !== wire || preparedConfiguration != config {
            if let preparing { try await preparing.value }
            if preparedConnection !== wire || preparedConfiguration != config {
                let task = Task { @MainActor in
                    let status: SteamAgentStatus = try await self.exchange(.configure(config), on: wire)
                    guard PluginManager.shared.connection(for: .steam) === wire else { throw CancellationError() }
                    self.preparedConnection = wire
                    self.preparedConfiguration = config
                    SteamServiceManager.shared.apply(status)
                }
                preparing = task
                do { try await task.value; preparing = nil }
                catch { preparing = nil; throw error }
            }
        }
        try Task.checkCancellation()
        return try await exchange(operation, on: wire)
    }

    private func exchange<T: Decodable>(_ operation: SteamAgentOperation, on wire: AgentConnection) async throws -> T {
        let request = SteamAgentRequest(id: UUID(), operation: operation)
        let payload = try JSONEncoder().encode(request)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let data = try await wire.request("steam.request", payload: payload, timeout: 60)
            try Task.checkCancellation()
            guard PluginManager.shared.connection(for: .steam) === wire else { throw CancellationError() }
            return data
        } onCancel: {
            if let id = try? JSONEncoder().encode(request.id) { wire.send("steam.cancel", payload: id) }
        }
        let response = try JSONDecoder().decode(SteamAgentEnvelope.self, from: result)
        if let error = response.apiError { throw error }
        if let error = response.serviceError { throw error }
        return try JSONDecoder().decode(T.self, from: response.payload)
    }
}
