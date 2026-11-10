// Ship displays: a star map, a radar sweep, system bars and a ship readout, all drawn live (no textures).
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform int mode = 0;                       // 0 map · 1 radar · 2 bars · 3 ship
uniform vec3 tint = vec3(0.35, 0.85, 1.0);
uniform float bright = 1.6;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float line(float d, float w) { return 1.0 - smoothstep(0.0, w, abs(d)); }

void fragment() {
	vec2 uv = UV;
	vec3 c = vec3(0.01, 0.025, 0.04);
	float g = 0.0;
	// a faint grid on every screen
	vec2 gd = abs(fract(uv * vec2(24.0, 12.0)) - 0.5);
	g += (1.0 - smoothstep(0.46, 0.5, max(gd.x, gd.y))) * 0.0;
	g += step(0.48, max(gd.x, gd.y)) * 0.12;
	if (mode == 0) {
		// the solar system: three worlds on orbits round a sun, a ship marker crawling along a route
		vec2 p = (uv - vec2(0.5)) * vec2(2.0, 1.0);
		float r = length(p);
		g += line(r - 0.22, 0.004) * 0.5 + line(r - 0.36, 0.004) * 0.5 + line(r - 0.47, 0.004) * 0.4;
		g += smoothstep(0.05, 0.0, r) * 1.5;
		for (int i = 0; i < 3; i++) {
			float rad = 0.22 + float(i) * 0.13; float a = TIME * (0.05 - float(i) * 0.012) + float(i) * 2.1;
			g += smoothstep(0.02, 0.0, length(p - vec2(cos(a), sin(a)) * rad)) * 1.5;
		}
		float t = fract(TIME * 0.05);
		g += smoothstep(0.012, 0.0, length(p - mix(vec2(0.22, 0.0), vec2(-0.25, 0.28), t))) * 2.0;
		g += line(dot(p - vec2(0.22, 0.0), normalize(vec2(0.28, 0.47))), 0.003) * step(r, 0.5) * 0.3;
	} else if (mode == 1) {
		vec2 p = (uv - 0.5) * vec2(2.0, 1.0);
		float r = length(p); float a = atan(p.y, p.x);
		float sweep = fract((a / 6.2832) - TIME * 0.25);
		g += (line(r - 0.15, 0.004) + line(r - 0.3, 0.004) + line(r - 0.45, 0.004)) * 0.45 * step(r, 0.5);
		g += pow(1.0 - sweep, 8.0) * step(r, 0.47) * 0.8;
		for (int i = 0; i < 6; i++) {
			vec2 b = vec2(hash(vec2(float(i), 1.0)) - 0.5, hash(vec2(float(i), 2.0)) - 0.5) * 0.8;
			g += smoothstep(0.015, 0.0, length(p - b)) * (0.4 + pow(1.0 - fract((atan(b.y, b.x) / 6.2832) - TIME * 0.25), 3.0) * 2.0);
		}
	} else if (mode == 2) {
		float i = floor(uv.x * 12.0);
		float h = 0.25 + 0.6 * (0.5 + 0.5 * sin(TIME * (0.6 + hash(vec2(i)) * 1.4) + i));
		float bar = step(fract(uv.x * 12.0), 0.7) * step(1.0 - uv.y, h);
		g += bar * 0.9;
		c += vec3(1.0, 0.5, 0.15) * bar * step(0.78, h) * 0.6;
	} else {
		// the ship from above, outlined, with a pulsing reactor and moving status lines
		vec2 p = (uv - 0.5) * vec2(2.0, 1.0);
		float hull = abs(p.x) - (0.12 + 0.18 * smoothstep(-0.45, 0.35, p.y));
		g += line(hull, 0.006) * step(abs(p.y), 0.45) * 1.2;
		g += smoothstep(0.04, 0.0, length(p - vec2(0.0, 0.1))) * (1.0 + 0.6 * sin(TIME * 3.0));
		for (int k = 0; k < 5; k++) g += line(uv.y - (0.15 + float(k) * 0.05), 0.002) * step(uv.x, 0.12 + 0.1 * fract(TIME * 0.3 + float(k) * 0.37)) * 0.8;
	}
	float scan = 0.92 + 0.08 * sin(uv.y * 300.0 + TIME * 4.0);
	float edge = smoothstep(0.0, 0.015, min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y)));
	ALBEDO = (c + tint * g * bright) * scan * edge + tint * (1.0 - edge) * 0.6;
}
