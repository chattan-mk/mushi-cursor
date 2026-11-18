import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd

/// 画面を使わずに決まった動きを再生して PNG に書き出す（見た目の確認用）
enum Snapshot {
    struct Step { var t: Double; var p: SIMD2<Double>; var down: Bool?; var right: Bool }

    static func run(outDir: String, speciesIndex: Int, sizeMul: Float, zoom: Double, scale: Double = 2.0, only: [Int]? = nil, times: (Double, Double, Double)? = nil, fixedView: Bool = false) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { print("Metal なし"); return }
        let src = ShaderSource.load()
        let sp = Creatures.all[speciesIndex]
        let ptPerMM = sp.basePtPerMM * sizeMul
        guard let r = CreatureRenderer(device: device, creature: sp, shaderSource: src) else { print("renderer 失敗"); return }
        let sim = sp.makeSim(ptPerMM: ptPerMM, seed: 20251017)
        let radPt = Double(r.layerRadiusMM() * ptPerMM)
        let sizePt = ceil(radPt * 2 / zoom)
        let px = Int(sizePt * scale)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: px, height: px, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        let tex = device.makeTexture(descriptor: td)!

        // 台本：(時刻, カーソル位置pt)
        let start = SIMD2<Double>(600, 400)
        func cursorAt(_ t: Double) -> SIMD2<Double> {
            var p = start
            if t > 1.0 { p.x += min(t - 1.0, 1.0) * 120 }                 // ゆっくり右へ
            if t > 2.0 { let u = min(t - 2.0, 0.6); p.y += u * 140; p.x += u * 60 }   // 右上へ曲がる
            if t > 3.8 { let u = min(t - 3.8, 0.35); p.x += u * 1700 }    // 速く振る（跳ぶ）
            if t > 5.0 { let u = min(t - 5.0, 1.0); p.x -= u * 90 }       // 後ずさり→振り返り
            return p
        }
        let downAt = 3.20, upAt = 3.45, rightAt = 4.6
        var captures: [(Double, String)] = [
            (0.95, "idle"), (1.50, "walk1"), (1.54, "walk2"), (2.40, "turn"), (3.15, "idle2"), (3.40, "threat"),
            (3.51, "strike"), (3.56, "bite"), (3.93, "jump1"), (4.05, "jump2"), (4.30, "land"), (4.68, "web"),
            (5.6, "back"), (6.4, "rest"),
        ]
        if let (a, b, st) = times {
            captures = []
            var tt = a
            while tt <= b + 1e-9 { captures.append((tt, String(format: "t%.3f", tt))); tt += st }
        }
        var images: [(String, CGImage)] = []
        var fixedOrigin: SIMD2<Double>? = nil
        let dt = 1.0 / 120.0
        var t = 0.0
        var ci = 0
        var wasDown = false
        var rightDone = false
        while ci < captures.count {
            t += dt
            let p = cursorAt(t)
            let down = t >= downAt && t < upAt
            if down && !wasDown { sim.mouseDown() }
            if !down && wasDown { sim.mouseUp(strike: true) }
            wasDown = down
            if t >= rightAt && !rightDone { sim.rightClick(); rightDone = true }
            sim.update(dt: Float(dt), cursor: F2(Float(p.x), Float(p.y)) / ptPerMM)
            sim.events.removeAll()
            if t >= captures[ci].0, let o = only, !o.contains(ci) { ci += 1; continue }
            if t >= captures[ci].0 {
                let center = SIMD2<Double>(Double(sim.bodyXY.x * ptPerMM), Double(sim.bodyXY.y * ptPerMM))
                var origin = center - sizePt / 2
                if fixedView { if fixedOrigin == nil { fixedOrigin = origin }; origin = fixedOrigin! }
                let cb = r.queue.makeCommandBuffer()!
                r.render(pose: sim.pose(), ptPerMM: ptPerMM, originPt: origin, sizePt: SIMD2(sizePt, sizePt), scale: scale, target: tex, commandBuffer: cb)
                cb.commit()
                cb.waitUntilCompleted()
                if let img = composite(tex: tex, px: px, hotspot: SIMD2<Double>((p.x - origin.x) * scale, (p.y - origin.y) * scale)) {
                    images.append((captures[ci].1, img))
                    writePNG(img, "\(outDir)/\(String(format: "%02d", ci))_\(captures[ci].1).png")
                }
                ci += 1
            }
        }
        // 一覧
        let cols = images.count > 12 ? 6 : 4
        let rows = (images.count + cols - 1) / cols
        let cell = px
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        if let ctx = CGContext(data: nil, width: cols * cell, height: rows * cell, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cols * cell, height: rows * cell))
            for (i, (_, img)) in images.enumerated() {
                let x = (i % cols) * cell
                let y = (rows - 1 - i / cols) * cell
                ctx.draw(img, in: CGRect(x: x, y: y, width: cell, height: cell))
            }
            if let sheet = ctx.makeImage() { writePNG(sheet, "\(outDir)/sheet.png") }
        }
        print("snapshot: \(images.count) frames → \(outDir)")
    }

    /// 背景（白い紙＋文字っぽい線 / 暗い面）に重ねる
    static func composite(tex: MTLTexture, px: Int, hotspot: SIMD2<Double>) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: px * px * 4)
        tex.getBytes(&bytes, bytesPerRow: px * 4, from: MTLRegionMake2D(0, 0, px, px), mipmapLevel: 0)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let prov = CGDataProvider(data: Data(bytes) as CFData),
              let spider = CGImage(width: px, height: px, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4, space: cs,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)
        else { return nil }
        let W = CGFloat(px)
        ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.96, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: W))
        ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: W * 0.72, y: 0, width: W * 0.28, height: W))
        ctx.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.27, alpha: 1))
        var y = W * 0.08
        var k = 0
        while y < W {
            let len = W * (0.35 + 0.25 * Double((k * 37) % 7) / 7.0)
            ctx.fill(CGRect(x: W * 0.05, y: y, width: len, height: W * 0.012))
            y += W * 0.045
            k += 1
        }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.45, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: W * 0.08, y: W * 0.55, width: W * 0.22, height: W * 0.07))
        ctx.draw(spider, in: CGRect(x: 0, y: 0, width: W, height: W))
        // カーソル位置（赤い点）
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.9))
        ctx.fill(CGRect(x: hotspot.x - 1.5, y: hotspot.y - 1.5, width: 3, height: 3))
        return ctx.makeImage()
    }

    static func writePNG(_ img: CGImage, _ path: String) {
        guard let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }
}

enum ShaderSource {
    static func load() -> String {
        if let u = Bundle.main.url(forResource: "Shaders", withExtension: "metal"), let s = try? String(contentsOf: u, encoding: .utf8) { return s }
        // 開発時：実行ファイルの隣や src から探す
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for c in [exe.appendingPathComponent("Shaders.metal"), exe.appendingPathComponent("../Resources/Shaders.metal")] {
            if let s = try? String(contentsOf: c, encoding: .utf8) { return s }
        }
        return ""
    }
}
