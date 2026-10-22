import SwiftUI

struct PlaylistSettingsSheet: View {
    @ObservedObject var manager: PlaylistManager
    let screen: Int
    @Binding var isPresented: Bool

    @State private var settings = PlaylistSettings.default()
    @State private var didLoad = false
    @State private var showDayOfWeekWarning = false

    private static let weekdaySymbols: [String] = [
        L("星期日"), L("星期一"), L("星期二"), L("星期三"),
        L("星期四"), L("星期五"), L("星期六")
    ]

    private var itemCount: Int { manager.current(on: screen).items.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(L("播放列表设置"))
                    .font(.title2.bold())
                Spacer()
                Button(L("重置")) {
                    settings = .default()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L("恢复默认设置，点“好”后生效"))
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    orderSection
                    timingSection
                    transitionSection
                    optionsSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 2)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)

            HStack {
                Spacer()
                Button(L("取消")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .help(L("关闭窗口，不保存设置"))
                Button(action: commit) {
                    Text(L("好")).frame(width: 60)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .help(L("保存并应用播放列表设置"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 560, height: 600)
        .background(Color.primary.opacity(0.035))
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            settings = manager.current(on: screen).settings
        }
    }

    // MARK: Sections

    private var orderSection: some View {
        card {
            HStack(spacing: 16) {
                sectionTitle(L("播放顺序"), systemImage: "list.number")
                Spacer(minLength: 12)
                Picker(L("播放顺序"), selection: $settings.order) {
                    ForEach(PlaylistOrder.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("playlist.settings.order")
                .help(L("按列表顺序或随机播放"))
            }
        }
    }

    private var timingSection: some View {
        card {
            HStack(spacing: 16) {
                sectionTitle(L("更换壁纸"), systemImage: "clock")
                Spacer(minLength: 12)
                Picker(L("更换壁纸"), selection: $settings.timing) {
                    ForEach(PlaylistTiming.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("playlist.settings.timing")
                .help(L("选择自动切换壁纸的时机"))
            }

            switch settings.timing {
            case .timer:
                timerControls
            case .daytime:
                daytimeControls
            case .dayOfWeek:
                dayOfWeekControls
            case .logon:
                Text(L("仅在 Motiscape 启动时切换到列表中的壁纸。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .never:
                Text(L("壁纸不会自动更换，仅手动点选切换。"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var timerControls: some View {
        HStack(spacing: 24) {
            HStack(spacing: 8) {
                Stepper(value: $settings.timerHours, in: 0...24) {
                    Text("\(settings.timerHours)")
                        .frame(minWidth: 24, alignment: .trailing)
                        .monospacedDigit()
                }
                .accessibilityLabel(L("小时"))
                .accessibilityIdentifier("playlist.settings.hours")
                .help(L("设置切换间隔的小时数"))
                Text(L("小时"))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Stepper(value: $settings.timerMinutes, in: 0...59) {
                    Text("\(settings.timerMinutes)")
                        .frame(minWidth: 24, alignment: .trailing)
                        .monospacedDigit()
                }
                .accessibilityLabel(L("分钟"))
                .accessibilityIdentifier("playlist.settings.minutes")
                .help(L("设置切换间隔的分钟数"))
                Text(L("分钟"))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var daytimeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("选择每天切换壁纸的时刻"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<24, id: \.self) { hour in
                    let active = settings.daytimeAnchors.contains(hour)
                    Button {
                        toggleAnchor(hour)
                    } label: {
                        Text(String(format: "%02d", hour))
                            .font(.caption.monospacedDigit())
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(active ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                            .foregroundStyle(active ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("每天 %02d:00 切换壁纸", hour))
                    .accessibilityAddTraits(active ? [.isSelected] : [])
                    .help(active ? L("取消每天 %02d:00 的切换", hour) : L("每天 %02d:00 切换壁纸", hour))
                }
            }
        }
    }

    private var dayOfWeekControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if itemCount > 7 {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L("星期播放列表不支持超过 7 张壁纸。"),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("立即移除多余的壁纸")) {
                        trimToSeven()
                    }
                    .buttonStyle(.link)
                    .help(L("只保留列表前 7 张，不删除壁纸"))
                }
            }
            Text(L("列表中的前 7 张壁纸将分别对应星期日至星期六。"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transitionSection: some View {
        card {
            HStack(spacing: 16) {
                sectionTitle(L("显示壁纸过渡"), systemImage: "square.on.square")
                Spacer(minLength: 12)
                Picker(L("显示壁纸过渡"), selection: $settings.transition) {
                    ForEach(PlaylistTransitionKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("playlist.settings.transition")
                .help(L("选择壁纸切换时的过渡效果"))
            }

            if settings.transition != .disabled {
                HStack(spacing: 12) {
                    Text(L("过渡时间"))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    MotiscapeSlider(value: $settings.transitionSeconds, in: 0.2...5.0, step: 0.1)
                        .accessibilityLabel(L("过渡时间"))
                        .accessibilityIdentifier("playlist.settings.duration")
                        .help(L("调整过渡效果的持续时间"))
                    Text(String(format: "%.1fs", settings.transitionSeconds))
                        .frame(width: 44, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
    }

    private var optionsSection: some View {
        section(L("选项"), systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $settings.alwaysBeginFirst) {
                    Text(L("总是从第一张壁纸开始"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(L("启动时从列表第一张开始"))
                Toggle(isOn: $settings.introOnStartup) {
                    Text(L("第一张壁纸仅在启动时播放"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(L("将第一张壁纸用作启动壁纸"))
                Toggle(isOn: $settings.videoSequence) {
                    Text(L("在视频结束时更换壁纸"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(L("视频播完后切换下一张"))
                Toggle(isOn: $settings.updateOnPause) {
                    Text(L("允许壁纸在暂停时更换"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .help(L("暂停播放时仍允许自动切换"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, systemImage: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        card {
            sectionTitle(title, systemImage: systemImage)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: MotiscapeDesign.cardRadius))
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).font(.headline)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func toggleAnchor(_ hour: Int) {
        if let idx = settings.daytimeAnchors.firstIndex(of: hour) {
            settings.daytimeAnchors.remove(at: idx)
        } else {
            settings.daytimeAnchors.append(hour)
            settings.daytimeAnchors.sort()
        }
    }

    private func trimToSeven() {
        manager.trimItems(to: 7, on: screen)
    }

    private func commit() {
        manager.updateSettings(on: screen) { $0 = settings }
        isPresented = false
    }
}
