## A planet: the Mac game's Earth (Worlds.swift), its height and colour rules ported, drawn as a cube-sphere quadtree
## of terrain chunks built on worker threads. Distances: heights in km (like the Mac code), positions in metres.
## Everything is placed camera-relative every frame (world positions held as doubles in GDScript floats), so the
## 32-bit renderer never sees planet-sized numbers.
class_name Planet
extends Node3D

var R_KM := 1000.0
var R := 1000000.0                     # metres
var kind := "earth"
var world_name := "Earth"
var sea := true
var gravity := 1.0
var wx := 0.0; var wy := 0.0; var wz := 0.0   # centre (metres, double) in the solar system
var atmo_top := 110000.0               # metres
var sky_zenith := Color(0.035, 0.11, 0.36); var sky_horizon := Color(0.45, 0.62, 0.86)
var halo_color := Color(0.25, 0.5, 1.0)
var fog_color := Color(0.5, 0.66, 0.92)
var fog_k := 1.0
var rayleigh := Vector3(5.8e-3, 13.5e-3, 33.1e-3) * 1.5   # per km at sea level (Worlds.swift)
var rayleigh_h := 11.0; var mie := 4.0e-3; var mie_h := 1.4
var craters: Array = []                # Ruber: [unit dir, radius (unit), depth km]
const N := 24                          # quads per chunk side
const MAX_DEPTH := 15
const SPLIT_K := 2.6                   # split a chunk when the camera is closer than this × its size

var nA := FastNoiseLite.new(); var nB := FastNoiseLite.new(); var nC := FastNoiseLite.new()
var nD := FastNoiseLite.new(); var nE := FastNoiseLite.new()
var material: ShaderMaterial
var chunks := {}                       # key -> {node, c}
var pending := {}                      # key -> task id
var results: Array = []                # finished meshes waiting to be added (main thread)
var mutex := Mutex.new()
var sun_dir := Vector3(0.3, 0.6, -0.74).normalized()

static func lin(hex: int) -> Color:
	return Color.hex(hex << 8 | 0xff).srgb_to_linear()

# colours (linear) for each world (Worlds.swift)
const DEEP := Color(0.0012, 0.0080, 0.042); const SHALLOW := Color(0.0048, 0.078, 0.24)
const SAND := Color(0.54, 0.42, 0.22); const GRASS := Color(0.093, 0.16, 0.042); const FOREST := Color(0.023, 0.058, 0.019)
const DRY := Color(0.32, 0.23, 0.10); const ROCK := Color(0.15, 0.125, 0.10); const DARK := Color(0.045, 0.040, 0.034); const SNOW := Color(0.85, 0.89, 0.93)
var C := {}

## kind: "earth", "ruber" or "verdance"
func _init(k := "earth") -> void:
	kind = k
	var seeds := [11, 12, 13, 14, 15]
	match kind:
		"ruber":
			world_name = "Ruber"; R_KM = 530.0; sea = false; gravity = 0.38; seeds = [31, 32, 33, 34, 35]
			wx = -600000e3; wy = 60000e3; wz = 360000e3; atmo_top = 70000.0; fog_k = 0.45
			cloud_color = Color(0.88, 0.62, 0.44); cloud_cover = 0.5
			rayleigh = Vector3(19.9e-3, 13.6e-3, 5.8e-3) * 0.85; rayleigh_h = 12.0; mie = 12e-3; mie_h = 2.4
			sky_zenith = Color(0.16, 0.08, 0.05); sky_horizon = Color(0.72, 0.44, 0.28); halo_color = Color(1.0, 0.55, 0.3); fog_color = Color(0.55, 0.36, 0.25)
			C = {"low": lin(0x6e2e18), "mid": lin(0xb0532a), "high": lin(0xd8925a), "dust": lin(0xe0a674), "dark": lin(0x3d1f15), "ice": lin(0xf4ece6)}
			var rng := RandomNumberGenerator.new(); rng.seed = 34
			for i in 160:
				var z := rng.randf() * 2.0 - 1.0; var a := rng.randf() * TAU; var sq := sqrt(1.0 - z * z)
				var r := minf(0.22, 0.006 / pow(rng.randf() * 0.97 + 0.03, 0.75))
				craters.append([Vector3(cos(a) * sq, z, sin(a) * sq), r, r * R_KM * (0.08 + rng.randf() * 0.06)])
		"verdance":
			world_name = "Verdance"; R_KM = 850.0; sea = true; gravity = 0.9; seeds = [41, 42, 43, 44, 45]
			wx = 560000e3; wy = -80000e3; wz = 480000e3; atmo_top = 100000.0; fog_k = 0.7
			cloud_color = Color(1.0, 0.86, 0.94); cloud_cover = 0.46
			rayleigh = Vector3(6.0e-3, 26.0e-3, 22.0e-3) * 1.5; mie = 5e-3; mie_h = 1.6
			sky_zenith = Color(0.025, 0.14, 0.2); sky_horizon = Color(0.36, 0.7, 0.68); halo_color = Color(0.3, 1.0, 0.85); fog_color = Color(0.3, 0.55, 0.55)
			C = {"deep": lin(0x170a3c), "shallow": lin(0x4a2a8c), "sand": lin(0xe6c8e4), "moss": lin(0x1e9a86), "bloom": lin(0x3fd6a2),
				"violet": lin(0x6b3fa0), "rock": lin(0x3a3450), "snow": lin(0xe6f6ff)}
	R = R_KM * 1000.0
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
	material.set_shader_parameter("sun_dir", sun_dir)
	material.set_shader_parameter("tint_k", {"earth": 0.65, "ruber": 0.7, "verdance": 0.7}[kind])

# ---------------------------------------------------------------- terrain functions (Worlds.swift)
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

func crater_h(d: Vector3, list: Array) -> float:
	var h := 0.0
	for c in list:
		var cd: Vector3 = c[0]; var cr: float = c[1]
		var d2 := d.distance_squared_to(cd); var lim := cr * 1.6
		if d2 > lim * lim: continue
		var dd := sqrt(d2) / cr; var q := (dd - 1.0) / 0.22
		h += ((dd * dd - 1.0 if dd < 1.0 else 0.0) + exp(-(q * q)) * 0.3) * float(c[2])
	return h

## height above sea level in km at unit direction d (list: craters to test, defaults to all)
func height(d: Vector3, oct: int, list = null) -> float:
	match kind:
		"ruber":
			var base := fbm(nA, d, 1.6, oct) * 7.0
			var region := smoothstep(-0.05, 0.35, nA.get_noise_3dv(d * 1.1 + Vector3(7, 0, 0)))
			var canyon := pow(1.0 - absf(nB.get_noise_3dv(d * 2.4)), 9.0) * -13.0 * region
			return base + canyon + ridged(nC, d, 6.0, oct) * 6.0 + crater_h(d, craters if list == null else list)
		"verdance":
			var c := fbm(nA, d, 1.6, mini(4 + oct / 2, 11)) - 0.02
			if c < 0.0: return c * 35.0
			var land := smoothstep(0.0, 0.25, c); var r := ridged(nB, d, 4.2, oct)
			return c * 8.0 + land * pow(r, 3.0) * 24.0 + fbm(nC, d, 26.0, maxi(1, oct - 3)) * 0.6 * land
	var c := fbm(nA, d, 1.25, mini(4 + oct / 2, 11)) - 0.04
	if c < 0.0: return c * 40.0
	var land := smoothstep(0.0, 0.3, c)
	var r := ridged(nB, d, 3.1, oct)
	var hills := fbm(nC, d, 22.0, maxi(1, oct - 3))
	return c * 8.0 + land * r * r * 11.0 + hills * 1.1 * land + fbm(nD, d, 260.0, maxi(1, oct - 6)) * 0.22 * land

func color_at(d: Vector3, e: float, slope: float) -> Color:
	match kind:
		"ruber":
			var lat := absf(d.y); var v := fbm(nC, d, 4.0, 4)
			if lat > 0.88 + v * 0.04: return C.ice
			var o: Color = (C.low as Color).lerp(C.mid, smoothstep(-6.0, 2.0, e)); o = o.lerp(C.high, smoothstep(3.0, 9.0, e))
			o = o.lerp(C.dust, smoothstep(-0.1, 0.5, v) * 0.45)
			var sb := sin(e * 2.6 + nA.get_noise_3dv(d * 4.0) * 1.5)
			o = o.lerp(C.high if sb > 0.0 else C.dark, absf(sb) * 0.45 * smoothstep(0.06, 0.22, slope / 4.0))
			return o.lerp(C.dark, smoothstep(0.25, 0.45, slope / 4.0) * 0.5)
		"verdance":
			var v := fbm(nD, d, 6.0, 4)
			if e <= 0.0: return (C.shallow as Color).lerp(C.deep, smoothstep(0.0, -12.0, e))
			var o: Color = (C.moss as Color).lerp(C.bloom, smoothstep(-0.4, 0.6, v))
			o = o.lerp(C.violet, smoothstep(0.15, 0.55, fbm(nA, d, 2.5, 3)) * 0.8)
			o = o.lerp(C.rock, smoothstep(9.0, 14.0, e))
			o = o.lerp(C.rock, smoothstep(0.2, 0.32, slope / 4.0))
			o = o.lerp(C.sand, smoothstep(0.25, 0.1, e) * smoothstep(0.16, 0.08, slope / 4.0))
			return o.lerp(C.snow, smoothstep(-0.5, 0.5, e - 15.0 - v * 2.0))
	var lat := absf(d.y)
	var v := nD.get_noise_3dv(d * 30.0) * 0.75 + nD.get_noise_3dv(d * 160.0) * 0.25
	if e <= 0.0:
		return SNOW if lat > 0.93 + v * 0.02 else SHALLOW.lerp(DEEP, smoothstep(0.0, -14.0, e))
	var o := FOREST.lerp(GRASS, smoothstep(-0.4, 0.5, v + e * 0.04))
	var dr := smoothstep(0.05, 0.45, nE.get_noise_3dv(d * 2.3) * 0.6 + 0.3 - absf(lat - 0.32) * 1.4)
	o = o.lerp(DRY, dr)
	o = o.lerp(ROCK, smoothstep(6.5, 10.5, e))
	o = o.lerp(ROCK.lerp(DARK, smoothstep(-0.4, 0.6, v)), smoothstep(0.14, 0.34, slope))   # cliffs fade in with steepness
	o = o.lerp(SAND, smoothstep(0.3, 0.12, e) * smoothstep(0.16, 0.08, slope))              # beaches (soft edged, no stair steps)
	var snow := maxf(smoothstep(0.0, 0.03, lat - 0.9 - v * 0.03), smoothstep(-0.3, 0.6, e - (12.5 - lat * 10.0 + v * 1.5)))
	o = o.lerp(SNOW, snow)
	var g := 1.0 + nE.get_noise_3dv(d * 420.0) * 0.12
	return Color(o.r * g, o.g * g, o.b * g)

## how much of each photo ground layer a point gets: grass, forest floor, rock, sand, snow, red rock
func layer_weights(d: Vector3, e: float, slope: float) -> PackedFloat32Array:
	var w := PackedFloat32Array([0, 0, 0, 0, 0, 0])
	match kind:
		"ruber":
			var lat := absf(d.y); var v := fbm(nC, d, 4.0, 4)
			var ice := smoothstep(0.0, 0.04, lat - 0.88 - v * 0.04)
			var cliff := smoothstep(0.08, 0.3, slope)
			var dust := smoothstep(-0.1, 0.5, v) * (1.0 - cliff)
			w[2] = cliff * 0.3 * (1.0 - ice); w[3] = dust * (1.0 - ice); w[4] = ice; w[5] = (1.0 - dust) * (1.0 - ice)
			return w
		"verdance":
			if e <= 0.0: return w
			var v := fbm(nD, d, 6.0, 4)
			var snow := smoothstep(-0.5, 0.5, e - 15.0 - v * 2.0)
			var beach := smoothstep(0.32, 0.15, e) * smoothstep(0.16, 0.08, slope)
			var rock := minf(1.0, smoothstep(0.2, 0.32, slope) + smoothstep(9.0, 14.0, e))
			var moss := (1.0 - snow) * (1.0 - beach) * (1.0 - rock)
			w[0] = moss * 0.6; w[1] = moss * 0.4; w[2] = rock * (1.0 - snow); w[3] = beach * (1.0 - snow); w[4] = snow
			return w
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

## the surface radius in metres (the sea clamps flat on worlds with oceans)
func ground_radius(d: Vector3) -> float:
	var e := height(d.normalized(), 14)
	return R + (maxf(e, 0.0) if sea else e) * 1000.0

## is this direction over open water?
func is_water(d: Vector3) -> bool:
	return sea and height(d.normalized(), 12) < 0.0

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
	var sub = null
	if not craters.is_empty():
		sub = []
		for c in craters:
			if (c[0] as Vector3).distance_to(cdir) < size * 0.9 + float(c[1]) * 1.6: sub.append(c)
	var ce0 := height(cdir, oct, sub)
	var ce := maxf(ce0, 0.0) if sea else ce0
	var center := cdir * (R + ce * 1000.0)       # double precision in GDScript
	var pos := PackedVector3Array(); pos.resize(M * M)
	var elev := PackedFloat32Array(); elev.resize(M * M)
	var dirs := PackedVector3Array(); dirs.resize(M * M)
	for j in M:
		for i in M:
			var u := u0 + size * (float(i - 1) / N); var v := v0 + size * (float(j - 1) / N)
			var d := face_dir(face, u, v)
			var e := height(d, oct, sub)
			var r := R + (maxf(e, 0.0) if sea else e) * 1000.0
			var k := j * M + i
			pos[k] = Vector3(d.x * r - center.x, d.y * r - center.y, d.z * r - center.z)
			elev[k] = e; dirs[k] = d
	var verts := PackedVector3Array(); var norms := PackedVector3Array(); var cols := PackedColorArray(); var idx := PackedInt32Array()
	var ev := PackedVector2Array()      # elevation (km) in UV.x: the shader draws the coastline per pixel
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
			verts.append(pos[k]); norms.append(nrm); cols.append(col); ev.append(Vector2(elev[k] if sea else 1.0, w[5]))
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
		verts.append(p - d * skirt); norms.append(norms[e]); cols.append(cols[e]); ev.append(ev[e])
		lw.append_array([lw[e * 4], lw[e * 4 + 1], lw[e * 4 + 2], lw[e * 4 + 3]])
	for s in edge.size() - 1:
		var a: int = edge[s]; var b: int = edge[s + 1]; var c := base + s; var dd := base + s + 1
		idx.append_array([a, c, b, b, c, dd])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts; arrays[Mesh.ARRAY_NORMAL] = norms; arrays[Mesh.ARRAY_COLOR] = cols; arrays[Mesh.ARRAY_INDEX] = idx
	arrays[Mesh.ARRAY_CUSTOM0] = lw
	arrays[Mesh.ARRAY_TEX_UV] = ev
	mutex.lock()
	results.append({"key": key, "arrays": arrays, "c": center, "depth": depth})
	mutex.unlock()

func _key(face: int, u0: float, v0: float, depth: int) -> String:
	return "%d_%d_%.6f_%.6f" % [face, depth, u0, v0]

## walk the quadtree from the camera's position (double, metres from the planet centre) and request/keep chunks
var wanted := {}
var _last_cam := Vector3(1e20, 0, 0)
var _horizon := 0.0
func update_lod(cam: Vector3, cam_alt: float) -> void:
	# re-walk the quadtree only when the camera has moved enough to matter (a small fraction of its height)
	if cam.distance_to(_last_cam) > maxf(1.0, absf(cam_alt) * 0.02):
		_last_cam = cam
		# nothing beyond the horizon (plus the tallest mountains peeking over it) needs drawing
		var h := maxf(cam.length() - R, 10.0)
		_horizon = sqrt(2.0 * R * h + h * h) + sqrt(2.0 * R * 22000.0)
		wanted = {}
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
		# only the fine chunks near you cast shadows: far hills in four shadow cascades cost a lot and show nothing
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if int(r["depth"]) >= 11 else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	if depth > 1 and dist - edge_m * 1.5 > _horizon: return
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
	position = Vector3.ZERO; scale = Vector3.ONE
	for key in chunks:
		var ch: Dictionary = chunks[key]
		var c: Vector3 = ch["c"]
		ch["node"].position = Vector3(c.x - cx, c.y - cy, c.z - cz)
	if halo: halo.position = Vector3(-cx, -cy, -cz)
	if clouds:
		clouds.position = Vector3(-cx, -cy, -cz)
		var ca := sqrt(cx * cx + cy * cy + cz * cz) - R - cloud_alt
		cloud_mat.set_shader_parameter("fade", smoothstep(150.0, 1500.0, absf(ca)))

## a world far away: drawn shrunk and pulled in (same angular size), so it sits inside the camera's range.
## (rx, ry, rz): its centre relative to the camera, metres (double)
func place_far(rx: float, ry: float, rz: float) -> void:
	var dist := sqrt(rx * rx + ry * ry + rz * rz)
	var k := minf(1.0, 3.0e6 / dist)
	position = Vector3(rx * k, ry * k, rz * k); scale = Vector3(k, k, k)
	for key in chunks:
		var ch: Dictionary = chunks[key]
		ch["node"].position = ch["c"]
	if halo: halo.position = Vector3.ZERO
	if clouds: clouds.position = Vector3.ZERO; cloud_mat.set_shader_parameter("fade", 1.0)

var halo: MeshInstance3D
var halo_mat: ShaderMaterial
var clouds: MeshInstance3D
var cloud_mat: ShaderMaterial
var cloud_alt := 6000.0
var cloud_cover := 0.42
var cloud_color := Color(1, 1, 1)
## the atmosphere's glow seen from space
func make_halo() -> void:
	halo = MeshInstance3D.new()
	var sm := SphereMesh.new(); sm.radius = R + atmo_top * 0.9; sm.height = sm.radius * 2.0; sm.radial_segments = 128; sm.rings = 64
	halo.mesh = sm
	halo_mat = ShaderMaterial.new(); halo_mat.shader = preload("res://shaders/halo.gdshader")
	halo_mat.set_shader_parameter("sun_dir", sun_dir)
	halo_mat.set_shader_parameter("tint", Vector3(halo_color.r, halo_color.g, halo_color.b))
	halo.material_override = halo_mat
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.extra_cull_margin = 16384.0
	add_child(halo)
	# the cloud layer
	clouds = MeshInstance3D.new()
	var cm := SphereMesh.new(); cm.radius = R + cloud_alt; cm.height = cm.radius * 2.0; cm.radial_segments = 256; cm.rings = 128
	clouds.mesh = cm
	cloud_mat = ShaderMaterial.new(); cloud_mat.shader = preload("res://shaders/clouds.gdshader")
	cloud_mat.set_shader_parameter("sun_dir", sun_dir)
	cloud_mat.set_shader_parameter("color", Vector3(cloud_color.r, cloud_color.g, cloud_color.b))
	cloud_mat.set_shader_parameter("cover", cloud_cover)
	clouds.material_override = cloud_mat
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clouds.extra_cull_margin = 16384.0
	add_child(clouds)

func _exit_tree() -> void:
	for key in pending:
		WorkerThreadPool.wait_for_task_completion(pending[key])
	pending.clear()

## the colour of sunlight after passing through this world's air (Renderer.swift sunTransmitCPU):
## cos_z: the sun's height (dot of up and sun direction), alt: the viewer's height above sea level (m)
func sun_transmit(cos_z: float, alt: float) -> Color:
	var c := clampf(cos_z, -0.2, 1.0)
	var zen := rad_to_deg(acos(c))
	var m := minf(1.0 / maxf(c + 0.50572 * pow(maxf(96.07995 - zen, 0.1), -1.6364), 0.02), 40.0)
	var tau := (rayleigh * rayleigh_h + Vector3.ONE * mie * 1.1 * mie_h) * m
	var inside := 1.0 - clampf(alt / atmo_top, 0.0, 1.0)
	var t := Vector3(exp(-tau.x), exp(-tau.y), exp(-tau.z))
	var r := (Vector3.ONE + (t - Vector3.ONE) * inside) * (smoothstep(-0.12, 0.04, cos_z) * inside + (1.0 - inside))
	return Color(r.x, r.y, r.z)
