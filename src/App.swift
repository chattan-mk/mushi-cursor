import AppKit
import Carbon

/// 全体ショートカット（権限不要の Carbon ホットキー）。複数登録できる
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private static var actions: [UInt32: () -> Void] = [:]
    private static var installed = false

    func add(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        if !HotKeys.installed {
            HotKeys.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var hk = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { HotKeys.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(HotKeys.actions.count + 1)
        HotKeys.actions[id] = action
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4D555348), id: id), GetApplicationEventTarget(), 0, &ref)
        if st != noErr { NSLog("MushiCursor: hotkey \(keyCode) register failed \(st)") }
        refs.append(ref)
    }
}

/// ⌘⌥D は macOS の「Dock を自動的に表示/非表示」に使われているので、
/// このアプリが動いている間だけそのショートカットを休ませ、終了時に元へ戻す
enum SystemShortcut {
    private typealias IsEn = @convention(c) (UInt32) -> Bool
    private typealias SetEn = @convention(c) (UInt32, Bool) -> Int32
    static let dockHiding: UInt32 = 52
    private static let restoreKey = "restoreDockShortcut"
    private static var fns: (IsEn, SetEn)? = {
        guard let h = dlopen(nil, RTLD_NOW), let i = dlsym(h, "CGSIsSymbolicHotKeyEnabled"), let s = dlsym(h, "CGSSetSymbolicHotKeyEnabled") else { return nil }
        return (unsafeBitCast(i, to: IsEn.self), unsafeBitCast(s, to: SetEn.self))
    }()

    static func borrowDockShortcut() {
        guard let (isEn, setEn) = fns else { return }
        if isEn(dockHiding) {
            _ = setEn(dockHiding, false)
            UserDefaults.standard.set(true, forKey: restoreKey)
        }
    }
    static func returnDockShortcut() {
        guard let (_, setEn) = fns, UserDefaults.standard.bool(forKey: restoreKey) else { return }
        _ = setEn(dockHiding, true)
        UserDefaults.standard.set(false, forKey: restoreKey)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var overlay: OverlayController!
    private let hotKeys = HotKeys()
    private var termSource: DispatchSourceSignal?
    private let defaults = UserDefaults.standard
    private let sizes: [(String, Float)] = [("実物大", 0.63), ("小", 0.8), ("中", 1.0), ("大", 1.4), ("特大", 2.0)]
    private let agentLabel = "com.neuwonka.mushicursor"

    private var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }
    private var creatureIndex: Int {
        get { min(max(defaults.integer(forKey: "species"), 0), Creatures.all.count - 1) }
        set { defaults.set(newValue, forKey: "species") }
    }
    private var sizeMul: Float {
        get { defaults.object(forKey: "size") as? Float ?? 1.0 }
        set { defaults.set(newValue, forKey: "size") }
    }
    private var clickFx: Bool {
        get { defaults.object(forKey: "clickFx") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "clickFx") }
    }
    private var silk: Bool {
        get { defaults.object(forKey: "silk") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "silk") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        CursorHider.prepare()
        guard let o = OverlayController(creature: Creatures.all[creatureIndex], sizeMul: sizeMul) else {
            let a = NSAlert()
            a.messageText = "虫カーソルを起動できませんでした"
            a.informativeText = "Metal（GPU）の準備に失敗しました。"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        overlay = o
        overlay.clickEffects = clickFx
        overlay.silkEnabled = silk
        overlay.demoMode = CommandLine.arguments.contains("--demo")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppDelegate.menuIcon()
        statusItem.button?.toolTip = "虫カーソル"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // ⌘⌥S で出す／しまう、⌘⌥D で次の生き物へ（⇧⌘⌥D で前へ）
        SystemShortcut.borrowDockShortcut()
        hotKeys.add(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in self?.toggle() }
        hotKeys.add(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | cmdKey)) { [weak self] in self?.cycle(1) }
        hotKeys.add(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | cmdKey | shiftKey)) { [weak self] in self?.cycle(-1) }
        // pkill などで終了させられても Dock のショートカットを戻す
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        termSource = src

        if enabled { overlay.start() }
    }

    func applicationWillTerminate(_ n: Notification) {
        overlay?.stop()
        CursorHider.show()
        SystemShortcut.returnDockShortcut()
    }

    /// 生き物を順に切り替える（しまっている時は出してから）
    func cycle(_ step: Int) {
        let n = Creatures.all.count
        creatureIndex = ((creatureIndex + step) % n + n) % n
        overlay.setCreature(Creatures.all[creatureIndex])
        if !enabled {
            enabled = true
            overlay.start()
            overlay.showName(Creatures.all[creatureIndex].name)
        }
    }

    @objc func toggle() {
        enabled.toggle()
        if enabled { overlay.start() } else { overlay.stop() }
    }

    // MARK: メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "虫カーソル — \(Creatures.all[creatureIndex].name)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let t = NSMenuItem(title: enabled ? "虫をしまう（ふつうのカーソルに戻す）" : "虫を出す", action: #selector(toggle), keyEquivalent: "s")
        t.keyEquivalentModifierMask = [.option, .command]
        t.target = self
        menu.addItem(t)
        menu.addItem(.separator())

        let next = NSMenuItem(title: "次の生き物へ", action: #selector(nextCreature), keyEquivalent: "d")
        next.keyEquivalentModifierMask = [.option, .command]
        next.target = self
        menu.addItem(next)
        let kind = NSMenuItem(title: "種類", action: nil, keyEquivalent: "")
        let km = NSMenu()
        for (i, c) in Creatures.all.enumerated() {
            let it = NSMenuItem(title: c.name, action: #selector(pickSpecies(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = i == creatureIndex ? .on : .off
            km.addItem(it)
        }
        kind.submenu = km
        menu.addItem(kind)

        let size = NSMenuItem(title: "大きさ", action: nil, keyEquivalent: "")
        let sm = NSMenu()
        for (i, s) in sizes.enumerated() {
            let it = NSMenuItem(title: s.0, action: #selector(pickSize(_:)), keyEquivalent: "")
            it.tag = i
            it.target = self
            it.state = abs(s.1 - sizeMul) < 0.01 ? .on : .off
            sm.addItem(it)
        }
        size.submenu = sm
        menu.addItem(size)

        let fx = NSMenuItem(title: "クリックのアクション（飛びかかる・右クリックで網や翅）", action: #selector(toggleFx), keyEquivalent: "")
        fx.target = self
        fx.state = clickFx ? .on : .off
        menu.addItem(fx)
        let sk = NSMenuItem(title: "ドラッグ・ジャンプで糸を引く", action: #selector(toggleSilk), keyEquivalent: "")
        sk.target = self
        sk.state = silk ? .on : .off
        menu.addItem(sk)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = FileManager.default.fileExists(atPath: agentPath) ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let q = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    @objc func pickSpecies(_ s: NSMenuItem) {
        creatureIndex = s.tag
        overlay.setCreature(Creatures.all[s.tag])
    }
    @objc func nextCreature() { cycle(1) }
    @objc func pickSize(_ s: NSMenuItem) {
        sizeMul = sizes[s.tag].1
        overlay.setSize(sizeMul)
    }
    @objc func toggleFx() {
        clickFx.toggle()
        overlay.clickEffects = clickFx
    }
    @objc func toggleSilk() {
        silk.toggle()
        overlay.silkEnabled = silk
        overlay.demoMode = CommandLine.arguments.contains("--demo")
    }
    @objc func quit() {
        overlay.stop()
        NSApp.terminate(nil)
    }

    // MARK: ログイン時に起動（LaunchAgent）

    private var agentPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
    @objc func toggleLogin() {
        let fm = FileManager.default
        if fm.fileExists(atPath: agentPath) {
            try? fm.removeItem(atPath: agentPath)
            return
        }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try? fm.createDirectory(atPath: (agentPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? d.write(to: URL(fileURLWithPath: agentPath))
        }
    }

    /// メニューバー用の小さなクモ（テンプレート画像）
    static func menuIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setFillColor(NSColor.black.cgColor)
            c.setStrokeColor(NSColor.black.cgColor)
            c.setLineWidth(1.1)
            c.setLineCap(.round)
            c.setLineJoin(.round)
            let cx: CGFloat = 9
            for side in [CGFloat(1), -1] {
                for (k, (a, b)) in [(0.55, 0.95), (0.25, 0.35), (-0.15, -0.35), (-0.45, -0.95)].enumerated() {
                    let y0: CGFloat = 10.2 - CGFloat(k) * 1.2
                    c.move(to: CGPoint(x: cx + side * 1.5, y: y0))
                    c.addLine(to: CGPoint(x: cx + side * 5.0, y: y0 + CGFloat(a) * 3.5))
                    c.addLine(to: CGPoint(x: cx + side * 7.6, y: y0 + CGFloat(b) * 3.6))
                }
            }
            c.strokePath()
            c.fillEllipse(in: CGRect(x: cx - 2.3, y: 8.0, width: 4.6, height: 5.0))
            c.fillEllipse(in: CGRect(x: cx - 2.8, y: 2.4, width: 5.6, height: 6.4))
            _ = r
            return true
        }
        img.isTemplate = true
        return img
    }
}
