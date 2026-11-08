## Wayfarer (Godot) — phase 1: Earth, and the Kestrel flying, hovering and landing. A port of ../WayfarerMac.
## The ship's position is kept in double precision (three GDScript floats) relative to the planet's centre; the camera
## sits at the origin and everything is drawn relative to it.
extends Node3D

enum Mode { FLY, HOVER, LANDING, LANDED, TAKEOFF }

const SHIP_LEN := 50.0                  # metres
const GEAR := 4.0                       # belly above the ground when landed (m)

var planet: Planet
var scatter: Scatter
var ship: MeshInstance3D
var cam: Camera3D
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ShaderMaterial
var hud: Label
var engine_light: OmniLight3D

# ship state
var px := 0.0; var py := 0.0; var pz := 0.0           # metres from the planet centre (double)
var q := Basis.IDENTITY                                # orientation (-z forward)
var v := 0.0                                           # forward speed m/s
var ang := Vector3.ZERO                                # turn rates
var throttle := 0.3
var afterburner := false; var ab := 0.0
var mode := Mode.LANDED
var hv := Vector3.ZERO; var vv := 0.0; var hover_alt := 20.0
var alt := 0.0
var mouse := Vector2.ZERO
var captured := false
var cam_off := Vector3(0, 14, 55)
var cam_basis := Basis.IDENTITY
var takeoff_t := 0.0

func _ready() -> void:
	planet = Planet.new()
	add_child(planet)
	scatter = Scatter.new(planet)
	add_child(scatter)
	# sun and sky
	sun = DirectionalLight3D.new()
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 1500.0
	sun.look_at_from_position(Vector3.ZERO, -planet.sun_dir, Vector3.UP)
	add_child(sun)
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = preload("res://shaders/sky.gdshader")
	sky_mat.set_shader_parameter("nebula", preload("res://assets/sky/nebula.png"))
	var sky := Sky.new(); sky.sky_material = sky_mat; sky.radiance_size = Sky.RADIANCE_SIZE_128
	env = Environment.new()
	env.background_mode = Environment.BG_SKY; env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; env.ambient_light_sky_contribution = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_ACES; env.tonemap_exposure = 0.95
	env.adjustment_enabled = true; env.adjustment_saturation = 1.05; env.adjustment_contrast = 1.08
	env.glow_enabled = true; env.glow_intensity = 0.6; env.glow_bloom = 0.08
	env.fog_enabled = true; env.fog_mode = Environment.FOG_MODE_EXPONENTIAL; env.fog_sky_affect = 0.0
	env.ssao_enabled = true
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	# camera
	cam = Camera3D.new(); cam.near = 0.5; cam.far = 8.0e6; cam.fov = 62.0
	add_child(cam); cam.make_current()
	# the Kestrel
	ship = MeshInstance3D.new()
	ship.mesh = BakedModel.load_mesh("res://assets/ships/kestrel.bin", SHIP_LEN / 1.4)
	ship.material_override = BakedModel.material(preload("res://assets/ships/kestrel_albedo.png"), preload("res://assets/ships/kestrel_normal.png"))
	var u := SHIP_LEN / 1.4
	var nz := PackedVector4Array()
	for x in [-0.15, 0.0, 0.15]: nz.append(Vector4(x * u, 0.0, 0.0414 * u, 0.0))
	ship.material_override.set_shader_parameter("nozzles", nz)
	ship.material_override.set_shader_parameter("nozzle_count", 3)
	add_child(ship)
	engine_light = OmniLight3D.new(); engine_light.light_color = Color(0.55, 0.75, 1.0); engine_light.omni_range = 40.0
	ship.add_child(engine_light); engine_light.position = Vector3(0, 0, 24)
	# HUD
	hud = Label.new(); hud.position = Vector2(24, 20)
	hud.add_theme_font_size_override("font_size", 16)
	var layer := CanvasLayer.new(); layer.add_child(hud); add_child(layer)
	_start_on_land()

## park the ship on sunlit land, like the Mac game's start
func _start_on_land() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	var best := planet.sun_dir
	for i in 20000:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var h := planet.height(d, 10)
		if h > 0.3 and h < 2.5 and absf(d.dot(planet.sun_dir) - 0.6) < 0.1 and absf(d.y) < 0.6:
			var c := planet.color_at(d, h, 0.0)
			var t := d.cross(Vector3.UP).normalized() * (300.0 / Planet.R); var b := d.cross(t)
			var flat := maxf(absf(planet.height((d + t).normalized(), 12) - h), absf(planet.height((d + b).normalized(), 12) - h)) * 1000.0
			if c.g > c.r * 1.2 and flat < 6.0:          # green, gentle land (not desert, not a hillside)
				best = d; break
	var r := planet.ground_radius(best) + GEAR
	px = best.x * r; py = best.y * r; pz = best.z * r
	q = _level(best, best.cross(Vector3.UP).normalized())
	mode = Mode.LANDED
	_settle()
	cam_basis = q

func _level(up: Vector3, fwd: Vector3) -> Basis:
	var f := (fwd - up * fwd.dot(up)).normalized()
	if f.length() < 0.1: f = up.cross(Vector3.RIGHT).normalized()
	var x := f.cross(up).normalized()
	return Basis(x, up, -f)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed and not captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; captured = true
	if e is InputEventMouseMotion and captured:
		mouse += e.relative
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; captured = false
			KEY_L:
				if mode == Mode.FLY or mode == Mode.HOVER:
					if alt < 3000.0: mode = Mode.LANDING
				elif mode == Mode.LANDED: _take_off()
			KEY_G:
				if mode == Mode.FLY:
					mode = Mode.HOVER; hover_alt = maxf(alt, 8.0); hv = -q.z * v; vv = 0.0
				elif mode == Mode.HOVER:
					mode = Mode.FLY; v = hv.length()
				elif mode == Mode.LANDED:
					_take_off()
			KEY_SHIFT:
				if mode == Mode.FLY and throttle > 0.97 and alt > 2000.0: afterburner = not afterburner

func _take_off() -> void:
	mode = Mode.TAKEOFF; takeoff_t = 0.0

func _process(dt: float) -> void:
	dt = minf(dt, 0.05)
	var up := Vector3(px, py, pz).normalized()
	var ground := planet.ground_radius(up)
	alt = sqrt(px * px + py * py + pz * pz) - ground - GEAR
	var dens := exp(-alt / 11000.0) if alt < 110000.0 else 0.0
	match mode:
		Mode.FLY: _fly(dt, up, dens)
		Mode.HOVER: _hover(dt, up)
		Mode.LANDING: _land(dt, up)
		Mode.TAKEOFF:
			takeoff_t += dt
			var climb := (12.0 + takeoff_t * takeoff_t * 50.0) * dt
			px += up.x * climb; py += up.y * climb; pz += up.z * climb
			if takeoff_t > 0.6: q = q.rotated(q.x, dt * 0.25 * minf(1.0, takeoff_t - 0.6)).orthonormalized()
			if takeoff_t > 3.0: mode = Mode.FLY; throttle = 0.25; v = 50.0
		Mode.LANDED: v = 0.0; _settle()
	ab = move_toward(ab, 1.0 if afterburner else 0.0, dt * 2.0)
	mouse = Vector2.ZERO
	_camera(dt, up)
	_draw_world(dens, up)

func _fly(dt: float, up: Vector3, dens: float) -> void:
	ang.x += (_k(KEY_UP) - _k(KEY_DOWN)) * dt * 2.2 - mouse.y * 0.0022
	ang.y += (_k(KEY_LEFT) - _k(KEY_RIGHT)) * dt * 2.2 - mouse.x * 0.0022
	ang.z += (_k(KEY_A) - _k(KEY_D)) * dt * 3.0
	ang *= exp(-dt * 3.2)
	q = (q * Basis(Vector3.RIGHT, ang.x * dt) * Basis(Vector3.UP, ang.y * dt) * Basis(Vector3.BACK, ang.z * dt)).orthonormalized()
	if Input.is_physical_key_pressed(KEY_W): throttle = clampf(throttle + dt * 0.5, 0.0, 1.0)
	if Input.is_physical_key_pressed(KEY_S): throttle = clampf(throttle - dt * 0.5, 0.0, 1.0)
	if Input.is_physical_key_pressed(KEY_SPACE): throttle = move_toward(throttle, 0.0, dt * 2.0)
	if afterburner and (throttle < 0.97 or alt < 1500.0): afterburner = false
	# top speed grows with height; the air caps it (about Mach 2.6 at sea level), orbital speed at the top of the air
	var max_v := clampf(alt * 1.6 + 150.0, 150.0, 2.5e6) * (1.0 + ab * 2.0)
	if dens > 1e-4: max_v = minf(max_v, minf(7500.0, (900.0 + ab * 1500.0) / sqrt(dens)))
	var vt := pow(throttle, 1.4) * max_v
	v = lerpf(v, vt, 1.0 - exp(-dt * (6.0 if vt < v else 2.2)))
	var f := -q.z
	px += f.x * v * dt; py += f.y * v * dt; pz += f.z * v * dt
	# don't fly into the ground: touch down when slow, otherwise skim
	var r := sqrt(px * px + py * py + pz * pz)
	var floor_r := planet.ground_radius(up) + GEAR
	if r < floor_r:
		px = up.x * floor_r; py = up.y * floor_r; pz = up.z * floor_r
		if v < 60.0: mode = Mode.LANDING

func _hover(dt: float, up: Vector3) -> void:
	ang.y += (_k(KEY_LEFT) - _k(KEY_RIGHT)) * dt * 2.0 - mouse.x * 0.002
	ang *= exp(-dt * 4.0)
	var level := _level(up, -q.z)
	level = Basis(up, ang.y * dt) * level
	var fwd := -level.z; var right := level.x
	var want := (fwd * (_k(KEY_UP) - _k(KEY_DOWN)) + right * (_k(KEY_D) - _k(KEY_A)) * 0.7) * 45.0
	hv = hv.lerp(want, 1.0 - exp(-dt * 1.4))
	hover_alt = clampf(hover_alt + (_k(KEY_W) - _k(KEY_S)) * dt * (6.0 + hover_alt * 0.35), 2.0, 5.0e6)
	var err := hover_alt - alt
	vv = lerpf(vv, clampf(err * 1.8, -maxf(30.0, hover_alt * 0.8), maxf(30.0, hover_alt * 0.8)), 1.0 - exp(-dt * 3.0))
	var dpos := hv * dt + up * vv * dt
	px += dpos.x; py += dpos.y; pz += dpos.z
	var pitch := clampf(-hv.dot(fwd) / 45.0 * 0.06, -0.25, 0.25)
	var roll := clampf(-hv.dot(right) / 45.0 * 0.18, -0.3, 0.3)
	var target := level * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	q = q.slerp(target.orthonormalized(), 1.0 - exp(-dt * 2.5)).orthonormalized()
	v = hv.length()

func _land(dt: float, up: Vector3) -> void:
	q = q.slerp(_level(up, -q.z), 1.0 - exp(-dt * 2.75)).orthonormalized()
	v = lerpf(v, 0.0, 1.0 - exp(-dt * 3.0))
	var f := -q.z
	px += f.x * v * dt; py += f.y * v * dt; pz += f.z * v * dt
	var rate := maxf(3.5, alt * 1.2) if alt > 30.0 else maxf(0.4, alt * 1.6)
	var sink := minf(rate * dt, alt)
	px -= up.x * sink; py -= up.y * sink; pz -= up.z * sink
	if alt <= 0.05:
		mode = Mode.LANDED; v = 0.0; throttle = 0.0; _settle()

func _camera(dt: float, up: Vector3) -> void:
	var target := q if mode == Mode.FLY else _level(up, -q.z)
	cam_basis = cam_basis.slerp(target, 1.0 - exp(-dt * 5.0)).orthonormalized()
	var off := cam_basis * (cam_off * (1.0 + ab * 0.3))
	cam.basis = cam_basis * Basis(Vector3.RIGHT, -0.14)
	cam.fov = lerpf(cam.fov, 62.0 + throttle * 2.0 + ab * 14.0 if mode == Mode.FLY else 62.0, 1.0 - exp(-dt * 3.0))
	# camera-relative: the camera's double-precision world position
	var cx := px + off.x; var cy := py + off.y; var cz := pz + off.z
	var cu := Vector3(cx, cy, cz).normalized()
	var cmin := planet.ground_radius(cu) + 3.0
	var cr := sqrt(cx * cx + cy * cy + cz * cz)
	if cr < cmin:
		cx = cu.x * cmin; cy = cu.y * cmin; cz = cu.z * cmin
	cam.position = Vector3.ZERO
	ship.position = Vector3(px - cx, py - cy, pz - cz)
	ship.basis = q
	planet.update_lod(Vector3(cx, cy, cz), alt)
	planet.place(cx, cy, cz)
	scatter.update(cx, cy, cz, sqrt(cx * cx + cy * cy + cz * cz) - planet.ground_radius(cu))

func _draw_world(dens: float, up: Vector3) -> void:
	var alt_km := alt / 1000.0
	sky_mat.set_shader_parameter("up", up)
	sky_mat.set_shader_parameter("alt_km", alt_km)
	var r := sqrt(px * px + py * py + pz * pz)
	sky_mat.set_shader_parameter("horizon_dip", acos(clampf(Planet.R / r, -1.0, 1.0)))
	var day := smoothstep(-0.12, 0.25, up.dot(planet.sun_dir))
	env.fog_density = 0.000045 * dens
	env.fog_light_color = Color(0.55, 0.68, 0.85) * (0.15 + 0.85 * day)
	env.ambient_light_energy = 0.4 + 0.6 * day
	engine_light.light_energy = (0.5 + throttle * 2.0 + ab * 4.0) if mode != Mode.LANDED else 0.2
	ship.material_override.set_shader_parameter("power", 0.05 if mode == Mode.LANDED else 0.4 + throttle * 0.6 + ab)
	var spd := v
	var mode_name: String = ["FLY", "HOVER", "LANDING", "LANDED", "TAKE-OFF"][mode]
	hud.text = "WAYFARER (Godot port · phase 1) · " + str(Engine.get_frames_per_second()) + " fps\n%s · %s\naltitude %s · speed %s%s\nthrottle %d%%%s\n\n%s" % [
		"Kestrel", mode_name, _fmt(alt), _fmt(spd), "/s", int(throttle * 100), "  AFTERBURNER" if ab > 0.05 else "",
		"click: capture mouse · W/S throttle · A/D roll · arrows/mouse pitch & yaw · G hover · L land / take off · Shift afterburner · Esc release"]

func _fmt(m: float) -> String:
	if m < 1000.0: return "%d m" % int(m)
	if m < 1.0e6: return "%.1f km" % (m / 1000.0)
	return "%.0fk km" % (m / 1.0e6)

# test hook: WAYFARER_SHOT=<png> saves a screenshot after a few seconds and quits; WAYFARER_ALT starts hovering at that height
var _shot_t := 0.0
func _physics_process(dt: float) -> void:
	var path := OS.get_environment("WAYFARER_SHOT")
	if path == "": return
	if _shot_t == 0.0 and OS.get_environment("WAYFARER_ALT") != "":
		mode = Mode.HOVER; hover_alt = float(OS.get_environment("WAYFARER_ALT"))
		var up := Vector3(px, py, pz).normalized()
		var r := sqrt(px * px + py * py + pz * pz) + hover_alt
		px = up.x * r; py = up.y * r; pz = up.z * r
	_shot_t += dt
	if _shot_t > float(OS.get_environment("WAYFARER_WAIT") if OS.get_environment("WAYFARER_WAIT") != "" else "6"):
		get_viewport().get_texture().get_image().save_png(path)
		get_tree().quit()

func _k(key: Key) -> float:
	return 1.0 if Input.is_physical_key_pressed(key) else 0.0

## sit the parked ship on the slope: tilt to the ground under its nose, tail and wingtips, and rest on the highest of them
func _settle() -> void:
	var p := Vector3(px, py, pz); var up := p.normalized()
	var lvl := _level(up, -q.z)
	var f := -lvl.z * 20.0; var r := lvl.x * 17.0
	var g := func(o: Vector3) -> Vector3:
		var d := (p + o).normalized(); return d * planet.ground_radius(d)
	var nose: Vector3 = g.call(f); var tail: Vector3 = g.call(-f)
	var left: Vector3 = g.call(-r); var right: Vector3 = g.call(r)
	var n := (right - left).cross(nose - tail).normalized()
	if n.dot(up) < 0.0: n = -n
	if n.dot(up) < 0.8: n = up.lerp(n, 0.5).normalized()   # too steep: don't stand on a cliff face
	var top := 0.0
	for c in [nose, tail, left, right]:
		top = maxf(top, (c as Vector3).length())
	top = maxf(top, planet.ground_radius(up))
	var rad := top + GEAR * 0.6
	px = up.x * rad; py = up.y * rad; pz = up.z * rad
	q = q.slerp(_level(n, -q.z), 0.25).orthonormalized()
