import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

/// An index item count must never appear as copied bytes or a confirmed import.
enum ImportReviewActivity: Hashable {
    case checkingLibrary, scanning, importing

    func message(progress: ImportProgress?) -> String {
        switch self {
        case .checkingLibrary:
            guard let progress, progress.total > 0 else { return L("正在检查资料库…") }
            return L("正在检查资料库 %d / %d 项…", progress.current, progress.total)
        case .scanning:
            return L("正在扫描和校验文件…")
        case .importing:
            guard let progress else { return L("正在准备导入…") }
            return L("正在导入 %d / %d：%@", progress.current, progress.total, progress.title)
        }
    }

    func fraction(progress: ImportProgress?) -> Double? {
        guard let progress else { return nil }
        switch self {
        case .checkingLibrary:
            guard progress.total > 0 else { return nil }
            return min(1, max(0, Double(progress.current) / Double(progress.total)))
        case .scanning:
            return nil
        case .importing:
            guard progress.totalBytes > 0 else { return nil }
            return min(1, max(0, Double(progress.copiedBytes) / Double(progress.totalBytes)))
        }
    }
}

/// Main-thread presentation state; all scanning, hashing, copying and persistence
/// run on the coordinator actor. Shared by file-picker and drag/drop entry points.
@Observable final class ImportSession {
    var isPresented = false
    var candidates: [ImportCandidate] = []
    var results: [ImportResult] = []
    var duplicatePolicy: ImportDuplicatePolicy = .skip
    private(set) var isWorking = false {
        didSet {
            if !isWorking && automaticIndexRequested {
                Task { @MainActor [weak self] in self?.startAutomaticIndexIfIdle() }
            }
        }
    }
    private(set) var progress: ImportProgress?
    private(set) var reviewActivity: ImportReviewActivity?
    private(set) var error: String?
    private var coordinator: ImportCoordinator?
    private var operation: Task<Void, Never>?
    private var coverTasks: [UUID: Task<Void, Never>] = [:]
    private var coverTokens: [UUID: UUID] = [:]
    private(set) var coverLoadingIDs = Set<UUID>()
    private(set) var coverErrors: [UUID: String] = [:]
    var isPreparingCover: Bool { !coverLoadingIDs.isEmpty }
    var isHistoryPresented = false
    var isBackupsPresented = false
    var isIndexRebuildPresented = false
    var isZIPWorkspacesPresented = false
    var isMetadataPresented = false
    let metadataMaintenance: LibraryMetadataMaintenance
    private(set) var zipWorkspaces = ZIPWorkspaceInventory()
    private(set) var zipWorkspaceRoot: URL?
    private(set) var zipWorkspaceError: String?
    private(set) var zipWorkspaceMessage: String?
    private(set) var isCheckingZIPWorkspaces = false
    private(set) var isManagingZIPWorkspace = false
    private(set) var isRebuildingIndex = false
    private(set) var indexRebuildReport: LibraryIndexRebuildReport?
    private(set) var indexRebuildError: String?
    private(set) var indexRebuildRoot: URL?
    private(set) var isAutomaticallyIndexing = false
    private(set) var automaticIndexReport: LibraryIndexScanReport?
    private(set) var automaticIndexError: String?
    private(set) var automaticIndexRoot: URL?
    private var automaticIndexRequested = false
    private(set) var backups: [ImportBackup] = []
    private(set) var backupRoot: URL?
    private(set) var backupError: String?
    private(set) var backupMessage: String?
    private(set) var isLoadingBackups = false
    private(set) var isManagingBackup = false
    private(set) var history: [ImportJob] = []
    private(set) var historyEntries: [ImportHistoryEntry] = []
    private(set) var historyRoot: URL?
    private(set) var historyError: String?
    private(set) var recoveryReport = ImportRecoveryReport()
    private(set) var isRecovering = false
    private var pendingImportURLs: [URL] = []
    private let rootProvider: () -> URL
    private let metadataDirectory: URL
    private let legacyIndexURL: URL?
    private let workspaceRoot: URL

    init(rootProvider: @escaping () -> URL = { WallpaperLibrary.shared.defaultImportedDirectory },
         metadataDirectory: URL = LibraryMetadataRecovery.defaultDirectory,
         legacyIndexURL: URL? = AppIntegrationFixture.supportDirectory?.appending(path: "library-additions.json") ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "motiscape/library-additions.json"), workspaceRoot: URL? = nil) {
        self.rootProvider = rootProvider
        self.metadataDirectory = metadataDirectory
        self.metadataMaintenance = LibraryMetadataMaintenance(directory: metadataDirectory)
        self.legacyIndexURL = legacyIndexURL
        self.workspaceRoot = workspaceRoot ?? metadataDirectory.appending(path: "ZIPWorkspaces")
    }

    private func makeCoordinator(root: URL, forAutomaticIndex: Bool = false) async throws -> ImportCoordinator {
        let metadata = metadataDirectory
        let workspaces = workspaceRoot
        return try await Task.detached {
            let store = try LibraryIndexActor(directory: metadata)
            if forAutomaticIndex, try await store.shouldDeferAutomaticIndexForRestore() {
                throw LibraryMetadataError.awaitingRestoreChoice
            }
            return ImportCoordinator(root: root, index: store, temporaryRoot: workspaces)
        }.value
    }

    /// Owns the same operation slot as import, so recovery cannot clean a live copy.
    func recoverAtLaunch(onCompletion: @escaping () -> Void = {}) {
        guard !isWorking else { return }
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        isWorking = true; isRecovering = true; historyError = nil
        if historyRoot != root { history = []; historyEntries = []; recoveryReport = ImportRecoveryReport() }
        historyRoot = root
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false; self.isRecovering = false; self.operation = nil
                onCompletion()
                let pending = self.pendingImportURLs; self.pendingImportURLs = []
                if !pending.isEmpty { self.prepare(urls: pending) }
            }
            do {
                let coordinator = try await self.makeCoordinator(root: root)
                try Task.checkCancellation()
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
                    self.history = []; self.historyEntries = []; self.historyRoot = nil; self.recoveryReport = ImportRecoveryReport()
                    return
                }
                let report = try await coordinator.recoverReport()
                let history = try await coordinator.history()
                let entries = try await coordinator.historyEntries()
                var workspaces = ZIPWorkspaceInventory()
                var workspaceError: String?
                do { workspaces = try await coordinator.archiveWorkspaceInventory() }
                catch { workspaceError = error.localizedDescription }
                // Settings may have changed while the actor was reading the old root.
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else {
                    self.history = []; self.historyEntries = []; self.historyRoot = nil; self.recoveryReport = ImportRecoveryReport()
                    return
                }
                self.rememberRecovery(report); self.history = history; self.historyEntries = entries
                self.zipWorkspaces = workspaces; self.zipWorkspaceError = workspaceError; self.zipWorkspaceRoot = root
            } catch {
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else {
                    self.history = []; self.historyEntries = []; self.historyRoot = nil; self.recoveryReport = ImportRecoveryReport()
                    return
                }
                if !(error is CancellationError) { self.historyError = error.localizedDescription }
            }
        }
    }

    func showHistory() {
        isHistoryPresented = true
        // Do not recover while a preflight sheet owns prepared ZIP contents.
        if !isPresented { recoverAtLaunch() }
    }

    /// Coalesce refreshes while keeping preflight, recovery and transactions serial.
    func requestAutomaticIndex() {
        automaticIndexRequested = true
        if isAutomaticallyIndexing,
           automaticIndexRoot != rootProvider().resolvingSymlinksInPath().standardizedFileURL {
            operation?.cancel()
        }
        startAutomaticIndexIfIdle()
    }

    private func startAutomaticIndexIfIdle() {
        guard automaticIndexRequested, !isWorking, !isPresented else { return }
        automaticIndexRequested = false
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        automaticIndexRoot = root; automaticIndexReport = nil; automaticIndexError = nil
        if historyRoot != root { history = []; historyEntries = []; recoveryReport = ImportRecoveryReport(); historyError = nil }
        historyRoot = root
        isWorking = true; isAutomaticallyIndexing = true; progress = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isAutomaticallyIndexing = false; self.isWorking = false; self.operation = nil; self.progress = nil
                let pending = self.pendingImportURLs; self.pendingImportURLs = []
                if !pending.isEmpty { self.prepare(urls: pending) }
            }
            do {
                let coordinator = try await self.makeCoordinator(root: root, forAutomaticIndex: true)
                try Task.checkCancellation()
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else {
                    throw LibraryIndexRebuildError.rootChanged
                }
                self.rememberRecovery(try await coordinator.recoverReport())
                let report = try await coordinator.maintainIndex(legacyIndexURL: self.legacyIndexURL) { [weak self] progress in
                    await MainActor.run { [weak self] in self?.progress = progress }
                    #if DEBUG
                    await AppIntegrationFixture.holdAutomaticIndexForUI(progress)
                    #endif
                }
                #if DEBUG
                if AppIntegrationFixture.isLibraryUI {
                    AppIntegrationFixture.record("index-ui-completed", fields: ["inserted": String(report.scan.inserted),
                        "preserved": String(report.scan.preserved), "resumed": String(report.resumed),
                        "generation": report.scan.generation])
                }
                #endif
                if self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root {
                    self.automaticIndexReport = report
                    self.historyRoot = root
                    await self.reloadHistory(coordinator)
                }
            } catch is CancellationError {
                self.automaticIndexError = L("自动索引检查已暂停，下次刷新将继续补全。")
            } catch { self.automaticIndexError = error.localizedDescription }
            if self.rootProvider().resolvingSymlinksInPath().standardizedFileURL != root {
                self.automaticIndexReport = nil; self.automaticIndexError = nil; self.automaticIndexRoot = nil
            }
        }
    }

    func showBackups() {
        isBackupsPresented = true
        refreshBackups()
    }

    func showZIPWorkspaces() { isZIPWorkspacesPresented = true; refreshZIPWorkspaces() }

    private func readZIPWorkspaces(root: URL) async throws -> ZIPWorkspaceInventory {
        let store = ZIPWorkspaceStore(root: workspaceRoot)
        let task = Task.detached { try store.inventory(libraryRoot: root) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func drainQueuedImports() {
        guard !isWorking, !isPresented, !pendingImportURLs.isEmpty else { return }
        let pending = pendingImportURLs; pendingImportURLs = []
        isZIPWorkspacesPresented = false; isHistoryPresented = false
        prepare(urls: pending)
    }

    func refreshZIPWorkspaces() {
        guard !isWorking, !isPresented else { return }
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        zipWorkspaceRoot = root; zipWorkspaces = ZIPWorkspaceInventory(); zipWorkspaceError = nil; zipWorkspaceMessage = nil
        isWorking = true; isCheckingZIPWorkspaces = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.isCheckingZIPWorkspaces = false; self.operation = nil; self.drainQueuedImports() }
            do {
                let inventory = try await self.readZIPWorkspaces(root: root)
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else { throw LibraryIndexRebuildError.rootChanged }
                self.zipWorkspaces = inventory
            } catch { if !(error is CancellationError) { self.zipWorkspaceError = error.localizedDescription } }
        }
    }

    func manageZIPWorkspace(_ snapshot: ZIPWorkspaceSnapshot, recover: Bool) {
        guard !isWorking, !isPresented else { return }
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        guard zipWorkspaceRoot == root else { zipWorkspaceError = LibraryIndexRebuildError.rootChanged.localizedDescription; return }
        isWorking = true; isManagingZIPWorkspace = true; zipWorkspaceError = nil; zipWorkspaceMessage = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.isManagingZIPWorkspace = false; self.operation = nil; self.drainQueuedImports() }
            do {
                if recover {
                    let coordinator = try await self.makeCoordinator(root: root)
                    self.coordinator = coordinator
                    guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else { throw LibraryIndexRebuildError.rootChanged }
                    self.rememberRecovery(try await coordinator.recoverReport())
                    if FileManager.default.fileExists(atPath: root.path) {
                        _ = try await coordinator.maintainIndex(legacyIndexURL: self.legacyIndexURL)
                    }
                    let restored = try await coordinator.recoverArchiveWorkspace(snapshot)
                    guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else {
                        await coordinator.discardPreparedArchives()
                        throw LibraryIndexRebuildError.rootChanged
                    }
                    self.candidates = restored.candidates; self.results = []; self.error = restored.cleanupError; self.historyRoot = root
                    await self.reloadHistory(coordinator)
                    self.isZIPWorkspacesPresented = false; self.isHistoryPresented = false; self.isPresented = true
                } else {
                    let store = ZIPWorkspaceStore(root: self.workspaceRoot)
                    try await Task.detached {
                        let lease = try store.acquire(snapshot, libraryRoot: root)
                        try lease.discard()
                    }.value
                    self.zipWorkspaceMessage = L("临时快照已清理，源 ZIP 和已导入壁纸未修改。")
                }
                let inventory = try await self.readZIPWorkspaces(root: root)
                if self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root { self.zipWorkspaces = inventory }
                else { self.zipWorkspaces = ZIPWorkspaceInventory(); self.zipWorkspaceMessage = nil }
            } catch { self.zipWorkspaceError = error.localizedDescription }
        }
    }

    func showIndexRebuild() {
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        if indexRebuildRoot != root { indexRebuildReport = nil; indexRebuildError = nil }
        indexRebuildRoot = root
        isIndexRebuildPresented = true
    }

    func rebuildIndex() {
        guard !isWorking, !isPresented else { return }
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        guard indexRebuildRoot == root else {
            indexRebuildReport = nil; indexRebuildError = LibraryIndexRebuildError.rootChanged.localizedDescription; return
        }
        indexRebuildRoot = root; indexRebuildReport = nil; indexRebuildError = nil
        isWorking = true; isRebuildingIndex = true; progress = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isWorking = false; self.isRebuildingIndex = false; self.operation = nil; self.progress = nil
                let pending = self.pendingImportURLs; self.pendingImportURLs = []
                if !pending.isEmpty { self.isIndexRebuildPresented = false; self.prepare(urls: pending) }
            }
            do {
                let coordinator = try await self.makeCoordinator(root: root)
                try Task.checkCancellation()
                guard self.rootProvider().resolvingSymlinksInPath().path == root.path else { throw LibraryIndexRebuildError.rootChanged }
                let report = try await coordinator.rebuildIndexReport(legacyIndexURL: self.legacyIndexURL) { [weak self] progress in
                    await MainActor.run { [weak self] in self?.progress = progress }
                }
                guard self.rootProvider().resolvingSymlinksInPath().path == root.path else { throw LibraryIndexRebuildError.rootChanged }
                self.indexRebuildReport = report
            } catch is CancellationError {
                self.indexRebuildError = L("已取消索引重建；未写入新记录。")
            } catch { self.indexRebuildError = error.localizedDescription }
        }
    }

    func refreshBackups() {
        guard !isWorking, !isPresented else { return }
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        if backupRoot?.path != root.path { backups = [] }
        if historyRoot?.path != root.path {
            history = []; historyEntries = []; recoveryReport = ImportRecoveryReport(); historyRoot = root; historyError = nil
        }
        backupRoot = root; backupError = nil; backupMessage = nil
        isWorking = true; isLoadingBackups = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.isLoadingBackups = false; self.operation = nil }
            do {
                let coordinator = try await self.makeCoordinator(root: root)
                let items = try await coordinator.backups()
                guard self.rootProvider().resolvingSymlinksInPath().path == root.path else {
                    self.backups = []; self.backupRoot = nil
                    throw ImportBackupError.changed
                }
                self.backups = items
                await self.reloadHistory(coordinator)
            } catch { self.backupError = error.localizedDescription }
        }
    }

    func manageBackup(_ backup: ImportBackup, restore: Bool) {
        guard !isWorking, !isPresented else { return }
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        guard root.path == backup.root else { backupError = ImportBackupError.changed.localizedDescription; return }
        isWorking = true; isManagingBackup = true; backupError = nil; backupMessage = nil; progress = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isWorking = false; self.isManagingBackup = false; self.operation = nil; self.progress = nil }
            do {
                let coordinator = try await self.makeCoordinator(root: root)
                do {
                    guard self.rootProvider().resolvingSymlinksInPath().path == root.path else { throw ImportBackupError.changed }
                    if restore {
                        let destination = try await coordinator.restoreBackup(backup) { [weak self] progress in
                            await MainActor.run { [weak self] in self?.progress = progress }
                        }
                        WallpaperLibrary.shared.recordAdded(at: destination)
                        WallpaperLibrary.shared.libraryDidChange(at: destination)
                        WEWallpaper.invalidateSizeCache()
                        self.backupMessage = L("备份已恢复；替换前的版本另存为备份。请重新应用壁纸以查看效果。")
                    } else {
                        try await coordinator.trashBackup(backup)
                        self.backupMessage = L("备份已移到废纸篓，可在 Finder 中取回。当前壁纸未改变。")
                    }
                } catch { self.backupError = error.localizedDescription }
                // Refresh actual state even when the final receipt could not be saved.
                let items = try await coordinator.backups()
                if self.rootProvider().resolvingSymlinksInPath().path == root.path {
                    self.backups = items
                    await self.reloadHistory(coordinator)
                } else {
                    self.backups = []; self.backupRoot = nil
                    self.backupMessage = nil; self.backupError = ImportBackupError.changed.localizedDescription
                }
            } catch { self.backupError = error.localizedDescription }
        }
    }

    private func reloadHistory(_ coordinator: ImportCoordinator) async {
        do {
            let jobs = try await coordinator.history()
            let entries = try await coordinator.historyEntries()
            history = jobs; historyEntries = entries; historyError = nil
        }
        catch { historyError = error.localizedDescription }
    }

    private func rememberRecovery(_ report: ImportRecoveryReport) {
        // Opening the history sheet must not erase the startup recovery summary.
        var records = Dictionary(uniqueKeysWithValues: recoveryReport.recovered.map { ($0.id, $0) })
        for job in report.recovered { records[job.id] = job }
        recoveryReport = ImportRecoveryReport(recovered: records.values.sorted { $0.updatedAt > $1.updatedAt }, issues: report.issues)
    }

    func prepare(urls: [URL]) {
        if isCheckingZIPWorkspaces || isManagingZIPWorkspace { pendingImportURLs.append(contentsOf: urls); return }
        if isAutomaticallyIndexing {
            pendingImportURLs.append(contentsOf: urls)
            operation?.cancel()
            return
        }
        if isRebuildingIndex { pendingImportURLs.append(contentsOf: urls); return }
        isPresented = true
        if isRecovering { pendingImportURLs.append(contentsOf: urls); return }
        guard !isWorking else { return }
        cancelCoverPreparation()
        coordinator = nil
        candidates = []; results = []; error = nil; progress = nil
        reviewActivity = .checkingLibrary
        isWorking = true
        let root = rootProvider().resolvingSymlinksInPath().standardizedFileURL
        if historyRoot != root { history = []; historyEntries = []; recoveryReport = ImportRecoveryReport() }
        historyRoot = root
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reviewActivity = nil; self.progress = nil; self.isWorking = false; self.operation = nil }
            do {
                let coordinator = try await self.makeCoordinator(root: root)
                self.coordinator = coordinator
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else { throw LibraryIndexRebuildError.rootChanged }
                self.rememberRecovery(try await coordinator.recoverReport())
                try Task.checkCancellation()
                // Fresh roots have no old contents. Existing roots must be
                // indexed before import duplicate decisions can be trusted.
                if FileManager.default.fileExists(atPath: root.path) {
                    let report = try await coordinator.maintainIndex(legacyIndexURL: self.legacyIndexURL) { [weak self] progress in
                        await MainActor.run { [weak self] in self?.progress = progress }
                    }
                    guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else { throw LibraryIndexRebuildError.rootChanged }
                    self.automaticIndexRoot = root; self.automaticIndexReport = report; self.automaticIndexError = nil
                }
                try Task.checkCancellation()
                self.reviewActivity = .scanning; self.progress = nil
                let scanned = try await coordinator.scan(urls)
                guard self.rootProvider().resolvingSymlinksInPath().standardizedFileURL == root else { throw LibraryIndexRebuildError.rootChanged }
                self.candidates = scanned
            } catch is CancellationError { self.error = L("已取消预检") }
            catch { self.error = error.localizedDescription }
            if let coordinator = self.coordinator { await self.reloadHistory(coordinator) }
        }
    }

    func start(onCompletion: @escaping () -> Void) {
        guard !isWorking, !isPreparingCover, let coordinator, !candidates.isEmpty else { return }
        guard rootProvider().resolvingSymlinksInPath().standardizedFileURL == historyRoot else {
            error = LibraryIndexRebuildError.rootChanged.localizedDescription; return
        }
        let selected = candidates
        let policy = duplicatePolicy
        error = nil; results = []; progress = nil; reviewActivity = .importing; isWorking = true
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.reviewActivity = nil; self.progress = nil; self.isWorking = false; self.operation = nil; onCompletion() }
            do {
                self.results = try await coordinator.run(selected, policy: policy) { [weak self] progress in
                    await MainActor.run { [weak self] in self?.progress = progress }
                    #if DEBUG
                    await AppIntegrationFixture.holdPartialCopyForUI(progress)
                    #endif
                }
                WallpaperLibrary.shared.didImport(at: self.results.compactMap {
                    $0.outcome == .imported ? $0.destination : nil
                })
            } catch { self.error = error.localizedDescription }
            await self.reloadHistory(coordinator)
        }
    }

    func retryFailures(onCompletion: @escaping () -> Void) {
        guard !isWorking, let coordinator else { return }
        let failed = Set(results.filter { $0.outcome == .failed || $0.outcome == .cancelled }.map(\.id))
        let retry = candidates.filter { failed.contains($0.id) }
        guard !retry.isEmpty else { return }
        isWorking = true; error = nil; progress = nil; reviewActivity = .scanning
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let scanned = try await coordinator.scan(retry.map(\.source))
                let refreshed = Self.matchingRetryCandidates(scanned, previous: retry)
                try Task.checkCancellation()
                self.candidates = refreshed
                self.reviewActivity = nil; self.progress = nil
                self.isWorking = false; self.operation = nil
                self.start(onCompletion: onCompletion)
            } catch {
                self.error = error is CancellationError ? L("已取消预检") : error.localizedDescription
                self.reviewActivity = nil; self.progress = nil
                self.isWorking = false; self.operation = nil
            }
        }
    }

    func cancel() {
        AppIntegrationFixture.record("library-ui-import-cancel")
        automaticIndexRequested = false; pendingImportURLs = []; operation?.cancel()
    }

    static func matchingRetryCandidates(_ scanned: [ImportCandidate], previous: [ImportCandidate]) -> [ImportCandidate] {
        scanned.compactMap { candidate in
            guard previous.contains(where: {
                $0.source == candidate.source && ($0.archiveMember == nil || candidate.archiveMember == nil || $0.archiveMember == candidate.archiveMember)
            }) else { return nil }
            var candidate = candidate
            if let previous = previous.first(where: { $0.source == candidate.source && $0.archiveMember == candidate.archiveMember }) {
                candidate.title = previous.title
                candidate.tagEdit = previous.tagEdit
                candidate.coverEdit = previous.coverEdit
            }
            return candidate
        }
    }

    func releasePreparedFiles() {
        guard !isWorking else { return }
        cancelCoverPreparation()
        let previous = coordinator
        coordinator = nil; candidates = []
        Task {
            #if DEBUG
            await AppIntegrationFixture.holdZIPCleanupForUI(previous)
            #endif
            await previous?.discardPreparedArchives()
        }
        drainQueuedImports()
        startAutomaticIndexIfIdle()
    }

    func chooseCover(for id: UUID) {
        guard !isWorking else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        panel.prompt = L("选择封面")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.loadCover(url, for: id)
        }
    }

    func loadCover(_ url: URL, for id: UUID) {
        guard !isWorking, candidates.contains(where: { $0.id == id }) else { return }
        coverTasks[id]?.cancel()
        let token = UUID(); coverTokens[id] = token
        coverLoadingIDs.insert(id); coverErrors[id] = nil
        coverTasks[id] = Task { @MainActor [weak self] in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let worker = Task.detached { try ImportMediaPreflight.cover(at: url) }
            do {
                let data = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                guard let self, self.coverTokens[id] == token,
                      let position = self.candidates.firstIndex(where: { $0.id == id }) else { return }
                self.candidates[position].coverEdit = .custom(data)
            } catch {
                guard let self, self.coverTokens[id] == token else { return }
                if !(error is CancellationError) { self.coverErrors[id] = error.localizedDescription + " " + L("现有封面未更改。") }
            }
            guard let self, self.coverTokens[id] == token else { return }
            self.coverTasks[id] = nil; self.coverTokens[id] = nil; self.coverLoadingIDs.remove(id)
        }
    }

    func setCover(_ edit: ImportCoverEdit, for id: UUID) {
        guard !isWorking, let position = candidates.firstIndex(where: { $0.id == id }) else { return }
        coverTasks[id]?.cancel(); coverTasks[id] = nil; coverTokens[id] = nil
        coverLoadingIDs.remove(id); coverErrors[id] = nil
        candidates[position].coverEdit = edit
    }

    private func cancelCoverPreparation() {
        coverTasks.values.forEach { $0.cancel() }
        coverTasks = [:]; coverTokens = [:]; coverLoadingIDs = []; coverErrors = [:]
    }
}
