import Foundation
import Metal
import simd

// Walkable ship interiors, one per ship and sized to it. Press I to leave the pilot's seat and walk around while the
// ship flies on by herself; stairs (or the Atlas's lift) lead up into the real cockpit under the canopy, where you
// can stand and look out, then sit down (E) to fly again.
//
// Everything is laid out in metres relative to the hull centre (x right, y up, z aft); 1 m = 0.001 km, so a deck
// point maps to the world with pos + q · (p × 0.001). Inside, the hull is cut away where it would block the windows
// or poke through a cabin (`carves`), and the canopy glass is opened up.

struct DeckRoom {
    var x0: Double, x1: Double, z0: Double, z1: Double     // walkable area, already inset by the body radius
    var y0: Double, y1: Double                             // floor height at the start and end of the slope
    var sz0: Double? = nil, sz1: Double? = nil             // where the slope runs (defaults to z0…z1); flat beyond
    func floor(_ z: Double) -> Double {
        let a = sz0 ?? z0, b = sz1 ?? z1
        return y0 + (y1 - y0) * clampd((z - a) / (b - a), 0, 1)
    }
    func contains(_ x: Double, _ z: Double) -> Bool { x >= x0 && x <= x1 && z >= z0 && z <= z1 }
}
struct DeckObstacle { var x0: Double, x1: Double, z0: Double, z1: Double, y: Double; var round = false }
struct Helm { var p: D3; var r: Double; var word: String; var seat: Bool }

struct Deck {
    var rooms: [DeckRoom]
    var obstacles: [DeckObstacle]
    var spawn: D3, spawnYaw: Double                         // where you appear when you leave a console
    var helms: [Helm]                                       // seats and consoles: E there takes the controls
    var lifts: [(a: D3, b: D3)] = []                        // E on one pad rides to the other
    var liftYaws: [(a: Double, b: Double)] = []             // which way each station's car doors face (0: toward -z)
    var liftNames: [(a: String, b: String)] = []
    var carves: [(lo: D3, hi: D3)] = []                     // hull cut away inside (model units; x is |x|)
    var liftRect: (x0: Double, x1: Double, z0: Double, z1: Double)? = nil   // the cargo lift platform (its floor moves)

    /// the floor under (x, z) on the level nearest to height y, or nil if that spot isn't walkable
    func floor(_ x: Double, _ z: Double, near y: Double, liftY: Double? = nil) -> Double? {
        var best: Double? = nil
        for r in rooms where r.contains(x, z) {
            let f = r.floor(z)
            if abs(f - y) < 1.4, best == nil || abs(f - y) < abs(best! - y) { best = f }
        }
        if let lr = liftRect, let ly = liftY, x > lr.x0 - 0.05 && x < lr.x1 + 0.05 && z > lr.z0 - 0.05 && z < lr.z1 + 0.05, abs(ly - y) < 1.4,
           best == nil || abs(ly - y) < abs(best! - y) { best = ly }
        guard let f = best else { return nil }
        for o in obstacles where abs(o.y - f) < 2.2 {
            if o.round {
                let cx = (o.x0 + o.x1) / 2, cz = (o.z0 + o.z1) / 2, r = (o.x1 - o.x0) / 2
                if (x - cx) * (x - cx) + (z - cz) * (z - cz) < r * r { return nil }
            } else if x >= o.x0 && x <= o.x1 && z >= o.z0 && z <= o.z1 { return nil }
        }
        return f
    }
    func walkable(_ x: Double, _ z: Double, _ y: Double) -> Bool { floor(x, z, near: y) != nil }
    /// the lowest floor at (x, z), for placing someone
    func anyFloor(_ x: Double, _ z: Double) -> Double? { rooms.filter { $0.contains(x, z) }.map { $0.floor(z) }.min() }
}

struct AboardState {
    var on = false
    var p = D3.zero            // feet position, metres in the ship's frame
    var yaw = 0.0, pitch = 0.0, vy = 0.0, onFloor = true
    var bob = 0.0, stepPhase = 0.0, lastStep = 0
    var lift: (from: D3, to: D3, t: Double)? = nil         // t: seconds since the doors started closing
    var liftYaw = (from: 0.0, to: 0.0), liftOffset = D3.zero, liftDest = "", liftIndex = 0, liftSpin = 0.0
}

// MARK: - building blocks

/// meshes and collision for a deck, built in metres
struct DeckKit {
    var b = MeshBuilder()
    var rooms: [DeckRoom] = []
    var obstacles: [DeckObstacle] = []
    var level = 0.0                     // floor height that new obstacles belong to
    let body = 0.35
    init(u: Double) { b.xform = scaleM(D3(u, u, u)) }

    mutating func box(_ s: D3, _ c: D3, _ m: Mat, solid: Bool = false, rot: D3 = .zero) {
        b.box(s, c, m, rot: rot)
        if solid { block(c.x - s.x / 2, c.x + s.x / 2, c.z - s.z / 2, c.z + s.z / 2) }
    }
    mutating func block(_ x0: Double, _ x1: Double, _ z0: Double, _ z1: Double) {
        obstacles.append(DeckObstacle(x0: x0 - body, x1: x1 + body, z0: z0 - body, z1: z1 + body, y: level))
    }
    mutating func post(_ x: Double, _ z: Double, _ r: Double) {
        let rr = r + body
        obstacles.append(DeckObstacle(x0: x - rr, x1: x + rr, z0: z - rr, z1: z + rr, y: level, round: true))
    }
    mutating func walk(_ x0: Double, _ x1: Double, _ z0: Double, _ z1: Double, y0: Double, y1: Double? = nil, inset: Bool = true) {
        let i = inset ? body : 0
        rooms.append(DeckRoom(x0: x0 + i, x1: x1 - i, z0: z0 + i, z1: z1 - i, y0: y0, y1: y1 ?? y0))
    }
    /// a glowing LED line between two points
    mutating func led(_ p: D3, _ q: D3, _ w: Double = 0.05) {
        let d = q - p, len = simd_length(d)
        if len < 1e-6 { return }
        let save = b.xform
        b.xform = b.xform * translate((p + q) / 2) * simd_double4x4(simd_quatd(from: D3(0, 0, 1), to: d / len))
        b.box(D3(w, w, len), .zero, .led)
        b.xform = save
    }
    mutating func beam(_ p: D3, _ q: D3, _ w: Double, _ m: Mat) {
        let d = q - p, len = simd_length(d)
        if len < 1e-6 { return }
        let save = b.xform
        b.xform = b.xform * translate((p + q) / 2) * simd_double4x4(simd_quatd(from: D3(0, 0, 1), to: d / len))
        b.box(D3(w, w, len), .zero, m)
        b.xform = save
    }
    /// window framing for an octahedral canopy (centre c, half-extents h): the edges and a few diamond rings,
    /// each a dark frame with a glowing line on its inner face, so the open glass reads as a window
    mutating func canopyFrame(_ c: D3, _ h: D3, width w: Double, rings: [Double] = [0.0, 0.3, 0.6]) {
        func pt(_ fx: Double, _ fy: Double, _ fz: Double) -> D3 { c + D3(fx * h.x, fy * h.y, fz * h.z) }
        let top = pt(0, 1, 0)
        let corners = [(1.0, 0.0), (0.0, 1.0), (-1.0, 0.0), (0.0, -1.0)]
        for (fx, fz) in corners { beam(top, pt(fx, 0, fz), w, .metal); led(top - D3(0, w * 0.6, 0), pt(fx, 0, fz) - D3(0, w * 0.6, 0), w * 0.3) }
        for f in rings {
            let s = 1 - f
            for i in 0..<4 {
                let a = corners[i], bb = corners[(i + 1) % 4]
                let p = pt(a.0 * s, f, a.1 * s), q = pt(bb.0 * s, f, bb.1 * s)
                beam(p, q, w, .metal); led(p - D3(0, w * 0.6, 0), q - D3(0, w * 0.6, 0), w * 0.3)
            }
        }
    }
    mutating func screen(_ c: D3, _ w: Double, _ h: Double, _ pic: ScreenPic, tilt: Double = 0, yaw: Double = 0) {
        let cw = 1.0 / Double(SCREEN_CELLS.cols), ch = 1.0 / Double(SCREEN_CELLS.rows)
        let u0 = Double(pic.rawValue % SCREEN_CELLS.cols) * cw, v0 = Double(pic.rawValue / SCREEN_CELLS.cols) * ch
        let save = b.xform
        b.xform = b.xform * translate(c) * eulerXYZ(D3(tilt, yaw, 0))
        b.quad(D3(-w / 2, -h / 2, 0), D3(w / 2, -h / 2, 0), D3(w / 2, h / 2, 0), D3(-w / 2, h / 2, 0), .screen,
               uv: [SIMD2(u0, v0 + ch), SIMD2(u0 + cw, v0 + ch), SIMD2(u0 + cw, v0), SIMD2(u0, v0)])
        b.box(D3(w * 1.06, h * 1.08, 0.05), D3(0, 0, -0.04), .dark)
        let e = D3(w * 0.53 + 0.02, h * 0.54 + 0.02, 0)
        b.box(D3(w * 1.08, 0.025, 0.03), D3(0, -e.y, 0.0), .led)                                       // glowing under-edge
        b.xform = save
    }
    /// a closed room: floor, ceiling, end walls (optional doorways), side walls with an optional window band whose
    /// reveal is closed out to `reach` (the hull skin). Sci-fi trim: LED lines along the floor and ceiling edges,
    /// light panels in the ceiling, vertical LED bars between the windows.
    mutating func room(halfW X: Double, z0: Double, z1: Double, floor fy: Double, height H: Double,
                       window: (y0: Double, y1: Double)? = nil, reach: Double = 0, mullion: Double = 2.5,
                       frontDoor: Double = 0, backDoor: Double = 0, doorH: Double = 2.4, panels: Int = 2,
                       floorHole: (x0: Double, x1: Double, z0: Double, z1: Double)? = nil) {
        let zc = (z0 + z1) / 2, L = z1 - z0, t = 0.2
        let ext = window != nil ? max(reach - X, 0) + 0.5 : 0
        if let h = floorHole {      // a floor with a rectangular opening (the cargo lift)
            let XX = X + ext
            box(D3(h.x0 + XX, t, L), D3((-XX + h.x0) / 2, fy - t / 2, zc), .floor)
            box(D3(XX - h.x1, t, L), D3((XX + h.x1) / 2, fy - t / 2, zc), .floor)
            box(D3(h.x1 - h.x0, t, h.z0 - z0), D3((h.x0 + h.x1) / 2, fy - t / 2, (z0 + h.z0) / 2), .floor)
            box(D3(h.x1 - h.x0, t, z1 - h.z1), D3((h.x0 + h.x1) / 2, fy - t / 2, (h.z1 + z1) / 2), .floor)
        } else { box(D3(2 * (X + ext), t, L), D3(0, fy - t / 2, zc), .floor) }
        box(D3(2 * (X + ext), t, L), D3(0, fy + H + t / 2, zc), .wall)
        for k in 0..<panels {     // recessed ceiling light panels
            let x = panels == 1 ? 0 : -X * 0.5 + Double(k) * (X / Double(panels - 1))
            box(D3(min(0.35, X * 0.1), 0.04, L - 1.5), D3(x, fy + H - 0.02, zc), .lamp)
        }
        for (z, door, sgn) in [(z0, frontDoor, -1.0), (z1, backDoor, 1.0)] {
            let wz = z + sgn * t / 2
            if door <= 0 { box(D3(2 * X, H, t), D3(0, fy + H / 2, wz), .wall) }
            else {
                for s in [-1.0, 1.0] { box(D3(X - door, H, t), D3(s * (X + door) / 2, fy + H / 2, wz), .wall) }
                box(D3(2 * door, H - doorH, t), D3(0, fy + doorH + (H - doorH) / 2, wz), .wall)
                let fz = z - sgn * 0.02
                led(D3(-door, fy, fz), D3(-door, fy + doorH, fz), 0.07); led(D3(door, fy, fz), D3(door, fy + doorH, fz), 0.07)
                led(D3(-door, fy + doorH, fz), D3(door, fy + doorH, fz), 0.07)
            }
            // LED along the base and top of the end walls
            led(D3(-X, fy + 0.05, z - sgn * 0.03), D3(door > 0 ? -door : X, fy + 0.05, z - sgn * 0.03))
            if door > 0 { led(D3(door, fy + 0.05, z - sgn * 0.03), D3(X, fy + 0.05, z - sgn * 0.03)) }
            led(D3(-X, fy + H - 0.05, z - sgn * 0.03), D3(X, fy + H - 0.05, z - sgn * 0.03))
        }
        for s in [-1.0, 1.0] {
            let wx = s * (X + t / 2), ix = s * (X - 0.03)
            led(D3(ix, fy + 0.05, z0), D3(ix, fy + 0.05, z1))
            led(D3(ix, fy + H - 0.05, z0), D3(ix, fy + H - 0.05, z1))
            if let w = window {
                box(D3(t, w.y0 - fy, L), D3(wx, (fy + w.y0) / 2, zc), .wall)
                box(D3(t, fy + H - w.y1, L), D3(wx, (w.y1 + fy + H) / 2, zc), .wall)
                var z = z0
                while z <= z1 + 1e-6 {
                    box(D3(0.3, w.y1 - w.y0, 0.25), D3(wx, (w.y0 + w.y1) / 2, z), .metal)
                    led(D3(ix - s * 0.14, w.y0, z), D3(ix - s * 0.14, w.y1, z), 0.04)
                    z += mullion
                }
                if w.y0 - fy > 0.5 { box(D3(0.6, 0.06, L), D3(s * (X - 0.2), w.y0 + 0.03, zc), .metal) }
                led(D3(ix - s * 0.1, w.y0 + 0.07, z0), D3(ix - s * 0.1, w.y0 + 0.07, z1))
                // the reveal out to the hull skin: caps at both ends
                for z in [z0 - t / 2, z1 + t / 2] { box(D3(ext, H, t), D3(s * (X + ext / 2), fy + H / 2, z), .wall) }
            } else {
                box(D3(t, H, L), D3(wx, fy + H / 2, zc), .wall)
                var z = z0 + 2.0
                while z < z1 - 1.0 { led(D3(ix, fy + 0.4, z), D3(ix, fy + H - 0.4, z), 0.04); z += 3.0 }
            }
        }
    }
    /// a steep stairway between two floors along z, enclosed by walls with LED handrails and a sloped ceiling.
    /// `zLow` is where it starts (floor yLow), `zHigh` where it arrives (floor yHigh).
    mutating func stairs(halfW w: Double, zLow: Double, zHigh: Double, yLow: Double, yHigh: Double, headroom: Double = 2.4, ceilingFrom: Double? = nil) {
        let n = max(4, Int(abs(yHigh - yLow) / 0.22)), run = zHigh - zLow, rise = yHigh - yLow
        for i in 0..<n {
            let f0 = Double(i) / Double(n), f1 = Double(i + 1) / Double(n)
            let za = zLow + run * f0, zb = zLow + run * f1, top = yLow + rise * f1
            b.box(D3(2 * w, top - yLow + 0.1, abs(zb - za)), D3(0, (top + yLow - 0.1) / 2, (za + zb) / 2), .floor)
            led(D3(-w, top + 0.01, zb), D3(w, top + 0.01, zb), 0.025)                     // lit step nosing
        }
        let lo = min(yLow, yHigh) - 0.1, hi = max(yLow, yHigh) + headroom + 0.2, zc = (zLow + zHigh) / 2, L = abs(run)
        for s in [-1.0, 1.0] {
            b.box(D3(0.2, hi - lo, L), D3(s * (w + 0.1), (lo + hi) / 2, zc), .wall)
            led(D3(s * (w - 0.02), yLow + 1.0, zLow), D3(s * (w - 0.02), yHigh + 1.0, zHigh), 0.06)   // handrail
        }
        // sloped ceiling following the stairs
        let c0 = ceilingFrom ?? (yLow + headroom), c1 = yHigh + headroom
        let mid = D3(0, (c0 + c1) / 2 + 0.1, zc), slope = atan2(c1 - c0, -(zHigh - zLow)) * (zHigh < zLow ? 1 : -1)
        b.box(D3(2 * w + 0.4, 0.2, sqrt(L * L + (c1 - c0) * (c1 - c0))), mid, .wall, rot: D3(slope, 0, 0))
        rooms.append(DeckRoom(x0: -w + body, x1: w - body, z0: min(zLow, zHigh) - 0.6, z1: max(zLow, zHigh) + 0.6,
                              y0: zLow < zHigh ? yLow : yHigh, y1: zLow < zHigh ? yHigh : yLow,
                              sz0: min(zLow, zHigh), sz1: max(zLow, zHigh)))
    }
    /// a pilot's seat facing forward (-z), seat pan at height `y`
    mutating func seat(_ c: D3, scale k: Double = 1) {
        box(D3(0.62, 0.14, 0.6) * k, c + D3(0, 0, 0) * k, .dark)
        box(D3(0.56, 0.06, 0.52) * k, c + D3(0, 0.09, 0) * k, .orange)
        box(D3(0.62, 0.95, 0.14) * k, c + D3(0, 0.5, 0.3) * k, .dark)
        box(D3(0.5, 0.75, 0.05) * k, c + D3(0, 0.5, 0.22) * k, .orange)
        box(D3(0.34, 0.24, 0.12) * k, c + D3(0, 1.1, 0.3) * k, .dark)
        for s in [-1.0, 1.0] { box(D3(0.08, 0.06, 0.5) * k, c + D3(s * 0.33, 0.3, 0.02) * k, .metal); led(c + D3(s * 0.37, 0.33, -0.2) * k, c + D3(s * 0.37, 0.33, 0.25) * k, 0.02) }
        b.cylinder(0.08 * k, 0.12 * k, (c.y - level) , D3(c.x, (c.y + level) / 2, c.z), .metal, seg: 10)
    }
    func deck(spawn: D3, spawnYaw: Double, helms: [Helm], lifts: [(a: D3, b: D3)] = [], carves: [(lo: D3, hi: D3)], u: Double) -> Deck {
        Deck(rooms: rooms, obstacles: obstacles, spawn: spawn, spawnYaw: spawnYaw, helms: helms, lifts: lifts,
             carves: carves.map { ($0.lo * u, $0.hi * u) })
    }
}

// MARK: - Atlas (1.3 km, the UNSA cruiser hull): observation lounge, corridor, reactor hall, hallway, lift up to the bridge

/// where things are aboard the Atlas (deck metres): the bridge eye, the cargo bay's offset along the hull, the hallway
let ATLAS_EYE = D3(0, 63.5, 290)
let ATLAS_BAY_DZ = 390.0
let ATLAS_DOOR_Y = -90.0
let ATLAS_HALL = (z0: 200.6, seg: 19.35, count: 5)

func buildAtlasInterior(device: MTLDevice, u: Double) -> (GPUMesh, Deck) {
    var k = DeckKit(u: u)
    let fy = -6.0
    k.level = fy
    // ---- observation lounge: x ±104, z -40…20, 14 m high, floor-to-ceiling windows on both flanks
    let LX = 80.0, LZ0 = -40.0, LZ1 = 20.0, LH = 14.0, dw = 3.5, dh = 4.5
    k.room(halfW: LX, z0: LZ0, z1: LZ1, floor: fy, height: LH, window: (fy + 0.25, fy + LH - 0.5), reach: 84, mullion: 7.5,
           backDoor: dw, doorH: dh, panels: 9)
    k.walk(-LX + 0.6, LX - 0.6, LZ0, LZ1, y0: fy)
    // glowing floor lanes leading to the windows and the helm
    for z in stride(from: LZ0 + 5, through: LZ1 - 5, by: 10) { k.led(D3(-LX + 2, fy + 0.01, z), D3(LX - 2, fy + 0.01, z), 0.08) }
    for s in [-1.0, 1.0] {
        for z in stride(from: LZ0 + 8, through: LZ1 - 6, by: 13) {      // benches facing the windows
            k.box(D3(2.2, 0.5, 6), D3(s * (LX - 7), fy + 0.25, z), .dark, solid: true)
            k.box(D3(0.4, 0.9, 6), D3(s * (LX - 8.0), fy + 0.95, z), .dark)
            k.led(D3(s * (LX - 5.85), fy + 0.5, z - 3), D3(s * (LX - 5.85), fy + 0.5, z + 3))
        }
    }
    // pillars wrapped in LED rings
    for x in [-70.0, -32, 32, 70] { for z in [-24.0, 6] {
        k.box(D3(1.6, LH, 1.6), D3(x, fy + LH / 2, z), .metal)
        for y in [0.6, 3.2, 10.5] { k.box(D3(1.75, 0.1, 1.75), D3(x, fy + y, z), .led) }
        k.box(D3(2.4, 0.4, 2.4), D3(x, fy + 0.2, z), .dark)
        k.post(x, z, 1.4)
    } }
    // central holo table with a slowly glowing planet
    let ht = D3(0, fy, -12)
    k.b.cylinder(4, 4.4, 1.0, ht + D3(0, 0.5, 0), .dark, seg: 32)
    k.b.cylinder(3.7, 3.7, 0.06, ht + D3(0, 1.03, 0), .led, seg: 32)
    k.b.sphere(2.2, ht + D3(0, 4.2, 0), .crystal, seg: 24, rings: 14)
    for i in 0..<3 { k.b.cylinder(3.0 + Double(i) * 0.4, 3.0 + Double(i) * 0.4, 0.05, ht + D3(0, 4.2, 0), .cyan, rot: D3(0.4 + Double(i) * 0.35, Double(i), 0), seg: 40, open: true) }
    k.post(ht.x, ht.z, 4.4)
    for a in stride(from: 0.4, to: .pi * 2, by: .pi / 2) {
        let c = ht + D3(sin(a) * 9, 0, cos(a) * 9)
        k.b.box(D3(5, 0.55, 1.8), c + D3(0, 0.28, 0), .orange, rot: D3(0, a, 0))
        k.b.box(D3(5, 0.9, 0.4), c + D3(sin(a) * 0.8, 0.9, cos(a) * 0.8), .dark, rot: D3(0, a, 0))
        k.post(c.x, c.z, 2.6)
    }
    for (x, z) in [(-52.0, -32.0), (52, -32), (-52, 12), (52, 12), (-62, -10), (62, -10)] {   // planters
        k.box(D3(3.2, 1.0, 3.2), D3(x, fy + 0.5, z), .dark)
        k.box(D3(3.3, 0.06, 3.3), D3(x, fy + 1.0, z), .led)
        k.b.sphere(1.6, D3(x, fy + 2.3, z), .plant, scale: D3(1, 1.2, 1), seg: 10, rings: 7)
        k.b.sphere(1.0, D3(x + 0.6, fy + 3.6, z - 0.3), .plant, seg: 8, rings: 6)
        k.post(x, z, 2.3)
    }
    // lounge helm station against the front wall
    let hz = LZ0 + 4
    k.box(D3(10, 1.1, 2), D3(0, fy + 0.55, hz), .dark, solid: true)
    k.box(D3(10.2, 0.08, 2.2), D3(0, fy + 1.12, hz), .metal)
    k.led(D3(-4.8, fy + 1.17, hz + 1.05), D3(4.8, fy + 1.17, hz + 1.05), 0.06)
    k.screen(D3(-3.2, fy + 2.0, hz - 0.6), 2.6, 1.6, .radar, tilt: -0.25, yaw: 0.25)
    k.screen(D3(0, fy + 2.05, hz - 0.7), 3.0, 1.7, .ship, tilt: -0.25)
    k.screen(D3(3.2, fy + 2.0, hz - 0.6), 2.6, 1.6, .power, tilt: -0.25, yaw: -0.25)
    k.screen(D3(0, fy + 8.0, LZ0 + 0.1), 18, 9, .map)
    k.screen(D3(-22, fy + 6.5, LZ0 + 0.1), 9, 4.5, .shields)
    k.screen(D3(22, fy + 6.5, LZ0 + 0.1), 9, 4.5, .readout)
    // lift up to the bridge, front left of the lounge

    // ---- corridor aft: x ±3.5, z 20…140, 4.5 m high
    let CZ0 = LZ1, CZ1 = 140.0
    let corridorModel = assetsURL().map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Props/corridor.mesh").path) } ?? false
    if !corridorModel { k.room(halfW: dw, z0: CZ0, z1: CZ1, floor: fy, height: dh, frontDoor: dw, backDoor: dw, doorH: dh, panels: 1) }   // else: the Jungle Jim corridor (Props.swift)
    k.walk(-dw, dw, CZ0 - 1.2, CZ1 + 1.2, y0: fy)
    if !corridorModel { for z in stride(from: CZ0 + 6, through: CZ1 - 4, by: 8) {      // ribbed frames with LED rings
        for s in [-1.0, 1.0] { k.box(D3(0.5, dh, 0.6), D3(s * (dw - 0.1), fy + dh / 2, z), .metal); k.led(D3(s * (dw - 0.36), fy + 0.1, z), D3(s * (dw - 0.36), fy + dh - 0.5, z), 0.05) }
        k.box(D3(dw * 2, 0.45, 0.6), D3(0, fy + dh - 0.2, z), .metal)
        k.led(D3(-dw + 0.4, fy + dh - 0.44, z), D3(dw - 0.4, fy + dh - 0.44, z), 0.05)
    }
    k.led(D3(0, fy + 0.01, CZ0), D3(0, fy + 0.01, CZ1), 0.12) }

    // ---- reactor hall: x ±24, z 140…200, 20 m high, a glowing core in the middle
    let RX = 24.0, RZ0 = CZ1, RZ1 = 200.0, RH = 20.0
    k.room(halfW: RX, z0: RZ0, z1: RZ1, floor: fy, height: RH, frontDoor: dw, backDoor: 2.0, doorH: dh, panels: 3)
    k.walk(-RX + 1.6, RX - 1.6, RZ0, RZ1, y0: fy)
    for s in [-1.0, 1.0] {
        for y in [2.0, 9.0] { k.b.cylinder(0.8, 0.8, RZ1 - RZ0 - 1, D3(s * (RX - 1.4), fy + y, (RZ0 + RZ1) / 2), .metal, rot: D3(.pi / 2, 0, 0), seg: 12) }
    }
    let rc = D3(0, fy, 175)
    k.b.cylinder(7.5, 8, 1.5, rc + D3(0, 0.75, 0), .dark, seg: 36)
    k.b.cylinder(3.6, 3.6, RH - 3, rc + D3(0, 1.5 + (RH - 3) / 2, 0), .disc, seg: 36)
    for y in [3.0, 7.0, 11.0, 15.0] { k.b.cylinder(5.2, 5.2, 0.9, rc + D3(0, y, 0), .metal, seg: 36); k.b.cylinder(5.25, 5.25, 0.12, rc + D3(0, y + 0.5, 0), .led, seg: 36, open: true) }
    k.b.cylinder(7.5, 8, 1.5, rc + D3(0, RH - 0.75, 0), .dark, seg: 36)
    k.b.cylinder(9.5, 9.5, 1.1, rc + D3(0, 2.05, 0), .metal, seg: 48, open: true)
    k.b.cylinder(9.55, 9.55, 0.08, rc + D3(0, 2.6, 0), .led, seg: 48, open: true)
    k.post(rc.x, rc.z, 9.6)

    // ---- the bridge, high in the cruiser's command tower: the captain's seat facing the bow
    let eye = ATLAS_EYE, bf = eye.y - 1.5, BX = 11.0, dz = eye.z - 200, BZ0 = 197.0 + dz, BZ1 = 224.0 + dz, BH = 6.0
    k.level = bf
    k.box(D3(2 * BX, 0.3, BZ1 - BZ0), D3(0, bf - 0.15, (BZ0 + BZ1) / 2), .floor)
    k.led(D3(-BX, bf + 0.02, BZ0 + 0.05), D3(BX, bf + 0.02, BZ0 + 0.05), 0.1)
    let wz0 = 207.0 + dz                                      // walls and ceiling only behind the glass
    k.box(D3(2 * BX, 0.2, BZ1 - wz0), D3(0, bf + BH + 0.1, (wz0 + BZ1) / 2), .wall)
    k.box(D3(1.2, 0.04, BZ1 - wz0 - 2), D3(-4, bf + BH - 0.02, (wz0 + BZ1) / 2), .lamp)
    k.box(D3(1.2, 0.04, BZ1 - wz0 - 2), D3(4, bf + BH - 0.02, (wz0 + BZ1) / 2), .lamp)
    k.box(D3(2 * BX, BH, 0.2), D3(0, bf + BH / 2, BZ1 + 0.1), .wall)
    k.led(D3(-BX, bf + BH - 0.05, wz0), D3(BX, bf + BH - 0.05, wz0), 0.08)
    for s in [-1.0, 1.0] {
        k.box(D3(0.2, BH, BZ1 - wz0), D3(s * (BX + 0.1), bf + BH / 2, (wz0 + BZ1) / 2), .wall)
        k.led(D3(s * (BX - 0.03), bf + 0.05, BZ0), D3(s * (BX - 0.03), bf + 0.05, BZ1))
        k.led(D3(s * (BX - 0.03), bf + BH - 0.05, wz0), D3(s * (BX - 0.03), bf + BH - 0.05, BZ1))
        // a low LED rail along the open front edges
        k.box(D3(0.1, 1.0, wz0 - BZ0), D3(s * BX, bf + 0.5, (BZ0 + wz0) / 2), .metal)
        k.led(D3(s * BX, bf + 1.02, BZ0), D3(s * BX, bf + 1.02, wz0), 0.07)
        // side stations
        k.box(D3(1.2, 1.0, 4.0), D3(s * 7.5, bf + 0.5, 212 + dz), .dark, solid: true)
        k.led(D3(s * 6.88, bf + 1.0, 210 + dz), D3(s * 6.88, bf + 1.0, 214 + dz), 0.04)
        k.screen(D3(s * 7.6, bf + 1.7, 212 + dz), 2.6, 1.2, s < 0 ? .radar : .shields, tilt: 0, yaw: -s * .pi / 2)
    }
    k.box(D3(2 * BX, 1.0, 0.1), D3(0, bf + 0.5, BZ0), .metal)
    k.led(D3(-BX, bf + 1.02, BZ0), D3(BX, bf + 1.02, BZ0), 0.07)
    k.seat(D3(0, bf + 0.55, 200.5 + dz), scale: 1.2)
    k.block(-0.5, 0.5, 199.9 + dz, 201.0 + dz)
    k.block(-1.0, 1.0, 198.0 + dz, 199.6 + dz)                      // the cockpit consoles in front of the seat
    // holo table and the lift pad at the back
    k.b.cylinder(1.6, 1.9, 1.0, D3(0, bf + 0.5, 215 + dz), .dark, seg: 28)
    k.b.cylinder(1.5, 1.5, 0.05, D3(0, bf + 1.02, 215 + dz), .led, seg: 28)
    k.b.sphere(0.9, D3(0, bf + 2.0, 215 + dz), .crystal, seg: 18, rings: 10)
    k.post(0, 215 + dz, 1.9)
    let liftB = D3(0, bf, 221 + dz)
    liftShaft(&k, liftB, yaw: 0, height: BH)
    k.walk(-BX, BX, BZ0, BZ1, y0: bf)

    // ---- the hallway from the reactor hall aft to a lobby under the bridge (the hallway model, Props.swift), and the lift up
    k.level = fy
    let hz1 = ATLAS_HALL.z0 + ATLAS_HALL.seg * Double(ATLAS_HALL.count)
    k.walk(-1.7, 1.7, RZ1 - 1.2, hz1 + 0.6, y0: fy, inset: false)
    let LZa = hz1 - 0.3, LZb = liftB.z + 4.5
    k.room(halfW: 4.5, z0: LZa, z1: LZb, floor: fy, height: 6, frontDoor: 1.8, doorH: 3.2, panels: 1)
    k.walk(-4.5, 4.5, LZa, LZb, y0: fy)
    let liftA = D3(0, fy, liftB.z)
    liftShaft(&k, liftA, yaw: 0, height: 6)
    // ---- cargo bay, low in the belly: the rover, two more parked, crates, and the lift down to the ground
    let CY = -64.0, CX = 28.0, BZ0c = -270.0 + ATLAS_BAY_DZ, BZ1c = -170.0 + ATLAS_BAY_DZ, CH = 16.0
    let hole = (x0: -10.5, x1: 10.5, z0: -252.0 + ATLAS_BAY_DZ, z1: -226.0 + ATLAS_BAY_DZ)
    k.level = CY
    k.room(halfW: CX, z0: BZ0c, z1: BZ1c, floor: CY, height: CH, panels: 4, floorHole: hole)
    let bi = k.body
    k.rooms += [DeckRoom(x0: -CX + bi, x1: hole.x0, z0: BZ0c + bi, z1: BZ1c - bi, y0: CY, y1: CY),
                DeckRoom(x0: hole.x1, x1: CX - bi, z0: BZ0c + bi, z1: BZ1c - bi, y0: CY, y1: CY),
                DeckRoom(x0: hole.x0 - 0.1, x1: hole.x1 + 0.1, z0: BZ0c + bi, z1: hole.z0, y0: CY, y1: CY),
                DeckRoom(x0: hole.x0 - 0.1, x1: hole.x1 + 0.1, z0: hole.z1, z1: BZ1c - bi, y0: CY, y1: CY)]
    // the shaft down to the belly doors, with hazard trim round the lip
    let doorY = ATLAS_DOOR_Y, hcx = (hole.x0 + hole.x1) / 2, hcz = (hole.z0 + hole.z1) / 2
    for s in [-1.0, 1.0] {
        k.box(D3(0.2, CY - doorY, hole.z1 - hole.z0), D3(s * (hole.x1 + 0.1), (CY + doorY) / 2, hcz), .wall)
        k.box(D3(hole.x1 - hole.x0, CY - doorY, 0.2), D3(hcx, (CY + doorY) / 2, s < 0 ? hole.z0 - 0.1 : hole.z1 + 0.1), .wall)
        k.box(D3(0.6, 0.04, hole.z1 - hole.z0 + 1.2), D3(s * (hole.x1 + 0.3), CY + 0.02, hcz), .orange)
        k.box(D3(hole.x1 - hole.x0 + 1.2, 0.04, 0.6), D3(hcx, CY + 0.02, s < 0 ? hole.z0 - 0.3 : hole.z1 + 0.3), .orange)
    }
    for s in [-1.0, 1.0] { k.led(D3(s * (hole.x1 + 0.62), CY + 0.05, hole.z0 - 0.6), D3(s * (hole.x1 + 0.62), CY + 0.05, hole.z1 + 0.6), 0.08) }
    // two parked rovers and stacks of crates
    for z in [-205.0 + ATLAS_BAY_DZ, -188.0 + ATLAS_BAY_DZ] {
        k.block(-17 - 2.1, -17 + 2.1, z - 3.4, z + 3.4)
    }
    for (x, z0) in [(22.0, -260.0), (22.0, -254.0), (17.0, -260.0), (-23.0, -258.0), (-23.0, -252.0)] {
        let z = z0 + ATLAS_BAY_DZ
        k.box(D3(4, 3, 4), D3(x, CY + 1.5, z), .metal, solid: true)
        k.box(D3(4.05, 0.3, 4.05), D3(x, CY + 2.2, z), .orange)
        if abs(x) > 21.5 { k.box(D3(3.6, 2.6, 3.6), D3(x, CY + 4.3, z), .dark) }
    }
    k.screen(D3(-CX + 0.15, CY + 6, -230 + ATLAS_BAY_DZ), 8, 4, .ship, yaw: .pi / 2)
    // second lift: lounge ↔ cargo bay
    k.level = fy
    let liftC = D3(16, fy, -34), liftD = D3(20, CY, -176 + ATLAS_BAY_DZ)
    liftShaft(&k, liftC, yaw: .pi, height: LH)
    k.level = CY
    liftShaft(&k, liftD, yaw: 0, height: CH)
    k.level = fy
    let deck0 = k.deck(spawn: D3(0, fy, hz + 5), spawnYaw: .pi,
                      helms: [Helm(p: D3(0, bf, 201.6 + dz), r: 1.3, word: "the captain's seat", seat: true),
                              Helm(p: D3(0, fy, hz + 2), r: 4.5, word: "the helm", seat: false)],
                      lifts: [(liftA, liftB), (liftC, liftD)],
                      carves: [(D3(LX, fy, LZ0), D3(130, fy + LH, LZ1)),                   // behind the lounge windows
                               (D3(0, fy - 0.3, LZ0), D3(LX + 0.3, fy + RH + 0.3, RZ1)),  // the decks themselves
                               (D3(0, bf - 0.4, BZ0 - 70), D3(BX + 4, bf + BH + 14, BZ1 + 0.4)),   // the bridge, and its view forward over the bow
                               (D3(0, CY - 0.3, BZ0c - 0.3), D3(CX + 0.3, CY + CH + 0.3, BZ1c + 0.3)), // the cargo bay
                               (D3(0, fy - 0.3, RZ1 - 0.5), D3(4.8, fy + 6.3, LZb + 0.3)),        // hallway and lobby
                               (D3(0, fy, liftB.z - 2.6), D3(2.6, bf + 0.5, liftB.z + 2.6))], u: u)   // the lift shaft
    var deck = deck0
    deck.liftRect = hole
    deck.liftYaws = [(0, 0), (.pi, 0)]
    deck.liftNames = [("the hallway", "the bridge"), ("the lounge", "the cargo bay")]
    return (GPUMesh(device: device, verts: k.b.v), deck)
}

// MARK: - Condor (85 m): crew deck with window walls over the wings, stairs up into the bubble cockpit

func buildCondorInterior(device: MTLDevice, u: Double) -> (GPUMesh, Deck) {
    var k = DeckKit(u: u)
    let fy = -0.6, H = 3.6, X = 6.5, z0 = -10.0, z1 = 16.0, reach = 10.6
    k.level = fy
    let win = (y0: fy + 0.35, y1: fy + 3.25)
    k.room(halfW: X, z0: z0, z1: z1, floor: fy, height: H, window: win, reach: reach, mullion: 2.6, frontDoor: 1.0, backDoor: 1.1, doorH: 3.3, panels: 3)
    k.walk(-X + 0.3, X - 0.3, z0, z1, y0: fy)
    for s in [-1.0, 1.0] { k.box(D3(0.2, 1.2, z1 - z0), D3(s * (reach + 0.5), fy + 0.6, (z0 + z1) / 2), .dark) }   // wing-root fairing below the view
    // deck console against the front wall, left of the stairs
    k.box(D3(3.4, 1.0, 1.0), D3(-4.2, fy + 0.5, z0 + 0.6), .dark, solid: true)
    k.box(D3(3.5, 0.06, 1.1), D3(-4.2, fy + 1.03, z0 + 0.6), .metal)
    k.led(D3(-5.8, fy + 1.08, z0 + 1.12), D3(-2.6, fy + 1.08, z0 + 1.12), 0.04)
    k.screen(D3(-5.0, fy + 1.75, z0 + 0.35), 1.3, 0.8, .radar, tilt: -0.2)
    k.screen(D3(-3.5, fy + 1.75, z0 + 0.35), 1.3, 0.8, .map, tilt: -0.2)
    k.screen(D3(4.2, fy + 2.0, z0 + 0.12), 3.0, 1.5, .shields)
    // lounge: round table with benches mid-deck
    k.b.cylinder(1.0, 0.25, 0.75, D3(0, fy + 0.375, 1.5), .metal, seg: 20)
    k.b.cylinder(1.1, 1.1, 0.06, D3(0, fy + 0.78, 1.5), .dark, seg: 24)
    k.b.cylinder(1.12, 1.12, 0.03, D3(0, fy + 0.8, 1.5), .led, seg: 24, open: true)
    k.post(0, 1.5, 1.1)
    for s in [-1.0, 1.0] {
        k.box(D3(0.7, 0.45, 3.0), D3(s * 2.0, fy + 0.22, 1.5), .orange, solid: true)
        k.box(D3(0.15, 0.6, 3.0), D3(s * 2.35, fy + 0.75, 1.5), .dark)
        k.led(D3(s * 1.64, fy + 0.1, 0.0), D3(s * 1.64, fy + 0.1, 3.0), 0.03)
    }
    // galley counter on the left, bunks on the right (aft half)
    k.box(D3(0.9, 1.0, 5.0), D3(-(X - 0.8), fy + 0.5, 9.5), .metal, solid: true)
    k.box(D3(0.95, 0.06, 5.0), D3(-(X - 0.8), fy + 1.03, 9.5), .dark)
    k.led(D3(-(X - 1.27), fy + 0.95, 7.0), D3(-(X - 1.27), fy + 0.95, 12.0), 0.04)
    for z in [7.8, 11.2] {
        for y in [0.35, 1.45] { k.box(D3(1.0, 0.25, 2.2), D3(X - 0.7, fy + y, z), .wall); k.box(D3(0.9, 0.12, 2.0), D3(X - 0.7, fy + y + 0.18, z), .orange) }
        k.box(D3(1.1, 0.06, 2.4), D3(X - 0.7, fy + 2.4, z), .metal)
        k.led(D3(X - 1.22, fy + 2.36, z - 1.1), D3(X - 1.22, fy + 2.36, z + 1.1), 0.03)
        k.block(X - 1.25, X, z - 1.15, z + 1.15)
    }
    // engine bay aft
    let ez0 = z1, ez1 = 26.0
    k.room(halfW: 3.6, z0: ez0, z1: ez1, floor: fy, height: H, frontDoor: 1.1, doorH: 3.3, panels: 1)
    k.walk(-3.6, 3.6, ez0 - 1.2, ez1, y0: fy)
    k.b.cylinder(1.0, 1.0, 5.0, D3(0, fy + 1.6, 22.5), .disc, rot: D3(.pi / 2, 0, 0), seg: 24)
    for z in [20.5, 22.5, 24.5] { k.b.cylinder(1.35, 1.35, 0.35, D3(0, fy + 1.6, z), .metal, rot: D3(.pi / 2, 0, 0), seg: 24) }
    k.block(-1.5, 1.5, 19.8, ez1)

    // stairs from the front doorway up into the cockpit
    let eye = D3(0, 7.94, -23.1), cf = eye.y - 1.55                        // cockpit floor: standing eye a little above the seated pilot's
    k.stairs(halfW: 1.0, zLow: z0, zHigh: -16.0, yLow: fy, yHigh: cf, ceilingFrom: fy + H)
    // the cockpit floor: a platform under the bubble, on a pedestal down to the hull
    k.level = cf
    let PX = 2.2, PZ0 = -24.4, PZ1 = -16.0
    k.box(D3(2 * PX, cf - 4.2, PZ1 - PZ0), D3(0, (cf + 4.2) / 2, (PZ0 + PZ1) / 2), .wall)
    k.box(D3(2 * PX, 0.1, PZ1 - PZ0), D3(0, cf - 0.05, (PZ0 + PZ1) / 2), .floor)
    for s in [-1.0, 1.0] {
        k.box(D3(0.06, 0.95, PZ1 - PZ0), D3(s * PX, cf + 0.48, (PZ0 + PZ1) / 2), .metal)
        k.led(D3(s * PX, cf + 0.98, PZ0), D3(s * PX, cf + 0.98, PZ1), 0.06)
        k.led(D3(s * (PX - 0.05), cf + 0.02, PZ0), D3(s * (PX - 0.05), cf + 0.02, PZ1), 0.04)
    }
    k.led(D3(-PX, cf + 0.98, PZ0), D3(PX, cf + 0.98, PZ0), 0.06)
    k.seat(D3(0, eye.y - 1.0, eye.z + 0.3))
    k.block(-0.45, 0.45, eye.z - 0.1, eye.z + 0.75)
    k.block(-0.85, 0.85, PZ0, eye.z - 0.3)                 // consoles ahead of the seat
    k.walk(-PX, PX, PZ0, PZ1 + 0.4, y0: cf)
    k.canopyFrame(D3(0, 0.15, -0.5) / u, D3(0.072, 0.058, 0.2) / u, width: 0.09, rings: [0.25, 0.55])

    let deck = k.deck(spawn: D3(0, fy, z0 + 4.5), spawnYaw: 0,
                      helms: [Helm(p: D3(0, cf, eye.z + 1.35), r: 0.9, word: "the pilot's seat", seat: true),
                              Helm(p: D3(-4.2, fy, z0 + 1.9), r: 1.6, word: "the deck console", seat: false)],
                      carves: [(D3(X + 0.3, win.y0 - 0.1, z0), D3(reach + 0.35, win.y1 + 0.1, z1)),         // behind the windows
                               (D3(0, fy - 0.25, z0 - 0.25), D3(X + 0.25, fy + H + 0.25, ez1 + 0.25)),      // crew deck and engine bay
                               (D3(0, fy - 0.25, -16.1), D3(1.15, cf + 3.2, z0 + 0.1)),                     // stairwell
                               (D3(0, 4.2, PZ0 - 0.1), D3(PX + 0.15, 10.0, PZ1 + 0.1))], u: u)             // cockpit platform
    return (GPUMesh(device: device, verts: k.b.v), deck)
}

// MARK: - Kestrel (50 m): compact cabin in the spine, steep stairs up into the fighter cockpit

func buildKestrelInterior(device: MTLDevice, u: Double) -> (GPUMesh, Deck) {
    var k = DeckKit(u: u)
    let fy = 0.8, H = 3.6, X = 4.4, z0 = -1.5, z1 = 10.0
    k.level = fy
    let win = (y0: 2.65, y1: 4.15)
    k.room(halfW: X, z0: z0, z1: z1, floor: fy, height: H, window: win, reach: 8.8, mullion: 2.3, frontDoor: 0.85, doorH: 3.3, panels: 2)
    k.walk(-X, X, z0, z1, y0: fy)
    k.screen(D3(-2.6, fy + 1.9, z0 + 0.1), 2.2, 1.2, .radar)
    k.screen(D3(2.6, fy + 1.9, z0 + 0.1), 2.2, 1.2, .ship)
    for z in [3.0, 5.4] {                                   // bunks
        k.box(D3(1.0, 0.3, 2.2), D3(-(X - 0.6), fy + 0.4, z), .wall)
        k.box(D3(0.9, 0.12, 2.0), D3(-(X - 0.6), fy + 0.6, z), .orange)
        k.led(D3(-(X - 1.12), fy + 0.25, z - 1.0), D3(-(X - 1.12), fy + 0.25, z + 1.0), 0.03)
    }
    k.block(-X, -(X - 1.1), 1.8, 6.6)
    k.box(D3(1.2, 0.06, 1.8), D3(X - 1.3, fy + 0.75, 4.0), .dark)
    k.b.box(D3(1.22, 0.02, 1.82), D3(X - 1.3, fy + 0.72, 4.0) , .led)
    k.box(D3(0.12, 0.72, 0.12), D3(X - 1.3, fy + 0.36, 4.0), .metal)
    k.box(D3(0.6, 0.45, 1.8), D3(X - 0.4, fy + 0.22, 4.0), .orange)
    k.block(X - 1.9, X, 3.1, 4.9)
    for x in [-2.6, -1.3, 1.3, 2.6] { k.box(D3(1.1, 2.2, 0.9), D3(x, fy + 1.1, z1 - 0.55), .dark); k.led(D3(x - 0.45, fy + 1.9, z1 - 1.01), D3(x + 0.45, fy + 1.9, z1 - 1.01), 0.03) }
    k.block(-X, X, z1 - 1.0, z1)

    // stairs up through the spine into the cockpit tub, right under the canopy
    let eye = D3(0, 6.07, -9.3), cf = eye.y - 1.6
    k.stairs(halfW: 0.85, zLow: z0, zHigh: -5.0, yLow: fy, yHigh: cf, headroom: 2.3, ceilingFrom: fy + H)
    k.level = cf
    let PX = 0.95, PZ0 = -9.6, PZ1 = -5.0
    for s in [-1.0, 1.0] {
        k.box(D3(0.12, cf - 0.7 + 0.35, PZ1 - PZ0), D3(s * PX, (cf + 0.35 + 0.7) / 2, (PZ0 + PZ1) / 2), .wall)
        k.led(D3(s * (PX - 0.07), cf + 0.3, PZ0), D3(s * (PX - 0.07), cf + 0.3, PZ1), 0.04)
    }
    k.box(D3(2 * PX, 0.1, PZ1 - PZ0), D3(0, cf - 0.05, (PZ0 + PZ1) / 2), .floor)
    k.box(D3(2 * PX, cf - 0.7, 0.12), D3(0, (cf + 0.7) / 2, PZ0 - 0.06), .wall)
    k.block(-PX, PX, PZ0 - 1, eye.z + 0.15)                // the instrument panel and centre console
    k.walk(-PX, PX, PZ0 + 0.2, PZ1 + 0.4, y0: cf, inset: false)
    k.canopyFrame(D3(0, 0.14, -0.24) / u, D3(0.075, 0.038, 0.17) / u, width: 0.07, rings: [0.35])
    k.rooms[k.rooms.count - 1].x0 = -PX + 0.3; k.rooms[k.rooms.count - 1].x1 = PX - 0.3

    let deck = k.deck(spawn: D3(0, fy, 1.5), spawnYaw: 0,
                      helms: [Helm(p: D3(0, cf, eye.z + 0.65), r: 0.8, word: "the pilot's seat", seat: true)],
                      carves: [(D3(X + 0.3, win.y0 - 0.05, z0), D3(9.5, win.y1 + 0.1, z1)),            // behind the windows
                               (D3(0, fy - 0.25, z0 - 0.25), D3(X + 0.25, fy + H + 0.25, z1 + 0.25)),    // the cabin
                               (D3(0, fy - 0.25, PZ0 - 0.1), D3(1.0, 7.5, z0 + 0.1))], u: u)             // stairs and cockpit tub
    return (GPUMesh(device: device, verts: k.b.v), deck)
}

// MARK: - walking aboard

extension Game {
    func goAboard() {
        guard let d = ship.deck else { sfx?.denied(); say("the \(ship.name) has no room to walk around"); return }
        guard [.fly, .hover, .landed].contains(mode) else { say("wait until the ship is steady"); return }
        // the ship keeps doing what you left her doing: autopilot, afterburner, hover
        // from the cockpit view you stand up right behind the pilot's seat; otherwise you start in the cabin
        if cockpitView, let h = d.helms.first(where: { $0.seat }) {
            aboard = AboardState(on: true, p: h.p, yaw: 0, pitch: -0.1)
        } else {
            aboard = AboardState(on: true, p: d.spawn, yaw: d.spawnYaw, pitch: -0.05)
        }
        cockpitView = false
        sfx?.hatch()
        say(mode == .fly ? "left the controls · the \(ship.name) holds her course" : mode == .hover ? "left the controls · holding the hover" : "walking around the \(ship.name)")
    }
    func leaveAboard(silent: Bool = false, toSeat: Bool = false) {
        guard aboard.on else { return }
        aboard.on = false; keys.removeAll()
        if toSeat { cockpitView = true; lookYaw = 0; lookPitch = 0 }
        if !silent { sfx?.beep(); say(toSeat ? "in the pilot's seat · V for the outside view" : "at the controls") }
    }
    /// the console or seat you're standing at, if any
    var nearHelm: Helm? {
        guard let d = ship.deck, aboard.on else { return nil }
        return d.helms.first { simd_distance(SIMD2(aboard.p.x, aboard.p.z), SIMD2($0.p.x, $0.p.z)) < $0.r && abs(aboard.p.y - $0.p.y) < 1.5 }
    }
    /// the lift pad you're standing on and where it goes
    var nearLift: (from: D3, to: D3)? {
        guard let d = ship.deck, aboard.on else { return nil }
        for l in d.lifts {
            for (a, b) in [(l.a, l.b), (l.b, l.a)] where simd_distance(SIMD2(aboard.p.x, aboard.p.z), SIMD2(a.x, a.z)) < 2.0 && abs(aboard.p.y - a.y) < 1.5 { return (a, b) }
        }
        return nil
    }
    /// standing (or parked) on the cargo lift platform
    var onCargoLift: Bool {
        guard let c = ship.cargo, aboard.on else { return false }
        let p = driving ? rover.p : aboard.p
        return p.x > c.lift.x0 && p.x < c.lift.x1 && p.z > c.lift.z0 && p.z < c.lift.z1 && abs(p.y - (cargoLiftY ?? 0)) < 1.5
    }
    func aboardUse() {
        if driving { exitRover(); return }
        if nearRover { enterRover(); return }
        if onCargoLift {
            if mode == .landed { setLift(!liftWant) } else { sfx?.denied(); say("land first to use the cargo lift") }
            return
        }
        if let h = nearHelm { leaveAboard(toSeat: h.seat); return }
        if let l = nearLift, aboard.lift == nil, let d = ship.deck {
            // step into the car, doors slide shut, ride, doors open at the other end
            let i = d.lifts.firstIndex { simd_distance($0.a, l.from) < 0.01 || simd_distance($0.b, l.from) < 0.01 } ?? 0
            let atA = simd_distance(d.lifts[i].a, l.from) < 0.01
            let ys: (a: Double, b: Double) = i < d.liftYaws.count ? d.liftYaws[i] : (0, 0)
            let names: (a: String, b: String) = i < d.liftNames.count ? d.liftNames[i] : ("the deck", "the deck")
            aboard.liftYaw = atA ? (ys.a, ys.b) : (ys.b, ys.a)
            aboard.liftOffset = aboard.p - l.from; aboard.liftOffset.y = 0
            aboard.liftDest = atA ? names.b : names.a; aboard.liftIndex = i
            aboard.lift = (l.from, l.to, 0)
            sfx?.servo()
            say("lift · \(aboard.liftDest)")
            return
        }
        let words = ship.deck?.helms.map { $0.word } ?? []
        say("walk to \(words.joined(separator: " or ")) · or press I")
    }

    /// walk off the lowered cargo lift onto the planet
    func walkOffLift() {
        guard let W = landedOn else { return }
        let wp = pos + q.act(aboard.p * 0.001), u = simd_normalize(wp - W.pos)
        aboard.on = false; mode = .walk; w.world = W
        w.pos = W.pos + u * surfaceR(W, u)
        var f = q.act(D3(-sin(aboard.yaw), 0, -cos(aboard.yaw))); f -= u * simd_dot(f, u); f = simd_normalize(f)
        w.fwd = f; w.camFwd = f; w.vel = .zero; w.vUp = 0; w.onGround = true; w.pitch = 0.2; w.camPos = camPos
        say("on the ground · \(W.name)")
    }

    /// one frame on foot inside the ship; keys and mouse are the player's, the ship flies on by itself
    func aboardStep(_ dt: Double, keys k: Set<UInt16>, mouse ms: SIMD2<Double>) {
        guard let d = ship.deck else { aboard.on = false; return }
        if driving && rover.inShip {
            keys = k; mouse = ms
            driveDeckStep(dt); mouse = .zero
            if mode == .fly && auto < 0 { let W = nearestWorld(pos); q = slerpShort(q, levelQuat(up: simd_normalize(pos - W.pos)), 1 - exp(-dt * 0.5)).normalized }
            return
        }
        let liftY = cargoLiftY
        aboard.yaw -= ms.x * 0.0025
        aboard.pitch = clampd(aboard.pitch - ms.y * 0.0025, -1.4, 1.4)
        var p = aboard.p
        var moving = false
        if var l = aboard.lift {
            // riding the lift: doors close, the car accelerates away, cruises, slows, and the doors open on arrival
            let ph = liftPhases(l)
            let before = l.t
            l.t += dt
            if before < ph.close && l.t >= ph.close { sfx?.lift() }
            if before < ph.close + ph.travel && l.t >= ph.close + ph.travel { sfx?.arrive(); sfx?.servo() }
            let s = liftProgress(l)
            let car = l.from + (l.to - l.from) * s
            let yaw0 = aboard.liftYaw.from, dyaw = aboard.liftYaw.to - aboard.liftYaw.from
            let rot = simd_quatd(angle: dyaw * s, axis: D3(0, 1, 0))
            p = car + rot.act(aboard.liftOffset)
            aboard.yaw += dyaw * (s - aboard.liftSpin); aboard.liftSpin = s
            _ = yaw0
            aboard.bob = 0.012 * sin(time * 31) * (s > 0.02 && s < 0.98 ? 1 : 0)
            if l.t >= ph.close + ph.travel + ph.open { aboard.lift = nil; aboard.liftSpin = 0; say("\(aboard.liftDest)") } else { aboard.lift = l }
        } else {
            let run = shift
            let speed = run ? 7.5 : 3.2
            let f = D3(-sin(aboard.yaw), 0, -cos(aboard.yaw)), r = D3(cos(aboard.yaw), 0, -sin(aboard.yaw))
            var mv = D3.zero
            if k.contains(Key.w) || k.contains(Key.up) { mv += f }
            if k.contains(Key.s) || k.contains(Key.down) { mv -= f }
            if k.contains(Key.d) || k.contains(Key.right) { mv += r }
            if k.contains(Key.a) || k.contains(Key.left) { mv -= r }
            moving = simd_length(mv) > 0
            if moving { mv = simd_normalize(mv) * speed * dt }
            let ref = aboard.onFloor ? p.y : p.y + 0.6
            if let fl = d.floor(p.x + mv.x, p.z + mv.z, near: ref, liftY: liftY) { p.x += mv.x; p.z += mv.z; if aboard.onFloor { p.y = fl } }
            else if moving && cargoOpen && onCargoLift { p.x += mv.x; p.z += mv.z; aboard.p = p; walkOffLift(); return }   // step off the lowered lift
            else if let fl = d.floor(p.x + mv.x, p.z, near: ref, liftY: liftY) { p.x += mv.x; if aboard.onFloor { p.y = fl } }
            else if let fl = d.floor(p.x, p.z + mv.z, near: ref, liftY: liftY) { p.z += mv.z; if aboard.onFloor { p.y = fl } }
            // jump in the ship's artificial gravity
            if k.contains(Key.space) && aboard.onFloor { aboard.vy = 3.6; aboard.onFloor = false; sfx?.step(0.5, air: true) }
            if !aboard.onFloor {
                aboard.vy -= 9.8 * dt; p.y += aboard.vy * dt
                let fl = d.floor(p.x, p.z, near: p.y, liftY: liftY) ?? d.anyFloor(p.x, p.z) ?? p.y
                if p.y <= fl { p.y = fl; aboard.vy = 0; aboard.onFloor = true; sfx?.step(0.6, air: true) }
            }
            if moving && aboard.onFloor {
                aboard.stepPhase += dt * (run ? 2.6 : 1.8) * .pi
                let n = Int(aboard.stepPhase / .pi)
                if n != aboard.lastStep { aboard.lastStep = n; sfx?.step(run ? 0.7 : 0.45, air: true) }
            }
            aboard.bob = damp(aboard.bob, moving && aboard.onFloor ? abs(sin(aboard.stepPhase)) * (run ? 0.07 : 0.04) : 0, 10, dt)
        }
        aboard.p = p
        // without a pilot the ship eases level so she doesn't fly into the ground
        if mode == .fly && auto < 0 {
            let W = nearestWorld(pos), up = simd_normalize(pos - W.pos)
            q = slerpShort(q, levelQuat(up: up), 1 - exp(-dt * 0.5)).normalized
        }
        // first-person camera
        let eye = D3(p.x, p.y + 1.7 + aboard.bob, p.z)
        camPos = pos + q.act(eye * 0.001)
        camQ = q * simd_quatd(angle: aboard.yaw, axis: D3(0, 1, 0)) * simd_quatd(angle: aboard.pitch, axis: D3(1, 0, 0))
        fov = damp(fov, 74, 3, dt)
    }
}


// MARK: - lift cars

let LIFT_HALF = 1.8, LIFT_H = 3.4, LIFT_DOOR = 1.15      // metres: half-width of the car, its height, half-width of the doorway

/// the frame a lift car parks in: a portal round the doorway, corner columns, a lit header and a status screen
func liftShaft(_ k: inout DeckKit, _ at: D3, yaw: Double, height: Double) {
    let r = simd_quatd(angle: yaw, axis: D3(0, 1, 0))
    func P(_ x: Double, _ y: Double, _ z: Double) -> D3 { at + r.act(D3(x, y, z)) }
    let h = LIFT_HALF + 0.25, top = LIFT_H + 0.5
    for (x, z) in [(-h, -h), (h, -h), (-h, h), (h, h)] {
        k.b.box(D3(0.3, top, 0.3), P(x, top / 2, z), .metal)
        k.led(P(x * 0.97, 0.1, z * 0.97 - 0.16), P(x * 0.97, top - 0.1, z * 0.97 - 0.16), 0.04)
    }
    // the shaft column above the car, up to the ceiling
    if height > top + 0.3 {
        let sh = height - top
        k.b.box(D3(2 * h + 0.3, sh, 2 * h + 0.3), P(0, top + sh / 2, 0), .wall)
        var y = top + 1.0; while y < height - 0.5 { k.led(P(-h - 0.16, y, -h - 0.16), P(h + 0.16, y, -h - 0.16), 0.05); y += 2.5 }
    }
    k.b.box(D3(2 * h + 0.3, 0.4, 0.3), P(0, top, -h), .metal)                       // header over the doorway
    k.led(P(-LIFT_DOOR, top - 0.25, -h - 0.16), P(LIFT_DOOR, top - 0.25, -h - 0.16), 0.08)
    k.screen(P(LIFT_DOOR + 0.55, 1.6, -h - 0.17), 0.45, 0.6, .map, yaw: yaw + .pi)
    // collision: the car's back and side walls (you walk in through the doors)
    let wallPts = [(P(-h, 0, h), P(h, 0, h)), (P(-h, 0, -h), P(-h, 0, h)), (P(h, 0, -h), P(h, 0, h))]
    for (a, b) in wallPts { k.block(min(a.x, b.x) - 0.15, max(a.x, b.x) + 0.15, min(a.z, b.z) - 0.15, max(a.z, b.z) + 0.15) }
    for sx in [-1.0, 1.0] {
        let a = P(sx * LIFT_DOOR, 0, -h), b = P(sx * h, 0, -h)
        k.block(min(a.x, b.x) - 0.02, max(a.x, b.x) + 0.02, min(a.z, b.z) - 0.15, max(a.z, b.z) + 0.15)
    }
}

/// the car itself, in deck metres (scaled to model units by u), doors facing -z; and one door panel
func buildLiftCar(device: MTLDevice, u: Double) -> (car: GPUMesh, door: GPUMesh) {
    var k = DeckKit(u: u)
    let h = LIFT_HALF, H = LIFT_H, t = 0.08
    k.box(D3(2 * h, 0.12, 2 * h), D3(0, -0.06, 0), .floor)
    k.b.cylinder(h * 0.7, h * 0.7, 0.02, D3(0, 0.01, 0), .led, seg: 40, open: true)
    k.box(D3(2 * h, 0.12, 2 * h), D3(0, H + 0.06, 0), .wall)
    k.box(D3(1.4, 0.03, 1.4), D3(0, H - 0.02, 0), .lamp)
    k.led(D3(-h + 0.05, H - 0.04, -h + 0.05), D3(h - 0.05, H - 0.04, -h + 0.05), 0.04)
    k.led(D3(-h + 0.05, H - 0.04, h - 0.05), D3(h - 0.05, H - 0.04, h - 0.05), 0.04)
    // back and side walls: a dark lower panel, a window band onto the shaft, an upper panel
    let band0 = 1.0, band1 = 2.45
    for (c, size) in [(D3(0, 0, h - t / 2), D3(2 * h, 0, t)), (D3(-h + t / 2, 0, 0), D3(t, 0, 2 * h)), (D3(h - t / 2, 0, 0), D3(t, 0, 2 * h))] {
        k.box(D3(size.x, band0, size.z), D3(c.x, band0 / 2, c.z), .wall)
        k.box(D3(size.x, H - band1, size.z), D3(c.x, (band1 + H) / 2, c.z), .wall)
        let inset = D3(c.x == 0 ? 0 : -c.x / abs(c.x) * 0.01, 0, c.z == 0 ? 0 : -c.z / abs(c.z) * 0.01)
        k.box(D3(max(size.x - 0.02, 0.02), band1 - band0, max(size.z - 0.02, 0.02)), D3(c.x, (band0 + band1) / 2, c.z) + inset, .shaft)
    }
    // front wall either side of the doorway, and above it
    for sx in [-1.0, 1.0] { k.box(D3(h - LIFT_DOOR, H, t), D3(sx * (h + LIFT_DOOR) / 2, H / 2, -h + t / 2), .wall) }
    k.box(D3(2 * LIFT_DOOR, H - 2.9, t), D3(0, 2.9 + (H - 2.9) / 2, -h + t / 2), .wall)
    for sx in [-1.0, 1.0] { k.led(D3(sx * LIFT_DOOR, 0.02, -h + 0.1), D3(sx * LIFT_DOOR, 2.9, -h + 0.1), 0.05) }
    k.led(D3(-LIFT_DOOR, 2.9, -h + 0.1), D3(LIFT_DOOR, 2.9, -h + 0.1), 0.05)
    // handrails with LED under-glow, a control panel by the door
    for (a, b) in [(D3(-h + 0.2, 0.95, h - 0.2), D3(h - 0.2, 0.95, h - 0.2)), (D3(-h + 0.2, 0.95, -h + 0.5), D3(-h + 0.2, 0.95, h - 0.2)), (D3(h - 0.2, 0.95, -h + 0.5), D3(h - 0.2, 0.95, h - 0.2))] {
        k.beam(a, b, 0.06, .metal); k.led(a - D3(0, 0.06, 0), b - D3(0, 0.06, 0), 0.025)
    }
    k.box(D3(0.5, 0.9, 0.08), D3(h - 0.45, 1.35, -h + 0.13), .dark)
    k.screen(D3(h - 0.45, 1.5, -h + 0.18), 0.4, 0.3, .readout)
    for i in 0..<3 { k.box(D3(0.09, 0.09, 0.03), D3(h - 0.58 + Double(i) * 0.13, 1.1, -h + 0.18), i == 1 ? .orange : .led) }
    var d = DeckKit(u: u)
    d.box(D3(LIFT_DOOR, 2.88, 0.06), D3(0, 1.44, 0), .metal)
    d.box(D3(LIFT_DOOR - 0.12, 1.6, 0.02), D3(0, 1.3, -0.035), .wall)
    d.led(D3(LIFT_DOOR / 2 - 0.02, 0.05, -0.04), D3(LIFT_DOOR / 2 - 0.02, 2.8, -0.04), 0.03)
    return (GPUMesh(device: device, verts: k.b.v), GPUMesh(device: device, verts: d.b.v))
}

extension Game {
    /// door-closing, travel and door-opening times for a ride
    func liftPhases(_ l: (from: D3, to: D3, t: Double)) -> (close: Double, travel: Double, open: Double) {
        (1.0, 2.5 + simd_distance(l.from, l.to) / 55, 1.0)
    }
    /// how far along the ride the car is (0…1), with smooth acceleration and braking
    func liftProgress(_ l: (from: D3, to: D3, t: Double)) -> Double {
        let ph = liftPhases(l)
        let x = clampd((l.t - ph.close) / ph.travel, 0, 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    /// what the renderer needs: every car (station or riding) with its door opening, and how fast the shaft is passing
    func liftCars() -> [(p: D3, yaw: Double, door: Double, moving: Double, run: Double)] {
        guard let d = ship.deck else { return [] }
        var out: [(p: D3, yaw: Double, door: Double, moving: Double, run: Double)] = []
        let riding = aboard.on ? aboard.lift : nil
        for (i, l) in d.lifts.enumerated() {
            let ys: (a: Double, b: Double) = i < d.liftYaws.count ? d.liftYaws[i] : (0, 0)
            if let r = riding, i == aboard.liftIndex {
                let ph = liftPhases(r), s = liftProgress(r)
                let door = r.t < ph.close ? 1 - r.t / ph.close : (r.t > ph.close + ph.travel ? (r.t - ph.close - ph.travel) / ph.open : 0)
                let x = clampd((r.t - ph.close) / ph.travel, 0, 1)
                let speed = 30 * x * x * (1 - x) * (1 - x) * simd_distance(r.from, r.to) / ph.travel   // m/s along the shaft
                let p = r.from + (r.to - r.from) * s
                out.append((p, aboard.liftYaw.from + (aboard.liftYaw.to - aboard.liftYaw.from) * s, clampd(door, 0, 1), speed, s * simd_distance(r.from, r.to)))
                continue
            }
            out.append((l.a, ys.a, 1, 0, 0)); out.append((l.b, ys.b, 1, 0, 0))
        }
        return out
    }
}
