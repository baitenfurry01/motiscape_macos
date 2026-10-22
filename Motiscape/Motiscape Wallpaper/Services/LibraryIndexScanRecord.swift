import Foundation

struct LibraryIndexScanRecord: LibraryMetadataRecord {
    static let category = "libraryIndexScan"
    enum State: String, Codable, Sendable { case scanning, completed, interrupted }
    struct Issue: Codable, Sendable, Identifiable {
        var id: String
        var message: String
    }
    var version = 1
    var id: String // canonical imported root, not a cursor into arbitrary paths
    var generation: String
    var state: State
    var processed: Int
    var total: Int
    var inserted: Int
    var preserved: Int
    var issues: [Issue]
    var error: String?
    var startedAt: Date
    var updatedAt: Date

    func validate() throws {
        guard version == 1 else { throw LibraryMetadataError.unsupportedVersion(version) }
        guard id.hasPrefix("/"), !id.contains("\0"), UUID(uuidString: generation) != nil,
              processed >= 0, total >= processed, total <= 100_000,
              inserted >= 0, inserted <= processed, preserved >= 0, preserved <= processed, issues.count <= processed,
              inserted + preserved + issues.count == processed,
              state != .completed || processed == total,
              Set(issues.map(\.id)).count == issues.count,
              issues.allSatisfy({ URL(fileURLWithPath: $0.id).deletingLastPathComponent().path == id
                  && !URL(fileURLWithPath: $0.id).lastPathComponent.hasPrefix(".") }),
              startedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

struct LibraryIndexScanReport: Sendable {
    let scan: LibraryIndexScanRecord
    let resumed: Bool
}
