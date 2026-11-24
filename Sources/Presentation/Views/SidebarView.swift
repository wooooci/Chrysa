import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var hoveredSidebarTab: StudioTab? = nil
    @State private var isLaunchChevronHovered = false

    private var topBarHeight: CGFloat {
        isSnapshotMode ? 38 : 10
    }

    var body: some View {
        let quickGames = vm.quickLaunchGames
        let showQuickCard = vm.isSidebarQuickLaunchExpanded && !quickGames.isEmpty

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

            VStack(spacing: 2) {
                sidebarRow(tab: .download, title: "下载", count: "\(vm.jobs(of: .download).filter { !$0.isArchived }.count)")
                sidebarRow(tab: .unpack,   title: "解压", count: "\(vm.jobs(of: .unpack).filter { !$0.isArchived }.count)")
                sidebarRow(tab: .patch,    title: "补丁", count: "\(vm.jobs(of: .patch).filter { !$0.isArchived }.count)")

                Spacer().frame(height: 14)

                launchSidebarRow(hasQuickGames: !quickGames.isEmpty)
            }
            .padding(.horizontal, 10)

            if showQuickCard {
                SidebarQuickLaunchDockCard(
                    vm: vm,
                    games: quickGames,
                    isSnapshotMode: isSnapshotMode
                )
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else {
                WindowDragArea(isSnapshotMode: isSnapshotMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            sidebarRow(tab: .settings, title: "设置", count: "")
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
                .help("偏好设置 (⌘,)")
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.90), value: showQuickCard)
        .backgroundPreferenceValue(SidebarTabBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[vm.activeTab] {
                    let rect = proxy[anchor]
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(Color.t3SidebarActive)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(.spring(response: 0.18, dampingFraction: 0.92), value: vm.activeTab)
                }
            }
        }
        .background(T3SidebarBackdropView(isSnapshotMode: isSnapshotMode))
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

                Text("\(vm.launchGames.count)")
                    .font(ChrysaFont.captionMedium.monospacedDigit())
                    .foregroundColor(isHighlighted ? .t3TextSub : .t3TextMuted)
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
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.90)) {
                        vm.toggleSidebarQuickLaunch()
                    }
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(isLaunchChevronHovered ? .t3TextMain : .t3TextMuted)
                        .rotationEffect(.degrees(vm.isSidebarQuickLaunchExpanded ? 0 : -90))
                        .frame(width: 20, height: 20)
                        .background(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                                .fill(isLaunchChevronHovered ? Color.t3ControlHoverFill : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .onHover { isLaunchChevronHovered = $0 }
                .help(vm.isSidebarQuickLaunchExpanded ? "收起快捷启动坞" : "展开快捷启动坞")
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
            if vm.activeTab != tab {
                vm.activeTab = tab
            }
        }
    }
}

// MARK: - Full-Height Sidebar Quick-Launch Dock Card (Scrollable Icon Wall + Anchored Continue-Playing Spotlight)
private struct SidebarQuickLaunchDockCard: View {
    @ObservedObject var vm: StudioViewModel
    let games: [LaunchGame]
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var hoveredGame: LaunchGame? = nil
    @State private var dropTargetedGame: LaunchGame? = nil
    @State private var isPlayButtonHovered = false
    @State private var isFolderButtonHovered = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    private var spotlightGame: LaunchGame? {
        dropTargetedGame ?? hoveredGame ?? games.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Upper Region: Scrollable All-Games Icon Wall
            if isSnapshotMode {
                iconGridContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    iconGridContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            // Lower Region: Anchored "Continue Playing / Hover Spotlight" Panel
            if let focused = spotlightGame {
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1)

                spotlightPanel(for: focused)
            }
        }
        .background(theme.isDark ? Color.white.opacity(0.038) : Color.black.opacity(0.028))
        .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 1)
        )
    }

    private var iconGridContent: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(games) { game in
                QuickLaunchIconTile(
                    vm: vm,
                    game: game,
                    isHovered: hoveredGame?.id == game.id,
                    isDropTargeted: dropTargetedGame?.id == game.id,
                    isFocused: spotlightGame?.id == game.id && hoveredGame == nil && dropTargetedGame == nil,
                    isSnapshotMode: isSnapshotMode,
                    onHoverChange: { isHovering in
                        if isHovering {
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
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
    }

    private func spotlightPanel(for game: LaunchGame) -> some View {
        let isDrop = (dropTargetedGame?.id == game.id)
        let isHoveringIcon = (hoveredGame?.id == game.id)
        let eyebrowText: String = {
            if isDrop { return "松开安装补丁" }
            if isHoveringIcon { return "单击直启" }
            return game.lastPlayedAt != nil ? "上次游玩" : "最近入库"
        }()
        let subtitleText: String = {
            if let bottle = game.bottleName?.trimmingCharacters(in: .whitespacesAndNewlines), !bottle.isEmpty {
                return bottle
            }
            switch game.source {
            case .patchPipeline: return "补丁自动入库"
            case .crossoverScan: return "CrossOver 容器"
            case .manualImport:  return "本地导入"
            }
        }()
        let isAccentMode = (theme.mode != .monochrome)
        let playFill: Color = {
            if isAccentMode {
                return theme.accent.opacity(isPlayButtonHovered ? (theme.isDark ? 0.28 : 0.20) : (theme.isDark ? 0.18 : 0.12))
            }
            return isPlayButtonHovered ? Color.t3ControlHoverFill : Color.t3ControlSelectedFill
        }()
        let playBorder: Color = {
            if isAccentMode {
                return theme.accent.opacity(theme.isDark ? 0.34 : 0.26)
            }
            return Color.t3ControlSelectedStroke
        }()
        let playForeground: Color = isAccentMode ? theme.accent : .t3TextMain

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(eyebrowText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isDrop ? theme.accent : .t3TextMuted)
                Spacer(minLength: 4)
                Text(game.lastPlayedDisplayText())
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundColor(.t3TextMuted)
                    .lineLimit(1)
            }

            HStack(alignment: .center, spacing: 8) {
                QuickLaunchMiniIcon(
                    icon: vm.launchGameIcon(for: game),
                    title: game.title,
                    size: 28,
                    cornerRadius: ChrysaMetrics.radiusSmall
                )

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(game.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.t3TextMain)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(subtitleText)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.t3TextMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 5) {
                Button(action: { vm.launchGame(game) }) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text(game.lastPlayedAt != nil ? "继续游玩" : "启动游戏")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundColor(playForeground)
                    .frame(maxWidth: .infinity)
                    .frame(height: ChrysaMetrics.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .fill(playFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .stroke(playBorder, lineWidth: 0.9)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { isPlayButtonHovered = $0 }
                .help("启动「\(game.title)」")

                if !isSnapshotMode && vm.hasAccessibleDirectory(for: game) {
                    Button(action: { vm.openLaunchGameDirectory(game) }) {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(isFolderButtonHovered ? .t3TextMain : .t3TextSub)
                            .frame(width: ChrysaMetrics.controlHeight, height: ChrysaMetrics.controlHeight)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .fill(isFolderButtonHovered ? Color.t3ControlHoverFill : Color.t3ControlFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .stroke(Color.t3GroupedCardBorder, lineWidth: 0.9)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .onHover { isFolderButtonHovered = $0 }
                    .help("打开游戏目录")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(theme.isDark ? Color.white.opacity(0.022) : Color.black.opacity(0.018))
    }
}

private struct QuickLaunchMiniIcon: View {
    let icon: NSImage?
    let title: String
    let size: CGFloat
    let cornerRadius: CGFloat
    @Environment(\.appTheme) private var theme

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
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.t3CardBorder, lineWidth: 0.6)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(theme.isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.055))
                    .frame(width: size, height: size)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.t3GroupedCardBorder, lineWidth: 0.75)
                    )
                Text(monogram)
                    .font(.system(size: size * 0.41, weight: .semibold, design: .rounded))
                    .foregroundColor(.t3TextSub)
            }
        }
    }
}

private struct QuickLaunchIconTile: View {
    @ObservedObject var vm: StudioViewModel
    let game: LaunchGame
    let isHovered: Bool
    let isDropTargeted: Bool
    let isFocused: Bool
    let isSnapshotMode: Bool
    let onHoverChange: (Bool) -> Void
    let onDropTargetChange: (Bool) -> Void
    @Environment(\.appTheme) private var theme

    private var ringColor: Color {
        if isDropTargeted {
            return theme.accent
        }
        if isHovered {
            return theme.mode == .monochrome
                ? Color.t3TextMain.opacity(theme.isDark ? 0.62 : 0.72)
                : theme.accent
        }
        if isFocused {
            return theme.mode == .monochrome
                ? Color.t3TextMain.opacity(theme.isDark ? 0.28 : 0.30)
                : theme.accent.opacity(0.55)
        }
        return Color.clear
    }

    var body: some View {
        let icon = vm.launchGameIcon(for: game)
        let dropBinding = Binding<Bool>(
            get: { isDropTargeted },
            set: { onDropTargetChange($0) }
        )

        Button(action: { vm.launchGame(game) }) {
            QuickLaunchMiniIcon(
                icon: icon,
                title: game.title,
                size: 30,
                cornerRadius: ChrysaMetrics.radiusSmall
            )
            .padding(2)
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                    .stroke(ringColor, lineWidth: isDropTargeted || isHovered ? 1.5 : 1.1)
            )
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
        }
        .buttonStyle(.plain)
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
        .task(id: StudioViewModel.launchGameIconSignature(for: game)) {
            guard !isSnapshotMode else { return }
            await vm.loadLaunchGameIconIfNeeded(for: game)
        }
    }
}
