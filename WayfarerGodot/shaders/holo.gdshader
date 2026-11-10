// Holograms: a slowly turning globe of light (latitude/longitude grid, glowing rim, scan bands), or the reactor core
// (core = 1: bands of energy climbing a column).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec3 tint = vec3(0.3, 0.85, 1.0);
uniform float strength = 1.0;
uniform float core = 0.0;
uniform vec3 land_col = vec3(0.35, 0.9, 0.45);    // the world on the globe (set from the autopilot's destination)
uniform vec3 sea_col = vec3(0.1, 0.35, 0.9);
uniform float pattern = 0.0;                         // varies the continents per world

varying vec3 lp;
void vertex() { lp = VERTEX; }

void fragment() {
	float fres = pow(1.0 - abs(dot(normalize(NORMAL), normalize(VIEW))), 2.0);
	vec3 c;
	if (core > 0.5) {
		float bands = pow(0.5 + 0.5 * sin(lp.y * 1.6 - TIME * 4.0), 6.0);
		float flick = 0.85 + 0.15 * sin(TIME * 23.0) * sin(TIME * 7.0);
		c = tint * (0.9 + bands * 2.5 + fres * 1.5) * flick;
	} else {
		vec3 d = normalize(lp);
		float lon = atan(d.z, d.x) + TIME * 0.25, lat = asin(clamp(d.y, -1.0, 1.0));
		float grid = max(1.0 - smoothstep(0.0, 0.05, abs(fract(lon / 0.3927) - 0.5) * 2.0 - 0.9) , 0.0);
		grid = max(step(0.94, abs(fract(lon / 0.3927) - 0.5) * 2.0), step(0.94, abs(fract(lat / 0.2618) - 0.5) * 2.0));
		// continents turning with the globe, in the destination world's colours
		float land = smoothstep(0.5, 0.62, 0.5 + 0.5 * sin(lon * 3.0 + pattern) * sin(lat * 4.0 + 1.0 + pattern * 0.7) * cos(lon * 1.7 - lat * 2.0 + pattern * 1.3));
		float scan = smoothstep(0.96, 1.0, fract(d.y * 2.0 - TIME * 0.4));
		vec3 surf = mix(sea_col * 0.45, land_col * 0.9, land);
		c = surf * 0.9 + tint * (grid * 0.18 + fres * 0.55 + scan * 0.25);
	}
	ALBEDO = c * strength;
}
