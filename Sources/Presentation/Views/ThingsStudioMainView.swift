import ChrysaCore
import ChrysaApplication
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Main Interactive Things 3 Studio View (Root Assembly)
package struct ThingsStudioMainView: View {
    @ObservedObject package var vm: StudioViewModel
    package var isSnapshotMode: Bool = false

    package init(vm: StudioViewModel, isSnapshotMode: Bool = false) {
        self.vm = vm
        self.isSnapshotMode = isSnapshotMode
    }

    private var topBarHeight: CGFloat {
        isSnapshotMode ? 38 : 10
    }

    package var body: some View {
        HStack(spacing: 0) {
            SidebarView(vm: vm, isSnapshotMode: isSnapshotMode)
                .frame(width: 186)

            Rectangle()
                .fill(Color.t3SidebarBorder)
                .frame(width: 1)

            mainCanvasView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color.white)
        .environment(\.appTheme, vm.themePalette)
        .onDrop(of: [.fileURL, .plainText, .url], isTargeted: nil) { providers in
            vm.handleDroppedProviders(providers)
        }
        .sheet(item: $vm.editingTask) { task in
            EditTaskSheetView(vm: vm, task: task)
                .environment(\.appTheme, vm.themePalette)
                .tint(vm.themePalette.accent)
        }
        .sheet(item: $vm.editingLaunchGame) { game in
            EditLaunchGameSheetView(vm: vm, game: game)
                .environment(\.appTheme, vm.themePalette)
                .tint(vm.themePalette.accent)
        }
        .launchErrorAlert($vm.launchErrorAlert)
    }

    private var mainCanvasView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: topBarHeight)

                PageHeaderView(vm: vm, isSnapshotMode: isSnapshotMode)
                    .frame(height: 30)
                    .padding(.bottom, 12)

                Group {
                    switch vm.activeTab {
                    case .settings:
                        SettingsView(vm: vm, isSnapshotMode: isSnapshotMode)
                    case .launch:
                        LaunchLibraryView(vm: vm, isSnapshotMode: isSnapshotMode)
                    case .download, .unpack, .patch:
                        TaskListSectionView(vm: vm, isSnapshotMode: isSnapshotMode)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 14)

            if vm.isLogDrawerPresented && vm.activeTab != .launch && !isSnapshotMode {
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1)
                    .overlay(alignment: .bottom) {
                        MascotBottomProgressOverlay(vm: vm, isSnapshotMode: isSnapshotMode)
                    }
                GlobalLogDrawerView(vm: vm)
                    .frame(height: 200)
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1)
            } else {
                Rectangle()
                    .fill(Color.t3Divider)
                    .frame(height: 1)
                    .overlay(alignment: .bottom) {
                        MascotBottomProgressOverlay(vm: vm, isSnapshotMode: isSnapshotMode)
                    }
            }

            bottomToolbar
        }
    }

    private var bottomToolbar: some View {
        HStack(spacing: 62) {
            Button(action: { vm.pickFileForActiveTab() }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)

            Button(action: {
                vm.activeTab = .settings
                vm.settingsCategory = .unpack
            }) {
                Image(systemName: "tag")
                    .foregroundColor(vm.activeTab == .settings && vm.settingsCategory == .unpack ? vm.themePalette.accent : .t3TextSub)
            }
            .buttonStyle(.plain)

            Button(action: { vm.openDownloadDirectoryInFinder() }) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.plain)

            Button(action: { vm.openBottlesDirectoryInFinder() }) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.plain)

            Button(action: {
                if vm.activeTab == .launch {
                    vm.activeTab = .patch
                    if !vm.isLogDrawerPresented {
                        vm.toggleLogDrawer()
                    }
                } else {
                    vm.toggleLogDrawer()
                }
            }) {
                Image(systemName: "terminal")
                    .foregroundColor(vm.isLogDrawerPresented && vm.activeTab != .launch ? vm.themePalette.accent : .t3TextSub)
                    .overlay(alignment: .topTrailing) {
                        if vm.hasUnreadErrorLogs {
                            Circle()
                                .fill(Color.red.opacity(0.88))
                                .frame(width: 5, height: 5)
                                .offset(x: 3.5, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)

            Button(action: {
                vm.activeTab = .settings
            }) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(vm.activeTab == .settings ? vm.themePalette.accent : .t3TextSub)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundColor(.t3TextSub)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
    }
}

extension View {
    /// Presents launch errors using SwiftUI's non-legacy alert API so nested child alerts are never shadowed on macOS.
    package func launchErrorAlert(_ alert: Binding<StudioViewModel.LaunchErrorNotice?>) -> some View {
        self.alert(
            alert.wrappedValue.map { "无法启动「\($0.title)」" } ?? "无法启动",
            isPresented: alert.isPresent(),
            presenting: alert.wrappedValue
        ) { _ in
            Button("好") {}
        } message: { notice in
            Text(notice.message)
        }
    }
}
