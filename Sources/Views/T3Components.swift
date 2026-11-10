import SwiftUI
import AppKit

// MARK: - Authentic Things 3 Custom Vector Icons (Inbox / Archive Box / Logbook / Sliders)
struct T3SidebarIcon: View {
    let tab: StudioTab
    var size: CGFloat = 15

    var body: some View {
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height

            switch tab {
            case .download:
                // Authentic Things 3 "Inbox" Icon: Sky-blue rounded square with T-stepped white tray cutout
                let bgRect = CGRect(x: w * 0.04, y: h * 0.04, width: w * 0.92, height: h * 0.92)
                let bgPath = Path(roundedRect: bgRect, cornerRadius: w * 0.22, style: .continuous)
                context.fill(bgPath, with: .color(Color(red: 0.098, green: 0.620, blue: 0.953))) // #199EF3

                var cutout = Path()
                let topW = w * 0.64
                let topH = h * 0.34
                let topX = (w - topW) / 2
                let topY = h * 0.22
                cutout.addRoundedRect(in: CGRect(x: topX, y: topY, width: topW, height: topH), cornerSize: CGSize(width: w * 0.08, height: w * 0.08))

                let botW = w * 0.28
                let botH = h * 0.28
                let botX = (w - botW) / 2
                let botY = h * 0.48
                cutout.addRoundedRect(in: CGRect(x: botX, y: botY, width: botW, height: botH), cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
                context.fill(cutout, with: .color(.white))

            case .unpack:
                // Authentic Things 3 "Someday" Archive Box Icon: Two-piece banker's box with lid gap & handle slot
                let boxColor = Color(red: 0.910, green: 0.698, blue: 0.165) // Things 3 Warm Gold-Amber #E8B228
                let lidRect = CGRect(x: w * 0.04, y: h * 0.10, width: w * 0.92, height: h * 0.21)
                let lidPath = Path(roundedRect: lidRect, cornerRadius: w * 0.09, style: .continuous)
                context.fill(lidPath, with: .color(boxColor))

                let bodyRect = CGRect(x: w * 0.09, y: h * 0.38, width: w * 0.82, height: h * 0.52)
                let bodyPath = Path(roundedRect: bodyRect, cornerRadius: w * 0.13, style: .continuous)
                context.fill(bodyPath, with: .color(boxColor))

                // White handle slot inside box body
                let slotRect = CGRect(x: w * 0.33, y: h * 0.52, width: w * 0.34, height: h * 0.12)
                let slotPath = Path(roundedRect: slotRect, cornerRadius: h * 0.06, style: .continuous)
                context.fill(slotPath, with: .color(.white))

            case .patch:
                // Authentic Things 3 "Logbook" Icon: Green book with left spine groove and white checkmark
                let greenColor = Color(red: 0.208, green: 0.753, blue: 0.353) // #35C05A
                let bookRect = CGRect(x: w * 0.11, y: h * 0.05, width: w * 0.78, height: h * 0.90)
                let bookPath = Path(roundedRect: bookRect, cornerRadius: w * 0.16, style: .continuous)
                context.fill(bookPath, with: .color(greenColor))

                // Left book spine line
                let spineRect = CGRect(x: w * 0.25, y: h * 0.05, width: max(1.0, w * 0.065), height: h * 0.90)
                context.fill(Path(spineRect), with: .color(Color.white.opacity(0.45)))

                // Crisp white checkmark on cover
                var check = Path()
                check.move(to: CGPoint(x: w * 0.42, y: h * 0.52))
                check.addLine(to: CGPoint(x: w * 0.53, y: h * 0.64))
                check.addLine(to: CGPoint(x: w * 0.74, y: h * 0.38))
                context.stroke(
                    check,
                    with: .color(.white),
                    style: StrokeStyle(lineWidth: max(1.5, w * 0.105), lineCap: .round, lineJoin: .round)
                )

            case .settings:
                // Authentic Things 3 Sliders / Preferences Icon (unboxed slate-gray tracks with circular knobs)
                let slate = Color(red: 0.455, green: 0.490, blue: 0.545) // #747D8B
                let lineW = max(1.3, h * 0.095)
                let yPositions: [CGFloat] = [h * 0.24, h * 0.50, h * 0.76]
                let knobXPositions: [CGFloat] = [w * 0.34, w * 0.68, w * 0.44]
                let knobR = max(2.1, w * 0.135)

                for (idx, y) in yPositions.enumerated() {
                    var track = Path()
                    track.move(to: CGPoint(x: w * 0.08, y: y))
                    track.addLine(to: CGPoint(x: w * 0.92, y: y))
                    context.stroke(track, with: .color(slate), style: StrokeStyle(lineWidth: lineW, lineCap: .round))

                    let kx = knobXPositions[idx]
                    let knobRect = CGRect(x: kx - knobR, y: y - knobR, width: knobR * 2, height: knobR * 2)
                    context.fill(Path(ellipseIn: knobRect), with: .color(.white))
                    context.stroke(Path(ellipseIn: knobRect), with: .color(slate), style: StrokeStyle(lineWidth: lineW))
                }
            }
        }
        .frame(width: size, height: size)
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

