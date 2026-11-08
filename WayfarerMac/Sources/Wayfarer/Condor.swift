import Foundation
import Metal
import simd

// MARK: - Condor: heavy long-range explorer with wingtip engines that tilt down for hover and landing
//
// An original design: a long arrowhead hull with a raised spine, swept wings, twin canted tail fins and a fixed
// main engine. The two wingtip nacelles swing on their pivots from horizontal (cruise) to vertical (hover/landing).

func buildCondor(device: MTLDevice) -> ShipModel {
    var b = MeshBuilder()
    // hull: long arrowhead
    b.extrude(mirrorOutline([SIMD2(0, -0.92), SIMD2(0.07, -0.7), SIMD2(0.13, -0.42), SIMD2(0.17, -0.1), SIMD2(0.19, 0.3),
                             SIMD2(0.17, 0.62), SIMD2(0.09, 0.74)]), depth: 0.1, bevel: 0.045, cy: 0, .paint)
    // raised spine and dark belly
    b.extrude(mirrorOutline([SIMD2(0, -0.6), SIMD2(0.07, -0.3), SIMD2(0.11, 0.1), SIMD2(0.11, 0.5), SIMD2(0.06, 0.66)]), depth: 0.05, bevel: 0.03, cy: 0.09, .metal)
    b.extrude(mirrorOutline([SIMD2(0, -0.78), SIMD2(0.1, -0.4), SIMD2(0.15, 0.1), SIMD2(0.13, 0.6)]), depth: 0.04, bevel: 0.025, cy: -0.085, .dark)
    // swept wings, slightly below the hull centre line
    b.extrude(mirrorOutline([SIMD2(0, -0.12), SIMD2(0.22, -0.14), SIMD2(0.6, 0.12), SIMD2(0.68, 0.2), SIMD2(0.68, 0.34),
                             SIMD2(0.42, 0.34), SIMD2(0.2, 0.38), SIMD2(0, 0.4)]), depth: 0.022, bevel: 0.014, cy: -0.015, .paint)
    // wing leading-edge strakes in metal
    for sx in [1.0, -1.0] {
        b.box(D3(0.5, 0.02, 0.035), D3(sx * 0.42, -0.012, 0.02), .metal, rot: D3(0, sx * 0.6, 0))
    }
    // cockpit canopy and a second, smaller observation dome
    b.octahedron(0.1, scale: D3(0.72, 0.58, 2.0), D3(0, 0.15, -0.5), .glass)
    b.octahedron(0.1, scale: D3(0.35, 0.2, 0.6), D3(0, 0.16, 0.05), .glass)
    // cyan running-light strips along the hull and wings
    for sx in [1.0, -1.0] {
        b.box(D3(0.012, 0.012, 0.5), D3(sx * 0.185, 0.03, 0.1), .cyan)
        b.box(D3(0.3, 0.008, 0.012), D3(sx * 0.48, 0.0, 0.335), .cyan)
        // hull side vents
        b.plane(0.16, 0.035, D3(sx * 0.2, 0.0, 0.42), .vent, rot: D3(0, sx * .pi / 2, 0))
    }
    // twin canted tail fins
    for sx in [1.0, -1.0] {
        let save = b.xform
        b.xform = b.xform * translate(D3(sx * 0.1, 0.1, 0)) * eulerXYZ(D3(0, 0, .pi / 2 - sx * 0.38))
        b.extrude([SIMD2(0, 0.36), SIMD2(0, 0.72), SIMD2(0.28, 0.82), SIMD2(0.29, 0.7), SIMD2(0.08, 0.38)], depth: 0.016, bevel: 0.01, cy: 0, .paint)
        b.xform = save
    }
    // fixed main engine
    let mainR = 0.07
    b.cylinder(mainR * 1.08, mainR * 1.25, mainR * 2.2, D3(0, 0, 0.74 - mainR * 0.5), .metal, rot: D3(.pi / 2, 0, 0), seg: 22, open: true)
    b.disc(mainR, D3(0, 0, 0.74 - mainR * 0.9), .disc, seg: 22)
    // wingtip pivot housings
    let pivots = [D3(0.75, 0.03, 0.25), D3(-0.75, 0.03, 0.25)]
    for p in pivots { b.cylinder(0.035, 0.035, 0.1, p + D3(-0.05 * (p.x > 0 ? 1 : -1), 0, 0), .dark, rot: D3(0, 0, .pi / 2), seg: 12) }

    // tilting nacelle, built around its pivot, pointing forward (-z) when level
    var nb = MeshBuilder()
    let nr = 0.075
    nb.cylinder(nr, nr, 0.36, D3(0, 0, 0.02), .paint, rot: D3(.pi / 2, 0, 0), seg: 24, open: true)            // body
    nb.cylinder(nr * 1.15, nr * 1.02, 0.08, D3(0, 0, -0.2), .metal, rot: D3(.pi / 2, 0, 0), seg: 24, open: true) // intake lip
    nb.disc(nr * 0.9, D3(0, 0, -0.17), .dark, seg: 24)                                                         // intake fan face
    nb.cylinder(nr * 0.96, nr * 0.82, 0.1, D3(0, 0, 0.25), .dark, rot: D3(.pi / 2, 0, 0), seg: 24, open: true)   // nozzle
    nb.disc(nr * 0.8, D3(0, 0, 0.24), .disc, seg: 24)                                                          // glowing exhaust
    nb.box(D3(0.012, 0.012, 0.3), D3(0, nr * 0.98, 0.02), .cyan)                                               // light strip on top
    for s in [1.0, -1.0] { nb.box(D3(0.01, 0.05, 0.16), D3(s * nr * 0.95, 0, 0.05), .metal) }                  // side fairings

    // landing leg, same construction as the Kestrel's but taller
    var lb = MeshBuilder()
    let len = 0.24, legR = 0.02, padR = 0.06
    lb.cylinder(legR, legR * 1.15, len, D3(0, -len / 2, 0), .dark, seg: 8)
    lb.cylinder(legR * 0.55, legR * 0.55, len * 0.7, D3(legR * 1.6, -len * 0.35, 0), .metal, seg: 6)
    lb.cylinder(padR, padR * 1.15, 0.02, D3(0, -len - 0.004, 0), .dark, seg: 14)
    let originY = -0.1
    let legPts = [D3(0.12, originY, -0.5), D3(-0.12, originY, -0.5), D3(0.24, originY, 0.36), D3(-0.24, originY, 0.36)]

    var condor = ShipModel(
        name: "Condor", role: "HEAVY EXPLORER", paint: 1, speedK: 1.5, pitch: 0.7, agility: 0.8, fuelEff: 0.18,
        hull: GPUMesh(device: device, verts: b.v), leg: GPUMesh(device: device, verts: lb.v), plume: plumeCone(device: device),
        eye: D3(0, 0.172, -0.5),
        cockpit: buildCockpit(device: device, style: .bubble, canopy: D3(0, 0.15, -0.5), half: D3(0.072, 0.058, 0.2), eye: D3(0, 0.172, -0.5), unitsPerMetre: 1.84 / 85),
        nacelle: GPUMesh(device: device, verts: nb.v), pivots: pivots,
        length: 1.84, size: 0.085, gearBottom: -originY + len + 0.015,
        legs: legPts.map { ($0, $0.z < 0 ? 1.45 : -1.45) },
        engines: [(pos: D3(0, 0, 0.74), r: 0.06, pivot: -1), (pos: D3(0, 0, 0.26), r: 0.068, pivot: 0), (pos: D3(0, 0, 0.26), r: 0.068, pivot: 1)],
        vtols: [],
        navLights: [(D3(-0.68, 0.0, 0.34), SIMD3(1, 0.23, 0.23), 0.1), (D3(0.68, 0.0, 0.34), SIMD3(0.23, 1, 0.48), 0.1),
                    (D3(0, 0.36, 0.78), SIMD3(1, 0.3, 0.3), 0.07)],
        steadyLights: [(D3(0, 0.02, -0.93), SIMD3(1, 1, 1), 0.08), (D3(0.2, 0.06, -0.3), SIMD3(0.35, 0.8, 1), 0.06), (D3(-0.2, 0.06, -0.3), SIMD3(0.35, 0.8, 1), 0.06)],
        landLights: legPts.map { D3($0.x * 0.8, originY - 0.01, $0.z * 0.85) })
    (condor.interior, condor.deck) = buildCondorInterior(device: device, u: 1.84 / 85)
    return condor
}

/// graphite hull plates with lighter panels and a few orange service markings
func makeCondorPanelTexture(device: MTLDevice) -> MTLTexture {
    let rnd = Mulberry(321)
    var cv = Canvas(512, 512, fill: SIMD3(0x6a, 0x6e, 0x76))
    for _ in 0..<80 {
        let pw = Int(30 + rnd.next() * 150), ph = Int(20 + rnd.next() * 110), px = Int(rnd.next() * 512), py = Int(rnd.next() * 512), k = rnd.next()
        let g = UInt8(88 + rnd.next() * 34)
        let c: SIMD3<UInt8> = k < 0.34 ? SIMD3(0xd0, 0xd3, 0xd8) : k < 0.42 ? SIMD3(0x2c, 0x2e, 0x33) : SIMD3(g, g &+ 2, g &+ 6)
        for ox in [0, -512] { for oy in [0, -512] {
            cv.rect(px + ox, py + oy, pw, ph, c)
            cv.strokeRect(px + ox, py + oy, pw, ph, SIMD3(14, 15, 18), alpha: 0.85)
        } }
    }
    for _ in 0..<6 {   // orange hazard markings
        let px = Int(rnd.next() * 512), py = Int(rnd.next() * 512)
        cv.rect(px, py, Int(40 + rnd.next() * 60), 6, SIMD3(0xe0, 0x6a, 0x1c))
    }
    for _ in 0..<300 { cv.rect(Int(rnd.next() * 512), Int(rnd.next() * 512), 2, 2, SIMD3(255, 255, 255), alpha: 0.08) }
    return makeTexture(device: device, w: 512, h: 512, pixels: cv.px, srgb: true)
}
