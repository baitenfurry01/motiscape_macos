import Foundation

/// The renderer-facing interface. Media collection lives in the optional agent.
final class NowPlayingService {
    static let shared = NowPlayingService()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.BaiTenG.motiscape.now-playing.proxy", qos: .utility)
    private var enabled = false
    private var updateHandler: (([String: Any]) -> Void)?
    private var observers: [NSObjectProtocol] = []

    var onUpdate: (([String: Any]) -> Void)? {
        get { lock.withLock { updateHandler } }
        set { lock.withLock { updateHandler = newValue } }
    }

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .agentConnectionChanged, object: nil, queue: nil
        ) { [weak self] notification in
            guard notification.userInfo?["role"] as? AgentRole == .media else { return }
            Task { @MainActor [weak self] in self?.synchronizeConnection() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .agentEvent, object: nil, queue: nil
        ) { [weak self] notification in
            guard notification.userInfo?["role"] as? AgentRole == .media,
                  notification.userInfo?["command"] as? String == "media.update",
                  let data = notification.userInfo?["payload"] as? Data else { return }
            self?.receive(data)
        })
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
        Task { @MainActor [weak self] in self?.synchronizeConnection() }
    }

    @MainActor
    private func synchronizeConnection() {
        let enabled = lock.withLock { self.enabled }
        guard let connection = PluginManager.shared.connection(for: .media) else {
            if enabled { publishStopped() }
            return
        }
        guard let payload = try? JSONEncoder().encode(enabled) else { return }
        connection.send("media.setEnabled", payload: payload)
    }

    private func receive(_ data: Data) {
        queue.async { [weak self] in
            guard let self, lock.withLock({ self.enabled }),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            onUpdate?(payload)
        }
    }

    private func publishStopped() {
        queue.async { [weak self] in
            self?.onUpdate?([
                "state": 0, "title": "", "artist": "", "album": "", "albumArtist": "",
                "position": 0, "duration": 0, "artURL": "", "previousArtURL": ""
            ])
        }
    }
}
