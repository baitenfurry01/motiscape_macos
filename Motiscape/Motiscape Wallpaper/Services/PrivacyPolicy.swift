import Foundation

enum PrivacyPolicy {
    // Increment when a changed policy requires renewed acceptance.
    static let currentVersion = "2026-10-15"
    static let acceptedVersionKey = "PrivacyPolicyAcceptedVersion"

    static func hasAcceptedCurrentVersion(defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: acceptedVersionKey) == currentVersion
    }

    static func acceptCurrentVersion(defaults: UserDefaults = .standard) {
        defaults.set(currentVersion, forKey: acceptedVersionKey)
    }

    static func text(language: String, bundle: Bundle = .main) -> String? {
        let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
        let resource = normalized.hasPrefix("zh-hant") || normalized.hasPrefix("zh-tw") || normalized.hasPrefix("zh-hk")
            ? "zh-Hant" : (normalized.hasPrefix("zh") ? "zh-Hans" : "en")
        guard let directory = bundle.url(forResource: resource, withExtension: "lproj"),
              let text = try? String(contentsOf: directory.appendingPathComponent("PrivacyPolicy.md"), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
