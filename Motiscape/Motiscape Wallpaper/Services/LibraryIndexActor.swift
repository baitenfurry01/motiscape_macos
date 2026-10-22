import Foundation
import SwiftData

/// SwiftData stores metadata only. Wallpaper contents remain authoritative on disk.
/// The payload version is separate from the storage schema so old jobs can be
/// decoded/migrated without silently discarding a user's queue.
enum LibraryMetadataSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Entry.self] }

    @Model final class Entry {
        @Attribute(.unique) var key: String
        var category: String
        var payloadVersion: Int
        var payload: Data

        init(key: String, category: String, payload: Data) {
            self.key = key
            self.category = category
            self.payloadVersion = 1
            self.payload = payload
        }
    }
}

enum LibraryMetadataMigration: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LibraryMetadataSchema.self] }
    static var stages: [MigrationStage] { [] }
}

protocol LibraryMetadataRecord: Codable, Sendable {
    static var category: String { get }
    var id: String { get }
}

struct WallpaperRecord: LibraryMetadataRecord {
    static let category = "wallpaper"
    var id: String // standardized directory path; never a user-supplied relative path
    var source: String
    var fingerprint: String
    var title: String
    var kind: String
    var addedAt: Date
}

struct ImportJob: LibraryMetadataRecord {
    static let category = "import"
    enum State: String, Codable { case copying, committing, completed, failed, cancelled, interrupted }
    var id: String
    var source: String
    var destination: String
    var staging: String
    var backup: String
    var state: State
    var record: WallpaperRecord
    var error: String?
    var updatedAt: Date
}

enum LibraryMetadataError: LocalizedError {
    case unsupportedVersion(Int)
    case nonemptyRestoreTarget
    case unsafeFile, inUse, restartRequired
    case maintenancePending, retainedTransactions, awaitingRestoreChoice
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return L("无法读取元数据版本：%d", version)
        case .nonemptyRestoreTarget: return L("为避免覆盖现有记录，只能恢复到空的元数据库")
        case .unsafeFile: return L("元数据文件路径、类型或大小不安全，已保留原文件。")
        case .inUse: return L("元数据库正由另一个应用进程使用，请关闭另一个实例后重试。")
        case .restartRequired: return L("元数据已恢复。为避免旧任务覆盖恢复结果，请退出并重新打开应用。")
        case .maintenancePending: return L("已安排数据库维护，请退出并重新打开应用以进入独立维护窗口。")
        case .retainedTransactions: return L("旧数据库已保留；此资料库还有未核对的文件事务。请先恢复可信的元数据备份，不会自动覆盖或清理这些文件。")
        case .awaitingRestoreChoice: return L("新元数据库仍为空，自动索引已暂缓。请先在元数据库维护中恢复备份；若不需要旧历史，可手动补全已有内容的索引或导入壁纸。")
        }
    }
}

actor LibraryIndexActor {
    private let container: ModelContainer
    private let access: LibraryMetadataAccess

    init(directory: URL) throws {
        let gate = try LibraryMetadataAccess.shared(directory: directory)
        access = gate
        try gate.enter(); defer { gate.leave() }
        try gate.validateStoreFiles()
        let storeDirectory = try gate.storeDirectory()
        let schema = Schema(versionedSchema: LibraryMetadataSchema.self)
        let configuration = ModelConfiguration("LibraryMetadata", schema: schema,
            url: storeDirectory.appending(path: "metadata.store"), cloudKitDatabase: .none)
        // Failure is surfaced to the caller. Never delete a corrupt/newer database
        // and pretend that the user's pending jobs were successfully restored.
        gate.willOpenContainer()
        container = try ModelContainer(for: schema, migrationPlan: LibraryMetadataMigration.self,
                                       configurations: [configuration])
    }

    func requiresFileTransactionReview() throws -> Bool {
        try access.enter(); defer { access.leave() }
        return try LibraryMetadataRecovery(directory: access.directory).hasRetainedDatabase()
    }

    /// A maintenance-created empty generation must stay restorable until the
    /// user chooses restore or explicitly writes new content. An automatic scan
    /// checkpoint alone would otherwise make even an empty library nonempty.
    func shouldDeferAutomaticIndexForRestore() throws -> Bool {
        try access.enter(); defer { access.leave() }
        return try LibraryMetadataRecovery(directory: access.directory).hasRetainedDatabase()
            && maintenanceStatus().canRestore
    }

    func records<T: LibraryMetadataRecord>(_ type: T.Type) throws -> [T] {
        try access.enter(); defer { access.leave() }
        let context = ModelContext(container)
        let category = T.category
        let rows = try context.fetch(FetchDescriptor<LibraryMetadataSchema.Entry>(
            predicate: #Predicate { $0.category == category }))
        return try rows.map { row in
            guard row.payloadVersion == 1 else { throw LibraryMetadataError.unsupportedVersion(row.payloadVersion) }
            let record = try JSONDecoder().decode(T.self, from: row.payload)
            guard row.key == T.category + ":" + record.id else { throw CocoaError(.fileReadCorruptFile) }
            if let attempt = record as? ImportAttemptRecord { try attempt.validate() }
            if let scan = record as? LibraryIndexScanRecord { try scan.validate() }
            return record
        }
    }

    func save<T: LibraryMetadataRecord>(_ record: T) throws {
        try access.enter(); defer { access.leave() }
        let context = ModelContext(container)
        try upsert(record, in: context)
        try context.save()
    }

    func complete(_ job: ImportJob) throws {
        try access.enter(); defer { access.leave() }
        let context = ModelContext(container)
        try upsert(job.record, in: context)
        try upsert(job, in: context)
        try context.save()
    }

    func saveAttempts(_ attempts: [ImportAttemptRecord]) throws {
        try access.enter(); defer { access.leave() }
        guard !attempts.isEmpty else { return }
        let context = ModelContext(container)
        for attempt in attempts {
            try attempt.validate()
            try upsert(attempt, in: context)
        }
        try context.save()
    }

    /// One transaction, no suspension between checking existing keys and saving.
    /// Rebuild must never upsert a newer import's source fingerprint or history.
    func insertMissingWallpapers(_ records: [WallpaperRecord]) throws -> Set<String> {
        try access.enter(); defer { access.leave() }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let inserted = try stageMissingWallpapers(records, in: context)
        try Task.checkCancellation()
        try context.save()
        return inserted
    }

    /// Contents and the resumable checkpoint advance in the same SQLite save.
    func commitIndexScan(_ scan: LibraryIndexScanRecord, records: [WallpaperRecord]) throws -> LibraryIndexScanRecord {
        try access.enter(); defer { access.leave() }
        try scan.validate()
        guard records.count <= scan.preserved, Set(records.map(\.id)).count == records.count,
              records.allSatisfy({ URL(fileURLWithPath: LibraryIndexPath.identity($0.id)).deletingLastPathComponent().path == scan.id
                  && !URL(fileURLWithPath: $0.id).lastPathComponent.hasPrefix(".") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let previous = try self.records(LibraryIndexScanRecord.self).first { $0.id == scan.id }
        guard previous?.generation == scan.generation else { throw LibraryIndexRebuildError.rootChanged }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        // An interrupted checkpoint is allowed to be saved from a cancelled task.
        let inserted = records.isEmpty ? Set<String>() : try stageMissingWallpapers(records, in: context)
        var checked = scan
        checked.inserted += inserted.count
        // The caller counts staged candidates as preserved until actual commit.
        checked.preserved -= inserted.count
        try checked.validate()
        try upsert(checked, in: context)
        if checked.state != .interrupted { try Task.checkCancellation() }
        try context.save()
        return checked
    }

    private func stageMissingWallpapers(_ records: [WallpaperRecord], in context: ModelContext) throws -> Set<String> {
        try Task.checkCancellation()
        let saved = try self.records(WallpaperRecord.self)
        var knownPaths = Set(saved.map { LibraryIndexPath.identity($0.id) })
        let jobs = try self.records(ImportJob.self)
        let pending = Set(jobs.filter { $0.state == .copying || $0.state == .committing }.map { LibraryIndexPath.identity($0.destination) })
        var inserted = Set<String>()
        for record in records {
            try Task.checkCancellation()
            guard record.id.hasPrefix("/"), record.addedAt.timeIntervalSince1970.isFinite else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let identity = LibraryIndexPath.identity(record.id)
            guard !pending.contains(identity) else { throw ImportBackupError.pendingTransaction }
            guard !knownPaths.contains(identity) else { continue }
            let key = WallpaperRecord.category + ":" + record.id
            let existing = try context.fetch(FetchDescriptor<LibraryMetadataSchema.Entry>(predicate: #Predicate { $0.key == key }))
            guard existing.allSatisfy({ $0.category == WallpaperRecord.category && $0.payloadVersion == 1 }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if existing.isEmpty {
                context.insert(LibraryMetadataSchema.Entry(key: key, category: WallpaperRecord.category,
                    payload: try JSONEncoder().encode(record)))
                inserted.insert(record.id)
                knownPaths.insert(identity)
            }
        }
        return inserted
    }

    private func upsert<T: LibraryMetadataRecord>(_ record: T, in context: ModelContext) throws {
        if let scan = record as? LibraryIndexScanRecord { try scan.validate() }
        let key = T.category + ":" + record.id
        let data = try JSONEncoder().encode(record)
        let rows = try context.fetch(FetchDescriptor<LibraryMetadataSchema.Entry>(
            predicate: #Predicate { $0.key == key }))
        if let row = rows.first {
            guard row.category == T.category else { throw CocoaError(.fileReadCorruptFile) }
            guard row.payloadVersion == 1 else { throw LibraryMetadataError.unsupportedVersion(row.payloadVersion) }
            if T.category == ImportAttemptRecord.category {
                try JSONDecoder().decode(ImportAttemptRecord.self, from: row.payload).validate()
            }
            if T.category == LibraryIndexScanRecord.category {
                try JSONDecoder().decode(LibraryIndexScanRecord.self, from: row.payload).validate()
            }
            row.payload = data
        }
        else { context.insert(LibraryMetadataSchema.Entry(key: key, category: T.category, payload: data)) }
    }

    /// Export a logical backup after reading on the serial actor, never copy a
    /// live SQLite file without its WAL. No wallpaper files are touched.
    func backup(to url: URL) throws {
        try access.enter(); defer { access.leave() }
        // Never let an export panel overwrite SQLite, WAL, journals or ZIP caches.
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard url.isFileURL, url.pathExtension.lowercased() == "json",
              target != access.directory.path, !target.hasPrefix(access.directory.path + "/") else { throw LibraryMetadataError.unsafeFile }
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LibraryMetadataSchema.Entry>())
        let backup = LibraryMetadataBackup(records: rows.map { LibraryMetadataBackup.Row(key: $0.key, category: $0.category,
                                                   version: $0.payloadVersion, payload: $0.payload) })
        let data = try JSONEncoder().encode(backup)
        guard rows.count <= LibraryMetadataBackup.rowLimit, data.count <= LibraryMetadataBackup.byteLimit else { throw LibraryMetadataError.unsafeFile }
        try Task.checkCancellation()
        try LibraryMetadataBackup.write(data, to: url)
    }

    func restore(from url: URL) throws {
        try restore(data: LibraryMetadataBackup.read(url), requiringRestart: false)
    }

    func maintenanceStatus() throws -> (count: Int, canRestore: Bool) {
        try access.enter(); defer { access.leave() }
        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<LibraryMetadataSchema.Entry>())
        return (rows.count, rows.allSatisfy(Self.isBootstrapQueue))
    }

    private static func isBootstrapQueue(_ row: LibraryMetadataSchema.Entry) -> Bool {
        guard row.key == "downloadQueue:main", row.category == DownloadQueueRecord.category, row.payloadVersion == 1,
              let queue = try? JSONDecoder().decode(DownloadQueueRecord.self, from: row.payload) else { return false }
        return queue.id == "main" && queue.version == 1 && queue.concurrency == 3 && queue.jobs.isEmpty && queue.history.isEmpty
    }

    func restore(data: Data, requiringRestart: Bool) throws {
        let backup = try LibraryMetadataBackup.decode(data)
        try access.enter(); defer { access.leave() }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<LibraryMetadataSchema.Entry>())
        guard existing.isEmpty || (requiringRestart && existing.allSatisfy(Self.isBootstrapQueue))
        else { throw LibraryMetadataError.nonemptyRestoreTarget }
        for row in existing { context.delete(row) }
        for row in backup.records {
            context.insert(LibraryMetadataSchema.Entry(key: row.key, category: row.category, payload: row.payload))
        }
        try Task.checkCancellation()
        try context.save()
        if requiringRestart { access.requireRestart() }
    }
}
