import AppKit
import Combine
import CryptoKit
import Foundation

/// Routes existing services; it does not own the main application's download queue or library database.
@MainActor
enum SteamAgentAdapter {
    private static var wire: AgentConnection?
    private static var configuration: SteamAgentConfiguration?
    private static var injectedAPI: SteamWebAPIBackend?
    private static var api: SteamWebAPIBackend?
    private static var explore: SteamExploreBackend?
    private static var observers = Set<AnyCancellable>()
    private static var tasks: [UUID: Task<Void, Never>] = [:]
    private static var cancelled = Set<UUID>()
    private static var downloads: [String: SteamAgentDownloadEvent] = [:]
    private static var started = false

    static func install(on connection: AgentConnection, apiBackend: SteamWebAPIBackend? = nil) {
        injectedAPI = apiBackend
        wire = connection
        connection.onRequest = { command, data, reply in
            Task { @MainActor in
                guard command == "steam.request", let request = try? JSONDecoder().decode(SteamAgentRequest.self, from: data) else {
                    reply(.failure(AgentTransportError.message(L("不支持此请求")))); return
                }
                if cancelled.remove(request.id) != nil { reply(.failure(CancellationError())); return }
                tasks[request.id] = Task { @MainActor in
                    defer { tasks.removeValue(forKey: request.id) }
                    let response: SteamAgentEnvelope
                    do { response = SteamAgentEnvelope(payload: try await execute(request.operation)) }
                    catch let error as SteamAPIError { response = SteamAgentEnvelope(apiError: error) }
                    catch let error as SteamServiceRequestError { response = SteamAgentEnvelope(serviceError: error) }
                    catch { response = SteamAgentEnvelope(serviceError: SteamServiceRequestError(code: "AGENT_ERROR", message: error.localizedDescription)) }
                    do { reply(.success(try JSONEncoder().encode(response))) }
                    catch { reply(.failure(error)) }
                }
            }
        }
        connection.onEvent = { command, data in
            guard command == "steam.cancel", let id = try? JSONDecoder().decode(UUID.self, from: data) else { return }
            Task { @MainActor in
                if let task = tasks[id] { task.cancel() }
                else { if cancelled.count > 1024 { cancelled.removeAll() }; cancelled.insert(id) }
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    private static func status() -> SteamAgentStatus {
        let host = SteamServiceHost.shared
        return SteamAgentStatus(isAvailable: host.isAvailable, isLoggedIn: host.isLoggedIn,
            loginState: host.loginState, authenticationState: host.authenticationState,
            accountName: host.accountName, steamId: host.steamId, savedUsername: host.savedUsername,
            favorites: host.workshopFavoriteIDs, hasBuiltInKey: SteamWebAPIBackend.hasBuiltInKey)
    }
    private static func publishStatus() {
        if let data = try? encode(status()) { wire?.send("steam.status", payload: data) }
    }
    private static func callback<T>(_ start: (@escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in start { continuation.resume(with: $0) } }
    }
    private static func execute(_ operation: SteamAgentOperation) async throws -> Data {
        if case .configure(let value) = operation {
            guard value.downloadDirectory.isFileURL, value.downloadDirectory.path.hasPrefix("/"),
                  value.previewDirectory.map({ $0.isFileURL && $0.path.hasPrefix("/") }) ?? true,
                  ["https://api.steampowered.com/", "https://steams.524228.xyz/"].contains(value.apiBaseURL) else {
                throw AgentTransportError.message(L("Steam 插件配置无效"))
            }
            if configuration != value {
                configuration = value
                SteamServiceHost.shared.configuration = value
                let proxy = AppHTTPProxy(settings: value.proxy)
                api = injectedAPI ?? SteamWebAPIBackend(apiKey: value.apiKey.isEmpty ? nil : value.apiKey, baseURL: value.apiBaseURL, proxy: proxy)
                explore = SteamExploreBackend(proxy: proxy)
            }
            return try encode(status())
        }
        guard let api, let configuration else { throw AgentTransportError.message(L("Steam 插件尚未配置")) }
        let host = SteamServiceHost.shared
        switch operation {
        case .configure: break
        case .start:
            if !started {
                started = true
                host.objectWillChange.receive(on: DispatchQueue.main).sink {
                    Task { @MainActor in publishStatus() }
                }.store(in: &observers)
                host.start()
            }
            return try encode(status())
        case .status: return try encode(status())
        case .restoreSession: host.restoreSessionIfNeeded()
        case .loginQR: host.loginWithQR()
        case .login(let username, let password): host.login(username: username, password: password)
        case .guardCode(let value): _ = host.submitGuardCode(value)
        case .cancelLogin: host.cancelLogin()
        case .logout: let _: Void = try await callback { host.logout(completion: $0) }
        case .subscriptions(let start): return try encode(try await callback { host.fetchSubscriptions(startIndex: start, completion: $0) })
        case .subscriptionStates(let ids): return try encode(try await callback { host.fetchSubscriptionStates(workshopIds: ids, completion: $0) })
        case .favorites:
            let ids: Set<String> = try await callback { host.refreshWorkshopFavorites(completion: $0) }
            return try encode(ids)
        case .favorite(let id, let enabled): let _: Void = try await callback { host.setWorkshopFavorite(workshopId: id, favorited: enabled, completion: $0) }
        case .subscribe(let id): let _: Void = try await callback { host.subscribe(workshopId: id, completion: $0) }
        case .unsubscribe(let id): let _: Void = try await callback { host.unsubscribe(workshopId: id, completion: $0) }
        case .comments(let item, let start, let count): return try encode(try await callback { host.fetchComments(item: item, startIndex: start, count: count, completion: $0) })
        case .postComment(let item, let text): let _: Void = try await callback { host.postComment(item: item, text: text, completion: $0) }
        case .download(let id, let attempt, let root, let managed):
            guard UUID(uuidString: attempt) != nil, root.isFileURL,
                  id.utf8.allSatisfy({ (48...57).contains($0) }), (UInt64(id) ?? 0) > 0 else {
                throw AgentTransportError.message(L("下载任务来源或目录无效"))
            }
            // Historical queued jobs retain their original output directory, even after a setting changes.
            if let old = downloads[attempt] {
                guard old.workshopID == id, old.root == root else { throw AgentTransportError.message(L("下载任务标识冲突")) }
                emit(old)
            } else {
                downloads[attempt] = SteamAgentDownloadEvent(attempt: attempt, workshopID: id, root: root, state: .resolving)
                host.downloadItem(workshopId: id, taskId: attempt, outputRoot: root, managedByCoordinator: managed) { state in
                    Task { @MainActor in
                        let event = SteamAgentDownloadEvent(attempt: attempt, workshopID: id, root: root, state: state)
                        downloads[attempt] = event
                        emit(event)
                    }
                }
            }
        case .stopDownload(let attempt, let pause):
            // Acknowledges receipt only; the original service emits the actual terminal state.
            let failure: (String) -> Void = { message in
                Task { @MainActor in
                    if let data = try? encode(SteamAgentStopFailure(attempt: attempt, message: message)) {
                        wire?.send("steam.downloadStopFailed", payload: data)
                    }
                }
            }
            if pause { host.pauseDownload(taskId: attempt, onFailure: failure) }
            else { host.cancelDownload(taskId: attempt, onFailure: failure) }
        case .downloadResults: return try encode(Array(downloads.values))
        case .acknowledgeDownload(let attempt):
            if downloads[attempt]?.state.isServiceTerminal == true { downloads.removeValue(forKey: attempt) }
        case .query(let query):
            let r = query.request
            return try encode(try await api.queryFiles(searchText: r.text, tags: r.tags.sorted(), sortOrder: r.sort,
                typeFilters: r.types, ageRating: r.ageRating, widescreenResolution: r.widescreen,
                ultraWidescreenResolution: r.ultraWidescreen, dualscreenResolution: r.dualscreen,
                triplescreenResolution: r.triplescreen, portraitResolution: r.portrait, miscResolution: r.misc,
                showOnly: r.showOnly, favoriteIDs: r.favoriteIDs, page: r.page, perPage: r.perPage,
                trendDays: query.trendDays, enrichCreatorProfiles: query.enrichCreatorProfiles, reuseFilteredPages: query.reuseFilteredPages))
        case .discover(let text, let sort, let required, let excluded, let page, let count, let days):
            let value = try await api.queryDiscoverFiles(searchText: text, sortOrder: sort, requiredTags: required, excludedTags: excluded, page: page, perPage: count, trendDays: days)
            return try encode(SteamAgentPage(items: value.items, total: value.total))
        case .details(let ids, let enrich): return try encode(try await api.getFileDetails(workshopIds: ids, enrichCreatorProfiles: enrich))
        case .userFiles(let id, let page, let count, let sort, let required, let excluded, let enrich):
            let value = try await api.getUserFiles(steamId: id, page: page, perPage: count, sortMethod: sort, requiredTags: required, excludedTags: excluded, enrichCreatorProfiles: enrich)
            return try encode(SteamAgentPage(items: value.items, total: value.total))
        case .collection(let id, let page, let count):
            let value = try await api.getCollectionItems(collectionId: id, page: page, perPage: count)
            return try encode(SteamAgentPage(items: value.items, total: value.total))
        case .creator(let id): return try encode(await api.creatorProfile(steamId: id))
        case .enrich(let items): return try encode(await api.enrichCreatorDetails(in: items))
        case .invalidateBrowse: api.invalidateBrowseCache()
        case .explore(let force): return try encode(try await explore!.fetch(force: force))
        case .preview(let url):
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw SteamAPIError.invalidURL }
            let data = try await api.downloadPreviewImage(url: url)
            let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let directory = configuration.previewDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appending(path: "motiscape/SteamAgentPreviews")
            let file = directory.appending(path: digest)
            try await Task.detached {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            }.value
            return try encode(SteamAgentPreview(file: file))
        }
        _ = configuration
        return try encode(SteamAgentEmpty())
    }
    private static func emit(_ event: SteamAgentDownloadEvent) {
        if let data = try? encode(event) { wire?.send("steam.download", payload: data) }
    }
    static func shutdown() async throws {
        tasks.values.forEach { $0.cancel() }
        if started { try await SteamServiceHost.shared.shutdown() }
        observers.removeAll()
    }
}

enum SteamAgentLog {
    static func append(_ text: String, source: String) { NSLog("[%@] %@", source, text) }
}
