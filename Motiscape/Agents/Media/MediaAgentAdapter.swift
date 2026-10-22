import Foundation

/// Installed only for a normal session. Discovery alone never starts collection.
enum MediaAgentAdapter {
    static func install(on connection: AgentConnection) {
        NowPlayingService.shared.onUpdate = { [weak connection] payload in
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
            connection?.send("media.update", payload: data)
        }
        connection.onRequest = { command, data, reply in
            guard command == "media.setEnabled" else {
                reply(.failure(NSError(domain: "motiscape.MediaAgent", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: L("Unsupported media command: %@", command)])))
                return
            }
            do {
                let enabled = try JSONDecoder().decode(Bool.self, from: data)
                NowPlayingService.shared.setEnabled(enabled)
                reply(.success(Data()))
            } catch {
                reply(.failure(error))
            }
        }
        connection.onEvent = { command, data in
            guard command == "media.setEnabled",
                  let enabled = try? JSONDecoder().decode(Bool.self, from: data) else { return }
            NowPlayingService.shared.setEnabled(enabled)
        }
    }

    static func shutdown() async {
        await NowPlayingService.shared.stop()
        NowPlayingService.shared.onUpdate = nil
    }
}
