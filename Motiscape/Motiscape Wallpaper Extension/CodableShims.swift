import Foundation

struct MotiscapeSettingsViewModels: Codable {
    let desktop: MotiscapeSettingsViewModel?
    let screenSaver: MotiscapeSettingsViewModel?
}

struct MotiscapeSettingsViewModel: Codable {
    let groups: [MotiscapeSettingsGroup]
    let refreshPolicy: MotiscapeRefreshPolicy
    let isModificationDisabled: Bool
}

struct MotiscapeSettingsGroup: Codable {
    let id: MotiscapeGroupID
    let items: [MotiscapeSettingsItem]
    let localizedName: String
    let disposability: MotiscapeDisposability
    let sortOrder: Int
    let sortID: MotiscapeGroupSortID?
    let allChoiceID: MotiscapeChoiceID?
    let shouldHideItemLabels: Bool?
    let contextMenu: MotiscapeContextMenu?
    let thumbnail: Data?
}

struct MotiscapeSettingsItem: Codable {
    let id: MotiscapeChoiceID
    let localizedName: String
    let thumbnail: MotiscapeThumbnail
    let choice: MotiscapeChoiceDescriptor
    let contentBadge: MotiscapeContentBadge
    let showInTopLevel: Bool
    let sortOrder: Int
    let disposability: MotiscapeDisposability
}

struct MotiscapeChoiceID: Codable {
    let id: String
    let descriptor: MotiscapeChoiceIDDescriptor
}

struct MotiscapeChoiceIDDescriptor: Codable {
    let provider: MotiscapeChoiceProviderID
    let identifier: String
    let files: [URL]
    let configuration: Data
}

struct MotiscapeChoiceDescriptor: Codable {
    let id: MotiscapeChoiceID
    let provider: MotiscapeChoiceProviderID
    let identifier: String
    let name: String?
    let localizedDescription: String
    let thumbnail: MotiscapeThumbnail
    let isDownloaded: Bool
    let options: [MotiscapeWallpaperOption]
}

struct MotiscapeChoiceProviderID: Codable {
    let rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct MotiscapeWallpaperOption: Codable {}
struct MotiscapeGroupID: Codable { let id: String }
struct MotiscapeGroupSortID: Codable { let id: String }

enum MotiscapeDisposability: Codable {
    case none
    case removable
    case purgeable

    private enum Keys: String, CodingKey { case none, removable, purgeable }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .none: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .none)
        case .removable: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .removable)
        case .purgeable: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .purgeable)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.removable) { self = .removable }
        else if container.contains(.purgeable) { self = .purgeable }
        else { self = .none }
    }
}

enum MotiscapeContentBadge: Codable {
    case none
    case video
    case dynamic

    private enum Keys: String, CodingKey { case none, video, dynamic }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .none: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .none)
        case .video: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .video)
        case .dynamic: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .dynamic)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.video) { self = .video }
        else if container.contains(.dynamic) { self = .dynamic }
        else { self = .none }
    }
}

enum MotiscapeRefreshPolicy: Codable {
    case `default`, discretionary

    private enum Keys: String, CodingKey { case `default`, discretionary }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .default: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .default)
        case .discretionary: _ = container.nestedContainer(keyedBy: EmptyKeys.self, forKey: .discretionary)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.discretionary) { self = .discretionary }
        else if container.contains(.default) { self = .default }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                   debugDescription: "Unsupported wallpaper settings refresh policy"))
        }
    }
}

enum MotiscapeThumbnail: Codable {
    case image(URL)
    case customButton(MotiscapeCustomButton)

    private enum Keys: String, CodingKey { case image, customButton }
    private enum ImageKeys: String, CodingKey { case url }
    private enum ButtonKeys: String, CodingKey { case value }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .image(let url):
            var nested = container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
            try nested.encode(url, forKey: .url)
        case .customButton(let button):
            var nested = container.nestedContainer(keyedBy: ButtonKeys.self, forKey: .customButton)
            try nested.encode(button, forKey: .value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if container.contains(.image) {
            let nested = try container.nestedContainer(keyedBy: ImageKeys.self, forKey: .image)
            self = .image(try nested.decode(URL.self, forKey: .url))
        } else {
            self = .image(URL(fileURLWithPath: "/"))
        }
    }
}

enum MotiscapeCustomButton: Codable { case addPhotoButton }
struct MotiscapeContextMenu: Codable { let items: [MotiscapeContextMenuItem] }
struct MotiscapeContextMenuItem: Codable { let identifier: String; let name: String }
enum EmptyKeys: String, CodingKey { case value }

@objc(MotiscapeShimViewModelsXPC)
final class MotiscapeShimViewModelsXPC: NSObject, NSSecureCoding {
    static let supportsSecureCoding = true
    let value: MotiscapeSettingsViewModels

    init(value: MotiscapeSettingsViewModels) {
        self.value = value
        super.init()
    }

    required init?(coder: NSCoder) { return nil }

    func encode(with coder: NSCoder) {
        guard let archiver = coder as? NSKeyedArchiver else { return }
        try? archiver.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
    }
}

func motiscapeSettingsViewModelsXPC(_ value: MotiscapeSettingsViewModels) -> AnyObject? {
    guard let data = try? NSKeyedArchiver.archivedData(
        withRootObject: MotiscapeShimViewModelsXPC(value: value), requiringSecureCoding: false),
          let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data),
          let realClass = objc_getClass("WallpaperSettingsViewModelsXPC") as? AnyClass else { return nil }
    unarchiver.requiresSecureCoding = false
    unarchiver.setClass(realClass, forClassName: "MotiscapeShimViewModelsXPC")
    let result = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
    unarchiver.finishDecoding()
    return result as AnyObject?
}
