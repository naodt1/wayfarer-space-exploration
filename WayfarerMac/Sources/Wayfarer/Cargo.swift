import Foundation
import Metal
import simd

// The Atlas cargo bay and its rover. The bay sits low in the belly. When the ship lands, two belly doors slide
// apart and a big lift platform lowers to the ground; drive the rover (or walk) onto it, ride it down, and off
// you go across the planet. Come back onto the lowered platform and you're aboard again.
//
// Bay coordinates are deck metres (x right, y up, z aft from the hull centre), like the rest of the interior.

struct CargoBay {
    var floorY: Double                                    // bay floor
    var doorY: Double                                     // belly skin the doors sit in
    var lift: (x0: Double, x1: Double, z0: Double, z1: Double)   // the platform (= the hole in the floor)
    var roverStart: D3, roverYaw: Double
}

struct Rover {
    var inShip = true
    var p = D3.zero, yaw = 0.0                            // in the ship: deck metres
    var wpos = D3.zero, wfwd = D3(1, 0, 0), wup = D3(0, 1, 0)   // on a planet: world km, heading, ground normal
    var world: World? = nil
    var speed = 0.0                                       // m/s
    var camYaw = 0.0, camPitch = 0.28
    var wheel = 0.0                                       // wheel spin angle
    var steerVis = 0.0, roll = 0.0, pitch = 0.0, accel = 0.0   // how the body and front wheels look (lean, nose dip)
    var susp = [Double](repeating: 0, count: 8)           // each wheel's suspension travel (m)
}

let ROVER_HALF = (w: 1.5, l: 4.05)                        // metres: the cargo truck (Jungle Jim, CC BY 4.0)

/// the truck's wheel layout (Tools/blender/prep_truck.py)
struct TruckLayout {
    let wheels: [D3]; let radius: Double
    static let shared: TruckLayout = {
        if let u = assetsURL()?.appendingPathComponent("Props/truck_wheels.json"), let d = try? Data(contentsOf: u),
           let js = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let w = js["wheels"] as? [[Double]] {
            return TruckLayout(wheels: w.map { D3($0[0], $0[1], $0[2]) }, radius: js["radius"] as? Double ?? 0.63)
        }
        return TruckLayout(wheels: [], radius: 0.63)
    }()
}

/// the rover, in metres: nose toward -z, wheels on y = 0
func buildRoverMesh(into b: inout MeshBuilder, at c: D3 = .zero, yaw: Double = 0) {
    let save = b.xform
    b.xform = b.xform * translate(c) * eulerXYZ(D3(0, yaw, 0))
    b.box(D3(3.4, 0.9, 6.2), D3(0, 1.35, 0), .dark)                       // chassis
    b.box(D3(3.6, 0.25, 6.4), D3(0, 1.85, 0), .orange)                     // deck rim
    b.box(D3(3.0, 1.3, 2.6), D3(0, 2.6, -0.9), .metal)                     // cab
    b.box(D3(2.7, 0.8, 0.12), D3(0, 2.75, -2.22), .glass)                  // windscreen
    for s in [-1.0, 1.0] { b.box(D3(0.12, 0.7, 2.0), D3(s * 1.51, 2.75, -0.9), .glass) }
    b.box(D3(3.1, 0.12, 2.8), D3(0, 3.3, -0.9), .dark)                     // roof
    for s in [-1.0, 1.0] {                                                 // roll bars over the cargo deck
        b.box(D3(0.12, 1.1, 0.12), D3(s * 1.5, 2.45, 1.4), .metal)
        b.box(D3(0.12, 1.1, 0.12), D3(s * 1.5, 2.45, 2.8), .metal)
        b.box(D3(0.12, 0.12, 1.5), D3(s * 1.5, 3.0, 2.1), .metal)
    }
    b.box(D3(3.1, 0.12, 0.12), D3(0, 3.0, 2.8), .metal)
    b.box(D3(2.6, 0.6, 1.4), D3(0, 2.2, 2.1), .wall)                       // cargo box
    for s in [-1.0, 1.0] { for z in [-2.3, 0.0, 2.3] {                    // six wheels
        b.cylinder(0.78, 0.78, 0.62, D3(s * 1.95, 0.78, z), .dark, rot: D3(0, 0, .pi / 2), seg: 16)
        b.cylinder(0.42, 0.42, 0.66, D3(s * 1.95, 0.78, z), .metal, rot: D3(0, 0, .pi / 2), seg: 10)
    } }
    for s in [-1.0, 1.0] {
        b.box(D3(0.5, 0.22, 0.1), D3(s * 1.1, 1.6, -3.12), .lamp)          // headlights
        b.box(D3(0.4, 0.18, 0.1), D3(s * 1.3, 1.6, 3.12), .orange)         // tail lights
        b.box(D3(0.06, 0.06, 5.6), D3(s * 1.72, 1.86, 0), .cyan)
    }
    b.cylinder(0.04, 0.04, 1.4, D3(1.2, 4.0, 1.0), .metal, seg: 6)         // antenna
    b.xform = save
}

extension Game {
    // MARK: door and lift
    var cargoLiftY: Double? {   // the platform's floor height in deck metres, nil if the ship has no bay
        guard let c = ship.cargo else { return nil }
        return c.floorY + (cargoGround - c.floorY) * liftK
    }
    var cargoOpen: Bool { ship.cargo != nil && liftK > 0.985 }

    /// the belly doors (O, and automatically on landing); closing also brings the lift up first
    func setCargoDoor(_ open: Bool) {
        guard ship.cargo != nil else { return }
        if open && mode != .landed && mode != .walk { return }
        if open != cargoWant {
            cargoWant = open; sfx?.servo()
            if !open { liftWant = false }
            say(open ? "cargo doors opening · drive or walk onto the lift" : "cargo bay closing")
        }
    }
    /// send the lift down (or up)
    func setLift(_ down: Bool) {
        guard ship.cargo != nil else { return }
        if down && !cargoWant { setCargoDoor(true) }
        if down != liftWant { liftWant = down; liftDwell = 0; sfx?.lift(); say(down ? "cargo lift going down" : "cargo lift going up") }
    }

    /// doors first, then the lift (reversed when closing); the lift tracks the ground under it, and works like an
    /// elevator: stand (or park) on it for a moment at either end and it takes you to the other
    func cargoStep(_ dt: Double) {
        guard let c = ship.cargo else { doorK = 0; liftK = 0; return }
        if rover.inShip && rover.p == .zero { rover.p = c.roverStart; rover.yaw = c.roverYaw }
        let landed = mode == .landed || mode == .walk
        if !landed { cargoWant = false; liftWant = false }
        if landed, let W = landedOn {
            let cx = (c.lift.x0 + c.lift.x1) / 2, cz = (c.lift.z0 + c.lift.z1) / 2
            let pc = pos + q.act(D3(cx, 0, cz) * 0.001), dir = simd_normalize(pc - W.pos)
            cargoGround = -(simd_distance(pc, W.pos) - surfaceR(W, dir)) * 1000 + 0.35
        }
        let prevY = cargoLiftY ?? 0
        let span = max(10, abs(cargoGround - c.floorY))
        if cargoWant { doorK = min(1, doorK + dt / 3) } else if liftK <= 0 { doorK = max(0, doorK - dt / 3) }
        if liftWant && doorK >= 1 { liftK = min(1, liftK + dt * 9 / span) } else if !liftWant { liftK = max(0, liftK - dt * 9 / span) }
        // anything standing on the platform rides it
        let ly = cargoLiftY ?? 0
        func onLift(_ p: D3) -> Bool { p.x > c.lift.x0 && p.x < c.lift.x1 && p.z > c.lift.z0 && p.z < c.lift.z1 && abs(p.y - prevY) < 1.5 }
        let roverOn = rover.inShip && onLift(rover.p), youOn = aboard.on && onLift(aboard.p)
        if roverOn { rover.p.y = ly }
        if youOn { aboard.p.y = ly }
        // elevator: someone waiting at either end for a moment → go to the other end
        let atEnd = liftK <= 0 || liftK >= 1
        if cargoWant && doorK >= 1 && atEnd && (youOn || (driving && roverOn)) && abs(driving ? rover.speed : 0) < 0.5 {
            liftDwell += dt
            if liftDwell > 1.4 { setLift(liftK <= 0) }
        } else { liftDwell = 0 }
    }

    // MARK: getting in and out of the rover
    var nearRover: Bool {
        guard ship.cargo != nil, !driving else { return false }
        if aboard.on && rover.inShip { return simd_distance(aboard.p, rover.p) < 5 }
        if mode == .walk && !rover.inShip, let w0 = w.world, w0 === rover.world { return simd_distance(w.pos, rover.wpos) < 0.006 }
        return false
    }
    func enterRover() {
        driving = true; rover.speed = 0; rover.camYaw = 0
        sfx?.hatch(); sfx?.powerUp()
        say("driving the rover · W S drive · A D steer · shift boost · E get out")
    }
    func exitRover() {
        driving = false; rover.speed = 0
        sfx?.hatch()
        if rover.inShip {
            let side = D3(cos(rover.yaw), 0, -sin(rover.yaw)) * (ROVER_HALF.w + 1.0)
            var p = rover.p + side
            if ship.deck?.floor(p.x, p.z, near: rover.p.y, liftY: cargoLiftY) == nil { p = rover.p - side }
            aboard.p = D3(p.x, rover.p.y, p.z); aboard.yaw = rover.yaw; aboard.pitch = -0.1
        } else if let P = rover.world {
            let side = simd_normalize(simd_cross(rover.wfwd, rover.wup)) * 0.0032
            let d = simd_normalize(rover.wpos + side - P.pos)
            w.pos = P.pos + d * surfaceR(P, d); w.world = P
            w.fwd = rover.wfwd; w.camFwd = rover.wfwd; w.vel = .zero; w.vUp = 0; w.onGround = true
        }
        say("out of the rover")
    }

    // MARK: driving
    /// throttle, braking and steering shared by both frames; returns the yaw change
    private func roverControls(_ dt: Double) -> Double {
        let k = keys
        let gas = (k.contains(Key.w) || k.contains(Key.up) ? 1.0 : 0) - (k.contains(Key.s) || k.contains(Key.down) ? 1.0 : 0)
        let steer = (k.contains(Key.a) || k.contains(Key.left) ? 1.0 : 0) - (k.contains(Key.d) || k.contains(Key.right) ? 1.0 : 0)
        let top = shift ? 75.0 : 45.0                 // m/s: 160 km/h, 270 with boost
        if gas > 0 { rover.speed += (rover.speed < 0 ? 20 : (shift ? 16 : 11)) * dt }
        else if gas < 0 { rover.speed -= (rover.speed > 0 ? 14 : 4) * dt }
        else { rover.speed *= exp(-dt * 0.7) }
        if k.contains(Key.space) { rover.speed *= exp(-dt * 4) }
        rover.speed = clampd(rover.speed, -12, top)
        rover.wheel += rover.speed * dt / 0.78
        rover.camYaw = damp(rover.camYaw, 0, mouse == .zero ? 0.6 : 0, dt)
        rover.camYaw -= mouse.x * 0.004
        rover.camPitch = clampd(rover.camPitch + mouse.y * 0.003, 0.02, 1.2)
        let grip = clampd(abs(rover.speed) / 5, 0, 1) * (rover.speed >= 0 ? 1 : -1)
        // the body leans out of turns and squats/dips with the throttle; the front wheels turn with the steering
        let prevSpeed = rover.speed
        _ = prevSpeed
        rover.steerVis = damp(rover.steerVis, steer * 0.5, 6, dt)
        rover.roll = damp(rover.roll, -steer * clampd(abs(rover.speed) / 45, 0, 1) * 0.07, 3, dt)
        rover.pitch = damp(rover.pitch, (gas > 0 ? -0.025 : gas < 0 && rover.speed > 1 ? 0.04 : 0) * clampd(abs(rover.speed) / 10 + 0.3, 0, 1), 4, dt)
        sfx?.engine(throttle: 0.15 + min(1, abs(rover.speed) / 45) * 0.55, ab: 0, on: true)
        return steer * 0.9 * grip * dt / (1 + abs(rover.speed) / 40)   // steering calms at speed
    }

    /// driving around inside the ship (the bay and the lift)
    func driveDeckStep(_ dt: Double) {
        guard let d = ship.deck, let c = ship.cargo else { return }
        rover.yaw += roverControls(dt)
        let f = D3(-sin(rover.yaw), 0, -cos(rover.yaw)), r = D3(cos(rover.yaw), 0, -sin(rover.yaw))
        let step = f * rover.speed * dt
        func fits(_ p: D3) -> Bool {
            for (a, b) in [(ROVER_HALF.l, ROVER_HALF.w), (ROVER_HALF.l, -ROVER_HALF.w), (-ROVER_HALF.l, ROVER_HALF.w), (-ROVER_HALF.l, -ROVER_HALF.w)] {
                let q = p + f * a + r * b
                if d.floor(q.x, q.z, near: rover.p.y, liftY: cargoLiftY) == nil { return false }
            }
            return true
        }
        let np = rover.p + step
        if fits(np) { rover.p = np }
        else if cargoOpen && rover.p.x > c.lift.x0 && rover.p.x < c.lift.x1 && rover.p.z > c.lift.z0 && rover.p.z < c.lift.z1 && abs(rover.p.y - (cargoLiftY ?? 0)) < 0.5 {
            // rolling off the lowered platform onto the ground
            rover.p = np; roverToPlanet(); return
        } else { rover.speed = -rover.speed * 0.15; sfx?.thud() }
        // third-person camera, kept inside the bay
        let back = simd_quatd(angle: rover.yaw + rover.camYaw, axis: D3(0, 1, 0)).act(D3(0, 0, 1))
        var eye = rover.p + back * (9 * cos(rover.camPitch)) + D3(0, 2 + 9 * sin(rover.camPitch), 0)
        eye.y = min(eye.y, c.floorY + 15)
        camPos = pos + q.act(eye * 0.001)
        let target = pos + q.act((rover.p + D3(0, 1.8, 0)) * 0.001)
        camQ = lookRotation(forward: simd_normalize(target - camPos), up: q.act(D3(0, 1, 0)))
        fov = damp(fov, 66, 3, dt)
    }

    func roverToPlanet() {
        guard let W = landedOn else { return }
        let wp = pos + q.act(rover.p * 0.001), u = simd_normalize(wp - W.pos)
        rover.inShip = false; rover.world = W
        rover.wpos = W.pos + u * surfaceR(W, u)
        var f = q.act(D3(-sin(rover.yaw), 0, -cos(rover.yaw))); f -= u * simd_dot(f, u); rover.wfwd = simd_normalize(f); rover.wup = u
        aboard.on = false; mode = .walk; w.world = W; w.pos = rover.wpos
        say("on the ground · \(W.name)")
    }
    /// back aboard: rolling (or walking) onto the lowered platform
    func planetToShip(_ wp: D3) -> D3? {
        guard let c = ship.cargo, cargoOpen, landedOn != nil else { return nil }
        let local = q.inverse.act(wp - pos) * 1000
        guard local.x > c.lift.x0 + 0.5 && local.x < c.lift.x1 - 0.5 && local.z > c.lift.z0 + 0.5 && local.z < c.lift.z1 - 0.5 else { return nil }
        guard abs(local.y - (cargoLiftY ?? 0)) < 3 else { return nil }
        return D3(local.x, cargoLiftY ?? local.y, local.z)
    }

    /// driving across a planet
    func drivePlanetStep(_ dt: Double, _ P: World) {
        let dy = roverControls(dt)
        var up = simd_normalize(rover.wpos - P.pos)
        rover.wfwd = simd_quatd(angle: dy, axis: up).act(rover.wfwd)
        var next = rover.wpos + rover.wfwd * rover.speed * 0.001 * dt
        let nu = simd_normalize(next - P.pos)
        if waterDepth(P, nu) > 0.0008 && rover.speed > 0 {
            rover.speed = 0; next = rover.wpos
            if time - lastWaterNag > 3 { lastWaterNag = time; sfx?.denied(); say("the rover doesn't float · turn back") }
        }
        up = simd_normalize(next - P.pos)
        rover.wpos = P.pos + up * surfaceR(P, up)
        var f = rover.wfwd - up * simd_dot(rover.wfwd, up); rover.wfwd = simd_normalize(f)
        // tilt with the ground under the wheels
        let side = simd_normalize(simd_cross(rover.wfwd, up))
        func g(_ o: D3) -> D3 { let d = simd_normalize(rover.wpos + o - P.pos); return P.pos + d * surfaceR(P, d) }
        let fa = g(rover.wfwd * 0.003), fb = g(-rover.wfwd * 0.003), sa = g(side * 0.002), sb = g(-side * 0.002)
        let n = simd_normalize(simd_cross(sa - sb, fa - fb))
        rover.wup = simd_normalize(mixd(rover.wup, simd_dot(n, up) > 0 ? n : -n, 1 - exp(-dt * 8)))
        // suspension: each wheel reaches for the ground under it
        let wl = TruckLayout.shared
        for (i, c) in wl.wheels.enumerated() where i < rover.susp.count {
            let off = side * c.x * 0.001 - rover.wfwd * c.z * 0.001
            let d = simd_normalize(rover.wpos + off - P.pos)
            let groundH = (surfaceR(P, d) - simd_distance(rover.wpos + off, P.pos)) * 1000     // m above (+) or below (-) the body plane
            rover.susp[i] = damp(rover.susp[i], clampd(groundH, -0.35, 0.35), 18, dt)
        }
        f = rover.wfwd
        w.pos = rover.wpos
        // drove onto the lowered lift?
        if let local = planetToShip(rover.wpos) {
            rover.inShip = true; rover.p = local; rover.speed = min(rover.speed, 3)   // brake onto the platform
            rover.yaw = atan2(-simd_dot(q.inverse.act(f), D3(1, 0, 0)), -simd_dot(q.inverse.act(f), D3(0, 0, 1)))
            mode = .landed; aboard = AboardState(on: true, p: local, yaw: rover.yaw, pitch: -0.1)
            say("aboard the \(ship.name) · E on the lift to raise it")
            return
        }
        // chase camera behind the rover; the mouse swings it round
        let back = simd_quatd(angle: rover.camYaw, axis: up).act(-f)
        var cp = rover.wpos + back * (0.015 * cos(rover.camPitch)) + up * (0.0025 + 0.015 * sin(rover.camPitch))
        let cu = simd_normalize(cp - P.pos), gr = surfaceR(P, cu) + 0.0015
        if simd_distance(cp, P.pos) < gr { cp = P.pos + cu * gr }
        camPos = cp
        camQ = lookRotation(forward: simd_normalize(rover.wpos + up * 0.0018 - camPos), up: up)
        fov = damp(fov, 64, 3, dt)
    }
}
