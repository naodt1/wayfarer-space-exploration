// A camera-facing light: a hot white core inside a soft coloured halo (nav lights, strobes, landing lights).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color = vec3(1.0);
uniform float strobe = 0.0;          // > 0: blinks (period in seconds)
uniform float strength = 1.0;
instance uniform float phase = 0.0;

void vertex() {
	// face the camera
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(vec4(length(MODEL_MATRIX[0].xyz), 0, 0, 0), vec4(0, length(MODEL_MATRIX[1].xyz), 0, 0), vec4(0, 0, length(MODEL_MATRIX[2].xyz), 0), vec4(0, 0, 0, 1));
}

void fragment() {
	float r = length(UV - 0.5) * 2.0;
	float halo = pow(max(1.0 - r, 0.0), 2.2);
	float core = smoothstep(0.22, 0.0, r);
	float on = 1.0;
	if (strobe > 0.0) { float t = mod(TIME + phase, strobe); on = smoothstep(0.0, 0.03, t) * smoothstep(0.14, 0.08, t); }
	ALBEDO = (color * halo * 0.8 + vec3(1.0) * core * 2.0) * on * strength;
}
