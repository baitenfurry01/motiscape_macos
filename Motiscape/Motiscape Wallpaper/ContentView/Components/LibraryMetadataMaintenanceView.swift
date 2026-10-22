import SwiftUI

struct LibraryMetadataMaintenanceView: View {
    @Bindable var session: LibraryMetadataMaintenance
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var schedulingRecovery = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("元数据库维护")).font(.title2.bold())
            Text(L("备份包含索引、导入历史和下载队列，不包含壁纸文件、ZIP 快照或 Steam 凭据。备份中的路径按原样保留，仅恢复您信任的备份。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(session.directory.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
            if session.isWorking { ProgressView(L("正在处理元数据…")) }
            if let error = session.databaseError ?? session.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).lineLimit(4).help(error)
                Text(L("未删除或隔离原数据库。若数据库损坏，请保留 metadata.store 及其 WAL/SHM 文件；不要在应用运行时移动这些文件。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = session.error, session.databaseError != nil && session.databaseError != error {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(3).help(error)
            }
            if let message = session.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            Form {
                Section(L("当前数据库")) {
                    if let count = session.count { countRow("记录数", count) }
                    Text(session.canRestore ? L("空库，可恢复备份；初始空下载队列不计为用户记录。")
                         : L("仅允许恢复到空库，不合并或覆盖已有记录。"))
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(L("导出元数据备份…")) { session.chooseExport() }.disabled(session.count == nil)
                        Button(L("选择备份预检…")) { session.chooseBackup() }
                    }
                    Button(L("安排保全并创建空库…")) { schedulingRecovery = true }
                }
                if let preview = session.preview {
                    Section(L("待恢复备份")) {
                        if let source = session.selectedSource { Text(source.path).font(.caption).textSelection(.enabled) }
                        countRow("记录数", preview.total)
                        countRow("壁纸索引", preview.counts[WallpaperRecord.category, default: 0])
                        countRow("导入事务", preview.counts[ImportJob.category, default: 0])
                        countRow("导入尝试", preview.counts[ImportAttemptRecord.category, default: 0])
                        countRow("索引检查点", preview.counts[LibraryIndexScanRecord.category, default: 0])
                        countRow("下载队列记录", preview.counts[DownloadQueueRecord.category, default: 0])
                        countRow("下载任务", preview.downloads)
                        Text(L("其中 %d 项导入事务需要重启后核对；下载任务不会自动继续。", preview.pendingImports))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("SHA-256: \(preview.digest)").font(.caption2).textSelection(.enabled)
                    }
                }
            }.formStyle(.grouped).disabled(session.isWorking || session.needsRestart)
            HStack {
                Button(L("关闭")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(session.isWorking)
                Spacer()
                if session.preview != nil && !session.needsRestart {
                    Button(L("恢复此备份…")) { confirming = true }.buttonStyle(.borderedProminent)
                        .disabled(!session.canRestore || session.isWorking)
                }
                Button(L("重新检查")) { session.refresh() }.disabled(session.isWorking || session.needsRestart)
            }
        }.padding(24).frame(width: 720, height: 640)
        .interactiveDismissDisabled(session.isWorking)
        .confirmationDialog(L("恢复元数据并在完成后重启？"), isPresented: $confirming) {
            Button(L("确认恢复")) { session.restoreConfirmed() }
        } message: {
            Text(L("仅恢复已预检的备份内容，不复制壁纸。完成后必须退出并重新打开应用，旧任务将被禁止写入。已有用户记录不会被覆盖。"))
        }
        .confirmationDialog(L("安排下次启动进行独立维护？"), isPresented: $schedulingRecovery) {
            Button(L("安排维护")) { session.scheduleRecovery() }
        } message: {
            Text(L("本次不会移动或删除数据库。退出重开后将进入独立维护窗口，再次确认后才保全旧库并创建空库；旧历史不会自动迁入。"))
        }
    }

    private func countRow(_ key: String, _ count: Int) -> some View {
        LabeledContent(L(key), value: "\(count)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L(key))
            .accessibilityValue("\(count)")
    }
}
