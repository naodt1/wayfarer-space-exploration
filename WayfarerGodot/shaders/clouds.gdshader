// A world's cloud layer (the Mac game's CloudLayer): a shell a few km above the ground, patterned by 3D noise on the
// direction from the centre, lit by the sun (white on the day side, warm at the terminator, dark at night) and seen
// from above or below. Slowly drifts.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform vec3 color = vec3(1.0);
uniform float cover = 0.5;
uniform float fade = 1.0;          // fades the layer out when you're right in it

varying vec3 dir;
void vertex() { dir = normalize(VERTEX); }

float hash(vec3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float vnoise(vec3 x) {
	vec3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1,0,0)), f.x), mix(hash(i + vec3(0,1,0)), hash(i + vec3(1,1,0)), f.x), f.y),
			   mix(mix(hash(i + vec3(0,0,1)), hash(i + vec3(1,0,1)), f.x), mix(hash(i + vec3(0,1,1)), hash(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float fbm(vec3 p) {
	float s = 0.0, a = 0.5;
	for (int i = 0; i < 6; i++) { s += a * vnoise(p); p = p * 2.03 + vec3(1.7, 9.2, 3.1); a *= 0.5; }
	return s;
}

void fragment() {
	float t = TIME * 0.0006;
	vec3 p = dir * 7.0 + vec3(t, 0.0, t * 0.7);
	// large weather systems with finer puffs inside them
	float big = fbm(p * 0.6);
	float n = fbm(p * 3.0 + big * 1.4) * 0.75 + vnoise(p * 40.0) * 0.12 + vnoise(p * 110.0) * 0.06;
	float lat = abs(dir.y);
	float c = smoothstep(1.0 - cover + 0.04, 1.0 - cover + 0.16, n * 0.65 + big * 0.55 - 0.1 + lat * 0.05);
	float s = dot(dir, sun_dir);
	float day = smoothstep(-0.15, 0.3, s);
	vec3 lit = mix(vec3(1.0, 0.55, 0.32), color, smoothstep(0.0, 0.35, s));      // warm along the terminator
	float shade = 0.72 + 0.28 * smoothstep(0.3, 0.8, n);                            // puffs: brighter tops
	ALBEDO = lit * shade * (0.03 + 0.97 * day) * 1.05;
	// seen from below: thinner, broken, bright where the sun shines through
	ALPHA = c * 0.9 * fade;
}
