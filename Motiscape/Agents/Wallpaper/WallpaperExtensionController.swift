import AppKit
import Darwin
import Foundation

enum WallpaperExtensionController {
    enum SelectionState: String {
        case selected, notSelected, unknown
    }

    struct Registration {
        enum Outcome {
            case awaitingSystemSettings
            case acknowledged(MotiscapeLockReport)
            case failed(String)
        }

        let fingerprint: String
        let probe: MotiscapeLockProbe
        let selection: SelectionState
        let outcome: Outcome

        var report: MotiscapeLockReport? {
            if case .acknowledged(let report) = outcome { return report }
            return nil
        }

        var errorMessage: String? {
            if case .failed(let message) = outcome { return message }
            return nil
        }
    }

    struct System {
        var run: (String, [String]) -> (success: Bool, output: String)
        var restart: (String, () -> Bool) throws -> Void
        var selection: (String) -> SelectionState
        var reports: (MotiscapeLockProbe, URL, String, URL) -> [MotiscapeLockReport]
        var invalidateSettingsCache: (String, WallpaperSettingsCache.Policy, () -> Bool) throws -> Bool
        var notify: () -> Void
        var now: () -> TimeInterval
        var sleep: (TimeInterval) -> Void

        static var live: Self {
            Self(run: { runTool($0, arguments: $1) }, restart: restartServices,
                 selection: selectionState, reports: liveReports,
                 invalidateSettingsCache: { try WallpaperSettingsCache.invalidate(identifier: $0, policy: $1, isCurrent: $2) },
                 notify: { MotiscapeLockBridge.post(MotiscapeLockBridge.probeNotification) },
                 now: { ProcessInfo.processInfo.systemUptime }, sleep: Thread.sleep(forTimeInterval:))
        }
    }

    static func register(appURL: URL, extensionURL: URL, container: URL,
                         previousFingerprint: String?, forceRestart: Bool,
                         forceRegistration: Bool = false, requireAcknowledgement: Bool = false,
                         system: System = .live,
                         isCurrent: () -> Bool) throws -> Registration {
        try check(isCurrent)
        let fingerprint = try MotiscapeLockBridge.fingerprint(at: extensionURL)
        guard let identifier = Bundle(url: extensionURL)?.bundleIdentifier else {
            throw MotiscapeLockBridge.failure("Wallpaper extension identifier is missing")
        }
        let targetPath = MotiscapeLockBridge.normalizedPath(extensionURL)
        let versionChanged = previousFingerprint != fingerprint
        let registrationNeeded = try withServiceLock(isCurrent: isCurrent) {
            let previous = try records(identifier: identifier, all: true, run: system.run)
            let needed = forceRegistration || versionChanged || previous.contains { $0.path != targetPath }
                || !previous.contains(where: { $0.path == targetPath && $0.elected })
            if needed {
                try updateRegistration(appURL: appURL, extensionURL: extensionURL, identifier: identifier,
                                       previous: previous, system: system, isCurrent: isCurrent)
            }
            return needed
        }
        try check(isCurrent)
        let data = try Data(contentsOf: container.appendingPathComponent(MotiscapeLockBridge.configurationName))
        let probe = MotiscapeLockProbe(configurationData: data)
        try MotiscapeLockBridge.writeProbe(probe, in: container)
        var selection = system.selection(identifier)
        var needsAcknowledgement = requireAcknowledgement || selection != .notSelected
        var restarted = false
        var recovered = forceRegistration && forceRestart
        var lastReportSummary = "no matching extension reports"
        do {
            if forceRestart || registrationNeeded {
                try withServiceLock(isCurrent: isCurrent) {
                    _ = try system.invalidateSettingsCache(identifier, .all, isCurrent)
                    try check(isCurrent)
                    try system.restart(identifier, isCurrent)
                }
                restarted = true
            }
            for recovery in 0..<2 {
                try check(isCurrent)
                system.notify()
                let acknowledgementTimeout: TimeInterval = restarted ? 75 : 8
                var deadline = system.now() + (needsAcknowledgement ? acknowledgementTimeout : 1)
                var reportedError: String?
                while system.now() < deadline {
                    try check(isCurrent)
                    selection = system.selection(identifier)
                    if !needsAcknowledgement, selection != .notSelected {
                        needsAcknowledgement = true
                        deadline = system.now() + acknowledgementTimeout
                    }
                    let configurationData = try Data(contentsOf: container.appendingPathComponent(MotiscapeLockBridge.configurationName))
                    let digest = MotiscapeLockBridge.digest(configurationData)
                    let reports = system.reports(probe, extensionURL, fingerprint, container).filter {
                        $0.probeID == probe.id && $0.extensionPath == targetPath && $0.fingerprint == fingerprint
                    }
                    if !reports.isEmpty {
                        lastReportSummary = reports.map {
                            "pid=\($0.processID) build=\($0.version) settingsReady=\($0.settingsReady) digest=\($0.configurationDigest ?? "nil") error=\($0.error ?? "nil")"
                        }.joined(separator: "; ")
                    }
                    let health = connectionHealth(reports: reports, configurationDigest: digest)
                    if let report = health.report {
                        NSLog("[MotiscapeLock] settings acknowledged: %@ build %@ pid %d selection %@",
                              report.extensionPath, report.version, report.processID, selection.rawValue)
                        return Registration(fingerprint: fingerprint, probe: probe, selection: selection,
                                            outcome: .acknowledged(report))
                    }
                    if let error = health.errorMessage { reportedError = error }
                    system.sleep(0.1)
                }
                try check(isCurrent)
                if let reportedError {
                    return Registration(fingerprint: fingerprint, probe: probe, selection: selection,
                                        outcome: .failed(reportedError))
                }
                if !needsAcknowledgement {
                    if recovery == 0, !recovered {
                        let refreshed = try withServiceLock(isCurrent: isCurrent) {
                            guard try system.invalidateSettingsCache(identifier, .emptyDesktop, isCurrent) else { return false }
                            try check(isCurrent)
                            try system.restart(identifier, isCurrent)
                            return true
                        }
                        if refreshed {
                            restarted = true
                            recovered = true
                            continue
                        }
                    }
                    NSLog("[MotiscapeLock] registration recorded; awaiting System Wallpaper Settings: %@ probe %@",
                          targetPath, probe.id.uuidString)
                    return Registration(fingerprint: fingerprint, probe: probe, selection: selection,
                                        outcome: .awaitingSystemSettings)
                }
                guard recovery == 0, !recovered else { break }
                try check(isCurrent)
                NSLog("[MotiscapeLock] settings acknowledgement timed out; repairing registration: %@ selection %@; %@",
                      targetPath, selection.rawValue, lastReportSummary)
                try withServiceLock(isCurrent: isCurrent) {
                    let current = try records(identifier: identifier, all: true, run: system.run)
                    try updateRegistration(appURL: appURL, extensionURL: extensionURL, identifier: identifier,
                                           previous: current, system: system, isCurrent: isCurrent)
                    try check(isCurrent)
                    _ = try system.invalidateSettingsCache(identifier, .all, isCurrent)
                    try check(isCurrent)
                    try system.restart(identifier, isCurrent)
                }
                restarted = true
                recovered = true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return Registration(fingerprint: fingerprint, probe: probe, selection: selection,
                                outcome: .failed(error.localizedDescription))
        }
        return Registration(fingerprint: fingerprint, probe: probe, selection: selection,
                            outcome: .failed("Wallpaper settings were not acknowledged after recovery: \(targetPath); selection=\(selection.rawValue); \(lastReportSummary)"))
    }

    static func connectionHealth(reports: [MotiscapeLockReport], configurationDigest: String?)
        -> (report: MotiscapeLockReport?, errorMessage: String?) {
        let current = reports.filter { $0.configurationDigest == configurationDigest || $0.configurationDigest == nil }
        if let error = current.compactMap(\.error).first { return (nil, error) }
        guard let configurationDigest else { return (nil, nil) }
        return (current.filter { $0.settingsReady && $0.configurationDigest == configurationDigest }
            .max(by: { $0.readyDisplayIDs.count < $1.readyDisplayIDs.count }), nil)
    }

    private static func updateRegistration(appURL: URL, extensionURL: URL, identifier: String,
                                           previous: [WallpaperExtensionRecord], system: System,
                                           isCurrent: () -> Bool) throws {
        let targetPath = MotiscapeLockBridge.normalizedPath(extensionURL)
        for record in previous where record.path != targetPath {
            try check(isCurrent)
            NSLog("[MotiscapeLock] removing duplicate registration: %@", record.path)
            try runRequired("/usr/bin/pluginkit", ["-r", record.path], run: system.run)
        }
        try check(isCurrent)
        try runRequired("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        ["-f", appURL.path], run: system.run)
        for attempt in 0..<3 {
            if attempt > 0 { system.sleep(0.3) }
            try check(isCurrent)
            try runRequired("/usr/bin/pluginkit", ["-a", extensionURL.path], run: system.run)
            try check(isCurrent)
            try runRequired("/usr/bin/pluginkit", ["-e", "use", "-i", identifier], run: system.run)
            try check(isCurrent)
            let current = try records(identifier: identifier, all: false, run: system.run)
            if current.count == 1, current[0].path == targetPath, current[0].elected {
                NSLog("[MotiscapeLock] registration verified: %@", targetPath)
                return
            }
        }
        throw MotiscapeLockBridge.failure("The system selected a different copy of the wallpaper extension")
    }

    static func liveReports(probe: MotiscapeLockProbe, extensionURL: URL,
                            fingerprint: String, container: URL) -> [MotiscapeLockReport] {
        let path = MotiscapeLockBridge.normalizedPath(extensionURL)
        return MotiscapeLockBridge.readReports(in: container).filter {
            $0.probeID == probe.id && $0.extensionPath == path && $0.fingerprint == fingerprint
                && $0.processID > 0 && (Darwin.kill($0.processID, 0) == 0 || errno == EPERM)
        }
    }

    static func records(identifier: String, all: Bool,
                        run: (String, [String]) -> (success: Bool, output: String) = { runTool($0, arguments: $1) }) throws -> [WallpaperExtensionRecord] {
        let result = run("/usr/bin/pluginkit", [all ? "-mADv" : "-mv", "-i", identifier])
        guard result.success else { throw MotiscapeLockBridge.failure(result.output) }
        return WallpaperExtensionRecord.parse(result.output, identifier: identifier)
    }

    static func runTool(_ executable: String, arguments: [String], timeout: TimeInterval = 10)
        -> (success: Bool, output: String) {
        let process = Process()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("motiscape-extension-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        do {
            try Data().write(to: outputURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            let completion = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { _ in completion.signal() }
            try process.run()
            let timedOut = completion.wait(timeout: .now() + timeout) == .timedOut
            if timedOut {
                process.terminate()
                if completion.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = completion.wait(timeout: .now() + 1)
                }
            }
            let output = String(data: try Data(contentsOf: outputURL), encoding: .utf8) ?? ""
            if timedOut { return (false, "\(executable) timed out\n\(output)") }
            return (!process.isRunning && process.terminationStatus == 0, output)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private static func runRequired(_ executable: String, _ arguments: [String],
                                    run: (String, [String]) -> (success: Bool, output: String)) throws {
        let result = run(executable, arguments)
        guard result.success else {
            throw MotiscapeLockBridge.failure("\(URL(fileURLWithPath: executable).lastPathComponent): \(result.output)")
        }
    }

    private static func check(_ isCurrent: () -> Bool) throws {
        if !isCurrent() { throw CancellationError() }
    }

    private static func withServiceLock<T>(isCurrent: () -> Bool, _ work: () throws -> T) throws -> T {
        WallpaperServiceCoordinator.lock.lock()
        defer { WallpaperServiceCoordinator.lock.unlock() }
        try check(isCurrent)
        return try work()
    }

    private static func restartServices(identifier: String, isCurrent: () -> Bool) throws {
        try check(isCurrent)
        let agentID = "com.apple.wallpaper.agent"
        let agents = NSRunningApplication.runningApplications(withBundleIdentifier: agentID)
        let extensions = WallpaperExtensionProcess.running(identifier: identifier)
        guard !agents.isEmpty || !extensions.isEmpty else { return }
        extensions.forEach { $0.terminate() }
        agents.forEach { _ = $0.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline,
              agents.contains(where: { !hasExited($0) }) || extensions.contains(where: \.isRunning) {
            try check(isCurrent)
            Thread.sleep(forTimeInterval: 0.05)
        }
        extensions.filter(\.isRunning).forEach { $0.terminate(force: true) }
        for application in agents where !hasExited(application) {
            if !application.forceTerminate() { _ = Darwin.kill(application.processIdentifier, SIGKILL) }
        }
        let recoveryDeadline = ProcessInfo.processInfo.systemUptime + 5
        let oldAgentIDs = Set(agents.map(\.processIdentifier))
        while ProcessInfo.processInfo.systemUptime < recoveryDeadline {
            try check(isCurrent)
            let relaunched = NSRunningApplication.runningApplications(withBundleIdentifier: agentID)
                .contains { !oldAgentIDs.contains($0.processIdentifier) && !hasExited($0) }
            if agents.allSatisfy(hasExited), !extensions.contains(where: \.isRunning),
               agents.isEmpty || relaunched { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw MotiscapeLockBridge.failure("Wallpaper services did not restart successfully")
    }

    private static func hasExited(_ application: NSRunningApplication) -> Bool {
        application.isTerminated || (Darwin.kill(application.processIdentifier, 0) != 0 && errno == ESRCH)
    }

    static func selectionState(identifier: String) -> SelectionState {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        return selectionState(identifier: identifier, storeURL: url)
    }

    static func selectionState(identifier: String, storeURL: URL) -> SelectionState {
        guard let data = try? Data(contentsOf: storeURL),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              ["Displays", "Spaces", "SystemDefault"].contains(where: { root[$0] != nil }) else { return .unknown }
        func contains(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                if dictionary["Provider"] as? String == identifier { return true }
                return dictionary.values.contains(where: contains)
            }
            return (value as? [Any])?.contains(where: contains) ?? false
        }
        return [root["Displays"], root["Spaces"], root["SystemDefault"]].compactMap { $0 }.contains(where: contains)
            ? .selected : .notSelected
    }
}
