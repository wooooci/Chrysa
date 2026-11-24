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
    package var lookVelX: CGFloat = 0
    package var lookVelY: CGFloat = 0
    package var targetLookX: CGFloat = 0
    package var targetLookY: CGFloat = 0
    package var saccadeX: CGFloat = 0
    package var saccadeY: CGFloat = 0
    package var saccadeTimer: CGFloat = 1.3
    package var saccadeTilt: CGFloat = 0
    package var saccadeCuriousTimer: CGFloat = 0

    package var eyeLW: CGFloat = 1.0
    package var eyeLH: CGFloat = 1.0
    package var eyeLTilt: CGFloat = 0.03
    package var eyeLY: CGFloat = 0.0
    package var eyeRW: CGFloat = 1.0
    package var eyeRH: CGFloat = 1.0
    package var eyeRTilt: CGFloat = 0.03
    package var eyeRY: CGFloat = 0.0
    package var eyeLHVel: CGFloat = 0.0
    package var eyeRHVel: CGFloat = 0.0

    // Expressive eyelid channels (0 = wide open, 1 = fully covered) & tilt angle in radians
    package var upperLidL: CGFloat = 0.0
    package var upperLidR: CGFloat = 0.0
    package var upperLidTiltL: CGFloat = 0.0
    package var upperLidTiltR: CGFloat = 0.0
    package var lowerLidL: CGFloat = 0.0
    package var lowerLidR: CGFloat = 0.0

    // Biological asymmetric blink state (applied directly at render time, never swallowed by low-pass filter)
    package var blinkOpen: CGFloat = 1.0
    package var blinkPhase: CGFloat = -1.0
    package var blinkTimer: CGFloat = 0.0
    package var nextBlinkAt: CGFloat = 2.4
    package var pendingDoubleBlink: Bool = false
    package var rngState: UInt64 = 0x5EED_C0DE_91A7_4B21

    package var mawOpen: CGFloat = 0
    package var mawVel: CGFloat = 0
    package var targetMaw: CGFloat = 0

    package var boingY: CGFloat = 0
    package var boingVel: CGFloat = 0
    package var leafSway: CGFloat = 0
    package var leafVel: CGFloat = 0
    package var haloSpin: CGFloat = 0.8
    package var haloSpeedBoost: CGFloat = 0
    package var pawTapPhase: CGFloat = 0
    package var ringLagTilt: CGFloat = 0
    package var ringLagVel: CGFloat = 0

    package var smileCurve: CGFloat = 0
    package var targetSmileCurve: CGFloat = 0
    package var stuffedCheeks: CGFloat = 0
    package var targetStuffed: CGFloat = 0

    // Bespoke Per-Character Expression & Prop Channels (Poke & Long-Idle Theater)
    package var cubeLegRetract: CGFloat = 0
    package var cubeLeafShiver: CGFloat = 0
    package var cubeEmberGlow: CGFloat = 0

    package var mochiPawShy: CGFloat = 0
    package var mochiSleepBubble: CGFloat = 0

    package var grokRingBank: CGFloat = 0
    package var grokRollAngle: CGFloat = 0

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

    private mutating func nextUnitRandom() -> CGFloat {
        rngState &+= 0x9E37_79B9_7F4A_7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z = z ^ (z >> 31)
        return CGFloat(z & 0xFF_FFFF) / CGFloat(0x100_0000)
    }

    package mutating func triggerBlink() {
        guard blinkPhase < 0, activePose != .sleepy else { return }
        blinkPhase = 0.0
        blinkTimer = 0.0
        squashVel += 0.28
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

        // 1. Hold-and-Accent Idle Micro-Saccades (mostly calm fixation, occasional snappy glance + curious beat)
        if saccadeCuriousTimer > 0 {
            saccadeCuriousTimer = max(0, saccadeCuriousTimer - dt)
        }
        if isIdleCalm && poseOverride == .auto {
            saccadeTimer -= dt
            if saccadeTimer <= 0 {
                let roll = nextUnitRandom()
                let hold = 1.45 + nextUnitRandom() * 2.15
                saccadeTimer = hold
                let prevSX = saccadeX
                if roll < 0.24 {
                    // Glance left-down toward the task list
                    saccadeX = -(0.28 + nextUnitRandom() * 0.26)
                    saccadeY = 0.14 + nextUnitRandom() * 0.16
                    saccadeTilt = saccadeX * 0.12
                } else if roll < 0.44 {
                    // Curious upward-right glance with occasional raised brow beat
                    saccadeX = 0.24 + nextUnitRandom() * 0.24
                    saccadeY = -(0.10 + nextUnitRandom() * 0.14)
                    saccadeTilt = saccadeX * 0.14
                    if nextUnitRandom() < 0.45 {
                        saccadeCuriousTimer = 0.72
                    }
                } else if roll < 0.58 {
                    // Subtle upward daydream glance
                    saccadeX = (nextUnitRandom() - 0.5) * 0.30
                    saccadeY = -(0.16 + nextUnitRandom() * 0.14)
                    saccadeTilt = saccadeX * 0.10
                } else {
                    // Return to relaxed forward fixation
                    saccadeX = 0
                    saccadeY = 0
                    saccadeTilt = 0
                }
                // Large gaze jumps naturally trigger an attention-shift blink (~45% chance)
                if abs(saccadeX - prevSX) > 0.34 && nextUnitRandom() < 0.45 {
                    triggerBlink()
                }
            }
        } else {
            let decay = exp(-dt * 10.0)
            saccadeX *= decay
            saccadeY *= decay
            saccadeTilt *= decay
            saccadeCuriousTimer = 0
        }

        let effLookX = max(-1.0, min(1.0, targetLookX + saccadeX))
        let effLookY = max(-1.0, min(1.0, targetLookY + saccadeY))

        smileCurve += (targetSmileCurve - smileCurve) * (1.0 - exp(-dt * 11.5))
        stuffedCheeks += (targetStuffed - stuffedCheeks) * (1.0 - exp(-dt * 9.5))

        var pose = poseOverride
        if pose == .auto {
            if smileCurve > 0.38 {
                pose = .beaming
            } else if mawOpen > 0.36 {
                pose = .focus
            } else if mawOpen > 0.05 || saccadeCuriousTimer > 0.01 {
                pose = .curious
            } else {
                pose = .auto
            }
        }
        let wokeFromSleep = (activePose == .sleepy && pose != .sleepy)
        activePose = pose
        if wokeFromSleep {
            triggerBlink()
        }

        // 2. Biological Asymmetric Blink (55ms fast shut -> 33ms full-closed hold -> 107ms lively open + random double-blink)
        if pose == .sleepy {
            blinkPhase = -1.0
            blinkOpen = 1.0
        } else if blinkPhase >= 0 {
            blinkPhase += dt
            let tClose: CGFloat = 0.055
            let tHoldEnd: CGFloat = 0.088
            let tTotal: CGFloat = 0.195
            if blinkPhase < tClose {
                let u = blinkPhase / tClose
                blinkOpen = 1.0 - u * u
            } else if blinkPhase < tHoldEnd {
                blinkOpen = 0.0
            } else if blinkPhase < tTotal {
                let u = (blinkPhase - tHoldEnd) / (tTotal - tHoldEnd)
                let c1: CGFloat = 1.15
                let c3: CGFloat = c1 + 1.0
                let tm1 = u - 1.0
                blinkOpen = max(0.0, 1.0 + c3 * tm1 * tm1 * tm1 + c1 * tm1 * tm1)
            } else {
                blinkPhase = -1.0
                blinkOpen = 1.0
                if pendingDoubleBlink {
                    pendingDoubleBlink = false
                    nextBlinkAt = 0.085
                } else {
                    pendingDoubleBlink = (nextUnitRandom() < 0.22)
                    nextBlinkAt = 2.1 + nextUnitRandom() * 3.1
                }
            }
        } else {
            blinkOpen = 1.0
            blinkTimer += dt
            if blinkTimer >= nextBlinkAt {
                blinkPhase = 0.0
                blinkTimer = 0.0
                squashVel += 0.28
            }
        }

        // 3. Expressive Eye Geometry + Eyelid Cut Targets (Blink is applied directly at render time!)
        var (tLW, tLH, tLTilt, tLY): (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0, 1.0, 0.0, 0.0)
        var (tRW, tRH, tRTilt, tRY): (CGFloat, CGFloat, CGFloat, CGFloat) = (1.0, 1.0, 0.0, 0.0)
        var (tUpL, tUpR, tUpTiltL, tUpTiltR): (CGFloat, CGFloat, CGFloat, CGFloat) = (0.0, 0.0, 0.0, 0.0)
        let (tLowL, tLowR): (CGFloat, CGFloat) = (0.0, 0.0)

        switch pose {
        case .auto:
            break
        case .curious:
            (tLW, tLH, tLTilt, tLY) = (1.04, 0.90, -0.04, 0.7)
            (tRW, tRH, tRTilt, tRY) = (1.04, 1.14, 0.04, -1.0)
            (tUpL, tUpR, tUpTiltL, tUpTiltR) = (0.22, 0.0, -0.16, 0.0)
        case .sideEye:
            (tLW, tLH, tLTilt, tLY) = (1.14, 0.96, 0.0, 0.4)
            (tRW, tRH, tRTilt, tRY) = (1.06, 1.00, 0.0, -0.2)
            (tUpL, tUpR, tUpTiltL, tUpTiltR) = (0.44, 0.38, -0.06, 0.04)
        case .beaming:
            (tLW, tLH, tLTilt, tLY) = (1.12, 0.92, 0.0, -1.6)
            (tRW, tRH, tRTilt, tRY) = (1.12, 0.92, 0.0, -1.6)
        case .sleepy:
            (tLW, tLH, tLTilt, tLY) = (1.20, 0.34, 0.0, 2.0)
            (tRW, tRH, tRTilt, tRY) = (1.20, 0.34, 0.0, 2.0)
            (tUpL, tUpR, tUpTiltL, tUpTiltR) = (0.48, 0.48, 0.12, -0.12)
        case .focus:
            (tLW, tLH, tLTilt, tLY) = (1.06, 1.00, 0.0, -0.3)
            (tRW, tRH, tRTilt, tRY) = (1.06, 1.00, 0.0, -0.3)
            (tUpL, tUpR, tUpTiltL, tUpTiltR) = (0.18, 0.18, 0.22, -0.22)
        }

        let eyeRate = 1.0 - exp(-dt * 18.0)
        let lidRate = 1.0 - exp(-dt * 20.0)
        eyeLW += (tLW - eyeLW) * eyeRate
        eyeLTilt += (tLTilt - eyeLTilt) * eyeRate
        eyeLY += (tLY - eyeLY) * eyeRate
        eyeRW += (tRW - eyeRW) * eyeRate
        eyeRTilt += (tRTilt - eyeRTilt) * eyeRate
        eyeRY += (tRY - eyeRY) * eyeRate

        upperLidL += (tUpL - upperLidL) * lidRate
        upperLidR += (tUpR - upperLidR) * lidRate
        upperLidTiltL += (tUpTiltL - upperLidTiltL) * lidRate
        upperLidTiltR += (tUpTiltR - upperLidTiltR) * lidRate
        lowerLidL += (tLowL - lowerLidL) * lidRate
        lowerLidR += (tLowR - lowerLidR) * lidRate

        haloSpin += dt * (1.8 + mawOpen * 5.5 + haloSpeedBoost)
        if haloSpeedBoost > 0 {
            haloSpeedBoost = max(0, haloSpeedBoost - dt * 14.0)
        }
        if pawTapPhase > 0 {
            pawTapPhase = max(0, pawTapPhase - dt * 3.2)
        }

        let steps = 4
        let h = dt / CGFloat(steps)
        let poseTiltAdd: CGFloat = (pose == .curious) ? 0.08 : (pose == .sideEye ? -0.07 : 0.0)

        for _ in 0..<steps {
            // Snappy underdamped eye gaze & height springs (eyes arrive first with crisp micro-overshoot!)
            let aLookX = 441.0 * (effLookX - lookX) - 26.04 * lookVelX
            lookVelX += aLookX * h
            lookX = max(-1.12, min(1.12, lookX + lookVelX * h))

            let aLookY = 441.0 * (effLookY - lookY) - 26.04 * lookVelY
            lookVelY += aLookY * h
            lookY = max(-1.05, min(1.05, lookY + lookVelY * h))

            let aEyeLH = 484.0 * (tLH - eyeLH) - 26.40 * eyeLHVel
            eyeLHVel += aEyeLH * h
            eyeLH = max(0.18, min(1.32, eyeLH + eyeLHVel * h))

            let aEyeRH = 484.0 * (tRH - eyeRH) - 26.40 * eyeRHVel
            eyeRHVel += aEyeRH * h
            eyeRH = max(0.18, min(1.32, eyeRH + eyeRHVel * h))

            // Body squash, jaw, volume, and head tilt (slower natural frequency than eyes -> Eye-Lead-Head overlap!)
            let aSq = 400.0 * (targetSquash - squash) - 19.2 * squashVel
            squashVel += aSq * h
            squash = max(-0.24, min(0.26, squash + squashVel * h))

            let aMaw = 484.0 * (targetMaw - mawOpen) - 24.64 * mawVel
            mawVel += aMaw * h
            mawOpen = max(0.0, mawOpen + mawVel * h)

            let aGas = 324.0 * (targetGas - gasScale) - 19.0 * gasVel
            gasVel += aGas * h
            gasScale = max(0.86, min(1.24, gasScale + gasVel * h))

            let effTilt = targetTilt + saccadeTilt + poseTiltAdd
            let aTilt = 256.0 * (effTilt - tiltRad) - 17.28 * tiltVel
            tiltVel += aTilt * h
            tiltRad = max(-0.30, min(0.30, tiltRad + tiltVel * h))

            let aSway = 361.0 * (targetSway - swayShear) - 20.52 * swayVel
            swayVel += aSway * h
            swayShear = max(-12.0, min(12.0, swayShear + swayVel * h))

            let aBoing = 676.0 * (0 - boingY) - 27.04 * boingVel
            boingVel += aBoing * h
            boingY = max(-11.0, min(9.0, boingY + boingVel * h))

            // 3rd-stage secondary follow-through for foliage & orbital ring
            let leafTarget = -velX * 0.015 + swayShear * 0.09 - tiltVel * 0.28 + sin(haloSpin * 1.4) * 0.09
            leafVel += (324.0 * (leafTarget - leafSway) - 12.24 * leafVel) * h
            leafSway = max(-0.62, min(0.62, leafSway + leafVel * h))

            let ringTarget = tiltRad * 0.92 - lookX * 0.10 + grokRingBank
            ringLagVel += (169.0 * (ringTarget - ringLagTilt) - 11.44 * ringLagVel) * h
            ringLagTilt = max(-0.85, min(0.85, ringLagTilt + ringLagVel * h))

            // Couple boing & head-tilt whip directly into the 8-knot jelly inertia mesh!
            let effAccX = max(-2200, min(2200, accelX + aTilt * 46.0))
            let effAccY = max(-2400, min(2400, accelY + aBoing * 14.0))
            for i in 0..<8 {
                let tx = max(-5.5, min(5.5, -effAccX * 0.0032 * knots[i].lagGain))
                let ty = max(-5.5, min(5.5, -effAccY * 0.0032 * knots[i].lagGain))
                let w2 = knots[i].omega * knots[i].omega
                let damp = 2.0 * knots[i].zeta * knots[i].omega
                knots[i].vx += (w2 * (tx - knots[i].x) - damp * knots[i].vx) * h
                knots[i].vy += (w2 * (ty - knots[i].y) - damp * knots[i].vy) * h
                knots[i].x = max(-6.5, min(6.5, knots[i].x + knots[i].vx * h))
                knots[i].y = max(-6.5, min(6.5, knots[i].y + knots[i].vy * h))
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
    package var activeBlend: CGFloat
    package var walkPhase: CGFloat
    package var cheerHop: CGFloat
    package var cheerProgress: CGFloat
    package var cheerSquash: CGFloat
    package var clock: CGFloat
}

@MainActor
package final class MascotController {
    nonisolated package static let uiMascotScale: CGFloat = 0.36
    nonisolated package static let uiRunnerScale: CGFloat = 0.38
    nonisolated package static let maxSiphonCharacters: Int = 28
    nonisolated package static let pokeDuration: CGFloat = 1.12
    nonisolated package static let cheerDuration: CGFloat = 0.76

    package private(set) var sim = MascotSimState()
    package private(set) var mode: MascotIntakeKind = .idle
    package private(set) var animT: CGFloat = 0
    package private(set) var elapsed: CGFloat = 0
    package private(set) var activeSiphonText: String = ""
    package private(set) var pokeTimer: CGFloat = 0
    package private(set) var idleCalmTime: CGFloat = 0
    package private(set) var idleTheaterForced = false

    private var lastTopTimestamp: TimeInterval?
    private var cachedTopFrame: MascotTopRenderFrame?
    private var lastRunnerTimestamp: TimeInterval?
    private var cachedRunnerFrame: MascotRunnerRenderFrame?
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
    private var pointerInside = false
    private var pointerIdleAge: CGFloat = 99
    private var pointerWeight: CGFloat = 0

    private var runnerX: CGFloat = 24
    private var runnerInitialized = false
    private var runnerPhase: CGFloat = 0
    private var runnerActiveBlend: CGFloat = 0
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
        mode != .idle
            || pokeTimer > 0
            || isDropHovering
            || afterglowTimer > 0.01
            || abs(sim.boingY) > 0.25
            || sim.pawTapPhase > 0.01
    }

    package var isActivelyAnimatingRunner: Bool {
        runnerCheerTimer > 0.005
    }

    private func resetBespokeChannelsOnThemeSwitch() {
        pokeTimer = 0
        idleCalmTime = 0
        idleTheaterForced = false
        sim.cubeLegRetract = 0
        sim.cubeLeafShiver = 0
        sim.cubeEmberGlow = 0
        sim.mochiPawShy = 0
        sim.mochiSleepBubble = 0
        sim.grokRingBank = 0
        sim.grokRollAngle = 0
        sim.poseOverride = .auto
    }

    private func decayBespokeChannels(dt: CGFloat, preserveSleep: Bool) {
        let fast = 1.0 - exp(-dt * 12.0)
        sim.cubeLeafShiver += (0 - sim.cubeLeafShiver) * fast
        sim.mochiPawShy += (0 - sim.mochiPawShy) * fast
        sim.grokRingBank += (0 - sim.grokRingBank) * fast
        sim.grokRollAngle = 0
        if !preserveSleep {
            sim.cubeLegRetract += (0 - sim.cubeLegRetract) * fast
            sim.cubeEmberGlow += (0 - sim.cubeEmberGlow) * fast
            sim.mochiSleepBubble += (0 - sim.mochiSleepBubble) * fast
        }
    }

    package func notifyThemeChanged(_ newTheme: MascotTheme) {
        guard newTheme != lastTheme else { return }
        lastTheme = newTheme
        resetBespokeChannelsOnThemeSwitch()
        sim.coreY = Self.restAnchorY(for: newTheme)
        if newTheme.isEnabled {
            sim.triggerZCodeBoing()
        }
    }

    /// Fires the bespoke per-character Poke reaction (`1: Hermit Leg-Tuck | 2: Shy Cheek-Paws | 3: Zero-G 360° Roll`)!
    package func triggerBoing() {
        idleCalmTime = 0
        idleTheaterForced = false
        guard mode == .idle else {
            sim.triggerZCodeBoing()
            return
        }
        pokeTimer = 0.0001
        switch lastTheme {
        case .forestCube:
            sim.boingVel = 24.0
            sim.squashVel = 1.3
        case .roundMochi:
            sim.boingVel = 34.0
            sim.squashVel = 2.6
        case .grokAstral:
            sim.boingVel = -36.0
        case .none:
            break
        }
    }

    /// Fires the bespoke per-character Bottom Runner Completion Celebration!
    package func triggerCheerHop() {
        idleCalmTime = 0
        runnerCheerTimer = Self.cheerDuration
        afterglowTimer = max(afterglowTimer, 0.65)
        sim.triggerSatisfiedGulp()
    }

    package func setIdleTheaterPreview(_ active: Bool) {
        mode = .idle
        pokeTimer = 0
        idleTheaterForced = active
        idleCalmTime = active ? 10.0 : 0.0
    }

    package func setDropHovering(_ hovering: Bool) {
        if hovering {
            idleCalmTime = 0
        }
        isDropHovering = hovering
    }

    package func updatePointer(x: CGFloat, y: CGFloat) {
        let moved = hypot(x - pointerX, y - pointerY)
        let firstEntry = !pointerInside
        pointerX = x
        pointerY = y
        pointerInside = true
        if firstEntry || moved > 2.0 {
            pointerIdleAge = 0
        }
        if moved > 3.5 && !idleTheaterForced {
            idleCalmTime = 0
        }
    }

    package func clearPointer() {
        pointerInside = false
        pointerIdleAge = 99
    }

    package func triggerIntake(kind: MascotIntakeKind, rawText: String = "") {
        guard kind != .idle else { return }
        mode = kind
        animT = 0
        pokeTimer = 0
        idleCalmTime = 0
        idleTheaterForced = false
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
        isSnapshotMode: Bool,
        isWorking: Bool = false
    ) -> MascotTopRenderFrame {
        let clampedW = max(240, width)
        barWidth = clampedW
        let lurkX = clampedW - 96.0
        let lurkIdleY = Self.restAnchorY(for: theme, boxTopY: boxTopY)

        if lastTheme != theme {
            lastTheme = theme
            resetBespokeChannelsOnThemeSwitch()
            sim.coreX = lurkX
            sim.coreY = lurkIdleY
        }

        if isSnapshotMode {
            if (mode != .idle || pokeTimer > 0 || idleTheaterForced || idleCalmTime > 6.5),
               let cached = cachedTopFrame,
               cached.theme == theme {
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
            isTypingURL: isTypingURL,
            isWorking: isWorking
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
        isTypingURL: Bool,
        isWorking: Bool
    ) -> Bool {
        // Mascot ALWAYS stays cozily perched at `lurkX` (zero sideways or aerial jumping!).
        // Round Mochi ALWAYS stays behind the bar (`isFrontLayer = false`) with its paws over the front border!
        isFrontLayer = (theme != .roundMochi)

        if pointerInside {
            pointerIdleAge = min(10.0, pointerIdleAge + dt)
        } else {
            pointerIdleAge = 99.0
        }
        let wantPointer: CGFloat = (pointerInside && pointerIdleAge < 2.2) ? 1.0 : 0.0
        let ptrRate = 1.0 - exp(-dt * (wantPointer > pointerWeight ? 12.0 : 4.5))
        pointerWeight += (wantPointer - pointerWeight) * ptrRate

        let wantHover = isDropHovering || isTypingURL
        if wantHover && !idleTheaterForced {
            idleCalmTime = 0
        }
        let targetProx: CGFloat = wantHover ? 1.0 : 0.0
        dropProximity += (targetProx - dropProximity) * (1.0 - exp(-dt * 10.0))

        // 1. Bespoke Left-Click Poke Reaction (`1.12s`)
        if mode == .idle && pokeTimer > 0 {
            pokeTimer += dt
            if pokeTimer >= Self.pokeDuration {
                pokeTimer = 0
                sim.poseOverride = .auto
                decayBespokeChannels(dt: dt, preserveSleep: false)
            } else {
                let p = max(0.0, min(1.0, pokeTimer / Self.pokeDuration))
                let posRate = 1.0 - exp(-dt * 14.0)
                sim.coreX += (lurkX - sim.coreX) * posRate
                sim.targetMaw = 0

                switch theme {
                case .forestCube:
                    let tuck = Self.smootherstep(0.0, 0.11, p) * (1.0 - Self.smootherstep(0.68, 0.98, p))
                    sim.cubeLegRetract = tuck
                    sim.cubeLeafShiver = sin(p * 62.0) * (1.0 - p) * 1.15
                    sim.cubeEmberGlow = tuck * 0.65
                    sim.coreY += (lurkIdleY - sim.coreY) * posRate
                    sim.poseOverride = (p < 0.24) ? .sleepy : .curious
                    sim.targetSquash = 0.10 * tuck
                    sim.targetGas = 1.0 - 0.02 * tuck
                    sim.targetTilt = sin(p * 26.0) * 0.075 * (1.0 - p)
                    sim.targetSway = 0
                    sim.targetSmileCurve = 0
                    sim.targetStuffed = 0
                    sim.targetLookX = -0.36
                    sim.targetLookY = -0.22

                case .roundMochi:
                    let shy = Self.smootherstep(0.04, 0.20, p) * (1.0 - Self.smootherstep(0.70, 0.98, p))
                    sim.mochiPawShy = shy
                    sim.mochiSleepBubble = 0
                    sim.coreY += ((lurkIdleY + 2.0 * shy) - sim.coreY) * posRate
                    sim.poseOverride = .beaming
                    sim.targetSmileCurve = shy
                    sim.targetStuffed = shy * 0.92
                    sim.targetSquash = 0.19 * shy
                    sim.targetGas = 1.0 + 0.065 * shy
                    sim.targetTilt = sin(p * 18.0) * 0.075 * shy
                    sim.targetSway = sin(p * 22.0) * 2.2 * (1.0 - p)
                    sim.targetLookX = 0
                    sim.targetLookY = 0

                case .grokAstral:
                    // Anticipation wind-up -> crisp 360° barrel roll -> damped rotational overshoot & soft landing!
                    let windUp = -sin(Self.smootherstep(0.0, 0.12, p) * .pi) * 0.22
                    let spinCore = Self.smootherstep(0.08, 0.82, p)
                    let settleOvershoot = sin(Self.smootherstep(0.74, 0.98, p) * .pi) * 0.24
                    sim.grokRollAngle = windUp + (spinCore * .pi * 2.0) + settleOvershoot
                    sim.grokRingBank = sin(p * .pi * 4.0) * 0.46 * (1.0 - p)
                    sim.haloSpeedBoost = 10.5 * (1.0 - p)
                    let crouch = sin(Self.smootherstep(0.0, 0.12, p) * .pi) * 1.4
                    let lift = -sin(Self.smootherstep(0.08, 0.88, p) * .pi) * 3.8
                    sim.coreY += ((lurkIdleY + crouch + lift) - sim.coreY) * posRate
                    sim.poseOverride = (p > 0.55) ? .beaming : .auto
                    sim.targetSmileCurve = Self.smootherstep(0.50, 0.78, p) * (1.0 - Self.smootherstep(0.86, 1.0, p))
                    let spinStretch = -sin(Self.smootherstep(0.08, 0.78, p) * .pi) * 0.09
                    let landSquish = sin(Self.smootherstep(0.76, 0.98, p) * .pi) * 0.11
                    sim.targetSquash = sin(Self.smootherstep(0.0, 0.12, p) * .pi) * 0.09 + spinStretch + landSquish
                    sim.targetGas = 1.0 + 0.04 * sin(p * .pi)
                    sim.targetTilt = 0
                    sim.targetSway = 0
                    sim.targetStuffed = 0
                    sim.targetLookX = 0
                    sim.targetLookY = 0

                case .none:
                    break
                }
                return false
            }
        }

        // 2. Idle & Bespoke Long-Idle Mini-Theater
        if mode == .idle {
            let posRate = 1.0 - exp(-dt * 10.0)
            sim.coreX += (lurkX - sim.coreX) * posRate

            if dropProximity > 0.04 {
                decayBespokeChannels(dt: dt, preserveSleep: false)
                sim.poseOverride = .auto
                let perkLift: CGFloat = (theme == .roundMochi) ? -1.8 : -1.2
                sim.coreY += ((lurkIdleY + perkLift * dropProximity) - sim.coreY) * posRate

                let hoverGate = Self.smootherstep(0.02, 0.35, dropProximity)
                sim.targetMaw = (isDropHovering ? 0.34 : 0.16) * hoverGate
                sim.targetSmileCurve = 0
                sim.targetGas = 1.0 + 0.03 * dropProximity
                sim.targetSquash = -0.032 * dropProximity
                sim.targetTilt = -0.085 * hoverGate
                sim.targetSway = (-1.4 + sin(elapsed * 4.2) * 0.9) * hoverGate
                sim.targetLookX = -0.58
                sim.targetLookY = 0.28
                sim.targetStuffed = 0
                return false
            }

            var fade: CGFloat = 0
            if afterglowTimer > 0 {
                afterglowTimer = max(0, afterglowTimer - dt)
                fade = Self.smootherstep(0.0, 0.55, afterglowTimer)
            } else if isWorking && !idleTheaterForced {
                // Stay alert while background jobs are running instead of nodding off
                idleCalmTime = max(0, idleCalmTime - dt * 2.0)
            } else {
                idleCalmTime += dt
            }

            let theater: CGFloat = idleTheaterForced
                ? 1.0
                : Self.smootherstep(6.5, 8.0, idleCalmTime) * (1.0 - fade)
            decayBespokeChannels(dt: dt, preserveSleep: theater > 0.01)

            if theater > 0.02 {
                switch theme {
                case .forestCube:
                    sim.cubeLegRetract += (0.60 * theater - sim.cubeLegRetract) * posRate
                    sim.cubeEmberGlow = (0.42 + 0.58 * (0.5 + 0.5 * sin(elapsed * 2.2))) * theater
                    sim.poseOverride = (theater > 0.45) ? .sleepy : .auto
                    sim.coreY += ((lurkIdleY + sin(elapsed * 1.4) * 0.55) - sim.coreY) * (1.0 - exp(-dt * 8.0))
                    sim.targetMaw = 0
                    sim.targetSmileCurve = 0
                    sim.targetGas = 1.0 + sin(elapsed * 1.4) * 0.022 * theater
                    sim.targetSquash = (0.045 + cos(elapsed * 1.4) * 0.018) * theater
                    sim.targetTilt = 0.055 * theater
                    sim.targetSway = 0
                    sim.targetStuffed = 0
                    sim.targetLookX = 0
                    sim.targetLookY = 0.15
                    return false

                case .roundMochi:
                    sim.mochiSleepBubble = theater
                    sim.poseOverride = (theater > 0.45) ? .sleepy : .auto
                    let sleepBreath = sin(elapsed * 1.6) * 0.75
                    sim.coreY += ((lurkIdleY + 2.1 * theater + sleepBreath * 0.5) - sim.coreY) * (1.0 - exp(-dt * 8.0))
                    sim.targetMaw = 0
                    sim.targetSmileCurve = 0
                    sim.targetGas = 1.0 + sin(elapsed * 1.6) * 0.032 * theater
                    sim.targetSquash = (0.075 + cos(elapsed * 1.6) * 0.028) * theater
                    sim.targetTilt = 0.045 * theater
                    sim.targetSway = 0
                    sim.targetStuffed = 0.25 * theater
                    sim.targetLookX = 0
                    sim.targetLookY = 0.20
                    return false

                case .grokAstral:
                    sim.poseOverride = .auto
                    let mAng = sim.haloSpin * 0.95
                    let moonLookX = cos(mAng) * 0.84
                    let moonLookY = sin(mAng) * 0.38 + 0.06
                    sim.coreY += ((lurkIdleY + sin(elapsed * 1.7) * 0.95) - sim.coreY) * (1.0 - exp(-dt * 8.0))
                    sim.targetMaw = 0
                    sim.targetSmileCurve = 0
                    sim.targetGas = 1.0 + sin(elapsed * 1.7) * 0.014
                    sim.targetSquash = cos(elapsed * 1.7) * 0.018
                    sim.targetTilt = cos(mAng) * 0.11 * theater
                    sim.targetSway = cos(mAng) * 1.4 * theater
                    sim.targetStuffed = 0
                    sim.targetLookX = moonLookX * theater
                    sim.targetLookY = moonLookY * theater
                    return false

                case .none:
                    break
                }
            }

            sim.poseOverride = .auto
            let breathPhase = elapsed * (isWorking ? 2.6 : 2.05)
            let breath = sin(breathPhase) * (isWorking ? 0.95 : 0.82)
            let workPerk: CGFloat = isWorking ? -0.6 : 0.0
            sim.coreY += ((lurkIdleY + workPerk + breath) - sim.coreY) * (1.0 - exp(-dt * 8.0))
            sim.targetMaw = 0
            sim.targetSmileCurve = fade
            sim.targetGas = 1.0 + sin(breathPhase) * 0.016 * (1.0 - fade)
            // 90° phase-shifted breathing squash (slight vertical stretch rising, soft settle at bottom)
            sim.targetSquash = cos(breathPhase) * 0.028 * (1.0 - fade)
            sim.targetStuffed = 0

            let rawPtrX = max(-0.88, min(0.88, (pointerX - sim.coreX) / 170.0))
            let rawPtrY = max(-0.75, min(0.75, (pointerY - sim.coreY) / 145.0))
            let workLookX: CGFloat = isWorking ? (-0.28 + sin(elapsed * 0.85) * 0.18) : 0.0
            let workLookY: CGFloat = isWorking ? 0.24 : 0.0
            let baseLookX = Self.lerp(workLookX, rawPtrX, pointerWeight)
            let baseLookY = Self.lerp(workLookY, rawPtrY, pointerWeight)
            sim.targetLookX = baseLookX * (1.0 - 0.5 * fade)
            sim.targetLookY = baseLookY * (1.0 - 0.5 * fade)

            // Eye-Lead-Head overlap: body tilts & leans slightly behind the eye gaze spring!
            let gazeDriveX = sim.lookX * (1.0 - 0.5 * fade)
            sim.targetTilt = gazeDriveX * 0.115
            sim.targetSway = gazeDriveX * 2.1
            return fade <= 0.2 && pointerWeight < 0.35 && !isWorking
        }

        // 3. Unified Stationary S-Arch URL Intake / Reject Choreography (`2.08s`)
        decayBespokeChannels(dt: dt, preserveSleep: false)

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
            // Brief 110ms surprised beat (Hit-stop) -> crisp skeptical side-eye head shake!
            let surpriseBeat = 1.0 - Self.smootherstep(0.08, 0.15, t)
            let purse = Self.smootherstep(0.28, 0.48, t)
            let close2 = Self.smootherstep(0.96, 1.28, t)
            let shakeWin = Self.smootherstep(0.24, 0.38, t) * (1.0 - Self.smootherstep(0.72, 0.90, t))

            sim.poseOverride = (t < 0.11) ? .curious : ((close2 > 0.65) ? .auto : .sideEye)
            sim.targetMaw = Self.lerp(Self.lerp(startMaw, 0.52, openIn), 0.06, purse) * (1.0 - close2)
            sim.targetSmileCurve = 0
            sim.targetSway = sin(t * 26.0) * 6.2 * shakeWin
            sim.targetGas = 1.0 + 0.035 * shakeWin
            sim.targetSquash = -0.07 * surpriseBeat + 0.04 * shakeWin
            sim.targetTilt = (-0.10 + sin(t * 26.0) * 0.08 * shakeWin) * (1.0 - close2)
            sim.targetLookX = -0.62 * (1.0 - close2)
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

        let inMouthGate = Self.smootherstep(tApproachEnd - 0.03, tApproachEnd + 0.05, t) * (1.0 - chompSnap)
        let feedPulse = sin(max(0.0, t - tApproachEnd) * 58.0) * 0.075 * inMouthGate
        let chewPhase = max(0.0, (t - tSlurpEnd) / max(0.1, tChewEnd - tSlurpEnd))
        let chewOsc = sin(chewPhase * .pi * 4.0) * chewWindow

        let trackedLookX = Self.lerp(-0.88, -0.58, approachProg)
        let trackedLookY = Self.lerp(0.20, 0.34, approachProg)

        sim.targetMaw = max(0.0, (openIn * 0.96 + feedPulse) * (1.0 - chompSnap))
        sim.targetSmileCurve = postGulp
        sim.targetStuffed = chewWindow * 0.96
        sim.targetSway = (theme == .forestCube ? 0.55 : 1.35) * sin(t * 11.5) * inMouthGate
        sim.targetGas = 1.0 + 0.055 * inhaleBell + 0.042 * inMouthGate + 0.095 * chewWindow
        sim.targetSquash = (-0.062 * inhaleBell) + (-0.042 + feedPulse * 0.65) * inMouthGate + (0.065 + 0.085 * chewOsc) * chewWindow
        sim.targetTilt = -0.075 * inhaleBell - 0.095 * inMouthGate + 0.055 * chewOsc
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
        if isSnapshotMode {
            if runnerCheerTimer > 0.005, let cached = cachedRunnerFrame, cached.theme == theme {
                return cached
            }
            let hasActive = (progress != nil)
            let pausedFlag = isPaused || !hasActive
            let clampedProg = CGFloat(max(0.0, min(1.0, progress ?? 0.0)))
            let snapTargetX = hasActive
                ? Self.lerp(seamX1 + 14.0, max(seamX1 + 20.0, seamX2 - 14.0), clampedProg)
                : (seamX1 + 16.0)
            return MascotRunnerRenderFrame(
                theme: theme,
                runnerX: snapTargetX,
                hasActiveProgress: hasActive,
                isPaused: pausedFlag,
                activeBlend: pausedFlag ? 0.0 : 1.0,
                walkPhase: 1.15,
                cheerHop: 0,
                cheerProgress: 0,
                cheerSquash: 0,
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

        var cheerProg: CGFloat = 0.0
        if runnerCheerTimer > 0 {
            runnerCheerTimer = max(0, runnerCheerTimer - dt)
            cheerProg = max(0.001, min(1.0, 1.0 - runnerCheerTimer / Self.cheerDuration))
        }
        let isCheering = (runnerCheerTimer > 0)

        // When a job finishes (`progress == nil` while `isCheering`), hold at 100% finish line for the full celebration!
        let hasActive = (progress != nil) || isCheering
        let clampedProg: CGFloat
        if let progress {
            clampedProg = CGFloat(max(0.0, min(1.0, progress)))
        } else if isCheering {
            clampedProg = 1.0
        } else {
            clampedProg = 0.0
        }

        let targetX = hasActive
            ? Self.lerp(seamX1 + 14.0, max(seamX1 + 20.0, seamX2 - 14.0), clampedProg)
            : (seamX1 + 16.0)

        let effectivelyPaused = (isPaused || progress == nil) && !isCheering
        let targetActiveBlend: CGFloat = effectivelyPaused ? 0.0 : 1.0

        if !runnerInitialized {
            runnerInitialized = true
            runnerX = targetX
            runnerActiveBlend = targetActiveBlend
        } else {
            runnerX += (targetX - runnerX) * (1.0 - exp(-dt * 11.0))
            runnerActiveBlend += (targetActiveBlend - runnerActiveBlend) * (1.0 - exp(-dt * 12.0))
        }

        if runnerActiveBlend > 0.02 {
            runnerPhase += dt * (11.0 * runnerActiveBlend)
        }

        let hopMax: CGFloat = switch theme {
        case .forestCube: 9.8
        case .roundMochi: 13.4
        case .grokAstral: 11.2
        case .none:       7.2
        }

        // Cheer choreography with takeoff crouch anticipation (0..0.11), airborne arc (0.11..0.84), and landing squash (0.84..1.0)!
        var hop: CGFloat = 0.0
        var cheerSquash: CGFloat = 0.0
        if isCheering {
            if cheerProg < 0.11 {
                let u = cheerProg / 0.11
                cheerSquash = sin(u * .pi) * 0.16
            } else if cheerProg < 0.84 {
                let u = (cheerProg - 0.11) / 0.73
                hop = sin(u * .pi) * hopMax
                cheerSquash = -sin(u * .pi) * 0.10
            } else {
                let u = (cheerProg - 0.84) / 0.16
                cheerSquash = sin(u * .pi) * 0.22
            }
        }

        let built = MascotRunnerRenderFrame(
            theme: theme,
            runnerX: runnerX,
            hasActiveProgress: hasActive,
            isPaused: effectivelyPaused,
            activeBlend: runnerActiveBlend,
            walkPhase: runnerPhase,
            cheerHop: hop,
            cheerProgress: cheerProg,
            cheerSquash: cheerSquash,
            clock: runnerClock
        )
        cachedRunnerFrame = built
        return built
    }

    nonisolated package static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    nonisolated package static func smootherstep(_ e0: CGFloat, _ e1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0.0, min(1.0, (x - e0) / max(0.0001, e1 - e0)))
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }
}
