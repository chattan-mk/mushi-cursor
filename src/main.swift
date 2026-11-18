import Foundation

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--effects"), i + 1 < args.count {
    // エフェクト画像の確認用
    let out = args[i + 1]
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    for (n, img) in [("foot", Effects.footImage), ("hole", Effects.holeImage), ("tread", Effects.treadImage), ("dust", Effects.dustRingImage),
                     ("glow", Effects.glowImage), ("ring", Effects.ringImage), ("dot", Effects.dotImage), ("smoke", Effects.smokeImage)] {
        if let im = img { Snapshot.writePNG(im, "\(out)/\(n).png") }
    }
    exit(0)
}
if let i = args.firstIndex(of: "--snapshot") {
    let out = i + 1 < args.count ? args[i + 1] : "snap"
    var species = 0
    var size: Float = 1
    var zoom = 1.0
    if let j = args.firstIndex(of: "--species"), j + 1 < args.count { species = Int(args[j + 1]) ?? 0 }
    if let j = args.firstIndex(of: "--size"), j + 1 < args.count { size = Float(args[j + 1]) ?? 1 }
    if let j = args.firstIndex(of: "--zoom"), j + 1 < args.count { zoom = Double(args[j + 1]) ?? 1 }
    var scale = 2.0
    var only: [Int]? = nil
    if let j = args.firstIndex(of: "--scale"), j + 1 < args.count { scale = Double(args[j + 1]) ?? 2 }
    if let j = args.firstIndex(of: "--only"), j + 1 < args.count { only = args[j + 1].split(separator: ",").compactMap { Int($0) } }
    var times: (Double, Double, Double)? = nil
    if let j = args.firstIndex(of: "--times"), j + 1 < args.count {
        let v = args[j + 1].split(separator: ":").compactMap { Double($0) }
        if v.count == 3 { times = (v[0], v[1], v[2]) }
    }
    Snapshot.run(outDir: out, speciesIndex: species, sizeMul: size, zoom: zoom, scale: scale, only: only, times: times, fixedView: args.contains("--fixed"))
    exit(0)
}

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
