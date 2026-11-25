import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main Interactive Things 3 Studio View (Root Assembly)
package struct ThingsStudioMainView: View {
    @ObservedObject package var vm: StudioViewModel
    package var isSnapshotMode: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme

    package init(vm: StudioViewModel, isSnapshotMode: Bool = false) {
        self.vm = vm
        self.isSnapshotMode = isSnapshotMode
    }

    private var effectiveColorScheme: ColorScheme {
        vm.appearanceMode.preferredColorScheme ?? systemColorScheme
    }

    private var resolvedTheme: AppThemePalette {
        vm.resolvedThemePalette(for: effectiveColorScheme)
    }

    private var topBarHeight: CGFloat {
        isSnapshotMode ? 38 : 10
    }

    package var body: some View {
        let theme = resolvedTheme

        HStack(spacing: 0) {
            SidebarView(vm: vm, isSnapshotMode: isSnapshotMode)
                .frame(width: ChrysaMetrics.sidebarWidth)

            Rectangle()
                .fill(Color.t3SidebarBorder)
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .top)

            mainCanvasView(theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.t3CanvasBg.ignoresSafeArea(.container, edges: .top))
        }
        .frame(minWidth: 820, minHeight: 560)
        .environment(\.appTheme, theme)
        .preferredColorScheme(vm.appearanceMode.preferredColorScheme)
        .onChange(of: vm.appearanceMode) { _, newMode in
            guard !isSnapshotMode else { return }
            NSApp?.appearance = newMode.nsAppearance
        }
        .onAppear {
            guard !isSnapshotMode else { return }
            NSApp?.appearance = vm.appearanceMode.nsAppearance
        }
        .conditionalDrop(enabled: !isSnapshotMode, of: [.fileURL, .plainText, .url]) { providers in
            vm.handleDroppedProviders(providers)
        }
        .sheet(item: $vm.editingTask) { task in
            EditTaskSheetView(vm: vm, task: task)
                .environment(\.appTheme, theme)
                .preferredColorScheme(vm.appearanceMode.preferredColorScheme)
                .tint(theme.accent)
        }
        .sheet(item: $vm.editingLaunchGame) { game in
            EditLaunchGameSheetView(vm: vm, game: game)
                .environment(\.appTheme, theme)
                .preferredColorScheme(vm.appearanceMode.preferredColorScheme)
                .tint(theme.accent)
        }
        .launchErrorAlert($vm.launchErrorAlert)
    }

    private func mainCanvasView(theme: AppThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.activeTab == .settings {
                SettingsView(vm: vm, isSnapshotMode: isSnapshotMode, topBarHeight: topBarHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    WindowDragArea(isSnapshotMode: isSnapshotMode)
                        .frame(height: topBarHeight)

                    PageHeaderView(vm: vm, isSnapshotMode: isSnapshotMode)
                        .frame(height: 30)
                        .padding(.horizontal, ChrysaMetrics.canvasInset)
                        .padding(.bottom, 12)

                    Group {
                        switch vm.activeTab {
                        case .launch:
                            LaunchLibraryView(vm: vm, isSnapshotMode: isSnapshotMode)
                        case .download, .unpack, .patch:
                            TaskListSectionView(vm: vm, isSnapshotMode: isSnapshotMode)
                        case .settings:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }

                if vm.isLogDrawerPresented {
                    Rectangle()
                        .fill(Color.t3Divider)
                        .frame(height: 1)
                        .overlay(alignment: .bottom) {
                            MascotBottomProgressOverlay(vm: vm, isSnapshotMode: isSnapshotMode)
                        }
                        .zIndex(2)
                    GlobalLogDrawerView(vm: vm, isSnapshotMode: isSnapshotMode)
                        .frame(height: vm.logDrawerHeight)
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
                        .zIndex(2)
                }

                bottomToolbar(theme: theme)
            }
        }
    }

    private func bottomToolbar(theme: AppThemePalette) -> some View {
        let status = vm.bottomBarStatusSummary

        return HStack(alignment: .center, spacing: 0) {
            HStack(spacing: 6) {
                if status.isActive {
                    Circle()
                        .fill(theme.accent)
                        .frame(width: 6, height: 6)
                }
                Text(status.text)
                    .font(ChrysaFont.caption.monospacedDigit())
                    .foregroundColor(.t3TextMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, ChrysaMetrics.canvasInset)
        .frame(maxWidth: .infinity)
        .frame(height: ChrysaMetrics.bottomBarHeight)
        .background(Color.t3CanvasBg)
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
