// Interior surfaces: panelled walls, tiled floors and ceilings. The panel seams come from the position in ship
// space (metres), projected on the face's own plane, so every box gets clean panels without UVs.
shader_type spatial;

uniform vec3 albedo : source_color = vec3(0.6);
uniform vec3 seam : source_color = vec3(0.2);
uniform vec2 cell = vec2(2.0, 1.0);        // panel width and height (m)
uniform float seam_w = 0.025;
uniform float roughness = 0.5;
uniform float metallic = 0.1;
uniform float variation = 0.06;            // panel-to-panel brightness change

varying vec3 lp;
varying vec3 ln;
void vertex() { lp = VERTEX; ln = NORMAL; }

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void fragment() {
	vec3 n = abs(normalize(ln));
	vec2 p = n.y > 0.7 ? lp.xz : (n.x > n.z ? lp.zy : lp.xy);
	vec2 c = p / cell;
	vec2 f = abs(fract(c) - 0.5) * cell;                         // distance to the panel centre (m)
	vec2 e = cell * 0.5 - f;                                     // distance to the seam
	float s = 1.0 - smoothstep(0.0, seam_w, min(e.x, e.y));
	float v = 1.0 + (hash(floor(c)) - 0.5) * variation * 2.0;
	ALBEDO = mix(albedo * v, seam, s);
	ROUGHNESS = mix(roughness, 0.9, s);
	METALLIC = metallic;
}
