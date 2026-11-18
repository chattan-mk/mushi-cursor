import Foundation
import simd

// MARK: - 戦車（ミニチュア）

struct TankSpec: CreatureDef {
    let shaderID: Int32 = 8
    let name = "戦車"
    let basePtPerMM: Float = 1.45
    let bodyZ: Float = 3.2
    let hairSpacing: Float = 0.3
    var bodyLengthMM: Float { 30 }
    let hullZ: Float = 3.7
    let trackY: Float = 6.6
    let turretPos = F3(-1.5, 0, 3.3)       // 車体の座標
    let barrelStart: Float = 6.6, barrelLen: Float = 19.0, brakeLen: Float = 1.8
    var reach: Float { barrelStart + barrelLen + brakeLen }   // 砲塔の中心 → 砲口

    static let tank = TankSpec()

    var meshShapes: [(F3) -> F3] {
        [
            { d in   // キャタピラ：前後が丸い箱
                let a: Float = 14.2, b: Float = 1.95, c: Float = 2.55
                let A = pow(pow(abs(d.x / a), 2.6) + pow(abs(d.z / c), 2.6), 1 / 2.6)
                let B = abs(d.y / b)
                return d / pow(pow(A, 8) + pow(B, 8), 1 / 8)
            },
            { d in superEllipsoid(d, 12.6, 4.8, 1.8, 1.8, 5) },                    // 車体下部
            { d in                                                                   // 車体上部（前面は傾斜）
                var p = superEllipsoid(d, 13.4, 8.4, 1.15, 1.0, 6)
                if p.z > 0 { p.z *= 1 - 0.75 * sstep(0.5, 1.0, p.x / 13.4) }
                return p
            },
            { d in                                                                   // 砲塔
                var p = superEllipsoid(d, 6.6, 5.6, 2.0, 1.7, 3.0)
                p.y *= 1 - 0.18 * sstep(0.1, 1, p.x / 6.6)
                if p.z > 0 { p.z *= 1 - 0.25 * sstep(0.3, 1, abs(p.x) / 6.6) }
                return p
            },
            { d in superEllipsoid(d, 1.2, 2.5, 1.3, 1.3, 3.2) },                    // 防盾
            { d in superEllipsoid(d, 1.6, 1.6, 0.85, 0.45, 2.6) },                  // キューポラ
        ]
    }
    func makeBristles() -> [Bristle] { [] }
    func layerRadiusMM() -> Float { reach + 16 + 6 }
    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { TankSim(spec: self, ptPerMM: ptPerMM, seed: seed) }
}

final class TankSim: CreatureSim {
    let sp: TankSpec
    var rng: SplitMix
    var time: Float = 0
    let ptPerMM: Float
    var aim: Follower          // 砲口がカーソル、砲身の向き
    var hullTail = F2.zero
    var hullYaw: Float = .pi / 2
    var hullYawRate: Float = 0
    var events: [SimEvent] = []
    var bodyXY = F2.zero
    var hullVel = F2.zero
    var pitch: Float = 0, roll: Float = 0
    var pitchV: Float = 0
    var scrollL: Float = 0, scrollR: Float = 0
    var trackAccum: Float = 0
    var leftDown = false
    var strikeT: Float = 10
    var webT: Float = 10
    var mgFired = 0
    var recoil: Float = 0
    var flash: Float = 0
    var mgFlash: Float = 0
    var antenna: [F3] = []
    var antennaV = F2.zero, antennaO = F2.zero
    var stillTime: Float { aim.stillTime }
    var airborne: Bool { false }
    var activeSilk: (F2, F3)? { nil }

    init(spec: TankSpec, ptPerMM: Float, seed: UInt64) {
        sp = spec
        self.ptPerMM = ptPerMM
        rng = SplitMix(seed: seed)
        aim = Follower(towLen: spec.reach)
    }

    func mouseDown() { leftDown = true }
    func mouseUp(strike: Bool) {
        leftDown = false
        guard strike else { return }
        strikeT = 0
        recoil = 1
        flash = 1
        pitchV += 2.2
        let dir = aim.fwd
        events.append(.shot(aim.head, dir, true))
    }
    func rightClick() { webT = 0; mgFired = 0 }

    var hullDir: F2 { F2(cos(hullYaw), sin(hullYaw)) }

    func update(dt rawDt: Float, cursor: F2) {
        let dt = clampf(rawDt, 1.0 / 500, 1.0 / 20)
        time += dt
        let wasInit = aim.initialized
        let moved = aim.update(dt: dt, cursor: cursor, ptPerMM: ptPerMM, turnAround: false)
        let pivot = aim.head - aim.fwd * sp.reach
        if !wasInit || moved < 0 {
            hullYaw = aim.yaw
            hullTail = pivot - hullDir * 26
        }
        // 車体は砲塔の中心を引っぱる点にして後ろへついてくる（横滑りしない）
        let prevYaw = hullYaw
        var d = pivot - hullTail
        let dl = simd_length(d)
        d = dl > 1e-5 ? d / dl : hullDir
        hullTail = pivot - d * 26
        hullYaw = atan2(d.y, d.x)
        hullYawRate = damp(hullYawRate, wrapPi(hullYaw - prevYaw) / dt, 20, dt)
        let newXY = pivot - rot2(F2(sp.turretPos.x, 0), hullYaw)
        let v = (newXY - bodyXY) / dt
        let prevV = hullVel
        hullVel = (!wasInit || moved < 0) ? .zero : damp2(hullVel, v, 25, dt)
        bodyXY = newXY

        // キャタピラの送りと跡
        let vf = simd_dot(hullVel, hullDir)
        scrollL += (vf - hullYawRate * sp.trackY) * dt
        scrollR += (vf + hullYawRate * sp.trackY) * dt
        trackAccum += (abs(vf) + abs(hullYawRate) * sp.trackY) * dt
        if trackAccum > 1.5 {
            trackAccum = 0
            events.append(.track(bodyXY - hullDir * 11.5, hullYaw, sp.trackY * 2))
        }

        // サスペンション：加減速で前後に揺れる
        let acc = (hullVel - prevV) / dt
        let af = simd_dot(acc, hullDir)
        let al = simd_dot(acc, F2(-hullDir.y, hullDir.x))
        pitchV += (-pitch * 140 - pitchV * 12 + af * 0.0028) * dt
        pitch += pitchV * dt
        roll = damp(roll, clampf(-al * 0.0012, -0.06, 0.06), 8, dt)

        // 砲撃・機銃
        strikeT += dt
        webT += dt
        recoil = damp(recoil, 0, recoil > 0.5 ? 9 : 6, dt)
        flash = max(0, flash - dt / 0.07)
        mgFlash = max(0, mgFlash - dt / 0.04)
        if webT < 0.6 {
            let k = Int(webT / 0.08)
            if k > mgFired - 1 && mgFired < 6 && k >= mgFired {
                mgFired += 1
                mgFlash = 1
                let dir = aim.fwd
                let spread = F2(rng.range(-2.5, 2.5), rng.range(-2.5, 2.5))
                events.append(.shot(aim.head + spread + dir * rng.range(0, 3), dir, false))
            }
        }

        // ホイップアンテナ：加速度で揺れる
        antennaV += (-antennaO * 90 - antennaV * 5 - acc * 0.004) * dt
        antennaO += antennaV * dt
        antennaO = F2(clampf(antennaO.x, -1, 1), clampf(antennaO.y, -1, 1))
    }

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        let vib = 0.05 * sin(time * 95) + 0.03 * sin(time * 61)
        let hullR = rotZ(hullYaw) * pitchUp(pitch) * rollL(roll)
        let hullP = F3(bodyXY.x, bodyXY.y, sp.hullZ + vib)
        let turretRel = wrapPi(aim.yaw - hullYaw)
        let turR = hullR * rotZ(turretRel)
        let turP = hullP + hullR * sp.turretPos
        // キャタピラ（送りの量を ext.w で渡す）
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            p.blobs.append(blob(0, makeTransform(hullR, hullP + hullR * F3(0, s * sp.trackY, -1.15)), .tread, ext: F3(14.2, 1.95, 2.55), seed: Float(k), extW: k == 0 ? scrollL : scrollR))
        }
        p.blobs.append(blob(1, makeTransform(hullR, hullP + hullR * F3(0, 0, -0.9)), .hull, ext: F3(12.6, 4.8, 1.8), seed: 3))
        p.blobs.append(blob(2, makeTransform(hullR, hullP + hullR * F3(0, 0, 1.55)), .hull, ext: F3(13.4, 8.4, 1.15), seed: 4))
        p.blobs.append(blob(3, makeTransform(turR, turP), .turret, ext: F3(6.6, 5.6, 2.0), seed: 5))
        p.blobs.append(blob(4, makeTransform(turR, turP + turR * F3(6.3, 0, 0.1)), .turret, ext: F3(1.2, 2.5, 1.3), seed: 6))
        p.blobs.append(blob(5, makeTransform(turR, turP + turR * F3(-2.6, 2.3, 1.85)), .turret, ext: F3(1.6, 1.6, 0.85), seed: 7))
        // 砲身（撃つと後退する）
        let rc = recoil * 2.8
        let b0 = turP + turR * F3(sp.barrelStart - rc, 0, 0.2)
        let b1 = turP + turR * F3(sp.barrelStart + sp.barrelLen - rc, 0, 0.3)
        let b2 = turP + turR * F3(sp.reach - rc, 0, 0.3)
        p.chains.append(ChainPose(joints: [b0, b1], radii: [(0.78, 0.62)], side: F3(0, 0, 1), part: .barrel, limb: 0, hair: 0, hairy: false))
        p.caps.append(capInst(b1, b2, 0.98, 0.98, side: F3(0, 0, 1), part: .metal, seg: 0, leg: 0, hair: 0, seed: 0))
        // 前照灯・排気管・ハッチ
        for s in [Float(1), -1] {
            p.blobs.append(blob(-1, makeTransform(hullR, hullP + hullR * F3(12.6, s * 6.0, 2.5), F3(0.55, 0.55, 0.45)), .lens, seed: 8, shadow: false))
            let e0 = hullP + hullR * F3(-12.6, s * 3.6, 2.3)
            p.caps.append(capInst(e0, e0 + hullR * F3(-1.4, 0, 0.1), 0.5, 0.5, side: F3(0, 0, 1), part: .metal, seg: 0, leg: 0, hair: 0, seed: 1))
        }
        // アンテナ
        let base = turP + turR * F3(-4.6, -3.7, 1.8)
        var a = [base]
        for k in 1...5 {
            let t = Float(k) / 5
            let lean = F3(-0.55 + antennaO.x * 0.8 * t, antennaO.y * 0.8 * t, 1)
            a.append(a[k - 1] + simd_normalize(turR * lean) * 2.3)
        }
        p.chains.append(ChainPose(joints: a, radii: [(0.16, 0.14), (0.14, 0.12), (0.12, 0.1), (0.1, 0.08), (0.08, 0.06)], side: F3(0, 0, 1), part: .metal, limb: 0, hair: 0, hairy: false))
        // 砲口の炎
        if flash > 0.01 {
            let tip = turP + turR * F3(sp.reach - rc + 1.8 * flash, 0, 0.3)
            p.blobs.append(blob(-1, makeTransform(turR, tip, F3(3.6, 2.4, 2.0) * (0.6 + 0.6 * flash)), .flash, shadow: false, alpha: true, extW: flash))
        }
        if mgFlash > 0.01 {
            let tip = turP + turR * F3(8.2, -1.6, 0.1)
            p.blobs.append(blob(-1, makeTransform(turR, tip, F3(1.4, 0.9, 0.8)), .flash, shadow: false, alpha: true, extW: mgFlash))
        }
        p.ell = [F4(hullP.x, hullP.y, 14.0, 8.2), F4(hullYaw, 0.1, 0.35, 0), .zero, .zero]
        return p
    }
}

// MARK: - ドローン

struct DroneSpec: CreatureDef {
    let shaderID: Int32 = 9
    let name = "ドローン"
    let basePtPerMM: Float = 2.0
    let bodyZ: Float = 5.0
    let hairSpacing: Float = 0.3
    var bodyLengthMM: Float { 34 }
    let hoverZ: Float = 13
    let motors: [F3] = [F3(8.8, 9.6, 0.7), F3(8.8, -9.6, 0.7), F3(-8.2, 9.2, 0.9), F3(-8.2, -9.2, 0.9)]

    static let drone = DroneSpec()

    var meshShapes: [(F3) -> F3] {
        [
            { d in
                var p = superEllipsoid(d, 8.2, 4.3, 2.2, 1.9, 2.6)
                p.y *= 1 - 0.20 * sstep(0.3, 1, p.x / 8.2)
                if p.z > 0 { p.z += 0.5 * exp(-pow(p.y / 2.2, 2)) * (1 - abs(p.x) / 8.2) }
                return p
            },
            { d in superEllipsoid(d, 6.6, 6.6, 0.04, 0.04, 2.0) },     // プロペラの残像
        ]
    }
    func makeBristles() -> [Bristle] { [] }
    func layerRadiusMM() -> Float { 17 + hoverZ * 0.65 + 4 }
    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { DroneSim(spec: self, ptPerMM: ptPerMM, seed: seed) }
}

final class DroneSim: CreatureSim {
    let sp: DroneSpec
    var time: Float = 0
    let ptPerMM: Float
    var f = Follower(towLen: 30)
    var events: [SimEvent] = []
    var bodyXY = F2.zero
    var yaw: Float = .pi / 2
    var tiltP: Float = 0, tiltR: Float = 0
    var z: Float = 13
    var leftDown = false
    var press: Float = 0
    var strikeT: Float = 10
    var strikeFired = true
    var webT: Float = 10
    var spin: Float = 0
    var stillTime: Float { f.stillTime }
    var airborne: Bool { true }
    var activeSilk: (F2, F3)? { nil }

    init(spec: DroneSpec, ptPerMM: Float, seed: UInt64) {
        sp = spec
        self.ptPerMM = ptPerMM
        z = spec.hoverZ
    }

    func mouseDown() { leftDown = true }
    func mouseUp(strike: Bool) {
        leftDown = false
        guard strike else { return }
        strikeT = 0
        strikeFired = false
    }
    func rightClick() { webT = 0 }

    func update(dt rawDt: Float, cursor: F2) {
        let dt = clampf(rawDt, 1.0 / 500, 1.0 / 20)
        time += dt
        let wasInit = f.initialized
        _ = f.update(dt: dt, cursor: cursor, ptPerMM: ptPerMM, turnAround: false)
        if !wasInit { yaw = f.yaw }
        bodyXY = f.head
        // 速く動く時だけ、ゆっくり進行方向へ機首を向ける
        if f.speed > 35 {
            let target = atan2(f.vel.y, f.vel.x)
            yaw += clampf(wrapPi(target - yaw), -1.3 * dt, 1.3 * dt)
        }
        // 速度の方向へ機体を傾ける
        let c = cos(yaw), s = sin(yaw)
        let vf = f.vel.x * c + f.vel.y * s
        let vl = -f.vel.x * s + f.vel.y * c
        tiltP = damp(tiltP, -clampf(vf * 0.0032, -0.45, 0.45), 6, dt)
        tiltR = damp(tiltR, -clampf(vl * 0.0032, -0.45, 0.45), 6, dt)

        press = damp(press, leftDown ? 1 : 0, 10, dt)
        strikeT += dt
        webT += dt
        var zt = sp.hoverZ - press * 4 + 0.35 * sin(time * 2 * .pi * 1.2) + 0.2 * fbm1(time * 0.7, 3)
        if strikeT < 0.55 {
            // 急降下して画面に触れ、また上がる
            let s2 = strikeT
            let k: Float = s2 < 0.11 ? sstep(0, 1, s2 / 0.11) : 1 - sstep(0, 1, (s2 - 0.11) / 0.44)
            zt = mixf(zt, 2.2, k)
            if !strikeFired && s2 >= 0.1 {
                strikeFired = true
                events.append(.downwash(f.head, 26))
                events.append(.bite(f.head, false))
            }
        }
        if webT < 0.55 { zt += 6 * sin(.pi * webT / 0.55) }
        z = damp(z, zt, strikeT < 0.12 ? 40 : 9, dt)
        spin += dt * 2 * .pi * 47.3
    }

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        var flip: Float = 0
        if webT < 0.55 { let u = webT / 0.55; flip = 2 * .pi * u * u * (3 - 2 * u) }
        let R = rotZ(yaw) * pitchUp(tiltP) * rollL(tiltR + flip)
        let P = F3(bodyXY.x, bodyXY.y, z)
        p.blobs.append(blob(0, makeTransform(R, P), .plastic, ext: F3(8.2, 4.3, 2.2), seed: 1))
        for (i, m) in sp.motors.enumerated() {
            let root = P + R * F3(m.x * 0.38, m.y * 0.22, 0.35)
            let mp = P + R * m
            p.chains.append(ChainPose(joints: [root, mp], radii: [(0.95, 0.75)], side: F3(0, 0, 1), part: .plastic, limb: i, hair: 0, hairy: false))
            p.caps.append(capInst(mp + R * F3(0, 0, -0.5), mp + R * F3(0, 0, 1.4), 1.35, 1.25, side: F3(1, 0, 0), part: .metal, seg: 0, leg: 0, hair: 0, seed: 2))
            let hub = mp + R * F3(0, 0, 1.75)
            p.blobs.append(blob(-1, makeTransform(R, hub, F3(0.7, 0.7, 0.35)), .metal, seed: 3, shadow: false))
            // 回転するプロペラの残像（半透明の円盤）
            let dir: Float = (i == 0 || i == 3) ? 1 : -1
            p.blobs.append(blob(1, makeTransform(R * rotZ(dir * spin + Float(i)), hub + R * F3(0, 0, 0.15)), .propBlur, seed: Float(i), shadow: false, alpha: true, extW: dir))
            // LED（前は白、後ろは赤く点滅）
            let ledP = mp + R * F3(0, 0, -0.75)
            p.blobs.append(blob(-1, makeTransform(R, ledP, F3(0.45, 0.45, 0.35)), .led, seed: i < 2 ? 0 : 1, shadow: false))
        }
        // ジンバルカメラ
        p.blobs.append(blob(-1, makeTransform(R, P + R * F3(8.3, 0, -1.7), F3(1.7, 1.9, 1.6)), .plastic, seed: 9))
        p.blobs.append(blob(-1, makeTransform(R, P + R * F3(9.75, 0, -1.8), F3(0.55, 0.95, 0.95)), .lens, seed: 9, shadow: false))
        p.ell = [F4(P.x, P.y, 9, 6), F4(yaw, z / sp.bodyZ, 0.05, 0), .zero, .zero]
        return p
    }
}
