// Grass clumps (one MultiMesh): blades sway in the wind more toward their tips, glow when backlit by the sun,
// and shrink away at the edge of the field so it has no hard border.  UV.x = 0 at the root, 1 at the tip.
shader_type spatial;
render_mode cull_disabled;

uniform float fade_start = 95.0;
uniform float fade_end = 150.0;

varying float tip;

void vertex() {
	tip = UV.x;
	vec3 wpos = MODEL_MATRIX[3].xyz;
	float ph = dot(wpos, vec3(1.0, 0.7, 1.3)) * 0.9;
	vec2 sway = vec2(sin(TIME * 1.7 + ph) + 0.4 * sin(TIME * 3.1 + ph * 1.7), cos(TIME * 1.3 + ph * 0.8)) * 0.07 * tip * tip;
	VERTEX.xz += sway;
	float d = length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz);
	VERTEX *= 1.0 - smoothstep(fade_start, fade_end, d);
}

void fragment() {
	ALBEDO = COLOR.rgb * mix(0.5, 1.3, tip) + vec3(0.025, 0.022, 0.0) * tip * tip;
	ROUGHNESS = 0.8;
	SPECULAR = 0.2;
	BACKLIGHT = vec3(0.35, 0.45, 0.15) * tip;
	AO = mix(0.35, 1.0, tip); AO_LIGHT_AFFECT = 0.5;
}
