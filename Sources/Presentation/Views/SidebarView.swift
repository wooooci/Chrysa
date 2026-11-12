import ChrysaCore
import ChrysaApplication
import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool

    @State private var hoveredSidebarTab: StudioTab? = nil
    private var topBarHeight: CGFloat {
        isSnapshotMode ? 38 : 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .leading) {
                if isSnapshotMode {
                    HStack(spacing: 8) {
                        Circle().fill(Color(red: 1.0, green: 0.373, blue: 0.341)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        Circle().fill(Color(red: 1.0, green: 0.741, blue: 0.180)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        Circle().fill(Color(red: 0.153, green: 0.788, blue: 0.247)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                    }
                    .padding(.leading, 18)
                }
            }
            .frame(height: topBarHeight)

            // Persistent follower shape sliding on NAV_SPRING (response: 0.42, dampingFraction: 0.84)
            VStack(spacing: 2) {
                sidebarRow(tab: .download, title: "下载", count: "\(vm.jobs(of: .download).filter { !$0.isArchived }.count)")
                sidebarRow(tab: .unpack,   title: "解压", count: "\(vm.jobs(of: .unpack).filter { !$0.isArchived }.count)")
                sidebarRow(tab: .patch,    title: "补丁", count: "\(vm.jobs(of: .patch).filter { !$0.isArchived }.count)")

                Rectangle()
                    .fill(Color.t3SidebarBorder)
                    .frame(height: 1)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)

                sidebarRow(tab: .settings, title: "设置", count: "")
            }
            .padding(.horizontal, 10)
            .backgroundPreferenceValue(SidebarTabBoundsKey.self) { bounds in
                GeometryReader { proxy in
                    if let anchor = bounds[vm.activeTab] {
                        let rect = proxy[anchor]
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.t3SidebarActive)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(.spring(response: 0.18, dampingFraction: 0.92), value: vm.activeTab)
                    }
                }
            }

            Spacer()

            Rectangle()
                .fill(Color.t3SidebarBorder)
                .frame(height: 1)

            HStack(alignment: .center, spacing: 0) {
                Text("自动流转")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.t3TextSub)
                Spacer()
                T3ToggleSwitch(isOn: vm.settingsStore.settings.autoRelay)
            }
            .padding(.horizontal, 18)
            .frame(height: 40)
            .contentShape(Rectangle())
            .onInstantPress {
                vm.toggleAutoRelay()
            }
        }
        .background(Color.t3SidebarBg)
    }

    private func sidebarRow(tab: StudioTab, title: String, count: String) -> some View {
        let isHighlighted = (vm.activeTab == tab)
        let isHovered = (hoveredSidebarTab == tab && !isHighlighted)

        return HStack(alignment: .center, spacing: 8) {
            T3SidebarIcon(tab: tab, placement: .sidebar(isActive: isHighlighted))

            Text(title)
                .font(.system(size: 14.5, weight: isHighlighted ? .semibold : .medium))
                .foregroundColor(
                    isHighlighted
                        ? .t3TextMain
                        : (isHovered ? .t3TextMain : .t3TextMain.opacity(0.86))
                )

            Spacer(minLength: 0)

            Text(count)
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundColor(isHighlighted ? .t3TextMain.opacity(0.75) : .t3TextSub)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
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
