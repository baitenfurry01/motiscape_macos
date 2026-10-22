import AppKit
import Darwin
import Foundation
import Network

#if !AGENT_BOOTSTRAP_TEST
@main
struct AgentMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AgentRuntime()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif

/// Session documents carry data only. The owning main app creates and removes
/// them; an Agent never deletes a URL supplied through an open-document event.
enum AgentBootstrapFile {
    static func read(_ url: URL, bundleIdentifier: String) throws -> AgentSessionBootstrap {
        func invalid() -> AgentTransportError { .message("Invalid Agent session document") }
        guard url.isFileURL, url.pathExtension == AgentSessionBootstrap.fileExtension else { throw invalid() }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw invalid() }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= 16_384 else { throw invalid() }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while data.count <= 16_384 {
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0 { if errno == EINTR { continue }; throw invalid() }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
        guard data.count == info.st_size, data.count <= 16_384 else { throw invalid() }
        let document = try JSONDecoder().decode(AgentSessionBootstrap.self, from: data)
        guard document.isValid(for: bundleIdentifier) else { throw invalid() }
        return document
    }
}

@MainActor
final class AgentRuntime: NSObject, NSApplicationDelegate {
    private var connection: AgentConnection?
    private var timer: Timer?
    private var lastHeartbeat = ProcessInfo.processInfo.systemUptime
    private var stopping = false
    private var configuredOnly = false
    private var started = false
    private var cleanupTask: Task<Void, Error>?
    private var terminationApproved = false
    private var terminationReplyPending = false
    private var signalSources: [DispatchSourceSignal] = []
    private var wakeObserver: NSObjectProtocol?
    private var didFinishLaunching = false
    private var pendingBootstrap: AgentSessionBootstrap?
    private var bootstrapWaitTimer: Timer?

    func application(_ application: NSApplication, open urls: [URL]) {
        // First valid session owns this process. Later document events cannot
        // replace its connection or initialize a business adapter twice.
        guard connection == nil, pendingBootstrap == nil, !stopping,
              urls.count == 1, let bundleID = Bundle.main.bundleIdentifier else { return }
        let scope = urls[0].startAccessingSecurityScopedResource()
        defer { if scope { urls[0].stopAccessingSecurityScopedResource() } }
        do {
            pendingBootstrap = try AgentBootstrapFile.read(urls[0], bundleIdentifier: bundleID)
            if didFinishLaunching { startPendingBootstrap() }
        } catch {
            // No document contents or session token is logged.
            NSLog("Agent rejected an invalid session document")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        if pendingBootstrap != nil { startPendingBootstrap(); return }
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        guard let portText = value("--agent-port"), let port = NWEndpoint.Port(portText),
              let token = value("--agent-token"), let sessionText = value("--agent-session"),
              let session = UUID(uuidString: sessionText), let bundleID = Bundle.main.bundleIdentifier else {
            // Launch Services may deliver the document after this callback.
            // Manually opening this headless app still exits without side effects.
            bootstrapWaitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.connection == nil else { return }
                    // Finish cleanup before asking AppKit to terminate. Calling
                    // terminate here without approval enters a nested event loop
                    // that can prevent the delegate's MainActor cleanup task
                    // from running, leaving an unconnected Agent alive.
                    await self.stop()
                }
            }
            return
        }
        startConnection(port: port, token: token, session: session, bundleID: bundleID,
            language: value("--agent-language") ?? Locale.preferredLanguages.first ?? "en",
            configureOnly: args.contains("--agent-configure"))
    }

    private func startPendingBootstrap() {
        guard let document = pendingBootstrap, let port = NWEndpoint.Port(rawValue: document.port),
              connection == nil, !stopping else { return }
        pendingBootstrap = nil
        startConnection(port: port, token: document.token, session: document.session,
            bundleID: document.bundleIdentifier, language: document.language, configureOnly: document.configureOnly)
    }

    private func startConnection(port: NWEndpoint.Port, token: String, session: UUID,
                                 bundleID: String, language: String, configureOnly: Bool) {
        guard connection == nil, !stopping else { return }
        bootstrapWaitTimer?.invalidate()
        bootstrapWaitTimer = nil
        MotiscapeLocalization.shared.locale = Locale(identifier: language)
        configuredOnly = configureOnly
        #if WALLPAPER_AGENT
        let role = AgentRole.wallpaper
        let nameKey = "屏保与锁屏"
        #elseif STEAM_AGENT
        let role = AgentRole.steam
        let nameKey = "Steam 服务"
        #else
        let role = AgentRole.media
        let nameKey = "歌曲信息"
        #endif
        let wire = AgentConnection(NWConnection(host: "127.0.0.1", port: port, using: .tcp))
        connection = wire
        wire.onClose = { [weak self] in Task { @MainActor in await self?.stop() } }
        func declaration() -> AgentDeclaration {
            AgentDeclaration(role: role, bundleIdentifier: bundleID, name: L(nameKey),
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                protocolVersion: AgentDeclaration.protocolVersion)
        }
        wire.onEvent = { [weak self, weak wire] command, data in
            Task { @MainActor in
                if command == "agent.heartbeat" { self?.lastHeartbeat = ProcessInfo.processInfo.systemUptime }
                else if command == "agent.language", let language = try? JSONDecoder().decode(String.self, from: data) {
                    MotiscapeLocalization.shared.locale = Locale(identifier: language)
                    if let payload = try? JSONEncoder().encode(declaration()) { wire?.send("agent.declaration", payload: payload) }
                    #if WALLPAPER_AGENT
                    if self?.started == true { WallpaperAgentAdapter.languageDidChange() }
                    #endif
                }
            }
        }
        wire.onRequest = { [weak self] command, _, reply in
            Task { @MainActor in
                if command == "agent.exitWithoutRestore" {
                    #if STEAM_AGENT
                    do { try await self?.cleanup() }
                    catch { reply(.failure(error)); return }
                    #endif
                    // Sent only after the owner has shown the failed-restoration choice.
                    self?.stopping = true
                    self?.timer?.invalidate()
                    self?.terminationApproved = true
                    reply(.success(Data()))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NSApp.terminate(nil) }
                } else if command == "agent.shutdown" {
                    do {
                        try await self?.cleanup()
                        reply(.success(Data()))
                        // Allow the acknowledgement to reach the socket before terminating.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                            self?.terminationApproved = true
                            NSApp.terminate(nil)
                        }
                    } catch {
                        reply(.failure(error))
                    }
                } else { reply(.failure(AgentTransportError.message(L("插件尚未启动")))) }
            }
        }
        wire.start()
        Task { [self] in
            do {
                let declaration = declaration()
                _ = try await wire.request("agent.hello", payload: JSONEncoder().encode(AgentHello(token: token, session: session, declaration: declaration)))
                guard !configuredOnly, !stopping else { return }
                wire.configureHandlers {
                    let lifecycleRequest = wire.onRequest
                    let lifecycleEvent = wire.onEvent
                    #if WALLPAPER_AGENT
                    WallpaperAgentAdapter.install(on: wire)
                    #elseif STEAM_AGENT
                    SteamAgentAdapter.install(on: wire)
                    #else
                    MediaAgentAdapter.install(on: wire)
                    #endif
                    started = true
                    let moduleRequest = wire.onRequest
                    let moduleEvent = wire.onEvent
                    wire.onRequest = { [weak self] command, data, reply in
                        Task { @MainActor in
                            if command.hasPrefix("agent.") { lifecycleRequest?(command, data, reply) }
                            else if self?.stopping == false || command == "lockA.permissions" { moduleRequest?(command, data, reply) }
                            else { reply(.failure(AgentTransportError.message(L("插件正在退出")))) }
                        }
                    }
                    wire.onEvent = { [weak self] command, data in
                        Task { @MainActor in
                            if command.hasPrefix("agent.") { lifecycleEvent?(command, data) }
                            else if self?.stopping == false || command == "lockA.permissions" { moduleEvent?(command, data) }
                        }
                    }
                }
                wire.send("agent.ready")
            } catch { await stop() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if ProcessInfo.processInfo.systemUptime - self.lastHeartbeat > 18 { await self.stop() }
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.lastHeartbeat = ProcessInfo.processInfo.systemUptime }
        }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in await self?.stop() } }
            source.resume(); signalSources.append(source)
        }
    }

    private func cleanup() async throws {
        if let cleanupTask { try await cleanupTask.value; return }
        stopping = true
        bootstrapWaitTimer?.invalidate()
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        let task = Task<Void, Error> { @MainActor in
            if started {
                #if WALLPAPER_AGENT
                try await WallpaperAgentAdapter.shutdown()
                #elseif STEAM_AGENT
                try await SteamAgentAdapter.shutdown()
                #else
                await MediaAgentAdapter.shutdown()
                #endif
            }
        }
        cleanupTask = task
        do { try await task.value }
        catch {
            // Preserve the process and recovery journal. A later shutdown may retry restoration.
            cleanupTask = nil
            throw error
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationApproved else { return .terminateNow }
        if !terminationReplyPending {
            terminationReplyPending = true
            Task { @MainActor in
                do {
                    try await cleanup()
                    terminationApproved = true
                    sender.reply(toApplicationShouldTerminate: true)
                } catch {
                    terminationReplyPending = false
                    NSLog("Agent cleanup failed: %@", error.localizedDescription)
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
        }
        return .terminateLater
    }

    private func stop() async {
        do {
            try await cleanup()
            terminationApproved = true
            NSApp.terminate(nil)
        } catch {
            // A lost owner cannot offer recovery UI. Preserve the journal for the next session.
            NSLog("Agent cleanup failed after owner disconnected: %@", error.localizedDescription)
            terminationApproved = true
            NSApp.terminate(nil)
        }
    }
}
