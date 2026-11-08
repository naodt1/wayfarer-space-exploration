// Terrain: the planet's per-vertex colours far away; up close, photo ground layers (grass, forest floor, rock, sand,
// snow) blended by per-vertex weights, projected from three sides and mixed at three scales so the tiling never shows.
// A port of terrainF in WayfarerMac/Sources/Wayfarer/Shaders.swift.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2DArray layer_albedo : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray layer_pack : filter_linear_mipmap_anisotropic, repeat_enable;   // normal xy, roughness, AO
uniform float tint_k = 0.65;                 // how much the region colour tints the photo layers

varying vec3 local_pos;
varying vec3 geo_n;
varying vec4 lw;                            // grass, forest, rock, sand
varying float snow_w;
instance uniform vec3 origin_mod;           // the chunk centre modulo 1 km (computed in double precision on the CPU)

const vec3 MEANS[5] = vec3[](vec3(0.1186, 0.1523, 0.0304), vec3(0.3135, 0.1721, 0.0651), vec3(0.0785, 0.0911, 0.1056),
							 vec3(0.3307, 0.2571, 0.1546), vec3(0.7323, 0.8584, 0.9745));

void vertex() {
	local_pos = VERTEX; geo_n = NORMAL; lw = CUSTOM0; snow_w = COLOR.a;
}

struct Surf { vec3 alb; vec3 n; float rough; float ao; };

// one layer at one scale, projected along the two strongest axes
Surf sample_layer(int l, vec3 p, vec3 bw) {
	Surf s; s.alb = vec3(0.0); s.n = vec3(0.0); s.rough = 0.0; s.ao = 0.0;
	if (bw.x > 0.001) {
		vec4 a = texture(layer_albedo, vec3(p.yz, float(l))); vec4 k = texture(layer_pack, vec3(p.yz, float(l)));
		s.alb += a.rgb * bw.x; s.n += vec3(0.0, k.r * 2.0 - 1.0, k.g * 2.0 - 1.0) * bw.x; s.rough += k.b * bw.x; s.ao += k.a * bw.x;
	}
	if (bw.y > 0.001) {
		vec4 a = texture(layer_albedo, vec3(p.xz, float(l))); vec4 k = texture(layer_pack, vec3(p.xz, float(l)));
		s.alb += a.rgb * bw.y; s.n += vec3(k.r * 2.0 - 1.0, 0.0, k.g * 2.0 - 1.0) * bw.y; s.rough += k.b * bw.y; s.ao += k.a * bw.y;
	}
	if (bw.z > 0.001) {
		vec4 a = texture(layer_albedo, vec3(p.xy, float(l))); vec4 k = texture(layer_pack, vec3(p.xy, float(l)));
		s.alb += a.rgb * bw.z; s.n += vec3(k.r * 2.0 - 1.0, k.g * 2.0 - 1.0, 0.0) * bw.z; s.rough += k.b * bw.z; s.ao += k.a * bw.z;
	}
	return s;
}

void fragment() {
	float dist = length(VERTEX);
	vec3 wp = origin_mod + local_pos;                     // metres, wrapped every 1 km (all scales below divide 1 km)
	vec3 gn = normalize(geo_n);
	float wt[5] = float[](lw.x, lw.y, lw.z, lw.w, snow_w);
	float wsum = lw.x + lw.y + lw.z + lw.w + snow_w;
	float nearK = (1.0 - smoothstep(600.0, 6000.0, dist)) * clamp(wsum * 1.5, 0.0, 1.0);
	vec3 c = COLOR.rgb;
	vec3 n = gn;
	float rough = 0.92, ao = 1.0;
	if (nearK > 0.003) {
		vec3 bw = pow(abs(gn), vec3(6.0));
		bw = max(bw - min(bw.x, min(bw.y, bw.z)), 0.0) + 1e-5; bw /= (bw.x + bw.y + bw.z);
		vec3 pA = wp / 2.5, pB = wp.zyx / 8.0 + 0.31, pC = wp.yxz / 40.0 + 0.57;
		float wA = 1.0 - smoothstep(100.0, 250.0, dist);
		float wC = smoothstep(60.0, 140.0, dist);
		// the two strongest layers
		int l0 = 0, l1 = 1;
		if (wt[1] > wt[0]) { l0 = 1; l1 = 0; }
		for (int l = 2; l < 5; l++) { if (wt[l] > wt[l0]) { l1 = l0; l0 = l; } else if (wt[l] > wt[l1]) { l1 = l; } }
		vec3 alb = vec3(0.0), tn = vec3(0.0); float rs = 0.0, aos = 0.0, tot = 0.0;
		for (int j = 0; j < 2; j++) {
			int l = j == 0 ? l0 : l1;
			float wl = j == 0 ? 1.0 : clamp((wt[l1] / max(wt[l0], 1e-4)) * 1.4 - 0.2, 0.0, 1.0);
			if (wl < 0.03) continue;
			Surf b = sample_layer(l, pB, bw);
			Surf cc = b; if (wC > 0.01) cc = sample_layer(l, pC, bw);
			Surf a = b;  if (wA > 0.01) a = sample_layer(l, pA, bw);
			float mixB = 0.35, mixC = 0.3 * wC;
			vec3 col = mix(mix(mix(b.alb, a.alb, wA), b.alb, mixB), cc.alb, mixC);
			col *= mix(1.0, 0.8 + 0.2 * dot(cc.alb, vec3(0.333)) / max(dot(MEANS[l], vec3(0.333)), 0.02), wC);
			vec3 ratio = clamp(c / max(MEANS[l], vec3(0.02)), 0.0, 3.0);
			col *= mix(vec3(1.0), ratio, tint_k);
			alb += col * wl;
			tn += (mix(b.n, a.n, wA) + cc.n * 0.4 * wC) * wl;
			rs += mix(b.rough, a.rough, wA) * wl; aos += mix(b.ao, a.ao, wA) * wl; tot += wl;
		}
		if (tot > 0.0) {
			alb /= tot; rough = rs / tot; ao = aos / tot;
			c = mix(c, alb, nearK);
			n = normalize(gn + tn / tot * 0.9 * nearK);
		}
	}
	bool water = wsum < 0.01 && COLOR.b > COLOR.g * 1.6 && COLOR.b > 0.03;
	ALBEDO = c;
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ROUGHNESS = water ? 0.08 : mix(0.92, rough, nearK);
	AO = mix(1.0, ao, nearK); AO_LIGHT_AFFECT = 0.3;
	METALLIC = 0.0;
	SPECULAR = water ? 0.6 : 0.25;
}
