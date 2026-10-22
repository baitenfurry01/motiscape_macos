import Foundation

/// External agents use the language selected in their owning main-app session.
/// They have separate bundles and must not rely on the system preferred language.
final class MotiscapeLocalization {
    static let shared = MotiscapeLocalization()
    static let didChangeNotification = Notification.Name("MotiscapeLocalizationDidChange")
    private let lock = NSLock()
    private var identifier = Locale.preferredLanguages.first ?? "en"

    var locale: Locale {
        get { lock.withLock { Locale(identifier: identifier) } }
        set { lock.withLock { identifier = newValue.identifier } }
    }

    func string(_ key: String, arguments: [CVarArg] = []) -> String {
        let locale = self.locale
        let language = Self.resourceLanguage(for: locale.identifier)
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        let format = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    /// Existing status fields are stored as text by the original business code.
    /// Translate known messages again when the owner changes language mid-session.
    func relocalized(_ message: String?) -> String? {
        guard let message, let key = Self.messageKeys[message] else { return message }
        return string(key)
    }

    private static let messageKeys: [String: String] = {
        var result: [String: String] = [:]
        for language in ["en", "zh-Hans", "zh-Hant"] {
            guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")),
                  let strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] else { continue }
            for (key, value) in strings where !key.contains("%") {
                result[key] = key
                result[value] = key
            }
        }
        return result
    }()

    static func resourceLanguage(for identifier: String) -> String {
        let lower = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower.hasPrefix("zh-hk") {
            return "zh-Hant"
        }
        return lower.hasPrefix("zh") ? "zh-Hans" : "en"
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    MotiscapeLocalization.shared.string(key, arguments: arguments)
}
