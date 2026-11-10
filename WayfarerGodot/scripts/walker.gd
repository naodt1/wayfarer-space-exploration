## The explorer on foot (a port of Walker.swift): walk, run (Shift), jump and the jetpack (Space), superhero flight (X)
## with a sonic boom at Mach 1, the kneeling superhero landing that cracks the ground, an over-the-shoulder camera.
## Positions are metres from the planet centre in double precision (three floats).
class_name Walker
extends RefCounted

const WALK := 3.0
const RUN := 7.8

var px := 0.0; var py := 0.0; var pz := 0.0
var fwd := Vector3.FORWARD; var cam_fwd := Vector3.FORWARD
var vel := Vector3.ZERO; var v_up := 0.0
var on_ground := true; var air := 0.0; var jet := 0.0; var land := 0.0; var turn := 0.0
var phase := 0.0; var last_step := 0; var pitch := 0.2
var cx := 0.0; var cy := 0.0; var cz := 0.0          # camera (double)
var cam_basis := Basis.IDENTITY
var fov := 62.0
var pose := {"lt": 0.0, "lk": 0.0, "rt": 0.0, "rk": 0.0, "la": 0.0, "le": 0.0, "ra": 0.0, "re": 0.0, "laz": 0.0, "raz": 0.0,
	"lean": 0.0, "roll": 0.0, "bob": 0.0, "crouch": 0.0}
var flying := false; var hero_land := 0.0; var fly_tilt := 0.0
var mach_armed := true
var idle_t := 0.0; var idle_k := 1.0
var speed := 0.0
var body_basis := Basis.IDENTITY                    # the robot's orientation (leans into flight)

## events for the game to react to (sounds, effects, messages)
signal sonic_boom(at: Vector3)
signal hero_landed(at: Vector3, hard: float)
signal step(k: float)
signal message(text: String)

func pos() -> Vector3: return Vector3(px, py, pz)

func place(p: Vector3, forward: Vector3) -> void:
	px = p.x; py = p.y; pz = p.z
	var up := p.normalized()
	fwd = (forward - up * forward.dot(up)).normalized(); cam_fwd = fwd
	flying = false; hero_land = 0.0; fly_tilt = 0.0; vel = Vector3.ZERO; v_up = 0.0; on_ground = true; pitch = 0.2; land = 0.0
	var c := p + up * 2.0 - fwd * 5.0
	cx = c.x; cy = c.y; cz = c.z

func step_frame(dt: float, planet: Planet, mouse: Vector2, k: Callable, shift: bool, time: float) -> void:
	var p := Vector3(px, py, pz)
	var up := p.normalized()
	var flat := func(v: Vector3) -> Vector3:
		var x := v - up * v.dot(up)
		if x.length_squared() < 1e-12: x = up.cross(Vector3.RIGHT)
		return x.normalized()
	fwd = flat.call(fwd); cam_fwd = flat.call(cam_fwd)
	cam_fwd = cam_fwd.rotated(up, -mouse.x * 0.004)
	pitch = clampf(pitch + mouse.y * 0.003, -1.2 if flying else -0.25, 1.45 if flying else 1.2)
	var cam_right := cam_fwd.cross(up)
	var f: float = k.call(KEY_W) + k.call(KEY_UP) - k.call(KEY_S) - k.call(KEY_DOWN)
	f = clampf(f, -1.0, 1.0)
	var s: float = clampf(k.call(KEY_D) + k.call(KEY_RIGHT) - k.call(KEY_A) - k.call(KEY_LEFT), -1.0, 1.0)
	var move := cam_fwd * f + cam_right * s
	if move.length_squared() > 0: move = move.normalized()
	var g := 9.8 * planet.gravity
	var space: bool = k.call(KEY_SPACE) > 0.5
	if flying:
		var ap := pitch - 0.2
		var aim := (cam_fwd * cos(ap) - up * sin(ap)).normalized()
		var sp := 1400.0 if shift else 250.0
		var want := aim * sp * maxf(0, f) - aim * 20.0 * maxf(0, -f) + cam_right * s * sp * 0.4 + up * (30.0 if space else 0.0)
		var v3 := vel + up * v_up
		v3 = v3.lerp(want, 1.0 - exp(-dt * (0.9 if shift else 2.4)))
		v_up = v3.dot(up); vel = v3 - up * v_up
		fwd = cam_fwd
		var mach := v3.length() / 343.0
		var in_air := p.length() - planet.R < planet.atmo_top
		if in_air and mach_armed and mach >= 1.0:
			mach_armed = false; sonic_boom.emit(p); message.emit("Mach 1 · sonic boom")
		elif mach < 0.9: mach_armed = true
	else:
		var target := move * (RUN if shift else WALK)
		var accel := (6.0 if target.length_squared() > 0 else 9.0) if on_ground else 1.2
		vel = vel.lerp(target, 1.0 - exp(-dt * (0.0 if hero_land > 0.3 else accel)))
		vel -= up * vel.dot(up)
		# the sea: paddle into the shallows, but no further
		var nu := (p + vel * dt).normalized()
		if on_ground and planet.sea and planet.height(nu, 14) < -0.0011 and planet.height(nu, 14) < planet.height(up, 14):
			vel = Vector3.ZERO
	p += vel * dt
	# jump, then hold space for the jetpack
	air = 0.0 if on_ground else air + dt
	if space and on_ground and not flying and hero_land < 0.3:
		v_up = 4.2; on_ground = false; land = -0.6; step.emit(0.6)
	var thrusting := space and not on_ground and air > 0.22 and not flying
	var fly_speed := (vel + up * v_up).length()
	jet = lerpf(jet, 1.0 if thrusting else (0.25 + minf(0.75, fly_speed / 200.0) if flying else 0.0), 1.0 - exp(-dt * 10.0))
	if thrusting: v_up += 9.8 * 1.7 * dt
	if not flying: v_up -= g * dt
	hero_land = maxf(0.0, hero_land - dt)
	p += up * v_up * dt
	var dist := p.length(); up = p / dist
	var gr := planet.ground_radius(up)
	if dist <= gr:
		p = up * gr
		var impact := maxf(0.0, -v_up) + (vel.length() * 0.35 if flying else 0.0)
		if not on_ground and impact > 14.0:
			var hard := clampf((impact - 14.0) / 80.0, 0.0, 1.0)
			flying = false; hero_land = 1.1 + hard * 0.5; vel = Vector3.ZERO
			hero_landed.emit(p, hard)
			message.emit("SUPERHERO LANDING" if hard > 0.6 else "landed")
		elif not on_ground:
			var hard := clampf(-v_up / 8.0, 0.0, 1.0); land = 0.35 + hard * 0.65
			if v_up < -2.0: step.emit(0.6 + hard)
			if flying and fly_speed < 10.0 and air > 0.4: flying = false
		v_up = maxf(0.0, v_up); on_ground = true
	elif dist > gr + 0.4: on_ground = false
	land = lerpf(land, 0.0, 1.0 - exp(-dt * 7.0))
	px = p.x; py = p.y; pz = p.z
	# the body turns toward where it moves
	var hvl := vel.length()
	var prev := fwd
	if hvl > 0.3: fwd = fwd.lerp(vel.normalized(), 1.0 - exp(-dt * 9.0)).normalized()
	var turn_rate := asin(clampf(prev.cross(fwd).dot(up), -1.0, 1.0)) / maxf(dt, 1e-3)
	turn = lerpf(turn, turn_rate, 1.0 - exp(-dt * 6.0))
	# walk-cycle targets
	var amp := clampf(hvl / 1.8, 0.0, 1.0)
	var run_k := clampf((hvl - WALK) / (RUN - WALK), 0.0, 1.0)
	var stride := 1.3 + run_k * 1.1
	phase += hvl * dt / stride * PI
	var sw := sin(phase)
	var T := {"lt": 0.0, "lk": 0.0, "rt": 0.0, "rk": 0.0, "la": 0.0, "le": 0.0, "ra": 0.0, "re": 0.0, "laz": 0.0, "raz": 0.0,
		"lean": 0.0, "roll": 0.0, "bob": 0.0, "crouch": 0.0}
	var fly_k := clampf(fly_speed / 50.0, 0.0, 1.0) if flying else 0.0
	if hero_land > 0:
		var k2 := minf(1.0, hero_land / 0.5)
		T.lt = 1.35 * k2; T.lk = 1.9 * k2; T.rt = -0.35 * k2; T.rk = 2.1 * k2
		T.ra = 0.95 * k2; T.re = 0.25; T.la = -0.5 * k2; T.le = 0.6; T.laz = -0.9 * k2; T.raz = 0.15
		T.lean = 0.75 * k2; T.crouch = 1.0 * k2; T.bob = -0.25 * k2
	elif flying:
		var bob := sin(time * 2.2) * 0.04 * (1.0 - fly_k)
		T.la = 0.3 + 2.6 * fly_k; T.le = 0.1; T.laz = -0.1
		T.ra = 0.1 - 0.35 * fly_k; T.re = 0.15; T.raz = 0.12 + 0.1 * fly_k
		T.lt = 0.08 - 0.15 * fly_k + bob; T.rt = -0.12 - 0.05 * fly_k; T.lk = 0.25 * (1.0 - fly_k) + 0.05; T.rk = 0.4 * (1.0 - fly_k) + 0.08
		T.lean = 0.05
	elif on_ground:
		T.lt = sw * (0.42 + 0.38 * run_k) * amp; T.rt = -T.lt
		T.lk = (0.12 + 0.95 * run_k) * maxf(0.0, sin(phase + 1.3)) * amp + 0.05
		T.rk = (0.12 + 0.95 * run_k) * maxf(0.0, sin(phase + 1.3 + PI)) * amp + 0.05
		T.la = -sw * (0.35 + 0.45 * run_k) * amp; T.ra = -T.la
		T.le = (0.18 + 0.95 * run_k) * (0.4 + 0.6 * amp); T.re = T.le
		T.laz = -0.07 + sin(time * 1.6) * 0.02 * (1.0 - amp); T.raz = -T.laz
		T.lean = (0.04 + 0.26 * run_k) * amp; T.roll = sw * 0.04 * amp
		T.bob = absf(cos(phase)) * (0.03 + 0.04 * run_k) * amp - 0.02 * run_k
		T.crouch = maxf(0.0, land)
	elif jet > 0.2:
		T.lt = -0.12; T.rt = -0.22; T.lk = 0.3; T.rk = 0.45; T.la = -0.2; T.ra = -0.2; T.le = 0.45; T.re = 0.45; T.laz = -0.45; T.raz = 0.45; T.lean = 0.18
	else:
		T.lt = 0.7; T.rt = -0.15; T.lk = 1.0; T.rk = 0.35; T.la = 0.45; T.ra = 0.2; T.le = 0.7; T.re = 0.6; T.laz = -0.35; T.raz = 0.35; T.lean = 0.08
	var r14 := 1.0 - exp(-dt * 14.0); var r20 := 1.0 - exp(-dt * 20.0)
	for key in T:
		pose[key] = lerpf(pose[key], T[key], r20 if key == "bob" or key == "crouch" else r14)
	var step_now := int(floor(phase / PI))
	if on_ground and amp > 0.25 and step_now != last_step: step.emit(0.4 + run_k * 0.5)
	last_step = step_now
	# over-the-shoulder camera
	var cam_dist := 4.2 + run_k * 1.2 + fly_k * 2.0 + (1.0 if flying else 0.0)
	var cp := cos(pitch); var spn := sin(pitch)
	var cam_r := cam_fwd.cross(up).normalized()
	var want := p + up * 1.7 + cam_r * 0.7 - cam_fwd * cam_dist * cp + up * cam_dist * spn
	var c := Vector3(cx, cy, cz)
	var lag := (12.0 + fly_speed * 0.4) if flying else 10.0
	c = c.lerp(want, 1.0 - exp(-dt * lag))
	var cu := c.normalized(); var cgr := planet.ground_radius(cu) + 0.5
	if c.length() < cgr: c = cu * cgr
	cx = c.x; cy = c.y; cz = c.z
	var look := (p + up * 1.5 + cam_r * 0.45 + cam_fwd * 2.0 - c).normalized()
	cam_basis = Basis.looking_at(look, up)
	fov = lerpf(fov, 62.0 + run_k * amp * 6.0 + fly_k * (10.0 if shift else 5.0), 1.0 - exp(-dt * 4.0))
	# the rigged robot: its own idle when still, code-driven motion otherwise; leans into flight
	idle_t += dt
	var still := (1.0 - amp) if on_ground and jet < 0.2 and hero_land <= 0.0 else 0.0
	idle_k = lerpf(idle_k, still, 1.0 - exp(-dt * 5.0))
	var vdir := (vel + up * v_up).normalized() if fly_speed > 0.01 else up
	fly_tilt = lerpf(fly_tilt, fly_k, 1.0 - exp(-dt * 3.0))
	var body_up := (up * (1.0 - fly_tilt) + vdir * fly_tilt + up * 1e-4).normalized()
	var right := up.cross(-fwd).normalized()
	var rgt := (right - body_up * right.dot(body_up)).normalized()
	body_basis = Basis(rgt, body_up, rgt.cross(body_up))
	speed = fly_speed
