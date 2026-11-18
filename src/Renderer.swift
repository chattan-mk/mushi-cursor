import Foundation
import Metal
import MetalPerformanceShaders
import simd

// シェーダと同じ並び
struct Globals {
    var viewProj = matrix_identity_float4x4
    var light = F4.zero
    var misc = F4.zero
    var vp = F4.zero
    var shadow = F4.zero
    var ell: (F4, F4, F4, F4) = (.zero, .zero, .zero, .zero)
    var feet: (F4, F4, F4, F4, F4, F4, F4, F4, F4, F4) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
}
struct BlobInst { var model: simd_float4x4; var nm0: F4; var nm1: F4; var nm2: F4; var info: F4; var ext: F4 }
struct CapInst { var a: F4; var b: F4; var side: F4; var info: F4 }
struct RibV { var x: Float; var y: Float; var z: Float; var alpha: Float; var t: Float; var kind: Float }

struct Mesh {
    let vbuf: MTLBuffer
    let ibuf: MTLBuffer
    let count: Int
}

final class CreatureRenderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let def: CreatureDef
    private var pBlob: MTLRenderPipelineState!
    private var pBlobShell: MTLRenderPipelineState!
    private var pBlobAlpha: MTLRenderPipelineState!
    private var pCap: MTLRenderPipelineState!
    private var pCapShell: MTLRenderPipelineState!
    private var pRib: MTLRenderPipelineState!
    private var pBlobShadow: MTLRenderPipelineState!
    private var pCapShadow: MTLRenderPipelineState!
    private var pComposite: MTLRenderPipelineState!
    private var dsWrite: MTLDepthStencilState!
    private var dsTest: MTLDepthStencilState!
    private var dsNone: MTLDepthStencilState!
    private var meshes: [Mesh] = []
    private var sphereMesh: Mesh!
    private var capMesh: Mesh!
    private var bristles: [Bristle] = []
    private var blobBufs: [MTLBuffer] = []
    private var capBufs: [MTLBuffer] = []
    private var ribBufs: [MTLBuffer] = []
    private var ring = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var msaaColor: MTLTexture?
    private var msaaDepth: MTLTexture?
    private var shadowTex: MTLTexture?
    private var shadowBlur: MTLTexture?
    private var blur: MPSImageGaussianBlur?
    private var blurSigma: Float = 0
    let sampleCount = 4
    let colorFormat: MTLPixelFormat = .bgra8Unorm
    let lightDir = simd_normalize(F3(-0.34, 0.58, 1.0))
    var lightIntensity: Float = 2.6
    let shellsBody = 14
    let shellsLeg = 8
    static let maxBlobs = 48, maxCaps = 320, maxRib = 6 * 2400

    init?(device: MTLDevice, creature: CreatureDef, shaderSource: String) {
        self.device = device
        guard let q = device.makeCommandQueue() else { return nil }
        queue = q
        def = creature
        do {
            let lib = try device.makeLibrary(source: shaderSource, options: nil)
            try buildPipelines(lib)
        } catch {
            NSLog("シェーダの準備に失敗: \(error)")
            return nil
        }
        meshes = creature.meshShapes.map { shape in blobMesh(n: 22, shape: shape) }
        for md in creature.customMeshes {
            meshes.append(Mesh(vbuf: device.makeBuffer(bytes: md.verts, length: md.verts.count * 4, options: .storageModeShared)!,
                               ibuf: device.makeBuffer(bytes: md.indices, length: md.indices.count * 4, options: .storageModeShared)!, count: md.indices.count))
        }
        sphereMesh = blobMesh(n: 10) { $0 }
        buildCapsule()
        bristles = creature.makeBristles()
        for _ in 0..<3 {
            blobBufs.append(device.makeBuffer(length: MemoryLayout<BlobInst>.stride * CreatureRenderer.maxBlobs, options: .storageModeShared)!)
            capBufs.append(device.makeBuffer(length: MemoryLayout<CapInst>.stride * CreatureRenderer.maxCaps, options: .storageModeShared)!)
            ribBufs.append(device.makeBuffer(length: MemoryLayout<RibV>.stride * CreatureRenderer.maxRib, options: .storageModeShared)!)
        }
    }

    // MARK: パイプライン

    enum Blend { case none, premul, max }

    private func pipe(_ lib: MTLLibrary, _ v: String, _ f: String, color: MTLPixelFormat, samples: Int, depth: Bool, blend: Blend, a2c: Bool) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        d.rasterSampleCount = samples
        d.colorAttachments[0].pixelFormat = color
        if depth { d.depthAttachmentPixelFormat = .depth32Float }
        d.isAlphaToCoverageEnabled = a2c
        d.isAlphaToOneEnabled = a2c
        let ca = d.colorAttachments[0]!
        switch blend {
        case .none: ca.isBlendingEnabled = false
        case .premul:
            ca.isBlendingEnabled = true
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .max:
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .max
            ca.alphaBlendOperation = .max
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .one
        }
        return try device.makeRenderPipelineState(descriptor: d)
    }

    private func buildPipelines(_ lib: MTLLibrary) throws {
        let s = sampleCount
        pBlob = try pipe(lib, "vBlob", "fSolid", color: colorFormat, samples: s, depth: true, blend: .none, a2c: false)
        pBlobShell = try pipe(lib, "vBlob", "fShell", color: colorFormat, samples: s, depth: true, blend: .none, a2c: true)
        pBlobAlpha = try pipe(lib, "vBlob", "fAlpha", color: colorFormat, samples: s, depth: true, blend: .premul, a2c: false)
        pCap = try pipe(lib, "vCap", "fSolid", color: colorFormat, samples: s, depth: true, blend: .none, a2c: false)
        pCapShell = try pipe(lib, "vCap", "fShell", color: colorFormat, samples: s, depth: true, blend: .none, a2c: true)
        pRib = try pipe(lib, "vRib", "fRib", color: colorFormat, samples: s, depth: true, blend: .none, a2c: true)
        pComposite = try pipe(lib, "vQuad", "fComposite", color: colorFormat, samples: s, depth: true, blend: .premul, a2c: false)
        pBlobShadow = try pipe(lib, "vBlobShadow", "fShadow", color: .r16Float, samples: 1, depth: false, blend: .max, a2c: false)
        pCapShadow = try pipe(lib, "vCapShadow", "fShadow", color: .r16Float, samples: 1, depth: false, blend: .max, a2c: false)
        let dw = MTLDepthStencilDescriptor()
        dw.depthCompareFunction = .lessEqual
        dw.isDepthWriteEnabled = true
        dsWrite = device.makeDepthStencilState(descriptor: dw)
        let dt = MTLDepthStencilDescriptor()
        dt.depthCompareFunction = .lessEqual
        dt.isDepthWriteEnabled = false
        dsTest = device.makeDepthStencilState(descriptor: dt)
        let dn = MTLDepthStencilDescriptor()
        dn.depthCompareFunction = .always
        dn.isDepthWriteEnabled = false
        dsNone = device.makeDepthStencilState(descriptor: dn)
    }

    // MARK: メッシュ

    /// 立方体を膨らませた球（極のない球）に形状関数を当てて作る
    private func blobMesh(n: Int, shape: (F3) -> F3) -> Mesh {
        var verts: [Float] = []
        var idx: [UInt32] = []
        let faces: [(F3, F3, F3)] = [
            (F3(1, 0, 0), F3(0, 1, 0), F3(0, 0, 1)), (F3(-1, 0, 0), F3(0, 0, 1), F3(0, 1, 0)),
            (F3(0, 1, 0), F3(0, 0, 1), F3(1, 0, 0)), (F3(0, -1, 0), F3(1, 0, 0), F3(0, 0, 1)),
            (F3(0, 0, 1), F3(1, 0, 0), F3(0, 1, 0)), (F3(0, 0, -1), F3(0, 1, 0), F3(1, 0, 0)),
        ]
        let eps: Float = 0.002
        for (o, U, Vv) in faces {
            let base = UInt32(verts.count / 6)
            for j in 0...n {
                for i in 0...n {
                    let u = Float(i) / Float(n) * 2 - 1
                    let v = Float(j) / Float(n) * 2 - 1
                    let c = o + U * u + Vv * v
                    let d = simd_normalize(c)
                    let p = shape(d)
                    let pu = shape(simd_normalize(c + U * eps)) - shape(simd_normalize(c - U * eps))
                    let pv = shape(simd_normalize(c + Vv * eps)) - shape(simd_normalize(c - Vv * eps))
                    var nrm = simd_cross(pu, pv)
                    nrm = simd_length(nrm) > 1e-12 ? simd_normalize(nrm) : d
                    if simd_dot(nrm, p) < 0 { nrm = -nrm }
                    verts += [p.x, p.y, p.z, nrm.x, nrm.y, nrm.z]
                }
            }
            let w = UInt32(n + 1)
            for j in 0..<UInt32(n) {
                for i in 0..<UInt32(n) {
                    let a = base + j * w + i
                    idx += [a, a + 1, a + w, a + 1, a + w + 1, a + w]
                }
            }
        }
        let vb = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)!
        let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)!
        return Mesh(vbuf: vb, ibuf: ib, count: idx.count)
    }

    private func buildCapsule() {
        // カプセル：(種類, パラメータ, 角度)
        let nSeg = 12, nCap = 4, nBody = 6
        var rings: [(Float, Float)] = []
        for k in 0...nCap { rings.append((0, Float.pi / 2 * (1 - Float(k) / Float(nCap)))) }
        for k in 0...nBody { rings.append((1, Float(k) / Float(nBody))) }
        for k in 0...nCap { rings.append((2, Float.pi / 2 * Float(k) / Float(nCap))) }
        var verts: [Float] = []
        for (kind, v) in rings {
            for j in 0...nSeg { verts += [kind, v, Float(j) / Float(nSeg) * 2 * .pi] }
        }
        var idx: [UInt32] = []
        let w = UInt32(nSeg + 1)
        for r in 0..<UInt32(rings.count - 1) {
            for j in 0..<UInt32(nSeg) {
                let a = r * w + j
                idx += [a, a + w, a + 1, a + 1, a + w, a + w + 1]
            }
        }
        capMesh = Mesh(vbuf: device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)!,
                       ibuf: device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)!,
                       count: idx.count)
    }

    func layerRadiusMM() -> Float { def.layerRadiusMM() }

    private func ensureTextures(width: Int, height: Int, pxPerMM: Float) {
        if msaaColor?.width != width || msaaColor?.height != height {
            let cd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
            cd.textureType = .type2DMultisample
            cd.sampleCount = sampleCount
            cd.usage = .renderTarget
            cd.storageMode = .memoryless
            msaaColor = device.makeTexture(descriptor: cd)
            let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            dd.textureType = .type2DMultisample
            dd.sampleCount = sampleCount
            dd.usage = .renderTarget
            dd.storageMode = .memoryless
            msaaDepth = device.makeTexture(descriptor: dd)
            let sw = max(width / 2, 1), sh = max(height / 2, 1)
            let sd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: sw, height: sh, mipmapped: false)
            sd.usage = [.renderTarget, .shaderRead, .shaderWrite]
            sd.storageMode = .private
            shadowTex = device.makeTexture(descriptor: sd)
            shadowBlur = device.makeTexture(descriptor: sd)
        }
        let sigma = max(0.7, min(def.bodyZ, 4.5) * 0.09 * pxPerMM * 0.5)
        if blur == nil || abs(sigma - blurSigma) > 0.05 {
            blur = MPSImageGaussianBlur(device: device, sigma: sigma)
            blur?.edgeMode = .zero
            blurSigma = sigma
        }
    }

    private func blobInst(_ b: BlobPose) -> BlobInst {
        let nm = normalMatrix(b.model)
        return BlobInst(model: b.model, nm0: F4(nm.columns.0, 0), nm1: F4(nm.columns.1, 0), nm2: F4(nm.columns.2, 0),
                        info: F4(b.part.rawValue, b.hair, def.hairSpacing, b.seed), ext: F4(b.ext, b.extW))
    }

    private func mesh(_ i: Int) -> Mesh { i >= 0 && i < meshes.count ? meshes[i] : sphereMesh }

    /// target（描画先テクスチャ）は originPt から sizePt の範囲（グローバル座標, pt）を写す
    func render(pose: RenderPose, ptPerMM: Float, originPt: SIMD2<Double>, sizePt: SIMD2<Double>, scale: Double,
                target: MTLTexture, commandBuffer cb: MTLCommandBuffer, clear: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)) {
        inflight.wait()
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }
        ring = (ring + 1) % 3
        let blobBuf = blobBufs[ring], capBuf = capBufs[ring], ribBuf = ribBufs[ring]
        let pxPerMM = ptPerMM * Float(scale)
        ensureTextures(width: target.width, height: target.height, pxPerMM: pxPerMM)

        // ---- 共通パラメータ ----
        var g = Globals()
        let ox = Float(originPt.x) / ptPerMM, oy = Float(originPt.y) / ptPerMM
        let sx = Float(sizePt.x) / ptPerMM, sy = Float(sizePt.y) / ptPerMM
        g.viewProj = simd_float4x4(F4(2 / sx, 0, 0, 0), F4(0, 2 / sy, 0, 0), F4(0, 0, -0.004, 0), F4(-2 * ox / sx - 1, -2 * oy / sy - 1, 0.5, 1))
        g.light = F4(lightDir, lightIntensity)
        g.misc = F4(pxPerMM, pose.time, Float(def.shaderID), def.hairSpacing)
        g.vp = F4(ox, oy, sx, sy)
        g.shadow = F4(0.60, def.bodyZ * 2.2, 0.30, 0.6)
        if pose.ell.count >= 4 { g.ell = (pose.ell[0], pose.ell[1], pose.ell[2], pose.ell[3]) }
        withUnsafeMutableBytes(of: &g.feet) { raw in
            let p = raw.bindMemory(to: F4.self)
            for i in 0..<10 { p[i] = i < pose.feet.count ? pose.feet[i] : .zero }
        }

        // ---- 胴体 ----
        let blobs = Array(pose.blobs.prefix(CreatureRenderer.maxBlobs))
        let insts = blobs.map { blobInst($0) }
        _ = insts.withUnsafeBytes { memcpy(blobBuf.contents(), $0.baseAddress!, $0.count) }
        let bStride = MemoryLayout<BlobInst>.stride

        // ---- 関節列 → カプセル（毛のあるものを先に）----
        var caps: [CapInst] = []
        var seed: Float = 0
        for pass in 0..<2 {
            for (ci, c) in pose.chains.enumerated() where (c.hairy && c.hair > 0) == (pass == 0) {
                for k in 0..<(c.joints.count - 1) {
                    let r = k < c.radii.count ? c.radii[k] : c.radii.last ?? (0.1, 0.1)
                    caps.append(capInst(c.joints[k], c.joints[k + 1], r.0, r.1, side: c.side, part: c.part, seg: k + c.segOffset,
                                        leg: c.limb, hair: pass == 0 ? c.hair : 0, seed: Float(ci * 11 + k)))
                    seed += 1
                }
            }
        }
        let nHairyCaps = pose.chains.filter { $0.hairy && $0.hair > 0 }.reduce(0) { $0 + $1.joints.count - 1 }
        caps += pose.caps
        if caps.count > CreatureRenderer.maxCaps { caps = Array(caps.prefix(CreatureRenderer.maxCaps)) }
        let nCaps = caps.count
        _ = caps.withUnsafeBytes { memcpy(capBuf.contents(), $0.baseAddress!, $0.count) }

        // ---- 剛毛 ----
        let nRib = buildRibbons(pose: pose, pxPerMM: pxPerMM, into: ribBuf)

        // ---- 影パス ----
        let sp1 = MTLRenderPassDescriptor()
        sp1.colorAttachments[0].texture = shadowTex
        sp1.colorAttachments[0].loadAction = .clear
        sp1.colorAttachments[0].storeAction = .store
        sp1.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let e = cb.makeRenderCommandEncoder(descriptor: sp1) {
            e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 2)
            e.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 0)
            e.setRenderPipelineState(pBlobShadow)
            for (i, b) in blobs.enumerated() where b.shadow {
                e.setVertexBuffer(blobBuf, offset: bStride * i, index: 1)
                drawMesh(e, mesh(b.mesh), instances: 1)
            }
            e.setRenderPipelineState(pCapShadow)
            e.setVertexBuffer(capBuf, offset: 0, index: 1)
            drawMesh(e, capMesh, instances: nCaps)
            e.endEncoding()
        }
        blur?.encode(commandBuffer: cb, sourceTexture: shadowTex!, destinationTexture: shadowBlur!)

        // ---- 本描画 ----
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = msaaColor
        rp.colorAttachments[0].resolveTexture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .multisampleResolve
        rp.colorAttachments[0].clearColor = clear
        rp.depthAttachment.texture = msaaDepth
        rp.depthAttachment.loadAction = .clear
        rp.depthAttachment.storeAction = .dontCare
        rp.depthAttachment.clearDepth = 1
        guard let e = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        e.setVertexBytes(&g, length: MemoryLayout<Globals>.stride, index: 2)
        e.setFragmentBytes(&g, length: MemoryLayout<Globals>.stride, index: 0)

        e.setDepthStencilState(dsNone)
        e.setRenderPipelineState(pComposite)
        e.setFragmentTexture(shadowBlur, index: 0)
        e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 不透明な体
        e.setDepthStencilState(dsWrite)
        e.setRenderPipelineState(pBlob)
        var one = F4(0, 1, 0, 0)
        e.setVertexBytes(&one, length: 16, index: 3)
        for (i, b) in blobs.enumerated() where !b.alpha {
            e.setVertexBuffer(blobBuf, offset: bStride * i, index: 1)
            drawMesh(e, mesh(b.mesh), instances: 1)
        }
        e.setRenderPipelineState(pCap)
        var shC = F4(0, Float(nCaps), 0, 0)
        e.setVertexBytes(&shC, length: 16, index: 3)
        e.setVertexBuffer(capBuf, offset: 0, index: 1)
        drawMesh(e, capMesh, instances: nCaps)

        if nRib > 0 {
            e.setDepthStencilState(dsTest)
            e.setRenderPipelineState(pRib)
            e.setVertexBuffer(ribBuf, offset: 0, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nRib)
        }

        // 毛（シェル）
        e.setDepthStencilState(dsWrite)
        e.setRenderPipelineState(pBlobShell)
        var shB = F4(Float(shellsBody), 1, 0, 0)
        e.setVertexBytes(&shB, length: 16, index: 3)
        for (i, b) in blobs.enumerated() where b.shells && b.hair > 0 && !b.alpha {
            e.setVertexBuffer(blobBuf, offset: bStride * i, index: 1)
            drawMesh(e, mesh(b.mesh), instances: shellsBody)
        }
        if nHairyCaps > 0 {
            e.setRenderPipelineState(pCapShell)
            var shL = F4(Float(shellsLeg), Float(nHairyCaps), 0, 0)
            e.setVertexBytes(&shL, length: 16, index: 3)
            e.setVertexBuffer(capBuf, offset: 0, index: 1)
            drawMesh(e, capMesh, instances: shellsLeg * nHairyCaps)
        }

        // 半透明の膜（後翅）
        if blobs.contains(where: { $0.alpha }) {
            e.setDepthStencilState(dsTest)
            e.setRenderPipelineState(pBlobAlpha)
            e.setVertexBytes(&one, length: 16, index: 3)
            for (i, b) in blobs.enumerated() where b.alpha {
                e.setVertexBuffer(blobBuf, offset: bStride * i, index: 1)
                drawMesh(e, mesh(b.mesh), instances: 1)
            }
        }
        e.endEncoding()
    }

    private func drawMesh(_ e: MTLRenderCommandEncoder, _ m: Mesh, instances: Int) {
        guard instances > 0 else { return }
        e.setVertexBuffer(m.vbuf, offset: 0, index: 0)
        e.drawIndexedPrimitives(type: .triangle, indexCount: m.count, indexType: .uint32, indexBuffer: m.ibuf, indexBufferOffset: 0, instanceCount: instances)
    }

    private func buildRibbons(pose: RenderPose, pxPerMM: Float, into buf: MTLBuffer) -> Int {
        let cap = CreatureRenderer.maxRib
        let p = buf.contents().bindMemory(to: RibV.self, capacity: cap)
        var n = 0
        let minW = 1.0 / pxPerMM
        let up = F3(0, 0, 1)
        for b in bristles {
            if n + 6 > cap { break }
            var base: F3, tip: F3
            if b.chain >= 0 {
                guard b.chain < pose.chains.count else { continue }
                let c = pose.chains[b.chain]
                guard b.seg + 1 < c.joints.count else { continue }
                let r = b.seg < c.radii.count ? c.radii[b.seg] : (0.1, 0.1)
                let rad = mixf(r.0, r.1, b.t)
                let a = c.joints[b.seg], cc = c.joints[b.seg + 1]
                let ax = cc - a
                let len = simd_length(ax)
                if len < 1e-5 { continue }
                let e = ax / len
                var dor = up - e * simd_dot(up, e)
                dor = simd_length(dor) < 1e-3 ? F3(1, 0, 0) : simd_normalize(dor)
                let n2 = simd_cross(e, dor)
                let radial = dor * cos(b.phi) + n2 * sin(b.phi)
                base = a + ax * b.t + radial * rad * 0.92
                let dir = simd_normalize(radial * cos(b.tilt) + e * sin(b.tilt))
                tip = base + dir * b.len + e * (b.len * 0.12)
            } else if b.blob >= 0 && b.blob < pose.blobs.count {
                let m = pose.blobs[b.blob].model
                let r = simd_float3x3(xyz(m.columns.0), xyz(m.columns.1), xyz(m.columns.2))
                base = xyz(m * F4(b.pos, 1))
                tip = base + r * b.dir * b.len
            } else { continue }
            let d2 = F2(tip.x - base.x, tip.y - base.y)
            let dl = simd_length(d2)
            if dl < 1e-5 { continue }
            let perp = F2(-d2.y, d2.x) / dl
            let w0 = b.width, w1 = b.width * 0.25
            let hw0 = max(w0, minW) * 0.5, hw1 = max(w1, minW) * 0.5
            let a0 = min(1, w0 / minW) * 0.95, a1 = min(1, w1 / minW) * 0.7
            let b0 = base + F3(perp.x, perp.y, 0) * hw0, b1 = base - F3(perp.x, perp.y, 0) * hw0
            let t0 = tip + F3(perp.x, perp.y, 0) * hw1, t1 = tip - F3(perp.x, perp.y, 0) * hw1
            p[n] = RibV(x: b0.x, y: b0.y, z: b0.z, alpha: a0, t: 0, kind: b.kind)
            p[n + 1] = RibV(x: b1.x, y: b1.y, z: b1.z, alpha: a0, t: 0, kind: b.kind)
            p[n + 2] = RibV(x: t0.x, y: t0.y, z: t0.z, alpha: a1, t: 1, kind: b.kind)
            p[n + 3] = RibV(x: b1.x, y: b1.y, z: b1.z, alpha: a0, t: 0, kind: b.kind)
            p[n + 4] = RibV(x: t1.x, y: t1.y, z: t1.z, alpha: a1, t: 1, kind: b.kind)
            p[n + 5] = RibV(x: t0.x, y: t0.y, z: t0.z, alpha: a1, t: 1, kind: b.kind)
            n += 6
        }
        return n
    }
}
