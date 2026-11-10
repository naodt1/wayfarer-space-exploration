## One ship as seen in the world: the baked hull, glowing nozzles, exhaust plumes, an engine light, nav lights and
## landing legs. Built from a Ships.roster() entry; the game drives it each frame with set_state().
class_name Ship
extends Node3D

var spec: Dictionary
var s := 1.0                          # metres per model unit
var size_m := 50.0
var gear_m := 9.0                     # origin to the ground when landed (m)
var hull: MeshInstance3D
var mat: ShaderMaterial
var plumes: Array[Node3D] = []
var plume_len: Array[float] = []
var plume_mat: ShaderMaterial
var engine_light: OmniLight3D
var legs: Array[Node3D] = []
var glows: Array[MeshInstance3D] = []

static var _mesh_cache := {}
var interior: AtlasInterior

func _init(sp: Dictionary) -> void:
	spec = sp
	size_m = sp["size_m"]
	s = size_m / float(sp["length_u"])
	gear_m = float(sp["gear_u"]) * s
	var file: String = sp["file"]
	# the hull (meshes are cached: swapping ships back and forth doesn't reload them)
	if not _mesh_cache.has(file):
		_mesh_cache[file] = BakedModel.load_mesh("res://assets/ships/%s.bin" % file, s)
	hull = MeshInstance3D.new()
	hull.mesh = _mesh_cache[file]
	mat = BakedModel.material(load("res://assets/ships/%s_albedo.png" % file), load("res://assets/ships/%s_normal.png" % file))
	if ResourceLoader.exists("res://assets/ships/%s_emit.png" % file):
		mat.set_shader_parameter("emit_tex", load("res://assets/ships/%s_emit.png" % file))
		mat.set_shader_parameter("emit_k", 1.6)
	var fl: Dictionary = sp["flame"]
	var glow: Color = fl["glow"]
	mat.set_shader_parameter("flame_glow", Vector3(glow.r, glow.g, glow.b))
	var nz := PackedVector4Array()
	for e in sp["engines"]:
		nz.append(Vector4(e[0] * s, e[1] * s, e[3] * s, (e[2] - float(sp["nozzle_depth"])) * s))
	mat.set_shader_parameter("nozzles", nz)
	mat.set_shader_parameter("nozzle_count", mini(nz.size(), 8))
	if size_m > 500.0: mat.set_shader_parameter("plating", 9.0)
	hull.material_override = mat
	add_child(hull)
	if file == "cruiser":
		interior = AtlasInterior.new(); interior.visible = false; add_child(interior)
		set_aboard(false)
	# exhaust plumes, one per engine, pointing aft (+z)
	plume_mat = ShaderMaterial.new(); plume_mat.shader = preload("res://shaders/plume.gdshader")
	var ec: Color = fl["edge"]; var cc: Color = fl["core"]
	plume_mat.set_shader_parameter("edge_col", Vector3(ec.r, ec.g, ec.b))
	plume_mat.set_shader_parameter("core_col", Vector3(cc.r, cc.g, cc.b))
	var cone := _cone_mesh()
	for e in sp["engines"]:
		var r: float = e[3] * s
		var p := Node3D.new(); p.position = Vector3(e[0] * s, e[1] * s, e[2] * s)
		var mi := MeshInstance3D.new(); mi.mesh = cone; mi.material_override = plume_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.scale = Vector3(r, r, r)
		p.add_child(mi); add_child(p)
		plumes.append(p); plume_len.append(r)
	# the engines light up the ground and hull behind the ship
	engine_light = OmniLight3D.new()
	engine_light.light_color = glow.lerp(cc, 0.5).clamp()
	engine_light.omni_range = size_m * 0.9
	engine_light.shadow_enabled = false
	var stern := Vector3.ZERO
	for e in sp["engines"]: stern += Vector3(e[0], e[1], e[2]) * s
	stern /= float(sp["engines"].size())
	engine_light.position = stern + Vector3(0, 0, size_m * 0.15)
	add_child(engine_light)
	# nav lights (red port, green starboard, steady) and white strobes
	var quad := QuadMesh.new(); quad.size = Vector2(1, 1)
	var i := 0
	for group in [["nav", 0.0], ["steady", 1.25]]:
		for l in sp[group[0]]:
			var gm := ShaderMaterial.new(); gm.shader = preload("res://shaders/glow.gdshader")
			var c: Color = l[4]
			gm.set_shader_parameter("color", Vector3(c.r, c.g, c.b))
			gm.set_shader_parameter("strobe", group[1] if c.r > 0.9 and c.g > 0.9 else 0.0)
			var g := MeshInstance3D.new(); g.mesh = quad; g.material_override = gm
			g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			var sz: float = l[3] * s * 1.6
			g.scale = Vector3(sz, sz, sz)
			g.position = Vector3(l[0] * s, l[1] * s, l[2] * s)
			g.set_instance_shader_parameter("phase", i * 0.37)
			add_child(g); glows.append(g); i += 1
	# landing legs: a strut and a foot pad hanging from each pivot; they fold up in flight
	if sp["legs"].size() > 0:
		var dark := StandardMaterial3D.new(); dark.albedo_color = Color(0.05, 0.055, 0.065); dark.metallic = 0.7; dark.roughness = 0.4
		var metal := StandardMaterial3D.new(); metal.albedo_color = Color(0.45, 0.47, 0.5); metal.metallic = 1.0; metal.roughness = 0.3
		var L: float = float(sp["leg_len"]) * s; var R: float = float(sp["leg_r"]) * s; var P: float = float(sp["pad_r"]) * s
		var top: float = float(sp["legs"][0][1]) * s
		var reach := -gear_m - top                 # from the pivot down to the ground
		for lp in sp["legs"]:
			var leg := Node3D.new(); leg.position = Vector3(lp[0] * s, lp[1] * s, lp[2] * s)
			var strut := MeshInstance3D.new(); var cm := CylinderMesh.new()
			cm.top_radius = R; cm.bottom_radius = R * 1.2; cm.height = -reach; cm.radial_segments = 12
			strut.mesh = cm; strut.material_override = dark; strut.position = Vector3(0, reach * 0.5, 0)
			var piston := MeshInstance3D.new(); var pm := CylinderMesh.new()
			pm.top_radius = R * 0.5; pm.bottom_radius = R * 0.5; pm.height = -reach * 0.7; pm.radial_segments = 8
			piston.mesh = pm; piston.material_override = metal; piston.position = Vector3(R * 1.7, reach * 0.35, 0)
			var pad := MeshInstance3D.new(); var padm := CylinderMesh.new()
			padm.top_radius = P; padm.bottom_radius = P * 1.15; padm.height = maxf(L * 0.06, 0.15); padm.radial_segments = 16
			pad.mesh = padm; pad.material_override = dark; pad.position = Vector3(0, reach + padm.height * 0.5, 0)
			leg.add_child(strut); leg.add_child(piston); leg.add_child(pad)
			add_child(leg); legs.append(leg)

## power: 0 parked … 1 full; thrust drives the plumes (0..1), ab the afterburner, gear 0 folded … 1 down
func set_state(power: float, thrust: float, ab: float, gear: float) -> void:
	mat.set_shader_parameter("power", power)
	var k := thrust * (1.0 + ab * 1.6)
	plume_mat.set_shader_parameter("intensity", (0.25 + 0.75 * thrust) * (1.0 + ab * 0.8) if thrust > 0.01 else 0.0)
	plume_mat.set_shader_parameter("diamonds", ab)
	for i in plumes.size():
		var r := plume_len[i]
		var length := r * (2.0 + 9.0 * k)
		var p := plumes[i]
		p.visible = thrust > 0.01
		(p.get_child(0) as Node3D).scale = Vector3(r * (1.0 + ab * 0.25), r * (1.0 + ab * 0.25), length)
	engine_light.light_energy = (0.3 + thrust * 2.5 + ab * 3.0) * (1.0 if thrust > 0.01 else 0.15)
	for leg in legs:
		leg.visible = gear > 0.02
		leg.scale = Vector3(1, maxf(gear, 0.02), 1)

## a unit cone along +z: radius 1 at z = 0 narrowing to 0.25 at z = 1 (UV.y = z)
func _cone_mesh() -> ArrayMesh:
	var st := SurfaceTool.new(); st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 20; var rings := 6
	for j in rings:
		var z0 := float(j) / rings; var z1 := float(j + 1) / rings
		var r0 := lerpf(0.95, 0.22, pow(z0, 0.8)); var r1 := lerpf(0.95, 0.22, pow(z1, 0.8))
		for i in seg:
			var a0 := TAU * i / seg; var a1 := TAU * (i + 1) / seg
			var p00 := Vector3(cos(a0) * r0, sin(a0) * r0, z0); var p10 := Vector3(cos(a1) * r0, sin(a1) * r0, z0)
			var p01 := Vector3(cos(a0) * r1, sin(a0) * r1, z1); var p11 := Vector3(cos(a1) * r1, sin(a1) * r1, z1)
			for v in [[p00, z0, a0], [p01, z1, a0], [p10, z0, a1], [p10, z0, a1], [p01, z1, a0], [p11, z1, a1]]:
				st.set_normal(Vector3(cos(v[2]), sin(v[2]), 0.25).normalized()); st.set_uv(Vector2(0.0, v[1])); st.add_vertex(v[0])
	return st.commit()

## open the hull round the rooms (aboard) or close it again
func set_aboard(on: bool) -> void:
	if interior == null: return
	interior.visible = on
	var lo := PackedVector4Array(); var hi := PackedVector4Array()
	for c in (interior.carves + [interior.pad_carve] if on else [interior.pad_carve]):
		lo.append(Vector4(c[0].x, c[0].y, c[0].z, 0)); hi.append(Vector4(c[1].x, c[1].y, c[1].z, 0))
	mat.set_shader_parameter("carve_lo", lo); mat.set_shader_parameter("carve_hi", hi)
	mat.set_shader_parameter("carve_n", lo.size())
