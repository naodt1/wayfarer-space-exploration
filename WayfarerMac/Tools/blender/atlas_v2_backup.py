# Wayfarer · Atlas, a 1 km heavy carrier, rebuilt as a hard-surface model.
# Keeps the in-game Atlas's footprint so the walkable decks still fit: the hull outline and thickness, the flat keel
# under the cargo lift, the lounge windows on both flanks, the bridge tower and its glass bubble, the nacelles and the
# 2×2 engine cluster all sit where Atlas.swift / Interior.swift expect them.
#
# Run:  Blender -b -P atlas.py -- <out_dir> [render]
# Game axes: x right, y up, z aft, 1 unit = 500 m (length 2 units = 1 km).  Blender: x right, z up, nose toward +y.

import bpy, bmesh, math, sys, os, random
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp/atlas"
DO_RENDER = "render" in argv
os.makedirs(OUT, exist_ok=True)
random.seed(4711)

S = 500.0
def G(x, y, z): return Vector((x * S, -z * S, y * S))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------------------------------------------------------------- materials
def mat(name, color, metal=0.0, rough=0.5, emit=None, strength=0.0, coat=0.0, panels=0.0):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; b = nt.nodes["Principled BSDF"]; L = nt.links.new
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metal; b.inputs["Roughness"].default_value = rough
    if coat > 0: b.inputs["Coat Weight"].default_value = coat; b.inputs["Coat Roughness"].default_value = 0.15
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*emit, 1); b.inputs["Emission Strength"].default_value = strength
    if panels > 0:
        tc = nt.nodes.new("ShaderNodeTexCoord")
        mp = nt.nodes.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = (1.0, 0.5, 1.0)
        L(tc.outputs["Object"], mp.inputs["Vector"])
        def edges(scale, rnd):
            v = nt.nodes.new("ShaderNodeTexVoronoi"); v.feature = "DISTANCE_TO_EDGE"; v.distance = "CHEBYCHEV"
            v.inputs["Scale"].default_value = scale; v.inputs["Randomness"].default_value = rnd
            L(mp.outputs["Vector"], v.inputs["Vector"]); return v
        def seam(v, w):
            r = nt.nodes.new("ShaderNodeMapRange"); r.inputs["From Max"].default_value = w
            L(v.outputs["Distance"], r.inputs["Value"]); return r
        big = seam(edges(panels, 0.15), 0.03)
        small = seam(edges(panels * 2.5, 0.2), 0.012)
        pm = nt.nodes.new("ShaderNodeMath"); pm.operation = "MULTIPLY"; L(big.outputs["Result"], pm.inputs[0]); L(small.outputs["Result"], pm.inputs[1])
        # panel-to-panel tone: some plates a shade lighter or darker, like a real refitted hull
        cell = nt.nodes.new("ShaderNodeTexVoronoi"); cell.feature = "F1"; cell.distance = "CHEBYCHEV"; cell.inputs["Scale"].default_value = panels
        cell.inputs["Randomness"].default_value = 0.15; L(mp.outputs["Vector"], cell.inputs["Vector"])
        sep = nt.nodes.new("ShaderNodeSeparateColor"); L(cell.outputs["Color"], sep.inputs["Color"])
        tone = nt.nodes.new("ShaderNodeMapRange"); tone.inputs["To Min"].default_value = 0.86; tone.inputs["To Max"].default_value = 1.08
        L(sep.outputs["Red"], tone.inputs["Value"])
        grime = nt.nodes.new("ShaderNodeTexNoise"); grime.inputs["Scale"].default_value = panels * 0.6; grime.inputs["Detail"].default_value = 8
        L(mp.outputs["Vector"], grime.inputs["Vector"])
        gr = nt.nodes.new("ShaderNodeMapRange"); gr.inputs["From Min"].default_value = 0.45; gr.inputs["From Max"].default_value = 0.75
        gr.inputs["To Min"].default_value = 1.0; gr.inputs["To Max"].default_value = 0.8; L(grime.outputs["Fac"], gr.inputs["Value"])
        sc = nt.nodes.new("ShaderNodeMapRange"); sc.inputs["To Min"].default_value = 0.35; L(pm.outputs["Value"], sc.inputs["Value"])
        k1 = nt.nodes.new("ShaderNodeMath"); k1.operation = "MULTIPLY"; L(tone.outputs["Result"], k1.inputs[0]); L(gr.outputs["Result"], k1.inputs[1])
        k2 = nt.nodes.new("ShaderNodeMath"); k2.operation = "MULTIPLY"; L(k1.outputs["Value"], k2.inputs[0]); L(sc.outputs["Result"], k2.inputs[1])
        col = nt.nodes.new("ShaderNodeMix"); col.data_type = "RGBA"; col.blend_type = "MULTIPLY"; col.inputs["Factor"].default_value = 1
        col.inputs["A"].default_value = (*color, 1); L(k2.outputs["Value"], col.inputs["B"]); L(col.outputs["Result"], b.inputs["Base Color"])
        rr = nt.nodes.new("ShaderNodeMapRange"); rr.inputs["To Min"].default_value = rough + 0.3; rr.inputs["To Max"].default_value = rough
        L(pm.outputs["Value"], rr.inputs["Value"]); L(rr.outputs["Result"], b.inputs["Roughness"])
        bp = nt.nodes.new("ShaderNodeBump"); bp.inputs["Strength"].default_value = 0.5; bp.inputs["Distance"].default_value = 0.3
        L(pm.outputs["Value"], bp.inputs["Height"]); L(bp.outputs["Normal"], b.inputs["Normal"])
    return m

M = {
    "hull": mat("Hull paint", (0.62, 0.63, 0.6), metal=0.2, rough=0.38, coat=0.3, panels=0.022),
    "armour": mat("Armour grey", (0.3, 0.32, 0.34), metal=0.4, rough=0.4, panels=0.03),
    "keel": mat("Keel", (0.06, 0.065, 0.075), metal=0.5, rough=0.45, panels=0.025),
    "navy": mat("Navy", (0.04, 0.07, 0.16), metal=0.2, rough=0.35, coat=0.3),
    "steel": mat("Bare metal", (0.55, 0.56, 0.58), metal=1.0, rough=0.25),
    "dark": mat("Dark metal", (0.035, 0.037, 0.042), metal=0.85, rough=0.35),
    "grille": mat("Grille", (0.012, 0.012, 0.014), metal=0.6, rough=0.6),
    "glass": mat("Bridge glass", (0.004, 0.007, 0.012), rough=0.03, emit=(0.05, 0.2, 0.45), strength=0.05, coat=1.0),
    "glow": mat("Engine core", (0, 0, 0), emit=(0.55, 0.75, 1.0), strength=40.0),
    "lift": mat("Lift glow", (0, 0, 0), emit=(0.45, 0.65, 1.0), strength=3.0),
    "window": mat("Lamp white", (0, 0, 0), emit=(1, 0.86, 0.62), strength=6.0),
    "white": mat("Marking white", (0.85, 0.85, 0.82), rough=0.4),
    "hazard": mat("Hazard", (0.9, 0.5, 0.05), rough=0.45),
    "red": mat("Nav red", (0, 0, 0), emit=(1.0, 0.08, 0.05), strength=12.0),
    "green": mat("Nav green", (0, 0, 0), emit=(0.1, 1.0, 0.3), strength=12.0),
}

# ---------------------------------------------------------------- helpers
def obj_from_bm(bm, name, material, smooth=True):
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); scene.collection.objects.link(o)
    o.data.materials.append(M[material] if isinstance(material, str) else material)
    if smooth:
        for p in o.data.polygons: p.use_smooth = True
    return o
def finish(o, bevel=1.0, segs=3, angle=35, weighted=True, sub=0):
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL"); b.width = bevel; b.segments = segs; b.limit_method = "ANGLE"
        b.angle_limit = math.radians(angle); b.harden_normals = True
    if sub: s = o.modifiers.new("Sub", "SUBSURF"); s.levels = sub; s.render_levels = sub
    if weighted: w = o.modifiers.new("WN", "WEIGHTED_NORMAL"); w.keep_sharp = True
    return o
def mirror(pts):
    out = list(pts)
    for p in reversed(pts[1:]):
        q = (-p[0], p[1])
        if out[-1] != q: out.append(q)
    if out[0] == out[-1]: out.pop()
    return out
def grow(pts, d):   # push a half-outline outward by d (game units) in x
    return [(x + (d if x > 1e-6 else 0), z) for x, z in pts]
def half_w(outline, z):
    for (x0, z0), (x1, z1) in zip(outline, outline[1:]):
        if z0 <= z <= z1: return x0 + (x1 - x0) * (z - z0) / max(z1 - z0, 1e-6)
    return 0.0
def slab(name, outline, height_fn, material, cuts=6):
    bm = bmesh.new()
    vs = [bm.verts.new((x, z, 0)) for x, z in mirror(outline)]
    face = bm.faces.new(vs)
    bmesh.ops.triangulate(bm, faces=[face], quad_method="BEAUTY", ngon_method="BEAUTY")
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=cuts, use_grid_fill=True)
    bmesh.ops.beautify_fill(bm, faces=bm.faces[:], edges=bm.edges[:])
    ret = bmesh.ops.extrude_face_region(bm, geom=bm.faces[:])
    bottom = {v for v in ret["geom"] if isinstance(v, bmesh.types.BMVert)}
    for v in bm.verts:
        x, z = v.co.x, v.co.y; top, bot = height_fn(x, z)
        v.co = G(x, bot if v in bottom else top, z)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, material)
def box(size_u, center_u, material, bevel=0.6, rot=(0, 0, 0)):
    """a box given in game units"""
    bpy.ops.mesh.primitive_cube_add(size=1, location=G(*center_u))
    o = bpy.context.object; o.scale = (size_u[0] * S, size_u[2] * S, size_u[1] * S); o.rotation_euler = rot
    o.data.materials.append(M[material]); bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel > 0: finish(o, bevel=bevel, segs=2, angle=40)
    return o
def boxm(size_m, center_m, material):
    """a small box in metres at a Blender-space point (no bevel; used for windows and greebles)"""
    bpy.ops.mesh.primitive_cube_add(size=1, location=center_m)
    o = bpy.context.object; o.scale = size_m; o.data.materials.append(M[material]); return o
def lathe(name, profile, at, material, segs=48):
    """profile: (radius m, aft m) spun about the engine axis (game z)"""
    bm = bmesh.new(); rings = []
    for r, aft in profile:
        rings.append([bm.verts.new(at + Vector((r * math.cos(2 * math.pi * i / segs), -aft, r * math.sin(2 * math.pi * i / segs)))) for i in range(segs)])
    for a, b2 in zip(rings, rings[1:]):
        for i in range(segs): j = (i + 1) % segs; bm.faces.new((a[i], a[j], b2[j], b2[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, material)
def superellipse(cx, cy, a, b, n, count=48):
    pts = []
    for i in range(count):
        t = 2 * math.pi * i / count; c_, s_ = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c_) ** (2 / n), c_), cy + b * math.copysign(abs(s_) ** (2 / n), s_)))
    return pts
def loft(name, sections, material, cap=True):
    bm = bmesh.new(); rings = []
    for z, pts in sections: rings.append([bm.verts.new(G(x, y, z)) for x, y in pts])
    n = len(rings[0])
    for a, b2 in zip(rings, rings[1:]):
        for i in range(n): j = (i + 1) % n; bm.faces.new((a[i], a[j], b2[j], b2[i]))
    if cap: bm.faces.new(rings[0][::-1]); bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, material)

# ---------------------------------------------------------------- main hull (same outline as before, plus the old bevel's outset)
hull_o = grow([(0, -1.0), (0.07, -0.9), (0.14, -0.55), (0.19, -0.1), (0.2, 0.55), (0.18, 0.9), (0.12, 0.98)], 0.03)
def hull_h(x, z):
    w = max(half_w(hull_o, z), 1e-4); u = min(1.0, abs(x) / w)
    nose = min(1.0, (z + 1.0) / 0.25)
    t = 0.09 * (0.55 + 0.45 * nose) * (1 - 0.35 * u ** 3)          # edges chamfer in
    return (t, -min(t, 0.085))
finish(slab("Hull", hull_o, hull_h, "hull", cuts=8), bevel=12.0, segs=4, angle=30)

# upper armour spine: a raised, stepped citadel along the centreline
spine_o = grow([(0, -0.8), (0.09, -0.5), (0.13, 0.0), (0.14, 0.6), (0.1, 0.85)], 0.02)
def spine_h(x, z):
    w = max(half_w(spine_o, z), 1e-4); u = min(1.0, abs(x) / w)
    rise = min(1.0, (z + 0.8) / 0.25)
    return (0.085 + 0.045 * rise * (1 - 0.5 * u ** 3), 0.06)
finish(slab("Spine", spine_o, spine_h, "armour", cuts=7), bevel=8.0, segs=3, angle=30)
# a second, narrower deck on the spine
deck_o = [(0, -0.55), (0.05, -0.4), (0.075, 0.0), (0.08, 0.3), (0.06, 0.38)]
finish(slab("Upper deck", deck_o, lambda x, z: (spine_h(0, z)[0] + 0.012, spine_h(0, z)[0] - 0.01), "hull", cuts=5), bevel=2.0, segs=2, angle=30)

# keel: dark, flat-bottomed (the cargo doors sit in it at y = -0.1404)
keel_o = grow([(0, -0.92), (0.1, -0.5), (0.15, 0.1), (0.15, 0.8), (0.1, 0.95)], 0.02)
finish(slab("Keel", keel_o, lambda x, z: (-0.05, -0.1404), "keel", cuts=6), bevel=3.0, segs=3, angle=30)

# prow armour: angled plates sweeping back from the nose, and a navy prow band
for s in (1, -1):
    bm = bmesh.new()
    pts = [(s * 0.05, -0.93), (s * 0.16, -0.6), (s * 0.19, -0.35), (s * 0.12, -0.55)]
    vs = [bm.verts.new(G(x, 0.095, z)) for x, z in pts]
    f = bm.faces.new(vs if s > 0 else vs[::-1])
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    for v in ext["geom"]:
        if isinstance(v, bmesh.types.BMVert): v.co.z -= 0.012 * S
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    finish(obj_from_bm(bm, "Prow plate", "armour"), bevel=1.5, segs=2)
for s in (1, -1):
    box((0.012, 0.13, 0.38), (s * 0.135, 0.0, -0.62), "navy", bevel=1.0, rot=(0, 0, s * 0.2))

# ---------------------------------------------------------------- side sponsons with the lounge windows
win_y0, win_y1 = -0.012, 0.016          # the lounge's window band (deck metres -6…8, in game units)
for s in (1, -1):
    # a long armoured sponson down each flank, broken where the lounge windows look out
    for z0, z1 in ((-0.42, -0.1), (0.06, 0.5)):
        zc = (z0 + z1) / 2; x = half_w(hull_o, zc) + 0.004
        box((0.03, 0.07, z1 - z0), (s * x, 0.0, zc), "armour", bevel=2.0)
    # lounge glass: a dark band of windows with mullions (the game opens it up when you're inside)
    x = 0.232
    box((0.006, win_y1 - win_y0, 0.124), (s * x, (win_y0 + win_y1) / 2, -0.02), "glass", bevel=0)
    for k in range(9):
        z = -0.08 + k * 0.015
        box((0.008, win_y1 - win_y0 + 0.004, 0.0024), (s * (x + 0.0015), (win_y0 + win_y1) / 2, z), "dark", bevel=0)
    box((0.01, 0.004, 0.13), (s * (x + 0.002), win_y1 + 0.002, -0.02), "dark", bevel=0)
    box((0.01, 0.004, 0.13), (s * (x + 0.002), win_y0 - 0.002, -0.02), "dark", bevel=0)

# rows of lit windows along the flanks and the spine walls
for s in (1, -1):
    for row, y in enumerate((-0.045, -0.03, 0.03, 0.05)):
        for z in [i * 0.0085 - 0.85 for i in range(int(1.7 / 0.0085))]:
            if -0.09 < z < 0.05 or random.random() < 0.35: continue
            w = half_w(hull_o, z)
            if w < 0.06: continue
            x = w - 0.006 * row * 0.3
            p = G(s * (w + 0.0022), y * (0.6 if z < -0.7 else 1.0), z)
            boxm((0.25, 1.4, 1.0), p, "window")
    for z in [i * 0.009 - 0.6 for i in range(int(1.3 / 0.009))]:
        if random.random() < 0.4: continue
        w = half_w(spine_o, z)
        p = G(s * (w + 0.0015), 0.105, z)
        boxm((0.25, 1.4, 1.0), p, "window")

# ---------------------------------------------------------------- bridge tower aft: tapered decks, window bands, the glass bubble
tz = 0.5
def deck(y0, y1, w0, w1, z0, z1, material="hull"):
    secs = []
    for z, f in ((z0, 0.0), (z0 + (z1 - z0) * 0.25, 1.0), (z1, 1.0)):
        a = (w0 + (w1 - w0) * 0.5) * (0.82 + 0.18 * f)
        secs.append((z, superellipse(0, (y0 + y1) / 2, a, (y1 - y0) / 2, 4.5)))
    finish(loft("Tower deck", secs, material), bevel=1.5, segs=2, angle=30)
deck(0.11, 0.17, 0.08, 0.075, tz - 0.15, tz + 0.15)
deck(0.17, 0.22, 0.06, 0.055, tz - 0.11, tz + 0.09)
deck(0.22, 0.262, 0.045, 0.04, tz - 0.09, tz + 0.01, "armour")
for y, w, z0, z1 in ((0.15, 0.081, tz - 0.15, tz + 0.15), (0.205, 0.061, tz - 0.11, tz + 0.09)):
    for s in (1, -1):
        box((0.002, 0.005, z1 - z0 - 0.03), (s * w, y, (z0 + z1) / 2 + 0.01), "window", bevel=0)
    box((2 * w - 0.02, 0.005, 0.002), (0, y, z0 + 0.012), "window", bevel=0)
# the bridge bubble, exactly where the cockpit view and the walkable bridge expect it
c = (0, 0.245, tz - 0.09); hb = (0.032, 0.012, 0.02)
bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, location=G(*c))
bub = bpy.context.object; bub.scale = (hb[0] * S * 1.05, hb[2] * S * 1.15, hb[1] * S * 1.1)
bub.data.materials.append(M["glass"]); bpy.ops.object.shade_smooth()
for k in range(5):     # bridge window frames
    a = -0.6 + k * 0.3
    bpy.ops.mesh.primitive_torus_add(major_radius=1, minor_radius=0.04, location=G(*c), rotation=(0, 0, a))
    fr = bpy.context.object; fr.scale = (hb[0] * S * 1.07, hb[2] * S * 1.17, hb[1] * S * 1.12); fr.data.materials.append(M["dark"])
# masts, a dish and sensor domes on the tower
for x, h in ((-0.03, 0.12), (0.025, 0.09), (0.0, 0.16)):
    box((0.003, h, 0.003), (x, 0.262 + h / 2, tz + 0.03), "dark", bevel=0)
    boxm((2.5, 2.5, 2.5), G(x, 0.262 + h, tz + 0.03), "red")
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.035 * S, location=G(0.05, 0.275, tz + 0.06)); d = bpy.context.object
d.scale = (1, 1, 0.25); d.rotation_euler = (0.5, 0, 0.3); d.data.materials.append(M["steel"]); bpy.ops.object.shade_smooth()
for x in (-0.03, 0.03):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.012 * S, location=G(x, 0.262, tz - 0.02)); bpy.context.object.data.materials.append(M["white"]); bpy.ops.object.shade_smooth()

# ---------------------------------------------------------------- engines: nacelles on pylons and the 2×2 main cluster
for s in (1, -1):
    c0 = G(s * 0.3, 0.0, 0.58); r = 0.065 * S
    lathe("Nacelle", [(r * 0.75, -0.29 * S), (r * 1.08, -0.27 * S), (r * 1.1, -0.2 * S), (r * 1.0, 0.0), (r * 1.0, 0.2 * S), (r * 0.92, 0.29 * S)], c0, "hull")
    lathe("Intake lip", [(r * 0.7, -0.27 * S), (r * 1.1, -0.285 * S), (r * 1.12, -0.25 * S)], c0, "steel")
    lathe("Nozzle", [(r * 0.92, 0.28 * S), (r * 0.98, 0.31 * S), (r * 0.9, 0.315 * S), (r * 0.8, 0.29 * S)], c0, "steel")
    bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=r * 0.8, depth=1, location=c0 + Vector((0, -0.3 * S, 0)), rotation=(math.pi / 2, 0, 0))
    bpy.context.object.data.materials.append(M["glow"])
    bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=r * 0.72, depth=1, location=c0 + Vector((0, 0.27 * S, 0)), rotation=(math.pi / 2, 0, 0))
    bpy.context.object.data.materials.append(M["grille"])
    for k in range(6):    # ribs round the nacelle
        z = 0.38 + k * 0.07
        lathe("Rib", [(r * 1.0, (z - 0.58 - 0.004) * S), (r * 1.03, (z - 0.58) * S), (r * 1.0, (z - 0.58 + 0.004) * S)], c0, "armour")
    box((0.12, 0.025, 0.28), (s * 0.21, 0.0, 0.56), "armour", bevel=2.0)                       # pylon
    box((0.004, 0.004, 0.5), (s * 0.3, 0.066, 0.58), "navy", bevel=0)                          # stripe on top
# main cluster housing and four nozzles
loft("Engine block", [(0.86, superellipse(0, 0.002, 0.15, 0.085, 4.0)), (0.93, superellipse(0, 0.002, 0.155, 0.088, 4.0)), (0.97, superellipse(0, 0.002, 0.15, 0.085, 4.0))], "armour")
for x in (-0.075, 0.075):
    for y in (-0.035, 0.04):
        r = 0.045 * S; at = G(x, y, 0.98)
        lathe("Main nozzle", [(r * 1.15, -0.05 * S), (r * 1.2, -0.01 * S), (r * 1.28, 0.02 * S), (r * 1.18, 0.025 * S), (r * 1.05, 0.0), (r * 0.95, -0.03 * S)], at, "steel")
        bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=r, depth=1, location=at + Vector((0, 0.03 * S, 0)), rotation=(math.pi / 2, 0, 0))
        bpy.context.object.data.materials.append(M["glow"])

# ---------------------------------------------------------------- belly: VTOL ports, cargo door seam, hazard marks
for s in (1, -1):
    for z in (-0.6, -0.2, 0.2, 0.6):
        p = G(s * 0.11, -0.1405, z)
        bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.03 * S, depth=0.5, location=p); bpy.context.object.data.materials.append(M["dark"])
        bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.022 * S, depth=0.6, location=p); bpy.context.object.data.materials.append(M["lift"])
# cargo door outline (the game draws the doors themselves): hazard frame round x ±10.5 m, z -252…-226 m
for zz in (-0.504, -0.452):
    box((0.046, 0.001, 0.003), (0, -0.1408, zz), "hazard", bevel=0)
for xx in (-0.022, 0.022):
    box((0.003, 0.001, 0.055), (xx, -0.1408, -0.478), "hazard", bevel=0)

# ---------------------------------------------------------------- topside: turrets, vents, greebles, flight-deck markings
for (x, z) in ((0.0, -0.55), (0.0, -0.25), (0.08, 0.15), (-0.08, 0.15), (0.1, -0.3), (-0.1, -0.3)):
    y = spine_h(x, z)[0] if abs(x) < half_w(spine_o, z) else hull_h(x, z)[0]
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.022 * S, depth=0.012 * S, location=G(x, y + 0.006, z))
    t = bpy.context.object; t.data.materials.append(M["armour"]); finish(t, bevel=0.8, segs=2)
    box((0.03, 0.012, 0.03), (x, y + 0.016, z), "hull", bevel=0.8)
    for o in (-0.007, 0.007): box((0.003, 0.003, 0.05), (x + o, y + 0.018, z - 0.03), "dark", bevel=0)
for _ in range(260):
    z = -0.7 + random.random() * 1.45; w = half_w(hull_o, z) * 0.95
    x = (random.random() * 2 - 1) * w
    on_spine = abs(x) < half_w(spine_o, z)
    y = spine_h(x, z)[0] if on_spine else hull_h(x, z)[0]
    sz = (0.004 + random.random() * 0.018, 0.002 + random.random() * 0.006, 0.004 + random.random() * 0.03)
    box(sz, (x, y + sz[1] / 2 - 0.0005, z), random.choice(("armour", "dark", "hull", "grille")), bevel=0.3)
# flight-deck lines and hull number
for s in (1, -1):
    box((0.003, 0.0006, 0.4), (s * 0.04, spine_h(0, -0.45)[0] + 0.0004, -0.45), "white", bevel=0)
for k in range(6):
    box((0.07, 0.0006, 0.004), (0, spine_h(0, -0.62 + k * 0.05)[0] + 0.0004, -0.62 + k * 0.05), "hazard", bevel=0)
for s in (1, -1):
    bpy.ops.object.text_add(location=G(s * 0.211, 0.0, -0.32))
    tx = bpy.context.object; tx.data.body = "ATLAS 01"; tx.data.size = 22; tx.data.extrude = 0.3; tx.data.align_x = "CENTER"
    tx.rotation_euler = (math.pi / 2, 0, math.pi / 2 * s); tx.data.materials.append(M["navy"])
# nav lights
boxm((3, 3, 3), G(-0.365, 0.0, 0.58), "red"); boxm((3, 3, 3), G(0.365, 0.0, 0.58), "green")

# ---------------------------------------------------------------- save, and optional turnaround renders
if True:
    w = bpy.data.worlds.new("World"); scene.world = w; w.use_nodes = True; nt_ = w.node_tree
    bg = nt_.nodes["Background"]; bg.inputs["Color"].default_value = (0.03, 0.035, 0.05, 1)
    sky = nt_.nodes.new("ShaderNodeTexSky"); sky.sky_type = "NISHITA"; sky.sun_elevation = math.radians(25)
    sbg = nt_.nodes.new("ShaderNodeBackground"); sbg.inputs["Strength"].default_value = 0.25; nt_.links.new(sky.outputs["Color"], sbg.inputs["Color"])
    lp = nt_.nodes.new("ShaderNodeLightPath"); mx = nt_.nodes.new("ShaderNodeMixShader")
    nt_.links.new(lp.outputs["Is Camera Ray"], mx.inputs["Fac"]); nt_.links.new(sbg.outputs["Background"], mx.inputs[1]); nt_.links.new(bg.outputs["Background"], mx.inputs[2])
    nt_.links.new(mx.outputs["Shader"], nt_.nodes["World Output"].inputs["Surface"])
    ld = bpy.data.lights.new("Sun", "SUN"); ld.energy = 5.5; ld.color = (1.0, 0.96, 0.9)
    so = bpy.data.objects.new("Sun", ld); scene.collection.objects.link(so); so.rotation_euler = (math.radians(40), math.radians(-25), math.radians(35))
    scene.render.engine = "BLENDER_EEVEE_NEXT"
    try: scene.eevee.use_raytracing = True; scene.eevee.taa_render_samples = 48
    except Exception: pass
    scene.view_settings.view_transform = "AgX"; scene.view_settings.look = "AgX - Punchy"
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam")); scene.collection.objects.link(cam); scene.camera = cam
    cam.data.lens = 50; cam.data.clip_end = 20000
    target = Vector((0, 0, 30))
    def shoot(name, pos, res=(1400, 860)):
        if not DO_RENDER: return
        scene.render.resolution_x, scene.render.resolution_y = res
        cam.location = pos; cam.rotation_euler = (target - pos).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(OUT, name); bpy.ops.render.render(write_still=True)
    shoot("hero.png", Vector((900, 1000, 380)), (1920, 1080))
    shoot("front34.png", Vector((1100, 1300, 650)))
    shoot("rear34.png", Vector((-1000, -1300, 500)))
    shoot("top.png", Vector((1, 0, 2600)))
    shoot("low.png", Vector((900, 700, -350)))
for o in scene.objects: o.select_set(False)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "atlas.blend"))
print("done", OUT)
