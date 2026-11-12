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
        .onDrop(of: [.fileURL, .plainText, .url], isTargeted: nil) { providers in
            vm.handleDroppedProviders(providers)
        }
        .sheet(item: $vm.editingTask) { task in
            EditTaskSheetView(vm: vm, task: task)
        }
    }

    private var mainCanvasView: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: topBarHeight)

                PageHeaderView(vm: vm, isSnapshotMode: isSnapshotMode)
                    .frame(height: 30)
                    .padding(.bottom, 12)

                Group {
                    if vm.activeTab == .settings {
                        SettingsView(vm: vm, isSnapshotMode: isSnapshotMode)
                    } else {
                        TaskListSectionView(vm: vm, isSnapshotMode: isSnapshotMode)
                    }
                }
                .id(vm.activeTab)
                .transition(.opacity.animation(.easeOut(duration: 0.16)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if vm.activeTab != .settings {
                    Spacer().frame(height: 10)
                    LogBoxSectionView(vm: vm)
                }
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 14)

            Rectangle()
                .fill(Color.t3Divider)
                .frame(height: 1)

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
                    .foregroundColor(vm.activeTab == .settings && vm.settingsCategory == .unpack ? .t3Blue : .t3TextSub)
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
                vm.activeTab = .settings
            }) {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(vm.activeTab == .settings ? .t3Blue : .t3TextSub)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 13.5, weight: .medium))
        .foregroundColor(.t3TextSub)
        .frame(maxWidth: .infinity)
        .frame(height: 38)
    }
}
