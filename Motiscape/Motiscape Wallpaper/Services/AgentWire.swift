import Foundation
import Network

enum AgentRole: String, Codable, CaseIterable {
    case wallpaper, media, steam
    var displayKey: String {
        switch self { case .wallpaper: return "屏保与锁屏"; case .media: return "歌曲信息"; case .steam: return "Steam 服务" }
    }
    var bundleIdentifier: String {
        switch self {
        case .wallpaper: return "com.BaiTenG.motiscape.WallpaperAgent"
        case .media: return "com.BaiTenG.motiscape.MediaAgent"
        case .steam: return "com.BaiTenG.motiscape.SteamAgent"
        }
    }
}

struct AgentDeclaration: Codable {
    static let protocolVersion = 2
    let role: AgentRole
    let bundleIdentifier: String
    let name: String
    let version: String
    let protocolVersion: Int

    func isCompatible(with expectedBundleIdentifier: String) -> Bool {
        protocolVersion == Self.protocolVersion
            && bundleIdentifier == expectedBundleIdentifier
            && bundleIdentifier == role.bundleIdentifier
    }
}

/// One-use launch metadata delivered through Launch Services document opening.
/// The token still has to pass the existing loopback handshake before any work.
struct AgentSessionBootstrap: Codable {
    static let formatVersion = 2
    static let fileExtension = "motiscape-agent-session"
    let version: Int
    let bundleIdentifier: String
    let port: UInt16
    let token: String
    let session: UUID
    let language: String
    let configureOnly: Bool
    let expiresAt: Date

    func isValid(for expectedBundleIdentifier: String, at now: Date = Date()) -> Bool {
        let remaining = expiresAt.timeIntervalSince(now)
        guard version == Self.formatVersion, bundleIdentifier == expectedBundleIdentifier,
              port != 0, token.count == 72, !language.isEmpty, language.utf8.count <= 128,
              remaining > 0, remaining <= 120 else { return false }
        let middle = token.index(token.startIndex, offsetBy: 36)
        return UUID(uuidString: String(token[..<middle])) != nil &&
            UUID(uuidString: String(token[middle...])) != nil
    }
}

struct AgentHello: Codable {
    let token: String
    let session: UUID
    let declaration: AgentDeclaration
}

enum AgentTransportError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

private struct AgentPacket: Codable {
    var id: UUID?
    var reply: Bool = false
    var command: String
    var payload: Data
    var error: String?
}

/// Responses are resolved on a private queue, including when a legacy caller waits synchronously.
final class AgentConnection: @unchecked Sendable {
    typealias Completion = (Result<Data, Error>) -> Void
    private let handlerLock = NSRecursiveLock()
    private var requestHandler: ((String, Data, @escaping Completion) -> Void)?
    private var eventHandler: ((String, Data) -> Void)?
    private var closeHandler: (() -> Void)?
    var onRequest: ((String, Data, @escaping Completion) -> Void)? {
        get { handlerLock.withLock { requestHandler } }
        set { handlerLock.withLock { requestHandler = newValue } }
    }
    var onEvent: ((String, Data) -> Void)? {
        get { handlerLock.withLock { eventHandler } }
        set { handlerLock.withLock { eventHandler = newValue } }
    }
    var onClose: (() -> Void)? {
        get { handlerLock.withLock { closeHandler } }
        set { handlerLock.withLock { closeHandler = newValue } }
    }
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "motiscape.agent.connection.\(UUID())")
    private var buffer = Data()
    private var pending: [UUID: Completion] = [:]
    private var closed = false
    private static let maximumPacketSize = 32 * 1024 * 1024

    init(_ connection: NWConnection) { self.connection = connection }

    /// Publish module and lifecycle handlers together; incoming callbacks cannot see a partial set.
    func configureHandlers(_ configure: () -> Void) { handlerLock.withLock(configure) }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error): self.finish(error)
            case .cancelled: self.finish(AgentTransportError.message(L("插件连接已关闭")))
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func close() { queue.async { self.connection.cancel(); self.finish(AgentTransportError.message(L("插件连接已关闭"))) } }

    func request(_ command: String, payload: Data = Data(), timeout: TimeInterval = 15) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            requestCallback(command, payload: payload, timeout: timeout) { continuation.resume(with: $0) }
        }
    }

    func requestSync(_ command: String, payload: Data = Data(), timeout: TimeInterval = 15) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let box = AgentReplyBox()
        requestCallback(command, payload: payload, timeout: timeout) { result in box.result = result; semaphore.signal() }
        semaphore.wait()
        return try box.result!.get()
    }

    private func requestCallback(_ command: String, payload: Data, timeout: TimeInterval, completion: @escaping Completion) {
        queue.async {
            guard !self.closed else { completion(.failure(AgentTransportError.message(L("插件未连接")))); return }
            let id = UUID()
            self.pending[id] = completion
            self.write(AgentPacket(id: id, command: command, payload: payload))
            self.queue.asyncAfter(deadline: .now() + timeout) {
                self.pending.removeValue(forKey: id)?(.failure(AgentTransportError.message(L("插件响应超时：%@", command))))
            }
        }
    }

    func send(_ command: String, payload: Data = Data()) {
        queue.async { self.write(AgentPacket(command: command, payload: payload)) }
    }

    private func write(_ packet: AgentPacket) {
        guard !closed, var data = try? JSONEncoder().encode(packet), data.count < Self.maximumPacketSize else { return }
        data.append(0x0a)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error) }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let newline = self.buffer.firstIndex(of: 0x0a) {
                let frame = self.buffer[..<newline]
                guard frame.count < Self.maximumPacketSize, let packet = try? JSONDecoder().decode(AgentPacket.self, from: frame) else {
                    self.connection.cancel(); self.finish(AgentTransportError.message(L("插件消息无效"))); return
                }
                self.buffer.removeSubrange(...newline)
                self.accept(packet)
            }
            if self.buffer.count >= Self.maximumPacketSize {
                self.connection.cancel(); self.finish(AgentTransportError.message(L("插件消息过大"))); return
            }
            if done || error != nil { self.finish(error ?? AgentTransportError.message(L("插件连接已结束"))); return }
            self.receive()
        }
    }

    private func accept(_ packet: AgentPacket) {
        if packet.reply, let id = packet.id {
            let result: Result<Data, Error> = packet.error.map { .failure(AgentTransportError.message($0)) } ?? .success(packet.payload)
            pending.removeValue(forKey: id)?(result)
        } else if let id = packet.id {
            guard let handler = onRequest else {
                write(AgentPacket(id: id, reply: true, command: packet.command, payload: Data(), error: L("不支持此请求"))); return
            }
            handler(packet.command, packet.payload) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .success(let payload): self.write(AgentPacket(id: id, reply: true, command: packet.command, payload: payload))
                    case .failure(let error): self.write(AgentPacket(id: id, reply: true, command: packet.command, payload: Data(), error: error.localizedDescription))
                    }
                }
            }
        } else { onEvent?(packet.command, packet.payload) }
    }

    private func finish(_ error: Error) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let callbacks = Array(pending.values); pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
        onClose?()
    }
}

private final class AgentReplyBox: @unchecked Sendable { var result: Result<Data, Error>? }

extension Notification.Name {
    static let agentConnectionChanged = Notification.Name("motiscape.agentConnectionChanged")
    static let agentEvent = Notification.Name("motiscape.agentEvent")
}
