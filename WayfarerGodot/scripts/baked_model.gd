## Loads a model baked by Tools/blender/export_ship.py (the same files the Mac game uses):
## <name>.bin — float32 triangles, 9 floats per vertex: position (model units), normal, uv, material id.
class_name BakedModel

static func load_mesh(path: String, scale: float) -> ArrayMesh:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("missing model " + path)
		return ArrayMesh.new()
	var data := f.get_buffer(f.get_length())
	var floats := data.to_float32_array()
	var n := floats.size() / 9
	var pos := PackedVector3Array(); pos.resize(n)
	var nor := PackedVector3Array(); nor.resize(n)
	var uv := PackedVector2Array(); uv.resize(n)
	var col := PackedColorArray(); col.resize(n)
	for i in n:
		var b := i * 9
		pos[i] = Vector3(floats[b], floats[b + 1], floats[b + 2]) * scale
		nor[i] = Vector3(floats[b + 3], floats[b + 4], floats[b + 5])
		uv[i] = Vector2(floats[b + 6], floats[b + 7])
		col[i] = Color(floats[b + 8] / 255.0, 0, 0)
	# Metal draws triangles counter-clockwise; Godot culls clockwise-front: swap winding
	for t in range(0, n - 2, 3):
		var p := pos[t + 1]; pos[t + 1] = pos[t + 2]; pos[t + 2] = p
		var q := nor[t + 1]; nor[t + 1] = nor[t + 2]; nor[t + 2] = q
		var u := uv[t + 1]; uv[t + 1] = uv[t + 2]; uv[t + 2] = u
		var c := col[t + 1]; col[t + 1] = col[t + 2]; col[t + 2] = c
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = nor
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_COLOR] = col
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

static func material(albedo: Texture2D, normal: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/baked.gdshader")
	m.set_shader_parameter("albedo_tex", albedo)
	m.set_shader_parameter("normal_tex", normal)
	return m
