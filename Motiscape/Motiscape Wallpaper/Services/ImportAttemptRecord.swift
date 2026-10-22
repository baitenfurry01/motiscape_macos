import Foundation

struct ImportAttemptRecord: LibraryMetadataRecord {
    static let category = "importAttempt"
    enum Phase: String, Codable, Sendable { case preflight, confirmed, backupRestore, backupCleanup }
    enum State: String, Codable, Sendable { case pending, imported, skipped, failed, cancelled, interrupted, restored, trashed }
    var version = 1
    var id: String
    var batchID: String
    var candidateID: String
    var root: String
    var source: String
    var title: String
    var phase: Phase
    var state: State
    var transactionID: String?
    var destination: String?
    var error: String?
    var createdAt: Date
    var updatedAt: Date

    func validate() throws {
        guard version == 1 else { throw LibraryMetadataError.unsupportedVersion(version) }
        guard UUID(uuidString: id) != nil, UUID(uuidString: batchID) != nil,
              UUID(uuidString: candidateID) != nil, root.hasPrefix("/"),
              transactionID == nil || UUID(uuidString: transactionID!) != nil,
              transactionID == nil || ([Phase.confirmed, .backupRestore].contains(phase) && transactionID == id),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

protocol ImportMetadataStore: Sendable {
    func requiresFileTransactionReview() async throws -> Bool
    func records<T: LibraryMetadataRecord>(_ type: T.Type) async throws -> [T]
    func save<T: LibraryMetadataRecord>(_ record: T) async throws
    func complete(_ job: ImportJob) async throws
    func saveAttempts(_ attempts: [ImportAttemptRecord]) async throws
    func insertMissingWallpapers(_ records: [WallpaperRecord]) async throws -> Set<String>
    func commitIndexScan(_ scan: LibraryIndexScanRecord, records: [WallpaperRecord]) async throws -> LibraryIndexScanRecord
}

extension ImportMetadataStore {
    func requiresFileTransactionReview() async throws -> Bool { false }
}

extension LibraryIndexActor: ImportMetadataStore {}

/// Presentation projection: old journals remain visible without a destructive migration.
struct ImportHistoryEntry: Identifiable, Sendable {
    let id: String
    let title: String
    let source: String
    let date: Date
    let state: ImportAttemptRecord.State
    let error: String?
    let destination: String?
    let phase: ImportAttemptRecord.Phase?
    let batchID: String?

    static func state(_ job: ImportJob) -> ImportAttemptRecord.State {
        switch job.state {
        case .copying, .committing: return .pending
        case .completed: return .imported
        case .failed: return .failed
        case .cancelled: return .cancelled
        case .interrupted: return .interrupted
        }
    }

    static func merged(attempts: [ImportAttemptRecord], jobs: [ImportJob]) -> [Self] {
        let jobMap = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0) })
        let confirmed = Set(attempts.filter { $0.phase == .confirmed }.map(\.candidateID))
        var linked = Set<String>()
        var entries: [Self] = []
        for attempt in attempts {
            // A failed scan handed to a confirmed batch is one visible result, not two.
            if attempt.phase == .preflight && confirmed.contains(attempt.candidateID) { continue }
            let job = attempt.transactionID.flatMap { jobMap[$0] }.flatMap { job in
                job.source == attempt.source ? job : nil
            }
            if let job { linked.insert(job.id) }
            var state = job.map(Self.state) ?? attempt.state
            if state == .imported && attempt.phase == .backupRestore { state = .restored }
            entries.append(Self(id: "attempt:" + attempt.id, title: attempt.title, source: attempt.source,
                date: max(attempt.updatedAt, job?.updatedAt ?? attempt.updatedAt), state: state,
                error: job != nil ? job?.error : attempt.error,
                destination: job.map { $0.record.id == $0.destination ? $0.destination : nil } ?? attempt.destination,
                phase: attempt.phase, batchID: attempt.batchID))
        }
        for job in jobs where !linked.contains(job.id) {
            entries.append(Self(id: "transaction:" + job.id, title: job.record.title, source: job.source,
                date: job.updatedAt, state: state(job), error: job.error,
                destination: job.record.id == job.destination ? job.destination : nil, phase: nil, batchID: nil))
        }
        return entries.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
