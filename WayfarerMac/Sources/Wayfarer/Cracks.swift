import Foundation
import simd

// Ground cracks left by a superhero landing: a dark crater with jagged fissures (and side branches) radiating out,
// glowing hot orange for a moment, then cooling to dark and fading away. Built once on the CPU at the moment of impact
// as triangles lying on the terrain, drawn by crackV/crackF (premultiplied: dark fissures plus an additive glow).

struct GroundCrack {
    let id: Int
    let pos: D3                 // impact point (km, world space; worlds don't move)
    let k: Double               // 0 a light landing … 1 slammed in from full speed
    var t = 0.0                 // seconds since impact
    let verts: [Float]          // 5 floats per vertex: offset from pos (km), along (0 at the impact … 1 at a tip), across (0 · 0.5 centre · 1)
    static let life = 22.0
}

extension Game {
    /// leave cracks where the robot slammed into the ground (not on water)
    func crackGround(_ P: World, at pos: D3, hard k: Double) {
        let u = simd_normalize(pos - P.pos)
        if waterDepth(P, u) > 0 { return }
        crackSerial += 1
        cracks.append(GroundCrack(id: crackSerial, pos: pos, k: k, verts: buildCracks(P, pos, k, seed: UInt64(crackSerial) &* 2654435761)))
        if cracks.count > 4 { cracks.removeFirst() }
    }

    func ageCracks(_ dt: Double) {
        for i in cracks.indices { cracks[i].t += dt }
        cracks.removeAll { $0.t > GroundCrack.life }
    }

    private func buildCracks(_ P: World, _ pos: D3, _ k: Double, seed: UInt64) -> [Float] {
        var s = seed | 1
        func rnd() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000 }
        func rr(_ a: Double, _ b: Double) -> Double { a + (b - a) * rnd() }
        let u = simd_normalize(pos - P.pos)
        let e1 = simd_normalize(simd_cross(u, abs(u.y) < 0.9 ? D3(0, 1, 0) : D3(1, 0, 0))), e2 = simd_cross(u, e1)
        // a point in the ground plane (metres from the impact) → km offset from pos, sitting just on the terrain
        func ground(_ q: SIMD2<Double>) -> D3 {
            let d = simd_normalize(pos + (e1 * q.x + e2 * q.y) * 0.001 - P.pos)
            return P.pos + d * (surfaceR(P, d) + 0.00004) - pos
        }
        var v: [Float] = []
        func put(_ q: SIMD2<Double>, _ along: Double, _ across: Double) {
            let g = ground(q); v += [Float(g.x), Float(g.y), Float(g.z), Float(along), Float(across)]
        }
        // the crater: a dark, irregular disc
        let R0 = 0.6 + 1.1 * k
        let segs = 22
        var rim: [SIMD2<Double>] = []
        for i in 0..<segs { let a = Double(i) / Double(segs) * .pi * 2; rim.append(SIMD2(cos(a), sin(a)) * R0 * rr(0.75, 1.15)) }
        for i in 0..<segs {
            put(.zero, 0.85, 0.5); put(rim[i], 0.95, 0); put(rim[(i + 1) % segs], 0.95, 0)   // scorched, barely glowing
        }
        // a fissure: a jagged polyline that narrows to a point, drawn as a strip with a dark centre line
        func fissure(from start: SIMD2<Double>, angle a0: Double, length L: Double, width w0: Double, along0: Double, depth: Int) {
            let n = 11
            var pts: [SIMD2<Double>] = [start], ang = a0
            for _ in 0..<n {
                ang += rr(-0.5, 0.5)
                pts.append(pts.last! + SIMD2(cos(ang), sin(ang)) * (L / Double(n)) * rr(0.7, 1.3))
            }
            for i in 0..<n {
                let p0 = pts[i], p1 = pts[i + 1]
                let d = simd_normalize(p1 - p0), nrm = SIMD2(-d.y, d.x)
                let t0 = Double(i) / Double(n), t1 = Double(i + 1) / Double(n)
                let w0i = w0 * (1 - t0 * 0.92), w1i = w0 * (1 - t1 * 0.92)
                let al0 = along0 + (1 - along0) * t0, al1 = along0 + (1 - along0) * t1
                let l0 = p0 + nrm * w0i, r0 = p0 - nrm * w0i, l1 = p1 + nrm * w1i, r1 = p1 - nrm * w1i
                // left half and right half, so "across" runs 0 → 0.5 → 1 (soft dark core)
                put(l0, al0, 0); put(p0, al0, 0.5); put(l1, al1, 0)
                put(l1, al1, 0); put(p0, al0, 0.5); put(p1, al1, 0.5)
                put(p0, al0, 0.5); put(r0, al0, 1); put(p1, al1, 0.5)
                put(p1, al1, 0.5); put(r0, al0, 1); put(r1, al1, 1)
                // the odd side branch
                if depth == 0 && i >= 1 && i <= 7 && rnd() < 0.3 {
                    let side: Double = rnd() < 0.5 ? 1 : -1
                    fissure(from: p1, angle: atan2(d.y, d.x) + side * rr(0.5, 1.1), length: L * rr(0.25, 0.45),
                            width: w1i * 0.7, along0: al1, depth: 1)
                }
            }
        }
        let count = 6 + Int(9 * k)
        for i in 0..<count {
            let a = Double(i) / Double(count) * .pi * 2 + rr(-0.25, 0.25)
            let start = SIMD2(cos(a), sin(a)) * R0 * 0.55
            fissure(from: start, angle: a, length: (2.4 + 6.5 * k) * rr(0.55, 1.25), width: 0.045 + 0.075 * k, along0: 0.1, depth: 0)
        }
        return v
    }
}
