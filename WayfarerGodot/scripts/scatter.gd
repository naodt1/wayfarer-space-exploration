## Grass and rocks around the camera (a port of the Mac game's Rocks.swift idea): a field ~130 m across is scattered on a
## worker thread from the planet's height and ground-layer weights, then shown as two MultiMeshes. The field is anchored
## at a double-precision point and re-scattered when the camera wanders 25 m from it.
class_name Scatter
extends Node3D

const HALF := 160.0                 # field half-size (m)
const G := 64                       # height-grid resolution across the field
const MAX_GRASS := 42000          # at HIGH quality; scaled by set_density()
var max_grass := MAX_GRASS
const MAX_ROCKS := 260

var planet: Planet
var grass: MultiMeshInstance3D
var rocks: MultiMeshInstance3D
var ax := 0.0; var ay := 0.0; var az := 0.0           # current field anchor (metres from the planet centre)
var has_field := false
var task := -1
var result: Dictionary = {}
var mutex := Mutex.new()

func _init(p: Planet) -> void:
	planet = p
	grass = MultiMeshInstance3D.new()
	var gm := MultiMesh.new(); gm.transform_format = MultiMesh.TRANSFORM_3D; gm.use_colors = true; gm.mesh = _clump_mesh()
	grass.multimesh = gm
	var gmat := ShaderMaterial.new(); gmat.shader = preload("res://shaders/grass.gdshader")
	grass.material_override = gmat
	grass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grass.extra_cull_margin = 200.0
	add_child(grass)
	rocks = MultiMeshInstance3D.new()
	var rm := MultiMesh.new(); rm.transform_format = MultiMesh.TRANSFORM_3D; rm.use_colors = true; rm.mesh = _rock_mesh()
	rocks.multimesh = rm
	var rmat := ShaderMaterial.new(); rmat.shader = preload("res://shaders/rock.gdshader")
	rmat.set_shader_parameter("layer_albedo", preload("res://assets/terrain/ground_albedo.jpg"))
	rmat.set_shader_parameter("layer_pack", preload("res://assets/terrain/ground_pack.png"))
	rocks.material_override = rmat
	rocks.extra_cull_margin = 200.0
	add_child(rocks)

## switch to another world (the field is rebuilt there)
func set_planet(p: Planet) -> void:
	if p == planet: return
	planet = p; has_field = false; ax = 1e12
	grass.multimesh.instance_count = 0; rocks.multimesh.instance_count = 0

## called every frame with the camera's double-precision position and altitude
func update(cx: float, cy: float, cz: float, cam_alt: float) -> void:
	visible = cam_alt < 1500.0
	# a finished scatter replaces the field
	mutex.lock()
	var r := result; result = {}
	mutex.unlock()
	if not r.is_empty():
		WorkerThreadPool.wait_for_task_completion(task); task = -1
		ax = r["ax"]; ay = r["ay"]; az = r["az"]; has_field = true
		grass.multimesh.instance_count = 0
		grass.multimesh.instance_count = r["ng"]
		if r["ng"] > 0: grass.multimesh.buffer = r["gbuf"]
		rocks.multimesh.instance_count = 0
		rocks.multimesh.instance_count = r["nr"]
		if r["nr"] > 0: rocks.multimesh.buffer = r["rbuf"]
	# re-scatter when the camera is low and has moved away from the field's centre
	var dx := cx - ax; var dy := cy - ay; var dz := cz - az
	var far := not has_field or sqrt(dx * dx + dy * dy + dz * dz) > 25.0 + maxf(0.0, cam_alt - 60.0)
	if cam_alt < 400.0 and far and task == -1:
		# anchor on the ground under the camera
		var up := Vector3(cx, cy, cz).normalized()
		var gr := planet.ground_radius(up)
		var k := gr / sqrt(cx * cx + cy * cy + cz * cz)
		task = WorkerThreadPool.add_task(_scatter.bind(cx * k, cy * k, cz * k))
	position = Vector3(ax - cx, ay - cy, az - cz)

func _scatter(px: float, py: float, pz: float) -> void:
	var ar := sqrt(px * px + py * py + pz * pz)
	var up := Vector3(px / ar, py / ar, pz / ar)
	var t1 := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
	var t2 := up.cross(t1)
	var A := Vector3(px, py, pz)
	# height grid over the field: local offsets (m) and ground-layer weights
	var off := PackedVector3Array(); off.resize((G + 1) * (G + 1))
	var wts := []; wts.resize((G + 1) * (G + 1))
	var cols := PackedColorArray(); cols.resize((G + 1) * (G + 1))
	var step := HALF * 2.0 / G
	var elev := PackedFloat32Array(); elev.resize((G + 1) * (G + 1))
	var dirs := PackedVector3Array(); dirs.resize((G + 1) * (G + 1))
	for j in G + 1:
		for i in G + 1:
			var x := -HALF + i * step; var y := -HALF + j * step
			var d := (A + t1 * x + t2 * y).normalized()
			var e := planet.height(d, 14)
			var h := planet.R + maxf(e, 0.0) * 1000.0 - ar - (x * x + y * y) / (2.0 * planet.R)
			var k := j * (G + 1) + i
			off[k] = t1 * x + t2 * y + up * h; elev[k] = e; dirs[k] = d
	for j in G + 1:
		for i in G + 1:
			var k := j * (G + 1) + i
			var a := off[k + 1] if i < G else off[k]; var b := off[k - 1] if i > 0 else off[k]
			var c := off[k + G + 1] if j < G else off[k]; var dd := off[k - G - 1] if j > 0 else off[k]
			var n := (a - b).cross(c - dd).normalized()
			if n.dot(up) < 0.0: n = -n
			var slope := 1.0 - n.dot(up)
			wts[k] = planet.layer_weights(dirs[k], elev[k], slope)
			cols[k] = planet.color_at(dirs[k], elev[k], slope * 4.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(int(px / 7.0), int(py / 7.0), int(pz / 7.0)))
	# grass
	var gbuf := PackedFloat32Array(); var ng := 0
	var cap := max_grass
	var tries := cap * 2
	for s in tries:
		if ng >= cap: break
		var rr := HALF * pow(rng.randf(), 0.75); var th := rng.randf() * TAU      # denser near the middle of the field
		var x := cos(th) * rr; var y := sin(th) * rr
		var fi := (x + HALF) / step; var fj := (y + HALF) / step
		var i := mini(int(fi), G - 1); var j := mini(int(fj), G - 1)
		var k := j * (G + 1) + i
		var w: PackedFloat32Array = wts[k]
		var dens := minf(1.0, (w[0] + w[1] * 0.7 + w[3] * 0.1) * 1.3)
		if rng.randf() > dens: continue
		var p := _interp(off, i, j, fi - i, fj - j)
		var col: Color = cols[k]
		var tint := Color(0.08, 0.125, 0.03).lerp(Color(col.r * 1.3, col.g * 1.4, col.b * 1.0), 0.35)
		tint = tint.lerp(Color(0.2, 0.15, 0.06), w[3] * 0.8)                       # dry, sandy grass
		var yaw := rng.randf() * TAU
		var sc := rng.randf_range(0.8, 1.4) * (0.6 + 0.6 * dens) * (1.0 + rr / HALF * 0.9)   # bigger clumps farther out
		var bs := Basis(t1, up, -t2).rotated(up, yaw).scaled(Vector3(sc, sc * rng.randf_range(0.8, 1.3), sc))
		_push(gbuf, bs, p, tint)
		ng += 1
	# rocks
	var rbuf := PackedFloat32Array(); var nr := 0
	for s in MAX_ROCKS * 6:
		if nr >= MAX_ROCKS: break
		var x := rng.randf_range(-HALF, HALF); var y := rng.randf_range(-HALF, HALF)
		if x * x + y * y > HALF * HALF: continue
		var fi := (x + HALF) / step; var fj := (y + HALF) / step
		var i := mini(int(fi), G - 1); var j := mini(int(fj), G - 1)
		var k := j * (G + 1) + i
		var w: PackedFloat32Array = wts[k]
		if rng.randf() > w[2] * 0.9 + 0.05 * (w[0] + w[1]) + w[3] * 0.04: continue
		if elev[k] <= 0.0: continue
		var p := _interp(off, i, j, fi - i, fj - j)
		var sz := 0.4 + pow(rng.randf(), 3.0) * 2.8
		var bs := Basis(Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized(), rng.randf() * TAU)
		bs = bs.scaled(Vector3(sz * rng.randf_range(0.8, 1.4), sz * rng.randf_range(0.5, 0.9), sz * rng.randf_range(0.8, 1.3)))
		var g := rng.randf_range(0.75, 1.15)
		_push(rbuf, bs, p - up * sz * 0.25, Color(g * 1.1, g, g * 0.82))
		nr += 1
	mutex.lock()
	result = {"ax": px, "ay": py, "az": pz, "ng": ng, "gbuf": gbuf, "nr": nr, "rbuf": rbuf}
	mutex.unlock()

func _interp(off: PackedVector3Array, i: int, j: int, fx: float, fy: float) -> Vector3:
	var k := j * (G + 1) + i
	var a := off[k].lerp(off[k + 1], fx); var b := off[k + G + 1].lerp(off[k + G + 2], fx)
	return a.lerp(b, fy)

func _push(buf: PackedFloat32Array, b: Basis, o: Vector3, c: Color) -> void:
	buf.append_array([b.x.x, b.y.x, b.z.x, o.x, b.x.y, b.y.y, b.z.y, o.y, b.x.z, b.y.z, b.z.z, o.z, c.r, c.g, c.b, 1.0])

## a clump of curved, tapering blades; UV.x runs 0 at the root to 1 at the tip
func _clump_mesh() -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for bl in 7:
		var ang := rng.randf() * TAU; var rad := rng.randf() * 0.22
		var base := Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
		var face := rng.randf() * TAU
		var side := Vector3(cos(face), 0.0, sin(face)); var lean := Vector3(-side.z, 0.0, side.x) * rng.randf_range(0.1, 0.35)
		var hgt := rng.randf_range(0.22, 0.5); var wid := rng.randf_range(0.035, 0.06)
		var segs := 2
		var prev_l := Vector3.ZERO; var prev_r := Vector3.ZERO
		for s in segs + 1:
			var t := float(s) / segs
			var c := base + Vector3(0.0, hgt * t, 0.0) + lean * hgt * t * t
			var w := wid * (1.0 - t * 0.92)
			var l := c - side * w; var r := c + side * w
			if s > 0:
				var n := (r - l).cross(Vector3.UP + lean).normalized()
				var t0 := float(s - 1) / segs
				for v in [[prev_l, t0], [l, t], [prev_r, t0], [prev_r, t0], [l, t], [r, t]]:
					st.set_normal(Vector3.UP * 0.6 + n * 0.4); st.set_uv(Vector2(v[1], 0.0)); st.add_vertex(v[0])
			prev_l = l; prev_r = r
	return st.commit()

## a lumpy boulder: a noise-displaced sphere, flattened underneath
func _rock_mesh() -> ArrayMesh:
	var sm := SphereMesh.new(); sm.radius = 0.5; sm.height = 1.0; sm.radial_segments = 20; sm.rings = 12
	var arr := sm.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n := FastNoiseLite.new(); n.seed = 3; n.frequency = 1.6
	for i in verts.size():
		var v := verts[i]
		var d := v.normalized()
		var r := 0.5 * (1.0 + n.get_noise_3dv(d * 1.3) * 0.35 + n.get_noise_3dv(d * 4.0) * 0.08)
		v = d * r
		if v.y < -0.12: v.y = -0.12 + (v.y + 0.12) * 0.3
		verts[i] = v
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = null; arr[Mesh.ARRAY_TANGENT] = null
	var st := SurfaceTool.new()
	var m := ArrayMesh.new(); m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	st.create_from(m, 0); st.generate_normals()
	return st.commit()

## grass amount for the graphics quality (1 = the full field); re-scatters the field
func set_density(k: float) -> void:
	var n := int(MAX_GRASS * k)
	if n != max_grass:
		max_grass = n; has_field = false

func _exit_tree() -> void:
	if task != -1:
		WorkerThreadPool.wait_for_task_completion(task); task = -1
