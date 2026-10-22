import AppKit
import Combine
import Foundation

@MainActor
final class DynamicLockScreenManager: ObservableObject {
    static let shared = DynamicLockScreenManager()
    @Published private(set) var isEnabled = false
    @Published var isConfirmationPresented = false
    @Published private(set) var registrationErrorMessage: String?
    @Published private(set) var connectionState = ConnectionState.disabled
    enum ConnectionState: String { case disabled, needsWallpaper, preparing, awaitingSystemSettings, awaitingSelection, connected, ready, failed }
    private var status = WallpaperAgentStatus()
    func apply(_ value: WallpaperAgentStatus) {
        status = value; isEnabled = value.aEnabled; registrationErrorMessage = value.aError
        connectionState = ConnectionState(rawValue: value.aState) ?? .disabled
    }
    var connectionStatusMessage: String {
        switch connectionState {
        case .disabled: return L("动态锁屏已关闭")
        case .needsWallpaper: return L("已启用，请设置锁屏壁纸")
        case .preparing: return L("正在连接动态锁屏")
        case .awaitingSystemSettings: return L("请打开系统墙纸设置以载入动态锁屏")
        case .awaitingSelection: return L("动态锁屏已载入，请在系统墙纸设置中选择 Motiscape")
        case .connected: return L("动态锁屏已连接，等待画面就绪")
        case .ready: return L("动态锁屏已就绪")
        case .failed: return L("动态锁屏恢复失败")
        }
    }

    var canRetryConnection: Bool {
        switch connectionState {
        case .awaitingSystemSettings, .awaitingSelection, .connected, .failed: return true
        default: return false
        }
    }

    var isAvailable: Bool { if #available(macOS 26, *) { return true }; return false }
    var hasConfirmedWarning: Bool { status.aConfirmed }
    var canUse: Bool { status.aCanUse }
    var isConfigured: Bool { status.aConfigured }
    var configuredWallpaperTitle: String? { status.aTitle }
    func requestEnable() { guard isAvailable else { return }; isConfirmationPresented = true }
    func confirmAndEnable(input: String) -> Bool {
        guard input == "我同意" || input.caseInsensitiveCompare("Agree") == .orderedSame else { return false }
        var request = WallpaperAgentRequest(); request.input = input
        do { try WallpaperAgentClient.call("lockA.confirm", request); isConfirmationPresented = false; return true }
        catch { registrationErrorMessage = error.localizedDescription; return false }
    }
    func setEnabled(_ enabled: Bool) {
        if enabled && !hasConfirmedWarning { requestEnable(); return }
        var request = WallpaperAgentRequest(); request.enabled = enabled
        WallpaperAgentClient.send("lockA.enable", request)
    }
    func configureCurrentWallpaper(_ wallpaper: WEWallpaper, runtime: WallpaperRuntimeState,
        properties: [String: WEProjectProperty], fps: Int, displayIDs: [UInt32]) async throws {
        var request = await WallpaperAgentClient.configuration(wallpaper: wallpaper, runtime: runtime, properties: properties, fps: fps)
        request.displayIDs = displayIDs
        try await WallpaperAgentClient.request("lockA.configure", request)
    }
    func updateRuntime(_ snapshot: WallpaperRenderSnapshot, wallpaper: WEWallpaper, displayKey: String, displayID: UInt32) {
        var request = WallpaperAgentRequest(); request.snapshot = snapshot; request.wallpaper = wallpaper
        request.displayKey = displayKey; request.displayID = displayID
        WallpaperAgentClient.send("lockA.runtime", request)
    }
    func updatePosition(_ position: WallpaperPosition, fillMode: FillMode, wallpaperID: String, displayID: UInt32) {
        var request = WallpaperAgentRequest(); request.position = position; request.fillMode = fillMode
        request.input = wallpaperID; request.displayID = displayID; WallpaperAgentClient.send("lockA.position", request)
    }
    func updateLoadFromMemory(_ enabled: Bool) {
        var request = WallpaperAgentRequest(); request.enabled = enabled; WallpaperAgentClient.send("lockA.memory", request)
    }
    func flushConfigurationUpdates() { WallpaperAgentClient.send("flush") }
    func refreshDesktopFallback(forDisplay displayID: UInt32) {
        guard let source = DesktopOverrideService.shared.dynamicLockScreenFallbackURL(forDisplay: displayID) else { return }
        _ = try? updateDesktopFallback(from: source, forDisplay: displayID)
    }
    func refreshDesktopFallbacks() { WallpaperAgentClient.send("lockA.fallbacks") }
    func updateDesktopFallback(from source: URL, forDisplay displayID: UInt32) throws -> Bool {
        guard isConfigured else { return false }
        var request = WallpaperAgentRequest(); request.source = source; request.displayID = displayID
        try WallpaperAgentClient.call("lockA.fallback", request); return true
    }
    func restoreSystemDesktopFallbacks() { WallpaperAgentClient.send("lockA.restoreFallbacks") }
    func clearConfiguration() { WallpaperAgentClient.send("lockA.clear") }
    func openSystemSettings() { WallpaperAgentClient.send("lockA.settings") }
    func openFullDiskAccessSettings() { WallpaperAgentClient.send("lockA.permissions") }
    func retryConnection() { WallpaperAgentClient.send("lockA.retry") }
    func refreshExtension() { WallpaperAgentClient.send("lockA.refresh") }
}
