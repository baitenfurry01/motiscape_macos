import Foundation
import CryptoKit

enum ZIPWorkspaceError: LocalizedError {
    case unsafe, active, changed, noSource
    var errorDescription: String? {
        switch self {
        case .unsafe: return L("ZIP 工作区归属或路径无法验证，已保留原文件。")
        case .active: return L("此 ZIP 工作区仍在使用，请稍后重新检查。")
        case .changed: return L("ZIP 工作区在检查后发生变化，请刷新后重新确认。")
        case .noSource: return L("没有可验证的源 ZIP，无法恢复预检；快照仍保留。")
        }
    }
}

struct ZIPWorkspaceRecord: Codable, Sendable {
    enum State: String, Codable, Sendable { case preparing, extracting, ready }
    var version = 1
    var id: String
    var libraryRoot: String
    var source: String
    var fingerprint: String?
    var state: State
    var createdAt: Date
    var updatedAt: Date

    func validate(id expected: String) throws {
        guard version == 1, id == expected, UUID(uuidString: id) != nil,
              libraryRoot.hasPrefix("/"), source.hasPrefix("/"), !source.contains("\0"),
              !libraryRoot.contains("\0"), URL(fileURLWithPath: source).pathExtension.lowercased() == "zip",
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              fingerprint.map({ $0.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) ?? true,
              state == .preparing || fingerprint != nil else { throw ZIPWorkspaceError.unsafe }
    }
}

struct ZIPWorkspaceSnapshot: Identifiable, Sendable {
    let id: String
    let path: String
    let record: ZIPWorkspaceRecord?
    let token: String?
    let issue: String?
    var canDiscard: Bool { record != nil && token != nil && issue == nil }
    var canRecover: Bool { canDiscard && record?.fingerprint != nil }
}

struct ZIPWorkspaceInventory: Sendable {
    var items: [ZIPWorkspaceSnapshot] = []
    var activeCount = 0
}

/// File descriptors anchor ownership and deletion. No record-supplied path is
/// ever used as a cleanup target; only a UUID child of this private root is used.
struct ZIPWorkspaceStore: Sendable {
    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "motiscape/LibraryMetadata/ZIPWorkspaces")
    }
    let root: URL
    private static let marker = Data("Motiscape ZIP workspace root v1\n".utf8)

    init(root: URL) { self.root = root.standardizedFileURL }

    func prepareRoot() throws { let fd = try openRoot(create: true); close(fd) }

    func create(source: URL, libraryRoot: URL) throws -> ZIPWorkspaceLease {
        let rootFD = try openRoot(create: true)
        defer { close(rootFD) }
        let id = UUID().uuidString
        guard mkdirat(rootFD, id, 0o700) == 0 else { throw ZIPWorkspaceError.unsafe }
        let directoryFD = openat(rootFD, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ZIPWorkspaceError.unsafe }
        let lockFD = openat(directoryFD, "lease", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { close(directoryFD); throw ZIPWorkspaceError.unsafe }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); close(directoryFD); throw ZIPWorkspaceError.active }
        let now = Date()
        let record = ZIPWorkspaceRecord(id: id, libraryRoot: LibraryIndexPath.identity(libraryRoot.path),
            source: source.standardizedFileURL.path, state: .preparing, createdAt: now, updatedAt: now)
        let lease = ZIPWorkspaceLease(store: self, id: id, directoryFD: directoryFD, lockFD: lockFD, record: record)
        do { try lease.write(record); return lease }
        catch { try? lease.discard(); throw error }
    }

    func inventory(libraryRoot: URL? = nil) throws -> ZIPWorkspaceInventory {
        // Read-only checks do not create empty cache roots during startup.
        var status = stat()
        if lstat(root.path, &status) != 0 {
            if errno == ENOENT { return ZIPWorkspaceInventory() }
            throw ZIPWorkspaceError.unsafe
        }
        let rootFD = try openRoot(create: false)
        defer { close(rootFD) }
        var result = ZIPWorkspaceInventory()
        for name in try Self.names(rootFD).sorted() where name != ".owner" && name != ".lock" {
            try Task.checkCancellation()
            let path = root.appending(path: name).path
            do {
                guard UUID(uuidString: name) != nil else { throw ZIPWorkspaceError.unsafe }
                let lease = try acquire(id: name, rootFD: rootFD)
                let record = lease.record
                if let libraryRoot, record.libraryRoot != LibraryIndexPath.identity(libraryRoot.path) { continue }
                result.items.append(.init(id: name, path: path, record: record, token: try lease.token(), issue: nil))
            } catch ZIPWorkspaceError.active { result.activeCount += 1 }
            catch { result.items.append(.init(id: name, path: path, record: nil, token: nil, issue: error.localizedDescription)) }
        }
        return result
    }

    func acquire(_ snapshot: ZIPWorkspaceSnapshot, libraryRoot: URL) throws -> ZIPWorkspaceLease {
        guard snapshot.canDiscard, snapshot.path == root.appending(path: snapshot.id).path else { throw ZIPWorkspaceError.unsafe }
        let rootFD = try openRoot(create: false)
        defer { close(rootFD) }
        let lease = try acquire(id: snapshot.id, rootFD: rootFD)
        guard lease.record.libraryRoot == LibraryIndexPath.identity(libraryRoot.path),
              try lease.token() == snapshot.token else { throw ZIPWorkspaceError.changed }
        return lease
    }

    private func acquire(id: String, rootFD: Int32) throws -> ZIPWorkspaceLease {
        guard UUID(uuidString: id) != nil else { throw ZIPWorkspaceError.unsafe }
        let directoryFD = openat(rootFD, id, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ZIPWorkspaceError.unsafe }
        var ownsDirectory = true
        defer { if ownsDirectory { close(directoryFD) } }
        try Self.verify(directoryFD, directory: true)
        let lockFD = openat(directoryFD, "lease", O_RDWR | O_NOFOLLOW | O_NONBLOCK)
        guard lockFD >= 0 else { throw ZIPWorkspaceError.unsafe }
        var ownsLock = true
        defer { if ownsLock { close(lockFD) } }
        try Self.verify(lockFD, directory: false)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw ZIPWorkspaceError.active }
            throw ZIPWorkspaceError.unsafe
        }
        let data = try Self.read("workspace.json", in: directoryFD)
        let record = try JSONDecoder().decode(ZIPWorkspaceRecord.self, from: data)
        try record.validate(id: id)
        ownsDirectory = false; ownsLock = false
        return ZIPWorkspaceLease(store: self, id: id, directoryFD: directoryFD, lockFD: lockFD, record: record)
    }

    fileprivate func openRoot(create: Bool) throws -> Int32 {
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else { throw ZIPWorkspaceError.unsafe }
        if create { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ZIPWorkspaceError.unsafe }
        var succeeded = false
        defer { if !succeeded { close(fd) } }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid() else { throw ZIPWorkspaceError.unsafe }
        let lock = openat(fd, ".lock", (create ? O_CREAT : 0) | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw ZIPWorkspaceError.unsafe }
        defer { close(lock) }
        try Self.verify(lock, directory: false)
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw ZIPWorkspaceError.active }
            throw ZIPWorkspaceError.unsafe
        }
        var markerStatus = stat()
        if fstatat(fd, ".owner", &markerStatus, AT_SYMLINK_NOFOLLOW) != 0 {
            guard create, errno == ENOENT, try Self.names(fd).allSatisfy({ $0 == ".lock" }) else { throw ZIPWorkspaceError.unsafe }
            guard fchmod(fd, 0o700) == 0 else { throw ZIPWorkspaceError.unsafe }
            let markerFD = openat(fd, ".owner", O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard markerFD >= 0 else { throw ZIPWorkspaceError.unsafe }
            let handle = FileHandle(fileDescriptor: markerFD, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: Self.marker); try handle.synchronize()
        }
        try Self.verify(fd, directory: true)
        guard try Self.read(".owner", in: fd) == Self.marker else { throw ZIPWorkspaceError.unsafe }
        succeeded = true
        return fd
    }

    fileprivate static func verify(_ fd: Int32, directory: Bool) throws {
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o077 == 0,
              status.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG), directory || status.st_nlink == 1 else {
            throw ZIPWorkspaceError.unsafe
        }
    }

    fileprivate static func read(_ name: String, in directoryFD: Int32) throws -> Data {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ZIPWorkspaceError.unsafe }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try verify(fd, directory: false)
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_size > 0, status.st_size <= 64 * 1024,
              let data = try handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024 else { throw ZIPWorkspaceError.unsafe }
        return data
    }

    fileprivate static func names(_ fd: Int32) throws -> [String] {
        // A fresh open file description avoids sharing a directory seek offset.
        let copy = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard copy >= 0 else { throw ZIPWorkspaceError.unsafe }
        guard let directory = fdopendir(copy) else { close(copy); throw ZIPWorkspaceError.unsafe }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { result.append(name) }
        }
        guard errno == 0 else { throw ZIPWorkspaceError.unsafe }
        return result
    }

    fileprivate static func checkContents(_ fd: Int32, depth: Int = 0) throws {
        guard depth <= 40 else { throw ZIPWorkspaceError.unsafe }
        for name in try names(fd) {
            var status = stat()
            guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw ZIPWorkspaceError.changed }
            if status.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw ZIPWorkspaceError.unsafe }
                defer { close(child) }
                try checkContents(child, depth: depth + 1)
            } else if status.st_mode & S_IFMT != S_IFREG { throw ZIPWorkspaceError.unsafe }
        }
    }

    fileprivate static func removeContents(_ fd: Int32, depth: Int = 0) throws {
        guard depth <= 40 else { throw ZIPWorkspaceError.unsafe }
        // Keep the ownership/lease files until all disposable data was removed.
        let entries = try names(fd).sorted { lhs, rhs in
            let leftLast = lhs == "workspace.json" || lhs == "lease"
            let rightLast = rhs == "workspace.json" || rhs == "lease"
            return leftLast == rightLast ? lhs < rhs : !leftLast
        }
        for name in entries {
            var status = stat()
            guard fstatat(fd, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else { throw ZIPWorkspaceError.changed }
            if status.st_mode & S_IFMT == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard child >= 0 else { throw ZIPWorkspaceError.unsafe }
                defer { close(child) }
                var opened = stat()
                guard fstat(child, &opened) == 0, opened.st_ino == status.st_ino, opened.st_dev == status.st_dev else { throw ZIPWorkspaceError.changed }
                try removeContents(child, depth: depth + 1)
                guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw ZIPWorkspaceError.changed }
            } else if status.st_mode & S_IFMT == S_IFREG {
                guard unlinkat(fd, name, 0) == 0 else { throw ZIPWorkspaceError.changed }
            } else {
                // Do not traverse links or special nodes introduced after extraction.
                throw ZIPWorkspaceError.unsafe
            }
        }
    }
}

/// The lock is held from creation through extraction and review, and released
/// by process termination as well as normal deinitialization. No PID guessing.
final class ZIPWorkspaceLease: @unchecked Sendable {
    let store: ZIPWorkspaceStore
    let id: String
    let directoryFD: Int32
    private var lockFD: Int32
    private let mutex = NSRecursiveLock()
    private var currentRecord: ZIPWorkspaceRecord
    var record: ZIPWorkspaceRecord { mutex.lock(); defer { mutex.unlock() }; return currentRecord }
    var workspace: URL { store.root.appending(path: id) }

    fileprivate init(store: ZIPWorkspaceStore, id: String, directoryFD: Int32, lockFD: Int32, record: ZIPWorkspaceRecord) {
        self.store = store; self.id = id; self.directoryFD = directoryFD; self.lockFD = lockFD; self.currentRecord = record
    }
    deinit { if lockFD >= 0 { close(lockFD) }; close(directoryFD) }

    func update(state: ZIPWorkspaceRecord.State, fingerprint: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        var next = record; next.state = state; next.fingerprint = fingerprint; next.updatedAt = Date()
        try write(next)
    }

    fileprivate func write(_ next: ZIPWorkspaceRecord) throws {
        mutex.lock(); defer { mutex.unlock() }
        try next.validate(id: id)
        guard lockFD >= 0 else { throw ZIPWorkspaceError.changed }
        let name = "record-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ZIPWorkspaceError.unsafe }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(next)); try handle.synchronize()
        guard renameat(directoryFD, name, directoryFD, "workspace.json") == 0 else { throw ZIPWorkspaceError.unsafe }
        currentRecord = next
    }

    func validateLocation() throws {
        mutex.lock(); defer { mutex.unlock() }
        try verifyLocation()
    }

    private func directory(_ components: [String]) throws -> Int32 {
        var fd = dup(directoryFD)
        guard fd >= 0 else { throw ZIPWorkspaceError.unsafe }
        do {
            for component in components {
                guard !component.isEmpty, component != ".", component != "..", !component.contains("/"), !component.contains("\0") else { throw ZIPWorkspaceError.unsafe }
                if mkdirat(fd, component, 0o700) != 0, errno != EEXIST { throw ZIPWorkspaceError.unsafe }
                let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                guard next >= 0 else { throw ZIPWorkspaceError.unsafe }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    func makeDirectory(_ path: String) throws {
        mutex.lock(); defer { mutex.unlock() }
        try verifyLocation()
        let fd = try directory(path.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
        close(fd)
    }

    func createFile(_ path: String) throws -> Int32 {
        mutex.lock(); defer { mutex.unlock() }
        try verifyLocation()
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.last, !name.isEmpty, name != ".", name != "..", !name.contains("\0") else { throw ZIPWorkspaceError.unsafe }
        let parent = try directory(Array(parts.dropLast()))
        defer { close(parent) }
        let fd = openat(parent, name, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ZIPWorkspaceError.unsafe }
        return fd
    }

    func removeCompressedSnapshot() throws {
        mutex.lock(); defer { mutex.unlock() }
        try verifyLocation()
        guard unlinkat(directoryFD, "source.zip", 0) == 0 else { throw ZIPWorkspaceError.changed }
    }

    func token() throws -> String {
        mutex.lock(); defer { mutex.unlock() }
        try verifyLocation()
        var status = stat(); guard fstat(directoryFD, &status) == 0 else { throw ZIPWorkspaceError.unsafe }
        let hash = SHA256.hash(data: try ZIPWorkspaceStore.read("workspace.json", in: directoryFD))
            .map { String(format: "%02x", $0) }.joined()
        return "\(status.st_dev):\(status.st_ino):\(hash)"
    }

    private func verifyLocation() throws {
        guard lockFD >= 0 else { throw ZIPWorkspaceError.changed }
        let rootFD = try store.openRoot(create: false)
        defer { close(rootFD) }
        var expected = stat(), actual = stat(), lock = stat(), lockAtPath = stat()
        guard fstat(directoryFD, &expected) == 0, fstatat(rootFD, id, &actual, AT_SYMLINK_NOFOLLOW) == 0,
              actual.st_mode & S_IFMT == S_IFDIR, expected.st_ino == actual.st_ino, expected.st_dev == actual.st_dev,
              fstat(lockFD, &lock) == 0, fstatat(directoryFD, "lease", &lockAtPath, AT_SYMLINK_NOFOLLOW) == 0,
              lock.st_ino == lockAtPath.st_ino, lock.st_dev == lockAtPath.st_dev, lock.st_nlink == 1 else { throw ZIPWorkspaceError.changed }
    }

    func discard() throws {
        mutex.lock(); defer { mutex.unlock() }
        try verifyLocation()
        let rootFD = try store.openRoot(create: false)
        defer { close(rootFD) }
        try ZIPWorkspaceStore.checkContents(directoryFD)
        try ZIPWorkspaceStore.removeContents(directoryFD)
        var expected = stat(), actual = stat()
        guard fstat(directoryFD, &expected) == 0, fstatat(rootFD, id, &actual, AT_SYMLINK_NOFOLLOW) == 0,
              expected.st_ino == actual.st_ino, expected.st_dev == actual.st_dev,
              actual.st_mode & S_IFMT == S_IFDIR else { throw ZIPWorkspaceError.changed }
        guard unlinkat(rootFD, id, AT_REMOVEDIR) == 0 else { throw ZIPWorkspaceError.changed }
        close(lockFD); lockFD = -1
    }
}
