import AppKit
import QuartzCore

/// クリック時のエフェクト（Core Animation）。座標はウインドウ内 pt（左下原点）
final class Effects {
    static let ringImage: CGImage? = makeRing()
    static let dropImage: CGImage? = makeDrop()
    static let dotImage: CGImage? = makeDot()

    /// クリックした点：小さく締まった波紋 ＋ ピンポイントの点（＋ 噛んだ虫なら小さなしずく）
    static func bite(in layer: CALayer, top: CALayer, at p: CGPoint, dropSize: CGFloat) {
        let now = CACurrentMediaTime()
        // 波紋（半径 13pt まで広がって消える）
        let r: CGFloat = 13
        let ring = CALayer()
        ring.contents = ringImage
        ring.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        ring.position = p
        ring.opacity = 0
        top.addSublayer(ring)
        let sc = CABasicAnimation(keyPath: "transform.scale")
        sc.fromValue = 0.25
        sc.toValue = 1.0
        sc.duration = 0.38
        sc.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.7, 0.3, 1)
        let op = CAKeyframeAnimation(keyPath: "opacity")
        op.values = [0.0, 1.0, 0.0]
        op.keyTimes = [0, 0.12, 1]
        op.duration = 0.38
        let g = CAAnimationGroup()
        g.animations = [sc, op]
        g.duration = 0.38
        g.beginTime = now
        ring.add(g, forKey: "ripple")
        // 押した点そのもの
        let dot = CALayer()
        dot.contents = dotImage
        dot.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
        dot.position = p
        dot.opacity = 0
        top.addSublayer(dot)
        let dop = CAKeyframeAnimation(keyPath: "opacity")
        dop.values = [1.0, 1.0, 0.0]
        dop.keyTimes = [0, 0.4, 1]
        dop.duration = 0.55
        dop.beginTime = now
        let dsc = CAKeyframeAnimation(keyPath: "transform.scale")
        dsc.values = [1.5, 0.9, 1.0]
        dsc.keyTimes = [0, 0.25, 1]
        dsc.duration = 0.55
        dsc.beginTime = now
        dot.add(dop, forKey: "o")
        dot.add(dsc, forKey: "s")
        var layers: [CALayer] = [ring, dot]
        // しずく（クモの毒・アリの蟻酸・テントウムシの黄色い液）
        if dropSize > 0 {
            let ds = dropSize
            let drop = CALayer()
            drop.contents = dropImage
            drop.bounds = CGRect(x: 0, y: 0, width: ds * 1.6, height: ds * 1.6)
            drop.position = CGPoint(x: p.x + ds * 0.1, y: p.y - ds * 0.1)
            drop.opacity = 0
            layer.addSublayer(drop)
            let o2 = CAKeyframeAnimation(keyPath: "opacity")
            o2.values = [0.0, 1.0, 1.0, 0.0]
            o2.keyTimes = [0, 0.04, 0.6, 1]
            o2.duration = 2.4
            let s2 = CAKeyframeAnimation(keyPath: "transform.scale")
            s2.values = [0.3, 1.08, 1.0, 1.0, 0.55]
            s2.keyTimes = [0, 0.05, 0.1, 0.6, 1]
            s2.duration = 2.4
            let g2 = CAAnimationGroup()
            g2.animations = [o2, s2]
            g2.duration = 2.4
            g2.beginTime = now + 0.05
            drop.add(g2, forKey: "drop")
            layers.append(drop)
        }
        removeLater(layers, after: 2.6)
    }

    /// アリの右クリック：腹を曲げて蟻酸をぴゅっと吹く（細かなしずくが前方へ散る）
    static func spray(in layer: CALayer, at p: CGPoint, dir: CGVector, size: CGFloat, seed: UInt64) {
        var rng = SplitMix(seed: seed)
        let now = CACurrentMediaTime()
        var layers: [CALayer] = []
        let base = atan2(dir.dy, dir.dx)
        for _ in 0..<9 {
            let a = base + CGFloat(rng.range(-0.45, 0.45))
            let dist = size * CGFloat(rng.range(0.25, 0.75))
            let ds = CGFloat(rng.range(2.0, 4.2))
            let d = CALayer()
            d.contents = dropImage
            d.bounds = CGRect(x: 0, y: 0, width: ds * 1.6, height: ds * 1.6)
            let end = CGPoint(x: p.x + cos(a) * dist, y: p.y + sin(a) * dist)
            d.position = end
            d.opacity = 0
            layer.addSublayer(d)
            let mv = CABasicAnimation(keyPath: "position")
            mv.fromValue = NSValue(point: p)
            mv.toValue = NSValue(point: end)
            mv.duration = 0.12
            mv.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0.0, 1.0, 1.0, 0.0]
            op.keyTimes = [0, 0.05, 0.55, 1]
            op.duration = 1.6
            let g = CAAnimationGroup()
            g.animations = [mv, op]
            g.duration = 1.6
            g.beginTime = now + Double(rng.range(0, 0.05))
            d.add(g, forKey: "spray")
            layers.append(d)
        }
        removeLater(layers, after: 1.8)
    }

    /// 右クリック：その場に小さな網を張る
    static func web(in layer: CALayer, at p: CGPoint, size: CGFloat, seed: UInt64) {
        var rng = SplitMix(seed: seed)
        let R = size * 1.9
        let nRad = 9 + Int(rng.f() * 4)
        var angles: [CGFloat] = []
        for k in 0..<nRad { angles.append((CGFloat(k) + CGFloat(rng.range(-0.3, 0.3))) / CGFloat(nRad) * 2 * .pi) }
        var lens: [CGFloat] = angles.map { _ in R * CGFloat(rng.range(0.75, 1.1)) }
        lens = lens.map { max($0, R * 0.6) }
        let radials = CGMutablePath()
        for (a, l) in zip(angles, lens) {
            radials.move(to: p)
            let mid = CGPoint(x: p.x + cos(a) * l * 0.5, y: p.y + sin(a) * l * 0.5 - CGFloat(rng.range(0, 0.6)))
            radials.addQuadCurve(to: CGPoint(x: p.x + cos(a) * l, y: p.y + sin(a) * l), control: mid)
        }
        let spiral = CGMutablePath()
        var r = R * 0.16
        let dr = R * CGFloat(rng.range(0.085, 0.11))
        var first = true
        while r < R * 0.98 {
            for k in 0..<nRad {
                let a0 = angles[k], a1 = angles[(k + 1) % nRad] + (k == nRad - 1 ? 2 * .pi : 0)
                let r0 = min(r + dr * CGFloat(k) / CGFloat(nRad), lens[k] * 0.97)
                let r1 = min(r + dr * CGFloat(k + 1) / CGFloat(nRad), lens[(k + 1) % nRad] * 0.97)
                let q0 = CGPoint(x: p.x + cos(a0) * r0, y: p.y + sin(a0) * r0)
                let q1 = CGPoint(x: p.x + cos(a1) * r1, y: p.y + sin(a1) * r1)
                let am = (a0 + a1) / 2
                let sag = (r0 + r1) / 2 * 0.86
                let c = CGPoint(x: p.x + cos(am) * sag, y: p.y + sin(am) * sag - 0.4)
                if first { spiral.move(to: q0); first = false }
                spiral.addQuadCurve(to: q1, control: c)
            }
            r += dr
        }
        let now = CACurrentMediaTime()
        let container = CALayer()
        container.frame = layer.bounds
        layer.addSublayer(container)
        for (path, w, begin, dur) in [(radials as CGPath, 0.55, 0.0, 0.16), (spiral as CGPath, 0.42, 0.10, 0.38)] {
            let s = silkLayer(path: path, width: CGFloat(w))
            s.strokeEnd = 0
            container.addSublayer(s)
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = 0
            a.toValue = 1
            a.duration = dur
            a.beginTime = now + begin
            a.fillMode = .both
            a.isRemovedOnCompletion = false
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            s.add(a, forKey: "spin")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = now + 2.6
        fade.duration = 1.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        container.add(fade, forKey: "fade")
        removeLater([container], after: 4.1)
    }

    // MARK: 恐竜・乗り物・もの

    static let footImage: CGImage? = makeFootprint()
    static let treadImage: CGImage? = makeTread()
    static let holeImage: CGImage? = makeHole()
    static let smokeImage: CGImage? = makeSmoke()
    static let dustRingImage: CGImage? = makeDustRing()
    static let glowImage: CGImage? = makeGlow()
    private static var trackLayers = 0

    private static func fadeOut(_ l: CALayer, appear: Double, hold: Double, fade: Double, peak: Float) {
        let now = CACurrentMediaTime()
        let a = CAKeyframeAnimation(keyPath: "opacity")
        let total = appear + hold + fade
        a.values = [0, peak, peak, 0]
        a.keyTimes = [0, NSNumber(value: appear / total), NSNumber(value: (appear + hold) / total), 1]
        a.duration = total
        a.beginTime = now
        a.fillMode = .both
        a.isRemovedOnCompletion = false
        l.opacity = 0
        l.add(a, forKey: "life")
        removeLater([l], after: total + 0.05)
    }

    /// 恐竜の足あと（3本指）
    static func footprint(in layer: CALayer, at p: CGPoint, angle: CGFloat, size: CGFloat, left: Bool) {
        let l = CALayer()
        l.contents = footImage
        l.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        l.position = p
        l.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: 1, y: left ? 1 : -1))
        layer.addSublayer(l)
        fadeOut(l, appear: 0.05, hold: 2.6, fade: 1.6, peak: 0.85)
    }

    /// キャタピラの跡（左右2本）
    static func track(in layer: CALayer, at p: CGPoint, angle: CGFloat, width: CGFloat, scale: CGFloat) {
        guard trackLayers < 360 else { return }
        let side = CGVector(dx: -sin(angle), dy: cos(angle))
        for s in [CGFloat(1), -1] {
            let l = CALayer()
            l.contents = treadImage
            l.bounds = CGRect(x: 0, y: 0, width: 2.0 * scale, height: 3.9 * scale)
            l.position = CGPoint(x: p.x + side.dx * width / 2 * s, y: p.y + side.dy * width / 2 * s)
            l.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            layer.addSublayer(l)
            trackLayers += 1
            fadeOut(l, appear: 0.02, hold: 1.4, fade: 1.6, peak: 0.6)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.1) { trackLayers -= 1 }
        }
    }

    /// 砲撃：着弾点にひび割れた穴、砲口から煙
    static func shot(in layer: CALayer, top: CALayer, at p: CGPoint, dir: CGVector, big: Bool, seed: UInt64) {
        var rng = SplitMix(seed: seed)
        let holeSize: CGFloat = big ? 46 : 10
        let hole = CALayer()
        hole.contents = holeImage
        hole.bounds = CGRect(x: 0, y: 0, width: holeSize, height: holeSize)
        hole.position = p
        hole.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rng.range(0, 6.28))))
        layer.addSublayer(hole)
        fadeOut(hole, appear: 0.02, hold: big ? 2.2 : 1.0, fade: 1.2, peak: 1.0)
        // 閃光
        let fl = CALayer()
        fl.contents = glowImage
        fl.bounds = CGRect(x: 0, y: 0, width: holeSize * 1.6, height: holeSize * 1.6)
        fl.position = p
        fl.compositingFilter = "screenBlendMode"
        top.addSublayer(fl)
        fadeOut(fl, appear: 0.01, hold: 0.03, fade: big ? 0.18 : 0.08, peak: 1.0)
        // 煙
        let n = big ? 6 : 2
        let ang = atan2(dir.dy, dir.dx)
        for i in 0..<n {
            let sm = CALayer()
            sm.contents = smokeImage
            let sz = (big ? 18 : 7) * CGFloat(rng.range(0.8, 1.3))
            sm.bounds = CGRect(x: 0, y: 0, width: sz, height: sz)
            let a = ang + CGFloat(rng.range(-0.6, 0.6)) + .pi
            let dist = (big ? 26 : 8) * CGFloat(rng.range(0.4, 1.0))
            let end = CGPoint(x: p.x + cos(a) * dist, y: p.y + sin(a) * dist + (big ? 6 : 2))
            sm.position = end
            top.addSublayer(sm)
            let now = CACurrentMediaTime()
            let mv = CABasicAnimation(keyPath: "position")
            mv.fromValue = NSValue(point: p)
            mv.toValue = NSValue(point: end)
            mv.duration = 0.9
            mv.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let sc = CABasicAnimation(keyPath: "transform.scale")
            sc.fromValue = 0.3
            sc.toValue = 2.2
            sc.duration = 1.3
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0, 0.7, 0]
            op.keyTimes = [0, 0.1, 1]
            op.duration = 1.3
            let g = CAAnimationGroup()
            g.animations = [mv, sc, op]
            g.duration = 1.3
            g.beginTime = now + Double(i) * 0.03
            g.fillMode = .both
            g.isRemovedOnCompletion = false
            sm.opacity = 0
            sm.add(g, forKey: "smoke")
            removeLater([sm], after: 1.5)
        }
    }

    /// ドローンの吹きおろし：砂ぼこりの輪が広がる
    static func downwash(in layer: CALayer, at p: CGPoint, size: CGFloat) {
        let l = CALayer()
        l.contents = dustRingImage
        l.bounds = CGRect(x: 0, y: 0, width: size * 2.4, height: size * 2.4)
        l.position = p
        layer.addSublayer(l)
        let now = CACurrentMediaTime()
        let sc = CABasicAnimation(keyPath: "transform.scale")
        sc.fromValue = 0.3
        sc.toValue = 1.0
        sc.duration = 0.6
        sc.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let op = CAKeyframeAnimation(keyPath: "opacity")
        op.values = [0, 0.9, 0]
        op.keyTimes = [0, 0.15, 1]
        op.duration = 0.6
        let g = CAAnimationGroup()
        g.animations = [sc, op]
        g.duration = 0.6
        g.beginTime = now
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        l.opacity = 0
        l.add(g, forKey: "wash")
        removeLater([l], after: 0.7)
    }

    /// UFO の牽引ビーム：光る円と、吸い上げられる光の粒
    static func beam(in layer: CALayer, top: CALayer, at p: CGPoint, size: CGFloat, seed: UInt64) {
        var rng = SplitMix(seed: seed)
        let g0 = CALayer()
        g0.contents = glowImage
        g0.bounds = CGRect(x: 0, y: 0, width: size * 1.6, height: size * 1.6)
        g0.position = p
        g0.compositingFilter = "screenBlendMode"
        layer.addSublayer(g0)
        fadeOut(g0, appear: 0.08, hold: 0.6, fade: 0.35, peak: 0.9)
        let now = CACurrentMediaTime()
        for _ in 0..<14 {
            let d = CALayer()
            d.contents = glowImage
            let s = CGFloat(rng.range(2.0, 4.0))
            d.bounds = CGRect(x: 0, y: 0, width: s, height: s)
            d.compositingFilter = "screenBlendMode"
            let a = CGFloat(rng.range(0, 6.28)), r = size * CGFloat(rng.range(0.15, 0.7))
            let start = CGPoint(x: p.x + cos(a) * r, y: p.y + sin(a) * r)
            let end = CGPoint(x: p.x + cos(a) * r * 0.2, y: p.y + sin(a) * r * 0.2 + size * 0.15)
            d.position = end
            top.addSublayer(d)
            let mv = CABasicAnimation(keyPath: "position")
            mv.fromValue = NSValue(point: start)
            mv.toValue = NSValue(point: end)
            mv.duration = 0.8
            mv.timingFunction = CAMediaTimingFunction(name: .easeIn)
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0, 1, 0]
            op.keyTimes = [0, 0.3, 1]
            op.duration = 0.8
            let g = CAAnimationGroup()
            g.animations = [mv, op]
            g.duration = 0.8
            g.beginTime = now + Double(rng.range(0, 0.3))
            g.fillMode = .both
            g.isRemovedOnCompletion = false
            d.opacity = 0
            d.add(g, forKey: "up")
            removeLater([d], after: 1.2)
        }
    }

    /// 恐竜の咆哮：口の前に広がる衝撃波の弧
    static func roar(in layer: CALayer, at p: CGPoint, dir: CGVector, size: CGFloat) {
        let ang = atan2(dir.dy, dir.dx)
        let now = CACurrentMediaTime()
        for i in 0..<3 {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: size, startAngle: ang - 0.75, endAngle: ang + 0.75, clockwise: false)
            let s = CAShapeLayer()
            s.path = path
            s.position = p
            s.fillColor = nil
            s.strokeColor = CGColor(gray: 1, alpha: 0.85)
            s.lineWidth = 2.2
            s.lineCap = .round
            s.shadowColor = CGColor(gray: 0, alpha: 1)
            s.shadowOpacity = 0.6
            s.shadowRadius = 1.2
            s.shadowOffset = CGSize(width: 0.5, height: -1)
            s.opacity = 0
            layer.addSublayer(s)
            let sc = CABasicAnimation(keyPath: "transform.scale")
            sc.fromValue = 0.25
            sc.toValue = 1.6
            sc.duration = 0.7
            sc.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let op = CAKeyframeAnimation(keyPath: "opacity")
            op.values = [0, 0.9, 0]
            op.keyTimes = [0, 0.15, 1]
            op.duration = 0.7
            let g = CAAnimationGroup()
            g.animations = [sc, op]
            g.duration = 0.7
            g.beginTime = now + Double(i) * 0.16
            g.fillMode = .both
            g.isRemovedOnCompletion = false
            s.add(g, forKey: "roar")
            removeLater([s], after: 1.3)
        }
    }

    /// UFO のワープ：光の輪がはじける
    static func warp(in layer: CALayer, at p: CGPoint, size: CGFloat) {
        let g0 = CALayer()
        g0.contents = glowImage
        g0.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        g0.position = p
        g0.compositingFilter = "screenBlendMode"
        layer.addSublayer(g0)
        fadeOut(g0, appear: 0.02, hold: 0.04, fade: 0.25, peak: 1)
        let r = CALayer()
        r.contents = ringImage
        r.bounds = CGRect(x: 0, y: 0, width: size * 2, height: size * 2)
        r.position = p
        layer.addSublayer(r)
        let now = CACurrentMediaTime()
        let sc = CABasicAnimation(keyPath: "transform.scale")
        sc.fromValue = 0.2
        sc.toValue = 1.0
        sc.duration = 0.4
        let op = CAKeyframeAnimation(keyPath: "opacity")
        op.values = [0, 1, 0]
        op.keyTimes = [0, 0.1, 1]
        op.duration = 0.4
        let g = CAAnimationGroup()
        g.animations = [sc, op]
        g.duration = 0.4
        g.beginTime = now
        g.fillMode = .both
        g.isRemovedOnCompletion = false
        r.opacity = 0
        r.add(g, forKey: "warp")
        removeLater([r], after: 0.5)
    }

    /// 切れた牽引糸：少したるんでから消える
    static func silkDone(in layer: CALayer, from a: CGPoint, to b: CGPoint) {
        let len = hypot(b.x - a.x, b.y - a.y)
        if len < 3 { return }
        let path = CGMutablePath()
        path.move(to: a)
        path.addLine(to: b)
        let sagged = CGMutablePath()
        sagged.move(to: a)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 - min(len * 0.08, 18))
        sagged.addQuadCurve(to: b, control: mid)
        let s = silkLayer(path: path, width: 0.55)
        layer.addSublayer(s)
        let now = CACurrentMediaTime()
        let pa = CABasicAnimation(keyPath: "path")
        pa.fromValue = path
        pa.toValue = sagged
        pa.duration = 0.9
        pa.beginTime = now
        pa.fillMode = .forwards
        pa.isRemovedOnCompletion = false
        pa.timingFunction = CAMediaTimingFunction(name: .easeOut)
        s.add(pa, forKey: "sag")
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1
        f.toValue = 0
        f.beginTime = now + 0.6
        f.duration = 1.3
        f.fillMode = .forwards
        f.isRemovedOnCompletion = false
        s.add(f, forKey: "fade")
        removeLater([s], after: 2.0)
    }

    /// 糸：白い細線＋画面に落ちる淡い影（白地でも見える）
    static func silkLayer(path: CGPath, width: CGFloat) -> CAShapeLayer {
        let s = CAShapeLayer()
        s.path = path
        s.fillColor = nil
        s.strokeColor = CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 0.92)
        s.lineWidth = width
        s.lineCap = .round
        s.lineJoin = .round
        s.shadowColor = CGColor(gray: 0, alpha: 1)
        s.shadowOpacity = 0.45
        s.shadowRadius = 0.7
        s.shadowOffset = CGSize(width: 0.8, height: -1.3)
        return s
    }

    static func removeLater(_ layers: [CALayer], after t: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for l in layers { l.removeFromSuperlayer() }
            CATransaction.commit()
        }
    }

    // MARK: 画像の下ごしらえ

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// 液晶を押した時のような、細くくっきりした輪（白地でも黒地でも見えるよう明暗の二重線）
    private static func makeRing() -> CGImage? {
        let S = 128
        guard let c = context(S, S) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let center = CGPoint(x: S / 2, y: S / 2)
        let colors: [CGColor] = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
            CGColor(red: 0.35, green: 0.20, blue: 0.55, alpha: 0.30),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
            CGColor(red: 0.10, green: 0.45, blue: 0.40, alpha: 0.35),
            CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.55),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
        ]
        let locs: [CGFloat] = [0.0, 0.66, 0.76, 0.82, 0.87, 0.91, 1.0]
        if let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs) {
            c.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: CGFloat(S) / 2, options: [])
        }
        return c.makeImage()
    }

    /// 3本指の足あと（+x が前）：かかとの肉球と、離れて広がる3本の指、先に爪の跡
    private static func makeFootprint() -> CGImage? {
        let S = 128
        guard let c = context(S, S) else { return nil }
        let toes: [(CGFloat, CGFloat, CGFloat)] = [(0, 50, 11), (0.52, 38, 10), (-0.52, 38, 10)]   // 角度, 長さ, 太さ
        func shape(_ color: CGColor, _ dx: CGFloat, _ dy: CGFloat, _ grow: CGFloat) {
            c.setFillColor(color)
            c.fillEllipse(in: CGRect(x: 22 + dx - grow, y: 52 + dy - grow, width: 28 + grow * 2, height: 24 + grow * 2))
            for (a, len, w) in toes {
                c.saveGState()
                c.translateBy(x: 48 + dx, y: 64 + dy)
                c.rotate(by: a)
                c.fillEllipse(in: CGRect(x: 6 - grow, y: -w / 2 - grow, width: len + grow * 2, height: w + grow * 2))
                // 爪の跡
                c.move(to: CGPoint(x: len + 4 - grow * 0.5, y: -w * 0.3))
                c.addLine(to: CGPoint(x: len + 13 + grow, y: 0))
                c.addLine(to: CGPoint(x: len + 4 - grow * 0.5, y: w * 0.3))
                c.closePath()
                c.fillPath()
                c.restoreGState()
            }
        }
        shape(CGColor(red: 1, green: 0.97, blue: 0.9, alpha: 0.20), -1.5, 1.5, 2.5)
        shape(CGColor(red: 0.16, green: 0.12, blue: 0.08, alpha: 0.45), 0, 0, 0)
        shape(CGColor(red: 0.07, green: 0.05, blue: 0.03, alpha: 0.30), 1.0, -1.0, -2.5)
        return c.makeImage()
    }

    /// キャタピラ跡の一コマ
    private static func makeTread() -> CGImage? {
        let W = 40, H = 78
        guard let c = context(W, H) else { return nil }
        c.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.08, alpha: 0.35))
        c.fill(CGRect(x: 0, y: 4, width: W, height: H - 8))
        c.setFillColor(CGColor(red: 0.05, green: 0.04, blue: 0.03, alpha: 0.55))
        c.fill(CGRect(x: 8, y: 6, width: 14, height: H - 12))
        return c.makeImage()
    }

    /// 着弾の穴：焦げた穴と放射状のひび
    private static func makeHole() -> CGImage? {
        let S = 256
        guard let c = context(S, S) else { return nil }
        var rng = SplitMix(seed: 4242)
        let ctr = CGPoint(x: 128, y: 128)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // 焦げ
        if let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.05, green: 0.04, blue: 0.03, alpha: 0.75), CGColor(red: 0.15, green: 0.10, blue: 0.06, alpha: 0.35), CGColor(red: 0, green: 0, blue: 0, alpha: 0)] as CFArray, locations: [0, 0.35, 1]) {
            c.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: 46, options: [])
        }
        // ひび（白い線に暗い影）
        for pass in 0..<2 {
            var r2 = SplitMix(seed: 99)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.setStrokeColor(pass == 0 ? CGColor(gray: 0, alpha: 0.45) : CGColor(gray: 1, alpha: 0.8))
            c.setLineWidth(pass == 0 ? 2.2 : 1.1)
            let off: CGFloat = pass == 0 ? 1.2 : 0
            for k in 0..<11 {
                var a = CGFloat(k) / 11 * 2 * .pi + CGFloat(r2.range(-0.2, 0.2))
                var p = CGPoint(x: ctr.x + cos(a) * 12 + off, y: ctr.y + sin(a) * 12 - off)
                c.move(to: p)
                let len = CGFloat(r2.range(60, 118))
                var d: CGFloat = 12
                while d < len {
                    d += CGFloat(r2.range(8, 18))
                    a += CGFloat(r2.range(-0.25, 0.25))
                    p = CGPoint(x: ctr.x + cos(a) * d + off, y: ctr.y + sin(a) * d - off)
                    c.addLine(to: p)
                }
                c.strokePath()
            }
            // 同心のひび（ところどころ）
            for _ in 0..<5 {
                let rad = CGFloat(r2.range(22, 60))
                let a0 = CGFloat(r2.range(0, 6.28))
                c.addArc(center: CGPoint(x: ctr.x + off, y: ctr.y - off), radius: rad, startAngle: a0, endAngle: a0 + CGFloat(r2.range(0.3, 0.8)), clockwise: false)
                c.strokePath()
            }
        }
        _ = rng.f()
        // 穴
        c.setFillColor(CGColor(gray: 0.02, alpha: 0.95))
        c.fillEllipse(in: CGRect(x: 117, y: 117, width: 22, height: 22))
        c.setStrokeColor(CGColor(gray: 1, alpha: 0.5))
        c.setLineWidth(1.2)
        c.strokeEllipse(in: CGRect(x: 115, y: 115, width: 26, height: 26))
        return c.makeImage()
    }

    private static func makeSmoke() -> CGImage? {
        let S = 96
        guard let c = context(S, S) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctr = CGPoint(x: 48, y: 48)
        if let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 0.45, green: 0.44, blue: 0.42, alpha: 0.55), CGColor(red: 0.5, green: 0.49, blue: 0.47, alpha: 0)] as CFArray, locations: [0, 1]) {
            c.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: 48, options: [])
        }
        return c.makeImage()
    }

    private static func makeDustRing() -> CGImage? {
        let S = 256
        guard let c = context(S, S) else { return nil }
        var rng = SplitMix(seed: 7)
        c.setLineCap(.round)
        for _ in 0..<70 {
            let a = CGFloat(rng.range(0, 6.28))
            let r0 = CGFloat(rng.range(70, 100)), r1 = r0 + CGFloat(rng.range(10, 26))
            c.setStrokeColor(CGColor(red: 0.55, green: 0.5, blue: 0.42, alpha: CGFloat(rng.range(0.15, 0.4))))
            c.setLineWidth(CGFloat(rng.range(1.0, 2.5)))
            c.move(to: CGPoint(x: 128 + cos(a) * r0, y: 128 + sin(a) * r0))
            c.addLine(to: CGPoint(x: 128 + cos(a) * r1, y: 128 + sin(a) * r1))
            c.strokePath()
        }
        return c.makeImage()
    }

    private static func makeGlow() -> CGImage? {
        let S = 128
        guard let c = context(S, S) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctr = CGPoint(x: 64, y: 64)
        if let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 1, blue: 0.92, alpha: 1), CGColor(red: 0.6, green: 1, blue: 0.8, alpha: 0.45), CGColor(red: 0.3, green: 0.9, blue: 0.7, alpha: 0)] as CFArray, locations: [0, 0.3, 1]) {
            c.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: 64, options: [])
        }
        return c.makeImage()
    }

    /// 押した点：白い芯に黒いふち
    private static func makeDot() -> CGImage? {
        let S = 32
        guard let c = context(S, S) else { return nil }
        c.setFillColor(CGColor(gray: 0, alpha: 0.55))
        c.fillEllipse(in: CGRect(x: 3, y: 3, width: 26, height: 26))
        c.setFillColor(CGColor(gray: 1, alpha: 0.95))
        c.fillEllipse(in: CGRect(x: 8, y: 8, width: 16, height: 16))
        return c.makeImage()
    }

    /// 透明なしずく（縁が暗く、左上に光、右下に集光）
    private static func makeDrop() -> CGImage? {
        let S = 96
        guard let c = context(S, S) else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let r = CGFloat(S) * 0.30
        let ctr = CGPoint(x: CGFloat(S) * 0.47, y: CGFloat(S) * 0.53)
        // 影
        c.saveGState()
        c.setShadow(offset: CGSize(width: r * 0.18, height: -r * 0.28), blur: r * 0.35, color: CGColor(gray: 0, alpha: 0.45))
        c.setFillColor(CGColor(red: 0.85, green: 0.80, blue: 0.55, alpha: 0.18))
        c.fillEllipse(in: CGRect(x: ctr.x - r, y: ctr.y - r, width: r * 2, height: r * 2))
        c.restoreGState()
        // 縁の屈折
        let edge: [CGColor] = [CGColor(red: 1, green: 0.97, blue: 0.85, alpha: 0.05), CGColor(red: 0.95, green: 0.9, blue: 0.7, alpha: 0.10),
                               CGColor(red: 0.12, green: 0.10, blue: 0.06, alpha: 0.55)]
        if let g = CGGradient(colorsSpace: cs, colors: edge as CFArray, locations: [0, 0.7, 1]) {
            c.drawRadialGradient(g, startCenter: ctr, startRadius: 0, endCenter: ctr, endRadius: r, options: [])
        }
        // 右下の集光
        c.saveGState()
        c.addEllipse(in: CGRect(x: ctr.x - r, y: ctr.y - r, width: r * 2, height: r * 2))
        c.clip()
        let cp = CGPoint(x: ctr.x + r * 0.35, y: ctr.y - r * 0.4)
        if let g = CGGradient(colorsSpace: cs, colors: [CGColor(red: 1, green: 1, blue: 0.9, alpha: 0.55), CGColor(red: 1, green: 1, blue: 0.9, alpha: 0)] as CFArray, locations: [0, 1]) {
            c.drawRadialGradient(g, startCenter: cp, startRadius: 0, endCenter: cp, endRadius: r * 0.5, options: [])
        }
        c.restoreGState()
        // 左上のハイライト
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
        c.fillEllipse(in: CGRect(x: ctr.x - r * 0.55, y: ctr.y + r * 0.22, width: r * 0.36, height: r * 0.26))
        return c.makeImage()
    }
}
