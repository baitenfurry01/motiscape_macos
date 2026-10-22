import Foundation

/// Shared, language-independent destinations configured in the app resources.
enum PluginLinks {
    private static let addresses: [String: String] = {
        guard let file = Bundle.main.url(forResource: "PluginLinks", withExtension: "plist"),
              let data = try? Data(contentsOf: file),
              let links = try? PropertyListDecoder().decode([String: String].self, from: data) else { return [:] }
        return links
    }()

    static var thirdPartyPluginLibraryURL: URL? { url(for: "thirdPartyPluginLibraryURL") }
    static var steamFeaturesInformationURL: URL? { url(for: "steamFeaturesInformationURL") }

    private static func url(for key: String) -> URL? {
        addresses[key].flatMap { URL(string: $0) }
    }
}
