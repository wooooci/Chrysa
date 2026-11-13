import ChrysaCore
import ChrysaApplication
import SwiftUI
import AppKit

// MARK: - Apple Native Unboxed Light SF Symbols Module Icons
struct T3SidebarIcon: View {
    enum Placement {
        case sidebar(isActive: Bool)
        case pageHeader
    }

    let tab: StudioTab
    var placement: Placement = .sidebar(isActive: false)
    @Environment(\.appTheme) private var theme

    private var isHeader: Bool {
        if case .pageHeader = placement { return true }
        return false
    }

    private var basePointSize: CGFloat {
        isHeader ? 19.5 : 14.0
    }

    private var opticalScaleFactor: CGFloat {
        switch tab {
        case .download: return 1.00
        case .unpack:   return 0.95
        case .patch:    return 0.92
        case .launch:   return 0.88
        case .settings: return 1.04
        }
    }

    private var sidebarOpticalOffset: CGSize {
        switch tab {
        case .download: return CGSize(width: 0.25, height: 0.0)
        case .unpack:   return CGSize(width: -0.75, height: -0.5)
        case .patch:    return CGSize(width: 0.25, height: -0.25)
        case .launch:   return CGSize(width: 0.0, height: 0.0)
        case .settings: return CGSize(width: 0.25, height: 0.0)
        }
    }

    private var headerOpticalOffset: CGSize {
        switch tab {
        case .download: return CGSize(width: -2.0, height: 0.5)
        case .unpack:   return CGSize(width: -1.5, height: 0.25)
        case .patch:    return CGSize(width: -2.0, height: 0.75)
        case .launch:   return CGSize(width: -1.5, height: 0.5)
        case .settings: return CGSize(width: -2.0, height: 0.75)
        }
    }

    private var resolvedColor: Color {
        switch placement {
        case .pageHeader:
            return theme.iconActive
        case .sidebar(let isActive):
            return isActive ? theme.iconActive : theme.iconInactive
        }
    }

    var body: some View {
        if isHeader {
            Image(systemName: tab.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: basePointSize * opticalScaleFactor, weight: .light))
                .imageScale(.medium)
                .foregroundStyle(resolvedColor)
                .offset(headerOpticalOffset)
                .frame(height: 26, alignment: .leading)
        } else {
            Image(systemName: tab.symbolName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: basePointSize * opticalScaleFactor, weight: .light))
                .imageScale(.medium)
                .foregroundStyle(resolvedColor)
                .offset(sidebarOpticalOffset)
                .frame(width: 20, height: 20, alignment: .center)
        }
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
                .stroke(resolvedColor, lineWidth: 1.5)
            Path { path in
                let center = CGPoint(x: size / 2, y: size / 2)
                let radius = (size / 2) - 2.6
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
            RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                .stroke(Color.t3CheckBorder, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 3.8).fill(Color.white))
                .frame(width: 14, height: 14)
        case .running(let pct):
            T3PieRing(progress: pct, size: 15, color: theme.accent)
        case .locked(let pct):
            T3PieRing(progress: pct, size: 15, color: .t3Amber)
        case .paused(let pct):
            ZStack {
                T3PieRing(progress: max(0.02, pct), size: 15, color: .t3TextMuted)
                    .opacity(0.45)
                Image(systemName: "pause.fill")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundColor(.t3TextSub)
            }
        case .done:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(theme.accent)
                    .frame(width: 14, height: 14)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white)
            }
        case .failed:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 14, height: 14)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }
}

// MARK: - Outlined Pill Badge
struct T3OutlinedPill: View {
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 3.5) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.t3TextSub)
            }
            Text(text)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.t3TextSub)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1.5)
        .overlay(
            Capsule()
                .stroke(Color.t3PillBorder, lineWidth: 1)
        )
    }
}

// MARK: - Native macOS Mini Toggle Switch
struct T3ToggleSwitch: View {
    let isOn: Bool
    @Environment(\.appTheme) private var theme

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? theme.accent : Color(red: 0.82, green: 0.84, blue: 0.87))
                .frame(width: 28, height: 16)
            Circle()
                .fill(Color.white)
                .frame(width: 12.5, height: 12.5)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.8)
                .padding(.horizontal, 1.8)
        }
        .animation(.easeOut(duration: 0.14), value: isOn)
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
// Replicates yetone/magpie's `.nav-top-hl` (NAV_SPRING: response 0.42, damping 0.84),
// `.seg > .thumb` / `.nav-hl` sliding pill, immediate pointer-down pre-glide,
// and `navlamp.js` pointer-following torch highlight.
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


