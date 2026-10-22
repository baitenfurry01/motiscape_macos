import Foundation

enum ImportBackupError: LocalizedError {
    case changed, unavailable, pendingTransaction
    var errorDescription: String? {
        switch self {
        case .changed: return L("备份或目标在检查后发生变化，请刷新后重新确认。")
        case .unavailable: return L("备份不可用或路径不安全，未修改任何文件。")
        case .pendingTransaction: return L("该壁纸有未完成的事务，请先重新检查恢复结果。")
        }
    }
}

struct ImportBackup: Identifiable, Sendable {
    let id: String // owning import job UUID
    let root: String
    let path: String
    let destination: String
    var title: String
    let date: Date
    var bytes: Int64 = 0
    var fingerprint: String?
    var destinationFingerprint: String?
    var issue: String?
    var canManage: Bool { issue == nil && fingerprint != nil }
    var canTrash: Bool { canManage && destinationFingerprint != nil }
}

struct ImportDestinationSnapshot: Sendable {
    let fingerprint: String? // nil means the destination did not exist at confirmation
}
