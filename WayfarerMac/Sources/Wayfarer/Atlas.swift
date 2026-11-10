import Foundation
import Metal
import simd

// MARK: - Atlas: a 1 km heavy carrier with a walkable deck (see Interior.swift)
//
// An original capital-ship design: a long armoured hull with a raised bridge tower aft, a dark keel with a lit
// hangar bay, two engine nacelles on pylons, a 2×2 main engine cluster and eight belly VTOL jets.
// Thousands of tiny window lights and surface detail give it its scale.

func buildAtlas(device: MTLDevice) -> ShipModel {
    var b = MeshBuilder()
    let rnd = Mulberry(4711)
    // main hull and armour layers
    b.extrude(mirrorOutline([SIMD2(0, -1.0), SIMD2(0.07, -0.9), SIMD2(0.14, -0.55), SIMD2(0.19, -0.1), SIMD2(0.2, 0.55),
                             SIMD2(0.18, 0.9), SIMD2(0.12, 0.98)]), depth: 0.12, bevel: 0.03, cy: 0, .paint)
    b.extrude(mirrorOutline([SIMD2(0, -0.8), SIMD2(0.09, -0.5), SIMD2(0.13, 0.0), SIMD2(0.14, 0.6), SIMD2(0.1, 0.85)]), depth: 0.05, bevel: 0.02, cy: 0.085, .metal)
    b.extrude(mirrorOutline([SIMD2(0, -0.92), SIMD2(0.1, -0.5), SIMD2(0.15, 0.1), SIMD2(0.15, 0.8), SIMD2(0.1, 0.95)]), depth: 0.06, bevel: 0.02, cy: -0.09, .dark)
    // prow armour plates
    for s in [1.0, -1.0] { b.box(D3(0.012, 0.09, 0.42), D3(s * 0.13, 0.0, -0.62), .metal, rot: D3(0, s * 0.2, 0)) }
    // bridge tower aft: stacked decks, window bands, antennae and a dish
    let tz = 0.5
    b.box(D3(0.16, 0.06, 0.3), D3(0, 0.14, tz), .paint)
    b.box(D3(0.12, 0.05, 0.2), D3(0, 0.195, tz - 0.01), .paint)
    b.box(D3(0.09, 0.04, 0.1), D3(0, 0.24, tz - 0.04), .metal)
    b.box(D3(0.161, 0.006, 0.301), D3(0, 0.15, tz), .lamp)
    b.box(D3(0.121, 0.005, 0.201), D3(0, 0.205, tz - 0.01), .lamp)
    b.octahedron(0.1, scale: D3(0.32, 0.12, 0.2), D3(0, 0.245, tz - 0.09), .glass)        // bridge windows
    for (x, h) in [(-0.03, 0.12), (0.025, 0.09), (0.0, 0.16)] { b.cylinder(0.002, 0.003, h, D3(x, 0.26 + h / 2, tz + 0.03), .dark, seg: 6) }
    b.cylinder(0.035, 0.035, 0.004, D3(0.05, 0.27, tz + 0.06), .metal, rot: D3(0.5, 0, 0.3), seg: 16)
    // landing lights either side of the cargo doors under the prow
    for s in [1.0, -1.0] { for z in stride(from: -0.56, through: -0.34, by: 0.04) { b.box(D3(0.02, 0.003, 0.006), D3(s * 0.04, -0.1405, z), .lamp) } }
    // side nacelles on pylons
    var nacPts: [D3] = []
    for s in [1.0, -1.0] {
        let c = D3(s * 0.3, 0.0, 0.58)
        b.cylinder(0.065, 0.065, 0.55, c, .paint, rot: D3(.pi / 2, 0, 0), seg: 28, open: true)
        b.cylinder(0.072, 0.066, 0.06, c + D3(0, 0, -0.29), .metal, rot: D3(.pi / 2, 0, 0), seg: 28, open: true)
        b.disc(0.06, c + D3(0, 0, -0.27), .dark, seg: 28)
        b.cylinder(0.06, 0.055, 0.08, c + D3(0, 0, 0.3), .dark, rot: D3(.pi / 2, 0, 0), seg: 28, open: true)
        b.disc(0.052, c + D3(0, 0, 0.29), .disc, seg: 28)
        b.box(D3(0.12, 0.025, 0.28), D3(s * 0.21, 0.0, 0.56), .metal)                        // pylon
        b.box(D3(0.004, 0.004, 0.5), c + D3(0, 0.066, 0), .cyan)
        nacPts.append(c + D3(0, 0, 0.32))
    }
    // main engine cluster
    var engines: [(pos: D3, r: Double, pivot: Int)] = []
    for x in [-0.085, 0.085] { for y in [-0.048, 0.045] {
        let r = 0.036, p = D3(x, y, 1.0)
        b.cylinder(r * 1.08, r * 1.2, 0.07, p + D3(0, 0, -0.02), .metal, rot: D3(.pi / 2, 0, 0), seg: 22, open: true)
        b.disc(r, p + D3(0, 0, -0.03), .disc, seg: 22)
        engines.append((pos: p, r: r, pivot: -1))
    } }
    for p in nacPts { engines.append((pos: p, r: 0.05, pivot: -1)) }
    // belly VTOL jets
    var vtols: [(pos: D3, r: Double)] = []
    for s in [1.0, -1.0] { for z in [-0.6, -0.2, 0.2, 0.6] {
        let p = D3(s * 0.11, -0.125, z)
        b.cylinder(0.03, 0.035, 0.02, p, .dark, seg: 14, open: true)
        vtols.append((pos: p, r: 0.028))
    } }
    // scale cues: rows of tiny lit windows along the hull sides, and greebles on the deck
    for s in [1.0, -1.0] {
        for row in 0..<3 {
            let y = -0.035 + Double(row) * 0.03
            for z in stride(from: -0.75, through: 0.85, by: 0.016) where rnd.next() > 0.35 {
                let halfW = 0.19 * min(1, (z + 1.0) / 0.9) + 0.012
                b.box(D3(0.002, 0.004, 0.006), D3(s * halfW, y, z), rnd.next() > 0.85 ? .cyan : .lamp)
            }
        }
    }
    for _ in 0..<140 {
        let z = -0.7 + rnd.next() * 1.5, x = (rnd.next() - 0.5) * 0.2 * min(1, (z + 1) / 0.8)
        let sz = D3(0.01 + rnd.next() * 0.04, 0.004 + rnd.next() * 0.012, 0.01 + rnd.next() * 0.05)
        b.box(sz, D3(x, 0.11 + sz.y / 2, z), rnd.next() > 0.5 ? .metal : .dark)
    }
    // turrets
    for (x, z) in [(0.0, -0.55), (0.0, -0.25), (0.08, 0.15), (-0.08, 0.15)] {
        b.cylinder(0.022, 0.026, 0.012, D3(x, 0.118, z), .metal, seg: 14)
        for s in [-0.006, 0.006] { b.box(D3(0.003, 0.003, 0.05), D3(x + s, 0.128, z - 0.03), .dark) }
    }

    // landing leg: a heavy strut with a broad pad
    var lb = MeshBuilder()
    let len = 0.11, legR = 0.012, padR = 0.03
    lb.cylinder(legR, legR * 1.2, len, D3(0, -len / 2, 0), .dark, seg: 10)
    lb.cylinder(legR * 0.5, legR * 0.5, len * 0.7, D3(legR * 1.7, -len * 0.35, 0), .metal, seg: 6)
    lb.cylinder(padR, padR * 1.15, 0.01, D3(0, -len - 0.003, 0), .dark, seg: 16)
    if let cruiser = loadShipAsset(device: device, name: "cruiser") {
        // the hull: "UNSA cruiser / spaceship" by xaxary (CC BY 4.0), 1.3 km. Decks, bay and bridge are fitted inside it.
        let m = 1.0 / 650                                   // model units per metre (2 units = 1.3 km)
        let legY = -82 * m
        let legPts = [D3(55, -82, 40), D3(-55, -82, 40), D3(60, -82, 170), D3(-60, -82, 170), D3(55, -82, 300), D3(-55, -82, 300)].map { $0 * m }
        lb = MeshBuilder()
        let L = 58 * m, R = 6 * m
        lb.cylinder(R, R * 1.2, L, D3(0, -L / 2, 0), .dark, seg: 12)
        lb.cylinder(R * 0.5, R * 0.5, L * 0.7, D3(R * 1.7, -L * 0.35, 0), .metal, seg: 8)
        lb.cylinder(R * 2.6, R * 3.0, 3 * m, D3(0, -L - 1 * m, 0), .dark, seg: 18)
        var vt: [(pos: D3, r: Double)] = []
        for (z, y) in [(-200.0, -56.0), (-80, -66), (60, -85), (220, -93)] { for s in [1.0, -1.0] { vt.append((D3(s * 45, y + 2, z) * m, 9 * m)) } }
        let eyeM = ATLAS_EYE * m
        var atlas = ShipModel(
            name: "Atlas", role: "HEAVY CRUISER", paint: 2, speedK: 1.2, pitch: 0.4,
            agility: 0.28, fuelEff: 0.06, camScale: 0.5, exitSide: 0.2,
            hullDetail: 1, mass: 3.8, chase: D3(0.43, 0.16, 0.95),
            hull: cruiser.mesh, leg: GPUMesh(device: device, verts: lb.v), plume: plumeCone(device: device),
            eye: eyeM, cockpit: nil,
            length: 2.0, size: 1.3, gearBottom: -legY + L + 4 * m,
            legs: legPts.map { ($0, $0.z < 0.2 ? 1.45 : -1.45) },
            // six main engines: the recessed rectangular housings either side of the stern hangar, three a side
            // (ray-cast from the model: rims at 570-581 m aft, centres 23 m below the deck line, 14 × 22 m openings)
            engines: [(64.8, 579.0), (82.8, 575.0), (100.5, 568.0)].flatMap { e in [1.0, -1.0].map { sx in
                (pos: D3(sx * e.0, -23.3, e.1) * m, r: 8.0 * m, pivot: -1) } },
            vtols: vt,
            navLights: [(D3(-150, -6, 360) * m, SIMD3(1, 0.23, 0.23), 0.05), (D3(150, -6, 360) * m, SIMD3(0.23, 1, 0.48), 0.05),
                        (D3(0, 92, 320) * m, SIMD3(1, 0.3, 0.3), 0.04)],
            steadyLights: [(D3(0, 2, -650) * m, SIMD3(1, 1, 1), 0.04)],
            landLights: legPts.map { D3($0.x * 0.9, legY - 2 * m, $0.z) })
        atlas.skin = cruiser.skin
        atlas.flame = (edge: SIMD3(0.3, 0.6, 2.4), core: SIMD3(1.6, 2.2, 3.4), hot: SIMD3(0.9, 1.6, 3.6), glow: D3(0.6, 0.85, 1.4))
        let (inside, deck) = buildAtlasInterior(device: device, u: m * 1)
        atlas.interior = inside; atlas.deck = deck
        atlas.liftCar = buildLiftCar(device: device, u: m)
        let bf = ATLAS_EYE.y - 1.5, dz = ATLAS_EYE.z - 200
        atlas.canopyCut = (D3(0, bf - 1, 130 + dz) * m, D3(15, bf + 20, 214 + dz) * m)     // cockpit view: open the tower round the bridge
        let bz = ATLAS_BAY_DZ
        atlas.cargo = CargoBay(floorY: -64, doorY: ATLAS_DOOR_Y, lift: (-10.5, 10.5, -252 + bz, -226 + bz), roverStart: D3(8, -64, -200 + bz), roverYaw: 0)
        return atlas
    }
    let originY = -0.12
    let legPts = [D3(0.09, originY, -0.7), D3(-0.09, originY, -0.7), D3(0.15, originY, 0.0), D3(-0.15, originY, 0.0), D3(0.15, originY, 0.7), D3(-0.15, originY, 0.7)]
    let eye = D3(0, 0.2498, tz - 0.1)          // inside the bridge glass, just ahead of the top deck

    var atlas = ShipModel(
        name: "Atlas", role: "HEAVY CARRIER", paint: 2, speedK: 1.2, pitch: 0.42,
        agility: 0.3, fuelEff: 0.07, camScale: 0.5, exitSide: 0.22,
        hullDetail: 11, mass: 3.6, chase: D3(0.33, 0.125, 0.7),
        hull: GPUMesh(device: device, verts: b.v), leg: GPUMesh(device: device, verts: lb.v), plume: plumeCone(device: device),
        eye: eye,
        cockpit: buildCockpit(device: device, style: .bubble, canopy: D3(0, 0.245, tz - 0.09), half: D3(0.032, 0.012, 0.02), eye: eye, unitsPerMetre: 2.0 / 1000),
        length: 2.0, size: 1.0, gearBottom: -originY + len + 0.008,
        legs: legPts.map { ($0, $0.z < 0 ? 1.45 : -1.45) },
        engines: engines, vtols: vtols,
        navLights: [(D3(-0.365, 0.0, 0.58), SIMD3(1, 0.23, 0.23), 0.03), (D3(0.365, 0.0, 0.58), SIMD3(0.23, 1, 0.48), 0.03),
                    (D3(0, 0.42, tz + 0.03), SIMD3(1, 0.3, 0.3), 0.02)],
        steadyLights: [(D3(0, 0.0, -1.0), SIMD3(1, 1, 1), 0.03), (D3(0.2, 0.05, 0.3), SIMD3(0.35, 0.8, 1), 0.02), (D3(-0.2, 0.05, 0.3), SIMD3(0.35, 0.8, 1), 0.02)],
        landLights: legPts.map { D3($0.x * 0.9, originY - 0.005, $0.z * 0.95) })
    let (inside, deck) = buildAtlasInterior(device: device, u: 2.0 / 1000)
    atlas.interior = inside; atlas.deck = deck
    atlas.liftCar = buildLiftCar(device: device, u: 2.0 / 1000)
    atlas.canopyCut = (D3(0, 0.236, tz - 0.14), D3(0.05, 0.3, tz - 0.035))   // cockpit view: open the tower round the bridge bubble
    if let m = loadShipAsset(device: device, name: "atlas") { atlas.hull = m.mesh; atlas.skin = m.skin }   // the Blender model
    atlas.cargo = CargoBay(floorY: -64, doorY: -70.2, lift: (-10.5, 10.5, -252, -226), roverStart: D3(8, -64, -200), roverYaw: 0)
    return atlas
}

/// off-white armour with grey plates and navy markings
func makeAtlasPanelTexture(device: MTLDevice) -> MTLTexture {
    let rnd = Mulberry(909)
    var cv = Canvas(512, 512, fill: SIMD3(0xb4, 0xb6, 0xb2))
    for _ in 0..<90 {
        let pw = Int(20 + rnd.next() * 120), ph = Int(14 + rnd.next() * 90), px = Int(rnd.next() * 512), py = Int(rnd.next() * 512), k = rnd.next()
        let g = UInt8(150 + rnd.next() * 50)
        let c: SIMD3<UInt8> = k < 0.18 ? SIMD3(0x6e, 0x72, 0x78) : k < 0.24 ? SIMD3(0x1c, 0x2c, 0x52) : SIMD3(g, g, g &- 4)
        for ox in [0, -512] { for oy in [0, -512] {
            cv.rect(px + ox, py + oy, pw, ph, c)
            cv.strokeRect(px + ox, py + oy, pw, ph, SIMD3(60, 62, 66), alpha: 0.7)
        } }
    }
    for _ in 0..<8 { cv.rect(Int(rnd.next() * 512), Int(rnd.next() * 512), Int(30 + rnd.next() * 80), 5, SIMD3(0x1c, 0x2c, 0x52)) }
    for _ in 0..<400 { cv.rect(Int(rnd.next() * 512), Int(rnd.next() * 512), 2, 2, SIMD3(0, 0, 0), alpha: 0.12) }
    return makeTexture(device: device, w: 512, h: 512, pixels: cv.px, srgb: true)
}
