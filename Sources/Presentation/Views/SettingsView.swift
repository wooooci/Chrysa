import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

// MARK: - Open Editorial Settings View (ChatGPT macOS Frameless Rows + Hairlines + Unified 8pt Controls)
struct SettingsView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    var topBarHeight: CGFloat = 10
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedCredentialKind: AccelerationCredentialKind = .pixeldrain
    @State private var hoveredIconID: String? = nil
    @State private var hoveredPasswordIdx: Int? = nil
    @FocusState private var isPasswordInputFocused: Bool
    @FocusState private var isCredentialFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WindowDragArea(isSnapshotMode: isSnapshotMode)
                .frame(height: topBarHeight)

            if isSnapshotMode {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) {
                        centeredSettingsColumn
                            .padding(.top, 16)
                            .padding(.bottom, 28)
                    }
                    .clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    centeredSettingsColumn
                        .padding(.top, 16)
                        .padding(.bottom, 48)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onKeyPress(.escape) {
            guard !isSnapshotMode else { return .ignored }
            if isPasswordInputFocused {
                isPasswordInputFocused = false
                return .handled
            }
            if isCredentialFocused {
                isCredentialFocused = false
                return .handled
            }
            vm.exitSettings()
            return .handled
        }
    }

    private var centeredSettingsColumn: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 0) {
                Text(vm.settingsCategory.rawValue)
                    .font(ChrysaFont.pageTitle)
                    .tracking(ChrysaTracking.pageTitle)
                    .foregroundColor(.t3TextMain)
                    .padding(.bottom, 26)

                settingsCategoryBody
            }
            .frame(maxWidth: ChrysaMetrics.settingsMaxWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }

    @ViewBuilder
    private var settingsCategoryBody: some View {
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

    // MARK: 1. Appearance Settings (Frameless Rows + Inline Window Thumbnails + Gliding Selection)
    private var settingsAppearanceView: some View {
        let mascotColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        let selectedID = vm.settingsStore.settings.selectedIconID
        let variant = vm.settingsStore.settings.selectedIconVariant
        let activeMascot = vm.mascotTheme
        let activeAppearance = vm.appearanceMode
        let activeSelectionStroke: Color = theme.mode == .monochrome
            ? Color.t3TextMain.opacity(theme.isDark ? 0.72 : 0.80)
            : theme.accent
        let activeIconStroke: Color = theme.mode == .monochrome
            ? Color.t3TextMain.opacity(theme.isDark ? 0.75 : 0.85)
            : theme.accent

        return VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            // Section 1: Visual Style
            EditorialSection(title: "视觉风格") {
                // Row 1: Inline Miniature Window Thumbnails (ChatGPT macOS Signature Row)
                editorialRow(title: "颜色模式", minHeight: 66) {
                    HStack(spacing: 10) {
                        ForEach(AppearanceMode.allCases) { mode in
                            CompactAppearanceThumb(
                                mode: mode,
                                isSelected: activeAppearance == mode,
                                accent: theme.accent
                            ) {
                                vm.setAppearanceMode(mode)
                            }
                        }
                    }
                    .overlayPreferenceValue(SelectionBoundsKey<AppearanceMode>.self) { bounds in
                        GeometryReader { proxy in
                            if let anchor = bounds[activeAppearance] {
                                let rect = proxy[anchor]
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .stroke(activeSelectionStroke, lineWidth: 1.6)
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .allowsHitTesting(false)
                                    .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: activeAppearance)
                            }
                        }
                    }
                }

                hairline

                // Row 2: Accent Swatches
                editorialRow(title: "强调色", minHeight: 54) {
                    accentSwatchStrip
                }

                hairline

                // Row 3: Inline Compact App Icons with Gliding Ring
                editorialRow(title: "应用图标", minHeight: 62) {
                    HStack(spacing: 8) {
                        ForEach(vm.iconOptions) { opt in
                            compactAppIconButton(opt, isSelected: selectedID == opt.id, variant: variant)
                        }
                    }
                    .overlayPreferenceValue(SelectionBoundsKey<String>.self) { bounds in
                        GeometryReader { proxy in
                            if let anchor = bounds[selectedID] {
                                let rect = proxy[anchor]
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                                    .stroke(activeIconStroke, lineWidth: 1.6)
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .allowsHitTesting(false)
                                    .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: selectedID)
                            }
                        }
                    }
                }
            }

            // Section 2: Companion (Open Frameless Grid)
            EditorialSection(title: "伙伴", trailingMeta: activeMascot.displayName) {
                LazyVGrid(columns: mascotColumns, spacing: 12) {
                    ForEach(MascotTheme.allCases) { option in
                        VStack(alignment: .center, spacing: 6) {
                            MascotThemeCardView(
                                option: option,
                                isSelected: activeMascot == option,
                                isSnapshotMode: isSnapshotMode,
                                cardHeight: 74
                            ) {
                                vm.setMascotTheme(option)
                            }
                            Text(option.displayName)
                                .font(.system(size: 12.5, weight: activeMascot == option ? .medium : .regular))
                                .foregroundColor(activeMascot == option ? .t3TextMain : .t3TextMuted)
                                .lineLimit(1)
                                .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: activeMascot)
                        }
                    }
                }
                .overlayPreferenceValue(SelectionBoundsKey<MascotTheme>.self) { bounds in
                    GeometryReader { proxy in
                        if let anchor = bounds[activeMascot] {
                            let rect = proxy[anchor]
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                                .stroke(activeSelectionStroke, lineWidth: 1.6)
                                .overlay(alignment: .topTrailing) {
                                    T3SelectionCheckBadge(size: 16)
                                        .padding(6)
                                }
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                                .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: activeMascot)
                        }
                    }
                }
                .padding(.top, 14)
            }
        }
    }

    private var accentSwatchStrip: some View {
        let currentMode = vm.accentColorMode
        let currentSwatch = vm.accentSwatch
        let activeSelectionID: AccentSelectionID = {
            switch currentMode {
            case .monochrome:    return .monochrome
            case .followAppIcon: return .followAppIcon
            case .custom:        return .swatch(currentSwatch)
            }
        }()
        let activeRingColor: Color = {
            switch currentMode {
            case .monochrome:
                return theme.isDark ? Color.white.opacity(0.65) : Color.black.opacity(0.65)
            case .followAppIcon:
                return theme.logoAccent
            case .custom:
                return AppThemePalette.swatchColor(for: currentSwatch, colorScheme: colorScheme)
            }
        }()

        return HStack(spacing: 8) {
            AccentDotButton(
                selectionID: .monochrome,
                isSelected: currentMode == .monochrome,
                tooltip: "纯色墨韵"
            ) {
                ZStack {
                    Circle().fill(Color(red: 0.12, green: 0.13, blue: 0.15))
                    Path { p in
                        p.move(to: CGPoint(x: 7.5, y: 0))
                        p.addArc(center: CGPoint(x: 7.5, y: 7.5), radius: 7.5, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                        p.closeSubpath()
                    }
                    .fill(Color(red: 0.92, green: 0.93, blue: 0.95))
                }
                .overlay(Circle().stroke(Color.t3GroupedCardBorder, lineWidth: 0.7))
            } action: {
                vm.setAccentColorMode(.monochrome)
            }

            AccentDotButton(
                selectionID: .followAppIcon,
                isSelected: currentMode == .followAppIcon,
                tooltip: "跟随当前图标（\(theme.logoColorTitle)）"
            ) {
                ZStack {
                    Circle().fill(theme.logoAccent)
                    Image(systemName: "link")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundColor(.white)
                }
            } action: {
                vm.setAccentColorMode(.followAppIcon)
            }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(width: 1, height: 13)
                .padding(.horizontal, 1)

            ForEach(AccentSwatch.allCases) { swatch in
                let col = AppThemePalette.swatchColor(for: swatch, colorScheme: colorScheme)
                let selected = (currentMode == .custom && currentSwatch == swatch)
                AccentDotButton(
                    selectionID: .swatch(swatch),
                    isSelected: selected,
                    tooltip: swatch.displayName
                ) {
                    Circle().fill(col)
                } action: {
                    vm.setCustomAccentSwatch(swatch)
                }
            }
        }
        .overlayPreferenceValue(SelectionBoundsKey<AccentSelectionID>.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[activeSelectionID] {
                    let rect = proxy[anchor]
                    Circle()
                        .stroke(activeRingColor, lineWidth: 1.6)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .allowsHitTesting(false)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: activeSelectionID)
                }
            }
        }
    }

    private func compactAppIconButton(_ opt: AppIconOption, isSelected: Bool, variant: String) -> some View {
        let isHovered = (hoveredIconID == opt.id && !isSelected)

        return ZStack {
            if let nsImg = vm.iconPreviewImage(id: opt.id, variant: variant) {
                Image(nsImage: nsImg)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
            } else {
                let previewTint = AppThemePalette.logoAccentColor(for: opt.id, colorScheme: colorScheme)
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .fill(previewTint.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .stroke(previewTint.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: 32, height: 32)
            }
        }
        .padding(3)
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                .stroke(isHovered ? Color.t3PillBorder : Color.clear, lineWidth: 1.0)
                .animation(ChrysaMotion.hover(isHovered), value: isHovered)
        )
        .anchorPreference(key: SelectionBoundsKey<String>.self, value: .bounds) { [opt.id: $0] }
        .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
        .onHover { hovering in
            if hovering {
                hoveredIconID = opt.id
            } else if hoveredIconID == opt.id {
                hoveredIconID = nil
            }
        }
        .onInstantPress {
            vm.selectAppIcon(id: opt.id)
        }
        .help("\(opt.title) · \(opt.subtitle)")
    }

    // MARK: 2. Download Settings
    private var settingsDownloadView: some View {
        let dirLabel = vm.settingsStore.settings.displayDownloadDirectory
        let connCount = vm.settingsStore.settings.maxConcurrentConnections
        let maxJobsCount = vm.settingsStore.settings.maxConcurrentDownloads

        return VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            EditorialSection(title: "存储与并发") {
                editorialRow(title: "下载目录") {
                    HStack(spacing: 8) {
                        if isSnapshotMode {
                            SettingsMenuLabel(text: dirLabel, icon: "folder")
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
                                SettingsMenuLabel(text: dirLabel, icon: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }

                        SettingsActionButton(title: "打开", tooltip: "在访达中打开下载目录") {
                            vm.openDownloadDirectoryInFinder()
                        }
                    }
                }

                hairline

                editorialRow(title: "同时下载") {
                    SettingsSegmentedControl(
                        options: [1, 2, 3, 4],
                        selection: maxJobsCount,
                        label: { "\($0)" },
                        isSnapshotMode: isSnapshotMode
                    ) { n in
                        vm.setMaxConcurrentDownloads(n)
                    }
                }

                hairline

                editorialRow(title: "分片线程") {
                    SettingsSegmentedControl(
                        options: [4, 8, 16],
                        selection: connCount,
                        label: { "\($0)" },
                        isSnapshotMode: isSnapshotMode
                    ) { n in
                        vm.setConcurrentConnections(n)
                    }
                }
            }

            EditorialSection(title: "网络与加速") {
                editorialRow(title: "代理策略") {
                    SettingsSegmentedControl(
                        options: ProxyPolicy.allCases,
                        selection: vm.settingsStore.settings.proxyPolicy,
                        label: \.displayName,
                        isSnapshotMode: isSnapshotMode
                    ) { option in
                        vm.setProxyPolicy(option)
                    }
                    .help("智能分流仅对海外受限网盘走系统代理")
                }

                hairline

                editorialRow(title: "加速凭证") {
                    if isSnapshotMode {
                        let configured = AccelerationCredentialKind.allCases
                            .filter { !vm.accelerationCredential(for: $0).isEmpty }
                            .map(\.displayName)
                        SettingsMenuLabel(text: configured.isEmpty ? "未配置" : configured.joined(separator: " / "))
                    } else {
                        HStack(spacing: 8) {
                            Menu {
                                ForEach(AccelerationCredentialKind.allCases) { kind in
                                    Button(action: { selectedCredentialKind = kind }) {
                                        HStack {
                                            Text(kind.displayName)
                                            if !vm.accelerationCredential(for: kind).isEmpty {
                                                Text("已填")
                                            }
                                            if selectedCredentialKind == kind {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                SettingsMenuLabel(text: selectedCredentialKind.displayName)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()

                            HStack(spacing: 4) {
                                SecureField(
                                    selectedCredentialKind.placeholder,
                                    text: Binding(
                                        get: { vm.accelerationCredential(for: selectedCredentialKind) },
                                        set: { vm.setAccelerationCredential($0, for: selectedCredentialKind) }
                                    )
                                )
                                .textFieldStyle(.plain)
                                .font(ChrysaFont.mono)
                                .foregroundColor(.t3TextMain)
                                .focused($isCredentialFocused)

                                if !vm.accelerationCredential(for: selectedCredentialKind).isEmpty {
                                    Button(action: {
                                        vm.setAccelerationCredential("", for: selectedCredentialKind)
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 11))
                                            .foregroundColor(.t3TextMuted)
                                    }
                                    .buttonStyle(.plain)
                                    .help("清除")
                                }
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 170, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .fill(isCredentialFocused ? Color.t3CanvasBg : Color.t3ControlFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .stroke(isCredentialFocused ? theme.accent.opacity(0.55) : Color.t3Divider, lineWidth: isCredentialFocused ? 1.2 : 0.8)
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: 3. Unpack Settings
    private var settingsUnpackView: some View {
        VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            EditorialSection(title: "解压行为") {
                EditorialToggleRow(
                    title: "解压后清理压缩包",
                    subtitle: nil,
                    isOn: vm.settingsStore.settings.deleteArchiveAfterUnpack,
                    onToggle: { vm.toggleDeleteArchiveAfterUnpack() }
                )
            }

            EditorialSection(title: "密码词典", trailingMeta: "共 \(vm.passwords.count) 条") {
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.t3TextMuted)

                        if !isSnapshotMode {
                            TextField("添加解压密码...", text: $vm.newPasswordInput)
                                .textFieldStyle(.plain)
                                .font(ChrysaFont.input)
                                .foregroundColor(.t3TextMain)
                                .focused($isPasswordInputFocused)
                                .onSubmit { vm.addPassword() }

                            if !vm.newPasswordInput.isEmpty {
                                Button(action: { vm.newPasswordInput = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundColor(.t3TextMuted)
                                }
                                .buttonStyle(.plain)
                                .help("清空")
                            }
                        } else {
                            Text("添加解压密码...")
                                .font(ChrysaFont.input)
                                .foregroundColor(.t3TextMuted)
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .fill(isPasswordInputFocused ? Color.t3CanvasBg : Color.t3ControlFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .stroke(isPasswordInputFocused ? theme.accent.opacity(0.55) : Color.t3Divider, lineWidth: isPasswordInputFocused ? 1.2 : 0.8)
                    )

                    SettingsActionButton(title: "添加", tooltip: "添加到自动试密词典", height: 34) {
                        vm.addPassword()
                    }
                }
                .padding(.top, 14)
                .padding(.bottom, 14)

                passwordTokenGrid(limit: isSnapshotMode ? 8 : nil)
            }
        }
    }

    private func passwordTokenGrid(limit: Int?) -> some View {
        let items: [(Int, String)] = {
            let all = Array(vm.passwords.enumerated()).map { ($0.offset, $0.element) }
            if let lim = limit {
                return Array(all.prefix(lim))
            }
            return all
        }()
        let columns = [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(items, id: \.0) { pair in
                let idx = pair.0
                let pwd = pair.1
                let isHovered = (hoveredPasswordIdx == idx)

                HStack(alignment: .center, spacing: 8) {
                    Text(pwd)
                        .font(ChrysaFont.mono)
                        .foregroundColor(.t3TextMain)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Button(action: { vm.removePassword(at: idx) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isHovered ? .t3TextMain : .t3TextMuted.opacity(0.75))
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .fill(isHovered ? Color.t3ControlHoverFill : Color.clear)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help("删除该密码")
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(isHovered ? Color.t3ControlHoverFill : Color.t3ControlFill)
                        .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .stroke(Color.t3Divider, lineWidth: 0.75)
                )
                .onHover { hovering in
                    if hovering {
                        hoveredPasswordIdx = idx
                    } else if hoveredPasswordIdx == idx {
                        hoveredPasswordIdx = nil
                    }
                }
            }
        }
    }

    // MARK: 4. Patch & CrossOver Settings
    private var settingsPatchView: some View {
        let bottlesLabel = vm.settingsStore.settings.displayBottlesDirectory
        let lang = vm.settingsStore.settings.defaultLanguage

        return VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            EditorialSection(title: "CrossOver 环境") {
                editorialRow(title: "容器目录") {
                    HStack(spacing: 8) {
                        if isSnapshotMode {
                            SettingsMenuLabel(text: bottlesLabel, icon: "folder")
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
                                SettingsMenuLabel(text: bottlesLabel, icon: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }

                        SettingsActionButton(title: "重扫", tooltip: "重新扫描已安装的 CrossOver 容器") {
                            vm.rescanCrossOverBottles(includePreviouslyRemoved: true)
                        }
                    }
                }

                hairline

                editorialRow(title: "默认语言") {
                    if isSnapshotMode {
                        SettingsMenuLabel(text: lang.displayName)
                    } else {
                        Menu {
                            ForEach(SteamLanguageOption.allCases) { opt in
                                Button(action: { vm.setDefaultLanguage(opt) }) {
                                    HStack {
                                        Text("\(opt.displayName) (\(opt.rawValue))")
                                        if lang == opt {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        } label: {
                            SettingsMenuLabel(text: lang.displayName)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
            }

            EditorialSection(title: "自动化流程") {
                EditorialToggleRow(
                    title: "自动流转",
                    subtitle: "下载 → 解压 → 补丁",
                    isOn: vm.settingsStore.settings.autoRelay,
                    onToggle: { vm.toggleAutoRelay() }
                )
            }
        }
    }

    // MARK: - Open Editorial Building Blocks
    private var hairline: some View {
        Rectangle()
            .fill(Color.t3Divider)
            .frame(height: 1)
    }

    private func editorialRow<Trailing: View>(
        title: String,
        subtitle: String? = nil,
        minHeight: CGFloat = 54,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ChrysaFont.settingLabel)
                    .foregroundColor(.t3TextMain)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ChrysaFont.helper)
                        .foregroundColor(.t3TextMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 8)
        .frame(minHeight: minHeight)
    }
}

// MARK: - Editorial Section (Recessed 12pt Eyebrow Header + 1px Hairline + High-Contrast 14pt Setting Rows)
private struct EditorialSection<Content: View>: View {
    let title: String
    var trailingMeta: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.appTheme) private var theme

    var body: some View {
        let headerColor: Color = theme.isDark
            ? Color.t3TextSub.opacity(0.84)
            : Color.t3TextMuted

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.45)
                    .foregroundColor(headerColor)

                Spacer(minLength: 8)

                if let trailingMeta, !trailingMeta.isEmpty {
                    Text(trailingMeta)
                        .font(.system(size: 12, weight: .regular).monospacedDigit())
                        .foregroundColor(.t3TextMuted.opacity(0.85))
                }
            }
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            content()
        }
    }
}

// MARK: - Open Toggle Row
private struct EditorialToggleRow: View {
    let title: String
    let subtitle: String?
    let isOn: Bool
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ChrysaFont.settingLabel)
                    .foregroundColor(.t3TextMain)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(ChrysaFont.helper)
                        .foregroundColor(.t3TextMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            T3ToggleSwitch(isOn: isOn)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .frame(minHeight: 54)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(isHovered ? Color.t3HoverBg : Color.clear)
                .animation(ChrysaMotion.hover(isHovered), value: isHovered)
        )
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onInstantPress(onToggle)
    }
}

// MARK: - Unified Rounded-Rect Settings Controls (Matches Global 8pt/6pt Concentric Radius Scale)
private struct SettingsMenuLabel: View {
    let text: String
    var icon: String? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.t3TextSub)
            }
            Text(text)
                .font(ChrysaFont.control.monospacedDigit())
                .foregroundColor(.t3TextMain)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.t3TextMuted)
        }
        .padding(.horizontal, 10)
        .frame(height: ChrysaMetrics.controlHeight)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(isHovered ? Color.t3ControlHoverFill : Color.t3ControlFill)
                .animation(ChrysaMotion.hover(isHovered), value: isHovered)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.9)
        )
        .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

private struct SettingsActionButton: View {
    let title: String
    var tooltip: String = ""
    var height: CGFloat = ChrysaMetrics.controlHeight
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ChrysaFont.control)
                .foregroundColor(isHovered ? .t3TextMain : .t3TextSub)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 12)
                .frame(height: height)
                .fixedSize()
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(isHovered ? Color.t3ControlHoverFill : Color.clear)
                        .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .stroke(isHovered ? Color.t3PillBorder : Color.t3GroupedCardBorder, lineWidth: 0.9)
                )
                .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

private struct SettingsSegmentedControl<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    var isSnapshotMode: Bool = false
    let onSelect: (Option) -> Void
    @State private var hoveredOption: Option? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let isSelected = (selection == option)
                let isHovered = (hoveredOption == option && !isSelected)

                Text(label(option))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular).monospacedDigit())
                    .foregroundColor(isSelected || isHovered ? .t3TextMain : .t3TextSub)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 10)
                    .frame(height: ChrysaMetrics.controlHeight - 4)
                    .background(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .fill(isHovered ? Color.t3HoverBg : Color.clear)
                            .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                    .anchorPreference(key: SelectionBoundsKey<Option>.self, value: .bounds) { [option: $0] }
                    .onHover { hovering in
                        if hovering {
                            hoveredOption = option
                        } else if hoveredOption == option {
                            hoveredOption = nil
                        }
                    }
                    .onInstantPress {
                        if selection != option {
                            onSelect(option)
                        }
                    }
            }
        }
        .backgroundPreferenceValue(SelectionBoundsKey<Option>.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[selection] {
                    let rect = proxy[anchor]
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(Color.t3ControlSelectedFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                .stroke(Color.t3ControlSelectedStroke, lineWidth: 0.8)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: selection)
                }
            }
        }
        .padding(2)
        .frame(height: ChrysaMetrics.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(Color.t3ControlTrackBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.8)
        )
        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: selection)
    }
}

// MARK: - Circular Color Swatch Button (Gliding Halo Rendered by Parent Overlay)
private enum AccentSelectionID: Hashable {
    case monochrome
    case followAppIcon
    case swatch(AccentSwatch)
}

private struct AccentDotButton<Content: View>: View {
    let selectionID: AccentSelectionID
    let isSelected: Bool
    let tooltip: String
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            content()
                .frame(width: 15, height: 15)
                .clipShape(Circle())
        }
        .frame(width: 21, height: 21)
        .overlay(
            Circle()
                .stroke((!isSelected && isHovered) ? Color.t3PillBorder : Color.clear, lineWidth: 1.0)
                .animation(ChrysaMotion.hover(isHovered), value: isHovered)
        )
        .anchorPreference(key: SelectionBoundsKey<AccentSelectionID>.self, value: .bounds) { [selectionID: $0] }
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .onInstantPress(action)
        .help(tooltip)
    }
}

// MARK: - Compact Inline Miniature Window Thumbnail (ChatGPT macOS `颜色模式` Signature Control)
private struct CompactAppearanceThumb: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let accent: Color
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        miniWindowMockup
            .frame(width: 66, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .stroke(
                        (!isSelected && isHovered) ? Color.t3PillBorder : Color.t3GroupedCardBorder,
                        lineWidth: 1.0
                    )
                    .animation(ChrysaMotion.hover(isHovered), value: isHovered)
            )
            .anchorPreference(key: SelectionBoundsKey<AppearanceMode>.self, value: .bounds) { [mode: $0] }
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
            .onHover { isHovered = $0 }
            .onInstantPress(action)
            .help(mode.displayName)
    }

    @ViewBuilder
    private var miniWindowMockup: some View {
        switch mode {
        case .light:
            miniWindowCanvas(isDarkSurface: false)
        case .dark:
            miniWindowCanvas(isDarkSurface: true)
        case .system:
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    miniWindowCanvas(isDarkSurface: true)
                    miniWindowCanvas(isDarkSurface: false)
                        .mask(
                            HStack(spacing: 0) {
                                Rectangle().frame(width: geo.size.width * 0.50)
                                Spacer(minLength: 0)
                            }
                        )
                }
            }
        }
    }

    private func miniWindowCanvas(isDarkSurface: Bool) -> some View {
        let winBg = isDarkSurface ? Color(red: 0.10, green: 0.108, blue: 0.125) : Color(red: 0.99, green: 0.99, blue: 1.0)
        let sideBg = isDarkSurface ? Color(red: 0.135, green: 0.145, blue: 0.17) : Color(red: 0.935, green: 0.942, blue: 0.96)
        let barStrong = isDarkSurface ? Color.white.opacity(0.45) : Color.black.opacity(0.32)
        let barSoft = isDarkSurface ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        let border = isDarkSurface ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
        let pillAccent: Color = {
            if theme.mode == .monochrome {
                return isDarkSurface ? Color.white.opacity(0.75) : Color(red: 0.14, green: 0.15, blue: 0.18)
            }
            return accent
        }()

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3.5) {
                HStack(spacing: 2) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 3.2, height: 3.2)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 3.2, height: 3.2)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 3.2, height: 3.2)
                }
                .padding(.bottom, 1)
                RoundedRectangle(cornerRadius: 1).fill(barStrong).frame(width: 11, height: 2.5)
                RoundedRectangle(cornerRadius: 1).fill(barSoft).frame(width: 9, height: 2)
                RoundedRectangle(cornerRadius: 1).fill(barSoft).frame(width: 10, height: 2)
                Spacer(minLength: 0)
            }
            .padding(5)
            .frame(width: 21, alignment: .leading)
            .background(sideBg)

            Rectangle().fill(border).frame(width: 0.6)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5).fill(barStrong).frame(width: 20, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(barSoft).frame(maxWidth: .infinity).frame(height: 5.5)
                HStack(spacing: 3) {
                    Circle().fill(pillAccent).frame(width: 4, height: 4)
                    RoundedRectangle(cornerRadius: 1).fill(barStrong).frame(width: 24, height: 2.5)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(pillAccent).frame(width: 12, height: 4.5)
                    RoundedRectangle(cornerRadius: 1.5).fill(barSoft).frame(width: 9, height: 4.5)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(winBg)
        }
    }
}
