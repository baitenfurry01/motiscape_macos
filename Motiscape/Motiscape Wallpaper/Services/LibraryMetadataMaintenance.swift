import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

@MainActor @Observable final class LibraryMetadataMaintenance {
    let directory: URL
    private(set) var isWorking = false
    private(set) var count: Int?
    private(set) var canRestore = false
    private(set) var error: String?
    private(set) var databaseError: String?
    private(set) var message: String?
    private(set) var preview: LibraryMetadataBackup.Preview?
    private(set) var selectedSource: URL?
    private(set) var needsRestart = false
    private var operation: Task<Void, Never>?

    nonisolated init(directory: URL) { self.directory = directory.resolvingSymlinksInPath().standardizedFileURL }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isWorking, !needsRestart else { return }
        isWorking = true; error = nil; message = nil
        operation = Task { @MainActor in
            defer { self.isWorking = false; self.operation = nil }
            do { try await work() }
            catch is CancellationError { self.message = L("操作已取消，原数据库保持不变。") }
            catch {
                self.error = error.localizedDescription
                if case LibraryMetadataError.restartRequired = error { self.needsRestart = true; self.canRestore = false }
            }
        }
    }

    private func openStore() async throws -> LibraryIndexActor {
        let directory = directory
        return try await Task.detached { try LibraryIndexActor(directory: directory) }.value
    }

    func refresh() {
        perform {
            self.count = nil; self.canRestore = false; self.databaseError = nil
            do {
                let store = try await self.openStore()
                let status = try await store.maintenanceStatus()
                self.count = status.count; self.canRestore = status.canRestore
            } catch { self.databaseError = error.localizedDescription; throw error }
        }
    }

    func inspect(_ url: URL) {
        guard !isWorking, !needsRestart else { return }
        preview = nil; selectedSource = nil
        perform {
            let task = Task.detached { try LibraryMetadataBackup.preview(LibraryMetadataBackup.read(url)) }
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            self.preview = result; self.selectedSource = url
        }
    }

    func export(to url: URL) {
        perform {
            let store = try await self.openStore()
            try Task.checkCancellation()
            try await store.backup(to: url)
            self.message = L("元数据备份已导出：%@", url.path)
        }
    }

    func restoreConfirmed() {
        guard let preview, canRestore else { return }
        // Restore exactly the immutable bytes reviewed, not a changed source file.
        perform {
            let store = try await self.openStore()
            try Task.checkCancellation()
            do { try await store.restore(data: preview.data, requiringRestart: true) }
            catch LibraryMetadataError.nonemptyRestoreTarget {
                self.canRestore = false
                throw LibraryMetadataError.nonemptyRestoreTarget
            }
            self.needsRestart = true; self.canRestore = false
            self.count = preview.total
            self.message = LibraryMetadataError.restartRequired.localizedDescription
        }
    }

    func chooseBackup() {
        guard !isWorking, !needsRestart else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.inspect(url)
        }
    }

    func scheduleRecovery() {
        perform {
            let recovery = LibraryMetadataRecovery(directory: self.directory)
            _ = try await Task.detached { try recovery.schedule() }.value
            self.needsRestart = true; self.canRestore = false
            self.message = LibraryMetadataError.maintenancePending.localizedDescription
        }
    }

    func chooseExport() {
        guard !isWorking, !needsRestart else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "wallpaper-metadata-backup.json"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.export(to: url)
        }
    }

    func cancel() { operation?.cancel() }
}
