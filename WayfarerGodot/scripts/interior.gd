## The Atlas mothership's interior, fitted inside the 1.3 km cruiser hull (measured from the model: ship-local
## metres, x right, y up, z aft). Walk it in first person while the ship flies on by herself.
##   · the grand lounge, x ±78 · z -60…20 · 18 m high, with window walls on both flanks, a holo planet, sofa groups,
##     a bar, planters, pillars wrapped in light and the helm under a wall of screens
##   · a corridor aft to the reactor hall and its 20 m core, a hallway to the lobby under the command tower
##   · lifts: lobby ↔ bridge (in the tower, looking out over the bow), lounge ↔ the landing pad on the top deck
## Also carries what the walking needs: walkable floors, obstacles, lifts and the seats that take the controls.
class_name AtlasInterior
extends Node3D

const FY := -6.0                         # main deck floor
const LX := 78.0; const LZ0 := -60.0; const LZ1 := 20.0; const LH := 18.0
const CZ1 := 140.0; const RX := 24.0; const RZ1 := 200.0; const RH := 20.0
const HZ1 := 290.0; const LBZ1 := 318.0
const BF := 62.0; const BX := 11.0; const BZ0 := 287.0; const BZ1 := 314.0; const BH := 6.5
const PAD_Y := 47.3                      # the landing pad on the top deck
const PAD := Vector4(-30.0, 30.0, -58.0, 2.0)   # x0 x1 z0 z1
const PAD_C := Vector2(0.0, -28.0)

var rooms: Array = []                    # [x0, x1, z0, z1, y]
var obstacles: Array = []                # [x0, x1, z0, z1, y, round]
var lifts: Array = []                    # {a: Vector3, b: Vector3, name_a, name_b, car: Node3D}
var helms: Array = []                    # {p: Vector3, r: float, word: String}
var carves: Array = []                   # [lo, hi] (ship metres, x is |x|): hull cut away while aboard
var spawn := Vector3(0, FY, -44)
## the landing pad's airspace: the hull's deck towers are cut away above it for good, so a ship can set down there
var pad_carve := [Vector3(0, PAD_Y + 0.15, PAD.z - 2.0), Vector3(PAD.y + 2.0, PAD_Y + 400.0, PAD.w + 2.0)]
var spawn_yaw := PI                      # facing aft, into the lounge

var mats := {}
var st := {}                             # material name -> SurfaceTool

func _init() -> void:
	_materials()
	_lounge(); _corridor(); _reactor(); _hallway(); _bridge(); _pad()
	_commit()
	carves = [
		[Vector3(0, FY - 0.5, LZ0 - 0.5), Vector3(150, FY + LH + 0.5, LZ1 + 0.5)],     # the lounge and the view out of its windows
		[Vector3(0, FY - 0.5, LZ1), Vector3(4.2, FY + 5.0, CZ1)],                       # corridor
		[Vector3(0, FY - 0.5, CZ1), Vector3(RX + 0.6, FY + RH + 0.5, RZ1)],             # reactor hall
		[Vector3(0, FY - 0.5, RZ1), Vector3(6.6, FY + 7.0, LBZ1 + 0.5)],                # hallway and lobby
		[Vector3(0, BF - 1.0, 215.0), Vector3(16.0, BF + 22.0, BZ1 + 0.5)],             # the bridge and the view over the bow
		[Vector3(0, FY, 306.0), Vector3(2.8, BF, 316.0)],                               # the bridge lift shaft
		[Vector3(21.0, FY, -54.5), Vector3(27.0, PAD_Y + 0.5, -45.5)],                  # the landing-pad lift shaft
	]

# ------------------------------------------------------------------ materials
func _panel(alb: Color, seam: Color, cell: Vector2, rough: float, metal := 0.1, var_k := 0.06) -> ShaderMaterial:
	var m := ShaderMaterial.new(); m.shader = preload("res://shaders/panel.gdshader")
	m.set_shader_parameter("albedo", alb); m.set_shader_parameter("seam", seam); m.set_shader_parameter("cell", cell)
	m.set_shader_parameter("roughness", rough); m.set_shader_parameter("metallic", metal); m.set_shader_parameter("variation", var_k)
	return m

func _std(alb: Color, rough: float, metal := 0.0, emit := Color.BLACK, emit_k := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = alb; m.roughness = rough; m.metallic = metal
	if emit_k > 0.0: m.emission_enabled = true; m.emission = emit; m.emission_energy_multiplier = emit_k
	return m

func _materials() -> void:
	mats.floor = _panel(Color(0.045, 0.05, 0.058), Color(0.015, 0.016, 0.02), Vector2(2.4, 2.4), 0.12, 0.35)
	mats.wall = _panel(Color(0.72, 0.74, 0.76), Color(0.32, 0.34, 0.37), Vector2(3.0, 1.5), 0.42, 0.05)
	mats.ceiling = _panel(Color(0.5, 0.52, 0.55), Color(0.18, 0.19, 0.21), Vector2(3.0, 3.0), 0.55)
	mats.darkwall = _panel(Color(0.08, 0.09, 0.105), Color(0.03, 0.03, 0.035), Vector2(2.0, 2.0), 0.35, 0.6)
	mats.metal = _std(Color(0.55, 0.57, 0.6), 0.28, 0.85)
	mats.dark = _std(Color(0.035, 0.038, 0.045), 0.35, 0.4)
	mats.fabric = _std(Color(0.11, 0.13, 0.17), 0.85)
	mats.leather = _std(Color(0.42, 0.26, 0.16), 0.5)
	mats.wood = _std(Color(0.3, 0.19, 0.11), 0.45)
	mats.plant = _std(Color(0.12, 0.3, 0.09), 0.8)
	mats.plant2 = _std(Color(0.2, 0.42, 0.12), 0.75)
	mats.soil = _std(Color(0.06, 0.045, 0.03), 0.95)
	mats.led = _std(Color(0.1, 0.3, 0.4), 0.3, 0.0, Color(0.35, 0.85, 1.0), 4.0)
	mats.warm = _std(Color(0.9, 0.8, 0.6), 0.3, 0.0, Color(1.0, 0.86, 0.66), 3.0)
	mats.orange = _std(Color(0.9, 0.35, 0.05), 0.4, 0.0, Color(1.0, 0.45, 0.1), 1.2)
	mats.yellow = _std(Color(0.95, 0.75, 0.1), 0.6)
	mats.white = _std(Color(0.85, 0.86, 0.88), 0.5)
	mats.red = _std(Color(0.5, 0.02, 0.02), 0.4, 0.0, Color(1.0, 0.1, 0.05), 3.0)
	var g := StandardMaterial3D.new(); g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	g.albedo_color = Color(0.55, 0.72, 0.85, 0.1); g.roughness = 0.03; g.metallic = 0.2; g.metallic_specular = 0.9
	g.cull_mode = BaseMaterial3D.CULL_DISABLED
	mats.glass = g
	var hm := ShaderMaterial.new(); hm.shader = preload("res://shaders/holo.gdshader"); mats.holo = hm
	var cm := ShaderMaterial.new(); cm.shader = preload("res://shaders/holo.gdshader"); cm.set_shader_parameter("core", 1.0)
	cm.set_shader_parameter("tint", Vector3(0.5, 0.9, 1.0)); cm.set_shader_parameter("strength", 0.3); mats.core = cm
	for i in 4:
		var sm := ShaderMaterial.new(); sm.shader = preload("res://shaders/screen.gdshader"); sm.set_shader_parameter("mode", i)
		mats["screen%d" % i] = sm

# ------------------------------------------------------------------ mesh building (one mesh per material)
func _s(mat: String) -> SurfaceTool:
	if not st.has(mat):
		var t := SurfaceTool.new(); t.begin(Mesh.PRIMITIVE_TRIANGLES); st[mat] = t
	return st[mat]

func _quad(t: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, n: Vector3, uv := false) -> void:
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
	for i in [0, 1, 2, 0, 2, 3]:
		t.set_normal(n); t.set_uv(uvs[i]); t.add_vertex([a, b, c, d][i])

## a box: size, centre, material, rotation (Euler, radians)
func box(size: Vector3, c: Vector3, mat: String, rot := Vector3.ZERO) -> void:
	var t := _s(mat); var b := Basis.from_euler(rot); var h := size * 0.5
	var faces := [[Vector3.RIGHT, Vector3.BACK, Vector3.UP], [Vector3.LEFT, Vector3.FORWARD, Vector3.UP], [Vector3.UP, Vector3.RIGHT, Vector3.FORWARD],
		[Vector3.DOWN, Vector3.RIGHT, Vector3.BACK], [Vector3.BACK, Vector3.LEFT, Vector3.UP], [Vector3.FORWARD, Vector3.RIGHT, Vector3.UP]]
	for f in faces:
		var n: Vector3 = f[0]; var u: Vector3 = f[1]; var v: Vector3 = f[2]
		var o := n * h; var uu := u * h; var vv := v * h
		var p := [o - uu - vv, o + uu - vv, o + uu + vv, o - uu + vv]
		_quad(t, c + b * p[0], c + b * p[1], c + b * p[2], c + b * p[3], (b * n).normalized())

## a cylinder along y (or rotated): bottom radius r0, top r1
func cyl(r0: float, r1: float, h: float, c: Vector3, mat: String, seg := 24, open := false, rot := Vector3.ZERO) -> void:
	var t := _s(mat); var b := Basis.from_euler(rot)
	for i in seg:
		var a0 := TAU * i / seg; var a1 := TAU * (i + 1) / seg
		var p00 := Vector3(cos(a0) * r0, -h / 2, sin(a0) * r0); var p10 := Vector3(cos(a1) * r0, -h / 2, sin(a1) * r0)
		var p01 := Vector3(cos(a0) * r1, h / 2, sin(a0) * r1); var p11 := Vector3(cos(a1) * r1, h / 2, sin(a1) * r1)
		var n := b * Vector3(cos((a0 + a1) * 0.5), (r0 - r1) / maxf(h, 0.01), sin((a0 + a1) * 0.5)).normalized()
		_quad(t, c + b * p00, c + b * p10, c + b * p11, c + b * p01, n)
		if not open:
			for cap in [[-h / 2, Vector3.DOWN, r0], [h / 2, Vector3.UP, r1]]:
				var y: float = cap[0]; var r: float = cap[2]
				var cn: Vector3 = b * cap[1]
				t.set_normal(cn); t.add_vertex(c + b * Vector3(0, y, 0))
				t.set_normal(cn); t.add_vertex(c + b * Vector3(cos(a0) * r, y, sin(a0) * r))
				t.set_normal(cn); t.add_vertex(c + b * Vector3(cos(a1) * r, y, sin(a1) * r))

func sphere(r: float, c: Vector3, mat: String, sc := Vector3.ONE, seg := 18, rings := 10) -> void:
	var t := _s(mat)
	var p := func(i: int, j: int) -> Vector3:
		var th := PI * i / rings; var ph := TAU * j / seg
		return Vector3(sin(th) * cos(ph), cos(th), sin(th) * sin(ph))
	for i in rings:
		for j in seg:
			var a: Vector3 = p.call(i, j); var b2: Vector3 = p.call(i, j + 1); var c2: Vector3 = p.call(i + 1, j + 1); var d: Vector3 = p.call(i + 1, j)
			for v in [a, d, c2, a, c2, b2]:
				t.set_normal((v / sc).normalized()); t.add_vertex(c + v * r * sc)

## a flat display facing +normal (yaw turns it about y; 0 faces +z)
func screen(c: Vector3, w: float, h: float, mode: int, yaw := 0.0, tilt := 0.0) -> void:
	var t := _s("screen%d" % mode); var b := Basis.from_euler(Vector3(tilt, yaw, 0))
	var u := b * Vector3(w / 2, 0, 0); var v := b * Vector3(0, h / 2, 0); var n := b * Vector3.BACK
	_quad(t, c - u - v, c + u - v, c + u + v, c - u + v, n, true)
	box(Vector3(w + 0.3, h + 0.3, 0.12), c - n * 0.08, "dark", Vector3(tilt, yaw, 0))

## a strip of light between two points
func led(a: Vector3, b: Vector3, w := 0.06, mat := "led") -> void:
	var d := b - a; var l := d.length()
	if l < 0.01: return
	var yaw := atan2(d.x, d.z); var pitch := -asin(clampf(d.y / l, -1, 1))
	box(Vector3(w, w, l), (a + b) * 0.5, mat, Vector3(pitch, yaw, 0))

func light(p: Vector3, col: Color, energy: float, rng: float) -> void:
	if OS.get_environment("NO_LIGHTS") != "": return
	var o := OmniLight3D.new(); o.position = p; o.light_color = col; o.light_energy = energy; o.omni_range = rng
	o.omni_attenuation = 1.4; o.shadow_enabled = false; o.light_specular = 0.6
	add_child(o)

func walk(x0: float, x1: float, z0: float, z1: float, y: float) -> void: rooms.append([x0, x1, z0, z1, y])
func block(x0: float, x1: float, z0: float, z1: float, y: float, round := false) -> void: obstacles.append([x0, x1, z0, z1, y, round])

## a room: floor, ceiling and walls with optional door openings (half widths) front (z0) and back (z1)
func room(hw: float, z0: float, z1: float, y: float, h: float, wall: String, front_door := 0.0, back_door := 0.0, door_h := 4.5, side_walls := true) -> void:
	var cz := (z0 + z1) * 0.5; var lz := z1 - z0
	box(Vector3(hw * 2, 0.3, lz), Vector3(0, y - 0.15, cz), "floor")
	box(Vector3(hw * 2, 0.3, lz), Vector3(0, y + h + 0.15, cz), "ceiling")
	if side_walls:
		for s in [-1.0, 1.0]: box(Vector3(0.3, h, lz), Vector3(s * (hw + 0.15), y + h / 2, cz), wall)
	for e in [[z0, front_door], [z1, back_door]]:
		var z: float = e[0]; var dw: float = e[1]
		if dw <= 0.0:
			box(Vector3(hw * 2, h, 0.3), Vector3(0, y + h / 2, z), wall)
		else:
			for s in [-1.0, 1.0]: box(Vector3(hw - dw, h, 0.3), Vector3(s * (dw + (hw - dw) / 2), y + h / 2, z), wall)
			box(Vector3(dw * 2, h - door_h, 0.3), Vector3(0, y + door_h + (h - door_h) / 2, z), wall)
			for s in [-1.0, 1.0]: led(Vector3(s * dw, y, z), Vector3(s * dw, y + door_h, z), 0.08)
			led(Vector3(-dw, y + door_h, z), Vector3(dw, y + door_h, z), 0.08)

func _commit() -> void:
	for k in st:
		var mi := MeshInstance3D.new(); mi.mesh = (st[k] as SurfaceTool).commit(); mi.material_override = mats[k]
		if k in ["glass", "holo", "core", "led", "warm"] or String(k).begins_with("screen"):
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)

# ------------------------------------------------------------------ the grand lounge
func _lounge() -> void:
	var y := FY; var cz := (LZ0 + LZ1) * 0.5; var lz := LZ1 - LZ0
	box(Vector3(LX * 2, 0.3, lz), Vector3(0, y - 0.15, cz), "floor")
	# a coffered ceiling: panels between beams, warm light troughs
	box(Vector3(LX * 2, 0.3, lz), Vector3(0, y + LH + 0.15, cz), "ceiling")
	for z in range(int(LZ0) + 10, int(LZ1), 10):
		box(Vector3(LX * 2, 1.2, 0.8), Vector3(0, y + LH - 0.6, z), "metal")
		led(Vector3(-LX + 1, y + LH - 1.25, z), Vector3(LX - 1, y + LH - 1.25, z), 0.12, "warm")
	for x in [-50.0, -18.0, 18.0, 50.0]: box(Vector3(0.8, 1.2, lz), Vector3(x, y + LH - 0.6, cz), "metal")
	# front wall (the bow side) with a wall of screens, back wall with the door aft
	box(Vector3(LX * 2, LH, 0.4), Vector3(0, y + LH / 2, LZ0), "darkwall")
	screen(Vector3(0, y + 8.5, LZ0 + 0.3), 30, 11, 0)
	screen(Vector3(-24, y + 7.5, LZ0 + 0.3), 12, 6, 1)
	screen(Vector3(24, y + 7.5, LZ0 + 0.3), 12, 6, 3)
	screen(Vector3(-40, y + 6.5, LZ0 + 0.3), 9, 4.5, 2)
	screen(Vector3(40, y + 6.5, LZ0 + 0.3), 9, 4.5, 2)
	led(Vector3(-LX, y + 0.05, LZ0 + 0.3), Vector3(LX, y + 0.05, LZ0 + 0.3), 0.1)
	var dw := 2.6
	for s in [-1.0, 1.0]: box(Vector3(LX - dw, LH, 0.4), Vector3(s * (dw + (LX - dw) / 2), y + LH / 2, LZ1), "wall")
	box(Vector3(dw * 2, LH - 4.5, 0.4), Vector3(0, y + 4.5 + (LH - 4.5) / 2, LZ1), "wall")
	for s in [-1.0, 1.0]: led(Vector3(s * dw, y, LZ1 - 0.25), Vector3(s * dw, y + 4.5, LZ1 - 0.25), 0.1)
	led(Vector3(-dw, y + 4.5, LZ1 - 0.25), Vector3(dw, y + 4.5, LZ1 - 0.25), 0.1)
	# the window walls: full-height glass between slim mullions, a low sill, a header beam
	for s in [-1.0, 1.0]:
		var x: float = s * LX
		box(Vector3(0.05, LH - 1.2, lz), Vector3(x, y + 0.6 + (LH - 1.2) / 2, cz), "glass")
		box(Vector3(1.0, 0.6, lz), Vector3(x, y + 0.3, cz), "dark")
		led(Vector3(x - s * 0.52, y + 0.62, LZ0), Vector3(x - s * 0.52, y + 0.62, LZ1), 0.06)
		box(Vector3(1.0, 0.8, lz), Vector3(x, y + LH - 0.4, cz), "metal")
		for z in range(int(LZ0), int(LZ1) + 1, 8):
			box(Vector3(0.6, LH, 0.45), Vector3(x, y + LH / 2, z), "metal")
	walk(-LX + 0.9, LX - 0.9, LZ0 + 0.7, LZ1 - 0.6, y)
	# glowing lanes in the floor, leading to the windows
	for z in range(int(LZ0) + 5, int(LZ1) - 4, 10): led(Vector3(-LX + 2, y + 0.005, z), Vector3(LX - 2, y + 0.005, z), 0.05)
	# the holo planet, centre stage, ringed by curved sofas
	var ht := Vector3(0, y, -16)
	cyl(4.6, 5.0, 1.0, ht + Vector3(0, 0.5, 0), "dark", 40)
	cyl(4.3, 4.3, 0.06, ht + Vector3(0, 1.03, 0), "led", 40)
	sphere(3.0, ht + Vector3(0, 5.2, 0), "holo", Vector3.ONE, 28, 16)
	for i in 3: cyl(3.9 + i * 0.5, 3.9 + i * 0.5, 0.05, ht + Vector3(0, 5.2, 0), "led", 48, true, Vector3(0.35 + i * 0.3, i * 1.1, 0))
	block(ht.x - 5.2, ht.x + 5.2, ht.z - 5.2, ht.z + 5.2, y, true)
	for a in [0.0, PI * 0.5, PI, PI * 1.5]:
		var c := ht + Vector3(sin(a + 0.6) * 10.5, 0, cos(a + 0.6) * 10.5)
		box(Vector3(6.5, 0.5, 2.0), c + Vector3(0, 0.4, 0), "fabric", Vector3(0, a + 0.6, 0))
		box(Vector3(6.5, 1.0, 0.5), c + Vector3(sin(a + 0.6) * 0.9, 0.9, cos(a + 0.6) * 0.9), "fabric", Vector3(0, a + 0.6, 0))
		box(Vector3(6.6, 0.08, 2.1), c + Vector3(0, 0.12, 0), "led", Vector3(0, a + 0.6, 0))
		block(c.x - 3.2, c.x + 3.2, c.z - 3.2, c.z + 3.2, y, true)
	light(ht + Vector3(0, 6, 0), Color(0.4, 0.85, 1.0), 4.0, 22.0)
	# sofa groups facing each window, with low tables and floor lamps
	for s in [-1.0, 1.0]:
		for z in [-46.0, -26.0, -6.0, 12.0]:
			var x: float = s * (LX - 9)
			box(Vector3(2.0, 0.5, 7.0), Vector3(x, y + 0.4, z), "leather")
			box(Vector3(0.6, 1.1, 7.0), Vector3(x + s * -0.9, y + 0.85, z), "leather")
			for e in [-1.0, 1.0]: box(Vector3(2.4, 0.9, 0.6), Vector3(x, y + 0.6, z + e * 3.6), "leather")
			box(Vector3(2.2, 0.45, 3.5), Vector3(x + s * 2.6, y + 0.3, z), "wood")
			box(Vector3(2.3, 0.04, 3.6), Vector3(x + s * 2.6, y + 0.54, z), "glass")
			cyl(0.08, 0.08, 2.4, Vector3(x - s * 1.6, y + 1.2, z + 4.6), "metal", 8)
			sphere(0.45, Vector3(x - s * 1.6, y + 2.6, z + 4.6), "warm", Vector3.ONE, 12, 8)
			block(x - 1.4 + minf(s, 0) * 3.8, x + 1.4 + maxf(s, 0) * 3.8, z - 4.0, z + 4.0, y)
			light(Vector3(x - s * 1.6, y + 3.0, z + 4.6), Color(1.0, 0.82, 0.6), 1.6, 9.0)
	# pillars wrapped in rings of light
	for x in [-50.0, -18.0, 18.0, 50.0]:
		for z in [-40.0, 0.0]:
			box(Vector3(1.8, LH, 1.8), Vector3(x, y + LH / 2, z), "metal")
			for h in [0.7, 3.4, LH - 3.0]: box(Vector3(1.95, 0.12, 1.95), Vector3(x, y + h, z), "led")
			box(Vector3(2.6, 0.4, 2.6), Vector3(x, y + 0.2, z), "dark")
			block(x - 1.6, x + 1.6, z - 1.6, z + 1.6, y)
	# planters with small trees
	for p in [Vector2(-34, -50), Vector2(34, -50), Vector2(-34, 12), Vector2(34, 12), Vector2(-62, -16), Vector2(62, -16)]:
		box(Vector3(3.6, 1.0, 3.6), Vector3(p.x, y + 0.5, p.y), "darkwall")
		box(Vector3(3.3, 0.1, 3.3), Vector3(p.x, y + 0.95, p.y), "soil")
		box(Vector3(3.7, 0.06, 3.7), Vector3(p.x, y + 1.02, p.y), "led")
		cyl(0.15, 0.22, 2.4, Vector3(p.x, y + 2.1, p.y), "wood", 8)
		sphere(1.4, Vector3(p.x, y + 3.6, p.y), "plant", Vector3(1, 0.85, 1), 12, 8)
		sphere(0.9, Vector3(p.x + 0.7, y + 4.3, p.y - 0.4), "plant2", Vector3.ONE, 10, 7)
		sphere(0.8, Vector3(p.x - 0.6, y + 3.3, p.y + 0.6), "plant2", Vector3.ONE, 10, 7)
		block(p.x - 2.1, p.x + 2.1, p.y - 2.1, p.y + 2.1, y)
	# the bar, against the back wall on the starboard side
	var bz := LZ1 - 4.5
	box(Vector3(22, 1.15, 1.6), Vector3(42, y + 0.58, bz), "wood")
	box(Vector3(22.4, 0.08, 1.9), Vector3(42, y + 1.19, bz), "white")
	led(Vector3(31, y + 0.08, bz - 0.85), Vector3(53, y + 0.08, bz - 0.85), 0.06)
	box(Vector3(22, 3.0, 0.6), Vector3(42, y + 2.2, LZ1 - 0.6), "darkwall")
	for i in 7: box(Vector3(2.6, 0.08, 0.5), Vector3(32 + i * 3.3, y + 2.6, LZ1 - 0.8), "warm")
	for i in 8: cyl(0.35, 0.3, 0.85, Vector3(32.5 + i * 2.7, y + 0.42, bz - 2.0), "metal", 12)
	block(30.5, 53.5, bz - 1.0, LZ1, y)
	light(Vector3(42, y + 3.5, bz - 1), Color(1.0, 0.75, 0.5), 2.0, 14.0)
	# the helm station under the screens
	var hz := LZ0 + 6.0
	box(Vector3(12, 1.1, 2.2), Vector3(0, y + 0.55, hz), "dark")
	box(Vector3(12.2, 0.08, 2.4), Vector3(0, y + 1.13, hz), "metal")
	led(Vector3(-5.8, y + 1.18, hz + 1.15), Vector3(5.8, y + 1.18, hz + 1.15), 0.06)
	screen(Vector3(-3.6, y + 1.95, hz - 0.5), 3.0, 1.7, 1, 0.25, -0.3)
	screen(Vector3(0, y + 2.0, hz - 0.6), 3.4, 1.8, 3, 0.0, -0.3)
	screen(Vector3(3.6, y + 1.95, hz - 0.5), 3.0, 1.7, 2, -0.25, -0.3)
	block(-6.2, 6.2, hz - 1.3, hz + 1.3, y)
	helms.append({"p": Vector3(0, y, hz + 2.4), "r": 4.0, "word": "the helm"})
	# the lift up to the landing pad (glass tube, front starboard)
	_lift_tube(Vector3(24, y, -50), LH)
	# lights across the room
	for x in [-60.0, -30.0, 0.0, 30.0, 60.0]:
		for z in [-48.0, -22.0, 4.0]:
			light(Vector3(x, y + LH - 2.0, z), Color(1.0, 0.9, 0.78), 2.2, 26.0)

## a glass lift tube with a lit floor ring, running up h metres from its floor
func _lift_tube(p: Vector3, h: float) -> void:
	cyl(2.1, 2.1, h, p + Vector3(0, h / 2, 0), "glass", 32, true)
	cyl(2.4, 2.4, 0.15, p + Vector3(0, 0.07, 0), "dark", 32)
	cyl(2.3, 2.3, 0.04, p + Vector3(0, 0.16, 0), "led", 32, true)
	for yy in range(3, int(h), 4): cyl(2.15, 2.15, 0.1, p + Vector3(0, yy, 0), "led", 32, true)
	box(Vector3(0.5, 1.2, 0.2), p + Vector3(2.5, 1.2, 0), "dark")
	box(Vector3(0.3, 0.3, 0.05), p + Vector3(2.5, 1.35, -0.12), "led")

## a lift car that rides between two stops
func _make_car() -> Node3D:
	var car := Node3D.new()
	var mi := MeshInstance3D.new()
	var t := SurfaceTool.new(); t.begin(Mesh.PRIMITIVE_TRIANGLES)
	var cm := CylinderMesh.new(); cm.top_radius = 1.9; cm.bottom_radius = 1.9; cm.height = 0.25; cm.radial_segments = 32
	mi.mesh = cm; mi.material_override = mats.dark; mi.position.y = -0.12; car.add_child(mi)
	var ring := MeshInstance3D.new(); var rm := TorusMesh.new(); rm.inner_radius = 1.75; rm.outer_radius = 1.9
	ring.mesh = rm; ring.material_override = mats.led; ring.position.y = 0.02; car.add_child(ring)
	var l := OmniLight3D.new(); l.light_color = Color(0.5, 0.85, 1.0); l.light_energy = 1.2; l.omni_range = 6; l.position.y = 2.5; car.add_child(l)
	add_child(car)
	return car

# ------------------------------------------------------------------ corridor, reactor hall, hallway, lobby
func _corridor() -> void:
	var y := FY; var hw := 3.6; var h := 4.6
	room(hw, LZ1, CZ1, y, h, "wall", 2.6, 2.6, 4.5)
	walk(-hw + 0.5, hw - 0.5, LZ1 - 1.5, CZ1 + 1.5, y)
	for z in range(int(LZ1) + 6, int(CZ1) - 2, 8):
		for s in [-1.0, 1.0]:
			box(Vector3(0.5, h, 0.7), Vector3(s * (hw - 0.2), y + h / 2, z), "metal")
			led(Vector3(s * (hw - 0.48), y + 0.15, z), Vector3(s * (hw - 0.48), y + h - 0.5, z), 0.05)
		box(Vector3(hw * 2, 0.45, 0.7), Vector3(0, y + h - 0.22, z), "metal")
		led(Vector3(-hw + 0.5, y + h - 0.47, z), Vector3(hw - 0.5, y + h - 0.47, z), 0.05)
	led(Vector3(0, y + 0.01, LZ1), Vector3(0, y + 0.01, CZ1), 0.1)
	for z in range(int(LZ1) + 10, int(CZ1), 16): light(Vector3(0, y + h - 0.8, z), Color(0.85, 0.92, 1.0), 1.4, 12.0)
	for z in [52.0, 100.0]:
		for s in [-1.0, 1.0]: screen(Vector3(s * (hw - 0.02), y + 2.2, z), 3.2, 1.6, 2 if s < 0 else 3, -s * PI / 2)

func _reactor() -> void:
	var y := FY
	room(RX, CZ1, RZ1, y, RH, "darkwall", 2.6, 2.6, 4.5)
	walk(-RX + 1.4, RX - 1.4, CZ1 + 0.6, RZ1 - 0.6, y)
	var rc := Vector3(0, y, 170)
	cyl(8.0, 8.6, 1.5, rc + Vector3(0, 0.75, 0), "dark", 40)
	cyl(3.8, 3.8, RH - 3.0, rc + Vector3(0, 1.5 + (RH - 3.0) / 2, 0), "core", 40, true)
	for yy in [3.5, 7.5, 11.5, 15.5]:
		cyl(5.4, 5.4, 0.9, rc + Vector3(0, yy, 0), "metal", 40, true)
		cyl(5.45, 5.45, 0.12, rc + Vector3(0, yy + 0.5, 0), "led", 40, true)
	cyl(8.0, 8.6, 1.5, rc + Vector3(0, RH - 0.75, 0), "dark", 40)
	cyl(10.0, 10.0, 1.1, rc + Vector3(0, 0.55, 0), "metal", 48, true)
	cyl(10.05, 10.05, 0.08, rc + Vector3(0, 1.12, 0), "led", 48, true)
	block(-10.4, 10.4, rc.z - 10.4, rc.z + 10.4, y, true)
	for s in [-1.0, 1.0]:
		for yy in [2.5, 6.0, 11.0]: cyl(0.7, 0.7, RZ1 - CZ1 - 2, Vector3(s * (RX - 1.2), y + yy, (CZ1 + RZ1) / 2), "metal", 14, false, Vector3(PI / 2, 0, 0))
		screen(Vector3(s * (RX - 0.1), y + 4, 160), 6, 3, 2, -s * PI / 2)
		screen(Vector3(s * (RX - 0.1), y + 4, 182), 6, 3, 3, -s * PI / 2)
	var l := OmniLight3D.new(); l.position = rc + Vector3(0, 9, 0); l.light_color = Color(0.45, 0.85, 1.0); l.light_energy = 3.0; l.omni_range = 34.0
	add_child(l)
	for z in [146.0, 194.0]: light(Vector3(0, y + RH - 2, z), Color(0.8, 0.9, 1.0), 1.5, 20.0)

func _hallway() -> void:
	var y := FY
	room(2.6, RZ1, HZ1, y, 4.0, "wall", 2.6, 2.6, 4.0, true)
	walk(-2.1, 2.1, RZ1 - 1.5, HZ1 + 1.5, y)
	for z in range(int(RZ1) + 5, int(HZ1), 6):
		box(Vector3(5.2, 0.3, 0.5), Vector3(0, y + 3.85, z), "metal")
		led(Vector3(-2.3, y + 3.68, z), Vector3(2.3, y + 3.68, z), 0.05, "warm")
	for z in range(int(RZ1) + 12, int(HZ1), 24): light(Vector3(0, y + 3.3, z), Color(1.0, 0.9, 0.75), 1.0, 10.0)
	# the lobby under the tower, the lift to the bridge at its back
	room(6.5, HZ1, LBZ1, y, 7.0, "wall", 2.6, 0.0, 4.0)
	walk(-6.0, 6.0, HZ1 - 0.5, LBZ1 - 0.6, y)
	screen(Vector3(-6.45, y + 3.0, 300), 5, 2.6, 0, PI / 2)
	screen(Vector3(6.45, y + 3.0, 300), 5, 2.6, 1, -PI / 2)
	light(Vector3(0, y + 6, 300), Color(1.0, 0.92, 0.8), 1.6, 14.0)
	_lift_tube(Vector3(0, y, 311), 7.0)
	var car := _make_car(); car.position = Vector3(0, y, 311)
	lifts.append({"a": Vector3(0, y, 311), "b": Vector3(0, BF, 311), "name_a": "the lobby", "name_b": "the bridge", "car": car})

# ------------------------------------------------------------------ the bridge, high in the tower
func _bridge() -> void:
	var y := BF; var wz0 := 298.0
	box(Vector3(BX * 2, 0.3, BZ1 - BZ0), Vector3(0, y - 0.15, (BZ0 + BZ1) / 2), "floor")
	box(Vector3(BX * 2, 0.3, BZ1 - wz0), Vector3(0, y + BH + 0.15, (wz0 + BZ1) / 2), "ceiling")
	box(Vector3(BX * 2, BH, 0.3), Vector3(0, y + BH / 2, BZ1), "darkwall")
	# glass: the slanted front, the sides and a skylight over the front half
	box(Vector3(BX * 2, BH + 1.0, 0.06), Vector3(0, y + BH / 2, BZ0 - 0.9), "glass", Vector3(-0.32, 0, 0))
	box(Vector3(BX * 2, 0.06, wz0 - BZ0 + 2), Vector3(0, y + BH + 0.2, (BZ0 + wz0) / 2 - 1), "glass")
	for s in [-1.0, 1.0]:
		box(Vector3(0.06, BH, BZ1 - BZ0), Vector3(s * BX, y + BH / 2, (BZ0 + BZ1) / 2), "glass")
		box(Vector3(0.6, 0.6, BZ1 - BZ0), Vector3(s * BX, y + 0.3, (BZ0 + BZ1) / 2), "dark")
		box(Vector3(0.5, 0.5, BZ1 - BZ0), Vector3(s * BX, y + BH + 0.25, (BZ0 + BZ1) / 2), "metal")
		led(Vector3(s * (BX - 0.35), y + 0.62, BZ0), Vector3(s * (BX - 0.35), y + 0.62, BZ1), 0.05)
		for z in [292.0, 300.0, 308.0]: box(Vector3(0.4, BH, 0.4), Vector3(s * BX, y + BH / 2, z), "metal")
		# side stations
		box(Vector3(1.4, 1.05, 5.0), Vector3(s * 7.8, y + 0.52, 300), "dark")
		led(Vector3(s * 7.08, y + 1.06, 297.6), Vector3(s * 7.08, y + 1.06, 302.4), 0.04)
		screen(Vector3(s * 7.9, y + 1.85, 300), 3.4, 1.4, 1 if s < 0 else 2, -s * PI / 2, 0.0)
		block(s * 7.8 - 0.9, s * 7.8 + 0.9, 297.3, 302.7, y)
	box(Vector3(BX * 2, 0.7, 0.4), Vector3(0, y + 0.35, BZ0 + 0.3), "dark")
	# the captain's chair and the flight consoles before it
	var seat := Vector3(0, y, 292.5)
	box(Vector3(1.1, 0.35, 1.1), seat + Vector3(0, 0.6, 0), "fabric")
	box(Vector3(1.0, 1.0, 0.22), seat + Vector3(0, 1.25, 0.55), "fabric", Vector3(0.15, 0, 0))
	box(Vector3(1.05, 0.05, 0.25), seat + Vector3(0, 1.76, 0.62), "led")
	for s in [-1.0, 1.0]: box(Vector3(0.25, 0.3, 1.0), seat + Vector3(s * 0.72, 0.95, 0.05), "metal")
	cyl(0.2, 0.3, 0.4, seat + Vector3(0, 0.2, 0), "metal", 12)
	box(Vector3(4.5, 0.9, 0.9), Vector3(0, y + 0.45, 289.8), "dark")
	screen(Vector3(-1.4, y + 1.25, 290.0), 1.8, 0.9, 3, 0.0, -0.6)
	screen(Vector3(1.4, y + 1.25, 290.0), 1.8, 0.9, 1, 0.0, -0.6)
	block(-0.8, 0.8, 291.7, 293.4, y)
	block(-2.4, 2.4, 289.2, 290.4, y)
	helms.append({"p": seat + Vector3(0, 0, 0.0), "r": 1.6, "word": "the captain's chair"})
	# a holo table at the back
	cyl(1.6, 1.9, 1.0, Vector3(0, y + 0.5, 305), "dark", 28)
	cyl(1.5, 1.5, 0.05, Vector3(0, y + 1.03, 305), "led", 28)
	sphere(0.7, Vector3(0, y + 1.9, 305), "holo", Vector3.ONE, 20, 12)
	block(-2.1, 2.1, 302.9, 307.1, y, true)
	walk(-BX + 0.6, BX - 0.6, BZ0 + 0.8, BZ1 - 0.6, y)
	for x in [-5.0, 5.0]: light(Vector3(x, y + BH - 0.6, 305), Color(0.9, 0.95, 1.0), 1.2, 12.0)
	_lift_tube(Vector3(0, y, 311), BH)

# ------------------------------------------------------------------ the landing pad on the top deck
func _pad() -> void:
	var y := PAD_Y
	var c := Vector3((PAD.x + PAD.y) / 2, y, (PAD.z + PAD.w) / 2)
	var sz := Vector3(PAD.y - PAD.x, 0.6, PAD.w - PAD.z)
	box(sz, c - Vector3(0, 0.3, 0), "darkwall")
	box(sz + Vector3(0.6, -0.4, 0.6), c - Vector3(0, 0.7, 0), "metal")
	# the landing circle and the H
	var pc := Vector3(PAD_C.x, y + 0.02, PAD_C.y)
	cyl(18.0, 18.0, 0.02, pc, "yellow", 64, true)
	cyl(17.4, 17.4, 0.02, pc + Vector3(0, 0.001, 0), "darkwall", 64)
	for k in [[-17.4, 0], [17.4, 0]]: pass
	cyl(17.9, 17.9, 0.03, pc + Vector3(0, 0.005, 0), "yellow", 64, true)
	box(Vector3(1.6, 0.03, 12), pc + Vector3(-4.5, 0.01, 0), "white")
	box(Vector3(1.6, 0.03, 12), pc + Vector3(4.5, 0.01, 0), "white")
	box(Vector3(9.0, 0.03, 1.6), pc + Vector3(0, 0.01, 0), "white")
	# a ring of landing lights and edge lights round the deck
	for i in 24:
		var a := TAU * i / 24.0
		box(Vector3(0.5, 0.12, 0.5), pc + Vector3(cos(a) * 19.5, 0.06, sin(a) * 19.5), "led")
	for x in range(int(PAD.x), int(PAD.y) + 1, 6):
		for z in [PAD.z, PAD.w]: box(Vector3(0.4, 0.25, 0.4), Vector3(x, y + 0.12, z), "red")
	for z in range(int(PAD.z), int(PAD.w) + 1, 6):
		for x in [PAD.x, PAD.y]: box(Vector3(0.4, 0.25, 0.4), Vector3(x, y + 0.12, z), "red")
	# low railing round the edge
	for e in [[Vector3(PAD.x, y, PAD.z), Vector3(PAD.y, y, PAD.z)], [Vector3(PAD.x, y, PAD.w), Vector3(PAD.y, y, PAD.w)],
			[Vector3(PAD.x, y, PAD.z), Vector3(PAD.x, y, PAD.w)], [Vector3(PAD.y, y, PAD.z), Vector3(PAD.y, y, PAD.w)]]:
		led(e[0] + Vector3(0, 1.05, 0), e[1] + Vector3(0, 1.05, 0), 0.08, "metal")
	# the lift kiosk: a canopy on posts over the shaft, glass on the outboard side
	var kp := Vector3(24, y, -50)
	box(Vector3(6, 0.25, 6), kp + Vector3(0, 3.6, 0), "metal")
	box(Vector3(6.1, 0.06, 6.1), kp + Vector3(0, 3.46, 0), "led")
	for p in [Vector3(-2.8, 0, -2.8), Vector3(2.8, 0, -2.8), Vector3(-2.8, 0, 2.8), Vector3(2.8, 0, 2.8)]: box(Vector3(0.3, 3.5, 0.3), kp + p + Vector3(0, 1.75, 0), "metal")
	box(Vector3(0.05, 3.3, 5.6), kp + Vector3(2.85, 1.7, 0), "glass")
	cyl(2.3, 2.3, 0.04, kp + Vector3(0, 0.02, 0), "led", 32, true)
	light(kp + Vector3(0, 3.0, 0), Color(0.5, 0.85, 1.0), 1.5, 8.0)
	walk(PAD.x + 1.2, PAD.y - 1.2, PAD.z + 1.2, PAD.w - 1.2, y)
	var car := _make_car(); car.position = Vector3(24, FY, -50)
	lifts.append({"a": Vector3(24, FY, -50), "b": Vector3(24, y, -50), "name_a": "the lounge", "name_b": "the landing pad", "car": car})

# ------------------------------------------------------------------ walking
## the floor under (x, z) nearest to height y, or NAN if that spot isn't walkable
func floor_at(x: float, z: float, y: float) -> float:
	var best := NAN
	for r in rooms:
		if x >= r[0] and x <= r[1] and z >= r[2] and z <= r[3] and absf(r[4] - y) < 1.5:
			if is_nan(best) or absf(r[4] - y) < absf(best - y): best = r[4]
	if is_nan(best): return NAN
	for o in obstacles:
		if absf(o[4] - best) > 2.0: continue
		if o[5]:
			var cx: float = (o[0] + o[1]) / 2; var cz: float = (o[2] + o[3]) / 2; var rr: float = (o[1] - o[0]) / 2
			if (x - cx) * (x - cx) + (z - cz) * (z - cz) < rr * rr: return NAN
		elif x >= o[0] and x <= o[1] and z >= o[2] and z <= o[3]: return NAN
	return best

## where you are, in words
func place_name(p: Vector3) -> String:
	if p.y > BF - 2: return "the bridge"
	if p.y > PAD_Y - 2: return "the landing pad"
	if p.z < LZ1: return "the lounge"
	if p.z < CZ1: return "the corridor"
	if p.z < RZ1: return "the reactor hall"
	if p.z < HZ1: return "the hallway"
	return "the lobby"

## show this world on the holo globes (the autopilot's destination, or the world you're at)
const HOLO_WORLDS := {
	"earth": [Color(0.35, 0.9, 0.4), Color(0.12, 0.4, 1.0), Color(0.4, 0.8, 1.0), 0.0],
	"ruber": [Color(1.0, 0.45, 0.18), Color(0.45, 0.12, 0.05), Color(1.0, 0.6, 0.35), 2.3],
	"verdance": [Color(0.25, 1.0, 0.8), Color(0.45, 0.2, 0.9), Color(0.5, 1.0, 0.9), 4.1]}
var holo_kind := ""
func set_holo(kind: String) -> void:
	if kind == holo_kind or not HOLO_WORLDS.has(kind): return
	holo_kind = kind
	var w: Array = HOLO_WORLDS[kind]
	var m: ShaderMaterial = mats.holo
	m.set_shader_parameter("land_col", Vector3(w[0].r, w[0].g, w[0].b))
	m.set_shader_parameter("sea_col", Vector3(w[1].r, w[1].g, w[1].b))
	m.set_shader_parameter("tint", Vector3(w[2].r, w[2].g, w[2].b))
	m.set_shader_parameter("pattern", w[3])
