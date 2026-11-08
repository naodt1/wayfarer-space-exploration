// Scattered rocks: the photo rock layer projected on the rock's own axes, tinted per rock.
shader_type spatial;

uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_pack : filter_linear_mipmap_anisotropic, repeat_enable;

varying vec3 lp;
varying vec3 ln;

void vertex() { lp = VERTEX; ln = NORMAL; }

void fragment() {
	vec3 bw = pow(abs(normalize(ln)), vec3(4.0)); bw /= bw.x + bw.y + bw.z;
	vec3 p = lp / 1.6;
	vec4 a = texture(layer_albedo, vec3(p.yz, 2.0)) * bw.x + texture(layer_albedo, vec3(p.xz, 2.0)) * bw.y + texture(layer_albedo, vec3(p.xy, 2.0)) * bw.z;
	vec4 k = texture(layer_pack, vec3(p.yz, 2.0)) * bw.x + texture(layer_pack, vec3(p.xz, 2.0)) * bw.y + texture(layer_pack, vec3(p.xy, 2.0)) * bw.z;
	// mossy tops
	float moss = smoothstep(0.55, 0.85, normalize(ln).y) * 0.6;
	ALBEDO = mix(a.rgb * COLOR.rgb * 1.3, vec3(0.06, 0.09, 0.02), moss);
	ROUGHNESS = mix(k.b, 0.9, moss);
	AO = k.a;
	vec3 tn = vec3(k.r * 2.0 - 1.0, k.g * 2.0 - 1.0, 0.0);
	vec3 n = normalize(normalize(ln) + (vec3(0.0, tn.x, tn.y) * bw.x + vec3(tn.x, 0.0, tn.y) * bw.y + vec3(tn.x, tn.y, 0.0) * bw.z) * 0.8);
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(n, 0.0)).xyz);
}
