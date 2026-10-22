import Foundation
import CryptoKit
import SwiftData

/// An offline, journaled generation switch. Original SQLite/WAL/SHM are never
/// moved or removed. The main app must not create any ModelContainer first.
struct LibraryMetadataRecovery: Sendable {
    static let requestName = "maintenance-request.json"
    static let pointerName = "current-store.json"
    static let fileNames = ["metadata.store", "metadata.store-wal", "metadata.store-shm"]
    struct FileRecord: Codable, Sendable, Equatable {
        var name: String
        var bytes: Int64
        var sha256: String
    }
    struct Request: Codable, Sendable {
        enum Phase: String, Codable, Sendable { case requested, copying, preserved, switched, rolledBack, cancelled }
        var version = 1
        var id: String
        var sourceGeneration: String?
        var phase: Phase = .requested
        var files: [FileRecord] = []
        var createdAt = Date()
    }
    private struct Pointer: Codable {
        var version = 1
        var generation: String
    }
    let directory: URL
    var requestURL: URL { directory.appending(path: Self.requestName) }

    static var defaultDirectory: URL {
        if let fixture = AppIntegrationFixture.metadataDirectory { return fixture }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "motiscape/LibraryMetadata")
    }
    static var needsMaintenanceStartup: Bool {
        var status = stat()
        // A malformed/linked request also routes to maintenance, never normal writes.
        return lstat(defaultDirectory.appending(path: requestName).path, &status) == 0
    }

    private func checkedDirectory(_ url: URL, create: Bool = false) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw LibraryMetadataError.unsafeFile }
        var components = Array(url.pathComponents.dropFirst())
        guard !components.contains("."), !components.contains("..") else { throw LibraryMetadataError.unsafeFile }
        // Foundation canonicalizes /private/var back to /var on macOS. Permit
        // only these verified system aliases; user-controlled ancestors still
        // go through O_NOFOLLOW at every level, including nonexistent leaves.
        if let first = components.first, first == "var" || first == "tmp" {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: "/" + first)
            guard destination == "/private/" + first || destination == "private/" + first else {
                throw LibraryMetadataError.unsafeFile
            }
            components.insert("private", at: 0)
        }
        // resolvingSymlinksInPath may leave a symlink ancestor unresolved when
        // its descendants do not exist. Walk from / using no-follow descriptors
        // before mkdir, rather than creating through a guessed canonical path.
        // Only traversal is needed here. O_RDONLY asks to read ancestor
        // directory contents, which App Sandbox denies outside its container.
        // O_SEARCH includes O_DIRECTORY and preserves the no-follow walk.
        var fd = open("/", O_SEARCH | O_NOFOLLOW)
        guard fd >= 0 else { throw LibraryMetadataError.unsafeFile }
        defer { close(fd) }
        for component in components {
            var next = openat(fd, component, O_SEARCH | O_NOFOLLOW)
            if next < 0, errno == ENOENT, create {
                guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw LibraryMetadataError.unsafeFile }
                next = openat(fd, component, O_SEARCH | O_NOFOLLOW)
            }
            guard next >= 0 else { throw LibraryMetadataError.unsafeFile }
            close(fd); fd = next
        }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid() else {
            throw LibraryMetadataError.unsafeFile
        }
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try checkedDirectory(url.deletingLastPathComponent())
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_nlink == 1, status.st_size <= 1024 * 1024 else {
            throw LibraryMetadataError.unsafeFile
        }
        return try JSONDecoder().decode(type, from: LibraryMetadataBackup.read(url))
    }

    private func write<T: Encodable>(_ value: T, at url: URL) throws {
        try checkedDirectory(url.deletingLastPathComponent())
        try LibraryMetadataBackup.write(JSONEncoder().encode(value), to: url)
    }

    private func generation() throws -> String? {
        let url = directory.appending(path: Self.pointerName)
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return nil }
            throw LibraryMetadataError.unsafeFile
        }
        let pointer = try read(Pointer.self, at: url)
        guard pointer.version == 1 else { throw LibraryMetadataError.unsupportedVersion(pointer.version) }
        guard UUID(uuidString: pointer.generation) != nil else { throw LibraryMetadataError.unsafeFile }
        return pointer.generation
    }

    private func storeDirectory(_ generation: String?) -> URL {
        generation.map { directory.appending(path: "DatabaseGenerations/\($0)") } ?? directory
    }
    func activeDirectory() throws -> URL {
        let result = storeDirectory(try generation())
        try checkedDirectory(result)
        return result
    }
    func hasRetainedDatabase() throws -> Bool { try generation() != nil }
    func preservationDirectory(_ request: Request) -> URL { directory.appending(path: "DatabaseRecovery/\(request.id)/snapshot") }

    func request() throws -> Request {
        let value = try read(Request.self, at: requestURL)
        guard value.version == 1 else { throw LibraryMetadataError.unsupportedVersion(value.version) }
        guard UUID(uuidString: value.id) != nil,
              value.sourceGeneration == nil || UUID(uuidString: value.sourceGeneration!) != nil,
              value.id != value.sourceGeneration, value.createdAt.timeIntervalSince1970.isFinite,
              Set(value.files.map(\.name)).count == value.files.count,
              value.files.allSatisfy({ Self.fileNames.contains($0.name) && $0.bytes >= 0 && $0.sha256.count == 64
                  && $0.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }),
              value.phase == .requested || value.phase == .cancelled || value.files.contains(where: { $0.name == "metadata.store" }) else {
            throw LibraryMetadataError.unsafeFile
        }
        return value
    }

    func schedule() throws -> Request {
        try checkedDirectory(directory)
        let gate = try LibraryMetadataAccess.shared(directory: directory)
        try gate.enterMaintenance(requireUnopened: false); defer { gate.leave() }
        try checkedDirectory(directory)
        var status = stat()
        if lstat(requestURL.path, &status) == 0 { return try request() }
        guard errno == ENOENT else { throw LibraryMetadataError.unsafeFile }
        let value = Request(id: UUID().uuidString, sourceGeneration: try generation())
        try write(value, at: requestURL)
        return value
    }

    /// Tests may inject failure at an exact stage; production uses the real
    /// free-space probe and SwiftData initialization, never fake success.
    func perform(availableBytes: (URL) throws -> Int64 = { url in
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
    }, checkpoint: (String) throws -> Void = { _ in }, initialize: (URL) throws -> Void = Self.initializeEmptyStore) throws -> Request {
        try checkedDirectory(directory)
        let gate = try LibraryMetadataAccess.shared(directory: directory)
        try gate.enterMaintenance(requireUnopened: true); defer { gate.leave() }
        try checkedDirectory(directory)
        var value = try request()
        let current = try generation()
        guard current == value.sourceGeneration || current == value.id else { throw LibraryMetadataError.unsafeFile }
        let original = storeDirectory(value.sourceGeneration)
        let snapshot = preservationDirectory(value)
        if current == value.id {
            guard value.phase == .preserved || value.phase == .switched else { throw LibraryMetadataError.unsafeFile }
            try verify(value.files, in: snapshot)
            value.phase = .switched; try write(value, at: requestURL)
            return value
        }
        guard value.phase != .switched && value.phase != .rolledBack && value.phase != .cancelled else { throw LibraryMetadataError.unsafeFile }
        try checkedDirectory(original)
        let actual = try inventory(original)
        guard actual.contains(where: { $0.name == "metadata.store" }) else { throw LibraryMetadataError.unsafeFile }
        if value.phase == .requested {
            value.files = actual; value.phase = .copying; try write(value, at: requestURL)
        } else { guard actual == value.files else { throw LibraryMetadataError.unsafeFile } }
        try checkpoint("before-copy")
        if value.phase == .copying {
            let bytes = value.files.reduce(Int64(0)) { $0 + $1.bytes }
            guard try availableBytes(directory) > bytes + 64 * 1024 * 1024 else { throw ImportFailure.noSpace }
            try checkedDirectory(snapshot, create: true)
            for file in value.files {
                let target = snapshot.appending(path: file.name)
                var existing = stat()
                if lstat(target.path, &existing) == 0 {
                    guard try fingerprint(target) == file else { throw LibraryMetadataError.unsafeFile }
                } else {
                    guard errno == ENOENT else { throw LibraryMetadataError.unsafeFile }
                    try copy(original.appending(path: file.name), to: target)
                    guard try fingerprint(target) == file else { throw LibraryMetadataError.unsafeFile }
                }
                try checkpoint("copied-" + file.name)
            }
            try verify(value.files, in: snapshot)
            guard try inventory(original) == value.files else { throw LibraryMetadataError.unsafeFile }
            value.phase = .preserved; try write(value, at: requestURL)
        }
        try checkpoint("preserved")
        try verify(value.files, in: snapshot)
        let next = storeDirectory(value.id)
        try checkedDirectory(next, create: true)
        try initialize(next)
        try checkpoint("initialized")
        guard try inventory(original) == value.files else { throw LibraryMetadataError.unsafeFile }
        try checkpoint("before-switch")
        try write(Pointer(generation: value.id), at: directory.appending(path: Self.pointerName))
        try checkpoint("switched")
        value.phase = .switched; try write(value, at: requestURL)
        return value
    }

    /// Acknowledgment preserves a permanent receipt and only removes the exact
    /// pending request. It never deletes old stores, snapshots or wallpaper data.
    func acknowledge() throws {
        try checkedDirectory(directory)
        let gate = try LibraryMetadataAccess.shared(directory: directory)
        try gate.enterMaintenance(requireUnopened: true); defer { gate.leave() }
        let value = try request()
        let current = try generation()
        guard (value.phase == .switched && current == value.id)
            || (value.phase == .rolledBack && current == value.sourceGeneration) else { throw LibraryMetadataError.unsafeFile }
        try verify(value.files, in: preservationDirectory(value))
        let receipt = directory.appending(path: "DatabaseRecovery/\(value.id)/receipt.json")
        try write(value, at: receipt)
        guard unlink(requestURL.path) == 0 else { throw LibraryMetadataError.unsafeFile }
        gate.requireRestart()
    }

    func rollback() throws -> Request {
        try checkedDirectory(directory)
        let gate = try LibraryMetadataAccess.shared(directory: directory)
        try gate.enterMaintenance(requireUnopened: true); defer { gate.leave() }
        var value = try request()
        let current = try generation()
        guard (value.phase == .switched || value.phase == .rolledBack), current == value.id || current == value.sourceGeneration else {
            throw LibraryMetadataError.unsafeFile
        }
        try verify(value.files, in: preservationDirectory(value))
        guard try inventory(storeDirectory(value.sourceGeneration)) == value.files else { throw LibraryMetadataError.unsafeFile }
        if current == value.id {
            if let previous = value.sourceGeneration { try write(Pointer(generation: previous), at: directory.appending(path: Self.pointerName)) }
            else { guard unlink(directory.appending(path: Self.pointerName).path) == 0 else { throw LibraryMetadataError.unsafeFile } }
        }
        value.phase = .rolledBack; try write(value, at: requestURL)
        return value
    }

    func cancelBeforeSwitch() throws -> Request {
        try checkedDirectory(directory)
        let gate = try LibraryMetadataAccess.shared(directory: directory)
        try gate.enterMaintenance(requireUnopened: true); defer { gate.leave() }
        var value = try request()
        guard [.requested, .copying, .preserved].contains(value.phase), try generation() == value.sourceGeneration else {
            throw LibraryMetadataError.unsafeFile
        }
        value.phase = .cancelled
        let receipt = directory.appending(path: "DatabaseRecovery/\(value.id)/receipt.json")
        try checkedDirectory(receipt.deletingLastPathComponent(), create: true)
        try write(value, at: receipt)
        guard unlink(requestURL.path) == 0 else { throw LibraryMetadataError.unsafeFile }
        gate.requireRestart()
        return value
    }

    private static func initializeEmptyStore(_ directory: URL) throws {
        // Only this new controlled generation is opened; original files are not.
        for name in fileNames {
            var status = stat()
            if lstat(directory.appending(path: name).path, &status) == 0 {
                guard status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_nlink == 1 else {
                    throw LibraryMetadataError.unsafeFile
                }
            } else if errno != ENOENT { throw LibraryMetadataError.unsafeFile }
        }
        let schema = Schema(versionedSchema: LibraryMetadataSchema.self)
        let configuration = ModelConfiguration("LibraryMetadata", schema: schema,
            url: directory.appending(path: "metadata.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: LibraryMetadataMigration.self, configurations: [configuration])
        let context = ModelContext(container)
        guard try context.fetchCount(FetchDescriptor<LibraryMetadataSchema.Entry>()) == 0 else { throw LibraryMetadataError.nonemptyRestoreTarget }
    }

    private func inventory(_ folder: URL) throws -> [FileRecord] {
        try checkedDirectory(folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        guard !names.contains(where: { $0.hasPrefix("metadata.store") && !Self.fileNames.contains($0) }) else {
            // Do not call a three-file copy complete if an unsupported journal
            // or external-storage sidecar is present.
            throw LibraryMetadataError.unsafeFile
        }
        var files: [FileRecord] = []
        for name in Self.fileNames {
            var status = stat()
            let path = folder.appending(path: name)
            if lstat(path.path, &status) == 0 { files.append(try fingerprint(path)) }
            else if errno != ENOENT { throw LibraryMetadataError.unsafeFile }
        }
        return files
    }
    private func verify(_ files: [FileRecord], in folder: URL) throws {
        guard try inventory(folder) == files else { throw LibraryMetadataError.unsafeFile }
    }

    private func fingerprint(_ url: URL) throws -> FileRecord {
        try checkedDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LibraryMetadataError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size >= 0,
              before.st_size <= Int64.max / 8 else { throw LibraryMetadataError.unsafeFile }
        var hash = SHA256(), bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(data.count)
            guard bytes <= before.st_size else { throw LibraryMetadataError.unsafeFile }
            hash.update(data: data)
        }
        guard fstat(fd, &after) == 0, bytes == before.st_size, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else { throw LibraryMetadataError.unsafeFile }
        return FileRecord(name: url.lastPathComponent, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func copy(_ source: URL, to target: URL) throws {
        try checkedDirectory(source.deletingLastPathComponent()); try checkedDirectory(target.deletingLastPathComponent())
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw LibraryMetadataError.unsafeFile }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1, status.st_uid == getuid() else {
            throw LibraryMetadataError.unsafeFile
        }
        let partial = target.deletingLastPathComponent().appending(path: ".partial-\(UUID().uuidString)")
        let outputFD = open(partial.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw LibraryMetadataError.unsafeFile }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        defer { try? output.close() }
        var bytes: Int64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            bytes += Int64(data.count)
            guard bytes <= status.st_size else { throw LibraryMetadataError.unsafeFile }
            try output.write(contentsOf: data)
        }
        guard bytes == status.st_size else { throw LibraryMetadataError.unsafeFile }
        try output.synchronize(); try output.close()
        try checkedDirectory(target.deletingLastPathComponent())
        // RENAME_EXCL rejects any concurrent replacement; partials are retained
        // on failure for diagnosis and are never mistaken for verified copies.
        guard renamex_np(partial.path, target.path, UInt32(RENAME_EXCL)) == 0 else { throw LibraryMetadataError.unsafeFile }
    }
}
