import Foundation
import simd

/// 脚1本ぶん（左側の値。右側は y を反転して使う）。単位は mm
struct LegSpec {
    var seg: [Float]        // 基節, 転節, 腿節, 膝節, 脛節, 蹠節, 跗節
    var root: F3            // 頭胸部中心から見た基節の付け根
    var restAngle: Float    // 休止時の足先の向き（前方 +x からの角度, 度）
    var restReach: Float    // 付け根→足先の水平距離
    var radius: Float       // 腿節の太さ（半径）
    var ankle: Float        // 蹠節の地面からの立ち上がり角（度）
    var total: Float { seg.reduce(0, +) }
}

struct EyeSpec {
    var dir: F3             // 頭胸部の物体座標での方向（表面に貼り付ける）
    var radius: Float
    var kind: Int32         // 0: 前中眼(大) 1: その他
}

/// クモの設計図
struct Species: CreatureDef {
    enum Style { case salticid, huntsman, orbweaver, tarantula }
    let id: Int32
    let name: String
    let style: Style
    let basePtPerMM: Float
    let carapace: F3        // 全長, 全幅, 上面の高さ（中心から）
    let carapaceBottom: Float
    let frontLift: Float    // 前方（眼域）がどれだけ高いか 0..1
    let boxiness: Float     // 超楕円の指数
    let abdomen: F3         // 全長, 全幅, 全高
    let abdomenBox: Float   // 腹部の角ばり（2 = 楕円体）
    let bodyZ: Float        // 頭胸部中心の地面からの高さ
    let legs: [LegSpec]     // 第1〜第4脚
    let palpSeg: [Float]    // 腿節, 膝節, 脛節, 跗節(シンビウム)
    let palpRadius: Float
    let palpTip: F3         // 触肢先端の休止位置（左, 頭胸部中心から）
    let chelicera: F3       // 長さ, 幅, 厚み
    let eyes: [EyeSpec]
    let hairBody: Float     // 体毛の長さ
    let hairLeg: Float
    let hairSpacing: Float
    let jumper: Bool        // ハエトリグモ（跳ぶ）
    let walkMaxSpeed: Float // ハエトリはこれを超えると跳ぶ (mm/s)
    let stepDur: Float      // 1歩の基本時間 (s)

    var bodyLength: Float { carapace.x + abdomen.x }
    var shaderID: Int32 { id }
    var bodyLengthMM: Float { bodyLength }

    /// 頭胸部の表面形状（方向 d → 物体座標の点）
    func carapacePoint(_ d: F3) -> F3 {
        let a = carapace.x / 2, b = carapace.y / 2
        let front = sstep(-0.55, 0.45, d.x)
        let cTop = carapace.z * (1 - frontLift + frontLift * front)
        let c = d.z >= 0 ? cTop : carapaceBottom
        // 前端は少しすぼまる（頭部が細い）
        let pinch = 1 - (style == .tarantula ? 0.04 : 0.10) * sstep(0.2, 1.0, d.x)
        let n = boxiness
        let s = pow(abs(d.x / a), n) + pow(abs(d.y / (b * pinch)), n) + pow(abs(d.z / c), n)
        return d * pow(s, -1 / n)
    }

    /// 腹部の表面形状
    func abdomenPoint(_ d: F3) -> F3 {
        let a = abdomen.x / 2, b = abdomen.y / 2
        var c = abdomen.z / 2
        if d.z < 0 { c *= 0.82 }
        // 後ろへ向かって少し細る卵形（ジョロウグモは前が広い円筒）
        let taper = 1 - (style == .orbweaver ? 0.12 : 0.20) * sstep(-0.1, 1.0, -d.x)
        let bt = b * taper, ct = c * (0.85 + 0.15 * taper)
        let n = abdomenBox
        let s = pow(abs(d.x / a), n) + pow(abs(d.y / bt), n) + pow(abs(d.z / ct), n)
        return d * pow(s, -1 / n)
    }

    var meshShapes: [(F3) -> F3] {
        let s = self
        return [{ s.carapacePoint($0) }, { s.abdomenPoint($0) }]
    }

    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim { SpiderSim(species: self, ptPerMM: ptPerMM, seed: seed) }

    func layerRadiusMM() -> Float {
        var legR: Float = 0
        for l in legs { legR = max(legR, simd_length(F2(l.root.x, l.root.y)) + l.total * 0.92) }
        let back = carapace.x * 0.5 + abdomen.x * 1.08
        let shadowMargin = bodyZ * 2.4 + (jumper ? bodyLength * 0.9 * 0.6 : 0)
        return max(legR, back) + shadowMargin
    }

    static let legRadiusProfile: [(Float, Float)] = [(1.25, 1.15), (1.05, 1.0), (1.0, 0.88), (0.86, 0.80), (0.80, 0.66), (0.58, 0.46), (0.44, 0.28)]
    static let palpRadiusProfile: [(Float, Float)] = [(0.9, 0.9), (0.9, 0.9), (0.9, 0.85), (0.85, 0.85), (0.85, 0.95), (1.25, 1.35), (1.35, 0.55)]

    /// 剛毛（棘・細毛・眼の上の長い毛など）の配置。chain 0..7 = 脚, 8..9 = 触肢 / blob 0 = 頭胸部, 1 = 腹部
    func makeBristles() -> [Bristle] {
        var r = SplitMix(seed: UInt64(77 + id))
        var list: [Bristle] = []
        let jumper = style == .salticid
        for leg in 0..<8 {
            let spec = legs[leg / 2]
            for seg in 2...6 {
                let rad = spec.radius * Species.legRadiusProfile[seg].0
                var nSp = 0
                switch style {
                case .salticid:
                    if seg == 4 || seg == 5 { nSp = leg / 2 == 0 ? 3 : 2 }
                    if seg == 2 { nSp = 1 }
                case .huntsman:
                    if seg == 2 { nSp = 4 } else if seg == 4 { nSp = 5 } else if seg == 5 { nSp = 4 } else if seg == 3 { nSp = 1 }
                case .orbweaver:
                    if seg == 2 { nSp = 3 } else if seg == 4 { nSp = 4 } else if seg == 5 { nSp = 3 }
                case .tarantula:
                    nSp = 0
                }
                for _ in 0..<nSp {
                    let ventral = r.f() < (jumper ? 0.7 : 0.45)
                    let phi: Float = ventral ? .pi + r.range(-1.1, 1.1) : r.range(-1.3, 1.3)
                    let len = rad * (jumper ? r.range(1.6, 2.6) : r.range(2.4, 4.6))
                    list.append(Bristle(chain: leg, seg: seg, t: r.range(0.15, 0.9), phi: phi, len: len, tilt: r.range(0.55, 0.95),
                                        width: rad * (jumper ? 0.16 : 0.10), kind: 0))
                }
                // 細い毛（タランチュラは長い毛がびっしり）
                let nHair: Int
                let kindHair: () -> Float
                switch style {
                case .salticid: nHair = 7; kindHair = { r.f() < 0.25 ? 2 : 1 }
                case .huntsman: nHair = 10; kindHair = { 3 }
                case .orbweaver: nHair = 6; kindHair = { 1 }
                case .tarantula: nHair = 26; kindHair = { (seg == 3 || seg == 4) && r.f() < 0.5 ? 4 : (r.f() < 0.3 ? 3 : 1) }
                }
                for _ in 0..<nHair {
                    let phi = r.range(0, 2 * .pi)
                    let len = rad * (style == .tarantula ? r.range(0.8, 1.6) : (jumper ? r.range(0.9, 1.8) : r.range(1.2, 2.4)))
                    list.append(Bristle(chain: leg, seg: seg, t: r.range(0.05, 0.95), phi: phi, len: len, tilt: r.range(0.9, 1.25),
                                        width: rad * (style == .tarantula ? 0.035 : 0.07), kind: kindHair()))
                }
            }
        }
        // 触肢
        for k in 0..<2 {
            for seg in 2...6 {
                let rad = palpRadius * Species.palpRadiusProfile[seg].0
                let n = jumper ? (seg == 3 || seg == 4 ? 22 : 8) : (style == .tarantula ? 18 : 6)
                for _ in 0..<n {
                    let kind: Float = jumper ? ((seg >= 3 && seg <= 5) ? 2 : 1) : (style == .tarantula ? 1 : 3)
                    list.append(Bristle(chain: 8 + k, seg: seg, t: r.range(0.0, 1.0), phi: r.range(-2.2, 2.2), len: rad * r.range(1.2, 2.4),
                                        tilt: r.range(0.6, 1.2), width: rad * 0.08, kind: kind))
                }
            }
        }
        // 頭胸部
        let cs = self
        let nCara = jumper ? 34 : (style == .tarantula ? 60 : 24)
        for i in 0..<nCara {
            var d: F3
            var kind: Float = 0
            var len: Float
            if jumper && i < 12 {
                d = simd_normalize(F3(1.0, r.range(-0.75, 0.75), r.range(0.55, 0.9)))
                len = r.range(0.30, 0.48)
            } else {
                d = simd_normalize(F3(r.range(-1, 1), r.range(-1, 1), r.range(0.2, 1.0)))
                switch style {
                case .salticid: len = r.range(0.12, 0.26); kind = r.f() < 0.5 ? 1 : 0
                case .huntsman: len = r.range(0.6, 1.2); kind = 3
                case .orbweaver: len = r.range(0.4, 0.8); kind = 2
                case .tarantula: len = r.range(1.5, 3.0); kind = r.f() < 0.5 ? 3 : 1
                }
            }
            let p = cs.carapacePoint(d)
            let n = surfaceNormal(d) { cs.carapacePoint($0) }
            let fwd: F3 = (jumper && i < 12) ? F3(1, 0, 0.3) : F3(-1, 0, 0)
            let dir = simd_normalize(n * 0.55 + fwd * 0.8 + F3(r.range(-0.2, 0.2), r.range(-0.2, 0.2), 0))
            list.append(Bristle(blob: 0, len: len, width: jumper ? 0.016 : (style == .tarantula ? 0.06 : 0.03), kind: kind, pos: p, dir: dir))
        }
        let nAbd = jumper ? 40 : (style == .tarantula ? 150 : (style == .orbweaver ? 12 : 50))
        for _ in 0..<nAbd {
            let d = simd_normalize(F3(r.range(-1, 1), r.range(-1, 1), r.range(-0.1, 1.0)))
            let p = cs.abdomenPoint(d)
            let n = surfaceNormal(d) { cs.abdomenPoint($0) }
            let dir = simd_normalize(n * 0.5 + F3(-1, 0, 0) * 0.85 + F3(r.range(-0.25, 0.25), r.range(-0.25, 0.25), 0))
            var kind: Float
            var len: Float
            switch style {
            case .salticid: kind = r.f() < 0.6 ? 0 : 1; len = r.range(0.16, 0.34)
            case .huntsman: kind = 3; len = r.range(0.5, 1.1)
            case .orbweaver: kind = 1; len = r.range(0.3, 0.7)
            case .tarantula: kind = r.f() < 0.6 ? 4 : 1; len = r.range(2.5, 5.0)
            }
            list.append(Bristle(blob: 1, len: len, width: jumper ? 0.014 : (style == .tarantula ? 0.07 : 0.03), kind: kind, pos: p, dir: dir))
        }
        return list
    }

    // MARK: - 種

    // アダンソンハエトリ（オス）: ほぼ黒・眼域を囲む白いU字・白い触肢・腹部に白い襟と白斑
    static let hasarius: Species = {
        let p: [Float] = [0.10, 0.06, 0.28, 0.14, 0.18, 0.14, 0.10]
        func leg(_ total: Float, _ root: F3, _ ang: Float, _ reach: Float, _ r: Float) -> LegSpec {
            LegSpec(seg: p.map { $0 * total }, root: root, restAngle: ang, restReach: reach, radius: r, ankle: 48)
        }
        return Species(
            id: 0, name: "アダンソンハエトリ", style: .salticid,
            basePtPerMM: 7.0,
            carapace: F3(2.9, 2.3, 0.95), carapaceBottom: 0.42, frontLift: 0.42, boxiness: 2.7,
            abdomen: F3(3.1, 2.15, 1.7), abdomenBox: 2,
            bodyZ: 1.30,
            legs: [
                leg(4.9, F3(0.80, 0.50, -0.30), 30, 2.80, 0.21),
                leg(3.9, F3(0.32, 0.68, -0.30), 70, 2.55, 0.165),
                leg(4.8, F3(-0.20, 0.70, -0.30), 114, 2.95, 0.17),
                leg(4.6, F3(-0.68, 0.55, -0.30), 152, 2.90, 0.165),
            ],
            palpSeg: [0.55, 0.28, 0.32, 0.42], palpRadius: 0.13,
            palpTip: F3(1.95, 0.42, -1.05),
            chelicera: F3(0.85, 0.40, 0.42),
            eyes: [
                EyeSpec(dir: simd_normalize(F3(1.0, 0.34, 0.30)), radius: 0.34, kind: 0),
                EyeSpec(dir: simd_normalize(F3(0.82, 0.80, 0.55)), radius: 0.16, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.30, 0.86, 0.80)), radius: 0.055, kind: 1),
                EyeSpec(dir: simd_normalize(F3(-0.12, 0.78, 0.92)), radius: 0.14, kind: 1),
            ],
            hairBody: 0.13, hairLeg: 0.075, hairSpacing: 0.045,
            jumper: true, walkMaxSpeed: 48, stepDur: 0.085
        )
    }()

    // アシダカグモ（オス）: 平たい茶色の体・クリーム色の頭楯と縁取り・長い脚に黒点と棘
    static let heteropoda: Species = {
        let p: [Float] = [0.07, 0.04, 0.27, 0.10, 0.23, 0.20, 0.09]
        func leg(_ total: Float, _ root: F3, _ ang: Float, _ reach: Float, _ r: Float) -> LegSpec {
            LegSpec(seg: p.map { $0 * total }, root: root, restAngle: ang, restReach: reach, radius: r, ankle: 28)
        }
        return Species(
            id: 1, name: "アシダカグモ", style: .huntsman,
            basePtPerMM: 1.55,
            carapace: F3(10.0, 9.4, 2.3), carapaceBottom: 1.5, frontLift: 0.15, boxiness: 2.2,
            abdomen: F3(10.5, 6.6, 3.8), abdomenBox: 2,
            bodyZ: 3.6,
            legs: [
                leg(38, F3(2.5, 3.4, -0.8), 42, 21.5, 0.62),
                leg(42, F3(0.9, 4.2, -0.8), 74, 24.0, 0.62),
                leg(32, F3(-0.9, 4.2, -0.8), 106, 18.5, 0.56),
                leg(35, F3(-2.5, 3.5, -0.8), 142, 20.0, 0.56),
            ],
            palpSeg: [2.4, 1.1, 1.4, 1.5], palpRadius: 0.42,
            palpTip: F3(8.5, 1.9, -3.3),
            chelicera: F3(3.0, 1.55, 1.6),
            eyes: [
                EyeSpec(dir: simd_normalize(F3(1.0, 0.20, 0.55)), radius: 0.36, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.92, 0.46, 0.42)), radius: 0.42, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.80, 0.20, 0.90)), radius: 0.30, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.70, 0.52, 0.80)), radius: 0.36, kind: 1),
            ],
            hairBody: 0.22, hairLeg: 0.16, hairSpacing: 0.09,
            jumper: false, walkMaxSpeed: 400, stepDur: 0.075
        )
    }()

    // ジョロウグモ（メス）: 銀色の頭胸部、黄色と青黒の縞の細長い腹、黄色い輪のある長い黒い脚
    static let joro: Species = {
        let p: [Float] = [0.05, 0.03, 0.29, 0.08, 0.24, 0.23, 0.08]
        func leg(_ total: Float, _ root: F3, _ ang: Float, _ reach: Float, _ r: Float) -> LegSpec {
            LegSpec(seg: p.map { $0 * total }, root: root, restAngle: ang, restReach: reach, radius: r, ankle: 32)
        }
        return Species(
            id: 2, name: "ジョロウグモ", style: .orbweaver,
            basePtPerMM: 1.25,
            carapace: F3(8.0, 6.2, 2.2), carapaceBottom: 1.3, frontLift: 0.35, boxiness: 2.2,
            abdomen: F3(18.0, 7.4, 6.4), abdomenBox: 2.35,
            bodyZ: 4.6,
            legs: [
                leg(56, F3(2.6, 2.1, -0.7), 26, 33, 0.40),
                leg(50, F3(1.0, 2.7, -0.7), 56, 30, 0.37),
                leg(28, F3(-0.8, 2.7, -0.7), 102, 16, 0.32),
                leg(46, F3(-2.4, 2.1, -0.7), 150, 28, 0.36),
            ],
            palpSeg: [2.0, 0.8, 1.0, 1.4], palpRadius: 0.30,
            palpTip: F3(7.0, 1.5, -3.8),
            chelicera: F3(2.6, 1.3, 1.4),
            eyes: [
                EyeSpec(dir: simd_normalize(F3(1.0, 0.16, 0.75)), radius: 0.30, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.95, 0.42, 0.40)), radius: 0.26, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.80, 0.14, 0.95)), radius: 0.28, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.78, 0.50, 0.55)), radius: 0.24, kind: 1),
            ],
            hairBody: 0.12, hairLeg: 0.08, hairSpacing: 0.08,
            jumper: false, walkMaxSpeed: 260, stepDur: 0.09
        )
    }()

    // メキシカンレッドニー・タランチュラ: 黒い毛深い体、オレンジ色の膝、甲の縁は淡い橙
    static let tarantula: Species = {
        let p: [Float] = [0.11, 0.06, 0.26, 0.14, 0.18, 0.15, 0.10]
        func leg(_ total: Float, _ root: F3, _ ang: Float, _ reach: Float, _ r: Float) -> LegSpec {
            LegSpec(seg: p.map { $0 * total }, root: root, restAngle: ang, restReach: reach, radius: r, ankle: 40)
        }
        return Species(
            id: 3, name: "タランチュラ（メキシカンレッドニー）", style: .tarantula,
            basePtPerMM: 0.95,
            carapace: F3(24.0, 22.0, 5.0), carapaceBottom: 3.2, frontLift: 0.10, boxiness: 2.1,
            abdomen: F3(28.0, 21.0, 17.0), abdomenBox: 2,
            bodyZ: 9.0,
            legs: [
                leg(64, F3(7.0, 7.8, -2.0), 36, 38, 2.1),
                leg(58, F3(2.4, 9.8, -2.0), 70, 35, 2.0),
                leg(54, F3(-2.6, 9.8, -2.0), 108, 32, 1.95),
                leg(70, F3(-7.0, 7.6, -2.0), 146, 41, 2.05),
            ],
            palpSeg: [11.0, 5.5, 8.0, 6.5], palpRadius: 1.8,
            palpTip: F3(30.0, 8.0, -8.2),
            chelicera: F3(10.0, 5.2, 6.0),
            eyes: [
                EyeSpec(dir: simd_normalize(F3(0.55, 0.06, 1.0)), radius: 0.55, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.56, 0.12, 1.0)), radius: 0.45, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.48, 0.08, 1.0)), radius: 0.40, kind: 1),
                EyeSpec(dir: simd_normalize(F3(0.50, 0.14, 1.0)), radius: 0.40, kind: 1),
            ],
            hairBody: 1.3, hairLeg: 1.1, hairSpacing: 0.32,
            jumper: false, walkMaxSpeed: 160, stepDur: 0.13
        )
    }()
}
