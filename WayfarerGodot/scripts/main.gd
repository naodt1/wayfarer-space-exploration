## Wayfarer (Godot): one planet, four ships. A port of ../WayfarerMac.
## Starts on a title screen with the chosen ship hanging in orbit above Earth; LAUNCH flies you down from there.
## The ship's position is kept in double precision (three GDScript floats) relative to the planet's centre; the camera
## sits at the origin and everything is drawn relative to it.
extends Node3D

enum Mode { TITLE, FLY, HOVER, LANDING, LANDED, TAKEOFF, WALK }
const ORBIT_ALT := 220000.0             # the title screen's showcase height (m)

var planet: Planet                                     # the world we are near: positions are relative to its centre
var worlds: Array[Planet] = []
var auto := -1                                         # autopilot target (world index)
var scatter: Scatter
var cam: Camera3D
var sun: DirectionalLight3D
var env: Environment
var sky_mat: ShaderMaterial
var ui: GameUI
var sfx: GameAudio
var robot: Robot
var walker := Walker.new()
var parked_hover := false                              # you stepped out of a ship that's still hovering
var summon := {"active": false, "phase": 0, "t": 0.0, "climb": 0.0, "tx": 0.0, "ty": 0.0, "tz": 0.0}
var shift := false
# flight physics
var vdir := Vector3.FORWARD          # where the ship is actually travelling (it slides behind the nose in turns)
var g_load := 0.0                    # how hard you're turning, for the camera
var shake := 0.0                     # camera shake: buffet in thick air, afterburner, hard landings
var bounce := 0.0; var bounce_v := 0.0   # the gear compressing on touchdown (m)
# walking aboard the Atlas (first person, ship-local metres)
var aboard := false
var ab_p := Vector3.ZERO; var ab_yaw := 0.0; var ab_pitch := 0.0; var ab_bob := 0.0
var lift_i := -1; var lift_t := 0.0; var lift_dur := 1.0; var lift_up := true
var fuel := 1.0

var roster: Array
var ship_idx := 0
var spec: Dictionary
var ship: Ship

# ship state
var px := 0.0; var py := 0.0; var pz := 0.0           # metres from the planet centre (double)
var q := Basis.IDENTITY                                # orientation (-z forward)
var v := 0.0                                           # forward speed m/s
var ang := Vector3.ZERO                                # turn rates
var throttle := 0.15
var afterburner := false; var ab := 0.0
var mode := Mode.TITLE
var hv := Vector3.ZERO; var vv := 0.0; var hover_alt := 20.0
var alt := 0.0
var gear := 0.0
var takeoff_t := 0.0
var time := 0.0
var paused := false

# input and camera
var mouse := Vector2.ZERO
var captured := false
var dragging := false
var cam_basis := Basis.IDENTITY
var cam_zoom := 1.0
var cam_alt := 0.0

# title showcase
var sc_up := Vector3.UP; var sc_side := Vector3.RIGHT
var show_yaw := 0.5; var show_pitch := 0.12

func _ready() -> void:
	GameSettings.load_all()
	for k in ["earth", "ruber", "verdance"]:
		var w := Planet.new(k); add_child(w); w.make_halo(); worlds.append(w)
	planet = worlds[0]
	scatter = Scatter.new(planet)
	add_child(scatter)
	# sun and sky
	sun = DirectionalLight3D.new()
	sun.light_energy = 2.1
	sun.light_color = Color(1.0, 0.96, 0.9)
	sun.light_angular_distance = 0.6
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
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY; env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES; env.tonemap_exposure = 1.0; env.tonemap_white = 6.0
	env.adjustment_enabled = true; env.adjustment_saturation = 1.15; env.adjustment_contrast = 1.1
	env.glow_enabled = true; env.glow_intensity = 0.5; env.glow_bloom = 0.04; env.glow_hdr_threshold = 1.2
	env.ssao_intensity = 1.6; env.ssao_radius = 1.5
	env.fog_enabled = true; env.fog_mode = Environment.FOG_MODE_EXPONENTIAL; env.fog_sky_affect = 0.0
	env.ssao_enabled = true
	var we := WorldEnvironment.new(); we.environment = env; add_child(we)
	# camera
	cam = Camera3D.new(); cam.near = 0.5; cam.far = 8.0e6; cam.fov = 62.0
	add_child(cam); cam.make_current()
	# the robot (on foot)
	robot = Robot.new(); robot.visible = false; add_child(robot)
	walker.message.connect(func(t): ui.say(t))
	walker.hero_landed.connect(_on_hero_landed)
	sfx = GameAudio.new(); add_child(sfx)
	walker.sonic_boom.connect(func(_p): sfx.sonic_boom())
	walker.step.connect(func(k): sfx.step(k))
	# interface
	ui = GameUI.new(); add_child(ui)
	ui.launch.connect(_launch)
	ui.change_ship.connect(_change_ship)
	ui.pick_ship.connect(func(i): _change_ship(i - ship_idx))
	ui.resume.connect(_resume)
	ui.main_menu.connect(_enter_title)
	ui.quit_game.connect(func(): get_tree().quit())
	ui.settings_changed.connect(_apply_settings)
	_apply_settings()
	roster = Ships.roster()
	ship_idx = clampi(int(OS.get_environment("WAYFARER_SHIP")) if OS.get_environment("WAYFARER_SHIP") != "" else 2, 0, roster.size() - 1)
	_set_ship(ship_idx)
	_enter_title()
	_test_setup()

# ------------------------------------------------------------------ ships and screens
func _set_ship(i: int) -> void:
	ship_idx = i
	if ship != null: ship.queue_free()
	spec = roster[i]
	ship = Ship.new(spec)
	add_child(ship)
	ui.show_ship(spec, i, roster.size())
	sun.directional_shadow_max_distance = clampf(ship.size_m * 4.0, 1500.0, 8000.0)

func _change_ship(d: int) -> void:
	_set_ship((ship_idx + d + roster.size()) % roster.size())
	if mode != Mode.TITLE:
		ui.say("now flying the %s" % spec["name"])
		if mode == Mode.LANDED: _settle()

func _enter_title() -> void:
	planet = worlds[0]; scatter.set_planet(planet); auto = -1
	mode = Mode.TITLE; paused = false
	afterburner = false; ab = 0.0; throttle = 0.15; v = 0.0; ang = Vector3.ZERO; hv = Vector3.ZERO; vv = 0.0; gear = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; captured = false
	# hang above the day side, with the terminator in view
	var perp := planet.sun_dir.cross(Vector3.UP).normalized()
	sc_up = (planet.sun_dir * 0.75 + perp * 0.66).normalized()
	sc_side = sc_up.cross(perp).normalized()
	var r := planet.R + ORBIT_ALT
	px = sc_up.x * r; py = sc_up.y * r; pz = sc_up.z * r
	ui.set_screen(true, false); ui.close_pause()
	ui.show_ship(spec, ship_idx, roster.size())
	_showcase(0.0)          # heading and camera set right away (a launch on the first frame still points at Earth)

func _launch() -> void:
	if mode != Mode.TITLE: return
	vdir = -q.z
	mode = Mode.FLY; throttle = 0.3; v = 0.0
	cam_basis = q
	ui.set_screen(false, false)
	ui.say("welcome aboard the %s" % spec["name"])

func _pause() -> void:
	if OS.get_environment("WAYFARER_SHOT") != "" and OS.get_environment("WAYFARER_MODE") != "pause": return   # tests run unattended
	paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE; captured = false
	ui.set_screen(false, true); ui.open_pause(roster, ship_idx)

func _resume() -> void:
	paused = false
	ui.close_pause(); ui.set_screen(false, false)

func _apply_settings() -> void:
	GameSettings.apply(get_viewport(), env, sun)
	GameSettings.test_overrides(get_viewport(), env, sun)
	scatter.set_density(GameSettings.grass_k())

# ------------------------------------------------------------------ input
var _testing := OS.get_environment("WAYFARER_SHOT") != ""
func _input(e: InputEvent) -> void:
	if _testing: get_viewport().set_input_as_handled(); return      # unattended tests: ignore whoever is at the keyboard
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_F11:
		GameSettings.fullscreen = not GameSettings.fullscreen
		GameSettings.save_all(); ui._refresh_settings(); _apply_settings()
		get_viewport().set_input_as_handled(); return
	if e is InputEventMouseButton and e.pressed and (ui.settings_root.visible or paused): return
	if not (e is InputEventKey and e.pressed): return
	var kc: int = e.keycode
	# the settings panel: ↑ ↓ pick a row, ← → change it, Esc or comma closes
	if ui.settings_root.visible:
		match kc:
			KEY_ESCAPE, KEY_COMMA: if not e.echo: ui.close_settings()
			KEY_UP, KEY_W: ui.settings_move(-1)
			KEY_DOWN, KEY_S: ui.settings_move(1)
			KEY_LEFT, KEY_A: ui.cycle_setting(ui.set_sel, -1)
			KEY_RIGHT, KEY_D, KEY_ENTER, KEY_KP_ENTER: ui.cycle_setting(ui.set_sel, 1)
		get_viewport().set_input_as_handled(); return
	if ui.controls_root.visible and kc in [KEY_K, KEY_ESCAPE]:
		if not e.echo: ui.toggle_controls()
		get_viewport().set_input_as_handled(); return
	# the pause menu
	if paused:
		match kc:
			KEY_ESCAPE: if not e.echo: _resume()
			KEY_UP, KEY_W: ui.menu_move(-1)
			KEY_DOWN, KEY_S: ui.menu_move(1)
			KEY_LEFT, KEY_A: ui.menu_step(-1)
			KEY_RIGHT, KEY_D: ui.menu_step(1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: if not e.echo: ui.menu_confirm()
			KEY_K: if not e.echo: ui.toggle_controls()
			KEY_COMMA: if not e.echo: ui.open_settings()
		get_viewport().set_input_as_handled(); return

func _unhandled_input(e: InputEvent) -> void:
	if _testing: return
	if paused: return
	if mode == Mode.TITLE:
		if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT: dragging = e.pressed
		if e is InputEventMouseMotion and dragging: mouse += e.relative
		if e is InputEventKey and e.pressed and not e.echo:
			match e.keycode:
				KEY_LEFT, KEY_A: _change_ship(-1)
				KEY_RIGHT, KEY_D: _change_ship(1)
				KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _launch()
				KEY_K: ui.toggle_controls()
				KEY_COMMA, KEY_O: ui.open_settings()
				KEY_ESCAPE:
					if ui.controls_root.visible: ui.toggle_controls()
					else: get_tree().quit()
		return
	if aboard:
		if e is InputEventMouseButton and e.pressed and not captured: Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; captured = true
		if e is InputEventMouseMotion and captured: mouse += e.relative * GameSettings.mouse_sens * Vector2(1.0, -1.0 if GameSettings.invert_y else 1.0)
		if e is InputEventKey and e.pressed and not e.echo:
			match e.keycode:
				KEY_ESCAPE: _pause()
				KEY_K: ui.toggle_controls()
				KEY_COMMA: _pause(); ui.open_settings()
				KEY_I: _leave_aboard()
				KEY_E: _aboard_use()
		return
	if mode in [Mode.LANDED, Mode.LANDING] and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		dragging = e.pressed
	if mode in [Mode.LANDED, Mode.LANDING] and e is InputEventMouseMotion and dragging: mouse += e.relative
	if mode in [Mode.LANDED, Mode.LANDING]: pass
	elif e is InputEventMouseButton and e.pressed and not captured:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; captured = true
	if e is InputEventMouseMotion and captured:
		mouse += e.relative * GameSettings.mouse_sens * Vector2(1.0, -1.0 if GameSettings.invert_y else 1.0)
	if e is InputEventKey and e.pressed and not e.echo:
		match e.keycode:
			KEY_ESCAPE:
				if ui.controls_root.visible: ui.toggle_controls()
				else: _pause()
			KEY_K: ui.toggle_controls()
			KEY_I:
				if mode in [Mode.FLY, Mode.HOVER, Mode.LANDED] and ship.interior != null: _go_aboard()
				elif mode != Mode.WALK: ui.say("only the Atlas has decks to walk · Esc to change ship")
			KEY_COMMA, KEY_O: _pause(); ui.open_settings()
			KEY_C:
				cam_zoom = 1.8 if cam_zoom == 1.0 else (3.0 if cam_zoom == 1.8 else 1.0)
				ui.say(["chase camera", "far camera", "wide camera"][[1.0, 1.8, 3.0].find(cam_zoom)])
			KEY_E:
				if mode == Mode.WALK:
					if _near_ship(): _board()
					else: ui.say("walk back to the ship to board")
				elif mode == Mode.LANDED: _enter_walk()
				elif mode == Mode.HOVER: parked_hover = true; _enter_walk()
			KEY_X:
				if mode == Mode.WALK:
					walker.flying = not walker.flying
					if walker.flying: sfx.burner_on()
					else: sfx.burner_off()
					if walker.flying:
						walker.on_ground = false; walker.v_up = maxf(walker.v_up, 12.0)
						ui.say("flying · W forward where you look · shift boost · space climb · X to drop")
					else: ui.say("falling · hit the ground hard for a superhero landing")
				elif mode == Mode.LANDED or mode == Mode.HOVER:
					if mode == Mode.HOVER: parked_hover = true
					_enter_walk()
					walker.flying = true; walker.on_ground = false; walker.v_up = 12.0; sfx.burner_on()
					ui.say("flying · W forward where you look · shift boost · space climb · X to drop")
				else: ui.say("X: fly as the robot · land or hover first (G)")
			KEY_R:
				if mode == Mode.WALK: _summon()
			KEY_1, KEY_2, KEY_3:
				if mode in [Mode.FLY, Mode.HOVER, Mode.LANDED]: _start_auto(e.keycode - KEY_1)
			KEY_L:
				if mode == Mode.WALK: pass
				elif mode == Mode.FLY or mode == Mode.HOVER:
					if alt < 3000.0 + ship.size_m * 2.0: mode = Mode.LANDING; afterburner = false
					else: ui.say("too high to land: get below %s" % _fmt(3000.0 + ship.size_m * 2.0))
				elif mode == Mode.LANDED: _take_off()
			KEY_G:
				if mode == Mode.WALK: pass
				elif mode == Mode.FLY:
					mode = Mode.HOVER; hover_alt = maxf(alt, 8.0); hv = -q.z * minf(v, 200.0); vv = 0.0; afterburner = false
					ui.say("hover")
				elif mode == Mode.HOVER:
					mode = Mode.FLY; v = maxf(hv.length(), 90.0 * sqrt(float(spec["mass"]))); throttle = maxf(throttle, 0.35); vdir = -q.z
				elif mode == Mode.LANDED:
					_take_off()
			KEY_SHIFT:
				if mode == Mode.WALK: pass
				elif mode == Mode.FLY:
					if throttle > 0.97 and alt > 2000.0:
						afterburner = not afterburner
						if afterburner: sfx.burner_on()
						else: sfx.burner_off()
					else: ui.say("afterburner: full throttle (W) and above 2 km")

func _take_off() -> void:
	mode = Mode.TAKEOFF; takeoff_t = 0.0

# ------------------------------------------------------------------ simulation
func _process(dt: float) -> void:
	dt = minf(dt, 0.05)
	time += dt
	_pick_world()
	shake = maxf(0.0, shake - dt * 1.8)
	# landing gear: a damped spring that takes the touchdown
	bounce_v += (-bounce * 60.0 - bounce_v * 9.0) * dt; bounce += bounce_v * dt
	var up := Vector3(px, py, pz).normalized()
	var ground := planet.ground_radius(up)
	alt = sqrt(px * px + py * py + pz * pz) - ground - ship.gear_m
	var dens := exp(-alt / 11000.0) if alt < 110000.0 else 0.0
	if not paused and aboard: _aboard_step(dt)
	if ship.interior != null: ship.interior.set_holo((worlds[auto] if auto >= 0 else planet).kind)
	if not paused:
		match mode:
			Mode.TITLE: _showcase(dt)
			Mode.FLY:
				_fly(dt, up, dens)
				# fuel: a tank lasts ~35 min at full throttle in a fighter, longer in the big ships
				fuel = maxf(0.0, fuel - dt / 2100.0 * (pow(throttle, 1.5) + ab * 3.0) * (0.3 if ship.size_m > 500.0 else 1.0))
				if fuel <= 0.0: throttle = 0.0; afterburner = false
			Mode.HOVER: _hover(dt, up)
			Mode.LANDING: _land(dt, up)
			Mode.TAKEOFF:
				takeoff_t += dt
				var climb := (12.0 + takeoff_t * takeoff_t * 50.0) * sqrt(maxf(1.0, ship.size_m / 50.0)) * dt / float(spec["mass"]) ** 0.5
				px += up.x * climb; py += up.y * climb; pz += up.z * climb
				if takeoff_t > 0.6: q = q.rotated(q.x, dt * 0.25 * minf(1.0, takeoff_t - 0.6)).orthonormalized()
				if takeoff_t > 3.0: mode = Mode.FLY; throttle = 0.5; v = 90.0 * sqrt(float(spec["mass"])); vdir = -q.z
			Mode.LANDED: v = 0.0; _settle()
			Mode.WALK: _walk_frame(dt)
		ab = move_toward(ab, 1.0 if afterburner else 0.0, dt * 2.0)
		var gear_down := mode in [Mode.HOVER, Mode.LANDING, Mode.LANDED, Mode.WALK] or (mode == Mode.TAKEOFF and takeoff_t < 1.5) \
			or (mode == Mode.FLY and alt < 120.0 + ship.size_m and v < 150.0)
		gear = move_toward(gear, 1.0 if gear_down else 0.0, dt * 0.8)
	mouse = Vector2.ZERO
	if aboard:
		var eye := ab_p + Vector3(0, 1.72 + sin(ab_bob) * 0.03, 0)
		var w := q * eye
		cam.basis = q * Basis(Vector3.UP, ab_yaw) * Basis(Vector3.RIGHT, ab_pitch)
		cam.fov = lerpf(cam.fov, 70.0, 1.0 - exp(-dt * 4.0))
		cam_pos_set = false
		_place(px + w.x, py + w.y, pz + w.z)
	elif mode == Mode.WALK:
		cam.basis = walker.cam_basis; cam.fov = walker.fov
		_place(walker.cx, walker.cy, walker.cz)
	elif mode != Mode.TITLE: _camera(dt, up)
	_draw_world(dens)

func _fly(dt: float, up: Vector3, dens: float) -> void:
	var agi: float = spec["agility"]
	var turn := 2.2 * agi
	ang.x += (_k(KEY_UP) - _k(KEY_DOWN)) * dt * turn - mouse.y * 0.0022 * agi
	ang.y += (_k(KEY_LEFT) - _k(KEY_RIGHT)) * dt * turn - mouse.x * 0.0022 * agi
	ang.z += (_k(KEY_A) - _k(KEY_D)) * dt * 3.0 * agi
	ang *= exp(-dt * 3.2 * clampf(agi, 0.5, 1.5))
	# wings: a banked ship turns toward its low wing while there's air to bite on
	var bank := q.x.dot(up)
	ang.y += bank * dens * 0.9 * dt * clampf(v / 300.0, 0.0, 1.0) * clampf(agi, 0.4, 1.2)
	q = (q * Basis(Vector3.RIGHT, ang.x * dt) * Basis(Vector3.UP, ang.y * dt) * Basis(Vector3.BACK, ang.z * dt)).orthonormalized()
	if Input.is_physical_key_pressed(KEY_W): throttle = clampf(throttle + dt * 0.5, 0.0, 1.0)
	if Input.is_physical_key_pressed(KEY_S): throttle = clampf(throttle - dt * 0.5, 0.0, 1.0)
	if Input.is_physical_key_pressed(KEY_SPACE): throttle = move_toward(throttle, 0.0, dt * 2.0)
	if afterburner and (throttle < 0.97 or alt < 1500.0): afterburner = false
	if auto >= 0 and mouse.length() > 6.0: auto = -1; ui.say("autopilot off")
	if auto >= 0:
		var T := worlds[auto]
		var rel := Vector3(T.wx - planet.wx - px, T.wy - planet.wy - py, T.wz - planet.wz - pz)
		var dist := rel.length() - T.R
		var aim := rel.normalized()
		if T != planet and alt < planet.R * 0.8 and aim.dot(up) < 0.35: aim = (aim + up * 0.9).normalized()
		q = q.slerp(Basis.looking_at(aim, q.y).orthonormalized(), 1.0 - exp(-dt * 1.4)).orthonormalized()
		throttle = 1.0
		if dist < T.R * 0.9:
			auto = -1; throttle = 0.0; afterburner = false; sfx.beep()
			ui.say("arrived · %s · fly low and press L to land" % T.world_name)
	# top speed grows with height; the air caps it (about Mach 2.6 at sea level), orbital speed at the top of the air
	var max_v := clampf(alt * 1.6 + 150.0, 150.0, 2.5e6) * (1.0 + ab * 2.0) * float(spec["speedK"])
	# closing on a world: slow toward orbital speed as you reach the top of its air
	var sea_alt := sqrt(px * px + py * py + pz * pz) - planet.R
	max_v = minf(max_v, 8000.0 + (sea_alt - planet.atmo_top) * 0.5 if sea_alt > planet.atmo_top else 7500.0)
	if auto >= 0:
		var T := worlds[auto]
		var rel := Vector3(T.wx - planet.wx - px, T.wy - planet.wy - py, T.wz - planet.wz - pz)
		max_v = minf(max_v, maxf(50.0, (rel.length() - T.R * 0.9) * 0.8))
	if dens > 1e-4: max_v = minf(max_v, minf(7500.0, (900.0 + ab * 1500.0) * float(spec["speedK"]) / sqrt(dens)))
	var vt := pow(throttle, 1.4) * max_v
	var m: float = spec["mass"]
	v = lerpf(v, vt, 1.0 - exp(-dt * (6.0 if vt < v else 2.2) / sqrt(m)))
	var f := -q.z
	# inertia: the ship keeps going the way it was going and the nose pulls the path round. Air gives grip, so in
	# the atmosphere it follows the nose closely; in space it slides through turns
	var grip := (1.6 + 5.0 * minf(1.0, dens * 3.0)) / sqrt(m)
	var before := vdir
	vdir = vdir.slerp(f, 1.0 - exp(-dt * grip)).normalized() if vdir.dot(f) > -0.999 else f
	g_load = lerpf(g_load, before.angle_to(vdir) / maxf(dt, 1e-4) * v / 9.8, 1.0 - exp(-dt * 4.0))
	px += vdir.x * v * dt; py += vdir.y * v * dt; pz += vdir.z * v * dt
	# gravity: too slow for the wings to carry her in air, she sinks; the nose drops with it
	var stall := 45.0 * sqrt(m)
	if dens > 0.02 and v < stall:
		var sink := (1.0 - v / stall) * 22.0 * planet.gravity * minf(1.0, dens * 2.0) * dt
		px -= up.x * sink; py -= up.y * sink; pz -= up.z * sink
		q = q.slerp(Basis.looking_at((f - up * 0.6).normalized(), q.y), (1.0 - v / stall) * dt * 0.25).orthonormalized()
	# buffet when you push fast through thick air, and under afterburner
	shake = maxf(shake, minf(1.0, dens * v / 2500.0) * 0.35 + ab * 0.5 + minf(g_load / 60.0, 0.4))
	# don't fly into the ground: touch down when slow, otherwise skim
	var r := sqrt(px * px + py * py + pz * pz)
	var floor_r := planet.ground_radius(up) + ship.gear_m
	if r < floor_r:
		px = up.x * floor_r; py = up.y * floor_r; pz = up.z * floor_r
		if v < 60.0: mode = Mode.LANDING

func _hover(dt: float, up: Vector3) -> void:
	var m: float = spec["mass"]
	var agi: float = spec["agility"]
	ang.y += ((_k(KEY_LEFT) - _k(KEY_RIGHT)) * dt * 2.0 - mouse.x * 0.002) * clampf(agi, 0.4, 1.2)
	ang *= exp(-dt * 4.0)
	var level := _level(up, -q.z)
	level = Basis(up, ang.y * dt) * level
	var fwd := -level.z; var right := level.x
	var top := 45.0 * sqrt(maxf(1.0, ship.size_m / 50.0))
	var want := (fwd * (_k(KEY_UP) - _k(KEY_DOWN)) + right * (_k(KEY_D) - _k(KEY_A)) * 0.7) * top
	hv = hv.lerp(want, 1.0 - exp(-dt * 1.4 / m))
	hover_alt = clampf(hover_alt + (_k(KEY_W) - _k(KEY_S)) * dt * (6.0 + hover_alt * 0.35), 2.0, 5.0e6)
	var err := hover_alt - alt
	vv = lerpf(vv, clampf(err * 1.8, -maxf(30.0, hover_alt * 0.8), maxf(30.0, hover_alt * 0.8)), 1.0 - exp(-dt * 3.0 / m))
	var dpos := hv * dt + up * vv * dt
	px += dpos.x; py += dpos.y; pz += dpos.z
	var pitch := clampf(-hv.dot(fwd) / top * 0.06, -0.25, 0.25)
	var roll := clampf(-hv.dot(right) / top * 0.18, -0.3, 0.3) / sqrt(m)
	var target := level * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
	q = q.slerp(target.orthonormalized(), 1.0 - exp(-dt * 2.5 / sqrt(m))).orthonormalized()
	v = hv.length()

func _land(dt: float, up: Vector3) -> void:
	var m: float = spec["mass"]
	q = q.slerp(_level(up, -q.z), 1.0 - exp(-dt * 2.75 / sqrt(m))).orthonormalized()
	v = lerpf(v, 0.0, 1.0 - exp(-dt * 3.0 / m))
	var f := -q.z
	px += f.x * v * dt; py += f.y * v * dt; pz += f.z * v * dt
	var rate := maxf(3.5, alt * 1.2) if alt > 30.0 else maxf(0.4, alt * 1.6)
	rate /= sqrt(m)
	var sink := minf(rate * dt, alt)
	px -= up.x * sink; py -= up.y * sink; pz -= up.z * sink
	if alt <= 0.05:
		mode = Mode.LANDED; v = 0.0; throttle = 0.0; _settle()
		ui.say("landed · L to take off"); sfx.thud()
		bounce_v = -1.6 - minf(2.5, ship.size_m / 400.0); shake = 0.5 + minf(0.5, m * 0.12)

## the title screen: the ship holds station above Earth, breathing on its engines; drag to swing the camera round it
func _showcase(dt: float) -> void:
	show_yaw += mouse.x * 0.006; show_pitch = clampf(show_pitch + mouse.y * 0.004, -0.4, 0.9)
	if not dragging: show_yaw += sin(time * 0.09) * 0.0006 * 60.0 * dt; show_pitch += sin(time * 0.07 + 2.0) * 0.00025 * 60.0 * dt
	var size := ship.size_m
	var to_e := -sc_up
	var fwd := (to_e * cos(0.72) + sc_side * sin(0.72)).normalized()
	var upT := (sc_up - fwd * sc_up.dot(fwd)).normalized()
	var right := fwd.cross(upT).normalized()
	var base := Basis(right, upT, -fwd)
	var t := time
	q = (Basis(fwd, sin(t * 0.47) * 0.045) * Basis(right, sin(t * 0.31 + 1.0) * 0.025) * Basis(upT, sin(t * 0.23) * 0.02) * base).orthonormalized()
	var r := planet.R + ORBIT_ALT
	var bob := upT * sin(t * 0.6) * size * 0.035 + right * sin(t * 0.37) * size * 0.02
	px = sc_up.x * r + bob.x; py = sc_up.y * r + bob.y; pz = sc_up.z * r + bob.z
	var d := size * 2.1 * (0.5 if size > 500.0 else 1.0)
	var back := Basis(upT, show_yaw) * (-fwd)
	var offs := (back * cos(show_pitch) + upT * sin(show_pitch)).normalized()
	var cx := sc_up.x * r + offs.x * d; var cy := sc_up.y * r + offs.y * d; var cz := sc_up.z * r + offs.z * d
	var look := fwd * size * 0.35 - upT * size * 0.55 + right * size * 0.05 - offs * d    # relative to the camera
	cam.basis = Basis.looking_at(look.normalized(), upT)
	cam.fov = 62.0
	_place(cx, cy, cz)

var orbit_yaw := 0.7; var orbit_pitch := 0.22
var cam_pos_set := false; var ccx := 0.0; var ccy := 0.0; var ccz := 0.0
## the Mac's cameras (Game.swift): landed, an orbit view 140 m (× size) out that you can drag round; flying, the chase
## camera 105 m behind and 24 m above a 50 m ship (scaled by size), big ships off to one side and turned toward the ship
func _camera(dt: float, up: Vector3) -> void:
	var m: float = spec["mass"]
	var k := ship.size_m / 50.0 * float(spec.get("cam_scale", 1.0))
	var cx: float; var cy: float; var cz: float
	if mode == Mode.LANDED or mode == Mode.LANDING:
		if dragging: orbit_yaw -= mouse.x * 0.006; orbit_pitch = clampf(orbit_pitch + mouse.y * 0.004, 0.02, 1.3)
		var cp := cos(orbit_pitch)
		var off := q * (Vector3(sin(orbit_yaw) * cp, sin(orbit_pitch), cos(orbit_yaw) * cp) * 140.0 * k * cam_zoom)
		var want := Vector3(px, py, pz) + off
		var cur := Vector3(ccx, ccy, ccz)
		cur = want if not cam_pos_set else cur.lerp(want, 1.0 - exp(-dt * 4.0))
		cx = cur.x; cy = cur.y; cz = cur.z
		var look := (Vector3(px, py, pz) + up * 6.0 * k) - cur
		cam.basis = Basis.looking_at(look.normalized(), up)
		cam_basis = q
	else:
		cam_basis = cam_basis.slerp(q, 1.0 - exp(-dt * 5.0 / m)).orthonormalized()
		var chase: Vector3 = spec.get("chase", Vector3(0.0, 24.0, 105.0) * k)
		var off := Vector3(0.0, ab * 6.0, ab * 35.0) * k + chase * cam_zoom
		var yaw := atan2(chase.x, chase.z + ship.size_m) * 0.75
		# the camera hangs back along the real path, so you see the ship slide in a turn, and it shakes with the airframe
		var slip := (cam_basis.inverse() * vdir) if mode == Mode.FLY else Vector3.FORWARD
		off += Vector3(-slip.x, -slip.y, 0.0) * chase.z * 0.55
		var sk := shake * shake * 0.012 * k
		off += Vector3(sin(time * 47.0) + sin(time * 31.3), sin(time * 53.0 + 1.0) + sin(time * 29.0), 0.0) * sk * 50.0
		var o := cam_basis * off
		cx = px + o.x; cy = py + o.y; cz = pz + o.z
		cam.basis = cam_basis * Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -0.14)
	cam.fov = lerpf(cam.fov, 62.0 + throttle * 2.0 + ab * 14.0 if mode == Mode.FLY else 62.0, 1.0 - exp(-dt * 3.0))
	# keep the camera above the terrain
	var cu := Vector3(cx, cy, cz).normalized()
	var cmin := planet.ground_radius(cu) + 6.0
	var cr := sqrt(cx * cx + cy * cy + cz * cz)
	if cr < cmin:
		cx = cu.x * cmin; cy = cu.y * cmin; cz = cu.z * cmin
	ccx = cx; ccy = cy; ccz = cz; cam_pos_set = true
	_place(cx, cy, cz)

## put everything where it belongs relative to the camera at (cx, cy, cz)
func _place(cx: float, cy: float, cz: float) -> void:
	cam.position = Vector3.ZERO
	ship.position = Vector3(px - cx, py - cy, pz - cz) + Vector3(px, py, pz).normalized() * bounce
	ship.basis = q
	robot.visible = mode == Mode.WALK
	if robot.visible:
		robot.position = Vector3(walker.px - cx, walker.py - cy, walker.pz - cz)
		robot.basis = walker.body_basis
		robot.apply(walker.idle_t, walker.idle_k, walker.pose, walker.turn, walker.pitch)
	var cu := Vector3(cx, cy, cz).normalized()
	cam_alt = sqrt(cx * cx + cy * cy + cz * cz) - planet.ground_radius(cu)
	for w in worlds:
		if w == planet:
			w.update_lod(Vector3(cx, cy, cz), cam_alt)
			w.place(cx, cy, cz)
			w.halo_mat.set_shader_parameter("strength", smoothstep(w.atmo_top * 0.25, w.atmo_top, cam_alt))
		else:
			var rx := w.wx - planet.wx - cx; var ry := w.wy - planet.wy - cy; var rz := w.wz - planet.wz - cz
			w.update_lod(Vector3(-rx, -ry, -rz), sqrt(rx * rx + ry * ry + rz * rz) - w.R)
			w.place_far(rx, ry, rz)
			w.halo_mat.set_shader_parameter("strength", 1.0)
	scatter.update(cx, cy, cz, cam_alt)
	if aboard or OS.get_environment("T_NOGRASS") != "": scatter.visible = false            # you're inside: no grass under the deck
	if OS.get_environment("T_NOTERRAIN") != "":
		for w in worlds: w.visible = false
	planet.material.set_shader_parameter("space_haze", smoothstep(8000.0, 120000.0, cam_alt))
	sky_mat.set_shader_parameter("up", cu)
	sky_mat.set_shader_parameter("zenith_col", Vector3(planet.sky_zenith.r, planet.sky_zenith.g, planet.sky_zenith.b))
	sky_mat.set_shader_parameter("horizon_col", Vector3(planet.sky_horizon.r, planet.sky_horizon.g, planet.sky_horizon.b))
	sky_mat.set_shader_parameter("atmo_km", planet.atmo_top / 1000.0)
	sky_mat.set_shader_parameter("cloud_col", Vector3(planet.cloud_color.r, planet.cloud_color.g, planet.cloud_color.b))
	sky_mat.set_shader_parameter("cloud_cover", planet.cloud_cover + 0.05)
	sky_mat.set_shader_parameter("alt_km", cam_alt / 1000.0)
	sky_mat.set_shader_parameter("horizon_dip", acos(clampf(planet.R / sqrt(cx * cx + cy * cy + cz * cz), -1.0, 1.0)))

func _draw_world(dens: float) -> void:
	var up := Vector3(px, py, pz).normalized()
	var day := smoothstep(-0.12, 0.25, up.dot(planet.sun_dir))
	var cdens := exp(-cam_alt / 11000.0) if cam_alt < 110000.0 else 0.0
	env.fog_density = 0.000022 * cdens * planet.fog_k
	env.fog_sun_scatter = 0.25
	env.fog_light_color = planet.fog_color * (0.15 + 0.85 * day)
	# sunlight filtered by the air: golden when the sun is low, white from space (the Mac's sunTransmit)
	var cup := Vector3(ccx, ccy, ccz).normalized() if cam_pos_set else up
	var st := planet.sun_transmit(cup.dot(planet.sun_dir), cam_alt)
	sun.light_color = Color.WHITE.lerp(st, 0.4 + 0.6 * (1.0 - day))      # warm only as the sun gets low
	sun.light_energy = 2.3
	env.ambient_light_energy = 0.3 + 0.25 * day
	sky_mat.set_shader_parameter("sun_tint", Vector3(st.r, st.g, st.b))
	env.fog_light_color = (planet.fog_color * 0.8 + Color(st.r, st.g, st.b) * 0.15) * (0.15 + 0.85 * day)
	# engines: what the plumes, nozzles and lights show
	var thrust := 0.0
	match mode:
		Mode.TITLE: thrust = 0.36 + 0.14 * sin(time * 0.8)
		Mode.FLY: thrust = 0.25 + throttle * 0.75
		Mode.HOVER, Mode.LANDING: thrust = 0.45
		Mode.TAKEOFF: thrust = 0.7
		Mode.WALK: thrust = 0.75 if summon.active else (0.4 if parked_hover else 0.0)
	var power := 0.05 if mode == Mode.LANDED or (mode == Mode.WALK and thrust == 0.0) else (0.5 if mode == Mode.TITLE else 0.4 + throttle * 0.6 + ab)
	ship.set_state(power, thrust, ab, gear)
	sfx.pitch = spec.get("pitch", 1.0)
	if mode == Mode.WALK:
		sfx.engine(0.75 if summon.active else 0.35, 0.0, summon.active or parked_hover)
		sfx.flight(clampf(0.18 + walker.speed / 400.0, 0.0, 1.0) if walker.flying else 0.0)
		sfx.jetpack(0.0 if walker.flying else walker.jet)
	else:
		sfx.engine(0.0 if mode == Mode.LANDED else (throttle if mode == Mode.FLY else 0.5), ab, mode != Mode.TITLE and fuel > 0.0)
		sfx.flight(0.0); sfx.jetpack(0.0)
	if mode == Mode.TITLE: return
	var hint := ""
	match mode:
		Mode.FLY: hint = "W S throttle · mouse steers · G hover · L land · shift afterburner · E/X step out when hovering"
		Mode.HOVER: hint = "W S rise and sink · arrows move · L land · G fly · E step out · X fly as the robot"
		Mode.LANDED: hint = "L take off · E step outside · X fly as the robot"
		Mode.LANDING: hint = "landing"
		Mode.TAKEOFF: hint = "taking off"
		Mode.WALK:
			if walker.flying: hint = "W forward where you look · shift boost · space climb · X to drop"
			elif _near_ship(): hint = "E board the %s · X fly · R call ship" % spec["name"]
			else: hint = "WASD walk · shift run · space jump / jetpack · X fly · R call your ship"
	if not captured and mode in [Mode.FLY, Mode.HOVER, Mode.WALK]: hint = "click to steer with the mouse · " + hint
	if aboard:
		hint = "WASD walk · shift run · mouse look · E use · I back to the controls"
		var near := _aboard_target()
		if near != "": hint = "E · " + near + " · " + hint
	var on_foot := mode == Mode.WALK or aboard
	var line := ("ABOARD THE ATLAS · " + ship.interior.place_name(ab_p).to_upper()) if aboard else "ON FOOT" if on_foot else "%s · %s" % [String(spec["name"]).to_upper(), spec["role"]]
	var a := alt if aboard else (walker.pos().length() - planet.ground_radius(walker.pos().normalized())) if on_foot else alt
	var spd := v if aboard else walker.speed if on_foot else v
	ui.update_marks(_world_marks())
	ui.update_hud(planet.world_name, line, _fmt(a), _fmt_speed(spd), throttle, ab, fuel, hint, on_foot,
		"OUT OF FUEL · ENGINES DOWN" if fuel <= 0.0 else ("FUEL LOW" if fuel < 0.1 else ""))

# ------------------------------------------------------------------ helpers
func _level(up: Vector3, fwd: Vector3) -> Basis:
	var f := (fwd - up * fwd.dot(up)).normalized()
	if f.length() < 0.1: f = up.cross(Vector3.RIGHT).normalized()
	var x := f.cross(up).normalized()
	return Basis(x, up, -f)

func _k(key: Key) -> float:
	if aboard: return 0.0           # walking the decks: the ship flies on by herself
	if _testing and OS.get_environment("WAYFARER_HOLD") == "": return 0.0
	if OS.get_environment("WAYFARER_HOLD") != "" and OS.get_environment("WAYFARER_HOLD").contains(OS.get_keycode_string(key)): return 1.0
	return 1.0 if Input.is_physical_key_pressed(key) else 0.0

func _fmt(m: float) -> String:
	if m < 1000.0: return "%d m" % int(maxf(m, 0.0))
	if m < 1.0e6: return "%.1f km" % (m / 1000.0)
	return "%.0fk km" % (m / 1.0e6)

func _fmt_speed(s: float) -> String:
	if s < 1000.0: return "%d m/s" % int(s)
	return "%.2f km/s" % (s / 1000.0)

## sit the parked ship on the slope: tilt to the ground under its nose, tail and sides, and rest on the highest of them
func _settle() -> void:
	var p := Vector3(px, py, pz); var up := p.normalized()
	var lvl := _level(up, -q.z)
	var f := -lvl.z * ship.size_m * 0.4; var r := lvl.x * ship.size_m * 0.34
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
	var rad := top + ship.gear_m
	px = up.x * rad; py = up.y * rad; pz = up.z * rad
	q = q.slerp(_level(n, -q.z), 0.25).orthonormalized()

## park the ship on gentle, green, sunlit land
func _start_on_land() -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	var best := planet.sun_dir
	for i in 20000:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized()
		var h := planet.height(d, 10)
		if h > 0.3 and h < 2.5 and absf(d.dot(planet.sun_dir) - 0.6) < 0.1 and absf(d.y) < 0.6:
			var c := planet.color_at(d, h, 0.0)
			var t := d.cross(Vector3.UP).normalized() * (300.0 / planet.R); var b := d.cross(t)
			var flat := maxf(absf(planet.height((d + t).normalized(), 12) - h), absf(planet.height((d + b).normalized(), 12) - h)) * 1000.0
			if c.g > c.r * 1.2 and flat < 6.0:
				best = d; break
	var r := planet.ground_radius(best) + ship.gear_m
	px = best.x * r; py = best.y * r; pz = best.z * r
	q = _level(best, best.cross(Vector3.UP).normalized())
	mode = Mode.LANDED; gear = 1.0; throttle = 0.0
	_settle()
	cam_basis = _level(best, -q.z)
	ui.set_screen(false, false)

# ------------------------------------------------------------------ test hooks
# WAYFARER_SHOT=<png> saves a screenshot after WAYFARER_WAIT seconds and quits.
# WAYFARER_MODE: title (default) · landed · hover (WAYFARER_ALT m) · fly · pause.  WAYFARER_SHIP: roster index.
var _shot_t := 0.0
func _test_setup() -> void:
	if OS.get_environment("WAYFARER_WORLD") != "":
		planet = worlds[int(OS.get_environment("WAYFARER_WORLD"))]; scatter.set_planet(planet)
	match OS.get_environment("WAYFARER_MODE"):
		"landed": _start_on_land()
		"hover", "fly":
			_start_on_land()
			var a := float(OS.get_environment("WAYFARER_ALT")) if OS.get_environment("WAYFARER_ALT") != "" else 40.0
			var up := Vector3(px, py, pz).normalized(); var r := sqrt(px * px + py * py + pz * pz) + a
			px = up.x * r; py = up.y * r; pz = up.z * r
			gear = 1.0
			if OS.get_environment("WAYFARER_MODE") == "hover": mode = Mode.HOVER; hover_alt = a
			else: mode = Mode.FLY; throttle = 0.8; v = 200.0; gear = 0.0; vdir = -q.z
		"pause": _launch(); _pause()
		"launch": _launch()
		"settings": ui.open_settings()
		"aboard":
			_start_on_land(); _go_aboard()
			var v3 := OS.get_environment("WAYFARER_AB").split(",")
			if v3.size() >= 4: ab_p = Vector3(float(v3[0]), float(v3[1]), float(v3[2])); ab_yaw = float(v3[3])
			if v3.size() >= 5: ab_pitch = float(v3[4])
		"walk", "hero":
			_start_on_land(); _enter_walk()
			if OS.get_environment("WAYFARER_MODE") == "hero":
				walker.flying = true; walker.on_ground = false; walker.v_up = 12.0

var _fps_t := 0.0
var _adapt_t := 0.0
func _physics_process(dt: float) -> void:
	_adapt_t += dt
	if _adapt_t > 1.0 and time > 6.0 and not paused:
		_adapt_t = 0.0; GameSettings.adapt(get_viewport(), Engine.get_frames_per_second())
	if OS.get_environment("WAYFARER_FPS") != "":
		_fps_t += dt
		if _fps_t > 1.0: _fps_t = 0.0; print("FPS %d  draw calls %d  objects %d" % [Engine.get_frames_per_second(), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME)])
	var path := OS.get_environment("WAYFARER_SHOT")
	if path == "": return
	_shot_t += dt
	if _shot_t > float(OS.get_environment("WAYFARER_WAIT") if OS.get_environment("WAYFARER_WAIT") != "" else "6"):
		get_viewport().get_texture().get_image().save_png(path)
		get_tree().quit()

# ------------------------------------------------------------------ on foot (Walker.swift)
func _enter_walk() -> void:
	var up := Vector3(px, py, pz).normalized()
	var ex: float = spec.get("exit_side", 0.75)
	var spot := Vector3(px, py, pz) + q * Vector3(ex * ship.size_m, -ship.gear_m * 0.5 if parked_hover else 0.0, 0.0)
	var d := spot.normalized()
	var ground := planet.ground_radius(d)
	var r := maxf(ground, spot.length()) if parked_hover else ground
	walker.place(d * r, -q.z)
	walker.on_ground = not parked_hover
	walker.cx = px - q.z.x * 0.0; walker.cy = py; walker.cz = pz
	var c := d * r + d * 3.0 + q.z * 8.0
	walker.cx = c.x; walker.cy = c.y; walker.cz = c.z
	mode = Mode.WALK; throttle = 0.0; afterburner = false; sfx.hatch()
	if parked_hover: hv = Vector3.ZERO; vv = 0.0
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; captured = true
	ui.say("jumped out · the %s holds her hover · walk under her and press E to board" % spec["name"] if parked_hover else "on foot · Earth · gravity 1 g")

func _near_ship() -> bool:
	if summon.active: return false
	var sp := Vector3(px, py, pz); var wp := walker.pos()
	var ex: float = spec.get("exit_side", 0.75)
	if parked_hover:
		var up := sp.normalized(); var dd := sp - wp; var vert := dd.dot(up)
		if (sp - wp).length() < ship.size_m * 1.2 + 30.0: return true
		return (dd - up * vert).length() < ship.size_m * ex * 1.5 + 15.0 and vert > -10.0 and vert < 35.0 + ship.size_m * 0.1 + ship.gear_m + 20.0
	return (sp - wp).length() < ship.size_m * ex * 1.5 + 15.0 + ship.gear_m

func _board() -> void:
	if parked_hover:
		sfx.hatch()
		parked_hover = false; mode = Mode.HOVER; hv = Vector3.ZERO; vv = 0.0
		var up := Vector3(px, py, pz).normalized()
		hover_alt = maxf(2.0, Vector3(px, py, pz).length() - planet.ground_radius(up) - ship.gear_m)
		ui.say("aboard the %s · hovering" % spec["name"])
	else:
		mode = Mode.LANDED; sfx.hatch(); ui.say("aboard the %s" % spec["name"])
	cam_basis = _level(Vector3(px, py, pz).normalized(), -q.z)

func _walk_frame(dt: float) -> void:
	walker.step_frame(dt, planet, mouse, _k, Input.is_physical_key_pressed(KEY_SHIFT) or OS.get_environment("WAYFARER_RUN") != "", time)
	if summon.active: _summon_step(dt)
	elif not parked_hover: _settle()

func _on_hero_landed(at: Vector3, hard: float) -> void:
	sfx.hero_impact(0.4 + hard * 0.6)
	if has_method("_crack"): call("_crack", at, 0.25 + 0.75 * hard)

## call the ship over (R): it spools up, lifts, flies over low and settles beside you
func _summon() -> void:
	if summon.active: return
	var wp := walker.pos()
	if (wp - Vector3(px, py, pz)).length() < ship.size_m * 2.2: ui.say("your ship is right here"); return
	var up := wp.normalized()
	var right := walker.cam_fwd.cross(up).normalized()
	var d := (wp + right * ship.size_m * 0.9 + walker.cam_fwd * ship.size_m * 0.5).normalized()
	if planet.height(d, 14) < 0.0: ui.say("no room to land here · it's water · walk up the beach and call again"); return
	var t := d * planet.ground_radius(d)
	summon = {"active": true, "phase": 0 if parked_hover else -1, "t": 0.0, "climb": 0.0, "tx": t.x, "ty": t.y, "tz": t.z}
	parked_hover = false
	var spool := 2.0 + ship.size_m / 55.0
	ui.say("calling the %s · %s out · engines spooling up · about %d s" % [spec["name"], _fmt((wp - Vector3(px, py, pz)).length()), int(spool + 6.0 + (wp - Vector3(px, py, pz)).length() / (140.0 / sqrt(float(spec["mass"]))))])

func _summon_step(dt: float) -> void:
	var p := Vector3(px, py, pz); var up := p.normalized()
	var a := p.length() - planet.ground_radius(up) - ship.gear_m
	var cruise := ship.size_m * 5.0
	var tgt := Vector3(summon.tx, summon.ty, summon.tz)
	var to_t := tgt - p; to_t -= up * to_t.dot(up)
	var hd := to_t.length()
	var m: float = spec["mass"]
	summon.t += dt
	match int(summon.phase):
		-1:
			gear = 1.0
			if summon.t >= 2.0 + ship.size_m / 55.0: summon.phase = 0; summon.t = 0.0
		0:
			summon.climb = minf(summon.climb + 4.0 / m * dt, maxf(ship.size_m * 0.5, (cruise - a) * 0.9))
			p += up * summon.climb * dt
			if a > cruise * 0.85: summon.phase = 1
		1:
			var dir_h := to_t.normalized()
			var sp := clampf(hd * 0.35, minf(10.0, 140.0 / sqrt(m)), 140.0 / sqrt(m))
			p += dir_h * minf(hd, sp * dt)
			var u2 := p.normalized(); var want_r := planet.ground_radius(u2) + ship.gear_m + cruise
			p = u2 * (p.length() + (want_r - p.length()) * minf(1.0, dt * 2.0))
			q = q.slerp(_level(u2, dir_h), 1.0 - exp(-dt * 2.0)).orthonormalized()
			if hd < ship.size_m * 0.3: summon.phase = 2
		_:
			q = q.slerp(_level(up, -q.z), 1.0 - exp(-dt * 2.5)).orthonormalized()
			p += to_t * minf(1.0, dt * 2.0)
			var sink := maxf(3.5 * ship.size_m / 50.0, a * 0.9) * dt
			if a <= sink + 0.1:
				p = up * (planet.ground_radius(up) + ship.gear_m)
				summon.active = false
				ui.say("the %s has landed · walk over and press E" % spec["name"])
			else: p -= up * minf(sink, a)
	px = p.x; py = p.y; pz = p.z

# ------------------------------------------------------------------ the solar system
## positions are kept relative to the nearest world; when another world becomes nearest, re-base onto it
func _pick_world() -> void:
	if mode == Mode.WALK or mode == Mode.TITLE: return
	var best := planet; var best_d := 1e30
	for w in worlds:
		var dx := planet.wx + px - w.wx; var dy := planet.wy + py - w.wy; var dz := planet.wz + pz - w.wz
		var d := sqrt(dx * dx + dy * dy + dz * dz) - w.R
		if d < best_d: best_d = d; best = w
	if best == planet: return
	px += planet.wx - best.wx; py += planet.wy - best.wy; pz += planet.wz - best.wz
	planet = best
	scatter.set_planet(planet)
	ui.say("entering %s's space" % planet.world_name)

func _start_auto(n: int) -> void:
	if mode == Mode.LANDED: _take_off()
	if mode == Mode.HOVER: mode = Mode.FLY; v = hv.length(); throttle = maxf(throttle, 0.2); vdir = -q.z
	auto = n; sfx.beep(); ui.say("autopilot · %s" % worlds[n].world_name)

## world markers: a ring and the distance for each world (on screen, or pinned to the edge)
func _world_marks() -> Array:
	var out := []
	if mode == Mode.TITLE or mode == Mode.WALK or aboard: return out
	var vp := get_viewport().get_visible_rect().size
	for i in worlds.size():
		var w := worlds[i]
		var rx := w.wx - planet.wx - px; var ry := w.wy - planet.wy - py; var rz := w.wz - planet.wz - pz
		var dist := sqrt(rx * rx + ry * ry + rz * rz) - w.R
		if w == planet and dist < 300000.0: continue
		var dir := Vector3(rx, ry, rz).normalized()
		var cpos := cam.global_position + dir * 1000.0
		var behind := cam.is_position_behind(cpos)
		var sp := cam.unproject_position(cpos)
		var edge := behind or sp.x < 30 or sp.y < 30 or sp.x > vp.x - 30 or sp.y > vp.y - 30
		if behind: sp = vp - sp
		sp = sp.clamp(Vector2(30, 30), vp - Vector2(30, 70))
		out.append({"pos": sp, "text": "%d · %s · %s" % [i + 1, w.world_name.to_upper(), _fmt(dist)], "edge": edge, "auto": i == auto})
	return out

# ------------------------------------------------------------------ walking aboard the Atlas (I)
func _go_aboard() -> void:
	var it := ship.interior
	aboard = true; lift_i = -1
	ab_p = it.spawn; ab_yaw = it.spawn_yaw; ab_pitch = -0.05
	ship.set_aboard(true)
	afterburner = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED; captured = true
	_aboard_look(true)
	sfx.hatch()
	ui.say("aboard the Atlas · the %s" % ("ship flies on by herself" if mode == Mode.FLY else "ship holds still") + " · I to take the controls")

func _leave_aboard() -> void:
	aboard = false; lift_i = -1
	ship.set_aboard(false)
	_aboard_look(false)
	cam_basis = q
	ui.say("at the controls")

## inside: crisp sun shadows through the windows, reflections on the floors, the lights do the work
func _aboard_look(on: bool) -> void:
	sun.directional_shadow_max_distance = 350.0 if on else clampf(ship.size_m * 4.0, 1500.0, 8000.0)
	env.ssr_enabled = on and OS.get_environment("NO_SSR") == ""; env.ssr_max_steps = 48; env.ssr_fade_in = 0.15; env.ssr_fade_out = 2.0
	env.ssao_radius = 1.0 if on else 1.5

func _kr(key: Key) -> float: return 0.0 if _testing else (1.0 if Input.is_physical_key_pressed(key) else 0.0)

func _aboard_step(dt: float) -> void:
	var it := ship.interior
	ab_yaw -= mouse.x * 0.0035; ab_pitch = clampf(ab_pitch - mouse.y * 0.0035, -1.35, 1.35)
	mouse = Vector2.ZERO
	if lift_i >= 0:
		var L: Dictionary = it.lifts[lift_i]
		lift_t += dt / lift_dur
		var k := smoothstep(0.0, 1.0, clampf(lift_t, 0.0, 1.0))
		var a: Vector3 = L.a if lift_up else L.b; var b: Vector3 = L.b if lift_up else L.a
		ab_p = a.lerp(b, k)
		(L.car as Node3D).position = ab_p
		sfx.lift_ride(sin(clampf(lift_t, 0.0, 1.0) * PI))
		if lift_t >= 1.0:
			lift_i = -1; sfx.lift_ride(0.0)
			sfx.chime(); sfx.voice(_lift_word(L.name_b if lift_up else L.name_a), 0.45); sfx.doors()
			ui.say(L.name_b if lift_up else L.name_a)
		return
	var f := _kr(KEY_W) + _kr(KEY_UP) - _kr(KEY_S) - _kr(KEY_DOWN)
	var sd := _kr(KEY_D) + _kr(KEY_RIGHT) - _kr(KEY_A) - _kr(KEY_LEFT)
	var mv := Vector3(sd, 0, -f)
	if mv.length() > 0.01:
		mv = (Basis(Vector3.UP, ab_yaw) * mv.normalized()) * (7.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 3.4) * dt
		ab_bob += mv.length() * 2.6
		# slide along walls: try the move, then each axis on its own
		for d in [mv, Vector3(mv.x, 0, 0), Vector3(0, 0, mv.z)]:
			var np: Vector3 = ab_p + d
			var fy := it.floor_at(np.x, np.z, ab_p.y)
			if not is_nan(fy):
				ab_p = Vector3(np.x, fy, np.z); break

## what E would do here, in words ("" when nothing)
func _aboard_target() -> String:
	var it := ship.interior
	for L in it.lifts:
		if Vector2(ab_p.x - L.a.x, ab_p.z - L.a.z).length() < 2.6:
			if absf(ab_p.y - L.a.y) < 1.0: return "lift up to " + L.name_b
			if absf(ab_p.y - L.b.y) < 1.0: return "lift down to " + L.name_a
	for h in it.helms:
		if (ab_p - (h.p as Vector3)).length() < h.r: return "take the controls at " + h.word
	return ""

func _aboard_use() -> void:
	if lift_i >= 0: return
	var it := ship.interior
	for i in it.lifts.size():
		var L: Dictionary = it.lifts[i]
		if Vector2(ab_p.x - L.a.x, ab_p.z - L.a.z).length() < 2.6:
			var up_ := absf(ab_p.y - L.a.y) < 1.0
			if not up_ and absf(ab_p.y - L.b.y) >= 1.0: continue
			lift_i = i; lift_t = 0.0; lift_up = up_
			lift_dur = 2.0 + absf(L.b.y - L.a.y) / 11.0
			ab_p = Vector3(L.a.x, ab_p.y, L.a.z)
			(L.car as Node3D).position = ab_p
			sfx.doors(); sfx.voice("up" if ((L.b.y > L.a.y) == up_) else "down", 0.3)
			ui.say("lift · to " + (L.name_b if up_ else L.name_a))
			return
	for h in it.helms:
		if (ab_p - (h.p as Vector3)).length() < h.r: _leave_aboard(); return
	sfx.denied()

func _lift_word(place: String) -> String:
	return {"the lounge": "lounge", "the bridge": "bridge", "the landing pad": "pad", "the lobby": "lobby"}.get(place, "")
