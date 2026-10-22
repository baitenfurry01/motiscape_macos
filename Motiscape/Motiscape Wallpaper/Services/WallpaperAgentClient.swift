import AppKit
import Foundation

/// Proxies retain only the latest declaration of the remote feature state.
enum WallpaperAgentClient {
    private static let lock = NSLock()
    private static var latest = WallpaperAgentStatus()
    static var status: WallpaperAgentStatus { lock.lock(); defer { lock.unlock() }; return latest }
    static func receive(_ data: Data) {
        guard let status = try? JSONDecoder().decode(WallpaperAgentStatus.self, from: data) else { return }
        lock.lock(); latest = status; lock.unlock()
        let apply: @MainActor () -> Void = {
            DynamicLockScreenManager.shared.apply(status)
            ScreenSaverDynamicLockScreenManager.shared.apply(status)
        }
        if Thread.isMainThread { MainActor.assumeIsolated { apply() } }
        else { DispatchQueue.main.async(execute: apply) }
    }
    static func disconnected() { receive((try? JSONEncoder().encode(WallpaperAgentStatus())) ?? Data()) }
    static func call(_ method: String, _ request: WallpaperAgentRequest = .init()) throws {
        guard let connection = PluginManager.shared.connection(for: .wallpaper) else {
            throw NSError(domain: "WallpaperAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: L("屏保与锁屏插件未连接")])
        }
        let data = try connection.requestSync(method, payload: JSONEncoder().encode(request), timeout: 60)
        if !data.isEmpty { receive(data) }
    }
    static func send(_ method: String, _ request: WallpaperAgentRequest = .init()) {
        guard let data = try? JSONEncoder().encode(request) else { return }
        PluginManager.shared.connection(for: .wallpaper)?.send(method, payload: data)
    }
    static func request(_ method: String, _ request: WallpaperAgentRequest = .init()) async throws {
        guard let connection = PluginManager.shared.connection(for: .wallpaper) else {
            throw NSError(domain: "WallpaperAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: L("屏保与锁屏插件未连接")])
        }
        do {
            let data = try await connection.request(method, payload: JSONEncoder().encode(request), timeout: 120)
            if !data.isEmpty { receive(data) }
        } catch AgentTransportError.message("wallpaper.fullDiskAccessRequired") {
            throw DynamicLockScreenError.fullDiskAccessRequired
        }
    }
    @MainActor static func configuration(wallpaper: WEWallpaper, runtime: WallpaperRuntimeState,
        properties: [String: WEProjectProperty], fps: Int) async -> WallpaperAgentRequest {
        await AppDelegate.shared.wallpaperViewModel.refreshScriptStorage(for: wallpaper)
        var request = WallpaperAgentRequest()
        request.wallpaper = wallpaper; request.runtime = runtime; request.properties = WallpaperViewModel.resolveProperties(properties, for: wallpaper)
        request.context = .init(wallpaperID: wallpaper.id, runtime: runtime, fps: fps)
        request.fallbacks = [:]; request.systemFallbacks = [:]; request.activeStates = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
            if let key = DisplayRegistry.shared.info(forDisplay: id)?.key {
                request.activeStates?[key.rawValue] = AppDelegate.shared.wallpaperViewModel.state(for: key)
            }
            request.fallbacks?[String(id)] = DesktopOverrideService.shared.dynamicLockScreenFallbackURL(forDisplay: id)
            request.systemFallbacks?[String(id)] = DesktopOverrideService.shared.dynamicLockScreenSystemFallbackURL(forDisplay: id)
        }
        return request
    }
}

/// Renderer snapshots are data supplied by the main app; the agent never owns
/// or starts the desktop renderer.
enum WallpaperAgentHost {
    private static var previews: [UUID: String] = [:]
    static func handle(_ command: String, payload: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        Task { @MainActor in
            do {
                switch command {
                case "host.prepareLock":
                    let prepared = await AppDelegate.shared.wallpaperViewModel.prepareForExternalLockScreen()
                    completion(.success(try JSONEncoder().encode(prepared)))
                case "host.resume":
                    AppDelegate.shared.wallpaperViewModel.resumeAfterExternalLockScreen()
                    completion(.success(Data()))
                case "host.preview":
                    let value = try JSONDecoder().decode(WallpaperAgentPreview.self, from: payload)
                    let renderer = AppDelegate.shared.wallpaperViewModel.renderer
                    let finished: (Bool) -> Void = { success in
                        previews.removeValue(forKey: value.token)
                        completion(Result { try JSONEncoder().encode(success) })
                    }
                    if let wallpaper = value.wallpaper, let options = value.options {
                        previews[value.token] = renderer.snapshot(wallpaper: wallpaper, onDisplay: value.displayID,
                            options: options, path: value.path, completion: finished)
                    } else {
                        guard let expected = value.expectedState,
                              let key = DisplayRegistry.shared.info(forDisplay: value.displayID)?.key,
                              AppDelegate.shared.wallpaperViewModel.state(for: key) == expected else {
                            finished(false); return
                        }
                        renderer.snapshot(onDisplay: value.displayID, path: value.path, completion: finished)
                    }
                case "host.cancelPreview":
                    let token = try JSONDecoder().decode(UUID.self, from: payload)
                    if let id = previews.removeValue(forKey: token) { AppDelegate.shared.wallpaperViewModel.renderer.cancelPreview(id) }
                    completion(.success(Data()))
                default:
                    throw NSError(domain: "WallpaperAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Unknown host request")])
                }
            } catch { completion(.failure(error)) }
        }
    }
}
