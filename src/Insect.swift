import Foundation
import simd

/// 昆虫の脚（左側。右は y を反転）。単位は mm
struct InsectLeg {
    var seg: [Float]        // 基節, 転節, 腿節, 脛節, 跗節
    var root: F3            // 胸の中心（中脚の付け根あたり）から見た付け根
    var restAngle: Float
    var restReach: Float
    var radius: Float
    var ankle: Float
    var total: Float { seg.reduce(0, +) }
    /// クモ用の7節IKにのせるための並べ替え（脛節の付け根を短い節にして膝を作る）
    var chainSeg: [Float] { [seg[0], seg[1], seg[2], seg[3] * 0.12, seg[3] * 0.88, seg[4] * 0.42, seg[4] * 0.58] }
}

/// 昆虫の設計図
struct InsectSpec: CreatureDef {
    enum Kind { case cockroach, ant, ladybug }
    let id: Int32
    let name: String
    let kind: Kind
    let basePtPerMM: Float
    let head: F3, headPos: F3          // 大きさ (長さ, 幅, 高さ) と中心位置
    let thorax: F3, thoraxPos: F3      // ゴキブリ・テントウムシは前胸背板、アリは中胸
    let abdomen: F3, abdomenPos: F3
    let wing: F3, wingPos: F3          // 前翅（左）。大きさ 0 = なし
    let membrane: F3                   // 後翅
    let petiole: F3, petiolePos: F3    // アリの腹柄
    let bodyZ: Float
    let legs: [InsectLeg]
    let antLen: Float, antSegs: Int, antRadius: Float, antBase: F3, antScape: Float, antSpread: Float
    let palpLen: Float, palpRadius: Float, palpBase: F3
    let cercusLen: Float, cercusBase: F3
    let mandible: F3, mandiblePos: F3  // (長さ, 太さ, 0)
    let eye: F3, eyePos: F3, eyeRadius: Float
    let hairBody: Float, hairLeg: Float, hairSpacing: Float
    let walkMaxSpeed: Float, stepDur: Float
    let flySpeed: Float                // これを超える速さで飛ぶ（0 = 飛ばない）

    var shaderID: Int32 { id }
    var bodyLengthMM: Float { bodyLength }
    var bodyLength: Float { (headPos.x + head.x / 2) - min(abdomenPos.x - abdomen.x / 2, wing.x > 0 ? wingPos.x - wing.x / 2 : 0) }
    var front: Float { headPos.x + head.x / 2 + (mandible.x > 0 ? mandible.x * 0.7 : 0) }

    // MARK: 形
    var meshShapes: [(F3) -> F3] {
        let s = self
        return [{ s.headPoint($0) }, { s.thoraxPoint($0) }, { s.abdomenPoint($0) }, { s.wingPoint($0) }, { s.membranePoint($0) }]
    }

    func headPoint(_ d: F3) -> F3 {
        let a = head.x / 2, b = head.y / 2, c = head.z / 2
        switch kind {
        case .ant:
            // 後ろが張ったハート形
            let widen = 1 + 0.12 * sstep(-0.2, -1, d.x)
            return superEllipsoid(d, a, b * widen, c, c * 0.8, 2.4)
        default:
            return superEllipsoid(d, a, b, c, c, 2.2)
        }
    }
    func thoraxPoint(_ d: F3) -> F3 {
        let a = thorax.x / 2, b = thorax.y / 2
        switch kind {
        case .cockroach:
            // 前胸背板：前が丸い平たい盾
            var p = superEllipsoid(d, a, b, thorax.z, thorax.z * 0.35, 2.3)
            p.z += 0.25 * thorax.z * (1 - (p.y / b) * (p.y / b))
            return p
        case .ant:
            // 中胸：前（前胸）が高く、くびれて、後ろ（前伸腹節）は下がる
            let x = d.x
            var p = superEllipsoid(d, a, b, thorax.z * 0.55, thorax.z * 0.45, 2.2)
            let pinch = 1 - 0.22 * exp(-pow((x - 0.05) / 0.35, 2))
            p.y *= pinch
            if p.z > 0 { p.z *= 0.75 + 0.35 * sstep(-0.8, 0.6, x) }
            return p
        case .ladybug:
            return superEllipsoid(d, a, b, thorax.z, thorax.z * 0.4, 2.6)
        }
    }
    func abdomenPoint(_ d: F3) -> F3 {
        let a = abdomen.x / 2, b = abdomen.y / 2, c = abdomen.z / 2
        switch kind {
        case .ant: return superEllipsoid(d, a, b, c, c, 2.0)
        default:
            let taper = 1 - 0.25 * sstep(0, 1, -d.x)
            return superEllipsoid(d, a, b * taper, c, c * 0.6, 2.2)
        }
    }
    func wingPoint(_ d: F3) -> F3 {
        guard wing.x > 0 else { return d * 0.01 }
        let a = wing.x / 2, b = wing.y / 2
        switch kind {
        case .ladybug:
            // 前翅（鞘翅）：半球ドームの右半分（原点は左右の合わせ目）
            var p = superEllipsoid(d, a, wing.y, wing.z, wing.z * 0.10, 2.15)
            p.y = abs(p.y)
            return p
        default:
            // ゴキブリの前翅：細長い楕円の板、外側は体に沿って下へ回り込む
            var p = superEllipsoid(d, a, b, wing.z, wing.z * 0.25, 2.0)
            let yy = p.y / b
            p.z -= wing.z * 0.7 * yy * yy * yy * yy
            p.z += wing.z * 0.5 * (1 - (p.x / a) * (p.x / a))
            return p
        }
    }
    func membranePoint(_ d: F3) -> F3 {
        // 後翅：とても薄い膜（原点は付け根、+x へ伸びる）
        let a = membrane.x / 2, b = membrane.y / 2
        let p = superEllipsoid(d, a, b, max(membrane.z, 0.01), max(membrane.z, 0.01), 2.0)
        return F3(p.x + a, p.y, p.z)
    }

    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { InsectSim(spec: self, ptPerMM: ptPerMM, seed: seed) }

    func layerRadiusMM() -> Float {
        var r: Float = 0
        for l in legs { r = max(r, simd_length(F2(l.root.x, l.root.y)) + l.total * 0.95) }
        r = max(r, antBase.x + antLen * 0.95)
        r = max(r, abs(abdomenPos.x) + abdomen.x * 0.6 + cercusLen)
        if wing.x > 0 { r = max(r, abs(wingPos.x) + wing.x * 0.6) }
        if flySpeed > 0 { r = max(r, membrane.x + thorax.y) }
        let fly: Float = flySpeed > 0 ? bodyLength * 0.5 * 0.6 + 2 : 0
        return r + bodyZ * 2.4 + fly
    }

    static let legProfile: [(Float, Float)] = [(1.45, 1.30), (1.10, 1.0), (1.0, 0.85), (0.70, 0.66), (0.66, 0.52), (0.40, 0.34), (0.34, 0.24)]

    /// chain 0..5 = 脚 / blob 0 = 頭, 1 = 胸, 2 = 腹
    func makeBristles() -> [Bristle] {
        var r = SplitMix(seed: UInt64(91 + id))
        var list: [Bristle] = []
        for leg in 0..<6 {
            let l = legs[leg / 2]
            let pair = leg / 2
            for seg in 2...6 {
                let rad = l.radius * InsectSpec.legProfile[seg].0
                var n = 0
                var kind: Float = 0
                var lenK: ClosedRange<Float> = 1...2
                var w: Float = 0.12
                switch kind_ {
                case .cockroach:
                    // ゴキブリの脛は太い棘だらけ
                    if seg == 4 { n = 7 + pair * 3; lenK = 2.6...4.4; w = 0.16 }
                    else if seg == 2 { n = 3; lenK = 1.2...2.2; w = 0.12 }
                    else if seg >= 5 { n = 2; lenK = 0.8...1.4; w = 0.1 }
                    kind = 0
                case .ant:
                    n = seg >= 4 ? 5 : 3; lenK = 1.5...3.0; w = 0.06; kind = 1
                case .ladybug:
                    n = 2; lenK = 1...2; w = 0.06; kind = 1
                }
                for _ in 0..<n {
                    let phi: Float = kind_ == .cockroach ? (r.f() < 0.7 ? .pi + r.range(-1.3, 1.3) : r.range(-1.4, 1.4)) : r.range(0, 2 * .pi)
                    list.append(Bristle(chain: leg, seg: seg, t: r.range(0.12, 0.95), phi: phi, len: rad * r.range(lenK.lowerBound, lenK.upperBound),
                                        tilt: r.range(0.5, 0.9), width: rad * w, kind: kind))
                }
            }
        }
        if kind_ == .ant {
            // 腹部（ガスター）と頭の細かい毛
            let s = self
            for (bi, count) in [(2, 70), (0, 25), (1, 20)] {
                for _ in 0..<count {
                    let d = simd_normalize(F3(r.range(-1, 1), r.range(-1, 1), r.range(-0.1, 1.0)))
                    let shape: (F3) -> F3 = bi == 2 ? { s.abdomenPoint($0) } : (bi == 0 ? { s.headPoint($0) } : { s.thoraxPoint($0) })
                    let p = shape(d)
                    let n = surfaceNormal(d, shape)
                    let dir = simd_normalize(n * 0.7 + F3(-0.6, 0, 0) + F3(r.range(-0.2, 0.2), r.range(-0.2, 0.2), 0))
                    list.append(Bristle(blob: bi, len: r.range(0.15, 0.32), width: 0.012, kind: bi == 2 ? 5 : 1, pos: p, dir: dir))
                }
            }
        }
        return list
    }
    private var kind_: Kind { kind }

    // MARK: - 種

    // クロゴキブリ：つやのある黒褐色、長い触角、棘だらけの脚。速く振ると飛ぶ
    static let cockroach = InsectSpec(
        id: 4, name: "クロゴキブリ", kind: .cockroach, basePtPerMM: 1.55,
        head: F3(3.2, 3.9, 2.6), headPos: F3(6.4, 0, -0.5),
        thorax: F3(7.5, 9.6, 1.3), thoraxPos: F3(2.6, 0, 0.9),
        abdomen: F3(17, 9.2, 2.6), abdomenPos: F3(-8.0, 0, 0.0),
        wing: F3(22.5, 6.9, 0.8), wingPos: F3(-7.6, 1.75, 1.35),
        membrane: F3(19, 8.5, 0.04),
        petiole: .zero, petiolePos: .zero,
        bodyZ: 2.2,
        legs: [
            InsectLeg(seg: [2.8, 0.7, 4.6, 4.4, 4.2], root: F3(2.3, 1.2, -0.9), restAngle: 36, restReach: 10.0, radius: 0.40, ankle: 16),
            InsectLeg(seg: [3.2, 0.8, 5.8, 6.4, 5.2], root: F3(0.0, 1.7, -0.9), restAngle: 86, restReach: 13.0, radius: 0.46, ankle: 14),
            InsectLeg(seg: [4.2, 1.0, 7.8, 9.6, 7.2], root: F3(-2.5, 1.9, -0.9), restAngle: 140, restReach: 17.0, radius: 0.52, ankle: 12),
        ],
        antLen: 31, antSegs: 24, antRadius: 0.20, antBase: F3(7.3, 1.15, 0.0), antScape: 0, antSpread: 26,
        palpLen: 2.6, palpRadius: 0.17, palpBase: F3(7.4, 0.7, -1.4),
        cercusLen: 3.4, cercusBase: F3(-16.4, 0.9, 0.1),
        mandible: .zero, mandiblePos: .zero,
        eye: F3(0.55, 0.45, 1.1), eyePos: F3(6.6, 1.62, -0.1), eyeRadius: 1.0,
        hairBody: 0, hairLeg: 0.05, hairSpacing: 0.12,
        walkMaxSpeed: 420, stepDur: 0.055, flySpeed: 900
    )

    // クロオオアリ（働きアリ）：黒、くの字の触角、大あご、腹柄でくびれた体
    static let ant = InsectSpec(
        id: 5, name: "クロオオアリ", kind: .ant, basePtPerMM: 4.6,
        head: F3(2.6, 2.5, 1.45), headPos: F3(3.15, 0, 0.35),
        thorax: F3(3.4, 1.35, 1.45), thoraxPos: F3(0.1, 0, 0.25),
        abdomen: F3(3.9, 3.0, 2.4), abdomenPos: F3(-4.2, 0, 0.35),
        wing: .zero, wingPos: .zero,
        membrane: .zero,
        petiole: F3(0.5, 0.9, 1.0), petiolePos: F3(-2.05, 0, 0.3),
        bodyZ: 1.45,
        legs: [
            InsectLeg(seg: [0.75, 0.25, 2.0, 1.8, 2.0], root: F3(0.95, 0.42, -0.45), restAngle: 42, restReach: 4.3, radius: 0.13, ankle: 22),
            InsectLeg(seg: [0.65, 0.25, 2.3, 2.1, 2.3], root: F3(0.05, 0.52, -0.45), restAngle: 92, restReach: 5.0, radius: 0.12, ankle: 20),
            InsectLeg(seg: [0.75, 0.30, 2.9, 2.8, 2.9], root: F3(-0.75, 0.55, -0.45), restAngle: 138, restReach: 6.0, radius: 0.12, ankle: 18),
        ],
        antLen: 5.1, antSegs: 12, antRadius: 0.085, antBase: F3(4.0, 0.55, 0.45), antScape: 2.2, antSpread: 62,
        palpLen: 0.8, palpRadius: 0.04, palpBase: F3(4.3, 0.3, -0.2),
        cercusLen: 0, cercusBase: .zero,
        mandible: F3(1.0, 0.17, 0), mandiblePos: F3(4.3, 0.34, 0.05),
        eye: F3(1.15, 0.85, 0.9), eyePos: F3(3.35, 1.16, 0.55), eyeRadius: 0.33,
        hairBody: 0.06, hairLeg: 0.03, hairSpacing: 0.03,
        walkMaxSpeed: 200, stepDur: 0.05, flySpeed: 0
    )

    // ナナホシテントウ：赤い鞘翅に7つの黒紋、白い紋のある黒い前胸。速く振ると翅を開いて飛ぶ
    static let ladybug = InsectSpec(
        id: 6, name: "ナナホシテントウ", kind: .ladybug, basePtPerMM: 6.5,
        head: F3(1.0, 1.75, 0.9), headPos: F3(2.85, 0, -0.05),
        thorax: F3(1.6, 3.9, 1.25), thoraxPos: F3(1.85, 0, 0.35),
        abdomen: F3(4.4, 4.4, 0.9), abdomenPos: F3(-0.9, 0, -0.25),
        wing: F3(5.6, 2.6, 2.7), wingPos: F3(-0.85, 0, 0.05),
        membrane: F3(7.5, 3.4, 0.03),
        petiole: .zero, petiolePos: .zero,
        bodyZ: 0.8,
        legs: [
            InsectLeg(seg: [0.45, 0.15, 1.05, 0.95, 0.75], root: F3(0.85, 0.75, -0.3), restAngle: 48, restReach: 2.1, radius: 0.12, ankle: 25),
            InsectLeg(seg: [0.45, 0.15, 1.10, 1.00, 0.80], root: F3(0.05, 0.95, -0.3), restAngle: 92, restReach: 2.3, radius: 0.12, ankle: 25),
            InsectLeg(seg: [0.50, 0.15, 1.25, 1.15, 0.85], root: F3(-0.75, 0.95, -0.3), restAngle: 132, restReach: 2.5, radius: 0.12, ankle: 25),
        ],
        antLen: 1.25, antSegs: 7, antRadius: 0.045, antBase: F3(3.1, 0.55, 0.0), antScape: 0, antSpread: 40,
        palpLen: 0.4, palpRadius: 0.05, palpBase: F3(3.2, 0.3, -0.35),
        cercusLen: 0, cercusBase: .zero,
        mandible: .zero, mandiblePos: .zero,
        eye: F3(0.9, 0.7, 1.0), eyePos: F3(2.95, 0.7, 0.05), eyeRadius: 0.28,
        hairBody: 0, hairLeg: 0, hairSpacing: 0.05,
        walkMaxSpeed: 28, stepDur: 0.07, flySpeed: 40
    )
}

// MARK: - 昆虫の動き

final class InsectSim: CreatureSim {
    let sp: InsectSpec
    var rng: SplitMix
    var time: Float = 0
    var ptPerMM: Float

    var head = F2.zero, headVel = F2.zero, speed: Float = 0
    var yaw: Float = .pi / 2
    var tail = F2.zero
    let towLen: Float
    let headToBody: Float
    var backAccum: Float = 0
    var turning = false
    var yawRate: Float = 0
    var stillTime: Float = 10
    var initialized = false

    var bodyXY = F2.zero
    var bodyPos = F3.zero
    var bodyVel = F2.zero
    var bodyAcc = F2.zero
    var bodyRot = matrix_identity_float3x3
    var pitch: Float = 0, roll: Float = 0, zNow: Float = 0, bob: Float = 0
    var abdYaw: Float = 0, abdPitch: Float = 0
    var lunge: Float = 0

    var leftDown = false
    var press: Float = 0
    var strikeT: Float = 10
    var strikeFired = true
    var webT: Float = 10
    var webFired = true
    var airborne = false
    var flyZ: Float = 0
    var airW: Float = 0
    var fastTimer: Float = 0, slowTimer: Float = 0
    var wingOpen: Float = 0
    var flapPhase: Float = 0
    var mandOpen: Float = 0

    var idleTimer: Float = 1.0
    var idleKind = -1
    var idleT: Float = 0, idleDur: Float = 0
    var twitchLeft: Float = 0, twitchRate: Float = 0
    var rest: Float = 0
    var antPhase: [Float] = [0, 2.1]
    var tapT: [Float] = [0, 0]

    var events: [SimEvent] = []
    var legs: [LegState]
    var antYaw: [[Float]]
    var antElev: [[Float]]
    var antJoints: [[F3]] = [[], []]
    var palpJoints: [[F3]] = [[], []]
    var palpSide: [F3] = [F3(0, 1, 0), F3(0, -1, 0)]
    var cercusJoints: [[F3]] = [[], []]
    var activeSilk: (F2, F3)? { nil }

    init(spec: InsectSpec, ptPerMM: Float, seed: UInt64) {
        sp = spec
        self.ptPerMM = ptPerMM
        rng = SplitMix(seed: seed)
        towLen = spec.bodyLength * 0.9
        headToBody = spec.front
        legs = [LegState](repeating: LegState(), count: 6)
        antYaw = [[Float]](repeating: [Float](repeating: 0, count: spec.antSegs), count: 2)
        antElev = antYaw
    }

    @inline(__always) func sideSign(_ i: Int) -> Float { i % 2 == 0 ? 1 : -1 }
    func rootBody(_ i: Int) -> F3 { let r = sp.legs[i / 2].root; return F3(r.x, r.y * sideSign(i), r.z) }
    func restBody(_ i: Int) -> F2 {
        let l = sp.legs[i / 2]
        let a = l.restAngle * .pi / 180
        let r = rootBody(i)
        return F2(r.x, r.y) + F2(cos(a), sin(a) * sideSign(i)) * l.restReach * (1 - 0.05 * rest)
    }
    func restWorld(_ i: Int) -> F2 { bodyXY + rot2(restBody(i) + legs[i].idleOffset, yaw) }

    func reset(at p: F2) {
        head = p
        headVel = .zero
        let f = F2(cos(yaw), sin(yaw))
        tail = head - f * towLen
        bodyXY = head - f * headToBody
        zNow = sp.bodyZ
        airborne = false
        flyZ = 0
        for i in 0..<6 {
            legs[i].idleOffset = .zero
            let r = restWorld(i)
            legs[i].foot = F3(r.x, r.y, 0)
            legs[i].planted = true
        }
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            for j in 0..<sp.antSegs { antYaw[k][j] = yaw + s * sp.antSpread * .pi / 180; antElev[k][j] = 0 }
        }
        initialized = true
    }

    func mouseDown() { leftDown = true }
    func mouseUp(strike: Bool) {
        leftDown = false
        guard strike else { return }
        strikeT = 0
        strikeFired = false
        idleKind = -1
    }
    func rightClick() {
        webT = 0
        webFired = false
        idleKind = -1
    }

    // MARK: 更新

    func update(dt rawDt: Float, cursor: F2) {
        let dt = clampf(rawDt, 1.0 / 500, 1.0 / 20)
        time += dt
        if !initialized { reset(at: cursor) }
        let delta = cursor - head
        let moved = simd_length(delta)
        if moved * ptPerMM > 700 { reset(at: cursor); return }
        head = cursor
        headVel = damp2(headVel, delta / dt, 28, dt)
        speed = simd_length(headVel)
        if speed > 2.5 { stillTime = 0 } else { stillTime += dt }

        updateFlight(dt: dt)
        updateFacing(dt: dt, moved: moved)
        updateActions(dt: dt)
        updateIdle(dt: dt)

        let fwd = F2(cos(yaw), sin(yaw))
        let newBodyXY = head + fwd * (lunge * sp.bodyLength * 0.06) - fwd * headToBody
        let v = (newBodyXY - bodyXY) / dt
        let pv = bodyVel
        bodyVel = damp2(bodyVel, v, 30, dt)
        bodyAcc = damp2(bodyAcc, (bodyVel - pv) / dt, 12, dt)
        bodyXY = newBodyXY

        updateBody(dt: dt)
        updateLegs(dt: dt)
        updateAntennae(dt: dt)
        updateSmallParts(dt: dt)
    }

    func updateFlight(dt: Float) {
        guard sp.flySpeed > 0 else { return }
        if speed > sp.flySpeed { fastTimer += dt; slowTimer = 0 } else { slowTimer += dt; fastTimer = 0 }
        if !airborne && fastTimer > 0.04 && !leftDown { airborne = true }
        if airborne && (slowTimer > 0.16 || leftDown) { airborne = false }
        let target: Float = airborne ? sp.bodyLength * 0.45 : 0
        flyZ = damp(flyZ, target, airborne ? (flyZ < target * 0.3 ? 5 : 9) : 11, dt)
        if !airborne && flyZ < 0.02 * sp.bodyLength && flyZ > 0 {
            // 着地：脚を置き直す
            for i in 0..<6 where !legs[i].planted || simd_length(xy(legs[i].foot) - restWorld(i)) > sp.legs[i / 2].restReach * 0.4 {
                let r = restWorld(i)
                legs[i].foot = F3(r.x, r.y, 0)
                legs[i].planted = true
            }
        }
    }

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
        if backAccum > sp.bodyLength * 0.5 && speed > 4 { turning = true }
        if (airborne || flyZ > 0.1 * sp.bodyLength) && speed > 5 {
            let target = atan2(headVel.y, headVel.x)
            yaw += wrapPi(target - yaw) * (1 - exp(-14 * dt))
            tail = head - F2(cos(yaw), sin(yaw)) * towLen
            turning = false
            backAccum = 0
        } else if turning {
            let target = atan2(headVel.y, headVel.x)
            let diff = wrapPi(target - yaw)
            let maxStep: Float = 15 * dt
            yaw += clampf(diff, -maxStep, maxStep)
            tail = head - F2(cos(yaw), sin(yaw)) * towLen
            if abs(diff) < 0.25 || speed < 2 { turning = false; backAccum = 0 }
        } else {
            tail = head - dir * towLen
            yaw = atan2(dir.y, dir.x)
        }
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
        var l: Float = 0
        if s < 0.34 {
            if s < 0.05 { l = sstep(0, 1, s / 0.05) } else if s < 0.12 { l = 1 } else { l = 1 - sstep(0, 1, (s - 0.12) / 0.22) }
            if !strikeFired && s >= 0.045 {
                strikeFired = true
                events.append(.bite(head, sp.kind != .cockroach))
            }
        }
        lunge = l
        webT += dt
        if !webFired && webT >= 0.12 {
            webFired = true
            if sp.kind == .ant {
                let f = F2(cos(yaw), sin(yaw))
                events.append(.spray(head + f * sp.bodyLength * 0.15, f))
            }
        }
        // 翅：飛行中・右クリックで全開、クリックの瞬間に小さくはためく
        var wo: Float = airborne || flyZ > 0.15 * sp.bodyLength ? 1 : 0
        if sp.wing.x > 0 {
            if webT < 0.75 { wo = max(wo, sin(.pi * min(webT / 0.75, 1)) * 1.6) }
            if s < 0.3 { wo = max(wo, sin(.pi * s / 0.3) * 0.35) }
            wo = max(wo, press * (sp.kind == .ladybug ? 0.18 : 0.08))
        }
        wingOpen = damp(wingOpen, min(wo, 1), wo > wingOpen ? 22 : 12, dt)
        flapPhase += dt * 2 * .pi * (sp.kind == .ladybug ? 31 : 23)
        // 大あご（アリ）：押すと開き、離すと閉じて噛む
        let mo: Float = max(press, s < 0.05 ? 1 : 0)
        mandOpen = damp(mandOpen, mo, mo > mandOpen ? 30 : 24, dt)
    }

    func updateIdle(dt: Float) {
        let calm = stillTime > 0.6 && !airborne && press < 0.05 && strikeT > 0.5 && webT > 0.8
        rest = damp(rest, stillTime > 18 ? 1 : 0, stillTime > 18 ? 0.8 : 6, dt)
        if idleKind >= 0 {
            idleT += dt
            if idleT >= idleDur { idleKind = -1 }
        }
        guard calm else { idleTimer = max(idleTimer, 0.6); return }
        idleTimer -= dt
        if idleTimer <= 0 && idleKind < 0 {
            idleTimer = rng.range(0.8, 2.8)
            idleT = 0
            let r = rng.f()
            if r < 0.35 {
                idleKind = 1; idleDur = 0.1
                twitchLeft = 0.07
                twitchRate = rng.range(0.10, 0.35) * rng.sign() / 0.07
            } else if r < 0.65 {
                idleKind = 2; idleDur = 0.2
                for _ in 0..<(1 + Int(rng.f() * 2.5)) {
                    let i = Int(rng.f() * 6) % 6
                    legs[i].idleOffset = F2(rng.range(-0.15, 0.15), rng.range(-0.15, 0.15)) * sp.legs[i / 2].restReach
                }
            } else {
                idleKind = 3; idleDur = rng.range(0.6, 1.2)     // 触角を大きく振る・地面をたたく
                tapT = [0, 0]
            }
        }
    }

    func updateBody(dt: Float) {
        let bz = sp.bodyZ
        var zt = bz * (1 - 0.18 * rest)
        zt += press * 0.25 * bz
        zt -= lunge * 0.15 * bz
        var swinging: Float = 0
        for l in legs where !l.planted { swinging += 1 }
        bob = damp(bob, -swinging * 0.015 * bz, 25, dt)
        zNow = damp(zNow, zt, 20, dt)
        let z = zNow + bob + flyZ
        var pt: Float = press * 0.10 - lunge * 0.08
        if flyZ > 0.05 * sp.bodyLength { pt += 0.22 * sat(flyZ / (0.3 * sp.bodyLength)) }
        pitch = damp(pitch, pt, 16, dt)
        let left = F2(-sin(yaw), cos(yaw))
        let lat = simd_dot(bodyAcc, left)
        roll = damp(roll, clampf(-lat * 0.00025, -0.12, 0.12) + fbm1(time * 0.4, 5) * 0.012, 12, dt)
        bodyRot = rotZ(yaw) * pitchUp(pitch) * rollL(roll)
        bodyPos = F3(bodyXY.x, bodyXY.y, z)

        // 腹：アリは威嚇で持ち上げ、右クリックで前へ曲げて蟻酸を吹く
        var ap: Float = 0
        var ay: Float = clampf(-yawRate * 0.02, -0.25, 0.25)
        if sp.kind == .ant {
            ap = press * 0.35
            let w = webT < 0.6 ? sin(.pi * webT / 0.6) : 0
            ap -= w * 0.9
            ay += fbm1(time * 0.6, 19) * 0.06
        }
        abdPitch = damp(abdPitch, ap, 14, dt)
        abdYaw = damp(abdYaw, ay, 10, dt)
    }

    func neighbors(_ i: Int) -> [Int] {
        let pair = i / 2, side = i % 2
        var n = [pair * 2 + (1 - side)]
        if pair > 0 { n.append((pair - 1) * 2 + side) }
        if pair < 2 { n.append((pair + 1) * 2 + side) }
        return n
    }

    func stepTarget(_ i: Int, settling: Bool) -> F2 {
        let r = restWorld(i)
        if settling { return r }
        let rel = r - bodyXY
        let vr = bodyVel + F2(-rel.y, rel.x) * yawRate
        let thr = sp.legs[i / 2].restReach * 0.26
        var lead = vr * (legs[i].dur * 1.05)
        let ll = simd_length(lead)
        if ll > thr * 0.95 { lead *= thr * 0.95 / ll }
        return r + lead
    }

    func updateLegs(dt: Float) {
        let sNorm = sat(speed / sp.walkMaxSpeed)
        let settling = stillTime > 0.10
        let yawM = rotZ(yaw)
        let flying = flyZ > 0.08 * sp.bodyLength

        if flying {
            for i in 0..<6 {
                let r = restWorld(i)
                legs[i].foot = F3(r.x, r.y, 0)
                legs[i].planted = true
            }
        } else {
            var swingCount = 0
            for i in 0..<6 where !legs[i].planted {
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
            var cand: [(Int, Float)] = []
            for i in 0..<6 where legs[i].planted {
                let reach = sp.legs[i / 2].restReach
                let thr = settling ? reach * 0.07 : reach * (0.28 - 0.08 * sNorm)
                var err = simd_length(xy(legs[i].foot) - restWorld(i))
                if legs[i].idleOffset != .zero { err = max(err, thr * 1.01) }
                let root = bodyPos + bodyRot * rootBody(i)
                let far = simd_length(xy(legs[i].foot) - xy(root)) > (sp.legs[i / 2].total - sp.legs[i / 2].seg[0]) * 0.95
                if err > thr || far { cand.append((i, far ? 1e6 : err / thr)) }
            }
            cand.sort { $0.1 > $1.1 }
            for (i, score) in cand {
                if swingCount >= 3 { break }
                let blocked = neighbors(i).contains { !legs[$0].planted }
                if blocked && score < 2.2 { continue }
                if settling && swingCount >= 1 { break }
                var L = legs[i]
                L.planted = false
                L.t = 0
                L.from = L.foot
                let lt = sp.legs[i / 2].total
                if settling {
                    L.dur = sp.stepDur * 1.5
                    L.lift = lt * 0.05
                } else {
                    L.dur = sp.stepDur * mixf(1.0, 0.55, sNorm)
                    L.lift = lt * (0.06 + 0.05 * sNorm)
                }
                legs[i] = L
                swingCount += 1
            }
        }

        let aw: Float = flying ? sat(flyZ / (0.2 * sp.bodyLength)) : 0
        airW = damp(airW, aw, 20, dt)
        for i in 0..<6 {
            let l = sp.legs[i / 2]
            let s = sideSign(i)
            let Lt = l.total
            let root = bodyPos + bodyRot * rootBody(i)
            var foot = legs[i].foot
            if airW > 0.001 {
                // 飛んでいる間：脚は下へぶら下げ、少し縮める
                let r = rootBody(i)
                let pair = Float(i / 2)
                let ap = F3(r.x + (0.25 - 0.35 * pair) * Lt, s * (r.y + 0.32 * Lt), -0.45 * Lt)
                foot = mix3(foot, bodyPos + yawM * ap, airW)
            }
            // 威嚇：前脚を少し持ち上げる（アリ・ゴキブリ）
            if i < 2 && press > 0.01 && sp.kind != .ladybug {
                let r = rootBody(i)
                let up = bodyPos + yawM * F3(r.x + 0.55 * Lt, s * (r.y + 0.30 * Lt), -0.1 * Lt + 0.05 * Lt * sin(time * 8))
                foot = mix3(foot, up, sstep(0, 1, press) * (sp.kind == .ant ? 0.8 : 0.35))
            }
            let fallback = rot2(simd_normalize(restBody(i) - F2(rootBody(i).x, rootBody(i).y)), yaw)
            var dl = xy(foot - root)
            dl = simd_length(dl) > 1e-4 ? simd_normalize(dl) : fallback
            var perp = F2(-dl.y, dl.x)
            let bodyLat = rot2(F2(0, s), yaw)
            if simd_dot(perp, bodyLat) < 0 { perp = -perp }
            let tilt = 0.30 * abs(simd_dot(perp, bodyLat)) + 0.08
            let (j, side) = SpiderSim.solveLeg(root: root, foot: foot, seg: l.chainSeg, ankleDeg: l.ankle, fallbackDir: fallback,
                                               lateral: F3(perp.x, perp.y, 0), tilt: tilt)
            legs[i].joints = j
            legs[i].side = side
            legs[i].contact = legs[i].planted && airW < 0.5 && foot.z < 0.05 ? 1 : max(0, 1 - foot.z / (0.1 * Lt))
        }
    }

    /// 触角：根元は首振り、先へいくほど遅れてついてくる鞭のような動き
    func updateAntennae(dt: Float) {
        let n = sp.antSegs
        let funLen = sp.antLen - sp.antScape
        let funSegs = sp.antScape > 0 ? n - 1 : n
        let segLen = funLen / Float(max(funSegs, 1))
        let alert = press
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            antPhase[k] += dt * (0.9 + 0.6 * fbm1(time * 0.3 + Float(k) * 3, 70 + Int32(k)))
            let idleBoost: Float = idleKind == 3 ? 1.8 : 1
            var sweep = (0.30 * sin(antPhase[k] * 2 * .pi * 0.7) + 0.22 * fbm1(time * 1.7 + Float(k) * 9, 80 + Int32(k))) * idleBoost
            sweep *= (1 - 0.6 * alert)
            let spread = sp.antSpread * .pi / 180 * (1 - 0.45 * alert)
            var base = bodyPos + bodyRot * F3(sp.antBase.x, sp.antBase.y * s, sp.antBase.z)
            var joints: [F3] = [base]
            var prevYaw = yaw + s * (spread + sweep * (sp.antScape > 0 ? 0.5 : 1))
            var elevBase: Float = 0.30 + 0.35 * alert + 0.08 * sin(antPhase[k] * 3.1)
            var startIdx = 0
            if sp.antScape > 0 {
                // アリ：柄節（くの字の根元）は外側・上向き
                let sy = prevYaw
                let se: Float = 0.55 + 0.2 * alert
                let p = base + F3(cos(se) * cos(sy), cos(se) * sin(sy), sin(se)) * sp.antScape
                antYaw[k][0] = sy
                joints.append(p)
                base = p
                prevYaw = yaw + s * (0.15 + sweep * 0.8)  // 鞭節は前へ折れ曲がる
                elevBase = -0.35 + 0.5 * alert
                startIdx = 1
                // ときどき地面をたたく
                if idleKind == 3 || speed > 5 { tapT[k] += dt * (6 + Float(k)) }
            }
            var p = base
            for j in startIdx..<n {
                let idx = Float(j - startIdx)
                let curv = s * (sp.kind == .cockroach ? 0.035 : 0.05) + 0.03 * fbm1(time * 2.3 + Float(j) * 0.7 + Float(k) * 5, 90)
                let target = j == startIdx ? prevYaw : antYaw[k][j - 1] + curv
                let rate: Float = 70 / (1 + idx * 0.45)
                antYaw[k][j] += wrapPi(target - antYaw[k][j]) * (1 - exp(-rate * dt))
                var el = elevBase - idx / Float(max(funSegs, 1)) * (sp.kind == .cockroach ? 0.55 : 0.4)
                if sp.antScape > 0 { el -= 0.25 * max(0, sin(tapT[k])) * idx / Float(funSegs) }
                antElev[k][j] = damp(antElev[k][j], el, 30 / (1 + idx * 0.3), dt)
                var e = antElev[k][j]
                let dz = sin(e) * segLen
                if p.z + dz < 0.05 { e = asin(clampf((0.05 - p.z) / segLen, -1, 1)) }
                let y = antYaw[k][j]
                p += F3(cos(e) * cos(y), cos(e) * sin(y), sin(e)) * segLen
                joints.append(p)
            }
            antJoints[k] = joints
        }
    }

    func updateSmallParts(dt: Float) {
        // 小あごひげ（口元でせわしなく動く）
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            let L = sp.palpLen
            guard L > 0 else { continue }
            let root = bodyPos + bodyRot * F3(sp.palpBase.x, sp.palpBase.y * s, sp.palpBase.z)
            let wig = 0.5 + 0.5 * sin(time * 2 * .pi * (2.2 + Float(k) * 0.4) + Float(k) * 1.3)
            let tip = bodyPos + bodyRot * F3(sp.palpBase.x + L * 0.75, sp.palpBase.y * s * 1.5, -sp.bodyZ + 0.1 * L + wig * 0.25 * L)
            let segs: [Float] = [0.01, 0.01, L * 0.35, L * 0.05, L * 0.25, L * 0.18, L * 0.16]
            let (j, side) = SpiderSim.solveLeg(root: root, foot: tip, seg: segs, ankleDeg: 50, fallbackDir: F2(cos(yaw), sin(yaw)))
            palpJoints[k] = j
            palpSide[k] = side
        }
        // 尾角（ゴキブリ）
        if sp.cercusLen > 0 {
            let ab = abdomenFrame()
            for k in 0..<2 {
                let s: Float = k == 0 ? 1 : -1
                let base = ab.p + ab.r * F3(sp.cercusBase.x - sp.abdomenPos.x, sp.cercusBase.y * s, sp.cercusBase.z - sp.abdomenPos.z)
                var pts = [base]
                let a0 = s * (0.45 + 0.08 * sin(time * 1.3 + Float(k)))
                for j in 1...4 {
                    let a = a0 * (1 - 0.1 * Float(j))
                    let d = ab.r * simd_normalize(F3(-cos(a), sin(a), -0.05 * Float(j)))
                    pts.append(pts[j - 1] + d * sp.cercusLen / 4)
                }
                cercusJoints[k] = pts
            }
        }
    }

    /// 腹部の座標（付け根で曲がる）
    func abdomenFrame() -> (p: F3, r: simd_float3x3) {
        let pivotL = F3(sp.abdomenPos.x + sp.abdomen.x * 0.5, 0, sp.abdomenPos.z)
        let r = bodyRot * rotZ(abdYaw) * pitchUp(abdPitch)
        let pivot = bodyPos + bodyRot * pivotL
        let center = pivot + r * F3(-sp.abdomen.x * 0.5, 0, 0)
        return (center, r)
    }

    // MARK: 姿勢 → 描画

    func pose() -> RenderPose {
        var p = RenderPose()
        p.time = time
        let R = bodyRot, P = bodyPos
        let headM = makeTransform(R, P + R * sp.headPos)
        let thoraxM = makeTransform(R, P + R * sp.thoraxPos)
        let ab = abdomenFrame()
        let abdM = makeTransform(ab.r, ab.p)
        p.blobs.append(blob(0, headM, .head, hair: sp.kind == .ant ? sp.hairBody : 0, ext: sp.head * 0.5, seed: 1, shells: sp.kind == .ant))
        p.blobs.append(blob(1, thoraxM, .thorax, hair: sp.kind == .ant ? sp.hairBody : 0, ext: sp.thorax * 0.5, seed: 2, shells: sp.kind == .ant))
        p.blobs.append(blob(2, abdM, .belly, hair: sp.kind == .ant ? sp.hairBody * 1.3 : 0, ext: sp.abdomen * 0.5, seed: 3, shells: sp.kind == .ant))
        if sp.kind == .ant {
            let pm = makeTransform(R * pitchUp(0.15), P + R * sp.petiolePos, sp.petiole * 0.5)
            p.blobs.append(blob(-1, pm, .petiole, seed: 4))
        }
        // 前翅（鞘翅）と後翅
        if sp.wing.x > 0 {
            let o = wingOpen
            for k in 0..<2 {
                let s: Float = k == 0 ? 1 : -1
                let wp = F3(sp.wingPos.x, sp.wingPos.y * s, sp.wingPos.z - (sp.kind == .cockroach && k == 1 ? 0.15 : 0))
                let hinge = F3(sp.wingPos.x + sp.wing.x * 0.45, sp.kind == .ladybug ? 0 : sp.wingPos.y * s * 0.4, sp.wingPos.z)
                let ro: simd_float3x3
                if sp.kind == .ladybug {
                    ro = rotZ(s * 0.35 * o) * pitchUp(0.45 * o) * rollL(s * 1.25 * o)
                } else {
                    ro = rotZ(s * 0.55 * o) * pitchUp(0.18 * o) * rollL(s * 0.95 * o)
                }
                let rot = R * ro
                let m = makeTransform(rot, P + R * hinge + rot * (wp - hinge), F3(1, s, 1))
                p.blobs.append(blob(3, m, .wing, ext: F3(sp.wing.x / 2, sp.wing.y, sp.wing.z), seed: 6 + Float(k)))
            }
            if o > 0.08 && sp.membrane.x > 0 {
                let u = sat((o - 0.15) / 0.6)
                let flying = airborne || flyZ > 0.1 * sp.bodyLength || webT < 0.7
                for k in 0..<2 {
                    let s: Float = k == 0 ? 1 : -1
                    let flap: Float = flying ? 0.75 * sin(flapPhase + Float(k) * 0.2) - 0.1 : 0.1
                    let yawW = s * mixf(2.9, 1.85, u)
                    let rot = R * rollL(s * flap) * rotZ(yawW)
                    let root = F3(sp.thoraxPos.x - sp.thorax.x * 0.35, sp.thorax.y * 0.22 * s, sp.thoraxPos.z + 0.2)
                    let m = makeTransform(rot, P + R * root, F3(mixf(0.45, 1, u), 1, 1))
                    var b = blob(4, m, .membrane, seed: 8 + Float(k), shadow: true)
                    b.alpha = true
                    p.blobs.append(b)
                }
            }
        }
        // 複眼
        for k in 0..<2 {
            let s: Float = k == 0 ? 1 : -1
            let m = makeTransform(R, P + R * F3(sp.eyePos.x, sp.eyePos.y * s, sp.eyePos.z), sp.eye * sp.eyeRadius)
            p.blobs.append(blob(-1, m, .ceye, seed: 9, shadow: false))
        }
        // 脚
        for i in 0..<6 {
            let r = sp.legs[i / 2].radius
            p.chains.append(ChainPose(joints: legs[i].joints, radii: InsectSpec.legProfile.map { ($0.0 * r, $0.1 * r) },
                                      side: legs[i].side, part: .leg, limb: i, hair: sp.hairLeg, hairy: sp.hairLeg > 0))
        }
        // 触角
        for k in 0..<2 {
            let j = antJoints[k]
            guard j.count > 1 else { continue }
            var radii: [(Float, Float)] = []
            let n = j.count - 1
            for q in 0..<n {
                let t0 = Float(q) / Float(n), t1 = Float(q + 1) / Float(n)
                var r0 = sp.antRadius * (1 - 0.6 * t0), r1 = sp.antRadius * (1 - 0.6 * t1)
                if sp.kind == .ladybug && q >= n - 2 { r0 *= 2.2; r1 *= 2.2 }       // 先が棍棒状
                if sp.kind == .ant && q == 0 { r0 *= 0.9; r1 *= 1.1 }
                radii.append((r0, r1))
            }
            p.chains.append(ChainPose(joints: j, radii: radii, side: F3(0, 0, 1), part: .antenna, limb: k, hair: 0, hairy: false))
        }
        for k in 0..<2 where palpJoints[k].count == 8 {
            let r = sp.palpRadius
            p.chains.append(ChainPose(joints: palpJoints[k], radii: [(r, r), (r, r), (r, r * 0.9), (r * 0.9, r * 0.9), (r * 0.9, r * 0.85), (r * 0.85, r * 0.8), (r * 0.8, r * 0.6)],
                                      side: palpSide[k], part: .palp, limb: 8 + k, hair: 0, hairy: false))
        }
        if sp.cercusLen > 0 {
            for k in 0..<2 where cercusJoints[k].count > 1 {
                let r: Float = 0.30
                p.chains.append(ChainPose(joints: cercusJoints[k], radii: [(r, r * 0.85), (r * 0.85, r * 0.65), (r * 0.65, r * 0.45), (r * 0.45, r * 0.2)],
                                          side: F3(0, 0, 1), part: .cercus, limb: k, hair: 0, hairy: false))
            }
        }
        // 大あご（アリ）
        if sp.mandible.x > 0 {
            for k in 0..<2 {
                let s: Float = k == 0 ? 1 : -1
                let base = P + R * F3(sp.mandiblePos.x, sp.mandiblePos.y * s, sp.mandiblePos.z)
                let open = mandOpen
                let a0 = s * (0.15 + 0.75 * open)
                let d1 = R * F3(cos(a0), sin(a0) * 1, -0.15)
                let mid = base + simd_normalize(d1) * sp.mandible.x * 0.55
                let a1 = a0 - s * 1.15
                let tip = mid + simd_normalize(R * F3(cos(a1), sin(a1), -0.1)) * sp.mandible.x * 0.55
                let w = sp.mandible.y
                p.chains.append(ChainPose(joints: [base, mid, tip], radii: [(w, w * 0.9), (w * 0.9, w * 0.25)], side: F3(0, 0, 1),
                                          part: .mandible, limb: k, hair: 0, hairy: false))
            }
        }
        for i in 0..<6 {
            let f = legs[i].joints[7]
            p.feet.append(F4(f.x, f.y, legs[i].contact, sp.legs[i / 2].radius * 1.4))
        }
        let bz = sp.bodyZ
        let tc = P + R * sp.thoraxPos
        let coverX = sp.wing.x > 0 ? max(sp.abdomen.x, sp.wing.x) : sp.abdomen.x
        let coverY = sp.kind == .ladybug ? sp.wing.y * 2 : max(sp.abdomen.y, sp.wing.y * 1.6)
        let ac = sp.wing.x > 0 && sp.kind == .ladybug ? P + R * sp.wingPos : ab.p
        p.ell = [F4(tc.x, tc.y, sp.thorax.x * 0.7, sp.thorax.y * 0.6),
                 F4(yaw, max(0, tc.z - sp.thorax.z * 0.4) / bz, 0.28, 0),
                 F4(ac.x, ac.y, coverX * 0.52, coverY * 0.52),
                 F4(yaw + abdYaw, max(0, ac.z - sp.abdomen.z * 0.4) / bz, 0.32, 0)]
        return p
    }
}
