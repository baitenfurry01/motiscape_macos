import Foundation
import CryptoKit

struct LibraryMetadataBackup: Codable, Sendable {
    struct Row: Codable, Sendable {
        var key: String
        var category: String
        var version: Int
        var payload: Data
    }
    var version = 1
    var records: [Row]
    static let byteLimit = 64 * 1024 * 1024
    static let rowLimit = 100_000

    struct Preview: Sendable {
        let data: Data
        let digest: String
        let counts: [String: Int]
        let pendingImports: Int
        let downloads: Int
        var total: Int { counts.values.reduce(0, +) }
    }

    static func read(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw LibraryMetadataError.unsafeFile }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size > 0, status.st_size <= byteLimit,
              let data = try handle.read(upToCount: byteLimit + 1), data.count <= byteLimit else {
            throw LibraryMetadataError.unsafeFile
        }
        try Task.checkCancellation()
        return data
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= byteLimit else { throw LibraryMetadataError.unsafeFile }
        let backup = try JSONDecoder().decode(Self.self, from: data)
        guard backup.version == 1 else { throw LibraryMetadataError.unsupportedVersion(backup.version) }
        guard backup.records.count <= rowLimit else { throw LibraryMetadataError.unsafeFile }
        var keys = Set<String>()
        for row in backup.records {
            try Task.checkCancellation()
            guard row.version == 1 else { throw LibraryMetadataError.unsupportedVersion(row.version) }
            let id: String
            switch row.category {
            case WallpaperRecord.category:
                let value = try JSONDecoder().decode(WallpaperRecord.self, from: row.payload)
                try validate(value); id = value.id
            case ImportJob.category:
                let value = try JSONDecoder().decode(ImportJob.self, from: row.payload)
                try validate(value.record)
                guard UUID(uuidString: value.id) != nil, path(value.destination), path(value.staging), path(value.backup),
                      value.updatedAt.timeIntervalSince1970.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                id = value.id
            case ImportAttemptRecord.category:
                let value = try JSONDecoder().decode(ImportAttemptRecord.self, from: row.payload)
                try value.validate(); id = value.id
            case DownloadQueueRecord.category:
                let value = try JSONDecoder().decode(DownloadQueueRecord.self, from: row.payload)
                guard value.version == 1 else { throw LibraryMetadataError.unsupportedVersion(value.version) }
                guard value.id == "main", (1...3).contains(value.concurrency),
                      Set(value.jobs.map(\.id)).count == value.jobs.count,
                      Set(value.jobs.map { $0.item.id }).count == value.jobs.count else { throw CocoaError(.fileReadCorruptFile) }
                for job in value.jobs + value.history {
                    guard UUID(uuidString: job.id) != nil, !job.item.id.isEmpty,
                          job.item.id.utf8.allSatisfy({ (48...57).contains($0) }), (UInt64(job.item.id) ?? 0) > 0,
                          path(job.outputRoot), job.receivedBytes >= 0, job.totalBytes >= 0,
                          job.createdAt.timeIntervalSince1970.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                }
                id = value.id
            case LibraryIndexScanRecord.category:
                let value = try JSONDecoder().decode(LibraryIndexScanRecord.self, from: row.payload)
                try value.validate(); id = value.id
            default: throw CocoaError(.fileReadCorruptFile)
            }
            guard row.key == row.category + ":" + id, keys.insert(row.key).inserted else { throw CocoaError(.fileReadCorruptFile) }
        }
        return backup
    }

    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw LibraryMetadataError.unsafeFile }
        defer { close(directoryFD) }
        let name = url.lastPathComponent
        var status = stat()
        if fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { throw LibraryMetadataError.unsafeFile }
        } else if errno != ENOENT { throw LibraryMetadataError.unsafeFile }
        let temporary = ".metadata-backup-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LibraryMetadataError.unsafeFile }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); unlinkat(directoryFD, temporary, 0) }
        try handle.write(contentsOf: data); try handle.synchronize()
        try Task.checkCancellation()
        guard renameat(directoryFD, temporary, directoryFD, name) == 0 else { throw LibraryMetadataError.unsafeFile }
    }

    static func preview(_ data: Data) throws -> Preview {
        let backup = try decode(data)
        var counts: [String: Int] = [:], pending = 0, downloads = 0
        for row in backup.records {
            counts[row.category, default: 0] += 1
            if row.category == ImportJob.category {
                let job = try JSONDecoder().decode(ImportJob.self, from: row.payload)
                if job.state == .copying || job.state == .committing { pending += 1 }
            }
            if row.category == DownloadQueueRecord.category {
                downloads += try JSONDecoder().decode(DownloadQueueRecord.self, from: row.payload).jobs.count
            }
        }
        return Preview(data: data, digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            counts: counts, pendingImports: pending, downloads: downloads)
    }

    private static func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") }
    private static func validate(_ value: WallpaperRecord) throws {
        guard path(value.id), value.addedAt.timeIntervalSince1970.isFinite else { throw CocoaError(.fileReadCorruptFile) }
    }
}
