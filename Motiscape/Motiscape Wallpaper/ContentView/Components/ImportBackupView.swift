import SwiftUI

struct ImportBackupView: View {
    @Bindable var session: ImportSession
    @State private var selection: ImportBackup?
    @State private var restoring = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("替换备份")).font(.title2.bold())
            Text(L("恢复会保留当前版本和所选备份；清理只会把所选备份移到废纸篓。"))
                .font(.callout).foregroundStyle(.secondary)
            if let root = session.backupRoot { Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if let error = session.backupError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if let message = session.backupMessage { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            if session.isLoadingBackups { ProgressView(L("正在校验备份内容…")) }
            // Keep each native action accessible; selectable List rows merge
            // both buttons into a single element in the macOS AX tree.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(session.backups) { backup in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(backup.title).font(.headline)
                                Spacer()
                                Text(backup.date, style: .date).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(backup.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled).help(backup.path)
                            if let issue = backup.issue {
                                Text(issue).font(.caption).foregroundStyle(.red)
                            } else {
                                Text(ByteCountFormatter.string(fromByteCount: backup.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                if backup.destinationFingerprint == nil {
                                    Text(L("目标已不存在，仅允许恢复备份。")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            HStack {
                                Button(L("恢复此备份")) { selection = backup; restoring = true }
                                    .accessibilityLabel(L("恢复此备份") + " · " + backup.title)
                                    .accessibilityIdentifier("backup.restore." + backup.id)
                                    .disabled(session.isWorking || !backup.canManage)
                                Button(L("移到废纸篓"), role: .destructive) { selection = backup; restoring = false }
                                    .accessibilityLabel(L("移到废纸篓") + " · " + backup.title)
                                    .accessibilityIdentifier("backup.trash." + backup.id)
                                    .disabled(session.isWorking || !backup.canTrash)
                            }.controlSize(.small)
                        }
                        .padding(.vertical, 5)
                        Divider()
                    }
                }.padding(.horizontal, 12)
            }
            .overlay {
                if session.backups.isEmpty && !session.isLoadingBackups && session.backupError == nil {
                    ContentUnavailableView(L("暂无替换备份"), systemImage: "archivebox")
                }
            }
            if session.isManagingBackup {
                if let progress = session.progress {
                    ProgressView(value: Double(progress.copiedBytes), total: Double(max(1, progress.totalBytes)))
                } else { ProgressView(L("正在处理备份…")) }
            }
            HStack {
                Button(L("关闭")) { session.isBackupsPresented = false }.keyboardShortcut(.cancelAction)
                    .disabled(session.isManagingBackup)
                if session.isManagingBackup || session.isLoadingBackups { Button(L("取消")) { session.cancel() } }
                Spacer()
                Button(L("重新检查")) { session.refreshBackups() }.disabled(session.isWorking)
            }
        }.padding(24).frame(width: 680, height: 540)
        .onDisappear { if session.isLoadingBackups { session.cancel() } }
        .interactiveDismissDisabled(session.isManagingBackup)
        .confirmationDialog(restoring ? L("恢复此备份？") : L("将此备份移到废纸篓？"),
            isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }),
            titleVisibility: .visible) {
                if let backup = selection {
                    Button(restoring ? L("恢复此备份") : L("移到废纸篓"), role: restoring ? nil : .destructive) {
                        session.manageBackup(backup, restore: restoring); selection = nil
                    }
                }
                Button(L("取消"), role: .cancel) { selection = nil }
            } message: {
                if let backup = selection {
                    Text(backup.title + "\n" + backup.destination + "\n" + (restoring
                        ? L("当前版本将另存备份；内容已变化时会拒绝操作。")
                        : L("仅清理所选备份，不删除当前壁纸。可以从废纸篓取回。")))
                }
            }
    }
}
