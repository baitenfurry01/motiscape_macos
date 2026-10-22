import Foundation

enum UIStoredValue {
    static func value<Value>(_ key: String, fallback: Value,
                             defaults: UserDefaults = .standard) -> Value {
        defaults.object(forKey: key) as? Value ?? fallback
    }

    static func rawValue<Value: RawRepresentable>(_ key: String, fallback: Value,
                                                 defaults: UserDefaults = .standard) -> Value {
        guard let raw = defaults.object(forKey: key) as? Value.RawValue,
              let value = Value(rawValue: raw) else { return fallback }
        return value
    }
}
