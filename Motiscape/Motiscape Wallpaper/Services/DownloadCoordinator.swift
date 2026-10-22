import Foundation

struct DownloadJob: Codable, Sendable {
    enum Status: String, Codable { case queued, resolving, downloading, validating, paused, cancelled, completed, failed }
    enum Stop: String, Codable { case pause, cancel, waitForLogin }
    var id = UUID().uuidString
    var item: WorkshopItem
    var outputRoot: String
    var purpose: DownloadPurpose
    var status: Status = .queued
    var attemptID: String?
    var stop: Stop?
    var error: String?
    var createdAt = Date()
    var startedAt: Date?
    var completedAt: Date?
    var receivedBytes: Int64 = 0
    var totalBytes: Int64 = 0
    var active: Bool { [.resolving, .downloading, .validating].contains(status) }
    var terminal: Bool { [.cancelled, .completed, .failed].contains(status) }
}

struct DownloadQueueRecord: LibraryMetadataRecord {
    static let category = "downloadQueue"
    var id = "main"
    var version = 1
    var concurrency = 3
    var jobs: [DownloadJob] = []
    var history: [DownloadJob] = []
}

protocol DownloadPersistence: Sendable {
    func loadDownloads() async throws -> DownloadQueueRecord
    func saveDownloads(_ queue: DownloadQueueRecord) async throws
}

extension LibraryIndexActor: DownloadPersistence {
    func loadDownloads() throws -> DownloadQueueRecord {
        try records(DownloadQueueRecord.self).first(where: { $0.id == "main" }) ?? DownloadQueueRecord()
    }
    func saveDownloads(_ queue: DownloadQueueRecord) throws { try save(queue) }
}

@MainActor protocol DownloadProvider: AnyObject {
    func start(_ job: DownloadJob, receive: @escaping @MainActor (DownloadState) -> Void)
    func stop(attemptID: String, pause: Bool, onFailure: @escaping @MainActor (String) -> Void)
}

@MainActor final class SteamDownloadProvider: DownloadProvider {
    func start(_ job: DownloadJob, receive: @escaping @MainActor (DownloadState) -> Void) {
        guard let attemptID = job.attemptID else { return }
        SteamServiceManager.shared.downloadItem(workshopId: job.item.id, taskId: attemptID,
            outputRoot: URL(fileURLWithPath: job.outputRoot), managedByCoordinator: true) { state in
                Task { @MainActor in receive(state) }
            }
    }
    func stop(attemptID: String, pause: Bool, onFailure: @escaping @MainActor (String) -> Void) {
        if pause {
            SteamServiceManager.shared.pauseDownload(taskId: attemptID) { error in
                Task { @MainActor in onFailure(error) }
            }
        } else {
            SteamServiceManager.shared.cancelDownload(taskId: attemptID) { error in
                Task { @MainActor in onFailure(error) }
            }
        }
    }
}

/// Commands and provider events share one ordered chain. No network side effect
/// starts before its intent is durable; actor awaits cannot reorder UI commands.
@MainActor final class DownloadCoordinator {
    private let store: any DownloadPersistence
    private let provider: any DownloadProvider
    private(set) var record = DownloadQueueRecord()
    private(set) var isLoaded = false
    private(set) var error: String?
    private var ready = false
    private var tail: Task<Void, Never>?
    private var views: [String: DownloadTask] = [:]
    private var progress: [String: DownloadProgress] = [:]
    private var pendingCompletions: [DownloadJob] = []
    var onChange: (([DownloadTask], DownloadQueueRecord, String?) -> Void)?
    var onCompleted: ((DownloadJob) -> Void)?

    init(store: any DownloadPersistence, provider: any DownloadProvider) {
        self.store = store; self.provider = provider
    }

    @discardableResult private func command(allowUnavailable: Bool = false, _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard allowUnavailable || (self.isLoaded && self.error == nil) else { self.publish(); return }
            await body()
            await self.schedule()
        }
        tail = task
        return task
    }

    @discardableResult func load() -> Task<Void, Never> {
        command(allowUnavailable: true) {
            guard !self.isLoaded else { return }
            do {
                var saved = try await self.store.loadDownloads()
                guard saved.version == 1 else { throw LibraryMetadataError.unsupportedVersion(saved.version) }
                guard (1...3).contains(saved.concurrency), Set(saved.jobs.map(\.id)).count == saved.jobs.count,
                      Set(saved.jobs.map { $0.item.id }).count == saved.jobs.count else { throw CocoaError(.fileReadCorruptFile) }
                for index in saved.jobs.indices {
                    guard UUID(uuidString: saved.jobs[index].id) != nil,
                          Self.validID(saved.jobs[index].item.id), saved.jobs[index].outputRoot.hasPrefix("/") else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    if !saved.jobs[index].terminal {
                        saved.jobs[index].status = .paused
                        saved.jobs[index].error = L("上次下载未完成，继续时会重新校验已下载内容")
                    }
                    saved.jobs[index].attemptID = nil
                    saved.jobs[index].stop = nil
                }
                try await self.store.saveDownloads(saved)
                self.record = saved; self.isLoaded = true; self.error = nil
                self.publish()
            } catch { self.error = error.localizedDescription; self.publish() }
        }
    }

    private static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.allSatisfy { (48...57).contains($0) } && (UInt64(id) ?? 0) > 0
    }

    private func commit(_ next: DownloadQueueRecord) async -> Bool {
        do {
            try await store.saveDownloads(next)
            record = next; error = nil; publish()
            let completed = pendingCompletions.filter { job in next.jobs.contains { $0.id == job.id && $0.status == .completed } }
            pendingCompletions.removeAll { job in completed.contains { $0.id == job.id } }
            completed.forEach { onCompleted?($0) }
            return true
        } catch {
            self.error = error.localizedDescription; publish()
            return false
        }
    }

    @discardableResult func enqueue(_ item: WorkshopItem, root: URL, purpose: DownloadPurpose) -> Task<Void, Never> {
        command {
            guard self.isLoaded else { return }
            guard Self.validID(item.id), root.isFileURL, item.consumerAppId == nil || item.consumerAppId == 431960 else {
                self.error = L("下载任务来源或目录无效"); self.publish(); return
            }
            await self.enqueueNow(item, root: root, purpose: purpose)
        }
    }

    private func enqueueNow(_ item: WorkshopItem, root: URL, purpose: DownloadPurpose) async {
        var next = record
        if let index = next.jobs.firstIndex(where: { $0.item.id == item.id }) {
            if !next.jobs[index].terminal {
                if purpose == .presetDependency { next.jobs[index].purpose = purpose; _ = await commit(next) }
                return
            }
            next.history.append(next.jobs.remove(at: index))
        }
        next.jobs.append(DownloadJob(item: item, outputRoot: root.standardizedFileURL.path, purpose: purpose))
        if !(await commit(next)) { record = next; publish() }
    }

    /// Await persistence before the import sheet reports success. Existing jobs
    /// stay in their current state; past failures are retried in Download Center.
    func enqueueImport(_ item: WorkshopItem, root: URL) async throws -> WorkshopImportReceipt {
        guard item.consumerAppId == 431960 else { throw WorkshopImportError.wrongApplication }
        guard Self.validID(item.id), root.isFileURL else { throw WorkshopImportError.invalidReference }
        var receipt: WorkshopImportReceipt?
        await command {
            if self.record.jobs.contains(where: { $0.item.id == item.id }) { receipt = .existing; return }
            await self.enqueueNow(item, root: root, purpose: .wallpaper)
            if self.error == nil { receipt = .queued }
        }.value
        guard let receipt else {
            throw WorkshopImportError.queueUnavailable
        }
        return receipt
    }

    @discardableResult func setReady(_ ready: Bool) -> Task<Void, Never> {
        command(allowUnavailable: true) {
            self.ready = ready
            if !ready {
                for id in self.record.jobs.filter({ $0.active && $0.stop == nil }).map(\.id) {
                    await self.requestStop(id: id, intent: .waitForLogin)
                }
            }
            self.publish()
        }
    }

    @discardableResult func retryPersistence() -> Task<Void, Never> {
        if !isLoaded { return load() }
        return command(allowUnavailable: true) {
            if await self.commit(self.record) {
                let completed = self.pendingCompletions; self.pendingCompletions = []
                completed.forEach { self.onCompleted?($0) }
            }
        }
    }

    @discardableResult func pause(_ sourceID: String) -> Task<Void, Never> {
        command {
            guard let id = self.record.jobs.first(where: { $0.item.id == sourceID })?.id else { return }
            await self.requestStop(id: id, intent: .pause)
        }
    }
    @discardableResult func cancel(_ sourceID: String) -> Task<Void, Never> {
        command {
            guard let id = self.record.jobs.first(where: { $0.item.id == sourceID })?.id else { return }
            await self.requestStop(id: id, intent: .cancel)
        }
    }

    func cancelAndWait(_ sourceID: String) async throws {
        await cancel(sourceID).value
        let deadline = Date().addingTimeInterval(15)
        while record.jobs.contains(where: { $0.item.id == sourceID && $0.active }) {
            if let error { throw NSError(domain: "DownloadPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            guard Date() < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(20))
        }
        if !isLoaded || error != nil { throw CocoaError(.fileWriteUnknown) }
    }

    private func requestStop(id: String, intent: DownloadJob.Stop) async {
        guard let index = record.jobs.firstIndex(where: { $0.id == id }), !record.jobs[index].terminal else { return }
        var next = record
        let job = next.jobs[index]
        guard job.stop != .cancel, job.stop != intent else { return }
        if job.active, let attemptID = job.attemptID {
            next.jobs[index].stop = intent
            guard await commit(next) else { return }
            provider.stop(attemptID: attemptID, pause: intent != .cancel) { [weak self] error in
                // Provider observations must not be discarded when unrelated
                // persistence fails after the stop intent was accepted.
                self?.command(allowUnavailable: true) { [weak self] in
                    guard let self, let index = self.record.jobs.firstIndex(where: { $0.id == id && $0.attemptID == attemptID }),
                          self.record.jobs[index].stop == intent else { return }
                    var failed = self.record
                    failed.jobs[index].stop = nil; failed.jobs[index].error = error
                    if !(await self.commit(failed)) {
                        // The stop was rejected, so workers are still active.
                        // Preserve that fact for retryPersistence without
                        // freeing a slot or leaving the UI stuck stopping.
                        self.record = failed
                        self.publish()
                    }
                }
            }
        } else {
            next.jobs[index].status = intent == .cancel ? .cancelled : intent == .pause ? .paused : .queued
            if intent == .cancel { next.jobs[index].completedAt = Date() }
            next.jobs[index].attemptID = nil; next.jobs[index].stop = nil
            _ = await commit(next)
        }
    }

    @discardableResult func resume(_ sourceID: String) -> Task<Void, Never> {
        command {
            guard let index = self.record.jobs.firstIndex(where: { $0.item.id == sourceID && $0.status == .paused }) else { return }
            var next = self.record
            next.jobs[index].status = .queued; next.jobs[index].error = nil
            next.jobs[index].attemptID = nil; next.jobs[index].stop = nil
            _ = await self.commit(next)
        }
    }

    @discardableResult func retry(_ sourceID: String) -> Task<Void, Never> {
        command {
            guard let index = self.record.jobs.firstIndex(where: { $0.item.id == sourceID && [.failed, .cancelled].contains($0.status) }) else { return }
            var next = self.record
            let old = next.jobs[index]
            next.history.append(old)
            next.jobs[index] = DownloadJob(item: old.item, outputRoot: old.outputRoot, purpose: old.purpose)
            _ = await self.commit(next)
        }
    }

    @discardableResult func clearHistory() -> Task<Void, Never> {
        command {
            var next = self.record
            next.jobs.removeAll(where: \.terminal); next.history.removeAll()
            _ = await self.commit(next)
        }
    }

    @discardableResult func setConcurrency(_ count: Int) -> Task<Void, Never> {
        command {
            var next = self.record; next.concurrency = max(1, min(3, count))
            _ = await self.commit(next)
        }
    }

    @discardableResult func moveToFront(_ sourceID: String) -> Task<Void, Never> {
        command {
            guard let index = self.record.jobs.firstIndex(where: { $0.item.id == sourceID && !$0.active && !$0.terminal }) else { return }
            var next = self.record; let job = next.jobs.remove(at: index); next.jobs.insert(job, at: 0)
            _ = await self.commit(next)
        }
    }

    @discardableResult func pauseAll() -> Task<Void, Never> {
        command {
            for id in self.record.jobs.filter({ !$0.terminal && $0.status != .paused }).map(\.id) {
                await self.requestStop(id: id, intent: .pause)
            }
        }
    }

    /// Communication boundary only: reuse existing pause/persistence semantics before removing a provider.
    func prepareForProviderStop(waitForReplies: Bool) async throws {
        await command(allowUnavailable: true) {
            self.ready = false
            for id in self.record.jobs.filter({ !$0.terminal && $0.status != .paused }).map(\.id) {
                await self.requestStop(id: id, intent: .pause)
            }
        }.value
        if waitForReplies {
            let deadline = Date().addingTimeInterval(20)
            while record.jobs.contains(where: { $0.active }) {
                if let error { throw AgentTransportError.message(error) }
                guard Date() < deadline else { throw AgentTransportError.message(L("正在等待 Steam 下载停止，请重试")) }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try await flushProviderEvents()
    }
    func flushProviderEvents() async throws {
        await command(allowUnavailable: true) {}.value
        if let error { throw AgentTransportError.message(error) }
    }

    @discardableResult func resumeAll() -> Task<Void, Never> {
        command {
            var next = self.record
            for index in next.jobs.indices where next.jobs[index].status == .paused {
                next.jobs[index].status = .queued; next.jobs[index].error = nil
            }
            _ = await self.commit(next)
        }
    }

    private func schedule() async {
        guard isLoaded, ready, error == nil else { return }
        while record.jobs.filter(\.active).count < record.concurrency,
              let index = record.jobs.firstIndex(where: { $0.status == .queued }) {
            var next = record
            next.jobs[index].status = .resolving; next.jobs[index].attemptID = UUID().uuidString
            next.jobs[index].startedAt = Date(); next.jobs[index].stop = nil
            let job = next.jobs[index]
            guard await commit(next) else { return }
            provider.start(job) { [weak self] state in
                self?.command(allowUnavailable: true) { [weak self] in await self?.receive(state, jobID: job.id, attemptID: job.attemptID!) }
            }
        }
    }

    private func receive(_ state: DownloadState, jobID: String, attemptID: String) async {
        guard let index = record.jobs.firstIndex(where: { $0.id == jobID && $0.attemptID == attemptID && $0.active }) else { return }
        var next = record
        switch state {
        case .waitingForLogin(let message):
            ready = false
            record.jobs[index].error = message
            for id in record.jobs.filter({ $0.active && $0.stop == nil }).map(\.id) {
                await requestStop(id: id, intent: .waitForLogin)
            }
            publish()
            return
        case .queued: return
        case .resolving:
            guard record.jobs[index].status != .validating else { return }
            next.jobs[index].status = .resolving
        case .validating: next.jobs[index].status = .validating
        case .downloading(let value):
            // Validation starts only after this attempt's transfer workers
            // finish. A delayed observational event must not rewind its phase
            // or overwrite the checkpoint saved at that transition.
            guard record.jobs[index].status != .validating else { return }
            progress[jobID] = value
            next.jobs[index].status = .downloading
            next.jobs[index].receivedBytes = value.receivedBytes; next.jobs[index].totalBytes = value.totalBytes
            // Progress is observational; checkpoints are saved with transitions.
            if record.jobs[index].status == .downloading { record = next; publish(); return }
        case .paused:
            next.jobs[index].status = next.jobs[index].stop == .cancel ? .cancelled :
                next.jobs[index].stop == .waitForLogin ? .queued : .paused
        case .cancelled:
            if next.jobs[index].stop == nil { ready = false; next.jobs[index].status = .queued }
            else { next.jobs[index].status = .cancelled }
        case .completed: next.jobs[index].status = .completed
        case .failed(let message):
            next.jobs[index].status = !ready && next.jobs[index].stop == .waitForLogin ? .queued : .failed
            next.jobs[index].error = message
        }
        if state.isServiceTerminal {
            next.jobs[index].attemptID = nil; next.jobs[index].stop = nil
            if next.jobs[index].terminal { next.jobs[index].completedAt = Date() }
        }
        let completed = next.jobs[index]
        if await commit(next) {
            if state == .completed { onCompleted?(completed) }
        } else {
            // The provider's real terminal state cannot be rolled back by a
            // database failure. Keep it visible, block new starts, retry saving.
            record = next
            if state == .completed { pendingCompletions.append(completed) }
            publish()
        }
    }

    private func publish() {
        let ids = Set(record.jobs.map(\.id))
        views = views.filter { ids.contains($0.key) }
        progress = progress.filter { ids.contains($0.key) }
        let tasks = record.jobs.map { job -> DownloadTask in
            let state: DownloadState
            switch job.status {
            case .queued: state = .queued
            case .resolving: state = .resolving
            case .validating: state = .validating
            case .downloading: state = .downloading(progress[job.id] ?? DownloadProgress(receivedBytes: job.receivedBytes,
                totalBytes: job.totalBytes, bytesPerSecond: 0, etaSeconds: nil))
            case .paused: state = .paused
            case .cancelled: state = .cancelled
            case .completed: state = .completed
            case .failed: state = .failed(job.error ?? L("下载失败"))
            }
            let task = views[job.id] ?? DownloadTask(workshopItem: job.item, attemptID: job.attemptID, state: state,
                startedAt: job.startedAt, completedAt: job.completedAt, purpose: job.purpose)
            task.state = state; task.attemptID = job.attemptID; task.isPausing = job.stop != nil
            task.controlError = job.error; task.purpose = job.purpose; task.startedAt = job.startedAt
            task.completedAt = job.completedAt; task.outputRoot = job.outputRoot
            task.waitingForLogin = job.status == .queued && !ready
            views[job.id] = task
            return task
        }
        onChange?(tasks, record, error)
    }
}
