// Models baked by Tools/blender/export_ship.py: albedo (rgb) + roughness (a), object-space normals in game axes
// (rgb) + metalness (a: 0.5 + 0.5·metal, below 0.25 = decide by material id), material id in the vertex colour.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D normal_tex : filter_linear_mipmap_anisotropic;
uniform vec3 flame_glow = vec3(0.55, 0.75, 1.0);
uniform float power = 1.0;
uniform float plating = 0.0;        // > 0: panel size in metres (capital ships)
varying vec3 obj_n;
uniform sampler2D emit_tex : source_color, filter_linear_mipmap, hint_default_black;
uniform float emit_k = 0.0;          // baked window and panel lights (the ships that have an emit map)

varying float mat_id;
varying vec3 local_pos;
uniform vec4 nozzles[8];          // engine mouths in local metres: centre x, y, radius, the depth they reach forward to (z)
uniform int nozzle_count = 0;
uniform vec4 carve_lo[10];          // hull cut away while you walk aboard (ship metres, x is |x|)
uniform vec4 carve_hi[10];
uniform int carve_n = 0;

void vertex() {
	mat_id = COLOR.r * 255.0;
	local_pos = VERTEX; obj_n = NORMAL;
}

void fragment() {
	if (carve_n > 0) {
		vec3 ap = vec3(abs(local_pos.x), local_pos.y, local_pos.z);
		for (int i = 0; i < carve_n; i++) {
			if (all(greaterThan(ap, carve_lo[i].xyz)) && all(lessThan(ap, carve_hi[i].xyz))) discard;
		}
	}
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
	METALLIC = min(METALLIC, 0.7);
	if (METALLIC > 0.3 && m >= 17 && local_pos.z < nozzles[0].w) ALBEDO = max(ALBEDO, vec3(0.22));   // bare hull metal catches the light (not the nozzles)
	if (m == 3) { ALBEDO = vec3(0.01, 0.015, 0.02); ROUGHNESS = 0.05; METALLIC = 0.0; }          // glass
	bool glow = m == 5;
	float rr = 1.0;
	for (int i = 0; i < nozzle_count; i++) {
		vec4 nz = nozzles[i];
		if (local_pos.z > nz.w && length(local_pos.xy - nz.xy) < nz.z * 0.98) { glow = true; rr = length(local_pos.xy - nz.xy) / nz.z; }
	}
	if (glow) {   // engine core and the inside of the nozzle: one lit surface, no sky reflection
		ALBEDO = vec3(0.0); METALLIC = 0.0; ROUGHNESS = 1.0; SPECULAR = 0.0;
		EMISSION = mix(flame_glow * 0.35, flame_glow, clamp(power * 2.0, 0.0, 1.0)) * (0.1 + 3.0 * power) * mix(1.8, 0.6, rr);
	}
	if (m == 1) { ALBEDO = vec3(0.042, 0.05, 0.065); METALLIC = 0.8; ROUGHNESS = 0.35; }
	if (m == 2 && !glow) { ALBEDO = vec3(0.007, 0.008, 0.012); METALLIC = 0.7; ROUGHNESS = 0.5; }
	if (m == 4) { ALBEDO = a.rgb * 0.08; METALLIC = 0.6; ROUGHNESS = 0.5; EMISSION = a.rgb * flame_glow * 2.5 * power; }   // nozzle rings: lit by the engine
	if (m == 7) { ALBEDO = vec3(1.0, 0.2, 0.05); METALLIC = 0.0; EMISSION = vec3(0.05, 0.01, 0.0); }
	if (m == 19) { ALBEDO = vec3(0.05, 0.02, 0.0); EMISSION = vec3(1.6, 0.6, 0.12) * power; }  // vents
	EMISSION += texture(emit_tex, UV).rgb * emit_k;
	if (plating > 0.0 && m >= 17 && !glow) {
		vec3 an = abs(normalize(obj_n));
		vec2 pp = an.y > 0.7 ? local_pos.xz : (an.x > an.z ? local_pos.zy : local_pos.xy);
		vec2 cellp = pp / vec2(plating * 2.0, plating);
		vec2 id = floor(cellp), fr = fract(cellp);
		float h1 = fract(sin(dot(id, vec2(12.9898, 78.233))) * 43758.5453);
		float seam = 1.0 - smoothstep(0.0, 0.035, min(min(fr.x, 1.0 - fr.x), min(fr.y, 1.0 - fr.y)));
		ALBEDO *= mix(0.86, 1.1, h1) * (1.0 - seam * 0.45);
		ROUGHNESS = clamp(ROUGHNESS + (h1 - 0.5) * 0.25, 0.2, 1.0);
		// windows: small lit rectangles in rows along the flanks
		if (an.y < 0.5) {
			vec2 wc = pp / vec2(3.2, 4.6); vec2 wf = fract(wc), wi = floor(wc);
			float h2 = fract(sin(dot(wi, vec2(39.3468, 11.135))) * 24634.6345);
			float row = step(0.72, fract(sin(wi.y * 91.7) * 4375.5));        // only some decks have windows
			float win = step(0.3, wf.x) * step(wf.x, 0.72) * step(0.38, wf.y) * step(wf.y, 0.62) * step(0.45, h2) * row;
			ALBEDO = mix(ALBEDO, vec3(0.02), win);
			EMISSION += win * mix(vec3(1.6, 1.25, 0.8), vec3(0.6, 1.1, 1.7), step(0.9, h2)) * 0.9;
		}
	}
	// rim light: the edges facing away from the camera pick up the sky, so the silhouette reads against the ground
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION += ALBEDO * rim * 0.35 + vec3(0.25, 0.35, 0.5) * rim * 0.06;
	if (m == 12) { EMISSION = vec3(2.6, 2.1, 1.5) * power; }                                    // lamps
}
