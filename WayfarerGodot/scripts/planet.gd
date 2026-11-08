## A planet: the Mac game's Earth (Worlds.swift), its height and colour rules ported, drawn as a cube-sphere quadtree
## of terrain chunks built on worker threads. Distances: heights in km (like the Mac code), positions in metres.
## Everything is placed camera-relative every frame (world positions held as doubles in GDScript floats), so the
## 32-bit renderer never sees planet-sized numbers.
class_name Planet
extends Node3D

const R_KM := 1000.0
const R := R_KM * 1000.0               # metres
const N := 24                          # quads per chunk side
const MAX_DEPTH := 15
const SPLIT_K := 2.6                   # split a chunk when the camera is closer than this × its size

var nA := FastNoiseLite.new(); var nB := FastNoiseLite.new(); var nC := FastNoiseLite.new()
var nD := FastNoiseLite.new(); var nE := FastNoiseLite.new()
var material: ShaderMaterial
var chunks := {}                       # key -> {node, cx, cy, cz (double centre, metres), size}
var pending := {}                      # key -> task id
var results: Array = []                # finished meshes waiting to be added (main thread)
var mutex := Mutex.new()
var sun_dir := Vector3(0.3, 0.6, -0.74).normalized()

# colours (linear)
const DEEP := Color(0.0012, 0.0080, 0.042); const SHALLOW := Color(0.0048, 0.078, 0.24)
const SAND := Color(0.54, 0.42, 0.22); const GRASS := Color(0.093, 0.16, 0.042); const FOREST := Color(0.023, 0.058, 0.019)
const DRY := Color(0.32, 0.23, 0.10); const ROCK := Color(0.15, 0.125, 0.10); const DARK := Color(0.045, 0.040, 0.034); const SNOW := Color(0.85, 0.89, 0.93)

func _init() -> void:
	var seeds := [11, 12, 13, 14, 15]
	var ns := [nA, nB, nC, nD, nE]
	for i in 5:
		ns[i].noise_type = FastNoiseLite.TYPE_SIMPLEX
		ns[i].frequency = 1.0
		ns[i].fractal_type = FastNoiseLite.FRACTAL_NONE
		ns[i].seed = seeds[i]
	material = ShaderMaterial.new()
	material.shader = preload("res://shaders/terrain.gdshader")
	material.set_shader_parameter("layer_albedo", preload("res://assets/terrain/ground_albedo.jpg"))
	material.set_shader_parameter("layer_pack", preload("res://assets/terrain/ground_pack.png"))

# ---------------------------------------------------------------- terrain functions (Worlds.swift: earth())
func fbm(n: FastNoiseLite, p: Vector3, f0: float, octs: int) -> float:
	var s := 0.0; var a := 1.0; var norm := 0.0; var f := f0
	for i in max(octs, 0):
		s += a * n.get_noise_3dv(p * f); norm += a; a *= 0.5; f *= 2.03
	return s / norm if norm > 0.0 else 0.0

func ridged(n: FastNoiseLite, p: Vector3, f0: float, octs: int) -> float:
	var s := 0.0; var a := 1.0; var norm := 0.0; var w := 1.0; var f := f0
	for i in max(octs, 0):
		var v := 1.0 - absf(n.get_noise_3dv(p * f)); v *= v * w; w = clampf(v * 1.6, 0.0, 1.0)
		s += a * v; norm += a; a *= 0.5; f *= 2.07
	return s / norm if norm > 0.0 else 0.0

## height above sea level in km at unit direction d
func height(d: Vector3, oct: int) -> float:
	var c := fbm(nA, d, 1.25, mini(4 + oct / 2, 11)) - 0.04
	if c < 0.0: return c * 40.0
	var land := smoothstep(0.0, 0.3, c)
	var r := ridged(nB, d, 3.1, oct)
	var hills := fbm(nC, d, 22.0, maxi(1, oct - 3))
	return c * 8.0 + land * r * r * 11.0 + hills * 1.1 * land + fbm(nD, d, 260.0, maxi(1, oct - 6)) * 0.22 * land

func color_at(d: Vector3, e: float, slope: float) -> Color:
	var lat := absf(d.y)
	var v := nD.get_noise_3dv(d * 30.0) * 0.75 + nD.get_noise_3dv(d * 160.0) * 0.25
	if e <= 0.0:
		return SNOW if lat > 0.93 + v * 0.02 else SHALLOW.lerp(DEEP, smoothstep(0.0, -14.0, e))
	var o: Color
	if lat > 0.9 + v * 0.03 or e > 12.5 - lat * 10.0 + v * 1.5: o = SNOW
	elif e < 0.22 and slope < 0.12: o = SAND
	else:
		o = FOREST.lerp(GRASS, smoothstep(-0.4, 0.5, v + e * 0.04))
		var dr := smoothstep(0.05, 0.45, nE.get_noise_3dv(d * 2.3) * 0.6 + 0.3 - absf(lat - 0.32) * 1.4)
		o = o.lerp(DRY, dr)
		o = o.lerp(ROCK, smoothstep(6.5, 10.5, e))
		o = o.lerp(ROCK.lerp(DARK, smoothstep(-0.4, 0.6, v)), smoothstep(0.14, 0.34, slope))   # cliffs fade in with steepness
	var g := 1.0 + nE.get_noise_3dv(d * 420.0) * 0.12
	return Color(o.r * g, o.g * g, o.b * g)

## how much of each photo ground layer a point gets (Worlds.swift earth materialFn): grass, forest floor, rock, sand, snow
func layer_weights(d: Vector3, e: float, slope: float) -> PackedFloat32Array:
	var w := PackedFloat32Array([0, 0, 0, 0, 0])
	if e <= 0.0: return w
	var lat := absf(d.y)
	var v := nD.get_noise_3dv(d * 30.0) * 0.75 + nD.get_noise_3dv(d * 160.0) * 0.25
	var snow := maxf(smoothstep(0.0, 0.03, lat - 0.9 - v * 0.03), smoothstep(-0.3, 0.6, e - (12.5 - lat * 10.0 + v * 1.5)))
	var rock := minf(1.0, smoothstep(0.17, 0.3, slope) + smoothstep(6.5, 10.5, e))
	var dry := smoothstep(0.05, 0.45, nE.get_noise_3dv(d * 2.3) * 0.6 + 0.3 - absf(lat - 0.32) * 1.4)
	var beach := smoothstep(0.3, 0.12, e) * smoothstep(0.16, 0.08, slope)
	var forest := 1.0 - smoothstep(-0.4, 0.5, v + e * 0.04)
	var g := (1.0 - forest) * (1.0 - dry * 0.6); var f := forest * (1.0 - dry * 0.6); var sd := dry * 0.6
	var veg := (1.0 - beach) * (1.0 - rock) * (1.0 - snow)
	w[0] = g * veg; w[1] = f * veg; w[2] = rock * (1.0 - snow); w[3] = sd * veg + beach * (1.0 - snow); w[4] = snow
	return w

## radius of the visible surface (metres) — the sea clamps flat
func ground_radius(d: Vector3) -> float:
	return R + maxf(height(d.normalized(), 14), 0.0) * 1000.0

# ---------------------------------------------------------------- cube-sphere quadtree
static func face_dir(face: int, u: float, v: float) -> Vector3:
	var p: Vector3
	match face:
		0: p = Vector3(1, v, -u)
		1: p = Vector3(-1, v, u)
		2: p = Vector3(u, 1, -v)
		3: p = Vector3(u, -1, v)
		4: p = Vector3(u, v, 1)
		_: p = Vector3(-u, v, -1)
	# spread the grid evenly over the sphere
	var x := p.x; var y := p.y; var z := p.z
	return Vector3(x * sqrt(1.0 - y * y / 2.0 - z * z / 2.0 + y * y * z * z / 3.0),
				   y * sqrt(1.0 - z * z / 2.0 - x * x / 2.0 + z * z * x * x / 3.0),
				   z * sqrt(1.0 - x * x / 2.0 - y * y / 2.0 + x * x * y * y / 3.0)).normalized()

## build one chunk's mesh (runs on a worker thread)
func build_chunk(key: String, face: int, u0: float, v0: float, size: float, depth: int) -> void:
	var oct := 5 + depth
	var M := N + 3                       # one extra ring each side for normals
	var cdir := face_dir(face, u0 + size * 0.5, v0 + size * 0.5)
	var ce := maxf(height(cdir, oct), 0.0)
	var center := cdir * (R + ce * 1000.0)       # double precision in GDScript
	var pos := PackedVector3Array(); pos.resize(M * M)
	var elev := PackedFloat32Array(); elev.resize(M * M)
	var dirs := PackedVector3Array(); dirs.resize(M * M)
	for j in M:
		for i in M:
			var u := u0 + size * (float(i - 1) / N); var v := v0 + size * (float(j - 1) / N)
			var d := face_dir(face, u, v)
			var e := height(d, oct)
			var r := R + maxf(e, 0.0) * 1000.0
			var k := j * M + i
			pos[k] = Vector3(d.x * r - center.x, d.y * r - center.y, d.z * r - center.z)
			elev[k] = e; dirs[k] = d
	var verts := PackedVector3Array(); var norms := PackedVector3Array(); var cols := PackedColorArray(); var idx := PackedInt32Array()
	var lw := PackedFloat32Array()      # layer weights: grass, forest, rock, sand (snow rides in the colour's alpha)
	var W := N + 1
	for j in W:
		for i in W:
			var k := (j + 1) * M + (i + 1)
			var nrm := (pos[k + 1] - pos[k - 1]).cross(pos[k + M] - pos[k - M]).normalized()
			var d := dirs[k]
			if nrm.dot(d) < 0.0: nrm = -nrm
			var slope := 1.0 - nrm.dot(d)
			var w := layer_weights(d, elev[k], slope)
			var col := color_at(d, elev[k], slope * 4.0); col.a = w[4]
			verts.append(pos[k]); norms.append(nrm); cols.append(col)
			lw.append_array([w[0], w[1], w[2], w[3]])
	for j in N:
		for i in N:
			var a := j * W + i
			idx.append_array([a, a + W, a + 1, a + 1, a + W, a + W + 1])
	# skirts hide cracks between chunks of different detail
	var skirt := size * R * 0.02
	var edge := []
	for i in W: edge.append(i)
	for j in W: edge.append(j * W + N)
	for i in range(N, -1, -1): edge.append(N * W + i)
	for j in range(N, -1, -1): edge.append(j * W)
	var base := verts.size()
	for e in edge:
		var p: Vector3 = verts[e]
		var d: Vector3 = (p + Vector3(center.x, center.y, center.z)).normalized()
		verts.append(p - d * skirt); norms.append(norms[e]); cols.append(cols[e])
		lw.append_array([lw[e * 4], lw[e * 4 + 1], lw[e * 4 + 2], lw[e * 4 + 3]])
	for s in edge.size() - 1:
		var a: int = edge[s]; var b: int = edge[s + 1]; var c := base + s; var dd := base + s + 1
		idx.append_array([a, c, b, b, c, dd])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_NORMAL] = norms; arrays[Mesh.ARRAY_COLOR] = cols; arrays[Mesh.ARRAY_INDEX] = idx
	arrays[Mesh.ARRAY_CUSTOM0] = lw
	mutex.lock()
	results.append({"key": key, "arrays": arrays, "c": center})
	mutex.unlock()

func _key(face: int, u0: float, v0: float, depth: int) -> String:
	return "%d_%d_%.6f_%.6f" % [face, depth, u0, v0]

## walk the quadtree from the camera's position (double, metres from the planet centre) and request/keep chunks
func update_lod(cam: Vector3, cam_alt: float) -> void:
	var wanted := {}
	for face in 6:
		_visit(face, -1.0, -1.0, 2.0, 0, cam, wanted)
	# start building what's missing (a few per frame)
	var started := 0
	for key in wanted:
		if chunks.has(key) or pending.has(key): continue
		if started >= 6: break
		var w: Array = wanted[key]
		pending[key] = WorkerThreadPool.add_task(build_chunk.bind(key, w[0], w[1], w[2], w[3], w[4]))
		started += 1
	# finished chunks become visible
	mutex.lock()
	var done := results.duplicate(); results.clear()
	mutex.unlock()
	for r in done:
		var key: String = r["key"]
		if pending.has(key):
			WorkerThreadPool.wait_for_task_completion(pending[key]); pending.erase(key)
		if not wanted.has(key): continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, r["arrays"], [], {}, Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		var mi := MeshInstance3D.new(); mi.mesh = mesh; mi.material_override = material
		mi.extra_cull_margin = 16384.0
		var c: Vector3 = r["c"]
		mi.set_instance_shader_parameter("origin_mod", Vector3(fmod(c.x, 1000.0), fmod(c.y, 1000.0), fmod(c.z, 1000.0)))
		add_child(mi)
		chunks[key] = {"node": mi, "c": r["c"]}
	# retire chunks no longer wanted, but only once every wanted one is ready (no holes while refining)
	var all_ready := true
	for key in wanted:
		if not chunks.has(key): all_ready = false; break
	if all_ready:
		for key in chunks.keys():
			if not wanted.has(key):
				chunks[key]["node"].queue_free(); chunks.erase(key)

func _visit(face: int, u0: float, v0: float, size: float, depth: int, cam: Vector3, wanted: Dictionary) -> void:
	var cdir := face_dir(face, u0 + size * 0.5, v0 + size * 0.5)
	var c := cdir * R
	var edge_m := size * R * 0.8
	# horizon cull: skip chunks well over the horizon
	var dist := cam.distance_to(c)
	if depth > 2 and cdir.dot(cam.normalized()) < -0.2 and dist > edge_m * 3.0: return
	if depth < MAX_DEPTH and dist < edge_m * SPLIT_K:
		var h := size * 0.5
		_visit(face, u0, v0, h, depth + 1, cam, wanted)
		_visit(face, u0 + h, v0, h, depth + 1, cam, wanted)
		_visit(face, u0, v0 + h, h, depth + 1, cam, wanted)
		_visit(face, u0 + h, v0 + h, h, depth + 1, cam, wanted)
	else:
		wanted[_key(face, u0, v0, depth)] = [face, u0, v0, size, depth]

## place every chunk relative to the camera; the camera position comes in as three doubles (GDScript floats)
## because a Vector3 is only 32-bit and would make the world shake in 6 cm steps this far from the centre
func place(cx: float, cy: float, cz: float) -> void:
	for key in chunks:
		var ch: Dictionary = chunks[key]
		var c: Vector3 = ch["c"]
		ch["node"].position = Vector3(c.x - cx, c.y - cy, c.z - cz)

func _exit_tree() -> void:
	for key in pending:
		WorkerThreadPool.wait_for_task_completion(pending[key])
	pending.clear()
