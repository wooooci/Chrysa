import ChrysaCore
import ChrysaApplication
import SwiftUI

// MARK: - 1:1 Clean-Line Bande-Dessinée Watercolor Vector & C2 B-Spline Renderer
package enum MascotVectorRenderer {
    private static let c2Weights8: [CGFloat] = [
        1.73214286, -0.46428571, 0.12500000, -0.03571429,
        0.01785714, -0.03571429, 0.12500000, -0.46428571
    ]

    private static let c2Weights6: [CGFloat] = [
        1.73333333, -0.46666667, 0.13333333,
        -0.06666667, 0.13333333, -0.46666667
    ]

    private static let mochiPuff8: [CGPoint] = [
        CGPoint(x: -30.8, y:   0.6),
        CGPoint(x: -23.2, y: -21.6),
        CGPoint(x:   0.0, y: -29.6),
        CGPoint(x:  23.2, y: -21.6),
        CGPoint(x:  30.8, y:   0.6),
        CGPoint(x:  23.6, y:  20.8),
        CGPoint(x:   0.0, y:  26.2),
        CGPoint(x: -23.6, y:  20.8)
    ]

    private static let mochiOpen8: [CGPoint] = [
        CGPoint(x: -33.2, y:   0.0),
        CGPoint(x: -25.0, y: -24.0),
        CGPoint(x:   0.0, y: -32.6),
        CGPoint(x:  25.0, y: -24.0),
        CGPoint(x:  33.2, y:   0.0),
        CGPoint(x:  25.4, y:  23.0),
        CGPoint(x:   0.0, y:  29.0),
        CGPoint(x: -25.4, y:  23.0)
    ]

    private static let grokOrbBody8: [CGPoint] = [
        CGPoint(x: -32.8, y:   0.5),
        CGPoint(x: -26.2, y: -26.5),
        CGPoint(x:   1.0, y: -35.8),
        CGPoint(x:  26.8, y: -25.2),
        CGPoint(x:  33.2, y:   1.0),
        CGPoint(x:  25.8, y:  27.0),
        CGPoint(x:  -0.8, y:  35.5),
        CGPoint(x: -26.2, y:  26.2)
    ]

    private static let grokOrbPuff8: [CGPoint] = [
        CGPoint(x: -36.2, y:   0.0),
        CGPoint(x: -28.8, y: -29.0),
        CGPoint(x:   0.6, y: -39.2),
        CGPoint(x:  29.2, y: -28.2),
        CGPoint(x:  36.5, y:   0.5),
        CGPoint(x:  28.4, y:  29.5),
        CGPoint(x:  -0.5, y:  38.8),
        CGPoint(x: -28.8, y:  29.0)
    ]

    private static let miniMochi6: [CGPoint] = [
        CGPoint(x: -22.2, y:   0.5),
        CGPoint(x: -11.6, y: -19.8),
        CGPoint(x:  11.6, y: -19.8),
        CGPoint(x:  22.2, y:   0.5),
        CGPoint(x:  12.2, y:  19.5),
        CGPoint(x: -12.2, y:  19.5)
    ]

    private static let miniOrb8: [CGPoint] = [
        CGPoint(x: -20.5, y:   0.0),
        CGPoint(x: -16.0, y: -16.0),
        CGPoint(x:   0.5, y: -21.0),
        CGPoint(x:  16.2, y: -15.5),
        CGPoint(x:  20.8, y:   0.5),
        CGPoint(x:  15.8, y:  16.2),
        CGPoint(x:  -0.4, y:  20.8),
        CGPoint(x: -16.0, y:  15.8)
    ]

    // Palette
    package static let colInkPen      = Color(red: 38 / 255, green: 31 / 255, blue: 29 / 255)
    package static let colPaperBg     = Color(red: 245 / 255, green: 240 / 255, blue: 230 / 255)
    package static let colPaperLine   = Color(red: 204 / 255, green: 196 / 255, blue: 182 / 255)
    package static let colPaperShadow = Color(red: 214 / 255, green: 206 / 255, blue: 190 / 255).opacity(0.68)
    package static let colTerracotta  = Color(red: 216 / 255, green: 118 / 255, blue: 86 / 255)
    package static let colWindInk     = Color(red: 104 / 255, green: 122 / 255, blue: 138 / 255).opacity(0.72)

    package static func seamColor(for theme: MascotTheme) -> Color {
        switch theme {
        case .forestCube:
            return Color(red: 104 / 255, green: 154 / 255, blue: 146 / 255)
        case .roundMochi:
            return Color(red: 226 / 255, green: 148 / 255, blue: 134 / 255)
        case .grokAstral:
            return Color(red: 220 / 255, green: 124 / 255, blue: 92 / 255)
        case .none:
            return .t3Divider
        }
    }

    // MARK: - Analytical Geometry Helpers
    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private static func addCircleCW(_ path: inout Path, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        guard r > 0.15 else { return }
        let k = 0.55228475 * r
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addCurve(to: CGPoint(x: cx + r, y: cy), control1: CGPoint(x: cx + k, y: cy - r), control2: CGPoint(x: cx + r, y: cy - k))
        path.addCurve(to: CGPoint(x: cx, y: cy + r), control1: CGPoint(x: cx + r, y: cy + k), control2: CGPoint(x: cx + k, y: cy + r))
        path.addCurve(to: CGPoint(x: cx - r, y: cy), control1: CGPoint(x: cx - k, y: cy + r), control2: CGPoint(x: cx - r, y: cy + k))
        path.addCurve(to: CGPoint(x: cx, y: cy - r), control1: CGPoint(x: cx - r, y: cy - k), control2: CGPoint(x: cx - k, y: cy - r))
        path.closeSubpath()
    }

    private static func addEllipseCW(_ path: inout Path, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat) {
        guard rx > 0.15 && ry > 0.15 else { return }
        let kx = 0.55228475 * rx
        let ky = 0.55228475 * ry
        path.move(to: CGPoint(x: cx, y: cy - ry))
        path.addCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + kx, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ky))
        path.addCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ky), control2: CGPoint(x: cx + kx, y: cy + ry))
        path.addCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - kx, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ky))
        path.addCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ky), control2: CGPoint(x: cx - kx, y: cy - ry))
        path.closeSubpath()
    }

    private static func addRotatedPillCW(_ path: inout Path, cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat, ang: CGFloat) {
        let rx = max(0.42, w * 0.5)
        let ry = max(0.42, h * 0.5)
        let c = cos(ang)
        let s = sin(ang)

        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: cx + u * c - v * s, y: cy + u * s + v * c)
        }

        if ry >= rx {
            let r = rx
            let seg = ry - rx
            let k = 0.55228475 * r
            path.move(to: pt(0, -seg - r))
            path.addCurve(to: pt(r, -seg), control1: pt(k, -seg - r), control2: pt(r, -seg - k))
            if seg > 0.05 {
                path.addLine(to: pt(r, seg))
            }
            path.addCurve(to: pt(0, seg + r), control1: pt(r, seg + k), control2: pt(k, seg + r))
            path.addCurve(to: pt(-r, seg), control1: pt(-k, seg + r), control2: pt(-r, seg + k))
            if seg > 0.05 {
                path.addLine(to: pt(-r, -seg))
            }
            path.addCurve(to: pt(0, -seg - r), control1: pt(-r, -seg - k), control2: pt(-k, -seg - r))
            path.closeSubpath()
        } else {
            let r = ry
            let seg = rx - ry
            let k = 0.55228475 * r
            path.move(to: pt(-seg, -r))
            path.addLine(to: pt(seg, -r))
            path.addCurve(to: pt(seg + r, 0), control1: pt(seg + k, -r), control2: pt(seg + r, -k))
            path.addCurve(to: pt(seg, r), control1: pt(seg + r, k), control2: pt(seg + k, r))
            path.addLine(to: pt(-seg, r))
            path.addCurve(to: pt(-seg - r, 0), control1: pt(-seg - k, r), control2: pt(-seg - r, k))
            path.addCurve(to: pt(-seg, -r), control1: pt(-seg - r, -k), control2: pt(-seg - k, -r))
            path.closeSubpath()
        }
    }

    private static func addLeafCW(_ path: inout Path, bx: CGFloat, by: CGFloat, tx: CGFloat, ty: CGFloat, halfW: CGFloat, bend: CGFloat) {
        let dx = tx - bx
        let dy = ty - by
        let len = hypot(dx, dy)
        guard len >= 0.5 else { return }
        let ux = dx / len
        let uy = dy / len
        let lx = uy
        let ly = -ux
        let mx = lerp(bx, tx, 0.52) + lx * bend
        let my = lerp(by, ty, 0.52) + ly * bend

        path.move(to: CGPoint(x: bx, y: by))
        path.addCurve(
            to: CGPoint(x: tx, y: ty),
            control1: CGPoint(x: bx + ux * len * 0.28 + lx * halfW * 0.85, y: by + uy * len * 0.28 + ly * halfW * 0.85),
            control2: CGPoint(x: mx + ux * len * 0.14 + lx * halfW, y: my + uy * len * 0.14 + ly * halfW)
        )
        path.addCurve(
            to: CGPoint(x: bx, y: by),
            control1: CGPoint(x: mx + ux * len * 0.14 - lx * halfW, y: my + uy * len * 0.14 - ly * halfW),
            control2: CGPoint(x: bx + ux * len * 0.28 - lx * halfW * 0.85, y: by + uy * len * 0.28 - ly * halfW * 0.85)
        )
        path.closeSubpath()
    }

    private static func addStar4CW(
        _ path: inout Path,
        cx: CGFloat,
        cy: CGFloat,
        rOuter: CGFloat,
        rInner: CGFloat,
        rot: CGFloat
    ) {
        guard rOuter > 0.25 else { return }
        for i in 0..<8 {
            let r = (i % 2 == 0) ? rOuter : rInner
            let a = rot + CGFloat(i) * (.pi * 0.25)
            let pt = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
            if i == 0 {
                path.move(to: pt)
            } else {
                path.addLine(to: pt)
            }
        }
        path.closeSubpath()
    }

    private static func addRoundedQuadCW(
        _ path: inout Path,
        _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ p4: CGPoint,
        radius: CGFloat
    ) {
        let pts = [p1, p2, p3, p4]
        var aPts = Array(repeating: CGPoint.zero, count: 4)
        var bPts = Array(repeating: CGPoint.zero, count: 4)

        for i in 0..<4 {
            let prev = pts[(i + 3) % 4]
            let cur = pts[i]
            let nxt = pts[(i + 1) % 4]

            let dpx = prev.x - cur.x, dpy = prev.y - cur.y
            let lp = max(0.001, hypot(dpx, dpy))
            let dnx = nxt.x - cur.x, dny = nxt.y - cur.y
            let ln = max(0.001, hypot(dnx, dny))

            let r = min(radius, min(lp, ln) * 0.42)
            aPts[i] = CGPoint(x: cur.x + (dpx / lp) * r, y: cur.y + (dpy / lp) * r)
            bPts[i] = CGPoint(x: cur.x + (dnx / ln) * r, y: cur.y + (dny / ln) * r)
        }

        let k: CGFloat = 0.55228475
        path.move(to: bPts[0])
        for i in 0..<4 {
            let j = (i + 1) % 4
            let cur = pts[j]
            path.addLine(to: aPts[j])
            path.addCurve(
                to: bPts[j],
                control1: CGPoint(x: aPts[j].x + (cur.x - aPts[j].x) * k, y: aPts[j].y + (cur.y - aPts[j].y) * k),
                control2: CGPoint(x: bPts[j].x + (cur.x - bPts[j].x) * k, y: bPts[j].y + (cur.y - bPts[j].y) * k)
            )
        }
        path.closeSubpath()
    }

    private static func addTiltedRingArcs(
        back: inout Path,
        front: inout Path,
        cx: CGFloat,
        cy: CGFloat,
        rx: CGFloat,
        ry: CGFloat,
        ang: CGFloat
    ) {
        let c = cos(ang)
        let s = sin(ang)
        let kx = 0.55228475 * rx
        let ky = 0.55228475 * ry

        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: cx + u * c - v * s, y: cy + u * s + v * c)
        }

        back.move(to: pt(-rx, 0))
        back.addCurve(to: pt(0, -ry), control1: pt(-rx, -ky), control2: pt(-kx, -ry))
        back.addCurve(to: pt(rx, 0), control1: pt(kx, -ry), control2: pt(rx, -ky))

        front.move(to: pt(rx, 0))
        front.addCurve(to: pt(0, ry), control1: pt(rx, ky), control2: pt(kx, ry))
        front.addCurve(to: pt(-rx, 0), control1: pt(-kx, ry), control2: pt(-rx, ky))
    }

    private static func emitClosedC2Path(
        _ outPath: inout Path,
        kx: [CGFloat],
        ky: [CGFloat],
        weights: [CGFloat],
        dxOut: inout [CGFloat],
        dyOut: inout [CGFloat]
    ) {
        let n = kx.count
        for i in 0..<n {
            var sx: CGFloat = 0
            var sy: CGFloat = 0
            for m in 0..<n {
                let idx = (i + m) % n
                let w = weights[m]
                sx += w * kx[idx]
                sy += w * ky[idx]
            }
            dxOut[i] = sx
            dyOut[i] = sy
        }

        outPath.move(to: CGPoint(x: kx[0], y: ky[0]))
        for i in 0..<n {
            let j = (i + 1) % n
            outPath.addCurve(
                to: CGPoint(x: kx[j], y: ky[j]),
                control1: CGPoint(x: (2.0 * dxOut[i] + dxOut[j]) / 3.0, y: (2.0 * dyOut[i] + dyOut[j]) / 3.0),
                control2: CGPoint(x: (dxOut[i] + 2.0 * dxOut[j]) / 3.0, y: (dyOut[i] + 2.0 * dyOut[j]) / 3.0)
            )
        }
        outPath.closeSubpath()
    }

    private static func addSmileArchStroke(
        _ path: inout Path,
        cx: CGFloat,
        cy: CGFloat,
        halfSpan: CGFloat,
        rise: CGFloat,
        ang: CGFloat
    ) {
        let c = cos(ang)
        let s = sin(ang)
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: cx + u * c - v * s, y: cy + u * s + v * c)
        }
        path.move(to: pt(-halfSpan, rise * 0.34))
        path.addQuadCurve(to: pt(halfSpan, rise * 0.34), control: pt(0, -rise * 1.16))
    }

    private static func addRotatedRectCW(
        _ path: inout Path,
        pivotX: CGFloat,
        pivotY: CGFloat,
        uMin: CGFloat,
        uMax: CGFloat,
        vMin: CGFloat,
        vMax: CGFloat,
        ang: CGFloat
    ) {
        let c = cos(ang)
        let s = sin(ang)
        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: pivotX + u * c - v * s, y: pivotY + u * s + v * c)
        }
        path.move(to: pt(uMin, vMin))
        path.addLine(to: pt(uMax, vMin))
        path.addLine(to: pt(uMax, vMax))
        path.addLine(to: pt(uMin, vMax))
        path.closeSubpath()
    }

    private static func drawExpressive25DEyes(
        in context: inout GraphicsContext,
        color: Color,
        sim: MascotSimState,
        headCx: CGFloat,
        headCy: CGFloat,
        sphereR: CGFloat,
        sepAng: CGFloat,
        baseW: CGFloat,
        baseH: CGFloat,
        scale: CGFloat,
        rotAngle: CGFloat
    ) {
        // True 3D spherical projection (yaw -> pitch on virtual sphere) so diagonal gaze follows curved latitude!
        let yaw = max(-0.60, min(0.60, sim.lookX * 0.56))
        let pitch = max(-0.46, min(0.46, sim.lookY * 0.44))

        let angL = yaw - sepAng
        let angR = yaw + sepAng

        let zL = cos(angL)
        let zR = cos(angR)
        let cosP = cos(pitch)
        let sinP = sin(pitch)

        let lxLocal = sphereR * sin(angL)
        let rxLocal = sphereR * sin(angR)
        let lyLocal = sphereR * 0.68 * zL * sinP + sim.eyeLY
        let ryLocal = sphereR * 0.68 * zR * sinP + sim.eyeRY

        let foreXL = max(0.42, min(1.0, zL))
        let foreXR = max(0.42, min(1.0, zR))
        let foreY = max(0.72, min(1.0, cosP))

        let c = cos(rotAngle)
        let s = sin(rotAngle)

        let wxL = headCx + (lxLocal * c - lyLocal * s) * scale
        let wyL = headCy + (lxLocal * s + lyLocal * c) * scale
        let wxR = headCx + (rxLocal * c - ryLocal * s) * scale
        let wyR = headCy + (rxLocal * s + ryLocal * c) * scale

        let perspTilt = yaw * 0.14 - yaw * pitch * 0.42
        let angEyeL = rotAngle + sim.eyeLTilt + perspTilt
        let angEyeR = rotAngle + sim.eyeRTilt + perspTilt

        // Direct biological blink (never attenuated by exponential smoothing!)
        let blinkFactor: CGFloat = (sim.activePose == .sleepy) ? 1.0 : max(0.0, sim.blinkOpen)
        let blinkWiden: CGFloat = lerp(1.16, 1.0, min(1.0, blinkFactor))
        let minShutH: CGFloat = max(1.20, 3.2 * scale)

        let rawWL = baseW * sim.eyeLW * foreXL * blinkWiden * scale
        let rawHL = max(minShutH, baseH * sim.eyeLH * foreY * blinkFactor * scale)
        let rawWR = baseW * sim.eyeRW * foreXR * blinkWiden * scale
        let rawHR = max(minShutH, baseH * sim.eyeRH * foreY * blinkFactor * scale)

        let smileAmt = max(0.0, min(1.0, sim.smileCurve))
        let archBlend = MascotController.smootherstep(0.28, 0.64, smileAmt)
        let preSmileCheekLift = MascotController.smootherstep(0.04, 0.42, smileAmt) * 0.48

        let effUpL = max(0.0, min(0.72, sim.upperLidL))
        let effUpR = max(0.0, min(0.72, sim.upperLidR))
        let effLowL = max(0.0, min(0.55, max(sim.lowerLidL, preSmileCheekLift)))
        let effLowR = max(0.0, min(0.55, max(sim.lowerLidR, preSmileCheekLift)))

        // 1. Pill eyes with crisp per-eye angled upper/lower eyelid masking (isolated per eye so lids never clip the neighbor eye!)
        let pillOpacity = Double(1.0 - archBlend)
        if pillOpacity > 0.02 {
            func drawSinglePillEye(
                cx: CGFloat,
                cy: CGFloat,
                w: CGFloat,
                h: CGFloat,
                eyeAng: CGFloat,
                up: CGFloat,
                upTilt: CGFloat,
                low: CGFloat
            ) {
                let hasLid = (blinkFactor > 0.25) && (up > 0.02 || low > 0.02)
                if hasLid {
                    context.drawLayer { eyeLayer in
                        var pEye = Path()
                        addRotatedPillCW(&pEye, cx: cx, cy: cy, w: w, h: h, ang: eyeAng)
                        eyeLayer.fill(pEye, with: .color(color.opacity(pillOpacity)))

                        var pLids = Path()
                        let span = max(w * 0.95, h * 0.65)
                        let clampedUp = min(up, 0.78 - low)
                        if clampedUp > 0.02 {
                            let edgeV = -h * 0.5 + h * clampedUp
                            let ec = cos(eyeAng), es = sin(eyeAng)
                            let px = cx - edgeV * es
                            let py = cy + edgeV * ec
                            addRotatedRectCW(
                                &pLids,
                                pivotX: px,
                                pivotY: py,
                                uMin: -span,
                                uMax: span,
                                vMin: -h * 1.4,
                                vMax: 0.0,
                                ang: eyeAng + upTilt
                            )
                        }
                        if low > 0.02 {
                            let edgeV = h * 0.5 - h * low
                            let ec = cos(eyeAng), es = sin(eyeAng)
                            let px = cx - edgeV * es
                            let py = cy + edgeV * ec
                            addRotatedRectCW(
                                &pLids,
                                pivotX: px,
                                pivotY: py,
                                uMin: -span,
                                uMax: span,
                                vMin: 0.0,
                                vMax: h * 1.4,
                                ang: eyeAng
                            )
                        }
                        eyeLayer.blendMode = .destinationOut
                        eyeLayer.fill(pLids, with: .color(.black))
                    }
                } else {
                    var pEye = Path()
                    addRotatedPillCW(&pEye, cx: cx, cy: cy, w: w, h: h, ang: eyeAng)
                    context.fill(pEye, with: .color(color.opacity(pillOpacity)))
                }
            }

            drawSinglePillEye(cx: wxL, cy: wyL, w: rawWL, h: rawHL, eyeAng: angEyeL, up: effUpL, upTilt: sim.upperLidTiltL, low: effLowL)
            drawSinglePillEye(cx: wxR, cy: wyR, w: rawWR, h: rawHR, eyeAng: angEyeR, up: effUpR, upTilt: sim.upperLidTiltR, low: effLowR)
        }

        // 2. Joyful beaming crescent smile arches (`◠ ◠`) driven continuously by `sim.smileCurve`!
        if archBlend > 0.02 {
            let strokeW = max(1.25, min(baseW * 0.45, 3.4) * scale)
            let spanL = max(rawWL * 0.72, 5.2 * foreXL * scale)
            let spanR = max(rawWR * 0.72, 5.2 * foreXR * scale)
            let archRise = max(2.0 * scale, min(baseH * 0.34, 5.2) * scale) * lerp(0.55, 1.0, archBlend) * min(1.0, blinkFactor)

            var pSmile = Path()
            addSmileArchStroke(&pSmile, cx: wxL, cy: wyL, halfSpan: spanL, rise: archRise, ang: rotAngle + perspTilt)
            addSmileArchStroke(&pSmile, cx: wxR, cy: wyR, halfSpan: spanR, rise: archRise, ang: rotAngle + perspTilt)
            context.stroke(
                pSmile,
                with: .color(color.opacity(Double(archBlend))),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private static func build8KnotBD(
        sim: MascotSimState,
        rest8: [CGPoint],
        puff8: [CGPoint],
        puffAmt: CGFloat,
        cx: CGFloat,
        cy: CGFloat,
        scale: CGFloat,
        inkPad: CGFloat,
        extraRot: CGFloat = 0.0,
        pInk: inout Path,
        pLight: inout Path,
        pShade: inout Path,
        pTerm: inout Path
    ) {
        let sx = exp(sim.squash) * sqrt(sim.gasScale)
        let sy = exp(-sim.squash) * sqrt(sim.gasScale)
        let totAng = sim.tiltRad + extraRot
        let cosT = cos(totAng)
        let sinT = sin(totAng)

        var kx = Array(repeating: CGFloat(0), count: 8)
        var ky = Array(repeating: CGFloat(0), count: 8)
        var ikx = Array(repeating: CGFloat(0), count: 8)
        var iky = Array(repeating: CGFloat(0), count: 8)
        let swayW: [CGFloat] = [0.30, 0.82, 1.00, 0.82, 0.30, -0.10, -0.22, -0.10]

        for i in 0..<8 {
            let r0 = rest8[i]
            let r1 = puff8[i]
            let lx = lerp(r0.x, r1.x, puffAmt) * sx + sim.swayShear * swayW[i] + sim.knots[i].x
            let ly = lerp(r0.y, r1.y, puffAmt) * sy + sim.knots[i].y

            let len = max(1.0, hypot(lx, ly))
            let nx = lx / len, ny = ly / len
            let weightBias = 0.76 + 0.38 * max(-0.6, min(1.0, nx * 0.65 + ny * 0.75))
            let padLocal = (inkPad / scale) * weightBias

            kx[i] = cx + (lx * cosT - ly * sinT) * scale
            ky[i] = cy + (lx * sinT + ly * cosT) * scale

            let ilx = lx + nx * padLocal + (0.28 / scale)
            let ily = ly + ny * padLocal + (0.36 / scale)
            ikx[i] = cx + (ilx * cosT - ily * sinT) * scale
            iky[i] = cy + (ilx * sinT + ily * cosT) * scale
        }

        var dummyX = Array(repeating: CGFloat(0), count: 8)
        var dummyY = Array(repeating: CGFloat(0), count: 8)
        var dx = Array(repeating: CGFloat(0), count: 8)
        var dy = Array(repeating: CGFloat(0), count: 8)

        emitClosedC2Path(&pInk, kx: ikx, ky: iky, weights: c2Weights8, dxOut: &dummyX, dyOut: &dummyY)
        emitClosedC2Path(&pLight, kx: kx, ky: ky, weights: c2Weights8, dxOut: &dx, dyOut: &dy)

        func segTo(_ p: inout Path, _ sIdx: Int) {
            let j = (sIdx + 1) % 8
            p.addCurve(
                to: CGPoint(x: kx[j], y: ky[j]),
                control1: CGPoint(x: (2.0 * dx[sIdx] + dx[j]) / 3.0, y: (2.0 * dy[sIdx] + dy[j]) / 3.0),
                control2: CGPoint(x: (dx[sIdx] + 2.0 * dx[j]) / 3.0, y: (dy[sIdx] + 2.0 * dy[j]) / 3.0)
            )
        }

        let c1 = CGPoint(x: lerp(kx[7], kx[4], 0.42), y: lerp(ky[7], ky[6], 0.25))
        let c2 = CGPoint(x: lerp(kx[3], kx[4], 0.36) - 4.0 * scale, y: lerp(ky[3], ky[5], 0.46))

        pShade.move(to: CGPoint(x: kx[3], y: ky[3]))
        segTo(&pShade, 3)
        segTo(&pShade, 4)
        segTo(&pShade, 5)
        segTo(&pShade, 6)
        pShade.addCurve(to: CGPoint(x: kx[3], y: ky[3]), control1: c1, control2: c2)
        pShade.closeSubpath()

        pTerm.move(to: CGPoint(x: kx[7], y: ky[7]))
        pTerm.addCurve(to: CGPoint(x: kx[3], y: ky[3]), control1: c1, control2: c2)
    }

    // MARK: - Master Top Mascot Renderer (Returns Exact World-Space Intake Point!)
    @discardableResult
    package static func drawTopMascot(
        in context: inout GraphicsContext,
        theme: MascotTheme,
        sim: MascotSimState,
        anchorX: CGFloat,
        anchorY: CGFloat,
        scale: CGFloat,
        isBig: Bool,
        includeShadow: Bool = true,
        includeBody: Bool = true,
        includeForepaws: Bool = true
    ) -> CGPoint {
        guard theme.isEnabled else {
            return CGPoint(x: anchorX, y: anchorY)
        }

        let inkPad: CGFloat = isBig ? 2.15 : 1.15
        let lineW: CGFloat = isBig ? 1.25 : 0.72
        let cx = anchorX
        let cy = anchorY + sim.boingY * scale
        let cosT = cos(sim.tiltRad)
        let sinT = sin(sim.tiltRad)

        func xf(_ lx: CGFloat, _ ly: CGFloat) -> CGPoint {
            CGPoint(
                x: cx + (lx * cosT - ly * sinT) * scale,
                y: cy + (lx * sinT + ly * cosT) * scale
            )
        }

        switch theme {
        case .forestCube:
            let sx = exp(sim.squash) * sqrt(sim.gasScale)
            let sy = exp(-sim.squash) * sqrt(sim.gasScale)
            // Keep feet & lower stone base planted on boxTopY while upper celadon lid hinges slightly upward!
            let slotOpen = max(0, min(1.0, sim.mawOpen)) * 11.4
            let lidLift = slotOpen * 0.68
            let retractDrop = max(0, min(1.0, sim.cubeLegRetract)) * 6.0
            let ridgeBotX = (12.0 - sim.lookX * 6.8) * sx
            let faceCenterLocalX = (-27.0 * sx + ridgeBotX) * 0.5
            let slotBotLocalY = 17.8 * sy + retractDrop
            let slotTopLocalY = slotBotLocalY - slotOpen
            let intakePt = xf(faceCenterLocalX, slotBotLocalY - slotOpen * 0.50)

            guard includeBody else { return intakePt }

            if includeShadow {
                var pShadow = Path()
                addEllipseCW(
                    &pShadow,
                    cx: anchorX + 1.5 * scale,
                    cy: anchorY + 30.5 * scale,
                    rx: (24.5 + sim.cubeLegRetract * 3.0) * scale,
                    ry: 4.0 * scale
                )
                context.fill(pShadow, with: .color(colPaperShadow))
            }

            var pPedInk = Path()
            var pPedFill = Path()
            let pedTL = xf(-14.0 * sx, 20.0 * sy + retractDrop)
            let pedTR = xf(14.0 * sx, 20.0 * sy + retractDrop)
            let pedBR = xf(10.0 * sx, 26.5 * sy + retractDrop)
            let pedBL = xf(-10.0 * sx, 26.5 * sy + retractDrop)
            addRoundedQuadCW(
                &pPedInk,
                CGPoint(x: pedTL.x - inkPad, y: pedTL.y - inkPad),
                CGPoint(x: pedTR.x + inkPad, y: pedTR.y - inkPad),
                CGPoint(x: pedBR.x + inkPad, y: pedBR.y + inkPad),
                CGPoint(x: pedBL.x - inkPad, y: pedBL.y + inkPad),
                radius: 2.5 * scale
            )
            addRoundedQuadCW(&pPedFill, pedTL, pedTR, pedBR, pedBL, radius: 2.0 * scale)

            var pBackInk = Path()
            let legVis = 1.0 - max(0, min(1.0, sim.cubeLegRetract * 1.08))
            if legVis > 0.06 {
                let leg1T = xf(-6.2, 25.5 * sy + retractDrop)
                let leg1B = xf(-6.2, 32.0)
                let leg2T = xf(6.2, 25.5 * sy + retractDrop)
                let leg2B = xf(6.2, 32.0)
                let legH1 = max(1.8 * scale, abs(leg1B.y - leg1T.y) * legVis)
                let legH2 = max(1.8 * scale, abs(leg2B.y - leg2T.y) * legVis)
                addRotatedPillCW(&pBackInk, cx: (leg1T.x + leg1B.x) * 0.5, cy: (leg1T.y + leg1B.y) * 0.5, w: 2.1 * scale, h: legH1, ang: sim.tiltRad)
                addRotatedPillCW(&pBackInk, cx: (leg2T.x + leg2B.x) * 0.5, cy: (leg2T.y + leg2B.y) * 0.5, w: 2.1 * scale, h: legH2, ang: sim.tiltRad)
            }

            let shiver = sim.cubeLeafShiver * 5.5
            let erectLift = abs(sim.cubeLeafShiver) * 3.5
            let stemB = xf(-2.0, -25.0 * sy - lidLift + retractDrop)
            let swayOff = sim.leafSway * 15.0 + shiver
            let stemM = xf(-2.0 + swayOff * 0.55, -36.5 * sy - lidLift + retractDrop)
            let cTip = xf(-2.0 + swayOff * 1.15, -53.5 * sy - lidLift - erectLift + retractDrop)
            let lTip = xf(-16.5 + swayOff * 0.95, -44.5 * sy - lidLift - erectLift + retractDrop)
            let rTip = xf(12.5 + swayOff * 0.95, -45.0 * sy - lidLift - erectLift + retractDrop)

            addLeafCW(&pBackInk, bx: stemM.x, by: stemM.y + 1.5 * scale, tx: lTip.x, ty: lTip.y, halfW: 5.0 * scale + inkPad * 0.85, bend: -2.2 * scale)
            addLeafCW(&pBackInk, bx: stemM.x, by: stemM.y + 1.5 * scale, tx: rTip.x, ty: rTip.y, halfW: 5.0 * scale + inkPad * 0.85, bend: 2.2 * scale)
            addLeafCW(&pBackInk, bx: stemM.x, by: stemM.y, tx: cTip.x, ty: cTip.y, halfW: 6.2 * scale + inkPad * 0.85, bend: swayOff * 0.15 * scale)

            var pSideLeaves = Path()
            var pCenterLeaf = Path()
            addLeafCW(&pSideLeaves, bx: stemM.x, by: stemM.y + 1.5 * scale, tx: lTip.x, ty: lTip.y, halfW: 4.9 * scale, bend: -2.2 * scale)
            addLeafCW(&pSideLeaves, bx: stemM.x, by: stemM.y + 1.5 * scale, tx: rTip.x, ty: rTip.y, halfW: 4.9 * scale, bend: 2.2 * scale)
            addLeafCW(&pCenterLeaf, bx: stemM.x, by: stemM.y, tx: cTip.x, ty: cTip.y, halfW: 6.1 * scale, bend: swayOff * 0.15 * scale)

            context.fill(pBackInk, with: .color(colInkPen))
            context.fill(pPedInk, with: .color(colInkPen))
            context.fill(pPedFill, with: .color(Color(red: 96 / 255, green: 124 / 255, blue: 125 / 255)))
            context.fill(pSideLeaves, with: .color(Color(red: 202 / 255, green: 86 / 255, blue: 72 / 255)))
            context.fill(pCenterLeaf, with: .color(Color(red: 229 / 255, green: 108 / 255, blue: 90 / 255)))

            let topY = -25.5 * sy - lidLift + retractDrop
            let botY = 21.0 * sy + retractDrop
            let shearTop = sim.swayShear * 0.65
            let ridgeTopX = (13.5 - sim.lookX * 7.5) * sx + shearTop

            let tl = xf(-28.5 * sx + shearTop, topY)
            let tr = xf(27.5 * sx + shearTop, topY + 1.2)
            let br = xf(24.8 * sx, botY)
            let bl = xf(-25.8 * sx, botY)
            let rt = xf(ridgeTopX, topY + 0.5)
            let rb = xf(ridgeBotX, botY + 0.4)

            var pInkHull = Path()
            var pBodyLight = Path()
            var pBodyShade = Path()
            addRoundedQuadCW(
                &pInkHull,
                CGPoint(x: tl.x - inkPad * 0.9, y: tl.y - inkPad * 0.9),
                CGPoint(x: tr.x + inkPad * 1.1, y: tr.y - inkPad * 0.85),
                CGPoint(x: br.x + inkPad * 1.2, y: br.y + inkPad * 1.2),
                CGPoint(x: bl.x - inkPad * 0.95, y: bl.y + inkPad * 1.1),
                radius: 4.8 * scale
            )
            addRoundedQuadCW(&pBodyLight, tl, tr, br, bl, radius: 4.2 * scale)
            addRoundedQuadCW(&pBodyShade, rt, tr, br, rb, radius: 3.8 * scale)

            context.fill(pInkHull, with: .color(colInkPen))
            context.fill(pBodyLight, with: .color(Color(red: 190 / 255, green: 211 / 255, blue: 203 / 255)))
            context.fill(pBodyShade, with: .color(Color(red: 114 / 255, green: 146 / 255, blue: 146 / 255).opacity(0.92)))

            var pTerm = Path()
            pTerm.move(to: stemB)
            pTerm.addCurve(
                to: stemM,
                control1: CGPoint(x: lerp(stemB.x, stemM.x, 0.5), y: lerp(stemB.y, stemM.y, 0.5)),
                control2: CGPoint(x: stemM.x, y: stemM.y + 2.0 * scale)
            )
            pTerm.move(to: CGPoint(x: rt.x, y: rt.y + 1.5 * scale))
            pTerm.addLine(to: CGPoint(x: rb.x, y: rb.y - 1.5 * scale))
            let crk = xf(-12.5 * sx + shearTop, topY)
            let crkB = xf(-9.5 * sx + shearTop, topY + 6.5)
            pTerm.move(to: crk)
            pTerm.addLine(to: crkB)
            context.stroke(
                pTerm,
                with: .color(Color(red: 62 / 255, green: 84 / 255, blue: 86 / 255).opacity(0.78)),
                style: StrokeStyle(lineWidth: lineW * 1.15, lineCap: .round, lineJoin: .round)
            )

            if sim.cubeEmberGlow > 0.05 {
                var pEmber = Path()
                pEmber.move(to: CGPoint(x: crk.x, y: crk.y + 0.5 * scale))
                pEmber.addLine(to: crkB)
                let eL = xf(faceCenterLocalX - 9.0, slotBotLocalY - 1.8)
                let eR = xf(faceCenterLocalX + 9.0, slotBotLocalY - 1.8)
                pEmber.move(to: eL)
                pEmber.addLine(to: eR)
                context.stroke(
                    pEmber,
                    with: .color(Color(red: 244 / 255, green: 184 / 255, blue: 92 / 255).opacity(0.92 * Double(sim.cubeEmberGlow))),
                    style: StrokeStyle(lineWidth: max(1.0, lineW * 1.45), lineCap: .round)
                )
            }

            if slotOpen > 0.35 {
                var pSlot = Path()
                let sL = xf(faceCenterLocalX - 12.8, slotTopLocalY - 0.8)
                let sR = xf(faceCenterLocalX + 12.8, slotTopLocalY - 0.8)
                let sBR = xf(faceCenterLocalX + 12.0, slotBotLocalY + 0.4)
                let sBL = xf(faceCenterLocalX - 12.0, slotBotLocalY + 0.4)
                addRoundedQuadCW(&pSlot, sL, sR, sBR, sBL, radius: 3.0 * scale)
                context.fill(pSlot, with: .color(Color(red: 46 / 255, green: 35 / 255, blue: 34 / 255)))

                var pGlow = Path()
                let glowC = xf(faceCenterLocalX, slotBotLocalY - slotOpen * 0.48)
                addEllipseCW(&pGlow, cx: glowC.x, cy: glowC.y, rx: 7.6 * scale, ry: max(1.3, slotOpen * 0.36) * scale)
                context.fill(pGlow, with: .color(Color(red: 238 / 255, green: 170 / 255, blue: 96 / 255).opacity(0.95)))
            } else if sim.stuffedCheeks > 0.20 {
                // Rosy celadon cheek puffs + flexing closed drawer seam while munching the swallowed link!
                var pBlush = Path()
                let bL = xf(faceCenterLocalX - 11.2, slotBotLocalY - 5.2)
                let bR = xf(faceCenterLocalX + 11.2, slotBotLocalY - 5.2)
                addEllipseCW(&pBlush, cx: bL.x, cy: bL.y, rx: 4.4 * scale, ry: 2.5 * scale)
                addEllipseCW(&pBlush, cx: bR.x, cy: bR.y, rx: 4.4 * scale, ry: 2.5 * scale)
                context.fill(pBlush, with: .color(Color(red: 229 / 255, green: 120 / 255, blue: 102 / 255).opacity(0.55 * Double(sim.stuffedCheeks))))

                var pMunch = Path()
                let mL = xf(faceCenterLocalX - 8.5, slotBotLocalY - 2.2)
                let mR = xf(faceCenterLocalX + 8.5, slotBotLocalY - 2.2)
                let wob = sin(sim.haloSpin * 9.0) * 1.4 * scale
                pMunch.move(to: mL)
                pMunch.addCurve(
                    to: mR,
                    control1: CGPoint(x: lerp(mL.x, mR.x, 0.35), y: mL.y + wob),
                    control2: CGPoint(x: lerp(mL.x, mR.x, 0.65), y: mR.y - wob)
                )
                context.stroke(pMunch, with: .color(colInkPen), style: StrokeStyle(lineWidth: max(0.85, lineW * 1.15), lineCap: .round))
            }

            let eyeCenter = xf(faceCenterLocalX, 5.8 * sy - slotOpen * 0.65 + retractDrop)
            drawExpressive25DEyes(
                in: &context,
                color: colInkPen,
                sim: sim,
                headCx: eyeCenter.x,
                headCy: eyeCenter.y,
                sphereR: 12.8,
                sepAng: 0.40,
                baseW: 5.4,
                baseH: 9.4,
                scale: scale,
                rotAngle: sim.tiltRad
            )

            return intakePt

        case .roundMochi:
            let puff = max(0, min(1.0, sim.mawOpen))
            let intakePt = xf(sim.lookX * 4.8, 9.8)

            if includeBody {
                if includeShadow {
                    var pShadow = Path()
                    addEllipseCW(&pShadow, cx: anchorX + 1.5 * scale, cy: anchorY + 25.0 * scale, rx: 26.5 * scale, ry: 4.2 * scale)
                    context.fill(pShadow, with: .color(colPaperShadow))
                }

                var pInk = Path()
                var pLight = Path()
                var pShade = Path()
                var pTerm = Path()
                build8KnotBD(sim: sim, rest8: mochiPuff8, puff8: mochiOpen8, puffAmt: puff, cx: cx, cy: cy, scale: scale, inkPad: inkPad, pInk: &pInk, pLight: &pLight, pShade: &pShade, pTerm: &pTerm)

                context.fill(pInk, with: .color(colInkPen))
                context.fill(pLight, with: .color(Color(red: 252 / 255, green: 249 / 255, blue: 241 / 255)))
                context.fill(pShade, with: .color(Color(red: 218 / 255, green: 210 / 255, blue: 192 / 255).opacity(0.76)))
                context.stroke(
                    pTerm,
                    with: .color(Color(red: 182 / 255, green: 172 / 255, blue: 154 / 255).opacity(0.55)),
                    style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)
                )

                var pBlush = Path()
                let cheekPuff = sim.stuffedCheeks * 2.4 + sim.mochiPawShy * 1.8
                let bL = xf(-18.2 + sim.lookX * 4.2, 5.8 - puff * 1.2)
                let bR = xf(18.2 + sim.lookX * 4.2, 5.8 - puff * 1.2)
                addEllipseCW(&pBlush, cx: bL.x, cy: bL.y, rx: (5.8 + cheekPuff) * scale, ry: (3.3 + cheekPuff * 0.55) * scale)
                addEllipseCW(&pBlush, cx: bR.x, cy: bR.y, rx: (5.8 + cheekPuff) * scale, ry: (3.3 + cheekPuff * 0.55) * scale)
                let blushBoost = max(Double(sim.stuffedCheeks), Double(sim.mochiPawShy))
                context.fill(pBlush, with: .color(Color(red: 232 / 255, green: 152 / 255, blue: 138 / 255).opacity(0.55 + blushBoost * 0.24)))

                if puff > 0.05 {
                    var pMouth = Path()
                    addEllipseCW(&pMouth, cx: intakePt.x, cy: intakePt.y, rx: (2.4 + puff * 5.6) * scale, ry: (2.2 + puff * 5.8) * scale)
                    context.fill(pMouth, with: .color(Color(red: 76 / 255, green: 44 / 255, blue: 48 / 255)))
                } else if sim.stuffedCheeks > 0.20 && sim.mochiPawShy < 0.25 {
                    // Cute wobbling closed-lip `w` munch dimple while chewing the swallowed link!
                    var pChew = Path()
                    let wob = sin(sim.haloSpin * 9.0) * 0.9 * scale
                    let cPt = xf(sim.lookX * 3.0, 9.5)
                    pChew.move(to: CGPoint(x: cPt.x - 4.2 * scale, y: cPt.y - 0.8 * scale + wob * 0.4))
                    pChew.addCurve(
                        to: CGPoint(x: cPt.x + 4.2 * scale, y: cPt.y - 0.8 * scale - wob * 0.4),
                        control1: CGPoint(x: cPt.x - 1.4 * scale, y: cPt.y + 2.2 * scale),
                        control2: CGPoint(x: cPt.x + 1.4 * scale, y: cPt.y + 2.2 * scale)
                    )
                    context.stroke(pChew, with: .color(colInkPen), style: StrokeStyle(lineWidth: max(0.88, lineW * 1.18), lineCap: .round))
                }

                let eyeCenter = xf(0.0, 1.0 - puff * 2.2)
                drawExpressive25DEyes(
                    in: &context,
                    color: colInkPen,
                    sim: sim,
                    headCx: eyeCenter.x,
                    headCy: eyeCenter.y,
                    sphereR: 17.5,
                    sepAng: 0.48,
                    baseW: 5.9,
                    baseH: 8.4,
                    scale: scale,
                    rotAngle: sim.tiltRad
                )
            }

            if includeForepaws {
                let slp = max(0, min(1.0, sim.mochiSleepBubble))
                let shy = max(0, min(1.0, sim.mochiPawShy))

                // Dreamy inflating/deflating translucent sleep bubble (`鼻泡泡`) floating off the right cheek!
                if slp > 0.06 {
                    let bubPulse = 0.5 + 0.5 * sin(sim.haloSpin * 1.15)
                    let bubR = (5.4 + bubPulse * 3.6) * scale * slp
                    let bubPt = xf(24.5 + bubPulse * 3.5, -2.5 - bubPulse * 3.5)
                    var pBubInk = Path()
                    var pBubFill = Path()
                    var pBubSpec = Path()
                    addCircleCW(&pBubInk, cx: bubPt.x, cy: bubPt.y, r: bubR + inkPad * 0.48)
                    addCircleCW(&pBubFill, cx: bubPt.x, cy: bubPt.y, r: bubR)
                    addCircleCW(&pBubSpec, cx: bubPt.x - bubR * 0.34, cy: bubPt.y - bubR * 0.34, r: bubR * 0.28)
                    context.fill(pBubInk, with: .color(colInkPen.opacity(0.72 * Double(slp))))
                    context.fill(pBubFill, with: .color(Color(red: 226 / 255, green: 241 / 255, blue: 249 / 255).opacity(0.82 * Double(slp))))
                    context.fill(pBubSpec, with: .color(Color.white.opacity(0.92 * Double(slp))))
                }

                // Forepaws smoothly transition between Rim Rest, Sleep Chin-Tuck (`slp`), and Shy Cheek-Cupping (`shy`)!
                let tapLift = sin(sim.pawTapPhase * .pi) * 4.8
                let kneadL = sin(sim.haloSpin * 4.5) * 2.2 * puff
                let kneadR = -kneadL

                let baseL = CGPoint(
                    x: cx - (16.8 - slp * 8.6) * scale,
                    y: anchorY + (21.2 - tapLift - max(0, kneadL)) * scale
                )
                let baseR = CGPoint(
                    x: cx + (16.8 - slp * 8.6) * scale,
                    y: anchorY + (21.2 - max(0, kneadR)) * scale
                )
                let shyL = xf(-16.2, 8.8)
                let shyR = xf(16.2, 8.8)

                let pL = CGPoint(x: lerp(baseL.x, shyL.x, shy), y: lerp(baseL.y, shyL.y, shy))
                let pR = CGPoint(x: lerp(baseR.x, shyR.x, shy), y: lerp(baseR.y, shyR.y, shy))
                let angL = lerp(-0.18 + slp * 0.12, 0.52, shy)
                let angR = lerp(0.18 - slp * 0.12, -0.52, shy)

                var pFrontInk = Path()
                var pFrontFill = Path()
                var pFrontPads = Path()
                addRotatedPillCW(&pFrontInk, cx: pL.x, cy: pL.y, w: 13.6 * scale + inkPad * 1.7, h: 9.8 * scale + inkPad * 1.7, ang: angL)
                addRotatedPillCW(&pFrontInk, cx: pR.x, cy: pR.y, w: 13.6 * scale + inkPad * 1.7, h: 9.8 * scale + inkPad * 1.7, ang: angR)
                addRotatedPillCW(&pFrontFill, cx: pL.x, cy: pL.y, w: 13.6 * scale, h: 9.8 * scale, ang: angL)
                addRotatedPillCW(&pFrontFill, cx: pR.x, cy: pR.y, w: 13.6 * scale, h: 9.8 * scale, ang: angR)
                addEllipseCW(&pFrontPads, cx: pL.x, cy: pL.y + 1.0 * scale, rx: 3.8 * scale, ry: 2.4 * scale)
                addEllipseCW(&pFrontPads, cx: pR.x, cy: pR.y + 1.0 * scale, rx: 3.8 * scale, ry: 2.4 * scale)

                context.fill(pFrontInk, with: .color(colInkPen))
                context.fill(pFrontFill, with: .color(Color(red: 252 / 255, green: 249 / 255, blue: 241 / 255)))
                context.fill(pFrontPads, with: .color(Color(red: 232 / 255, green: 174 / 255, blue: 160 / 255).opacity(0.80)))
            }

            return intakePt

        case .grokAstral:
            let puff = max(0, min(1.0, sim.mawOpen))
            let floatBob = sin(sim.haloSpin * 1.25) * 2.8 * scale
            let orbCy = cy - 12.5 * scale + floatBob
            let bodyRot = sim.tiltRad + sim.grokRollAngle
            let mouthCenter = CGPoint(
                x: cx + sim.lookX * 4.8 * scale,
                y: orbCy + 10.2 * scale
            )
            let intakePt = mouthCenter

            guard includeBody else { return intakePt }

            if includeShadow {
                var pShadow = Path()
                addEllipseCW(&pShadow, cx: anchorX + 1.5 * scale, cy: anchorY + 30.5 * scale, rx: 16.5 * scale, ry: 2.7 * scale)
                context.fill(pShadow, with: .color(colPaperShadow))
            }

            let ringTilt = -0.22 + sim.ringLagTilt
            let ringRx = (43.0 + puff * 4.5) * scale
            let ringRy = (11.5 + puff * 2.6) * scale
            let ringCy = orbCy + (2.0 + puff * 4.2) * scale
            var pBackRing = Path()
            var pFrontRing = Path()
            addTiltedRingArcs(back: &pBackRing, front: &pFrontRing, cx: cx, cy: ringCy, rx: ringRx, ry: ringRy, ang: ringTilt)

            context.stroke(
                pBackRing,
                with: .color(Color(red: 214 / 255, green: 164 / 255, blue: 88 / 255).opacity(0.85)),
                style: StrokeStyle(lineWidth: lineW * 1.35, lineCap: .round, lineJoin: .round)
            )

            let mAng = sim.haloSpin * 0.95
            let cR = cos(ringTilt), sR = sin(ringTilt)
            let mu = cos(mAng) * ringRx, mv = sin(mAng) * ringRy
            let moonPt = CGPoint(x: cx + mu * cR - mv * sR, y: ringCy + mu * sR + mv * cR)

            if sin(mAng) <= 0 {
                var pMInk = Path()
                var pMFill = Path()
                addCircleCW(&pMInk, cx: moonPt.x, cy: moonPt.y, r: 3.4 * scale + inkPad * 0.7)
                addCircleCW(&pMFill, cx: moonPt.x, cy: moonPt.y, r: 3.3 * scale)
                context.fill(pMInk, with: .color(colInkPen))
                context.fill(pMFill, with: .color(Color(red: 244 / 255, green: 204 / 255, blue: 118 / 255)))
            }

            var pInk = Path()
            var pLight = Path()
            var pShade = Path()
            var pTerm = Path()
            build8KnotBD(
                sim: sim,
                rest8: grokOrbBody8,
                puff8: grokOrbPuff8,
                puffAmt: max(puff, sim.stuffedCheeks * 0.75),
                cx: cx,
                cy: orbCy,
                scale: scale,
                inkPad: inkPad,
                extraRot: sim.grokRollAngle,
                pInk: &pInk,
                pLight: &pLight,
                pShade: &pShade,
                pTerm: &pTerm
            )

            context.fill(pInk, with: .color(colInkPen))
            context.fill(pLight, with: .color(Color(red: 232 / 255, green: 132 / 255, blue: 100 / 255)))
            context.fill(pShade, with: .color(Color(red: 184 / 255, green: 88 / 255, blue: 62 / 255).opacity(0.73)))
            context.stroke(
                pTerm,
                with: .color(Color(red: 146 / 255, green: 64 / 255, blue: 44 / 255).opacity(0.58)),
                style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)
            )

            let eyeOffY = -(1.2 + puff * 5.2) * scale
            let eyeWorldX = cx - eyeOffY * sin(bodyRot)
            let eyeWorldY = orbCy + eyeOffY * cos(bodyRot)
            drawExpressive25DEyes(
                in: &context,
                color: Color(red: 38 / 255, green: 24 / 255, blue: 20 / 255),
                sim: sim,
                headCx: eyeWorldX,
                headCy: eyeWorldY,
                sphereR: 18.0,
                sepAng: 0.40,
                baseW: 7.4,
                baseH: 20.4 - puff * 4.8,
                scale: scale,
                rotAngle: bodyRot
            )

            if puff > 0.05 {
                // Crisp espresso-gold singularity mouth opening below the `||` eyes so chomp & swallow feel physical!
                var pVortex = Path()
                addEllipseCW(&pVortex, cx: mouthCenter.x, cy: mouthCenter.y, rx: (2.4 + puff * 5.4) * scale, ry: (2.2 + puff * 5.4) * scale)
                context.fill(pVortex, with: .color(Color(red: 38 / 255, green: 24 / 255, blue: 20 / 255)))
                var pCore = Path()
                addEllipseCW(&pCore, cx: mouthCenter.x, cy: mouthCenter.y, rx: (1.0 + puff * 2.4) * scale, ry: (0.9 + puff * 2.2) * scale)
                context.fill(pCore, with: .color(Color(red: 244 / 255, green: 198 / 255, blue: 108 / 255).opacity(0.92)))
            } else if sim.stuffedCheeks > 0.20 {
                var pChew = Path()
                pChew.move(to: CGPoint(x: mouthCenter.x - 4.0 * scale, y: mouthCenter.y - 0.6 * scale))
                pChew.addCurve(
                    to: CGPoint(x: mouthCenter.x + 4.0 * scale, y: mouthCenter.y - 0.6 * scale),
                    control1: CGPoint(x: mouthCenter.x - 1.3 * scale, y: mouthCenter.y + 1.8 * scale),
                    control2: CGPoint(x: mouthCenter.x + 1.3 * scale, y: mouthCenter.y + 1.8 * scale)
                )
                context.stroke(pChew, with: .color(Color(red: 38 / 255, green: 24 / 255, blue: 20 / 255)), style: StrokeStyle(lineWidth: max(0.88, lineW * 1.18), lineCap: .round))
            }

            context.stroke(
                pFrontRing,
                with: .color(Color(red: 232 / 255, green: 184 / 255, blue: 98 / 255).opacity(0.95)),
                style: StrokeStyle(lineWidth: lineW * 1.45, lineCap: .round, lineJoin: .round)
            )

            if sin(mAng) > 0 {
                var pMInk = Path()
                var pMFill = Path()
                addCircleCW(&pMInk, cx: moonPt.x, cy: moonPt.y, r: 3.6 * scale + inkPad * 0.75)
                addCircleCW(&pMFill, cx: moonPt.x, cy: moonPt.y, r: 3.5 * scale)
                context.fill(pMInk, with: .color(colInkPen))
                context.fill(pMFill, with: .color(Color(red: 246 / 255, green: 210 / 255, blue: 126 / 255)))
            }

            return intakePt

        case .none:
            return CGPoint(x: anchorX, y: anchorY)
        }
    }

    // MARK: - Physical Intact-Ribbon Siphon + Mouth-Interior Hard Clip + Chomp Sparks!
    package static func drawIntakeEffects(
        in context: inout GraphicsContext,
        frame: MascotTopRenderFrame,
        intakePoint: CGPoint,
        isDark: Bool = false
    ) {
        guard frame.theme.isEnabled, frame.mode != .idle else { return }

        let chars = Array(frame.siphonText)
        guard !chars.isEmpty else { return }

        let siphonExtra: CGFloat = (frame.mode == .multiDrop) ? 0.14 : 0.0
        let tLock: CGFloat = 0.03
        let tApproachEnd: CGFloat = 0.62
        let tSlurpEnd: CGFloat = 1.36 + siphonExtra

        let originStartX: CGFloat = 12.5
        let originY: CGFloat = frame.boxTopY + 18.0
        let accentCol = seamColor(for: frame.theme)

        func siphonInkColor(blend: CGFloat) -> Color {
            let b = Double(max(0.0, min(1.0, blend)))
            let (r1, g1, b1): (Double, Double, Double) = isDark
                ? (236.0 / 255.0, 238.0 / 255.0, 242.0 / 255.0)
                : (29.0 / 255.0, 30.0 / 255.0, 32.0 / 255.0)
            let (r2, g2, b2): (Double, Double, Double) = switch frame.theme {
            case .forestCube:
                isDark ? (122.0 / 255.0, 202.0 / 255.0, 190.0 / 255.0) : (54.0 / 255.0, 118.0 / 255.0, 110.0 / 255.0)
            case .roundMochi:
                isDark ? (240.0 / 255.0, 156.0 / 255.0, 142.0 / 255.0) : (192.0 / 255.0, 98.0 / 255.0, 86.0 / 255.0)
            case .grokAstral:
                isDark ? (238.0 / 255.0, 142.0 / 255.0, 106.0 / 255.0) : (188.0 / 255.0, 86.0 / 255.0, 56.0 / 255.0)
            case .none:
                (r1, g1, b1)
            }
            return Color(
                red: r1 + (r2 - r1) * b,
                green: g1 + (g2 - g1) * b,
                blue: b1 + (b2 - b1) * b
            )
        }

        // Measure exact proportional SF Pro glyph advances (uniform .medium weight -> zero bold-pop flicker!)
        var baseResolved: [GraphicsContext.ResolvedText] = []
        var charOrigins: [CGFloat] = []
        baseResolved.reserveCapacity(chars.count)
        charOrigins.reserveCapacity(chars.count)

        var cursorX = originStartX
        for ch in chars {
            let s = String(ch)
            let resDark = context.resolve(
                Text(s)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(.t3TextMain)
            )
            let w = max(3.3, resDark.measure(in: CGSize(width: 100, height: 30)).width + 0.15)
            baseResolved.append(resDark)
            charOrigins.append(cursorX + w * 0.5)
            cursorX += w
        }

        if frame.mode == .reject {
            let fadeOut = 1.0 - MascotController.smootherstep(0.86, 1.22, frame.animT)
            guard fadeOut > 0.02 else { return }

            let sniffLift = sin(max(0, min(1, (frame.animT - 0.04) / 0.52)) * .pi)
            let count = chars.count
            for idx in 0..<count {
                let tailProximity = max(0, CGFloat(idx - max(0, count - 6)) / 6.0)
                let lift = sniffLift * tailProximity
                let gx = lerp(charOrigins[idx] + frame.boxShakeX, intakePoint.x - 18.0, lift * 0.28)
                let gy = lerp(originY, intakePoint.y + 4.0, lift * 0.38)
                let resolved = context.resolve(
                    Text(String(chars[idx]))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color.t3TextMain.opacity(fadeOut))
                )
                context.draw(resolved, at: CGPoint(x: gx, y: gy), anchor: .center)
            }
            return
        }

        // 1. Crisp Bande-Dessinée `CHOMP!` Impact Sparks right when the jaw snaps shut on the last character!
        let chompLocalT = (frame.animT - (tSlurpEnd - 0.02)) / 0.24
        if chompLocalT > 0.0 && chompLocalT < 1.0 {
            let pop = MascotController.smootherstep(0.0, 0.28, chompLocalT)
            let fade = 1.0 - MascotController.smootherstep(0.45, 1.0, chompLocalT)
            let angles: [CGFloat] = [.pi * 0.80, .pi, .pi * 1.20]
            var pTicks = Path()
            for (k, ang) in angles.enumerated() {
                let rIn = lerp(5.0, 11.5, pop) + CGFloat(k % 2) * 1.5
                let rOut = rIn + lerp(5.2, 1.8, chompLocalT)
                let c = cos(ang), s = sin(ang)
                let basePt = CGPoint(x: intakePoint.x - 3.0, y: intakePoint.y)
                pTicks.move(to: CGPoint(x: basePt.x + c * rIn, y: basePt.y + s * rIn))
                pTicks.addLine(to: CGPoint(x: basePt.x + c * rOut, y: basePt.y + s * rOut))
            }
            context.stroke(
                pTicks,
                with: .color(colInkPen.opacity(Double(fade))),
                style: StrokeStyle(lineWidth: 1.55, lineCap: .round)
            )

            var pSparkDot = Path()
            addCircleCW(
                &pSparkDot,
                cx: intakePoint.x - lerp(6.0, 14.0, pop),
                cy: intakePoint.y - lerp(3.0, 7.5, pop),
                r: 1.6 * fade
            )
            context.fill(pSparkDot, with: .color(accentCol.opacity(Double(fade))))
        }

        guard frame.animT <= tSlurpEnd + 0.03 else { return }

        // 2. Build sweeping C1 S-arch Conveyor Track (`liftX` ~232pt before mouth so Phase 1 lifts gracefully!)
        let rightEndX = charOrigins.last ?? originStartX
        let liftX = min(intakePoint.x - 108.0, max(originStartX + 46.0, intakePoint.x - 232.0))
        let p0 = CGPoint(x: liftX, y: originY)
        let p1 = CGPoint(x: lerp(liftX, intakePoint.x, 0.46), y: originY)
        let p2 = CGPoint(x: intakePoint.x - 46.0, y: intakePoint.y + 1.0)
        let p3 = CGPoint(x: intakePoint.x + 3.5, y: intakePoint.y)

        let samples = 48
        var arcS = Array(repeating: CGFloat(0), count: samples + 1)
        var arcPt = Array(repeating: p0, count: samples + 1)
        var arcAng = Array(repeating: CGFloat(0), count: samples + 1)

        func bezierPt(_ u: CGFloat) -> CGPoint {
            let om = 1.0 - u
            let b0 = om * om * om
            let b1 = 3.0 * om * om * u
            let b2 = 3.0 * om * u * u
            let b3 = u * u * u
            return CGPoint(
                x: b0 * p0.x + b1 * p1.x + b2 * p2.x + b3 * p3.x,
                y: b0 * p0.y + b1 * p1.y + b2 * p2.y + b3 * p3.y
            )
        }

        func bezierTan(_ u: CGFloat) -> CGPoint {
            let om = 1.0 - u
            let d0 = 3.0 * om * om
            let d1 = 6.0 * om * u
            let d2 = 3.0 * u * u
            return CGPoint(
                x: d0 * (p1.x - p0.x) + d1 * (p2.x - p1.x) + d2 * (p3.x - p2.x),
                y: d0 * (p1.y - p0.y) + d1 * (p2.y - p1.y) + d2 * (p3.y - p2.y)
            )
        }

        var accum: CGFloat = 0
        for i in 0...samples {
            let u = CGFloat(i) / CGFloat(samples)
            let pt = bezierPt(u)
            let tg = bezierTan(u)
            if i > 0 {
                accum += hypot(pt.x - arcPt[i - 1].x, pt.y - arcPt[i - 1].y)
            }
            arcS[i] = accum
            arcPt[i] = pt
            arcAng[i] = atan2(tg.y, tg.x)
        }
        let curveLen = max(1.0, accum)
        let leadTravel = max(12.0, (liftX - rightEndX) + curveLen - 5.0)
        let bodyTravel = max(24.0, (rightEndX - charOrigins[0]) + 12.0)
        let approachDur = max(0.15, tApproachEnd - tLock)
        let eatDuration = max(0.25, tSlurpEnd - tApproachEnd)
        let vJoin = (1.08 * bodyTravel) / eatDuration

        // Phase 1 (`0.04..0.86s`): silky, readable C1 Hermite glide (~360-480 pt/s, zero blur!) matching mouth entry velocity `vJoin`!
        // Phase 2 (`0.86..1.82s`): 0.96s of steady, chewy, jaw-ratcheted ingestion INSIDE the mouth with a crisp tail-whip!
        let feedDist: CGFloat
        if frame.animT <= tLock {
            let p = max(0.0, frame.animT / max(0.01, tLock))
            feedDist = p * p * 0.8
        } else if frame.animT <= tApproachEnd {
            let u = max(0.0, min(1.0, (frame.animT - tLock) / approachDur))
            let u2 = u * u
            let u3 = u2 * u
            let h01 = -2.0 * u3 + 3.0 * u2
            let h11 = u3 - u2
            let m1 = min(leadTravel * 2.35, vJoin * approachDur)
            feedDist = 0.8 + (leadTravel - 0.8) * h01 + m1 * h11
        } else {
            let w = max(0.0, min(1.0, (frame.animT - tApproachEnd) / eatDuration))
            let w2 = w * w
            let baseFeed = bodyTravel * (1.08 * w - 0.22 * w2 + 0.14 * w2 * w)
            let nibbleAngle = (frame.animT - tApproachEnd) * 58.0
            let ratchet = (1.0 - cos(nibbleAngle)) * 1.65 * sin(w * .pi)
            feedDist = leadTravel + baseFeed + ratchet
        }

        func sampleCurve(at s: CGFloat) -> (pt: CGPoint, ang: CGFloat, frac: CGFloat) {
            let clamped = max(0.0, min(curveLen, s))
            var lo = 0
            var hi = samples
            while lo + 1 < hi {
                let mid = (lo + hi) / 2
                if arcS[mid] <= clamped {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            let segLen = max(0.0001, arcS[hi] - arcS[lo])
            let t = (clamped - arcS[lo]) / segLen
            let frac = clamped / curveLen
            let baseX = lerp(arcPt[lo].x, arcPt[hi].x, t)
            let baseY = lerp(arcPt[lo].y, arcPt[hi].y, t)
            let ang = lerp(arcAng[lo], arcAng[hi], t)
            let waveAmp = sin(clamped * 0.052 - frame.animT * 8.2) * 1.15 * sin(frac * .pi)
            let pt = CGPoint(
                x: baseX - sin(ang) * waveAmp,
                y: baseY + cos(ang) * waveAmp
            )
            return (pt, ang, frac)
        }

        let headTrackX = rightEndX + feedDist
        let tailTrackX = charOrigins[0] + feedDist
        let headPt: CGPoint = (headTrackX <= liftX)
            ? CGPoint(x: headTrackX, y: originY)
            : sampleCurve(at: headTrackX - liftX).pt

        // 3A. Phase 1 Organic Hand-Inked Inhale Wisps right in front of the open mouth (no mechanical long dashed tracks!)
        let mouthGap = intakePoint.x - headPt.x
        if frame.animT > 0.04 && mouthGap > 10.0 {
            let inhaleIn = MascotController.smootherstep(0.04, 0.22, frame.animT)
            let inhaleOut = MascotController.smootherstep(10.0, 38.0, mouthGap)
            let envAlpha = inhaleIn * inhaleOut

            for k in 0..<2 {
                let side: CGFloat = (k == 0) ? -1.0 : 1.0
                let cyc = (frame.animT * 2.35 + CGFloat(k) * 0.5).truncatingRemainder(dividingBy: 1.0)
                let wispBell = sin(cyc * .pi)
                let distOut = lerp(46.0, 6.0, cyc)
                let wispLen = lerp(22.0, 11.0, cyc)
                let ePt = CGPoint(
                    x: intakePoint.x - distOut,
                    y: intakePoint.y + side * lerp(4.2, 1.1, cyc) + lerp(3.5, 0.0, cyc)
                )
                let sPt = CGPoint(
                    x: ePt.x - wispLen,
                    y: ePt.y + side * 2.2 + 2.6
                )
                var pWisp = Path()
                pWisp.move(to: sPt)
                pWisp.addCurve(
                    to: ePt,
                    control1: CGPoint(x: lerp(sPt.x, ePt.x, 0.45), y: sPt.y - side * 0.6),
                    control2: CGPoint(x: lerp(sPt.x, ePt.x, 0.78), y: ePt.y + side * 0.4)
                )
                context.stroke(
                    pWisp,
                    with: .color(accentCol.opacity(Double(0.46 * envAlpha * wispBell))),
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
                )
            }
        }

        // 3B. Soft watercolor air-cushion & 2.5D paper shadow under the lifted portion of the URL
        if headTrackX > liftX + 8.0 && tailTrackX < liftX + curveLen - 4.0 {
            let s0 = max(0.0, tailTrackX - liftX)
            let s1 = min(curveLen - 2.0, headTrackX - liftX)
            if s1 > s0 + 6.0 {
                var pStream = Path()
                var pLiftShadow = Path()
                let steps = 16
                for st in 0...steps {
                    let cs = lerp(s0, s1, CGFloat(st) / CGFloat(steps))
                    let smp = sampleCurve(at: cs)
                    let pt = smp.pt
                    let shPt = CGPoint(x: pt.x, y: pt.y + 2.8 * sin(smp.frac * .pi))
                    if st == 0 {
                        pStream.move(to: pt)
                        pLiftShadow.move(to: shPt)
                    } else {
                        pStream.addLine(to: pt)
                        pLiftShadow.addLine(to: shPt)
                    }
                }
                context.stroke(
                    pLiftShadow,
                    with: .color(colPaperShadow.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 4.0, lineCap: .round, lineJoin: .round)
                )
                context.stroke(
                    pStream,
                    with: .color(accentCol.opacity(0.16)),
                    style: StrokeStyle(lineWidth: 5.5, lineCap: .round, lineJoin: .round)
                )
            }
        }

        // 4. Render every character at 100% solid ink opacity:
        //    - Uniform .medium weight + continuous watercolor RGB blend (zero bold-pop flicker in Phase 1!),
        //    - Full size (1.0x) all along the track until the final 15pt lip threshold (`frac 0.82 -> 1.0`),
        //    - Vertically squeezed between the upper & lower lips right as it crosses into the dark mouth cavity (`clipW = intakePoint.x + 1.2`)!
        context.drawLayer { layer in
            let clipW = max(20.0, intakePoint.x + 1.2)
            layer.clip(to: Path(CGRect(x: 0, y: 0, width: clipW, height: frame.boxTopY + 60.0)))

            for idx in 0..<chars.count {
                let virtualX = charOrigins[idx] + feedDist
                if virtualX <= liftX {
                    layer.draw(baseResolved[idx], at: CGPoint(x: virtualX, y: originY), anchor: .center)
                } else {
                    let sAlong = virtualX - liftX
                    if sAlong > curveLen + 4.0 {
                        continue
                    }
                    let sample = sampleCurve(at: sAlong)
                    let lipPinch = MascotController.smootherstep(0.82, 0.99, sample.frac)
                    let scaleX = lerp(1.0, 0.78, lipPinch)
                    let scaleY = lerp(1.0, 0.44, lipPinch)
                    let inkBlend = MascotController.smootherstep(0.04, 0.68, sample.frac)
                    let tintedRes = layer.resolve(
                        Text(String(chars[idx]))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(siphonInkColor(blend: inkBlend))
                    )

                    layer.drawLayer { charLayer in
                        charLayer.translateBy(x: sample.pt.x, y: sample.pt.y)
                        charLayer.rotate(by: .radians(Double(sample.ang * 0.75 * (1.0 - lipPinch * 0.65))))
                        charLayer.scaleBy(x: scaleX, y: scaleY)
                        charLayer.draw(tintedRes, at: .zero, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: - Master Matched Bottom Progress Bar Companion Renderer
    package static func drawBottomRunner(
        in context: inout GraphicsContext,
        theme: MascotTheme,
        rx: CGFloat,
        seamY: CGFloat,
        scale: CGFloat,
        isPaused: Bool,
        activeBlend: CGFloat? = nil,
        walkPhase: CGFloat,
        cheerHop: CGFloat,
        cheerProgress: CGFloat = 0.0,
        cheerSquash: CGFloat = 0.0,
        clock: CGFloat
    ) {
        guard theme.isEnabled else { return }
        let inkPad = max(0.82, 1.80 * scale)
        let isCheering = (cheerProgress > 0.005 && cheerProgress < 0.995)
        let runAmt = max(0.0, min(1.0, activeBlend ?? (isPaused ? 0.0 : 1.0)))
        let sqX = exp(cheerSquash)
        let sqY = exp(-cheerSquash)

        switch theme {
        case .forestCube:
            let legBlend: CGFloat = isCheering ? 1.0 : runAmt
            let legLen: CGFloat = 5.5 * legBlend * scale
            let trotBob: CGFloat = isCheering ? 0.0 : (abs(sin(walkPhase)) * 2.2 * runAmt * scale)
            let lean: CGFloat = isCheering ? (sin(cheerProgress * .pi * 2.0) * 0.10) : (0.06 * runAmt)
            let sx: CGFloat = lerp(1.08, 1.0, legBlend) * sqX
            let sy: CGFloat = lerp(0.90, 1.0, legBlend) * sqY

            let cubeH = 23.0 * sy * scale
            let cubeW = 28.0 * sx * scale
            let cy = seamY - legLen - cubeH * 0.5 - trotBob - cheerHop
            let cx = rx

            var pShadow = Path()
            let airShrink = isCheering ? min(1.0, cheerHop / max(1.0, 9.8)) * 3.8 : 0.0
            addEllipseCW(
                &pShadow,
                cx: rx,
                cy: seamY + 0.5,
                rx: (13.5 - airShrink) * scale,
                ry: 2.0 * scale
            )
            context.fill(pShadow, with: .color(colPaperShadow))

            var pBackInk = Path()
            if legBlend > 0.08 {
                let s1 = sin(walkPhase) * runAmt
                let s2 = -s1
                let legH = max(1.6, 5.2 * legBlend) * scale
                let legY = seamY - legH * 0.5 - cheerHop
                addRotatedPillCW(&pBackInk, cx: cx - 5.2 * scale + s1 * 2.8 * scale, cy: legY - max(0, s1) * 2.0 * scale, w: 2.2 * scale, h: legH, ang: 0)
                addRotatedPillCW(&pBackInk, cx: cx + 5.2 * scale + s2 * 2.8 * scale, cy: legY - max(0, s2) * 2.0 * scale, w: 2.2 * scale, h: legH, ang: 0)
            }

            let leafBaseX = cx - 1.0 * scale
            let leafBaseY = cy - cubeH * 0.5
            var pLeafFill = Path()

            if isCheering {
                // Bespoke Cheer: Bamboo-Copter Helicopter Leaf Rotor Spin + Golden Pollen Sparkles!
                let rotorSpin = cheerProgress * .pi * 8.0
                let bladeSpan = max(3.5, abs(cos(rotorSpin)) * 14.5) * scale
                let hubY = leafBaseY - 7.5 * scale

                var pStem = Path()
                pStem.move(to: CGPoint(x: leafBaseX, y: leafBaseY + 1.0 * scale))
                pStem.addLine(to: CGPoint(x: leafBaseX, y: hubY))
                context.stroke(pStem, with: .color(colInkPen), style: StrokeStyle(lineWidth: max(0.85, 1.5 * scale), lineCap: .round))

                addLeafCW(&pBackInk, bx: leafBaseX, by: hubY, tx: leafBaseX - bladeSpan, ty: hubY - 1.8 * scale, halfW: 3.6 * scale + inkPad * 0.7, bend: 0)
                addLeafCW(&pBackInk, bx: leafBaseX, by: hubY, tx: leafBaseX + bladeSpan, ty: hubY - 1.8 * scale, halfW: 3.6 * scale + inkPad * 0.7, bend: 0)
                addLeafCW(&pLeafFill, bx: leafBaseX, by: hubY, tx: leafBaseX - bladeSpan, ty: hubY - 1.8 * scale, halfW: 3.5 * scale, bend: 0)
                addLeafCW(&pLeafFill, bx: leafBaseX, by: hubY, tx: leafBaseX + bladeSpan, ty: hubY - 1.8 * scale, halfW: 3.5 * scale, bend: 0)

                var pRotorBlur = Path()
                addEllipseCW(&pRotorBlur, cx: leafBaseX, cy: hubY - 1.5 * scale, rx: 14.5 * scale, ry: 2.6 * scale)
                context.stroke(
                    pRotorBlur,
                    with: .color(seamColor(for: .forestCube).opacity(0.65 * Double(sin(cheerProgress * .pi)))),
                    style: StrokeStyle(lineWidth: max(0.75, 1.15 * scale), lineCap: .round)
                )

                var pPollen = Path()
                let pFade = sin(cheerProgress * .pi)
                addCircleCW(&pPollen, cx: leafBaseX - 11.0 * scale, cy: hubY - 5.5 * scale, r: 1.8 * scale * pFade)
                addCircleCW(&pPollen, cx: leafBaseX + 12.0 * scale, cy: hubY - 4.0 * scale, r: 1.6 * scale * pFade)
                context.fill(pPollen, with: .color(Color(red: 244 / 255, green: 196 / 255, blue: 92 / 255)))
            } else {
                let leafSway: CGFloat = lerp(sin(clock * 1.8) * 1.5, -3.5 + sin(walkPhase) * 2.8, runAmt)
                let leafTipX = leafBaseX + leafSway * scale
                let leafTipY = leafBaseY - 13.5 * scale
                addLeafCW(&pBackInk, bx: leafBaseX, by: leafBaseY + 1.0 * scale, tx: leafTipX, ty: leafTipY, halfW: 4.6 * scale + inkPad * 0.85, bend: 1.2 * scale)
                addLeafCW(&pLeafFill, bx: leafBaseX, by: leafBaseY + 1.0 * scale, tx: leafTipX, ty: leafTipY, halfW: 4.5 * scale, bend: 1.2 * scale)
            }

            context.fill(pBackInk, with: .color(colInkPen))
            context.fill(pLeafFill, with: .color(Color(red: 229 / 255, green: 108 / 255, blue: 90 / 255)))

            let c = cos(lean), s = sin(lean)
            func qf(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                CGPoint(x: cx + u * c - v * s, y: cy + u * s + v * c)
            }
            let hw = cubeW * 0.5, hh = cubeH * 0.5
            let ridgeU = hw * 0.36
            let tl = qf(-hw * 1.04, -hh)
            let tr = qf(hw * 1.04, -hh)
            let br = qf(hw * 0.96, hh)
            let bl = qf(-hw * 0.96, hh)
            let rt = qf(ridgeU, -hh)
            let rb = qf(ridgeU, hh)

            var pInkHull = Path()
            var pLight = Path()
            var pShade = Path()
            addRoundedQuadCW(
                &pInkHull,
                CGPoint(x: tl.x - inkPad, y: tl.y - inkPad),
                CGPoint(x: tr.x + inkPad, y: tr.y - inkPad),
                CGPoint(x: br.x + inkPad, y: br.y + inkPad),
                CGPoint(x: bl.x - inkPad, y: bl.y + inkPad),
                radius: 3.2 * scale
            )
            addRoundedQuadCW(&pLight, tl, tr, br, bl, radius: 2.8 * scale)
            addRoundedQuadCW(&pShade, rt, tr, br, rb, radius: 2.5 * scale)

            context.fill(pInkHull, with: .color(colInkPen))
            context.fill(pLight, with: .color(Color(red: 190 / 255, green: 211 / 255, blue: 203 / 255)))
            context.fill(pShade, with: .color(Color(red: 114 / 255, green: 146 / 255, blue: 146 / 255).opacity(0.92)))

            let eyeCy = cy + hh * 0.30
            let eyeCx = cx - hw * 0.16
            if isCheering {
                var pSmile = Path()
                addSmileArchStroke(&pSmile, cx: eyeCx - 3.8 * scale, cy: eyeCy, halfSpan: 2.8 * scale, rise: 2.2 * scale, ang: lean)
                addSmileArchStroke(&pSmile, cx: eyeCx + 4.0 * scale, cy: eyeCy, halfSpan: 2.8 * scale, rise: 2.2 * scale, ang: lean)
                context.stroke(pSmile, with: .color(colInkPen), style: StrokeStyle(lineWidth: max(1.05, 2.0 * scale), lineCap: .round))
            } else {
                var pEyes = Path()
                let eW = lerp(4.2, 2.7, runAmt) * scale
                let eH = lerp(1.5, 5.2, runAmt) * scale
                let eLX = eyeCx - lerp(4.0, 3.6, runAmt) * scale
                let eRX = eyeCx + lerp(4.0, 4.2, runAmt) * scale
                addRotatedPillCW(&pEyes, cx: eLX, cy: eyeCy, w: eW, h: eH, ang: lean)
                addRotatedPillCW(&pEyes, cx: eRX, cy: eyeCy, w: eW * 0.96, h: eH, ang: lean)
                context.fill(pEyes, with: .color(colInkPen))
            }

        case .roundMochi:
            // Bespoke Cheer: Joyful 360° Mid-Air Forward Somersault + Squishy Landing!
            let activeAmt: CGFloat = isCheering ? 1.0 : runAmt
            let hopAbs: CGFloat = isCheering ? 0.0 : (abs(sin(walkPhase * 0.85)) * runAmt)
            let hopLift: CGFloat = isCheering ? 0.0 : (hopAbs * 7.0 * scale)
            let sx: CGFloat = lerp(1.22, lerp(1.14, 0.91, hopAbs), activeAmt) * sqX
            let sy: CGFloat = lerp(0.79, lerp(0.87, 1.10, hopAbs), activeAmt) * sqY

            let flipAng: CGFloat = isCheering ? (MascotController.smootherstep(0.11, 0.84, cheerProgress) * .pi * 2.0) : 0.0
            let cf = cos(flipAng), sf = sin(flipAng)

            let cy = seamY - 18.8 * sy * scale - hopLift - cheerHop
            let cx = rx

            var pShadow = Path()
            let airAmt = max(hopAbs, isCheering ? min(1.0, cheerHop / max(1.0, 13.4)) : 0.0)
            addEllipseCW(&pShadow, cx: rx, cy: seamY + 0.5, rx: lerp(15.5, 8.2, airAmt) * scale, ry: 2.0 * scale)
            context.fill(pShadow, with: .color(colPaperShadow))

            if isCheering {
                var pFlipHalo = Path()
                addCircleCW(&pFlipHalo, cx: cx, cy: cy, r: 24.5 * scale * sin(cheerProgress * .pi))
                context.stroke(
                    pFlipHalo,
                    with: .color(seamColor(for: .roundMochi).opacity(0.65 * Double(sin(cheerProgress * .pi)))),
                    style: StrokeStyle(lineWidth: max(0.75, 1.15 * scale), lineCap: .round)
                )
            }

            let pawFlap: CGFloat = isCheering ? -0.85 : lerp(0.18, -0.42 + hopAbs * 0.85, runAmt)
            let pLuX = -22.4 * sx * scale
            let pLuY = lerp(9.2, 3.2, activeAmt) * sy * scale
            let pRuX = 22.4 * sx * scale
            let pRuY = pLuY
            let pLx = cx + pLuX * cf - pLuY * sf
            let pLy = cy + pLuX * sf + pLuY * cf
            let pRx = cx + pRuX * cf - pRuY * sf
            let pRy = cy + pRuX * sf + pRuY * cf

            var pPawInk = Path()
            var pPawFill = Path()
            addRotatedPillCW(&pPawInk, cx: pLx, cy: pLy, w: 9.4 * scale + inkPad * 1.45, h: 6.6 * scale + inkPad * 1.45, ang: flipAng - pawFlap)
            addRotatedPillCW(&pPawInk, cx: pRx, cy: pRy, w: 9.4 * scale + inkPad * 1.45, h: 6.6 * scale + inkPad * 1.45, ang: flipAng + pawFlap)
            addRotatedPillCW(&pPawFill, cx: pLx, cy: pLy, w: 9.4 * scale, h: 6.6 * scale, ang: flipAng - pawFlap)
            addRotatedPillCW(&pPawFill, cx: pRx, cy: pRy, w: 9.4 * scale, h: 6.6 * scale, ang: flipAng + pawFlap)
            context.fill(pPawInk, with: .color(colInkPen))
            context.fill(pPawFill, with: .color(Color(red: 252 / 255, green: 249 / 255, blue: 241 / 255)))

            var kx = Array(repeating: CGFloat(0), count: 6)
            var ky = Array(repeating: CGFloat(0), count: 6)
            var ikx = Array(repeating: CGFloat(0), count: 6)
            var iky = Array(repeating: CGFloat(0), count: 6)
            for i in 0..<6 {
                let p = miniMochi6[i]
                let lx = p.x * sx, ly = p.y * sy
                let rxP = lx * cf - ly * sf
                let ryP = lx * sf + ly * cf
                let len = max(1.0, hypot(rxP, ryP))
                kx[i] = cx + rxP * scale
                ky[i] = cy + ryP * scale
                ikx[i] = kx[i] + (rxP / len) * inkPad
                iky[i] = ky[i] + (ryP / len) * inkPad
            }
            var dumX = Array(repeating: CGFloat(0), count: 6)
            var dumY = Array(repeating: CGFloat(0), count: 6)
            var bdx = Array(repeating: CGFloat(0), count: 6)
            var bdy = Array(repeating: CGFloat(0), count: 6)
            var pInk = Path()
            var pLight = Path()
            var pShade = Path()
            emitClosedC2Path(&pInk, kx: ikx, ky: iky, weights: c2Weights6, dxOut: &dumX, dyOut: &dumY)
            emitClosedC2Path(&pLight, kx: kx, ky: ky, weights: c2Weights6, dxOut: &bdx, dyOut: &bdy)

            func seg6(_ p: inout Path, _ sIdx: Int) {
                let j = (sIdx + 1) % 6
                p.addCurve(
                    to: CGPoint(x: kx[j], y: ky[j]),
                    control1: CGPoint(x: (2.0 * bdx[sIdx] + bdx[j]) / 3.0, y: (2.0 * bdy[sIdx] + bdy[j]) / 3.0),
                    control2: CGPoint(x: (bdx[sIdx] + 2.0 * bdx[j]) / 3.0, y: (bdy[sIdx] + 2.0 * bdy[j]) / 3.0)
                )
            }
            pShade.move(to: CGPoint(x: kx[3], y: ky[3]))
            seg6(&pShade, 3)
            seg6(&pShade, 4)
            pShade.addCurve(
                to: CGPoint(x: kx[3], y: ky[3]),
                control1: CGPoint(x: lerp(kx[5], kx[4], 0.5), y: lerp(ky[5], ky[4], 0.45)),
                control2: CGPoint(x: lerp(kx[3], kx[4], 0.45) - 3.0 * scale, y: lerp(ky[3], ky[4], 0.5))
            )
            pShade.closeSubpath()

            context.fill(pInk, with: .color(colInkPen))
            context.fill(pLight, with: .color(Color(red: 252 / 255, green: 249 / 255, blue: 241 / 255)))
            context.fill(pShade, with: .color(Color(red: 218 / 255, green: 210 / 255, blue: 192 / 255).opacity(0.76)))

            func rPt(_ ux: CGFloat, _ uy: CGFloat) -> CGPoint {
                CGPoint(x: cx + (ux * cf - uy * sf) * scale, y: cy + (ux * sf + uy * cf) * scale)
            }
            let blL = rPt(-12.2 * sx, 4.5)
            let blR = rPt(12.2 * sx, 4.5)
            var pBlush = Path()
            addEllipseCW(&pBlush, cx: blL.x, cy: blL.y, rx: 4.2 * scale, ry: 2.4 * scale)
            addEllipseCW(&pBlush, cx: blR.x, cy: blR.y, rx: 4.2 * scale, ry: 2.4 * scale)
            context.fill(pBlush, with: .color(Color(red: 232 / 255, green: 148 / 255, blue: 134 / 255).opacity(0.62)))

            let eL = rPt(-4.6, 1.5)
            let eR = rPt(6.6, 1.5)
            if isCheering {
                var pSmile = Path()
                addSmileArchStroke(&pSmile, cx: eL.x, cy: eL.y, halfSpan: 3.1 * scale, rise: 2.4 * scale, ang: flipAng)
                addSmileArchStroke(&pSmile, cx: eR.x, cy: eR.y, halfSpan: 3.1 * scale, rise: 2.4 * scale, ang: flipAng)
                context.stroke(pSmile, with: .color(colInkPen), style: StrokeStyle(lineWidth: max(1.1, 2.2 * scale), lineCap: .round))
            } else {
                var pEyes = Path()
                let eW = lerp(5.0, 3.6, runAmt) * scale
                let eH = lerp(1.7, 5.8, runAmt) * scale
                addRotatedPillCW(&pEyes, cx: eL.x, cy: eL.y, w: eW, h: eH, ang: flipAng + 0.04 * runAmt)
                addRotatedPillCW(&pEyes, cx: eR.x, cy: eR.y, w: eW * 0.95, h: eH, ang: flipAng + 0.04 * runAmt)
                context.fill(pEyes, with: .color(colInkPen))
            }

        case .grokAstral:
            // Bespoke Cheer: Zero-G Boost + 360° Satellite Orbit + Golden Supernova Halo Burst!
            let activeAmt: CGFloat = isCheering ? 1.0 : runAmt
            let hoverGap: CGFloat = (lerp(5.5, 12.5, activeAmt) + sin(clock * 4.2) * lerp(0.9, 2.4, activeAmt)) * scale
            let lean: CGFloat = 0.13 * activeAmt
            let cy = seamY - 22.0 * sqY * scale - hoverGap - cheerHop
            let cx = rx
            let ringW = max(0.95, 1.8 * scale)

            var pShadow = Path()
            let airShrink = isCheering ? min(1.0, cheerHop / max(1.0, 11.2)) * 2.8 : 0.0
            addEllipseCW(&pShadow, cx: rx, cy: seamY + 0.5, rx: (10.0 - airShrink) * scale, ry: 1.6 * scale)
            context.fill(pShadow, with: .color(colPaperShadow))

            if isCheering {
                let burstR = lerp(14.0, 36.0, cheerProgress) * scale
                let stScale = sin(cheerProgress * .pi)
                var pBurst = Path()
                addCircleCW(&pBurst, cx: cx, cy: cy, r: burstR)
                context.stroke(
                    pBurst,
                    with: .color(Color(red: 238 / 255, green: 192 / 255, blue: 96 / 255).opacity(0.85 * Double(stScale))),
                    style: StrokeStyle(lineWidth: max(0.85, 1.25 * scale), lineCap: .round)
                )

                var pStars = Path()
                addStar4CW(&pStars, cx: cx - burstR * 0.92, cy: cy - 9.0 * scale, rOuter: 6.2 * scale * stScale, rInner: 1.8 * scale * stScale, rot: cheerProgress * 1.8)
                addStar4CW(&pStars, cx: cx + burstR * 0.92, cy: cy - 7.0 * scale, rOuter: 5.8 * scale * stScale, rInner: 1.7 * scale * stScale, rot: -cheerProgress * 1.8)
                addStar4CW(&pStars, cx: cx + 2.0 * scale, cy: cy - burstR * 0.95, rOuter: 5.2 * scale * stScale, rInner: 1.5 * scale * stScale, rot: 0.3)
                context.fill(pStars, with: .color(Color(red: 246 / 255, green: 204 / 255, blue: 108 / 255)))
            }

            let satAng: CGFloat = isCheering ? (cheerProgress * .pi * 2.0) : .pi
            let trailX: CGFloat = isCheering
                ? (cx + cos(satAng) * 29.0 * scale)
                : (cx - (28.0 + sin(clock * 5.0) * 2.0) * scale)
            let trailY: CGFloat = isCheering
                ? (cy + sin(satAng) * 8.5 * scale)
                : (cy + (2.5 + cos(clock * 4.2) * 2.0) * scale)
            var pTrailInk = Path()
            var pTrailFill = Path()
            addCircleCW(&pTrailInk, cx: trailX, cy: trailY, r: 3.0 * scale + inkPad * 0.7)
            addCircleCW(&pTrailFill, cx: trailX, cy: trailY, r: 2.9 * scale)

            let rTilt = -0.20 + lean * 0.5 + (isCheering ? sin(cheerProgress * .pi * 4.0) * 0.25 : 0.0)
            var pBackRing = Path()
            var pFrontRing = Path()
            addTiltedRingArcs(back: &pBackRing, front: &pFrontRing, cx: cx, cy: cy + 1.2 * scale, rx: 27.5 * scale, ry: 7.2 * scale, ang: rTilt)

            context.stroke(
                pBackRing,
                with: .color(Color(red: 214 / 255, green: 164 / 255, blue: 88 / 255).opacity(0.86)),
                style: StrokeStyle(lineWidth: ringW, lineCap: .round, lineJoin: .round)
            )
            if !isCheering || sin(satAng) <= 0 {
                context.fill(pTrailInk, with: .color(colInkPen))
                context.fill(pTrailFill, with: .color(Color(red: 244 / 255, green: 204 / 255, blue: 118 / 255)))
            }

            let c = cos(lean), s = sin(lean)
            var kx = Array(repeating: CGFloat(0), count: 8)
            var ky = Array(repeating: CGFloat(0), count: 8)
            var ikx = Array(repeating: CGFloat(0), count: 8)
            var iky = Array(repeating: CGFloat(0), count: 8)
            for i in 0..<8 {
                let p = miniOrb8[i]
                let sxP = p.x * sqX
                let syP = p.y * sqY
                let rxP = sxP * c - syP * s
                let ryP = sxP * s + syP * c
                let len = max(1.0, hypot(rxP, ryP))
                kx[i] = cx + rxP * scale
                ky[i] = cy + ryP * scale
                ikx[i] = kx[i] + (rxP / len) * inkPad
                iky[i] = ky[i] + (ryP / len) * inkPad
            }
            var dumX = Array(repeating: CGFloat(0), count: 8)
            var dumY = Array(repeating: CGFloat(0), count: 8)
            var bdx = Array(repeating: CGFloat(0), count: 8)
            var bdy = Array(repeating: CGFloat(0), count: 8)
            var pInk = Path()
            var pLight = Path()
            var pShade = Path()
            emitClosedC2Path(&pInk, kx: ikx, ky: iky, weights: c2Weights8, dxOut: &dumX, dyOut: &dumY)
            emitClosedC2Path(&pLight, kx: kx, ky: ky, weights: c2Weights8, dxOut: &bdx, dyOut: &bdy)

            func seg8(_ p: inout Path, _ sIdx: Int) {
                let j = (sIdx + 1) % 8
                p.addCurve(
                    to: CGPoint(x: kx[j], y: ky[j]),
                    control1: CGPoint(x: (2.0 * bdx[sIdx] + bdx[j]) / 3.0, y: (2.0 * bdy[sIdx] + bdy[j]) / 3.0),
                    control2: CGPoint(x: (bdx[sIdx] + 2.0 * bdx[j]) / 3.0, y: (bdy[sIdx] + 2.0 * bdy[j]) / 3.0)
                )
            }
            pShade.move(to: CGPoint(x: kx[3], y: ky[3]))
            seg8(&pShade, 3)
            seg8(&pShade, 4)
            seg8(&pShade, 5)
            seg8(&pShade, 6)
            pShade.addCurve(
                to: CGPoint(x: kx[3], y: ky[3]),
                control1: CGPoint(x: lerp(kx[7], kx[4], 0.42), y: lerp(ky[7], ky[6], 0.25)),
                control2: CGPoint(x: lerp(kx[3], kx[4], 0.36) - 2.5 * scale, y: lerp(ky[3], ky[5], 0.46))
            )
            pShade.closeSubpath()

            context.fill(pInk, with: .color(colInkPen))
            context.fill(pLight, with: .color(Color(red: 234 / 255, green: 138 / 255, blue: 104 / 255)))
            context.fill(pShade, with: .color(Color(red: 184 / 255, green: 88 / 255, blue: 62 / 255).opacity(0.75)))

            let eyeCol = Color(red: 38 / 255, green: 24 / 255, blue: 20 / 255)
            let eyeOff: CGFloat = 2.2 * activeAmt * scale
            if isCheering {
                var pSmile = Path()
                addSmileArchStroke(&pSmile, cx: cx - 4.4 * scale + eyeOff, cy: cy - 0.8 * scale, halfSpan: 3.4 * scale, rise: 2.8 * scale, ang: lean)
                addSmileArchStroke(&pSmile, cx: cx + 4.8 * scale + eyeOff, cy: cy - 0.8 * scale, halfSpan: 3.4 * scale, rise: 2.8 * scale, ang: lean)
                context.stroke(pSmile, with: .color(eyeCol), style: StrokeStyle(lineWidth: max(1.15, 2.3 * scale), lineCap: .round))
            } else {
                var pEyes = Path()
                let eW = lerp(5.2, 3.6, runAmt) * scale
                let eH = lerp(1.8, 10.6, runAmt) * scale
                let eLX = cx - lerp(5.2, 4.2, runAmt) * scale + eyeOff
                let eRX = cx + lerp(5.2, 4.8, runAmt) * scale + eyeOff
                let eY = cy - 0.5 * runAmt * scale
                addRotatedPillCW(&pEyes, cx: eLX, cy: eY, w: eW, h: eH, ang: lean)
                addRotatedPillCW(&pEyes, cx: eRX, cy: eY, w: eW * 0.95, h: eH, ang: lean)
                context.fill(pEyes, with: .color(eyeCol))
            }

            context.stroke(
                pFrontRing,
                with: .color(Color(red: 234 / 255, green: 186 / 255, blue: 100 / 255).opacity(0.95)),
                style: StrokeStyle(lineWidth: ringW * 1.08, lineCap: .round, lineJoin: .round)
            )
            if isCheering && sin(satAng) > 0 {
                context.fill(pTrailInk, with: .color(colInkPen))
                context.fill(pTrailFill, with: .color(Color(red: 246 / 255, green: 210 / 255, blue: 126 / 255)))
            }

        case .none:
            break
        }
    }
}

// MARK: - 1. Top Drop Zone Mascot Container (Supports Behind-Bar Tuck + Front Forepaws + Quick Theme Menu)
struct MascotTopDropZoneContainer<Content: View>: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.appTheme) private var appTheme

    @State private var isDropTargeted = false

    private let skyHeight: CGFloat = 52.0

    var body: some View {
        let theme = vm.mascotTheme
        let typingURL = (vm.activeTab == .download && !vm.urlInput.isEmpty)
        let pipelineStatus = vm.activePipelineProgressSummary
        let isWorking = (!pipelineStatus.isPaused && pipelineStatus.progress != nil)

        if !theme.isEnabled {
            content()
        } else if isSnapshotMode {
            decoratedContent(theme: theme, typingURL: typingURL, isWorking: isWorking)
        } else {
            decoratedContent(theme: theme, typingURL: typingURL, isWorking: isWorking)
                .onDrop(of: [.fileURL, .plainText, .url], isTargeted: $isDropTargeted) { providers in
                    vm.handleDroppedProviders(providers)
                }
                .onChange(of: isDropTargeted) { _, targeted in
                    vm.mascot.setDropHovering(targeted)
                }
        }
    }

    @ViewBuilder
    private func decoratedContent(theme: MascotTheme, typingURL: Bool, isWorking: Bool) -> some View {
        // Keep `content()` (TextField & buttons) OUTSIDE TimelineView so 60fps Canvas never re-diffs the input bar!
        content()
            .background(alignment: .bottom) {
                if theme == .roundMochi {
                    if isSnapshotMode {
                        backLayerCanvas(at: 0.55, theme: theme, typingURL: typingURL, isWorking: isWorking)
                    } else {
                        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                            backLayerCanvas(
                                at: timeline.date.timeIntervalSinceReferenceDate,
                                theme: theme,
                                typingURL: typingURL,
                                isWorking: isWorking
                            )
                        }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    let w = max(240, geo.size.width)
                    let boxH = max(34, geo.size.height)
                    let totalH = boxH + skyHeight

                    ZStack(alignment: .topLeading) {
                        if isSnapshotMode {
                            frontLayerCanvas(at: 0.55, w: w, totalH: totalH, theme: theme, typingURL: typingURL, isWorking: isWorking)
                        } else {
                            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                                frontLayerCanvas(
                                    at: timeline.date.timeIntervalSinceReferenceDate,
                                    w: w,
                                    totalH: totalH,
                                    theme: theme,
                                    typingURL: typingURL,
                                    isWorking: isWorking
                                )
                            }
                        }

                        if !isSnapshotMode {
                            // Compact interactive hit-box right on the perched mascot (kept outside TimelineView!):
                            // Left-click -> bespoke Poke reaction; Right-click -> quick Theme Switcher menu!
                            Color.clear
                                .frame(width: 40, height: 32)
                                .contentShape(Rectangle())
                                .offset(x: max(20, w - 116), y: skyHeight - 28)
                                .onTapGesture {
                                    vm.mascot.triggerBoing()
                                }
                                .contextMenu {
                                    Section("切换伴生灵主题") {
                                        ForEach(MascotTheme.allCases) { opt in
                                            Button {
                                                vm.setMascotTheme(opt)
                                            } label: {
                                                if vm.mascotTheme == opt {
                                                    Label(opt.displayName, systemImage: "checkmark")
                                                } else {
                                                    Text(opt.displayName)
                                                }
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("打开外观设置...") {
                                        vm.activeTab = .settings
                                        vm.settingsCategory = .appearance
                                    }
                                }
                                .help("\(theme.displayName) · 点击互动，右键切换主题")
                        }
                    }
                    .frame(width: w, height: totalH)
                    .offset(y: -skyHeight)
                }
            }
    }

    @ViewBuilder
    private func backLayerCanvas(at now: TimeInterval, theme: MascotTheme, typingURL: Bool, isWorking: Bool) -> some View {
        GeometryReader { geo in
            let w = max(240, geo.size.width)
            let boxH = max(34, geo.size.height)
            let totalH = boxH + skyHeight
            let frame = vm.mascot.stepTopFrame(
                at: now,
                theme: theme,
                width: w,
                boxTopY: skyHeight,
                isTypingURL: typingURL,
                isSnapshotMode: isSnapshotMode,
                isWorking: isWorking
            )
            Canvas { ctx, _ in
                if !frame.isFrontLayer {
                    MascotVectorRenderer.drawTopMascot(
                        in: &ctx,
                        theme: frame.theme,
                        sim: frame.sim,
                        anchorX: frame.sim.coreX,
                        anchorY: frame.sim.coreY,
                        scale: MascotController.uiMascotScale,
                        isBig: false,
                        includeShadow: false,
                        includeBody: true,
                        includeForepaws: false
                    )
                }
            }
            .frame(width: w, height: totalH)
            .offset(y: -skyHeight)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func frontLayerCanvas(
        at now: TimeInterval,
        w: CGFloat,
        totalH: CGFloat,
        theme: MascotTheme,
        typingURL: Bool,
        isWorking: Bool
    ) -> some View {
        let frame = vm.mascot.stepTopFrame(
            at: now,
            theme: theme,
            width: w,
            boxTopY: skyHeight,
            isTypingURL: typingURL,
            isSnapshotMode: isSnapshotMode,
            isWorking: isWorking
        )
        Canvas { ctx, _ in
            let intakePt: CGPoint
            if frame.isFrontLayer {
                intakePt = MascotVectorRenderer.drawTopMascot(
                    in: &ctx,
                    theme: frame.theme,
                    sim: frame.sim,
                    anchorX: frame.sim.coreX,
                    anchorY: frame.sim.coreY,
                    scale: MascotController.uiMascotScale,
                    isBig: false,
                    includeShadow: true,
                    includeBody: true,
                    includeForepaws: true
                )
            } else {
                intakePt = MascotVectorRenderer.drawTopMascot(
                    in: &ctx,
                    theme: frame.theme,
                    sim: frame.sim,
                    anchorX: frame.sim.coreX,
                    anchorY: frame.sim.coreY,
                    scale: MascotController.uiMascotScale,
                    isBig: false,
                    includeShadow: false,
                    includeBody: false,
                    includeForepaws: true
                )
            }
            MascotVectorRenderer.drawIntakeEffects(
                in: &ctx,
                frame: frame,
                intakePoint: intakePt,
                isDark: appTheme.isDark
            )
        }
        .frame(width: w, height: totalH)
        .allowsHitTesting(false)
    }
}

// MARK: - 2. Bottom Progress Seam Companion Overlay (Rides Directly Along the Bottom Divider Seam)
struct MascotBottomProgressOverlay: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool

    private let overlayHeight: CGFloat = 48.0
    private let horizontalInset: CGFloat = ChrysaMetrics.canvasInset

    var body: some View {
        let theme = vm.mascotTheme
        if !theme.isEnabled || vm.activeTab == .settings || vm.activeTab == .launch {
            EmptyView()
        } else if isSnapshotMode {
            runnerCanvas(at: 0.55, theme: theme, status: vm.activePipelineProgressSummary)
                .frame(height: overlayHeight)
                .allowsHitTesting(false)
        } else {
            let status = vm.activePipelineProgressSummary
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                runnerCanvas(
                    at: timeline.date.timeIntervalSinceReferenceDate,
                    theme: theme,
                    status: status
                )
            }
            .frame(height: overlayHeight)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func runnerCanvas(
        at now: TimeInterval,
        theme: MascotTheme,
        status: (progress: Double?, isPaused: Bool)
    ) -> some View {
        GeometryReader { geo in
            let w = max(200, geo.size.width)
            let seamX1 = horizontalInset
            let seamX2 = max(seamX1 + 40, w - horizontalInset)
            let seamY = overlayHeight - 0.5
            let frame = vm.mascot.stepRunnerFrame(
                at: now,
                theme: theme,
                seamX1: seamX1,
                seamX2: seamX2,
                progress: status.progress,
                isPaused: status.isPaused,
                isSnapshotMode: isSnapshotMode
            )
            Canvas { ctx, _ in
                if frame.hasActiveProgress && frame.runnerX > seamX1 + 1.0 {
                    var pSeam = Path()
                    pSeam.move(to: CGPoint(x: seamX1, y: seamY))
                    pSeam.addLine(to: CGPoint(x: frame.runnerX, y: seamY))
                    ctx.stroke(
                        pSeam,
                        with: .color(MascotVectorRenderer.seamColor(for: frame.theme)),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                    )
                }
                MascotVectorRenderer.drawBottomRunner(
                    in: &ctx,
                    theme: frame.theme,
                    rx: frame.runnerX,
                    seamY: seamY,
                    scale: MascotController.uiRunnerScale,
                    isPaused: frame.isPaused,
                    activeBlend: frame.activeBlend,
                    walkPhase: frame.walkPhase,
                    cheerHop: frame.cheerHop,
                    cheerProgress: frame.cheerProgress,
                    cheerSquash: frame.cheerSquash,
                    clock: frame.clock
                )
            }
            .frame(width: w, height: overlayHeight)
        }
    }
}

// MARK: - 3. Pure-Flat Matched-Duo Theme Picker Card for Settings -> 外观
struct MascotThemeCardView: View {
    let option: MascotTheme
    let isSelected: Bool
    let isSnapshotMode: Bool
    var cardHeight: CGFloat = ChrysaMetrics.showcaseCardHeight
    let onSelect: () -> Void
    @Environment(\.appTheme) private var appTheme
    @State private var isHovered = false

    var body: some View {
        duoMiniStage
            .frame(maxWidth: .infinity)
            .frame(height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous)
                    .stroke(
                        (!isSelected && isHovered) ? Color.t3PillBorder : Color.t3GroupedCardBorder,
                        lineWidth: 1.0
                    )
                    .animation(ChrysaMotion.hover(isHovered), value: isHovered)
            )
            .anchorPreference(key: SelectionBoundsKey<MascotTheme>.self, value: .bounds) { [option: $0] }
            .contentShape(RoundedRectangle(cornerRadius: ChrysaMetrics.radiusCard, style: .continuous))
            .onHover { isHovered = $0 }
            .onInstantPress(onSelect)
            .help("\(option.displayName) · \(option.companionSubtitle)")
    }

    @ViewBuilder
    private var duoMiniStage: some View {
        if option == .none {
            ZStack {
                Color.t3GroupedCardBg
                VStack(alignment: .leading, spacing: 6.5) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(appTheme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
                        .frame(width: 86, height: 11)
                    HStack(spacing: 5.5) {
                        Circle()
                            .stroke(Color.t3CheckBorder, lineWidth: 1.2)
                            .frame(width: 8, height: 8)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(appTheme.isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.10))
                            .frame(width: 60, height: 4.5)
                    }
                    Rectangle()
                        .fill(appTheme.isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08))
                        .frame(width: 86, height: 1.2)
                }
            }
        } else if isSnapshotMode {
            duoStageCanvas(t: 0.72)
        } else {
            TimelineView(.animation(minimumInterval: isSelected ? (1.0 / 60.0) : (1.0 / 30.0))) { timeline in
                duoStageCanvas(t: CGFloat(timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    @ViewBuilder
    private func duoStageCanvas(t: CGFloat) -> some View {
        Canvas { ctx, size in
            let shelfY = size.height - 10.5
            let leftShelfX1: CGFloat = 14
            let leftShelfX2: CGFloat = size.width * 0.50
            let rightSeamX1: CGFloat = size.width * 0.56
            let rightSeamX2: CGFloat = size.width - 14
            let runnerX: CGFloat = MascotController.lerp(rightSeamX1, rightSeamX2, 0.58)

            var pShelf = Path()
            pShelf.move(to: CGPoint(x: leftShelfX1, y: shelfY))
            pShelf.addLine(to: CGPoint(x: leftShelfX2, y: shelfY))
            ctx.stroke(pShelf, with: .color(Color.t3MascotStageLine), style: StrokeStyle(lineWidth: 1.0, lineCap: .round))

            var pSeamBg = Path()
            pSeamBg.move(to: CGPoint(x: rightSeamX1, y: shelfY))
            pSeamBg.addLine(to: CGPoint(x: rightSeamX2, y: shelfY))
            ctx.stroke(pSeamBg, with: .color(Color.t3MascotStageLine.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            var pSeamFill = Path()
            pSeamFill.move(to: CGPoint(x: rightSeamX1, y: shelfY))
            pSeamFill.addLine(to: CGPoint(x: runnerX, y: shelfY))
            ctx.stroke(pSeamFill, with: .color(MascotVectorRenderer.seamColor(for: option)), style: StrokeStyle(lineWidth: 2.1, lineCap: .round))

            let topScale: CGFloat = 0.54
            let topCx: CGFloat = (leftShelfX1 + leftShelfX2) * 0.5 + (option == .forestCube ? 1.5 : 0.0)
            let topAnchorY: CGFloat = (option == .roundMochi)
                ? (shelfY - 19.0 * topScale)
                : (shelfY - 30.5 * topScale)

            var sim = MascotSimState(startX: topCx, startY: topAnchorY)
            sim.haloSpin = t * 1.6
            sim.leafSway = sin(t * 2.1) * 0.14
            sim.lookX = sin(t * 0.9) * 0.28
            sim.tiltRad = sin(t * 0.9 - 0.35) * 0.055
            sim.ringLagTilt = sin(t * 0.9 - 0.7) * 0.08
            sim.boingY = sin(t * 2.0) * 1.05

            MascotVectorRenderer.drawTopMascot(
                in: &ctx,
                theme: option,
                sim: sim,
                anchorX: topCx,
                anchorY: topAnchorY,
                scale: topScale,
                isBig: true
            )

            MascotVectorRenderer.drawBottomRunner(
                in: &ctx,
                theme: option,
                rx: runnerX,
                seamY: shelfY,
                scale: 0.44,
                isPaused: false,
                activeBlend: 1.0,
                walkPhase: t * 8.5,
                cheerHop: 0,
                clock: t
            )
        }
        .background(Color.t3MascotStageBg)
    }
}
