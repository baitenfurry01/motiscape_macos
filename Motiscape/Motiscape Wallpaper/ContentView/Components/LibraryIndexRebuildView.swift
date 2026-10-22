import SwiftUI

struct LibraryIndexRebuildView: View {
    @Bindable var session: ImportSession
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("补全资料库索引")).font(.title2.bold())
            Text(L("仅扫描当前导入目录，补充缺失记录并保留旧加入时间。不会覆盖已有索引、修改壁纸文件或恢复丢失的历史。"))
                .font(.callout).foregroundStyle(.secondary)
            if let root = session.indexRebuildRoot {
                Text(root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            if session.isRebuildingIndex {
                ProgressView(L("正在检查壁纸文件…"))
                if let progress = session.progress {
                    Text(L("%d / %d · %@", progress.current, progress.total, progress.title))
                        .font(.caption).lineLimit(1)
                }
            }
            if let error = session.indexRebuildError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
            }
            if let report = session.indexRebuildReport {
                Text(L("新增 %d 项，保留 %d 项，需检查 %d 项。", report.insertedIDs.count, report.preservedCount, report.issues.count))
                List(report.issues) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.source.lastPathComponent).font(.headline)
                        Text(item.source.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).help(item.source.path)
                        Text(item.issue ?? "").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            } else { Spacer() }
            HStack {
                Button(L("关闭")) { session.isIndexRebuildPresented = false }
                    .keyboardShortcut(.cancelAction).disabled(session.isRebuildingIndex)
                Spacer()
                if session.isRebuildingIndex {
                    Button(L("取消")) { session.cancel() }
                } else {
                    Button(L("开始检查")) { confirming = true }.disabled(session.isWorking || session.isPresented)
                }
            }
        }
        .padding(24).frame(width: 680, height: 480)
        .interactiveDismissDisabled(session.isRebuildingIndex)
        .confirmationDialog(L("补全资料库索引？"), isPresented: $confirming) {
            Button(L("开始检查")) { session.rebuildIndex() }
        } message: {
            Text(L("检查会读取壁纸内容，较大的资料库可能需要一些时间。所有检查完成后才一次性保存缺失记录，可随时取消。"))
        }
    }
}
