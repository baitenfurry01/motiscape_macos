import AppKit
import Observation
import SwiftUI

@MainActor @Observable final class LibraryMetadataRecoverySession {
    let recovery: LibraryMetadataRecovery
    private(set) var request: LibraryMetadataRecovery.Request?
    private(set) var isWorking = false
    private(set) var error: String?
    private(set) var acknowledged = false

    init(directory: URL = LibraryMetadataRecovery.defaultDirectory) {
        recovery = LibraryMetadataRecovery(directory: directory.resolvingSymlinksInPath().standardizedFileURL)
        refresh()
    }
    func refresh() {
        guard !isWorking, !acknowledged else { return }
        do { request = try recovery.request(); error = nil }
        catch { self.request = nil; self.error = error.localizedDescription }
    }
    func preserveAndSwitch() {
        guard !isWorking, !acknowledged else { return }
        isWorking = true; error = nil
        let recovery = recovery
        Task { @MainActor in
            defer { self.isWorking = false }
            do { self.request = try await Task.detached { try recovery.perform() }.value }
            catch { self.error = error.localizedDescription; self.request = try? recovery.request() }
        }
    }
    func acknowledge() {
        guard !isWorking, !acknowledged, request?.phase == .switched || request?.phase == .rolledBack else { return }
        isWorking = true; error = nil
        let recovery = recovery
        Task { @MainActor in
            defer { self.isWorking = false }
            do { try await Task.detached { try recovery.acknowledge() }.value; self.acknowledged = true }
            catch { self.error = error.localizedDescription }
        }
    }
    func rollback() {
        guard !isWorking, !acknowledged else { return }
        isWorking = true; error = nil
        let recovery = recovery
        Task { @MainActor in
            defer { self.isWorking = false }
            do { self.request = try await Task.detached { try recovery.rollback() }.value }
            catch { self.error = error.localizedDescription }
        }
    }
    func cancelBeforeSwitch() {
        guard !isWorking, !acknowledged else { return }
        isWorking = true; error = nil
        let recovery = recovery
        Task { @MainActor in
            defer { self.isWorking = false }
            do {
                self.request = try await Task.detached { try recovery.cancelBeforeSwitch() }.value
                self.acknowledged = true
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// This delegate deliberately does not construct AppDelegate, import/download
/// models, renderers or Steam services. It runs before normal startup.
@MainActor final class LibraryMetadataRecoveryAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private let session = LibraryMetadataRecoverySession()
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppIntegrationFixture.record("maintenance-window", fields: ["directory": session.recovery.directory.path])
        NSApplication.shared.setActivationPolicy(.regular)
        let view = LibraryMetadataRecoveryView(session: session)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 640),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("壁纸引擎 · 数据库维护")
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self; window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !session.isWorking }
    func windowWillClose(_ notification: Notification) { NSApplication.shared.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppIntegrationFixture.record("maintenance-quit", fields: ["busy": String(session.isWorking)])
        return session.isWorking ? .terminateCancel : .terminateNow
    }
}
