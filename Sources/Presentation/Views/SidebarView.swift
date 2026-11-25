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
                SidebarArcFavoritesGrid(
                    vm: vm,
                    games: quickGames,
                    isSnapshotMode: isSnapshotMode
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            WindowDragArea(isSnapshotMode: isSnapshotMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
        .background(
            T3SidebarBackdropView(isSnapshotMode: isSnapshotMode)
                .ignoresSafeArea(.container, edges: .top)
        )
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

// MARK: - Arc-Style Unboxed Adaptive Favorites Grid (Content-Sized, Floating Directly on Translucent Sidebar)
private struct SidebarArcFavoritesGrid: View {
    @ObservedObject var vm: StudioViewModel
    let games: [LaunchGame]
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var hoveredGame: LaunchGame? = nil
    @State private var dropTargetedGame: LaunchGame? = nil

    private let tileHeight: CGFloat = 44
    private let gridSpacing: CGFloat = 6
    private let maxVisibleRows: Int = 4

    private var columnCount: Int {
        min(max(games.count, 1), 3)
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    private var totalRows: Int {
        let count = max(games.count, 1)
        return (count + columnCount - 1) / columnCount
    }

    private var needsScroll: Bool {
        totalRows > maxVisibleRows
    }

    private var maxGridHeight: CGFloat {
        CGFloat(maxVisibleRows) * tileHeight + CGFloat(maxVisibleRows - 1) * gridSpacing
    }

    private var activeHintGame: LaunchGame? {
        dropTargetedGame ?? hoveredGame
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if needsScroll && !isSnapshotMode {
                ScrollView(.vertical, showsIndicators: false) {
                    gridBody
                }
                .frame(height: maxGridHeight)
            } else {
                gridBody
            }

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
                .frame(height: 16)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: activeHintGame?.id)
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

    private var tileFill: Color {
        if isDropTargeted {
            return theme.accent.opacity(theme.isDark ? 0.22 : 0.14)
        }
        if isHovered {
            return theme.isDark ? Color.white.opacity(0.115) : Color.white.opacity(0.82)
        }
        return theme.isDark ? Color.white.opacity(0.056) : Color.black.opacity(0.035)
    }

    private var tileBorder: Color {
        if isDropTargeted {
            return theme.accent
        }
        if isHovered {
            if theme.mode != .monochrome {
                return theme.accent.opacity(theme.isDark ? 0.58 : 0.48)
            }
            return theme.isDark ? Color.white.opacity(0.18) : Color.black.opacity(0.12)
        }
        return theme.isDark ? Color.white.opacity(0.075) : Color.black.opacity(0.062)
    }

    var body: some View {
        let icon = vm.launchGameIcon(for: game)
        let dropBinding = Binding<Bool>(
            get: { isDropTargeted },
            set: { onDropTargetChange($0) }
        )

        Button(action: { vm.launchGame(game) }) {
            ZStack {
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                    .fill(tileFill)
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                    .stroke(tileBorder, lineWidth: isDropTargeted ? 1.5 : 0.9)

                ArcGameGlyph(
                    icon: icon,
                    title: game.title,
                    iconSize: 28,
                    monogramSize: 26
                )
                .scaleEffect(isHovered ? 1.05 : 1.0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: tileHeight)
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
        }
        .buttonStyle(ArcTilePressStyle())
        .animation(.easeOut(duration: 0.14), value: isHovered)
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

private struct ArcTilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct ArcGameGlyph: View {
    let icon: NSImage?
    let title: String
    let iconSize: CGFloat
    let monogramSize: CGFloat
    @Environment(\.appTheme) private var theme

    private var monogram: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }

    private var mutedTone: Color {
        let palette: [Color] = [
            Color(red: 0.36, green: 0.58, blue: 0.90), // Slate Blue
            Color(red: 0.28, green: 0.70, blue: 0.54), // Sage Emerald
            Color(red: 0.84, green: 0.58, blue: 0.28), // Warm Ochre
            Color(red: 0.68, green: 0.48, blue: 0.86), // Muted Lavender
            Color(red: 0.82, green: 0.44, blue: 0.52), // Dusty Rose
            Color(red: 0.32, green: 0.66, blue: 0.76), // Muted Teal
            Color(red: 0.52, green: 0.56, blue: 0.88), // Periwinkle
            Color(red: 0.76, green: 0.66, blue: 0.34)  // Soft Brass
        ]
        var hash: UInt64 = 14695981039346656037
        for byte in title.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .stroke(Color.black.opacity(theme.isDark ? 0.22 : 0.08), lineWidth: 0.5)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .fill(mutedTone.opacity(theme.isDark ? 0.20 : 0.14))
                    .frame(width: monogramSize, height: monogramSize)
                Text(monogram)
                    .font(.system(size: monogramSize * 0.48, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.isDark ? mutedTone.opacity(0.95) : mutedTone.opacity(0.88))
            }
        }
    }
}
