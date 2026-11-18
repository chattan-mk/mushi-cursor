import Foundation
import simd

typealias F2 = SIMD2<Float>
typealias F3 = SIMD3<Float>
typealias F4 = SIMD4<Float>

@inline(__always) func mixf(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
@inline(__always) func mix3(_ a: F3, _ b: F3, _ t: Float) -> F3 { a + (b - a) * t }
@inline(__always) func mix2(_ a: F2, _ b: F2, _ t: Float) -> F2 { a + (b - a) * t }
@inline(__always) func clampf(_ x: Float, _ a: Float, _ b: Float) -> Float { min(max(x, a), b) }
@inline(__always) func sat(_ x: Float) -> Float { min(max(x, 0), 1) }
@inline(__always) func sstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = clampf((x - e0) / (e1 - e0), 0, 1)
    return t * t * (3 - 2 * t)
}
/// フレームレートに依存しない指数スムージング
@inline(__always) func damp(_ c: Float, _ t: Float, _ rate: Float, _ dt: Float) -> Float {
    c + (t - c) * (1 - exp(-rate * dt))
}
@inline(__always) func damp3(_ c: F3, _ t: F3, _ rate: Float, _ dt: Float) -> F3 {
    c + (t - c) * (1 - exp(-rate * dt))
}
@inline(__always) func damp2(_ c: F2, _ t: F2, _ rate: Float, _ dt: Float) -> F2 {
    c + (t - c) * (1 - exp(-rate * dt))
}
func wrapPi(_ a: Float) -> Float {
    var x = fmodf(a + .pi, 2 * .pi)
    if x < 0 { x += 2 * .pi }
    return x - .pi
}
@inline(__always) func rot2(_ v: F2, _ a: Float) -> F2 {
    let c = cos(a), s = sin(a)
    return F2(c * v.x - s * v.y, s * v.x + c * v.y)
}
@inline(__always) func xy(_ v: F3) -> F2 { F2(v.x, v.y) }
@inline(__always) func v3(_ v: F2, _ z: Float) -> F3 { F3(v.x, v.y, z) }

func rotZ(_ a: Float) -> simd_float3x3 {
    let c = cos(a), s = sin(a)
    return simd_float3x3(F3(c, s, 0), F3(-s, c, 0), F3(0, 0, 1))
}
/// 前(+x)を持ち上げる方向が正
func pitchUp(_ a: Float) -> simd_float3x3 {
    let c = cos(a), s = sin(a)
    return simd_float3x3(F3(c, 0, s), F3(0, 1, 0), F3(-s, 0, c))
}
/// 左(+y)を持ち上げる方向が正
func rollL(_ a: Float) -> simd_float3x3 {
    let c = cos(a), s = sin(a)
    return simd_float3x3(F3(1, 0, 0), F3(0, c, s), F3(0, -s, c))
}
func axisAngle(_ axis: F3, _ a: Float) -> simd_float3x3 {
    simd_float3x3(simd_quatf(angle: a, axis: simd_normalize(axis)))
}
func makeTransform(_ r: simd_float3x3, _ t: F3, _ s: F3 = F3(1, 1, 1)) -> simd_float4x4 {
    simd_float4x4(F4(r.columns.0 * s.x, 0), F4(r.columns.1 * s.y, 0), F4(r.columns.2 * s.z, 0), F4(t, 1))
}
func normalMatrix(_ m: simd_float4x4) -> simd_float3x3 {
    let u = simd_float3x3(F3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                          F3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                          F3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
    return u.inverse.transpose
}

// MARK: - 乱数・ノイズ

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func f() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * f() }
    mutating func sign() -> Float { f() < 0.5 ? -1 : 1 }
}

@inline(__always) func hash1(_ n: Int32, _ seed: Int32) -> Float {
    var x = UInt32(bitPattern: n &* 374761393 &+ seed &* 668265263)
    x = (x ^ (x >> 13)) &* 1274126177
    x ^= x >> 16
    return Float(x & 0xFFFFFF) / Float(0xFFFFFF)
}
/// 1次元の滑らかなノイズ (-1..1)
func vnoise(_ x: Float, _ seed: Int32) -> Float {
    let i = floor(x)
    let f = x - i
    let u = f * f * (3 - 2 * f)
    let ii = Int32(truncatingIfNeeded: Int(i))
    let a = hash1(ii, seed), b = hash1(ii &+ 1, seed)
    return (a + (b - a) * u) * 2 - 1
}
func fbm1(_ x: Float, _ seed: Int32) -> Float {
    vnoise(x, seed) * 0.6 + vnoise(x * 2.13 + 3.7, seed &+ 11) * 0.28 + vnoise(x * 4.7 + 9.1, seed &+ 23) * 0.12
}
@inline(__always) func xyz(_ v: F4) -> F3 { F3(v.x, v.y, v.z) }
