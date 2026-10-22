import Foundation
import Combine

/// The existing public interface is retained; Steam execution and credentials live in the Agent.
final class SteamServiceManager: ObservableObject, @unchecked Sendable {
    static let shared = SteamServiceManager()
    @Published private(set) var isAvailable = false
    @Published private(set) var isLoggedIn = false
    @Published private(set) var loginState: SteamLoginState = .idle
    @Published private(set) var authenticationState: SteamServiceState = .unknown
    @Published private(set) var accountName = ""
    @Published private(set) var steamId = ""
    @Published private(set) var workshopFavoriteIDs: Set<String> = []
    @Published private(set) var hasBuiltInKey = false
    private(set) var savedUsername = ""
    private var observers: [NSObjectProtocol] = []
    private var downloadHandlers: [String: (DownloadState) -> Void] = [:]
    private var stopFailures: [String: (String) -> Void] = [:]
    private var stopping = false
    private var connected: AgentConnection?

    var contentDirectory: URL { WallpaperLibrary.shared.managedWorkshopDirectory }
    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        observers.append(NotificationCenter.default.addObserver(forName: .agentConnectionChanged, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["role"] as? AgentRole == .steam else { return }
            self?.connectionChanged()
        })
        observers.append(NotificationCenter.default.addObserver(forName: .agentEvent, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?["role"] as? AgentRole == .steam,
                  let command = note.userInfo?["command"] as? String,
                  let data = note.userInfo?["payload"] as? Data else { return }
            if command == "steam.downloadStopFailed", let failure = try? JSONDecoder().decode(SteamAgentStopFailure.self, from: data) {
                self?.stopFailures.removeValue(forKey: failure.attempt)?(failure.message)
            }
            if command == "steam.status", let status = try? JSONDecoder().decode(SteamAgentStatus.self, from: data) { self?.apply(status) }
            if command == "steam.download", let event = try? JSONDecoder().decode(SteamAgentDownloadEvent.self, from: data) { self?.receive(event) }
        })
        connectionChanged()
    }

    private func connectionChanged() {
        connected = PluginManager.shared.connection(for: .steam)
        guard connected != nil else {
            apply(SteamAgentStatus(authenticationState: .unavailable(L("Steam 服务插件未连接"))))
            // Do not fabricate a terminal state: the Agent may still be stopping its worker.
            // Existing queue persistence retains the job for verification after app restart.
            return
        }
        perform(.start) { [weak self] (result: Result<SteamAgentStatus, Error>) in
            if case .success(let status) = result { self?.apply(status) }
            if case .failure(let error) = result { self?.authenticationState = .unavailable(error.localizedDescription) }
            self?.perform(.downloadResults) { (result: Result<[SteamAgentDownloadEvent], Error>) in
                if case .success(let events) = result { events.forEach { self?.receive($0) } }
            }
        }
    }

    func apply(_ status: SteamAgentStatus) {
        if hasBuiltInKey != (status.hasBuiltInKey) { hasBuiltInKey = status.hasBuiltInKey }
        if savedUsername != (status.savedUsername) { savedUsername = status.savedUsername }
        if accountName != (status.accountName) { accountName = status.accountName }
        if steamId != (status.steamId) { steamId = status.steamId }
        if workshopFavoriteIDs != (status.favorites) { workshopFavoriteIDs = status.favorites }
        if isAvailable != (status.isAvailable && !stopping) { isAvailable = status.isAvailable && !stopping }
        if loginState != (status.loginState) { loginState = status.loginState }
        if authenticationState != (status.authenticationState) { authenticationState = status.authenticationState }
        if isLoggedIn != (status.isLoggedIn && !stopping) { isLoggedIn = status.isLoggedIn && !stopping }
    }

    private func perform<T: Decodable>(_ operation: SteamAgentOperation, completion: @escaping (Result<T, Error>) -> Void) {
        Task { @MainActor in
            do { completion(.success(try await SteamAgentClient.shared.call(operation))) }
            catch { completion(.failure(error)) }
        }
    }
    private func action(_ operation: SteamAgentOperation, completion: ((Result<Void, Error>) -> Void)? = nil) {
        perform(operation) { [weak self] (result: Result<SteamAgentEmpty, Error>) in
            if let completion { completion(result.map { _ in () }) }
            else if case .failure(let error) = result { self?.authenticationState = .unavailable(error.localizedDescription) }
        }
    }
    func restoreSessionIfNeeded() { action(.restoreSession) }
    func loginWithQR() { action(.loginQR) }
    func login(username: String, password: String) { action(.login(username: username, password: password)) }
    @discardableResult func submitGuardCode(_ code: String) -> Bool {
        guard !code.isEmpty, connected != nil else { return false }
        action(.guardCode(code)); return true
    }
    func cancelLogin() { action(.cancelLogin) }
    func logout(completion: @escaping (Result<Void, Error>) -> Void) { action(.logout, completion: completion) }
    func fetchSubscriptions(startIndex: Int, completion: @escaping (Result<WorkshopSubscriptionPage, Error>) -> Void) {
        perform(.subscriptions(start: startIndex), completion: completion)
    }
    func refreshWorkshopFavorites(completion: ((Result<Set<String>, Error>) -> Void)? = nil) {
        perform(.favorites) { [weak self] (result: Result<Set<String>, Error>) in
            if case .success(let ids) = result { self?.workshopFavoriteIDs = ids }
            completion?(result)
        }
    }
    func setWorkshopFavorite(workshopId: String, favorited: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        action(.favorite(id: workshopId, enabled: favorited), completion: completion)
    }
    func fetchSubscriptionStates(workshopIds: [String], completion: @escaping (Result<[String: Bool], Error>) -> Void) {
        perform(.subscriptionStates(workshopIds), completion: completion)
    }
    func subscribe(workshopId: String, completion: @escaping (Result<Void, Error>) -> Void) { action(.subscribe(workshopId), completion: completion) }
    func unsubscribe(workshopId: String, completion: @escaping (Result<Void, Error>) -> Void) { action(.unsubscribe(workshopId), completion: completion) }
    func fetchComments(item: WorkshopItem, startIndex: Int, count: Int = 30, completion: @escaping (Result<WorkshopCommentPage, Error>) -> Void) {
        perform(.comments(item: item, start: startIndex, count: count), completion: completion)
    }
    func postComment(item: WorkshopItem, text: String, completion: @escaping (Result<Void, Error>) -> Void) {
        action(.postComment(item: item, text: text), completion: completion)
    }
    func downloadItem(workshopId: String, taskId: String, outputRoot: URL? = nil,
                      managedByCoordinator: Bool = false, onProgress: @escaping (DownloadState) -> Void) {
        downloadHandlers[taskId] = onProgress
        action(.download(id: workshopId, attempt: taskId, root: outputRoot ?? contentDirectory, managed: managedByCoordinator)) { [weak self] result in
            if case .failure(let error) = result { self?.downloadHandlers.removeValue(forKey: taskId)?(.failed(error.localizedDescription)) }
        }
    }
    func cancelDownload(taskId: String, onFailure: ((String) -> Void)? = nil) {
        stopDownload(taskId: taskId, pause: false, onFailure: onFailure)
    }
    func pauseDownload(taskId: String, onFailure: @escaping (String) -> Void) {
        stopDownload(taskId: taskId, pause: true, onFailure: onFailure)
    }
    private func stopDownload(taskId: String, pause: Bool, onFailure: ((String) -> Void)?) {
        if let onFailure { stopFailures[taskId] = onFailure }
        action(.stopDownload(attempt: taskId, pause: pause)) { [weak self] result in
            if case .failure(let error) = result { self?.stopFailures.removeValue(forKey: taskId)?(error.localizedDescription) }
        }
    }
    private func receive(_ event: SteamAgentDownloadEvent) {
        guard let handler = downloadHandlers[event.attempt] else { return }
        handler(event.state)
        if event.state.isServiceTerminal {
            downloadHandlers.removeValue(forKey: event.attempt)
            stopFailures.removeValue(forKey: event.attempt)
        }
    }
    func downloadedItemDirectory(workshopId: String) -> URL? {
        let url = contentDirectory.appending(path: workshopId, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.appending(path: "project.json").path) ? url : nil
    }
    func prepareForAgentStop() {
        stopping = true
        isLoggedIn = false
        isAvailable = false
    }
    /// Called only after PluginManager has confirmed the Agent and its child exited.
    func agentDidStop() {
        let callbacks = Array(downloadHandlers.values)
        downloadHandlers.removeAll()
        stopFailures.removeAll()
        callbacks.forEach { $0(.paused) }
    }
    /// Agent shutdown is awaited by PluginManager; this no longer owns a local process.
    func shutdown() {}
}
