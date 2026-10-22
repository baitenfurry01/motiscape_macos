import Foundation

enum DynamicLockScreenMode: String { case extensionMode = "extension", screenSaver = "screenSaver" }
enum DynamicLockScreenModeStore {
    static var active: DynamicLockScreenMode? { WallpaperAgentClient.status.mode.flatMap(DynamicLockScreenMode.init(rawValue:)) }
}
