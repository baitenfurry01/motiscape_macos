import Foundation

/// Every LibraryIndexActor for the same canonical directory shares this gate.
/// Synchronous database operations cannot suspend while holding the gate.
final class LibraryMetadataAccess: @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var registry: [String: LibraryMetadataAccess] = [:]
    private let mutex = NSRecursiveLock()
    private var needsRestart = false
    private var containerAttempted = false
    private let leaseFD: Int32
    let directory: URL

    static func shared(directory: URL) throws -> LibraryMetadataAccess {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[directory.path] { return existing }
        let access = try LibraryMetadataAccess(directory: directory)
        registry[directory.path] = access
        return access
    }

    private init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appending(path: ".metadata.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw LibraryMetadataError.unsafeFile }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1, status.st_mode & 0o077 == 0 else {
            close(fd); throw LibraryMetadataError.unsafeFile
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw LibraryMetadataError.inUse }
        leaseFD = fd
    }
    deinit { close(leaseFD) }

    func enter() throws {
        mutex.lock()
        if needsRestart { mutex.unlock(); throw LibraryMetadataError.restartRequired }
        var pending = stat()
        if lstat(directory.appending(path: LibraryMetadataRecovery.requestName).path, &pending) == 0 || errno != ENOENT {
            mutex.unlock(); throw LibraryMetadataError.maintenancePending
        }
    }
    func leave() { mutex.unlock() }
    // Call only while holding the gate, after a successful transaction save.
    func requireRestart() { needsRestart = true }
    func willOpenContainer() { containerAttempted = true }

    func enterMaintenance(requireUnopened: Bool) throws {
        mutex.lock()
        if requireUnopened && containerAttempted { mutex.unlock(); throw LibraryMetadataError.restartRequired }
    }

    func storeDirectory() throws -> URL { try LibraryMetadataRecovery(directory: directory).activeDirectory() }

    func validateStoreFiles() throws {
        let directory = try storeDirectory()
        for name in ["metadata.store", "metadata.store-wal", "metadata.store-shm"] {
            var status = stat()
            if lstat(directory.appending(path: name).path, &status) != 0 {
                if errno == ENOENT { continue }
                throw LibraryMetadataError.unsafeFile
            }
            guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_nlink == 1 else {
                throw LibraryMetadataError.unsafeFile
            }
        }
    }
}
