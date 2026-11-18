import Foundation
import simd

/// カーソル（先端）を引っぱる点として、体が後ろへついてくる動き（虫・恐竜・乗り物で共通）
struct Follower {
    var head = F2.zero, vel = F2.zero, speed: Float = 0
    var yaw: Float = .pi / 2
    var tail = F2.zero
    let towLen: Float
    var backAccum: Float = 0
    var turning = false
    var yawRate: Float = 0
    var stillTime: Float = 10
    var initialized = false
    var fwd: F2 { F2(cos(yaw), sin(yaw)) }

    init(towLen: Float) { self.towLen = towLen }

    mutating func reset(_ p: F2) {
        head = p
        vel = .zero
        speed = 0
        tail = head - fwd * towLen
        initialized = true
    }

    /// 戻り値：動いた距離（ワープして置き直した時は -1）
    mutating func update(dt: Float, cursor: F2, ptPerMM: Float, turnAround: Bool, turnSpeed: Float = 13) -> Float {
        if !initialized { reset(cursor) }
        let delta = cursor - head
        let moved = simd_length(delta)
        if moved * ptPerMM > 700 { reset(cursor); return -1 }
        head = cursor
        vel = damp2(vel, delta / dt, 28, dt)
        speed = simd_length(vel)
        stillTime = speed > 2.5 ? 0 : stillTime + dt
        let prev = yaw
        var dir = head - tail
        let dl = simd_length(dir)
        dir = dl > 1e-5 ? dir / dl : fwd
        if turnAround {
            if speed > 4 {
                if simd_dot(vel / speed, fwd) < -0.3 { backAccum += moved } else { backAccum = max(0, backAccum - moved * 1.5) }
            } else {
                backAccum = max(0, backAccum - dt * towLen)
            }
            if backAccum > towLen * 0.6 && speed > 4 { turning = true }
        }
        if turning {
            let target = atan2(vel.y, vel.x)
            let diff = wrapPi(target - yaw)
            yaw += clampf(diff, -turnSpeed * dt, turnSpeed * dt)
            tail = head - fwd * towLen
            if abs(diff) < 0.25 || speed < 2 { turning = false; backAccum = 0 }
        } else {
            tail = head - dir * towLen
            yaw = atan2(dir.y, dir.x)
        }
        yawRate = damp(yawRate, wrapPi(yaw - prev) / dt, 20, dt)
        return moved
    }

    mutating func rotate(_ a: Float) { yaw += a; tail = head - fwd * towLen }
}

// MARK: - ティラノサウルス

struct DinoSpec: CreatureDef {
    let shaderID: Int32 = 7
    let name = "ティラノサウルス"
    let basePtPerMM: Float = 1.05
    let bodyZ: Float = 17.0          // 腰の高さ
    let hairSpacing: Float = 0.3
    var bodyLengthMM: Float { 64 }

    // 体の座標：原点＝左右の股関節の真ん中（地面から bodyZ の高さ）、+x が前
    let torso = F3(23, 13.0, 13.0), torsoPos = F3(5.0, 0, 0.8)
    let head = F3(12.5, 9.2, 6.2), headPos = F3(22.0, 0, 5.4)
    let neckBase = F3(14.0, 0, 3.6)
    let jaw = F3(11.5, 7.2, 2.4), jawHinge = F3(-4.6, 0, -1.5)    // 頭の座標
    let hipY: Float = 4.6
    let legSeg: [Float] = [8.6, 9.2, 5.4, 3.4]                     // 大腿, 下腿, 中足, 趾
    let tailSegs = 12, tailLen: Float = 37, tailBase = F3(-4.5, 0, 2.0), tailR: Float = 5.2
    var snout: F3 { headPos + F3(head.x * 0.5, 0, -0.6) }

    static let trex = DinoSpec()

    var meshShapes: [(F3) -> F3] {
        let s = self
        return [{ s.torsoPoint($0) }, { s.headPoint($0) }, { s.jawPoint($0) }]
    }
    func torsoPoint(_ d: F3) -> F3 {
        let a = torso.x / 2, b = torso.y / 2
        let front = sstep(-0.7, 0.5, d.x)
        let bb = b * (0.70 + 0.30 * front)
        let cTop = torso.z * 0.42
        let cBot = torso.z * 0.58 * (0.72 + 0.28 * front)
        var p = superEllipsoid(d, a, bb, cTop, cBot, 2.15)
        // 背骨の盛り上がり
        p.z += 0.5 * exp(-pow(p.y / (b * 0.35), 2)) * (p.z > 0 ? 1 : 0)
        return p
    }
    func headPoint(_ d: F3) -> F3 {
        let a = head.x / 2, b = head.y / 2
        let back = sstep(0.95, -0.35, d.x)                // 後ろが太く、鼻先は丸く幅がある
        let bb = b * (0.60 + 0.40 * back)
        let cTop = head.z * 0.5 * (0.62 + 0.38 * back)
        let cBot = head.z * 0.30
        var p = superEllipsoid(d, a, bb, cTop, cBot, 2.6)
        // 眼の上の隆起
        let brow = exp(-pow((p.x + 1.6) / 1.4, 2)) * exp(-pow((abs(p.y) - bb * 0.62) / 0.9, 2))
        if p.z > 0 { p.z += brow * 0.55 }
        return p
    }
    func jawPoint(_ d: F3) -> F3 {
        let a = jaw.x / 2, b = jaw.y / 2
        let back = sstep(0.9, -0.6, d.x)
        return superEllipsoid(d, a, b * (0.58 + 0.42 * back), jaw.z * 0.38, jaw.z * 0.62, 2.5)
    }

    func makeBristles() -> [Bristle] { [] }
    func layerRadiusMM() -> Float { max(snout.x + 3, -tailBase.x + tailLen + 2) + bodyZ * 0.75 }
    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { DinoSim(spec: self, ptPerMM: ptPerMM, seed: seed) }
}

final class DinoSim: CreatureSim {
    let sp: DinoSpec
    var rng: SplitMix
    var time: Float = 0
    let ptPerMM: Float
    var f: Follower
    var events: [SimEvent] = []

    var bodyXY = F2.zero
    var bodyPos = F3.zero
    var bodyVel = F2.zero
    var bodyRot = matrix_identity_float3x3
    var pitch: Float = 0, roll: Float = 0, zNow: Float = 0, bob: Float = 0

    var leftDown = false
    var press: Float = 0
    var strikeT: Float = 10
    var strikeFired = true
    var webT: Float = 10           // 咆哮
    var webFired = true
    var airborne: Bool { false }
    var stillTime: Float { f.stillTime }
    var activeSilk: (F2, F3)? { nil }

    var headYaw: Float = 0, headPitch: Float = 0, jawOpen: Float = 0
    var lookYaw: Float = 0, lookPitch: Float = 0, lookTimer: Float = 1.5
    var lunge: Float = 0
    var gaitPhase: Float = 0

    struct Foot { var p = F3.zero; var planted = true; var t: Float = 0; var dur: Float = 0.3; var from = F3.zero; var lift: Float = 2; var big = false }
    var feet = [Foot(), Foot()]
    var legJoints: [[F3]] = [[], []]
    var tailYaw: [Float]
    var tailJoints: [F3] = []
    var armJoints: [[F3]] = [[], []]

    init(spec: DinoSpec, ptPerMM: Float, seed: UInt64) {
        sp = spec
        self.ptPerMM = ptPerMM
        rng = SplitMix(seed: seed)
        f = Follower(towLen: 46)
        tailYaw = [Float](repeating: 0, count: spec.tailSegs)
    }

    func mouseDown() { leftDown = true }
    func mouseUp(strike: Bool) {
        leftDown = false
        guard strike else { return }
        strikeT = 0
        strikeFired = false
    }
    func rightClick() { webT = 0; webFired = false }

    @inline(__always) func sideSign(_ i: Int) -> Float { i == 0 ? 1 : -1 }
    func restFoot(_ i: Int) -> F2 { bodyXY + rot2(F2(1.4, sideSign(i) * 5.2), f.yaw) }

    /// 頭（首から先）の体に対するずれ（体の座標）
    func headFrame() -> (center: F3, rot: simd_float3x3) {
        let hr = rotZ(headYaw) * pitchUp(headPitch)
        let c = sp.neckBase + hr * (sp.headPos - sp.neckBase) + F3(lunge * 3.0, 0, 0)
        return (c, hr)
    }

    func reset() {
        for i in 0..<2 {
            let r = restFoot(i)
            feet[i] = Foot(p: F3(r.x, r.y, 0))
        }
        for k in 0..<sp.tailSegs { tailYaw[k] = f.yaw + .pi }
        zNow = sp.bodyZ
    }

    func update(dt rawDt: Float, cursor: F2) {
        let dt = clampf(rawDt, 1.0 / 500, 1.0 / 20)
        time += dt
        let wasInit = f.initialized
        let moved = f.update(dt: dt, cursor: cursor, ptPerMM: ptPerMM, turnAround: true, turnSpeed: 7)
        let speed = f.speed
        let sNorm = sat(speed / 130)

        // ---- 動作 ----
        press = damp(press, leftDown ? 1 : 0, leftDown ? 18 : 12, dt)
        strikeT += dt
        webT += dt
        var jawT: Float = press * 0.55
        var lungeT: Float = 0
        if strikeT < 0.4 {
            let s = strikeT
            if s < 0.06 { lungeT = sstep(0, 1, s / 0.06); jawT = 0.6 * (1 - s / 0.06) } else { lungeT = 1 - sstep(0, 1, (s - 0.06) / 0.3); jawT = 0 }
            if !strikeFired && s >= 0.055 { strikeFired = true; events.append(.bite(f.head, false)) }
        }
        var roar: Float = 0
        if webT < 1.25 {
            roar = sstep(0, 0.12, webT) * (1 - sstep(0.95, 1.25, webT))
            jawT = max(jawT, roar * 0.95)
            if !webFired && webT >= 0.18 {
                webFired = true
                events.append(.roar(f.head, f.fwd, 34))
            }
        }
        jawOpen = damp(jawOpen, jawT, jawT > jawOpen ? 30 : 22, dt)
        lunge = damp(lunge, lungeT, 40, dt)

        // 待機中はあたりを見回す
        lookTimer -= dt
        if lookTimer <= 0 {
            lookTimer = rng.range(1.2, 3.5)
            lookYaw = f.stillTime > 0.5 ? rng.range(-0.35, 0.35) : 0
            lookPitch = rng.range(-0.08, 0.12)
        }
        let moving = speed > 6
        var hyT = (moving ? 0 : lookYaw) + clampf(-f.yawRate * 0.12, -0.3, 0.3)
        var hpT = (moving ? -0.04 : lookPitch) + press * 0.12 + roar * 0.38
        hyT += roar * 0.07 * sin(time * 34)
        hpT -= lunge * 0.10
        headYaw = damp(headYaw, hyT, 6, dt)
        headPitch = damp(headPitch, hpT, 8, dt)

        // ---- 胴体の位置：鼻先がカーソルに来るように ----
        let hf = headFrame()
        let snoutB = hf.center + hf.rot * F3(sp.head.x * 0.5, 0, -0.6) - F3(lunge * 3.0, 0, 0)
        let newXY = f.head - rot2(F2(snoutB.x, snoutB.y), f.yaw)
        if !wasInit || moved < 0 { bodyXY = newXY; reset() }
        bodyVel = damp2(bodyVel, (newXY - bodyXY) / dt, 25, dt)
        bodyXY = newXY

        // ---- 二足歩行 ----
        let settling = f.stillTime > 0.15
        var swinging = -1
        for i in 0..<2 where !feet[i].planted {
            var ft = feet[i]
            ft.t += dt / ft.dur
            let target = stepTarget(i, settling: settling)
            let p = min(ft.t, 1)
            let e = p * p * (3 - 2 * p)
            let xyp = mix2(xy(ft.from), target, e)
            ft.p = F3(xyp.x, xyp.y, ft.lift * sin(.pi * pow(p, 0.8)))
            if ft.t >= 1 {
                ft.planted = true
                ft.p = F3(target.x, target.y, 0)
                if ft.big { events.append(.footprint(target + rot2(F2(-0.8, 0), f.yaw), f.yaw, 7.5, i == 0)) }
            } else { swinging = i }
            feet[i] = ft
        }
        if swinging < 0 {
            var best = -1
            var bestErr: Float = 0
            for i in 0..<2 {
                let err = simd_length(xy(feet[i].p) - restFoot(i))
                let thr: Float = settling ? 0.9 : 3.2 - 1.2 * sNorm
                let far = simd_length(xy(feet[i].p) - bodyXY) > 15
                if (err > thr || far) && err > bestErr { best = i; bestErr = err }
            }
            if best >= 0 {
                var ft = feet[best]
                ft.planted = false
                ft.t = 0
                ft.from = ft.p
                ft.dur = settling ? 0.34 : mixf(0.30, 0.11, sNorm)
                ft.lift = settling ? 1.2 : 2.4 + 2.0 * sNorm
                ft.big = !settling || bestErr > 2.0
                feet[best] = ft
            }
        }
        // 届かないほど置いていかれた足は引きずる（脚が伸びきらないように）
        for i in 0..<2 {
            let hipXY = bodyXY + rot2(F2(0, sideSign(i) * sp.hipY), f.yaw)
            let d = xy(feet[i].p) - hipXY
            let L = simd_length(d)
            if L > 15 {
                let np = hipXY + d / L * 15
                feet[i].p = F3(np.x, np.y, feet[i].p.z)
                if !feet[i].planted { feet[i].from = F3(np.x, np.y, 0) }
            }
        }
        // 片足立ちの間は体が少し持ち上がり、立っている足の側へ傾く
        var bobT: Float = 0
        var rollT: Float = 0
        if swinging >= 0 {
            let p = min(feet[swinging].t, 1)
            bobT = 0.55 * sin(.pi * p)
            rollT = -sideSign(swinging) * 0.05
            gaitPhase += dt / feet[swinging].dur * .pi
        }
        bob = damp(bob, bobT, 14, dt)
        let breathe = sin(time * 2 * .pi * 0.35) * 0.18
        let crouch = press * 0.08 + roar * 0.10 + lunge * 0.04
        zNow = damp(zNow, sp.bodyZ * (1 - crouch), 10, dt)
        let z = zNow + bob + breathe * 0.3
        pitch = damp(pitch, -0.10 * sNorm - lunge * 0.06 + roar * 0.05, 6, dt)
        roll = damp(roll, rollT + clampf(-f.yawRate * speed * 0.0008, -0.08, 0.08), 6, dt)
        bodyRot = rotZ(f.yaw) * pitchUp(pitch) * rollL(roll)
        bodyPos = F3(bodyXY.x, bodyXY.y, z)

        // ---- 脚の形 ----
        let fwd3 = F3(cos(f.yaw), sin(f.yaw), 0)
        for i in 0..<2 {
            let hip = bodyPos + bodyRot * F3(0, sideSign(i) * sp.hipY, -1.2)
            legJoints[i] = DinoSim.bipedLeg(hip: hip, toe: feet[i].p, fwd: fwd3, seg: sp.legSeg)
        }

        // ---- 尾：付け根から先へ遅れてついてくる ----
        let swayAmp: Float = 0.05 + 0.08 * sNorm + (f.stillTime > 1 ? 0.04 : 0)
        let segL = sp.tailLen / Float(sp.tailSegs)
        var p = bodyPos + bodyRot * sp.tailBase
        var joints = [p]
        for k in 0..<sp.tailSegs {
            let kk = Float(k)
            let sway = swayAmp * sin(gaitPhase * 0.5 + time * 0.9 - kk * 0.45) * (0.3 + kk / Float(sp.tailSegs))
            let target = k == 0 ? f.yaw + .pi + sway - roll * 1.5 : tailYaw[k - 1] + sway * 0.35
            let rate: Float = 26 / (1 + kk * 0.28)
            tailYaw[k] += wrapPi(target - tailYaw[k]) * (1 - exp(-rate * dt))
            let r0 = sp.tailR * (1 - kk / Float(sp.tailSegs))
            let el: Float = (k < 3 ? 0.02 : -0.045) + roar * 0.06 - pitch * 0.5
            p += F3(cos(tailYaw[k]) * cos(el), sin(tailYaw[k]) * cos(el), sin(el)) * segL
            p.z = max(p.z, r0 * 0.4 + 0.2)
            joints.append(p)
        }
        tailJoints = joints

        // ---- 小さな前脚 ----
        for k in 0..<2 {
            let s = sideSign(k)
            let wig = 0.25 * sin(time * 2.1 + Float(k) * 2) + press * 0.4
            let sh = bodyPos + bodyRot * F3(11.2, s * 3.4, -2.6)
            let el = sh + bodyRot * F3(0.9, s * 0.5, -1.7 + wig * 0.3)
            let hd = el + bodyRot * F3(1.6, -s * 0.2, -0.2 + wig)
            armJoints[k] = [sh, el, hd]
        }
    }

    func stepTarget(_ i: Int, settling: Bool) -> F2 {
        let r = restFoot(i)
        if settling { return r }
        var lead = bodyVel * (feet[i].dur * 1.0)
        let ll = simd_length(lead)
        if ll > 13 { lead *= 13 / ll }
        return r + lead
    }

    /// 二足の脚：膝は前、かかとは後ろへ折れる。趾は地面に寝る
    static func bipedLeg(hip: F3, toe: F3, fwd: F3, seg: [Float]) -> [F3] {
        let up = F3(0, 0, 1)
        let A = seg[0], B = seg[1], M = seg[2], T = seg[3]
        let toeBase = toe - fwd * T * 0.95 + up * 0.35
        var alpha: Float = 1.05
        var heel = F3.zero
        var L: Float = 0
        for _ in 0..<12 {
            heel = toeBase - fwd * cos(alpha) * M + up * sin(alpha) * M
            L = simd_length(heel - hip)
            if L > (A + B) * 0.985 { alpha -= 0.1; if alpha < 0.15 { break } }
            else if L < abs(A - B) + 0.25 * (A + B) { alpha += 0.1; if alpha > 1.5 { break } }
            else { break }
        }
        heel = toeBase - fwd * cos(alpha) * M + up * sin(alpha) * M
        let w = heel - hip
        L = simd_length(w)
        let e = L > 1e-4 ? w / L : -up
        var bend = fwd - e * simd_dot(fwd, e)
        bend = simd_length(bend) > 1e-4 ? simd_normalize(bend) : fwd
        let knee: F3
        if L >= A + B {
            knee = hip + e * A
        } else {
            let cosA = clampf((A * A + L * L - B * B) / (2 * A * L), -1, 1)
            knee = hip + e * (A * cosA) + bend * (A * sqrt(max(0, 1 - cosA * cosA)))
        }
        return [hip, knee, heel, toeBase, toe]
    }

    // MARK: 描画

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        let R = bodyRot, P = bodyPos
        let breathe = 1 + 0.012 * sin(time * 2 * .pi * 0.35)
        p.blobs.append(blob(0, makeTransform(R, P + R * sp.torsoPos, F3(1, breathe, breathe)), .skin, ext: sp.torso * 0.5, seed: 1))
        let hf = headFrame()
        let headR = R * hf.rot
        let headC = P + R * hf.center
        p.blobs.append(blob(1, makeTransform(headR, headC), .skin, ext: sp.head * 0.5, seed: 2))
        // 下あご：ちょうつがいで開く
        let jr = headR * pitchUp(-jawOpen)
        let hinge = headC + headR * sp.jawHinge
        let jawC = hinge + jr * F3(sp.jaw.x * 0.48, 0, -0.35)
        p.blobs.append(blob(2, makeTransform(jr, jawC), .jaw, ext: sp.jaw * 0.5, seed: 3))
        // 眼
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            p.blobs.append(blob(-1, makeTransform(headR, headC + headR * F3(-2.0, s * 3.05, 1.35), F3(0.7, 0.55, 0.6)), .reptEye, seed: 4, shadow: false))
        }
        // 歯（口を開けると見える）
        for k in 0..<7 {
            let x = 4.6 - Float(k) * 1.0
            let wHalf = sp.head.y * 0.5 * (0.60 + 0.40 * sstep(0.95, -0.35, x / (sp.head.x * 0.5))) * 0.86
            for s in [Float(1), -1] {
                let a = headC + headR * F3(x, s * wHalf, -1.1)
                p.caps.append(capInst(a, a + headR * F3(0.1, -s * 0.1, -0.9), 0.17, 0.02, side: F3(0, 0, 1), part: .tooth, seg: 0, leg: 0, hair: 0, seed: 0))
                let jx = x - 0.4
                let jl = F3(jx - sp.jawHinge.x, s * wHalf * 0.9, 0.2)
                let b = hinge + jr * jl
                p.caps.append(capInst(b, b + jr * F3(0.1, -s * 0.1, 0.75), 0.15, 0.02, side: F3(0, 0, 1), part: .tooth, seg: 0, leg: 0, hair: 0, seed: 0))
            }
        }
        // 首
        let n0 = P + R * F3(9.5, 0, 2.6)
        let n1 = P + R * sp.neckBase
        let n2 = headC + headR * F3(-3.8, 0, -0.2)
        p.chains.append(ChainPose(joints: [n0, n1, n2], radii: [(5.2, 4.6), (4.6, 3.9)], side: F3(0, 0, 1), part: .skin, limb: 20, hair: 0, hairy: false))
        // 尾
        var tr: [(Float, Float)] = []
        for k in 0..<sp.tailSegs {
            let a = sp.tailR * (1 - Float(k) / Float(sp.tailSegs)) + 0.25
            let b = sp.tailR * (1 - Float(k + 1) / Float(sp.tailSegs)) + 0.25
            tr.append((a, b))
        }
        p.chains.append(ChainPose(joints: tailJoints, radii: tr, side: F3(0, 0, 1), part: .skin, limb: 21, hair: 0, hairy: false))
        // 脚
        for i in 0..<2 {
            let j = legJoints[i]
            guard j.count == 5 else { continue }
            p.chains.append(ChainPose(joints: j, radii: [(3.9, 2.4), (2.1, 1.3), (1.05, 0.85), (0.8, 0.34)], side: F3(0, 0, 1), part: .skin, limb: 22 + i, hair: 0, hairy: false))
            // 横の趾と爪
            let fwd3 = F3(cos(f.yaw), sin(f.yaw), 0)
            for s in [Float(-1), 1] {
                let dir = simd_normalize(rotZ(s * 0.42) * fwd3)
                p.caps.append(capInst(j[3], j[3] + dir * 2.6 + F3(0, 0, -0.3), 0.6, 0.28, side: F3(0, 0, 1), part: .skin, seg: 3, leg: 22 + i, hair: 0, seed: 0))
                p.caps.append(capInst(j[3] + dir * 2.6 + F3(0, 0, -0.3), j[3] + dir * 3.3 + F3(0, 0, -0.35), 0.24, 0.05, side: F3(0, 0, 1), part: .claw, seg: 0, leg: 0, hair: 0, seed: 0))
            }
            p.caps.append(capInst(j[4], j[4] + fwd3 * 0.8 + F3(0, 0, -0.05), 0.28, 0.05, side: F3(0, 0, 1), part: .claw, seg: 0, leg: 0, hair: 0, seed: 0))
            p.feet.append(F4(j[4].x, j[4].y, feet[i].planted ? 1 : 0, 2.6))
        }
        for k in 0..<2 where armJoints[k].count == 3 {
            p.chains.append(ChainPose(joints: armJoints[k], radii: [(0.8, 0.6), (0.6, 0.4)], side: F3(0, 0, 1), part: .skin, limb: 24 + k, hair: 0, hairy: false))
            let h = armJoints[k][2]
            p.caps.append(capInst(h, h + R * F3(0.5, 0, -0.5), 0.2, 0.04, side: F3(0, 0, 1), part: .claw, seg: 0, leg: 0, hair: 0, seed: 0))
        }
        let tc = P + R * sp.torsoPos
        let mid = tailJoints.count > 4 ? tailJoints[4] : tc
        p.ell = [F4(tc.x, tc.y, sp.torso.x * 0.55, sp.torso.y * 0.6), F4(f.yaw, max(0, tc.z - 6) / sp.bodyZ, 0.22, 0),
                 F4(mid.x, mid.y, 9, 3.2), F4(f.yaw, max(0, mid.z - 3) / sp.bodyZ, 0.18, 0)]
        return p
    }
}
