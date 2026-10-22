import Foundation
import ImageIO

private func motiscapeLocalized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
}

private func motiscapePreviewURL(_ path: String?) -> URL? {
    guard let path, !path.isEmpty else { return nil }
    let url = URL(fileURLWithPath: path)
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1
          ] as CFDictionary) != nil else { return nil }
    return url
}

func buildMotiscapeSettingsViewModels(configuration: MotiscapeLockConfiguration) throws -> AnyObject {
    let provider = MotiscapeChoiceProviderID(Bundle.main.bundleIdentifier ?? "com.BaiTenG.motiscape.WallpaperExtension")
    let fallbackThumbnail = URL(fileURLWithPath: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarDisplay.icns")
    let defaultThumbnail = Bundle.main.url(forResource: "thumbnail", withExtension: "png") ?? fallbackThumbnail
    let items = configuration.displays.values.sorted { $0.displayID < $1.displayID }.map { display in
        let identifier = "display-\(display.displayID)"
        let choiceID = MotiscapeChoiceID(
            id: identifier,
            descriptor: MotiscapeChoiceIDDescriptor(
                provider: provider,
                identifier: identifier,
                files: [],
                configuration: Data(identifier.utf8)
            )
        )
        let thumbnail = MotiscapeThumbnail.image(motiscapePreviewURL(display.renderedPreviewPath) ?? defaultThumbnail)
        return MotiscapeSettingsItem(
            id: choiceID,
            localizedName: "motiscape · \(display.title)",
            thumbnail: thumbnail,
            choice: MotiscapeChoiceDescriptor(
                id: choiceID,
                provider: provider,
                identifier: identifier,
                name: display.title,
                localizedDescription: motiscapeLocalized("Motiscape 动态锁屏显示器实例"),
                thumbnail: thumbnail,
                isDownloaded: true,
                options: []
            ),
            contentBadge: .dynamic,
            showInTopLevel: true,
            sortOrder: Int(display.displayID),
            disposability: .none
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let revision = MotiscapeLockBridge.digest(try encoder.encode(items))
    let group = MotiscapeSettingsGroup(
        id: MotiscapeGroupID(id: "motiscape-dynamic-lock-screen-\(revision.prefix(16))"),
        items: items,
        localizedName: motiscapeLocalized("Motiscape 动态锁屏"),
        disposability: .none,
        sortOrder: -100,
        sortID: MotiscapeGroupSortID(id: "com.apple.wallpaper.aerials"),
        allChoiceID: nil,
        shouldHideItemLabels: false,
        contextMenu: nil,
        thumbnail: nil
    )
    let models = MotiscapeSettingsViewModels(
        desktop: MotiscapeSettingsViewModel(groups: configuration.enabled == false ? [] : [group],
                                        refreshPolicy: .discretionary, isModificationDisabled: false),
        screenSaver: nil
    )
    guard let encoded = motiscapeSettingsViewModelsXPC(models) else {
        throw MotiscapeLockBridge.failure("Unable to encode wallpaper settings")
    }
    return encoded
}
