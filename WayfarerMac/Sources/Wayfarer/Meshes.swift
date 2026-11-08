import Foundation
import Metal
import simd

// MARK: - generic GPU mesh

final class GPUMesh {
    let vb: MTLBuffer
    let ib: MTLBuffer?
    let count: Int
    init(device: MTLDevice, verts: [Float], indices: [UInt32]? = nil) {
        vb = device.makeBuffer(bytes: verts, length: max(4, verts.count * 4), options: .storageModeShared)!
        if let idx = indices { ib = device.makeBuffer(bytes: idx, length: max(4, idx.count * 4), options: .storageModeShared); count = idx.count }
        else { ib = nil; count = verts.count }
    }
}

func uvSphere(device: MTLDevice, seg: Int = 96, rings: Int = 48) -> GPUMesh {
    var v: [Float] = [], idx: [UInt32] = []
    for r in 0...rings {
        let th = Double(r) / Double(rings) * .pi
        for s in 0...seg {
            let ph = Double(s) / Double(seg) * .pi * 2
            v += [Float(sin(th) * cos(ph)), Float(cos(th)), Float(sin(th) * sin(ph))]
        }
    }
    for r in 0..<rings { for s in 0..<seg {
        let a = UInt32(r * (seg + 1) + s), b = a + 1, c = a + UInt32(seg + 1), d = c + 1
        idx += [a, c, b, b, c, d]
    } }
    return GPUMesh(device: device, verts: v, indices: idx)
}

/// open cone along +z from z=0 (radius r) to z=1 (tip); pos3 normal3 uv2 — used for engine flames
/// an exhaust plume: a tube along +z from the nozzle (z = 0, radius 1) that swells slightly, then tapers to a soft
/// point at z = 1; pos3 normal3 uv2 (uv.y = how far along). Also used for the beams over scanned sites.
func plumeCone(device: MTLDevice, seg: Int = 24) -> GPUMesh {
    var v: [Float] = [], idx: [UInt32] = []
    let rings: [(z: Double, r: Double)] = [(0, 0.92), (0.04, 1.0), (0.12, 1.06), (0.25, 1.0), (0.45, 0.82), (0.65, 0.6), (0.82, 0.38), (1.0, 0.12)]
    for (ri, rg) in rings.enumerated() {
        let slope = ri + 1 < rings.count ? (rg.r - rings[ri + 1].r) / (rings[ri + 1].z - rg.z) : 0.5
        for s in 0...seg {
            let a = Double(s) / Double(seg) * .pi * 2
            let n = simd_normalize(D3(cos(a), sin(a), slope * 0.25))
            v += [Float(cos(a) * rg.r), Float(sin(a) * rg.r), Float(rg.z), Float(n.x), Float(n.y), Float(n.z), Float(s) / Float(seg), Float(rg.z)]
        }
    }
    for ri in 0..<(rings.count - 1) { for s in 0..<seg {
        let a = UInt32(ri * (seg + 1) + s), b = a + 1, c = a + UInt32(seg + 1), d = c + 1; idx += [a, c, b, b, c, d]
    } }
    return GPUMesh(device: device, verts: v, indices: idx)
}
/// a flat disc facing +z, radius 1, uv.x = distance from the centre: the glowing mouth of a nozzle
func nozzleDisc(device: MTLDevice, seg: Int = 32) -> GPUMesh {
    var v: [Float] = [], idx: [UInt32] = []
    for ring in 0...4 { let r = Double(ring) / 4; for s in 0...seg {
        let a = Double(s) / Double(seg) * .pi * 2
        v += [Float(cos(a) * r), Float(sin(a) * r), 0, 0, 0, 1, Float(r), 0]
    } }
    for ring in 0..<4 { for s in 0..<seg { let a = UInt32(ring * (seg + 1) + s), b = a + 1, c = a + UInt32(seg + 1), d = c + 1; idx += [a, c, b, b, c, d] } }
    return GPUMesh(device: device, verts: v, indices: idx)
}

// MARK: - ship mesh builder (pos3 normal3 uv2 material1, flat shaded)

enum Mat: Float { case paint = 0, metal = 1, dark = 2, glass = 3, vent = 4, disc = 5, suit = 6, orange = 7, cyan = 8, visor = 9, crystal = 10, screen = 11, lamp = 12, wall = 13, floor = 14, plant = 15, led = 16, skin = 17, shaft = 21 }

struct MeshBuilder {
    var v: [Float] = []
    var xform = simd_double4x4(1)

    mutating func tri(_ a: D3, _ b: D3, _ c: D3, _ ua: SIMD2<Double>, _ ub: SIMD2<Double>, _ uc: SIMD2<Double>, _ m: Mat) {
        let pa = (xform * SIMD4(a, 1)).xyz, pb = (xform * SIMD4(b, 1)).xyz, pc = (xform * SIMD4(c, 1)).xyz
        var n = simd_cross(pb - pa, pc - pa); let l = simd_length(n); if l < 1e-12 { return }; n /= l
        for (p, u) in [(pa, ua), (pb, ub), (pc, uc)] {
            v += [Float(p.x), Float(p.y), Float(p.z), Float(n.x), Float(n.y), Float(n.z), Float(u.x), Float(u.y), m.rawValue]
        }
    }
    mutating func quad(_ a: D3, _ b: D3, _ c: D3, _ d: D3, _ m: Mat, uv: [SIMD2<Double>]? = nil) {
        let u = uv ?? [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        tri(a, b, c, u[0], u[1], u[2], m); tri(a, c, d, u[0], u[2], u[3], m)
    }
    /// box centred at c with size s, optional Euler rotation (x, y, z order like three.js)
    mutating func box(_ s: D3, _ c: D3, _ m: Mat, rot: D3 = .zero) {
        let save = xform; xform = xform * translate(c) * eulerXYZ(rot)
        let h = s / 2
        let p = [D3(-h.x, -h.y, -h.z), D3(h.x, -h.y, -h.z), D3(h.x, h.y, -h.z), D3(-h.x, h.y, -h.z),
                 D3(-h.x, -h.y, h.z), D3(h.x, -h.y, h.z), D3(h.x, h.y, h.z), D3(-h.x, h.y, h.z)]
        quad(p[4], p[5], p[6], p[7], m); quad(p[1], p[0], p[3], p[2], m); quad(p[5], p[1], p[2], p[6], m)
        quad(p[0], p[4], p[7], p[3], m); quad(p[3], p[7], p[6], p[2], m); quad(p[0], p[1], p[5], p[4], m)
        xform = save
    }
    /// plane in the local XY plane facing +z (like THREE.PlaneGeometry), with uv 0..1
    mutating func plane(_ w: Double, _ h: Double, _ c: D3, _ m: Mat, rot: D3 = .zero) {
        let save = xform; xform = xform * translate(c) * eulerXYZ(rot)
        quad(D3(-w / 2, -h / 2, 0), D3(w / 2, -h / 2, 0), D3(w / 2, h / 2, 0), D3(-w / 2, h / 2, 0), m)
        xform = save
    }
    /// cylinder along local y (like THREE.CylinderGeometry), optionally open-ended
    mutating func cylinder(_ rTop: Double, _ rBot: Double, _ h: Double, _ c: D3, _ m: Mat, rot: D3 = .zero, seg: Int = 16, open: Bool = false, yOffset: Double = 0) {
        let save = xform; xform = xform * translate(c) * eulerXYZ(rot)
        for s in 0..<seg {
            let a0 = Double(s) / Double(seg) * .pi * 2, a1 = Double(s + 1) / Double(seg) * .pi * 2
            let t0 = D3(cos(a0) * rTop, h / 2 + yOffset, sin(a0) * rTop), t1 = D3(cos(a1) * rTop, h / 2 + yOffset, sin(a1) * rTop)
            let b0 = D3(cos(a0) * rBot, -h / 2 + yOffset, sin(a0) * rBot), b1 = D3(cos(a1) * rBot, -h / 2 + yOffset, sin(a1) * rBot)
            quad(b0, b1, t1, t0, m)
            if !open {
                tri(D3(0, h / 2 + yOffset, 0), t1, t0, .zero, .zero, .zero, m)
                tri(D3(0, -h / 2 + yOffset, 0), b0, b1, .zero, .zero, .zero, m)
            }
        }
        xform = save
    }
    mutating func disc(_ r: Double, _ c: D3, _ m: Mat, seg: Int = 18) {
        for s in 0..<seg {
            let a0 = Double(s) / Double(seg) * .pi * 2, a1 = Double(s + 1) / Double(seg) * .pi * 2
            tri(c, c + D3(cos(a0) * r, sin(a0) * r, 0), c + D3(cos(a1) * r, sin(a1) * r, 0), .zero, .zero, .zero, m)
        }
    }
    mutating func octahedron(_ r: Double, scale s: D3, _ c: D3, _ m: Mat) {
        let save = xform; xform = xform * translate(c) * scaleM(s)
        let px = D3(r, 0, 0), nx = D3(-r, 0, 0), py = D3(0, r, 0), ny = D3(0, -r, 0), pz = D3(0, 0, r), nz = D3(0, 0, -r)
        for (a, b) in [(px, pz), (pz, nx), (nx, nz), (nz, px)] {
            tri(py, b, a, .zero, .zero, .zero, m); tri(ny, a, b, .zero, .zero, .zero, m)
        }
        xform = save
    }
    /// three.js-style extrusion of a polygon given in (x, z) with a bevel; the slab is centred on y = cy
    mutating func extrude(_ pts: [SIMD2<Double>], depth: Double, bevel: Double, cy: Double, _ m: Mat) {
        let poly = ensureCCW(pts)
        let n = poly.count
        func ring(_ outset: Double, _ y: Double) -> [D3] {
            (0..<n).map { i in
                let p = poly[i], a = poly[(i + n - 1) % n], b = poly[(i + 1) % n]
                let e1 = simd_normalize(p - a), e2 = simd_normalize(b - p)
                let n1 = SIMD2(e1.y, -e1.x), n2 = SIMD2(e2.y, -e2.x)
                var nn = simd_normalize(n1 + n2); let k = simd_dot(nn, n1); nn /= max(k, 0.3)
                let q = p + nn * outset
                return D3(q.x, y, q.y)
            }
        }
        let hd = depth / 2
        let rings = [ring(0, cy - hd - bevel), ring(bevel, cy - hd), ring(bevel, cy + hd), ring(0, cy + hd + bevel)]
        for r in 0..<3 { for i in 0..<n {
            let j = (i + 1) % n
            let a = rings[r][i], b = rings[r][j], c = rings[r + 1][j], d = rings[r + 1][i]
            quad(a, b, c, d, m, uv: [SIMD2(a.x, a.z), SIMD2(b.x, b.z), SIMD2(c.x, c.z), SIMD2(d.x, d.z)])
        } }
        let tris = earClip(poly)
        for t in tris {
            let top = rings[3], bot = rings[0]
            tri(top[t.0], top[t.2], top[t.1], SIMD2(top[t.0].x, top[t.0].z), SIMD2(top[t.2].x, top[t.2].z), SIMD2(top[t.1].x, top[t.1].z), m)
            tri(bot[t.0], bot[t.1], bot[t.2], SIMD2(bot[t.0].x, bot[t.0].z), SIMD2(bot[t.1].x, bot[t.1].z), SIMD2(bot[t.2].x, bot[t.2].z), m)
        }
    }
}

extension SIMD4 where Scalar == Double { var xyz: D3 { D3(x, y, z) } }
func translate(_ t: D3) -> simd_double4x4 { var m = simd_double4x4(1); m.columns.3 = SIMD4(t, 1); return m }
func scaleM(_ s: D3) -> simd_double4x4 { simd_double4x4(diagonal: SIMD4(s, 1)) }
func eulerXYZ(_ r: D3) -> simd_double4x4 {
    let cx = cos(r.x), sx = sin(r.x), cy = cos(r.y), sy = sin(r.y), cz = cos(r.z), sz = sin(r.z)
    let rx = simd_double4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, cx, -sx, 0), SIMD4(0, sx, cx, 0), SIMD4(0, 0, 0, 1)])
    let ry = simd_double4x4(rows: [SIMD4(cy, 0, sy, 0), SIMD4(0, 1, 0, 0), SIMD4(-sy, 0, cy, 0), SIMD4(0, 0, 0, 1)])
    let rz = simd_double4x4(rows: [SIMD4(cz, -sz, 0, 0), SIMD4(sz, cz, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)])
    return rx * ry * rz
}
func mirrorOutline(_ half: [SIMD2<Double>]) -> [SIMD2<Double>] {
    var out = half
    for p in half.dropFirst().reversed() { let q = SIMD2(-p.x, p.y); if out.last != q { out.append(q) } }
    if out.count > 1 && out.first == out.last { out.removeLast() }
    return out
}
func ensureCCW(_ p: [SIMD2<Double>]) -> [SIMD2<Double>] {
    var a = 0.0; for i in 0..<p.count { let j = (i + 1) % p.count; a += p[i].x * p[j].y - p[j].x * p[i].y }
    return a < 0 ? p.reversed() : p
}
func earClip(_ poly: [SIMD2<Double>]) -> [(Int, Int, Int)] {
    var idx = Array(0..<poly.count), out: [(Int, Int, Int)] = []
    func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var guardN = 0
    while idx.count > 3 && guardN < 1000 {
        guardN += 1
        var clipped = false
        for k in 0..<idx.count {
            let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
            let a = poly[i0], b = poly[i1], c = poly[i2]
            if cross(a, b, c) <= 0 { continue }
            var inside = false
            for j in idx where j != i0 && j != i1 && j != i2 {
                let p = poly[j]
                if cross(a, b, p) > 0 && cross(b, c, p) > 0 && cross(c, a, p) > 0 { inside = true; break }
            }
            if inside { continue }
            out.append((i0, i1, i2)); idx.remove(at: k); clipped = true; break
        }
        if !clipped { break }
    }
    if idx.count == 3 { out.append((idx[0], idx[1], idx[2])) }
    return out
}

// MARK: - Kestrel (ported from the web build)

struct ShipModel {
    var name: String
    var role: String
    var paint: Int                      // 0 Kestrel red panels, 1 Condor graphite
    var speedK: Double                  // top-speed multiplier
    var pitch: Float                    // engine sound pitch
    var agility = 1.0                   // turn-rate multiplier
    var fuelEff = 1.0                   // fuel use multiplier (bigger tanks → smaller)
    var camScale = 1.0                  // chase/orbit camera distance multiplier (big ships: closer, so they fill the view)
    var exitSide = 0.75                 // where the explorer steps out, as a fraction of the ship's size
    var hullDetail: Float = 1           // hull texture tiling multiplier (big ships: finer panels, so they read as huge)
    var mass = 1.0                      // hover inertia: heavier ships speed up, stop and settle more slowly
    var chase: D3? = nil                // custom chase-camera offset in km (x right, y up, z back); nil: scaled default
    var hull: GPUMesh
    var leg: GPUMesh
    var plume: GPUMesh
    var eye = D3(0, 0.16, -0.2)         // pilot's eye (model units), for the cockpit view
    var cockpit: GPUMesh? = nil         // interior seen from the cockpit: canopy frame, sills, dashboard
    var nacelle: GPUMesh? = nil         // tilting engine pod, built around its pivot
    var pivots: [D3] = []               // nacelle pivots (model units); they tilt from cruise (0) to vertical (π/2)
    var length: Double
    var size: Double
    var gearBottom: Double              // model units, origin to pad soles
    var legs: [(pos: D3, stow: Double)]
    var engines: [(pos: D3, r: Double, pivot: Int)] // flame origins (model units); pivot ≥ 0: relative to that nacelle pivot
    var vtols: [(pos: D3, r: Double)]
    var navLights: [(pos: D3, color: SIMD3<Float>, size: Float)]
    var steadyLights: [(pos: D3, color: SIMD3<Float>, size: Float)]
    var landLights: [D3]
    var interior: GPUMesh? = nil        // walkable deck (big ships), drawn when you walk aboard
    var deck: Deck? = nil
    var canopyCut: (lo: D3, hi: D3)? = nil   // a model hull with an opaque canopy: cut open around the pilot in cockpit view
    var flame: (edge: SIMD3<Float>, core: SIMD3<Float>, hot: SIMD3<Float>, glow: D3)? = nil   // engine colours (default blue-white)
    var skin: BakedSkin? = nil          // baked textures for a hull modelled in Blender
    var liftCar: (car: GPUMesh, door: GPUMesh)? = nil   // the enclosed lift car and one of its sliding door panels
    var cargo: CargoBay? = nil          // a belly cargo bay with a lift and a rover (the Atlas)
}

func buildKestrel(device: MTLDevice) -> ShipModel {
    var b = MeshBuilder()
    let hull: [SIMD2<Double>] = mirrorOutline([SIMD2(0, -0.8), SIMD2(0.16, -0.42), SIMD2(0.34, -0.05), SIMD2(0.68, 0.3), SIMD2(0.64, 0.44), SIMD2(0.3, 0.38), SIMD2(0.18, 0.5)])
    b.extrude(hull, depth: 0.07, bevel: 0.035, cy: 0, .paint)
    b.extrude(mirrorOutline([SIMD2(0, -0.52), SIMD2(0.12, -0.2), SIMD2(0.22, 0.2), SIMD2(0.2, 0.47)]), depth: 0.05, bevel: 0.03, cy: 0.08, .metal)
    b.extrude(mirrorOutline([SIMD2(0, -0.6), SIMD2(0.14, -0.2), SIMD2(0.26, 0.25), SIMD2(0.22, 0.46)]), depth: 0.04, bevel: 0.025, cy: -0.075, .dark)
    b.octahedron(0.1, scale: D3(0.75, 0.38, 1.7), D3(0, 0.14, -0.24), .glass)
    for sx in [1.0, -1.0] {
        for (z, w) in [(0.06, 0.24), (0.2, 0.3)] { b.plane(w, 0.075, D3(sx * (0.3 + z * 0.6), 0.072, z), .vent, rot: D3(-.pi / 2, 0, -0.62 * sx)) }
        b.plane(0.14, 0.04, D3(sx * 0.235, 0, 0.43), .vent, rot: D3(0, sx * 0.2, 0))
    }
    b.plane(0.16, 0.12, D3(0, 0.137, 0.25), .vent, rot: D3(-.pi / 2, 0, 0))
    b.box(D3(0.5, 0.13, 0.1), D3(0, 0, 0.5), .dark)
    var engines: [(D3, Double)] = []
    for x in [-0.15, 0.0, 0.15] {
        let r = 0.046
        b.cylinder(r * 1.04, r * 1.2, r * 1.9, D3(x, 0, 0.6 - r * 0.4), .metal, rot: D3(.pi / 2, 0, 0), seg: 18, open: true)
        b.disc(r, D3(x, 0, 0.6 - r * 0.8), .disc)
        engines.append((D3(x, 0, 0.6), r))
    }
    var vtols: [(D3, Double)] = []
    for sx in [1.0, -1.0] {
        for p in [D3(sx * 0.2, -0.1, -0.15), D3(sx * 0.26, -0.1, 0.3)] {
            b.cylinder(0.035 * 1.1, 0.035 * 1.3, 0.035 * 0.8, p + D3(0, 0.01, 0), .dark, seg: 12, open: true)
            vtols.append((p, 0.035))
        }
    }
    // one landing leg (pivot at the origin, hanging down): strut, piston, pad
    var lb = MeshBuilder()
    let len = 0.17, legR = 0.016, padR = 0.05
    lb.cylinder(legR, legR * 1.15, len, D3(0, -len / 2, 0), .dark, seg: 8)
    lb.cylinder(legR * 0.55, legR * 0.55, len * 0.7, D3(legR * 1.6, -len * 0.35, 0), .metal, seg: 6)
    lb.cylinder(padR, padR * 1.15, 0.018, D3(0, -len - 0.004, 0), .dark, seg: 14)
    let originY = -0.09
    let legPts = [D3(0, originY, -0.42), D3(0.3, originY, 0.26), D3(-0.3, originY, 0.26)]
    let eye = D3(0, 0.17, -0.26)
    var kestrel = ShipModel(
        name: "Kestrel", role: "STRIKE FIGHTER", paint: 0, speedK: 1, pitch: 1, fuelEff: 0.32,
        hull: GPUMesh(device: device, verts: b.v), leg: GPUMesh(device: device, verts: lb.v), plume: plumeCone(device: device),
        eye: eye, cockpit: buildCockpit(device: device, style: .fighter, canopy: D3(0, 0.14, -0.24), half: D3(0.075, 0.038, 0.17), eye: eye, unitsPerMetre: 1.4 / 50),
        length: 1.4, size: 0.05, gearBottom: -originY + len + 0.013,
        legs: legPts.map { ($0, $0.z < 0 ? 1.45 : -1.45) },
        engines: engines.map { (pos: $0.0, r: $0.1, pivot: -1) }, vtols: vtols.map { (pos: $0.0, r: $0.1) },
        navLights: [(D3(-0.66, 0.02, 0.38), SIMD3(1, 0.23, 0.23), 0.1), (D3(0.66, 0.02, 0.38), SIMD3(0.23, 1, 0.48), 0.1)],
        steadyLights: [(D3(0.24, 0.07, -0.3), SIMD3(0.35, 0.66, 1), 0.06), (D3(-0.24, 0.07, -0.3), SIMD3(0.35, 0.66, 1), 0.06), (D3(0, 0.02, -0.82), SIMD3(1, 1, 1), 0.07)],
        landLights: legPts.map { D3($0.x * 0.8, originY - 0.01, $0.z * 0.8) })
    (kestrel.interior, kestrel.deck) = buildKestrelInterior(device: device, u: 1.4 / 50)
    if let a = loadShipAsset(device: device, name: "kestrel") { kestrel.hull = a.mesh; kestrel.skin = a.skin }   // the Blender model
    return kestrel
}

// MARK: - procedural textures

func makeTexture(device: MTLDevice, w: Int, h: Int, pixels: [UInt8], srgb: Bool) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: w, height: h, mipmapped: true)
    d.usage = .shaderRead
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: w * 4)
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
    bl.generateMipmaps(for: t); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return t
}

/// tiling 3-channel noise (smooth fbm, ridged fbm, fine fbm) used for close-up ground detail
func makeDetailTexture(device: MTLDevice) -> MTLTexture {
    let S = 256
    func lattice(_ n: Int, _ seed: UInt32) -> [Double] { let r = Mulberry(seed); return (0..<(n * n)).map { _ in r.next() } }
    func sample(_ g: [Double], _ n: Int, _ u: Double, _ v: Double) -> Double {
        let x = u * Double(n), y = v * Double(n), x0 = Int(floor(x)), y0 = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let i0 = ((x0 % n) + n) % n, j0 = ((y0 % n) + n) % n, i1 = (i0 + 1) % n, j1 = (j0 + 1) % n
        let a = g[j0 * n + i0], b = g[j0 * n + i1], c = g[j1 * n + i0], d = g[j1 * n + i1]
        let top = a + (b - a) * sx, bot = c + (d - c) * sx
        return top + (bot - top) * sy
    }
    func channel(_ seed: UInt32, _ start: Int, _ oct: Int, _ ridge: Bool) -> [Double] {
        let ls = (0..<oct).map { o in (lattice(start << o, seed + UInt32(o)), start << o, pow(0.55, Double(o))) }
        var out = [Double](repeating: 0, count: S * S); var mn = 1e9, mx = -1e9
        for j in 0..<S { for i in 0..<S {
            var s = 0.0
            for (g, n, a) in ls { var v = sample(g, n, Double(i) / Double(S), Double(j) / Double(S)); if ridge { v = 1 - abs(v * 2 - 1) }; s += v * a }
            out[j * S + i] = s; mn = min(mn, s); mx = max(mx, s)
        } }
        return out.map { ($0 - mn) / (mx - mn) }
    }
    let r = channel(101, 4, 6, false), g = channel(202, 4, 6, true), b = channel(303, 16, 4, false)
    var px = [UInt8](repeating: 255, count: S * S * 4)
    for k in 0..<(S * S) { px[k * 4] = UInt8(r[k] * 255); px[k * 4 + 1] = UInt8(g[k] * 255); px[k * 4 + 2] = UInt8(b[k] * 255) }
    return makeTexture(device: device, w: S, h: S, pixels: px, srgb: false)
}

/// simple RGBA canvas for painting hull panels and vent grilles
struct Canvas {
    let w: Int, h: Int
    var px: [UInt8]
    init(_ w: Int, _ h: Int, fill: SIMD3<UInt8>) { self.w = w; self.h = h; px = [UInt8](repeating: 255, count: w * h * 4); rect(0, 0, w, h, fill) }
    mutating func rect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: SIMD3<UInt8>, alpha: Double = 1) {
        let y0 = max(0, y), y1 = min(h, y + rh), x0 = max(0, x), x1 = min(w, x + rw)
        if y1 <= y0 || x1 <= x0 { return }
        for j in y0..<y1 { for i in x0..<x1 {
            let k = (j * w + i) * 4
            px[k] = UInt8(Double(px[k]) * (1 - alpha) + Double(c.x) * alpha)
            px[k + 1] = UInt8(Double(px[k + 1]) * (1 - alpha) + Double(c.y) * alpha)
            px[k + 2] = UInt8(Double(px[k + 2]) * (1 - alpha) + Double(c.z) * alpha)
        } }
    }
    mutating func strokeRect(_ x: Int, _ y: Int, _ rw: Int, _ rh: Int, _ c: SIMD3<UInt8>, alpha: Double) {
        rect(x, y, rw, 2, c, alpha: alpha); rect(x, y + rh - 2, rw, 2, c, alpha: alpha)
        rect(x, y, 2, rh, c, alpha: alpha); rect(x + rw - 2, y, 2, rh, c, alpha: alpha)
    }
}

func makePanelTexture(device: MTLDevice) -> MTLTexture {
    let rnd = Mulberry(99)
    var cv = Canvas(512, 512, fill: SIMD3(0x8a, 0x1a, 0x17))
    for _ in 0..<70 {
        let pw = Int(30 + rnd.next() * 140), ph = Int(20 + rnd.next() * 110), px = Int(rnd.next() * 512), py = Int(rnd.next() * 512), k = rnd.next()
        let c: SIMD3<UInt8> = k < 0.18 ? SIMD3(0x4b, 0x4f, 0x57) : k < 0.3 ? SIMD3(0x2a, 0x2c, 0x31) : SIMD3(UInt8(120 + rnd.next() * 30), UInt8(20 + rnd.next() * 12), UInt8(18 + rnd.next() * 10))
        // wrap panels across edges so the texture tiles seamlessly
        for ox in [0, -512] { for oy in [0, -512] {
            cv.rect(px + ox, py + oy, pw, ph, c)
            cv.strokeRect(px + ox, py + oy, pw, ph, SIMD3(20, 4, 4), alpha: 0.85)
        } }
    }
    for _ in 0..<300 { cv.rect(Int(rnd.next() * 512), Int(rnd.next() * 512), 2, 2, SIMD3(255, 255, 255), alpha: 0.08) }
    return makeTexture(device: device, w: 512, h: 512, pixels: cv.px, srgb: true)
}

func makeVentTexture(device: MTLDevice) -> MTLTexture {
    var cv = Canvas(256, 128, fill: SIMD3(0x12, 0x08, 0x06))
    for i in 0..<14 {
        let x = 10 + Int(Double(i) * 17.5)
        for j in 12..<116 {
            let t = abs(Double(j - 64) / 52.0)   // bright centre, orange ends
            let c = SIMD3<UInt8>(255, UInt8(0x7a + (0xd2 - 0x7a) * (1 - t)), UInt8(0x1a + (0x7a - 0x1a) * (1 - t)))
            cv.rect(x, j, 10, 1, c)
        }
    }
    return makeTexture(device: device, w: 256, h: 128, pixels: cv.px, srgb: true)
}
