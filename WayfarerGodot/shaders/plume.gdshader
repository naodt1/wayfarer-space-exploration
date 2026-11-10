// Engine exhaust: an additive cone, hot and white at the nozzle, tinted toward its edge and fading down its length,
// with flickering shock diamonds. UV.y runs 0 at the nozzle to 1 at the tail.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 edge_col = vec3(0.3, 0.6, 2.4);
uniform vec3 core_col = vec3(1.6, 2.2, 3.4);
uniform float intensity = 1.0;
uniform float diamonds = 0.0;

void fragment() {
	float t = UV.y;
	float face = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float core = pow(face, 2.5);
	float fall = pow(1.0 - t, 2.4);
	float flick = 0.9 + 0.1 * sin(TIME * 53.0 + t * 7.0) * sin(TIME * 31.0);
	float shock = 1.0 + diamonds * 0.6 * pow(0.5 + 0.5 * sin(t * 38.0 - TIME * 3.0), 6.0) * (1.0 - t);
	vec3 c = mix(edge_col * 0.6, core_col, core) * fall * flick * shock;
	c += core_col * 1.5 * smoothstep(0.12, 0.0, t) * core;       // white-hot right at the nozzle
	ALBEDO = c * intensity * 0.35;
}
