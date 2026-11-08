import Foundation
import Metal
import simd

// The explorer on foot: an articulated astronaut with a jetpack. Built in metres (1 m = 0.001 km).

let WALK_SPEED = 0.003, RUN_SPEED = 0.0078      // km/s: 3 m/s walk, ~8 m/s run

struct WalkState {
    var world: World?
    var pos = D3.zero, fwd = D3(1, 0, 0), camFwd = D3(1, 0, 0), vel = D3.zero
    var vUp = 0.0, onGround = true, air = 0.0, jet = 0.0, land = 0.0, turn = 0.0
    var phase = 0.0, lastStep = 0, pitch = 0.2, camPos = D3.zero
    var pose = Pose(), target = Pose()
    var flying = false, heroLand = 0.0, flyTilt = 0.0     // superhero flight (X), the kneeling landing, how far the body leans into flight
}
struct Pose { var lt = 0.0, lk = 0.0, rt = 0.0, rk = 0.0, la = 0.0, le = 0.0, ra = 0.0, re = 0.0, laz = 0.0, raz = 0.0, lean = 0.0, roll = 0.0, bob = 0.0, crouch = 0.0 }
struct SummonState { var active = false, phase = 0, target = D3.zero, vtol = 0.0, t = 0.0, climb = 0.0 }

/// astronaut body parts, in the order the renderer draws them
enum AstroPart: Int, CaseIterable { case pelvis, torso, head, thighL, shinL, thighR, shinR, upperArmL, foreArmL, upperArmR, foreArmR }

extension MeshBuilder {
    mutating func sphere(_ r: Double, _ c: D3, _ m: Mat, scale s: D3 = D3(1, 1, 1), seg: Int = 14, rings: Int = 9) {
        func p(_ i: Int, _ j: Int) -> D3 {
            let th = Double(i) / Double(rings) * .pi, ph = Double(j) / Double(seg) * .pi * 2
            return c + D3(sin(th) * cos(ph) * r * s.x, cos(th) * r * s.y, sin(th) * sin(ph) * r * s.z)
        }
        for i in 0..<rings { for j in 0..<seg { quad(p(i, j), p(i, j + 1), p(i + 1, j + 1), p(i + 1, j), m) } }
    }
}

func buildAstronaut(device: MTLDevice) -> [GPUMesh] {
    func part(_ f: (inout MeshBuilder) -> Void) -> GPUMesh { var b = MeshBuilder(); f(&b); return GPUMesh(device: device, verts: b.v) }
    let limb = { (b: inout MeshBuilder, len: Double, r1: Double, r2: Double, joint: Bool) in
        b.cylinder(r1 * 0.85, r1, len, D3(0, -len / 2, 0), .suit, seg: 12)   // hangs down from the joint
        if joint { b.sphere(r1 * 0.95, .zero, .suit, seg: 10, rings: 6) }
        _ = r2
    }
    return [
        part { $0.box(D3(0.36, 0.2, 0.25), .zero, .dark) },                                                     // pelvis
        part { b in                                                                                              // torso + backpack
            b.box(D3(0.42, 0.48, 0.27), D3(0, 0.27, 0), .suit)
            b.box(D3(0.44, 0.06, 0.28), D3(0, 0.38, 0), .orange)
            b.box(D3(0.2, 0.12, 0.04), D3(0, 0.26, -0.15), .dark)
            b.box(D3(0.36, 0.46, 0.17), D3(0, 0.26, 0.21), .dark)
            b.box(D3(0.3, 0.04, 0.02), D3(0, 0.42, 0.3), .cyan)
            for sx in [1.0, -1.0] { b.cylinder(0.045, 0.055, 0.12, D3(sx * 0.11, 0.0, 0.25), .metal, seg: 10) }
        },
        part { b in                                                                                              // helmet
            b.sphere(0.155, .zero, .suit)
            b.sphere(0.14, D3(0, 0.0, -0.06), .visor, scale: D3(1, 0.82, 0.72))
            b.sphere(0.02, D3(0.13, 0.04, -0.04), .cyan, seg: 6, rings: 4)
        },
        part { limb(&$0, 0.44, 0.085, 0.072, true) },                                                            // thigh L
        part { b in limb(&b, 0.44, 0.072, 0.065, true); b.box(D3(0.15, 0.09, 0.28), D3(0, -0.475, -0.05), .dark) }, // shin L + boot
        part { limb(&$0, 0.44, 0.085, 0.072, true) },
        part { b in limb(&b, 0.44, 0.072, 0.065, true); b.box(D3(0.15, 0.09, 0.28), D3(0, -0.475, -0.05), .dark) },
        part { limb(&$0, 0.3, 0.06, 0.05, true) },                                                               // upper arm L
        part { b in limb(&b, 0.28, 0.05, 0.045, true); b.sphere(0.058, D3(0, -0.31, 0), .dark, seg: 8, rings: 5) },  // forearm + glove
        part { limb(&$0, 0.3, 0.06, 0.05, true) },
        part { b in limb(&b, 0.28, 0.05, 0.045, true); b.sphere(0.058, D3(0, -0.31, 0), .dark, seg: 8, rings: 5) },
    ]
}

extension Game {
    var nearShip: Bool {
        if sh.active { return false }
        if parkedHover, let W = w.world {    // a hovering ship: walk or fly up to her
            let up = simd_normalize(pos - W.pos), d = pos - w.pos, vert = simd_dot(d, up)
            if simd_distance(pos, w.pos) < size * 1.2 + 0.03 { return true }
            return simd_length(d - up * vert) < size * ship.exitSide * 1.5 + 0.015 && vert > -0.01 && vert < hoverExitAlt + gearH + 0.02
        }
        return simd_distance(w.pos, pos) < size * ship.exitSide * 1.5 + 0.015
    }

    func enterWalk() {
        guard let P = landedOn ?? Optional(near) else { return }
        w.world = P
        // step out beside the ship (right-hand side); from a hovering ship you drop from the hatch
        let spot = pos + q.act(D3(ship.exitSide * size, parkedHover ? -gearH * 0.5 : 0, 0))
        let dir = simd_normalize(spot - P.pos)
        let ground = surfaceR(P, dir)
        w.pos = parkedHover ? P.pos + dir * max(ground, simd_distance(spot, P.pos)) : P.pos + dir * ground
        var f = forward; f -= dir * simd_dot(f, dir); w.fwd = simd_normalize(f); w.camFwd = w.fwd
        w.flying = false; w.heroLand = 0; w.flyTilt = 0
        w.vel = parkedHover ? hv * 0.3 : .zero; w.vUp = 0; w.onGround = !parkedHover; w.pitch = 0.2; w.land = 0; w.camPos = camPos
        mode = .walk; throttle = 0
        if parkedHover { hv = .zero; vv = 0 }
        sfx?.hatch(); say(parkedHover ? "jumped out · the \(ship.name) holds her hover · walk under her and press E to board" : "on foot · \(P.name) · gravity \(P.gravity) g")
    }
    func boardShip() {
        if parkedHover {        // back aboard a hovering ship: carry on hovering
            parkedHover = false; mode = .hover; hv = .zero; vv = 0
            if let W = w.world { near = W; let up = simd_normalize(pos - W.pos); hoverAlt = max(0.002, simd_distance(pos, W.pos) - surfaceR(W, up) - gearH) }
            sfx?.hatch(); say("aboard the \(ship.name) · hovering"); return
        }
        mode = .landed; landedOn = w.world; orbitYaw = 0.7; orbitPitch = 0.22
        sfx?.hatch(); say("aboard the \(ship.name)")
    }
    func summonShip() {
        guard mode == .walk, !sh.active, let P = w.world else { return }
        if simd_distance(w.pos, pos) < size * 2.2 { say("your ship is right here"); return }
        if !power { sfx?.denied(); say("the \(ship.name) is powered down · walk back, board her and press P"); return }
        if fuel <= 0 { sfx?.denied(); say("the \(ship.name) has no fuel · press F for the emergency tanker first"); return }
        dockedAt = nil
        let up = simd_normalize(w.pos - P.pos)
        let right = simd_normalize(simd_cross(w.camFwd, up))
        let d = simd_normalize(w.pos + right * size * 0.9 + w.camFwd * size * 0.5 - P.pos)
        if waterDepth(P, d) > 0.0006 { sfx?.denied(); say("no room to land here · it's water · walk up the beach and call again"); return }
        sh.target = P.pos + d * surfaceR(P, d)
        sh.active = true; sh.phase = parkedHover ? 0 : -1; sh.t = 0; sh.climb = 0
        parkedHover = false
        sfx?.beep(); say("calling the \(ship.name) · \(fmtDist(simd_distance(w.pos, pos))) out · engines spooling up · about \(Int(summonETA())) s")
    }

    /// how fast a called ship flies over to you: a few hundred km/h, slower for heavy ships
    var summonCruise: Double { 0.14 / sqrt(ship.mass) }
    /// how long a ship takes to wake its engines before it can lift: a few seconds for a fighter, ~20 s for the Atlas
    var spoolTime: Double { 2.0 + size * 1000 / 55 }
    /// rough time for the ship to reach you (lift off, cruise, settle)
    func summonETA() -> Double {
        let d = simd_distance(w.pos, pos)
        return spoolTime + 6 + d / summonCruise + size * 120
    }

    func walkFrame(_ dt: Double) {
        guard let P = w.world else { return }
        if driving && !rover.inShip { drivePlanetStep(dt, P) } else {
            walkStep(dt, P)
            // walked onto the lowered cargo lift: back aboard
            if let local = planetToShip(w.pos) {
                let f = q.inverse.act(w.camFwd)
                mode = .landed
                aboard = AboardState(on: true, p: local, yaw: atan2(-f.x, -f.z), pitch: -0.05)
                say("aboard the \(ship.name) · E on the lift to raise it")
            }
        }
        mouse = .zero
        if sh.active { summonStep(dt, P) } else if parkedHover {
            // the ship you left holds her hover: jets lit, gear down, engines idling
            gear = damp(gear, 1, 2.2, dt); landedK = damp(landedK, 0, 2, dt); vtol = damp(vtol, 1, 4, dt); tilt = damp(tilt, 1, 1.5, dt)
            summonThrust = 0.4
            sfx?.engine(throttle: 0.35, ab: 0, on: power && fuel > 0)
        } else {
            gear = damp(gear, 1, 2.2, dt); landedK = damp(landedK, 1, 1.2, dt)
            vtol = damp(vtol, 0, 4, dt)
            tilt = damp(tilt, 1, 1.5, dt)
            sfx?.engine(throttle: 0, ab: 0, on: false)
        }
        abLevel = 0
        powerK = damp(powerK, power ? 1 : 0, power ? 1.8 : 1.1, dt)
        bounceT += dt
        streakOpacity = 0
        near = P
        let shipUp = simd_normalize(pos - P.pos)
        alt = simd_distance(pos, P.pos) - surfaceR(P, shipUp) - gearH
        airDensity = 1
        sfx?.jet(w.jet)
        checkDiscovery()
    }

    private func walkStep(_ dt: Double, _ P: World) {
        let k = keys, t = time
        var up = simd_normalize(w.pos - P.pos)
        func flat(_ v: D3) -> D3 { var x = v - up * simd_dot(v, up); if simd_length_squared(x) < 1e-12 { x = simd_cross(up, D3(1, 0, 0)) }; return simd_normalize(x) }
        w.fwd = flat(w.fwd); w.camFwd = flat(w.camFwd)
        w.camFwd = simd_quatd(angle: -mouse.x * 0.004, axis: up).act(w.camFwd)
        w.pitch = clampd(w.pitch + mouse.y * 0.003, w.flying ? -1.2 : -0.25, w.flying ? 1.45 : 1.2)
        let camRight = simd_cross(w.camFwd, up)
        let f = (k.contains(Key.w) || k.contains(Key.up) ? 1.0 : 0) - (k.contains(Key.s) || k.contains(Key.down) ? 1.0 : 0)
        let s = (k.contains(Key.d) || k.contains(Key.right) ? 1.0 : 0) - (k.contains(Key.a) || k.contains(Key.left) ? 1.0 : 0)
        var move = w.camFwd * f + camRight * s
        if simd_length_squared(move) > 0 { move = simd_normalize(move) }
        let run = shift, g = 0.0098 * P.gravity
        if w.flying {
            // fly where you look: W forward along the camera's aim, Shift to boost, Space to climb
            let ap = w.pitch - 0.2
            let aim = simd_normalize(w.camFwd * cos(ap) - up * sin(ap))
            let speed = run ? 1.4 : 0.25                        // km/s: 250 m/s cruising, boosting to ~Mach 4
            let want = aim * speed * max(0, f) - aim * 0.02 * max(0, -f) + camRight * s * speed * 0.4 + up * (k.contains(Key.space) ? 0.03 : 0)
            var v3 = w.vel + up * w.vUp
            v3 = mixd(v3, want, 1 - exp(-dt * (run ? 0.9 : 2.4)))
            w.vUp = simd_dot(v3, up); w.vel = v3 - up * w.vUp
            w.fwd = w.camFwd
            // sonic boom when you punch through Mach 1, a vapour cone around Mach 1
            let mach = simd_length(v3) / 0.343, inAir = P.atmo.top > 0 && simd_distance(w.pos, P.pos) - P.R < P.atmo.top
            if inAir && heroMachArmed && mach >= 1 { heroMachArmed = false; heroBoomT = 0; heroBoomPos = w.pos; sfx?.sonicBoom(); kick = max(kick, 1.2); say("Mach 1 · sonic boom") }
            else if mach < 0.9 { heroMachArmed = true }
            heroVapor = damp(heroVapor, inAir ? 1 - ss(0.05, 0.35, abs(mach - 1)) : 0, 6, dt)
        } else {
            let target = move * (run ? RUN_SPEED : WALK_SPEED)
            let accel = w.onGround ? (simd_length_squared(target) > 0 ? 6.0 : 9.0) : 1.2
            w.vel = mixd(w.vel, target, 1 - exp(-dt * (w.heroLand > 0.3 ? 0 : accel)))
            w.vel -= up * simd_dot(w.vel, up)
        }
        // the sea: you can paddle into the shallows, but not wade out of your depth
        let nextUp = simd_normalize(w.pos + w.vel * dt - P.pos)
        if waterDepth(P, nextUp) > 0.0011 && w.onGround && waterDepth(P, nextUp) > waterDepth(P, up) {
            w.vel = .zero
            if time - lastWaterNag > 3 { lastWaterNag = time; sfx?.denied(); say("too deep to wade any further") }
        }
        w.pos += w.vel * dt

        // jump, then hold space for the jetpack (unlimited fuel)
        w.air = w.onGround ? 0 : w.air + dt
        if k.contains(Key.space) && w.onGround && !w.flying && w.heroLand < 0.3 { w.vUp = 0.0042; w.onGround = false; w.land = -0.6; sfx?.step(0.6, air: P.atmo.top > 0) }
        let thrusting = k.contains(Key.space) && !w.onGround && w.air > 0.22 && !w.flying
        let flySpeed = simd_length(w.vel + up * w.vUp)
        w.jet = damp(w.jet, thrusting ? 1 : (w.flying ? 0.25 + min(0.75, flySpeed / 0.2) : 0), 10, dt)
        if thrusting { w.vUp += 0.0098 * 1.7 * dt }
        if !w.flying { w.vUp -= g * dt }
        w.heroLand = max(0, w.heroLand - dt)
        if !w.flying { heroVapor = damp(heroVapor, 0, 4, dt) }
        w.pos += up * w.vUp * dt
        let dist = simd_distance(w.pos, P.pos); up = (w.pos - P.pos) / dist
        let gr = surfaceR(P, up)
        if dist <= gr {
            w.pos = P.pos + up * gr
            let impact = max(0, -w.vUp) + (w.flying ? simd_length(w.vel) * 0.35 : 0)    // km/s into the ground
            if !w.onGround && impact > 0.014 {
                // superhero landing: down on one knee, fist to the ground, the earth shakes
                let hard = clampd((impact - 0.014) / 0.08, 0, 1)
                w.flying = false; w.heroLand = 1.1 + hard * 0.5; w.vel = .zero
                kick = max(kick, 0.6 + hard * 1.6); heroLandT = 0; heroLandPos = w.pos; heroLandK = 0.4 + hard * 0.6
                sfx?.heavyLand(0.4 + hard * 0.6)
                say(hard > 0.6 ? "SUPERHERO LANDING" : "landed")
            } else if !w.onGround {
                let hard = clampd(-w.vUp / 0.008, 0, 1); w.land = 0.35 + hard * 0.65; if w.vUp < -0.002 { sfx?.step(0.6 + hard, air: true) }
                if w.flying && flySpeed < 0.01 { w.flying = false }
            }
            w.vUp = max(0, w.vUp); w.onGround = true
        } else if dist > gr + 0.0004 { w.onGround = false }
        w.land = damp(w.land, 0, 7, dt)

        // body turns toward where it moves, banking into turns
        let hv = simd_length(w.vel)
        let prev = w.fwd
        if hv > 0.0003 { w.fwd = simd_normalize(mixd(w.fwd, simd_normalize(w.vel), 1 - exp(-dt * 9))) }
        let turnRate = asin(clampd(simd_dot(simd_cross(prev, w.fwd), up), -1, 1)) / max(dt, 1e-3)
        w.turn = damp(w.turn, turnRate, 6, dt)

        // walk-cycle targets
        let amp = clampd(hv / 0.0018, 0, 1), runK = clampd((hv - WALK_SPEED) / (RUN_SPEED - WALK_SPEED), 0, 1)
        let stride = 0.0013 + runK * 0.0011
        w.phase += hv * dt / stride * .pi
        let sw = sin(w.phase)
        var T = Pose()
        let flyK = w.flying ? clampd(flySpeed / 0.05, 0, 1) : 0
        if w.heroLand > 0 {
            // the landing: front knee up, back knee down, right fist planted, left arm thrown out
            let k2 = min(1, w.heroLand / 0.5)
            T.lt = 1.35 * k2; T.lk = 1.9 * k2; T.rt = -0.35 * k2; T.rk = 2.1 * k2
            T.ra = 0.95 * k2; T.re = 0.25; T.la = -0.5 * k2; T.le = 0.6; T.laz = -0.9 * k2; T.raz = 0.15
            T.lean = 0.75 * k2; T.crouch = 1.0 * k2; T.bob = -0.25 * k2
        } else if w.flying {
            // flying: one fist punched forward, the other arm back, legs together and trailing; upright when hovering
            let bob = sin(t * 2.2) * 0.04 * (1 - flyK)
            T.la = 0.3 + 2.6 * flyK; T.le = 0.1; T.laz = -0.1
            T.ra = 0.1 - 0.35 * flyK; T.re = 0.15; T.raz = 0.12 + 0.1 * flyK
            T.lt = 0.08 - 0.15 * flyK + bob; T.rt = -0.12 - 0.05 * flyK; T.lk = 0.25 * (1 - flyK) + 0.05; T.rk = 0.4 * (1 - flyK) + 0.08
            T.lean = 0.05; T.bob = 0
        } else if w.onGround {
            T.lt = sw * (0.42 + 0.38 * runK) * amp; T.rt = -T.lt
            T.lk = (0.12 + 0.95 * runK) * max(0, sin(w.phase + 1.3)) * amp + 0.05
            T.rk = (0.12 + 0.95 * runK) * max(0, sin(w.phase + 1.3 + .pi)) * amp + 0.05
            T.la = -sw * (0.35 + 0.45 * runK) * amp; T.ra = -T.la
            T.le = (0.18 + 0.95 * runK) * (0.4 + 0.6 * amp); T.re = T.le
            T.laz = -0.07 + sin(t * 1.6) * 0.02 * (1 - amp); T.raz = -T.laz
            T.lean = (0.04 + 0.26 * runK) * amp; T.roll = sw * 0.04 * amp
            T.bob = abs(cos(w.phase)) * (0.03 + 0.04 * runK) * amp - 0.02 * runK
            T.crouch = max(0, w.land)
        } else if w.jet > 0.2 {
            T.lt = -0.12; T.rt = -0.22; T.lk = 0.3; T.rk = 0.45; T.la = -0.2; T.ra = -0.2; T.le = 0.45; T.re = 0.45; T.laz = -0.45; T.raz = 0.45; T.lean = 0.18
        } else {
            T.lt = 0.7; T.rt = -0.15; T.lk = 1.0; T.rk = 0.35; T.la = 0.45; T.ra = 0.2; T.le = 0.7; T.re = 0.6; T.laz = -0.35; T.raz = 0.35; T.lean = 0.08
        }
        let r14 = 1 - exp(-dt * 14), r20 = 1 - exp(-dt * 20)
        var p = w.pose
        p.lt += (T.lt - p.lt) * r14; p.rt += (T.rt - p.rt) * r14; p.lk += (T.lk - p.lk) * r14; p.rk += (T.rk - p.rk) * r14
        p.la += (T.la - p.la) * r14; p.ra += (T.ra - p.ra) * r14; p.le += (T.le - p.le) * r14; p.re += (T.re - p.re) * r14
        p.laz += (T.laz - p.laz) * r14; p.raz += (T.raz - p.raz) * r14; p.lean += (T.lean - p.lean) * r14; p.roll += (T.roll - p.roll) * r14
        p.bob += (T.bob - p.bob) * r20; p.crouch += (T.crouch - p.crouch) * r20
        w.pose = p
        let stepNow = Int(floor(w.phase / .pi))
        if w.onGround && amp > 0.25 && stepNow != w.lastStep { sfx?.step(0.4 + runK * 0.5, air: P.atmo.top > 0) }
        w.lastStep = stepNow

        // over-the-shoulder camera
        let camDist = 0.0042 + runK * 0.0012 + flyK * 0.002 + (w.flying ? 0.001 : 0), cp = cos(w.pitch), spn = sin(w.pitch)
        let camR = simd_normalize(simd_cross(w.camFwd, up))
        let want = w.pos + up * 0.0017 + camR * 0.0007 - w.camFwd * camDist * cp + up * camDist * spn
        w.camPos = mixd(w.camPos, want, 1 - exp(-dt * (w.flying ? 12 + flySpeed * 400 : 10)))   // keep up at flying speeds
        let cu = simd_normalize(w.camPos - P.pos), cgr = surfaceR(P, cu) + 0.0005
        if simd_distance(w.camPos, P.pos) < cgr { w.camPos = P.pos + cu * cgr }
        camPos = w.camPos
        camQ = lookRotation(forward: simd_normalize(w.pos + up * 0.0015 + camR * 0.00045 + w.camFwd * 0.002 - camPos), up: up)
        fov = damp(fov, 62 + runK * amp * 6 + flyK * (shift ? 10 : 5), 4, dt)

        // body-part transforms (km units, world space relative to the planet-independent origin)
        let back = -w.fwd, right = simd_normalize(simd_cross(up, back))
        let basis = simd_double3x3(columns: (right, up, simd_cross(right, up)))
        var root = simd_double4x4(1)
        root.columns.0 = SIMD4(basis.columns.0 * 0.001, 0); root.columns.1 = SIMD4(basis.columns.1 * 0.001, 0); root.columns.2 = SIMD4(basis.columns.2 * 0.001, 0)
        root.columns.3 = SIMD4(w.pos, 1)
        let cr = p.crouch
        let pelvis = root * translate(D3(0, 0.97 + p.bob - cr * 0.16, 0)) * eulerXYZ(D3(0, 0, p.roll))
        let torso = pelvis * translate(D3(0, 0.08, 0)) * eulerXYZ(D3(-p.lean - cr * 0.25, 0, clampd(-w.turn * 0.06, -0.25, 0.25) * amp)) * scaleM(D3(1, 1 + sin(t * 1.8) * 0.008 * (1 - amp), 1))
        let head = torso * translate(D3(0, 0.62, 0)) * eulerXYZ(D3(p.lean * 0.5 - w.pitch * 0.25, 0, 0))
        let hipL = pelvis * translate(D3(-0.11, -0.04, 0)) * eulerXYZ(D3(p.lt + cr * 0.6, 0, 0))
        let kneeL = hipL * translate(D3(0, -0.44, 0)) * eulerXYZ(D3(-(p.lk + cr * 1.2), 0, 0))
        let hipR = pelvis * translate(D3(0.11, -0.04, 0)) * eulerXYZ(D3(p.rt + cr * 0.6, 0, 0))
        let kneeR = hipR * translate(D3(0, -0.44, 0)) * eulerXYZ(D3(-(p.rk + cr * 1.2), 0, 0))
        let shL = torso * translate(D3(-0.27, 0.46, 0)) * eulerXYZ(D3(p.la, 0, p.laz))
        let elL = shL * translate(D3(0, -0.3, 0)) * eulerXYZ(D3(p.le, 0, 0))
        let shR = torso * translate(D3(0.27, 0.46, 0)) * eulerXYZ(D3(p.ra, 0, p.raz))
        let elR = shR * translate(D3(0, -0.3, 0)) * eulerXYZ(D3(p.re, 0, 0))
        astroPose = [pelvis, torso, head, hipL, kneeL, hipR, kneeR, shL, elL, shR, elR]
        jetPoints = [torso * SIMD4(0.11, -0.12, 0.25, 1), torso * SIMD4(-0.11, -0.12, 0.25, 1)].map { D3($0.x, $0.y, $0.z) }
        // the rigged robot: its own idle when standing still, code-driven motion when moving or in the air
        if let rig = CharacterRig.shared {
            charIdleT += dt
            let still = w.onGround && w.jet < 0.2 ? 1 - amp : 0
            charIdleK = damp(charIdleK, still, 5, dt)
            let e = rig.evaluate(idleTime: charIdleT, idleK: charIdleK, pose: p, turn: w.turn * amp, look: w.pitch)
            charSkin = e.skin
            // lean the whole body into the direction of flight, pivoting at the chest
            let vdir = flySpeed > 1e-5 ? simd_normalize(w.vel + up * w.vUp) : up
            w.flyTilt = damp(w.flyTilt, flyK, 3, dt)
            let bodyUp = simd_normalize(up * (1 - w.flyTilt) + vdir * w.flyTilt + up * 1e-4)
            let rgt = simd_normalize(right - bodyUp * simd_dot(right, bodyUp)), bk = simd_cross(rgt, bodyUp)
            var r2 = simd_double4x4(1)
            r2.columns.0 = SIMD4(rgt * 0.001, 0); r2.columns.1 = SIMD4(bodyUp * 0.001, 0); r2.columns.2 = SIMD4(bk * 0.001, 0)
            r2.columns.3 = SIMD4(w.pos + up * 0.001 - bodyUp * 0.001 * w.flyTilt - up * 0.001 * (1 - w.flyTilt), 1)
            charRoot = r2
            let root = r2
            jetPoints = [root * e.spine * SIMD4(0.12, 0.0, 0.18, 1), root * e.spine * SIMD4(-0.12, 0.0, 0.18, 1)].map { D3($0.x, $0.y, $0.z) }
        }
        v = hv
    }

    private func summonStep(_ dt: Double, _ P: World) {
        let up = simd_normalize(pos - P.pos)
        let alt = simd_distance(pos, P.pos) - surfaceR(P, up) - gearH, cruise = size * 5
        var toT = sh.target - pos; toT -= up * simd_dot(toT, up)
        let hd = simd_length(toT)
        var thrust = 0.35, vt = 1.0
        landedK = damp(landedK, 0, 2.5, dt)
        sh.t += dt
        switch sh.phase {
        case -1:  // engines spooling up on the ground: the jets light, the ship strains on its gear
            thrust = 0.15 + 0.3 * min(1, sh.t / spoolTime); vt = min(1, sh.t / spoolTime)
            gear = 1; landedK = damp(landedK, 1, 2, dt)
            if sh.t >= spoolTime { sh.phase = 0; sh.t = 0; sfx?.lift() }
        case 0:   // lift off: heavy ships climb away slowly, gaining speed
            let accel = 0.004 / ship.mass                                 // km/s²: ~4 m/s² for a fighter, ~1 m/s² for the Atlas
            sh.climb = min(sh.climb + accel * dt, max(size * 0.5, (cruise - alt) * 0.9))
            pos += up * sh.climb * dt
            gear = damp(gear, alt > size * 1.5 ? 0 : 1, 2.2, dt)
            if alt > cruise * 0.85 { sh.phase = 1 }
        case 1:   // fly over low, holding height above the terrain
            let dirH = simd_normalize(toT), sp = clampd(hd * 0.35, min(0.01, summonCruise), summonCruise)
            pos += dirH * min(hd, sp * dt)
            let u2 = simd_normalize(pos - P.pos), r = simd_distance(pos, P.pos), wantR = surfaceR(P, u2) + gearH + cruise
            pos = P.pos + u2 * (r + (wantR - r) * min(1, dt * 2))
            q = slerpShort(q, lookRotation(forward: dirH, up: u2), 1 - exp(-dt * 2))
            gear = damp(gear, 0, 2.2, dt); thrust = 0.75; vt = 0.3
            if hd < size * 0.3 { sh.phase = 2 }
        default:  // settle down beside you
            q = slerpShort(q, levelQuat(up: up), 1 - exp(-dt * 2.5))
            pos += toT * min(1, dt * 2)
            let sink = max(0.0035 * size / 0.05, alt * 0.9) * (gear > 0.85 || alt > size * 3 ? 1 : 0.15) * dt
            gear = damp(gear, 1, 2.2, dt)
            if alt <= sink + 1e-4 {
                pos = P.pos + up * (surfaceR(P, up) + gearH)
                sh.active = false; landedOn = P; bounceT = 0; touchdown(); checkDock()
                say("the \(ship.name) has landed · walk over and press E")
            } else { pos -= up * min(sink, alt) }
        }
        sh.vtol = damp(sh.vtol, vt, 4, dt); vtol = sh.vtol; tilt = damp(tilt, sh.vtol > 0.3 ? 1 : 0, 1.5, dt)
        summonThrust = thrust
        sfx?.engine(throttle: thrust, ab: 0, on: true)
    }

    /// project a world point to normalised screen coordinates (0..1, y down); flags points behind the camera
    func project(_ p: D3, aspect: Double) -> (x: Double, y: Double, behind: Bool) {
        let v = simd_double3x3(camQ).transpose * (p - camPos)
        let behind = v.z > 0
        let tanY = tan(fov * .pi / 360), tanX = tanY * aspect
        let z = max(abs(v.z), 1e-6)
        var x = v.x / z / tanX, y = v.y / z / tanY
        if behind { x = -x; y = -y }
        return ((x * 0.5 + 0.5), (-y * 0.5 + 0.5), behind)
    }
}
