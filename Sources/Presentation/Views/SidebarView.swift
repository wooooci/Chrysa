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

            sidebarRow(tab: .settings, title: "设置", count: "")
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
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
                    vm.toggleSidebarQuickLaunch()
                }) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
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
            if vm.activeTab != tab {
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
    private let maxVisibleRows: Int = 4
    private let topSpacing: CGFloat = 8

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

    private var visibleRows: Int {
        min(totalRows, maxVisibleRows)
    }

    private var needsScroll: Bool {
        totalRows > maxVisibleRows
    }

    private var gridHeight: CGFloat {
        CGFloat(visibleRows) * tileHeight + CGFloat(max(visibleRows - 1, 0)) * gridSpacing
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

            Group {
                if needsScroll && !isSnapshotMode {
                    ScrollView(.vertical, showsIndicators: false) {
                        gridBody
                    }
                    .frame(height: gridHeight)
                } else {
                    gridBody
                }
            }
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
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundColor(isHovered ? .t3TextMain : .t3TextSub)
        }
    }
}
