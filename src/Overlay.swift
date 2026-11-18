import AppKit
import Metal
import QuartzCore
import simd

// MARK: - 本物のカーソルを隠す（バックグラウンドからでも隠せるように WindowServer へ申告）

enum CursorHider {
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SetPropFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private(set) static var hidden = false

    static func prepare() {
        guard let h = dlopen(nil, RTLD_NOW),
              let c = dlsym(h, "_CGSDefaultConnection"),
              let s = dlsym(h, "CGSSetConnectionProperty") else { NSLog("SetsCursorInBackground が使えません"); return }
        let conn = unsafeBitCast(c, to: ConnFn.self)
        let set = unsafeBitCast(s, to: SetPropFn.self)
        let cid = conn()
        _ = set(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
    static func hide() {
        guard !hidden else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }
    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
    private typealias VisFn = @convention(c) () -> Int32
    private static let isVisibleFn: VisFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let f = dlsym(h, "CGCursorIsVisible") else { return nil }
        return unsafeBitCast(f, to: VisFn.self)
    }()
    static var systemCursorVisible: Bool? { isVisibleFn.map { $0() != 0 } }

    /// 何かのはずみで見えてしまったら隠し直す
    static func reassert() {
        guard hidden, let v = systemCursorVisible, v else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        CGDisplayHideCursor(CGMainDisplayID())
    }
}

// MARK: - 画面ごとの透明ウインドウ

final class OverlayWindow: NSWindow {
    let root = CALayer()
    let fxLayer = CALayer()
    let silk = CAShapeLayer()
    let metal = CAMetalLayer()
    let hud = CALayer()
    let topFx = CALayer()
    var screenRef: NSScreen
    var scale: CGFloat

    init(screen: NSScreen, device: MTLDevice) {
        screenRef = screen
        scale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none

        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.frame = v.bounds
        root.isGeometryFlipped = false
        v.layer = root
        v.wantsLayer = true
        contentView = v

        fxLayer.frame = root.bounds
        root.addSublayer(fxLayer)
        silk.fillColor = nil
        silk.strokeColor = CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 0.9)
        silk.lineWidth = 0.55
        silk.lineCap = .round
        silk.shadowColor = CGColor(gray: 0, alpha: 1)
        silk.shadowOpacity = 0.45
        silk.shadowRadius = 0.7
        silk.shadowOffset = CGSize(width: 0.8, height: -1.3)
        silk.frame = root.bounds
        root.addSublayer(silk)

        metal.device = device
        metal.pixelFormat = .bgra8Unorm
        metal.framebufferOnly = true
        metal.isOpaque = false
        metal.presentsWithTransaction = true
        metal.contentsScale = scale
        metal.maximumDrawableCount = 3
        metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metal.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        metal.isHidden = true
        root.addSublayer(metal)
        topFx.frame = root.bounds
        root.addSublayer(topFx)
        hud.frame = root.bounds
        root.addSublayer(hud)
    }

    func setSpiderSize(_ pt: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metal.bounds = CGRect(x: 0, y: 0, width: pt, height: pt)
        metal.drawableSize = CGSize(width: pt * scale, height: pt * scale)
        CATransaction.commit()
    }
}

// MARK: - 本体：毎フレーム、カーソルの位置へ虫を動かして描く

final class OverlayController: NSObject {
    let device: MTLDevice
    let shaderSource: String
    private(set) var creature: CreatureDef
    private(set) var sizeMul: Float
    var ptPerMM: Float { creature.basePtPerMM * sizeMul }
    private var renderer: CreatureRenderer!
    private(set) var sim: CreatureSim!
    private var windows: [OverlayWindow] = []
    private var link: CADisplayLink?
    private var lastTime: CFTimeInterval = 0
    private var monitors: [Any] = []
    private var layerPt: CGFloat = 100
    private var hideTimer: Timer?
    private(set) var running = false
    var clickEffects = true
    var silkEnabled = true
    private var effectSeed: UInt64 = 1
    private var lastMouse = CGPoint.zero

    init?(creature: CreatureDef, sizeMul: Float) {
        guard let d = MTLCreateSystemDefaultDevice() else { return nil }
        device = d
        shaderSource = ShaderSource.load()
        self.creature = creature
        self.sizeMul = sizeMul
        super.init()
        guard rebuildCreature() else { return nil }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @discardableResult
    private func rebuildCreature() -> Bool {
        guard let r = CreatureRenderer(device: device, creature: creature, shaderSource: shaderSource) else { return false }
        renderer = r
        sim = creature.makeSim(ptPerMM: ptPerMM, seed: UInt64(Date().timeIntervalSince1970))
        layerPt = CGFloat(ceil(r.layerRadiusMM() * ptPerMM * 2 / 2) * 2)
        for w in windows { w.setSpiderSize(layerPt) }
        return true
    }

    func setCreature(_ c: CreatureDef) {
        creature = c
        rebuildCreature()
        lastPose = nil
        if running { showName(c.name) }
    }

    /// 切り替えた時に、カーソルのそばへ名前を少しだけ出す
    func showName(_ name: String) {
        let m = NSEvent.mouseLocation
        guard let w = windows.first(where: { $0.frame.contains(m) }) ?? windows.first else { return }
        let font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let text = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: NSColor.white])
        let size = text.size()
        let pad: CGFloat = 8
        let box = CALayer()
        box.backgroundColor = CGColor(gray: 0.08, alpha: 0.78)
        box.cornerRadius = 7
        box.bounds = CGRect(x: 0, y: 0, width: ceil(size.width) + pad * 2, height: ceil(size.height) + pad)
        box.position = CGPoint(x: m.x - w.frame.minX + box.bounds.width / 2 + 18, y: m.y - w.frame.minY - 34)
        box.contentsScale = w.scale
        let tl = CATextLayer()
        tl.string = text
        tl.contentsScale = w.scale
        tl.frame = CGRect(x: pad, y: pad / 2 - 1, width: ceil(size.width) + 2, height: ceil(size.height) + 2)
        box.addSublayer(tl)
        w.hud.sublayers?.forEach { $0.removeFromSuperlayer() }
        w.hud.addSublayer(box)
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1
        f.toValue = 0
        f.beginTime = CACurrentMediaTime() + 1.1
        f.duration = 0.5
        f.fillMode = .forwards
        f.isRemovedOnCompletion = false
        box.add(f, forKey: "fade")
        Effects.removeLater([box], after: 1.7)
    }
    func setSize(_ m: Float) {
        sizeMul = m
        rebuildCreature()
    }

    // MARK: 開始・停止

    func start() {
        guard !running else { return }
        running = true
        buildWindows()
        CursorHider.hide()
        NSLog("MushiCursor: started, system cursor visible=\(String(describing: CursorHider.systemCursorVisible)) screens=\(windows.count)")
        installMonitors()
        lastTime = CACurrentMediaTime()
        demoStart = lastTime
        let l = (NSScreen.main ?? NSScreen.screens[0]).displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in CursorHider.reassert() }
    }

    func stop() {
        guard running else { return }
        running = false
        link?.invalidate()
        link = nil
        hideTimer?.invalidate()
        hideTimer = nil
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        CursorHider.show()
    }

    private func buildWindows() {
        for w in windows { w.orderOut(nil) }
        windows = NSScreen.screens.map { OverlayWindow(screen: $0, device: device) }
        for w in windows {
            w.setSpiderSize(layerPt)
            w.orderFrontRegardless()
        }
    }

    @objc private func screensChanged() {
        guard running else { return }
        buildWindows()
    }

    @objc private func didWake() {
        guard running else { return }
        // スリープ明けはカーソルの表示状態が戻されることがある
        CursorHider.show()
        CursorHider.hide()
        buildWindows()
    }

    private func installMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e) }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) { monitors.append(l) }
    }

    private func handle(_ e: NSEvent) {
        guard running else { return }
        switch e.type {
        case .leftMouseDown: sim.mouseDown()
        case .leftMouseUp: if sim.leftDown { sim.mouseUp(strike: clickEffects) }
        case .rightMouseDown: if clickEffects { sim.rightClick() }
        default: break
        }
    }

    // MARK: 毎フレーム

    private var calmSkip = false

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        var mouse = NSEvent.mouseLocation
        // じっとしている間は半分のコマ数で十分（触肢や呼吸のゆっくりした動きだけ）
        let calm = !demoMode && mouse == lastMouse && sim.stillTime > 1.5 && !sim.leftDown && !sim.airborne
            && sim.strikeT > 0.5 && sim.webT > 0.5 && NSEvent.pressedMouseButtons == 0
        if calm {
            calmSkip.toggle()
            if calmSkip { return }
        }
        let dt = Float(min(max(now - lastTime, 1.0 / 240), 0.1))
        lastTime = now
        if demoMode {
            mouse = demoCursor(now - demoStart)
        } else {
            // イベントを取りこぼした時の保険
            let pressed = NSEvent.pressedMouseButtons & 1 != 0
            if !pressed && sim.leftDown { sim.mouseUp(strike: clickEffects) }
        }
        lastMouse = mouse

        let k = ptPerMM
        sim.update(dt: dt, cursor: F2(Float(mouse.x), Float(mouse.y)) / k)
        let pose = sim.pose()
        lastPose = pose
        let events = sim.events
        sim.events.removeAll()

        let center = CGPoint(x: CGFloat(sim.bodyXY.x * k), y: CGFloat(sim.bodyXY.y * k))
        let half = layerPt / 2
        let globalRect = CGRect(x: center.x - half, y: center.y - half, width: layerPt, height: layerPt)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in windows {
            let wf = w.frame
            if wf.intersects(globalRect) {
                let s = w.scale
                let lx = (globalRect.minX - wf.minX)
                let ly = (globalRect.minY - wf.minY)
                let sx = floor(lx * s) / s, sy = floor(ly * s) / s
                w.metal.frame = CGRect(x: sx, y: sy, width: layerPt, height: layerPt)
                w.metal.isHidden = false
                draw(into: w, pose: pose, originGlobal: CGPoint(x: sx + wf.minX, y: sy + wf.minY))
            } else if !w.metal.isHidden {
                w.metal.isHidden = true
            }
            // 伸びている糸
            if silkEnabled, let (a, b) = sim.activeSilk {
                let pa = CGPoint(x: CGFloat(a.x * k) - wf.minX, y: CGFloat(a.y * k) - wf.minY)
                let pb = CGPoint(x: CGFloat(b.x * k) - wf.minX, y: CGFloat(b.y * k) - wf.minY)
                let path = CGMutablePath()
                path.move(to: pa)
                path.addLine(to: pb)
                w.silk.path = path
            } else if w.silk.path != nil {
                w.silk.path = nil
            }
        }
        CATransaction.commit()

        for ev in events { spawn(ev) }
    }

    // MARK: 確認用の自動デモ（--demo）
    var demoMode = false
    private var demoStart: CFTimeInterval = CACurrentMediaTime()
    private var demoFired = Set<Int>()
    private func demoCursor(_ t: Double) -> CGPoint {
        let f = (NSScreen.main ?? NSScreen.screens[0]).frame
        var p = CGPoint(x: f.midX - 150, y: f.midY - 60)
        func ev(_ i: Int, _ at: Double, _ act: () -> Void) { if t >= at && !demoFired.contains(i) { demoFired.insert(i); act() } }
        if t > 1.0 { p.x += min(t - 1.0, 1.5) * 130 }
        ev(1, 2.5) { sim.mouseDown() }
        ev(2, 2.75) { sim.mouseUp(strike: clickEffects) }
        ev(3, 3.5) { sim.rightClick() }
        if t > 4.0 { p.x -= min(t - 4.0, 0.3) * 2000 }
        ev(4, 5.0) { sim.mouseDown() }
        if t > 5.0 { let u = min(t - 5.0, 1.0); p.y += u * 160; p.x += u * 60 }
        ev(5, 6.0) { sim.mouseUp(strike: clickEffects) }
        return p
    }

    private var lastPose: RenderPose?

    private func draw(into w: OverlayWindow, pose: RenderPose, originGlobal: CGPoint) {
        guard let drawable = w.metal.nextDrawable(), let cb = renderer.queue.makeCommandBuffer() else { return }
        renderer.render(pose: pose, ptPerMM: ptPerMM, originPt: SIMD2(Double(originGlobal.x), Double(originGlobal.y)),
                        sizePt: SIMD2(Double(layerPt), Double(layerPt)), scale: Double(w.scale), target: drawable.texture, commandBuffer: cb)
        cb.commit()
        cb.waitUntilScheduled()
        drawable.present()
    }

    private func window(containing p: CGPoint) -> OverlayWindow? {
        windows.first { $0.frame.contains(p) } ?? windows.first
    }

    private func spawn(_ ev: SimEvent) {
        let k = CGFloat(ptPerMM)
        let bodyPt = CGFloat(creature.bodyLengthMM) * k
        func local(_ p: F2) -> (OverlayWindow, CGPoint)? {
            let g = CGPoint(x: CGFloat(p.x) * k, y: CGFloat(p.y) * k)
            guard let w = window(containing: g) else { return nil }
            return (w, CGPoint(x: g.x - w.frame.minX, y: g.y - w.frame.minY))
        }
        switch ev {
        case .bite(let p, let drop):
            guard clickEffects, let (w, q) = local(p) else { return }
            Effects.bite(in: w.fxLayer, top: w.topFx, at: q, dropSize: drop ? max(4, min(bodyPt * 0.12, 9)) : 0)
        case .web(let p):
            guard clickEffects, let (w, q) = local(p) else { return }
            effectSeed &+= 1
            Effects.web(in: w.fxLayer, at: q, size: max(bodyPt, 26), seed: effectSeed)
        case .spray(let p, let dir):
            guard clickEffects, let (w, q) = local(p) else { return }
            effectSeed &+= 1
            Effects.spray(in: w.fxLayer, at: q, dir: CGVector(dx: CGFloat(dir.x), dy: CGFloat(dir.y)), size: max(bodyPt, 26), seed: effectSeed)
        case .footprint(let pt, let ang, let size, let left):
            guard let (w, q) = local(pt) else { return }
            Effects.footprint(in: w.fxLayer, at: q, angle: CGFloat(ang), size: CGFloat(size) * k, left: left)
        case .track(let pt, let ang, let width):
            guard let (w, q) = local(pt) else { return }
            Effects.track(in: w.fxLayer, at: q, angle: CGFloat(ang), width: CGFloat(width) * k, scale: k)
        case .shot(let pt, let dir, let big):
            guard clickEffects, let (w, q) = local(pt) else { return }
            effectSeed &+= 1
            Effects.shot(in: w.fxLayer, top: w.topFx, at: q, dir: CGVector(dx: CGFloat(dir.x), dy: CGFloat(dir.y)), big: big, seed: effectSeed)
        case .downwash(let pt, let size):
            guard clickEffects, let (w, q) = local(pt) else { return }
            Effects.downwash(in: w.fxLayer, at: q, size: CGFloat(size) * k)
        case .beam(let pt, let size):
            guard clickEffects, let (w, q) = local(pt) else { return }
            effectSeed &+= 1
            Effects.beam(in: w.fxLayer, top: w.topFx, at: q, size: CGFloat(size) * k, seed: effectSeed)
        case .roar(let pt, let dir, let size):
            guard clickEffects, let (w, q) = local(pt) else { return }
            Effects.roar(in: w.topFx, at: q, dir: CGVector(dx: CGFloat(dir.x), dy: CGFloat(dir.y)), size: CGFloat(size) * k)
        case .warp(let pt, let size):
            guard clickEffects, let (w, q) = local(pt) else { return }
            Effects.warp(in: w.topFx, at: q, size: CGFloat(size) * k)
        case .silkDone(let a, let b):
            guard silkEnabled else { return }
            let ga = CGPoint(x: CGFloat(a.x) * k, y: CGFloat(a.y) * k)
            let gb = CGPoint(x: CGFloat(b.x) * k, y: CGFloat(b.y) * k)
            for w in windows where w.frame.insetBy(dx: -2000, dy: -2000).contains(ga) {
                Effects.silkDone(in: w.fxLayer, from: CGPoint(x: ga.x - w.frame.minX, y: ga.y - w.frame.minY),
                                 to: CGPoint(x: gb.x - w.frame.minX, y: gb.y - w.frame.minY))
            }
        }
    }
}
