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
    @State private var isSearchHovered = false
    @State private var sidebarSearchQuery = ""
    @State private var hoveredSearchResultID: String? = nil
    @FocusState private var isSidebarSearchFocused: Bool

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
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(isBackHovered ? Color.t3HoverBg : Color.clear)
                )
                .animation(ChrysaMotion.hover(isBackHovered), value: isBackHovered)
                .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
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
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
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
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
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
        let trimmedQuery = sidebarSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShowingSearchResults = !trimmedQuery.isEmpty

        return VStack(alignment: .leading, spacing: 0) {
            sidebarSearchPill
                .padding(.horizontal, 10)
                .padding(.bottom, 12)

            if isShowingSearchResults {
                sidebarSearchResultsView(query: trimmedQuery)
                    .transition(.opacity)
            } else {
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
            }

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

            sidebarFooterUtilityBar
                .padding(.leading, 10.5)
                .padding(.trailing, 12)
                .frame(height: ChrysaMetrics.bottomBarHeight)
        }
        .backgroundPreferenceValue(SidebarTabBoundsKey.self) { bounds in
            GeometryReader { proxy in
                if !isShowingSearchResults, let anchor = bounds[vm.activeTab] {
                    let rect = proxy[anchor]
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                        .fill(Color.t3SidebarActive)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: vm.activeTab)
                }
            }
        }
        .onChange(of: vm.searchFocusNonce) { _, _ in
            guard !isSnapshotMode,
                  vm.activeTab != .launch,
                  vm.activeTab != .settings,
                  !vm.isLogDrawerPresented else { return }
            focusSidebarSearch()
        }
        .onKeyPress(.escape) {
            guard isSidebarSearchFocused || !sidebarSearchQuery.isEmpty else { return .ignored }
            clearSidebarSearch()
            return .handled
        }
    }

    private func focusSidebarSearch() {
        DispatchQueue.main.async {
            isSidebarSearchFocused = true
        }
    }

    private func clearSidebarSearch() {
        isSidebarSearchFocused = false
        withAnimation(ChrysaMotion.tabGlide) {
            sidebarSearchQuery = ""
        }
    }

    private var sidebarSearchPill: some View {
        let pillFill: Color = {
            if isSidebarSearchFocused {
                return Color.t3SidebarActive
            }
            return isSearchHovered ? Color.t3ControlHoverFill : Color.t3ControlFill
        }()

        return HStack(alignment: .center, spacing: 7) {
            Image(systemName: "magnifyingglass")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isSidebarSearchFocused ? theme.accent : Color.t3TextMuted)

            if !isSnapshotMode {
                TextField("搜索", text: $sidebarSearchQuery)
                    .textFieldStyle(.plain)
                    .font(ChrysaFont.control)
                    .foregroundColor(.t3TextMain)
                    .focused($isSidebarSearchFocused)
                    .onSubmit {
                        submitTopSidebarSearchResult()
                    }
            } else {
                Text("搜索")
                    .font(ChrysaFont.control)
                    .fontWeight(.regular)
                    .foregroundColor(.t3TextMuted)
                Spacer(minLength: 0)
            }

            if !sidebarSearchQuery.isEmpty && !isSnapshotMode {
                Button(action: { clearSidebarSearch() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundColor(.t3TextMuted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("清空搜索 (Esc)")
            } else if !isSidebarSearchFocused {
                Text("⌘F")
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundColor(.t3TextMuted.opacity(0.65))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(pillFill)
                .animation(isSnapshotMode ? nil : ChrysaMotion.hover(isSearchHovered), value: isSearchHovered)
                .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: isSidebarSearchFocused)
        )
        .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
        .onHover { isSearchHovered = $0 }
        .onTapGesture {
            if !isSnapshotMode {
                isSidebarSearchFocused = true
            }
        }
        .help("搜索游戏与任务 (⌘F)")
    }

    private var sidebarFooterUtilityBar: some View {
        HStack(alignment: .center, spacing: 0) {
            T3ToolbarIconButton(
                systemName: StudioTab.settings.symbolName,
                opticalSize: 14,
                tooltip: "偏好设置 (⌘,)"
            ) {
                vm.openSettings()
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

    private func matchedSidebarGames(for query: String) -> [LaunchGame] {
        let lower = query.lowercased()
        return vm.launchGames.filter { $0.title.lowercased().contains(lower) }
    }

    private func matchedSidebarJobs(for query: String) -> [(tab: StudioTab, job: Job)] {
        let lower = query.lowercased()
        let stages: [(StudioTab, JobKind)] = [(.download, .download), (.unpack, .unpack), (.patch, .patch)]
        var matches: [(StudioTab, Job)] = []
        for (tab, stage) in stages {
            for job in vm.jobs(of: stage) where job.title.lowercased().contains(lower) {
                matches.append((tab, job))
            }
        }
        return matches
    }

    private func submitTopSidebarSearchResult() {
        let trimmed = sidebarSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearSidebarSearch()
            return
        }
        if let firstGame = matchedSidebarGames(for: trimmed).first {
            vm.launchSearchQuery = firstGame.title
            vm.activeTab = .launch
            clearSidebarSearch()
            return
        }
        if let firstJob = matchedSidebarJobs(for: trimmed).first {
            openMatchedJob(tab: firstJob.tab, job: firstJob.job)
            return
        }
    }

    private func openMatchedJob(tab: StudioTab, job: Job) {
        if job.isArchived {
            vm.showArchived = true
        }
        vm.activeTab = tab
        Task {
            await vm.coordinator.updateJob(job.id, expanded: true)
        }
        clearSidebarSearch()
    }

    private func sidebarSearchResultsView(query: String) -> some View {
        let games = Array(matchedSidebarGames(for: query).prefix(6))
        let jobs = Array(matchedSidebarJobs(for: query).prefix(8))

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                if games.isEmpty && jobs.isEmpty {
                    Text("未找到匹配项")
                        .font(ChrysaFont.caption)
                        .foregroundColor(.t3TextMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else {
                    if !games.isEmpty {
                        Text("游戏")
                            .font(ChrysaFont.helper)
                            .foregroundColor(.t3TextMuted)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                            .padding(.bottom, 2)

                        ForEach(games) { game in
                            let rowID = "game:\(game.id.uuidString)"
                            let isHovered = (hoveredSearchResultID == rowID)
                            HStack(spacing: 8) {
                                if let icon = vm.launchGameIcon(for: game) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 16, height: 16)
                                        .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous))
                                } else {
                                    Image(systemName: "gamecontroller")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.t3TextSub)
                                        .frame(width: 16, height: 16)
                                }
                                Text(game.title)
                                    .font(ChrysaFont.control)
                                    .foregroundColor(.t3TextMain)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 4)
                                if isHovered {
                                    Button(action: {
                                        vm.launchGame(game)
                                        clearSidebarSearch()
                                    }) {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 9.5, weight: .semibold))
                                            .foregroundColor(theme.accent)
                                            .frame(width: 20, height: 20)
                                    }
                                    .buttonStyle(.plain)
                                    .help("启动游戏")
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .fill(isHovered ? Color.t3HoverBg : Color.clear)
                                    .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    hoveredSearchResultID = rowID
                                } else if hoveredSearchResultID == rowID {
                                    hoveredSearchResultID = nil
                                }
                            }
                            .onInstantPress {
                                vm.launchSearchQuery = game.title
                                vm.activeTab = .launch
                                clearSidebarSearch()
                            }
                        }
                    }

                    if !jobs.isEmpty {
                        Text("任务")
                            .font(ChrysaFont.helper)
                            .foregroundColor(.t3TextMuted)
                            .padding(.horizontal, 8)
                            .padding(.top, games.isEmpty ? 4 : 10)
                            .padding(.bottom, 2)

                        ForEach(jobs, id: \.job.id) { item in
                            let rowID = "job:\(item.job.id.uuidString)"
                            let isHovered = (hoveredSearchResultID == rowID)
                            HStack(spacing: 8) {
                                Image(systemName: item.tab.symbolName)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.t3TextSub)
                                    .frame(width: 16, height: 16)
                                Text(item.job.title)
                                    .font(ChrysaFont.control)
                                    .foregroundColor(.t3TextMain)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                                    .fill(isHovered ? Color.t3HoverBg : Color.clear)
                                    .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                            )
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    hoveredSearchResultID = rowID
                                } else if hoveredSearchResultID == rowID {
                                    hoveredSearchResultID = nil
                                }
                            }
                            .onInstantPress {
                                openMatchedJob(tab: item.tab, job: item.job)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
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
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
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
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
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
        let shape = RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
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
