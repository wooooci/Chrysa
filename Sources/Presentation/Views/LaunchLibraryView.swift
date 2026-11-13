import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

struct LaunchLibraryView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        let games = vm.filteredAndSortedLaunchGames

        VStack(alignment: .leading, spacing: 0) {
            searchAndImportBar
                .padding(.bottom, 16)

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
    }

    private var searchAndImportBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundColor(.t3TextMuted)

            if !isSnapshotMode {
                TextField("搜索已就绪游戏...", text: $vm.launchSearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(.t3TextMain)

                if !vm.launchSearchQuery.isEmpty {
                    Button(action: { vm.launchSearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.t3TextMuted)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("搜索已就绪游戏...")
                    .font(.system(size: 12.5))
                    .foregroundColor(.t3TextSub)
                Spacer()
            }

            Button(action: { vm.importLaunchGameFromPanel() }) {
                Text("+ 导入")
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
    }

    private var emptyStateView: some View {
        let isSearching = !vm.launchSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 6) {
            Spacer()
            Text(isSearching ? "未找到匹配的游戏" : "暂无已就绪游戏")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.t3TextSub)
            if !isSearching {
                Text("补丁完成后自动入库，或拖入本地游戏目录 / .app / .exe")
                    .font(.system(size: 11.5))
                    .foregroundColor(.t3TextMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func gameListContent(games: [LaunchGame]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(games) { game in
                LaunchGameRowView(vm: vm, game: game, isSnapshotMode: isSnapshotMode)
            }
        }
    }
}

private struct LaunchGameRowView: View {
    @ObservedObject var vm: StudioViewModel
    let game: LaunchGame
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    @State private var isHovered = false
    @State private var isPlayHovered = false

    var body: some View {
        let icon = vm.launchGameIcon(for: game)

        HStack(alignment: .center, spacing: 10) {
            LaunchGameIconView(icon: icon)
                .frame(width: 22, height: 22, alignment: .center)
            Text(game.title)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundColor(.t3TextMain)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 12)
            Text(game.lastPlayedDisplayText())
                .font(.system(size: 11.5, weight: .regular))
                .foregroundColor(.t3TextMuted)
                .padding(.trailing, isHovered && !isSnapshotMode ? 54 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .overlay(alignment: .trailing) {
            if !isSnapshotMode {
                HStack(spacing: 4) {
                    Button(action: { vm.launchGame(game) }) {
                        Image(systemName: "play")
                            .font(.system(size: 11.5, weight: .light))
                            .foregroundColor(isPlayHovered ? theme.accent : .t3TextSub)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isPlayHovered = $0 }
                    .help("启动游戏")

                    Menu {
                        gameMenuItems
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.t3TextSub)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                .padding(.trailing, 10)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovered ? Color.t3TopBoxBg : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            if !hovering {
                isPlayHovered = false
            }
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
        Button(action: { vm.launchGame(game) }) {
            Label("启动游戏", systemImage: "play")
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

        Button(role: .destructive, action: { vm.removeLaunchGame(game) }) {
            Label("从启动库移除记录", systemImage: "trash")
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
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.t3TopBoxBg)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.t3Divider, lineWidth: 0.6)
                    )
                Image(systemName: "gamecontroller")
                    .font(.system(size: 10.5, weight: .light))
                    .foregroundColor(.t3TextMuted)
            }
        }
    }
}
