import Foundation

struct DynamicLockScreenDisplayConfiguration: Codable {
    let displayID: UInt32
    let wallpaperID: String
    let title: String
    let kind: String
    let renderDirectory: String
    let entryPath: String
    let previewPath: String?
    var desktopFallbackPath: String?
    var systemFallbackPath: String?
    var rawProperties: [String: AnyCodableValue]
    let fps: Int
    var fillMode: String
    var position: WallpaperPosition? = nil
    var loadFromMemory: Bool?
    var renderedPreviewPath: String? = nil
    var displayKey: String? = nil
    var speed: Float? = nil
    var scriptStorage: [String: String]? = nil
    var runtimeRevision: UUID? = nil
}

struct DynamicLockScreenConfiguration: Codable {
    let version: Int
    var enabled: Bool?
    var displays: [String: DynamicLockScreenDisplayConfiguration]
    var configuredAt: TimeInterval? = nil
    var configurationSession: String? = nil
}

enum AnyCodableValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .null: return NSNull()
        }
    }

    init(_ value: Any) {
        switch value {
        case let value as String: self = .string(value)
        case let value as NSString: self = .string(value as String)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber: self = .number(value.doubleValue)
        case let value as [String: Any]: self = .object(value.mapValues(AnyCodableValue.init))
        case let value as [Any]: self = .array(value.map(AnyCodableValue.init))
        default: self = .null
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: AnyCodableValue].self) { self = .object(value); return }
        self = .array(try container.decode([AnyCodableValue].self))
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
}


struct WallpaperRuntimeState: Codable, Equatable {
    var volume: Float = 1.0
    var speed: Float = 1.0
    var muted: Bool = false
    var fillMode: FillMode = .cover
    var position: WallpaperPosition = .center
    var propertyOverrides: [String: WEPropertyValue] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        speed = try values.decodeIfPresent(Float.self, forKey: .speed) ?? 1
        muted = try values.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        fillMode = try values.decodeIfPresent(FillMode.self, forKey: .fillMode) ?? .cover
        position = try values.decodeIfPresent(WallpaperPosition.self, forKey: .position) ?? .center
        propertyOverrides = try values.decodeIfPresent([String: WEPropertyValue].self,
                                                        forKey: .propertyOverrides) ?? [:]
    }
}

struct DisplayWallpaperState: Codable, Equatable {
    var wallpaper: WEWallpaper
    var runtime: WallpaperRuntimeState
}


enum FillMode: String, CaseIterable, Codable, Identifiable {
    case cover, contain, stretch
    var id: Self { self }
    var displayName: String {
        switch self {
        case .cover: return L("填充")
        case .contain: return L("适应")
        case .stretch: return L("拉伸")
        }
    }
}

/// Final playback state handed to a renderer. The renderer never learns *why*
/// it is in this state — that judgement belongs to the app, which is the only
/// process with a global view of window layering, displays and power sources.
enum MotiscapePowerState: String, Codable, Equatable {
    /// Render normally at the configured frame rate.
    case run
    /// Keep rendering, but at the reduced frame rate carried alongside.
    case throttle
    /// Stop producing frames entirely.
    case pause
}


struct RenderOptions: Codable, Equatable {
    var developerModeEnabled = false
    var fps: Int = 30
    var volume: Float = 1.0
    var muted: Bool = false
    var speed: Float = 1.0
    var fillMode: FillMode = .cover
    var position: WallpaperPosition = .center
    var enableSpectrum: Bool = true
    var renderScale: Double = 1.0
    var enableMetalFX: Bool = false
    var msaaSamples: Int = 1
    var loadFromMemory: Bool = false
    var enableHDRVideo: Bool = false
    var userProperties: [String: WEProjectProperty] = [:]
    var scriptStorage: [String: String]? = nil
    var powerState: MotiscapePowerState = .run
    var powerFps: Int?
    /// Identifies the UI assignment that owns these playback options. A newer
    /// proposal can reuse a process, so ownership is intentionally mutable on
    /// `RendererProcess` even though the process generation itself is fixed.
    var assignmentID: UUID?
}


struct WallpaperPathRemapper {
    private let mappings: [(old: String, new: String)]

    init(_ paths: [String: String]) {
        mappings = paths.map {
            ($0.key.standardizedPath, $0.value.standardizedPath)
        }.sorted { $0.old.count > $1.old.count }
    }

    func path(_ value: String) -> String {
        let standardized = value.standardizedPath
        for mapping in mappings {
            if standardized == mapping.old { return mapping.new }
            if standardized.hasPrefix(mapping.old + "/") {
                return mapping.new + standardized.dropFirst(mapping.old.count)
            }
        }
        return value
    }

    func url(_ value: URL) -> URL {
        guard value.isFileURL else { return value }
        let remapped = path(value.path)
        return remapped == value.path ? value : URL(fileURLWithPath: remapped)
    }
}

private extension String {
    var standardizedPath: String {
        URL(fileURLWithPath: self).standardizedFileURL.path
    }
}

enum MotiscapeScreenSaverError: LocalizedError {
    case noWallpaper
    case unsupportedWallpaper
    case bundledSaverMissing
    case invalidConfiguration
    case invalidBundle
    case screenSaverHostDidNotTerminate
    case installationVerificationFailed

    var errorDescription: String? {
        switch self {
        case .noWallpaper: return L("请先播放一张壁纸")
        case .unsupportedWallpaper: return L("当前壁纸不能用作屏保")
        case .bundledSaverMissing: return L("App 内没有找到 Motiscape 屏保组件")
        case .invalidConfiguration: return L("无法生成屏保配置")
        case .invalidBundle: return L("Motiscape 屏保组件不完整")
        case .screenSaverHostDidNotTerminate: return L("无法结束旧的系统屏保进程，请稍后重试")
        case .installationVerificationFailed: return L("屏保安装校验失败")
        }
    }
}


enum ScreenSaverDynamicLockScreenError: LocalizedError {
    case unavailable
    case notEnabled
    case noWallpaper
    case unsupportedWallpaper
    case storeUnavailable
    case invalidStore
    case conflict
    case restoreConflict

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("屏保动态锁屏需要 macOS 14.2 或更高版本")
        case .notEnabled: return L("请先开启屏保动态锁屏并完成确认")
        case .noWallpaper: return L("请先播放一张壁纸")
        case .unsupportedWallpaper: return L("当前壁纸不能用作动态锁屏")
        case .storeUnavailable: return L("无法访问系统墙纸配置")
        case .invalidStore: return L("系统墙纸配置格式不受支持")
        case .conflict: return L("系统墙纸配置已被其他程序修改，请稍后重试")
        case .restoreConflict: return L("系统墙纸配置已被用户修改，Motiscape 未覆盖当前设置")
        }
    }
}


enum DynamicLockScreenError: LocalizedError {
    case notEnabled
    case noWallpaper
    case unsupportedWallpaper
    case appGroupUnavailable
    case fullDiskAccessRequired

    var errorDescription: String? {
        switch self {
        case .notEnabled: return L("请先开启动态锁屏并完成确认")
        case .noWallpaper: return L("请先播放一张壁纸")
        case .unsupportedWallpaper: return L("当前壁纸不能用作动态锁屏")
        case .appGroupUnavailable: return L("动态锁屏共享容器不可用")
        case .fullDiskAccessRequired: return L("动态锁屏需要完全磁盘访问权限")
        }
    }
}
