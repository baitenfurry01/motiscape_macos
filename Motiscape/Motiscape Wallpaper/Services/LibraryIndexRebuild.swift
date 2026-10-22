import Foundation

enum LibraryIndexRebuildError: LocalizedError {
    case legacyUnreadable(path: String, reason: String)
    case rootChanged
    var errorDescription: String? {
        switch self {
        case .legacyUnreadable(let path, let reason):
            return L("无法读取旧加入时间索引 %@：%@。原文件未修改。", path, reason)
        case .rootChanged: return L("资料库目录已切换，请关闭并重新打开此窗口。")
        }
    }
}

struct LibraryIndexRebuildReport: Sendable {
    var candidates: [ImportCandidate]
    var insertedIDs: Set<String>
    var preservedCount: Int { candidates.filter { $0.issue == nil && !insertedIDs.contains($0.source.path) }.count }
    var issues: [ImportCandidate] { candidates.filter { $0.issue != nil } }
}

enum LibraryIndexPath {
    static func identity(_ path: String) -> String {
        // Recreate the URL to avoid cached resource values after a directory is created.
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Read-only compatibility with library-additions.json. Never replace a corrupt
/// or newer file with an empty index, or use its paths as content scan roots.
struct LegacyLibraryAdditionIndex: Codable {
    var version: Int
    var paths: [String: Date]
    var workshopIDs: [String: Date]

    static func read(from url: URL?) throws -> Self? {
        guard let url else { return nil }
        do { return try readFile(url) }
        catch let error as LibraryMetadataError { throw error }
        catch { throw LibraryIndexRebuildError.legacyUnreadable(path: url.path, reason: error.localizedDescription) }
    }

    private static func readFile(_ url: URL) throws -> Self? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        let limit = 16 * 1024 * 1024
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1 else { throw LibraryMetadataError.unsupportedVersion(value.version) }
        guard value.paths.allSatisfy({ $0.key.hasPrefix("/") && !$0.key.contains("\0") && $0.value.timeIntervalSince1970.isFinite }),
              value.workshopIDs.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return value
    }

    func dates(in root: URL) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for (path, date) in paths {
            try Task.checkCancellation()
            let identity = LibraryIndexPath.identity(path)
            guard URL(fileURLWithPath: identity).deletingLastPathComponent().path == root.path else { continue }
            // Resolve path aliases only; never open files or infer Steam IDs.
            result[identity] = min(result[identity] ?? date, date)
        }
        return result
    }
}
