// Models baked by Tools/blender/export_ship.py: albedo (rgb) + roughness (a), object-space normals in game axes
// (rgb) + metalness (a: 0.5 + 0.5·metal, below 0.25 = decide by material id), material id in the vertex colour.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic;
uniform vec3 flame_glow = vec3(0.55, 0.75, 1.0);
uniform float power = 1.0;

varying float mat_id;
varying vec3 local_pos;
uniform vec4 nozzles[4];          // engine mouths in local metres: centre x, y, radius, the depth they reach forward to (z)
uniform int nozzle_count = 0;

void vertex() {
	mat_id = COLOR.r * 255.0;
	local_pos = VERTEX;
}

void fragment() {
	vec4 a = texture(albedo_tex, UV);
	vec4 nm = texture(normal_tex, UV);
	vec3 on = nm.rgb * 2.0 - 1.0;
	vec3 vn = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(on, 0.0)).xyz);
	if (!FRONT_FACING) vn = -vn;
	NORMAL = vn;
	int m = int(mat_id + 0.5);
	ALBEDO = a.rgb;
	ROUGHNESS = clamp(a.a, 0.06, 1.0);
	if (m >= 17) ROUGHNESS = max(ROUGHNESS, 0.45);   // painted hull: satin, not a mirror for the sky
	METALLIC = nm.a >= 0.25 ? clamp((nm.a - 0.5) * 2.0, 0.0, 1.0) : (m == 18 ? 0.9 : 0.05);
	if (m == 3) { ALBEDO = vec3(0.01, 0.015, 0.02); ROUGHNESS = 0.05; METALLIC = 0.0; }          // glass
	bool glow = m == 5;
	float rr = 1.0;
	for (int i = 0; i < nozzle_count; i++) {
		vec4 nz = nozzles[i];
		if (local_pos.z > nz.w && length(local_pos.xy - nz.xy) < nz.z * 0.98) { glow = true; rr = length(local_pos.xy - nz.xy) / nz.z; }
	}
	if (glow) {   // engine core and the inside of the nozzle: one lit surface, no sky reflection
		ALBEDO = vec3(0.0); METALLIC = 0.0; ROUGHNESS = 1.0; SPECULAR = 0.0;
		EMISSION = mix(vec3(0.15, 0.3, 0.9) * 0.6, vec3(0.5, 0.75, 1.4), clamp(power * 2.0, 0.0, 1.0)) * (0.1 + 3.0 * power) * mix(1.8, 0.6, rr);
	}
	if (m == 1) { ALBEDO = vec3(0.042, 0.05, 0.065); METALLIC = 0.8; ROUGHNESS = 0.35; }
	if (m == 2 && !glow) { ALBEDO = vec3(0.007, 0.008, 0.012); METALLIC = 0.7; ROUGHNESS = 0.5; }
	if (m == 4) { ALBEDO = a.rgb * 0.08; METALLIC = 0.6; ROUGHNESS = 0.5; EMISSION = a.rgb * flame_glow * 2.5 * power; }   // nozzle rings: lit by the engine
	if (m == 7) { ALBEDO = vec3(1.0, 0.2, 0.05); METALLIC = 0.0; EMISSION = vec3(0.05, 0.01, 0.0); }
	if (m == 19) { ALBEDO = vec3(0.05, 0.02, 0.0); EMISSION = vec3(1.6, 0.6, 0.12) * power; }  // vents
	if (m == 12) { EMISSION = vec3(2.6, 2.1, 1.5) * power; }                                    // lamps
}
