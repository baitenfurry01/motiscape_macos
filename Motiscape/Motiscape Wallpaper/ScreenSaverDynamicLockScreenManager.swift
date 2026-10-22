import AppKit
import Combine
import Foundation

@MainActor
final class ScreenSaverDynamicLockScreenManager: ObservableObject {
    static let shared = ScreenSaverDynamicLockScreenManager()
    @Published private(set) var isEnabled = false
    @Published var isConfirmationPresented = false
    @Published private(set) var recoveryErrorMessage: String?
    private var status = WallpaperAgentStatus()
    func apply(_ value: WallpaperAgentStatus) {
        status = value; isEnabled = value.bEnabled; recoveryErrorMessage = value.bError
    }
    var isAvailable: Bool { if #available(macOS 14.2, *) { return true }; return false }
    var hasConfirmedWarning: Bool { status.bConfirmed }
    var canUse: Bool { status.bCanUse }
    var isConfigured: Bool { status.bConfigured }
    var configuredWallpaperTitle: String? { status.bTitle }
    func requestEnable() { guard isAvailable else { return }; isConfirmationPresented = true }
    func confirmAndEnable(input: String) -> Bool {
        guard input == "我同意" || input.caseInsensitiveCompare("Agree") == .orderedSame else { return false }
        var request = WallpaperAgentRequest(); request.input = input
        do { try WallpaperAgentClient.call("lockB.confirm", request); isConfirmationPresented = false; return true }
        catch { recoveryErrorMessage = error.localizedDescription; return false }
    }
    func setEnabled(_ enabled: Bool) {
        if enabled && !hasConfirmedWarning { requestEnable(); return }
        var request = WallpaperAgentRequest(); request.enabled = enabled; WallpaperAgentClient.send("lockB.enable", request)
    }
    func configureCurrentWallpaper(_ wallpaper: WEWallpaper, runtime: WallpaperRuntimeState,
        properties: [String: WEProjectProperty], fps: Int) async throws {
        let request = await WallpaperAgentClient.configuration(wallpaper: wallpaper, runtime: runtime, properties: properties, fps: fps)
        try await WallpaperAgentClient.request("lockB.configure", request)
    }
    func updateLoadFromMemory(_ enabled: Bool) {
        var request = WallpaperAgentRequest(); request.enabled = enabled; WallpaperAgentClient.send("lockB.memory", request)
    }
}
