// The sky: a blue atmosphere that thins with height and reddens at sunset, fading to the nebula panorama in space.
shader_type sky;

uniform sampler2D nebula : source_color, filter_linear;
uniform vec3 up = vec3(0.0, 1.0, 0.0);      // the planet's up at the camera
uniform float alt_km = 0.0;
uniform float horizon_dip = 0.0;
uniform float atmo_km = 110.0;
uniform vec3 zenith_col = vec3(0.035, 0.11, 0.36);
uniform vec3 horizon_col = vec3(0.45, 0.62, 0.86);
uniform vec3 sun_tint = vec3(1.0);           // sunlight after the air: warms the haze
uniform vec3 cloud_col = vec3(1.0);
uniform float cloud_cover = 0.42;

float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vn(vec2 p) {
	vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash2(i), hash2(i + vec2(1, 0)), f.x), mix(hash2(i + vec2(0, 1)), hash2(i + vec2(1, 1)), f.x), f.y);
}
float fbm2(vec2 p) { float s = 0.0, a = 0.5; for (int i = 0; i < 6; i++) { s += a * vn(p); p = p * 2.07 + vec2(3.1, 1.7); a *= 0.5; } return s; }

void sky() {
	vec3 d = EYEDIR;
	vec3 L = LIGHT0_DIRECTION;
	float sun_up = dot(up, L);
	float day = smoothstep(-0.12, 0.25, sun_up);
	float dens = exp(-alt_km / 14.0) * (1.0 - smoothstep(atmo_km * 0.55, atmo_km, alt_km));
	float h = dot(d, up) + sin(horizon_dip);
	// sky gradient: pale near the horizon, deep blue overhead; warm near the sun when it's low
	vec3 zenith = zenith_col, horizon = horizon_col;
	// warm, sunlit haze low down (yellowish when the sun is low, as on the Mac), deep blue overhead
	horizon = mix(horizon, sun_tint * vec3(0.95, 0.9, 0.72), 0.22);
	zenith = mix(zenith, vec3(0.05, 0.2, 0.5), 0.5);
	vec3 c = mix(horizon, zenith, pow(clamp(h, 0.0, 1.0), 0.42));
	float toward_sun = max(dot(d, L), 0.0);
	vec3 sunset = vec3(1.0, 0.45, 0.15) * pow(toward_sun, 4.0) * (1.0 - smoothstep(0.0, 0.35, sun_up)) * smoothstep(-0.15, 0.05, sun_up);
	c = c * day + sunset * 1.6 * (1.0 - clamp(h * 3.0, 0.0, 1.0));
	c += vec3(1.0, 0.95, 0.85) * pow(toward_sun, 60.0) * 0.6 * day;          // glare round the sun
	// a cloud deck 6 km up seen from below: long wispy streaks, lit warm by the sun, thinning toward the horizon
	if (!AT_CUBEMAP_PASS && h > 0.0 && alt_km < 5.5) {
		vec3 t1 = normalize(cross(up, abs(up.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0))), t2 = cross(up, t1);
		float hgt = 6.0 - alt_km;
		vec2 pp = vec2(dot(d, t1), dot(d, t2)) / max(dot(d, up), 0.02) * hgt;     // km across the deck
		vec2 q = vec2(pp.x * 0.09 + pp.y * 0.05, pp.y * 0.28 - pp.x * 0.04);        // stretched: streaks
		float n = fbm2(q + vec2(TIME * 0.004, 0.0)) * 0.8 + fbm2(q * 4.0 + 7.0) * 0.25;
		float cov = smoothstep(1.0 - cloud_cover, 1.05 - cloud_cover + 0.3, n) * smoothstep(0.0, 0.25, h);
		// cream tops, cool grey-blue undersides
		vec3 cc = mix(vec3(0.3, 0.42, 0.5), cloud_col * sun_tint * vec3(1.05, 0.98, 0.82), smoothstep(0.45, 0.85, n)) * day + zenith * 0.15;
		cc += sun_tint * pow(toward_sun, 6.0) * 0.6 * cov;                          // bright edges toward the sun
		c = mix(c, cc, cov * 0.85);
	}
	c *= dens;
	// below the horizon from up high: a hazy limb glow
	c += horizon_col * 0.9 * exp(-abs(h) * 30.0) * (1.0 - dens) * day * smoothstep(1.0, 20.0, alt_km) * 0.8;
	// space: the nebula, hidden by a bright daytime sky
	vec2 uv = vec2(atan(d.x, -d.z) / 6.2831853 + 0.5, acos(clamp(d.y, -1.0, 1.0)) / 3.14159265);
	vec3 neb = texture(nebula, uv).rgb * 0.5;
	c += neb * (1.0 - dens * day) * (1.0 - dens * 0.7);
	// the sun's disc
	c += vec3(30.0, 28.0, 24.0) * smoothstep(0.9997, 0.99985, toward_sun);
	COLOR = c;
}
