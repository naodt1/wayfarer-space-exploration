import Foundation
import Metal
import simd

struct FrameU { var view: float4x4; var proj: float4x4; var viewProj: float4x4; var invViewProj: float4x4; var sun: F4; var misc: F4; var camFwd: F4
    var shadow0 = matrix_identity_float4x4; var shadow1 = matrix_identity_float4x4; var shadowP = F4.zero; var shadowQ = F4.zero; var blob = F4.zero; var blob2 = F4.zero }
let SHADOW_SIZE = 2048
struct RockGPU { var posScale: F4; var quat: F4; var tint: F4 }
struct RockU { var sun: F4; var sky: F4; var up: F4; var mean: F4 }
struct RockSeg { let kind: Int; let lod: Int; let start: Int; let count: Int; let pass: Int }   // pass 0 main, 1 near shadow, 2 wide shadow
let ROCK_CAP = 24000
struct ObjU { var model: float4x4; var p0: F4 = .zero; var p1: F4 = .zero; var p2: F4 = .zero; var color: F4 = .zero; var p3: F4 = .zero; var p4: F4 = .zero; var p5: F4 = .zero; var p6: F4 = .zero }
struct AtmoPlanetU { var centerR: F4; var topHrHmG: F4; var rayleigh: F4; var mieTint: F4 }
struct GlowU { var posSize: F4; var color: F4 }

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let game: Game
    let terrain: Terrain

    private var pTerrain, pSun, pCloud, pStar, pShip, pPlume, pGlow, pStreak, pAtmo, pBright, pDown, pUp, pUpAdd, pComposite: MTLRenderPipelineState!
    private var dsWrite, dsTest, dsNone, dsShadow: MTLDepthStencilState!
    private var pShadowTerrain, pShadowShip: MTLRenderPipelineState!
    private let shadowTex: MTLTexture
    private var pRock, pShadowRock, pGrass: MTLRenderPipelineState!
    private let grassClumps: [RockLOD]
    let rocks: RockSet?
    let rockField: RockField?
    private var rockBufs: [MTLBuffer] = []
    private var rockRing = 0
    private var glowBufs: [MTLBuffer] = []
    private var glowRing = 0
    private let sampler: MTLSamplerState
    private let detailTex, ventTex: MTLTexture
    private let paintTex: [MTLTexture]
    private let screenTex: MTLTexture
    private let groundMats: TerrainMaterials?
    private let sphere: GPUMesh
    private let astro: [GPUMesh]
    private let siteMeshes: [GPUMesh]
    private let depotMesh: GPUMesh
    private let depotLights: [D3], depotBeacon: D3
    private let cargoKit: (platform: GPUMesh, door: GPUMesh, rover: GPUMesh)
    var propAssets: [String: PropAsset] = [:]
    private var pNozzle: MTLRenderPipelineState!, nozzleMesh: GPUMesh!
    private var pSkin: MTLRenderPipelineState!, pShadowSkin: MTLRenderPipelineState!, player: SkinnedModel?, boneBufs: [MTLBuffer] = [], boneRing = 0
    private var blackTex: MTLTexture!, skyTex: MTLTexture?, pSky: MTLRenderPipelineState!
    private let tankerKit: (mesh: GPUMesh, boomTip: D3, engines: [D3], lights: [(D3, SIMD3<Float>)])
    private let starBuf: MTLBuffer
    private let starCount: Int
    private let streakBuf: MTLBuffer

    private var hdr: MTLTexture?, depth: MTLTexture?, bloom: [MTLTexture] = []
    private(set) var targetW = 0, targetH = 0      // the internal 3D render resolution
    private(set) var outputW = 0, outputH = 0      // the window's drawable (what it is scaled up to)
    var renderScale = 1.0
    var maxPixels = 10e6
    private(set) var lastAspect: Float = 1.6
    let outputFormat: MTLPixelFormat = .bgra8Unorm_srgb

    init(device: MTLDevice, game: Game, terrain: Terrain) throws {
        self.device = device; self.game = game; self.terrain = terrain
        queue = device.makeCommandQueue()!
        var src = shaderSource
        if let exp = ProcessInfo.processInfo.environment["WAYFARER_EXP"] {   // dev-only: "find=>replace;;find=>replace"
            for pair in exp.components(separatedBy: ";;") { let p = pair.components(separatedBy: "=>"); if p.count == 2 { src = src.replacingOccurrences(of: p[0], with: p[1]) } }
        }
        let lib = try device.makeLibrary(source: src, options: nil)
        func pipe(_ v: String, _ f: String, color: MTLPixelFormat = .rgba16Float, depth: Bool = true, blend: String = "none") throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v); d.fragmentFunction = lib.makeFunction(name: f)
            d.colorAttachments[0].pixelFormat = color
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            let c = d.colorAttachments[0]!
            switch blend {
            case "add": c.isBlendingEnabled = true; c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .one; c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            case "premul": c.isBlendingEnabled = true; c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .oneMinusSourceAlpha; c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            case "dual": c.isBlendingEnabled = true; c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = .source1Color; c.sourceAlphaBlendFactor = .zero; c.destinationAlphaBlendFactor = .one
            default: break
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pTerrain = try pipe("terrainV", "terrainF")
        pSun = try pipe("sphereV", "emissiveF")
        pCloud = try pipe("sphereV", "cloudF", blend: "premul")
        pStar = try pipe("starV", "starF", blend: "add")
        pSky = try pipe("skyV", "skyF", blend: "add")
        pShip = try pipe("shipV", "shipF")
        pPlume = try pipe("plumeV", "plumeF", blend: "add")
        pNozzle = try pipe("plumeV", "nozzleF", blend: "add")
        pGlow = try pipe("glowV", "glowF", blend: "add")
        pStreak = try pipe("streakV", "streakF", blend: "add")
        pAtmo = try pipe("quadV", "atmoF", depth: false, blend: "dual")
        pBright = try pipe("quadV", "brightF", depth: false)
        pDown = try pipe("quadV", "downF", depth: false)
        pUp = try pipe("quadV", "upF", depth: false)
        pUpAdd = try pipe("quadV", "upF", depth: false, blend: "add")
        pComposite = try pipe("quadV", "compositeF", color: outputFormat, depth: false)
        func depthPipe(_ v: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v); d.depthAttachmentPixelFormat = .depth32Float
            return try device.makeRenderPipelineState(descriptor: d)
        }
        pShadowTerrain = try depthPipe("terrainV"); pShadowShip = try depthPipe("shipV"); pShadowRock = try depthPipe("rockV")
        pShadowSkin = try depthPipe("skinV"); pSkin = try pipe("skinV", "shipF")
        pRock = try pipe("rockV", "rockF"); pGrass = try pipe("grassV", "grassF")
        rocks = loadRocks(device: device)
        rockField = rocks.map { RockField(kindCount: $0.kinds.count, mean: $0.mean) }
        grassClumps = buildGrassClumps(device: device)
        for _ in 0..<3 { glowBufs.append(device.makeBuffer(length: 2048 * MemoryLayout<GlowU>.stride, options: .storageModeShared)!) }
        for _ in 0..<3 { rockBufs.append(device.makeBuffer(length: ROCK_CAP * MemoryLayout<RockGPU>.stride, options: .storageModeShared)!) }
        let sdd = MTLTextureDescriptor()
        sdd.textureType = .type2DArray; sdd.pixelFormat = .depth32Float; sdd.width = SHADOW_SIZE; sdd.height = SHADOW_SIZE; sdd.arrayLength = 2
        sdd.usage = [.renderTarget, .shaderRead]; sdd.storageMode = .private
        shadowTex = device.makeTexture(descriptor: sdd)!

        func ds(_ cmp: MTLCompareFunction, _ write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor(); d.depthCompareFunction = cmp; d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        dsWrite = ds(.greater, true); dsTest = ds(.greater, false); dsNone = ds(.always, false); dsShadow = ds(.less, true)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear; sd.sAddressMode = .repeat; sd.tAddressMode = .repeat; sd.maxAnisotropy = 8
        sampler = device.makeSamplerState(descriptor: sd)!
        detailTex = makeDetailTexture(device: device); ventTex = makeVentTexture(device: device)
        paintTex = [makePanelTexture(device: device), makeCondorPanelTexture(device: device), makeAtlasPanelTexture(device: device)]
        screenTex = makeScreenAtlas(device: device)
        groundMats = loadTerrainMaterials(device: device)
        if let gm = groundMats?.means[Layer.grass.rawValue] { rockField?.grassMean = SIMD3(gm.x, gm.y, gm.z) }
        sphere = uvSphere(device: device)
        astro = buildAstronaut(device: device)
        siteMeshes = buildSiteMeshes(device: device)
        (depotMesh, depotLights, depotBeacon) = buildDepotMesh(device: device)
        tankerKit = buildTankerMesh(device: device)
        nozzleMesh = nozzleDisc(device: device)
        player = loadSkinnedModel(device: device, name: "player")
        for _ in 0..<3 { boneBufs.append(device.makeBuffer(length: 128 * 64, options: .storageModeShared)!) }
        // downloaded models (Props.swift) and the nebula sky
        func tiny(_ px: [UInt8], srgb: Bool) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: 1, height: 1, mipmapped: false)
            let t = device.makeTexture(descriptor: d)!; t.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: px, bytesPerRow: 4); return t
        }
        blackTex = tiny([0, 0, 0, 255], srgb: true)
        for name in Set(game.props.map { $0.asset } + ["truckbody", "truckwheel"]) where name != "picture" {
            if let a = loadPropAsset(device: device, name: name) { propAssets[name] = a }
        }
        if let base = assetsURL() {
            skyTex = loadImageTexture(device: device, base.appendingPathComponent("Sky/nebula_0.png"))
            if let pic = loadImageTexture(device: device, base.appendingPathComponent("Sky/alien_landscape_0.jpg")) {
                var b = MeshBuilder()
                b.quad(D3(-9, -4.5, 0), D3(9, -4.5, 0), D3(9, 4.5, 0), D3(-9, 4.5, 0), .skin, uv: [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)])
                b.box(D3(18.6, 9.6, 0.2), D3(0, 0, -0.15), .dark)
                propAssets["picture"] = PropAsset(mesh: GPUMesh(device: device, verts: b.v),
                                                  skin: BakedSkin(albedo: tiny([4, 4, 6, 40], srgb: true), normal: tiny([128, 128, 255, 0], srgb: false)), emit: pic)
            }
        }
        do {
            var pb = MeshBuilder()                        // lift platform, top at y = 0
            pb.box(D3(20.6, 1.0, 25.6), D3(0, -0.5, 0), .floor)
            for s in [-1.0, 1.0] {
                pb.box(D3(0.3, 0.08, 25.6), D3(s * 10.1, 0.04, 0), .led); pb.box(D3(20.6, 0.08, 0.3), D3(0, 0.04, s * 12.65), .led)
                pb.box(D3(1.6, 0.05, 1.6), D3(s * 8.8, 0.03, 11.4), .orange); pb.box(D3(1.6, 0.05, 1.6), D3(s * 8.8, 0.03, -11.4), .orange)
                pb.box(D3(0.6, 1.2, 25.6), D3(s * 10.0, -1.1, 0), .metal)
            }
            var db = MeshBuilder()                        // one belly door half, spanning x 0…10.6
            db.box(D3(10.6, 0.8, 26.4), D3(5.3, 0, 0), .metal)
            db.box(D3(10.4, 0.06, 0.4), D3(5.3, -0.42, -12), .orange); db.box(D3(10.4, 0.06, 0.4), D3(5.3, -0.42, 12), .orange)
            var rb = MeshBuilder(); buildRoverMesh(into: &rb)
            cargoKit = (GPUMesh(device: device, verts: pb.v), GPUMesh(device: device, verts: db.v), GPUMesh(device: device, verts: rb.v))
        }

        // star field: directions + colour, brighter stars rarer, a hint of a galactic band
        var st: [Float] = []
        let rnd = Mulberry(7)
        for _ in 0..<9000 {
            let z = rnd.next() * 2 - 1, a = rnd.next() * .pi * 2, s = sqrt(1 - z * z)
            let band = exp(-((z * 3) * (z * 3))) * 0.6
            let d = simd_normalize(D3(cos(a) * s, z * (1 - band * 0.8), sin(a) * s))
            let b = pow(rnd.next(), 3.2) * 2.2 + 0.03, warm = rnd.next()
            st += [Float(d.x), Float(d.y), Float(d.z), Float(b * (0.85 + warm * 0.2)), Float(b * 0.93), Float(b * (1.05 - warm * 0.25))]
        }
        starCount = 9000
        starBuf = device.makeBuffer(bytes: st, length: st.count * 4, options: .storageModeShared)!
        streakBuf = device.makeBuffer(length: 280 * 6 * 4, options: .storageModeShared)!
    }

    private func ensureTargets(_ w: Int, _ h: Int) {
        if w == targetW && h == targetH && hdr != nil { return }
        targetW = w; targetH = h
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
        hdr = device.makeTexture(descriptor: d)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
        dd.usage = [.renderTarget, .shaderRead]; dd.storageMode = .private
        depth = device.makeTexture(descriptor: dd)
        bloom = []
        var bw = max(1, w / 2), bh = max(1, h / 2)
        for _ in 0..<6 {
            let b = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: bw, height: bh, mipmapped: false)
            b.usage = [.renderTarget, .shaderRead]; b.storageMode = .private
            bloom.append(device.makeTexture(descriptor: b)!)
            bw = max(1, bw / 2); bh = max(1, bh / 2)
        }
    }

    // MARK: - sun shadows

    private func siteBasis(_ s: Site) -> simd_double4x4 {
        let up = s.dir, f0 = simd_normalize(simd_cross(up, D3(0, 1, 0.3)))
        let f = simd_quatd(angle: s.yaw, axis: up).act(f0)
        let r = simd_cross(f, up)
        return simd_double4x4(columns: (SIMD4(r, 0), SIMD4(up, 0), SIMD4(-f, 0), SIMD4(0, 0, 0, 1)))
    }
    private func depotBasis(_ d: Depot) -> simd_double4x4 {
        let up = d.dir, f0 = simd_normalize(simd_cross(up, D3(0, 1, 0.3)))
        let f = simd_quatd(angle: d.yaw, axis: up).act(f0), r = simd_cross(f, up)
        return simd_double4x4(columns: (SIMD4(r, 0), SIMD4(up, 0), SIMD4(-f, 0), SIMD4(0, 0, 0, 1)))
    }
    private func depotModel(_ d: Depot, _ cam: D3) -> simd_double4x4 { translate(d.pos - cam) * depotBasis(d) * scaleM(D3(0.001, 0.001, 0.001)) }
    private func siteModel(_ s: Site, _ cam: D3) -> float4x4 {
        toFloat(translate(s.pos - cam) * siteBasis(s) * scaleM(D3(0.001, 0.001, 0.001)))
    }

    /// orthographic sun view around a world-space point, snapped to whole texels so shadows don't shimmer
    private func shadowMatrix(center: D3, cam: D3, L: D3, radius r: Double, depthHalf: Double) -> (float4x4, D3) {
        var right = simd_cross(L, D3(0, 1, 0))
        if simd_length(right) < 1e-3 { right = simd_cross(L, D3(1, 0, 0)) }
        right = simd_normalize(right)
        let upL = simd_cross(right, L)
        let texel = 2 * r / Double(SHADOW_SIZE)
        var wc = center
        let a = simd_dot(wc, right), b = simd_dot(wc, upL)
        let da: Double = (a / texel).rounded() * texel - a
        let db: Double = (b / texel).rounded() * texel - b
        wc += right * da
        wc += upL * db
        let c = wc - cam, D = 2 * depthHalf
        let row0: SIMD4<Double> = SIMD4(right / r, -simd_dot(c, right) / r)
        let row1: SIMD4<Double> = SIMD4(upL / r, -simd_dot(c, upL) / r)
        let row2: SIMD4<Double> = SIMD4(-L / D, (depthHalf + simd_dot(c, L)) / D)
        let m = simd_double4x4(rows: [row0, row1, row2, SIMD4<Double>(0, 0, 0, 1)])
        return (toFloat(m), c)
    }

    private func encodeShadows(_ cb: MTLCommandBuffer, _ F: inout FrameU, cam: D3, camWorld cw: World, camFwd: D3, shipModel: float4x4, legModels: [float4x4], nacelleModels: [float4x4], rockSegs: [RockSeg]) {
        let g = game
        let cup = simd_normalize(cam - cw.pos)
        let camAlt = simd_distance(cam, cw.pos) - cw.R
        let subject = g.mode == .walk ? g.w.pos : g.pos
        let r0 = g.mode == .walk ? 0.06 : max(0.08, g.ship.size * 1.5)
        let use0 = simd_distance(subject, cam) < 1.2
        let use1 = camAlt < 20
        F.shadowP = .zero
        guard use0 || use1, ProcessInfo.processInfo.environment["WAYFARER_NOSHADOW"] == nil else { return }
        let r1 = min(10, 2.5 + max(0, camAlt) * 0.5)
        let hf0 = camFwd - cup * simd_dot(camFwd, cup)
        let hf = simd_length(hf0) > 1e-4 ? simd_normalize(hf0) : D3(0, 0, 0)
        let c1World = cam + hf * r1 * 0.55
        let L0 = simd_normalize(g.sunPos - subject), L1 = simd_normalize(g.sunPos - c1World)
        let dh0 = max(0.35, g.ship.size * 1.2), dh1 = max(6, r1 * 2)
        let (m0, c0) = shadowMatrix(center: subject, cam: cam, L: L0, radius: r0, depthHalf: dh0)
        let (m1, c1) = shadowMatrix(center: c1World, cam: cam, L: L1, radius: r1, depthHalf: dh1)
        F.shadow0 = m0; F.shadow1 = m1
        F.shadowP = F4(use0 ? Float(r0) : 0, use1 ? Float(r1) : 0, 1 / Float(SHADOW_SIZE), 1)
        F.shadowQ = F4(Float(0.0004 / (2 * dh0)), Float(0.006 / (2 * dh1)), 0, 0)

        let cascades: [(Int, Bool, float4x4, D3, Double, Double, D3)] = [(0, use0, m0, c0, r0, dh0, L0), (1, use1, m1, c1, r1, dh1, L1)]
        for (slice, on, M, c, r, dh, L) in cascades {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = shadowTex; sp.depthAttachment.slice = slice
            sp.depthAttachment.loadAction = .clear; sp.depthAttachment.clearDepth = 1; sp.depthAttachment.storeAction = .store
            let se = cb.makeRenderCommandEncoder(descriptor: sp)!
            defer { se.endEncoding() }
            if !on { continue }
            se.setDepthStencilState(dsShadow); se.setCullMode(.none); se.setDepthClipMode(.clamp)
            se.setDepthBias(0, slopeScale: 1.2, clamp: 0.002)
            var LF = F; LF.viewProj = M
            se.setVertexBytes(&LF, length: MemoryLayout<FrameU>.stride, index: 1)
            func inside(_ rel: D3, _ rad: Double) -> Bool {
                let q = rel - c, along = simd_dot(q, L)
                if along < -dh - rad || along > dh * 4 + rad { return false }
                return simd_length(q - L * along) < r * 1.42 + rad
            }
            // terrain
            if camAlt < 60 {
                se.setRenderPipelineState(pShadowTerrain)
                for node in terrain.draw {
                    guard let mesh = node.mesh else { continue }
                    let rel = node.world.pos + node.center - cam
                    if !inside(rel, Double(mesh.radius)) { continue }
                    var o = ObjU(model: modelMatrix(rel: rel))
                    se.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
                    se.setVertexBuffer(mesh.vb, offset: 0, index: 0)
                    se.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint16, indexBuffer: mesh.ib, indexBufferOffset: 0)
                }
            }
            if let rs = rocks {
                se.setRenderPipelineState(pShadowRock)
                for sg in rockSegs where sg.pass == slice + 1 { drawRocks(se, rs, sg) }
            }
            se.setRenderPipelineState(pShadowShip)
            func draw(_ mesh: GPUMesh, _ model: float4x4) {
                var o = ObjU(model: model)
                se.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
                se.setVertexBuffer(mesh.vb, offset: 0, index: 0)
                se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count / 9)
            }
            if inside(g.pos - cam, g.ship.size) {
                draw(g.ship.hull, shipModel)
                for lm in legModels { draw(g.ship.leg, lm) }
                if let nm = g.ship.nacelle { for m in nacelleModels { draw(nm, m) } }
            }
            for s in g.sites where inside(s.pos - cam, 0.03) { draw(siteMeshes[s.kind.rawValue], siteModel(s, cam)) }
            for d in g.depots where inside(d.pos - cam, 0.16) { draw(depotMesh, toFloat(depotModel(d, cam))) }
            for p in g.props {
                guard case let .surface(wi, dir, _) = p.anchor, let a = propAssets[p.asset] else { continue }
                if inside(g.worlds[wi].pos + dir * p.baseR - cam, (PROP_RADIUS[p.asset] ?? 10) * p.scale * 0.006), let m = propModel(p, cam: cam, shipModel: simd_double4x4(1), aboardShip: nil) { draw(a.mesh, toFloat(m)) }
            }
            if g.mode == .walk && !g.driving, let pm = player, !g.charSkin.isEmpty {
                se.setRenderPipelineState(pShadowSkin)
                var o = ObjU(model: toFloat(translate(-cam) * g.charRoot))
                se.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
                se.setVertexBuffer(pm.model.mesh.vb, offset: 0, index: 0); se.setVertexBuffer(boneBufs[boneRing], offset: 0, index: 3); se.setVertexBuffer(pm.weights, offset: 0, index: 5)
                se.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pm.model.mesh.count / 9)
                se.setRenderPipelineState(pShadowShip)
            } else if g.mode == .walk && !g.driving && g.astroPose.count == astro.count {
                for (i, m) in astro.enumerated() { draw(m, toFloat(translate(-cam) * g.astroPose[i])) }
            }
        }
    }

    // MARK: - rocks

    private func drawRocks(_ e: MTLRenderCommandEncoder, _ rs: RockSet, _ sg: RockSeg) {
        let L = rs.kinds[sg.kind].lods[sg.lod]
        e.setVertexBuffer(L.vb, offset: 0, index: 0)
        e.setVertexBuffer(rockBufs[rockRing], offset: sg.start * MemoryLayout<RockGPU>.stride, index: 2)
        e.drawIndexedPrimitives(type: .triangle, indexCount: L.indexCount, indexType: .uint32, indexBuffer: L.ib, indexBufferOffset: 0, instanceCount: sg.count)
    }

    /// waits for rock placement around the camera to finish (snapshots only)
    func settleRocks() {
        guard let f = rockField else { return }
        let g = game
        for _ in 0..<400 {
            f.update(cam: g.camPos, world: g.nearestWorld(g.camPos))
            if f.idle { f.update(cam: g.camPos, world: g.nearestWorld(g.camPos)); if f.idle { break } }
            usleep(10000)
        }
    }

    private func prepareRocks(cam: D3, world: World, aspect: Double) -> [RockSeg] {
        guard let rs = rocks, let field = rockField else { return [] }
        let g = game
        field.avoid = g.sites.filter { $0.world === world }.map { $0.pos }
        field.update(cam: cam, world: world)
        let vis = field.visible
        if vis.isEmpty { return [] }
        let kinds = rs.kinds.count
        let subject = g.mode == .walk ? g.w.pos : g.pos
        let tanY = tan(g.fov * .pi / 360) * 1.1, tanX = tanY * aspect
        let viewD = simd_double3x3(g.camQ).transpose
        var buckets = [[RockGPU]](repeating: [], count: kinds * 5 + GRASS_VARIANTS)
        for r in vis {
            if r.kind >= GRASS_KIND {
                let rel = r.pos - cam, dist = simd_length(rel)
                if dist > GRASS_RANGE { continue }
                let sizeKm = Double(r.size) * 0.001 * (1 - ss(GRASS_RANGE * 0.45, GRASS_RANGE, dist))
                let vc = viewD * rel, depthV = -vc.z, rad = 0.0006
                if vc.z - rad > 0 || abs(vc.x) - rad > depthV * tanX || abs(vc.y) - rad > depthV * tanY { continue }
                buckets[kinds * 5 + r.kind - GRASS_KIND].append(RockGPU(posScale: F4(rel.f, Float(sizeKm)), quat: r.q.vector, tint: F4(r.tint, 0)))
                continue
            }
            let rel = r.pos - cam, dist = simd_length(rel)
            let range = r.size < 1.4 ? 0.26 : 1.6
            if dist > range { continue }
            let sizeKm = Double(r.size) * 0.001 * (1 - ss(range * 0.75, range, dist))
            let u = r.q.act(SIMD3<Float>(0, 1, 0))
            let p = rel - D3(Double(u.x), Double(u.y), Double(u.z)) * Double(rs.kinds[r.kind].height) * sizeKm * 0.25
            let gpu = RockGPU(posScale: F4(p.f, Float(sizeKm)), quat: r.q.vector, tint: F4(r.tint, 0))
            let vc = viewD * p, rad = sizeKm
            let depthV = -vc.z
            let culled = vc.z - rad > 0 || abs(vc.x) - rad > depthV * tanX || abs(vc.y) - rad > depthV * tanY
            if !culled {
                let lod = dist < ROCK_LOD_DIST[0] ? 0 : dist < ROCK_LOD_DIST[1] ? 1 : 2
                buckets[r.kind * 3 + lod].append(gpu)
            }
            if simd_distance(r.pos, subject) < 0.11 { buckets[kinds * 3 + r.kind * 2].append(gpu) }
            if r.size > 1.4 { buckets[kinds * 3 + r.kind * 2 + 1].append(gpu) }
        }
        rockRing = (rockRing + 1) % rockBufs.count
        let ptr = rockBufs[rockRing].contents().bindMemory(to: RockGPU.self, capacity: ROCK_CAP)
        var segs: [RockSeg] = [], at = 0
        for (bi, b) in buckets.enumerated() where !b.isEmpty {
            let n = min(b.count, ROCK_CAP - at)
            if n <= 0 { break }
            for i in 0..<n { ptr[at + i] = b[i] }
            let seg: RockSeg
            if bi >= kinds * 5 { seg = RockSeg(kind: bi - kinds * 5, lod: 0, start: at, count: n, pass: 3) }
            else if bi < kinds * 3 { seg = RockSeg(kind: bi / 3, lod: bi % 3, start: at, count: n, pass: 0) }
            else { let k = bi - kinds * 3; seg = RockSeg(kind: k / 2, lod: 2, start: at, count: n, pass: k % 2 == 0 ? 1 : 2) }
            segs.append(seg); at += n
        }
        if CommandLine.arguments.contains("--rockstats") {
            var c = [0, 0, 0, 0, 0, 0]
            for sg in segs { c[sg.pass == 0 ? sg.lod : 2 + sg.pass] += sg.count }
            print("rocks visible \(vis.count) · lod0 \(c[0]) lod1 \(c[1]) lod2 \(c[2]) · shadow \(c[3]) / \(c[4]) · grass \(c[5])")
        }
        return segs
    }

    // MARK: - frame

    func encode(_ cb: MTLCommandBuffer, output: MTLTexture) {
        let outW = output.width, outH = output.height
        outputW = outW; outputH = outH
        let scale = min(1.0, sqrt(maxPixels / Double(outW * outH))) * renderScale
        let w = max(64, Int(Double(outW) * scale)), h = max(64, Int(Double(outH) * scale))
        ensureTargets(w, h)
        let g = game
        let cam = g.camPos
        let aspect = Float(w) / Float(h); lastAspect = aspect
        let near: Float = 0.0002
        let proj = perspectiveReversedInfinite(fovyRadians: Float(min(100, g.fov * (1 + g.kick * 0.1)) * .pi / 180), aspect: aspect, near: near)
        let view = viewMatrix(g.camQ)
        let viewProj = proj * view
        let camFwd = g.camQ.act(D3(0, 0, -1))
        let sunRel = g.sunPos - cam

        // how much of the sky is lit around the camera (fades the stars by day)
        let cw = g.nearestWorld(cam)
        let cup = simd_normalize(cam - cw.pos)
        let inside = 1 - clampd((simd_distance(cam, cw.pos) - cw.R) / cw.atmo.top, 0, 1)
        let dayAtCam = ss(-0.12, 0.3, simd_dot(cup, simd_normalize(g.sunPos - cam)))
        let starOpacity = Float(1 - inside * inside * dayAtCam * 0.985)
        let sunI: Float = 3.2

        var F = FrameU(view: view, proj: proj, viewProj: viewProj, invViewProj: viewProj.inverse,
                       sun: F4(sunRel.f, Float(g.time)), misc: F4(1, starOpacity, sunI, near), camFwd: F4(camFwd.f, 0))

        // the shade under a low ship, broader and darker the bigger she is
        do {
            let W = g.nearestWorld(g.pos), u = simd_normalize(g.pos - W.pos)
            let low = 1 - ss(g.size * 1.5, g.size * 12, g.alt)
            let shipMode = g.mode != .title && (g.mode != .walk || g.landedOn != nil || g.sh.active)
            let strength = shipMode ? low * (0.35 + 0.4 * ss(0.04, 0.5, g.size)) : 0
            if strength > 0.01 {
                F.blob = F4((W.pos + u * W.groundRadius(u) - cam).f, Float(g.size * 0.62))
                F.blob2 = F4(Float(strength), 0, 0, 0)
            }
        }
        let S0 = g.ship
        let k = S0.size / S0.length
        let bounce = 0.0
        let shipUp = g.q.act(D3(0, 1, 0))
        let shipModel = translate(g.pos - cam + shipUp * bounce) * simd_double4x4(g.q) * scaleM(D3(k, k, k))
        // the character's bone matrices for this frame
        boneRing = (boneRing + 1) % boneBufs.count
        if !g.charSkin.isEmpty { let n = min(128, g.charSkin.count); g.charSkin.withUnsafeBytes { memcpy(boneBufs[boneRing].contents(), $0.baseAddress!, n * 64) } }
        var legModels: [float4x4] = []
        if g.gear > 0.01 {
            let e = g.gear * g.gear * (3 - 2 * g.gear)
            for leg in S0.legs { legModels.append(toFloat(shipModel * translate(leg.pos) * eulerXYZ(D3(leg.stow * (1 - e), 0, 0)) * scaleM(D3(1, 0.55 + 0.45 * e, 1)))) }
        }
        let rockSegs = prepareRocks(cam: cam, world: cw, aspect: Double(aspect))
        // tilting engine nacelles (and where each engine's flame starts)
        let tiltA = (g.tilt * g.tilt * (3 - 2 * g.tilt)) * .pi / 2
        func pivotXf(_ i: Int) -> simd_double4x4 { translate(S0.pivots[i]) * eulerXYZ(D3(tiltA, 0, 0)) }
        func engineXf(_ e: (pos: D3, r: Double, pivot: Int)) -> simd_double4x4 { e.pivot < 0 ? translate(e.pos) : pivotXf(e.pivot) * translate(e.pos) }
        let nacelleModels: [float4x4] = S0.nacelle == nil ? [] : S0.pivots.indices.map { toFloat(shipModel * pivotXf($0)) }
        encodeShadows(cb, &F, cam: cam, camWorld: cw, camFwd: camFwd, shipModel: toFloat(shipModel), legModels: legModels, nacelleModels: nacelleModels, rockSegs: rockSegs)

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = hdr; rp.colorAttachments[0].loadAction = .clear; rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = .clear; rp.depthAttachment.clearDepth = 0; rp.depthAttachment.storeAction = .store
        let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
        enc.setFrontFacing(.counterClockwise)
        enc.setCullMode(.none)
        enc.setFragmentTexture(shadowTex, index: 5)
        // point lights: the ship's engines (and its landing lights when the gear is down) light up the hull and the ground
        do {
            var pl = [F4](repeating: .zero, count: 9); var n = 0
            let S = g.ship, pw = g.powerK * g.engineK, k = S.size / S.length
            let flame = S.flame?.glow ?? D3(0.55, 0.75, 1.0)
            if pw > 0.02 && g.mode != .title && g.mode != .walk || (g.mode == .walk && g.sh.active) {
                let main = S.engines.sorted { $0.r > $1.r }.prefix(3)
                for e in main where n < 3 {
                    let wp = shipModel * engineXf(e) * SIMD4(0, 0, e.r * 2.5, 1)
                    let strength = (0.5 + g.thrust * 1.2 + g.abLevel * 2.5) * pw * (e.r / 0.05)
                    pl[1 + n] = F4(D3(wp.x, wp.y, wp.z).f, Float(max(0.004, e.r * k * 22)))
                    pl[5 + n] = F4((flame * strength * 3.0).f, 0); n += 1
                }
            }
            if g.gear > 0.7 && g.powerK > 0.5 && g.mode != .title, let lp = S.landLights.first {
                let wp = shipModel * SIMD4(lp.x, lp.y - 0.3, lp.z, 1)
                pl[1 + n] = F4(D3(wp.x, wp.y, wp.z).f, Float(S.size * 3)); pl[5 + n] = F4(SIMD3(1.6, 1.5, 1.3) * Float(g.powerK), 0); n += 1
            }
            pl[0] = F4(Float(n), 0, 0, 0)
            enc.setFragmentBytes(&pl, length: MemoryLayout<F4>.stride * 9, index: 7)
        }

        enc.setFragmentTexture(blackTex, index: 6)
        // the nebula panorama behind the stars (Jungle Jim, CC BY 4.0)
        if let sky = skyTex {
            enc.setRenderPipelineState(pSky); enc.setDepthStencilState(dsNone)
            enc.setFragmentBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1); enc.setFragmentTexture(sky, index: 0); enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        // stars
        enc.setRenderPipelineState(pStar); enc.setDepthStencilState(dsNone)
        enc.setVertexBuffer(starBuf, offset: 0, index: 0); enc.setVertexBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)

        // sun
        enc.setRenderPipelineState(pSun); enc.setDepthStencilState(dsWrite)
        var sunObj = ObjU(model: modelMatrix(rel: sunRel, scale: D3(120000, 120000, 120000)), color: F4(1.0 * 60, 0.95 * 60, 0.86 * 60, 1))
        drawSphere(enc, &F, &sunObj)

        // terrain
        enc.setRenderPipelineState(pTerrain); enc.setDepthStencilState(dsWrite)
        enc.setFragmentTexture(detailTex, index: 0); enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentTexture(groundMats?.albedo, index: 1); enc.setFragmentTexture(groundMats?.packed, index: 2)
        var means = groundMats?.means ?? [SIMD4<Float>](repeating: SIMD4(0.3, 0.3, 0.3, 1), count: LAYER_COUNT)
        enc.setFragmentBytes(&means, length: MemoryLayout<SIMD4<Float>>.stride * means.count, index: 3)
        enc.setVertexBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1); enc.setFragmentBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1)
        let tanY = tan(g.fov * .pi / 360), tanX = tanY * Double(aspect)
        let viewD = simd_double3x3(g.camQ).transpose
        for node in terrain.draw {
            guard let mesh = node.mesh else { continue }
            let P = node.world
            let rel = P.pos + node.center - cam
            let vc = viewD * rel, r = Double(mesh.radius)
            if vc.z - r > 0 { continue }
            let depthV = -vc.z
            if vc.x - r * 1.5 > depthV * tanX || -vc.x - r * 1.5 > depthV * tanX || vc.y - r * 1.5 > depthV * tanY || -vc.y - r * 1.5 > depthV * tanY { continue }
            let cen = P.pos - cam
            var o = ObjU(model: modelMatrix(rel: rel),
                         p0: F4(P.atmo.rayleigh, P.sea ? 1 : 0), p1: F4(P.bio ?? .zero, P.atmo.mie),
                         p2: F4(cen.f, Float(P.R)), color: F4(P.atmo.rayleighH, P.atmo.mieH, groundMats == nil ? 0 : P.tint, 0))
            enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.setVertexBuffer(mesh.vb, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint16, indexBuffer: mesh.ib, indexBufferOffset: 0)
        }

        // rocks
        if let rs = rocks, rockSegs.contains(where: { $0.pass == 0 || $0.pass == 3 }) {
            let up = simd_normalize(cam - cw.pos)
            let cz = simd_dot(up, simd_normalize(g.sunPos - cam))
            let tint = cw.atmo.rayleigh / max(cw.atmo.rayleigh.x, max(cw.atmo.rayleigh.y, cw.atmo.rayleigh.z))
            var ru = RockU(sun: F4(sunTransmitCPU(cz, cw) * sunI, 0), sky: F4(tint, Float(ss(-0.15, 0.25, cz))), up: F4(up.f, 0), mean: F4(rs.mean, min(0.9, cw.tint * 1.2)))
            enc.setRenderPipelineState(pRock); enc.setDepthStencilState(dsWrite)
            enc.setVertexBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1); enc.setFragmentBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1)
            enc.setFragmentBytes(&ru, length: MemoryLayout<RockU>.stride, index: 3)
            enc.setFragmentTexture(rs.albedo, index: 0); enc.setFragmentTexture(rs.packed, index: 1); enc.setFragmentSamplerState(sampler, index: 0)
            for sg in rockSegs where sg.pass == 0 { drawRocks(enc, rs, sg) }
            enc.setRenderPipelineState(pGrass)
            for sg in rockSegs where sg.pass == 3 {
                let L = grassClumps[sg.kind]
                enc.setVertexBuffer(L.vb, offset: 0, index: 0)
                enc.setVertexBuffer(rockBufs[rockRing], offset: sg.start * MemoryLayout<RockGPU>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: L.indexCount, indexType: .uint32, indexBuffer: L.ib, indexBufferOffset: 0, instanceCount: sg.count)
            }
        }

        // ship
        let S = g.ship
        let world = g.nearestWorld(g.pos)
        let up = simd_normalize(g.pos - world.pos)
        let cosZ = simd_dot(up, simd_normalize(g.sunPos - g.pos))
        let sunAtShip = sunTransmitCPU(cosZ, world) * sunI
        let skyTint = world.atmo.rayleigh / max(world.atmo.rayleigh.x, max(world.atmo.rayleigh.y, world.atmo.rayleigh.z))
        let shipInside = 1 - clampd((simd_distance(g.pos, world.pos) - world.R) / world.atmo.top, 0, 1)
        let inCockpit = g.cockpitView && g.mode != .walk && g.mode != .title && !g.aboard.on
        let aboardDeck = g.aboard.on ? S.deck : nil
        let bayOpen = S.cargo != nil && g.doorK > 0.01 && (g.mode == .landed || g.mode == .walk)
        let uM = S.length / (S.size * 1000)              // model units per metre
        var so = ObjU(model: toFloat(shipModel), p0: F4(Float(g.abLevel), sunI * 0.35, Float(g.powerK), inCockpit ? 1 : (aboardDeck != nil ? 2 : (bayOpen ? 2.25 : 0))),
                      p1: F4(up.f, Float(ss(-0.15, 0.25, cosZ) * shipInside)), p2: F4(skyTint, S.hullDetail), color: F4(sunAtShip, 1))
        enc.setRenderPipelineState(pShip); enc.setDepthStencilState(dsWrite)
        enc.setFragmentTexture(paintTex[min(S.paint, paintTex.count - 1)], index: 0); enc.setFragmentTexture(ventTex, index: 1); enc.setFragmentTexture(screenTex, index: 2)
        enc.setVertexBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2)
        // walking aboard: cut the hull away behind the windows and wherever it would poke into the cabins
        var carve = [F4](repeating: .zero, count: 17)
        var cuts: [(lo: D3, hi: D3)] = aboardDeck?.carves ?? []
        if inCockpit, let cc = S.canopyCut { cuts.append(cc) }
        if let c = S.cargo, g.doorK > 0.01 && (aboardDeck != nil || bayOpen) {   // the opening in the belly under the cargo lift
            cuts.append((D3(0, c.doorY - 6, c.lift.z0 + 0.2) * uM, D3(c.lift.x1 - 0.2, c.floorY - 0.3, c.lift.z1 - 0.2) * uM))
        }
        carve[0] = F4(Float(min(cuts.count, 8)), 0, 0, 0)
        for (i, c) in cuts.prefix(8).enumerated() { carve[1 + i] = F4(c.lo.f, 0); carve[9 + i] = F4(c.hi.f, 0) }
        enc.setFragmentBytes(&carve, length: MemoryLayout<F4>.stride * 17, index: 4)
        enc.setVertexBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2)
        if let sk = S.skin { enc.setFragmentTexture(sk.albedo, index: 3); enc.setFragmentTexture(sk.normal, index: 4) }
        enc.setVertexBuffer(S.hull.vb, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: S.hull.count / 9)
        if aboardDeck != nil || bayOpen, let im = S.interior {
            var io = so; io.p0.w = 3; io.p2.w = Float(S.size * 1000 / S.length)    // metres per model unit, for panel patterns
            enc.setVertexBytes(&io, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&io, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.setVertexBuffer(im.vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: im.count / 9)
            if aboardDeck != nil, let lc = S.liftCar {    // lift cars: parked at their stations, or carrying you
                let uM = S.length / (S.size * 1000)
                for car in g.liftCars() {
                    let base = shipModel * scaleM(D3(uM, uM, uM)) * translate(car.p) * eulerXYZ(D3(0, car.yaw, 0))
                    var lo = io; lo.p6 = F4(Float(car.run), Float(min(1, car.moving / 15)), 0, 0)
                    lo.model = toFloat(base * scaleM(D3(1 / uM, 1 / uM, 1 / uM)))
                    enc.setVertexBytes(&lo, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&lo, length: MemoryLayout<ObjU>.stride, index: 2)
                    enc.setVertexBuffer(lc.car.vb, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: lc.car.count / 9)
                    enc.setVertexBuffer(lc.door.vb, offset: 0, index: 0)
                    for sx in [-1.0, 1.0] {
                        let x = sx * (LIFT_DOOR / 2 + car.door * LIFT_DOOR * 0.95)
                        lo.model = toFloat(base * translate(D3(x, 0, -LIFT_HALF + 0.03)) * scaleM(D3(1 / uM, 1 / uM, 1 / uM)))
                        enc.setVertexBytes(&lo, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&lo, length: MemoryLayout<ObjU>.stride, index: 2)
                        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: lc.door.count / 9)
                    }
                }
            }
            if aboardDeck != nil, let cm = S.cockpit {    // the real cockpit, under the open canopy
                var co = io; co.p2.w = S.hullDetail
                enc.setVertexBytes(&co, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&co, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.setVertexBuffer(cm.vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cm.count / 9)
            }
            enc.setVertexBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2)
        }
        // cargo bay: belly doors, the lift platform, and the rover (in the bay or out on the ground)
        if let c = S.cargo {
            var co = so; co.p0.w = 0
            let hcx = (c.lift.x0 + c.lift.x1) / 2, hcz = (c.lift.z0 + c.lift.z1) / 2
            enc.setVertexBuffer(cargoKit.door.vb, offset: 0, index: 0)
            for s in [-1.0, 1.0] {
                co.model = toFloat(shipModel * scaleM(D3(uM, uM, uM)) * translate(D3(hcx + s * g.doorK * 11, c.doorY, hcz)) * scaleM(D3(s, 1, 1)))
                enc.setVertexBytes(&co, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&co, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cargoKit.door.count / 9)
            }
            if aboardDeck != nil || bayOpen {
                co.p0.w = 3; co.p2.w = Float(1 / uM)
                co.model = toFloat(shipModel * scaleM(D3(uM, uM, uM)) * translate(D3(hcx, g.cargoLiftY ?? c.floorY, hcz)))
                enc.setVertexBytes(&co, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&co, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.setVertexBuffer(cargoKit.platform.vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cargoKit.platform.count / 9)
            }
            // the rover: the cargo truck, its wheels spinning, steering and riding their suspension
            var ro = so; ro.p0 = F4(0, sunI * 0.35, 1, g.rover.inShip ? 3 : 0); ro.p2.w = 1; ro.p5 = F4(1.5, 0, 0, 0)
            var base: simd_double4x4
            if g.rover.inShip {
                base = shipModel * scaleM(D3(uM, uM, uM)) * translate(g.rover.p) * eulerXYZ(D3(0, g.rover.yaw, 0))
            } else {
                let zb = simd_normalize(-g.rover.wfwd + g.rover.wup * simd_dot(g.rover.wfwd, g.rover.wup)), yb = g.rover.wup
                let xb = simd_normalize(simd_cross(yb, zb)), zz = simd_cross(xb, yb)
                let basis = simd_double4x4(columns: (SIMD4(xb, 0), SIMD4(yb, 0), SIMD4(zz, 0), SIMD4(0, 0, 0, 1)))
                base = translate(g.rover.wpos - cam) * basis * scaleM(D3(0.001, 0.001, 0.001))
            }
            if let body = propAssets["truckbody"], let wheel = propAssets["truckwheel"] {
                let wl = TruckLayout.shared
                let susAvg = g.rover.susp.reduce(0, +) / Double(max(1, g.rover.susp.count))
                let bodyM = base * translate(D3(0, susAvg, 0)) * eulerXYZ(D3(g.rover.pitch, 0, g.rover.roll))
                ro.model = toFloat(bodyM)
                enc.setVertexBytes(&ro, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&ro, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.setFragmentTexture(body.skin.albedo, index: 3); enc.setFragmentTexture(body.skin.normal, index: 4); enc.setFragmentTexture(body.emit ?? blackTex, index: 6)
                enc.setVertexBuffer(body.mesh.vb, offset: 0, index: 0); enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: body.mesh.count / 9)
                enc.setFragmentTexture(wheel.skin.albedo, index: 3); enc.setFragmentTexture(wheel.skin.normal, index: 4); enc.setFragmentTexture(blackTex, index: 6)
                enc.setVertexBuffer(wheel.mesh.vb, offset: 0, index: 0)
                for (i, c) in wl.wheels.enumerated() {
                    let steer = c.z < -2 ? g.rover.steerVis : (c.z > 2.5 ? -g.rover.steerVis * 0.35 : 0)   // front axle steers, rear axle a little
                    let su = i < g.rover.susp.count ? g.rover.susp[i] : 0
                    ro.model = toFloat(base * translate(c + D3(0, su, 0)) * eulerXYZ(D3(0, steer, 0)) * eulerXYZ(D3(-g.rover.wheel, 0, 0)) * scaleM(D3(c.x < 0 ? -1 : 1, 1, 1)))
                    enc.setVertexBytes(&ro, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&ro, length: MemoryLayout<ObjU>.stride, index: 2)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: wheel.mesh.count / 9)
                }
                enc.setFragmentTexture(blackTex, index: 6)
            } else {
                ro.p2.w = 1000; ro.model = toFloat(base)
                enc.setVertexBytes(&ro, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&ro, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.setVertexBuffer(cargoKit.rover.vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cargoKit.rover.count / 9)
            }
            enc.setVertexBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&so, length: MemoryLayout<ObjU>.stride, index: 2)
        }
        if inCockpit, let cm = S.cockpit {
            enc.setVertexBuffer(cm.vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: cm.count / 9)
        }
        if let nm = S.nacelle {
            enc.setVertexBuffer(nm.vb, offset: 0, index: 0)
            for m in nacelleModels {
                var no = so; no.model = m
                enc.setVertexBytes(&no, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&no, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: nm.count / 9)
            }
        }
        if g.gear > 0.01 {
            enc.setVertexBuffer(S.leg.vb, offset: 0, index: 0)
            for lm in legModels {
                var lo = so
                lo.model = lm
                enc.setVertexBytes(&lo, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&lo, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: S.leg.count / 9)
            }
        }

        // discovery sites close enough to see
        enc.setRenderPipelineState(pShip); enc.setDepthStencilState(dsWrite)
        for s in g.sites where simd_distance(s.pos, cam) < 40 {
            let m = siteMeshes[s.kind.rawValue]
            var o = so
            o.model = siteModel(s, cam)
            o.p0 = F4(0, sunI * 0.35, 1, 0)
            let su = simd_dot(s.dir, simd_normalize(g.sunPos - s.pos))
            o.color = F4(sunTransmitCPU(su, s.world) * sunI, 1)
            enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.setVertexBuffer(m.vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: m.count / 9)
        }

        // fuel depots
        for d in g.depots where simd_distance(d.pos, cam) < 80 {
            var o = so
            o.model = toFloat(depotModel(d, cam))
            o.p0 = F4(0, sunI * 0.35, 1, 0)
            o.color = F4(sunTransmitCPU(simd_dot(d.dir, simd_normalize(g.sunPos - d.pos)), d.world) * sunI, 1)
            enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.setVertexBuffer(depotMesh.vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: depotMesh.count / 9)
        }

        // downloaded models: the outpost town, the orbital station, decks, and traffic round the station
        do {
            let aboardShip: Int? = aboardDeck != nil ? g.shipIndex : nil
            enc.setRenderPipelineState(pShip); enc.setDepthStencilState(dsWrite)
            for p in g.props {
                guard let a = propAssets[p.asset], let m = propModel(p, cam: cam, shipModel: shipModel, aboardShip: aboardShip) else { continue }
                var o = so
                o.model = toFloat(m); o.p0 = F4(0, sunI * 0.35, 1, aboardShip != nil && { if case .deck = p.anchor { return true }; return false }() ? 3 : 0)
                o.p2.w = 1; o.p5 = F4(p.glow, 0, 0, 0)
                if case .orbit = p.anchor { o.color = F4(sunI * 0.9, sunI * 0.9, sunI * 0.88, 1); o.p1 = F4(0, 1, 0, 1) }
                enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.setFragmentTexture(a.skin.albedo, index: 3); enc.setFragmentTexture(a.skin.normal, index: 4); enc.setFragmentTexture(a.emit ?? blackTex, index: 6)
                enc.setVertexBuffer(a.mesh.vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: a.mesh.count / 9)
            }
            if let H = g.ships.first(where: { $0.name == "Heron" }), let sk = H.skin, simd_distance(g.stationPos, cam) < 600 {
                let hk = H.size / H.length
                for t in g.trafficShips() {
                    var o = so
                    o.model = toFloat(translate(t.pos - cam) * simd_double4x4(t.q) * scaleM(D3(repeating: hk))); o.p0 = F4(0, sunI * 0.35, 1, 0); o.p5 = F4(1, 0, 0, 0)
                    o.color = F4(SIMD3<Float>(repeating: sunI * 0.9), 1); o.p1 = F4(SIMD3<Float>(0, 1, 0), 1)
                    enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
                    enc.setFragmentTexture(sk.albedo, index: 3); enc.setFragmentTexture(sk.normal, index: 4); enc.setFragmentTexture(blackTex, index: 6)
                    enc.setVertexBuffer(H.hull.vb, offset: 0, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: H.hull.count / 9)
                }
            }
            enc.setFragmentTexture(blackTex, index: 6)
        }

        // the emergency tanker
        if g.tanker.active {
            var o = so
            o.model = toFloat(translate(g.pos + g.tanker.rel - cam) * simd_double4x4(g.tanker.q) * scaleM(D3(0.001, 0.001, 0.001)))
            o.p0 = F4(0, sunI * 0.35, 1, 0)
            enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.setVertexBuffer(tankerKit.mesh.vb, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: tankerKit.mesh.count / 9)
        }

        // the explorer
        if g.mode == .walk && !g.driving, let pm = player, !g.charSkin.isEmpty {
            // the robot, skinned on the GPU
            enc.setRenderPipelineState(pSkin); enc.setDepthStencilState(dsWrite)
            var o = so
            o.model = toFloat(translate(-cam) * g.charRoot); o.p0 = F4(0, sunI * 0.35, 1, 0); o.p5 = F4(1.4, 0, 0, 0)
            enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.setFragmentTexture(pm.model.skin.albedo, index: 3); enc.setFragmentTexture(pm.model.skin.normal, index: 4); enc.setFragmentTexture(pm.model.emit ?? blackTex, index: 6)
            enc.setVertexBuffer(pm.model.mesh.vb, offset: 0, index: 0); enc.setVertexBuffer(boneBufs[boneRing], offset: 0, index: 3); enc.setVertexBuffer(pm.weights, offset: 0, index: 5)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: pm.model.mesh.count / 9)
            enc.setFragmentTexture(blackTex, index: 6)
        } else if g.mode == .walk && !g.driving && g.astroPose.count == astro.count {
            enc.setRenderPipelineState(pShip); enc.setDepthStencilState(dsWrite)
            for (i, m) in astro.enumerated() {
                var ao = so
                ao.model = toFloat(translate(-cam) * g.astroPose[i])
                ao.p0 = F4(0, sunI * 0.35, 1, 0)
                enc.setVertexBytes(&ao, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&ao, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.setVertexBuffer(m.vb, offset: 0, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: m.count / 9)
            }
        }

        // clouds (premultiplied alpha, both sides)
        enc.setRenderPipelineState(pCloud); enc.setDepthStencilState(dsTest)
        for P in terrain.worlds {
            guard let cl = P.clouds else { continue }
            let rr = P.R + cl.alt
            var o = ObjU(model: modelMatrix(rel: P.pos - cam, scale: D3(rr, rr, rr)),
                         p0: F4(simd_normalize(g.sunPos - P.pos).f, cl.cover), p1: F4(P.atmo.rayleigh, 0), color: F4(cl.color, 1))
            drawSphere(enc, &F, &o, frag: true)
        }

        // engine flames and belly thrusters
        let flick = 0.92 + sin(g.time * 60) * 0.05 + sin(g.time * 23) * 0.03
        enc.setRenderPipelineState(pPlume); enc.setDepthStencilState(dsTest)
        enc.setVertexBuffer(S.plume.vb, offset: 0, index: 0)
        let pw = g.powerK * g.engineK                     // no fuel: the engines go dark
        if pw > 0.02 {
            let wScale = 1 + g.abLevel * 0.25
            var po = ObjU(model: matrix_identity_float4x4, p0: F4(Float((0.25 + g.thrust * 0.55 + g.abLevel * 0.5) * pw), Float(g.abLevel), Float(g.time), 0),
                          p1: F4(S.flame?.edge ?? SIMD3(0.35, 0.6, 2.2), 0), p2: F4(S.flame?.core ?? SIMD3(2.6, 2.8, 3.2), 0), color: F4(S.flame?.hot ?? SIMD3(0.25, 0.6, 3.4), 0))
            for e in S.engines {
                // on tilt-engine ships the fixed main engine idles while the nacelles hold the ship up
                // flame length scales with the nozzle: idle a stub, full throttle ~8 nozzle widths, afterburner ~18
                let len = e.r * (2.0 + g.thrust * 14 * flick) * (1 + g.abLevel * 1.4) * pw
                let l = e.pivot < 0 && !S.pivots.isEmpty ? max(0.001, len * (1 - 0.8 * g.tilt)) : max(0.001, len)
                po.model = toFloat(shipModel * engineXf(e) * scaleM(D3(e.r * 1.25 * wScale, e.r * 1.25 * wScale, l * 1.3)))
                enc.setVertexBytes(&po, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&po, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: S.plume.count, indexType: .uint32, indexBuffer: S.plume.ib!, indexBufferOffset: 0)
            }
            // the glowing nozzle mouths, drawn just inside each nozzle so the hull hides them from the front
            enc.setRenderPipelineState(pNozzle); enc.setVertexBuffer(nozzleMesh.vb, offset: 0, index: 0)
            var no = po
            no.p0 = F4(Float((0.55 + g.thrust * 0.6 + g.abLevel * 0.9) * pw * flick), 0, 0, 0)
            no.p1 = F4((S.flame?.glow ?? D3(0.55, 0.75, 1.0)).f * 1.6, 0)
            for e in S.engines {
                no.model = toFloat(shipModel * engineXf(e) * translate(D3(0, 0, -e.r * 0.15)) * scaleM(D3(e.r, e.r, e.r)))
                enc.setVertexBytes(&no, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&no, length: MemoryLayout<ObjU>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: nozzleMesh.count, indexType: .uint32, indexBuffer: nozzleMesh.ib!, indexBufferOffset: 0)
            }
            enc.setRenderPipelineState(pPlume); enc.setVertexBuffer(S.plume.vb, offset: 0, index: 0)
            if g.vtol > 0.02 {
                po.p0 = F4(Float(g.vtol * 0.9 * pw), 0, Float(g.time), 0)
                for (i, vt) in S.vtols.enumerated() {
                    let fl = 0.85 + sin(g.time * 50 + Double(i) * 1.7) * 0.15
                    po.model = toFloat(shipModel * translate(vt.pos) * eulerXYZ(D3(.pi / 2, 0, 0)) * scaleM(D3(vt.r, vt.r, 0.05 + g.vtol * 0.55 * fl)))
                    enc.setVertexBytes(&po, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&po, length: MemoryLayout<ObjU>.stride, index: 2)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: S.plume.count, indexType: .uint32, indexBuffer: S.plume.ib!, indexBufferOffset: 0)
                }
            }
        }

        // signal beacons: tall beams of light over scanned sites
        enc.setRenderPipelineState(pPlume); enc.setDepthStencilState(dsTest); enc.setVertexBuffer(S.plume.vb, offset: 0, index: 0)
        for s in g.sites where s.scanned && !s.discovered {
            let d = simd_distance(s.pos, cam)
            if d > 3000 { continue }
            let r = max(0.0018, d * 0.0009), len = max(3.0, d * 0.12)
            var bo = ObjU(model: toFloat(translate(s.pos - cam) * siteBasis(s) * eulerXYZ(D3(-.pi / 2, 0, 0)) * scaleM(D3(r, r, len))),
                          p0: F4(Float(1.7 + 0.3 * sin(g.time * 2.4)), 0, Float(g.time), 0), p1: F4(3.0, 1.1, 0.15, 0), p2: F4(4.0, 3.0, 1.4, 0), color: F4(3.0, 1.1, 0.15, 0))
            enc.setVertexBytes(&bo, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&bo, length: MemoryLayout<ObjU>.stride, index: 2)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: S.plume.count, indexType: .uint32, indexBuffer: S.plume.ib!, indexBufferOffset: 0)
        }

        // glows: engines, navigation and landing lights, the sun's halo
        var glows: [GlowU] = []
        func worldPt(_ p: D3) -> D3 { let v = shipModel * SIMD4(p, 1); return D3(v.x, v.y, v.z) }
        let pwF = Float(pw)
        let glowCol = S.flame.map { mixd($0.glow, $0.glow * 1.3, g.abLevel) } ?? mixd(D3(0.61, 0.78, 1.0), D3(0.3, 0.6, 1.3), g.abLevel)
        for e in S.engines where pw > 0.02 {
            let s = e.r * (2.2 + g.thrust * 1.5 * flick) * (1 + g.abLevel * 0.8) * k * pw
            let gp = shipModel * engineXf(e) * SIMD4(0, 0, e.r * 0.3, 1)
            glows.append(GlowU(posSize: F4(D3(gp.x, gp.y, gp.z).f, Float(s)), color: F4(glowCol.f * 0.6, pwF)))
        }
        // afterburner light-off: a white-hot flash at each nozzle
        if g.burnFlash > 0.02 && pw > 0.5 {
            for e in S.engines {
                let gp = shipModel * engineXf(e) * SIMD4(0, 0, e.r * 1.4, 1)
                glows.append(GlowU(posSize: F4(D3(gp.x, gp.y, gp.z).f, Float(e.r / 0.046 * k * 0.25 * (1 + 4 * g.burnFlash))), color: F4((S.flame.map { $0.glow.f * 2.6 } ?? SIMD3(1.4, 2.2, 3.4)) * Float(g.burnFlash), 1)))
            }
        }
        // vapour cone around the hull near Mach 1, and the shock ring of a sonic boom
        if g.vapor > 0.02 {
            for (zi, z) in [-0.15, 0.05, 0.25, 0.45].enumerated() {
                let r = 0.3 + Double(zi) * 0.12
                for i in 0..<28 {
                    let a = Double(i) / 28 * .pi * 2 + Double(zi) * 0.4
                    let wob = 1 + 0.08 * sin(g.time * 9 + Double(i) * 1.3)
                    let p = worldPt(D3(cos(a) * r * 1.25 * wob, sin(a) * r * 0.75 * wob, z))
                    glows.append(GlowU(posSize: F4(p.f, Float(g.size * 0.16)), color: F4(SIMD3(0.9, 0.95, 1.0) * Float(g.vapor * (0.12 + 0.05 * Double(zi))), -1)))
                }
            }
        }
        // re-entry: a sheath of glowing plasma wrapping the nose and belly, flickering, trailing back
        if g.heat > 0.02 {
            let h = Float(g.heat)
            for i in 0..<40 {
                let a = Double(i) / 40 * .pi * 2, fl = 0.8 + 0.4 * sin(g.time * 37 + Double(i) * 2.3)
                let p = worldPt(D3(cos(a) * 0.32, sin(a) * 0.14 - 0.06, -0.62))
                glows.append(GlowU(posSize: F4(p.f, Float(g.size * 0.3 * fl)), color: F4(SIMD3(3.2, 1.1, 0.35) * h * 0.35, -1)))
            }
            for k in 0..<10 {
                let z = -0.7 + Double(k) * 0.18, fl = 0.7 + 0.3 * sin(g.time * 23 + Double(k))
                glows.append(GlowU(posSize: F4(worldPt(D3(0, -0.1, z)).f, Float(g.size * (0.55 + Double(k) * 0.06) * fl)), color: F4(SIMD3(2.6, 0.7, 0.4) * h * (0.4 - Float(k) * 0.03), -1)))
            }
        }
        if g.shockT < 1.2 {
            let f = g.shockT / 1.2, r = 0.5 + f * 7
            for i in 0..<48 {
                let a = Double(i) / 48 * .pi * 2
                let p = worldPt(D3(cos(a) * r, sin(a) * r * 0.9, 0.1 + f * 0.8))
                glows.append(GlowU(posSize: F4(p.f, Float(g.size * (0.25 + f * 0.6))), color: F4(SIMD3(0.85, 0.92, 1.0) * Float((1 - f) * (1 - f) * 0.35), -1)))
            }
        }
        if g.tanker.active {
            let tq = g.tanker.q, tp = g.pos + g.tanker.rel - cam
            func tw(_ p: D3) -> D3 { tp + tq.act(p * 0.001) }
            for e in tankerKit.engines { glows.append(GlowU(posSize: F4(tw(e + D3(0, 0, 1)).f, Float(0.003 + 0.006 * g.tanker.thrust)), color: F4(SIMD3(0.5, 0.8, 2.4), -1))) }
            let tb = Int(g.time / 0.6) % 2 == 0
            for (p, c) in tankerKit.lights { glows.append(GlowU(posSize: F4(tw(p).f, 0.0025), color: F4(c * 2.4, tb ? 1 : 0.2))) }
            // the fuel line: a glowing hose from the boom to your ship, with pulses running along it
            if g.tanker.line > 0.01 {
                let a = tw(tankerKit.boomTip), bEnd = worldPt(D3(0, 0.08, 0.05))
                let n = 36, reach = Int(Double(n) * g.tanker.line)
                for i in 0...reach {
                    let f = Double(i) / Double(n)
                    let sag = sin(f * .pi) * simd_distance(a, bEnd) * 0.08
                    let up = simd_normalize(g.pos - g.nearestWorld(g.pos).pos)
                    let p = a + (bEnd - a) * f - up * sag
                    let pulse = 0.5 + 0.5 * sin(f * 18 - g.time * 9)
                    glows.append(GlowU(posSize: F4(p.f, Float(0.0012 + 0.0008 * pulse)), color: F4(SIMD3(0.3, 1.6, 2.2) * Float(0.6 + pulse * 0.8), -1)))
                }
            }
        }
        if let c = S.cargo {
            let uM = S.length / (S.size * 1000)
            if g.liftK > 0.01, let ly = g.cargoLiftY {   // glowing guide cables down to the lift platform
                for (x, z) in [(c.lift.x0 + 0.4, c.lift.z0 + 0.4), (c.lift.x1 - 0.4, c.lift.z0 + 0.4), (c.lift.x0 + 0.4, c.lift.z1 - 0.4), (c.lift.x1 - 0.4, c.lift.z1 - 0.4)] {
                    let n = 24
                    for i in 0...n {
                        let y = c.floorY + (ly - c.floorY) * Double(i) / Double(n)
                        glows.append(GlowU(posSize: F4(worldPt(D3(x, y, z) * uM).f, 0.0007), color: F4(SIMD3(0.3, 1.5, 2.2), -1)))
                    }
                }
            }
            // rover headlights
            func rp(_ p: D3) -> D3 {
                if g.rover.inShip { return worldPt((g.rover.p + simd_quatd(angle: g.rover.yaw, axis: D3(0, 1, 0)).act(p)) * uM) }
                let side = simd_normalize(simd_cross(g.rover.wfwd, g.rover.wup))
                return g.rover.wpos - cam + (side * p.x + g.rover.wup * p.y - g.rover.wfwd * p.z) * 0.001
            }
            if g.driving || !g.rover.inShip {
                for x in [-0.95, 0.95] { glows.append(GlowU(posSize: F4(rp(D3(x, 1.45, -4.1)).f, 0.0011), color: F4(SIMD3(2.6, 2.5, 2.2) * (g.driving ? 1 : 0.3), 1))) }
                for x in [-1.2, 1.2] { glows.append(GlowU(posSize: F4(rp(D3(x, 1.3, 4.05)).f, 0.0007), color: F4(SIMD3(2.6, 0.25, 0.15) * (g.rover.speed < -0.5 || g.keys.contains(Key.space) ? 1.6 : 0.6), 1))) }
            }
            // dust kicked up behind the wheels on a planet
            if !g.rover.inShip && abs(g.rover.speed) > 6 {
                let k2 = Float(min(1, (abs(g.rover.speed) - 6) / 30))
                for i in 0..<14 {
                    let z = 3.5 + Double(i) * 0.9 + sin(g.time * 7 + Double(i)) * 0.3, x = (i % 2 == 0 ? 1.0 : -1.0) * (1.0 + Double(i) * 0.08)
                    glows.append(GlowU(posSize: F4(rp(D3(x, 0.4 + Double(i) * 0.08, z)).f, Float(0.0012 + Double(i) * 0.00025)), color: F4(SIMD3(0.7, 0.62, 0.5) * k2 * Float(0.3 - Double(i) * 0.018), -1)))
                }
            }
        }
        // the robot's sonic boom: a shock ring spreading from where it broke Mach 1, and a vapour cone round it near Mach 1
        if g.heroBoomT < 1.5 {
            let f = g.heroBoomT / 1.5, d = simd_normalize(g.w.vel + D3(1e-9, 0, 0))
            let a1 = simd_normalize(simd_cross(d, D3(0, 1, 0) + D3(1e-6, 0, 0))), a2 = simd_cross(d, a1)
            let r: Double = 0.003 + f * 0.06
            for i in 0..<48 {
                let a: Double = Double(i) / 48 * .pi * 2
                let dir: D3 = a1 * cos(a) + a2 * sin(a)
                let p: D3 = g.heroBoomPos - cam + dir * r
                glows.append(GlowU(posSize: F4(p.f, Float(0.002 + f * 0.01)), color: F4(SIMD3(0.85, 0.92, 1.0) * Float((1 - f) * (1 - f) * 0.4), -1)))
            }
        }
        if g.heroVapor > 0.02 && g.mode == .walk {
            let d = simd_normalize(g.w.vel + D3(1e-9, 0, 0)), a1 = simd_normalize(simd_cross(d, D3(0, 1, 0) + D3(1e-6, 0, 0))), a2 = simd_cross(d, a1)
            for i in 0..<24 {
                let a: Double = Double(i) / 24 * .pi * 2 + g.time * 3
                let dir: D3 = a1 * cos(a) + a2 * sin(a)
                let p: D3 = g.w.pos - cam + dir * 0.0013 - d * 0.0006
                glows.append(GlowU(posSize: F4(p.f, 0.0009), color: F4(SIMD3(0.9, 0.95, 1.0) * Float(g.heroVapor * 0.18), -1)))
            }
        }
        // a superhero landing: a flash at the impact, a ring of dust racing outward, debris thrown up
        if g.heroLandT < 2.5, let W = g.w.world ?? Optional(g.near) {
            let f = g.heroLandT / 2.5, u = simd_normalize(g.heroLandPos - W.pos)
            let a1 = simd_normalize(simd_cross(u, D3(0, 1, 0))), a2 = simd_cross(u, a1), K = Float(g.heroLandK)
            let base = g.heroLandPos - cam
            if g.heroLandT < 0.25 { glows.append(GlowU(posSize: F4((base + u * 0.0005).f, Float(0.004 * K)), color: F4(SIMD3(3.0, 2.6, 2.0) * Float(1 - g.heroLandT / 0.25) * K, 1))) }
            let Kd: Double = g.heroLandK, grow: Double = 1 - pow(1 - f, 3)
            let r: Double = 0.0015 + 0.022 * Kd * grow
            for i in 0..<64 {
                let a: Double = Double(i) / 64 * .pi * 2, wob: Double = 1 + 0.12 * sin(Double(i) * 3.7)
                let dir: D3 = a1 * cos(a) + a2 * sin(a)
                let p: D3 = base + dir * (r * wob) + u * (0.0004 + f * 0.002)
                glows.append(GlowU(posSize: F4(p.f, Float(0.0015 + f * 0.004 * Kd)), color: F4(SIMD3(0.75, 0.66, 0.52) * Float((1 - f) * (1 - f)) * 0.45 * K, -1)))
            }
            for i in 0..<18 {                                   // debris arcing up and out
                let a = Double(i) * 2.399, sp: Double = 0.006 + Double((i * 37) % 10) * 0.0012
                let tt: Double = g.heroLandT
                let h: Double = sp * tt * 1.2 - 0.0049 * tt * tt
                if h < 0 { continue }
                let out: Double = sp * tt * 0.8 * Double(K)
                let dir: D3 = a1 * cos(a) + a2 * sin(a)
                let p: D3 = base + dir * out + u * h
                glows.append(GlowU(posSize: F4(p.f, 0.00035), color: F4(SIMD3(0.5, 0.42, 0.32) * K, -1)))
            }
        }
        // dust: a burst when a ship touches down, a swirl under one hovering low
        do {
            let W = g.nearestWorld(g.pos), u = simd_normalize(g.pos - W.pos)
            let gp = W.pos + u * W.groundRadius(u) - cam
            let a1 = simd_normalize(simd_cross(u, D3(0, 1, 0))), a2 = simd_cross(u, a1)
            let wet = g.waterDepth(W, u) > 0
            let col: SIMD3<Float> = wet ? SIMD3(0.85, 0.92, 1.0) : SIMD3(0.72, 0.64, 0.5)
            if g.dustT < 4.5 && g.mode != .title {
                let f = g.dustT / 4.5, heavy = 0.4 + 0.6 * ss(0.05, 0.6, g.size)
                for i in 0..<48 {
                    let a = Double(i) / 48 * .pi * 2 + Double(i % 3) * 0.7
                    let r = g.size * (0.35 + f * 0.9 * (0.8 + 0.4 * Double((i * 7) % 5) / 5))
                    let p = gp + (a1 * cos(a) + a2 * sin(a)) * r + u * g.size * (0.03 + f * 0.12)
                    glows.append(GlowU(posSize: F4(p.f, Float(g.size * (0.12 + f * 0.25))), color: F4(col * Float((1 - f) * (1 - f) * 0.3 * heavy), -1)))
                }
            }
            let hoverLow = (g.mode == .hover || g.mode == .landing || g.mode == .takeoff || g.sh.active) && g.alt < g.size * 2.5 && g.engineK > 0.5
            if hoverLow {
                let k2 = 1 - g.alt / (g.size * 2.5)
                for i in 0..<30 {
                    let a = Double(i) / 30 * .pi * 2 + g.time * 0.6
                    let r = g.size * (0.45 + 0.15 * sin(g.time * 1.3 + Double(i)))
                    let p = gp + (a1 * cos(a) + a2 * sin(a)) * r + u * g.size * 0.04
                    glows.append(GlowU(posSize: F4(p.f, Float(g.size * 0.2)), color: F4(col * Float(0.14 * k2), -1)))
                }
            }
        }
        if g.ships.contains(where: { $0.name == "Heron" }), simd_distance(g.stationPos, cam) < 600 {      // the station's traffic: engine glows and beacons
            for t in g.trafficShips() {
                let tail = t.q.act(D3(0, 0, 0.014)), d = simd_distance(t.pos, cam)
                glows.append(GlowU(posSize: F4((t.pos + tail - cam).f, Float(max(0.006, d * 0.003))), color: F4(SIMD3(2.8, 0.45, 0.15), -1)))
                glows.append(GlowU(posSize: F4((t.pos - cam).f, Float(max(0.003, d * 0.0015))), color: F4(SIMD3(2.5, 0.4, 0.3), Int(g.time * 1.5 + d) % 2 == 0 ? 1 : 0.2)))
            }
            let sd = simd_distance(g.stationPos, cam)                    // beacon lights round the station's rim
            for k in 0..<8 {
                let a = Double(k) / 8 * .pi * 2 + g.time * 0.01
                let up = simd_normalize(g.stationPos - g.worlds[0].pos), e1 = simd_normalize(simd_cross(up, D3(0, 1, 0))), e2 = simd_cross(up, e1)
                let p = g.stationPos + (e1 * cos(a) + e2 * sin(a)) * 2.15
                glows.append(GlowU(posSize: F4((p - cam).f, Float(max(0.02, sd * 0.002))), color: F4(SIMD3(2.8, 0.6, 0.3), Int(g.time / 0.8 + Double(k)) % 3 == 0 ? 1 : 0.1)))
            }
        }
        let blink = Int(g.time / 0.7) % 2 == 0
        for l in S.navLights { glows.append(GlowU(posSize: F4(worldPt(l.pos).f, Float(Double(l.size) * k * 0.5)), color: F4(l.color * 2.5, (blink ? 1 : 0.12) * pwF))) }
        for l in S.steadyLights { glows.append(GlowU(posSize: F4(worldPt(l.pos).f, Float(Double(l.size) * k * 0.5)), color: F4(l.color * 2.0, pwF))) }
        if g.gear > 0.7 && pw > 0.5 { for p in S.landLights { glows.append(GlowU(posSize: F4(worldPt(p).f, Float(0.09 * k * 0.5)), color: F4(SIMD3(2.4, 2.3, 2.1), pwF))) } }
        // depot pad lights and blinking beacons
        let beaconOn = Int(g.time / 0.9) % 2 == 0
        for d in g.depots {
            let dist = simd_distance(d.pos, cam)
            if dist > 250 { continue }
            let M = depotModel(d, cam)
            func wp(_ p: D3) -> D3 { let v = M * SIMD4(p, 1); return D3(v.x, v.y, v.z) }
            if dist < 25 { for l in depotLights { glows.append(GlowU(posSize: F4(wp(l).f, 0.0012), color: F4(SIMD3(2.6, 2.0, 1.2), 1))) } }
            let bs = max(0.004, dist * 0.004)
            glows.append(GlowU(posSize: F4(wp(depotBeacon).f, Float(bs)), color: F4(SIMD3(3.0, 0.5, 0.35), beaconOn ? 1 : 0.15)))
        }
        glows.append(GlowU(posSize: F4(sunRel.f, 800000), color: F4(SIMD3(1.0, 0.82, 0.6) * 1.4, -1)))
        // distant worlds shine like bright stars so you can find them across the gulf
        for P in g.worlds {
            let rel = P.pos - cam, d = simd_length(rel)
            if d < P.R * 25 { continue }
            let lit = 0.35 + 0.65 * max(0, simd_dot(simd_normalize(g.sunPos - P.pos), simd_normalize(cam - P.pos)))
            let tint = simd_normalize(P.atmo.rayleigh + SIMD3<Float>(0.3, 0.3, 0.3)) * 1.6
            glows.append(GlowU(posSize: F4(rel.f, Float(d * 0.004)), color: F4(tint * Float(lit) * Float(ss(25, 60, d / P.R)), 1)))
        }
        if g.mode == .walk && g.w.jet > 0.02 {
            for p in g.jetPoints { glows.append(GlowU(posSize: F4((p - cam).f, Float((0.04 + g.w.jet * 0.5 * Double.random(in: 0.85...1.15)) * 0.001 * 0.5)), color: F4(SIMD3(0.62, 0.88, 1.0) * 2.2, 1))) }
        }
        enc.setRenderPipelineState(pGlow); enc.setDepthStencilState(dsTest)
        enc.setVertexBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1)
        glowRing = (glowRing + 1) % glowBufs.count
        let gb = glowBufs[glowRing], gn = min(glows.count, 2048)
        glows.withUnsafeBytes { memcpy(gb.contents(), $0.baseAddress!, gn * MemoryLayout<GlowU>.stride) }
        enc.setVertexBuffer(gb, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: gn)

        // speed streaks
        if g.streakOpacity > 0.005 {
            memcpy(streakBuf.contents(), g.streaks, g.streaks.count * 4)
            var sc = F4(g.streakColor, g.streakOpacity)
            enc.setRenderPipelineState(pStreak); enc.setDepthStencilState(dsNone)
            enc.setVertexBuffer(streakBuf, offset: 0, index: 0); enc.setVertexBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1)
            enc.setFragmentBytes(&sc, length: 16, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: 280 * 2)
        }
        enc.endEncoding()

        // atmosphere: scattering + extinction over everything drawn so far
        var atmos: [AtmoPlanetU] = terrain.worlds.map { P in
            AtmoPlanetU(centerR: F4((P.pos - cam).f, Float(P.R)), topHrHmG: F4(Float(P.atmo.top), P.atmo.rayleighH, P.atmo.mieH, P.atmo.mieG),
                        rayleigh: F4(P.atmo.rayleigh, P.atmo.mie), mieTint: F4(P.atmo.mieTint, 0))
        }
        var count = Int32(atmos.count)
        let ap = MTLRenderPassDescriptor()
        ap.colorAttachments[0].texture = hdr; ap.colorAttachments[0].loadAction = .load; ap.colorAttachments[0].storeAction = .store
        let ae = cb.makeRenderCommandEncoder(descriptor: ap)!
        ae.setRenderPipelineState(pAtmo)
        ae.setFragmentTexture(depth, index: 0)
        ae.setFragmentBytes(&F, length: MemoryLayout<FrameU>.stride, index: 0)
        ae.setFragmentBytes(&atmos, length: MemoryLayout<AtmoPlanetU>.stride * atmos.count, index: 1)
        ae.setFragmentBytes(&count, length: 4, index: 2)
        ae.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ae.endEncoding()

        // bloom
        func pass(_ target: MTLTexture, _ pipe: MTLRenderPipelineState, _ src: MTLTexture, _ params: F4, load: Bool = false) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = target; d.colorAttachments[0].loadAction = load ? .load : .dontCare; d.colorAttachments[0].storeAction = .store
            let e = cb.makeRenderCommandEncoder(descriptor: d)!
            e.setRenderPipelineState(pipe); e.setFragmentTexture(src, index: 0)
            var p = params; e.setFragmentBytes(&p, length: 16, index: 0)
            e.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); e.endEncoding()
        }
        pass(bloom[0], pBright, hdr!, F4(1 / Float(w), 1 / Float(h), 1.6, 0))
        for i in 1..<bloom.count { pass(bloom[i], pDown, bloom[i - 1], F4(1 / Float(bloom[i - 1].width), 1 / Float(bloom[i - 1].height), 0, 0)) }
        for i in stride(from: bloom.count - 1, to: 0, by: -1) { pass(bloom[i - 1], pUpAdd, bloom[i], F4(1 / Float(bloom[i].width), 1 / Float(bloom[i].height), 0, 0), load: true) }

        // tone map to the screen
        let cd = MTLRenderPassDescriptor()
        cd.colorAttachments[0].texture = output; cd.colorAttachments[0].loadAction = .dontCare; cd.colorAttachments[0].storeAction = .store
        let ce = cb.makeRenderCommandEncoder(descriptor: cd)!
        ce.setRenderPipelineState(pComposite)
        ce.setFragmentTexture(hdr, index: 0); ce.setFragmentTexture(bloom[0], index: 1)
        let hw = Float(hdr!.width), hh = Float(hdr!.height); let upscale = Float(output.width) / max(1, hw)   // how much the image is stretched to the screen
        var cp = F4(Float(0.1 + g.abLevel * 0.04), 1.0, 1 / hw, min(1.0, 0.35 + 0.45 * (upscale - 1)))
        var cp2 = F4(1 / hh, 0, 0, 0)
        ce.setFragmentBytes(&cp2, length: 16, index: 1)
        ce.setFragmentBytes(&cp, length: 16, index: 0)
        ce.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ce.endEncoding()
    }

    private func drawSphere(_ enc: MTLRenderCommandEncoder, _ F: inout FrameU, _ o: inout ObjU, frag: Bool = true) {
        enc.setVertexBuffer(sphere.vb, offset: 0, index: 0)
        enc.setVertexBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1); enc.setFragmentBytes(&F, length: MemoryLayout<FrameU>.stride, index: 1)
        enc.setVertexBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2); enc.setFragmentBytes(&o, length: MemoryLayout<ObjU>.stride, index: 2)
        enc.drawIndexedPrimitives(type: .triangle, indexCount: sphere.count, indexType: .uint32, indexBuffer: sphere.ib!, indexBufferOffset: 0)
    }

    /// CPU copy of the shader's sunlight-through-air model (used to light the ship)
    private func sunTransmitCPU(_ cosZ: Double, _ P: World) -> SIMD3<Float> {
        let c = clampd(cosZ, -0.2, 1)
        let zen = acos(clampd(c, -1, 1)) * 180 / .pi
        let m = min(1 / max(c + 0.50572 * pow(max(96.07995 - zen, 0.1), -1.6364), 0.02), 40)
        let tau = (P.atmo.rayleigh * P.atmo.rayleighH + SIMD3(repeating: P.atmo.mie * 1.1 * P.atmo.mieH)) * Float(m)
        let inside = 1 - clampd((simd_distance(game.pos, P.pos) - P.R) / P.atmo.top, 0, 1)
        let t = SIMD3<Float>(exp(-tau.x), exp(-tau.y), exp(-tau.z))
        let full = SIMD3<Float>(repeating: 1)
        return (full + (t - full) * Float(inside)) * Float(ss(-0.12, 0.04, cosZ) * inside + (1 - inside))
    }
}

func toFloat(_ m: simd_double4x4) -> float4x4 {
    float4x4(columns: (F4(Float(m.columns.0.x), Float(m.columns.0.y), Float(m.columns.0.z), Float(m.columns.0.w)),
                       F4(Float(m.columns.1.x), Float(m.columns.1.y), Float(m.columns.1.z), Float(m.columns.1.w)),
                       F4(Float(m.columns.2.x), Float(m.columns.2.y), Float(m.columns.2.z), Float(m.columns.2.w)),
                       F4(Float(m.columns.3.x), Float(m.columns.3.y), Float(m.columns.3.z), Float(m.columns.3.w))))
}
