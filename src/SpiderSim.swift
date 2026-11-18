import Foundation
import simd

/// シミュレーションから画面側へ渡すできごと（座標はワールド mm）
enum SimEvent {
    case bite(F2, Bool)         // 左クリック: 噛みついた点（しずくを残すか）
    case web(F2)                // 右クリック: 糸を張った点
    case spray(F2, F2)          // 右クリック（アリ）: 蟻酸を吹きかける（点, 向き）
    case silkDone(F2, F2)       // 牽引糸が切れて残る（始点, 終点）
    case footprint(F2, Float, Float, Bool)   // 恐竜の足あと（位置, 向き, 大きさ mm, 左足か）
    case track(F2, Float, Float)             // 戦車のキャタピラ跡（中心, 向き, 車幅 mm）
    case shot(F2, F2, Bool)                  // 砲撃（着弾点, 向き, 主砲か機銃か）
    case downwash(F2, Float)                 // ドローンの吹きおろし（点, 大きさ mm）
    case beam(F2, Float)                     // UFO の牽引ビーム（点, 大きさ mm）
    case roar(F2, F2, Float)                 // 恐竜の咆哮（口の位置, 向き, 大きさ mm）
    case warp(F2, Float)                     // UFO のワープ（点, 大きさ mm）
}

struct LegState {
    var foot = F3.zero          // 地面上の足（接地中 or 振り出し中）
    var planted = true
    var t: Float = 0
    var dur: Float = 0.1
    var from = F3.zero
    var lift: Float = 0.3
    var joints = [F3](repeating: .zero, count: 8)
    var side = F3(0, 1, 0)
    var contact: Float = 1
    var idleOffset = F2.zero
}

final class SpiderSim: CreatureSim {
    let sp: Species
    var rng: SplitMix
    var time: Float = 0
    var ptPerMM: Float

    // カーソル（＝牙の先）
    var head = F2.zero
    var headVel = F2.zero
    var speed: Float = 0
    var yaw: Float = .pi / 2
    var tail = F2.zero
    let towLen: Float
    let headToBody: Float
    var backAccum: Float = 0
    var turning = false
    var yawRate: Float = 0
    var stillTime: Float = 10
    var initialized = false

    // 胴体
    var bodyXY = F2.zero
    var bodyPos = F3.zero
    var bodyVel = F2.zero
    var bodyAcc = F2.zero
    var bodyRot = matrix_identity_float3x3
    var pitch: Float = 0, roll: Float = 0, zNow: Float = 0
    var bob: Float = 0
    var abdYaw: Float = 0, abdPitch: Float = 0
    var lunge: Float = 0

    // 動作
    var leftDown = false
    var press: Float = 0
    var strikeT: Float = 10
    var strikeFired = true
    var strikePlanted = true
    var webT: Float = 10
    var webFired = true
    var airborne = false
    var hopPhase: Float = 0
    var hopLen: Float = 10
    var hopH: Float = 0
    var hopZ: Float = 0
    var airW: Float = 0
    var fastTimer: Float = 0, slowTimer: Float = 0
    var landSquash: Float = 0

    // 待機中のしぐさ
    var idleTimer: Float = 1.2
    var idleKind = -1
    var idleT: Float = 0
    var idleDur: Float = 0
    var idleSide = 0
    var twitchLeft: Float = 0
    var twitchRate: Float = 0
    var rest: Float = 0
    var palpBoost: Float = 0
    var palpPhase: [Float] = [0, 1.7]

    // 糸
    var pressPoint = F2.zero
    var pressAnchor = F2.zero
    var silkAnchor: F2? = nil
    var silkFromJump = false
    var events: [SimEvent] = []

    var legs: [LegState]
    var palpJoints: [[F3]] = [[F3](repeating: .zero, count: 8), [F3](repeating: .zero, count: 8)]
    var palpSide: [F3] = [F3(0, 1, 0), F3(0, -1, 0)]

    // 描画用の出力
    var carapaceM = matrix_identity_float4x4
    var abdomenM = matrix_identity_float4x4
    var abdomenRot = matrix_identity_float3x3
    var abdomenCenter = F3.zero
    var cheliceraM = [matrix_identity_float4x4, matrix_identity_float4x4]
    var fangs: [(F3, F3)] = [(.zero, .zero), (.zero, .zero)]
    var spinneret = F3.zero
    var pedicel: (F3, F3) = (.zero, .zero)
    var chelOpen: Float = 0

    init(species: Species, ptPerMM: Float, seed: UInt64 = 20251017) {
        sp = species
        self.ptPerMM = ptPerMM
        rng = SplitMix(seed: seed)
        towLen = species.bodyLength * 0.95
        headToBody = species.carapace.x * 0.5 + species.chelicera.z * 0.55
        legs = [LegState](repeating: LegState(), count: 8)
        // 眼：頭胸部の表面に半分埋め込む
        for e in species.eyes {
            for side in [Float(1), -1] {
                let d = F3(e.dir.x, e.dir.y * side, e.dir.z)
                let m = surfaceAttach({ species.carapacePoint($0) }, dir: d, radius: e.radius, inset: e.kind == 0 ? 0.32 : 0.62)
                eyeLocal.append((m, e.kind == 0 ? .eyeBig : .eye))
            }
        }
    }
    private var eyeLocal: [(simd_float4x4, Part)] = []

    // MARK: 描画用の姿勢

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        p.blobs.append(blob(0, carapaceM, .cara, hair: sp.hairBody, ext: F3(sp.carapace.x / 2, sp.carapace.y / 2, sp.carapace.z), seed: 1, shells: true))
        p.blobs.append(blob(1, abdomenM, .abdo, hair: sp.hairBody * 1.1, ext: F3(sp.abdomen.x / 2, sp.abdomen.y / 2, sp.abdomen.z / 2), seed: 2, shells: true))
        for k in 0..<2 { p.blobs.append(blob(-1, cheliceraM[k], .chel, seed: 3 + Float(k))) }
        for (m, part) in eyeLocal { p.blobs.append(blob(-1, carapaceM * m, part, seed: 5, shadow: false)) }
        for i in 0..<8 {
            let r = sp.legs[i / 2].radius
            p.chains.append(ChainPose(joints: legs[i].joints, radii: Species.legRadiusProfile.map { ($0.0 * r, $0.1 * r) },
                                      side: legs[i].side, part: .leg, limb: i, hair: sp.hairLeg, hairy: true))
        }
        for k in 0..<2 {
            let r = sp.palpRadius
            p.chains.append(ChainPose(joints: palpJoints[k], radii: Species.palpRadiusProfile.map { ($0.0 * r, $0.1 * r) },
                                      side: palpSide[k], part: .palp, limb: 8 + k, hair: sp.hairLeg * (sp.jumper ? 1.9 : 1.2), hairy: true))
        }
        for k in 0..<2 {
            let f = fangs[k]
            p.caps.append(capInst(f.0, f.1, sp.chelicera.y * 0.16, sp.chelicera.y * 0.03, side: F3(0, 0, 1), part: .fang, seg: 0, leg: 0, hair: 0, seed: 0))
        }
        let ar = abdomenRot
        for k in -1...1 {
            let base = spinneret + ar * F3(sp.abdomen.x * 0.05, Float(k) * sp.abdomen.y * 0.035, -sp.abdomen.z * 0.04)
            let tip = base + ar * F3(-sp.abdomen.x * 0.055, Float(k) * sp.abdomen.y * 0.02, -sp.abdomen.z * 0.03)
            p.caps.append(capInst(base, tip, sp.abdomen.y * 0.032, sp.abdomen.y * 0.022, side: F3(0, 0, 1), part: .spin, seg: 0, leg: 0, hair: 0, seed: 0))
        }
        p.caps.append(capInst(pedicel.0, pedicel.1, sp.carapace.y * 0.10, sp.carapace.y * 0.10, side: F3(0, 0, 1), part: .spin, seg: 0, leg: 0, hair: 0, seed: 0))
        for i in 0..<8 {
            let f = legs[i].joints[7]
            p.feet.append(F4(f.x, f.y, legs[i].contact, sp.legs[i / 2].radius * 1.5))
        }
        let bz = sp.bodyZ
        p.ell = [F4(bodyPos.x, bodyPos.y, sp.carapace.x * 0.62, sp.carapace.y * 0.62),
                 F4(yaw, max(0, bodyPos.z - sp.carapaceBottom) / bz, 0.30, 0),
                 F4(abdomenCenter.x, abdomenCenter.y, sp.abdomen.x * 0.55, sp.abdomen.y * 0.58),
                 F4(yaw + abdYaw, max(0, abdomenCenter.z - sp.abdomen.z * 0.4) / bz, 0.30, 0)]
        return p
    }

    // MARK: 脚の幾何

    @inline(__always) func sideSign(_ i: Int) -> Float { i % 2 == 0 ? 1 : -1 }
    func legSpec(_ i: Int) -> LegSpec { sp.legs[i / 2] }
    func rootBody(_ i: Int) -> F3 {
        let r = legSpec(i).root
        return F3(r.x, r.y * sideSign(i), r.z)
    }
    func restBody(_ i: Int) -> F2 {
        let l = legSpec(i)
        let a = l.restAngle * .pi / 180
        let r = rootBody(i)
        let reach = l.restReach * (1 - 0.06 * rest)
        return F2(r.x, r.y) + F2(cos(a), sin(a) * sideSign(i)) * reach
    }
    func restWorld(_ i: Int) -> F2 {
        bodyXY + rot2(restBody(i) + legs[i].idleOffset, yaw)
    }

    func reset(at p: F2) {
        head = p
        headVel = .zero
        let f = F2(cos(yaw), sin(yaw))
        tail = head - f * towLen
        bodyXY = head - f * headToBody
        bodyVel = .zero
        zNow = sp.bodyZ
        airborne = false
        hopZ = 0
        airW = 0
        for i in 0..<8 {
            legs[i].idleOffset = .zero
            let r = restWorld(i)
            legs[i].foot = F3(r.x, r.y, 0)
            legs[i].planted = true
        }
        if let a = silkAnchor { events.append(.silkDone(a, xy(spinneret))) }
        silkAnchor = nil
        initialized = true
    }

    // MARK: 入力

    func mouseDown() {
        leftDown = true
        pressPoint = head
        pressAnchor = xy(spinneret)
        if airborne { forceLand() }
    }
    func mouseUp(strike: Bool = true) {
        leftDown = false
        if !strike {
            if let a = silkAnchor, !silkFromJump { events.append(.silkDone(a, xy(spinneret))); silkAnchor = nil }
            return
        }
        strikeT = 0
        strikeFired = false
        strikePlanted = false
        if let a = silkAnchor, !silkFromJump {
            events.append(.silkDone(a, xy(spinneret)))
            silkAnchor = nil
        }
        idleKind = -1
    }
    func rightClick() {
        webT = 0
        webFired = false
        idleKind = -1
    }

    func forceLand() {
        airborne = false
        hopZ = 0
        for i in 0..<8 {
            let r = restWorld(i)
            legs[i].foot = F3(r.x, r.y, 0)
            legs[i].planted = true
        }
    }

    // MARK: 1フレーム更新

    func update(dt rawDt: Float, cursor: F2) {
        let dt = clampf(rawDt, 1.0 / 500, 1.0 / 20)
        time += dt
        if !initialized { reset(at: cursor) }

        // ---- カーソル ----
        let delta = cursor - head
        let moved = simd_length(delta)
        if moved * ptPerMM > 700 { reset(at: cursor); return }
        head = cursor
        headVel = damp2(headVel, delta / dt, 28, dt)
        speed = simd_length(headVel)
        let moving = speed > 2.5
        if moving { stillTime = 0 } else { stillTime += dt }

        updateAir(dt: dt, moved: moved)
        updateFacing(dt: dt, moved: moved)
        updateActions(dt: dt)
        updateIdle(dt: dt)

        // ---- 胴体の位置 ----
        let fwd = F2(cos(yaw), sin(yaw))
        let newBodyXY = head + fwd * (lunge * sp.carapace.x * 0.22) - fwd * headToBody
        let v = (newBodyXY - bodyXY) / dt
        let prevVel = bodyVel
        bodyVel = damp2(bodyVel, v, 30, dt)
        bodyAcc = damp2(bodyAcc, (bodyVel - prevVel) / dt, 12, dt)
        bodyXY = newBodyXY

        updateBody(dt: dt)
        updateLegs(dt: dt)
        updatePalps(dt: dt)
        updateAbdomenAndMouth(dt: dt)
        updateSilk()
    }

    // 速く動かすと跳ぶ（ハエトリグモ）
    func updateAir(dt: Float, moved: Float) {
        guard sp.jumper else { return }
        if speed > sp.walkMaxSpeed { fastTimer += dt; slowTimer = 0 } else { slowTimer += dt; fastTimer = 0 }
        if !airborne {
            if fastTimer > 0.025 && !leftDown {
                airborne = true
                hopPhase = 0
                startHop()
                if silkAnchor == nil {
                    silkAnchor = xy(spinneret)
                    silkFromJump = true
                }
            }
        }
        if airborne {
            let adv = max(moved / max(hopLen, 0.1), dt / 0.15)
            hopPhase += adv
            if hopPhase >= 1 {
                if slowTimer < 0.05 && !leftDown {
                    hopPhase -= 1
                    hopPhase = min(hopPhase, 0.5)
                    startHop()
                } else {
                    airborne = false
                    hopZ = 0
                    landSquash = 1
                    for i in 0..<8 {
                        let r = restWorld(i) + F2(rng.range(-0.15, 0.15), rng.range(-0.15, 0.15))
                        legs[i].foot = F3(r.x, r.y, 0)
                        legs[i].planted = true
                    }
                }
            }
            if airborne {
                hopZ = hopH * sin(.pi * clampf(hopPhase, 0, 1))
            }
        }
        // 着地後、糸を残して離す
        if !airborne, silkFromJump, let a = silkAnchor, stillTime > 0.2 || slowTimer > 0.35 {
            events.append(.silkDone(a, xy(spinneret)))
            silkAnchor = nil
            silkFromJump = false
        }
    }

    func startHop() {
        hopLen = clampf(speed * 0.13, sp.bodyLength * 1.2, sp.bodyLength * 7)
        hopH = min(hopLen * 0.20, sp.bodyLength * 0.9)
    }

    // 向き：頭（カーソル）を牽引点とするトレーラーのように体が後ろへついてくる
    func updateFacing(dt: Float, moved: Float) {
        let prevYaw = yaw
        var dir = head - tail
        let dl = simd_length(dir)
        dir = dl > 1e-5 ? dir / dl : F2(cos(yaw), sin(yaw))
        let fwd = F2(cos(yaw), sin(yaw))

        if speed > 4 {
            let vd = headVel / speed
            if simd_dot(vd, fwd) < -0.3 { backAccum += moved } else { backAccum = max(0, backAccum - moved * 1.5) }
        } else {
            backAccum = max(0, backAccum - dt * sp.bodyLength)
        }
        if backAccum > sp.bodyLength * 0.7 && speed > 4 { turning = true }

        if airborne && speed > 5 {
            // 跳んでいる間は進行方向へまっすぐ向く
            let target = atan2(headVel.y, headVel.x)
            yaw += wrapPi(target - yaw) * (1 - exp(-16 * dt))
            tail = head - F2(cos(yaw), sin(yaw)) * towLen
            turning = false
            backAccum = 0
        } else if turning {
            let target = atan2(headVel.y, headVel.x)
            let diff = wrapPi(target - yaw)
            let maxStep: Float = 13 * dt
            yaw += clampf(diff, -maxStep, maxStep)
            tail = head - F2(cos(yaw), sin(yaw)) * towLen
            if abs(diff) < 0.25 || speed < 2 { turning = false; backAccum = 0 }
        } else {
            tail = head - dir * towLen
            yaw = atan2(dir.y, dir.x)
        }
        // 待機中の「キョロッ」
        if twitchLeft > 0 {
            let s = min(dt, twitchLeft)
            yaw += twitchRate * s
            twitchLeft -= s
            tail = head - F2(cos(yaw), sin(yaw)) * towLen
        }
        yawRate = damp(yawRate, wrapPi(yaw - prevYaw) / dt, 20, dt)
    }

    func updateActions(dt: Float) {
        press = damp(press, leftDown ? 1 : 0, leftDown ? 26 : 16, dt)
        strikeT += dt
        let s = strikeT
        var strikeLegs: Float = 0
        var lungeT: Float = 0
        if s < 0.40 {
            if s < 0.065 { let u = sstep(0, 1, s / 0.065); lungeT = u; strikeLegs = u }
            else if s < 0.15 { lungeT = 1; strikeLegs = 1 }
            else { let u = sstep(0, 1, (s - 0.15) / 0.25); lungeT = 1 - u; strikeLegs = 0 }
            if !strikeFired && s >= 0.055 {
                strikeFired = true
                events.append(.bite(head, true))
            }
        }
        lunge = lungeT
        strikeLegsW = strikeLegs
        if !strikePlanted && s >= 0.15 {
            // 叩きつけた第1脚はその場に残し、あとは歩行に任せて戻す
            strikePlanted = true
            for i in 0..<2 {
                let f = strikeFoot(i)
                legs[i].foot = F3(f.x, f.y, 0)
                legs[i].planted = true
            }
        }
        chelOpen = damp(chelOpen, max(press, (s < 0.06 ? 1 : 0)), s < 0.06 ? 40 : 18, dt)

        webT += dt
        if !webFired && webT >= 0.10 {
            webFired = true
            events.append(.web(head))
        }
        landSquash = damp(landSquash, 0, 9, dt)
    }
    var strikeLegsW: Float = 0

    func strikeFoot(_ i: Int) -> F2 {
        let L = legSpec(i).total
        return head + rot2(F2(-0.02 * L, sideSign(i) * 0.24 * L), yaw)
    }

    func updateIdle(dt: Float) {
        let calm = stillTime > 0.6 && !airborne && press < 0.05 && strikeT > 0.5 && webT > 0.5
        rest = damp(rest, stillTime > 18 ? 1 : 0, stillTime > 18 ? 0.8 : 6, dt)
        palpBoost = damp(palpBoost, 0, 1.5, dt)
        if idleKind >= 0 {
            idleT += dt
            if idleT >= idleDur { idleKind = -1 }
        }
        guard calm else { idleTimer = max(idleTimer, 0.6); return }
        idleTimer -= dt
        if idleTimer <= 0 && idleKind < 0 {
            idleTimer = rng.range(1.0, 3.2) * (rest > 0.5 ? 2.2 : 1)
            let r = rng.f()
            idleT = 0
            idleSide = rng.f() < 0.5 ? 0 : 1
            if r < 0.24 {
                idleKind = 0; idleDur = rng.range(0.45, 0.9)          // 前脚を上げる
            } else if r < 0.46 {
                idleKind = 1; idleDur = 0.1                           // キョロッと向きを変える
                let ang = rng.range(0.12, 0.38) * rng.sign()
                twitchLeft = 0.07
                twitchRate = ang / 0.07
            } else if r < 0.66 {
                idleKind = 2; idleDur = 0.2                           // 脚を置き直す
                let n = 1 + Int(rng.f() * 2.5)
                for _ in 0..<n {
                    let i = Int(rng.f() * 8) % 8
                    let rr = legSpec(i).restReach
                    legs[i].idleOffset = F2(rng.range(-0.16, 0.16), rng.range(-0.16, 0.16)) * rr
                }
            } else if r < 0.80 {
                idleKind = 3; idleDur = rng.range(0.9, 1.4)           // 脚の手入れ
            } else {
                idleKind = 4; idleDur = 0.5                           // 触肢をせわしなく動かす
                palpBoost = 1
            }
        }
    }

    func idleEnv(_ kind: Int) -> Float {
        guard idleKind == kind, idleDur > 0 else { return 0 }
        let u = clampf(idleT / idleDur, 0, 1)
        return sstep(0, 0.25, u) * (1 - sstep(0.7, 1, u))
    }

    func updateBody(dt: Float) {
        let bz = sp.bodyZ
        var zt = bz * (1 - 0.25 * rest)
        zt += press * 0.22 * bz
        zt -= lunge * 0.22 * bz
        zt -= landSquash * 0.25 * bz
        let webEnv = webT < 0.4 ? sin(.pi * webT / 0.4) : 0
        zt -= webEnv * 0.15 * bz
        // 脚の振り出しに合わせた上下動
        var swinging: Float = 0
        for l in legs where !l.planted { swinging += 1 }
        bob = damp(bob, -swinging * 0.018 * bz, 25, dt)
        let breathe = sin(time * 2 * .pi * 0.9) * 0.012 * bz
        zNow = damp(zNow, zt, 22, dt)
        let z = zNow + bob + breathe + hopZ

        var pt: Float = press * 0.38 - lunge * 0.20 - webEnv * 0.10 - landSquash * 0.10
        if airborne { pt += 0.16 * cos(.pi * clampf(hopPhase, 0, 1)) }
        pt += fbm1(time * 0.35, 3) * 0.025 * (1 - min(1, speed / 20))
        pitch = damp(pitch, pt, 20, dt)
        let left = F2(-sin(yaw), cos(yaw))
        let lat = simd_dot(bodyAcc, left)
        var rl = clampf(-lat * 0.00045 * (sp.jumper ? 1 : 0.4), -0.14, 0.14)
        rl += fbm1(time * 0.3, 9) * 0.02
        roll = damp(roll, rl, 14, dt)

        bodyRot = rotZ(yaw) * pitchUp(pitch) * rollL(roll)
        bodyPos = F3(bodyXY.x, bodyXY.y, z)
        carapaceM = makeTransform(bodyRot, bodyPos)
    }

    // MARK: 脚

    func neighbors(_ i: Int) -> [Int] {
        let pair = i / 2, side = i % 2
        var n = [pair * 2 + (1 - side)]
        if pair > 0 { n.append((pair - 1) * 2 + side) }
        if pair < 3 { n.append((pair + 1) * 2 + side) }
        return n
    }

    func updateLegs(dt: Float) {
        let sNorm = sat(speed / sp.walkMaxSpeed)
        let settling = stillTime > 0.10
        let yawM = rotZ(yaw)

        if airborne {
            for i in 0..<8 {
                let r = restWorld(i)
                legs[i].foot = F3(r.x, r.y, 0)
                legs[i].planted = true
            }
        } else {
            // 振り出し中の脚を進める
            var swingCount = 0
            for i in 0..<8 where !legs[i].planted {
                var L = legs[i]
                L.t += dt / L.dur
                let target = stepTarget(i, settling: settling)
                let p = min(L.t, 1)
                let e = p * p * (3 - 2 * p)
                let h = L.lift * sin(.pi * pow(p, 0.75))
                let fx = mix2(xy(L.from), target, e)
                L.foot = F3(fx.x, fx.y, h)
                if L.t >= 1 {
                    L.planted = true
                    L.foot = F3(target.x, target.y, 0)
                    L.idleOffset = .zero
                } else { swingCount += 1 }
                legs[i] = L
            }
            // 新しく踏み出す脚を選ぶ
            var cand: [(Int, Float)] = []
            for i in 0..<8 where legs[i].planted {
                if i < 2 && (press > 0.3 || strikeLegsW > 0.05) { continue }
                let reach = legSpec(i).restReach
                let thr = settling ? reach * 0.075 : reach * (0.26 - 0.06 * sNorm)
                var err = simd_length(xy(legs[i].foot) - restWorld(i))
                if legs[i].idleOffset != .zero { err = max(err, thr * 1.01) }
                // 届かない位置に取り残されたら必ず踏み出す
                let root = bodyPos + bodyRot * rootBody(i)
                let far = simd_length(xy(legs[i].foot) - xy(root)) > (legSpec(i).total - legSpec(i).seg[0]) * 0.93
                if err > thr || far { cand.append((i, far ? 1e6 : err / thr)) }
            }
            cand.sort { $0.1 > $1.1 }
            for (i, score) in cand {
                if swingCount >= 4 { break }
                let blocked = neighbors(i).contains { !legs[$0].planted }
                if blocked && score < 2.2 { continue }
                if settling && swingCount >= 1 { break }
                var L = legs[i]
                L.planted = false
                L.t = 0
                L.from = L.foot
                let lt = legSpec(i).total
                if settling {
                    L.dur = sp.stepDur * 1.5
                    L.lift = lt * 0.07
                } else {
                    L.dur = sp.stepDur * mixf(1.0, 0.55, sNorm)
                    L.lift = lt * (0.09 + 0.08 * sNorm)
                }
                legs[i] = L
                swingCount += 1
            }
        }

        // 跳躍中の脚の構え（前脚を前へ伸ばし、後脚は後ろへ）
        let targetAir: Float = airborne ? sat(hopZ / max(hopH * 0.35, 0.01)) : 0
        airW = damp(airW, targetAir, 30, dt)

        for i in 0..<8 {
            let spec = legSpec(i)
            let s = sideSign(i)
            let Lt = spec.total
            let root = bodyPos + bodyRot * rootBody(i)
            var foot = legs[i].foot

            if airW > 0.001 {
                let r = rootBody(i)
                var ap: F3
                switch i / 2 {
                case 0: ap = F3(r.x + 0.62 * Lt, s * (r.y + 0.22 * Lt), -0.15 * Lt)
                case 1: ap = F3(r.x + 0.30 * Lt, s * (r.y + 0.48 * Lt), -0.25 * Lt)
                case 2: ap = F3(r.x - 0.20 * Lt, s * (r.y + 0.45 * Lt), -0.28 * Lt)
                default: ap = F3(r.x - 0.62 * Lt, s * (r.y + 0.22 * Lt), -0.22 * Lt)
                }
                let wa = bodyPos + yawM * ap
                foot = mix3(foot, wa, airW)
            }

            // 前脚：ボタンを押している間は振り上げ（威嚇）、離すと叩きつける
            if i < 2 {
                var w: Float = 0
                var target = foot
                let raised = bodyPos + yawM * F3(rootBody(i).x + 0.42 * Lt, s * (rootBody(i).y + 0.40 * Lt), 0.42 * Lt + 0.06 * Lt * sin(time * 9 + Float(i)))
                if press > 0.001 || strikeLegsW > 0.001 {
                    let sf = strikeFoot(i)
                    target = mix3(raised, F3(sf.x, sf.y, 0), strikeLegsW)
                    w = max(press, strikeLegsW)
                }
                let wave = idleEnv(0) * (idleSide == i % 2 ? 1 : 0.0)
                if wave > 0.001 {
                    let up = bodyPos + yawM * F3(rootBody(i).x + 0.50 * Lt, s * (rootBody(i).y + 0.22 * Lt), 0.18 * Lt + 0.06 * Lt * sin(idleT * 14))
                    target = w > 0 ? target : up
                    w = max(w, wave)
                }
                let groom = idleEnv(3) * (idleSide == i % 2 ? 1 : 0.0)
                if groom > 0.001 {
                    // 第1脚の先を口元（鋏角）へ運んでしごく
                    let pull = 0.5 + 0.5 * sin(idleT * 11)
                    let mouth = bodyPos + bodyRot * F3(sp.carapace.x * 0.5 + 0.10 * Lt * pull, s * 0.05 * Lt, -sp.bodyZ * 0.35)
                    target = w > 0 ? target : mouth
                    w = max(w, groom)
                }
                if w > 0.001 { foot = mix3(foot, target, sstep(0, 1, w)) }
            }

            let fallback = rot2(simd_normalize(restBody(i) - F2(rootBody(i).x, rootBody(i).y)), yaw)
            var dl = xy(foot - root)
            dl = simd_length(dl) > 1e-4 ? simd_normalize(dl) : fallback
            var perp = F2(-dl.y, dl.x)
            let bodyLat = rot2(F2(0, s), yaw)
            if simd_dot(perp, bodyLat) < 0 { perp = -perp }
            let tilt = 0.26 * abs(simd_dot(perp, bodyLat)) + 0.06
            let (j, side) = SpiderSim.solveLeg(root: root, foot: foot, seg: spec.seg, ankleDeg: spec.ankle, fallbackDir: fallback,
                                               lateral: F3(perp.x, perp.y, 0), tilt: tilt)
            legs[i].joints = j
            legs[i].side = side
            legs[i].contact = legs[i].planted && airW < 0.5 && foot.z < 0.05 ? 1 : max(0, 1 - foot.z / (0.1 * Lt))
        }
    }

    func stepTarget(_ i: Int, settling: Bool) -> F2 {
        let r = restWorld(i)
        if settling { return r }
        let rel = r - bodyXY
        let vr = bodyVel + F2(-rel.y, rel.x) * yawRate
        let thr = legSpec(i).restReach * 0.24
        var lead = vr * (legs[i].dur * 1.05)
        let ll = simd_length(lead)
        if ll > thr * 0.95 { lead *= thr * 0.95 / ll }
        return r + lead
    }

    /// 脚のIK：膝（腿節-膝節）が高く上がるクモらしい形にする
    static func solveLeg(root: F3, foot: F3, seg: [Float], ankleDeg: Float, fallbackDir: F2, lateral: F3 = .zero, tilt: Float = 0) -> ([F3], F3) {
        var j = [F3](repeating: .zero, count: 8)
        j[0] = root
        let up = F3(0, 0, 1)
        let dh = xy(foot - root)
        let dhl = simd_length(dh)
        var d2 = dhl > 1e-3 ? dh / dhl : fallbackDir
        // 足が付け根より内側に来すぎた時は外向きを保つ
        if simd_dot(d2, fallbackDir) < -0.2 && dhl < seg[0] + seg[1] + seg[2] * 0.3 { d2 = fallbackDir }
        let d3 = F3(d2.x, d2.y, 0)
        j[1] = j[0] + (d3 * cos(0.20) + up * sin(0.20)) * seg[0]
        j[2] = j[1] + (d3 * cos(0.55) + up * sin(0.55)) * seg[1]
        let A = seg[2]
        let B = seg[3] + seg[4]
        let C = seg[5] + seg[6]
        var alpha = ankleDeg * .pi / 180
        var ankle = F3.zero
        var L: Float = 0
        for _ in 0..<14 {
            ankle = foot + (-d3 * cos(alpha) + up * sin(alpha)) * C
            L = simd_length(ankle - j[2])
            if L > (A + B) * 0.985 { alpha -= 0.11; if alpha < 0.02 { alpha = 0.02; break } }
            else if L < abs(A - B) + 0.12 * (A + B) { alpha += 0.11; if alpha > 1.5 { alpha = 1.5; break } }
            else { break }
        }
        ankle = foot + (-d3 * cos(alpha) + up * sin(alpha)) * C
        let w = ankle - j[2]
        L = simd_length(w)
        let e = L > 1e-5 ? w / L : d3
        var side = simd_cross(e, up)
        if simd_length(side) < 1e-3 { side = simd_cross(d3, up) }
        side = simd_normalize(side)
        var bend = simd_normalize(simd_cross(side, e))
        if bend.z < 0 { bend = -bend }
        // 脚の面を少し外へ倒す：上から見ると膝で外側へ弓なりに曲がる
        if tilt != 0 {
            var lp = lateral - e * simd_dot(lateral, e)
            if simd_length(lp) > 1e-4 {
                lp = simd_normalize(lp)
                bend = simd_normalize(bend * cos(tilt) + lp * sin(tilt))
            }
        }
        let knee: F3
        let j5: F3
        if L >= A + B {
            knee = j[2] + e * A
            j5 = knee + e * B
        } else {
            let Lc = max(L, abs(A - B) + 1e-3)
            let cosA = clampf((A * A + Lc * Lc - B * B) / (2 * A * Lc), -1, 1)
            let sinA = sqrt(max(0, 1 - cosA * cosA))
            knee = j[2] + e * (A * cosA) + bend * (A * sinA)
            j5 = ankle
        }
        j[3] = knee
        let kd = j5 - knee
        var perp = simd_cross(side, kd)
        perp = simd_length(perp) > 1e-6 ? simd_normalize(perp) : up
        if perp.z < 0 { perp = -perp }
        j[4] = knee + kd * (seg[3] / B) + perp * (seg[3] * 0.25)
        j[5] = j5
        let md = foot - j5
        var perp2 = simd_cross(side, md)
        perp2 = simd_length(perp2) > 1e-6 ? simd_normalize(perp2) : up
        if perp2.z < 0 { perp2 = -perp2 }
        j[6] = j5 + md * (seg[5] / C) + perp2 * (seg[5] * 0.10)
        j[7] = foot
        return (j, side)
    }

    // MARK: 触肢（うにゅうにゅ動く口元の小さな腕）

    func updatePalps(dt: Float) {
        let segs: [Float] = [0.02, 0.02, sp.palpSeg[0], sp.palpSeg[1], sp.palpSeg[2], sp.palpSeg[3] * 0.55, sp.palpSeg[3] * 0.45]
        let rate: Float = sp.jumper ? 2.4 : 0.9
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            let n = fbm1(time * 0.8 + Float(k) * 7, 40 + Int32(k))
            palpPhase[k] += dt * 2 * .pi * rate * (1 + 0.5 * n + palpBoost * 1.2)
            let amp = (sp.jumper ? 0.20 : 0.12) * (1 + palpBoost * 0.8) * (0.6 + 0.4 * (n + 1) * 0.5)
            let flick = pow(0.5 + 0.5 * sin(palpPhase[k] + (k == 1 ? .pi : 0)), 1.6)
            var tip = sp.palpTip
            tip.y *= s
            let scale = sp.carapace.x
            tip.z += amp * scale * 0.35 * flick
            tip.x += amp * scale * 0.08 * sin(palpPhase[k] * 0.5)
            tip.y += s * 0.04 * scale * sin(palpPhase[k] * 0.37)
            // 威嚇：触肢も持ち上げる / 噛みつく瞬間は左右に開く
            tip.z += press * 0.28 * scale
            tip.x += press * 0.10 * scale
            tip.y += s * lunge * 0.10 * scale
            let rootB = F3(sp.carapace.x * 0.40, s * sp.carapace.y * 0.13, -sp.carapaceBottom * 0.75)
            let root = bodyPos + bodyRot * rootB
            let tipW = bodyPos + bodyRot * tip
            let fallback = rot2(F2(1, 0.25 * s), yaw)
            let (j, side) = SpiderSim.solveLeg(root: root, foot: tipW, seg: segs, ankleDeg: 58, fallbackDir: simd_normalize(fallback))
            palpJoints[k] = j
            palpSide[k] = side
        }
    }

    func updateAbdomenAndMouth(dt: Float) {
        // 腹部は少し遅れてついてくる
        var ay = clampf(-yawRate * 0.045, -0.40, 0.40)
        ay += fbm1(time * 0.5, 77) * 0.05
        if idleKind == 2 { ay += 0.03 * sin(idleT * 30) }
        abdYaw = damp(abdYaw, ay, 10, dt)
        let webEnv: Float = webT < 0.4 ? sin(.pi * webT / 0.4) : 0
        var ap: Float = 0.03 + webEnv * 0.30
        if airborne { ap += 0.10 * sin(.pi * clampf(hopPhase, 0, 1)) }
        ap -= landSquash * 0.08
        abdPitch = damp(abdPitch, ap, 14, dt)

        let breath = 1 + 0.014 * sin(time * 2 * .pi * 0.9)
        pedicel.0 = bodyPos + bodyRot * F3(-sp.carapace.x * 0.40, 0, -sp.carapaceBottom * 0.15)
        let abdR = rotZ(yaw + abdYaw) * pitchUp(pitch * 0.45 + abdPitch)
        abdomenRot = abdR
        let pedEnd = pedicel.0 + abdR * F3(-sp.carapace.x * 0.08, 0, 0)
        pedicel.1 = pedEnd
        abdomenCenter = pedEnd + abdR * F3(-sp.abdomen.x * 0.47, 0, sp.abdomen.z * 0.16)
        abdomenM = makeTransform(abdR, abdomenCenter, F3(breath, breath * 1.012, breath))
        spinneret = abdomenCenter + abdR * F3(-sp.abdomen.x * 0.49, 0, -sp.abdomen.z * 0.10)

        // 鋏角と牙
        let ch = sp.chelicera
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            let base = bodyPos + bodyRot * F3(sp.carapace.x * 0.5 - ch.z * 0.55, s * ch.y * 0.50, -sp.carapaceBottom * 0.35)
            let open = chelOpen
            let r = bodyRot * pitchUp(0.40 + open * 0.35) * rollL(s * open * 0.32)
            let center = base + r * F3(0, 0, -ch.x * 0.5)
            cheliceraM[k] = makeTransform(r, center, F3(ch.z * 0.5, ch.y * 0.5, ch.x * 0.5))
            let tipP = center + r * F3(ch.z * 0.12, 0, -ch.x * 0.46)
            // 牙：ふだんは内側へ折りたたみ、噛む瞬間に前へ出す
            let folded = r * simd_normalize(F3(0.15, -s * 1.0, 0.25))
            let opened = r * simd_normalize(F3(0.8, -s * 0.25, -0.55))
            let fd = simd_normalize(mix3(folded, opened, open))
            fangs[k] = (tipP, tipP + fd * ch.x * 0.42)
        }
    }

    func updateSilk() {
        if leftDown, silkAnchor == nil, simd_length(head - pressPoint) > sp.bodyLength * 0.35 {
            silkAnchor = pressAnchor
            silkFromJump = false
        }
    }

    /// いま伸びている牽引糸（始点, 終点）
    var activeSilk: (F2, F3)? {
        guard let a = silkAnchor else { return nil }
        return (a, spinneret)
    }
}
