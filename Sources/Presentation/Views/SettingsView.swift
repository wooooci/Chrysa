import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var hoveredSettingsCategory: SettingsCategory? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Secondary Category Menu Bar with Magpie `.seg > .thumb` shared gliding capsule
            HStack(spacing: 6) {
                ForEach(SettingsCategory.allCases) { cat in
                    settingsCategoryPill(cat)
                }
                Spacer()
            }
            .backgroundPreferenceValue(SettingsCategoryBoundsKey.self) { bounds in
                GeometryReader { proxy in
                    if let anchor = bounds[vm.settingsCategory] {
                        let rect = proxy[anchor]
                        Capsule(style: .continuous)
                            .fill(theme.accent)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(.spring(response: 0.18, dampingFraction: 0.92), value: vm.settingsCategory)
                    }
                }
            }
            .padding(.bottom, 12)
            .overlay(
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1),
                alignment: .bottom
            )
            .padding(.bottom, 16)
            Group {
                switch vm.settingsCategory {
                case .appearance:
                    settingsAppearanceView
                case .download:
                    settingsDownloadView
                case .unpack:
                    settingsUnpackView
                case .patch:
                    settingsPatchView
                }
            }
        }
    }

    private func settingsCategoryPill(_ cat: SettingsCategory) -> some View {
        let isHighlighted = (vm.settingsCategory == cat)
        let isHovered = (hoveredSettingsCategory == cat && !isHighlighted)

        return Text(cat.rawValue)
            .font(.system(size: 12, weight: .semibold))
            .opacity(0)
            .overlay {
                Text(cat.rawValue)
                    .font(.system(size: 12, weight: isHighlighted ? .semibold : .medium))
                    .foregroundColor(
                        isHighlighted
                            ? .white
                            : (isHovered ? .t3TextMain : .t3TextSub)
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3.5)
            .contentShape(Rectangle())
            .anchorPreference(key: SettingsCategoryBoundsKey.self, value: .bounds) { [cat: $0] }
            .onHover { hovering in
                if hovering {
                    hoveredSettingsCategory = cat
                } else if hoveredSettingsCategory == cat {
                    hoveredSettingsCategory = nil
                }
            }
            .onInstantPress {
                if vm.settingsCategory != cat {
                    vm.settingsCategory = cat
                }
            }
    }

    // MARK: 1. Appearance Settings
    private var settingsAppearanceView: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)
        let selectedID = vm.settingsStore.settings.selectedIconID
        let variant = vm.settingsStore.settings.selectedIconVariant
        let followTheme = (vm.settingsStore.settings.accentColorMode == .followAppIcon)

        return VStack(alignment: .leading, spacing: 0) {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(vm.iconOptions) { opt in
                    appIconCard(opt, isSelected: selectedID == opt.id, variant: variant)
                }
            }
            .padding(.bottom, 16)
            .overlay(
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1),
                alignment: .bottom
            )

            t3SettingRow(title: "跟随主题色") {
                T3ToggleSwitch(isOn: followTheme)
            }
            .contentShape(Rectangle())
            .onInstantPress {
                vm.toggleFollowAppIconTheme()
            }
        }
    }

    private func appIconCard(_ opt: AppIconOption, isSelected: Bool, variant: String) -> some View {
        ZStack {
            if let nsImg = vm.iconPreviewImage(id: opt.id, variant: variant) {
                Image(nsImage: nsImg)
                    .frame(width: 58, height: 58)
            } else {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(AppThemePalette.logoAccentColor(for: opt.id).opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(AppThemePalette.logoAccentColor(for: opt.id).opacity(0.40), lineWidth: 1)
                    )
                    .frame(width: 58, height: 58)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? theme.accent.opacity(0.06) : Color.t3TopBoxBg.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? theme.accent : Color.t3Divider, lineWidth: isSelected ? 1.8 : 1)
                )
        )
        .overlay(alignment: .topTrailing) {
            if isSelected {
                ZStack {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 16, height: 16)
                        .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(.white)
                }
                .padding(5)
            }
        }
        .contentShape(Rectangle())
        .onInstantPress {
            vm.selectAppIcon(id: opt.id)
        }
    }
    // MARK: 2. Download Settings (Interactive Directory & Concurrent Connections)
    private var settingsDownloadView: some View {
        let dirLabel = vm.settingsStore.settings.displayDownloadDirectory
        let connCount = vm.settingsStore.settings.maxConcurrentConnections
        let maxJobsCount = vm.settingsStore.settings.maxConcurrentDownloads

        return VStack(alignment: .leading, spacing: 0) {
            t3SettingRow(title: "下载目录") {
                if isSnapshotMode {
                    T3OutlinedPill(text: dirLabel, icon: "folder")
                } else {
                    Menu {
                        Button(action: { vm.chooseDownloadDirectory() }) {
                            Label("选择下载目录...", systemImage: "folder.badge.gearshape")
                        }
                        Button(action: { vm.openDownloadDirectoryInFinder() }) {
                            Label("在访达中打开", systemImage: "arrow.up.forward.square")
                        }
                        Divider()
                        Button(action: { vm.resetDownloadDirectory() }) {
                            Label("恢复默认 (~/Downloads)", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        T3OutlinedPill(text: dirLabel, icon: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            t3SettingRow(title: "同时下载") {
                if isSnapshotMode {
                    T3OutlinedPill(text: "\(maxJobsCount) 个")
                } else {
                    Menu {
                        ForEach([1, 2, 3, 4], id: \.self) { n in
                            Button(action: { vm.setMaxConcurrentDownloads(n) }) {
                                HStack {
                                    Text("\(n) 个任务")
                                    if maxJobsCount == n {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        T3OutlinedPill(text: "\(maxJobsCount) 个")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            t3SettingRow(title: "并发连接") {
                if isSnapshotMode {
                    T3OutlinedPill(text: "\(connCount)")
                } else {
                    Menu {
                        ForEach([4, 8, 16], id: \.self) { n in
                            Button(action: { vm.setConcurrentConnections(n) }) {
                                HStack {
                                    Text("\(n) 线程")
                                    if connCount == n {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        T3OutlinedPill(text: "\(connCount)")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
    // MARK: 3. Unpack Settings (Auto Cleanup + Password Dictionary)
    private var settingsUnpackView: some View {
        VStack(alignment: .leading, spacing: 12) {
            t3SettingRow(title: "解压后清理压缩包") {
                Button(action: { vm.toggleDeleteArchiveAfterUnpack() }) {
                    T3ToggleSwitch(isOn: vm.settingsStore.settings.deleteArchiveAfterUnpack)
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 10) {
                if !isSnapshotMode {
                    TextField("添加解压密码...", text: $vm.newPasswordInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(.t3TextMain)
                        .onSubmit { vm.addPassword() }

                    if !vm.newPasswordInput.isEmpty {
                        Button(action: { vm.newPasswordInput = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.t3TextMuted)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("添加解压密码...")
                        .font(.system(size: 12.5))
                        .foregroundColor(.t3TextSub)
                    Spacer()
                }

                Button(action: { vm.addPassword() }) {
                    Text("+ 添加")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.t3TopBoxBg)
            )

            passwordDictionaryList
        }
    }

    @ViewBuilder
    private var passwordDictionaryList: some View {
        if isSnapshotMode {
            passwordRows(limit: 8)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                passwordRows(limit: nil)
            }
        }
    }

    private func passwordRows(limit: Int?) -> some View {
        let items: [(Int, String)] = {
            let all = Array(vm.passwords.enumerated()).map { ($0.offset, $0.element) }
            if let lim = limit {
                return Array(all.prefix(lim))
            }
            return all
        }()

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(items, id: \.0) { idx, pwd in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 16, alignment: .center)

                    Text(pwd)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.t3TextMain)

                    Spacer()

                    Button(action: { vm.removePassword(at: idx) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.t3TextMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .overlay(
                    Rectangle()
                        .fill(Color.t3Divider)
                        .frame(height: 1),
                    alignment: .bottom
                )
            }
        }
    }

    // MARK: 4. Patch & CrossOver Settings (Interactive Bottles Dir, Default Language, Auto Relay)
    private var settingsPatchView: some View {
        let bottlesLabel = vm.settingsStore.settings.displayBottlesDirectory
        let lang = vm.settingsStore.settings.defaultLanguage

        return VStack(alignment: .leading, spacing: 0) {
            t3SettingRow(title: "容器目录") {
                if isSnapshotMode {
                    T3OutlinedPill(text: bottlesLabel, icon: "folder")
                } else {
                    Menu {
                        Button(action: { vm.openBottlesDirectoryInFinder() }) {
                            Label("在访达中打开", systemImage: "arrow.up.forward.square")
                        }
                        Button(action: { vm.rescanCrossOverBottles(includePreviouslyRemoved: true) }) {
                            Label("重新扫描已安装容器", systemImage: "arrow.clockwise")
                        }
                        Button(action: { vm.chooseBottlesDirectory() }) {
                            Label("选择容器目录...", systemImage: "folder.badge.gearshape")
                        }
                        Divider()
                        Button(action: { vm.resetBottlesDirectory() }) {
                            Label("恢复默认 (CrossOver Bottles)", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        T3OutlinedPill(text: bottlesLabel, icon: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            t3SettingRow(title: "默认语言") {
                if isSnapshotMode {
                    T3OutlinedPill(text: lang.rawValue)
                } else {
                    Menu {
                        ForEach(SteamLanguageOption.allCases) { opt in
                            Button(action: { vm.setDefaultLanguage(opt) }) {
                                HStack {
                                    Text("\(opt.rawValue) · \(opt.shortLabel)")
                                    if lang == opt {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        T3OutlinedPill(text: lang.rawValue)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }

            t3SettingRow(title: "自动流转") {
                Button(action: { vm.toggleAutoRelay() }) {
                    T3ToggleSwitch(isOn: vm.settingsStore.settings.autoRelay)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func t3SettingRow<Trailing: View>(title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundColor(.t3TextMain)
            Spacer()
            trailing()
        }
        .frame(height: 40)
        .overlay(
            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}
