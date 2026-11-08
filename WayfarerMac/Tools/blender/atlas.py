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
    "warm": mat("Lamp warm", (0, 0, 0), emit=(1.0, 0.62, 0.28), strength=9.0),
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

# ---------------------------------------------------------------- greeble kit: thousands of small parts, merged per material
from mathutils import Matrix
KIT = {}
def kit(material, size_m, center_m, rz=0.0):
    bm = KIT.setdefault(material, bmesh.new())
    m = Matrix.Translation(center_m) @ Matrix.Rotation(rz, 4, "Z") @ Matrix.Diagonal((*size_m, 1.0))
    bmesh.ops.create_cube(bm, size=1.0, matrix=m)
def kit_cyl(material, r, length, center_m, axis="Y", segs=10):
    bm = KIT.setdefault(material, bmesh.new())
    rot = {"X": Matrix.Rotation(math.pi / 2, 4, "Y"), "Y": Matrix.Rotation(math.pi / 2, 4, "X"), "Z": Matrix.Identity(4)}[axis]
    m = Matrix.Translation(center_m) @ rot
    bmesh.ops.create_cone(bm, cap_ends=True, segments=segs, radius1=r, radius2=r, depth=length, matrix=m)
def kit_build():
    for mname, bm in KIT.items():
        o = obj_from_bm(bm, "Greebles " + mname, mname, smooth=False)

def shrink(outline, d, z0=None, z1=None):
    """the half-outline pulled in by d (game units), optionally clipped to z0…z1"""
    pts = [(max(0.0, x - d) if x > 1e-6 else 0.0, z) for x, z in outline]
    if z0 is not None:
        zs = [z0] + [z for _, z in pts if z0 < z < z1] + [z1]
        pts = [(0.0, z0)] + [(max(0.0, half_w(outline, z) - d), z) for z in zs] + [(0.0, z1)]
        pts = [p for i, p in enumerate(pts) if i == 0 or p != pts[i - 1]]
    return pts

# ---------------------------------------------------------------- the hull: a lower and an upper armoured shell split by a recessed machinery trench
hull_o = grow([(0, -1.0), (0.07, -0.9), (0.14, -0.55), (0.19, -0.1), (0.2, 0.55), (0.18, 0.9), (0.12, 0.98)], 0.03)
TR0, TR1 = -0.022, 0.024            # the trench (the lounge windows look out of it)
def nose_k(z): return 0.55 + 0.45 * min(1.0, (z + 1.0) / 0.25)
def deck_top(z): return 0.085 * nose_k(z)
finish(slab("Lower shell", hull_o, lambda x, z: (TR0, -0.085 * nose_k(z) * 0.9), "hull", cuts=8), bevel=10.0, segs=3, angle=30)
finish(slab("Upper shell", hull_o, lambda x, z: (deck_top(z), TR1), "hull", cuts=8), bevel=10.0, segs=3, angle=30)
core_o = shrink(hull_o, 0.011)
slab("Trench core", core_o, lambda x, z: (TR1 + 0.002, TR0 - 0.002), "keel", cuts=6)

# keel: dark and flat-bottomed (the cargo doors sit in it at y = -0.1404)
keel_o = grow([(0, -0.92), (0.1, -0.5), (0.15, 0.1), (0.15, 0.8), (0.1, 0.95)], 0.02)
finish(slab("Keel", keel_o, lambda x, z: (-0.05, -0.1404), "keel", cuts=6), bevel=4.0, segs=3, angle=30)
# armour skirts hanging along the keel's flanks, broken into segments
for s_ in (1, -1):
    for k in range(14):
        z0 = -0.8 + k * 0.12; z1 = z0 + 0.105
        x = half_w(keel_o, (z0 + z1) / 2) + 0.004
        box((0.012, 0.05, z1 - z0), (s_ * x, -0.098, (z0 + z1) / 2), "armour", bevel=2.0)

# ---------------------------------------------------------------- the trench: pipes, ribs, machinery and warm lights all along both flanks
for s_ in (1, -1):
    z = -0.93
    while z < 0.94:
        w = half_w(core_o, z)
        if w < 0.02 or -0.092 < z < 0.052: z += 0.007; continue      # the lounge's windows: keep the view clear
        xf = s_ * (w + 0.0005) * S
        # ribs every ~14 m holding the shells apart
        if int(z * 1000) % 28 < 9: kit("armour", (2.0, 3.0, (TR1 - TR0) * S), Vector((xf + s_ * 1.0, -z * S, (TR0 + TR1) / 2 * S)))
        # machinery boxes
        if random.random() < 0.7:
            h = random.uniform(2, 9); d = random.uniform(1.5, 5)
            kit(random.choice(("dark", "grille", "armour")), (d, random.uniform(3, 10), h), Vector((xf + s_ * d / 2, -z * S, random.uniform(TR0 * S + h / 2 + 1, TR1 * S - h / 2 - 1))))
        # warm lit windows deep in the trench (skip where the lounge's own glass is)
        if not (-0.085 < z < 0.045) and random.random() < 0.55:
            kit("warm", (0.4, random.uniform(2, 7), 1.4), Vector((xf + s_ * 0.25, -z * S, random.choice((TR0 + 0.006, 0.0, TR1 - 0.007)) * S)))
        z += 0.007
    # long pipes running the length of the trench
    for yy in (TR0 + 0.004, TR1 - 0.005):
        for k in range(18):
            z0 = -0.85 + k * 0.1; zc = z0 + 0.045
            w = half_w(core_o, zc)
            if w < 0.04: continue
            kit_cyl("steel", 1.0, 0.085 * S, Vector((s_ * (w + 0.002) * S, -zc * S, yy * S)), axis="Y", segs=8)
    # the lounge's window wall, set into the trench (the game opens it up when you're inside)
    x = half_w(core_o, -0.02) + 0.0008
    box((0.002, TR1 - TR0 - 0.004, 0.124), (s_ * x, (TR0 + TR1) / 2, -0.02), "glass", bevel=0)
    for k in range(9):
        box((0.004, TR1 - TR0, 0.0024), (s_ * (x + 0.001), (TR0 + TR1) / 2, -0.08 + k * 0.015), "dark", bevel=0)

# ---------------------------------------------------------------- forked prow: two armoured blades reaching past the nose, a lit docking trench between
for s_ in (1, -1):
    bm = bmesh.new()
    pts = [(s_ * 0.012, -1.07), (s_ * 0.06, -0.88), (s_ * 0.09, -0.7), (s_ * 0.035, -0.72)]
    vs = [bm.verts.new(G(x, deck_top(-0.9) + 0.004, z)) for x, z in pts]
    f = bm.faces.new(vs if s_ > 0 else vs[::-1])
    ext = bmesh.ops.extrude_face_region(bm, geom=[f])
    for v in ext["geom"]:
        if isinstance(v, bmesh.types.BMVert): v.co.z -= 0.06 * S
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    finish(obj_from_bm(bm, "Prow blade", "armour"), bevel=3.0, segs=2)
box((0.03, 0.006, 0.3), (0, deck_top(-0.8) + 0.002, -0.82), "keel", bevel=0)       # the docking trench floor
for s_ in (1, -1):
    box((0.006, 0.012, 0.3), (s_ * 0.018, deck_top(-0.8) + 0.006, -0.82), "armour", bevel=1.0)
    for k in range(16): kit("warm", (0.5, 2.5, 1.2), G(s_ * 0.0145, deck_top(-0.8) + 0.006, -0.95 + k * 0.018))
for k in range(12): kit("lift", (6, 0.6, 0.3), G(0, deck_top(-0.8) + 0.0055, -0.95 + k * 0.022))

# ---------------------------------------------------------------- stepped terraces climbing aft to the command tower
TIERS = []          # (outline, top, bottom) — used for placing surface detail
def tier(name, outline, top, bottom, material="hull", band=0.006):
    # a dark machinery band under each step, then the plated step itself
    slab(name + " band", shrink(outline, 0.004), lambda x, z: (bottom + band, bottom - 0.002), "keel", cuts=4)
    finish(slab(name, outline, lambda x, z: (top, bottom + band), material, cuts=5), bevel=5.0, segs=2, angle=30)
    TIERS.append((outline, top, bottom))
    # lit slits in the band
    for s_ in (1, -1):
        for zz in [outline[0][1] + i * 0.009 for i in range(int((outline[-1][1] - outline[0][1]) / 0.009))]:
            if random.random() < 0.45: continue
            w = half_w(shrink(outline, 0.004), zz)
            if w > 0.01: kit("warm", (0.3, 2.6, 1.0), G(s_ * (w + 0.0004), bottom + band * 0.5, zz))
t1 = [(0, -0.72), (0.08, -0.55), (0.15, -0.2), (0.165, 0.3), (0.15, 0.72), (0.1, 0.84)]
t2 = [(0, -0.42), (0.07, -0.3), (0.12, -0.05), (0.13, 0.35), (0.11, 0.62), (0.07, 0.7)]
t3 = [(0, -0.15), (0.06, -0.06), (0.095, 0.15), (0.1, 0.45), (0.08, 0.6), (0.05, 0.64)]
t4 = [(0, 0.12), (0.05, 0.2), (0.075, 0.32), (0.075, 0.52), (0.05, 0.6)]
tier("Terrace 1", t1, 0.125, 0.08, band=0.012)
tier("Terrace 2", t2, 0.167, 0.12, "armour", band=0.014)
tier("Terrace 3", t3, 0.203, 0.162, band=0.014)
tier("Terrace 4", t4, 0.232, 0.198, "armour", band=0.012)
def top_y(x, z):
    y = deck_top(z) if abs(x) < half_w(hull_o, z) else None
    for o, t, b in TIERS:
        if abs(x) < half_w(o, z): y = t
    return y

# ---------------------------------------------------------------- command tower: a forward-raked blade on the top terrace, bridge pod at its brow
tz = 0.5
def raked(y0, y1, w, z0, z1, rake, material):
    secs = []
    for k, y in enumerate((y0, y1)):
        off = rake * (y - y0)
        secs.append(y)
    bm = bmesh.new()
    def ring(y, w_, za, zb):
        return [bm.verts.new(G(x, y, z)) for x, z in ((-w_, za), (w_, za), (w_ * 0.85, zb), (-w_ * 0.85, zb))]
    a = ring(y0, w, z0, z1); b2 = ring(y1, w * 0.82, z0 - rake, z1 - rake * 0.4)
    for i in range(4): j = (i + 1) % 4; bm.faces.new((a[i], a[j], b2[j], b2[i]))
    bm.faces.new(a[::-1]); bm.faces.new(b2)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    finish(obj_from_bm(bm, "Tower", material), bevel=2.0, segs=2, angle=30)
raked(0.229, 0.244, 0.046, tz - 0.08, tz + 0.08, 0.012, "armour")
raked(0.244, 0.26, 0.038, tz - 0.1, tz + 0.03, 0.01, "hull")
for y in (0.242,):
    kit("keel", (0.05 * S * 2, 0.17 * S, 2.0), G(0, y, tz + 0.01))
    for s_ in (1, -1):
        for k in range(12): kit("warm", (0.4, 3, 1.2), G(s_ * 0.045, y + 0.002, tz - 0.06 + k * 0.012))
# the bridge bubble, exactly where the cockpit view and the walkable bridge expect it
c = (0, 0.245, tz - 0.09); hb = (0.032, 0.012, 0.02)
bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, location=G(*c))
bub = bpy.context.object; bub.scale = (hb[0] * S * 1.05, hb[2] * S * 1.15, hb[1] * S * 1.1)
bub.data.materials.append(M["glass"]); bpy.ops.object.shade_smooth()
for k in range(5):
    bpy.ops.mesh.primitive_torus_add(major_radius=1, minor_radius=0.04, location=G(*c), rotation=(0, 0, -0.6 + k * 0.3))
    fr = bpy.context.object; fr.scale = (hb[0] * S * 1.07, hb[2] * S * 1.17, hb[1] * S * 1.12); fr.data.materials.append(M["dark"])
# a tall swept comms fin aft of the bridge, sensor spheres, masts
bm = bmesh.new()
fin = [(0.258, tz + 0.0), (0.33, tz + 0.06), (0.335, tz + 0.09), (0.258, tz + 0.1)]
vs = [bm.verts.new(G(-0.004, y, z)) for y, z in fin]; f = bm.faces.new(vs)
ext = bmesh.ops.extrude_face_region(bm, geom=[f])
for v in ext["geom"]:
    if isinstance(v, bmesh.types.BMVert): v.co.x += 0.008 * S
bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:]); finish(obj_from_bm(bm, "Comms fin", "armour"), bevel=1.0, segs=2)
for s_ in (1, -1):
    bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=2, radius=0.011 * S, location=G(s_ * 0.034, 0.268, tz + 0.04))
    bpy.context.object.data.materials.append(M["white"])
    box((0.004, 0.012, 0.004), (s_ * 0.034, 0.258, tz + 0.04), "dark", bevel=0)
for x, h in ((-0.012, 0.06), (0.01, 0.045)):
    box((0.002, h, 0.002), (x, 0.258 + h / 2, tz + 0.07), "dark", bevel=0)
    boxm((2.5, 2.5, 2.5), G(x, 0.258 + h, tz + 0.07), "red")

# ---------------------------------------------------------------- surface detail in zones: calm plating with clusters of machinery
def in_hull(x, z): return abs(x) < half_w(hull_o, z) * 0.97
def tier_edge(x, z):   # how close (game units) to the edge of the deck x, z stands on
    best = half_w(hull_o, z) - abs(x)
    for o, t, b in TIERS:
        w = half_w(o, z)
        if abs(x) < w: best = w - abs(x)
    return best
deck_spots = 0
# 1. large raised armour plates in hull tones (subtle relief over the whole deck)
for _ in range(1600):
    z = -0.95 + random.random() * 1.9; x = (random.random() * 2 - 1) * half_w(hull_o, z)
    if not in_hull(x, z): continue
    y = top_y(x, z)
    if y is None or (0.32 < z < 0.7 and abs(x) < 0.06): continue
    a, b = random.choice(((8, 30), (14, 22), (20, 60), (10, 12)))
    kit(random.choice(("hull", "hull", "hull", "armour")), (a, b, 0.7), G(x, y, z) + Vector((0, 0, 0.3)))
# 2. machinery clusters: a few dozen sites, each a dense knot of boxes, pipes and vents, mostly near deck edges
for _ in range(70):
    z = -0.85 + random.random() * 1.7; x = (random.random() * 2 - 1) * half_w(hull_o, z) * 0.95
    if not in_hull(x, z) or top_y(x, z) is None: continue
    if random.random() < 0.6 and tier_edge(x, z) > 0.03: continue
    for _k in range(random.randint(14, 40)):
        dx, dz = random.gauss(0, 0.008), random.gauss(0, 0.014)
        xx, zz = x + dx, z + dz
        if not in_hull(xx, zz): continue
        y = top_y(xx, zz)
        if y is None: continue
        r = random.random(); p = G(xx, y, zz)
        if r < 0.55:
            a, b, h = random.uniform(2, 9), random.uniform(2, 12), random.uniform(1.5, 7)
            kit(random.choice(("armour", "armour", "hull", "dark")), (a, b, h), p + Vector((0, 0, h / 2)))
        elif r < 0.75: kit("grille", (random.uniform(3, 8), random.uniform(5, 14), 0.8), p + Vector((0, 0, 0.4)))
        elif r < 0.92: kit_cyl("steel", random.uniform(0.6, 1.5), random.uniform(12, 35), p + Vector((0, 0, 1.2)), axis="Y", segs=8)
        else: kit("warm", (1.2, 1.2, 0.4), p + Vector((0, 0, 0.25)))
        deck_spots += 1
# 3. a few long service trenches and landing strips down the forward deck
for x in (-0.07, 0.07):
    box((0.012, 0.003, 0.32), (x, deck_top(-0.55) + 0.001, -0.6), "keel", bevel=0)
    for k in range(18): kit("warm", (1.2, 1.2, 0.3), G(x, deck_top(-0.55) + 0.003, -0.75 + k * 0.018))
for k in range(8):
    box((0.07, 0.0006, 0.004), (0, deck_top(-0.88) + 0.0004, -0.9 + k * 0.035), "hazard", bevel=0)
# turrets along the terrace edges
for (x, z) in ((0.1, -0.45), (-0.1, -0.45), (0.14, -0.15), (-0.14, -0.15), (0.12, 0.1), (-0.12, 0.1), (0.0, -0.58), (0.08, -0.3), (-0.08, -0.3)):
    y = top_y(x, z)
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.018 * S, depth=0.01 * S, location=G(x, y + 0.005, z))
    t = bpy.context.object; t.data.materials.append(M["armour"]); finish(t, bevel=0.8, segs=2)
    box((0.026, 0.01, 0.026), (x, y + 0.014, z), "hull", bevel=0.8)
    for o in (-0.006, 0.006): box((0.0025, 0.0025, 0.045), (x + o, y + 0.016, z - 0.028), "dark", bevel=0)
# hull number on the upper shell's flanks
for s_ in (1, -1):
    bpy.ops.object.text_add(location=G(s_ * (half_w(hull_o, 0.2) + 0.003), (TR1 + deck_top(0.2)) / 2, 0.2))
    tx = bpy.context.object; tx.data.body = "ATLAS 01"; tx.data.size = 18; tx.data.extrude = 0.3; tx.data.align_x = "CENTER"; tx.data.align_y = "CENTER"
    tx.rotation_euler = (math.pi / 2, 0, math.pi / 2 * s_); tx.data.materials.append(M["navy"])
boxm((3, 3, 3), G(-0.365, 0.0, 0.58), "red"); boxm((3, 3, 3), G(0.365, 0.0, 0.58), "green")
kit_build()
print("deck details", deck_spots)

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
loft("Engine block", [(0.84, superellipse(0, -0.002, 0.15, 0.098, 4.0)), (0.92, superellipse(0, -0.002, 0.158, 0.104, 4.0)), (0.965, superellipse(0, -0.002, 0.152, 0.1, 4.0))], "armour")
# four main engines, well apart: each a deep bell set into a recessed collar, with a throat and a glowing core
for x in (-0.085, 0.085):
    for y in (-0.048, 0.045):
        r = 0.036 * S; at = G(x, y, 0.99)
        lathe("Engine collar", [(r * 1.42, -0.04 * S), (r * 1.42, -0.018 * S), (r * 1.3, -0.016 * S), (r * 1.18, -0.02 * S)], at, "dark")
        lathe("Main nozzle", [(r * 1.0, -0.03 * S), (r * 1.06, -0.012 * S), (r * 1.16, 0.01 * S), (r * 1.26, 0.03 * S), (r * 1.2, 0.033 * S),
                              (r * 1.1, 0.02 * S), (r * 0.92, 0.0), (r * 0.72, -0.016 * S), (r * 0.5, -0.024 * S)], at, "steel")
        for k in range(16):    # petal seams on the bell
            a0 = 2 * math.pi * k / 16
            boxm((0.6, 0.03 * S, 0.6), at + Vector((r * 1.2 * math.cos(a0), -0.012 * S, r * 1.2 * math.sin(a0))), "dark")
        bpy.ops.mesh.primitive_cylinder_add(vertices=48, radius=r * 0.94, depth=0.6, location=at, rotation=(math.pi / 2, 0, 0))
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
