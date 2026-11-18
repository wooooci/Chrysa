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

    private static func addTaperedDroplet(
        _ path: inout Path,
        tx: CGFloat, ty: CGFloat,
        hx: CGFloat, hy: CGFloat,
        rTail: CGFloat, rHead: CGFloat
    ) {
        let dx = hx - tx
        let dy = hy - ty
        let dist = hypot(dx, dy)
        if dist < 0.25 {
            addCircleCW(&path, cx: hx, cy: hy, r: rHead)
            return
        }
        let ux = dx / dist, uy = dy / dist
        let nx = uy, ny = -ux
        let k: CGFloat = 0.55228475
        let kh = k * rHead
        let kt = k * rTail
        let waistH = dist * 0.44

        let tip = CGPoint(x: hx + ux * rHead, y: hy + uy * rHead)
        let rH  = CGPoint(x: hx - nx * rHead, y: hy - ny * rHead)
        let rT  = CGPoint(x: tx - nx * rTail, y: ty - ny * rTail)
        let end = CGPoint(x: tx - ux * rTail, y: ty - uy * rTail)
        let lT  = CGPoint(x: tx + nx * rTail, y: ty + ny * rTail)
        let lH  = CGPoint(x: hx + nx * rHead, y: hy + ny * rHead)

        path.move(to: tip)
        path.addCurve(to: rH, control1: CGPoint(x: tip.x - nx * kh, y: tip.y - ny * kh), control2: CGPoint(x: rH.x + ux * kh, y: rH.y + uy * kh))
        path.addCurve(to: rT, control1: CGPoint(x: rH.x - ux * waistH, y: rH.y - uy * waistH), control2: CGPoint(x: rT.x + ux * waistH, y: rT.y + uy * waistH))
        path.addCurve(to: end, control1: CGPoint(x: rT.x - ux * kt, y: rT.y - uy * kt), control2: CGPoint(x: end.x - nx * kt, y: end.y - ny * kt))
        path.addCurve(to: lT, control1: CGPoint(x: end.x + nx * kt, y: end.y + ny * kt), control2: CGPoint(x: lT.x - ux * kt, y: lT.y - uy * kt))
        path.addCurve(to: lH, control1: CGPoint(x: lT.x + ux * waistH, y: lT.y + uy * waistH), control2: CGPoint(x: lH.x - ux * waistH, y: lH.y - uy * waistH))
        path.addCurve(to: tip, control1: CGPoint(x: lH.x + ux * kh, y: lH.y + uy * kh), control2: CGPoint(x: tip.x + nx * kh, y: tip.y + ny * kh))
        path.closeSubpath()
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

    private static func emitGrokbot25DEyes(
        sim: MascotSimState,
        into outPath: inout Path,
        headCx: CGFloat,
        headCy: CGFloat,
        sphereR: CGFloat,
        sepAng: CGFloat,
        baseW: CGFloat,
        baseH: CGFloat,
        scale: CGFloat,
        rotAngle: CGFloat
    ) {
        let yaw = max(-0.56, min(0.56, sim.lookX * 0.54))
        let pitch = max(-0.44, min(0.44, sim.lookY * 0.42))

        let angL = yaw - sepAng
        let angR = yaw + sepAng

        let lxLocal = sphereR * sin(angL)
        let rxLocal = sphereR * sin(angR)
        let yCommon = sphereR * 0.62 * sin(pitch)

        let foreL = max(0.46, min(1.0, cos(angL)))
        let foreR = max(0.46, min(1.0, cos(angR)))

        let c = cos(rotAngle)
        let s = sin(rotAngle)

        let lyLocal = yCommon + sim.eyeLY
        let ryLocal = yCommon + sim.eyeRY

        let wxL = headCx + (lxLocal * c - lyLocal * s) * scale
        let wyL = headCy + (lxLocal * s + lyLocal * c) * scale
        let wxR = headCx + (rxLocal * c - ryLocal * s) * scale
        let wyR = headCy + (rxLocal * s + ryLocal * c) * scale

        let perspTilt = yaw * 0.12
        addRotatedPillCW(
            &outPath,
            cx: wxL, cy: wyL,
            w: baseW * sim.eyeLW * foreL * scale,
            h: baseH * sim.eyeLH * scale,
            ang: rotAngle + sim.eyeLTilt + perspTilt
        )
        addRotatedPillCW(
            &outPath,
            cx: wxR, cy: wyR,
            w: baseW * sim.eyeRW * foreR * scale,
            h: baseH * sim.eyeRH * scale,
            ang: rotAngle + sim.eyeRTilt + perspTilt
        )
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
        pInk: inout Path,
        pLight: inout Path,
        pShade: inout Path,
        pTerm: inout Path
    ) {
        let sx = exp(sim.squash) * sqrt(sim.gasScale)
        let sy = exp(-sim.squash) * sqrt(sim.gasScale)
        let cosT = cos(sim.tiltRad)
        let sinT = sin(sim.tiltRad)

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
            let slotOpen = max(0, min(1.0, sim.mawOpen)) * 12.6
            let ridgeBotX = (12.0 - sim.lookX * 6.8) * sx
            let faceCenterLocalX = (-27.0 * sx + ridgeBotX) * 0.5
            let slotTopLocalY = 11.6 * sy
            let intakePt = xf(faceCenterLocalX, slotTopLocalY + slotOpen * 0.50)

            guard includeBody else { return intakePt }

            if includeShadow {
                var pShadow = Path()
                addEllipseCW(&pShadow, cx: anchorX + 1.5 * scale, cy: anchorY + 30.5 * scale, rx: 24.5 * scale, ry: 4.0 * scale)
                context.fill(pShadow, with: .color(colPaperShadow))
            }

            let pedDrop = slotOpen * 0.52
            var pPedInk = Path()
            var pPedFill = Path()
            let pedTL = xf(-14.0 * sx, 20.0 * sy + pedDrop)
            let pedTR = xf(14.0 * sx, 20.0 * sy + pedDrop)
            let pedBR = xf(10.0 * sx, 26.5 * sy + pedDrop)
            let pedBL = xf(-10.0 * sx, 26.5 * sy + pedDrop)
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
            let leg1T = xf(-6.2, 25.5 * sy + pedDrop)
            let leg1B = xf(-6.2, 32.0 + pedDrop * 0.35)
            let leg2T = xf(6.2, 25.5 * sy + pedDrop)
            let leg2B = xf(6.2, 32.0 + pedDrop * 0.35)
            addRotatedPillCW(&pBackInk, cx: (leg1T.x + leg1B.x) * 0.5, cy: (leg1T.y + leg1B.y) * 0.5, w: 2.1 * scale, h: max(2.5, abs(leg1B.y - leg1T.y)), ang: sim.tiltRad)
            addRotatedPillCW(&pBackInk, cx: (leg2T.x + leg2B.x) * 0.5, cy: (leg2T.y + leg2B.y) * 0.5, w: 2.1 * scale, h: max(2.5, abs(leg2B.y - leg2T.y)), ang: sim.tiltRad)

            let stemB = xf(-2.0, -25.0 * sy - slotOpen * 0.18)
            let swayOff = sim.leafSway * 15.0
            let stemM = xf(-2.0 + swayOff * 0.55, -36.5 * sy - slotOpen * 0.20)
            let cTip = xf(-2.0 + swayOff * 1.15, -53.5 * sy - slotOpen * 0.25)
            let lTip = xf(-16.5 + swayOff * 0.95, -44.5 * sy - slotOpen * 0.20)
            let rTip = xf(12.5 + swayOff * 0.95, -45.0 * sy - slotOpen * 0.20)

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

            let topY = -25.5 * sy - slotOpen * 0.18
            let botY = 21.0 * sy + pedDrop
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

            if slotOpen > 0.35 {
                var pSlot = Path()
                let sL = xf(faceCenterLocalX - 12.2, slotTopLocalY)
                let sR = xf(faceCenterLocalX + 12.2, slotTopLocalY)
                let sBR = xf(faceCenterLocalX + 11.4, slotTopLocalY + slotOpen)
                let sBL = xf(faceCenterLocalX - 11.4, slotTopLocalY + slotOpen)
                addRoundedQuadCW(&pSlot, sL, sR, sBR, sBL, radius: 2.8 * scale)
                context.fill(pSlot, with: .color(Color(red: 46 / 255, green: 35 / 255, blue: 34 / 255)))

                var pGlow = Path()
                let glowC = xf(faceCenterLocalX, slotTopLocalY + slotOpen * 0.52)
                addEllipseCW(&pGlow, cx: glowC.x, cy: glowC.y, rx: 7.2 * scale, ry: max(1.2, slotOpen * 0.34) * scale)
                context.fill(pGlow, with: .color(Color(red: 238 / 255, green: 170 / 255, blue: 96 / 255).opacity(0.95)))
            }

            var pEyes = Path()
            let eyeCenter = xf(faceCenterLocalX, 5.8 * sy - slotOpen * 0.22)
            emitGrokbot25DEyes(sim: sim, into: &pEyes, headCx: eyeCenter.x, headCy: eyeCenter.y, sphereR: 12.5, sepAng: 0.38, baseW: 4.8, baseH: 8.6, scale: scale, rotAngle: sim.tiltRad)
            context.fill(pEyes, with: .color(colInkPen))

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
                let bL = xf(-18.2 + sim.lookX * 4.2, 5.8 - puff * 1.2)
                let bR = xf(18.2 + sim.lookX * 4.2, 5.8 - puff * 1.2)
                addEllipseCW(&pBlush, cx: bL.x, cy: bL.y, rx: 5.8 * scale, ry: 3.3 * scale)
                addEllipseCW(&pBlush, cx: bR.x, cy: bR.y, rx: 5.8 * scale, ry: 3.3 * scale)
                context.fill(pBlush, with: .color(Color(red: 232 / 255, green: 152 / 255, blue: 138 / 255).opacity(0.53)))

                if puff > 0.05 {
                    var pMouth = Path()
                    addEllipseCW(&pMouth, cx: intakePt.x, cy: intakePt.y, rx: (1.8 + puff * 4.6) * scale, ry: (1.6 + puff * 4.8) * scale)
                    context.fill(pMouth, with: .color(Color(red: 76 / 255, green: 44 / 255, blue: 48 / 255)))
                }

                var pEyes = Path()
                let eyeCenter = xf(0.0, 1.0 - puff * 2.0)
                emitGrokbot25DEyes(sim: sim, into: &pEyes, headCx: eyeCenter.x, headCy: eyeCenter.y, sphereR: 17.2, sepAng: 0.48, baseW: 5.3, baseH: 7.6, scale: scale, rotAngle: sim.tiltRad)
                context.fill(pEyes, with: .color(colInkPen))
            }

            if includeForepaws {
                let tapLift = sin(sim.pawTapPhase * .pi) * 6.5
                let airRaise = MascotController.smootherstep(0.12, 0.65, puff) * 13.5
                let airSpread = MascotController.smootherstep(0.12, 0.65, puff) * 5.8
                let pL = xf(-16.8 - airSpread, 21.2 - airRaise - tapLift)
                let pR = xf(16.8 + airSpread, 21.2 - airRaise)

                var pFrontInk = Path()
                var pFrontFill = Path()
                var pFrontPads = Path()
                addRotatedPillCW(&pFrontInk, cx: pL.x, cy: pL.y, w: 13.6 * scale + inkPad * 1.7, h: 9.8 * scale + inkPad * 1.7, ang: sim.tiltRad - 0.18)
                addRotatedPillCW(&pFrontInk, cx: pR.x, cy: pR.y, w: 13.6 * scale + inkPad * 1.7, h: 9.8 * scale + inkPad * 1.7, ang: sim.tiltRad + 0.18)
                addRotatedPillCW(&pFrontFill, cx: pL.x, cy: pL.y, w: 13.6 * scale, h: 9.8 * scale, ang: sim.tiltRad - 0.18)
                addRotatedPillCW(&pFrontFill, cx: pR.x, cy: pR.y, w: 13.6 * scale, h: 9.8 * scale, ang: sim.tiltRad + 0.18)
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
            let intakePt = CGPoint(x: cx, y: orbCy)

            guard includeBody else { return intakePt }

            if includeShadow {
                var pShadow = Path()
                addEllipseCW(&pShadow, cx: anchorX + 1.5 * scale, cy: anchorY + 30.5 * scale, rx: 16.5 * scale, ry: 2.7 * scale)
                context.fill(pShadow, with: .color(colPaperShadow))
            }

            let ringTilt = -0.22 + sim.tiltRad * 0.85 - sim.lookX * 0.08
            let ringRx = (43.0 + puff * 4.5) * scale
            let ringRy = (11.5 + puff * 2.2) * scale
            var pBackRing = Path()
            var pFrontRing = Path()
            addTiltedRingArcs(back: &pBackRing, front: &pFrontRing, cx: cx, cy: orbCy + 2.0 * scale, rx: ringRx, ry: ringRy, ang: ringTilt)

            context.stroke(
                pBackRing,
                with: .color(Color(red: 214 / 255, green: 164 / 255, blue: 88 / 255).opacity(0.85)),
                style: StrokeStyle(lineWidth: lineW * 1.35, lineCap: .round, lineJoin: .round)
            )

            let mAng = sim.haloSpin * 0.95
            let cR = cos(ringTilt), sR = sin(ringTilt)
            let mu = cos(mAng) * ringRx, mv = sin(mAng) * ringRy
            let moonPt = CGPoint(x: cx + mu * cR - mv * sR, y: orbCy + 2.0 * scale + mu * sR + mv * cR)

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
            build8KnotBD(sim: sim, rest8: grokOrbBody8, puff8: grokOrbPuff8, puffAmt: puff, cx: cx, cy: orbCy, scale: scale, inkPad: inkPad, pInk: &pInk, pLight: &pLight, pShade: &pShade, pTerm: &pTerm)

            context.fill(pInk, with: .color(colInkPen))
            context.fill(pLight, with: .color(Color(red: 232 / 255, green: 132 / 255, blue: 100 / 255)))
            context.fill(pShade, with: .color(Color(red: 184 / 255, green: 88 / 255, blue: 62 / 255).opacity(0.73)))
            context.stroke(
                pTerm,
                with: .color(Color(red: 146 / 255, green: 64 / 255, blue: 44 / 255).opacity(0.58)),
                style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round)
            )

            var pEyes = Path()
            emitGrokbot25DEyes(sim: sim, into: &pEyes, headCx: cx, headCy: orbCy - 1.2 * scale, sphereR: 18.0, sepAng: 0.40, baseW: 7.2, baseH: 20.2, scale: scale, rotAngle: sim.tiltRad)
            context.fill(pEyes, with: .color(Color(red: 38 / 255, green: 24 / 255, blue: 20 / 255)))

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

    // MARK: - 0.0px Aligned Parcel Droplet & URL Bead Intake Effects
    package static func drawIntakeEffects(
        in context: inout GraphicsContext,
        frame: MascotTopRenderFrame,
        intakePoint: CGPoint
    ) {
        guard frame.theme.isEnabled, frame.mode != .idle, frame.mode != .reject else { return }

        let siphonExtra: CGFloat = (frame.mode == .multiDrop) ? 0.24 : (frame.mode == .url ? 0.08 : 0.0)
        let moteEnv = MascotController.smootherstep(0.04, 0.20, frame.animT)
            * (1.0 - MascotController.smootherstep(0.54 + siphonExtra, 0.70 + siphonExtra, frame.animT))
            * MascotController.smootherstep(0.24, 0.50, frame.sim.mawOpen)

        if moteEnv > 0.05 {
            var pMotes = Path()
            for k in 1...3 {
                let cyc = (frame.elapsed * 2.4 + CGFloat(k) * 0.33).truncatingRemainder(dividingBy: 1.0)
                let accel = cyc * cyc
                let ang = CGFloat.pi * 0.5 + CGFloat(k - 2) * 0.50
                let dist = lerp(19.0, 2.5, accel)
                addCircleCW(
                    &pMotes,
                    cx: intakePoint.x + cos(ang) * dist,
                    cy: intakePoint.y + sin(ang) * dist * 0.78,
                    r: 1.05 * moteEnv * (1.0 - 0.45 * accel)
                )
            }
            context.fill(pMotes, with: .color(colWindInk))
        }

        if frame.mode == .url {
            // Stream crisp sapphire URL glyph-pearls out of the input bar directly into `intakePoint`!
            var pBeads = Path()
            let sDur: CGFloat = 0.62
            let sProg = max(0, min(1, (frame.animT - 0.03) / sDur))
            let beadCount = 10
            for idx in 0..<beadCount {
                let order = CGFloat(idx) / CGFloat(beadCount - 1)
                let localU = max(0, min(1, sProg * 1.48 - order * 0.48))
                if localU > 0.01 && localU < 0.985 {
                    let startX = lerp(frame.dropOriginX + 70, max(28, frame.dropOriginX - 140), order)
                    let startY = frame.dropOriginY
                    let smoothU = MascotController.smootherstep(0, 1, localU)
                    let accelU = pow(localU, 1.65)
                    let lift = sin(localU * .pi) * 10.5
                    let bx = lerp(startX, intakePoint.x, accelU)
                    let by = lerp(startY, intakePoint.y, smoothU) - lift * (1.0 - localU)
                    let r = 2.4 * (1.0 - 0.65 * MascotController.smootherstep(0.55, 1.0, localU))
                    addCircleCW(&pBeads, cx: bx, cy: by, r: r)
                }
            }
            context.fill(pBeads, with: .color(seamColor(for: frame.theme)))
            return
        }

        let tEnd: CGFloat = (frame.mode == .multiDrop) ? 0.94 : 0.68
        guard frame.animT <= tEnd else { return }

        var pDrop = Path()
        var pDropHi = Path()
        let count = (frame.mode == .multiDrop) ? 3 : 1
        for k in 1...count {
            let startX = (count == 1) ? frame.dropOriginX : (frame.dropOriginX + CGFloat(k - 2) * 48.0)
            let startY = frame.dropOriginY
            let p = max(0, min(1, (frame.animT - (0.02 + CGFloat(k - 1) * 0.16)) / 0.52))
            if p < 0.985 {
                let headU = MascotController.smootherstep(0, 0.76, p)
                let tailU = MascotController.smootherstep(0.22, 1.0, p)
                let hx = lerp(startX, intakePoint.x, headU)
                let hy = lerp(startY, intakePoint.y, headU)
                let tx = lerp(startX, intakePoint.x, tailU)
                let ty = lerp(startY, intakePoint.y, tailU)
                let rHead = lerp(7.6, 1.45, headU)
                let rTail = lerp(6.0, 0.95, tailU)
                addTaperedDroplet(&pDrop, tx: tx, ty: ty, hx: hx, hy: hy, rTail: rTail, rHead: rHead)
                addCircleCW(&pDropHi, cx: lerp(tx, hx, 0.55), cy: lerp(ty, hy, 0.55), r: rHead * 0.38)
            }
        }
        context.fill(pDrop, with: .color(colPaperBg))
        context.stroke(pDrop, with: .color(colInkPen), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        context.fill(pDropHi, with: .color(colTerracotta))
    }

    // MARK: - Master Matched Bottom Progress Bar Companion Renderer
    package static func drawBottomRunner(
        in context: inout GraphicsContext,
        theme: MascotTheme,
        rx: CGFloat,
        seamY: CGFloat,
        scale: CGFloat,
        isPaused: Bool,
        walkPhase: CGFloat,
        cheerHop: CGFloat,
        clock: CGFloat
    ) {
        guard theme.isEnabled else { return }
        let inkPad = max(0.82, 1.80 * scale)

        switch theme {
        case .forestCube:
            let legLen: CGFloat = isPaused ? 0.0 : (5.5 * scale)
            let trotBob: CGFloat = isPaused ? 0.0 : (abs(sin(walkPhase)) * 2.2 * scale)
            let lean: CGFloat = isPaused ? 0.0 : 0.055
            let sx: CGFloat = isPaused ? 1.08 : 1.0
            let sy: CGFloat = isPaused ? 0.90 : 1.0

            let cubeH = 23.0 * sy * scale
            let cubeW = 28.0 * sx * scale
            let cy = seamY - legLen - cubeH * 0.5 - trotBob - cheerHop
            let cx = rx

            var pShadow = Path()
            addEllipseCW(&pShadow, cx: rx, cy: seamY + 0.5, rx: 13.5 * scale, ry: 2.0 * scale)
            context.fill(pShadow, with: .color(colPaperShadow))

            var pBackInk = Path()
            if !isPaused {
                let s1 = sin(walkPhase)
                let s2 = -s1
                addRotatedPillCW(&pBackInk, cx: cx - 5.2 * scale + s1 * 2.8 * scale, cy: seamY - 2.6 * scale - max(0, s1) * 2.0 * scale - cheerHop, w: 2.2 * scale, h: 5.2 * scale, ang: 0)
                addRotatedPillCW(&pBackInk, cx: cx + 5.2 * scale + s2 * 2.8 * scale, cy: seamY - 2.6 * scale - max(0, s2) * 2.0 * scale - cheerHop, w: 2.2 * scale, h: 5.2 * scale, ang: 0)
            }

            let leafBaseX = cx - 1.0 * scale
            let leafBaseY = cy - cubeH * 0.5
            let leafSway: CGFloat = isPaused ? (sin(clock * 1.8) * 1.5) : (-3.5 + sin(walkPhase) * 2.8)
            let leafTipX = leafBaseX + leafSway * scale
            let leafTipY = leafBaseY - 13.5 * scale

            var pLeafFill = Path()
            addLeafCW(&pBackInk, bx: leafBaseX, by: leafBaseY + 1.0 * scale, tx: leafTipX, ty: leafTipY, halfW: 4.6 * scale + inkPad * 0.85, bend: 1.2 * scale)
            addLeafCW(&pLeafFill, bx: leafBaseX, by: leafBaseY + 1.0 * scale, tx: leafTipX, ty: leafTipY, halfW: 4.5 * scale, bend: 1.2 * scale)

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

            var pEyes = Path()
            let eyeCy = cy + hh * 0.30
            let eyeCx = cx - hw * 0.16
            if isPaused {
                addRotatedPillCW(&pEyes, cx: eyeCx - 4.0 * scale, cy: eyeCy, w: 4.2 * scale, h: 1.5 * scale, ang: 0)
                addRotatedPillCW(&pEyes, cx: eyeCx + 4.0 * scale, cy: eyeCy, w: 4.2 * scale, h: 1.5 * scale, ang: 0)
            } else {
                addRotatedPillCW(&pEyes, cx: eyeCx - 3.6 * scale, cy: eyeCy, w: 2.6 * scale, h: 5.0 * scale, ang: lean)
                addRotatedPillCW(&pEyes, cx: eyeCx + 4.2 * scale, cy: eyeCy, w: 2.5 * scale, h: 5.0 * scale, ang: lean)
            }
            context.fill(pEyes, with: .color(colInkPen))

        case .roundMochi:
            let hopAbs: CGFloat = isPaused ? 0.0 : abs(sin(walkPhase * 0.85))
            let hopLift = hopAbs * 7.0 * scale
            let sx: CGFloat = isPaused ? 1.24 : lerp(1.15, 0.91, hopAbs)
            let sy: CGFloat = isPaused ? 0.77 : lerp(0.86, 1.10, hopAbs)
            let cy = seamY - 18.8 * sy * scale - hopLift - cheerHop
            let cx = rx

            var pShadow = Path()
            addEllipseCW(&pShadow, cx: rx, cy: seamY + 0.5, rx: lerp(15.5, 9.2, hopAbs) * scale, ry: 2.0 * scale)
            context.fill(pShadow, with: .color(colPaperShadow))

            let pawFlap: CGFloat = isPaused ? 0.18 : (-0.42 + hopAbs * 0.85)
            let pLx = cx - 22.4 * sx * scale
            let pRx = cx + 22.4 * sx * scale
            let pY = cy + (isPaused ? 9.2 : 4.8) * sy * scale
            var pPawInk = Path()
            var pPawFill = Path()
            addRotatedPillCW(&pPawInk, cx: pLx, cy: pY, w: 9.4 * scale + inkPad * 1.45, h: 6.6 * scale + inkPad * 1.45, ang: -pawFlap)
            addRotatedPillCW(&pPawInk, cx: pRx, cy: pY, w: 9.4 * scale + inkPad * 1.45, h: 6.6 * scale + inkPad * 1.45, ang: pawFlap)
            addRotatedPillCW(&pPawFill, cx: pLx, cy: pY, w: 9.4 * scale, h: 6.6 * scale, ang: -pawFlap)
            addRotatedPillCW(&pPawFill, cx: pRx, cy: pY, w: 9.4 * scale, h: 6.6 * scale, ang: pawFlap)
            context.fill(pPawInk, with: .color(colInkPen))
            context.fill(pPawFill, with: .color(Color(red: 252 / 255, green: 249 / 255, blue: 241 / 255)))

            var kx = Array(repeating: CGFloat(0), count: 6)
            var ky = Array(repeating: CGFloat(0), count: 6)
            var ikx = Array(repeating: CGFloat(0), count: 6)
            var iky = Array(repeating: CGFloat(0), count: 6)
            for i in 0..<6 {
                let p = miniMochi6[i]
                let lx = p.x * sx, ly = p.y * sy
                let len = max(1.0, hypot(lx, ly))
                kx[i] = cx + lx * scale
                ky[i] = cy + ly * scale
                ikx[i] = kx[i] + (lx / len) * inkPad
                iky[i] = ky[i] + (ly / len) * inkPad
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

            let eyeY = cy + 1.5 * scale
            var pBlush = Path()
            addEllipseCW(&pBlush, cx: cx - 12.2 * sx * scale, cy: eyeY + 3.0 * scale, rx: 4.2 * scale, ry: 2.4 * scale)
            addEllipseCW(&pBlush, cx: cx + 12.2 * sx * scale, cy: eyeY + 3.0 * scale, rx: 4.2 * scale, ry: 2.4 * scale)
            context.fill(pBlush, with: .color(Color(red: 232 / 255, green: 148 / 255, blue: 134 / 255).opacity(0.62)))

            var pEyes = Path()
            if isPaused {
                addRotatedPillCW(&pEyes, cx: cx - 6.0 * scale, cy: eyeY, w: 5.0 * scale, h: 1.7 * scale, ang: 0)
                addRotatedPillCW(&pEyes, cx: cx + 6.0 * scale, cy: eyeY, w: 5.0 * scale, h: 1.7 * scale, ang: 0)
            } else {
                addRotatedPillCW(&pEyes, cx: cx - 5.4 * scale + 1.2 * scale, cy: eyeY, w: 3.5 * scale, h: 5.8 * scale, ang: 0.04)
                addRotatedPillCW(&pEyes, cx: cx + 6.2 * scale + 1.2 * scale, cy: eyeY, w: 3.3 * scale, h: 5.8 * scale, ang: 0.04)
            }
            context.fill(pEyes, with: .color(colInkPen))

        case .grokAstral:
            let hoverGap: CGFloat = isPaused ? (5.5 * scale) : ((12.5 + sin(clock * 4.2) * 2.4) * scale)
            let lean: CGFloat = isPaused ? 0.0 : 0.13
            let cy = seamY - 22.0 * scale - hoverGap - cheerHop
            let cx = rx
            let ringW = max(0.95, 1.8 * scale)

            var pShadow = Path()
            addEllipseCW(&pShadow, cx: rx, cy: seamY + 0.5, rx: 10.0 * scale, ry: 1.6 * scale)
            context.fill(pShadow, with: .color(colPaperShadow))

            let trailX = cx - (28.0 + sin(clock * 5.0) * 2.0) * scale
            let trailY = cy + (2.5 + cos(clock * 4.2) * 2.0) * scale
            var pTrailInk = Path()
            var pTrailFill = Path()
            addCircleCW(&pTrailInk, cx: trailX, cy: trailY, r: 3.0 * scale + inkPad * 0.7)
            addCircleCW(&pTrailFill, cx: trailX, cy: trailY, r: 2.9 * scale)

            var pBackRing = Path()
            var pFrontRing = Path()
            addTiltedRingArcs(back: &pBackRing, front: &pFrontRing, cx: cx, cy: cy + 1.2 * scale, rx: 27.5 * scale, ry: 7.2 * scale, ang: -0.20 + lean * 0.5)

            context.stroke(
                pBackRing,
                with: .color(Color(red: 214 / 255, green: 164 / 255, blue: 88 / 255).opacity(0.86)),
                style: StrokeStyle(lineWidth: ringW, lineCap: .round, lineJoin: .round)
            )
            context.fill(pTrailInk, with: .color(colInkPen))
            context.fill(pTrailFill, with: .color(Color(red: 244 / 255, green: 204 / 255, blue: 118 / 255)))

            let c = cos(lean), s = sin(lean)
            var kx = Array(repeating: CGFloat(0), count: 8)
            var ky = Array(repeating: CGFloat(0), count: 8)
            var ikx = Array(repeating: CGFloat(0), count: 8)
            var iky = Array(repeating: CGFloat(0), count: 8)
            for i in 0..<8 {
                let p = miniOrb8[i]
                let rxP = p.x * c - p.y * s
                let ryP = p.x * s + p.y * c
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

            var pEyes = Path()
            let eyeOff: CGFloat = isPaused ? 0.0 : (2.2 * scale)
            if isPaused {
                addRotatedPillCW(&pEyes, cx: cx - 5.2 * scale, cy: cy, w: 5.2 * scale, h: 1.8 * scale, ang: 0)
                addRotatedPillCW(&pEyes, cx: cx + 5.2 * scale, cy: cy, w: 5.2 * scale, h: 1.8 * scale, ang: 0)
            } else {
                addRotatedPillCW(&pEyes, cx: cx - 4.2 * scale + eyeOff, cy: cy - 0.5 * scale, w: 3.6 * scale, h: 10.6 * scale, ang: lean)
                addRotatedPillCW(&pEyes, cx: cx + 4.8 * scale + eyeOff, cy: cy - 0.5 * scale, w: 3.4 * scale, h: 10.6 * scale, ang: lean)
            }
            context.fill(pEyes, with: .color(Color(red: 38 / 255, green: 24 / 255, blue: 20 / 255)))

            context.stroke(
                pFrontRing,
                with: .color(Color(red: 234 / 255, green: 186 / 255, blue: 100 / 255).opacity(0.95)),
                style: StrokeStyle(lineWidth: ringW * 1.08, lineCap: .round, lineJoin: .round)
            )

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

    @State private var isDropTargeted = false

    private let skyHeight: CGFloat = 52.0

    var body: some View {
        let theme = vm.mascotTheme
        let typingURL = (vm.activeTab == .download && !vm.urlInput.isEmpty)

        if !theme.isEnabled {
            content()
        } else if isSnapshotMode {
            mascotDecoratedContent(at: 0.55, theme: theme, typingURL: typingURL)
        } else {
            TimelineView(.animation(minimumInterval: vm.mascot.isActivelyAnimatingTop ? (1.0 / 60.0) : (1.0 / 24.0))) { timeline in
                mascotDecoratedContent(
                    at: timeline.date.timeIntervalSinceReferenceDate,
                    theme: theme,
                    typingURL: typingURL
                )
            }
            .onDrop(of: [.fileURL, .plainText, .url], isTargeted: $isDropTargeted) { providers in
                vm.handleDroppedProviders(providers)
            }
            .onChange(of: isDropTargeted) { _, targeted in
                vm.mascot.setDropHovering(targeted)
            }
        }
    }

    @ViewBuilder
    private func mascotDecoratedContent(at now: TimeInterval, theme: MascotTheme, typingURL: Bool) -> some View {
        content()
            .background(alignment: .bottom) {
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
                        isSnapshotMode: isSnapshotMode
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
            .overlay(alignment: .bottom) {
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
                        isSnapshotMode: isSnapshotMode
                    )
                    ZStack(alignment: .topLeading) {
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
                                    sim: frame.theme == .none ? frame.sim : frame.sim,
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
                                intakePoint: intakePt
                            )
                        }
                        .frame(width: w, height: totalH)
                        .allowsHitTesting(false)

                        if !isSnapshotMode {
                            // Compact interactive hit-box right on the perched mascot:
                            // Left-click -> tactile ZCode Boing; Right-click -> quick Theme Switcher menu!
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
}

// MARK: - 2. Bottom Progress Seam Companion Overlay (Rides Directly Along the Bottom Divider Seam)
struct MascotBottomProgressOverlay: View {
    @ObservedObject var vm: StudioViewModel
    let isSnapshotMode: Bool

    private let overlayHeight: CGFloat = 30.0
    private let horizontalInset: CGFloat = 34.0

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
            TimelineView(.animation(minimumInterval: (!status.isPaused && status.progress != nil) ? (1.0 / 60.0) : (1.0 / 18.0))) { timeline in
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
                    walkPhase: frame.walkPhase,
                    cheerHop: frame.cheerHop,
                    clock: frame.clock
                )
            }
            .frame(width: w, height: overlayHeight)
        }
    }
}

// MARK: - 3. Pure Picture-Only Matched-Duo Theme Picker Card for Settings -> 外观 (Zero Text!)
struct MascotThemeCardView: View {
    let option: MascotTheme
    let isSelected: Bool
    let isSnapshotMode: Bool
    let onSelect: () -> Void
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        duoMiniStage
            .padding(8)
            .frame(maxWidth: .infinity)
            .frame(height: 88)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? appTheme.accent.opacity(0.06) : Color.t3TopBoxBg.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(isSelected ? appTheme.accent : Color.t3Divider, lineWidth: isSelected ? 1.8 : 1.0)
                    )
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    ZStack {
                        Circle()
                            .fill(appTheme.accent)
                            .frame(width: 16, height: 16)
                            .shadow(color: Color.black.opacity(0.15), radius: 2, x: 0, y: 1)
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(5)
                }
            }
            .contentShape(Rectangle())
            .onInstantPress(onSelect)
    }

    @ViewBuilder
    private var duoMiniStage: some View {
        if option == .none {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.t3Divider, lineWidth: 1)
                    )
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.t3TopBoxBg)
                        .frame(width: 96, height: 14)
                    HStack(spacing: 6) {
                        Circle()
                            .stroke(Color.t3CheckBorder, lineWidth: 1.3)
                            .frame(width: 9, height: 9)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.t3Divider)
                            .frame(width: 68, height: 5)
                    }
                    Rectangle()
                        .fill(Color.t3Divider)
                        .frame(width: 96, height: 1.5)
                }
            }
        } else if isSnapshotMode {
            duoStageCanvas(t: 0.72)
        } else {
            TimelineView(.animation(minimumInterval: isSelected ? (1.0 / 30.0) : (1.0 / 12.0))) { timeline in
                duoStageCanvas(t: CGFloat(timeline.date.timeIntervalSinceReferenceDate))
            }
        }
    }

    @ViewBuilder
    private func duoStageCanvas(t: CGFloat) -> some View {
        Canvas { ctx, size in
            let shelfY = size.height - 11.0
            let leftShelfX1: CGFloat = 10
            let leftShelfX2: CGFloat = size.width * 0.50
            let rightSeamX1: CGFloat = size.width * 0.56
            let rightSeamX2: CGFloat = size.width - 10
            let runnerX: CGFloat = MascotController.lerp(rightSeamX1, rightSeamX2, 0.58)

            var pShelf = Path()
            pShelf.move(to: CGPoint(x: leftShelfX1, y: shelfY))
            pShelf.addLine(to: CGPoint(x: leftShelfX2, y: shelfY))
            ctx.stroke(pShelf, with: .color(MascotVectorRenderer.colPaperLine), style: StrokeStyle(lineWidth: 1.05, lineCap: .round))

            var pSeamBg = Path()
            pSeamBg.move(to: CGPoint(x: rightSeamX1, y: shelfY))
            pSeamBg.addLine(to: CGPoint(x: rightSeamX2, y: shelfY))
            ctx.stroke(pSeamBg, with: .color(MascotVectorRenderer.colPaperLine.opacity(0.65)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

            var pSeamFill = Path()
            pSeamFill.move(to: CGPoint(x: rightSeamX1, y: shelfY))
            pSeamFill.addLine(to: CGPoint(x: runnerX, y: shelfY))
            ctx.stroke(pSeamFill, with: .color(MascotVectorRenderer.seamColor(for: option)), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))

            let topScale: CGFloat = 0.62
            let topCx: CGFloat = (leftShelfX1 + leftShelfX2) * 0.5 + (option == .forestCube ? 1.5 : 0.0)
            let topAnchorY: CGFloat = (option == .roundMochi)
                ? (shelfY - 19.0 * topScale)
                : (shelfY - 30.5 * topScale)

            var sim = MascotSimState(startX: topCx, startY: topAnchorY)
            sim.haloSpin = t * 1.6
            sim.leafSway = sin(t * 2.1) * 0.12
            sim.lookX = sin(t * 0.9) * 0.22
            sim.boingY = sin(t * 2.0) * 0.85

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
                scale: 0.50,
                isPaused: false,
                walkPhase: t * 8.5,
                cheerHop: 0,
                clock: t
            )
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(MascotVectorRenderer.colPaperBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(MascotVectorRenderer.colPaperLine.opacity(0.65), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
