import Foundation

enum MotiscapeLockAnyValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: MotiscapeLockAnyValue])
    case array([MotiscapeLockAnyValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: MotiscapeLockAnyValue].self) { self = .object(value); return }
        self = .array(try container.decode([MotiscapeLockAnyValue].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues { $0.foundationValue }
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }
}

struct MotiscapeLockDisplayConfiguration: Codable, Equatable {
    let displayID: UInt32
    let wallpaperID: String
    let title: String
    let kind: String
    let renderDirectory: String
    let entryPath: String
    var previewPath: String?
    var desktopFallbackPath: String?
    let rawProperties: [String: MotiscapeLockAnyValue]
    let fps: Int
    let fillMode: String
    var position: WallpaperPosition? = nil
    let loadFromMemory: Bool?
    var renderedPreviewPath: String? = nil
    var displayKey: String? = nil
    var speed: Float? = nil
    var scriptStorage: [String: String]? = nil
    var runtimeRevision: UUID? = nil

    var playbackSpeed: Float {
        guard let speed, speed.isFinite, speed > 0 else { return 1 }
        return speed
    }

    var renderIdentity: String {
        var value = self
        value.previewPath = nil
        value.renderedPreviewPath = nil
        value.desktopFallbackPath = nil
        value.runtimeRevision = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(value)).map(MotiscapeLockBridge.digest) ?? ""
    }
}

struct MotiscapeLockConfiguration: Codable {
    let version: Int
    let enabled: Bool?
    let displays: [String: MotiscapeLockDisplayConfiguration]
}


struct MotiscapeLockRuntimeIdentity {
    static let current = Self()
    let path: String
    let fingerprint: String
    let version: String

    private init() {
        path = MotiscapeLockBridge.normalizedPath(Bundle.main.bundleURL)
        fingerprint = (try? MotiscapeLockBridge.fingerprint(at: Bundle.main.bundleURL)) ?? ""
        version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}

final class MotiscapeLockConfigurationStore {
    static let shared = MotiscapeLockConfigurationStore()
    private let lock = NSLock()
    private let containerURL: URL?
    private var stored: (configuration: MotiscapeLockConfiguration, data: Data)?

    init(containerURL: URL? = nil) {
        self.containerURL = containerURL
    }

    func load() throws -> (configuration: MotiscapeLockConfiguration, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        let container = try containerURL ?? MotiscapeLockBridge.containerURL()
        let data = try Data(contentsOf: container.appendingPathComponent(MotiscapeLockBridge.configurationName))
        if let stored, stored.data == data { return stored }
        let configuration = try JSONDecoder().decode(MotiscapeLockConfiguration.self, from: data)
        guard (1...2).contains(configuration.version), !configuration.displays.isEmpty,
              configuration.displays.values.allSatisfy({ $0.kind == "video" || $0.kind == "scene" }) else {
            throw MotiscapeLockBridge.failure("Unsupported lock screen configuration")
        }
        let result = (configuration, data)
        stored = result
        return result
    }

    var lastKnownConfiguration: MotiscapeLockConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return stored?.configuration
    }
}
