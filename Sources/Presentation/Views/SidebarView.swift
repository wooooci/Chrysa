import ChrysaCore
import ChrysaApplication
import SwiftUI

struct SidebarView: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool

    // Magpie-style `.nav-top-hl` follower state:
    // - Immediate pointer-down pre-glide (`onpointerdown` -> glide to pressed tab; drag out -> spring back)
    // - `navlamp.js` continuous pointer torch on hovered sidebar rows
    @State private var pressingSidebarTab: StudioTab? = nil
    @State private var hoveredSidebarTab: StudioTab? = nil
    @State private var hoverSidebarX: CGFloat = 45

    private var effectiveSidebarTab: StudioTab {
        pressingSidebarTab ?? vm.activeTab
    }

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
                    if let anchor = bounds[effectiveSidebarTab] {
                        let rect = proxy[anchor]
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.t3SidebarActive)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .animation(.spring(response: 0.42, dampingFraction: 0.84), value: effectiveSidebarTab)
                    }
                }
            }

            Spacer()

            Rectangle()
                .fill(Color.t3SidebarBorder)
                .frame(height: 1)

            Button(action: {
                vm.toggleAutoRelay()
            }) {
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
            }
            .buttonStyle(.plain)
        }
        .background(Color.t3SidebarBg)
    }

    private func sidebarRow(tab: StudioTab, title: String, count: String) -> some View {
        let isHighlighted = (effectiveSidebarTab == tab)
        let isHovered = (hoveredSidebarTab == tab && !isHighlighted)

        return HStack(alignment: .center, spacing: 9) {
            T3SidebarIcon(tab: tab, size: 17)
                .frame(width: 18, height: 18, alignment: .center)

            Text(title)
                .font(.system(size: 14.5, weight: isHighlighted ? .semibold : .medium))
                .foregroundStyle(
                    isHovered
                        ? AnyShapeStyle(
                            RadialGradient(
                                colors: [Color.black, Color.t3TextMain.opacity(0.88)],
                                center: UnitPoint(x: min(max((hoverSidebarX - 35) / 60, 0), 1), y: 0.5),
                                startRadius: 2,
                                endRadius: 42
                            )
                        )
                        : AnyShapeStyle(isHighlighted ? Color.t3TextMain : Color.t3TextMain.opacity(0.86))
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
        .onContinuousHover { phase in
            switch phase {
            case .active(let loc):
                hoveredSidebarTab = tab
                withAnimation(.linear(duration: 0.08)) {
                    hoverSidebarX = loc.x
                }
            case .ended:
                if hoveredSidebarTab == tab {
                    hoveredSidebarTab = nil
                }
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let rowBounds = CGRect(x: -4, y: -4, width: 174, height: 38)
                    if rowBounds.contains(value.location) {
                        if pressingSidebarTab != tab {
                            pressingSidebarTab = tab
                        }
                    } else if pressingSidebarTab == tab {
                        pressingSidebarTab = nil
                    }
                }
                .onEnded { value in
                    let rowBounds = CGRect(x: -4, y: -4, width: 174, height: 38)
                    if rowBounds.contains(value.location) {
                        vm.activeTab = tab
                    }
                    pressingSidebarTab = nil
                }
        )
        .animation(.easeOut(duration: 0.18), value: isHighlighted)
        .animation(.easeOut(duration: 0.18), value: isHovered)
    }
}
