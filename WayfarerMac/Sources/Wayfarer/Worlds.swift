import Foundation
import simd

/// Physical atmosphere description (units: km, coefficients per km).
struct Atmosphere {
    var top: Double            // height of the atmosphere shell above sea level
    var rayleigh: SIMD3<Float> // Rayleigh scattering coefficient at sea level
    var rayleighH: Float       // Rayleigh scale height
    var mie: Float             // Mie scattering coefficient at sea level
    var mieH: Float
    var mieG: Float            // Mie anisotropy
    var mieTint: SIMD3<Float>  // dust colour of the Mie scattering
}

struct CloudLayer { var color: SIMD3<Float>; var alt: Double; var cover: Float }

struct Crater { var x, y, z, r, depth: Double }

final class World: @unchecked Sendable {
    let name: String
    let R: Double
    let pos: D3
    let sea: Bool
    let baseOct: Int
    let maxOct: Int
    let atmo: Atmosphere
    let clouds: CloudLayer?
    let bio: SIMD3<Float>?
    let gravity: Double
    var craters: [Crater] = []
    var heightFn: (Double, Double, Double, Int, [Crater]?) -> Double = { _, _, _, _, _ in 0 }
    var colorFn: (Double, Double, Double, Double, Double) -> D3 = { _, _, _, _, _ in D3(0.5, 0.5, 0.5) }
    /// how much of each ground texture layer covers a point (grass, forest, rock, sand, snow, red rock); zero = water
    var materialFn: (Double, Double, Double, Double, Double) -> SIMD8<Float> = { _, _, _, _, _ in SIMD8(0, 0, 1, 0, 0, 0, 0, 0) }
    var tint: Float = 0.5   // how strongly the textures take on this world's palette
    var maxDepth = 0
    var roots: [Node] = []

    init(name: String, R: Double, pos: D3, sea: Bool, baseOct: Int, maxOct: Int, atmo: Atmosphere, clouds: CloudLayer?, bio: SIMD3<Float>?, gravity: Double) {
        self.name = name; self.R = R; self.pos = pos; self.sea = sea; self.baseOct = baseOct; self.maxOct = maxOct
        self.atmo = atmo; self.clouds = clouds; self.bio = bio; self.gravity = gravity
        maxDepth = Int(ceil(log2(R * 1.57 / 0.03)))
    }

    @inline(__always) func height(_ x: Double, _ y: Double, _ z: Double, _ oct: Int, _ ctx: [Crater]? = nil) -> Double { heightFn(x, y, z, oct, ctx) }

    /// radius of the visible surface (sea level clamps oceans flat)
    func groundRadius(_ dir: D3) -> Double {
        let e = height(dir.x, dir.y, dir.z, 16, nil)
        return R + (sea ? max(e, 0) : e)
    }

    func craterSubset(center: D3, size: Double) -> [Crater]? {
        if craters.isEmpty { return nil }
        let lim = size * 0.8
        return craters.filter { k in
            let dx = k.x - center.x, dy = k.y - center.y, dz = k.z - center.z, m = lim + k.r * 1.6
            return dx * dx + dy * dy + dz * dz < m * m
        }
    }
}

// MARK: - helpers shared by the colour functions

@inline(__always) private func mixc(_ a: D3, _ b: D3, _ t: Double) -> D3 { a + (b - a) * t }

func makeCraters(seed: UInt32, count: Int, R: Double) -> [Crater] {
    let rnd = Mulberry(seed)
    var out: [Crater] = []
    for _ in 0..<count {
        let z = rnd.next() * 2 - 1, a = rnd.next() * .pi * 2, s = sqrt(1 - z * z)
        let r = min(0.22, 0.006 / pow(rnd.next() * 0.97 + 0.03, 0.75))
        out.append(Crater(x: cos(a) * s, y: z, z: sin(a) * s, r: r, depth: r * R * (0.08 + rnd.next() * 0.06)))
    }
    return out
}

@inline(__always) func craterH(_ x: Double, _ y: Double, _ z: Double, _ list: [Crater]) -> Double {
    var h = 0.0
    for c in list {
        let dx = x - c.x, dy = y - c.y, dz = z - c.z, d2 = dx * dx + dy * dy + dz * dz, lim = c.r * 1.6
        if d2 > lim * lim { continue }
        let d = sqrt(d2) / c.r
        let q = (d - 1) / 0.22
        h += ((d < 1 ? d * d - 1 : 0) + exp(-(q * q)) * 0.3) * c.depth
    }
    return h
}

// MARK: - the three worlds (same formulas and seeds as the web build)

func makeWorlds() -> [World] {
    return [earth(), ruber(), verdance()]
}

private func earth() -> World {
    let nA = Simplex(11), nB = Simplex(12), nC = Simplex(13), nD = Simplex(14), nE = Simplex(15)
    let deep = linearColor(0x04163a), shallow = linearColor(0x0f4f86), sand = linearColor(0xc2ae82), grass = linearColor(0x56703a),
        forest = linearColor(0x2a4426), dry = linearColor(0x9a845a), rock = linearColor(0x6b6358), dark = linearColor(0x3c3833), snow = linearColor(0xeef2f7)
    let w = World(name: "Earth", R: 1000, pos: D3(0, 0, 0), sea: true, baseOct: 5, maxOct: 18,
                  atmo: Atmosphere(top: 110, rayleigh: SIMD3(5.8e-3, 13.5e-3, 33.1e-3) * 1.5, rayleighH: 11, mie: 4.0e-3, mieH: 1.4, mieG: 0.76, mieTint: SIMD3(1, 1, 1)),
                  clouds: CloudLayer(color: SIMD3(1, 1, 1), alt: 6, cover: 0.5), bio: nil, gravity: 1)
    w.heightFn = { x, y, z, oct, _ in
        let c = fbm(nA, x, y, z, 1.25, min(4 + oct / 2, 11)) - 0.04
        if c < 0 { return c * 40 }
        let land = ss(0, 0.3, c)
        let r = ridged(nB, x, y, z, 3.1, oct)
        let hills = fbm(nC, x, y, z, 22, max(1, oct - 3))
        return c * 8 + land * r * r * 11 + hills * 1.1 * land + fbm(nD, x, y, z, 260, max(1, oct - 6)) * 0.22 * land
    }
    w.colorFn = { x, y, z, e, slope in
        let lat = abs(y), v = nD(x * 30, y * 30, z * 30) * 0.75 + nD(x * 160, y * 160, z * 160) * 0.25
        var o: D3
        if e <= 0 {
            return lat > 0.93 + v * 0.02 ? snow : mixc(shallow, deep, ss(0, -14, e))
        }
        if lat > 0.9 + v * 0.03 || e > 12.5 - lat * 10 + v * 1.5 { o = snow }
        else if e < 0.22 && slope < 0.12 { o = sand }
        else if slope > 0.24 { o = mixc(rock, dark, ss(-0.4, 0.6, v)) }
        else {
            o = mixc(forest, grass, ss(-0.4, 0.5, v + e * 0.04))
            let dr = ss(0.05, 0.45, nE(x * 2.3, y * 2.3, z * 2.3) * 0.6 + 0.3 - abs(lat - 0.32) * 1.4)
            o = mixc(o, dry, dr)
            o = mixc(o, rock, ss(6.5, 10.5, e))
        }
        let g = 1 + nE(x * 420, y * 420, z * 420) * 0.12 + nC(x * 3100, y * 3100, z * 3100) * 0.08
        return o * g
    }
    w.materialFn = { x, y, z, e, slope in
        if e <= 0 { return .zero }
        let lat = abs(y), v = nD(x * 30, y * 30, z * 30) * 0.75 + nD(x * 160, y * 160, z * 160) * 0.25
        let snow = max(ss(0, 0.03, lat - 0.9 - v * 0.03), ss(-0.3, 0.6, e - (12.5 - lat * 10 + v * 1.5)))
        let rock = min(1, ss(0.17, 0.3, slope) + ss(6.5, 10.5, e))
        let dry = ss(0.05, 0.45, nE(x * 2.3, y * 2.3, z * 2.3) * 0.6 + 0.3 - abs(lat - 0.32) * 1.4)
        let beach = ss(0.3, 0.12, e) * ss(0.16, 0.08, slope)
        let forest = 1 - ss(-0.4, 0.5, v + e * 0.04)
        var g = (1 - forest) * (1 - dry * 0.6), f = forest * (1 - dry * 0.6), sd = dry * 0.6
        let veg = (1 - beach) * (1 - rock) * (1 - snow)
        g *= veg; f *= veg; sd = sd * veg + beach * (1 - snow)
        let r = rock * (1 - snow)
        return SIMD8(Float(g), Float(f), Float(r), Float(sd), Float(snow), 0, 0, 0)
    }
    w.tint = 0.45
    return w
}

private func ruber() -> World {
    let nA = Simplex(31), nB = Simplex(32), nC = Simplex(33)
    let low = linearColor(0x6e2e18), mid = linearColor(0xb0532a), high = linearColor(0xd8925a), dust = linearColor(0xe0a674),
        dark = linearColor(0x3d1f15), ice = linearColor(0xf4ece6)
    let w = World(name: "Ruber", R: 530, pos: D3(-600000, 60000, 360000), sea: false, baseOct: 5, maxOct: 17,
                  atmo: Atmosphere(top: 70, rayleigh: SIMD3(19.9e-3, 13.6e-3, 5.8e-3) * 0.85, rayleighH: 12, mie: 12e-3, mieH: 2.4, mieG: 0.65, mieTint: SIMD3(1.0, 0.62, 0.38)),
                  clouds: CloudLayer(color: SIMD3(0.88, 0.62, 0.44), alt: 6, cover: 0.6), bio: nil, gravity: 0.38)
    w.craters = makeCraters(seed: 34, count: 160, R: 530)
    let all = w.craters
    w.heightFn = { x, y, z, oct, ctx in
        let base = fbm(nA, x, y, z, 1.6, oct) * 7
        let region = ss(-0.05, 0.35, nA(x * 1.1 + 7, y * 1.1, z * 1.1))
        let canyon = pow(1 - abs(nB(x * 2.4, y * 2.4, z * 2.4)), 9) * -13 * region
        return base + canyon + ridged(nC, x, y, z, 6, oct) * 6 + craterH(x, y, z, ctx ?? all)
    }
    w.colorFn = { x, y, z, e, slope in
        let lat = abs(y), v = fbm(nC, x, y, z, 4, 4)
        if lat > 0.88 + v * 0.04 { return ice }
        var o = mixc(low, mid, ss(-6, 2, e)); o = mixc(o, high, ss(3, 9, e))
        o = mixc(o, dust, ss(-0.1, 0.5, v) * 0.45)
        let sb = sin(e * 2.6 + nA(x * 4, y * 4, z * 4) * 1.5)
        o = mixc(o, sb > 0 ? high : dark, abs(sb) * 0.45 * ss(0.06, 0.22, slope))
        o = mixc(o, dark, ss(0.25, 0.45, slope) * 0.5)
        return o
    }
    w.materialFn = { x, y, z, e, slope in
        let lat = abs(y), v = fbm(nC, x, y, z, 4, 4)
        let ice = ss(0, 0.04, lat - 0.88 - v * 0.04)
        let cliff = ss(0.08, 0.3, slope)
        let dust = ss(-0.1, 0.5, v) * (1 - cliff)
        let red = (1 - dust) * (1 - ice)
        return SIMD8(0, 0, Float(cliff * 0.3 * (1 - ice)), Float(dust * (1 - ice)), Float(ice), Float(red), 0, 0)
    }
    w.tint = 0.75
    return w
}

private func verdance() -> World {
    let nA = Simplex(41), nB = Simplex(42), nC = Simplex(43), nD = Simplex(44)
    let deep = linearColor(0x170a3c), shallow = linearColor(0x4a2a8c), sand = linearColor(0xe6c8e4), moss = linearColor(0x1e9a86),
        bloom = linearColor(0x3fd6a2), violet = linearColor(0x6b3fa0), rock = linearColor(0x3a3450), snow = linearColor(0xe6f6ff)
    let w = World(name: "Verdance", R: 850, pos: D3(560000, -80000, 480000), sea: true, baseOct: 5, maxOct: 18,
                  atmo: Atmosphere(top: 100, rayleigh: SIMD3(6.0e-3, 26.0e-3, 22.0e-3) * 1.5, rayleighH: 11, mie: 5e-3, mieH: 1.6, mieG: 0.72, mieTint: SIMD3(0.9, 1.0, 0.95)),
                  clouds: CloudLayer(color: SIMD3(1.0, 0.86, 0.94), alt: 6, cover: 0.55), bio: SIMD3(0.1, 1.0, 0.82), gravity: 0.9)
    w.heightFn = { x, y, z, oct, _ in
        let c = fbm(nA, x, y, z, 1.6, min(4 + oct / 2, 11)) - 0.02
        if c < 0 { return c * 35 }
        let land = ss(0, 0.25, c), r = ridged(nB, x, y, z, 4.2, oct)
        return c * 8 + land * pow(r, 3) * 24 + fbm(nC, x, y, z, 26, max(1, oct - 3)) * 0.6 * land
    }
    w.colorFn = { x, y, z, e, slope in
        let v = fbm(nD, x, y, z, 6, 4)
        if e <= 0 { return mixc(shallow, deep, ss(0, -12, e)) }
        if e > 15 + v * 2 { return snow }
        if e < 0.25 && slope < 0.12 { return sand }
        if slope > 0.26 { return rock }
        var o = mixc(moss, bloom, ss(-0.4, 0.6, v))
        o = mixc(o, violet, ss(0.15, 0.55, fbm(nA, x, y, z, 2.5, 3)) * 0.8)
        o = mixc(o, rock, ss(9, 14, e))
        return o
    }
    w.materialFn = { x, y, z, e, slope in
        if e <= 0 { return .zero }
        let v = fbm(nD, x, y, z, 6, 4)
        let snow = ss(-0.5, 0.5, e - 15 - v * 2)
        let beach = ss(0.32, 0.15, e) * ss(0.16, 0.08, slope)
        let rock = min(1, ss(0.2, 0.32, slope) + ss(9, 14, e))
        let moss = (1 - snow) * (1 - beach) * (1 - rock)
        return SIMD8(Float(moss * 0.6), Float(moss * 0.4), Float(rock * (1 - snow)), Float(beach * (1 - snow)), Float(snow), 0, 0, 0)
    }
    w.tint = 1.0
    return w
}
