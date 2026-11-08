import Foundation
import Metal
import simd

// The emergency tanker: press F when the tank is low and a fuel tanker flies out to you wherever you are, matches
// your speed, runs a glowing fuel line across and fills you up, then peels away. An original design: a stubby
// cockpit pod on a long twin-tank body with a refuelling boom, hazard stripes and blue drive pods.

struct TankerState {
    var active = false
    var phase = 0                  // 0 flying in, 1 refuelling, 2 leaving
    var rel = D3.zero              // position relative to your ship (km, world axes)
    var startRel = D3.zero
    var t = 0.0
    var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var line = 0.0                 // how far the fuel line has reached across (0…1)
    var thrust = 0.0
}

let TANKER_LENGTH = 0.034          // km

/// tanker mesh in metres, nose toward -z, boom pointing down-left from the belly
func buildTankerMesh(device: MTLDevice) -> (mesh: GPUMesh, boomTip: D3, engines: [D3], lights: [(D3, SIMD3<Float>)]) {
    var b = MeshBuilder()
    // twin fuel tanks
    for s in [-1.0, 1.0] {
        b.cylinder(2.4, 2.4, 22, D3(s * 2.6, 0, 2), .metal, rot: D3(.pi / 2, 0, 0), seg: 20)
        b.sphere(2.4, D3(s * 2.6, 0, -9), .metal, seg: 16, rings: 8)
        b.sphere(2.4, D3(s * 2.6, 0, 13), .metal, seg: 16, rings: 8)
        for z in [-4.0, 3.0, 10.0] { b.cylinder(2.5, 2.5, 0.8, D3(s * 2.6, 0, z), .orange, rot: D3(.pi / 2, 0, 0), seg: 20) }
    }
    // spine joining the tanks, cockpit pod at the nose
    b.box(D3(3.2, 2.2, 24), D3(0, 1.6, 1.5), .dark)
    b.box(D3(4.6, 2.6, 6), D3(0, 1.4, -12.5), .metal)
    b.octahedron(1, scale: D3(1.8, 1.1, 3.0), D3(0, 2.6, -13.5), .glass)
    b.box(D3(3.4, 0.25, 0.3), D3(0, 2.95, -10.0), .cyan)
    // stubby wings with drive pods
    b.box(D3(15, 0.5, 4.5), D3(0, 0.6, 9), .dark)
    var engines: [D3] = []
    for s in [-1.0, 1.0] {
        b.cylinder(1.3, 1.3, 6, D3(s * 7.6, 0.6, 9.5), .metal, rot: D3(.pi / 2, 0, 0), seg: 14)
        b.disc(1.1, D3(s * 7.6, 0.6, 12.55), .disc, seg: 14)
        engines.append(D3(s * 7.6, 0.6, 12.6))
    }
    // refuelling boom: a long arm folded out from the belly, with a lit nozzle
    b.box(D3(0.6, 0.6, 9), D3(-1.5, -2.6, 2), .orange, rot: D3(0, 0.35, 0.5))
    let boomTip = D3(-4.0, -4.6, -2.0)
    b.sphere(0.55, boomTip, .cyan, seg: 10, rings: 6)
    let lights: [(D3, SIMD3<Float>)] = [(D3(-8.9, 0.6, 9), SIMD3(1, 0.23, 0.23)), (D3(8.9, 0.6, 9), SIMD3(0.23, 1, 0.48)),
                                        (D3(0, 3.2, 13), SIMD3(1, 0.6, 0.15)), (D3(0, -1.2, -12), SIMD3(1, 1, 1))]
    return (GPUMesh(device: device, verts: b.v), boomTip, engines, lights)
}

extension Game {
    /// press F: call the emergency tanker
    func callTanker() {
        if tanker.active { say(tanker.phase == 0 ? "tanker inbound" : tanker.phase == 1 ? "refuelling in progress" : "tanker departing"); return }
        if fuel > 0.6 { sfx?.denied(); say("tank is \(Int(fuel * 100))% · the emergency tanker comes out below 60%"); return }
        if mode == .title { return }
        let W = nearestWorld(pos), up = simd_normalize(pos - W.pos)
        let side = simd_normalize(simd_cross(forward, up))
        // it comes in from behind and above
        let start = (-forward * 6 + up * 2.5 + side * 1.5) * max(1, size / 0.05)
        tanker = TankerState(active: true, phase: 0, rel: start, startRel: start, t: 0, q: q, line: 0, thrust: 1)
        sfx?.beep()
        say("emergency tanker dispatched · arriving in about 20 s")
    }
    /// where the tanker holds station beside you while it refuels (relative to your ship, km)
    func tankerStation() -> D3 {
        let W = nearestWorld(pos), up = simd_normalize(pos - W.pos)
        let base = mode == .fly ? q : levelQuat(up: up)
        let s = size / ship.length
        // above and to the right, clear of the hull
        return base.act(D3(ship.length * 0.45 * s + 0.012, ship.length * 0.22 * s + 0.012, ship.length * 0.05 * s))
    }
    func tankerStep(_ dt: Double) {
        guard tanker.active else { return }
        tanker.t += dt
        let station = tankerStation()
        let W = nearestWorld(pos), up = simd_normalize(pos - W.pos)
        let face = mode == .fly ? q : levelQuat(up: up)
        switch tanker.phase {
        case 0:   // fly in along a smooth curve, slowing as it closes
            let f = min(1, tanker.t / 20), e = 1 - pow(1 - f, 3)
            tanker.rel = tanker.startRel + (station - tanker.startRel) * e
            tanker.thrust = 1 - e * 0.8
            tanker.q = slerpShort(tanker.q, face, 1 - exp(-dt * 1.5))
            if f >= 1 { tanker.phase = 1; tanker.t = 0; sfx?.thud(); say("tanker in position · fuel line connected") }
        case 1:   // hold station, run the line across, pump
            tanker.rel = station + up * sin(time * 0.9) * 0.0004
            tanker.q = slerpShort(tanker.q, face, 1 - exp(-dt * 3))
            tanker.thrust = 0.2
            tanker.line = min(1, tanker.line + dt / 1.5)
            if tanker.line >= 1 {
                let lvl0 = Int(fuel * 10)
                fuel = min(1, fuel + 0.12 * dt)
                if Int(fuel * 10) != lvl0 { sfx?.tick(Int(fuel * 10)) }
                if fuel >= 1 { tanker.phase = 2; tanker.t = 0; tanker.startRel = tanker.rel; sfx?.full(); say("tank full · tanker breaking away") }
            }
        default:  // break away up and out, then gone
            tanker.line = max(0, tanker.line - dt / 0.8)
            let a = tanker.t * tanker.t * 0.6 * max(1, size / 0.05)
            let side = simd_normalize(simd_cross(face.act(D3(0, 0, -1)), up))
            tanker.rel = tanker.startRel + (up * 0.5 + side * 0.4 - face.act(D3(0, 0, -1)) * 0.2) * a
            tanker.thrust = 1
            if tanker.t > 9 { tanker.active = false }
        }
    }
}
