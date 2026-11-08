import Foundation
import Metal
import simd

// Fuel and refuelling depots. Each world has a handful of depots: a raised landing pad big enough for the
// Condor, fuel tanks, a control building and a beacon mast. Land on a pad and the tank refills.

let PAD_RADIUS = 0.058            // km: the usable pad surface
private let depotNames = [["Kepler", "Halden", "Marrow", "Vesta", "Corran", "Tamsin"],
                          ["Ash Gate", "Cinder", "Red Hollow", "Basalt", "Ferrum", "Dune Nine"],
                          ["Lumen", "Tidewater", "Sorrel", "Glasswing", "Verd Point", "Halcyon"]]

struct Depot {
    let name: String
    let world: World
    let dir: D3            // direction from the planet centre
    let padR: Double       // radius of the pad's top surface from the planet centre (km)
    let yaw: Double
    var pos: D3 { world.pos + dir * padR }
}

/// deterministic placement on fairly flat land, away from discovery sites
func makeDepots(worlds: [World], sites: [Site]) -> [Depot] {
    var out: [Depot] = []
    for (wi, w) in worlds.enumerated() {
        let rnd = Mulberry(UInt32(1700 + wi))
        var n = 0, tries = 0
        while n < 6 && tries < 40000 {
            tries += 1
            let d = simd_normalize(D3(rnd.next() * 2 - 1, rnd.next() * 2 - 1, rnd.next() * 2 - 1))
            let yaw = rnd.next() * .pi * 2
            if abs(d.y) > 0.8 { continue }
            let e = w.height(d.x, d.y, d.z, 12)
            if w.sea && e < 0.4 { continue }
            if out.contains(where: { $0.world === w && simd_distance($0.dir, d) * w.R < w.R * 0.25 }) { continue }   // spread them out
            if sites.contains(where: { $0.world === w && simd_distance($0.dir, d) * w.R < 2 }) { continue }
            // the pad stands just above the highest ground under it; skip rough spots
            var a = simd_cross(d, D3(0, 1, 0)); a = simd_normalize(a); let b = simd_cross(d, a)
            var hi = -1e9, lo = 1e9
            for k in 0..<12 {
                let t = Double(k) / 12 * .pi * 2
                for rr in [0.0, PAD_RADIUS * 0.6, PAD_RADIUS * 1.1] {
                    let g = w.groundRadius(simd_normalize(d + (a * cos(t) + b * sin(t)) * (rr / w.R)))
                    hi = max(hi, g); lo = min(lo, g)
                }
            }
            if hi - lo > 0.03 { continue }
            out.append(Depot(name: depotNames[wi % 3][n] + " Depot", world: w, dir: d, padR: hi + 0.003, yaw: yaw))
            n += 1
        }
    }
    return out
}

/// the depot model in metres, origin at the centre of the pad's top surface
func buildDepotMesh(device: MTLDevice) -> (mesh: GPUMesh, lights: [D3], beacon: D3) {
    var b = MeshBuilder()
    let R = PAD_RADIUS * 1000
    // pad: deck, rim, markings
    b.cylinder(R, R, 2.4, D3(0, -1.2, 0), .metal, seg: 48)
    b.cylinder(R + 0.6, R + 0.6, 1.0, D3(0, -0.3, 0), .dark, seg: 48, open: true)
    for k in 0..<28 {                                       // dashed orange ring
        let a = Double(k) / 28 * .pi * 2
        b.box(D3(6, 0.1, 1.0), D3(cos(a) * R * 0.72, 0.06, sin(a) * R * 0.72), .orange, rot: D3(0, -a + .pi / 2, 0))
    }
    b.box(D3(2.2, 0.1, 22), D3(-7, 0.07, 0), .cyan); b.box(D3(2.2, 0.1, 22), D3(7, 0.07, 0), .cyan); b.box(D3(14, 0.1, 2.2), D3(0, 0.07, 0), .cyan)   // "H"
    // supports down into the ground
    for k in 0..<10 {
        let a = Double(k) / 10 * .pi * 2
        b.cylinder(2.4, 2.6, 70, D3(cos(a) * R * 0.78, -37, sin(a) * R * 0.78), .dark, seg: 10)
    }
    b.cylinder(9, 11, 70, D3(0, -37, 0), .dark, seg: 16)
    // fuel tanks in a row beside the pad, with pipes
    for z in [-26.0, 0, 26] {
        b.cylinder(10, 10, 80, D3(R + 40, -18, z), .metal, seg: 24)
        b.octahedron(1, scale: D3(10, 5, 10), D3(R + 40, 22, z), .metal)
        b.box(D3(1.2, 82, 1.2), D3(R + 40 - 10.3, -18, z), .orange)            // stripe
        b.box(D3(34, 1.6, 1.6), D3(R + 18, -3, z), .dark)                        // pipe to the pad
    }
    // control building with a lit window band, and a walkway onto the pad
    b.box(D3(30, 70, 20), D3(-(R + 32), -26, 24), .dark)
    b.box(D3(30.4, 2, 20.4), D3(-(R + 32), 4, 24), .cyan)
    b.box(D3(30, 1, 14), D3(-(R + 32), 9.5, 24), .metal)
    b.box(D3(22, 1.2, 6), D3(-(R + 8), -0.6, 24), .metal)
    // beacon mast
    let mast = D3(-(R + 22), 0, -36)
    b.cylinder(1.3, 1.8, 110, mast + D3(0, 5, 0), .dark, seg: 8)
    b.box(D3(3, 3, 3), mast + D3(0, 60, 0), .orange)
    var lights: [D3] = []
    for k in 0..<20 { let a = Double(k) / 20 * .pi * 2; lights.append(D3(cos(a) * (R + 0.4), 0.5, sin(a) * (R + 0.4))) }
    return (GPUMesh(device: device, verts: b.v), lights, mast + D3(0, 62, 0))
}

extension Game {
    static let refuelRate = 0.08            // tank fraction per second on the pad

    /// the surface a ship or explorer stands on: the terrain, or a depot pad where there is one
    func surfaceR(_ W: World, _ dir: D3) -> Double {
        var r = W.groundRadius(dir)
        for dp in depots where dp.world === W {
            if simd_length_squared(dir - dp.dir) * W.R * W.R < PAD_RADIUS * PAD_RADIUS { r = max(r, dp.padR) }
        }
        return r
    }
    /// how deep the sea is at this spot (km), 0 on land or on a depot pad
    func waterDepth(_ W: World, _ dir: D3) -> Double {
        guard W.sea else { return 0 }
        let e = W.height(dir.x, dir.y, dir.z, 12)
        if e >= 0 || surfaceR(W, dir) > W.R + 1e-6 { return 0 }
        return -e
    }
    /// index of the depot whose pad the ship is sitting on
    func depotUnderShip() -> Int? {
        guard let W = landedOn else { return nil }
        let d = simd_normalize(pos - W.pos)
        // ships too big for a pad refuel when parked close beside a depot
        let reach = max(PAD_RADIUS, size * 0.8)
        return depots.firstIndex { $0.world === W && simd_length(d - $0.dir) * W.R < reach }
    }
    func nearestDepot(to p: D3) -> (Depot, Double)? {
        depots.map { ($0, simd_distance($0.pos, p)) }.min { $0.1 < $1.1 }
    }

    /// fuel use per second as a fraction of the tank
    func updateFuel(_ dt: Double) {
        let eff = ship.fuelEff
        var burn = 0.0
        switch mode {
        case .fly: burn = 0.0003 + pow(throttle, 1.5) * 0.0012 + abLevel * 0.0045
        case .hover: burn = 0.0011 + min(1, simd_length(hv) / (0.045 * size / 0.05)) * 0.0006
        case .landing, .takeoff: burn = 0.0012
        case .walk: burn = sh.active ? 0.001 : (parkedHover ? 0.0008 : 0)
        default: burn = 0
        }
        if !power { burn = 0 }
        let before = fuel
        fuel = max(0, fuel - burn * eff * dt)
        if before > 0.2 && fuel <= 0.2 { sfx?.denied(); say("fuel low · 20% · find a depot (cyan markers) or press F for a tanker") }
        if before > 0.05 && fuel <= 0.05 { sfx?.denied(); say("fuel critical · 5% · press F for the emergency tanker") }
        if before > 0 && fuel <= 0 { sfx?.powerDown(); setBurner(false); auto = -1; say("out of fuel · engines dead · press F for the emergency tanker") }
        // refuel on a depot pad
        if mode == .landed, let i = dockedAt, fuel < 1 {
            let lvl0 = Int(fuel * 10)
            fuel = min(1, fuel + Game.refuelRate * dt)
            if Int(fuel * 10) != lvl0 { sfx?.tick(Int(fuel * 10)) }
            if fuel >= 1 { sfx?.full(); say("\(depots[i].name) · tank full") }
        }
    }
    /// called when the ship touches down
    func checkDock() {
        dockedAt = depotUnderShip()
        if let i = dockedAt { sfx?.beep(); say(fuel < 0.999 ? "docked at \(depots[i].name) · refuelling" : "docked at \(depots[i].name) · tank already full") }
    }
}
