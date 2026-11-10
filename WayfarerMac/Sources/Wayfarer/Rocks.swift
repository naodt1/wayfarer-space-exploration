import Foundation
import Metal
import ModelIO
import CoreGraphics
import ImageIO
import simd

// Photo-scanned rocks (Poly Haven, CC0) scattered over the ground near the camera.
// Every rock model gets two extra levels of detail made by vertex clustering, and placement is
// deterministic per cube-face cell, so the same rocks are always in the same places.

let ROCK_STRIDE = 8          // floats per vertex: pos3 normal3 uv2
let ROCK_LOD_DIST: [Double] = [0.025, 0.09]   // km: LOD0 closer than 25 m, LOD1 to 90 m, LOD2 beyond

struct RockLOD { let vb: MTLBuffer; let ib: MTLBuffer; let indexCount: Int }
struct RockKind { var lods: [RockLOD]; var height: Float }     // models are normalised to 1 m wide, base at y = 0

final class RockSet {
    let kinds: [RockKind]
    let albedo: MTLTexture          // sRGB colour
    let packed: MTLTexture          // RG normal (GL), B roughness
    let mean: SIMD3<Float>          // average linear albedo (for tinting toward each world's rock colour)
    init(kinds: [RockKind], albedo: MTLTexture, packed: MTLTexture, mean: SIMD3<Float>) {
        self.kinds = kinds; self.albedo = albedo; self.packed = packed; self.mean = mean
    }
}

/// merge vertices that fall in the same grid cell (and roughly the same UV, so texture seams survive)
private func clusterLOD(_ v: [Float], _ idx: [UInt32], cell: Float) -> ([Float], [UInt32]) {
    var map: [Int: UInt32] = [:]
    var acc: [Float] = []; var cnt: [Float] = []
    var remap = [UInt32](repeating: 0, count: v.count / ROCK_STRIDE)
    for i in 0..<(v.count / ROCK_STRIDE) {
        let b = i * ROCK_STRIDE
        let kx = Int(floor(v[b] / cell)) & 0x3FF, ky = Int(floor(v[b + 1] / cell)) & 0x3FF, kz = Int(floor(v[b + 2] / cell)) & 0x3FF
        let ku = Int(floor(v[b + 6] * 6)) & 0x3F, kv = Int(floor(v[b + 7] * 6)) & 0x3F
        let key = kx | ky << 10 | kz << 20 | ku << 30 | kv << 36
        if let id = map[key] {
            remap[i] = id
            let a = Int(id) * ROCK_STRIDE
            for k in 0..<ROCK_STRIDE { acc[a + k] += v[b + k] }
            cnt[Int(id)] += 1
        } else {
            let id = UInt32(cnt.count); map[key] = id; remap[i] = id
            acc += v[b..<(b + ROCK_STRIDE)]; cnt.append(1)
        }
    }
    for i in 0..<cnt.count {
        let a = i * ROCK_STRIDE
        for k in 0..<ROCK_STRIDE { acc[a + k] /= cnt[i] }
        let n = simd_normalize(SIMD3<Float>(acc[a + 3], acc[a + 4], acc[a + 5]))
        acc[a + 3] = n.x; acc[a + 4] = n.y; acc[a + 5] = n.z
    }
    var out: [UInt32] = []; out.reserveCapacity(idx.count / 4)
    for t in stride(from: 0, to: idx.count - 2, by: 3) {
        let a = remap[Int(idx[t])], b = remap[Int(idx[t + 1])], c = remap[Int(idx[t + 2])]
        if a != b && b != c && a != c { out += [a, b, c] }
    }
    return (acc, out)
}

private func decodeImage(_ url: URL, size: Int, srgb: Bool) -> [UInt8]? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var px = [UInt8](repeating: 0, count: size * size * 4)
    let cs = srgb ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return px
}

func loadRocks(device: MTLDevice) -> RockSet? {
    guard let dir = assetsURL()?.appendingPathComponent("Models/rock_moss_set_01") else { return nil }
    let asset = MDLAsset(url: dir.appendingPathComponent("rock_moss_set_01.usdc"))
    var meshes: [MDLMesh] = []
    func walk(_ o: MDLObject) {
        if let m = o as? MDLMesh { meshes.append(m) }
        for c in o.children.objects { walk(c) }
    }
    for i in 0..<asset.count { walk(asset.object(at: i)) }
    if meshes.isEmpty { print("rocks: no meshes"); return nil }

    let vd = MDLVertexDescriptor()
    vd.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
    vd.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
    vd.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
    vd.layouts[0] = MDLVertexBufferLayout(stride: 32)

    var kinds: [RockKind] = []
    for m in meshes {
        m.vertexDescriptor = vd
        let n = m.vertexCount
        let raw = m.vertexBuffers[0].map().bytes.bindMemory(to: Float.self, capacity: n * 8)
        var v = [Float](repeating: 0, count: n * 8)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in 0..<n {
            let b = i * 8
            // Z-up → Y-up
            let p = SIMD3<Float>(raw[b], raw[b + 2], -raw[b + 1]), nn = SIMD3<Float>(raw[b + 3], raw[b + 5], -raw[b + 4])
            v[b] = p.x; v[b + 1] = p.y; v[b + 2] = p.z; v[b + 3] = nn.x; v[b + 4] = nn.y; v[b + 5] = nn.z
            v[b + 6] = raw[b + 6]; v[b + 7] = 1 - raw[b + 7]
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        // base centre at the origin, 1 m across
        let width = max(hi.x - lo.x, hi.z - lo.z), s = 1 / max(width, 1e-4)
        let c = SIMD3<Float>((lo.x + hi.x) / 2, lo.y, (lo.z + hi.z) / 2)
        for i in 0..<n {
            let b = i * 8
            v[b] = (v[b] - c.x) * s; v[b + 1] = (v[b + 1] - c.y) * s; v[b + 2] = (v[b + 2] - c.z) * s
        }
        var idx: [UInt32] = []
        for case let sm as MDLSubmesh in m.submeshes ?? [] {
            let ib = sm.indexBuffer(asIndexType: .uInt32)
            let p = ib.map().bytes.bindMemory(to: UInt32.self, capacity: sm.indexCount)
            idx += UnsafeBufferPointer(start: p, count: sm.indexCount)
        }
        // keep winding consistent after the axis swap (a rotation, so nothing to flip)
        var lods: [RockLOD] = []
        func add(_ vv: [Float], _ ii: [UInt32]) {
            lods.append(RockLOD(vb: device.makeBuffer(bytes: vv, length: vv.count * 4, options: .storageModeShared)!,
                                ib: device.makeBuffer(bytes: ii, length: ii.count * 4, options: .storageModeShared)!, indexCount: ii.count))
        }
        add(v, idx)
        let l1 = clusterLOD(v, idx, cell: 1.0 / 28), l2 = clusterLOD(v, idx, cell: 1.0 / 9)
        add(l1.0, l1.1); add(l2.0, l2.1)
        kinds.append(RockKind(lods: lods, height: (hi.y - lo.y) * s))
        if CommandLine.arguments.contains("--snapshot") && kinds.count == 1 {
            print("rocks: \(meshes.count) models · LOD tris \(idx.count / 3) / \(l1.1.count / 3) / \(l2.1.count / 3)")
        }
    }

    // textures
    let size = 1024, tdir = dir.appendingPathComponent("textures")
    guard let col = decodeImage(tdir.appendingPathComponent("rock_moss_set_01_diff_1k.jpg"), size: size, srgb: true),
          let nor = decodeImage(tdir.appendingPathComponent("rock_moss_set_01_nor_gl_1k.jpg"), size: size, srgb: false),
          let rough = decodeImage(tdir.appendingPathComponent("rock_moss_set_01_rough_1k.jpg"), size: size, srgb: false) else { print("rocks: textures missing"); return nil }
    var pk = [UInt8](repeating: 255, count: size * size * 4)
    var acc = SIMD3<Double>(0, 0, 0)
    func lin(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
    for k in 0..<(size * size) {
        pk[k * 4] = nor[k * 4]; pk[k * 4 + 1] = nor[k * 4 + 1]; pk[k * 4 + 2] = rough[k * 4]
        if k % 61 == 0 { acc += SIMD3(lin(col[k * 4]), lin(col[k * 4 + 1]), lin(col[k * 4 + 2])) }
    }
    let mean = acc / Double((size * size + 60) / 61)
    func tex(_ fmt: MTLPixelFormat, _ px: [UInt8]) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: size, height: size, mipmapped: true)
        d.usage = .shaderRead; d.storageMode = .shared
        let t = device.makeTexture(descriptor: d)!
        t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: px, bytesPerRow: size * 4)
        return t
    }
    let albedo = tex(.rgba8Unorm_srgb, col), packed = tex(.rgba8Unorm, pk)
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
    bl.generateMipmaps(for: albedo); bl.generateMipmaps(for: packed); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return RockSet(kinds: kinds, albedo: albedo, packed: packed, mean: SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z)))
}

// MARK: - placement

struct RockInstance {
    var pos: D3              // world position of the base (km)
    var q: simd_quatf        // orientation
    var size: Float          // metres across
    var kind: Int
    var tint: SIMD3<Float>
}

private let FACE_AXES: [(n: D3, r: D3, u: D3)] = [
    (D3(1, 0, 0), D3(0, 0, -1), D3(0, 1, 0)), (D3(-1, 0, 0), D3(0, 0, 1), D3(0, 1, 0)),
    (D3(0, 1, 0), D3(1, 0, 0), D3(0, 0, -1)), (D3(0, -1, 0), D3(1, 0, 0), D3(0, 0, 1)),
    (D3(0, 0, 1), D3(1, 0, 0), D3(0, 1, 0)), (D3(0, 0, -1), D3(-1, 0, 0), D3(0, 1, 0)),
]

/// two grids: small stones in 10 m cells out to 260 m, larger rocks and boulders in 45 m cells out to 1.6 km
private struct Tier { let cell: Double; let range: Double; let minSize: Double; let maxSize: Double; let id: Int }
private let TIERS = [Tier(cell: 0.010, range: 0.26, minSize: 0.3, maxSize: 1.4, id: 0),
                     Tier(cell: 0.045, range: 1.6, minSize: 1.0, maxSize: 7.0, id: 1),
                     Tier(cell: 0.0022, range: GRASS_RANGE, minSize: 0.8, maxSize: 1.35, id: 2),     // grass clumps
                     Tier(cell: 0.028, range: TREE_RANGE, minSize: 0.85, maxSize: 1.6, id: 3),       // trees (Flora.swift)
                     Tier(cell: 0.006, range: BUSH_RANGE, minSize: 0.75, maxSize: 1.35, id: 4)]      // bushes and flowers
let GRASS_RANGE = 0.055
let GRASS_KIND = 100          // instances with kind >= this are grass clumps (variant = kind - GRASS_KIND)
let GRASS_VARIANTS = 4

/// a clump of curved grass blades, in metres, base at the origin (same vertex layout as the rocks)
func buildGrassClumps(device: MTLDevice) -> [RockLOD] {
    var out: [RockLOD] = []
    for vi in 0..<GRASS_VARIANTS {
        let rnd = Mulberry(UInt32(4242 + vi))
        var v: [Float] = [], idx: [UInt32] = []
        for _ in 0..<16 {
            let a = rnd.next() * .pi * 2, r = sqrt(rnd.next()) * 0.32
            let base = SIMD3<Float>(Float(cos(a) * r), 0, Float(sin(a) * r))
            let h = Float(0.22 + rnd.next() * 0.38), w = Float(0.018 + rnd.next() * 0.014)
            let facing = Float(rnd.next() * .pi * 2), lean = Float(0.15 + rnd.next() * 0.5)
            let side = SIMD3<Float>(cos(facing), 0, sin(facing)), fwd = SIMD3<Float>(-sin(facing), 0, cos(facing))
            let n = simd_normalize(fwd + SIMD3(0, 0.35, 0))
            let start = UInt32(v.count / 8), segs = 4
            for k in 0...segs {
                let t = Float(k) / Float(segs)
                let p = base + SIMD3(0, h * t, 0) + fwd * (lean * h * t * t)
                let ww = w * (1 - t * 0.92)
                for s in [-1 as Float, 1] {
                    let q = p + side * (ww * s)
                    v += [q.x, q.y, q.z, n.x, n.y, n.z, t, s * 0.5 + 0.5]
                }
            }
            for k in 0..<UInt32(segs) {
                let i = start + k * 2
                idx += [i, i + 1, i + 2, i + 1, i + 3, i + 2]
            }
        }
        out.append(RockLOD(vb: device.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared)!,
                           ib: device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)!, indexCount: idx.count))
    }
    return out
}

final class RockField {
    private var cache: [Int: [RockInstance]] = [:]
    private var pendingKeys = Set<Int>()
    private let queue = DispatchQueue(label: "rocks", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var done: [(Int, [RockInstance])] = []
    private var worldID: ObjectIdentifier?
    private var lastCam = D3(1e30, 0, 0)
    private(set) var visible: [RockInstance] = []
    let kindCount: Int
    let mean: SIMD3<Float>
    var avoid: [D3] = []                 // keep clear of discovery sites
    var grassMean = SIMD3<Float>(0.12, 0.16, 0.05)     // average colour of the grass ground texture
    var avoidWide: [D3] = []             // keep trees off depot pads and out of the town
    var avoidWorld: ObjectIdentifier?
    var flora: (green: [Int], autumn: [Int], dry: [Int], bush: [Int], flower: [Int]) = ([], [], [], [], [])
    var idle: Bool { lock.lock(); defer { lock.unlock() }; return pendingKeys.isEmpty && done.isEmpty }

    init(kindCount: Int, mean: SIMD3<Float>) { self.kindCount = kindCount; self.mean = mean }

    /// cube face coordinates of a direction (Newton refinement of the spherified-cube mapping)
    private func faceUV(_ d: D3, _ f: Int) -> (Double, Double)? {
        let F = FACE_AXES[f]
        let dn = simd_dot(d, F.n)
        if dn < 0.35 { return nil }
        var u = simd_dot(d, F.r) / dn, v = simd_dot(d, F.u) / dn
        // Newton's method with a numerical Jacobian (the mapping has no closed-form inverse)
        for _ in 0..<8 {
            let c = cubeDir(f, u, v), h = 1e-6
            let du = (cubeDir(f, u + h, v) - c) / h, dv = (cubeDir(f, u, v + h) - c) / h
            let e = d - c
            // least squares: [du dv] * [x y] = e
            let a11 = simd_dot(du, du), a12 = simd_dot(du, dv), a22 = simd_dot(dv, dv)
            let b1 = simd_dot(du, e), b2 = simd_dot(dv, e)
            let det = a11 * a22 - a12 * a12
            if abs(det) < 1e-20 { break }
            let x = (b1 * a22 - b2 * a12) / det, y = (a11 * b2 - a12 * b1) / det
            u += x; v += y
            if abs(x) + abs(y) < 1e-12 { break }
        }
        return (u, v)
    }

    func update(cam: D3, world W: World) {
        let wid = ObjectIdentifier(W)
        if wid != worldID { worldID = wid; cache = [:]; visible = []; lock.lock(); done = []; pendingKeys = []; lock.unlock(); lastCam = D3(1e30, 0, 0) }
        lock.lock(); let fresh = done; done = []; lock.unlock()
        for (k, v) in fresh { cache[k] = v }
        if fresh.isEmpty && simd_distance(cam, lastCam) < 0.004 { return }
        let d = simd_normalize(cam - W.pos)
        let alt = simd_distance(cam, W.pos) - W.groundRadius(d)
        if alt > 2.5 { if !visible.isEmpty { visible = [] }; lastCam = cam; return }
        lastCam = cam
        let uvPerKm = 4 / (.pi * W.R)
        var want: [(Int, Int, Int, Int, Tier)] = []        // key, face, iu, iv
        var vis: [RockInstance] = []
        var keep = Set<Int>()
        for t in TIERS {
            let cu = t.cell * uvPerKm, ru = t.range * uvPerKm
            let n = Int(2 / cu) + 1
            for f in 0..<6 {
                guard let (u, v) = faceUV(d, f) else { continue }
                let i0 = max(0, Int(floor((u + 1 - ru) / cu))), i1 = min(n - 1, Int(floor((u + 1 + ru) / cu)))
                let j0 = max(0, Int(floor((v + 1 - ru) / cu))), j1 = min(n - 1, Int(floor((v + 1 + ru) / cu)))
                if i0 > i1 || j0 > j1 { continue }
                for i in i0...i1 { for j in j0...j1 {
                    let du = (Double(i) + 0.5) * cu - 1 - u, dv = (Double(j) + 0.5) * cu - 1 - v
                    if du * du + dv * dv > (ru + cu) * (ru + cu) { continue }
                    let key = ((t.id * 6 + f) << 50) | (i << 25) | j
                    keep.insert(key)
                    if let c = cache[key] { vis += c } else { want.append((key, f, i, j, t)) }
                }}
            }
        }
        visible = vis
        // forget far cells
        if cache.count > keep.count * 2 + 2000 { cache = cache.filter { keep.contains($0.key) } }
        lock.lock()
        let todo = want.filter { !pendingKeys.contains($0.0) }
        for w in todo { pendingKeys.insert(w.0) }
        lock.unlock()
        if todo.isEmpty { return }
        let avoid = self.avoid, kinds = kindCount, mean = self.mean, grassMean = self.grassMean, avoidWide = self.avoidWide, flora = self.flora
        // nearest cells first
        let sorted = todo.sorted { a, b in
            let pa = cubeDir(a.1, (Double(a.2) + 0.5) * a.4.cell * uvPerKm - 1, (Double(a.3) + 0.5) * a.4.cell * uvPerKm - 1)
            let pb = cubeDir(b.1, (Double(b.2) + 0.5) * b.4.cell * uvPerKm - 1, (Double(b.3) + 0.5) * b.4.cell * uvPerKm - 1)
            return simd_dot(pa, d) > simd_dot(pb, d)
        }
        for chunk in stride(from: 0, to: sorted.count, by: 64) {
            let part = Array(sorted[chunk..<min(sorted.count, chunk + 64)])
            queue.async { [weak self] in
                var out: [(Int, [RockInstance])] = []
                for (key, f, i, j, t) in part {
                    out.append((key, t.id == 2 ? RockField.grass(W, face: f, i: i, j: j, tier: t, uvPerKm: uvPerKm, avoid: avoid, mean: grassMean)
                                : t.id >= 3 ? RockField.plants(W, face: f, i: i, j: j, tier: t, uvPerKm: uvPerKm, avoid: avoid + avoidWide, flora: flora)
                                : RockField.generate(W, face: f, i: i, j: j, tier: t, uvPerKm: uvPerKm, avoid: avoid, kinds: kinds, mean: mean)))
                }
                guard let self else { return }
                self.lock.lock()
                if ObjectIdentifier(W) == self.worldID { self.done += out }
                for o in out { self.pendingKeys.remove(o.0) }
                self.lock.unlock()
            }
        }
    }

    /// trees (tier 3) and bushes and flowers (tier 4), on the living worlds: dense in forest, scattered over grassland,
    /// autumn colours and bare trees where the land is dry; none on sand, rock, snow or steep ground
    private static func plants(_ W: World, face f: Int, i: Int, j: Int, tier t: Tier, uvPerKm: Double, avoid: [D3],
                               flora: (green: [Int], autumn: [Int], dry: [Int], bush: [Int], flower: [Int])) -> [RockInstance] {
        var out: [RockInstance] = []
        if !W.sea { return out }
        let trees = t.id == 3
        if trees && flora.green.isEmpty || !trees && flora.bush.isEmpty { return out }
        let cu = t.cell * uvPerKm
        let rnd = Mulberry(UInt32(truncatingIfNeeded: (i &* 2654435761) ^ (j &* 40503) ^ (f &* 97531) ^ (t.id &* 668265263) ^ 0x7f4a7c15))
        for _ in 0..<(trees ? 4 : 3) {
            let u = (Double(i) + rnd.next()) * cu - 1, v = (Double(j) + rnd.next()) * cu - 1
            let pick = rnd.next(), sizeR = rnd.next(), yaw = rnd.next() * .pi * 2, which = rnd.next(), shade = Float(rnd.next()), lean = rnd.next()
            let d = cubeDir(f, u, v)
            let e = W.height(d.x, d.y, d.z, 16, nil)
            if e < 0.006 { continue }                       // not on beaches or underwater
            // slope from two nearby samples
            var a = simd_cross(d, D3(0, 1, 0)); if simd_length(a) < 1e-3 { a = simd_cross(d, D3(1, 0, 0)) }
            a = simd_normalize(a); let b = simd_cross(d, a)
            let eps = 0.004 / W.R
            let ra = W.groundRadius(simd_normalize(d + a * eps)), rb = W.groundRadius(simd_normalize(d + b * eps))
            let r0 = W.R + e
            let pa = simd_normalize(d + a * eps) * ra, pb = simd_normalize(d + b * eps) * rb, p0 = d * r0
            var n = simd_normalize(simd_cross(pa - p0, pb - p0)); if simd_dot(n, d) < 0 { n = -n }
            let slope = 1 - simd_dot(n, d)
            if slope > 0.12 { continue }
            let m = W.materialFn(d.x, d.y, d.z, e, slope)
            let tot = max(1e-4, m[0] + m[1] + m[2] + m[3] + m[4] + m[5])
            let grass = m[0] / tot, forest = m[1] / tot
            // how green the land really is here (the dry belts are brown even where the layer says "forest")
            let gc = W.colorFn(d.x, d.y, d.z, e, slope)
            let greenness = Float(ss(0.9, 1.35, gc.y / max(gc.x, 1e-4)))
            let dry = 1 - greenness
            // groves and clearings: slow, warped stripes of density a few hundred metres across
            let g1 = sin(d.x * 7300 + sin(d.z * 5100) * 2.1) * sin(d.y * 6100 + sin(d.x * 4300) * 1.7)
            let g2 = sin(d.z * 19000 + d.y * 11000) * 0.35
            let grove = Float(ss(-0.35, 0.55, g1 + g2))
            let density = trees ? (forest * 0.95 + grass * 0.08) * (0.15 + 0.85 * grove) * (0.02 + 0.98 * greenness * greenness)
                                : (grass * 0.55 + forest * 0.3) * 0.7 * (0.3 + 0.7 * greenness)
            if Float(pick) > density { continue }
            let pos = W.pos + d * r0
            if avoid.contains(where: { simd_distance($0, pos) < (trees ? 0.09 : 0.03) }) { continue }
            func one(_ a: [Int]) -> Int? { a.isEmpty ? nil : a[min(a.count - 1, Int(rnd.next() * Double(a.count)))] }
            let model: Int
            if trees {
                if dry > 0.45 { model = (which < 0.3 ? one(flora.dry) : one(flora.autumn)) ?? one(flora.green)! }
                else { model = (which < 0.82 ? one(flora.green) : one(flora.autumn)) ?? one(flora.green)! }
            } else {
                model = (which < 0.62 ? one(flora.bush) : one(flora.flower)) ?? one(flora.bush)!
            }
            // trees grow straight up; small plants follow the ground a little
            let up = trees ? d : simd_normalize(simd_mix(d, n, D3(repeating: 0.5)))
            let q = simd_quatd(from: D3(0, 1, 0), to: up) * simd_quatd(angle: yaw, axis: D3(0, 1, 0))
                  * simd_quatd(angle: (lean - 0.5) * (trees ? 0.06 : 0.2), axis: D3(1, 0, 0))
            let tint = SIMD3<Float>(repeating: 0.82 + shade * 0.3) * SIMD3(1, 1.0 + (shade - 0.5) * 0.08, 1)
            out.append(RockInstance(pos: pos - d * 0.0002, q: simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real)),
                                    size: Float(t.minSize + (t.maxSize - t.minSize) * sizeR), kind: FLORA_KIND + model, tint: tint))
        }
        return out
    }

    private static func grass(_ W: World, face f: Int, i: Int, j: Int, tier t: Tier, uvPerKm: Double, avoid: [D3], mean: SIMD3<Float>) -> [RockInstance] {
        let cu = t.cell * uvPerKm
        let rnd = Mulberry(UInt32(truncatingIfNeeded: (i &* 2246822519) ^ (j &* 3266489917) ^ (f &* 668265263) ^ 0x5bd1e995))
        var out: [RockInstance] = []
        if !W.sea { return out }          // only the living worlds grow grass
        for _ in 0..<5 {
            let u = (Double(i) + rnd.next()) * cu - 1, v = (Double(j) + rnd.next()) * cu - 1
            let pick = rnd.next(), sizeR = rnd.next(), yaw = rnd.next() * .pi * 2, shade = Float(rnd.next()), variant = Int(rnd.next() * Double(GRASS_VARIANTS))
            let d = cubeDir(f, u, v)
            let e = W.height(d.x, d.y, d.z, 16, nil)
            if W.sea && e < 0.003 { continue }
            let m = W.materialFn(d.x, d.y, d.z, e, 0.04)
            let tot = max(1e-4, m[0] + m[1] + m[2] + m[3] + m[4] + m[5])
            let density = (m[0] * 1.0 + m[1] * 0.55 + m[3] * 0.08) / tot
            if Float(pick) > density { continue }
            let pos = W.pos + d * (W.R + (W.sea ? max(e, 0) : e))
            if avoid.contains(where: { simd_distance($0, pos) < 0.02 }) { continue }
            let q = simd_quatd(from: D3(0, 1, 0), to: d) * simd_quatd(angle: yaw, axis: D3(0, 1, 0))
            let gc = W.colorFn(d.x, d.y, d.z, e, 0.04)
            var col = simd_mix(mean, SIMD3<Float>(Float(gc.x), Float(gc.y), Float(gc.z)), SIMD3(repeating: min(1, W.tint * 1.2)))
            col *= 0.8 + shade * 0.4
            out.append(RockInstance(pos: pos, q: simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real)),
                                    size: Float(t.minSize + (t.maxSize - t.minSize) * sizeR), kind: GRASS_KIND + variant, tint: col))
        }
        return out
    }

    private static func generate(_ W: World, face f: Int, i: Int, j: Int, tier t: Tier, uvPerKm: Double, avoid: [D3], kinds: Int, mean: SIMD3<Float>) -> [RockInstance] {
        let cu = t.cell * uvPerKm
        let rnd = Mulberry(UInt32(truncatingIfNeeded: (i &* 73856093) ^ (j &* 19349663) ^ (f &* 83492791) ^ (t.id &* 2654435761)))
        var out: [RockInstance] = []
        let tries = t.id == 0 ? 2 : 1
        for _ in 0..<tries {
            let u = (Double(i) + rnd.next()) * cu - 1, v = (Double(j) + rnd.next()) * cu - 1
            let pick = rnd.next(), sizeR = rnd.next(), yaw = rnd.next() * .pi * 2, kindR = rnd.next(), tx = rnd.next(), tz = rnd.next()
            let d = cubeDir(f, u, v)
            let e = W.height(d.x, d.y, d.z, 16, nil)
            if W.sea && e < 0.004 { continue }
            // terrain normal from two nearby samples
            var a = simd_cross(d, D3(0, 1, 0)); if simd_length(a) < 1e-3 { a = simd_cross(d, D3(1, 0, 0)) }
            a = simd_normalize(a); let b = simd_cross(d, a)
            let eps = 0.004 / W.R
            let ra = W.groundRadius(simd_normalize(d + a * eps)), rb = W.groundRadius(simd_normalize(d + b * eps))
            let r0 = W.R + e
            let pa = simd_normalize(d + a * eps) * ra, pb = simd_normalize(d + b * eps) * rb, p0 = d * r0
            var n = simd_normalize(simd_cross(pa - p0, pb - p0)); if simd_dot(n, d) < 0 { n = -n }
            let slope = 1 - simd_dot(n, d)
            let m = W.materialFn(d.x, d.y, d.z, e, slope)
            let tot = max(1e-4, m[0] + m[1] + m[2] + m[3] + m[4] + m[5])
            var density = (m[2] * 1.0 + m[5] * 0.9 + m[0] * 0.22 + m[1] * 0.3 + m[3] * 0.35 + m[4] * 0.12) / tot
            if t.id == 1 { density *= 0.4 }
            if Double(pick) > Double(density) { continue }
            let pos = W.pos + d * (r0)
            if avoid.contains(where: { simd_distance($0, pos) < 0.035 }) { continue }
            // size: mostly small, occasionally big
            let size = t.minSize + (t.maxSize - t.minSize) * pow(sizeR, t.id == 0 ? 1.8 : 2.6)
            // orientation: lean partly with the slope, random yaw and a slight random tilt
            let up = simd_normalize(simd_mix(d, n, D3(repeating: 0.6)))
            let align = simd_quatd(from: D3(0, 1, 0), to: up)
            let tilt = simd_quatd(angle: (tx - 0.5) * 0.5, axis: D3(1, 0, 0)) * simd_quatd(angle: (tz - 0.5) * 0.5, axis: D3(0, 0, 1))
            let q = align * simd_quatd(angle: yaw, axis: D3(0, 1, 0)) * tilt
            // colour: the world's rock colour here, relative to the photo's average
            let rc = simd_mix(W.colorFn(d.x, d.y, d.z, e, max(slope, 0.5)), W.colorFn(d.x, d.y, d.z, e, slope), D3(repeating: 0.45))
            let ratio = simd_clamp(SIMD3<Float>(Float(rc.x), Float(rc.y), Float(rc.z)) / simd_max(mean, SIMD3(repeating: 0.02)), SIMD3(repeating: 0.2), SIMD3(repeating: 4))
            var tint = simd_mix(SIMD3<Float>(repeating: 1), ratio, SIMD3(repeating: min(1, W.tint * 1.4)))
            // the scan is a dark, damp rock: lift it to a typical dry-rock brightness
            let lum = simd_dot(mean * tint, SIMD3(0.3, 0.59, 0.11))
            if lum < 0.16 { tint *= 0.16 / max(lum, 0.01) }
            out.append(RockInstance(pos: pos, q: simd_quatf(ix: Float(q.imag.x), iy: Float(q.imag.y), iz: Float(q.imag.z), r: Float(q.real)),
                                    size: Float(size), kind: Int(kindR * Double(kinds)) % max(1, kinds), tint: tint))
        }
        return out
    }
}
