import IOKit.ps

enum PowerSourceCapabilities {
    static var hasBuiltInBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return hasBuiltInBattery(in: descriptions)
    }

    static func hasBuiltInBattery(in descriptions: [[String: Any]]) -> Bool {
        // Detect the built-in battery, not the current supply: AC-powered laptops
        // still need this rule, while a desktop connected to a UPS does not.
        descriptions.contains { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
    }
}
