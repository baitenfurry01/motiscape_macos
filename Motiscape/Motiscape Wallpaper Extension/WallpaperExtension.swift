import AppKit
import ExtensionFoundation
import Foundation
import QuartzCore

struct MotiscapeWallpaperExtensionConfiguration: AppExtensionConfiguration {
    func accept(connection: NSXPCConnection) -> Bool {
        let exported = NSXPCInterface(with: WallpaperExtensionXPCProtocol.self)
        let names = [
            "WallpaperIDXPC", "WallpaperCreationRequestXPC", "WallpaperUpdateRequestXPC",
            "WallpaperRemoteContextXPC", "WallpaperSnapshotXPC", "WallpaperContentTypeSetXPC",
            "WallpaperChoiceIDXPC", "WallpaperChoiceIDsXPC", "WallpaperExtensionChoiceRequestXPC",
            "WallpaperChoiceRequestAdditionResultXPC", "WallpaperDebugRequestXPC", "WallpaperDebugResponseXPC",
            "WallpaperMigrationVersionXPC", "WallpaperSettingsViewModelsXPC", "AuditTokenXPC"
        ]
        let classes = NSMutableSet()
        names.compactMap { objc_getClass($0) }.forEach { classes.add($0) }
        [NSString.self, NSNumber.self, NSData.self, NSArray.self, NSDictionary.self, NSURL.self, NSError.self]
            .forEach { classes.add($0) }
        let allowed = classes as! Set<AnyHashable>
        let selectors: [(Selector, Int, Bool)] = [
            (#selector(MotiscapeWallpaperXPCHandler.acquire(withId:request:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.acquire(withId:request:reply:)), 1, false),
            (#selector(MotiscapeWallpaperXPCHandler.acquire(withId:request:reply:)), 0, true),
            (#selector(MotiscapeWallpaperXPCHandler.update(withId:request:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.update(withId:request:reply:)), 1, false),
            (#selector(MotiscapeWallpaperXPCHandler.invalidate(withId:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.snapshot(withId:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.snapshot(withId:reply:)), 0, true),
            (#selector(MotiscapeWallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.provideSettingsViewModels(withContentTypes:reply:)), 0, true),
            (#selector(MotiscapeWallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.addChoiceRequest(withChoiceRequest:onBehalfOfProcess:reply:)), 1, false),
            (#selector(MotiscapeWallpaperXPCHandler.removeChoiceRequest(withChoiceRequest:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.selectedChoicesDidChange(for:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.invokeContextMenuAction(withMenuItemID:groupItemID:reply:)), 1, false),
            (#selector(MotiscapeWallpaperXPCHandler.isChoiceDownloaded(with:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.download(withChoiceID:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.pauseDownload(for:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.cancelDownload(for:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.resumeDownload(for:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.removeDownload(for:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, false),
            (#selector(MotiscapeWallpaperXPCHandler.handleDebugRequest(for:reply:)), 0, true),
            (#selector(MotiscapeWallpaperXPCHandler.handleNotification(withNamed:reply:)), 0, false)
        ]
        selectors.forEach { exported.setClasses(allowed, for: $0.0, argumentIndex: $0.1, ofReply: $0.2) }
        connection.exportedInterface = exported
        let proxyInterface = NSXPCInterface(with: WallpaperExtensionProxyXPCProtocol.self)
        proxyInterface.setClasses(allowed, for: NSSelectorFromString("updateSettingsViewModels:reply:"),
                                  argumentIndex: 0, ofReply: false)
        connection.remoteObjectInterface = proxyInterface
        let handler = MotiscapeWallpaperXPCHandler()
        connection.exportedObject = handler
        handler.agentProxy = connection.remoteObjectProxyWithErrorHandler { [weak handler] error in
            handler?.connectionFailed(error)
        } as? WallpaperExtensionProxyXPCProtocol
        connection.invalidationHandler = { [weak handler] in handler?.invalidateAll() }
        connection.interruptionHandler = { [weak handler] in handler?.invalidateAll() }
        connection.resume()
        return true
    }
}

@main
final class MotiscapeWallpaperExtension: NSObject, AppExtension {
    typealias Configuration = MotiscapeWallpaperExtensionConfiguration

    var configuration: MotiscapeWallpaperExtensionConfiguration { MotiscapeWallpaperExtensionConfiguration() }

    override required init() {
        super.init()
        if #available(macOS 26.0, *) {
            _ = dlopen("/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit", RTLD_LAZY)
            _ = MotiscapeLockRuntimeIdentity.current
        }
    }
}
