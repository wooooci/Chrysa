import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

package struct LaunchLibraryView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @State private var pendingRemovalGame: LaunchGame?
    @State private var isSearchHovered = false
    @FocusState private var isSearchFocused: Bool
    @Environment(\.appTheme) private var theme

    package init(
        vm: StudioViewModel,
        isSnapshotMode: Bool,
        initialPendingRemoval: LaunchGame? = nil
    ) {
        self.vm = vm
        self.isSnapshotMode = isSnapshotMode
        self._pendingRemovalGame = State(initialValue: initialPendingRemoval)
    }

    package var body: some View {
        let games = vm.filteredAndSortedLaunchGames

        VStack(alignment: .leading, spacing: 0) {
            searchAndImportBar
                .padding(.horizontal, ChrysaMetrics.canvasInset)
                .padding(.bottom, 14)

            if games.isEmpty {
                emptyStateView
            } else if isSnapshotMode {
                gameListContent(games: games)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    gameListContent(games: games)
                }
            }
        }
        .onChange(of: vm.searchFocusNonce) { _, _ in
            if vm.activeTab == .launch && !isSnapshotMode {
                isSearchFocused = true
            }
        }
        // Avoid legacy `.alert(item:)` here so ancestor `.alert(item:)` in ThingsStudioMainView does not swallow it.
        .alert(
            pendingRemovalGame.map { "移除「\($0.title)」？" } ?? "移除游戏？",
            isPresented: $pendingRemovalGame.isPresent(),
            presenting: pendingRemovalGame
        ) { pending in
            Button("仅移除记录") {
                vm.removeLaunchGame(pending, mode: .recordOnly)
            }
            Button("彻底卸载（移入废纸篓）", role: .destructive) {
                vm.removeLaunchGame(pending, mode: .moveToTrash)
            }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("「仅移除记录」保留本地目录与容器；「彻底卸载」会终止关联专属容器进程，并将本地目录、专属容器与快捷方式移入废纸篓。")
        }
    }

    private var searchAndImportBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSearchFocused ? theme.accent : .t3TextMuted)

            if !isSnapshotMode {
                TextField("搜索已就绪游戏...", text: $vm.launchSearchQuery)
                    .textFieldStyle(.plain)
                    .font(ChrysaFont.input)
                    .foregroundColor(.t3TextMain)
                    .focused($isSearchFocused)

                if !vm.launchSearchQuery.isEmpty {
                    Button(action: { vm.launchSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.t3TextMuted)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                }
            } else {
                Text("搜索已就绪游戏...")
                    .font(ChrysaFont.input)
                    .foregroundColor(.t3TextSub)
                Spacer()
            }

            T3InlineActionButton(title: "+ 导入", tooltip: "导入本地游戏目录、.app 或 .exe (⌘N)") {
                vm.importLaunchGameFromPanel()
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .frame(height: ChrysaMetrics.topBoxHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(isSearchFocused ? Color.t3CardBg : Color.t3TopBoxBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(
                    isSearchFocused
                        ? theme.accent.opacity(theme.isDark ? 0.55 : 0.45)
                        : (isSearchHovered ? Color.t3PillBorder : Color.t3TopBoxBorder),
                    lineWidth: isSearchFocused ? 1.4 : 1
                )
        )
        .onHover { isSearchHovered = $0 }
    }

    private var emptyStateView: some View {
        let isSearching = !vm.launchSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 8) {
            Spacer()
            Image(systemName: isSearching ? "magnifyingglass" : "gamecontroller")
                .font(.system(size: 28, weight: .ultraLight))
                .foregroundColor(.t3TextMuted.opacity(0.65))
                .padding(.bottom, 2)
            Text(isSearching ? "未找到匹配的游戏" : "暂无已就绪游戏")
                .font(ChrysaFont.navItemActive)
                .foregroundColor(.t3TextSub)
            if !isSearching {
                Text("补丁完成后自动入库，或拖入本地游戏目录 / .app / .exe")
                    .font(ChrysaFont.caption)
                    .foregroundColor(.t3TextMuted)
            }
            Spacer()
        }
        .padding(.horizontal, ChrysaMetrics.canvasInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gameListContent(games: [LaunchGame]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(games) { game in
                LaunchGameRowView(
                    vm: vm,
                    game: game,
                    isSnapshotMode: isSnapshotMode,
                    onRequestRemove: { pendingRemovalGame = $0 }
                )
            }
        }
        .padding(.horizontal, ChrysaMetrics.canvasInset)
        .padding(.bottom, 12)
    }
}

private struct LaunchGameRowView: View {
    @ObservedObject var vm: StudioViewModel
    let game: LaunchGame
    let isSnapshotMode: Bool
    let onRequestRemove: (LaunchGame) -> Void
    @Environment(\.appTheme) private var theme

    @State private var isHovered = false
    @State private var isPlayHovered = false
    @State private var isMenuHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        let icon = vm.launchGameIcon(for: game)
        let isPatching = vm.patchingGameIDs.contains(game.id)

        HStack(alignment: .center, spacing: 10) {
            LaunchGameIconView(icon: icon)
                .frame(width: 22, height: 22, alignment: .center)
            Text(game.title)
                .font(ChrysaFont.rowTitle)
                .foregroundColor(.t3TextMain)
                .lineLimit(1)
                .truncationMode(.tail)

            if isPatching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            }

            Spacer(minLength: 12)
            Text(isPatching ? "处理中…" : (isDropTargeted ? "松开以安装补丁" : game.lastPlayedDisplayText()))
                .font(ChrysaFont.caption.monospacedDigit())
                .foregroundColor(isDropTargeted ? theme.accent : .t3TextMuted)
                .padding(.trailing, isHovered && !isSnapshotMode ? 54 : 0)
        }
        .padding(.horizontal, ChrysaMetrics.rowInnerInset)
        .frame(height: ChrysaMetrics.listRowHeight)
        .overlay(alignment: .trailing) {
            if !isSnapshotMode {
                HStack(spacing: 4) {
                    Button(action: { vm.launchGame(game) }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(isPlayHovered ? theme.accent : .t3TextSub)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .fill(isPlayHovered ? Color.t3HoverBg : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isPlayHovered = $0 }
                    .help("启动游戏")

                    Menu {
                        gameMenuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(isMenuHovered ? .t3TextMain : .t3TextSub)
                            .frame(width: 24, height: 24)
                            .background(
                                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                    .fill(isMenuHovered ? Color.t3HoverBg : Color.clear)
                            )
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .onHover { isMenuHovered = $0 }
                    .help("更多操作")
                }
                .padding(.trailing, 8)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(isDropTargeted ? theme.accent.opacity(theme.isDark ? 0.14 : 0.08) : (isHovered ? Color.t3HoverBg : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(isDropTargeted ? theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                isPlayHovered = false
                isMenuHovered = false
            }
        }
        .conditionalDrop(enabled: !isSnapshotMode, of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            vm.handleDroppedPatchProviders(providers, for: game)
        }
        .onTapGesture(count: 2) {
            vm.launchGame(game)
        }
        .contextMenu {
            gameMenuItems
        }
        .task(id: StudioViewModel.launchGameIconSignature(for: game)) {
            guard !isSnapshotMode else { return }
            await vm.loadLaunchGameIconIfNeeded(for: game)
        }
    }

    @ViewBuilder
    private var gameMenuItems: some View {
        let isPatching = vm.patchingGameIDs.contains(game.id)

        Button(action: { vm.launchGame(game) }) {
            Label("启动游戏", systemImage: "play")
        }

        if vm.hasAccessibleDirectory(for: game) {
            Button(action: { vm.pickAndInstallPatchOrDLC(for: game) }) {
                Label("安装补丁 / DLC…", systemImage: "puzzlepiece.extension")
            }
            .disabled(isPatching)
        }

        if vm.hasBaselineSnapshot(for: game) {
            Button(action: { vm.restoreBaselineSnapshot(for: game) }) {
                Label("恢复纯净原版", systemImage: "arrow.uturn.backward")
            }
            .disabled(isPatching)
        }

        Divider()

        Button(action: { vm.beginEditingLaunchGame(game) }) {
            Label("编辑游戏与图标...", systemImage: "photo")
        }

        Button(action: { vm.refreshLaunchGameIcon(game) }) {
            Label("重新获取图标", systemImage: "arrow.clockwise")
        }

        Divider()

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

        Divider()

        Button(role: .destructive, action: { onRequestRemove(game) }) {
            Label("移除 / 卸载游戏...", systemImage: "trash")
        }
    }
}

private struct LaunchGameIconView: View {
    let icon: NSImage?

    var body: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .stroke(Color.t3CardBorder, lineWidth: 0.6)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                    .fill(Color.t3TopBoxBg)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .stroke(Color.t3TopBoxBorder, lineWidth: 0.6)
                    )
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextMuted)
            }
        }
    }
}
