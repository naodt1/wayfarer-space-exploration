import Foundation
import simd

enum Key {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, h: UInt16 = 4, w: UInt16 = 13, one: UInt16 = 18, two: UInt16 = 19, three: UInt16 = 20
    static let e: UInt16 = 14, r: UInt16 = 15, q: UInt16 = 12, tab: UInt16 = 48
    static let g: UInt16 = 5, v: UInt16 = 9, i: UInt16 = 34, c: UInt16 = 8, f: UInt16 = 3, x: UInt16 = 7
    static let p: UInt16 = 35, l: UInt16 = 37, m: UInt16 = 46, space: UInt16 = 49, esc: UInt16 = 53, enter: UInt16 = 36
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

enum Mode { case title, fly, hover, landing, landed, takeoff, walk }

/// All simulation state. Positions are in kilometres, in double precision.
final class Game {
    let worlds: [World]
    let sunPos = D3(-3600000, 360000, -1800000)
    var ships: [ShipModel]
    var shipIndex = 0
    var ship: ShipModel { ships[shipIndex] }
    var sfx: Audio?
    var say: (String) -> Void = { _ in }

    // input
    var keys = Set<UInt16>()
    var mouse = SIMD2<Double>(0, 0)
    var shift = false

    // ship state
    var mode: Mode = .title
    // pause menu (Esc): 0 resume, 1 ship, 2 main menu
    var paused = false, menuSel = 0, menuShip = 0
    var aboard = AboardState()        // walking around inside the ship (big ships with a deck)
    // afterburner and sonic boom effects
    var kick = 0.0, burnFlash = 0.0, vapor = 0.0, shockT = 9.0, machArmed = true, heat = 0.0   // heat: re-entry plasma
    // cameras: 0 chase, 1 drone (far behind, lagging), 2 film crew (tracking shots as you fly past)
    var camMode = 0
    var flyCam: D3? = nil, droneOff: D3? = nil, flyCamSide = 1.0
    var tanker = TankerState()          // the emergency fuel tanker (F)
    var props: [PropInstance] = []      // downloaded models placed in the world (Props.swift)
    var stationPos = D3.zero, outpostDir = D3(0, 1, 0)
    let corridorFloor = 0.28, corridorHalfW = 9.0     // the corridor model's floor height and half-width (m, unscaled)
    var dustT = 9.0                     // time since a touchdown (dust burst)
    var rover = Rover(), driving = false
    var cargoWant = false, liftWant = false, liftDwell = 0.0, doorK = 0.0, liftK = 0.0, cargoGround = -119.0
    var engineK = 1.0                   // engine flames and lights: fade out when the tank runs dry
    var extYaw = 0.0, extPitch = 0.22, extZoom = 1.0      // orbit camera: the mouse swings it round the ship, the scroll wheel zooms
    func zoomCamera(_ dy: Double) { if camMode == 1 { extZoom = clampd(extZoom * exp(-dy * 0.03), 0.2, 8) } }
    var pos = D3.zero
    var q = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    var throttle = 0.35, v = 0.0, ang = D3.zero
    var ab = false, abLevel = 0.0, lastLvl = 3
    var auto = -1
    var cockpitView = false          // V: first-person view from the pilot's seat
    var lookYaw = 0.0, lookPitch = 0.0   // free look: orbits the camera in hover, turns your head in the cockpit
    var tilt = 0.0                   // engine nacelle tilt: 0 cruise, 1 vertical (ships with tilting engines)
    var gear = 0.0, gearTarget = 0.0, vtol = 0.0, landedK = 0.0, bounceT = 9.0, takeoffT = 0.0
    var power = true, powerK = 1.0
    var fuel = 1.0                     // tank fraction
    var depots: [Depot] = []
    var dockedAt: Int?                 // depot whose pad the ship is parked on
    var hv = D3.zero, vv = 0.0, hoverAlt = 0.02   // hover: horizontal velocity, vertical speed, height held above the ground (km)
    var w = WalkState()              // the explorer on foot
    var sh = SummonState()           // the ship flying itself over when called
    var astroPose: [simd_double4x4] = []   // world transforms of the astronaut's body parts
    var jetPoints: [D3] = []
    var heroBoomT = 9.0, heroBoomPos = D3.zero, heroMachArmed = true, heroVapor = 0.0   // the robot breaking the sound barrier
    var heroLandT = 9.0, heroLandPos = D3.zero, heroLandK = 0.0   // the shockwave of a superhero landing
    var cracks: [GroundCrack] = [], crackSerial = 0              // the ground split open by superhero landings (Cracks.swift)
    var parkedHover = false              // you stepped out of a ship that's still hovering
    var charSkin: [simd_float4x4] = []     // the rigged character's skin matrices (CharacterRig), and where it stands
    var charRoot = simd_double4x4(1), charIdleT = 0.0, charIdleK = 1.0
    var sites: [Site] = []
    var lastScan = -10.0, scanPulse = 9.0
    var hintsSeen = Set<String>()
    var banner: ((String, String) -> Void)?
    var launchTime = 0.0
    var summonThrust = 0.0
    var near: World
    var landedOn: World?
    var alt = 0.0
    var airDensity = 0.0          // 1 at sea level, falls off with altitude; 0 in space
    var mach: Double { v / 0.343 }  // speed of sound ≈ 343 m/s
    static let burnerMinAlt = 2.0, burnerCutAlt = 1.5
    static let cruiseMax = 2500.0      // km/s between the planets (×3 on afterburner): a few minutes from world to world

    // camera
    var camPos = D3.zero, camQ = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), fov = 62.0
    private var camBase = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)   // smoothed ship orientation the chase camera follows
    var orbitYaw = 0.7, orbitPitch = 0.22
    var showcaseYaw = 0.55, showcasePitch = 0.28, showcaseZoom = 1.0
    var dragging = false
    private var scUp = D3.zero, scSide = D3.zero, scPos = D3.zero

    // speed streaks in camera space
    var streaks = [Float](repeating: 0, count: 280 * 6)
    private var streakSeed = [D3](repeating: .zero, count: 280)
    var streakOpacity: Float = 0, streakColor = SIMD3<Float>(0.66, 0.8, 1)
    var time = 0.0

    var size: Double { ship.size }
    var gearH: Double { ship.gearBottom * ship.size / ship.length }

    init(worlds: [World], ships: [ShipModel]) {
        self.worlds = worlds; self.ships = ships; near = worlds[0]
        sites = makeSites(worlds: worlds)
        depots = makeDepots(worlds: worlds, sites: sites)
        placeProps()
        for i in 0..<streakSeed.count { streakSeed[i] = Game.newStreak(z: -Double.random(in: 0...2.2)) }
        let E = worlds[0], toSun = simd_normalize(sunPos - E.pos)
        scUp = simd_normalize(rotateY(toSun, 1.05) + D3(0, 0.2, 0))
        scPos = E.pos + scUp * E.R * 1.22
        scSide = simd_normalize(toSun - scUp * simd_dot(toSun, scUp))
        pos = scPos
        showcase(0)
    }

    static func newStreak(z: Double) -> D3 {
        var x = 0.0, y = 0.0
        repeat { x = Double.random(in: -0.45...0.45); y = Double.random(in: -0.3...0.3) } while abs(x) < 0.05 && abs(y) < 0.04
        return D3(x, y, z)
    }

    // MARK: helpers
    func nearestWorld(_ p: D3) -> World { worlds.min { simd_distance(p, $0.pos) - $0.R < simd_distance(p, $1.pos) - $1.R }! }
    var forward: D3 { q.act(D3(0, 0, -1)) }
    func levelQuat(up: D3) -> simd_quatd {
        var f = forward; f -= up * simd_dot(f, up)
        if simd_length_squared(f) < 1e-10 { f = simd_cross(up, D3(1, 0, 0)) }
        return lookRotation(forward: simd_normalize(f), up: up)
    }

    // MARK: actions
    func launch() {
        guard mode == .title else { return }
        camBase = q; throttle = 0.15
        mode = .fly; launchTime = time
        say("welcome aboard the \(ship.name)")
    }
    func selectShip(_ delta: Int) {
        guard mode == .title else { return }
        shipIndex = (shipIndex + delta + ships.count) % ships.count
        sfx?.pitch = ship.pitch; sfx?.servo()
    }
    // MARK: pause menu
    static let menuItems = 4
    func openMenu() {
        guard mode != .title, !paused else { return }
        paused = true; menuSel = 0; menuShip = shipIndex; keys.removeAll(); mouse = .zero; dragging = false
        sfx?.beep()
    }
    func closeMenu() { paused = false; keys.removeAll(); mouse = .zero }
    /// keyboard input while the menu is open
    func menuKey(_ k: UInt16) {
        switch k {
        case Key.esc: closeMenu()
        case Key.up, Key.w: menuSel = (menuSel + Game.menuItems - 1) % Game.menuItems; sfx?.tick(3)
        case Key.down, Key.s: menuSel = (menuSel + 1) % Game.menuItems; sfx?.tick(3)
        case Key.left, Key.a: menuSel = 1; menuShip = (menuShip + ships.count - 1) % ships.count; sfx?.servo()
        case Key.right, Key.d: menuSel = 1; menuShip = (menuShip + 1) % ships.count; sfx?.servo()
        case Key.enter, Key.space:
            switch menuSel {
            case 0: closeMenu()
            case 1: if menuShip != shipIndex { swapShip(to: menuShip) }; closeMenu()
            case 2: break                                  // settings: opened by the view
            default: returnToTitle()
            }
        default: break
        }
    }
    /// trade the current ship for another one, right where you are
    func swapShip(to i: Int) {
        guard i != shipIndex, mode != .title else { return }
        if sh.active { sfx?.denied(); say("wait until your ship has landed"); return }
        leaveAboard(silent: true)
        if driving || !rover.inShip { sfx?.denied(); say("park the rover back in the bay first"); return }
        rover = Rover(); cargoWant = false; liftWant = false; doorK = 0; liftK = 0
        shipIndex = i; sfx?.pitch = ship.pitch; setBurner(false)
        if mode == .landed || mode == .walk, let W = landedOn ?? w.world {
            // stand the new ship on its own landing gear
            let up = simd_normalize(pos - W.pos)
            pos = W.pos + up * (surfaceR(W, up) + gearH)
            dockedAt = depotUnderShip()
            if mode == .walk && simd_distance(w.pos, pos) < size * ship.exitSide * 1.2 {
                // a bigger ship would swallow the explorer: step them out beside it
                let dir = simd_normalize(pos + q.act(D3(ship.exitSide * size, 0, 0)) - W.pos)
                w.pos = W.pos + dir * surfaceR(W, dir); w.vel = .zero; w.vUp = 0
            }
        }
        if mode == .hover { hoverAlt = max(hoverAlt, 0.002 * min(size / 0.05, 3.5)) }
        say("now flying the \(ship.name) · \(ship.role.lowercased())")
    }
    /// leave the game and go back to the title screen (ship selector)
    func returnToTitle() {
        paused = false; keys.removeAll(); mouse = .zero; aboard.on = false
        rover = Rover(); driving = false; cargoWant = false; liftWant = false; doorK = 0; liftK = 0
        mode = .title; auto = -1; setBurner(false); abLevel = 0; throttle = 0.35; v = 0; ang = .zero; hv = .zero; vv = 0
        cockpitView = false; lookYaw = 0; lookPitch = 0; landedOn = nil; dockedAt = nil; sh = SummonState()
        power = true; powerK = 1; gear = 0; gearTarget = 0; vtol = 0; landedK = 0; tilt = 0; fuel = 1
        showcaseYaw = 0.55; showcasePitch = 0.28
        showcase(0)
        sfx?.servo()
    }
    func setBurner(_ on: Bool) { if on == ab { return }; ab = on; if on { sfx?.burnerOn(); kick = 1; burnFlash = 1; say("afterburner") } else { sfx?.burnerOff() } }
    func toggleBurner() {
        guard mode == .fly else { return }
        if ab { setBurner(false); return }
        if fuel <= 0 { sfx?.denied(); say("no fuel for the afterburner"); return }
        if throttle < 0.97 { sfx?.denied(); say("full throttle first · hold W"); return }
        if alt < Game.burnerMinAlt { sfx?.denied(); say("too close to the ground for afterburner · climb above 2 km"); return }
        setBurner(true)
    }
    func startLanding() {
        if alt > 3 { say("get within 3 km of the ground to land"); return }
        if landingOverWater() { sfx?.denied(); say("water below · you can't land on the sea · find a beach or land"); return }
        setBurner(false); mode = .landing; auto = -1; say("landing on \(near.name)")
    }
    private var nag = 0.0
    var lastWaterNag = -10.0
    /// is there open water under the landing gear (anywhere the ship's footprint would sit)?
    func landingOverWater() -> Bool {
        let W = nearestWorld(pos), up = simd_normalize(pos - W.pos)
        guard W.sea else { return false }
        let a = simd_normalize(simd_cross(up, D3(0, 1, 0))), b = simd_cross(up, a), r = size * 0.35 / W.R
        for o in [D3.zero, a * r, -a * r, b * r, -b * r] where waterDepth(W, simd_normalize(up + o)) > 0.0006 { return true }
        return false
    }
    /// how low a hovering ship must be before you can step or jump out
    var hoverExitAlt: Double { 0.035 + size * 0.1 }
    static let hoverMaxAlt = 5000.0     // effectively anywhere: height is held above the nearest world's surface
    func toggleHover() {
        switch mode {
        case .fly:
            setBurner(false); auto = -1
            let up = simd_normalize(pos - near.pos)
            var f = forward * v; f -= up * simd_dot(f, up)
            hv = f; vv = 0; hoverAlt = max(0.004, alt)
            lookYaw = 0; lookPitch = 0
            mode = .hover; sfx?.lift(); say("hover mode · W S height · ↑ ↓ forward · A D strafe · ← → turn · mouse looks around")
        case .hover:
            mode = .fly; v = simd_length(hv); throttle = clampd(v / max(0.15, alt * 1.6 + 0.15), 0.15, 1); lastLvl = Int(throttle * 10)
            sfx?.beep(); say("flight mode")
        case .landed:
            if !power { takeOff(); return }
            hv = .zero; vv = 0; hoverAlt = 0.012 * min(size / 0.05, 5); lookYaw = 0; lookPitch = 0
            mode = .hover; landedOn = nil; dockedAt = nil; sfx?.lift(); say("lifting into a hover")
        default: break
        }
    }
    func takeOff() {
        if !power { if time - nag > 2.5 { say("ship is powered down · press P"); sfx?.denied(); nag = time }; return }
        if fuel <= 0 { if time - nag > 2.5 { sfx?.denied(); say("no fuel to lift off · F calls the emergency tanker"); nag = time }; return }
        if doorK > 0.01 { if time - nag > 2.5 { setCargoDoor(false); say("closing the cargo bay first"); nag = time }; return }
        if ship.cargo != nil && !rover.inShip && time - nag > 2.5 { say("the rover is still out on the surface"); nag = time }
        mode = .takeoff; takeoffT = 0; dockedAt = nil; sfx?.lift(); say("lift off")
    }
    func togglePower() {
        guard mode == .landed || mode == .walk else { say("land first to power down"); return }
        power.toggle()
        if power { sfx?.powerUp(); say("systems online") } else { sfx?.powerDown(); say("ship powered down") }
    }
    func keyDown(_ k: UInt16) {
        if mode == .title {
            if k == Key.enter { launch() }
            if k == Key.left { selectShip(-1) }
            if k == Key.right { selectShip(1) }
            return
        }
        if k == Key.q { scan(); return }
        if k == Key.f { callTanker(); return }
        if k == 31 && ship.cargo != nil {          // O: cargo bay doors and lift
            if mode == .landed || mode == .walk { setCargoDoor(!cargoWant) } else { sfx?.denied(); say("land first to open the cargo bay") }
            return
        }
        if aboard.on {
            switch k {
            case Key.i: leaveAboard()
            case Key.e: aboardUse()
            case Key.g, Key.v, Key.l, Key.p: sfx?.denied(); say("take the controls first · E at the seat or I")
            case Key.one, Key.two, Key.three:    // you can still set the autopilot from anywhere aboard
                let n = k == Key.one ? 0 : k == Key.two ? 1 : 2
                if mode == .fly { auto = n; sfx?.beep(); say("autopilot · \(worlds[n].name)") } else { sfx?.denied(); say("take the controls to lift off first") }
            default: break
            }
            return
        }
        if k == Key.i && mode != .walk { goAboard(); return }
        if k == Key.x && mode != .walk {
            // X anywhere near the ground: step out of the ship and take off as the robot
            if mode == .landed || mode == .hover {
                if mode == .hover { parkedHover = true }
                enterWalk(); keyDown(Key.x)
            } else { sfx?.denied(); say("X: fly as the robot · land or hover first (G)") }
            return
        }
        if mode == .walk {
            switch k {
            case Key.e: if driving { exitRover() } else if nearRover { enterRover() } else if nearShip { boardShip() } else { say("walk back to the ship to board") }
            case Key.r: summonShip()
            case Key.x:
                if driving { break }
                w.flying.toggle()
                if w.flying { w.onGround = false; w.vUp = max(w.vUp, 0.012); sfx?.burnerOn(); say("flying · W forward where you look · shift boost · space climb · X to drop") }
                else { sfx?.burnerOff(); say("falling · hit the ground hard for a superhero landing") }
            case Key.p: togglePower()
            default: break
            }
            return
        }
        switch k {
        case Key.e:
            if mode == .landed { enterWalk() }
            else if mode == .hover { parkedHover = true; enterWalk() }     // drop out at any height, even in space
        case Key.g: toggleHover()
        case Key.c:
            camMode = (camMode + 1) % 3; flyCam = nil; droneOff = nil; cockpitView = false; sfx?.beep()
            if camMode == 1 { extYaw = 0; extPitch = 0.22 }
            say(["chase camera", "orbit camera · mouse looks around the ship · scroll to zoom · keys still fly", "pass-by camera · watch yourself fly past"][camMode])
        case Key.v:
            cockpitView.toggle(); lookYaw = 0; lookPitch = 0; sfx?.beep()
            say(cockpitView ? "cockpit view · V for chase view" : "chase view")
        case Key.one, Key.two, Key.three:
            let n = k == Key.one ? 0 : k == Key.two ? 1 : 2
            if mode == .landed { takeOff() }
            if mode == .hover { toggleHover() }
            auto = n; sfx?.beep(); say("autopilot · \(worlds[n].name)")
        case Key.l: if mode == .fly || mode == .hover { startLanding() } else if mode == .landed { takeOff() }
        case Key.p: togglePower()
        default: break
        }
    }
    func shiftPressed() { if aboard.on { return }; if mode == .hover { sfx?.denied(); say("press G to leave hover first") } else if mode != .title { toggleBurner() } }

    // MARK: per-frame update
    func update(_ dt: Double) {
        if paused { mouse = .zero; return }      // the world holds still behind the menu
        time += dt
        if mode == .title { showcase(dt); return }
        updateFuel(dt)
        tankerStep(dt)
        cargoStep(dt)
        dustT += dt; heroLandT += dt; heroBoomT += dt
        ageCracks(dt)
        engineK = damp(engineK, fuel > 0 ? 1 : 0, fuel > 0 ? 3 : 1.5, dt)
        if mode == .walk { walkFrame(dt); return }
        let heldKeys = keys, heldMouse = mouse
        if aboard.on { keys = []; mouse = .zero }       // you're walking the deck: the ship flies on by herself
        let best = nearestWorld(pos)
        near = best
        let up = simd_normalize(pos - best.pos)
        alt = simd_distance(pos, best.pos) - surfaceR(best, up) - gearH
        let seaAlt = simd_distance(pos, best.pos) - best.R
        airDensity = seaAlt < best.atmo.top ? exp(-max(seaAlt, 0) / Double(best.atmo.rayleighH)) : 0

        // outside cameras: the mouse looks around the ship instead of steering it
        if camMode != 0 && !cockpitView && (mode == .fly || mode == .hover) && !aboard.on {
            if camMode == 1 {
                extYaw -= mouse.x * 0.005
                extPitch = clampd(extPitch + mouse.y * 0.004, -1.3, 1.4)
            }
            mouse = .zero
        }
        switch mode {
        case .fly: flyStep(dt, best, up)
        case .hover: hoverStep(dt, best, up)
        case .landing: landStep(dt, best, up)
        case .takeoff: takeoffStep(dt, up)
        case .landed:
            if keys.contains(Key.up) || keys.contains(Key.w) || keys.contains(Key.space) { takeOff() }
            if cockpitView && dragging { freeLook() }
        case .title, .walk: break
        }
        mouse = .zero

        let gT = (mode != .fly && mode != .hover) || alt < (mode == .hover ? 0.15 : 0.4) ? 1.0 : 0.0
        if gT != gearTarget { if time > 0.5 { sfx?.servo() }; gearTarget = gT }
        gear = damp(gear, gT, 2.2, dt)
        landedK = damp(landedK, mode == .landed ? 1 : 0, 1.2, dt)
        abLevel = damp(abLevel, ab ? 1 : 0, ab ? 2.5 : 1.4, dt)
        let vT = mode == .landing || mode == .takeoff || mode == .hover ? 1.0 : (mode == .fly && alt < min(size, 0.085) * 8 && v < min(size, 0.085) * 6 ? 0.55 : 0)
        vtol = damp(vtol, vT, 4, dt)
        tilt = damp(tilt, mode == .fly ? 0 : 1, 1.5, dt)
        powerK = damp(powerK, power ? 1 : 0, power ? 1.8 : 1.1, dt)
        bounceT += dt
        sfx?.engine(throttle: mode == .landed ? 0 : (mode == .fly ? throttle : mode == .hover ? 0.4 + min(0.4, simd_length(hv) * 10) : 0.5), ab: abLevel, on: power && fuel > 0)
        sfx?.flight(0); sfx?.jet(0)          // the robot's wind and jetpack stop once you're aboard
        // afterburner kick, sonic boom at Mach 1, vapour cone in the transonic zone
        kick *= exp(-dt * 2.2); burnFlash *= exp(-dt * 3.5); shockT += dt
        if mode == .fly && airDensity > 0.02 {
            if machArmed && mach >= 1 { machArmed = false; sfx?.sonicBoom(); kick = max(kick, 1.4); shockT = 0; say("Mach 1 · sonic boom") }
            else if mach < 0.9 { machArmed = true }
        }
        let trans = mode == .fly && airDensity > 0.02 ? (1 - ss(0.05, 0.4, abs(mach - 1))) * min(1, airDensity * 3) : 0
        vapor = damp(vapor, trans, trans > vapor ? 8 : 0.9, dt)
        if mode != .fly { heat = damp(heat, 0, 1.5, dt) }
        if heat > 0.05 { kick = max(kick, heat * 0.35) }                 // the buffeting of re-entry
        followCamera(dt, best)
        if aboard.on {
            if ![.fly, .hover, .landed, .landing, .takeoff].contains(mode) { aboard.on = false }
            else { keys = heldKeys; aboardStep(dt, keys: heldKeys, mouse: heldMouse) }
        }
        if let o = overrideCam { camPos = o.0; camQ = o.1 }
        updateStreaks(dt)
    }

    private func flyStep(_ dt: Double, _ best: World, _ up: D3) {
        let k = keys
        // arrows pitch and yaw, A/D roll, W/S throttle
        let ag = ship.agility, heavy = sqrt(ship.mass)   // heavy ships: slow to start turning, slow to stop
        ang.x += ((k.contains(Key.up) ? 1 : 0) - (k.contains(Key.down) ? 1 : 0)) * dt * 2.2 * ag
        ang.y += ((k.contains(Key.left) ? 1 : 0) - (k.contains(Key.right) ? 1 : 0)) * dt * 2.2 * ag
        ang.z += ((k.contains(Key.a) ? 1 : 0) - (k.contains(Key.d) ? 1 : 0)) * dt * 3 * ag
        ang.y -= mouse.x * 0.0022 * ag; ang.x -= mouse.y * 0.0022 * ag
        if auto >= 0 && abs(mouse.x) + abs(mouse.y) > 6 { auto = -1 }
        ang *= exp(-dt * 3.2 / heavy)
        if heavy > 1.2 { ang.z *= exp(-dt * 2) }                 // a carrier barely rolls
        q = q * axisAngle(D3(1, 0, 0), ang.x * dt) * axisAngle(D3(0, 1, 0), ang.y * dt) * axisAngle(D3(0, 0, 1), ang.z * dt)
        q = q.normalized

        if k.contains(Key.w) { throttle = clampd(throttle + dt * 0.5, 0, 1) }
        if k.contains(Key.s) { throttle = clampd(throttle - dt * 0.5, 0, 1) }
        if k.contains(Key.space) { throttle = damp(throttle, 0, 4, dt) }
        if k.contains(Key.w) || k.contains(Key.s) {
            let lvl = Int(floor(throttle * 10 + 1e-6))
            if lvl != lastLvl { lvl == 10 ? sfx?.full() : sfx?.tick(lvl); if lvl == 10 { say("full throttle · shift for afterburner") }; lastLvl = lvl }
        }
        if fuel <= 0 { throttle = 0; auto = -1 }               // engines dead: you coast
        if ab && throttle < 0.97 { setBurner(false) }
        if ab && alt < Game.burnerCutAlt { setBurner(false); sfx?.denied(); say("afterburner cut · too low") }

        if auto >= 0 {
            let T = worlds[auto], dist = simd_distance(pos, T.pos) - T.R
            var aim = simd_normalize(T.pos - pos)
            if best !== T {
                let away = simd_normalize(pos - best.pos)
                if simd_dot(aim, away) < 0.35 && alt < best.R * 0.8 { aim = simd_normalize(aim + away * 0.9) }
            }
            q = slerpShort(q, lookRotation(forward: aim, up: q.act(D3(0, 1, 0))), 1 - exp(-dt * 1.4))
            throttle = 1
            if dist < T.R * 0.9 { auto = -1; throttle = 0; setBurner(false); sfx?.arrive(); say("arrived · \(T.name) · fly low and press L to land") }
        }
        // engines: top speed grows with height above the ground (so the world never feels too slow or too fast)
        // afterburner: an air-breathing boost, strongest where the air is thick
        let rho = airDensity
        var maxV = clampd(alt * 1.6 + 0.15, 0.15, Game.cruiseMax) * (1 + abLevel * (2 + 3 * min(1, rho * 4)))
        // closing on a world: slow toward orbital speed (8 km/s) as you reach the top of its air, so entry takes time
        let seaAltNow = simd_distance(pos, best.pos) - best.R, airTop = best.atmo.top
        maxV = min(maxV, seaAltNow > airTop ? 8 + (seaAltNow - airTop) * 0.5 : 7.5)
        // inside an atmosphere, drag caps the speed, rising as the air thins
        if rho > 1e-4 {
            // about Mach 2.6 at sea level, Mach 7 on afterburner; at most 7.5 km/s (orbital speed) at the top of the air
            let dragCap = min(7.5, (0.9 + abLevel * 1.5) / sqrt(rho))
            maxV = min(maxV, dragCap)
        }
        maxV *= ship.speedK
        if auto >= 0 { let T = worlds[auto]; maxV = min(maxV, max(50, (simd_distance(pos, T.pos) - T.R * 0.9) * 0.8)) }
        let vT = pow(throttle, 1.4) * maxV
        if fuel <= 0 {
            // out of fuel: coast, bleeding speed in the air, and glide slowly down
            v *= exp(-dt * 0.12 * min(1, airDensity * 4))
            if airDensity > 0.01 { pos -= up * min(0.05, 0.01 + v * 0.03) * dt }
        } else {
            // the air slows you over many seconds, not instantly: arriving fast from space means a long, glowing entry
            let overspeed = rho > 1e-4 && v > vT * 1.02
            let brake = overspeed ? (0.12 + 0.8 * min(1, rho * 2)) : 6
            v = damp(v, vT, vT < v ? brake : (2.2 + abLevel * 1.5) / ship.mass, dt)
            heat = damp(heat, overspeed ? clampd((v / max(vT, 0.05) - 1) * 0.6, 0, 1) * min(1, rho * 200) : 0, overspeed ? 3 : 1.2, dt)
        }
        pos += forward * v * dt

        let d = simd_distance(pos, best.pos), minR = surfaceR(best, up) + gearH
        if d < minR {
            pos = best.pos + up * minR
            if v < 0.25 {
                if landingOverWater() {
                    if time - lastWaterNag > 4 { lastWaterNag = time; sfx?.denied(); say("skimming the water · climb, or find land to set down") }
                } else { setBurner(false); mode = .landing; auto = -1; say("touching down on \(best.name)") }
            }
        }
    }

    private func landStep(_ dt: Double, _ best: World, _ up: D3) {
        q = slerpShort(q, levelQuat(up: up), 1 - exp(-dt * 2.75))
        let ground = surfaceR(best, up) + gearH, gap = simd_distance(pos, best.pos) - ground
        // descend quickly while high, then ease onto the gear at well under a metre per second
        let k = size / 0.05
        let rate = gap > 0.03 * k ? max(0.0035 * k, gap * 1.2) : max(0.0004 * min(k, 1.8), gap * 1.6)
        let sink = rate * (gear > 0.85 || gap > size * 3 ? 1 : 0.15) * dt
        v = damp(v, 0, 3, dt); hv = .zero
        pos += forward * v * dt
        let target = levelQuat(up: up)
        let angleOff = 2 * acos(min(1, abs(simd_dot(q.vector, target.vector))))
        if gap <= sink + 1e-4 && angleOff < 0.05 {
            pos = best.pos + up * ground; q = target
            mode = .landed; v = 0; throttle = 0; landedOn = best; bounceT = 0
            touchdown()
            say("landed on \(best.name)")
            checkDock()
            orbitYaw = 0.7; orbitPitch = 0.22
        } else { pos -= up * min(sink, gap) }
    }

    /// the moment of touchdown: a thud for small ships, a ground-shaking landing for the heavy ones
    func touchdown() {
        dustT = 0
        let heavy = clampd((size - 0.05) / 0.5, 0, 1)
        kick = max(kick, 0.4 + heavy * 1.4)
        if heavy > 0.05 { sfx?.heavyLand(heavy) } else { sfx?.thud() }
        if ship.cargo != nil { setCargoDoor(true) }
    }

    /// mouse free look (hover, and the cockpit while parked)
    private func freeLook() {
        lookYaw -= mouse.x * 0.004
        lookPitch = clampd(lookPitch - mouse.y * 0.003, cockpitView ? -1.0 : -0.9, cockpitView ? 1.0 : 0.35)
        if lookYaw > .pi { lookYaw -= 2 * .pi } else if lookYaw < -.pi { lookYaw += 2 * .pi }
    }

    private func hoverStep(_ dt: Double, _ best: World, _ up: D3) {
        let k = keys, s = min(size / 0.05, 3.5)      // bigger ships hover faster, up to a point
        // turn: arrows and mouse
        ang.y += ((k.contains(Key.left) ? 1 : 0) - (k.contains(Key.right) ? 1 : 0)) * dt * 2.0 * ship.agility
        freeLook()
        ang *= exp(-dt * 4)
        var level = levelQuat(up: up)
        level = simd_quatd(angle: ang.y * dt, axis: up) * level
        let fwd = level.act(D3(0, 0, -1)), right = level.act(D3(1, 0, 0))
        // move: WASD in the horizontal plane, space brakes
        let inF = (k.contains(Key.up) ? 1.0 : 0) - (k.contains(Key.down) ? 1.0 : 0)
        let inS = (k.contains(Key.d) ? 1.0 : 0) - (k.contains(Key.a) ? 1.0 : 0)
        let mass = ship.mass
        let maxH = 0.045 * s / sqrt(mass)
        var flat = hv - up * simd_dot(hv, up)
        let want = (fwd * inF + right * inS * 0.7) * maxH
        let prev = flat
        flat = k.contains(Key.space) ? flat * exp(-dt * 3 / mass) : flat + (want - flat) * (1 - exp(-dt * (inF != 0 || inS != 0 ? 1.4 : 0.9) / mass))
        let accel = (flat - prev) / max(dt, 1e-4)
        hv = flat
        // height: W climbs, S descends (faster the higher you are)
        let inV = (k.contains(Key.w) ? 1.0 : 0) - (k.contains(Key.s) ? 1.0 : 0)
        hoverAlt = clampd(hoverAlt + inV * dt * (0.006 * s + hoverAlt * 0.35), 0.002 * s, Game.hoverMaxAlt)
        if fuel <= 0 { hoverAlt = max(0.002 * s, hoverAlt - dt * (0.003 * s + hoverAlt * 0.2)) }   // no fuel: sink gently
        let ground = surfaceR(best, up) + gearH
        let err = ground + hoverAlt - simd_distance(pos, best.pos)
        let vMax = max(0.03 * s, hoverAlt * 0.8)
        vv = damp(vv, clampd(err * 1.8 / sqrt(mass), -vMax, vMax), 3 / mass, dt)
        pos += hv * dt + up * vv * dt
        let u2 = simd_normalize(pos - best.pos), floor = surfaceR(best, u2) + gearH
        if simd_distance(pos, best.pos) < floor { pos = best.pos + u2 * floor; vv = max(vv, 0) }
        v = simd_length(hv)
        // lean into the motion like a real VTOL: nose down accelerating forward, bank into strafes and turns
        let pitch = clampd(-simd_dot(accel, fwd) / (0.03 * s) * 0.12 - simd_dot(hv, fwd) / maxH * 0.06, -0.25, 0.25)
        let roll = clampd(-simd_dot(hv, right) / maxH * 0.18 - ang.y * 0.08, -0.3, 0.3)
        let target = level * axisAngle(D3(1, 0, 0), pitch) * axisAngle(D3(0, 0, 1), roll)
        q = slerpShort(q, target, 1 - exp(-dt * 2.5 / sqrt(mass))).normalized     // settle level gently
    }

    private func takeoffStep(_ dt: Double, _ up: D3) {
        takeoffT += dt
        pos += up * (0.012 + takeoffT * takeoffT * 0.05) * 1.05 * dt
        if takeoffT > 0.6 { q = q * axisAngle(D3(1, 0, 0), dt * 0.25 * min(1, takeoffT - 0.6)) }
        if takeoffT > 3.0 { mode = .fly; throttle = 0.25; v = 0.05; landedOn = nil }
    }

    /// an off-centre chase camera turns a little toward the ship
    private var chaseYaw: Double { guard let c = ship.chase else { return 0 }; return atan2(c.x, c.z + size) * 0.75 }

    private func followCamera(_ dt: Double, _ best: World) {
        let k = size / 0.05 * ship.camScale
        let shipModes: [Mode] = [.fly, .hover, .landing, .landed, .takeoff]
        if cockpitView && shipModes.contains(mode) {
            // pilot's seat: the view turns with the ship; free look turns your head
            if mode == .fly || mode == .takeoff { lookYaw = damp(lookYaw, 0, 3, dt); lookPitch = damp(lookPitch, 0, 3, dt) }
            // a gentle engine rumble (smooth, a centimetre or two), not a random jolt every frame
            let rumble = (abLevel * 0.000015 + (mode == .fly ? throttle * 0.000003 : 0)) * k
            let wob = D3(sin(time * 23) + 0.5 * sin(time * 37.3), sin(time * 29.7) + 0.5 * sin(time * 17.1), 0)
            camPos = pos + q.act(ship.eye * (size / ship.length)) + q.act(wob * rumble)
            camQ = q * simd_quatd(angle: lookYaw, axis: D3(0, 1, 0)) * simd_quatd(angle: lookPitch - 0.05, axis: D3(1, 0, 0))
            camBase = q
            let fovT = 72 + (mode == .fly ? throttle * 3 + abLevel * 12 : 0)
            fov = damp(fov, fovT, 3, dt)
            camPos += q.act(D3(sin(time * 41), sin(time * 37 + 1), 0) * kick * 0.00004 * k)
            return
        }
        if (mode == .fly || mode == .hover) && camMode != 0 { filmingCamera(dt, best, k); return }
        if mode == .hover {
            // the same chase camera as in flight, but it follows only the ship's heading (not its lean);
            // moving the mouse swings it around the ship
            let up = simd_normalize(pos - best.pos)
            camBase = slerpShort(camBase, levelQuat(up: up), 1 - exp(-dt * 5 / ship.mass))
            let orbit = camBase * simd_quatd(angle: lookYaw, axis: D3(0, 1, 0)) * simd_quatd(angle: lookPitch, axis: D3(1, 0, 0))
            camPos = pos + orbit.act(ship.chase ?? D3(0, 0.024, 0.105) * k)
            camQ = orbit * axisAngle(D3(0, 1, 0), chaseYaw) * axisAngle(D3(1, 0, 0), -0.14)
            let cu = simd_normalize(camPos - best.pos), gr = best.groundRadius(cu) + 0.003
            if simd_distance(camPos, best.pos) < gr { camPos = best.pos + cu * gr }
            fov = damp(fov, 62, 3, dt)
            return
        }
        if mode == .landed || mode == .landing {
            let up = simd_normalize(pos - best.pos)
            let r = 0.14 * k, cp = cos(orbitPitch)
            if dragging { orbitYaw -= mouse.x * 0.006; orbitPitch = clampd(orbitPitch + mouse.y * 0.004, 0.02, 1.3) }
            let off = q.act(D3(sin(orbitYaw) * cp, sin(orbitPitch), cos(orbitYaw) * cp) * r)
            camPos = mixd(camPos, pos + off, 1 - exp(-dt * 4))
            camQ = lookRotation(forward: simd_normalize(pos + up * 0.006 * k - camPos), up: up); camBase = q
        } else {
            camBase = slerpShort(camBase, q, 1 - exp(-dt * 5 / ship.mass))
            let shake = abLevel * 0.0009
            var off = D3(sin(time * 21) * 0.5 * shake, abLevel * 0.006 + sin(time * 26.3 + 1) * 0.5 * shake, abLevel * 0.035)   // smooth rumble
            off *= k
            off += ship.chase ?? D3(0, 0.024, 0.105) * k
            camPos = pos + camBase.act(off)
            camQ = camBase * axisAngle(D3(0, 1, 0), chaseYaw) * axisAngle(D3(1, 0, 0), -0.14)
        }
        // keep the camera above the terrain
        let cu = simd_normalize(camPos - best.pos), gr = best.groundRadius(cu) + 0.006
        if simd_distance(camPos, best.pos) < gr { camPos = best.pos + cu * gr }
        let fovT = mode == .fly ? 62 + throttle * 2 + abLevel * 14 : 62
        fov = damp(fov, fovT, 3, dt)
        if kick > 0.01 { camPos += camQ.act(D3(sin(time * 33), sin(time * 29 + 1), 0) * kick * 0.0012 * k) }
        if mode != .fly && mode != .landed && mode != .landing { camQ = camQ.normalized }
    }

    /// cameras outside the ship: an orbit camera you swing round with the mouse, or a pass-by camera you fly past
    private func filmingCamera(_ dt: Double, _ best: World, _ k: Double) {
        let up = simd_normalize(pos - best.pos)
        let travel: D3 = mode == .fly ? forward : (simd_length(hv) > 1e-5 ? simd_normalize(hv) : forward)
        let speed = mode == .fly ? v : simd_length(hv)
        func keepAbove(_ p: D3) -> D3 {
            let u = simd_normalize(p - best.pos), g = best.groundRadius(u) + 0.004
            return simd_distance(p, best.pos) < g ? best.pos + u * g : p
        }
        if camMode == 1 || speed > 60 {
            // orbit: a camera on a boom around the ship; the mouse swings it round, the scroll wheel sets the distance
            camBase = slerpShort(camBase, levelQuat(up: up), 1 - exp(-dt * 2.5))
            let boom = camBase * simd_quatd(angle: extYaw, axis: D3(0, 1, 0)) * simd_quatd(angle: -extPitch, axis: D3(1, 0, 0))
            let dist = size * 9 * ship.camScale * extZoom
            camPos = keepAbove(pos + boom.act(D3(0, 0, dist)))
            camQ = lookRotation(forward: simd_normalize(pos - camPos), up: up)
            fov = damp(fov, 50, 2, dt)
            if kick > 0.01 { camPos += camQ.act(D3(sin(time * 33), sin(time * 29 + 1), 0) * kick * 0.0016 * k) }
            return
        }
        // film crew: set up ahead of you and off to one side, follow you through the pass, then move on
        let lead = clampd(speed * 2.6, size * 10, 160)        // the shot lasts a couple of seconds at any speed
        if let fc = flyCam {
            let along = simd_dot(pos - fc, travel), d = simd_distance(pos, fc)
            if along > lead * 0.8 || d > lead * 3 { flyCam = nil }
        }
        if flyCam == nil {
            flyCamSide = -flyCamSide
            let side = simd_normalize(simd_cross(travel, up)) * (size * 2.5 + lead * 0.2) * flyCamSide
            flyCam = keepAbove(pos + travel * lead + side + up * (size * 0.8 + lead * 0.04))
        }
        let d = simd_distance(pos, flyCam!)
        // a hand-held feel: slow drift and a little breathing
        let hand = D3(sin(time * 0.7) * 0.6 + sin(time * 1.9) * 0.2, sin(time * 0.53 + 1) * 0.5, 0) * 0.004
        camPos = flyCam!
        camQ = lookRotation(forward: simd_normalize(pos + travel * size * 0.2 - camPos), up: up) * simd_quatd(angle: hand.x, axis: D3(0, 1, 0)) * simd_quatd(angle: hand.y, axis: D3(1, 0, 0))
        // zoom so the ship stays a good size in frame
        let fovT = clampd(2 * atan(size * 1.4 / d) * 180 / .pi, 4, 60)
        fov = damp(fov, fovT, 3, dt)
    }

    private func showcase(_ dt: Double) {
        // the ship holds still, nose toward Earth; dragging only swings the camera around it
        if dragging { showcaseYaw += mouse.x * 0.006; showcasePitch = clampd(showcasePitch + mouse.y * 0.004, -0.4, 0.9) }
        mouse = .zero
        let E = worlds[0], toE = simd_normalize(E.pos - scPos)
        let fwdT = simd_normalize(toE * cos(0.72) + scSide * sin(0.72))      // aimed partway down toward the planet
        let upT = simd_normalize(scUp - fwdT * simd_dot(scUp, fwdT))
        // alive: she breathes on her engines, bobbing and swaying gently while she holds her heading
        let t = time, rightT = simd_normalize(simd_cross(fwdT, upT))
        let sway = simd_quatd(angle: sin(t * 0.47) * 0.045, axis: fwdT) * simd_quatd(angle: sin(t * 0.31 + 1) * 0.025, axis: rightT) * simd_quatd(angle: sin(t * 0.23) * 0.02, axis: upT)
        q = sway * lookRotation(forward: fwdT, up: upT)
        pos = scPos + upT * sin(t * 0.6) * size * 0.035 + rightT * sin(t * 0.37) * size * 0.02
        tilt = 0; gear = 0; vtol = 0
        let d = size * 2.6 * ship.camScale * showcaseZoom
        // the camera drifts slowly round her when you're not dragging it
        if !dragging { showcaseYaw += sin(t * 0.09) * 0.0006; showcasePitch += sin(t * 0.07 + 2) * 0.00025 }
        let back = simd_quatd(angle: showcaseYaw, axis: upT).act(-fwdT)
        let offs = simd_normalize(back * cos(showcasePitch) + upT * sin(showcasePitch))
        camPos = scPos + offs * d
        let right = simd_normalize(simd_cross(fwdT, upT))
        let look = scPos + fwdT * size * 0.35 - upT * size * 0.55 * showcaseZoom + right * size * 0.05   // the ship sits centred, above the picker
        camQ = lookRotation(forward: simd_normalize(look - camPos), up: upT)
        fov = 62
        near = worlds[0]; alt = simd_distance(pos, near.pos) - near.R
        updateStreaks(dt)
    }

    private func updateStreaks(_ dt: Double) {
        let flying = mode == .fly ? 1.0 : 0.0
        let rate = (0.25 + throttle * 0.9 + abLevel * 4) * flying
        streakOpacity = aboard.on ? 0 : Float(flying * clampd(throttle * 0.12 + abLevel * 0.55, 0, 0.6))
        streakColor = SIMD3(Float(0.66 + abLevel * 0.34), Float(0.8 - abLevel * 0.15), Float(1 - abLevel * 0.45))
        if streakOpacity < 0.005 { return }
        let len = 0.01 + rate * 0.06
        for i in 0..<streakSeed.count {
            streakSeed[i].z += rate * dt
            if streakSeed[i].z > 0.1 { streakSeed[i] = Game.newStreak(z: -2.2 + Double.random(in: 0...0.2)) }
            let s = streakSeed[i]
            streaks[i * 6] = Float(s.x); streaks[i * 6 + 1] = Float(s.y); streaks[i * 6 + 2] = Float(s.z)
            streaks[i * 6 + 3] = Float(s.x); streaks[i * 6 + 4] = Float(s.y); streaks[i * 6 + 5] = Float(s.z - len)
        }
    }

    /// pitch, roll and compass heading (degrees) relative to the local horizon of the nearest world
    var attitude: (pitch: Double, roll: Double, heading: Double) {
        let up = simd_normalize(pos - near.pos), f = forward
        let pitch = asin(clampd(simd_dot(f, up), -1, 1)) * 180 / .pi
        let roll = atan2(-simd_dot(q.act(D3(1, 0, 0)), up), simd_dot(q.act(D3(0, 1, 0)), up)) * 180 / .pi
        var north = D3(0, 1, 0) - up * up.y
        if simd_length(north) < 1e-6 { north = D3(0, 0, -1) - up * simd_dot(D3(0, 0, -1), up) }
        north = simd_normalize(north)
        let east = simd_cross(north, up)
        var fh = f - up * simd_dot(f, up); if simd_length(fh) < 1e-6 { fh = q.act(D3(0, 1, 0)) }
        var hdg = atan2(simd_dot(fh, east), simd_dot(fh, north)) * 180 / .pi
        if hdg < 0 { hdg += 360 }
        return (pitch, roll, hdg)
    }
    func snapCamera() { camBase = q }
    var overrideCam: (D3, simd_quatd)?   // fixed camera used by the snapshot tool
    /// effective engine thrust for the flames
    var thrust: Double { mode == .walk ? (sh.active || parkedHover ? summonThrust : 0.08) : mode == .landed ? 0.08 : (mode == .fly ? 0.25 + throttle * 0.75 : mode == .title ? 0.36 + 0.14 * sin(time * 0.8) : 0.45) }
}
