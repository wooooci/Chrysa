import SwiftUI
import AppKit

// MARK: - Things 3 Uniform Sidebar Badge Icon (15x15pt Rounded Square)
struct T3SidebarIcon: View {
    let tab: StudioTab

    var body: some View {
        switch tab {
        case .download:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(Color.t3Blue)
                Image(systemName: "arrow.down")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 15, height: 15)
        case .unpack:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(Color.t3Amber)
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 15, height: 15)
        case .patch:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(Color.t3Green)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 15, height: 15)
        case .settings:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(Color(red: 0.455, green: 0.490, blue: 0.545)) // Slate #747D8B
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 15, height: 15)
        }
    }
}

// MARK: - Things 3 Pie Progress Ring Component
struct T3PieRing: View {
    let progress: Double
    var size: CGFloat = 15
    var color: Color = .t3Blue

    var body: some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: 1.5)
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
            .fill(color)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Things 3 Status Checkbox
struct T3StatusBox: View {
    let status: TaskStatus

    var body: some View {
        switch status {
        case .queued:
            RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                .stroke(Color.t3CheckBorder, lineWidth: 1.5)
                .background(RoundedRectangle(cornerRadius: 3.8).fill(Color.white))
                .frame(width: 14, height: 14)
        case .running(let pct):
            T3PieRing(progress: pct, size: 15, color: .t3Blue)
        case .locked(let pct):
            T3PieRing(progress: pct, size: 15, color: .t3Amber)
        case .done:
            ZStack {
                RoundedRectangle(cornerRadius: 3.8, style: .continuous)
                    .fill(Color.t3Blue)
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

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.t3Blue : Color(red: 0.82, green: 0.84, blue: 0.87))
                .frame(width: 28, height: 16)
            Circle()
                .fill(Color.white)
                .frame(width: 12.5, height: 12.5)
                .shadow(color: Color.black.opacity(0.18), radius: 1, x: 0, y: 0.8)
                .padding(.horizontal, 1.8)
        }
    }
}

