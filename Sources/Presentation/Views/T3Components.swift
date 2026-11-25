import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Apple Native Unboxed SF Symbols Module Icons (Optically Matched to PingFang SC + SF Pro)
struct T3SidebarIcon: View {
    enum Placement {
        case sidebar(isActive: Bool)
        case pageHeader
        case emptyState
    }

    let tab: StudioTab
    var placement: Placement = .sidebar(isActive: false)
    @Environment(\.appTheme) private var theme

    private var isHeader: Bool {
        if case .pageHeader = placement { return true }
        return false
    }

    private var isEmptyState: Bool {
        if case .emptyState = placement { return true }
        return false
    }

    private var isActiveSidebar: Bool {
        if case .sidebar(let active) = placement { return active }
        return false
    }

    private var basePointSize: CGFloat {
        switch placement {
        case .pageHeader: return 21
        case .sidebar:    return 15
        case .emptyState: return 28
        }
    }

    private var symbolWeight: Font.Weight {
        switch placement {
        case .pageHeader: return .semibold
        case .emptyState: return .medium
        case .sidebar(let isActive): return isActive ? .semibold : .medium
        }
    }

    private var opticalScaleFactor: CGFloat {
        switch tab {
        case .download: return 1.00
        case .unpack:   return 0.94
        case .patch:    return 0.92
        case .launch:   return 0.90
        case .settings: return 1.02
        }
    }

    private var sidebarOpticalOffset: CGSize {
        switch tab {
        case .download: return CGSize(width: 0.0, height: 0.0)
        case .unpack:   return CGSize(width: -0.5, height: -0.25)
        case .patch:    return CGSize(width: 0.0, height: -0.25)
        case .launch:   return CGSize(width: 0.0, height: 0.0)
        case .settings: return CGSize(width: 0.0, height: 0.0)
        }
    }

    private var headerOpticalOffset: CGSize {
        switch tab {
        case .download: return CGSize(width: 0.0, height: 0.75)
        case .unpack:   return CGSize(width: 0.0, height: -0.25)
        case .patch:    return CGSize(width: 0.0, height: 1.0)
        case .launch:   return CGSize(width: 0.0, height: 0.75)
        case .settings: return CGSize(width: 0.0, height: 0.5)
        }
    }

    /// Compensates per-symbol SF Symbol right side-bearing (notably `folder.badge.plus` negative overhang)
    /// so visual ink-to-ink spacing to the 24pt page title stays identical across all tabs.
    private var headerTrailingOpticalPadding: CGFloat {
        switch tab {
        case .download: return 1.0
        case .unpack:   return 5.5
        case .patch:    return 1.5
        case .launch:   return 2.0
        case .settings: return 1.0
        }
    }

    private var resolvedColor: Color {
        switch placement {
        case .pageHeader:
            return theme.iconActive
        case .sidebar(let isActive):
            return isActive ? theme.iconActive : theme.iconInactive
        case .emptyState:
            return Color.t3TextMuted.opacity(0.78)
        }
    }

    var body: some View {
        if isEmptyState {
            Image(systemName: tab.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: basePointSize * opticalScaleFactor, weight: symbolWeight))
                .foregroundStyle(resolvedColor)
                .frame(width: 44, height: 34, alignment: .center)
        } else if isHeader {
            Image(systemName: tab.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: basePointSize * opticalScaleFactor, weight: symbolWeight))
                .imageScale(.medium)
                .foregroundStyle(resolvedColor)
                .offset(headerOpticalOffset)
                .padding(.trailing, headerTrailingOpticalPadding)
                .frame(height: 26, alignment: .leading)
        } else {
            Image(systemName: tab.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: basePointSize * opticalScaleFactor, weight: symbolWeight))
                .imageScale(.medium)
                .foregroundStyle(resolvedColor)
                .offset(sidebarOpticalOffset)
                .frame(width: 20, height: 20, alignment: .center)
        }
    }
}

// MARK: - Native Translucent Sidebar Backdrop (Real Behind-Window Vibrancy Live, Ambient Veil in Snapshot)
struct T3SidebarBackdropView: View {
    let isSnapshotMode: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        if isSnapshotMode {
            ZStack {
                Color.t3SidebarBg
                // Subtle ambient wallpaper bloom matching real macOS .sidebar behindWindow translucency
                LinearGradient(
                    colors: theme.isDark
                        ? [
                            Color(red: 0.42, green: 0.14, blue: 0.34).opacity(0.24),
                            Color(red: 0.16, green: 0.13, blue: 0.28).opacity(0.16),
                            Color(red: 0.45, green: 0.20, blue: 0.16).opacity(0.20)
                        ]
                        : [
                            Color(red: 0.72, green: 0.78, blue: 0.96).opacity(0.16),
                            Color(red: 0.90, green: 0.88, blue: 0.96).opacity(0.10),
                            Color(red: 0.96, green: 0.85, blue: 0.78).opacity(0.16)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        } else {
            ZStack {
                SidebarVisualEffectRepresentable()
                Color.t3SidebarVeil
            }
        }
    }
}

private struct SidebarVisualEffectRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

// MARK: - Pie Progress Ring Component
struct T3PieRing: View {
    let progress: Double
    var size: CGFloat = 15
    var color: Color? = nil
    @Environment(\.appTheme) private var theme

    var body: some View {
        let resolvedColor = color ?? theme.accent
        ZStack {
            Circle()
                .stroke(resolvedColor, lineWidth: 1.75)
            Path { path in
                let center = CGPoint(x: size / 2, y: size / 2)
                let radius = (size / 2) - 2.8
                path.move(to: center)
                path.addArc(
                    center: center,
                    radius: radius,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(-90 + 360 * progress),
                    clockwise: false
                )
                path.closeSubpath()
            }
            .fill(resolvedColor)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Status Checkbox
struct T3StatusBox: View {
    let status: TaskStatus
    @Environment(\.appTheme) private var theme

    var body: some View {
        switch status {
        case .queued:
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                .stroke(Color.t3CheckBorder, lineWidth: 1.75)
                .background(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous).fill(Color.t3CanvasBg))
                .frame(width: 15, height: 15)
        case .running(let pct):
            T3PieRing(progress: pct, size: 16, color: theme.accent)
        case .locked(let pct):
            T3PieRing(progress: pct, size: 16, color: .t3Amber)
        case .paused(let pct):
            ZStack {
                T3PieRing(progress: max(0.02, pct), size: 16, color: .t3TextMuted)
                    .opacity(0.45)
                Image(systemName: "pause.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.t3TextSub)
            }
        case .done:
            ZStack {
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                    .fill(theme.accent)
                    .frame(width: 15, height: 15)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.accentForeground)
            }
        case .failed:
            ZStack {
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusMicro, style: .continuous)
                    .fill(Color.t3ErrorText)
                    .frame(width: 15, height: 15)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Read-Only Soft-Tinted Inline Tag (Linear / Vercel Geist 20pt × 6pt Radius Proportion)
struct T3OutlinedPill: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.t3TextSub)
            }
            Text(text)
                .font(ChrysaFont.badge.monospacedDigit())
                .tracking(ChrysaTracking.badge)
                .foregroundColor(.t3TextSub)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: ChrysaMetrics.badgeHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .fill(Color.t3ControlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.75)
        )
    }
}

// MARK: - Matte Dropdown Menu Trigger (Refined Vetta/Linear Single-Chevron Style)
struct T3MenuPill: View {
    let text: String
    var icon: String? = nil
    var showChevron: Bool = true
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.t3TextSub)
            }
            Text(text)
                .font(ChrysaFont.control.monospacedDigit())
                .foregroundColor(.t3TextMain)
                .lineLimit(1)
            if showChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.t3TextMuted)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: ChrysaMetrics.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(isHovered ? Color.t3ControlHoverFill : Color.t3ControlFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous))
        .onHover { isHovered = $0 }
    }
}

// MARK: - Subtle Inline Action Button (for + 新建 / + 导入 / + 添加)
struct T3InlineActionButton: View {
    let title: String
    var tooltip: String? = nil
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(ChrysaFont.controlSemibold)
                .foregroundColor(theme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(isHovered ? theme.accent.opacity(theme.isDark ? 0.14 : 0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip ?? "")
    }
}

// MARK: - Bottom Toolbar Icon Button (Native macOS Hierarchical SF Symbols + Optical Sizing)
struct T3ToolbarIconButton: View {
    let systemName: String
    var opticalSize: CGFloat = 13.5
    var isActive: Bool = false
    var showBadgeDot: Bool = false
    let tooltip: String
    let action: () -> Void
    @Environment(\.appTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: opticalSize, weight: isActive ? .semibold : .medium))
                .imageScale(.medium)
                .foregroundStyle(isActive ? theme.accent : (isHovered ? Color.t3TextMain : Color.t3TextSub))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(
                            isActive
                                ? Color.t3SidebarActive
                                : (isHovered ? Color.t3HoverBg : Color.clear)
                        )
                )
                .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                .overlay(alignment: .topTrailing) {
                    if showBadgeDot {
                        Circle()
                            .fill(Color.t3ErrorText)
                            .frame(width: 5.5, height: 5.5)
                            .offset(x: -3, y: 2.5)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

// MARK: - Pure-Flat Mini Toggle Switch (Adaptive Light/Dark Contrast)
struct T3ToggleSwitch: View {
    let isOn: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? theme.accent : Color.t3ToggleOffBg)
                .frame(width: 28, height: 16)
            Circle()
                .fill(isOn ? theme.accentForeground : Color.t3ToggleKnobOff)
                .frame(width: 12.5, height: 12.5)
                .padding(.horizontal, 1.8)
        }
        .animation(ChrysaMotion.tabGlide, value: isOn)
    }
}

// MARK: - Shared Sliding Segmented Control (Magpie / Sidebar `ChrysaMotion.tabGlide` Pattern)
struct T3SlidingSegmentedControl<Option: Hashable & Identifiable>: View {
    let options: [Option]
    let selection: Option
    let label: (Option) -> String
    var equalWidth: Bool = false
    var fontSize: CGFloat = 13
    var isSnapshotMode: Bool = false
    let onSelect: (Option) -> Void

    @State private var hoveredOption: Option? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = (selection == option)
                let isHovered = (hoveredOption == option && !isSelected)

                Text(label(option))
                    .font(.system(size: fontSize, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .t3TextMain : (isHovered ? .t3TextMain : .t3TextSub))
                    .padding(.horizontal, equalWidth ? 4 : 9)
                    .frame(maxWidth: equalWidth ? .infinity : nil)
                    .frame(height: ChrysaMetrics.controlHeight - 4)
                    .background(
                        RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                            .fill(isHovered ? Color.t3HoverBg : Color.clear)
                            .animation(ChrysaMotion.hover(isHovered), value: isHovered)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous))
                    .anchorPreference(key: SelectionBoundsKey<Option>.self, value: .bounds) { [option: $0] }
                    .onHover { hovering in
                        if hovering {
                            hoveredOption = option
                        } else if hoveredOption == option {
                            hoveredOption = nil
                        }
                    }
                    .onInstantPress {
                        if selection != option {
                            onSelect(option)
                        }
                    }
            }
        }
        .backgroundPreferenceValue(SelectionBoundsKey<Option>.self) { bounds in
            GeometryReader { proxy in
                if let anchor = bounds[selection] {
                    let rect = proxy[anchor]
                    RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                        .fill(Color.t3ControlSelectedFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusSmall, style: .continuous)
                                .stroke(Color.t3ControlSelectedStroke, lineWidth: 0.8)
                        )
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: selection)
                }
            }
        }
        .padding(2)
        .frame(height: ChrysaMetrics.controlHeight)
        .background(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .fill(Color.t3ControlTrackBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChrysaMetrics.radiusControl, style: .continuous)
                .stroke(Color.t3GroupedCardBorder, lineWidth: 0.8)
        )
        .animation(isSnapshotMode ? nil : ChrysaMotion.tabGlide, value: selection)
    }
}

struct T3SelectionCheckBadge: View {
    var size: CGFloat = 17
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .fill(theme.isDark ? Color.black.opacity(0.68) : Color(red: 0.12, green: 0.13, blue: 0.16))
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(theme.isDark ? 0.22 : 0.0), lineWidth: 0.75)
                )
            Image(systemName: "checkmark")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - Native macOS Window Drag Area (Zero-Impact in Snapshot Mode)
struct WindowDragArea: View {
    let isSnapshotMode: Bool

    var body: some View {
        if isSnapshotMode {
            Color.clear
        } else {
            WindowDragNSViewRepresentable()
        }
    }
}

private struct WindowDragNSViewRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragNSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Snapshot-Safe Drop Modifier (Prevents SwiftUI ImageRenderer Yellow Placeholder on `.onDrop`)
struct ConditionalDropModifier: ViewModifier {
    let enabled: Bool
    let types: [UTType]
    let isTargeted: Binding<Bool>?
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: types, isTargeted: isTargeted, perform: perform)
        } else {
            content
        }
    }
}

extension View {
    func conditionalDrop(
        enabled: Bool,
        of types: [UTType],
        isTargeted: Binding<Bool>? = nil,
        perform: @escaping ([NSItemProvider]) -> Bool
    ) -> some View {
        modifier(ConditionalDropModifier(enabled: enabled, types: types, isTargeted: isTargeted, perform: perform))
    }
}

// MARK: - Instant Pointer-Down Press Modifier (Zero mouseUp Delay & Cancellation-Safe)
struct InstantPressModifier: ViewModifier {
    let action: () -> Void
    @GestureState private var isPressing = false

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .updating($isPressing) { _, state, _ in
                        state = true
                    }
            )
            .onChange(of: isPressing) { oldValue, newValue in
                if !oldValue && newValue {
                    action()
                }
            }
    }
}

extension View {
    func onInstantPress(_ action: @escaping () -> Void) -> some View {
        modifier(InstantPressModifier(action: action))
    }
}

// MARK: - Magpie-Style Shared Tab Follower Preference Keys & Interaction
struct SelectionBoundsKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [ID: Anchor<CGRect>], nextValue: () -> [ID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SidebarTabBoundsKey: PreferenceKey {
    static var defaultValue: [StudioTab: Anchor<CGRect>] = [:]
    static func reduce(value: inout [StudioTab: Anchor<CGRect>], nextValue: () -> [StudioTab: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct SettingsCategoryBoundsKey: PreferenceKey {
    static var defaultValue: [SettingsCategory: Anchor<CGRect>] = [:]
    static func reduce(value: inout [SettingsCategory: Anchor<CGRect>], nextValue: () -> [SettingsCategory: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension Binding {
    /// Maps an optional binding to a presentation flag that clears the wrapped value when dismissed.
    package func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    wrappedValue = nil
                }
            }
        )
    }
}
