import SwiftUI

struct DisplayPicker: View {
    @Bindable var wallpaperViewModel: WallpaperViewModel
    @ObservedObject private var registry = DisplayRegistryObserver.shared

    private var displays: [DisplayInfo] {
        wallpaperViewModel.connectedDisplays
    }

    var body: some View {
        Menu {
            Section {
                ForEach(displays) { info in
                    Button {
                        wallpaperViewModel.selectedDisplayKey = info.key
                    } label: {
                        Label(rowTitle(info), systemImage: icon(for: info))
                    }
                }
            }

            Section {
                Button {
                    wallpaperViewModel.stopWallpaper()
                } label: {
                    Label(L("停止所选显示器的壁纸"), systemImage: "stop.fill")
                }
                .disabled(!wallpaperViewModel.isRendering(wallpaperViewModel.selectedDisplayKey))

                Button {
                    wallpaperViewModel.stopAllWallpapers()
                } label: {
                    Label(L("停止所有显示器的壁纸"), systemImage: "stop.circle.fill")
                }
                .disabled(!wallpaperViewModel.hasAnyWallpaper)
            } header: {
                Text(L("当前选择：%@", wallpaperViewModel.selectedDisplayTitle))
            }
        } label: {
            Label(label, systemImage: "display")
                // Scope icon-only styling to the trigger. macOS 15 can inherit
                // a Menu-wide style into its rows and hide their titles.
                .labelStyle(.iconOnly)
        }
        .menuIndicator(displays.count > 1 ? .visible : .hidden)
        .help(helpText)
        .labelStyle(.titleAndIcon)
        .accessibilityLabel(L("选择要设置的显示器"))
    }

    private var label: String {
        guard let selected = wallpaperViewModel.selectedDisplay else {
            return L("显示器")
        }
        guard displays.count > 1 else { return selected.name }
        return L("显示器 %d", selected.index + 1)
    }

    private var helpText: String {
        guard let selected = wallpaperViewModel.selectedDisplay else {
            return L("选择要设置的显示器")
        }
        let wallpaper = wallpaperViewModel.wallpaper(for: selected.key)
        guard wallpaper.presentationIsValid else {
            return L("%@ · 未渲染壁纸", selected.name)
        }
        return L("%@ · 当前壁纸：%@", selected.name, wallpaper.project.title)
    }

    private func icon(for info: DisplayInfo) -> String {
        info.key == wallpaperViewModel.selectedDisplayKey ? "checkmark.circle.fill" : "display"
    }

    private func rowTitle(_ info: DisplayInfo) -> String {
        var text = L("显示器 %d", info.index + 1) + " · " + info.name
        text += " · \(Int(info.size.width)) × \(Int(info.size.height))"
        if info.isMain { text += L(" · 主屏") }
        let wallpaper = wallpaperViewModel.wallpaper(for: info.key)
        if wallpaper.presentationIsValid {
            text += " · " + wallpaper.project.title
        } else {
            text += " · " + L("未渲染壁纸")
        }
        return text
    }
}

final class DisplayRegistryObserver: ObservableObject {
    static let shared = DisplayRegistryObserver()

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: DisplayRegistry.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
