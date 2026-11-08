// The sky: a blue atmosphere that thins with height and reddens at sunset, fading to the nebula panorama in space.
shader_type sky;

uniform sampler2D nebula : source_color, filter_linear;
uniform vec3 up = vec3(0.0, 1.0, 0.0);      // the planet's up at the camera
uniform float alt_km = 0.0;
uniform float horizon_dip = 0.0;            // how far below level the horizon is (radians), grows with height

void sky() {
	vec3 d = EYEDIR;
	vec3 L = LIGHT0_DIRECTION;
	float sun_up = dot(up, L);
	float day = smoothstep(-0.12, 0.25, sun_up);
	float dens = exp(-alt_km / 14.0) * (1.0 - smoothstep(60.0, 110.0, alt_km));
	float h = dot(d, up) + sin(horizon_dip);
	// sky gradient: pale near the horizon, deep blue overhead; warm near the sun when it's low
	vec3 zenith = vec3(0.06, 0.16, 0.42), horizon = vec3(0.55, 0.7, 0.9);
	vec3 c = mix(horizon, zenith, pow(clamp(h, 0.0, 1.0), 0.45));
	float toward_sun = max(dot(d, L), 0.0);
	vec3 sunset = vec3(1.0, 0.45, 0.15) * pow(toward_sun, 4.0) * (1.0 - smoothstep(0.0, 0.35, sun_up)) * smoothstep(-0.15, 0.05, sun_up);
	c = c * day + sunset * 1.6 * (1.0 - clamp(h * 3.0, 0.0, 1.0));
	c += vec3(1.0, 0.95, 0.85) * pow(toward_sun, 60.0) * 0.6 * day;          // glare round the sun
	c *= dens;
	// below the horizon from up high: a hazy limb glow
	c += vec3(0.3, 0.55, 1.0) * exp(-abs(h) * 30.0) * (1.0 - dens) * day * smoothstep(1.0, 20.0, alt_km) * 0.8;
	// space: the nebula, hidden by a bright daytime sky
	vec2 uv = vec2(atan(d.x, -d.z) / 6.2831853 + 0.5, acos(clamp(d.y, -1.0, 1.0)) / 3.14159265);
	vec3 neb = texture(nebula, uv).rgb * 0.5;
	c += neb * (1.0 - dens * day) * (1.0 - dens * 0.7);
	// the sun's disc
	c += vec3(30.0, 28.0, 24.0) * smoothstep(0.9997, 0.99985, toward_sun);
	COLOR = c;
}
