import Foundation
import simd

// MARK: - 描画に渡す「いまの姿勢」（クモでも昆虫でも共通）

enum Part: Float {
    case cara = 0, abdo = 1, chel = 2, eyeBig = 3, eye = 4, leg = 5, palp = 6, fang = 7, spin = 8
    case head = 9, thorax = 10, wing = 11, antenna = 12, cercus = 13, mandible = 14, membrane = 15, petiole = 16, belly = 17, ceye = 18
    // 恐竜
    case skin = 19, jaw = 20, tooth = 21, claw = 22, reptEye = 23
    // 乗り物・もの
    case hull = 24, tread = 25, turret = 26, barrel = 27, metal = 28, propBlur = 29, plastic = 30, led = 31, lens = 32
    case paper = 33, saucer = 34, glass = 35, alien = 36, rimLight = 37, beam = 38, glow = 39, flash = 40
}

/// 形状関数では作れない角ばった形（紙飛行機など）
struct MeshData {
    var verts: [Float]     // x,y,z, nx,ny,nz の繰り返し
    var indices: [UInt32]
}

/// 関節の列（脚・触肢・触角など）。joints[k]→joints[k+1] が1節
struct ChainPose {
    var joints: [F3]
    var radii: [(Float, Float)]
    var side: F3
    var part: Part
    var limb: Int          // 脚の番号（模様の切り替え用）
    var hair: Float        // 毛の長さ (mm)
    var hairy: Bool
    var segOffset: Int = 0 // シェーダに渡す節番号のずれ
}

struct BlobPose {
    var mesh: Int          // 生き物の形状メッシュ番号（-1 = 単位球）
    var model: simd_float4x4
    var part: Part
    var hair: Float = 0
    var ext: F3 = F3(1, 1, 1)
    var seed: Float = 0
    var shadow: Bool = true
    var shells: Bool = false
    var alpha: Bool = false   // 半透明（後翅・プロペラの残像・光など）
    var extW: Float = 0       // 部位ごとの追加パラメータ（キャタピラの送り・ライトの位相など）
}

struct RenderPose {
    var blobs: [BlobPose] = []
    var chains: [ChainPose] = []
    var caps: [CapInst] = []       // 毛のない小さな部品（牙・糸疣など）
    var feet: [F4] = []            // 足先の接地影 (x, y, 接地, 半径)
    var ell: [F4] = [.zero, .zero, .zero, .zero]
    var time: Float = 0
}

/// 剛毛：chain（関節列）か blob（胴体）のどちらかに生える
struct Bristle {
    var chain = -1
    var blob = -1
    var seg = 0
    var t: Float = 0
    var phi: Float = 0       // 0 = 背側
    var len: Float = 0
    var tilt: Float = 0      // 先端方向への傾き
    var width: Float = 0
    var kind: Float = 0      // 0 黒い棘 1 茶の細毛 2 白い毛 3 淡褐色 4 赤褐色の長毛 5 金色の短毛
    var pos = F3.zero        // 胴体用：物体座標の根元
    var dir = F3.zero        // 胴体用：物体座標の向き
}

/// 動きの中身（クモ・昆虫それぞれが実装）
protocol CreatureSim: AnyObject {
    var events: [SimEvent] { get set }
    var leftDown: Bool { get }
    var stillTime: Float { get }
    var airborne: Bool { get }
    var strikeT: Float { get }
    var webT: Float { get }
    var bodyXY: F2 { get }
    var activeSilk: (F2, F3)? { get }
    func update(dt: Float, cursor: F2)
    func mouseDown()
    func mouseUp(strike: Bool)
    func rightClick()
    func pose() -> RenderPose
}

/// 生き物の種類（見た目と動きの設計図）
protocol CreatureDef {
    var shaderID: Int32 { get }
    var name: String { get }
    var basePtPerMM: Float { get }
    var bodyZ: Float { get }
    var bodyLengthMM: Float { get }
    var hairSpacing: Float { get }
    var meshShapes: [(F3) -> F3] { get }
    var customMeshes: [MeshData] { get }
    func makeBristles() -> [Bristle]
    func layerRadiusMM() -> Float
    func makeSim(ptPerMM: Float, seed: UInt64) -> CreatureSim
}

extension CreatureDef {
    var customMeshes: [MeshData] { [] }
}

enum Creatures {
    /// ⌘⌥D で順に切り替わる
    static let all: [CreatureDef] = [
        Species.hasarius, Species.heteropoda, Species.joro, Species.tarantula,
        InsectSpec.cockroach, InsectSpec.ant, InsectSpec.ladybug,
        DinoSpec.trex, TankSpec.tank, DroneSpec.drone, PlaneSpec.plane, UFOSpec.ufo,
    ]
}

/// 形状関数の表面法線（数値微分）
func surfaceNormal(_ d: F3, _ shape: (F3) -> F3) -> F3 {
    var t1 = simd_cross(d, F3(0, 0, 1))
    if simd_length(t1) < 1e-3 { t1 = simd_cross(d, F3(1, 0, 0)) }
    t1 = simd_normalize(t1)
    let t2 = simd_cross(d, t1)
    let e: Float = 0.003
    let pu = shape(simd_normalize(d + t1 * e)) - shape(simd_normalize(d - t1 * e))
    let pv = shape(simd_normalize(d + t2 * e)) - shape(simd_normalize(d - t2 * e))
    var n = simd_normalize(simd_cross(pu, pv))
    if simd_dot(n, shape(d)) < 0 { n = -n }
    return n
}

/// 超楕円体（指数 n で角ばり具合）
func superEllipsoid(_ d: F3, _ a: Float, _ b: Float, _ cTop: Float, _ cBot: Float, _ n: Float) -> F3 {
    let c = d.z >= 0 ? cTop : cBot
    let s = pow(abs(d.x / a), n) + pow(abs(d.y / b), n) + pow(abs(d.z / c), n)
    return d * pow(s, -1 / n)
}

/// 楕円体の表面に眼などを貼り付けるための変換
func surfaceAttach(_ shape: (F3) -> F3, dir: F3, radius: Float, inset: Float, scale: F3 = F3(1, 1, 1)) -> simd_float4x4 {
    let d = simd_normalize(dir)
    let p = shape(d)
    let n = surfaceNormal(d, shape)
    let c = p - n * radius * inset
    let x = n
    var y = simd_cross(F3(0, 0, 1), x)
    y = simd_length(y) < 1e-3 ? F3(0, 1, 0) : simd_normalize(y)
    let z = simd_cross(x, y)
    return makeTransform(simd_float3x3(x, y, z), c, scale * radius)
}

@inline(__always) func blob(_ mesh: Int, _ m: simd_float4x4, _ part: Part, hair: Float = 0, ext: F3 = F3(1, 1, 1), seed: Float = 0,
                            shadow: Bool = true, shells: Bool = false, alpha: Bool = false, extW: Float = 0) -> BlobPose {
    BlobPose(mesh: mesh, model: m, part: part, hair: hair, ext: ext, seed: seed, shadow: shadow, shells: shells, alpha: alpha, extW: extW)
}

/// 主要な部品から3×3の回転を取り出す
@inline(__always) func rotOf(_ m: simd_float4x4) -> simd_float3x3 {
    simd_float3x3(xyz(m.columns.0), xyz(m.columns.1), xyz(m.columns.2))
}

@inline(__always) func capInst(_ a: F3, _ b: F3, _ r0: Float, _ r1: Float, side: F3, part: Part, seg: Int, leg: Int, hair: Float, seed: Float) -> CapInst {
    CapInst(a: F4(a, r0), b: F4(b, r1), side: F4(side, part.rawValue), info: F4(Float(seg), Float(leg), hair, seed))
}
