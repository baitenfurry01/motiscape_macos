import Foundation
import CryptoKit
import ZIPFoundation

struct ZIPImportLimits: Sendable {
    var entries = 100_000
    var expandedBytes: UInt64 = 50 * 1024 * 1024 * 1024
    var archiveBytes: UInt64 = 50 * 1024 * 1024 * 1024
    var expansionRatio: UInt64 = 1_000
    var depth = 32
}

/// A private, disposable snapshot: never extracts directly into the library or
/// honors archived permissions, executable bits, links, or extended attributes.
enum SafeZIPImporter {
    struct Prepared: Sendable {
        let workspace: URL
        let contents: URL
        let fingerprint: String
        let lease: ZIPWorkspaceLease
    }

    static func fingerprint(_ source: URL, limit: UInt64) throws -> String {
        try copyAndHash(source, outputFD: nil, limit: limit)
    }

    static func prepare(_ source: URL, temporaryRoot: URL, libraryRoot: URL? = nil, limits: ZIPImportLimits,
                        availableBytes: (URL) throws -> Int64,
                        progress: (UInt64) -> Void = { _ in }) throws -> Prepared {
        guard limits.entries > 0, limits.depth > 0, limits.expansionRatio > 0,
              limits.archiveBytes <= UInt64(Int64.max - 16 * 1024 * 1024),
              limits.expandedBytes <= UInt64(Int64.max - 16 * 1024 * 1024) else { throw ImportFailure.limitExceeded }
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard source.isFileURL, attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
            throw ImportFailure.unsafePath
        }
        let size = UInt64(max(0, attributes.fileSize ?? 0))
        guard size <= limits.archiveBytes else { throw ImportFailure.limitExceeded }
        try ZIPWorkspaceStore(root: temporaryRoot).prepareRoot()
        guard try availableBytes(temporaryRoot) >= Int64(size) + 16 * 1024 * 1024 else { throw ImportFailure.noSpace }
        let lease = try ZIPWorkspaceStore(root: temporaryRoot).create(source: source, libraryRoot: libraryRoot ?? temporaryRoot)
        let workspace = lease.workspace
        do {
            let snapshotFD = try lease.createFile("source.zip")
            defer { close(snapshotFD) }
            let fingerprint = try copyAndHash(source, outputFD: snapshotFD, limit: limits.archiveBytes)
            try lease.update(state: .extracting, fingerprint: fingerprint)
            // Read through the open descriptor, not a replaceable parent path.
            let snapshot = URL(fileURLWithPath: "/dev/fd/\(snapshotFD)")
            let metadata = try ZIPEnvelope.read(snapshot, limits: limits)
            let archive = try Archive(url: snapshot, accessMode: .read)
            var entries: [(entry: Entry, path: String)] = []
            var paths: [String: String] = [:]
            var files = Set<String>()
            var directories = Set<String>()
            var explicit = Set<String>()
            var expanded: UInt64 = 0
            for entry in archive {
                try Task.checkCancellation()
                guard entries.count < metadata.count else { throw ImportFailure.invalidArchive }
                let expected = metadata[entries.count]
                guard entry.type != .symlink else { throw ImportFailure.unsafePath }
                guard entry.uncompressedSize == expected.size, entry.compressedSize == expected.compressed,
                      entry.checksum == expected.crc else { throw ImportFailure.invalidArchive }
                let path = try safePath(expected.path ?? entry.path, directory: entry.type == .directory, depth: limits.depth)
                let components = path.split(separator: "/").map(String.init)
                for i in components.indices {
                    let prefix = components[...i].joined(separator: "/")
                    let folded = prefix.precomposedStringWithCanonicalMapping.lowercased()
                    if let existing = paths[folded], existing != prefix { throw ImportFailure.unsafePath }
                    paths[folded] = prefix
                    if i < components.count - 1, files.contains(folded) { throw ImportFailure.unsafePath }
                    if i < components.count - 1 { directories.insert(folded) }
                }
                let key = path.precomposedStringWithCanonicalMapping.lowercased()
                guard explicit.insert(key).inserted else { throw ImportFailure.unsafePath }
                if entry.type == .file {
                    guard !directories.contains(key) else { throw ImportFailure.unsafePath }
                    files.insert(key)
                } else {
                    guard entry.uncompressedSize == 0, !files.contains(key) else { throw ImportFailure.invalidArchive }
                    directories.insert(key)
                }
                guard entry.uncompressedSize <= limits.expandedBytes - expanded else { throw ImportFailure.limitExceeded }
                expanded += entry.uncompressedSize
                if entry.uncompressedSize > 0 {
                    guard entry.compressedSize > 0,
                          (entry.uncompressedSize - 1) / entry.compressedSize < limits.expansionRatio else {
                        throw ImportFailure.limitExceeded
                    }
                }
                entries.append((entry, path))
            }
            // ZIPFoundation's iterator may end early for a damaged header. An
            // apparently valid prefix is never accepted as the complete archive.
            guard !entries.isEmpty, entries.count == metadata.count else { throw ImportFailure.invalidArchive }
            guard try availableBytes(workspace) >= Int64(expanded) + 16 * 1024 * 1024 else { throw ImportFailure.noSpace }
            let contents = workspace.appending(path: "contents")
            try lease.makeDirectory("contents")
            var total: UInt64 = 0
            for (entry, path) in entries {
                try Task.checkCancellation()
                let destination = contents.appending(path: path)
                guard destination.standardizedFileURL.path.hasPrefix(contents.path + "/") else { throw ImportFailure.unsafePath }
                if entry.type == .directory {
                    try lease.makeDirectory("contents/" + path)
                    continue
                }
                // O_EXCL/O_NOFOLLOW prevents overwriting an unexpected entry.
                let descriptor = try lease.createFile("contents/" + path)
                let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? output.close() }
                var written: UInt64 = 0
                let crc = try archive.extract(entry, bufferSize: 256 * 1024) { data in
                    try Task.checkCancellation()
                    let count = UInt64(data.count)
                    guard count <= entry.uncompressedSize - written,
                          count <= limits.expandedBytes - total else { throw ImportFailure.limitExceeded }
                    try output.write(contentsOf: data)
                    written += count; total += count
                    progress(total)
                    try Task.checkCancellation()
                }
                guard written == entry.uncompressedSize, crc == entry.checksum else { throw ImportFailure.invalidArchive }
                try output.synchronize()
            }
            // The immutable extracted snapshot is retained for user review;
            // keeping a second copy of the compressed file is unnecessary.
            try lease.removeCompressedSnapshot()
            try lease.update(state: .ready, fingerprint: fingerprint)
            return Prepared(workspace: workspace, contents: contents, fingerprint: fingerprint, lease: lease)
        } catch {
            try? lease.discard()
            if error is CancellationError || error is ImportFailure || error is ZIPWorkspaceError { throw error }
            throw ImportFailure.invalidArchive
        }
    }

    private static func copyAndHash(_ source: URL, outputFD: Int32?, limit: UInt64) throws -> String {
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ImportFailure.unsafePath }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var statValue = stat()
        guard fstat(fd, &statValue) == 0, statValue.st_mode & S_IFMT == S_IFREG else { throw ImportFailure.unsafePath }
        var output: FileHandle?
        if let outputFD {
            let descriptor = dup(outputFD)
            guard descriptor >= 0 else { throw ImportFailure.unsafePath }
            output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
        defer { try? output?.close() }
        var hash = SHA256(), total: UInt64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            guard UInt64(data.count) <= limit - total else { throw ImportFailure.limitExceeded }
            total += UInt64(data.count); hash.update(data: data)
            try output?.write(contentsOf: data)
        }
        try output?.synchronize()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func safePath(_ value: String, directory: Bool, depth: Int) throws -> String {
        let path = directory && value.hasSuffix("/") ? String(value.dropLast()) : value
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 4096, !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              components.count <= depth,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw ImportFailure.unsafePath
        }
        return path
    }
}

/// Bounds-check the ZIP/ZIP64 envelope before handing data to a decompressor.
/// All arithmetic from untrusted fields is bounded by the actual file length.
private enum ZIPEnvelope {
    struct Metadata { let size: UInt64; let compressed: UInt64; let crc: UInt32; let path: String? }
    static func read(_ url: URL, limits: ZIPImportLimits) throws -> [Metadata] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length >= 22, length <= limits.archiveBytes else { throw ImportFailure.invalidArchive }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= length, count >= 0, UInt64(count) <= length - offset else { throw ImportFailure.invalidArchive }
            try file.seek(toOffset: offset)
            let data = try file.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ImportFailure.invalidArchive }
            return data
        }
        let tailSize = Int(min(length, 65557)), tail = try read(length - UInt64(min(length, 65557)), tailSize)
        var end: Int?
        for i in stride(from: tailSize - 22, through: 0, by: -1) {
            if tail.number(i, 4) == 0x06054b50, i + 22 + Int(tail.number(i + 20, 2)) == tailSize { end = i; break }
        }
        guard let end else { throw ImportFailure.invalidArchive }
        let eocd = length - UInt64(tailSize) + UInt64(end)
        guard tail.number(end + 4, 2) == 0, tail.number(end + 6, 2) == 0 else { throw ImportFailure.invalidArchive }
        var count = tail.number(end + 10, 2), size = tail.number(end + 12, 4), offset = tail.number(end + 16, 4)
        var centralEnd = eocd
        if eocd >= 20, try read(eocd - 20, 4).number(0, 4) == 0x07064b50 {
            let locator = try read(eocd - 20, 20), location = locator.number(8, 8)
            guard locator.number(4, 4) == 0, locator.number(16, 4) == 1,
                  location <= eocd - 20, eocd - 20 - location == 56 else { throw ImportFailure.invalidArchive }
            let zip64 = try read(location, 56)
            guard zip64.number(0, 4) == 0x06064b50, zip64.number(4, 8) == 44,
                  zip64.number(16, 4) == 0, zip64.number(20, 4) == 0,
                  zip64.number(24, 8) == zip64.number(32, 8) else { throw ImportFailure.invalidArchive }
            count = zip64.number(32, 8); size = zip64.number(40, 8); offset = zip64.number(48, 8)
            centralEnd = location
        } else if count == 0xffff || size == 0xffffffff || offset == 0xffffffff {
            throw ImportFailure.invalidArchive
        } else if tail.number(end + 8, 2) != count { throw ImportFailure.invalidArchive }
        guard count > 0, count <= UInt64(limits.entries), size <= 64 * 1024 * 1024 else { throw ImportFailure.limitExceeded }
        guard offset <= centralEnd, size == centralEnd - offset else { throw ImportFailure.invalidArchive }
        let central = try read(offset, Int(size))
        var cursor = 0, result: [Metadata] = [], ranges: [(UInt64, UInt64)] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard central.count - cursor >= 46, central.number(cursor, 4) == 0x02014b50 else { throw ImportFailure.invalidArchive }
            let h = central.subdata(in: cursor..<cursor + 46)
            let nameLength = Int(h.number(28, 2)), extraLength = Int(h.number(30, 2)), commentLength = Int(h.number(32, 2))
            let entryLength = 46 + nameLength + extraLength + commentLength
            guard entryLength <= central.count - cursor, h.number(34, 2) == 0 else { throw ImportFailure.invalidArchive }
            let flags = h.number(8, 2), method = h.number(10, 2)
            guard flags & ~UInt64(0x080e) == 0, method == 0 || method == 8 else { throw ImportFailure.invalidArchive }
            let mode = (h.number(38, 4) >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw ImportFailure.unsafePath }
            var expanded = h.number(24, 4), compressed = h.number(20, 4), local = h.number(42, 4)
            let name = central.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let extra = central.subdata(in: cursor + 46 + nameLength..<cursor + 46 + nameLength + extraLength)
            var extraCursor = 0, zip64: Data?, unicodePath: Data?
            while extraCursor < extra.count {
                guard extra.count - extraCursor >= 4 else { throw ImportFailure.invalidArchive }
                let extraSize = Int(extra.number(extraCursor + 2, 2))
                guard extraSize <= extra.count - extraCursor - 4 else { throw ImportFailure.invalidArchive }
                if extra.number(extraCursor, 2) == 1 {
                    guard zip64 == nil else { throw ImportFailure.invalidArchive }
                    zip64 = extra.subdata(in: extraCursor + 4..<extraCursor + 4 + extraSize)
                } else if extra.number(extraCursor, 2) == 0x7075 {
                    guard unicodePath == nil else { throw ImportFailure.invalidArchive }
                    unicodePath = extra.subdata(in: extraCursor + 4..<extraCursor + 4 + extraSize)
                }
                extraCursor += extraSize + 4
            }
            var zipCursor = 0
            func zipValue(_ value: UInt64) throws -> UInt64 {
                guard value == 0xffffffff else { return value }
                guard let zip64, zip64.count - zipCursor >= 8 else { throw ImportFailure.invalidArchive }
                defer { zipCursor += 8 }
                return zip64.number(zipCursor, 8)
            }
            expanded = try zipValue(expanded); compressed = try zipValue(compressed); local = try zipValue(local)
            guard expanded <= limits.expandedBytes, compressed <= length, local <= offset, offset - local >= 30 else {
                throw ImportFailure.limitExceeded
            }
            let header = try read(local, 30)
            guard header.number(0, 4) == 0x04034b50, header.number(6, 2) == flags,
                  header.number(8, 2) == method, header.number(26, 2) == UInt64(nameLength) else { throw ImportFailure.invalidArchive }
            if flags & 8 == 0 {
                guard header.number(14, 4) == h.number(16, 4),
                      header.number(18, 4) == compressed || header.number(18, 4) == 0xffffffff,
                      header.number(22, 4) == expanded || header.number(22, 4) == 0xffffffff else {
                    throw ImportFailure.invalidArchive
                }
            }
            let headerLength = UInt64(30 + nameLength) + header.number(28, 2)
            guard headerLength <= offset - local, compressed <= offset - local - headerLength,
                  try read(local + 30, nameLength) == name else { throw ImportFailure.invalidArchive }
            if method == 0, compressed != expanded { throw ImportFailure.invalidArchive }
            var entryEnd = local + headerLength + compressed
            if flags & 8 != 0 {
                let wide = zip64 != nil || h.number(6, 2) >= 45
                let width = wide ? 8 : 4
                guard offset - entryEnd >= UInt64(4 + 2 * width) else { throw ImportFailure.invalidArchive }
                let hasSignature = try read(entryEnd, 4).number(0, 4) == 0x08074b50
                let descriptorLength = 4 + 2 * width + (hasSignature ? 4 : 0)
                guard offset - entryEnd >= UInt64(descriptorLength) else { throw ImportFailure.invalidArchive }
                let descriptor = try read(entryEnd, descriptorLength), start = hasSignature ? 4 : 0
                guard descriptor.number(start, 4) == h.number(16, 4),
                      descriptor.number(start + 4, width) == compressed,
                      descriptor.number(start + 4 + width, width) == expanded else { throw ImportFailure.invalidArchive }
                entryEnd += UInt64(descriptorLength)
            }
            ranges.append((local, entryEnd))
            result.append(Metadata(size: expanded, compressed: compressed, crc: UInt32(h.number(16, 4)),
                                   path: try decodedPath(name, flags: flags, unicodePath: unicodePath)))
            cursor += entryLength
        }
        guard cursor == central.count else { throw ImportFailure.invalidArchive }
        ranges.sort { $0.0 < $1.0 }
        for i in ranges.indices.dropFirst() where ranges[i].0 < ranges[i - 1].1 { throw ImportFailure.invalidArchive }
        return result
    }

    private static func decodedPath(_ name: Data, flags: UInt64, unicodePath: Data?) throws -> String? {
        if flags & 0x800 != 0 {
            guard let path = String(data: name, encoding: .utf8) else { throw ImportFailure.invalidArchive }
            return path
        }
        // Info-ZIP's Unicode Path extra field is authoritative only when its
        // version and CRC match the original filename bytes.
        if let unicodePath, unicodePath.count >= 5, unicodePath[0] == 1,
           unicodePath.number(1, 4) == UInt64(name.crc32(checksum: 0)) {
            guard let path = String(data: unicodePath.dropFirst(5), encoding: .utf8) else {
                throw ImportFailure.invalidArchive
            }
            return path
        }
        // Some ZIP writers store UTF-8 names without setting bit 11. Decode
        // strictly before falling back to ZIPFoundation's legacy CP437 path.
        // The chosen name still goes through the same path/collision checks.
        return String(data: name, encoding: .utf8)
    }
}

private extension Data {
    /// Callers bounds-check fixed structures and extra fields before reading.
    func number(_ offset: Int, _ bytes: Int) -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<bytes { result |= UInt64(self[offset + i]) << (8 * i) }
        return result
    }
}
