import Cocoa
import SwiftUI

class MainWindowController: NSWindowController, NSWindowDelegate {
    private let minimumContentSize = NSSize(width: MotiscapeDesign.minimumWindowWidth,
                                          height: MotiscapeDesign.minimumWindowHeight)

    override var window: NSWindow! {
        get {
            return super.window
        }
        set {
            super.window = newValue
        }
    }
    
    override init(window: NSWindow?) {
        super.init(window: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false))
        self.window.delegate = self
        self.window.isReleasedWhenClosed = false
        refreshLocalizedTitle()
        self.window.titlebarAppearsTransparent = true
        self.window.toolbarStyle = .unified
        self.window.setFrameAutosaveName("MainWindow")
        self.window.isMovableByWindowBackground = false
        let hostingView = NSHostingView(rootView: ContentView(
                viewModel: AppDelegate.shared.contentViewModel,
                wallpaperViewModel: AppDelegate.shared.wallpaperViewModel,
                navigationModel: AppDelegate.shared.navigationModel
            ).environment(AppDelegate.shared.globalSettingsViewModel)
        )
        hostingView.sizingOptions = []
        self.window.contentView = hostingView
        enforceMinimumSize()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func windowDidLoad() {
        super.windowDidLoad()
        enforceMinimumSize()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimumFrameSize = sender.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        enforceMinimumSize()
    }

    private func enforceMinimumSize() {
        guard let window else { return }
        window.contentMinSize = minimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size

        let currentContentSize = window.contentRect(forFrameRect: window.frame).size
        let clampedSize = NSSize(
            width: max(currentContentSize.width, minimumContentSize.width),
            height: max(currentContentSize.height, minimumContentSize.height)
        )
        if currentContentSize != clampedSize {
            window.setContentSize(clampedSize)
        }
    }
    
    func windowWillClose(_ notification: Notification) {
        AppDelegate.shared.contentViewModel.isWindowVisible = false
        AppDelegate.shared.contentViewModel.isStaging = false
        AppDelegate.shared.enterMenuBarMode()
    }
    
    func windowDidResignKey(_ notification: Notification) { }

    func windowDidResignMain(_ notification: Notification) { }
    
    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async {
            AppDelegate.shared.contentViewModel.isStaging = true
            AppDelegate.shared.contentViewModel.isWindowVisible = true
        }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        AppDelegate.shared.contentViewModel.isWindowVisible = window.isVisible &&
            !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        AppDelegate.shared.contentViewModel.isWindowVisible = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        windowDidChangeOcclusionState(notification)
    }

    func refreshLocalizedTitle() {
        // Keep the internal localization key stable while branding the visible title.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        window?.title = L("Motiscape %@", version)
    }
}
