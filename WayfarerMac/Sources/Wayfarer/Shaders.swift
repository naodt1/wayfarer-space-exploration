// All Metal shaders, compiled at launch with device.makeLibrary(source:).
// Rendering is camera-relative: every position is (world - camera) computed in double precision on the CPU.

let shaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Frame {
    float4x4 view;        // rotation only
    float4x4 proj;
    float4x4 viewProj;
    float4x4 invViewProj;
    float4 sun;           // xyz sun position relative to camera, w time
    float4 misc;          // x exposure, y star opacity, z sun intensity, w near plane
    float4 camFwd;        // xyz camera forward
    float4x4 shadow0;     // light matrices of the two sun-shadow cascades (camera-relative)
    float4x4 shadow1;
    float4 shadowP;       // x radius0 (0 = off), y radius1 (0 = off), z 1/texture size, w enabled
    float4 shadowQ;       // x,y depth bias of each cascade in light-depth units
    float4 blob;          // the ground under a low ship: xyz point (camera-relative), w radius
    float4 blob2;         // x strength
};
// the broad shade a big ship throws on the ground beneath it while it hovers or lands
float blobShade(constant Frame& F, float3 rel) {
    if (F.blob2.x <= 0.0) return 0.0;
    float d = length(rel - F.blob.xyz);
    return (1.0 - smoothstep(F.blob.w * 0.45, F.blob.w * 1.3, d)) * F.blob2.x;
}
struct Obj { float4x4 model; float4 p0; float4 p1; float4 p2; float4 color; float4 p3; float4 p4; float4 p5; float4 p6; };

constant float PI = 3.14159265;

// ---------------------------------------------------------------- noise
float h3(float3 p) { p = fract(p * 0.3183099 + 0.1); p *= 17.0; return fract(p.x * p.y * p.z * (p.x + p.y + p.z)); }
float vn(float3 x) {
    float3 i = floor(x), f = fract(x); f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(h3(i), h3(i + float3(1,0,0)), f.x), mix(h3(i + float3(0,1,0)), h3(i + float3(1,1,0)), f.x), f.y),
               mix(mix(h3(i + float3(0,0,1)), h3(i + float3(1,0,1)), f.x), mix(h3(i + float3(0,1,1)), h3(i + float3(1,1,1)), f.x), f.y), f.z);
}
float fbn(float3 p, int o) { float s = 0.0, a = 0.5; for (int i = 0; i < 8; i++) { if (i >= o) break; s += a * vn(p); p = p * 2.03 + 1.7; a *= 0.5; } return s; }

// ---------------------------------------------------------------- sunlight through the atmosphere
// Kasten-Young air mass gives the reddened sunlight that reaches a point on the ground.
float3 sunTransmit(float cosZ, float3 rayleigh, float Hr, float mie, float Hm) {
    float c = clamp(cosZ, -0.2, 1.0);
    float zen = acos(clamp(c, -1.0, 1.0)) * 57.2957795;
    float m = 1.0 / max(c + 0.50572 * pow(max(96.07995 - zen, 0.1), -1.6364), 0.02);
    float3 tau = (rayleigh * Hr + mie * 1.1 * Hm) * min(m, 40.0);
    return exp(-tau) * smoothstep(-0.12, 0.04, cosZ);
}

// ---------------------------------------------------------------- sun shadows (two cascades, 3x3 hardware PCF)
constexpr sampler shSmp(coord::normalized, filter::linear, address::clamp_to_edge, compare_func::less_equal);
float shadowTap(depth2d_array<float> sm, float4x4 M, float3 p, uint slice, float bias, float tx, thread float& edge) {
    float4 q = M * float4(p, 1.0);
    edge = max(abs(q.x), abs(q.y));
    if (edge > 0.98 || q.z >= 1.0) { edge = 2.0; return 1.0; }
    float2 uv = float2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
    float s = 0.0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) s += sm.sample_compare(shSmp, uv + float2(x, y) * tx, slice, q.z - bias);
    return s / 9.0;
}
float shadowAt(constant Frame& F, depth2d_array<float> sm, float3 rel, float3 n) {
    if (F.shadowP.w < 0.5) return 1.0;
    float tx = F.shadowP.z, e0 = 2.0, e1 = 2.0;
    float s0 = 1.0, s1 = 1.0;
    if (F.shadowP.x > 0.0) s0 = shadowTap(sm, F.shadow0, rel + n * (F.shadowP.x * tx * 3.0), 0, F.shadowQ.x, tx, e0);
    if (e0 < 0.8) return s0;
    if (F.shadowP.y > 0.0) s1 = mix(shadowTap(sm, F.shadow1, rel + n * (F.shadowP.y * tx * 3.0), 1, F.shadowQ.y, tx, e1), 1.0, smoothstep(0.7, 0.95, e1));
    return e0 < 0.98 ? mix(s0, s1, smoothstep(0.8, 0.98, e0)) : s1;
}

// ---------------------------------------------------------------- terrain
struct TOut { float4 pos [[position]]; float3 rel; float3 n; float3 col; float elev; float3 tri; float3 w0; float3 w1; };
vertex TOut terrainV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]]) {
    uint b = vid * 19;
    float4 w = O.model * float4(vb[b], vb[b+1], vb[b+2], 1.0);
    TOut o; o.pos = F.viewProj * w; o.rel = w.xyz;
    o.n = float3(vb[b+3], vb[b+4], vb[b+5]); o.col = float3(vb[b+6], vb[b+7], vb[b+8]); o.elev = vb[b+9];
    o.tri = float3(vb[b+10], vb[b+11], vb[b+12]);
    o.w0 = float3(vb[b+13], vb[b+14], vb[b+15]); o.w1 = float3(vb[b+16], vb[b+17], vb[b+18]);
    return o;
}
float4 tri(texture2d<float> t, sampler s, float3 p, float3 w) { return t.sample(s, p.yz) * w.x + t.sample(s, p.xz) * w.y + t.sample(s, p.xy) * w.z; }

struct Surf { float3 albedo; float3 n; float rough; float ao; };
// tri-planar sample of one ground layer with whiteout normal blending
Surf sampleLayer(texture2d_array<float> alb, texture2d_array<float> pk, sampler s, uint layer, float3 p, float3 gn, float3 bw) {
    Surf r; r.albedo = float3(0.0); r.rough = 0.0; r.ao = 0.0;
    float3 nsum = float3(0.0);
    if (bw.x > 0.02) {
        float2 uv = p.zy; float4 c = alb.sample(s, uv, layer), k = pk.sample(s, uv, layer);
        float3 tn = float3(k.xy * 2.0 - 1.0, 0.0); tn.z = sqrt(saturate(1.0 - dot(tn.xy, tn.xy))); tn.x *= sign(gn.x);
        float3 t = float3(tn.xy + gn.zy, abs(tn.z) * gn.x);
        nsum += t.zyx * bw.x; r.albedo += c.rgb * bw.x; r.rough += k.z * bw.x; r.ao += k.w * bw.x;
    }
    if (bw.y > 0.02) {
        float2 uv = p.xz; float4 c = alb.sample(s, uv, layer), k = pk.sample(s, uv, layer);
        float3 tn = float3(k.xy * 2.0 - 1.0, 0.0); tn.z = sqrt(saturate(1.0 - dot(tn.xy, tn.xy))); tn.x *= sign(gn.y);
        float3 t = float3(tn.xy + gn.xz, abs(tn.z) * gn.y);
        nsum += t.xzy * bw.y; r.albedo += c.rgb * bw.y; r.rough += k.z * bw.y; r.ao += k.w * bw.y;
    }
    if (bw.z > 0.02) {
        float2 uv = p.xy; float4 c = alb.sample(s, uv, layer), k = pk.sample(s, uv, layer);
        float3 tn = float3(k.xy * 2.0 - 1.0, 0.0); tn.z = sqrt(saturate(1.0 - dot(tn.xy, tn.xy))); tn.x *= -sign(gn.z);
        float3 t = float3(tn.xy + gn.xy, abs(tn.z) * gn.z);
        nsum += t * bw.z; r.albedo += c.rgb * bw.z; r.rough += k.z * bw.z; r.ao += k.w * bw.z;
    }
    r.n = normalize(nsum);
    return r;
}

// O.p0 = rayleigh.xyz, sea   O.p1 = bio.rgb, mie   O.p2 = planet centre (rel), R   O.color = Hr, Hm, texture tint, -
// engine and landing lights: up to four point lights, falling off smoothly to nothing at their radius
float3 pointLights(constant float4* pl, float3 rel, float3 n, float3 albedo) {
    float3 sum = float3(0.0);
    int cnt = int(pl[0].x);
    for (int i = 0; i < cnt; i++) {
        float3 Lv = pl[1 + i].xyz - rel; float d = length(Lv), R = pl[1 + i].w;
        if (d >= R) continue;
        float fall = 1.0 - d / R; fall *= fall;
        float wrap = saturate((dot(n, Lv / d) + 0.25) / 1.25);
        sum += pl[5 + i].rgb * albedo * wrap * fall / (1.0 + d * d / (R * R * 0.02));
    }
    return sum;
}
fragment float4 terrainF(TOut in [[stage_in]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]], constant float4* means [[buffer(3)]], constant float4* pl [[buffer(7)]],
                         texture2d<float> detail [[texture(0)]], texture2d_array<float> albedoArr [[texture(1)]], texture2d_array<float> packArr [[texture(2)]],
                         depth2d_array<float> shadowMap [[texture(5)]], sampler smp [[sampler(0)]]) {
    float3 gn = normalize(in.n);
    float3 w = pow(abs(gn), float3(4.0)); w /= (w.x + w.y + w.z);
    float dist = length(in.rel);
    float f1 = 1.0 - smoothstep(4.0, 30.0, dist), f2 = 1.0 - smoothstep(0.15, 1.2, dist);
    float3 up = normalize(in.rel - O.p2.xyz);
    float3 L = normalize(F.sun.xyz - in.rel), V = normalize(-in.rel);
    bool water = O.p0.w > 0.5 && in.elev <= 0.0;
    float t = F.sun.w;
    float weights[6] = { in.w0.x, in.w0.y, in.w0.z, in.w1.x, in.w1.y, in.w1.z };
    float wsum = in.w0.x + in.w0.y + in.w0.z + in.w1.x + in.w1.y + in.w1.z;
    float nearK = water ? 0.0 : (1.0 - smoothstep(0.6, 6.0, dist)) * saturate(wsum * 1.5);

    float H; float4 d1 = float4(0.5), d2 = float4(0.5);
    if (water) {
        float4 a = tri(detail, smp, in.tri * 16.0 + float3(t * 0.03, 0.0, t * 0.02), w);
        float4 b = tri(detail, smp, in.tri * 48.0 - float3(t * 0.05, t * 0.02, 0.0), w);
        H = ((a.r - 0.5) * 0.0005 + (b.b - 0.5) * 0.00025) * f2;
    } else {
        d1 = tri(detail, smp, in.tri, w);
        d2 = (tri(detail, smp, in.tri * 13.0, w) + tri(detail, smp, in.tri * 29.0 + 0.37, w)) * 0.5;
        H = (d1.g - 0.5) * 0.03 * f1 + (d2.r - 0.5) * 0.0012 * f2 * (1.0 - nearK);
    }
    // bump mapping from screen-space derivatives (large-scale relief)
    float3 dpx = dfdx(in.rel), dpy = dfdy(in.rel); float dhx = dfdx(H), dhy = dfdy(H);
    float3 r1 = cross(dpy, gn), r2 = cross(gn, dpx); float det = dot(dpx, r1);
    float3 n = normalize(abs(det) * gn - sign(det) * (dhx * r1 + dhy * r2));

    // photographic ground textures up close
    float3 texAlb = float3(0.0); float3 texN = float3(0.0); float rough = 0.85, ao = 1.0;
    if (nearK > 0.003) {
        float3 bw = pow(abs(gn), float3(6.0));
        bw = max(bw - min(bw.x, min(bw.y, bw.z)), 0.0) + 1e-5; bw /= (bw.x + bw.y + bw.z);   // weakest plane dropped: at most two samples, still continuous
        // three scales (2.5 m, ~8 m, ~40 m); the larger two are rotated so their tiling never lines up
        float3 pA = in.tri * 20.0;
        float3 pB = float3(in.tri.x * 0.8 - in.tri.z * 0.6, in.tri.y, in.tri.x * 0.6 + in.tri.z * 0.8) * 6.0 + 0.31;
        float3 pC = float3(in.tri.x * 0.6 + in.tri.y * 0.8, in.tri.y * 0.6 - in.tri.x * 0.8, in.tri.z) * 1.25 + 0.57;
        float mixB = 0.3 + (d1.g - 0.5) * 0.5, mixC = 0.25 + (d1.r - 0.5) * 0.4;
        float rs = 0.0, aos = 0.0, tot = 0.0;
        // only the two strongest layers (sharpened so the second one fades out instead of popping)
        uint l0 = 0, l1 = 1; if (weights[1] > weights[0]) { l0 = 1; l1 = 0; }
        for (uint l = 2; l < 6; l++) { if (weights[l] > weights[l0]) { l1 = l0; l0 = l; } else if (weights[l] > weights[l1]) { l1 = l; } }
        float wA = 1.0 - smoothstep(0.1, 0.25, dist);      // the finest scale only matters up close
        float wC = smoothstep(0.06, 0.14, dist);           // the coarsest only farther out: at most ~two scales per pixel
        mixC *= wC;
        for (uint j = 0; j < 2; j++) {
            uint l = j == 0 ? l0 : l1;
            float wl = j == 0 ? 1.0 : saturate((weights[l1] / max(weights[l0], 1e-4)) * 1.4 - 0.2);
            if (wl < 0.03) continue;
            Surf b = sampleLayer(albedoArr, packArr, smp, l, pB, gn, bw);
            Surf cc = b;
            if (wC > 0.01) cc = sampleLayer(albedoArr, packArr, smp, l, pC, gn, bw);
            Surf a = b;
            if (wA > 0.01) { a = sampleLayer(albedoArr, packArr, smp, l, pA, gn, bw); a.albedo = mix(b.albedo, a.albedo, wA); a.n = normalize(mix(b.n, a.n, wA)); a.rough = mix(b.rough, a.rough, wA); a.ao = mix(b.ao, a.ao, wA); }
            float3 c = mix(mix(a.albedo, b.albedo, mixB), cc.albedo, mixC);
            // large-scale brightness from the coarse sample breaks up any remaining repetition
            c *= mix(1.0, 0.8 + 0.4 * dot(cc.albedo, float3(0.33)) / max(dot(means[l].rgb, float3(0.33)), 0.02) * 0.5, wC);
            float3 ratio = clamp(in.col / max(means[l].rgb, float3(0.02)), 0.0, 3.0);
            c *= mix(float3(1.0), ratio, O.color.z);
            texAlb += c * wl; texN += normalize(a.n + b.n * 0.6 + cc.n * 0.4 * wC) * wl;
            rs += mix(a.rough, b.rough, mixB) * wl; aos += mix(a.ao, b.ao, mixB) * wl; tot += wl;
        }
        if (tot > 0.0) {
            texAlb /= tot; rough = rs / tot; ao = aos / tot;
            n = normalize(mix(n, normalize(texN), nearK));
        }
    }

    float cosZ = dot(up, L);
    float3 sunCol = sunTransmit(cosZ, O.p0.xyz, O.color.x, O.p1.w, O.color.y) * F.misc.z;
    float3 skyTint = O.p0.xyz / max(max(O.p0.x, O.p0.y), O.p0.z);
    float dayK = smoothstep(-0.15, 0.25, cosZ);
    float hemi = 0.5 + 0.5 * dot(n, up);
    float3 ambient = skyTint * F.misc.z * (0.07 + 0.09 * hemi) * dayK + float3(0.004, 0.005, 0.008);
    float ndl = max(dot(n, L), 0.0);
    sunCol *= shadowAt(F, shadowMap, in.rel, gn);
    float under = blobShade(F, in.rel);
    sunCol *= 1.0 - 0.8 * under; ambient *= 1.0 - 0.65 * under;
    float3 c;
    if (water) {
        // ---- the sea: wave normals, light absorbed with depth over a sandy seabed, sky reflection, sun glitter, surf
        float depth = max(-in.elev, 0.0) * 1000.0;                        // metres of water under this point
        // waves: a sum of travelling sines with integer frequencies per 1 km, so they tile seamlessly with the terrain
        const float3 kv[8] = { float3(31, 12, -9), float3(-18, 27, 14), float3(9, -14, 33), float3(55, -31, 20),
                               float3(-40, 52, -35), float3(71, 38, -60), float3(-110, 64, 95), float3(150, -120, -90) };
        const float sl[8] = { 0.2, 0.17, 0.15, 0.13, 0.11, 0.09, 0.075, 0.06 };
        float3 grad = float3(0.0);
        float calm = 0.35 + 0.65 * smoothstep(0.3, 6.0, depth);           // smaller waves in the shallows
        for (int i = 0; i < 8; i++) {
            float kl = length(kv[i]), lam = 1000.0 / kl;                 // wavelength, metres
            float fade = 1.0 - smoothstep(lam / 6000.0, lam / 2500.0, dist);   // drop waves too small to see from here
            if (fade <= 0.0) break;                                         // (they're ordered long to short)
            float k = 6.2831853 * kl / 1000.0, om = sqrt(9.8 * k);
            float ph = 6.2831853 * dot(in.tri, kv[i]) / 20.0 + om * t + float(i) * 1.7;
            grad += kv[i] / kl * cos(ph) * sl[i] * fade;
        }
        grad *= calm;
        float3 gt = grad - gn * dot(grad, gn);
        float3 wn = normalize(gn - gt);
        n = normalize(wn + (n - gn) * 0.6);                              // plus the fine ripple texture up close
        float3 Rv = reflect(-V, n);
        if (dot(Rv, up) < 0.0) Rv = normalize(Rv - up * dot(Rv, up) * 1.05);
        float fres = 0.02 + 0.98 * pow(1.0 - saturate(dot(n, V)), 5.0);
        // sky seen in the reflection: hazy and bright at the horizon, deeper blue overhead
        float hz = saturate(dot(Rv, up));
        float3 horizon = mix(skyTint, float3(1.0), 0.35) * 0.19, zenith = skyTint * float3(0.1, 0.14, 0.2);
        float3 skyRefl = mix(horizon, zenith, pow(hz, 0.45)) * F.misc.z * dayK + float3(0.002, 0.003, 0.006);
        // light inside the water: sunlight and skylight, absorbed on the way down and back up
        float3 lightIn = sunCol * saturate(dot(up, L)) * 0.9 + ambient * 2.5;
        float3 T = exp(-depth * float3(0.42, 0.075, 0.045) * 2.0);
        float3 seabed = float3(0.52, 0.47, 0.36) * (0.85 + 0.3 * d1.r);
        float3 scatter = float3(0.008, 0.07, 0.095);
        float3 body = (seabed * T + scatter * (1.0 - T)) * lightIn;
        // sun glitter: sharp up close, a broad shimmering road toward the horizon
        float3 hv = normalize(L + V);
        float ex = mix(900.0, 120.0, smoothstep(0.2, 25.0, dist));
        float glint = pow(saturate(dot(n, hv)), ex) * ex * 0.0035;
        c = body * (1.0 - fres) + skyRefl * fres + sunCol * glint * (0.3 + fres);
        // surf: foam lines washing up the beach and a white fringe at the waterline
        if (depth < 2.5 && dist < 6.0) {
            float nz = tri(detail, smp, in.tri * 9.0 + float3(t * 0.01, 0.0, -t * 0.008), w).r;
            float wash = sin(depth * 4.5 - t * 1.4 + nz * 5.0) * 0.5 + 0.5;
            float foam = (1.0 - smoothstep(0.0, 2.2, depth)) * smoothstep(0.55, 0.95, wash) * smoothstep(0.35, 0.6, nz);
            foam = max(foam, (1.0 - smoothstep(0.0, 0.25, depth)) * smoothstep(0.3, 0.55, nz));
            foam *= 1.0 - smoothstep(2.0, 6.0, dist);
            c = mix(c, float3(0.9, 0.93, 0.95) * lightIn, saturate(foam) * 0.85);
        }
        float night = smoothstep(0.05, -0.25, cosZ);
        float sparkle = smoothstep(0.6, 0.85, tri(detail, smp, in.tri * 6.0 + float3(0.0, t * 0.004, 0.0), w).r) * (0.6 + 0.4 * sin(t * 2.0 + in.tri.x * 40.0));
        c += O.p1.xyz * night * (0.04 + sparkle * 0.9) * (O.p1.x + O.p1.y + O.p1.z > 0.0 ? 1.0 : 0.0);
    } else {
        float bright = 1.0 + (d1.r - 0.5) * 0.55 * f1 + (d2.b - 0.5) * 0.08 * f2 * (1.0 - nearK);
        float3 alb = mix(in.col * bright, texAlb * (1.0 + (d1.r - 0.5) * 0.3), nearK);
        float3 h = normalize(L + V);
        float gloss = mix(8.0, 90.0, saturate(1.0 - rough));
        float spec = pow(max(dot(n, h), 0.0), gloss) * (1.0 - rough) * 0.35 * nearK;
        if (O.p0.w > 0.5) {   // sand darkened and glossy where the waves wash up
            float wet = 1.0 - smoothstep(0.0, 0.0009, in.elev);
            alb *= 1.0 - 0.45 * wet;
            spec += pow(max(dot(n, h), 0.0), 120.0) * 0.6 * wet;
        }
        c = alb * (sunCol * ndl * mix(1.0, ao, 0.4) + ambient * ao) + sunCol * spec * ndl + pointLights(pl, in.rel, n, alb);
    }
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- scanned rocks (instanced)
struct RockInst { float4 posScale; float4 quat; float4 tint; };
struct RockU { float4 sun; float4 sky; float4 up; float4 mean; };   // mean.w = how much to desaturate the photo
float3 qrot(float4 q, float3 v) { float3 t = 2.0 * cross(q.xyz, v); return v + q.w * t + cross(q.xyz, t); }
struct ROut { float4 pos [[position]]; float3 rel; float3 n; float2 uv; float3 tint; float h; float size; };
vertex ROut rockV(uint vid [[vertex_id]], uint iid [[instance_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]],
                  const device RockInst* inst [[buffer(2)]]) {
    uint b = vid * 8; RockInst I = inst[iid];
    float3 p = float3(vb[b], vb[b+1], vb[b+2]);
    float3 w = qrot(I.quat, p * I.posScale.w) + I.posScale.xyz;
    ROut o; o.pos = F.viewProj * float4(w, 1.0); o.rel = w; o.n = qrot(I.quat, float3(vb[b+3], vb[b+4], vb[b+5]));
    o.uv = float2(vb[b+6], vb[b+7]); o.tint = I.tint.rgb; o.h = p.y; o.size = I.posScale.w; return o;
}
// grass clumps: same instancing, plus wind sway that grows toward the blade tips
vertex ROut grassV(uint vid [[vertex_id]], uint iid [[instance_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]],
                   const device RockInst* inst [[buffer(2)]]) {
    uint b = vid * 8; RockInst I = inst[iid];
    float3 p = float3(vb[b], vb[b+1], vb[b+2]);
    float t = vb[b+6], tm = F.sun.w;
    float ph = dot(I.posScale.xyz, float3(1.0, 0.7, 1.3)) * 900.0;
    float2 sway = float2(sin(tm * 1.7 + ph) + 0.4 * sin(tm * 3.1 + ph * 1.7), cos(tm * 1.3 + ph * 0.8)) * 0.06 * t * t;
    p.xz += sway;
    float3 w = qrot(I.quat, p * I.posScale.w) + I.posScale.xyz;
    ROut o; o.pos = F.viewProj * float4(w, 1.0); o.rel = w; o.n = qrot(I.quat, float3(vb[b+3], vb[b+4], vb[b+5]));
    o.uv = float2(t, vb[b+7]); o.tint = I.tint.rgb; o.h = t; o.size = I.posScale.w; return o;
}
fragment float4 grassF(ROut in [[stage_in]], constant Frame& F [[buffer(1)]], constant RockU& U [[buffer(3)]],
                       depth2d_array<float> shadowMap [[texture(5)]]) {
    float3 V = normalize(-in.rel), L = normalize(F.sun.xyz - in.rel), up = U.up.xyz;
    float3 n = normalize(in.n); if (dot(n, V) < 0.0) n = -n;
    float wrap = (max(dot(n, L), 0.0) * 0.5 + max(dot(up, L), 0.0) * 0.5) * 1.15;
    float trans = pow(saturate(dot(-V, L)), 3.0) * 0.6 * in.h;              // sunlight glowing through backlit blades
    float sh = shadowAt(F, shadowMap, in.rel, up);
    float3 albedo = in.tint * mix(0.55, 1.35, in.h) + float3(0.025, 0.022, 0.0) * in.h * in.h;
    float3 ambient = U.sky.rgb * F.misc.z * (0.07 + 0.09 * (0.5 + 0.5 * dot(n, up))) * U.sky.w + float3(0.004, 0.005, 0.008);
    float3 c = albedo * (U.sun.rgb * (wrap + trans) * sh + ambient * mix(0.4, 1.0, in.h));
    c *= 1.0 - 0.7 * blobShade(F, in.rel);
    return float4(c, 1.0);
}

// normal mapping without stored tangents (cotangent frame from screen-space derivatives)
float3 perturbNormal(float3 n, float3 p, float2 uv, float3 tn) {
    float3 dp1 = dfdx(p), dp2 = dfdy(p); float2 duv1 = dfdx(uv), duv2 = dfdy(uv);
    float3 dp2perp = cross(dp2, n), dp1perp = cross(n, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x, B = dp2perp * duv1.y + dp1perp * duv2.y;
    float im = rsqrt(max(max(dot(T, T), dot(B, B)), 1e-30));
    return normalize(T * im * tn.x + B * im * tn.y + n * tn.z);
}
fragment float4 rockF(ROut in [[stage_in]], constant Frame& F [[buffer(1)]], constant RockU& U [[buffer(3)]],
                      texture2d<float> alb [[texture(0)]], texture2d<float> pk [[texture(1)]], depth2d_array<float> shadowMap [[texture(5)]],
                      sampler smp [[sampler(0)]]) {
    float3 tex = alb.sample(smp, in.uv).rgb;
    float lum = dot(tex, float3(0.3, 0.59, 0.11)) / max(dot(U.mean.rgb, float3(0.3, 0.59, 0.11)), 1e-3);
    float3 albedo = mix(tex, U.mean.rgb * lum, U.mean.w) * in.tint;
    float4 k = pk.sample(smp, in.uv);
    float3 tn = float3(k.xy * 2.0 - 1.0, 0.0); tn.y = -tn.y; tn.z = sqrt(saturate(1.0 - dot(tn.xy, tn.xy)));
    float3 gn = normalize(in.n), V = normalize(-in.rel);
    if (dot(gn, V) < 0.0) gn = -gn;
    float3 n = perturbNormal(gn, in.rel, in.uv, tn);
    float3 L = normalize(F.sun.xyz - in.rel);
    float ndl = max(dot(n, L), 0.0);
    // look up the shadow a little toward the sun so a rock smaller than a shadow texel doesn't shade itself
    float sh = shadowAt(F, shadowMap, in.rel + L * (in.size * 0.8 + 0.0008), gn);
    float rough = k.z; float3 h = normalize(L + V);
    float spec = pow(max(dot(n, h), 0.0), mix(8.0, 64.0, 1.0 - rough)) * (1.0 - rough) * 0.3;
    float hemi = 0.5 + 0.5 * dot(n, U.up.xyz);
    // sky light from above plus sunlight bounced off the ground below
    float3 ambient = U.sky.rgb * F.misc.z * (0.10 + 0.14 * hemi) * U.sky.w + U.sun.rgb * max(dot(U.up.xyz, L), 0.0) * 0.12 * (1.0 - hemi)
                   + float3(0.004, 0.005, 0.008);
    float ao = mix(0.45, 1.0, saturate(in.h * 3.0));          // darker where the rock meets the ground
    float3 c = albedo * (U.sun.rgb * ndl * sh + ambient * ao) + U.sun.rgb * spec * ndl * sh;
    c *= 1.0 - 0.7 * blobShade(F, in.rel);
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- unit-sphere based objects (sun, clouds)
struct SOut { float4 pos [[position]]; float3 rel; float3 lp; };
vertex SOut sphereV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]]) {
    float3 p = float3(vb[vid*3], vb[vid*3+1], vb[vid*3+2]);
    float4 w = O.model * float4(p, 1.0);
    SOut o; o.pos = F.viewProj * w; o.rel = w.xyz; o.lp = p; return o;
}
fragment float4 emissiveF(SOut in [[stage_in]], constant Obj& O [[buffer(2)]]) { return float4(O.color.rgb, 1.0); }

// O.p0 = sunDir from planet centre, cover   O.p1 = rayleigh, -   O.color = cloud colour, alpha scale   O.p2.x = time
fragment float4 cloudF(SOut in [[stage_in]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]]) {
    float3 n = normalize(in.lp);
    float camD = length(in.rel);
    int oct = camD < 30.0 ? 10 : (camD < 120.0 ? 8 : (camD < 500.0 ? 6 : 5));
    float t = F.sun.w;
    float3 q = n * 2.6 + float3(t * 0.0015, 0.0, 0.0);
    q += 0.45 * float3(fbn(n * 2.0 + 3.1, 4), fbn(n * 2.0 + 7.3, 4), fbn(n * 2.0 + 11.7, 4));
    float d = fbn(q * 2.2, oct);
    if (camD < 60.0) d += (fbn(n * 380.0 + t * 0.002, 4) - 0.5) * 0.12 * (1.0 - smoothstep(20.0, 60.0, camD));   // billows up close
    float lat = abs(n.y);
    d += smoothstep(0.15, 0.0, abs(lat - 0.12)) * 0.06 + smoothstep(0.55, 0.75, lat) * 0.05;
    float cov = O.p0.w;
    float a = smoothstep(cov, cov + 0.12, d);
    float thick = smoothstep(cov, cov + 0.35, d);
    float cosZ = dot(n, O.p0.xyz);
    float3 sunCol = sunTransmit(cosZ, O.p1.xyz, 8.0, 0.002, 1.2) * F.misc.z;
    float3 skyAmb = O.p1.xyz / max(max(O.p1.x, O.p1.y), O.p1.z) * F.misc.z * 0.12 * smoothstep(-0.2, 0.2, cosZ);
    // bright sunlit tops, grey self-shadowed undersides, a soft silver lining at the edges
    float3 c = O.color.rgb * (sunCol * mix(0.85, 0.42, thick) + skyAmb) + sunCol * (1.0 - thick) * a * 0.18;
    float fade = smoothstep(0.15, 1.5, camD);          // only vanish when you're right inside them
    float alpha = a * mix(0.75, 0.97, thick) * fade;
    return float4(c * alpha, alpha);   // premultiplied
}

// ---------------------------------------------------------------- stars (points at infinity)
struct StarOut { float4 pos [[position]]; float size [[point_size]]; float3 col; };
vertex StarOut starV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]]) {
    float3 d = float3(vb[vid*6], vb[vid*6+1], vb[vid*6+2]);
    float3 v = (F.view * float4(d, 0.0)).xyz;
    StarOut o; o.pos = F.proj * float4(v, 0.0); o.pos.z = 0.0;
    o.size = 2.0 * F.misc.w * 0.0 + 2.2; o.col = float3(vb[vid*6+3], vb[vid*6+4], vb[vid*6+5]) * F.misc.y;
    return o;
}
// ---------------------------------------------------------------- the nebula sky (equirectangular panorama), faded out by daylight
struct SkyOut { float4 pos [[position]]; float2 ndc; };
vertex SkyOut skyV(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o; o.pos = float4(p, 0.0, 1.0); o.ndc = p; return o;
}
fragment float4 skyF(SkyOut in [[stage_in]], constant Frame& F [[buffer(1)]], texture2d<float> sky [[texture(0)]], sampler smp [[sampler(0)]]) {
    float4 w = F.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 d = normalize(w.xyz / w.w);
    float2 uv = float2(atan2(d.x, -d.z) / 6.2831853 + 0.5, acos(clamp(d.y, -1.0, 1.0)) / 3.14159265);
    float3 c = sky.sample(smp, uv).rgb;
    return float4(c * 0.55 * F.misc.y, 0.0);
}
fragment float4 starF(StarOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5); float a = smoothstep(0.5, 0.05, d);
    return float4(in.col * a, 1.0);
}

// ---------------------------------------------------------------- ship (physically-inspired metal / paint)
struct ShOut { float4 pos [[position]]; float3 rel; float3 n; float2 uv; float mat; float3 op; float3 on; };
vertex ShOut shipV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]]) {
    uint b = vid * 9;
    float3 p = float3(vb[b], vb[b+1], vb[b+2]), nn = float3(vb[b+3], vb[b+4], vb[b+5]);
    float4 w = O.model * float4(p, 1.0);
    ShOut o; o.pos = F.viewProj * w; o.rel = w.xyz; o.n = (O.model * float4(nn, 0.0)).xyz; o.uv = float2(vb[b+6], vb[b+7]); o.mat = vb[b+8];
    o.op = p; o.on = nn; return o;
}
// a skinned character: each vertex blends up to four joint matrices
vertex ShOut skinV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]],
                   const device float4x4* bones [[buffer(3)]], const device float* wt [[buffer(5)]]) {
    uint b = vid * 9, k = vid * 8;
    float3 p = float3(vb[b], vb[b+1], vb[b+2]), nn = float3(vb[b+3], vb[b+4], vb[b+5]);
    float4x4 M = bones[uint(wt[k])] * wt[k+4] + bones[uint(wt[k+1])] * wt[k+5] + bones[uint(wt[k+2])] * wt[k+6] + bones[uint(wt[k+3])] * wt[k+7];
    float3 sp = (M * float4(p, 1.0)).xyz, sn = normalize((M * float4(nn, 0.0)).xyz);
    float4 w = O.model * float4(sp, 1.0);
    ShOut o; o.pos = F.viewProj * w; o.rel = w.xyz; o.n = (O.model * float4(sn, 0.0)).xyz; o.uv = float2(vb[b+6], vb[b+7]); o.mat = vb[b+8];
    o.op = sp; o.on = sn; return o;
}
// the light around a ship: a sky that brightens toward the horizon, sunlit ground below, and the sun's glare.
// rough = 1 gives the blurred (irradiance-like) version used for ambient light.
float3 shipEnv(float3 d, float3 L, float3 up, float3 skyTint, float day, float rough) {
    float h = dot(d, up);
    float3 zenith = skyTint * float3(0.42, 0.5, 0.62), horizon = mix(skyTint, float3(1.0), 0.45) * 0.75;
    float3 sky = mix(horizon, zenith, pow(saturate(h), mix(0.5, 1.0, rough)));
    float3 ground = float3(0.34, 0.3, 0.24) * (0.35 + 0.65 * saturate(dot(L, up)));   // sunlit terrain bouncing light up
    float3 c = mix(ground, sky, smoothstep(-0.12 - rough * 0.5, 0.06 + rough * 0.5, h));
    float sunLobe = pow(saturate(dot(d, L)), mix(400.0, 4.0, rough)) * mix(6.0, 0.6, rough);
    return (c * day + float3(0.012, 0.014, 0.02)) + float3(1.0, 0.95, 0.85) * sunLobe * day;
}
float3 envColor(float3 r, float3 L, float3 up, float3 skyTint, float day) {
    float h = dot(r, up);
    float3 sky = mix(float3(0.02, 0.025, 0.035), skyTint * 0.6, day) * smoothstep(-0.3, 0.4, h) + float3(0.03, 0.028, 0.025) * smoothstep(0.2, -0.6, h);
    return sky + float3(6.0, 5.6, 5.0) * pow(max(dot(r, L), 0.0), 60.0);
}
// O.p0 = afterburner, sun intensity scale, power, cockpit   O.p1 = planet up (rel, normalised), day   O.p2 = sky tint, hull detail   O.color = sun colour at ship
fragment float4 shipF(ShOut in [[stage_in]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]], constant float4* carve [[buffer(4)]], constant float4* pl [[buffer(7)]],
                      texture2d<float> paint [[texture(0)]], texture2d<float> vent [[texture(1)]], texture2d<float> screens [[texture(2)]], texture2d<float> skinA [[texture(3)]], texture2d<float> skinN [[texture(4)]], depth2d_array<float> shadowMap [[texture(5)]], texture2d<float> skinE [[texture(6)]], sampler smp [[sampler(0)]]) {
    float3 n = normalize(in.n), V = normalize(-in.rel);
    if (dot(n, V) < 0.0) n = -n;
    float3 L = normalize(F.sun.xyz - in.rel);
    int m = int(in.mat + 0.5);
    if ((m == 3 || m == 20) && O.p0.w > 0.5 && O.p0.w < 1.5) discard_fragment();
    if (m == 20 && O.p0.w > 1.5 && O.p0.w < 2.05) { discard_fragment(); return float4(0.0); }      // cockpit view: look through the canopy
    if (O.p0.w > 0.5 && O.p0.w < 2.5) {
        // walking aboard (or a model canopy in cockpit view): open the canopy glass, and cut the hull away behind the windows and inside the cabins
        if (m == 3 && O.p0.w < 2.05) { discard_fragment(); return float4(0.0); }
        int nc = int(carve[0].x);
        float3 ap = float3(abs(in.op.x), in.op.y, in.op.z);
        for (int i = 0; i < nc; i++) {
            if (all(ap > carve[1 + i].xyz) && all(ap < carve[9 + i].xyz)) { discard_fragment(); return float4(0.0); }
        }
    }
    float ab = O.p0.x, pw = O.p0.z;
    float3 albedo = float3(0.5); float metal = 0.3, rough = 0.5; float3 emis = float3(0.0);
    if (m == 0) {
        float hd = max(O.p2.w, 1.0);
        albedo = paint.sample(smp, in.uv * 1.6).rgb; metal = 0.55; rough = 0.42;
        if (hd > 1.5) {
            // big hulls: fine panels mapped on the dominant model axis (no streaks on the sides), broken up by a
            // large-scale wash, plus rows of small lit windows along the flanks, so the hull reads at its real size
            float3 an = abs(in.on);
            float2 tuv = an.x > an.y && an.x > an.z ? in.op.zy : (an.y > an.z ? in.op.xz : in.op.xy);
            albedo = paint.sample(smp, tuv * 1.6 * hd).rgb;
            float big = dot(paint.sample(smp, tuv * 0.23 + 0.37).rgb, float3(0.333));
            albedo *= mix(0.78, 1.12, saturate(big / 0.5));
            rough = 0.36 + 0.14 * big;
            if (an.x > 0.7 && abs(in.op.x) < 0.24) {
                float2 cell = float2(in.op.z / 0.011, in.op.y / 0.016);
                float2 f = fract(cell), id = floor(cell);
                float hsh = fract(sin(dot(id, float2(12.9898, 78.233))) * 43758.5453);
                float win = step(0.3, f.x) * step(f.x, 0.75) * step(0.35, f.y) * step(f.y, 0.62) * step(0.58, hsh);
                albedo = mix(albedo, float3(0.02), win);
                emis += win * mix(float3(2.2, 1.7, 1.1), float3(0.9, 1.6, 2.4), step(0.93, hsh)) * 0.28 * (0.05 + 0.95 * pw);
            }
        }
    }
    else if (m == 1) { albedo = float3(0.042, 0.05, 0.065); metal = 0.8; rough = 0.35; }
    else if (m == 2) { albedo = float3(0.007, 0.008, 0.012); metal = 0.7; rough = 0.5; }
    else if (m == 3) { albedo = float3(0.002, 0.003, 0.005); metal = 1.0; rough = 0.06; emis = float3(0.004, 0.024, 0.09) * 0.6; }
    else if (m == 4) { float4 tv = vent.sample(smp, in.uv); albedo = tv.rgb * 0.3; emis = tv.rgb * (1.8 + ab * 3.5) * (0.03 + 0.97 * pw); rough = 0.6; }
    else if (m == 5) { albedo = float3(0.0); emis = float3(1.6, 2.0, 2.8) * (0.04 + 0.96 * pw); }
    else if (m == 6) { albedo = float3(0.80, 0.78, 0.74); metal = 0.0; rough = 0.75; }                 // suit fabric
    else if (m == 7) { albedo = float3(1.0, 0.2, 0.05); metal = 0.0; rough = 0.5; emis = float3(0.05, 0.01, 0.0); }
    else if (m == 8) { albedo = float3(0.0); emis = float3(0.4, 2.2, 2.4); }                             // suit lights
    else if (m == 9) { albedo = float3(0.55, 0.38, 0.12); metal = 1.0; rough = 0.08; }                  // gold visor
    else if (m == 11) { albedo = float3(0.01); metal = 0.2; rough = 0.15; emis = screens.sample(smp, in.uv).rgb * 1.3 * (0.05 + 0.95 * pw); }   // cockpit display
    else if (m == 21) {
        // a lift car's window onto its shaft: dark glass with the shaft's light rings streaming past while it moves
        float3 pm = in.op * O.p2.w;
        float run = O.p6.x, moving = O.p6.y;
        // the shaft's light bars sweep past the glass as the car travels (run = metres travelled)
        float along = pm.x + pm.z;                                         // along the wall
        float bars = smoothstep(0.86, 0.96, fract(along * 0.45 - run * 0.45)) ;
        float rails = smoothstep(0.9, 1.0, fract(pm.y * 1.4)) * 0.5;      // the shaft's guide rails behind the glass
        float blur = mix(1.0, 0.5, moving);                                  // fast: the bars smear into streaks
        albedo = float3(0.01); metal = 0.0; rough = 0.08;
        emis = (float3(0.4, 2.2, 3.2) * bars * blur * (0.35 + 0.65 * moving) + float3(0.05, 0.25, 0.35) * moving * 0.5
               + float3(0.03, 0.06, 0.09) * (1.0 + rails)) * (0.08 + 0.92 * pw);
    }
    else if (m >= 17) {
        // a hull modelled in Blender: baked colour + roughness, and a baked object-space normal map
        float4 a = skinA.sample(smp, in.uv);
        float3 on = skinN.sample(smp, in.uv).xyz * 2.0 - 1.0;
        float3 wn = normalize((O.model * float4(on, 0.0)).xyz);
        if (dot(wn, V) < -0.2) wn = n;                 // guard against the odd mismatched texel
        n = wn;
        emis += skinE.sample(smp, in.uv).rgb * O.p5.x;          // baked glow: windows, screens, lights
        if (m == 19) { albedo = float3(0.05, 0.02, 0.0); rough = 0.6; emis = float3(1.6, 0.6, 0.12) * (0.05 + 0.95 * pw) * (1.0 + ab * 1.5); }
        else {
            albedo = a.rgb; rough = clamp(a.a, 0.06, 1.0);
            float4 nm = skinN.sample(smp, in.uv);
            metal = nm.a >= 0.25 ? saturate((nm.a - 0.5) * 2.0) : (m == 18 ? 0.9 : 0.05);   // the model's own metal map when it has one
        }
    }
    else if (m >= 13) {
        // ship interior: dark sci-fi panels, glossy floors with faint light lines, flowing LED strips
        float3 pm = in.op * O.p2.w;                                  // metres
        float t = F.sun.w;
        if (m == 13) {
            float2 q = float2(abs(n.x) > 0.5 ? pm.z : pm.x, pm.y);
            float2 g = abs(fract(q * float2(0.42, 0.55)) - 0.5);
            float seam = smoothstep(0.46, 0.5, max(g.x, g.y));
            float tone = fract(sin(dot(floor(q * float2(0.42, 0.55)), float2(12.9898, 78.233))) * 43758.5453);
            albedo = mix(float3(0.11, 0.12, 0.145) * (0.85 + 0.3 * tone), float3(0.03, 0.035, 0.045), seam); metal = 0.55; rough = 0.32;
            emis += float3(0.05, 0.45, 0.7) * smoothstep(0.485, 0.5, g.y) * step(0.8, tone) * (0.05 + 0.95 * pw);     // a few lit seams
        } else if (m == 14) {
            float2 g = abs(fract(pm.xz * 0.5) - 0.5);
            float line = smoothstep(0.47, 0.5, max(g.x, g.y));
            albedo = float3(0.035, 0.04, 0.05); metal = 0.6; rough = 0.22;
            emis += float3(0.02, 0.2, 0.32) * line * (0.05 + 0.95 * pw);
        } else if (m == 15) { albedo = float3(0.09, 0.26, 0.07); metal = 0.0; rough = 0.8; }
        else {   // LED strip: a cyan-to-violet glow with pulses running along it
            float along = (pm.x + pm.z) * 0.35 + pm.y * 0.2;
            float3 c1 = float3(0.05, 0.85, 1.45), c2 = float3(0.75, 0.2, 1.5);
            float3 c = mix(c1, c2, 0.5 + 0.5 * sin(along * 0.15 + t * 0.3));
            emis = c * (0.75 + 0.55 * pow(0.5 + 0.5 * sin(along * 1.3 - t * 3.0), 6.0)) * (0.06 + 0.94 * pw);
            albedo = float3(0.0); metal = 0.0; rough = 1.0;
        }
        float3 lights = float3(0.75, 0.86, 1.0) * (0.45 + 0.55 * saturate(n.y * 0.5 + 0.5));
        float3 sky = O.p2.xyz * 0.5 + 0.25;
        if (m != 16) emis += albedo * (lights * 0.55 + sky * O.p1.w * 0.25) * (0.08 + 0.92 * pw);
    }
    else if (m == 12) { albedo = float3(0.1); emis = (O.p0.w > 2.5 ? float3(1.1, 1.3, 1.6) : float3(2.6, 2.1, 1.5)) * (0.05 + 0.95 * pw); }                                          // warm lamp
    else if (m == 10) { albedo = float3(0.12, 0.04, 0.2); metal = 0.3; rough = 0.1; emis = float3(1.2, 0.45, 2.4) * (0.7 + 0.3 * sin(F.sun.w * 1.7 + in.op.y * 0.4)); }  // glowing crystal
    if (O.p0.w > 2.5 && (m < 13 || (m >= 17 && m != 21))) {   // furniture, trim and models inside the ship catch the ceiling lights too
        float3 lights = float3(0.75, 0.86, 1.0) * (0.45 + 0.55 * saturate(n.y * 0.5 + 0.5));
        emis += max(albedo, float3(0.04)) * lights * (m >= 17 ? 0.22 : 0.6) * (0.08 + 0.92 * pw);   // baked models already carry their own shading
    }
    float ndl = max(dot(n, L), 0.0);
    float3 h = normalize(L + V);
    float a2 = max(rough * rough, 0.002); a2 *= a2;
    float nh = max(dot(n, h), 0.0); float dd = nh * nh * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * dd * dd);
    float3 F0 = mix(float3(0.04), albedo, metal);
    float3 Fs = F0 + (1.0 - F0) * pow(1.0 - max(dot(h, V), 0.0), 5.0);
    float k = (rough + 1.0) * (rough + 1.0) / 8.0;
    float G = (ndl / (ndl * (1.0 - k) + k)) * (max(dot(n, V), 0.0) / (max(dot(n, V), 0.0) * (1.0 - k) + k) + 1e-4);
    float3 spec = D * Fs * G / max(4.0 * ndl * max(dot(n, V), 0.0), 1e-3);
    float3 sunC = O.color.rgb * shadowAt(F, shadowMap, in.rel, n);
    float3 direct = ((1.0 - metal) * albedo / PI + spec) * sunC * ndl;
    float3 r = reflect(-V, n);
    float3 up = O.p1.xyz; float day = max(O.p1.w, 0.22);   // never pitch black: in space the lit planet still fills the shadows (earthshine)
    // image-based light, cheaply: reflections blur with roughness; ambient comes from the hemisphere the surface faces
    float3 env = shipEnv(r, L, up, O.p2.xyz, day, rough) * O.p0.y;
    float3 irr = shipEnv(n, L, up, O.p2.xyz, day, 1.0) * O.p0.y;
    float nv = max(dot(n, V), 0.0);
    float3 Fr = F0 + (max(float3(1.0 - rough), F0) - F0) * pow(1.0 - nv, 5.0);
    float envK = m == 17 ? 0.75 : 1.0;
    // ambient falls off in crevices and on faces turned from the sky, so forms keep their shape
    float occl = 0.55 + 0.45 * saturate(dot(n, up) * 0.5 + 0.5);
    float3 c = direct * 1.15 + env * Fr * envK * 1.2 * occl + (1.0 - metal) * albedo * irr * 0.5 * occl + emis + pointLights(pl, in.rel, n, max(albedo, float3(0.04)) * (1.0 - metal * 0.6));
    return float4(c, 1.0);
}

// ---------------------------------------------------------------- engine flames
struct PlOut { float4 pos [[position]]; float2 uv; float3 n; float3 v; };
vertex PlOut plumeV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]], constant Obj& O [[buffer(2)]]) {
    uint b = vid * 8;
    float4 w = O.model * float4(vb[b], vb[b+1], vb[b+2], 1.0);
    PlOut o; o.pos = F.viewProj * w; o.uv = float2(vb[b+6], vb[b+7]);
    o.n = normalize((O.model * float4(vb[b+3], vb[b+4], vb[b+5], 0.0)).xyz); o.v = normalize(-w.xyz);
    return o;
}
// O.p0 = power, afterburner, time   O.p1/p2/color = cool edge, cool core, hot   (hot core is white)
fragment float4 plumeF(PlOut in [[stage_in]], constant Obj& O [[buffer(2)]]) {
    // exhaust: white-hot at the nozzle, the engine's colour through the body of the flame, fading soft at the edges and tail
    float along = 1.0 - in.uv.y;                                   // 1 at the nozzle, 0 at the tail
    float facing = abs(dot(in.n, in.v));
    float core = pow(facing, 2.2);                                 // bright down the middle, soft at the rim
    float uAB = O.p0.y, t = O.p0.z;
    float3 edge = O.p1.rgb, body = O.p2.rgb, hot = O.color.rgb;
    float3 col = mix(edge, body, core);
    col = mix(col, mix(body, hot, 0.6), uAB * core);
    col += float3(1.8, 1.7, 1.6) * pow(core, 4.0) * smoothstep(0.7, 1.0, along) * (1.2 + uAB);   // white-hot throat
    float flicker = 0.9 + 0.1 * sin(t * 41.0 + in.uv.x * 30.0) * (1.0 - along);
    float diamonds = 1.0 + (0.25 + uAB * 1.1) * smoothstep(0.6, 1.0, sin(along * 30.0 - t * 26.0)) * smoothstep(0.2, 0.7, along) * core;
    // soft volumetric edges and streaks running down the flame
    float rim = smoothstep(0.05, 0.6, facing);
    float streaks = 0.75 + 0.25 * sin(in.uv.x * 6.2831853 * 7.0 + along * 4.0 - t * 2.0) * sin(in.uv.x * 6.2831853 * 3.0 - t * 1.3);
    float a = pow(along, 1.6) * rim * (0.05 + core * 0.95) * O.p0.x * diamonds * flicker * streaks;
    return float4(col * a * 0.75, 0.0);
}
fragment float4 nozzleF(PlOut in [[stage_in]], constant Obj& O [[buffer(2)]]) {
    // the nozzle mouth: a white-hot centre shading out to the engine colour at the rim
    float r = in.uv.x, k = O.p0.x;
    float3 rim = O.p1.rgb, hot = mix(O.p1.rgb, float3(max(O.p1.r, max(O.p1.g, O.p1.b))), 0.7) * 1.6;
    float3 c = mix(hot * 3.0, rim * 1.6, smoothstep(0.0, 0.75, r)) * (1.0 - smoothstep(0.82, 1.0, r));
    c += rim * 0.8 * exp(-pow((r - 0.9) * 9.0, 2.0));               // a bright ring just inside the lip
    return float4(c * k, 0.0);
}

// ---------------------------------------------------------------- camera-facing glows (instanced)
struct GlowIn { float4 posSize; float4 color; };
struct GOut { float4 pos [[position]]; float2 uv; float4 color; };
vertex GOut glowV(uint vid [[vertex_id]], uint iid [[instance_id]], const device GlowIn* g [[buffer(0)]], constant Frame& F [[buffer(1)]]) {
    float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(1,1), float2(-1,-1), float2(1,1), float2(-1,1) };
    float2 c = corners[vid];
    float3 vc = (F.view * float4(g[iid].posSize.xyz, 1.0)).xyz + float3(c * g[iid].posSize.w, 0.0);
    GOut o; o.pos = F.proj * float4(vc, 1.0); o.uv = c; o.color = g[iid].color; return o;
}
fragment float4 glowF(GOut in [[stage_in]]) {
    // a light: a white-hot pinpoint, a coloured bloom falling off like real scatter, and a faint lens streak
    float r = length(in.uv);
    float core = exp(-r * r * 90.0);
    float halo = exp(-r * 5.0) * 0.55 + exp(-r * r * 9.0) * 0.35;
    float streak = exp(-abs(in.uv.y) * 55.0) * exp(-abs(in.uv.x) * 2.2) * 0.35;
    float edge = 1.0 - smoothstep(0.75, 1.0, r);
    float3 col = in.color.rgb;
    float3 hot = mix(col, float3(max(col.r, max(col.g, col.b))) * 1.2, 0.75);   // the centre burns toward white
    float3 c = (hot * core * 4.0 + col * halo + col * streak) * edge;
    if (in.color.a < 0.0) {   // soft puffs (dust, vapour, plasma, haloes): no hot centre, no streak
        float puff = r < 0.18 ? mix(1.0, 0.7, r / 0.18) : (r < 0.45 ? mix(0.7, 0.16, (r - 0.18) / 0.27) : mix(0.16, 0.0, saturate((r - 0.45) / 0.55)));
        return float4(col * puff * -in.color.a, 0.0);
    }
    return float4(c * in.color.a, 0.0);
}

// ---------------------------------------------------------------- speed streaks (camera space lines)
struct LOut { float4 pos [[position]]; };
vertex LOut streakV(uint vid [[vertex_id]], const device float* vb [[buffer(0)]], constant Frame& F [[buffer(1)]]) {
    LOut o; o.pos = F.proj * float4(vb[vid*3], vb[vid*3+1], vb[vid*3+2], 1.0); return o;
}
fragment float4 streakF(LOut in [[stage_in]], constant float4& c [[buffer(0)]]) { return float4(c.rgb * c.a, 0.0); }

// ---------------------------------------------------------------- full-screen passes
struct QOut { float4 pos [[position]]; float2 uv; };
vertex QOut quadV(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    QOut o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); o.uv = float2(p.x, 1.0 - p.y); return o;
}

// physically based atmosphere: single scattering (Rayleigh + Mie) with planet shadow, applied over the scene
struct AtmoPlanet { float4 centerR; float4 topHrHmG; float4 rayleigh; float4 mieTint; };
struct AtmoOut { float4 add [[color(0), index(0)]]; float4 mul [[color(0), index(1)]]; };
float2 raySphere(float3 o, float3 d, float3 c, float r) {
    float3 oc = o - c; float b = dot(oc, d); float cc = dot(oc, oc) - r * r; float h = b * b - cc;
    if (h < 0.0) return float2(1e30, -1e30);
    h = sqrt(h); return float2(-b - h, -b + h);
}
fragment AtmoOut atmoF(QOut in [[stage_in]], depth2d<float> depthTex [[texture(0)]], constant Frame& F [[buffer(0)]],
                       constant AtmoPlanet* planets [[buffer(1)]], constant int& count [[buffer(2)]]) {
    float2 ndc = float2(in.uv.x * 2.0 - 1.0, (1.0 - in.uv.y) * 2.0 - 1.0);
    float4 p4 = F.invViewProj * float4(ndc, 0.5, 1.0);
    float3 dir = normalize(p4.xyz / p4.w);
    float d = depthTex.read(uint2(in.pos.xy));
    float sceneDist = d > 0.0 ? (F.misc.w / d) / max(dot(dir, F.camFwd.xyz), 1e-4) : 1e30;
    float3 inscatter = float3(0.0), trans = float3(1.0);
    for (int k = 0; k < count; k++) {
        AtmoPlanet P = planets[k];
        float3 c = P.centerR.xyz; float R = P.centerR.w, top = P.topHrHmG.x, Hr = P.topHrHmG.y, Hm = P.topHrHmG.z, g = P.topHrHmG.w;
        float2 ta = raySphere(float3(0.0), dir, c, R + top);
        if (ta.x > ta.y || ta.y < 0.0) continue;
        float2 tp = raySphere(float3(0.0), dir, c, R * 0.996);
        float t0 = max(ta.x, 0.0), t1 = min(ta.y, sceneDist);
        if (tp.x > 0.0 && tp.x < tp.y) t1 = min(t1, tp.x);
        if (t1 <= t0) continue;
        float3 L = normalize(F.sun.xyz - c);
        float3 bR = P.rayleigh.xyz, bM = float3(P.rayleigh.w) * P.mieTint.xyz;
        int N = int(mix(5.0, 16.0, saturate((t1 - t0) / (top * 3.0)))); float ds = (t1 - t0) / float(N);   // short paths need fewer steps
        float odR = 0.0, odM = 0.0; float3 sumR = float3(0.0), sumM = float3(0.0);
        for (int i = 0; i < N; i++) {
            float3 x = dir * (t0 + (float(i) + 0.5) * ds);
            float h = length(x - c) - R;
            float dR = exp(-h / Hr) * ds, dM = exp(-h / Hm) * ds;
            odR += dR; odM += dM;
            // light path to the sun; points in the planet's shadow receive nothing
            float2 ls = raySphere(x, L, c, R + top);
            float2 lp = raySphere(x, L, c, R * 0.998);
            if (lp.x > 0.0 && lp.x < lp.y) continue;
            const int M = 5; float lds = max(ls.y, 0.0) / float(M), lR = 0.0, lM = 0.0;
            for (int j = 0; j < M; j++) {
                float lh = length(x + L * ((float(j) + 0.5) * lds) - c) - R;
                lR += exp(-lh / Hr) * lds; lM += exp(-lh / Hm) * lds;
            }
            float3 T = exp(-(bR * (odR + lR) + bM * 1.1 * (odM + lM)));
            sumR += dR * T; sumM += dM * T;
        }
        float mu = dot(dir, L);
        float phR = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
        float g2 = g * g;
        float phM = 3.0 / (8.0 * PI) * ((1.0 - g2) * (1.0 + mu * mu)) / ((2.0 + g2) * pow(1.0 + g2 - 2.0 * g * mu, 1.5));
        inscatter += trans * (sumR * bR * phR + sumM * bM * phM) * F.misc.z * 3.4;
        trans *= exp(-(bR * odR + bM * 1.1 * odM));
    }
    AtmoOut o; o.add = float4(inscatter, 0.0); o.mul = float4(trans, 1.0); return o;
}

// bloom: bright pass, dual-filter blur down and up, then ACES tone mapping
fragment float4 brightF(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4& P [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 hp = P.xy;
    float3 c = (t.sample(s, in.uv + hp * float2(-1, -1)).rgb + t.sample(s, in.uv + hp * float2(1, -1)).rgb +
                t.sample(s, in.uv + hp * float2(-1, 1)).rgb + t.sample(s, in.uv + hp * float2(1, 1)).rgb) * 0.25;
    c = min(c, float3(200.0));
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    return float4(c * smoothstep(P.z, P.z + 1.2, l), 1.0);
}
fragment float4 downF(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4& P [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 hp = P.xy;
    float3 c = t.sample(s, in.uv).rgb * 4.0 + t.sample(s, in.uv + hp * float2(-1, -1)).rgb + t.sample(s, in.uv + hp * float2(1, -1)).rgb +
               t.sample(s, in.uv + hp * float2(-1, 1)).rgb + t.sample(s, in.uv + hp * float2(1, 1)).rgb;
    return float4(c / 8.0, 1.0);
}
fragment float4 upF(QOut in [[stage_in]], texture2d<float> t [[texture(0)]], constant float4& P [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 hp = P.xy;
    float3 c = t.sample(s, in.uv + hp * float2(-2, 0)).rgb + t.sample(s, in.uv + hp * float2(2, 0)).rgb +
               t.sample(s, in.uv + hp * float2(0, -2)).rgb + t.sample(s, in.uv + hp * float2(0, 2)).rgb +
               (t.sample(s, in.uv + hp * float2(-1, -1)).rgb + t.sample(s, in.uv + hp * float2(1, -1)).rgb +
                t.sample(s, in.uv + hp * float2(-1, 1)).rgb + t.sample(s, in.uv + hp * float2(1, 1)).rgb) * 2.0;
    return float4(c / 12.0, 1.0);
}
float3 RRTAndODTFit(float3 v) { float3 a = v * (v + 0.0245786) - 0.000090537; float3 b = v * (0.983729 * v + 0.4329510) + 0.238081; return a / b; }
float3 aces(float3 c) {
    const float3x3 inM = float3x3(float3(0.59719, 0.07600, 0.02840), float3(0.35458, 0.90834, 0.13383), float3(0.04823, 0.01566, 0.83777));
    const float3x3 outM = float3x3(float3(1.60475, -0.10208, -0.00327), float3(-0.53108, 1.10813, -0.07276), float3(-0.07367, -0.00605, 1.07602));
    return saturate(outM * RRTAndODTFit(inM * c));
}
fragment float4 compositeF(QOut in [[stage_in]], texture2d<float> hdr [[texture(0)]], texture2d<float> bloom [[texture(1)]], constant float4& P [[buffer(0)]], constant float4& P2 [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // contrast-adaptive sharpening: restores the crispness lost to upscaling and filtering, without halos
    float2 dx = float2(P.z, 0.0), dy = float2(0.0, P2.x);
    float3 c0 = hdr.sample(s, in.uv).rgb;
    float3 cn = hdr.sample(s, in.uv - dy).rgb, cs = hdr.sample(s, in.uv + dy).rgb, cw = hdr.sample(s, in.uv - dx).rgb, ce = hdr.sample(s, in.uv + dx).rgb;
    float3 mn = min(c0, min(min(cn, cs), min(cw, ce))), mx = max(c0, max(max(cn, cs), max(cw, ce)));
    float3 amp = sqrt(saturate(min(mn, 2.0 - mx) / max(mx, 1e-4)));
    float3 w = -amp * mix(0.08, 0.2, saturate(P.w));
    float3 c = (c0 + (cn + cs + cw + ce) * w) / (1.0 + 4.0 * w);
    c = max(c, 0.0) + bloom.sample(s, in.uv).rgb * P.x;
    // tone map: ACES, then win back the saturation it removes and add a gentle S-curve for contrast
    c = aces(c * P.y / 0.6);
    float l = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = max(mix(float3(l), c, 1.1), 0.0);
    c = saturate(c + (c - c * c) * 0.22 * (c - 0.5) * 2.0 + 0.0);
    c = mix(c, c * c * (3.0 - 2.0 * c), 0.25);
    float2 q = in.uv - 0.5; c *= 1.0 - dot(q, q) * 0.18;
    return float4(c, 1.0);
}
"""#
