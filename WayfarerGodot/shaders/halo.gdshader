// The atmosphere seen from space: a shell a little larger than the planet, glowing blue along the sunlit limb and
// laying a faint haze over the disc. Fades out as you descend into the air (the sky shader takes over there).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, shadows_disabled, fog_disabled;

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float strength = 1.0;
uniform vec3 tint = vec3(0.25, 0.5, 1.0);

varying vec3 wn;
void vertex() { wn = NORMAL; }

void fragment() {
	float f = 1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	// a thick limb: bright at the edge, a soft blue veil well across the disc (the Mac's look)
	float rim = pow(f, 6.0) * 2.0 + pow(f, 2.2) * 0.22;
	float s = dot(normalize(wn), sun_dir);
	float day = smoothstep(-0.35, 0.3, s);
	vec3 col = mix(tint, vec3(1.0, 0.5, 0.25), smoothstep(0.3, -0.1, s) * day);    // a sunset band along the terminator
	ALBEDO = col * rim * day * strength;
}
