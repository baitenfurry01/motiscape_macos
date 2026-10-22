import Foundation
#if DEBUG
import AppKit
#endif

/// Debug-only application-entry tests. Release builds cannot redirect storage.
/// A separate bundle ID, explicit argument and owned temporary marker are all
/// required. Normal business startup is refused unless the explicit local-only
/// library UI profile installs its sandbox before model construction.
enum AppIntegrationFixture {
    private static let lock = NSLock()
    private static let argument = "--metadata-integration-root"
    private static let root: URL? = {
        let args = CommandLine.arguments
        let fixtureBundle = Bundle.main.bundleIdentifier == "dev.motiscape.integration"
        let libraryUI = args.contains("--library-ui-integration")
        let reopenProbe = args.contains("--metadata-reopen-probe")
        let copyCancel = args.contains("--import-copy-cancel-integration")
        let frameCancel = args.contains("--import-frame-cancel-integration")
        let zipClose = args.contains("--zip-close-exit-integration")
        let indexQuit = args.contains("--index-quit-integration")
        let videoPlayback = args.contains("--video-playback-integration")
        let scenePlayback = args.contains("--scene-playback-integration")
        guard fixtureBundle || args.contains(argument) || libraryUI || reopenProbe || copyCancel || frameCancel || zipClose || indexQuit || videoPlayback || scenePlayback else { return nil }
        #if DEBUG
        guard fixtureBundle, let position = args.firstIndex(of: argument), position + 1 < args.count else {
            fail("Integration fixture requires its own bundle and explicit root")
        }
        guard !(libraryUI && reopenProbe) else { fail("Conflicting integration modes") }
        guard !copyCancel || libraryUI else { fail("Copy cancellation fixture requires local library UI mode") }
        guard !frameCancel || (libraryUI && !copyCancel) else { fail("Frame cancellation requires exclusive local library UI mode") }
        guard !zipClose || (libraryUI && !copyCancel && !frameCancel) else { fail("ZIP close fixture requires exclusive local library UI mode") }
        guard !indexQuit || (libraryUI && !copyCancel && !frameCancel && !zipClose) else { fail("Index quit fixture requires exclusive local library UI mode") }
        guard !videoPlayback || (libraryUI && !copyCancel && !frameCancel && !zipClose && !indexQuit) else { fail("Video playback requires exclusive local library UI mode") }
        guard !scenePlayback || (libraryUI && !videoPlayback && !copyCancel && !frameCancel && !zipClose && !indexQuit) else { fail("Scene playback requires exclusive local library UI mode") }
        let url = URL(fileURLWithPath: args[position + 1]).resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(temporary.path + "/"), url.path != temporary.path else { fail("Integration root is not a private temporary fixture") }
        let marker = url.appending(path: ".app-integration-fixture")
        let fd = open(marker.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { fail("Missing integration ownership marker") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_uid == getuid(), status.st_nlink == 1,
              status.st_size < 1024,
              (try? handle.readToEnd()) == Data("Motiscape application integration fixture v1\n".utf8) else {
            fail("Invalid integration ownership marker")
        }
        return url
        #else
        fail("Integration overrides are not available in release builds")
        #endif
    }()

    static var isEnabled: Bool { root != nil }
    static var isLibraryUI: Bool { isEnabled && CommandLine.arguments.contains("--library-ui-integration") }
    static var isVideoPlayback: Bool { isLibraryUI && CommandLine.arguments.contains("--video-playback-integration") }
    static var isScenePlayback: Bool { isLibraryUI && CommandLine.arguments.contains("--scene-playback-integration") }
    static var isPlayback: Bool { isVideoPlayback || isScenePlayback }
    static var playbackEventPrefix: String { isScenePlayback ? "scene-playback" : "video-playback" }
    private static var playbackRenderer: String { isScenePlayback ? "SceneWallpaper" : "VideoWallpaper" }
    private static var playbackProject: String { isScenePlayback ? "Scene Playback Test" : "Playback Test" }
    static var supportDirectory: URL? { root?.appending(path: "support") }
    static var libraryDirectory: URL? { root?.appending(path: "library") }
    static var metadataDirectory: URL? { root?.appending(path: "metadata") }
    static var frameCancellationSource: URL? {
        guard isLibraryUI, CommandLine.arguments.contains("--import-frame-cancel-integration") else { return nil }
        return root?.appending(path: "sources/Frame Cancel.mp4")
    }
    static func validateInvocation() {
        _ = root
        if isLibraryUI {
            // Storage uses the validated fixture root directly. Keep account
            // and trust preferences isolated from earlier preview runs too.
            UserDefaults.standard.setVolatileDomain([
                "SteamServiceUsername": "", "TrustedWallpapers": [String]()
            ], forName: UserDefaults.argumentDomain)
        }
    }

    static func requireProductionStartupAllowed() {
        if isEnabled && !isLibraryUI { record("production-delegate-refused"); fail("Production models are forbidden in the isolated fixture") }
    }

    static func requireExternalEffectsAllowed(_ component: String) {
        if isEnabled { record("external-effect-refused", fields: ["component": component]); fail("External effect forbidden: " + component) }
    }

    /// Only a separately requested fixture can launch its one packaged
    /// renderer. The ordinary UI fixture continues to reject every child.
    static func requireWallpaperRendererAllowed(executable: URL, wallpaper: WEWallpaper) {
        guard isPlayback, let directory = libraryDirectory else {
            requireExternalEffectsAllowed("wallpaper renderer process")
            return
        }
        let expected = Bundle.main.bundleURL.appending(path: "Contents/Resources/Renderers/" + playbackRenderer)
        let project = directory.resolvingSymlinksInPath().appending(path: playbackProject)
        guard executable.standardizedFileURL.path == expected.standardizedFileURL.path,
              executable.resolvingSymlinksInPath().path == expected.standardizedFileURL.path,
              wallpaper.kind == (isScenePlayback ? .scene : .video),
              wallpaper.wallpaperDirectory.resolvingSymlinksInPath().path == project.standardizedFileURL.path,
              wallpaper.resolvedEntryURL.resolvingSymlinksInPath().deletingLastPathComponent().path == project.standardizedFileURL.path else {
            record(playbackEventPrefix + "-target-refused", fields: ["executable": executable.path,
                "expected": expected.path, "project": wallpaper.wallpaperDirectory.path,
                "expectedProject": project.path, "kind": String(describing: wallpaper.kind)])
            fail("Playback fixture rejected renderer or wallpaper")
        }
        record(playbackEventPrefix + "-launch-allowed", fields: ["executable": executable.path, "project": project.path])
    }

    @MainActor static func startPlaybackWatchdog() {
        guard isPlayback else { return }
        #if DEBUG
        // A lost automation connection must not leave a desktop child running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
            record(playbackEventPrefix + "-watchdog")
            NSApplication.shared.terminate(nil)
        }
        #endif
    }

    static func capturePlaybackEvidence(displayID: UInt32) {
        guard isPlayback, let root else { return }
        #if DEBUG
        Task { @MainActor in
            record(playbackEventPrefix + "-committed", fields: ["display": String(displayID)])
            for index in 1...2 {
                try? await Task.sleep(for: .milliseconds(700))
                let path = root.appending(path: "playback-frame-\(index).heic").path
                AppDelegate.shared.wallpaperViewModel.renderer.snapshot(onDisplay: displayID, path: path) { ok in
                    record(playbackEventPrefix + "-snapshot", fields: ["frame": String(index), "ok": String(ok)])
                }
            }
        }
        #endif
    }

    #if DEBUG
    private static var copyPauseTaken = false
    private static var indexPauseTaken = false
    private static func claimIndexPause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !indexPauseTaken else { return false }
        indexPauseTaken = true
        return true
    }
    /// Observe the real incremental index after its first 16-record commit.
    /// Only the explicit isolated UI mode waits; no record is fabricated here.
    static func holdAutomaticIndexForUI(_ progress: ImportProgress) async {
        guard isLibraryUI, CommandLine.arguments.contains("--index-quit-integration"),
              progress.current == 17, progress.total == 100, claimIndexPause() else { return }
        let hasSheet = await MainActor.run { NSApp.windows.contains { $0.attachedSheet != nil } }
        record("index-ui-held", fields: ["current": String(progress.current), "total": String(progress.total),
                                        "hasSheet": String(hasSheet)])
        do {
            try await Task.sleep(for: .seconds(120))
            record("index-ui-hold-expired")
        } catch { record("index-ui-hold-cancelled") }
    }

    /// Keep the actual prepared leases alive across a visible sheet close so an
    /// explicit normal Quit can interrupt pending cleanup deterministically.
    /// No file is removed or lease released by this observation point.
    static func holdZIPCleanupForUI(_ coordinator: ImportCoordinator?) async {
        guard isLibraryUI, CommandLine.arguments.contains("--zip-close-exit-integration"),
              let coordinator, let inventory = try? await coordinator.archiveWorkspaceInventory(),
              inventory.activeCount > 0 else { return }
        record("zip-close-cleanup-held", fields: ["active": String(inventory.activeCount)])
        do {
            try await Task.sleep(for: .seconds(60))
            record("zip-close-cleanup-hold-expired")
        } catch { record("zip-close-cleanup-hold-cancelled") }
    }
    private static func claimCopyPause() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !copyPauseTaken else { return false }
        copyPauseTaken = true
        return true
    }

    /// Hold only after real bytes were copied, so a UI click can cancel the real
    /// transaction. Never compiled into Release; default Debug runs do not wait.
    /// One-shot permits the same process to retry normally after cancellation.
    static func holdPartialCopyForUI(_ progress: ImportProgress) async {
        guard isLibraryUI, CommandLine.arguments.contains("--import-copy-cancel-integration"),
              progress.copiedBytes >= 4 * 1024 * 1024, progress.copiedBytes < progress.totalBytes,
              claimCopyPause() else { return }
        record("copy-cancel-held", fields: ["copied": String(progress.copiedBytes), "total": String(progress.totalBytes)])
        await MainActor.run {
            let window = AppDelegate.shared.mainWindowController.window
            record("copy-ui-modal-state", fields: [
                "hasSheet": String(window?.attachedSheet != nil),
                "preventsTermination": String(window?.attachedSheet?.preventsApplicationTerminationWhenModal ?? false),
                "parentVisible": String(window?.isVisible ?? false)
            ])
        }
        do {
            try await Task.sleep(for: .seconds(60))
            record("copy-cancel-hold-expired")
        } catch {
            record("copy-cancel-released", fields: ["cancelled": String(Task.isCancelled)])
        }
    }
    #endif

    /// Use the installed SDK's sandbox_init ABI, loaded only in debug fixtures.
    /// A sandbox-exec wrapper loses the GUI app's Launch Services identity on
    /// this host; applying the same restrictions in-process avoids that wrapper.
    static func installLibrarySandbox() {
        guard isLibraryUI, let root else { return }
        #if DEBUG
        typealias Initialize = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
        typealias FreeError = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
        guard let library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_NOW),
              let symbol = dlsym(library, "sandbox_init"),
              let freeSymbol = dlsym(library, "sandbox_free_error"),
              let url = Bundle.main.url(forResource: "LibraryUIFixture", withExtension: "sb"),
              var profile = try? String(contentsOf: url, encoding: .utf8) else { fail("Missing local UI sandbox") }
        let initialize = unsafeBitCast(symbol, to: Initialize.self)
        let freeError = unsafeBitCast(freeSymbol, to: FreeError.self)
        func literal(_ value: String) -> String {
            guard !value.unicodeScalars.contains(where: { $0.value < 32 }) else { fail("Unsafe sandbox path") }
            return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let sentinel = root.appending(path: "denied-sentinel")
        guard FileManager.default.fileExists(atPath: sentinel.path) else { fail("Missing sandbox sentinel") }
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(sentinel.path, &canonical) != nil else { fail("Cannot canonicalize sandbox sentinel") }
        profile = profile.replacingOccurrences(of: "(param \"USER_LIBRARY\")", with: literal(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").path))
        profile = profile.replacingOccurrences(of: "(param \"DENIED_SENTINEL\")", with: literal(String(cString: canonical)))
        if isPlayback {
            let renderer = Bundle.main.bundleURL.appending(path: "Contents/Resources/Renderers/" + playbackRenderer)
            guard renderer.resolvingSymlinksInPath() == renderer.standardizedFileURL,
                  FileManager.default.isExecutableFile(atPath: renderer.path),
                  profile.contains("(deny process-exec)") else { fail("Missing packaged playback renderer or sandbox rule") }
            // Exact binary only; networking and real user-library denies remain.
            profile = profile.replacingOccurrences(of: "(deny process-exec)",
                with: "(deny process-exec (require-not (literal " + literal(renderer.path) + ")))")
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = profile.withCString { initialize($0, 0, &error) }
        if result != 0 {
            let message = error.map { String(cString: $0) } ?? "unknown sandbox error"
            freeError(error); fail(message)
        }
        freeError(error)
        let fd = open(sentinel.path, O_RDONLY)
        guard fd == -1 && (errno == EPERM || errno == EACCES) else {
            if fd >= 0 { close(fd) }
            fail("Local UI sandbox did not block its sentinel")
        }
        let writeFD = open(sentinel.path, O_WRONLY)
        guard writeFD == -1 && (errno == EPERM || errno == EACCES) else {
            if writeFD >= 0 { close(writeFD) }
            fail("Local UI sandbox did not block writes")
        }
        let networkFD = socket(AF_INET, SOCK_STREAM, 0)
        if networkFD >= 0 {
            defer { close(networkFD) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(networkFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard connected == -1 && (errno == EPERM || errno == EACCES) else { fail("Local UI sandbox did not block networking") }
        } else if errno != EPERM && errno != EACCES { fail("Could not verify network sandbox") }
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        do { try child.run(); child.waitUntilExit(); fail("Local UI sandbox did not block child processes") }
        catch { /* sandbox denied spawning even a harmless process */ }
        record("library-ui-sandbox-installed")
        #else
        fail("Local UI sandbox requires a Debug build")
        #endif
    }

    static func record(_ event: String, fields: [String: String] = [:]) {
        guard let root else { return }
        lock.lock(); defer { lock.unlock() }
        var value = fields; value["event"] = event; value["pid"] = String(getpid())
        do {
            let url = root.appending(path: "startup-events.jsonl")
            let fd = open(url.path, O_CREAT | O_APPEND | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { fail("Cannot write fixture trace") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1, status.st_uid == getuid() else {
                fail("Unsafe fixture trace")
            }
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: value) + Data([10]))
            try handle.synchronize()
        } catch { fail("Fixture trace failed: \(error)") }
    }

    /// Proves selection/reopen only. It intentionally does not pretend to be a
    /// normal production startup or start Steam, renderers or automatic indexing.
    static func runReopenProbe() -> Never {
        guard let directory = metadataDirectory, CommandLine.arguments.contains("--metadata-reopen-probe") else {
            record("normal-startup-refused"); fail("Fixture has no maintenance request; normal startup is disabled")
        }
        Task {
            do {
                let store = try LibraryIndexActor(directory: directory)
                let wallpapers = try await store.records(WallpaperRecord.self)
                let jobs = try await store.records(DownloadQueueRecord.self)
                let active = try LibraryMetadataRecovery(directory: directory).activeDirectory()
                record("reopen-probe", fields: ["store": active.path, "wallpapers": String(wallpapers.count), "queues": String(jobs.count)])
                exit(0)
            } catch { record("reopen-error", fields: ["error": error.localizedDescription]); exit(1) }
        }
        dispatchMain()
    }

    private static func fail(_ message: String) -> Never { fputs("AppIntegrationFixture: \(message)\n", stderr); exit(78) }
}
