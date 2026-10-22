import Foundation
import Darwin

@_silgen_name("flock")
private func wallpaperAgentFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Durable session undo data belongs to the external agent. The main app never
/// reads or writes system wallpaper preferences.
final class WallpaperAgentSession {
    static let shared = WallpaperAgentSession()
    private let fm = FileManager.default
    private let supportDirectory: URL?
    init(supportDirectory: URL? = nil) { self.supportDirectory = supportDirectory }
    private var root: URL {
        (supportDirectory ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/motiscape"))
            .appendingPathComponent("WallpaperAgentSession")
    }
    private var store: URL { fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist") }
    private var marker: URL { root.appendingPathComponent("session.json") }
    private struct Record: Codable { var hadStore: Bool; var savers: [String: Bool] = [:] }
    private var record: Record?
    private var lockDescriptor: Int32 = -1
    deinit { if lockDescriptor >= 0 { Darwin.close(lockDescriptor) } }

    /// The lock lives outside the undo directory, which is removed after each
    /// successful restore. Keep its inode and ownership until this process exits.
    private func acquireSessionOwnership() throws {
        guard lockDescriptor < 0 else { return }
        let parent = root.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = parent.appendingPathComponent("WallpaperAgentSession.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard wallpaperAgentFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw NSError(domain: "WallpaperAgent", code: 5, userInfo: [
                NSLocalizedDescriptionKey: L("屏保与锁屏插件正在由另一个 motiscape 使用。请先退出另一个 motiscape。")
            ])
        }
        lockDescriptor = descriptor
    }
    private static let managedSaverPaths = [
        "Library/Screen Savers/motiscapeScreenSaver.saver",
        "Library/Screen Savers/motiscapeDynamicLockScreen.saver",
        "Library/Screen Savers/.motiscapeDynamicLockScreen.saver",
        "Library/Application Support/motiscape/Components/motiscapeDynamicLockScreen.saver"
    ]
    func recover() throws {
        try acquireSessionOwnership()
        if fm.fileExists(atPath: marker.path) {
            record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: marker))
            try restore()
        }
    }
    func begin() throws {
        try acquireSessionOwnership()
        guard record == nil else { return }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let exists = fm.fileExists(atPath: store.path)
        if exists { try Data(contentsOf: store).write(to: root.appendingPathComponent("Index.plist"), options: .atomic) }
        record = Record(hadStore: exists)
        try persist()
        try captureSaver()
        ScreenSaverManager.shared.prepareForAgentSession()
    }
    func captureSaver() throws {
        try begin()
        for (index, relative) in Self.managedSaverPaths.enumerated() {
            guard record?.savers[relative] == nil else { continue }
            let url = fm.homeDirectoryForCurrentUser.appendingPathComponent(relative)
            let exists = fm.fileExists(atPath: url.path)
            if exists {
                let backup = root.appendingPathComponent("saver-\(index)")
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
                try fm.copyItem(at: url, to: backup)
            }
            record?.savers[relative] = exists
            try persist()
        }
    }

    private func persist() throws { try JSONEncoder().encode(record).write(to: marker, options: .atomic) }
    func restore() throws {
        guard let record else { return }
        if fm.fileExists(atPath: store.path) {
            let original: Any? = record.hadStore
                ? try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("Index.plist")), format: nil)
                : nil
            let current = try PropertyListSerialization.propertyList(from: Data(contentsOf: store), format: nil)
            let restored = Self.restoreOwnedChoices(current, original: original)
            let data = try PropertyListSerialization.data(fromPropertyList: restored, format: .binary, options: 0)
            try data.write(to: store, options: .atomic)
        }
        // Stop the system hosts before replacing or removing their modules.
        try ScreenSaverManager.shared.terminateScreenSaverServices(restartWallpaperAgent: false)
        for (index, relative) in Self.managedSaverPaths.enumerated() {
            guard let existed = record.savers[relative] else { continue }
            let target = fm.homeDirectoryForCurrentUser.appendingPathComponent(relative)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            if existed {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: root.appendingPathComponent("saver-\(index)"), to: target)
            }
        }
        try ScreenSaverManager.shared.restartForWallpaperStoreChange()
        try fm.removeItem(at: root)
        self.record = nil
    }
    static func restoreOwnedChoices(_ current: Any, original: Any?) -> Any {
        if let dictionary = current as? [String: Any] {
            let previous = original as? [String: Any]
            var result = dictionary
            for (key, value) in dictionary {
                if ["Desktop", "Idle"].contains(key), containsOwnedChoice(value) {
                    if let saved = previous?[key] { result[key] = saved }
                    else { result.removeValue(forKey: key) }
                } else { result[key] = restoreOwnedChoices(value, original: previous?[key]) }
            }
            return result
        }
        if let values = current as? [Any] {
            let previous = original as? [Any]
            return values.enumerated().map { index, item in
                restoreOwnedChoices(item, original: previous.flatMap { index < $0.count ? $0[index] : nil })
            }
        }
        return current
    }
    private static func containsOwnedChoice(_ value: Any) -> Bool {
        if let text = value as? String {
            return text.contains("com.BaiTenG.motiscape.WallpaperExtension")
                || text.contains("com.BaiTenG.motiscape.Development.WallpaperExtension")
                || text.contains("motiscapeScreenSaver.saver") || text.contains("motiscapeDynamicLockScreen.saver")
        }
        if let data = value as? Data,
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) { return containsOwnedChoice(plist) }
        if let dictionary = value as? [String: Any] { return dictionary.values.contains(where: containsOwnedChoice) }
        if let array = value as? [Any] { return array.contains(where: containsOwnedChoice) }
        return false
    }
}
