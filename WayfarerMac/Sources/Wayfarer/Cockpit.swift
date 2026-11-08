import Foundation
import Metal
import simd

// Cockpit interiors. Built in metres around the pilot's eye, then converted to model units.
// The canopy glass is hidden from inside, so the frame, rails and screens are what you see.

enum CockpitStyle { case fighter, bubble }

// MARK: - display atlas: eight 256×256 green screens in a 1024×512 texture

let SCREEN_CELLS = (cols: 4, rows: 2)
enum ScreenPic: Int { case radar = 0, ship, bars, readout, target, shields, power, map }

private struct Raster {
    let w: Int, h: Int
    var px: [Float]                       // rgb, linear 0..1
    init(_ w: Int, _ h: Int) { self.w = w; self.h = h; px = [Float](repeating: 0, count: w * h * 3) }
    mutating func add(_ x: Int, _ y: Int, _ c: SIMD3<Float>) {
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let k = (y * w + x) * 3
        px[k] = min(1, px[k] + c.x); px[k + 1] = min(1, px[k + 1] + c.y); px[k + 2] = min(1, px[k + 2] + c.z)
    }
    mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ c: SIMD3<Float>) {
        for y in max(0, y0)..<min(h, y1) { for x in max(0, x0)..<min(w, x1) { let k = (y * w + x) * 3; px[k] = c.x; px[k + 1] = c.y; px[k + 2] = c.z } }
    }
    mutating func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD3<Float>, _ t: Double = 1.2) {
        let n = Int(simd_length(b - a) * 2) + 1
        for i in 0...n {
            let p = a + (b - a) * Double(i) / Double(n)
            let r = Int(ceil(t))
            for dy in -r...r { for dx in -r...r {
                let d = sqrt(Double(dx * dx + dy * dy)); if d > t { continue }
                add(Int(p.x) + dx, Int(p.y) + dy, c * Float(0.35 * (1 - d / (t + 0.5))))
            } }
        }
    }
    mutating func circle(_ c0: SIMD2<Double>, _ r: Double, _ c: SIMD3<Float>, from: Double = 0, to: Double = 2 * .pi) {
        let n = max(24, Int(r * 0.8))
        var prev = c0 + SIMD2(cos(from), sin(from)) * r
        for i in 1...n {
            let a = from + (to - from) * Double(i) / Double(n), p = c0 + SIMD2(cos(a), sin(a)) * r
            line(prev, p, c); prev = p
        }
    }
    mutating func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: SIMD3<Float>) {
        line(SIMD2(x0, y0), SIMD2(x1, y0), c); line(SIMD2(x1, y0), SIMD2(x1, y1), c)
        line(SIMD2(x1, y1), SIMD2(x0, y1), c); line(SIMD2(x0, y1), SIMD2(x0, y0), c)
    }
    /// little blocks that read as text from the pilot's seat
    mutating func text(_ x: Double, _ y: Double, _ chars: Int, _ c: SIMD3<Float>, _ rnd: Mulberry, size: Double = 6) {
        var cx = x
        for _ in 0..<chars {
            let cw = size * (0.55 + rnd.next() * 0.35)
            for j in 0..<Int(size * 1.3) { for i in 0..<Int(cw) where rnd.next() > 0.45 { add(Int(cx) + i, Int(y) + j, c * 0.55) } }
            cx += cw + 2
        }
    }
}

func makeScreenAtlas(device: MTLDevice) -> MTLTexture {
    let S = 256
    var r = Raster(S * SCREEN_CELLS.cols, S * SCREEN_CELLS.rows)
    let g = SIMD3<Float>(0.55, 1.0, 0.42), dim = SIMD3<Float>(0.2, 0.42, 0.16), bg = SIMD3<Float>(0.012, 0.035, 0.015)
    let rnd = Mulberry(77)
    for cell in 0..<(SCREEN_CELLS.cols * SCREEN_CELLS.rows) {
        let ox = Double((cell % SCREEN_CELLS.cols) * S), oy = Double((cell / SCREEN_CELLS.cols) * S)
        let ix = Int(ox), iy = Int(oy)
        r.fill(ix, iy, ix + S, iy + S, bg)
        // scan lines and a frame
        for y in stride(from: iy, to: iy + S, by: 3) { for x in ix..<(ix + S) { r.add(x, y, bg * 0.6) } }
        r.box(ox + 6, oy + 6, ox + 250, oy + 250, dim)
        r.text(ox + 12, oy + 12, 5, g, rnd, size: 5)
        let c = SIMD2(ox + 128, oy + 136)
        switch ScreenPic(rawValue: cell)! {
        case .radar:
            for k in 1...4 { r.circle(c, Double(k) * 26, k == 4 ? g : dim) }
            r.line(c - SIMD2(104, 0), c + SIMD2(104, 0), dim); r.line(c - SIMD2(0, 104), c + SIMD2(0, 104), dim)
            for k in 0..<18 { let a = -2.2 + Double(k) * 0.02; r.line(c, c + SIMD2(cos(a), sin(a)) * 104, g * 0.25) }   // sweep
            for _ in 0..<5 { let a = rnd.next() * 6.28, d = 20 + rnd.next() * 80; r.circle(c + SIMD2(cos(a), sin(a)) * d, 2.5, g) }
        case .ship:   // top-down wireframe of the ship
            let pts: [SIMD2<Double>] = [SIMD2(0, -80), SIMD2(18, -30), SIMD2(70, 30), SIMD2(66, 48), SIMD2(22, 42), SIMD2(14, 60), SIMD2(-14, 60), SIMD2(-22, 42), SIMD2(-66, 48), SIMD2(-70, 30), SIMD2(-18, -30)]
            for i in 0..<pts.count { r.line(c + pts[i], c + pts[(i + 1) % pts.count], g, 1.6) }
            r.circle(c, 95, dim, from: 0.3, to: 2.8); r.circle(c, 95, dim, from: 3.4, to: 5.9)
            for (i, p) in [SIMD2(-40.0, 20.0), SIMD2(40, 20), SIMD2(0, -40)].enumerated() { r.box(c.x + p.x - 8, c.y + p.y - 6, c.x + p.x + 8, c.y + p.y + 6, i == 2 ? g : dim) }
        case .bars:
            for k in 0..<6 {
                let x = ox + 26 + Double(k) * 36, hgt = 40 + rnd.next() * 140
                r.box(x, oy + 230 - 170, x + 22, oy + 230, dim)
                for y in stride(from: oy + 230 - hgt, to: oy + 228, by: 5) { r.line(SIMD2(x + 3, y), SIMD2(x + 19, y), g) }
            }
        case .readout:
            for k in 0..<9 {
                let y = oy + 40 + Double(k) * 21
                r.text(ox + 16, y, 4 + Int(rnd.next() * 5), g, rnd)
                let len = 40 + rnd.next() * 90
                r.line(SIMD2(ox + 140, y + 4), SIMD2(ox + 140 + len, y + 4), k % 3 == 0 ? g : dim, 2)
            }
        case .target:
            r.box(ox + 30, oy + 50, ox + 226, oy + 226, dim)
            r.line(SIMD2(ox + 30, oy + 50), SIMD2(ox + 226, oy + 226), g); r.line(SIMD2(ox + 226, oy + 50), SIMD2(ox + 30, oy + 226), g)
            r.text(ox + 92, oy + 128, 6, g, rnd, size: 8)
        case .shields:
            r.circle(c, 70, g, from: -2.6, to: -0.55); r.circle(c, 70, g, from: 0.55, to: 2.6)
            r.circle(c, 82, dim, from: -2.6, to: -0.55); r.circle(c, 82, dim, from: 0.55, to: 2.6)
            r.circle(c, 30, g); r.line(c - SIMD2(0, 30), c - SIMD2(0, 60), g); r.line(c + SIMD2(0, 30), c + SIMD2(0, 60), g)
            r.text(ox + 100, oy + 222, 4, g, rnd)
        case .power:
            for k in 0..<4 {
                let y = oy + 50 + Double(k) * 46
                r.text(ox + 16, y, 3, g, rnd)
                r.box(ox + 70, y - 2, ox + 236, y + 16, dim)
                let f = 0.3 + rnd.next() * 0.65
                r.fill(Int(ox + 73), Int(y + 1), Int(ox + 73 + 160 * f), Int(y + 13), g * 0.55)
            }
        case .map:
            for k in 0...8 { let t = Double(k) * 26; r.line(SIMD2(ox + 20 + t, oy + 30), SIMD2(ox + 20 + t, oy + 238), dim * 0.7); r.line(SIMD2(ox + 20, oy + 30 + t), SIMD2(ox + 228, oy + 30 + t), dim * 0.7) }
            var p = SIMD2(ox + 40, oy + 210)
            for _ in 0..<7 { let q = p + SIMD2(15 + rnd.next() * 20, -(10 + rnd.next() * 30)); r.line(p, q, g, 1.8); p = q }
            r.circle(p, 7, g)
        }
    }
    var px = [UInt8](repeating: 255, count: r.w * r.h * 4)
    for i in 0..<(r.w * r.h) {
        // linear → sRGB
        for ch in 0..<3 { let v = r.px[i * 3 + ch]; px[i * 4 + ch] = UInt8(min(255, pow(Double(v), 1 / 2.2) * 255)) }
    }
    return makeTexture(device: device, w: r.w, h: r.h, pixels: px, srgb: true)
}

// MARK: - cockpit geometry

func buildCockpit(device: MTLDevice, style: CockpitStyle, canopy c: D3, half h: D3, eye e: D3, unitsPerMetre u: Double) -> GPUMesh {
    var b = MeshBuilder()
    func m(_ x: Double, _ y: Double, _ z: Double) -> D3 { D3(x, y, z) * u }          // metres → model units
    func beam(_ p: D3, _ q: D3, _ w: Double, _ t: Double, _ mat: Mat, roll: Double = 0) {   // w, t in metres
        let d = q - p, len = simd_length(d)
        let save = b.xform
        b.xform = b.xform * translate((p + q) / 2) * simd_double4x4(simd_quatd(from: D3(0, 0, 1), to: d / len)) * eulerXYZ(D3(0, 0, roll))
        b.box(D3(w * u, t * u, len), .zero, mat)
        b.xform = save
    }
    /// a screen showing one cell of the display atlas, facing the eye
    func screen(_ ctr: D3, _ w: Double, _ hh: Double, _ pic: ScreenPic, bezel: Bool = true) {
        let toEye = simd_normalize(e - ctr)
        let rot = simd_double4x4(simd_quatd(from: D3(0, 0, 1), to: toEye))
        let save = b.xform
        b.xform = b.xform * translate(ctr) * rot
        let cw = 1.0 / Double(SCREEN_CELLS.cols), ch = 1.0 / Double(SCREEN_CELLS.rows)
        let u0 = Double(pic.rawValue % SCREEN_CELLS.cols) * cw, v0 = Double(pic.rawValue / SCREEN_CELLS.cols) * ch
        let hw = w * u / 2, hh2 = hh * u / 2
        b.quad(D3(-hw, -hh2, 0), D3(hw, -hh2, 0), D3(hw, hh2, 0), D3(-hw, hh2, 0), .screen,
               uv: [SIMD2(u0, v0 + ch), SIMD2(u0 + cw, v0 + ch), SIMD2(u0 + cw, v0), SIMD2(u0, v0)])
        if bezel { b.box(D3(w * u * 1.12, hh * u * 1.14, 0.05 * u), D3(0, 0, -0.03 * u), .dark) }
        b.xform = save
    }
    func onCanopy(_ fx: Double, _ fy: Double, _ fz: Double) -> D3 {      // a point on the octahedron surface
        let s = abs(fx) + abs(fy) + abs(fz)
        return c + D3(fx * h.x, fy * h.y, fz * h.z) / max(s, 1e-6)
    }
    let F = c + D3(0, 0, -h.z), L = c + D3(-h.x, 0, 0), R = c + D3(h.x, 0, 0)

    switch style {
    case .fighter:
        // heavy canopy rails in the hull colour, sweeping down to the nose, with lamps along them
        for s in [-1.0, 1.0] {
            let top = onCanopy(s * 0.55, 0.45, 0.0), front = onCanopy(s * 0.14, 0.12, -0.74)
            let back = onCanopy(s * 0.42, 0.38, 0.2)
            beam(back, top, 0.34, 0.2, .paint); beam(top, front, 0.34, 0.2, .paint)
            beam(top + m(s * 0.12, -0.12, 0), front + m(s * 0.05, -0.08, 0), 0.1, 0.06, .dark)
            for f in [0.2, 0.5] {
                let p = top + (front - top) * f - m(s * 0.12, 0.13, 0)
                b.box(m(0.12, 0.03, 0.18), p, .lamp)
            }
            beam(F, s < 0 ? L : R, 0.22, 0.14, .paint)                          // sill
        }
        // instrument panel: centre radar block and angled displays, two rows
        let base = e + m(0, -0.62, -0.85)
        b.box(m(1.9, 0.18, 0.5), base + m(0, -0.08, 0.05), .dark)
        b.box(m(0.5, 0.55, 0.3), e + m(0, -0.6, -1.0), .dark)
        screen(e + m(0, -0.42, -0.86), 0.34, 0.32, .radar)
        screen(e + m(-0.42, -0.48, -0.78), 0.34, 0.27, .ship)
        screen(e + m(0.42, -0.48, -0.78), 0.34, 0.27, .bars)
        screen(e + m(-0.8, -0.56, -0.6), 0.32, 0.26, .readout)
        screen(e + m(0.8, -0.56, -0.6), 0.32, 0.26, .power)
        screen(e + m(-0.3, -0.33, -1.05), 0.3, 0.2, .shields)
        screen(e + m(0.3, -0.33, -1.05), 0.3, 0.2, .target)
        b.box(m(1.2, 0.05, 0.2), e + m(0, -0.21, -1.12), .metal)                // glare shield
        // centre console, stick and side panels
        b.box(m(0.36, 0.5, 0.6), e + m(0, -1.0, -0.35), .dark)
        b.cylinder(0.025 * u, 0.03 * u, 0.32 * u, e + m(0, -0.72, -0.3), .metal, rot: D3(0.3, 0, 0), seg: 8)
        b.box(m(0.06, 0.05, 0.08), e + m(0, -0.57, -0.36), .orange)
        for s in [-1.0, 1.0] { b.box(m(0.3, 0.25, 0.9), e + m(s * 0.55, -0.7, -0.1), .dark); b.box(m(0.2, 0.02, 0.3), e + m(s * 0.55, -0.57, -0.1), .cyan) }

    case .bubble:
        // ribs: diamond hoops across the canopy, a keel along the top, and thick sills
        for fz in [-0.3, 0.05, 0.4] {
            let f = 1 - abs(fz)
            let l = c + D3(-h.x * f, 0, fz * h.z), r = c + D3(h.x * f, 0, fz * h.z), t = c + D3(0, h.y * f, fz * h.z)
            beam(l, t, 0.11, 0.09, .dark); beam(t, r, 0.11, 0.09, .dark)
        }
        beam(F, L, 0.26, 0.16, .metal); beam(F, R, 0.26, 0.16, .metal)
        // overhead console hanging in front of the pilot, three screens
        let oc = e + m(0, 0.36, -0.95)
        b.box(m(1.25, 0.42, 0.14), oc + m(0, 0, -0.08), .dark)
        screen(oc + m(-0.4, 0, 0), 0.36, 0.32, .ship)
        screen(oc + m(0, 0, 0.02), 0.36, 0.34, .radar)
        screen(oc + m(0.4, 0, 0), 0.36, 0.32, .shields)
        b.box(m(0.08, 0.02, 0.05), oc + m(-0.1, 0.19, 0.05), .lamp); b.box(m(0.08, 0.02, 0.05), oc + m(0.1, 0.19, 0.05), .orange)
        for s in [-1.0, 1.0] {   // hangers up to the keel
            beam(oc + m(s * 0.5, 0.2, -0.05), onCanopy(s * 0.25, 0.75, -0.22), 0.08, 0.08, .dark)
        }
        // low panel and side consoles
        b.box(m(1.4, 0.2, 0.4), e + m(0, -0.72, -0.7), .dark)
        screen(e + m(-0.45, -0.6, -0.7), 0.3, 0.22, .power)
        screen(e + m(0.45, -0.6, -0.7), 0.3, 0.22, .map)
        screen(e + m(0, -0.58, -0.78), 0.26, 0.2, .readout)
        for s in [-1.0, 1.0] { b.box(m(0.3, 0.25, 0.9), e + m(s * 0.6, -0.72, -0.05), .dark) }
    }
    return GPUMesh(device: device, verts: b.v)
}
