import AppKit
import Combine
import Darwin
import Foundation
import Network

struct InstalledAgent: Codable, Identifiable {
    let id: String
    let role: AgentRole
    let name: String
    let version: String
    let relativePath: String
    var isActive = false
    /// Present only for user-selected external apps; legacy records remain managed copies.
    var securityScopedBookmark: Data? = nil
    var localizedName: String { L(role.displayKey) }
}

final class PluginManager: ObservableObject, @unchecked Sendable {
    static let shared = PluginManager()
    @Published private(set) var plugins: [InstalledAgent] = []
    @Published private(set) var isConfiguring = false
    @Published private(set) var lastError: String?
    @Published private(set) var removingPluginID: String?
    var isBusy: Bool { isConfiguring || removingPluginID != nil }
    private let directory: URL
    private let registryURL: URL
    @Published private var activeRoles: Set<AgentRole>
    private let lock = NSLock()
    private var connections: [AgentRole: AgentConnection] = [:]
    private var sessions: [AgentRole: AgentLaunchSession] = [:]
    private var installationSession: AgentLaunchSession?
    private var heartbeat: Timer?
    private var started = false
    private var stopping = false
    private var languageObserver: NSObjectProtocol?

    var hasWallpaperAgent: Bool { activeRoles.contains(.wallpaper) }
    var hasMediaAgent: Bool { activeRoles.contains(.media) }
    var hasSteamAgent: Bool { activeRoles.contains(.steam) }
    /// Owner persists pending downloads before the Steam process is stopped.
    var beforeSteamStop: (@MainActor () async throws -> Void)?
    var afterSteamStop: (@MainActor () async throws -> Void)?

    private init() {
        directory = (AppIntegrationFixture.supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("motiscape"))
            .appendingPathComponent("AgentPlugins", isDirectory: true)
        registryURL = directory.appendingPathComponent("plugins.json")
        let pluginDirectory = directory
        let saved = (try? Data(contentsOf: registryURL)).flatMap { try? JSONDecoder().decode([InstalledAgent].self, from: $0) } ?? []
        let installed = saved.filter {
            // Keep external references even when their app is unavailable, so the
            // user can remove the association and startup can report the error.
            $0.securityScopedBookmark != nil ||
            (!$0.relativePath.contains("..") && !$0.relativePath.hasPrefix("/") &&
             FileManager.default.fileExists(atPath: pluginDirectory.appendingPathComponent($0.relativePath).path))
        }.map { var item = $0; item.isActive = true; return item }
        activeRoles = Set(installed.map(\.role))
        plugins = installed
        languageObserver = NotificationCenter.default.addObserver(
            forName: MotiscapeLocalization.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.synchronizeLanguage() }
        }
    }

    func connection(for role: AgentRole) -> AgentConnection? {
        lock.lock(); defer { lock.unlock() }; return connections[role]
    }

    private func setConnection(_ connection: AgentConnection?, for role: AgentRole) {
        lock.lock(); connections[role] = connection; lock.unlock()
        NotificationCenter.default.post(name: .agentConnectionChanged, object: self, userInfo: ["role": role])
    }

    @MainActor private func synchronizeLanguage() {
        objectWillChange.send()
        guard let data = try? JSONEncoder().encode(MotiscapeLocalization.shared.locale.identifier) else { return }
        for role in AgentRole.allCases { connection(for: role)?.send("agent.language", payload: data) }
    }

    @MainActor func install(from source: URL) async throws {
        guard !stopping else { throw AgentTransportError.message(L("主程序正在退出")) }
        guard installationSession == nil else { throw AgentTransportError.message(L("上一次配置的插件尚未退出。请退出并重新打开 motiscape 后重试。")) }
        guard !isConfiguring else { throw AgentTransportError.message(L("正在配置另一个插件")) }
        guard removingPluginID == nil else { throw AgentTransportError.message(L("正在处理另一个插件，请稍后重试。")) }
        let access = AgentAppAccess(url: source)
        defer { withExtendedLifetime(access) {} }
        guard source.pathExtension.lowercased() == "app", let bundle = Bundle(url: source), bundle.executableURL != nil else {
            throw AgentTransportError.message(L("请选择有效的插件 App。"))
        }
        isConfiguring = true
        defer {
            isConfiguring = false
            if installationSession?.confirmedExited != false { installationSession = nil }
        }
        let installID = UUID().uuidString
        var committed = false
        let destination: URL
        let bookmark: Data?
        let relativePath: String
        #if MOTISCAPE_SANDBOX_TEST
        // A sandbox-created copy acquires a quarantine flag that prevents its
        // execution. Keep the user's original app and its scoped authorization.
        destination = source
        bookmark = try source.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        relativePath = ""
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #else
        let staging = directory.appendingPathComponent(installID, isDirectory: true)
        destination = staging.appendingPathComponent(source.lastPathComponent)
        bookmark = nil
        relativePath = installID + "/" + source.lastPathComponent
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { if !committed { try? FileManager.default.removeItem(at: staging) } }
        // FileManager preserves the copied bundle, its signature and quarantine metadata.
        try await Task.detached { try FileManager.default.copyItem(at: source, to: destination) }.value
        #endif
        guard !stopping else { throw AgentTransportError.message(L("插件安装已取消，主程序正在退出")) }
        let session = AgentLaunchSession(url: destination, configureOnly: true,
            access: bookmark != nil ? access : nil)
        installationSession = session
        do {
            let declaration = try await session.launch()
            guard !plugins.contains(where: { $0.role == declaration.role }) else {
                throw AgentTransportError.message(L("已添加此类插件，请勿重复添加"))
            }
            _ = try await session.connection?.request("agent.shutdown", timeout: 20)
            guard await session.waitForExit() else { throw AgentTransportError.message(L("配置完成，但插件尚未退出")) }
            guard !stopping else { throw AgentTransportError.message(L("插件安装已取消，主程序正在退出")) }
            let item = InstalledAgent(id: declaration.bundleIdentifier, role: declaration.role,
                name: declaration.name, version: declaration.version,
                relativePath: relativePath, isActive: false, securityScopedBookmark: bookmark)
            let updated = plugins + [item]
            try JSONEncoder().encode(updated).write(to: registryURL, options: .atomic)
            plugins = updated
            committed = true
        } catch {
            do { try await session.abortConfiguration() }
            catch {
                // Keep the candidate and process tracked until exit is confirmed.
                committed = true
                throw error
            }
            throw error
        }
    }

    @MainActor func remove(_ plugin: InstalledAgent) async throws {
        guard !stopping else { throw AgentTransportError.message(L("主程序正在退出")) }
        guard !isBusy else { throw AgentTransportError.message(L("正在处理另一个插件，请稍后重试。")) }
        guard let installed = plugins.first(where: { $0.id == plugin.id }) else { return }
        removingPluginID = installed.id
        lastError = nil
        defer { removingPluginID = nil }

        // Restoration must succeed and the process must actually exit before
        // changing either the installation record or the managed app bundle.
        if let session = sessions[installed.role] {
            do {
                if installed.role == .steam { try await beforeSteamStop?() }
                try await session.stop()
                if installed.role == .steam { try await afterSteamStop?() }
            }
            catch {
                throw AgentTransportError.message(L("无法删除插件，已保留插件文件。%@", error.localizedDescription))
            }
        }
        let fm = FileManager.default
        let updated = plugins.filter { $0.id != installed.id }
        var removedFolder: URL?
        if installed.securityScopedBookmark != nil {
            // Unlinking must never move or delete the user's original app, even
            // if its bookmark no longer resolves or its volume is disconnected.
            try JSONEncoder().encode(updated).write(to: registryURL, options: .atomic)
        } else {
            let components = installed.relativePath.split(separator: "/").map(String.init)
            guard components.count == 2, UUID(uuidString: components[0]) != nil,
                  components[1].hasSuffix(".app") else {
                throw AgentTransportError.message(L("插件安装位置无效，无法删除。"))
            }
            let folder = directory.appendingPathComponent(components[0], isDirectory: true)
            let temporaryFolder = directory.appendingPathComponent(".removed-" + UUID().uuidString, isDirectory: true)
            let exists = fm.fileExists(atPath: folder.path)
            if exists { try fm.moveItem(at: folder, to: temporaryFolder) }
            do {
                try JSONEncoder().encode(updated).write(to: registryURL, options: .atomic)
            } catch {
                if exists { try? fm.moveItem(at: temporaryFolder, to: folder) }
                throw error
            }
            if exists { removedFolder = temporaryFolder }
        }
        sessions.removeValue(forKey: installed.role)
        setConnection(nil, for: installed.role)
        activeRoles.remove(installed.role)
        plugins = updated
        if installed.role == .wallpaper {
            WallpaperAgentClient.disconnected()
            AppDelegate.shared.wallpaperViewModel.resumeAfterExternalLockScreen()
        }
        if let removedFolder {
            do { try await Task.detached { try FileManager.default.removeItem(at: removedFolder) }.value }
            catch {
                let message = L("插件已停用，但未能删除文件：%@", error.localizedDescription)
                lastError = message
                throw AgentTransportError.message(message)
            }
        }
    }

    @MainActor func start() {
        guard !stopping, !started, !AppIntegrationFixture.isLibraryUI else { return }
        started = true
        for item in plugins where item.isActive {
            Task {
                guard !stopping, removingPluginID != item.id, plugins.contains(where: { $0.id == item.id && $0.isActive }) else { return }
                let session: AgentLaunchSession
                do { session = try launchSession(for: item) }
                catch {
                    lastError = L("%@：%@", item.localizedName, error.localizedDescription)
                    return
                }
                sessions[item.role] = session
                session.eventHandler = { [weak self] command, payload in
                    guard let self else { return }
                    if item.role == .wallpaper, command.hasPrefix("host.") {
                        WallpaperAgentHost.handle(command, payload: payload) { _ in }
                        return
                    }
                    if command == "wallpaper.error", let message = try? JSONDecoder().decode(String.self, from: payload) { self.lastError = message }
                    if item.role == .wallpaper, command == "wallpaper.status" { WallpaperAgentClient.receive(payload) }
                    NotificationCenter.default.post(name: .agentEvent, object: self,
                        userInfo: ["role": item.role, "command": command, "payload": payload])
                }
                session.requestHandler = { command, payload, reply in
                    if item.role == .wallpaper { WallpaperAgentHost.handle(command, payload: payload, completion: reply) }
                    else { reply(.failure(AgentTransportError.message(L("不支持此插件请求")))) }
                }
                session.closeHandler = { [weak self, weak session] in
                    guard let self, let session, self.sessions[item.role] === session else { return }
                    if item.role == .wallpaper { WallpaperAgentClient.disconnected() }
                    self.setConnection(nil, for: item.role)
                    if item.role == .wallpaper && !self.stopping { AppDelegate.shared.wallpaperViewModel.resumeAfterExternalLockScreen() }
                    if !self.stopping && self.removingPluginID != item.id && self.plugins.contains(where: { $0.id == item.id }) { self.lastError = L("%@插件已断开连接，请重新启动 App。", item.localizedName) }
                }
                do {
                    let declaration = try await session.launch()
                    guard declaration.role == item.role, declaration.bundleIdentifier == item.id else {
                        throw AgentTransportError.message(L("插件声明与安装记录不一致"))
                    }
                    guard !stopping else { try? await session.stop(); return }
                    setConnection(session.connection, for: item.role)
                } catch {
                    try? await session.stop()
                    if removingPluginID != item.id && plugins.contains(where: { $0.id == item.id }) {
                        lastError = L("%@：%@", item.localizedName, error.localizedDescription)
                    }
                }
            }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            for role in AgentRole.allCases { self.connection(for: role)?.send("agent.heartbeat") }
        }
    }

    @MainActor private func launchSession(for item: InstalledAgent) throws -> AgentLaunchSession {
        guard let bookmark = item.securityScopedBookmark else {
            return AgentLaunchSession(url: directory.appendingPathComponent(item.relativePath), configureOnly: false)
        }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let access = AgentAppAccess(url: url)
        if stale, let index = plugins.firstIndex(where: { $0.id == item.id }) {
            var updated = plugins
            updated[index].securityScopedBookmark = try url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: nil, relativeTo: nil)
            try JSONEncoder().encode(updated).write(to: registryURL, options: .atomic)
            plugins = updated
        }
        return AgentLaunchSession(url: url, configureOnly: false, access: access)
    }

    @MainActor func shutdown() async throws {
        stopping = true
        // Keep heartbeats alive until cleanup has finished or the user has
        // resolved an error; an error must not silently turn into a timeout quit.
        // Copying may still be in progress before an installation process exists.
        // install() observes stopping before it launches or commits a candidate.
        if let installationSession { try await installationSession.abortConfiguration() }
        while isBusy { try await Task.sleep(nanoseconds: 100_000_000) }
        if sessions[.steam] != nil { try await beforeSteamStop?() }
        var failures: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for (role, session) in sessions {
                group.addTask {
                    do { try await session.stop(); return nil }
                    catch { return L("%@：%@", L(role.displayKey), error.localizedDescription) }
                }
            }
            for await error in group { if let error { failures.append(error) } }
        }
        if !failures.isEmpty { throw AgentTransportError.message(failures.joined(separator: "\n")) }
        if sessions[.steam] != nil { try await afterSteamStop?() }
        finishShutdown()
    }

    @MainActor func requestRecoveryPermissions() {
        connection(for: .wallpaper)?.send("lockA.permissions")
    }

    @MainActor func exitAfterRecoveryFailure() async throws {
        if let installationSession { try await installationSession.exitWithoutRestore() }
        var failures: [String] = []
        for session in sessions.values {
            do { try await session.exitWithoutRestore() }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw AgentTransportError.message(failures.joined(separator: "\n")) }
        if sessions[.steam] != nil { try await afterSteamStop?() }
        finishShutdown()
    }

    @MainActor func cancelShutdown() {
        stopping = false
        lastError = L("已取消退出，部分插件已停止。请解决恢复错误后，退出并重新打开 motiscape。")
    }

    @MainActor private func finishShutdown() {
        heartbeat?.invalidate()
        for role in AgentRole.allCases { setConnection(nil, for: role) }
        sessions.removeAll()
        installationSession = nil
    }

}

/// One balanced scope per URL resolution. A failed shutdown keeps this object
/// with its tracked session until the process has actually exited.
private final class AgentAppAccess {
    let url: URL
    private let accessing: Bool

    init(url: URL) {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if accessing { url.stopAccessingSecurityScopedResource() }
    }
}

@MainActor
private final class AgentLaunchSession {
    let url: URL
    let configureOnly: Bool
    var connection: AgentConnection?
    var eventHandler: ((String, Data) -> Void)?
    var requestHandler: ((String, Data, @escaping AgentConnection.Completion) -> Void)?
    var closeHandler: (() -> Void)?
    private var listener: NWListener?
    private var application: NSRunningApplication?
    private var launchContinuation: CheckedContinuation<AgentDeclaration, Error>?
    private var declaration: AgentDeclaration?
    private let session = UUID()
    private let token = UUID().uuidString + UUID().uuidString
    private var authenticated = false
    private var stopping = false
    private var openInFlight = false
    private var candidates: [AgentConnection] = []
    private var access: AgentAppAccess?
    private var bootstrapDirectory: URL?

    init(url: URL, configureOnly: Bool, access: AgentAppAccess? = nil) {
        self.url = url
        self.configureOnly = configureOnly
        self.access = access
    }

    func launch() async throws -> AgentDeclaration {
        guard let bundleID = Bundle(url: url)?.bundleIdentifier,
              AgentRole.allCases.contains(where: { $0.bundleIdentifier == bundleID }) else {
            throw AgentTransportError.message(L("此 App 不是 motiscape 支持的插件。"))
        }
        #if MOTISCAPE_SANDBOX_TEST
        guard Bundle(url: url)?.object(forInfoDictionaryKey: "MotiscapeAgentSessionFileVersion") as? Int == AgentSessionBootstrap.formatVersion else {
            throw AgentTransportError.message(L("此 App 不是 motiscape 支持的插件。"))
        }
        #endif
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] incoming in
            Task { @MainActor in self?.accept(incoming, bundleID: bundleID) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            launchContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, !self.stopping else { return }
                    if case .ready = state, let port = listener.port {
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = false
                        config.createsNewApplicationInstance = true
                        let completion: (NSRunningApplication?, Error?) -> Void = { app, error in
                            Task { @MainActor in
                                self.openInFlight = false
                                self.application = app
                                if self.stopping { app?.terminate(); return }
                                if let error { self.complete(.failure(error)) }
                            }
                        }
                        #if MOTISCAPE_SANDBOX_TEST
                        do {
                            let file = try self.writeBootstrap(bundleID: bundleID, port: port.rawValue)
                            self.openInFlight = true
                            NSWorkspace.shared.open([file], withApplicationAt: self.url,
                                configuration: config, completionHandler: completion)
                        } catch { self.complete(.failure(error)) }
                        #else
                        config.arguments = ["--agent-port", String(port.rawValue), "--agent-token", self.token, "--agent-session", self.session.uuidString]
                        config.arguments += ["--agent-language", MotiscapeLocalization.shared.locale.identifier]
                        if self.configureOnly { config.arguments += ["--agent-configure"] }
                        self.openInFlight = true
                        NSWorkspace.shared.openApplication(at: self.url, configuration: config, completionHandler: completion)
                        #endif
                    } else if case .failed(let error) = state { self.complete(.failure(error)) }
                }
            }
            listener.start(queue: DispatchQueue(label: "motiscape.agent.listener"))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.complete(.failure(AgentTransportError.message(L("插件配置超时，请检查系统首次打开提示"))))
            }
        }
    }

    private func writeBootstrap(bundleID: String, port: UInt16) throws -> URL {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("AgentSessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        bootstrapDirectory = directory
        let file = directory.appendingPathComponent("session." + AgentSessionBootstrap.fileExtension)
        let bootstrap = AgentSessionBootstrap(version: AgentSessionBootstrap.formatVersion,
            bundleIdentifier: bundleID, port: port, token: token, session: session,
            language: MotiscapeLocalization.shared.locale.identifier, configureOnly: configureOnly,
            expiresAt: Date().addingTimeInterval(60))
        let data = try JSONEncoder().encode(bootstrap)
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        return file
    }

    private func removeBootstrap() {
        guard let directory = bootstrapDirectory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            bootstrapDirectory = nil
        } catch {
            // Retry at transport closure if a transient filesystem error occurs.
            // Never log the session data or alter any URL from an incoming app.
        }
    }

    private func accept(_ incoming: NWConnection, bundleID: String) {
        guard !stopping, !authenticated, candidates.count < 4 else { incoming.cancel(); return }
        let wire = AgentConnection(incoming)
        candidates.append(wire)
        wire.onRequest = { [weak self, weak wire] command, payload, reply in
            Task { @MainActor in
                guard let self, let wire, !self.stopping || self.connection === wire else { return }
                if !self.authenticated {
                    guard command == "agent.hello", let hello = try? JSONDecoder().decode(AgentHello.self, from: payload),
                          hello.token == self.token, hello.session == self.session,
                          hello.declaration.isCompatible(with: bundleID) else {
                        reply(.failure(AgentTransportError.message(L("插件声明验证失败")))); wire.close(); return
                    }
                    self.authenticated = true; self.declaration = hello.declaration; self.connection = wire
                    self.removeBootstrap()
                    self.listener?.cancel()
                    for other in self.candidates where other !== wire { other.close() }
                    self.candidates.removeAll()
                    reply(.success(Data()))
                    if self.configureOnly { self.complete(.success(hello.declaration)) }
                } else if self.connection === wire {
                    self.requestHandler?(command, payload, reply)
                }
            }
        }
        wire.onEvent = { [weak self, weak wire] command, payload in
            Task { @MainActor in
                guard let self, self.authenticated, self.connection === wire else { return }
                if command == "agent.ready", let declaration = self.declaration { self.complete(.success(declaration)) }
                else { self.eventHandler?(command, payload) }
            }
        }
        wire.onClose = { [weak self, weak wire] in
            Task { @MainActor in
                guard let self, self.connection === wire else { return }
                self.complete(.failure(AgentTransportError.message(L("插件启动时断开连接"))))
                self.closeHandler?()
            }
        }
        wire.start()
    }

    private func complete(_ result: Result<AgentDeclaration, Error>) {
        guard let continuation = launchContinuation else { return }
        launchContinuation = nil
        if case .failure = result { removeBootstrap() }
        continuation.resume(with: result)
    }

    var confirmedExited: Bool { !openInFlight && application?.isTerminated != false }

    func waitForExit() async -> Bool {
        for _ in 0..<80 {
            if confirmedExited { removeBootstrap(); access = nil; return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    func stop() async throws {
        stopping = true
        complete(.failure(AgentTransportError.message(L("插件启动已取消"))))
        listener?.cancel()
        if !openInFlight && application?.isTerminated == true { closeTransport(); return }
        if let connection {
            _ = try await connection.request("agent.shutdown", timeout: 30)
        } else {
            application?.terminate()
        }
        guard await waitForExit() else { throw AgentTransportError.message(L("插件尚未退出，无法关闭主程序。请重试。")) }
        closeTransport()
    }

    func exitWithoutRestore() async throws {
        stopping = true
        complete(.failure(AgentTransportError.message(L("插件启动已取消"))))
        listener?.cancel()
        if let connection, application?.isTerminated != true {
            _ = try? await connection.request("agent.exitWithoutRestore", timeout: 5)
        }
        if !(await waitForExit()) {
            // This path is reached only after the user acknowledges failed
            // recovery and explicitly chooses to exit anyway.
            application?.forceTerminate()
            guard await waitForExit() else { throw AgentTransportError.message(L("无法确认插件已退出")) }
        }
        closeTransport()
    }

    func abortConfiguration() async throws {
        precondition(configureOnly)
        do { try await stop() }
        catch {
            // Configuration mode has no feature state to restore. This is only
            // the new candidate launched by this installation attempt.
            application?.terminate()
            if !(await waitForExit()) {
                application?.forceTerminate()
                guard await waitForExit() else { throw AgentTransportError.message(L("无法确认配置中的插件已退出")) }
            }
            closeTransport()
        }
    }

    private func closeTransport() {
        removeBootstrap()
        connection?.close()
        listener?.cancel()
        candidates.forEach { $0.close() }
        candidates.removeAll()
        if confirmedExited { access = nil }
    }
}
