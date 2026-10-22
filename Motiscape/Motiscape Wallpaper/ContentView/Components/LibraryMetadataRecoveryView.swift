import SwiftUI

struct LibraryMetadataRecoveryView: View {
    @Bindable var session: LibraryMetadataRecoverySession
    @State private var confirming = false
    @State private var confirmingRollback = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("独立数据库维护")).font(.title2.bold())
            Text(L("此窗口不会启动导入、下载或壁纸播放。先完整保全原 SQLite、WAL、SHM，再创建空数据库并切换；原文件不移动、不删除。"))
                .font(.callout).foregroundStyle(.secondary)
            Text(session.recovery.directory.path).font(.caption).textSelection(.enabled)
            if session.isWorking { ProgressView(L("正在保全并检查数据库，请勿退出…")) }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled).lineLimit(4).help(error)
            }
            if session.acknowledged {
                Text(session.request?.phase == .cancelled ? L("维护已取消，原数据库选择未改变。请退出并重新打开应用。")
                    : L("维护回执已保存。请退出此窗口并重新打开应用；旧数据库及保全副本仍保留。"))
            }
            if let request = session.request {
                Form {
                    Section(L("维护状态")) {
                        Text(Self.phase(request.phase))
                        Text(L("旧历史和下载队列不会自动迁入。新库不会自动继续旧下载；发现未核对的导入文件事务时，会阻止导入和索引，直到恢复可信元数据。"))
                            .font(.callout).foregroundStyle(.secondary)
                        Text(session.recovery.preservationDirectory(request).path).font(.caption).textSelection(.enabled)
                    }
                    Section(L("原数据库文件")) {
                        if request.files.isEmpty { Text(L("将在独立检查后记录实际文件及指纹。")) }
                        ForEach(request.files, id: \.name) { file in
                            VStack(alignment: .leading, spacing: 4) {
                                LabeledContent(file.name, value: ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                                Text("SHA-256: \(file.sha256)").font(.caption2).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(file.name)
                            .accessibilityValue("\(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file)), SHA-256: \(file.sha256)")
                        }
                    }
                }.formStyle(.grouped)
            } else { Spacer() }
            HStack {
                Button(L("退出")) { NSApplication.shared.terminate(nil) }.disabled(session.isWorking)
                Spacer()
                if !session.acknowledged {
                    if session.request?.phase == .switched || session.request?.phase == .rolledBack {
                        if session.request?.phase == .switched {
                            Button(L("回退到原数据库…")) { confirmingRollback = true }.disabled(session.isWorking)
                        }
                        Button(L("确认保留旧库并结束维护")) { session.acknowledge() }.disabled(session.isWorking)
                    } else {
                        Button(L("取消维护，保留原库")) { session.cancelBeforeSwitch() }.disabled(session.isWorking || session.request == nil)
                        Button(L("保全原库并创建空库…")) { confirming = true }
                            .buttonStyle(.borderedProminent).disabled(session.isWorking || session.request == nil)
                    }
                }
            }
        }.padding(24).frame(width: 740, height: 640)
        .confirmationDialog(L("保全原数据库后切换到空库？"), isPresented: $confirming) {
            Button(L("确认保全并切换")) { session.preserveAndSwitch() }
        } message: {
            Text(L("不会删除旧库或壁纸文件。新库不包含旧历史及下载任务；维护完成后需退出重开。任何检查失败都会停止，不会猜测成功。"))
        }
        .confirmationDialog(L("回退到保留的原数据库？"), isPresented: $confirmingRollback) {
            Button(L("确认回退")) { session.rollback() }
        } message: {
            Text(L("不会修复原数据库的损坏。新库和保全副本均保留，仅恢复原数据库选择；退出重开后生效。"))
        }
    }
    static func phase(_ phase: LibraryMetadataRecovery.Request.Phase) -> String {
        switch phase {
        case .requested: return L("等待独立保全检查")
        case .copying: return L("正在保全，或上次保全中断")
        case .preserved: return L("原库已保全，等待新库验证")
        case .switched: return L("新库已切换，等待确认维护回执")
        case .rolledBack: return L("已回退到原数据库，等待确认维护回执")
        case .cancelled: return L("维护已取消，原数据库选择未改变。请退出并重新打开应用。")
        }
    }
}
