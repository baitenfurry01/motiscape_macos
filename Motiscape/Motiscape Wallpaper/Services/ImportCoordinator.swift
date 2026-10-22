import Foundation
import CryptoKit

enum ImportFailure: LocalizedError, Equatable {
    case invalidManifest, missingManifest, missingEntry, unsafePath, unsupported, limitExceeded, noSpace, sourceChanged, busy, invalidArchive
    var errorDescription: String? {
        switch self {
        case .missingManifest: return L("请选择包含 project.json 的单个壁纸文件夹。批量导入请使用 ZIP。")
        case .invalidManifest: return L("壁纸清单无效或过大")
        case .missingEntry: return L("壁纸入口文件不存在")
        case .unsafePath: return L("导入包含不安全路径或符号链接")
        case .unsupported: return L("不支持的导入格式")
        case .limitExceeded: return L("导入超过文件数或大小限制")
        case .noSpace: return L("可用磁盘空间不足")
        case .sourceChanged: return L("源文件在预检后发生变化，请重新选择")
        case .busy: return L("已有导入任务正在进行")
        case .invalidArchive: return L("ZIP 文件损坏、加密或使用了不支持的格式")
        }
    }
}

enum ImportDuplicatePolicy: String, CaseIterable, Sendable {
    case skip, keepBoth, replace
    var title: String {
        switch self {
        case .skip: return L("跳过重复项")
        case .keepBoth: return L("保留副本")
        case .replace: return L("替换重复项")
        }
    }
}

struct ImportCandidate: Identifiable, Sendable {
    let id: UUID
    let source: URL
    var title: String
    let kind: String
    let bytes: Int64
    let fingerprint: String
    let isVideo: Bool
    var issue: String?
    var archiveMember: String?
    var archiveFingerprint: String?
    var extractedSource: URL?
    var originalTags: [String] = []
    var tagEdit: String?
    var coverEdit: ImportCoverEdit = .original
    var originalPreviewURL: URL?
    var previewThumbnail: Data?
    var videoSourceURL: URL?
    var videoInfo: ImportVideoInfo?
    var mediaWarnings: [String] = []

    var tagsText: String {
        get { tagEdit ?? originalTags.joined(separator: ", ") }
        set { tagEdit = newValue }
    }

    var validationIssue: String? {
        if let issue { return issue }
        do {
            _ = try ImportMediaPreflight.title(title)
            if let tagEdit { _ = try ImportMediaPreflight.tags(tagEdit) }
            return nil
        } catch { return error.localizedDescription }
    }

    var displaySource: String {
        archiveMember.map { source.path + " ▸ " + $0 } ?? source.path
    }

    var contentSource: URL { extractedSource ?? source }
}

struct ImportResult: Identifiable, Sendable {
    enum Outcome: String, Sendable { case imported, skipped, failed, cancelled }
    let id: UUID
    let source: URL
    let destination: URL?
    let outcome: Outcome
    let message: String?
}

struct ImportProgress: Sendable {
    var current: Int
    var total: Int
    var title: String
    var copiedBytes: Int64
    var totalBytes: Int64
}

struct ImportRecoveryIssue: Identifiable, Sendable {
    let id: String
    let title: String
    let message: String
}

struct ImportRecoveryReport: Sendable {
    var recovered: [ImportJob] = []
    var issues: [ImportRecoveryIssue] = []
}

/// Serial import transactions with an injectable data root and disk probe.
/// Only files created by a journaled job may be cleaned up during recovery.
actor ImportCoordinator {
    private let root: URL
    private let index: any ImportMetadataStore
    private let availableBytes: @Sendable (URL) throws -> Int64
    private let moveItem: @Sendable (URL, URL) throws -> Void
    private let trashItem: @Sendable (URL) throws -> Void
    private let fm = FileManager.default
    private var running = false
    private let maxFiles = 100_000
    private let maxBytes: Int64 = 50 * 1024 * 1024 * 1024
    private let temporaryRoot: URL
    private let zipLimits: ZIPImportLimits
    private var archiveWorkspaces: [ZIPWorkspaceLease] = []

    init(root: URL, index: any ImportMetadataStore,
         temporaryRoot: URL = ZIPWorkspaceStore.defaultRoot,
         zipLimits: ZIPImportLimits = ZIPImportLimits(),
         moveItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
         trashItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         availableBytes: @escaping @Sendable (URL) throws -> Int64 = { url in
             let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
             return values.volumeAvailableCapacityForImportantUsage ?? 0
         }) {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.index = index
        self.availableBytes = availableBytes
        self.moveItem = moveItem
        self.trashItem = trashItem
        self.temporaryRoot = temporaryRoot.standardizedFileURL
        self.zipLimits = zipLimits
    }

    deinit { for workspace in archiveWorkspaces { try? workspace.discard() } }

    func discardPreparedArchives() {
        guard !running else { return }
        for workspace in archiveWorkspaces { try? workspace.discard() }
        archiveWorkspaces = []
    }

    func archiveWorkspaceInventory() throws -> ZIPWorkspaceInventory {
        try ZIPWorkspaceStore(root: temporaryRoot).inventory(libraryRoot: root)
    }

    /// Re-extract the verified original ZIP, never automatically commit cached
    /// contents or trust an interrupted extraction as a ready wallpaper.
    func recoverArchiveWorkspace(_ snapshot: ZIPWorkspaceSnapshot) async throws -> (candidates: [ImportCandidate], cleanupError: String?) {
        guard !running else { throw ImportFailure.busy }
        let lease = try ZIPWorkspaceStore(root: temporaryRoot).acquire(snapshot, libraryRoot: root)
        guard let expected = lease.record.fingerprint else { throw ZIPWorkspaceError.noSource }
        let source = URL(fileURLWithPath: lease.record.source)
        guard try SafeZIPImporter.fingerprint(source, limit: zipLimits.archiveBytes) == expected else { throw ImportFailure.sourceChanged }
        let candidates = try await scan([source])
        guard candidates.allSatisfy({ $0.archiveFingerprint == nil || $0.archiveFingerprint == expected }) else {
            discardPreparedArchives()
            throw ImportFailure.sourceChanged
        }
        var cleanupError: String?
        if candidates.contains(where: { $0.validationIssue == nil }) {
            do { try lease.discard() } catch { cleanupError = error.localizedDescription }
        }
        return (candidates, cleanupError)
    }

    func scan(_ urls: [URL]) async throws -> [ImportCandidate] {
        guard !running else { throw ImportFailure.busy }
        discardPreparedArchives()
        running = true
        var succeeded = false
        defer { running = false; if !succeeded { discardPreparedArchives() } }
        try await guardRetainedTransactions()
        var seen = Set<String>()
        var result: [ImportCandidate] = []
        var visitedCount = 0
        func visit(_ url: URL, depth: Int, archive: (URL, SafeZIPImporter.Prepared)? = nil) throws {
            try Task.checkCancellation()
            let url = url.standardizedFileURL
            guard seen.insert(url.path).inserted else { return }
            visitedCount += 1
            guard visitedCount <= maxFiles, depth <= 16 else { throw ImportFailure.limitExceeded }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ImportFailure.unsafePath }
                if archive == nil, values.isDirectory != true, url.pathExtension.lowercased() == "zip" {
                    let prepared = try SafeZIPImporter.prepare(url, temporaryRoot: temporaryRoot, libraryRoot: root,
                        limits: zipLimits, availableBytes: availableBytes)
                    archiveWorkspaces.append(prepared.lease)
                    let previousCount = result.count
                    try visit(prepared.contents, depth: 0, archive: (url, prepared))
                    if result.count == previousCount { throw ImportFailure.invalidManifest }
                } else if values.isDirectory == true, !fm.fileExists(atPath: url.appending(path: "project.json").path) {
                    // Only archives discover multiple projects; a selected folder is one wallpaper.
                    guard archive != nil else { throw ImportFailure.missingManifest }
                    let children = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
                    if children.isEmpty { throw ImportFailure.invalidManifest }
                    for child in children {
                        if archive != nil, child.lastPathComponent == "__MACOSX" { continue }
                        try visit(child, depth: depth + 1, archive: archive)
                    }
                } else {
                    var candidate = try inspect(url)
                    if let archive { candidate = archiveCandidate(candidate, archive: archive) }
                    result.append(candidate)
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                var candidate = ImportCandidate(id: UUID(), source: url, title: url.lastPathComponent,
                    kind: "unknown", bytes: 0, fingerprint: "", isVideo: false,
                    issue: error.localizedDescription)
                if let archive { candidate = archiveCandidate(candidate, archive: archive) }
                result.append(candidate)
            }
        }
        do {
            for url in urls { try visit(url, depth: 0) }
            for i in result.indices where result[i].issue == nil {
                try Task.checkCancellation()
                if let video = result[i].videoSourceURL {
                    do {
                        result[i].videoInfo = try await ImportMediaPreflight.video(at: video)
                        if let warning = result[i].videoInfo?.warning { result[i].mediaWarnings.append(warning) }
                    } catch is CancellationError { throw CancellationError() }
                    catch { result[i].issue = error.localizedDescription }
                }
                if let preview = result[i].originalPreviewURL {
                    do { result[i].previewThumbnail = try ImportMediaPreflight.cover(at: preview, maximumDimension: 320) }
                    catch is CancellationError { throw CancellationError() }
                    catch { result[i].mediaWarnings.append(L("原封面无法预览，可以更换或移除封面。")) }
                } else if let generated = result[i].videoInfo?.thumbnail {
                    result[i].previewThumbnail = try? ImportMediaPreflight.cover(data: generated, maximumDimension: 320)
                }
            }
            let batchID = UUID().uuidString
            let failures = result.compactMap { candidate -> ImportAttemptRecord? in
                guard let issue = candidate.validationIssue else { return nil }
                var attempt = makeAttempt(candidate, batchID: batchID, phase: .preflight)
                attempt.state = .failed; attempt.error = issue
                return attempt
            }
            try await index.saveAttempts(failures)
            succeeded = true
            return result
        } catch is CancellationError {
            // Cancellation may occur before package members are known. Preserve
            // one source-level preflight result per input, not imaginary imports.
            let batchID = UUID().uuidString
            var seenSources = Set<String>()
            let cancelled = urls.compactMap { url -> ImportAttemptRecord? in
                guard seenSources.insert(url.standardizedFileURL.path).inserted else { return nil }
                let candidate = ImportCandidate(id: UUID(), source: url, title: url.lastPathComponent,
                    kind: "unknown", bytes: 0, fingerprint: "", isVideo: false)
                var attempt = makeAttempt(candidate, batchID: batchID, phase: .preflight)
                attempt.state = .cancelled; attempt.error = L("已取消预检")
                return attempt
            }
            try await index.saveAttempts(cancelled)
            throw CancellationError()
        }
    }

    private func archiveCandidate(_ candidate: ImportCandidate, archive: (URL, SafeZIPImporter.Prepared)) -> ImportCandidate {
        let relative = String(candidate.source.path.dropFirst(archive.1.contents.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return ImportCandidate(id: candidate.id, source: archive.0, title: candidate.title,
            kind: candidate.kind, bytes: candidate.bytes, fingerprint: candidate.fingerprint,
            isVideo: candidate.isVideo, issue: candidate.issue, archiveMember: relative.isEmpty ? "." : relative,
            archiveFingerprint: archive.1.fingerprint, extractedSource: candidate.source,
            originalTags: candidate.originalTags, originalPreviewURL: candidate.originalPreviewURL,
            videoSourceURL: candidate.videoSourceURL)
    }

    private func inspect(_ url: URL) throws -> ImportCandidate {
        guard url.isFileURL else { throw ImportFailure.unsupported }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw ImportFailure.unsafePath }
        let isVideo = values.isDirectory != true
        var title = url.deletingPathExtension().lastPathComponent
        var kind = "video"
        var tags: [String] = []
        var previewURL: URL?
        var videoURL: URL? = isVideo ? url : nil
        if isVideo {
            guard values.isRegularFile == true,
                  ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { throw ImportFailure.unsupported }
        } else {
            let projectURL = try safeChild("project.json", in: url)
            let size = try projectURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 8 * 1024 * 1024,
                  let project = try JSONSerialization.jsonObject(with: Data(contentsOf: projectURL)) as? [String: Any],
                  let type = project["type"] as? String else { throw ImportFailure.invalidManifest }
            kind = type.lowercased()
            tags = project["tags"] as? [String] ?? []
            guard ["video", "web", "scene"].contains(kind) else { throw ImportFailure.unsupported }
            title = (project["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
            // Presets are resolved through the existing dependency flow after import.
            let dependency = project["dependency"].map { String(describing: $0) } ?? ""
            let isPreset = !dependency.isEmpty && dependency.utf8.allSatisfy { (48...57).contains($0) } &&
                dependency.contains(where: { $0 != "0" }) && project["preset"] is [String: Any]
            if !isPreset {
                guard let entry = project["file"] as? String else { throw ImportFailure.missingEntry }
                // Scene manifests commonly name scene.json inside scene.pkg.
                // Match WEWallpaper.resolvedEntryURL, while still validating the manifest path.
                let manifestEntryURL = try safeChild(entry, in: url)
                let entryURL: URL
                if kind == "scene", fm.fileExists(atPath: url.appending(path: "scene.pkg").path) {
                    entryURL = try safeChild("scene.pkg", in: url)
                } else {
                    entryURL = manifestEntryURL
                }
                guard (try? entryURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { throw ImportFailure.missingEntry }
                if kind == "video" { videoURL = entryURL }
            }
            if let preview = project["preview"] as? String, !preview.isEmpty { previewURL = try safeChild(preview, in: url) }
        }
        let inventory = try files(at: url, isVideo: isVideo)
        var hash = SHA256()
        var bytes: Int64 = 0
        for (relative, file) in inventory {
            // Length prefix prevents ambiguity between filenames and file bytes.
            let name = Data(relative.utf8)
            hash.update(data: Data("\(name.count):".utf8)); hash.update(data: name)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            hash.update(data: Data("\(size):".utf8))
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                bytes += Int64(chunk.count)
                guard bytes <= maxBytes else { throw ImportFailure.limitExceeded }
                hash.update(data: chunk)
            }
        }
        return ImportCandidate(id: UUID(), source: url, title: title, kind: kind, bytes: bytes,
            fingerprint: hash.finalize().map { String(format: "%02x", $0) }.joined(), isVideo: isVideo,
            originalTags: tags, originalPreviewURL: previewURL, videoSourceURL: videoURL)
    }

    private func safeChild(_ path: String, in directory: URL) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              !path.split(separator: "/").contains("..") else { throw ImportFailure.unsafePath }
        let child = directory.appending(path: path).standardizedFileURL
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard child.resolvingSymlinksInPath().path.hasPrefix(base) else { throw ImportFailure.unsafePath }
        return child
    }

    private func files(at source: URL, isVideo: Bool) throws -> [(String, URL)] {
        if isVideo { return [(source.lastPathComponent, source)] }
        // Foundation enumerators may return /private/var while the selected URL
        // uses /var. Derive relative paths from the same canonical base.
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        var failure: Error?
        guard let enumerator = fm.enumerator(at: source,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey],
            errorHandler: { _, error in failure = error; return false }) else { throw ImportFailure.invalidManifest }
        var result: [(String, URL)] = []
        var count = 0
        for case let file as URL in enumerator {
            try Task.checkCancellation()
            count += 1
            guard count <= maxFiles else { throw ImportFailure.limitExceeded }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
            guard values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else { throw ImportFailure.unsafePath }
            if values.isRegularFile == true {
                let normalized = file.resolvingSymlinksInPath().standardizedFileURL
                guard normalized.path.hasPrefix(source.path + "/") else { throw ImportFailure.unsafePath }
                let relative = String(normalized.path.dropFirst(source.path.count + 1))
                if ![".motiscape-import.json"].contains(relative) {
                    result.append((relative, file))
                }
            }
        }
        if let failure { throw failure }
        return result.sorted { $0.0 < $1.0 }
    }

    func run(_ candidates: [ImportCandidate], policy: ImportDuplicatePolicy,
             progress: @escaping @Sendable (ImportProgress) async -> Void) async throws -> [ImportResult] {
        guard !running else { throw ImportFailure.busy }
        guard !candidates.isEmpty else { return [] }
        running = true
        defer { running = false }
        // Read/version-check existing receipts before accepting more work.
        try await guardRetainedTransactions()
        _ = try await attempts()
        let batchID = UUID().uuidString
        let receipts = candidates.map { makeAttempt($0, batchID: batchID, phase: .confirmed) }
        // The whole batch is durable before creating directories or copying content.
        try await index.saveAttempts(receipts)
        var records = try await index.records(WallpaperRecord.self)
        var results: [ImportResult] = []
        func finish(_ result: ImportResult, at position: Int) async throws {
            var receipt = receipts[position]
            switch result.outcome {
            case .imported: receipt.state = .imported
            case .skipped: receipt.state = .skipped
            case .failed: receipt.state = .failed
            case .cancelled: receipt.state = .cancelled
            }
            receipt.destination = result.destination?.path
            receipt.error = result.message; receipt.updatedAt = Date()
            try await index.saveAttempts([receipt])
            results.append(result)
        }
        do { try prepareRoot() }
        catch {
            for (position, candidate) in candidates.enumerated() {
                try await finish(.init(id: candidate.id, source: candidate.source, destination: nil,
                    outcome: .failed, message: error.localizedDescription), at: position)
            }
            return results
        }
        var verifiedArchives: [URL: String] = [:]
        for (position, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                try await finish(.init(id: candidate.id, source: candidate.source, destination: nil,
                                     outcome: .cancelled, message: nil), at: position)
                continue
            }
            if let issue = candidate.validationIssue {
                try await finish(.init(id: candidate.id, source: candidate.source, destination: nil,
                                     outcome: .failed, message: issue), at: position)
                continue
            }
            do {
                if let expected = candidate.archiveFingerprint {
                    let actual = try verifiedArchives[candidate.source] ?? SafeZIPImporter.fingerprint(candidate.source, limit: zipLimits.archiveBytes)
                    verifiedArchives[candidate.source] = actual
                    guard actual == expected else { throw ImportFailure.sourceChanged }
                }
            } catch {
                try await finish(.init(id: candidate.id, source: candidate.source, destination: nil,
                    outcome: error is CancellationError ? .cancelled : .failed,
                    message: error is CancellationError ? nil : error.localizedDescription), at: position)
                continue
            }
            let duplicate = records.first {
                $0.fingerprint == candidate.fingerprint && isManagedDestination(URL(fileURLWithPath: $0.id)) &&
                    fm.fileExists(atPath: URL(fileURLWithPath: $0.id).appending(path: "project.json").path)
            }
            if duplicate != nil, policy == .skip {
                try await finish(.init(id: candidate.id, source: candidate.source,
                    destination: URL(fileURLWithPath: duplicate!.id), outcome: .skipped, message: nil), at: position)
                continue
            }
            let result: ImportResult
            do {
                let record = try await importOne(candidate, id: receipts[position].id, replacement: policy == .replace ? duplicate : nil) { copied in
                    await progress(ImportProgress(current: position + 1, total: candidates.count,
                        title: candidate.title, copiedBytes: copied, totalBytes: candidate.bytes))
                }
                records.removeAll { $0.id == record.id }; records.append(record)
                result = .init(id: candidate.id, source: candidate.source,
                    destination: URL(fileURLWithPath: record.id), outcome: .imported, message: nil)
            } catch {
                result = .init(id: candidate.id, source: candidate.source, destination: nil,
                    outcome: error is CancellationError ? .cancelled : .failed,
                    message: error is CancellationError ? nil : error.localizedDescription)
            }
            // Receipt failure is not a file-copy failure. Stop the batch and let
            // recovery reconcile its pending receipt with the authoritative journal.
            try await finish(result, at: position)
        }
        return results
    }

    private func prepareRoot() throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appending(path: ".importing")
        if fm.fileExists(atPath: staging.path),
           (try staging.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true {
            throw ImportFailure.unsafePath
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    private func isManagedDestination(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == root.path &&
            !url.lastPathComponent.hasPrefix(".") &&
            url.resolvingSymlinksInPath().deletingLastPathComponent().path == root.path
    }

    private func importOne(_ candidate: ImportCandidate, id: String, replacement: WallpaperRecord?,
                           expectedDestination: ImportDestinationSnapshot? = nil, preserveMetadata: Bool = false,
                           sourceBackup: ImportJob? = nil,
                           progress: @escaping @Sendable (Int64) async -> Void) async throws -> WallpaperRecord {
        let source = candidate.contentSource
        if candidate.extractedSource != nil {
            guard let owner = archiveWorkspaces.first(where: { source.path.hasPrefix($0.workspace.appending(path: "contents").path + "/") || source == $0.workspace.appending(path: "contents") }) else {
                throw ImportFailure.sourceChanged
            }
            try owner.validateLocation()
        }
        let fresh = try inspect(source)
        guard fresh.fingerprint == candidate.fingerprint else { throw ImportFailure.sourceChanged }
        let title = preserveMetadata ? candidate.title : try ImportMediaPreflight.title(candidate.title)
        let editedTags = try candidate.tagEdit.map { try ImportMediaPreflight.tags($0) }
        let customCover: Data?
        if case .custom(let data) = candidate.coverEdit { customCover = try ImportMediaPreflight.cover(data: data) }
        else { customCover = nil }
        // Reserve the maximum encoded thumbnail before creating the staging copy.
        let coverReservation = Int64(customCover?.count ?? 0) + (fresh.videoSourceURL == nil ? 0 : 4 * 1024 * 1024)
        guard try availableBytes(root) >= candidate.bytes + coverReservation + 16 * 1024 * 1024 else { throw ImportFailure.noSpace }
        let staging = root.appending(path: ".importing/\(id)")
        let backup = root.appending(path: ".importing/\(id).backup")
        let destination = replacement.map { URL(fileURLWithPath: $0.id) } ?? root.appending(path: "import-\(id)")
        if let expectedDestination { try verifyDestination(destination, expected: expectedDestination) }
        let record = WallpaperRecord(id: destination.path, source: candidate.displaySource,
            fingerprint: candidate.fingerprint, title: title, kind: candidate.kind, addedAt: Date())
        var job = ImportJob(id: id, source: candidate.displaySource, destination: destination.path,
            staging: staging.path, backup: backup.path, state: .copying, record: record, updatedAt: Date())
        try await index.save(job)
        var committed = false
        var needsRecovery = false
        do {
            if let sourceBackup { try validateBackupJob(sourceBackup, jobs: [sourceBackup]) }
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            var copied: Int64 = 0
            await progress(copied)
            for (relative, source) in try files(at: source, isVideo: candidate.isVideo) {
                try Task.checkCancellation()
                let destination = try safeChild(relative, in: staging)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard fm.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let input = try FileHandle(forReadingFrom: source)
                let output = try FileHandle(forWritingTo: destination)
                defer { try? input.close(); try? output.close() }
                var lastReported = copied
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    guard copied + Int64(data.count) <= candidate.bytes else { throw ImportFailure.sourceChanged }
                    try output.write(contentsOf: data)
                    copied += Int64(data.count)
                    if copied - lastReported >= 4 * 1024 * 1024 {
                        await progress(copied); lastReported = copied
                    }
                }
                try output.synchronize()
            }
            var project: [String: Any]
            if candidate.isVideo {
                let copiedFile = staging.appending(path: source.lastPathComponent)
                guard try inspect(copiedFile).fingerprint == candidate.fingerprint else { throw ImportFailure.sourceChanged }
                project = ["file": source.lastPathComponent, "title": title, "type": "video"]
            } else {
                // Verify the copy before editing metadata; preserve unknown manifest fields.
                guard try inspect(staging).fingerprint == candidate.fingerprint else { throw ImportFailure.sourceChanged }
                let manifest = staging.appending(path: "project.json")
                project = try JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as! [String: Any]
                project["title"] = title
            }
            if !preserveMetadata {
                // Probe the verified copy, not the mutable original: the generated cover
                // and playback metadata must describe exactly the bytes being committed.
                let videoInfo: ImportVideoInfo?
                if fresh.videoSourceURL != nil {
                    guard let entry = project["file"] as? String else { throw ImportFailure.sourceChanged }
                    videoInfo = try await ImportMediaPreflight.video(at: safeChild(entry, in: staging))
                } else { videoInfo = nil }
                let newCover: Data?
                switch candidate.coverEdit {
                case .custom: newCover = customCover
                case .remove: newCover = nil
                case .original: newCover = fresh.originalPreviewURL == nil ? videoInfo?.thumbnail : nil
                }
                if let editedTags { project["tags"] = editedTags }
                if case .remove = candidate.coverEdit { project["preview"] = "" }
                if let newCover {
                    var name: String
                    repeat { name = "import-cover-\(UUID().uuidString).jpg" }
                    while fm.fileExists(atPath: staging.appending(path: name).path)
                    try newCover.write(to: staging.appending(path: name), options: .atomic)
                    project["preview"] = name
                }
                try JSONSerialization.data(withJSONObject: project).write(to: staging.appending(path: "project.json"), options: .atomic)
            }
            try JSONEncoder().encode(job).write(to: staging.appending(path: ".motiscape-import.json"), options: .atomic)
            try Task.checkCancellation()
            job.state = .committing; job.updatedAt = Date()
            try await index.save(job)
            try Task.checkCancellation()
            if let sourceBackup { try validateBackupJob(sourceBackup, jobs: [sourceBackup]) }
            if let expectedDestination { try verifyDestination(destination, expected: expectedDestination) }
            // No suspension/cancellation between moving the old item aside and commit.
            if replacement != nil && fm.fileExists(atPath: destination.path) { try moveItem(destination, backup) }
            do { try moveItem(staging, destination) }
            catch {
                if fm.fileExists(atPath: backup.path) {
                    do { try moveItem(backup, destination) }
                    catch { needsRecovery = true; throw error }
                }
                throw error
            }
            committed = true
            job.state = .completed; job.updatedAt = Date()
            try await index.complete(job)
            // Keep replacement backups recoverable; cleanup is a separate user action.
            await progress(candidate.bytes)
            return record
        } catch {
            if staging.resolvingSymlinksInPath().path != staging.path { needsRecovery = true }
            if !committed && !needsRecovery {
                if fm.fileExists(atPath: staging.path) { try? fm.removeItem(at: staging) }
                job.state = error is CancellationError ? .cancelled : .failed
                // Cancellation is an expected user outcome, not a low-level
                // failure message. Preserve diagnostics for real copy errors.
                job.error = error is CancellationError ? nil : error.localizedDescription; job.updatedAt = Date()
                try? await index.save(job)
            }
            // After a filesystem commit, leave the durable "committing" journal
            // intact if metadata saving fails. Recovery finishes that transaction.
            throw error
        }
    }

    func backups() async throws -> [ImportBackup] {
        guard !running else { throw ImportFailure.busy }
        running = true
        defer { running = false }
        let jobs = try await history()
        var result: [ImportBackup] = []
        for job in jobs where UUID(uuidString: job.id) != nil {
            try Task.checkCancellation()
            let expected = root.appending(path: ".importing/\(job.id).backup")
            // Only enumerate paths derived from a journal UUID; never trust its raw backup field.
            guard try nodeExists(expected) else { continue }
            var item = ImportBackup(id: job.id, root: root.path, path: expected.path,
                destination: job.destination, title: L("备份 · %@", String(job.id.prefix(8))), date: job.updatedAt)
            do {
                try validateBackupJob(job, jobs: jobs)
                let candidate = try inspect(expected)
                item.title = candidate.title; item.bytes = candidate.bytes; item.fingerprint = candidate.fingerprint
                item.destinationFingerprint = try destinationFingerprint(URL(fileURLWithPath: job.destination))
            } catch is CancellationError { throw CancellationError() }
            catch { item.issue = error.localizedDescription }
            result.append(item)
        }
        return result
    }

    func restoreBackup(_ selected: ImportBackup,
                       progress: @escaping @Sendable (ImportProgress) async -> Void = { _ in }) async throws -> URL {
        guard !running else { throw ImportFailure.busy }
        running = true
        defer { running = false }
        try await guardRetainedTransactions()
        let (job, candidate) = try await checkedBackup(selected)
        var receipt = makeAttempt(candidate, batchID: UUID().uuidString, phase: .backupRestore)
        try await index.saveAttempts([receipt])
        let restored: WallpaperRecord
        do {
            try prepareRoot()
            restored = try await importOne(candidate, id: receipt.id, replacement: job.record,
                expectedDestination: .init(fingerprint: selected.destinationFingerprint), preserveMetadata: true, sourceBackup: job) { copied in
                    await progress(.init(current: 1, total: 1, title: candidate.title,
                                         copiedBytes: copied, totalBytes: candidate.bytes))
                }
        } catch {
            receipt.state = error is CancellationError ? .cancelled : .failed
            receipt.error = error.localizedDescription; receipt.updatedAt = Date()
            try await index.saveAttempts([receipt])
            throw error
        }
        receipt.state = .restored; receipt.destination = restored.id; receipt.updatedAt = Date()
        try await index.saveAttempts([receipt])
        return URL(fileURLWithPath: restored.id)
    }

    func trashBackup(_ selected: ImportBackup) async throws {
        guard !running else { throw ImportFailure.busy }
        running = true
        defer { running = false }
        try await guardRetainedTransactions()
        guard selected.canTrash else { throw ImportBackupError.unavailable }
        let (job, candidate) = try await checkedBackup(selected)
        var receipt = makeAttempt(candidate, batchID: UUID().uuidString, phase: .backupCleanup)
        try await index.saveAttempts([receipt])
        do {
            // Recheck after persistence suspension, immediately before the filesystem action.
            try Task.checkCancellation()
            try validateBackupJob(job, jobs: [job])
            guard try inspect(candidate.source).fingerprint == selected.fingerprint else { throw ImportBackupError.changed }
            try verifyDestination(URL(fileURLWithPath: selected.destination), expected: .init(fingerprint: selected.destinationFingerprint))
            try trashItem(candidate.source)
        } catch {
            receipt.state = error is CancellationError ? .cancelled : .failed
            receipt.error = error.localizedDescription; receipt.updatedAt = Date()
            try await index.saveAttempts([receipt])
            throw error
        }
        // A receipt failure after trashing must not relabel a successful move as a failed delete.
        receipt.state = .trashed; receipt.updatedAt = Date()
        try await index.saveAttempts([receipt])
    }

    private func checkedBackup(_ selected: ImportBackup) async throws -> (ImportJob, ImportCandidate) {
        _ = try await attempts() // Reject unknown receipt versions before new actions.
        guard selected.canManage, selected.root == root.path else { throw ImportBackupError.unavailable }
        let jobs = try await history()
        guard let job = jobs.first(where: { $0.id == selected.id }), job.backup == selected.path,
              job.destination == selected.destination else { throw ImportBackupError.unavailable }
        try validateBackupJob(job, jobs: jobs)
        let candidate = try inspect(URL(fileURLWithPath: job.backup))
        guard candidate.fingerprint == selected.fingerprint else { throw ImportBackupError.changed }
        try verifyDestination(URL(fileURLWithPath: job.destination), expected: .init(fingerprint: selected.destinationFingerprint))
        return (job, candidate)
    }

    private func validateBackupJob(_ job: ImportJob, jobs: [ImportJob]) throws {
        guard job.state == .completed,
              !jobs.contains(where: { $0.destination == job.destination && ($0.state == .copying || $0.state == .committing) })
        else { throw ImportBackupError.pendingTransaction }
        let path = root.appending(path: ".importing/\(job.id).backup")
        let parent = root.appending(path: ".importing")
        guard UUID(uuidString: job.id) != nil, job.backup == path.path,
              job.staging == root.appending(path: ".importing/\(job.id)").path,
              job.record.id == job.destination, isManagedDestination(URL(fileURLWithPath: job.destination)),
              parent.resolvingSymlinksInPath().path == parent.path,
              path.resolvingSymlinksInPath().path == path.path,
              (try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try path.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true
        else { throw ImportBackupError.unavailable }
    }

    private func nodeExists(_ url: URL) throws -> Bool {
        var attributes = stat()
        if lstat(url.path, &attributes) == 0 { return true }
        guard errno == ENOENT else { throw CocoaError(.fileReadUnknown) }
        return false
    }

    private func destinationFingerprint(_ url: URL) throws -> String? {
        guard isManagedDestination(url) else { throw ImportBackupError.unavailable }
        return try nodeExists(url) ? inspect(url).fingerprint : nil
    }

    private func verifyDestination(_ url: URL, expected: ImportDestinationSnapshot) throws {
        guard try destinationFingerprint(url) == expected.fingerprint else { throw ImportBackupError.changed }
    }

    private func makeAttempt(_ candidate: ImportCandidate, batchID: String,
                             phase: ImportAttemptRecord.Phase) -> ImportAttemptRecord {
        let id = UUID().uuidString, now = Date()
        return ImportAttemptRecord(id: id, batchID: batchID, candidateID: candidate.id.uuidString,
            root: root.path, source: candidate.displaySource, title: candidate.title, phase: phase,
            state: .pending, transactionID: [.confirmed, .backupRestore].contains(phase) ? id : nil, createdAt: now, updatedAt: now)
    }

    func attempts() async throws -> [ImportAttemptRecord] {
        try await index.records(ImportAttemptRecord.self).filter {
            URL(fileURLWithPath: $0.root).resolvingSymlinksInPath().standardizedFileURL.path == root.path
        }
    }

    func historyEntries() async throws -> [ImportHistoryEntry] {
        try await ImportHistoryEntry.merged(attempts: attempts(), jobs: history())
    }

    func history() async throws -> [ImportJob] {
        try await index.records(ImportJob.self).filter { belongsToRoot($0) }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    private func belongsToRoot(_ job: ImportJob) -> Bool {
        URL(fileURLWithPath: job.destination).deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path == root.path
    }

    func recover() async throws -> [ImportJob] {
        let report = try await recoverReport()
        if !report.issues.isEmpty { throw ImportFailure.unsafePath }
        return report.recovered
    }

    func recoverReport() async throws -> ImportRecoveryReport {
        guard !running else { throw ImportFailure.busy }
        running = true
        defer { running = false }
        try await guardRetainedTransactions()
        _ = try await attempts()
        let pending = try await history().filter { $0.state == .copying || $0.state == .committing }
        guard !pending.isEmpty else {
            try await reconcileAttempts()
            return ImportRecoveryReport()
        }
        // An unavailable removable library must not become an empty replacement.
        guard fm.fileExists(atPath: root.path) else { throw CocoaError(.fileNoSuchFile) }
        try prepareRoot()
        var report = ImportRecoveryReport()
        for var job in pending {
            try Task.checkCancellation()
            do {
                guard UUID(uuidString: job.id) != nil,
                      job.staging == root.appending(path: ".importing/\(job.id)").path,
                      job.backup == root.appending(path: ".importing/\(job.id).backup").path,
                      isManagedDestination(URL(fileURLWithPath: job.destination)) else { throw ImportFailure.unsafePath }
                // Never restore a symlink backup or traverse a substituted job folder.
                for path in [job.staging, job.backup, job.destination] {
                    if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                        throw ImportFailure.unsafePath
                    }
                }
                let destination = URL(fileURLWithPath: job.destination)
                let markerURL = importMarker(in: destination)
                let marker = recoveryMarker(at: markerURL)
                if marker?.id == job.id, marker?.destination == job.destination,
                   job.record.id == job.destination, fm.fileExists(atPath: destination.appending(path: "project.json").path) {
                    job.state = .completed; job.updatedAt = Date(); job.error = nil
                    try await index.complete(job)
                } else {
                    let backup = URL(fileURLWithPath: job.backup)
                    if !fm.fileExists(atPath: destination.path), fm.fileExists(atPath: backup.path) {
                        try fm.moveItem(at: backup, to: destination)
                    }
                    let staging = URL(fileURLWithPath: job.staging)
                    if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
                    job.state = .interrupted; job.updatedAt = Date()
                    try await index.save(job)
                }
                report.recovered.append(job)
            } catch is CancellationError { throw CancellationError() }
            catch { report.issues.append(.init(id: job.id, title: job.record.title, message: error.localizedDescription)) }
        }
        try await reconcileAttempts()
        return report
    }

    private func reconcileAttempts() async throws {
        let jobs = Dictionary(uniqueKeysWithValues: try await history().map { ($0.id, $0) })
        var updates: [ImportAttemptRecord] = []
        for var attempt in try await attempts() {
            if let id = attempt.transactionID, let job = jobs[id], job.source == attempt.source {
                guard job.state != .copying && job.state != .committing else { continue }
                var state = ImportHistoryEntry.state(job)
                if state == .imported && attempt.phase == .backupRestore { state = .restored }
                let destination = [.imported, .restored].contains(state) && job.record.id == job.destination ? job.destination : nil
                guard attempt.state != state || attempt.destination != destination || attempt.error != job.error else { continue }
                attempt.state = state; attempt.destination = destination; attempt.error = job.error
            } else if attempt.state == .pending {
                attempt.state = .interrupted
                attempt.error = attempt.phase == .backupCleanup
                    ? L("备份清理结果尚未记录，请检查备份列表和废纸篓；不会自动重复清理。")
                    : L("导入在完成记录前中断，请重新选择源文件。")
            } else { continue }
            attempt.updatedAt = Date(); updates.append(attempt)
        }
        try await index.saveAttempts(updates)
    }

    private func recoveryMarker(at url: URL) -> ImportJob? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= 1024 * 1024,
              let data = try? file.read(upToCount: 1024 * 1024 + 1), data.count <= 1024 * 1024 else { return nil }
        return try? JSONDecoder().decode(ImportJob.self, from: data)
    }

    /// After an offline database replacement, missing SQL rows do not imply
    /// that old filesystem transactions are safe to index, replace or remove.
    private func guardRetainedTransactions() async throws {
        guard try await index.requiresFileTransactionReview() else { return }
        guard fm.fileExists(atPath: root.path) else { return }
        guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else { throw ImportFailure.unsafePath }
        let jobs = try await history()
        let valid = jobs.filter { UUID(uuidString: $0.id) != nil
            && $0.staging == root.appending(path: ".importing/\($0.id)").path
            && $0.backup == root.appending(path: ".importing/\($0.id).backup").path
            && $0.record.id == $0.destination && isManagedDestination(URL(fileURLWithPath: $0.destination)) }
        let knownNodes = Set(valid.flatMap { [$0.id, $0.id + ".backup"] })
        let byID = Dictionary(valid.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let temporary = root.appending(path: ".importing")
        if try nodeExists(temporary) {
            guard temporary.resolvingSymlinksInPath().path == temporary.path else { throw LibraryMetadataError.retainedTransactions }
            let nodes = try fm.contentsOfDirectory(atPath: temporary.path)
            guard nodes.count <= maxFiles, nodes.allSatisfy(knownNodes.contains) else { throw LibraryMetadataError.retainedTransactions }
        }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        guard children.count <= maxFiles else { throw ImportFailure.limitExceeded }
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let markerURL = importMarker(in: child)
            if try nodeExists(markerURL) {
                guard let marker = recoveryMarker(at: markerURL), let job = byID[marker.id],
                      job.destination == LibraryIndexPath.identity(child.path), marker.destination == job.destination,
                      marker.record.fingerprint == job.record.fingerprint else { throw LibraryMetadataError.retainedTransactions }
            }
        }
    }

    private func importMarker(in directory: URL) -> URL {
        let names = [".motiscape-import.json"]
        return names.map { directory.appending(path: $0) }
            .first { fm.fileExists(atPath: $0.path) } ?? directory.appending(path: names[0])
    }

    /// Automatic missing-only scan. Existing indexed packages are never hashed
    /// again here. Each checkpoint and its additions are a single transaction.
    func maintainIndex(legacyIndexURL: URL? = nil, batchSize: Int = 16,
        progress: @escaping @Sendable (ImportProgress) async -> Void = { _ in }) async throws -> LibraryIndexScanReport {
        guard !running else { throw ImportFailure.busy }
        guard (1...128).contains(batchSize) else { throw ImportFailure.limitExceeded }
        running = true
        defer { running = false }
        try await guardRetainedTransactions()
        try Task.checkCancellation()
        let previous = try await index.records(LibraryIndexScanRecord.self).first { $0.id == root.path }
        let existing = try await index.records(WallpaperRecord.self)
        let jobs = try await index.records(ImportJob.self).filter {
            URL(fileURLWithPath: LibraryIndexPath.identity($0.destination)).deletingLastPathComponent().path == root.path
        }
        let pendingPaths = Set(jobs.filter { $0.state == .copying || $0.state == .committing }
            .map { LibraryIndexPath.identity($0.destination) })
        var priorRecords: [String: ImportJob] = [:]
        for job in jobs where job.state == .completed {
            let path = LibraryIndexPath.identity(job.destination)
            guard LibraryIndexPath.identity(job.record.id) == path else { continue }
            if priorRecords[path].map({ $0.updatedAt < job.updatedAt }) ?? true { priorRecords[path] = job }
        }
        let legacyDates = try LegacyLibraryAdditionIndex.read(from: legacyIndexURL)?.dates(in: root) ?? [:]
        guard root.resolvingSymlinksInPath().path == root.path else { throw ImportFailure.unsafePath }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .map { root.appending(path: $0.lastPathComponent) }.sorted { $0.path < $1.path }
        guard children.count <= maxFiles else { throw ImportFailure.limitExceeded }
        let existingIDs = Set(existing.map { LibraryIndexPath.identity($0.id) })
        let now = Date()
        var scan = LibraryIndexScanRecord(id: root.path, generation: UUID().uuidString, state: .scanning,
            processed: 0, total: children.count, inserted: 0, preserved: 0, issues: [], startedAt: now, updatedAt: now)
        try Task.checkCancellation()
        try await index.save(scan)
        var persisted = scan
        var additions: [WallpaperRecord] = []
        do {
            for (position, child) in children.enumerated() {
                await progress(.init(current: position + 1, total: children.count, title: child.lastPathComponent,
                    copiedBytes: 0, totalBytes: 0))
                try Task.checkCancellation()
                do {
                    guard !pendingPaths.contains(child.path) else { throw ImportBackupError.pendingTransaction }
                    guard root.resolvingSymlinksInPath().path == root.path, isManagedDestination(child),
                          try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                        throw ImportFailure.unsafePath
                    }
                    if existingIDs.contains(child.path) {
                        scan.preserved += 1
                    } else {
                        let candidate = try inspect(child)
                        let prior = priorRecords[child.path]?.record
                        let date = prior?.addedAt ?? legacyDates[child.path]
                            ?? (try? child.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                        additions.append(WallpaperRecord(id: child.path, source: prior?.source ?? child.path,
                            fingerprint: prior?.fingerprint ?? candidate.fingerprint,
                            title: candidate.title, kind: candidate.kind, addedAt: date))
                        scan.preserved += 1 // atomically reclassified as inserted at commit
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { scan.issues.append(.init(id: child.path, message: error.localizedDescription)) }
                scan.processed += 1
                // Unchanged libraries need only a final checkpoint, not a save
                // per 16 existing items. Error-only progress is saved in chunks.
                if additions.count >= batchSize || (scan.processed - persisted.processed >= 128
                    && scan.issues.count != persisted.issues.count) {
                    scan.updatedAt = Date()
                    scan = try await index.commitIndexScan(scan, records: additions)
                    persisted = scan; additions = []
                }
            }
            try Task.checkCancellation()
            guard root.resolvingSymlinksInPath().path == root.path else { throw ImportFailure.unsafePath }
            scan.state = .completed; scan.updatedAt = Date()
            scan = try await index.commitIndexScan(scan, records: additions)
            return .init(scan: scan, resumed: previous.map { $0.state != .completed } ?? false)
        } catch {
            // Never advance past the last atomic checkpoint after a failed batch.
            persisted.state = .interrupted; persisted.updatedAt = Date()
            persisted.error = error is CancellationError ? L("自动索引检查已暂停，下次刷新将继续补全。") : error.localizedDescription
            _ = try? await index.commitIndexScan(persisted, records: [])
            throw error
        }
    }

    /// Rebuild a missing metadata index from contents without changing files.
    /// Invalid packages remain visible to the caller as issues, never deleted.
    func rebuildIndex() async throws -> [ImportCandidate] {
        try await rebuildIndexReport().candidates
    }

    func rebuildIndexReport(legacyIndexURL: URL? = nil,
        progress: @escaping @Sendable (ImportProgress) async -> Void = { _ in }) async throws -> LibraryIndexRebuildReport {
        guard !running else { throw ImportFailure.busy }
        running = true
        defer { running = false }
        try await guardRetainedTransactions()
        try Task.checkCancellation()
        let existing = try await index.records(WallpaperRecord.self)
        let jobs = try await index.records(ImportJob.self).filter {
            URL(fileURLWithPath: LibraryIndexPath.identity($0.destination)).deletingLastPathComponent().path == root.path
        }
        guard !jobs.contains(where: { $0.state == .copying || $0.state == .committing }) else {
            throw ImportBackupError.pendingTransaction
        }
        var priorRecords: [String: ImportJob] = [:]
        for job in jobs where job.state == .completed {
            try Task.checkCancellation()
            let path = LibraryIndexPath.identity(job.destination)
            guard LibraryIndexPath.identity(job.record.id) == path else { continue }
            if priorRecords[path].map({ $0.updatedAt < job.updatedAt }) ?? true { priorRecords[path] = job }
        }
        let legacyDates = try LegacyLibraryAdditionIndex.read(from: legacyIndexURL)?.dates(in: root) ?? [:]
        // Do not create an offline/missing root or its staging directory.
        guard root.resolvingSymlinksInPath().path == root.path else { throw ImportFailure.unsafePath }
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            // Directory enumeration may return /private/var for a /var root.
            // Keep the child's name (and symlink node), anchored to our root URL.
            .map { root.appending(path: $0.lastPathComponent) }
            .sorted { $0.path < $1.path }
        guard children.count <= maxFiles else { throw ImportFailure.limitExceeded }
        let existingIDs = Set(existing.map { LibraryIndexPath.identity($0.id) })
        var result: [ImportCandidate] = []
        var additions: [WallpaperRecord] = []
        for (position, child) in children.enumerated() {
            await progress(.init(current: position + 1, total: children.count, title: child.lastPathComponent,
                copiedBytes: 0, totalBytes: 0))
            try Task.checkCancellation()
            do {
                guard root.resolvingSymlinksInPath().path == root.path, isManagedDestination(child) else {
                    throw ImportFailure.unsafePath
                }
                let candidate = try inspect(child)
                result.append(candidate)
                if !existingIDs.contains(child.path) {
                    let prior = priorRecords[child.path]?.record
                    let addedAt = prior?.addedAt ?? legacyDates[child.path]
                        ?? (try? child.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                    additions.append(WallpaperRecord(id: child.path, source: prior?.source ?? child.path,
                        fingerprint: prior?.fingerprint ?? candidate.fingerprint,
                        title: candidate.title, kind: candidate.kind, addedAt: addedAt))
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.append(ImportCandidate(id: UUID(), source: child, title: child.lastPathComponent,
                    kind: "unknown", bytes: 0, fingerprint: "", isVideo: false, issue: error.localizedDescription))
            }
        }
        try Task.checkCancellation()
        guard root.resolvingSymlinksInPath().path == root.path else { throw ImportFailure.unsafePath }
        // Database errors abort the operation, not a misleading per-file failure.
        let inserted = try await index.insertMissingWallpapers(additions)
        return LibraryIndexRebuildReport(candidates: result, insertedIDs: inserted)
    }
}
