import Foundation
import simd

// MARK: - 紙飛行機

struct PlaneSpec: CreatureDef {
    let shaderID: Int32 = 10
    let name = "紙飛行機"
    let basePtPerMM: Float = 1.7
    let bodyZ: Float = 3.0
    let hairSpacing: Float = 0.3
    var bodyLengthMM: Float { 30 }
    let flyZ: Float = 14
    let nose: Float = 15

    static let plane = PlaneSpec()

    var meshShapes: [(F3) -> F3] { [] }

    /// 折り目のある紙（翼2枚ずつ＋竜骨）。面ごとに法線を持たせて折り目をくっきり出す
    var customMeshes: [MeshData] {
        var v: [Float] = []
        var idx: [UInt32] = []
        func tri(_ a: F3, _ b: F3, _ c: F3, up: F3) {
            var n = simd_normalize(simd_cross(b - a, c - a))
            if simd_dot(n, up) < 0 { n = -n }
            let base = UInt32(v.count / 6)
            for p in [a, b, c] { v += [p.x, p.y, p.z, n.x, n.y, n.z] }
            idx += [base, base + 1, base + 2]
        }
        let N = F3(15, 0, 0.05), C = F3(-15, 0, 0.0)
        for s in [Float(1), -1] {
            let M = F3(-15, s * 4.6, 0.35), W = F3(-15, s * 11.2, 1.6)
            let Nk = F3(15, s * 0.12, -0.1), K = F3(-14.2, s * 0.15, -3.4), Ck = F3(-15, s * 0.12, -0.05)
            tri(N, C, M, up: F3(0, 0, 1))
            tri(N, M, W, up: F3(0, 0, 1))
            tri(Nk, K, Ck, up: F3(0, s, 0))
        }
        return [MeshData(verts: v, indices: idx)]
    }
    func makeBristles() -> [Bristle] { [] }
    func layerRadiusMM() -> Float { 16 + 12 + flyZ * 0.7 + 6 }
    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { PlaneSim(spec: self, ptPerMM: ptPerMM, seed: seed) }
}

final class PlaneSim: CreatureSim {
    let sp: PlaneSpec
    var time: Float = 0
    let ptPerMM: Float
    var f = Follower(towLen: 26)
    var events: [SimEvent] = []
    var bodyXY = F2.zero
    var z: Float = 3
    var flying: Float = 0
    var roll: Float = 0.28, pitch: Float = 0
    var leftDown = false
    var strikeT: Float = 10
    var strikeFired = true
    var webT: Float = 10
    var stillTime: Float { f.stillTime }
    var airborne: Bool { flying > 0.3 }
    var activeSilk: (F2, F3)? { nil }

    init(spec: PlaneSpec, ptPerMM: Float, seed: UInt64) {
        sp = spec
        self.ptPerMM = ptPerMM
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
        _ = f.update(dt: dt, cursor: cursor, ptPerMM: ptPerMM, turnAround: true, turnSpeed: 6)
        bodyXY = f.head - f.fwd * sp.nose
        // 動いている間は飛び、止まるとすーっと降りて画面に着地する
        let wantFly: Float = (f.speed > 10 || f.stillTime < 0.45 || strikeT < 0.6 || webT < 0.9) ? 1 : 0
        flying = damp(flying, wantFly, wantFly > flying ? 6 : 2.2, dt)
        let sN = sat(f.speed / 250)
        var zt = mixf(3.1, sp.flyZ + 1.5 * sin(time * 1.1), flying)
        if webT < 0.85 { zt += 13 * sin(.pi * webT / 0.85) }
        z = damp(z, zt, 4, dt)
        let flutter = flying * (0.035 * sin(time * 23) + 0.02 * sin(time * 37)) * (0.3 + sN)
        let bank = -clampf(f.yawRate * 0.30, -1.0, 1.0)
        roll = damp(roll, mixf(0.28, bank, flying) + flutter, 7, dt)
        pitch = damp(pitch, flying * (0.05 - 0.10 * sN) + flying * 0.5 * flutter, 5, dt)
        strikeT += dt
        webT += dt
        if !strikeFired && strikeT >= 0.02 {
            strikeFired = true
            events.append(.bite(f.head, false))
        }
    }

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        var rx: Float = 0, py: Float = 0
        if strikeT < 0.55 { let u = strikeT / 0.55; rx = 2 * .pi * u * u * (3 - 2 * u) }
        if webT < 0.85 { let u = webT / 0.85; py = 2 * .pi * u * u * (3 - 2 * u) }
        let R = rotZ(f.yaw) * pitchUp(pitch + py) * rollL(roll + rx)
        let P = F3(bodyXY.x, bodyXY.y, z)
        p.blobs.append(blob(0, makeTransform(R, P), .paper, ext: F3(15, 11, 3), seed: 1))
        p.ell = [F4(P.x, P.y, 13, 7), F4(f.yaw, z / sp.bodyZ, 0.10, 0), .zero, .zero]
        return p
    }
}

// MARK: - UFO

struct UFOSpec: CreatureDef {
    let shaderID: Int32 = 11
    let name = "UFO"
    let basePtPerMM: Float = 1.6
    let bodyZ: Float = 7.0
    let hairSpacing: Float = 0.3
    var bodyLengthMM: Float { 30 }
    let hoverZ: Float = 17
    let radius: Float = 15

    static let ufo = UFOSpec()

    var meshShapes: [(F3) -> F3] {
        [
            { d in                                   // 円盤：縁ほど薄いレンズ形
                var p = superEllipsoid(d, 15, 15, 2.7, 2.2, 2.0)
                let r = min(1, simd_length(F2(p.x, p.y)) / 15)
                p.z *= 1 - 0.55 * pow(r, 4)
                if p.z > 0 { p.z += 0.35 * exp(-pow((r - 0.62) / 0.05, 2)) + 0.25 * exp(-pow((r - 0.86) / 0.04, 2)) }
                return p
            },
            { d in superEllipsoid(d, 7.6, 7.6, 5.6, 0.3, 2.0) },           // ガラスのドーム
            { d in                                                          // 光の円錐（底面半径1・高さ1）
                let t = (d.z + 1) / 2
                let a = atan2(d.y, d.x)
                let rr = mixf(1.0, 0.16, t)
                return F3(rr * cos(a), rr * sin(a), t)
            },
            { d in superEllipsoid(d, 1, 1, 0.01, 0.01, 2.0) },             // 地面の光だまり
        ]
    }
    func makeBristles() -> [Bristle] { [] }
    func layerRadiusMM() -> Float { 24 + hoverZ * 0.6 }
    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { UFOSim(spec: self, ptPerMM: ptPerMM, seed: seed) }
}

final class UFOSim: CreatureSim {
    let sp: UFOSpec
    var time: Float = 0
    let ptPerMM: Float
    var f = Follower(towLen: 30)
    var events: [SimEvent] = []
    var bodyXY = F2.zero
    var spinYaw: Float = 0
    var tiltF = F2.zero
    var z: Float = 17
    var leftDown = false
    var press: Float = 0
    var strikeT: Float = 10
    var strikeFired = true
    var webT: Float = 10
    var webFired = true
    var beam: Float = 0
    var stillTime: Float { f.stillTime }
    var airborne: Bool { true }
    var activeSilk: (F2, F3)? { nil }

    init(spec: UFOSpec, ptPerMM: Float, seed: UInt64) {
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
    func rightClick() { webT = 0; webFired = false }

    func update(dt rawDt: Float, cursor: F2) {
        let dt = clampf(rawDt, 1.0 / 500, 1.0 / 20)
        time += dt
        _ = f.update(dt: dt, cursor: cursor, ptPerMM: ptPerMM, turnAround: false)
        bodyXY = f.head
        spinYaw += dt * 0.9
        tiltF = damp2(tiltF, F2(clampf(f.vel.x * 0.0028, -0.4, 0.4), clampf(f.vel.y * 0.0028, -0.4, 0.4)), 5, dt)
        press = damp(press, leftDown ? 1 : 0, 10, dt)
        strikeT += dt
        webT += dt
        var bt: Float = press * 0.35
        if strikeT < 1.0 { bt = max(bt, sstep(0, 0.08, strikeT) * (1 - sstep(0.7, 1.0, strikeT))) }
        beam = damp(beam, bt, 18, dt)
        if !strikeFired && strikeT >= 0.06 {
            strikeFired = true
            events.append(.beam(f.head, 13))
        }
        if !webFired && webT >= 0.16 {
            webFired = true
            events.append(.warp(f.head, 24))
        }
        z = damp(z, sp.hoverZ - press * 3 + 0.6 * sin(time * 1.6), 5, dt)
    }

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        // ワープ：縮んで消え、また現れる
        var sc: Float = 1, zUp: Float = 0
        if webT < 0.75 {
            if webT < 0.2 { let u = webT / 0.2; sc = 1 - u * u; zUp = 10 * u }
            else if webT < 0.42 { sc = 0 }
            else { let u = (webT - 0.42) / 0.33; sc = u * u * (3 - 2 * u); zUp = 10 * (1 - u) }
        }
        let wob = F2(0.07 * sin(time * 1.3), 0.07 * cos(time * 1.1))
        // 進む方向へ少し前のめり
        let tiltAxis = F3(-tiltF.y + wob.y, tiltF.x + wob.x, 0)
        let ta = simd_length(tiltAxis)
        let tilt: simd_float3x3 = ta > 1e-5 ? axisAngle(tiltAxis, ta) : matrix_identity_float3x3
        let R = tilt * rotZ(spinYaw)
        let P = F3(bodyXY.x, bodyXY.y, z + zUp)
        let S = F3(repeating: max(sc, 0.001))
        // 地面の光だまり（加算）と牽引ビーム
        let glowI = 0.35 + 0.65 * beam
        p.blobs.append(blob(3, makeTransform(matrix_identity_float3x3, F3(bodyXY.x, bodyXY.y, 0.05), F3(20, 20, 1) * max(sc, 0.001)), .glow, shadow: false, alpha: true, extW: glowI))
        if beam > 0.02 && sc > 0.05 {
            let h = P.z - 2.0
            p.blobs.append(blob(2, makeTransform(matrix_identity_float3x3, F3(bodyXY.x, bodyXY.y, 0.0), F3(6.5, 6.5, h)), .beam, shadow: false, alpha: true, extW: beam))
        }
        guard sc > 0.01 else { return p }
        p.blobs.append(blob(0, makeTransform(R, P, S), .saucer, ext: F3(15, 15, 2.7), seed: 1))
        // 中の宇宙人
        let aR = R * rotZ(-spinYaw + atan2(f.fwd.y, f.fwd.x))
        p.blobs.append(blob(-1, makeTransform(aR, P + R * (F3(0, 0, 3.2) * sc), F3(1.6, 1.5, 1.6) * sc), .alien, seed: 2, shadow: false))
        p.blobs.append(blob(-1, makeTransform(aR, P + R * (F3(0.2, 0, 5.6) * sc) , F3(2.5, 2.3, 2.6) * sc), .alien, seed: 3, shadow: false))
        for s in [Float(1), -1] {
            let e = makeTransform(aR * rotZ(s * 0.35) * rollL(s * 0.35), P + aR * (F3(2.05, s * 1.0, 6.0) * sc), F3(0.8, 0.45, 1.0) * sc)
            p.blobs.append(blob(-1, e, .lens, seed: 4, shadow: false))
        }
        // 縁のライト（色が回る）
        let n = 14
        var halos: [BlobPose] = []
        for k in 0..<n {
            let a = Float(k) / Float(n) * 2 * .pi
            let lp = P + R * (F3(cos(a) * 13.7, sin(a) * 13.7, 0.55) * sc)
            let phase = 0.5 + 0.5 * sin(time * 6 - Float(k) * 0.9)
            p.blobs.append(blob(-1, makeTransform(R, lp, F3(0.85, 0.85, 0.6) * sc), .rimLight, seed: Float(k % 3), shadow: false, extW: phase))
            halos.append(blob(3, makeTransform(matrix_identity_float3x3, lp + F3(0, 0, 0.6), F3(2.6, 2.6, 1) * sc), .glow, seed: 10 + Float(k % 3), shadow: false, alpha: true, extW: phase))
        }
        // ガラスのドーム（半透明・最後に描く）
        p.blobs.append(blob(1, makeTransform(R, P + R * (F3(0, 0, 1.9) * sc), S), .glass, ext: F3(7.6, 7.6, 5.6), seed: 5, shadow: true, alpha: true))
        p.blobs += halos
        p.ell = [F4(P.x, P.y, 15 * sc, 15 * sc), F4(0, P.z / sp.bodyZ, 0.04, 0), .zero, .zero]
        return p
    }
}
