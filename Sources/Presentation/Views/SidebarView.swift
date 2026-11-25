import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct SidebarView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var hoveredSidebarTab: StudioTab? = nil
    @State private var hoveredSettingsCategory: SettingsCategory? = nil
    @State private var isBackHovered = false
    @State private var isLaunchChevronHovered = false

    private var topBarHeight: CGFloat {
        isSnapshotMode ? 38 : 10
    }

    private var appVersionLabel: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        if let short, !short.isEmpty {
            return "Chrysa v\(short)"
        }
        return "Chrysa"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                WindowDragArea(isSnapshotMode: isSnapshotMode)

                if isSnapshotMode {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 1.0, green: 0.373, blue: 0.341)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.14), lineWidth: 0.5))
                        Circle().fill(Color(red: 1.0, green: 0.741, blue: 0.180)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.14), lineWidth: 0.5))
                        Circle().fill(Color(red: 0.153, green: 0.788, blue: 0.247)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.14), lineWidth: 0.5))
                    }
                    .padding(.leading, 18)
                }
            }
            .frame(height: topBarHeight)

            if vm.activeTab == .settings {
                settingsSidebarBody
            } else {
                workspaceSidebarBody
            }
        }
        .background(
            T3SidebarBackdropView(isSnapshotMode: isSnapshotMode)
                .ignoresSafeArea(.container, edges: .top)
        )
    }

    // MARK: - Dedicated Settings Navigation Sidebar (Linear / Vetta Pattern)
    private var settingsSidebarBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Back to Workspace Anchor
            Button(action: { vm.exitSettings() }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(isBackHovered ? .t3TextMain : .t3TextSub)
                    Text("返回")
                        .font(ChrysaFont.navItem)
                        .foregroundColor(isBackHovered ? .t3TextMain : .t3TextSub)
                    Spacer(minLength: 0)
                    Text("Esc")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.t3TextMuted.opacity(isBackHovered ? 0.85 : 0.5))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(isBackHovered ? Color.t3HoverBg : Color.clear)
                )
                .animation(ChrysaMotion.hover(isBackHovered), value: isBackHovered)
                .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .onHover { isBackHovered = $0 }
            .help("返回工作台 (Esc)")

            Text("设置")
                .font(.system(size: 20, weight: .semibold))
                .tracking(ChrysaTracking.pageTitle)
                .foregroundColor(.t3TextMain)
                .padding(.leading, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(SettingsCategory.allCases) { cat in
                    settingsCategoryRow(cat)
                }
            }
            .padding(.horizontal, 10)

            WindowDragArea(isSnapshotMode: isSnapshotMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(appVersionLabel)
                .font(ChrysaFont.helper.monospacedDigit())
                .foregroundColor(.t3TextMuted.opacity(0.75))
                .padding(.horizontal, 18)
                .padding(.bottom, 12)
        }
        .backgroundPreferenceValue(SettingsCategoryBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[vm.settingsCategory] {
                    let rect = proxy[anchor]
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(Color.t3SidebarActive)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: vm.settingsCategory)
                }
            }
        }
    }

    private func settingsCategoryRow(_ cat: SettingsCategory) -> some View {
        let isHighlighted = (vm.settingsCategory == cat)
        let isHovered = (hoveredSettingsCategory == cat && !isHighlighted)

        return HStack(alignment: .center, spacing: 8) {
            Group {
                switch cat {
                case .download:
                    T3SidebarIcon(tab: .download, placement: .sidebar(isActive: isHighlighted))
                case .unpack:
                    T3SidebarIcon(tab: .unpack, placement: .sidebar(isActive: isHighlighted))
                case .patch:
                    T3SidebarIcon(tab: .patch, placement: .sidebar(isActive: isHighlighted))
                case .appearance:
                    Image(systemName: cat.symbolName)
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: 15, weight: isHighlighted ? .semibold : .medium))
                        .imageScale(.medium)
                        .foregroundStyle(isHighlighted ? theme.iconActive : theme.iconInactive)
                        .frame(width: 20, height: 20, alignment: .center)
                }
            }

            Text(cat.rawValue)
                .font(isHighlighted ? ChrysaFont.navItemActive : ChrysaFont.navItem)
                .foregroundColor(
                    isHighlighted
                        ? .t3TextMain
                        : (isHovered ? .t3TextMain : .t3TextMain.opacity(0.86))
                )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: ChrysaMetrics.navRowHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .fill(isHovered ? Color.t3HoverBg : Color.clear)
                .animation(ChrysaMotion.hover(isHovered), value: isHovered)
        )
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

    // MARK: - Primary Workspace Sidebar
    private var workspaceSidebarBody: some View {
        let quickGames = vm.quickLaunchGames
        let showQuickCard = vm.isSidebarQuickLaunchExpanded && !quickGames.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            sidebarUtilityBar
                .padding(.horizontal, 4)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(Color.t3ControlTrackBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .stroke(Color.t3GroupedCardBorder, lineWidth: 0.8)
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

            VStack(spacing: 2) {
                sidebarRow(tab: .download, title: "下载", count: "\(vm.jobs(of: .download).filter { !$0.isArchived }.count)")
                sidebarRow(tab: .unpack,   title: "解压", count: "\(vm.jobs(of: .unpack).filter { !$0.isArchived }.count)")
                sidebarRow(tab: .patch,    title: "补丁", count: "\(vm.jobs(of: .patch).filter { !$0.isArchived }.count)")
                launchSidebarRow(hasQuickGames: !quickGames.isEmpty)
            }
            .padding(.horizontal, 10)

            if !quickGames.isEmpty {
                SidebarArcFavoritesGrid(
                    vm: vm,
                    games: quickGames,
                    isExpanded: showQuickCard,
                    isSnapshotMode: isSnapshotMode
                )
                .padding(.horizontal, 10)
            }

            WindowDragArea(isSnapshotMode: isSnapshotMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            sidebarRow(tab: .settings, title: "设置", count: "")
                .padding(.horizontal, 10)
                .frame(height: ChrysaMetrics.bottomBarHeight)
                .help("偏好设置 (⌘,)")
        }
        .backgroundPreferenceValue(SidebarTabBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[vm.activeTab] {
                    let rect = proxy[anchor]
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(Color.t3SidebarActive)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: vm.activeTab)
                }
            }
        }
    }

    private var sidebarUtilityBar: some View {
        HStack(alignment: .center, spacing: 0) {
            T3ToolbarIconButton(
                systemName: "plus",
                opticalSize: 14,
                tooltip: addActionTooltip
            ) {
                if vm.activeTab == .download {
                    vm.requestPrimaryInputFocus()
                } else if vm.activeTab == .launch {
                    vm.importLaunchGameFromPanel()
                } else {
                    vm.pickFileForActiveTab()
                }
            }

            Spacer(minLength: 0)

            T3ToolbarIconButton(
                systemName: "folder",
                opticalSize: 13.5,
                tooltip: "在访达中打开下载目录"
            ) {
                vm.openDownloadDirectoryInFinder()
            }

            Spacer(minLength: 0)

            T3ToolbarIconButton(
                systemName: "folder.badge.gearshape",
                opticalSize: 13.5,
                tooltip: "在访达中打开 CrossOver 容器目录"
            ) {
                vm.openBottlesDirectoryInFinder()
            }

            Spacer(minLength: 0)

            T3ToolbarIconButton(
                systemName: "key.horizontal",
                opticalSize: 13.5,
                isActive: vm.activeTab == .settings && vm.settingsCategory == .unpack,
                tooltip: "解压密码词典"
            ) {
                vm.openSettings(category: .unpack)
            }

            Spacer(minLength: 0)

            T3ToolbarIconButton(
                systemName: "apple.terminal",
                opticalSize: 13.5,
                isActive: vm.isLogDrawerPresented,
                showBadgeDot: vm.hasUnreadErrorLogs,
                tooltip: "显示或隐藏诊断日志 (⇧⌘L)"
            ) {
                vm.toggleLogDrawer()
            }
        }
    }

    private var addActionTooltip: String {
        switch vm.activeTab {
        case .download: return "新建下载任务 (⌘N)"
        case .unpack:   return "添加压缩包 (⌘N)"
        case .patch:    return "选择游戏目录 (⌘N)"
        case .launch:   return "导入本地游戏 (⌘N)"
        case .settings: return "新建任务 (⌘N)"
        }
    }

    private func launchSidebarRow(hasQuickGames: Bool) -> some View {
        let tab: StudioTab = .launch
        let isHighlighted = (vm.activeTab == tab)
        let isHovered = (hoveredSidebarTab == tab && !isHighlighted)

        return HStack(alignment: .center, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                T3SidebarIcon(tab: tab, placement: .sidebar(isActive: isHighlighted))

                Text("启动")
                    .font(isHighlighted ? ChrysaFont.navItemActive : ChrysaFont.navItem)
                    .foregroundColor(
                        isHighlighted
                            ? .t3TextMain
                            : (isHovered ? .t3TextMain : .t3TextMain.opacity(0.86))
                    )

                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.trailing, hasQuickGames ? 4 : 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onInstantPress {
                if vm.activeTab != tab {
                    vm.activeTab = tab
                }
            }

            if hasQuickGames {
                Button(action: {
                    vm.toggleSidebarQuickLaunch()
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isLaunchChevronHovered ? .t3TextMain : .t3TextMuted)
                        .rotationEffect(.degrees(vm.isSidebarQuickLaunchExpanded ? 0 : -90))
                        .animation(
                            isSnapshotMode ? nil : (vm.isSidebarQuickLaunchExpanded ? ChrysaMotion.foldOpen : ChrysaMotion.foldClose),
                            value: vm.isSidebarQuickLaunchExpanded
                        )
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                                .fill(isLaunchChevronHovered ? Color.t3ControlHoverFill : Color.clear)
                        )
                        .animation(ChrysaMotion.hover(isLaunchChevronHovered), value: isLaunchChevronHovered)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .onHover { isLaunchChevronHovered = $0 }
                .help(vm.isSidebarQuickLaunchExpanded ? "收起快捷启动" : "展开快捷启动")
            }
        }
        .frame(height: ChrysaMetrics.navRowHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .fill(isHovered ? Color.t3HoverBg : Color.clear)
        )
        .anchorPreference(key: SidebarTabBoundsKey.self, value: .bounds) { [tab: $0] }
        .onHover { hovering in
            if hovering {
                hoveredSidebarTab = tab
            } else if hoveredSidebarTab == tab {
                hoveredSidebarTab = nil
            }
        }
    }

    private func sidebarRow(tab: StudioTab, title: String, count: String) -> some View {
        let isHighlighted = (vm.activeTab == tab)
        let isHovered = (hoveredSidebarTab == tab && !isHighlighted)

        return HStack(alignment: .center, spacing: 8) {
            T3SidebarIcon(tab: tab, placement: .sidebar(isActive: isHighlighted))

            Text(title)
                .font(isHighlighted ? ChrysaFont.navItemActive : ChrysaFont.navItem)
                .foregroundColor(
                    isHighlighted
                        ? .t3TextMain
                        : (isHovered ? .t3TextMain : .t3TextMain.opacity(0.86))
                )

            Spacer(minLength: 0)

            if !count.isEmpty {
                Text(count)
                    .font(ChrysaFont.captionMedium.monospacedDigit())
                    .foregroundColor(isHighlighted ? .t3TextSub : .t3TextMuted)
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ChrysaMetrics.navRowHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .fill(isHovered ? Color.t3HoverBg : Color.clear)
        )
        .contentShape(Rectangle())
        .anchorPreference(key: SidebarTabBoundsKey.self, value: .bounds) { [tab: $0] }
        .onHover { hovering in
            if hovering {
                hoveredSidebarTab = tab
            } else if hoveredSidebarTab == tab {
                hoveredSidebarTab = nil
            }
        }
        .onInstantPress {
            if tab == .settings {
                vm.openSettings()
            } else if vm.activeTab != tab {
                vm.activeTab = tab
            }
        }
    }
}

// MARK: - Authentic Arc / Nook Favorites Grid (Flat Borderless Tiles + Off-Screen CI Glow + Critically-Damped Fold)
private struct SidebarArcFavoritesGrid: View {
    @ObservedObject var vm: StudioViewModel
    let games: [LaunchGame]
    let isExpanded: Bool
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var hoveredGame: LaunchGame? = nil
    @State private var dropTargetedGame: LaunchGame? = nil

    private let tileHeight: CGFloat = 46
    private let gridSpacing: CGFloat = 7
    private let topSpacing: CGFloat = 8

    private var columnCount: Int {
        min(max(games.count, 1), 3)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    private var rowCount: Int {
        let count = max(games.count, 1)
        return (count + columnCount - 1) / columnCount
    }

    private var gridHeight: CGFloat {
        CGFloat(rowCount) * tileHeight + CGFloat(max(rowCount - 1, 0)) * gridSpacing
    }

    private var activeHintGame: LaunchGame? {
        guard isExpanded else { return nil }
        return dropTargetedGame ?? hoveredGame
    }

    private var expandedHeight: CGFloat {
        let hintHeight: CGFloat = (activeHintGame != nil) ? 22 : 0
        return topSpacing + gridHeight + hintHeight
    }

    var body: some View {
        let foldAnim: Animation? = isSnapshotMode ? nil : (isExpanded ? ChrysaMotion.foldOpen : ChrysaMotion.foldClose)

        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: topSpacing)

            gridBody
                .opacity(isExpanded ? 1.0 : 0.0)
                .scaleEffect(isExpanded ? 1.0 : 0.96, anchor: .top)
                .offset(y: isExpanded ? 0 : -6)

            if let hintGame = activeHintGame {
                let isDrop = (dropTargetedGame?.id == hintGame.id)
                HStack(spacing: 4) {
                    Image(systemName: isDrop ? "puzzlepiece.extension" : "play.fill")
                        .font(.system(size: isDrop ? 9.5 : 8, weight: .semibold))
                        .foregroundColor(isDrop ? theme.accent : .t3TextMuted)
                    Text(isDrop ? "松开安装补丁 · \(hintGame.title)" : hintGame.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isDrop ? theme.accent : .t3TextSub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !isDrop {
                        Text(hintGame.lastPlayedDisplayText())
                            .font(.system(size: 10, weight: .regular).monospacedDigit())
                            .foregroundColor(.t3TextMuted)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.top, 6)
                .frame(height: 22, alignment: .center)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: isExpanded ? expandedHeight : 0, alignment: .top)
        .clipped()
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(foldAnim, value: isExpanded)
        .animation(isSnapshotMode ? nil : .easeOut(duration: 0.14), value: activeHintGame?.id)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                hoveredGame = nil
                dropTargetedGame = nil
            }
        }
    }

    private var gridBody: some View {
        LazyVGrid(columns: columns, spacing: gridSpacing) {
            ForEach(games) { game in
                ArcFavoriteTile(
                    vm: vm,
                    game: game,
                    tileHeight: tileHeight,
                    isHovered: hoveredGame?.id == game.id,
                    isDropTargeted: dropTargetedGame?.id == game.id,
                    isSnapshotMode: isSnapshotMode,
                    onHoverChange: { hovering in
                        if hovering {
                            hoveredGame = game
                        } else if hoveredGame?.id == game.id {
                            hoveredGame = nil
                        }
                    },
                    onDropTargetChange: { targeted in
                        if targeted {
                            dropTargetedGame = game
                        } else if dropTargetedGame?.id == game.id {
                            dropTargetedGame = nil
                        }
                    }
                )
            }
        }
    }
}

private struct ArcFavoriteTile: View {
    @ObservedObject var vm: StudioViewModel
    let game: LaunchGame
    let tileHeight: CGFloat
    let isHovered: Bool
    let isDropTargeted: Bool
    let isSnapshotMode: Bool
    let onHoverChange: (Bool) -> Void
    let onDropTargetChange: (Bool) -> Void
    @Environment(\.appTheme) private var theme
    @State private var glowImage: CGImage? = nil

    // Pure flat borderless fill matching Arc / Nook measured ratios (no specular bevels, no gradients)
    private var tileFill: Color {
        if isDropTargeted {
            return theme.accent.opacity(theme.isDark ? 0.18 : 0.12)
        }
        if theme.isDark {
            return Color.white.opacity(isHovered ? 0.115 : 0.065)
        } else {
            return Color.black.opacity(isHovered ? 0.085 : 0.048)
        }
    }

    // Exact Nook / Arc FaviconGlow opacities: subtle wash in Dark, zero at rest in Light
    private var glowOpacity: Double {
        if theme.isDark {
            return isHovered ? 0.30 : 0.20
        } else {
            return isHovered ? 0.10 : 0.0
        }
    }

    var body: some View {
        let icon = vm.launchGameIcon(for: game)
        let iconSignature = StudioViewModel.launchGameIconSignature(for: game)
        let shape = RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
        let dropBinding = Binding<Bool>(
            get: { isDropTargeted },
            set: { onDropTargetChange($0) }
        )

        Button(action: { vm.launchGame(game) }) {
            ZStack {
                shape
                    .fill(tileFill)
                    .animation(isSnapshotMode ? nil : ChrysaMotion.hover(isHovered), value: isHovered)

                // Off-screen CoreImage CIGaussianBlur atmospheric icon wash (only for real icons)
                if let glowImage {
                    Color.clear
                        .overlay {
                            Image(decorative: glowImage, scale: 2.0)
                                .resizable()
                                .scaledToFill()
                        }
                        .clipped()
                        .opacity(glowOpacity)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.hover(isHovered), value: isHovered)
                }

                if isDropTargeted {
                    shape
                        .strokeBorder(theme.accent, lineWidth: 1.5)
                }

                ArcGameGlyph(
                    icon: icon,
                    title: game.title,
                    isHovered: isHovered
                )
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .contentShape(shape)
        }
        .buttonStyle(ArcTilePressStyle())
        .onHover { onHoverChange($0) }
        .conditionalDrop(enabled: !isSnapshotMode, of: [.fileURL], isTargeted: dropBinding) { providers in
            vm.handleDroppedPatchProviders(providers, for: game)
        }
        .help("启动「\(game.title)」 · 可直接拖入补丁包")
        .contextMenu {
            Button(action: { vm.launchGame(game) }) {
                Label("启动游戏", systemImage: "play")
            }
            Button(action: { vm.beginEditingLaunchGame(game) }) {
                Label("编辑游戏与图标...", systemImage: "photo")
            }
            if vm.hasAccessibleDirectory(for: game) {
                Button(action: { vm.openLaunchGameDirectory(game) }) {
                    Label("打开游戏目录", systemImage: "folder")
                }
            }
            if let bottlePath = vm.resolvedBottlePath(for: game) {
                Button(action: { vm.revealLaunchGameBottle(game, bottlePath: bottlePath) }) {
                    Label("打开 / 定位容器", systemImage: "shippingbox")
                }
            }
        }
        .task(id: iconSignature) {
            guard !isSnapshotMode else { return }
            await vm.loadLaunchGameIconIfNeeded(for: game)
            if let loaded = vm.launchGameIcon(for: game),
               let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                glowImage = await ArcIconGlowCache.shared.glow(forKey: iconSignature, source: cg)
            } else {
                glowImage = nil
            }
        }
    }
}

private struct ArcTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(ChrysaMotion.press, value: configuration.isPressed)
    }
}

/// Off-screen CoreImage CIGaussianBlur cache matching Arc / Nook `FaviconGlow` (`radius = side * 0.25`, `clampedToExtent`)
private actor ArcIconGlowCache {
    static let shared = ArcIconGlowCache()

    private let limit = 64
    private var cache: [String: CGImage] = [:]
    private var order: [String] = []
    private let context = CIContext()

    func glow(forKey key: String, source: CGImage) -> CGImage? {
        if let hit = cache[key] { return hit }
        guard let rendered = render(source) else { return nil }
        cache[key] = rendered
        order.append(key)
        if order.count > limit {
            cache[order.removeFirst()] = nil
        }
        return rendered
    }

    private func render(_ source: CGImage) -> CGImage? {
        let side: CGFloat = 96
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        let input = CIImage(cgImage: source)
        let fill = max(side / input.extent.width, side / input.extent.height)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let centered = scaled.transformed(by: CGAffineTransform(
            translationX: (side - scaled.extent.width) / 2 - scaled.extent.minX,
            y: (side - scaled.extent.height) / 2 - scaled.extent.minY
        ))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = centered.clampedToExtent()
        blur.radius = Float(side * 0.25)
        guard let out = blur.outputImage else { return nil }
        return context.createCGImage(out, from: rect)
    }
}

private struct ArcGameGlyph: View {
    let icon: NSImage?
    let title: String
    let isHovered: Bool

    private var monogram: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
        } else {
            Text(monogram)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(isHovered ? .t3TextMain : .t3TextSub)
        }
    }
}
