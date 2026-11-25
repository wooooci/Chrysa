import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

// MARK: - Editorial Centered Settings View (Linear / Vetta / Cursor Spacious Architecture)
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
                            .padding(.top, 14)
                            .padding(.bottom, 28)
                    }
                    .clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    centeredSettingsColumn
                        .padding(.top, 14)
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
                // Editorial Category Page Header
                VStack(alignment: .leading, spacing: 5) {
                    Text(vm.settingsCategory.rawValue)
                        .font(ChrysaFont.settingsTitle)
                        .tracking(ChrysaTracking.pageTitle)
                        .foregroundColor(.t3TextMain)

                    Text(vm.settingsCategory.pageDescription)
                        .font(ChrysaFont.input)
                        .foregroundColor(.t3TextMuted)
                        .lineLimit(2)
                }
                .padding(.bottom, 18)

                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1)
                    .padding(.bottom, 26)

                settingsCategoryBody
            }
            .frame(maxWidth: ChrysaMetrics.settingsMaxWidth, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 36)
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

    // MARK: 1. Appearance Settings (Generous 30pt Section Separation & Distinct Roles)
    private var settingsAppearanceView: some View {
        let mascotColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)
        let selectedID = vm.settingsStore.settings.selectedIconID
        let variant = vm.settingsStore.settings.selectedIconVariant
        let activeMascot = vm.mascotTheme
        let activeAppearance = vm.appearanceMode
        let selectedIconTitle = vm.iconOptions.first(where: { $0.id == selectedID })?.title
            .components(separatedBy: " · ").last ?? theme.logoColorTitle

        return VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            // Section 1: Appearance Mode Miniature Windows
            SettingsSection(title: "外观模式") {
                HStack(spacing: 14) {
                    ForEach(AppearanceMode.allCases) { mode in
                        AppearanceModeWindowCard(
                            mode: mode,
                            isSelected: activeAppearance == mode,
                            accent: theme.accent
                        ) {
                            vm.setAppearanceMode(mode)
                        }
                    }
                }
            }

            // Section 2: Theme & Live Preview Stage
            SettingsSection(
                title: "主题强调色",
                description: "控制进度环、开关及主要操作的高亮色调"
            ) {
                T3SettingsGroupCard {
                    liveAppearancePreviewStage

                    cardDivider

                    groupedRow(
                        title: "强调色",
                        subtitle: theme.activeAccentTitle,
                        minHeight: 58
                    ) {
                        accentSwatchStrip
                    }
                }
            }

            // Section 3: Dedicated App Icon Section (No Longer Squeezed Under Color Dots)
            SettingsSection(
                title: "应用图标",
                description: "切换程序坞与访达中显示的应用图标风格",
                trailingMeta: selectedIconTitle
            ) {
                T3SettingsGroupCard {
                    HStack(spacing: 0) {
                        ForEach(Array(vm.iconOptions.enumerated()), id: \.element.id) { idx, opt in
                            if idx > 0 {
                                Spacer(minLength: 6)
                            }
                            compactAppIconButton(opt, isSelected: selectedID == opt.id, variant: variant)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
            }

            // Section 4: Dedicated Companion Mascot Section
            SettingsSection(
                title: "桌面伴生灵",
                description: "在下载与处理过程中陪伴你的轻量动态伙伴",
                trailingMeta: activeMascot.displayName
            ) {
                LazyVGrid(columns: mascotColumns, spacing: 12) {
                    ForEach(MascotTheme.allCases) { option in
                        VStack(alignment: .leading, spacing: 7) {
                            MascotThemeCardView(
                                option: option,
                                isSelected: activeMascot == option,
                                isSnapshotMode: isSnapshotMode,
                                cardHeight: ChrysaMetrics.showcaseCardHeight
                            ) {
                                vm.setMascotTheme(option)
                            }
                            Text(option.displayName)
                                .font(.system(size: 12, weight: activeMascot == option ? .medium : .regular))
                                .foregroundColor(activeMascot == option ? .t3TextMain : .t3TextMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    /// Airy 96pt preview stage with generous breathing room around a centered simulated task row (Vetta-grade spacing)
    private var liveAppearancePreviewStage: some View {
        ZStack {
            Canvas { ctx, size in
                let step: CGFloat = 16
                let dotColor = theme.isDark
                    ? Color.white.opacity(0.05)
                    : Color.black.opacity(0.05)
                var y: CGFloat = 10
                while y < size.height {
                    var x: CGFloat = 12
                    while x < size.width {
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                            with: .color(dotColor)
                        )
                        x += step
                    }
                    y += step
                }
            }

            // Floating compact preview item centered inside open negative space
            HStack(alignment: .center, spacing: 10) {
                T3PieRing(progress: 0.68, size: 15, color: theme.accent)

                Text("Esoteric_Ebb_Build_1402.7z")
                    .font(ChrysaFont.rowTitle)
                    .foregroundColor(.t3TextMain)
                    .lineLimit(1)

                T3OutlinedPill(text: "48.4 MB/s")

                Spacer(minLength: 10)

                T3ToggleSwitch(isOn: true)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .frame(maxWidth: 440)
            .background(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .fill(Color.t3CardBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .stroke(Color.t3CardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
        .frame(height: 96)
        .background(Color.t3PreviewWellBg)
    }

    private var accentSwatchStrip: some View {
        let currentMode = vm.accentColorMode
        let currentSwatch = vm.accentSwatch

        return HStack(spacing: 9) {
            AccentDotButton(
                isSelected: currentMode == .monochrome,
                ringColor: theme.isDark ? Color.white.opacity(0.65) : Color.black.opacity(0.65),
                tooltip: "纯色墨韵"
            ) {
                ZStack {
                    Circle().fill(Color(red: 0.12, green: 0.13, blue: 0.15))
                    Path { p in
                        p.move(to: CGPoint(x: 8, y: 0))
                        p.addArc(center: CGPoint(x: 8, y: 8), radius: 8, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                        p.closeSubpath()
                    }
                    .fill(Color(red: 0.92, green: 0.93, blue: 0.95))
                }
                .overlay(Circle().stroke(Color.t3GroupedCardBorder, lineWidth: 0.7))
            } action: {
                vm.setAccentColorMode(.monochrome)
            }

            AccentDotButton(
                isSelected: currentMode == .followAppIcon,
                ringColor: theme.logoAccent,
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
                .frame(width: 1, height: 14)
                .padding(.horizontal, 2)

            ForEach(AccentSwatch.allCases) { swatch in
                let col = AppThemePalette.swatchColor(for: swatch, colorScheme: colorScheme)
                let selected = (currentMode == .custom && currentSwatch == swatch)
                AccentDotButton(
                    isSelected: selected,
                    ringColor: col,
                    tooltip: swatch.displayName
                ) {
                    Circle().fill(col)
                } action: {
                    vm.setCustomAccentSwatch(swatch)
                }
            }
        }
    }

    private func compactAppIconButton(_ opt: AppIconOption, isSelected: Bool, variant: String) -> some View {
        let isHovered = (hoveredIconID == opt.id && !isSelected)
        let ringColor: Color = isSelected
            ? (theme.mode == .monochrome ? Color.t3TextMain.opacity(theme.isDark ? 0.75 : 0.85) : theme.accent)
            : (isHovered ? Color.t3PillBorder : Color.clear)

        return ZStack {
            if let nsImg = vm.iconPreviewImage(id: opt.id, variant: variant) {
                Image(nsImage: nsImg)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
            } else {
                let previewTint = AppThemePalette.logoAccentColor(for: opt.id, colorScheme: colorScheme)
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .fill(previewTint.opacity(0.22))
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                            .stroke(previewTint.opacity(0.55), lineWidth: 1)
                    )
                    .frame(width: 38, height: 38)
            }
        }
        .padding(3)
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                .stroke(ringColor, lineWidth: isSelected ? 1.8 : 1.0)
        )
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
            SettingsSection(title: "存储与并发") {
                T3SettingsGroupCard {
                    groupedRow(title: "下载目录", subtitle: "新建下载任务的默认保存位置") {
                        if isSnapshotMode {
                            T3MenuPill(text: dirLabel, icon: "folder")
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
                                T3MenuPill(text: dirLabel, icon: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }

                    cardDivider

                    groupedRow(title: "同时下载", subtitle: "队列中允许并行执行的下载任务上限") {
                        if isSnapshotMode {
                            T3MenuPill(text: "\(maxJobsCount) 个任务")
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
                                T3MenuPill(text: "\(maxJobsCount) 个任务")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }

                    cardDivider

                    groupedRow(title: "并发连接", subtitle: "单文件多分片拉取的最大线程数") {
                        if isSnapshotMode {
                            T3MenuPill(text: "\(connCount) 线程")
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
                                T3MenuPill(text: "\(connCount) 线程")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                }
            }

            SettingsSection(title: "网络与加速") {
                T3SettingsGroupCard {
                    groupedRow(title: "代理策略", subtitle: "智能分流仅对海外受限网盘走系统代理") {
                        let policy = vm.settingsStore.settings.proxyPolicy
                        HStack(spacing: 2) {
                            ForEach(ProxyPolicy.allCases) { option in
                                let selected = (policy == option)
                                Button(action: { vm.setProxyPolicy(option) }) {
                                    Text(option.displayName)
                                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                                        .foregroundColor(selected ? .t3TextMain : .t3TextSub)
                                        .padding(.horizontal, 9)
                                        .frame(height: ChrysaMetrics.controlHeight - 4)
                                        .background(
                                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                                .fill(selected ? Color.t3ControlSelectedFill : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                                .stroke(selected ? Color.t3ControlSelectedStroke : Color.clear, lineWidth: 0.8)
                                        )
                                }
                                .buttonStyle(.plain)
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
                    }

                    cardDivider

                    groupedRow(title: "加速凭证", subtitle: "可选填入 Pixeldrain / Debrid API 密钥") {
                        if isSnapshotMode {
                            let configured = AccelerationCredentialKind.allCases
                                .filter { !vm.accelerationCredential(for: $0).isEmpty }
                                .map(\.displayName)
                            T3MenuPill(text: configured.isEmpty ? "未配置" : configured.joined(separator: " / "))
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
                                    T3MenuPill(text: selectedCredentialKind.displayName)
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
                                .padding(.horizontal, 8)
                                .frame(width: 162, height: ChrysaMetrics.controlHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                        .fill(isCredentialFocused ? Color.t3CanvasBg : Color.t3PreviewWellBg)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                        .stroke(isCredentialFocused ? theme.accent.opacity(0.55) : Color.t3GroupedCardBorder, lineWidth: isCredentialFocused ? 1.2 : 1)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 3. Unpack Settings
    private var settingsUnpackView: some View {
        VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            SettingsSection(title: "解压行为") {
                T3SettingsGroupCard {
                    T3GroupedToggleRow(
                        title: "解压后清理压缩包",
                        subtitle: "解压完整校验成功后自动移除源压缩包以释放磁盘空间",
                        isOn: vm.settingsStore.settings.deleteArchiveAfterUnpack,
                        onToggle: { vm.toggleDeleteArchiveAfterUnpack() }
                    )
                }
            }

            SettingsSection(
                title: "密码词典",
                description: "遇到加密压缩包时按顺序自动尝试以下常用密码",
                trailingMeta: "共 \(vm.passwords.count) 条"
            ) {
                T3SettingsGroupCard {
                    HStack(alignment: .center, spacing: 8) {
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

                        T3InlineActionButton(title: "+ 添加", tooltip: "添加到自动试密词典") {
                            vm.addPassword()
                        }
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, 10)
                    .frame(height: 42)
                    .background(isPasswordInputFocused ? Color.t3CanvasBg : Color.t3PreviewWellBg)

                    cardDivider

                    passwordRows(limit: isSnapshotMode ? 6 : nil)
                }
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
            ForEach(Array(items.enumerated()), id: \.element.0) { pos, pair in
                let idx = pair.0
                let pwd = pair.1
                let isHovered = (hoveredPasswordIdx == idx)
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 14, alignment: .center)

                    Text(pwd)
                        .font(ChrysaFont.mono)
                        .foregroundColor(.t3TextMain)

                    Spacer()

                    Button(action: { vm.removePassword(at: idx) }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(isHovered ? .t3TextMain : .t3TextMuted)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .fill(isHovered ? Color.t3ControlHoverFill : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("删除该密码")
                }
                .padding(.horizontal, 18)
                .frame(height: 40)
                .background(isHovered ? Color.t3HoverBg : Color.clear)
                .onHover { hovering in
                    if hovering {
                        hoveredPasswordIdx = idx
                    } else if hoveredPasswordIdx == idx {
                        hoveredPasswordIdx = nil
                    }
                }

                if pos < items.count - 1 {
                    cardDivider
                }
            }
        }
    }

    // MARK: 4. Patch & CrossOver Settings (Split Clearly into Environment vs Automation)
    private var settingsPatchView: some View {
        let bottlesLabel = vm.settingsStore.settings.displayBottlesDirectory
        let lang = vm.settingsStore.settings.defaultLanguage

        return VStack(alignment: .leading, spacing: ChrysaMetrics.settingsSectionGap) {
            SettingsSection(title: "CrossOver 环境") {
                T3SettingsGroupCard {
                    groupedRow(title: "容器目录", subtitle: "扫描和新建 CrossOver 游戏容器的根目录") {
                        if isSnapshotMode {
                            T3MenuPill(text: bottlesLabel, icon: "folder")
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
                                T3MenuPill(text: bottlesLabel, icon: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }

                    cardDivider

                    groupedRow(title: "默认语言", subtitle: "补丁写入 Goldberg 配置时使用的游戏内语言") {
                        if isSnapshotMode {
                            T3MenuPill(text: lang.displayName)
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
                                T3MenuPill(text: lang.displayName)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                }
            }

            SettingsSection(title: "自动化流程") {
                T3SettingsGroupCard {
                    T3GroupedToggleRow(
                        title: "自动流转",
                        subtitle: "下载完成自动解压，并在解压完成后自动执行补丁入库",
                        isOn: vm.settingsStore.settings.autoRelay,
                        onToggle: { vm.toggleAutoRelay() }
                    )
                }
            }
        }
    }

    // MARK: - Grouped Card Layout Building Blocks
    private var cardDivider: some View {
        Rectangle()
            .fill(Color.t3Divider)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }

    private func groupedRow<Trailing: View>(
        title: String,
        subtitle: String? = nil,
        minHeight: CGFloat = ChrysaMetrics.settingRowHeight,
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: minHeight)
    }
}

// MARK: - Editorial Section Wrapper (Clear Title / Description / Content Separation)
private struct SettingsSection<Content: View>: View {
    let title: String
    var description: String? = nil
    var trailingMeta: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(ChrysaFont.sectionTitle)
                        .tracking(ChrysaTracking.sectionTitle)
                        .foregroundColor(.t3TextMain)

                    Spacer(minLength: 8)

                    if let trailingMeta, !trailingMeta.isEmpty {
                        Text(trailingMeta)
                            .font(ChrysaFont.caption.monospacedDigit())
                            .foregroundColor(.t3TextMuted)
                    }
                }

                if let description, !description.isEmpty {
                    Text(description)
                        .font(ChrysaFont.helper)
                        .foregroundColor(.t3TextMuted)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 2)

            content()
        }
    }
}

// MARK: - Grouped Card Container (Pure-Flat Surface + 1px Crisp Hairline)
private struct T3SettingsGroupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .background(Color.t3GroupedCardBg)
        .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 1)
        )
    }
}

private struct T3GroupedToggleRow: View {
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: ChrysaMetrics.settingRowHeight)
        .background(isHovered ? Color.t3HoverBg : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onInstantPress(onToggle)
    }
}

// MARK: - Circular Color Swatch Button with Double-Ring Selection Halo
private struct AccentDotButton<Content: View>: View {
    let isSelected: Bool
    let ringColor: Color
    let tooltip: String
    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            content()
                .frame(width: 16, height: 16)
                .clipShape(Circle())
        }
        .frame(width: 22, height: 22)
        .overlay(
            Circle()
                .stroke(
                    isSelected ? ringColor : (isHovered ? Color.t3PillBorder : Color.clear),
                    lineWidth: isSelected ? 1.6 : 1.0
                )
        )
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .onInstantPress(action)
        .help(tooltip)
    }
}

// MARK: - Miniature Window Appearance Mode Card (Spacious 86pt Proportions)
private struct AppearanceModeWindowCard: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let accent: Color
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                backdropGradient
                miniWindowMockup
                    .padding(.top, 13)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 9)
            }
            .frame(maxWidth: .infinity)
            .frame(height: ChrysaMetrics.showcaseCardHeight)
            .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                    .stroke(
                        isSelected
                            ? (theme.mode == .monochrome ? Color.t3TextMain.opacity(theme.isDark ? 0.72 : 0.80) : theme.accent)
                            : (isHovered ? Color.t3PillBorder : Color.t3GroupedCardBorder),
                        lineWidth: isSelected ? 1.6 : 1.0
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    ZStack {
                        Circle()
                            .fill(theme.isDark ? Color.black.opacity(0.68) : Color(red: 0.12, green: 0.13, blue: 0.16))
                            .frame(width: 17, height: 17)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(theme.isDark ? 0.22 : 0.0), lineWidth: 0.75)
                            )
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(7)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
            .onHover { isHovered = $0 }
            .onInstantPress(action)

            Text(mode.displayName)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .t3TextMain : .t3TextMuted)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var backdropGradient: some View {
        switch mode {
        case .system:
            LinearGradient(
                colors: [
                    Color(red: 0.76, green: 0.80, blue: 0.88),
                    Color(red: 0.36, green: 0.34, blue: 0.44),
                    Color(red: 0.72, green: 0.48, blue: 0.24)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .light:
            LinearGradient(
                colors: [
                    Color(red: 0.84, green: 0.87, blue: 0.93),
                    Color(red: 0.91, green: 0.92, blue: 0.95),
                    Color(red: 0.93, green: 0.86, blue: 0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .dark:
            LinearGradient(
                colors: [
                    Color(red: 0.24, green: 0.28, blue: 0.56),
                    Color(red: 0.14, green: 0.15, blue: 0.24),
                    Color(red: 0.62, green: 0.36, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
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
        let winBg = isDarkSurface ? Color(red: 0.08, green: 0.085, blue: 0.10) : Color.white
        let sideBg = isDarkSurface ? Color(red: 0.11, green: 0.115, blue: 0.14) : Color(red: 0.95, green: 0.96, blue: 0.975)
        let barStrong = isDarkSurface ? Color.white.opacity(0.42) : Color.black.opacity(0.32)
        let barSoft = isDarkSurface ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        let border = isDarkSurface ? Color.white.opacity(0.14) : Color.black.opacity(0.12)
        let pillAccent: Color = {
            if theme.mode == .monochrome {
                return isDarkSurface ? Color.white.opacity(0.75) : Color(red: 0.14, green: 0.15, blue: 0.18)
            }
            return accent
        }()

        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4.5) {
                HStack(spacing: 2.5) {
                    Circle().fill(Color(red: 1.0, green: 0.37, blue: 0.34)).frame(width: 4, height: 4)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 4, height: 4)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.25)).frame(width: 4, height: 4)
                }
                .padding(.bottom, 2)
                RoundedRectangle(cornerRadius: 1.5).fill(barStrong).frame(width: 24, height: 3.5)
                RoundedRectangle(cornerRadius: 1.5).fill(barSoft).frame(width: 20, height: 3)
                RoundedRectangle(cornerRadius: 1.5).fill(barSoft).frame(width: 22, height: 3)
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(width: 40, alignment: .leading)
            .background(sideBg)

            Rectangle().fill(border).frame(width: 0.75)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(barStrong).frame(width: 38, height: 4)
                RoundedRectangle(cornerRadius: 2.5).fill(barSoft).frame(maxWidth: .infinity).frame(height: 9)
                HStack(spacing: 4) {
                    Circle().fill(pillAccent).frame(width: 5, height: 5)
                    RoundedRectangle(cornerRadius: 1.5).fill(barStrong).frame(width: 50, height: 3)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(pillAccent).frame(width: 20, height: 6)
                    RoundedRectangle(cornerRadius: 2).fill(barSoft).frame(width: 15, height: 6)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(winBg)
        }
        .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .stroke(border, lineWidth: 0.75)
        )
    }
}
