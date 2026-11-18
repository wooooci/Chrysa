import ChrysaCore
import CoreGraphics
import Foundation

package enum MascotEyePose: String, Sendable, Equatable {
    case auto
    case curious
    case sideEye
    case beaming
    case sleepy
    case focus
}

package enum MascotIntakeKind: Sendable, Equatable {
    case idle
    case url
    case fileDrop
    case multiDrop
    case reject
}

package struct MascotLiveKnot: Sendable, Equatable {
    package var x: CGFloat = 0
    package var y: CGFloat = 0
    package var vx: CGFloat = 0
    package var vy: CGFloat = 0
    package var omega: CGFloat
    package var zeta: CGFloat
    package var lagGain: CGFloat
}

package struct MascotSimState: Sendable, Equatable {
    package var knots: [MascotLiveKnot]
    package var coreX: CGFloat
    package var coreY: CGFloat
    package var velX: CGFloat = 0
    package var velY: CGFloat = 0

    package var squash: CGFloat = 0
    package var squashVel: CGFloat = 0
    package var targetSquash: CGFloat = 0

    package var gasScale: CGFloat = 1.0
    package var gasVel: CGFloat = 0
    package var targetGas: CGFloat = 1.0

    package var tiltRad: CGFloat = 0
    package var tiltVel: CGFloat = 0
    package var targetTilt: CGFloat = 0

    package var swayShear: CGFloat = 0
    package var swayVel: CGFloat = 0
    package var targetSway: CGFloat = 0

    package var lookX: CGFloat = 0
    package var lookY: CGFloat = 0
    package var targetLookX: CGFloat = 0
    package var targetLookY: CGFloat = 0
    package var saccadeX: CGFloat = 0
    package var saccadeY: CGFloat = 0
    package var saccadeTimer: CGFloat = 1.3
    package var saccadeTilt: CGFloat = 0

    package var eyeLW: CGFloat = 1.0
    package var eyeLH: CGFloat = 1.0
    package var eyeLTilt: CGFloat = 0.03
    package var eyeLY: CGFloat = 0.0
    package var eyeRW: CGFloat = 1.0
    package var eyeRH: CGFloat = 1.0
    package var eyeRTilt: CGFloat = 0.03
    package var eyeRY: CGFloat = 0.0

    package var blinkOpen: CGFloat = 1.0
    package var blinkTimer: CGFloat = 0.0
    package var nextBlinkAt: CGFloat = 2.6

    package var mawOpen: CGFloat = 0
    package var mawVel: CGFloat = 0
    package var targetMaw: CGFloat = 0

    package var boingY: CGFloat = 0
    package var boingVel: CGFloat = 0
    package var leafSway: CGFloat = 0
    package var leafVel: CGFloat = 0
    package var haloSpin: CGFloat = 0.8
    package var pawTapPhase: CGFloat = 0

    package var smileCurve: CGFloat = 0
    package var targetSmileCurve: CGFloat = 0
    package var stuffedCheeks: CGFloat = 0
    package var targetStuffed: CGFloat = 0

    package var poseOverride: MascotEyePose = .auto
    package var activePose: MascotEyePose = .auto

    package init(startX: CGFloat = 480, startY: CGFloat = -11.4) {
        let omegas: [CGFloat] = [22.0, 19.0, 17.5, 19.0, 22.0, 24.0, 27.0, 24.0]
        let zetas: [CGFloat]  = [0.48, 0.44, 0.40, 0.44, 0.48, 0.52, 0.58, 0.52]
        let lags: [CGFloat]   = [0.45, 0.82, 1.00, 0.82, 0.45, 0.25, 0.12, 0.25]
        var built: [MascotLiveKnot] = []
        built.reserveCapacity(8)
        for i in 0..<8 {
            built.append(MascotLiveKnot(omega: omegas[i], zeta: zetas[i], lagGain: lags[i]))
        }
        self.knots = built
        self.coreX = startX
        self.coreY = startY
    }

    package mutating func triggerZCodeBoing() {
        boingVel = -62.0
        squashVel = -1.4
        pawTapPhase = 1.0
    }

    package mutating func triggerSatisfiedGulp() {
        boingVel = -44.0
        squashVel = -1.35
        pawTapPhase = 1.0
    }

    package mutating func triggerLatchCatch() {
        // Subtle tactile micro-catch right when the gliding URL tip enters the open mouth!
        boingVel = 16.0
        squashVel = 0.75
        pawTapPhase = 0.55
    }

    package mutating func triggerChompImpact() {
        // Crisp weighted recoil when the jaw snaps shut on the tail of the URL!
        boingVel = 36.0
        squashVel = 2.15
        mawVel = -14.0
        pawTapPhase = 0.9
    }

    package mutating func stepContinuous(dt: CGFloat, prevCoreX: CGFloat, prevCoreY: CGFloat, isIdleCalm: Bool) {
        guard dt > 0.00001 else { return }

        let rawVx = (coreX - prevCoreX) / dt
        let rawVy = (coreY - prevCoreY) / dt
        let oldVx = velX
        let oldVy = velY
        let vSmooth = 1.0 - exp(-dt * 24.0)
        velX += (rawVx - velX) * vSmooth
        velY += (rawVy - velY) * vSmooth

        let accelX = max(-2000, min(2000, (velX - oldVx) / dt))
        let accelY = max(-2200, min(2200, (velY - oldVy) / dt))

        if isIdleCalm && poseOverride == .auto {
            saccadeTimer -= dt
            if saccadeTimer <= 0 {
                let seed = (haloSpin * 3.71 + 1.19).truncatingRemainder(dividingBy: 1.0)
                saccadeTimer = 1.55 + abs(seed) * 1.75
                if seed < 0.28 {
                    saccadeX = -0.24
                    saccadeY = 0.14
                    saccadeTilt = -0.035
                } else if seed < 0.56 {
                    saccadeX = 0.22
                    saccadeY = -0.08
                    saccadeTilt = 0.035
                } else {
                    saccadeX = 0
                    saccadeY = 0
                    saccadeTilt = 0
                }
            }
        } else {
            let decay = exp(-dt * 10.0)
            saccadeX *= decay
            saccadeY *= decay
            saccadeTilt *= decay
        }

        let effLookX = max(-1.0, min(1.0, targetLookX + saccadeX))
        let effLookY = max(-1.0, min(1.0, targetLookY + saccadeY))
        let lookRate = 1.0 - exp(-dt * 16.0)
        lookX += (effLookX - lookX) * lookRate
        lookY += (effLookY - lookY) * lookRate

        smileCurve += (targetSmileCurve - smileCurve) * (1.0 - exp(-dt * 10.0))
        stuffedCheeks += (targetStuffed - stuffedCheeks) * (1.0 - exp(-dt * 9.5))

        blinkTimer += dt
        if blinkTimer >= nextBlinkAt {
            let bPhase = (blinkTimer - nextBlinkAt) / 0.105
            if bPhase >= 1.0 {
                blinkOpen = 1.0
                blinkTimer = 0.0
                nextBlinkAt = 2.5 + abs((haloSpin * 1.93).truncatingRemainder(dividingBy: 2.1))
            } else {
                blinkOpen = abs(bPhase * 2.0 - 1.0)
            }
        } else {
            blinkOpen = 1.0
        }

        var pose = poseOverride
        if pose == .auto {
            if smileCurve > 0.38 {
                pose = .beaming
            } else if mawOpen > 0.36 {
                pose = .focus
            } else if mawOpen > 0.05 {
                pose = .curious
            } else {
                pose = .auto
            }
        }
        activePose = pose

        var (tLW, tLH, tLTilt, tLY): (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0, 1.0, 0.03, 0.0)
        var (tRW, tRH, tRTilt, tRY): (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0, 1.0, 0.03, 0.0)

        switch pose {
        case .auto:
            break
        case .curious:
            (tLW, tLH, tLTilt, tLY) = (1.04, 0.64, -0.10, 1.2)
            (tRW, tRH, tRTilt, tRY) = (0.98, 1.12, -0.06, -1.0)
        case .sideEye:
            (tLW, tLH, tLTilt, tLY) = (1.28, 0.26, 0.0, 0.5)
            (tRW, tRH, tRTilt, tRY) = (0.94, 1.08, 0.0, -0.4)
        case .beaming:
            (tLW, tLH, tLTilt, tLY) = (1.06, 0.94, 0.19, -2.0)
            (tRW, tRH, tRTilt, tRY) = (1.06, 0.94, 0.19, -2.4)
        case .sleepy:
            (tLW, tLH, tLTilt, tLY) = (1.22, 0.20, 0.04, 2.2)
            (tRW, tRH, tRTilt, tRY) = (1.22, 0.20, -0.04, 2.2)
        case .focus:
            (tLW, tLH, tLTilt, tLY) = (1.08, 0.84, -0.14, -0.5)
            (tRW, tRH, tRTilt, tRY) = (1.08, 0.84, 0.14, -0.5)
        }

        let bMult: CGFloat = (pose == .sleepy) ? 1.0 : max(0.14, blinkOpen)
        tLH *= bMult
        tRH *= bMult

        let eyeRate = 1.0 - exp(-dt * 18.0)
        eyeLW += (tLW - eyeLW) * eyeRate
        eyeLH += (tLH - eyeLH) * eyeRate
        eyeLTilt += (tLTilt - eyeLTilt) * eyeRate
        eyeLY += (tLY - eyeLY) * eyeRate
        eyeRW += (tRW - eyeRW) * eyeRate
        eyeRH += (tRH - eyeRH) * eyeRate
        eyeRTilt += (tRTilt - eyeRTilt) * eyeRate
        eyeRY += (tRY - eyeRY) * eyeRate

        haloSpin += dt * (1.8 + mawOpen * 5.5)
        if pawTapPhase > 0 {
            pawTapPhase = max(0, pawTapPhase - dt * 3.2)
        }

        let steps = 4
        let h = dt / CGFloat(steps)
        let poseTiltAdd: CGFloat = (pose == .curious) ? 0.05 : (pose == .sideEye ? -0.05 : 0.0)

        for _ in 0..<steps {
            let aSq = 400.0 * (targetSquash - squash) - 20.8 * squashVel
            squashVel += aSq * h
            squash = max(-0.22, min(0.24, squash + squashVel * h))

            let aMaw = 484.0 * (targetMaw - mawOpen) - 36.08 * mawVel
            mawVel += aMaw * h
            mawOpen = max(0.0, mawOpen + mawVel * h)

            let aGas = 324.0 * (targetGas - gasScale) - 20.16 * gasVel
            gasVel += aGas * h
            gasScale = max(0.88, min(1.22, gasScale + gasVel * h))

            let effTilt = targetTilt + saccadeTilt + poseTiltAdd
            let aTilt = 361.0 * (effTilt - tiltRad) - 24.32 * tiltVel
            tiltVel += aTilt * h
            tiltRad = max(-0.26, min(0.26, tiltRad + tiltVel * h))

            let aSway = 441.0 * (targetSway - swayShear) - 23.52 * swayVel
            swayVel += aSway * h
            swayShear = max(-12.0, min(12.0, swayShear + swayVel * h))

            let aBoing = 676.0 * (0 - boingY) - 30.16 * boingVel
            boingVel += aBoing * h
            boingY = max(-10.0, min(8.0, boingY + boingVel * h))

            let leafTarget = -velX * 0.015 + swayShear * 0.08 + sin(haloSpin * 1.4) * 0.08
            leafVel += (361.0 * (leafTarget - leafSway) - 13.68 * leafVel) * h
            leafSway = max(-0.55, min(0.55, leafSway + leafVel * h))

            for i in 0..<8 {
                let tx = -accelX * 0.0036 * knots[i].lagGain
                let ty = -accelY * 0.0046 * knots[i].lagGain
                let w2 = knots[i].omega * knots[i].omega
                let damp = 2.0 * knots[i].zeta * knots[i].omega
                knots[i].vx += (w2 * (tx - knots[i].x) - damp * knots[i].vx) * h
                knots[i].vy += (w2 * (ty - knots[i].y) - damp * knots[i].vy) * h
                knots[i].x += knots[i].vx * h
                knots[i].y += knots[i].vy * h
            }
        }
    }
}

package struct MascotTopRenderFrame: Sendable, Equatable {
    package var theme: MascotTheme
    package var sim: MascotSimState
    package var isFrontLayer: Bool
    package var mode: MascotIntakeKind
    package var animT: CGFloat
    package var elapsed: CGFloat
    package var boxTopY: CGFloat
    package var siphonText: String
    package var boxShakeX: CGFloat
}

package struct MascotRunnerRenderFrame: Sendable, Equatable {
    package var theme: MascotTheme
    package var runnerX: CGFloat
    package var hasActiveProgress: Bool
    package var isPaused: Bool
    package var walkPhase: CGFloat
    package var cheerHop: CGFloat
    package var clock: CGFloat
}

@MainActor
package final class MascotController {
    nonisolated package static let uiMascotScale: CGFloat = 0.36
    nonisolated package static let uiRunnerScale: CGFloat = 0.38
    nonisolated package static let maxSiphonCharacters: Int = 28

    package private(set) var sim = MascotSimState()
    package private(set) var mode: MascotIntakeKind = .idle
    package private(set) var animT: CGFloat = 0
    package private(set) var elapsed: CGFloat = 0
    package private(set) var activeSiphonText: String = ""

    private var lastTopTimestamp: TimeInterval?
    private var cachedTopFrame: MascotTopRenderFrame?
    private var lastRunnerTimestamp: TimeInterval?
    private var lastTheme: MascotTheme = .forestCube
    private var barWidth: CGFloat = 605

    private var startMaw: CGFloat = 0
    private var latchFired = false
    private var chompFired = false
    private var gulpFired = false
    private var afterglowTimer: CGFloat = 0
    private var boxShakeX: CGFloat = 0
    private var isFrontLayer = true

    private var isDropHovering = false
    private var dropProximity: CGFloat = 0
    private var pointerX: CGFloat = 300
    private var pointerY: CGFloat = 0

    private var runnerX: CGFloat = 24
    private var runnerInitialized = false
    private var runnerPhase: CGFloat = 0
    private var runnerCheerTimer: CGFloat = 0
    private var runnerClock: CGFloat = 0

    package init() {}

    /// Normalizes a pasted URL / multi-line batch / filename to a clean single line and caps long strings
    /// to a fixed `maxSiphonCharacters` prefix + `"..."` so the visual siphon stream always has a predictable length.
    nonisolated package static func fixedLengthSiphonText(
        _ raw: String,
        maxCharacters: Int = maxSiphonCharacters
    ) -> String {
        let lines = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first else { return "" }

        let condensed = first.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        let cap = max(8, maxCharacters)
        if condensed.count > cap {
            return String(condensed.prefix(cap)) + "..."
        }
        return condensed
    }

    nonisolated package static func restAnchorY(for theme: MascotTheme, boxTopY: CGFloat = 0) -> CGFloat {
        switch theme {
        case .roundMochi:
            // Belly tucks smoothly behind topDropZone while rosy cheeks & eyes stay cleanly above boxTopY,
            // and chubby Bongo-Cat forepaws hook right over boxTopY!
            return boxTopY - 6.8
        case .forestCube:
            return boxTopY - 11.4
        case .grokAstral:
            return boxTopY - 13.6
        case .none:
            return boxTopY - 11.4
        }
    }

    nonisolated package static func slotAlignOffsetX(for theme: MascotTheme, scale: CGFloat = uiMascotScale) -> CGFloat {
        if theme == .forestCube {
            return 7.5 * scale
        }
        return 0.0
    }

    package var isActivelyAnimatingTop: Bool {
        mode != .idle || isDropHovering || afterglowTimer > 0.01 || abs(sim.boingY) > 0.25 || sim.pawTapPhase > 0.01
    }

    package func notifyThemeChanged(_ newTheme: MascotTheme) {
        guard newTheme != lastTheme else { return }
        lastTheme = newTheme
        sim.coreY = Self.restAnchorY(for: newTheme)
        if newTheme.isEnabled {
            sim.triggerZCodeBoing()
        }
    }

    package func triggerBoing() {
        sim.triggerZCodeBoing()
        afterglowTimer = max(afterglowTimer, 0.55)
    }

    package func triggerCheerHop() {
        runnerCheerTimer = 0.45
        afterglowTimer = max(afterglowTimer, 0.65)
        sim.triggerSatisfiedGulp()
    }

    package func setDropHovering(_ hovering: Bool) {
        isDropHovering = hovering
    }

    package func updatePointer(x: CGFloat, y: CGFloat) {
        pointerX = x
        pointerY = y
    }

    package func triggerIntake(kind: MascotIntakeKind, rawText: String = "") {
        guard kind != .idle else { return }
        mode = kind
        animT = 0
        latchFired = false
        chompFired = false
        gulpFired = false
        boxShakeX = 0
        sim.poseOverride = .auto
        startMaw = sim.mawOpen

        let formatted = Self.fixedLengthSiphonText(rawText)
        if !formatted.isEmpty {
            activeSiphonText = formatted
        } else {
            switch kind {
            case .url:       activeSiphonText = "https://chrysa.app/dl/..."
            case .multiDrop: activeSiphonText = "3x_Archive_Batch.7z"
            case .fileDrop:  activeSiphonText = "Game_Archive.7z"
            case .reject:    activeSiphonText = "invalid_link???"
            case .idle:      activeSiphonText = ""
            }
        }
    }

    package func stepTopFrame(
        at timestamp: TimeInterval,
        theme: MascotTheme,
        width: CGFloat,
        boxTopY: CGFloat,
        isTypingURL: Bool,
        isSnapshotMode: Bool
    ) -> MascotTopRenderFrame {
        let clampedW = max(240, width)
        barWidth = clampedW
        let lurkX = clampedW - 96.0
        let lurkIdleY = Self.restAnchorY(for: theme, boxTopY: boxTopY)

        if lastTheme != theme {
            lastTheme = theme
            sim.coreX = lurkX
            sim.coreY = lurkIdleY
        }

        if isSnapshotMode {
            if mode != .idle, let cached = cachedTopFrame, cached.theme == theme {
                return cached
            }
            var snapSim = MascotSimState(startX: lurkX, startY: lurkIdleY)
            snapSim.haloSpin = 1.05
            snapSim.lookX = -0.18
            snapSim.lookY = 0.08
            return MascotTopRenderFrame(
                theme: theme,
                sim: snapSim,
                isFrontLayer: theme != .roundMochi,
                mode: .idle,
                animT: 0,
                elapsed: 1.2,
                boxTopY: boxTopY,
                siphonText: "",
                boxShakeX: 0
            )
        }

        if let prev = lastTopTimestamp,
           abs(timestamp - prev) < 0.0002,
           let cached = cachedTopFrame,
           cached.theme == theme {
            return cached
        }

        let dt: CGFloat
        if let prev = lastTopTimestamp {
            dt = CGFloat(max(0.001, min(0.05, timestamp - prev)))
        } else {
            dt = 1.0 / 60.0
            sim.coreX = lurkX
            sim.coreY = lurkIdleY
        }
        lastTopTimestamp = timestamp
        elapsed += dt

        let prevX = sim.coreX
        let prevY = sim.coreY
        let isIdleCalm = updateStationaryChoreography(
            dt: dt,
            theme: theme,
            lurkX: lurkX,
            lurkIdleY: lurkIdleY,
            isTypingURL: isTypingURL
        )
        sim.stepContinuous(dt: dt, prevCoreX: prevX, prevCoreY: prevY, isIdleCalm: isIdleCalm)

        let built = MascotTopRenderFrame(
            theme: theme,
            sim: sim,
            isFrontLayer: isFrontLayer,
            mode: mode,
            animT: animT,
            elapsed: elapsed,
            boxTopY: boxTopY,
            siphonText: activeSiphonText,
            boxShakeX: boxShakeX
        )
        cachedTopFrame = built
        return built
    }

    private func updateStationaryChoreography(
        dt: CGFloat,
        theme: MascotTheme,
        lurkX: CGFloat,
        lurkIdleY: CGFloat,
        isTypingURL: Bool
    ) -> Bool {
        // Mascot ALWAYS stays cozily perched at `lurkX` (zero sideways or aerial jumping!).
        // Round Mochi ALWAYS stays behind the bar (`isFrontLayer = false`) with its paws over the front border!
        isFrontLayer = (theme != .roundMochi)

        let wantHover = isDropHovering || isTypingURL
        let targetProx: CGFloat = wantHover ? 1.0 : 0.0
        dropProximity += (targetProx - dropProximity) * (1.0 - exp(-dt * 10.0))

        if mode == .idle {
            let posRate = 1.0 - exp(-dt * 10.0)
            sim.coreX += (lurkX - sim.coreX) * posRate

            if dropProximity > 0.04 {
                let perkLift: CGFloat = (theme == .roundMochi) ? -1.4 : -0.8
                sim.coreY += ((lurkIdleY + perkLift * dropProximity) - sim.coreY) * posRate

                let hoverGate = Self.smootherstep(0.02, 0.35, dropProximity)
                sim.targetMaw = (isDropHovering ? 0.34 : 0.16) * hoverGate
                sim.targetSmileCurve = 0
                sim.targetGas = 1.0 + 0.02 * dropProximity
                sim.targetSquash = -0.015 * dropProximity
                sim.targetTilt = -0.035 * hoverGate
                sim.targetSway = sin(elapsed * 4.2) * 0.7 * hoverGate
                sim.targetLookX = -0.52
                sim.targetLookY = 0.28
                sim.targetStuffed = 0
                return false
            }

            var fade: CGFloat = 0
            if afterglowTimer > 0 {
                afterglowTimer = max(0, afterglowTimer - dt)
                fade = Self.smootherstep(0.0, 0.55, afterglowTimer)
            }

            let breath = sin(elapsed * 1.9) * 0.45
            sim.coreY += ((lurkIdleY + breath) - sim.coreY) * (1.0 - exp(-dt * 8.0))
            sim.targetMaw = 0
            sim.targetSmileCurve = fade
            sim.targetGas = 1.0
            sim.targetSquash = sin(elapsed * 1.9) * 0.012 * (1.0 - fade)
            sim.targetTilt = 0
            sim.targetSway = 0
            sim.targetStuffed = 0

            sim.targetLookX = max(-0.88, min(0.88, (pointerX - sim.coreX) / 170.0)) * (1.0 - 0.5 * fade)
            sim.targetLookY = max(-0.75, min(0.75, (pointerY - sim.coreY) / 145.0)) * (1.0 - 0.5 * fade)
            return fade <= 0.2
        }

        let siphonExtra: CGFloat = (mode == .multiDrop) ? 0.14 : 0.0
        let tApproachEnd: CGFloat = 0.62
        let tSlurpEnd: CGFloat = 1.36 + siphonExtra
        let tChewEnd: CGFloat = 1.78 + siphonExtra
        let tTotal: CGFloat = 2.08 + siphonExtra

        animT += dt
        let t = animT

        if t >= tTotal {
            if mode != .reject {
                afterglowTimer = 0.55
            }
            sim.poseOverride = .auto
            mode = .idle
            boxShakeX = 0
            return false
        }

        let openIn = Self.smootherstep(0.0, 0.12, t)
        let approachProg = Self.smootherstep(0.03, tApproachEnd, t)
        let inhaleBell = sin(approachProg * .pi) * (1.0 - Self.smootherstep(tApproachEnd - 0.04, tApproachEnd + 0.06, t))
        // Jaw stays wide open during the entire ribbon feed, then SNAPS shut at `tSlurpEnd`!
        let chompSnap = Self.smootherstep(tSlurpEnd - 0.03, tSlurpEnd + 0.06, t)
        let slurpEnv = openIn * (1.0 - chompSnap)

        // Stay planted right at `lurkX`: gentle backward draw while inhaling in Phase 1, crisp recoil on chomp!
        let inhaleDrawX: CGFloat = inhaleBell * 1.15
        let chompRecoilX: CGFloat = sin(Self.smootherstep(tSlurpEnd - 0.02, tSlurpEnd + 0.22, t) * .pi) * 2.4
        sim.coreX += ((lurkX + inhaleDrawX + chompRecoilX) - sim.coreX) * (1.0 - exp(-dt * 16.0))
        let mochiCrane: CGFloat = (theme == .roundMochi) ? (-2.6 * slurpEnv) : 0.0
        sim.coreY += ((lurkIdleY + mochiCrane) - sim.coreY) * (1.0 - exp(-dt * 15.0))

        if mode == .reject {
            let purse = Self.smootherstep(0.28, 0.48, t)
            let close2 = Self.smootherstep(0.96, 1.28, t)
            let shakeWin = Self.smootherstep(0.24, 0.38, t) * (1.0 - Self.smootherstep(0.72, 0.90, t))

            sim.poseOverride = (close2 > 0.65) ? .auto : .sideEye
            sim.targetMaw = Self.lerp(Self.lerp(startMaw, 0.52, openIn), 0.06, purse) * (1.0 - close2)
            sim.targetSmileCurve = 0
            sim.targetSway = sin(t * 26.0) * 6.2 * shakeWin
            sim.targetGas = 1.0 + 0.03 * shakeWin
            sim.targetSquash = 0
            sim.targetTilt = -0.07 * (1.0 - close2)
            sim.targetLookX = -0.58 * (1.0 - close2)
            sim.targetLookY = 0.28 * (1.0 - close2)
            boxShakeX = sin(t * 48.0) * 2.2 * shakeWin
            return false
        }

        if t >= tApproachEnd && !latchFired {
            latchFired = true
            sim.triggerLatchCatch()
        }

        if chompSnap > 0.52 && !chompFired {
            chompFired = true
            sim.triggerChompImpact()
        }

        let chewWindow = chompSnap * (1.0 - Self.smootherstep(tChewEnd - 0.06, tChewEnd + 0.10, t))
        let postGulp = Self.smootherstep(tChewEnd - 0.02, tChewEnd + 0.14, t)

        if postGulp > 0.55 && !gulpFired {
            gulpFired = true
            sim.triggerSatisfiedGulp()
        }

        // Phase 1 (`0..0.86s`): deep steady inhale while eyes smoothly track the gliding URL tip (`-0.88 -> -0.58`)!
        // Phase 2 (`0.86..1.82s`): 8.2 Hz rhythmic jaw-ratchet nibbling while actively eating inside the mouth!
        let inMouthGate = Self.smootherstep(tApproachEnd - 0.03, tApproachEnd + 0.05, t) * (1.0 - chompSnap)
        let feedPulse = sin(max(0.0, t - tApproachEnd) * 58.0) * 0.075 * inMouthGate
        let chewPhase = max(0.0, (t - tSlurpEnd) / max(0.1, tChewEnd - tSlurpEnd))
        let chewOsc = sin(chewPhase * .pi * 4.0) * chewWindow

        let trackedLookX = Self.lerp(-0.88, -0.58, approachProg)
        let trackedLookY = Self.lerp(0.20, 0.34, approachProg)

        sim.targetMaw = max(0.0, (openIn * 0.96 + feedPulse) * (1.0 - chompSnap))
        sim.targetSmileCurve = postGulp
        sim.targetStuffed = chewWindow * 0.96
        sim.targetSway = (theme == .forestCube ? 0.40 : 1.05) * sin(t * 11.5) * inMouthGate
        sim.targetGas = 1.0 + 0.048 * inhaleBell + 0.036 * inMouthGate + 0.088 * chewWindow
        sim.targetSquash = (-0.042 * inhaleBell) + (-0.030 + feedPulse * 0.58) * inMouthGate + (0.048 + 0.062 * chewOsc) * chewWindow
        sim.targetTilt = -0.045 * inhaleBell - 0.062 * inMouthGate + 0.034 * chewOsc
        sim.targetLookX = trackedLookX * slurpEnv - 0.15 * chewWindow
        sim.targetLookY = trackedLookY * slurpEnv + 0.08 * chewWindow - 0.12 * postGulp
        return false
    }

    package func stepRunnerFrame(
        at timestamp: TimeInterval,
        theme: MascotTheme,
        seamX1: CGFloat,
        seamX2: CGFloat,
        progress: Double?,
        isPaused: Bool,
        isSnapshotMode: Bool
    ) -> MascotRunnerRenderFrame {
        let hasActive = (progress != nil)
        let clampedProg = CGFloat(max(0.0, min(1.0, progress ?? 0.0)))
        let targetX = hasActive
            ? Self.lerp(seamX1 + 14.0, max(seamX1 + 20.0, seamX2 - 14.0), clampedProg)
            : (seamX1 + 16.0)

        if isSnapshotMode {
            return MascotRunnerRenderFrame(
                theme: theme,
                runnerX: targetX,
                hasActiveProgress: hasActive,
                isPaused: isPaused || !hasActive,
                walkPhase: 1.15,
                cheerHop: 0,
                clock: 1.2
            )
        }

        let dt: CGFloat
        if let prev = lastRunnerTimestamp {
            dt = CGFloat(max(0.001, min(0.05, timestamp - prev)))
        } else {
            dt = 1.0 / 60.0
        }
        lastRunnerTimestamp = timestamp
        runnerClock += dt

        if !runnerInitialized {
            runnerInitialized = true
            runnerX = targetX
        } else {
            runnerX += (targetX - runnerX) * (1.0 - exp(-dt * 11.0))
        }

        let effectivelyPaused = isPaused || !hasActive
        if !effectivelyPaused {
            runnerPhase += dt * 11.0
        }
        if runnerCheerTimer > 0 {
            runnerCheerTimer = max(0, runnerCheerTimer - dt)
        }
        let hop = (runnerCheerTimer > 0)
            ? sin((runnerCheerTimer / 0.45) * .pi) * 7.2
            : 0.0

        return MascotRunnerRenderFrame(
            theme: theme,
            runnerX: runnerX,
            hasActiveProgress: hasActive,
            isPaused: effectivelyPaused,
            walkPhase: runnerPhase,
            cheerHop: hop,
            clock: runnerClock
        )
    }

    nonisolated package static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    nonisolated package static func smootherstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0.0, min(1.0, (x - e0) / max(0.0001, e1 - e0)))
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }
}
