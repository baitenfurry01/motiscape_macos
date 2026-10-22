import CryptoKit
import Foundation

enum MotiscapeLockBridge {
    #if DEBUG
    static let groupID = "group.com.BaiTenG.motiscape.Development"
    private static let notificationPrefix = "com.BaiTenG.motiscape.Development.dynamicLockScreen"
    #else
    static let groupID = "group.com.BaiTenG.motiscape"
    private static let notificationPrefix = "com.BaiTenG.motiscape.dynamicLockScreen"
    #endif
    static let configurationName = "dynamic-lock-screen.json"
    static let probeNotification = notificationPrefix + ".probe"
    static let statusNotification = notificationPrefix + ".status"
    static let configurationNotification = notificationPrefix + ".configurationChanged"
    static let previewNotification = notificationPrefix + ".previewChanged"
    static let desktopFallbackNotification = notificationPrefix + ".desktopFallbackChanged"
    static let lockedNotification = notificationPrefix + ".locked"
    static let unlockedNotification = notificationPrefix + ".unlocked"
    static let wakeNotification = notificationPrefix + ".wake"
    static let sleepNotification = notificationPrefix + ".sleep"

    static func containerURL() throws -> URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            throw failure("Shared container is unavailable")
        }
        return url
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "motiscape.WallpaperExtension", code: 10,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func fingerprint(at extensionURL: URL) throws -> String {
        let fm = FileManager.default
        let paths = [
            "Contents/Info.plist",
            "Contents/MacOS/motiscapeWallpaperExtension"
        ]
        var hasher = SHA256()
        for path in paths {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: try Data(contentsOf: extensionURL.appendingPathComponent(path), options: .mappedIfSafe))
        }
        let contents = extensionURL.appendingPathComponent("Contents", isDirectory: true)
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: contents.appendingPathComponent("Resources/assets").path,
                            isDirectory: &directory), directory.boolValue else {
            throw failure("Wallpaper extension scene resources are missing")
        }
        for path in ["Frameworks/libMotiscapeSceneSaver.dylib", "Resources/vulkan/icd.d/MoltenVK_icd.json",
                     "Resources/MoltenVK/manifest.json", "Resources/scene-runtime.json"] {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: try Data(contentsOf: contents.appendingPathComponent(path), options: .mappedIfSafe))
        }
        let signature = extensionURL.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        if fm.fileExists(atPath: signature.path) {
            hasher.update(data: try Data(contentsOf: signature, options: .mappedIfSafe))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func runtimeDirectory(in container: URL) -> URL {
        container.appendingPathComponent("DynamicLockScreen/Runtime", isDirectory: true)
    }

    static func readProbe(in container: URL) throws -> MotiscapeLockProbe {
        try JSONDecoder().decode(MotiscapeLockProbe.self, from: Data(contentsOf:
            runtimeDirectory(in: container).appendingPathComponent("probe.json")))
    }

    static func writeProbe(_ probe: MotiscapeLockProbe, in container: URL) throws {
        let directory = runtimeDirectory(in: container)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(probe).write(to: directory.appendingPathComponent("probe.json"), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("status-") {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               date < Date().addingTimeInterval(-86_400) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    static func readReports(in container: URL) -> [MotiscapeLockReport] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: runtimeDirectory(in: container), includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("status-") }.compactMap {
            guard let data = try? Data(contentsOf: $0) else { return nil }
            return try? JSONDecoder().decode(MotiscapeLockReport.self, from: data)
        }
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }
}

struct MotiscapeLockProbe: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let configurationDigest: String

    init(configurationData: Data) {
        id = UUID()
        createdAt = Date()
        configurationDigest = MotiscapeLockBridge.digest(configurationData)
    }
}

struct MotiscapeLockReport: Codable {
    let probeID: UUID
    let instanceID: UUID
    let processID: Int32
    let extensionPath: String
    let fingerprint: String
    let version: String
    let configurationDigest: String?
    let settingsReady: Bool
    let readyDisplayIDs: [UInt32]
    let error: String?

    func matches(_ probe: MotiscapeLockProbe, extensionURL: URL, fingerprint expected: String) -> Bool {
        probeID == probe.id && fingerprint == expected
            && extensionPath == MotiscapeLockBridge.normalizedPath(extensionURL)
            && configurationDigest == probe.configurationDigest
    }

    func write(in container: URL) throws {
        let url = MotiscapeLockBridge.runtimeDirectory(in: container)
            .appendingPathComponent("status-\(instanceID.uuidString).json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        MotiscapeLockBridge.post(MotiscapeLockBridge.statusNotification)
    }
}
