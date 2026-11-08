# Wayfarer · Kestrel, rebuilt as a smooth hard-surface model.
# Same silhouette and proportions as the in-game Kestrel (outlines taken from Meshes.swift), refined:
# tapered wings, domed spine and belly, bevelled edges, a framed canopy, flared nozzles, recessed vents,
# panel seams, nav lights and a hull number.
#
# Run:  Blender -b -P kestrel.py -- <out_dir> [render]
# Game axes: x right, y up, z aft (nose toward -z), 1 unit = 50/1.4 m.  Blender: x right, z up, nose toward -y.

import bpy, bmesh, math, sys, os
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp/kestrel"
DO_RENDER = "render" in argv
os.makedirs(OUT, exist_ok=True)

S = 50.0 / 1.4                      # metres per game unit
def G(x, y, z): return Vector((x * S, -z * S, y * S))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------------------------------------------------------------- materials
def mat(name, color, metal=0.0, rough=0.5, emit=None, strength=0.0, coat=0.0, panels=False):
    m = bpy.data.materials.new(name); m.use_nodes = True
    nt = m.node_tree; b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    if coat > 0: b.inputs["Coat Weight"].default_value = coat; b.inputs["Coat Roughness"].default_value = 0.12
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*emit, 1); b.inputs["Emission Strength"].default_value = strength
    if panels:
        L = nt.links.new
        tc = nt.nodes.new("ShaderNodeTexCoord")
        mp = nt.nodes.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = (1.0, 0.45, 1.0)   # panels run lengthwise
        L(tc.outputs["Object"], mp.inputs["Vector"])
        def edges(scale, rnd):
            v = nt.nodes.new("ShaderNodeTexVoronoi"); v.feature = "DISTANCE_TO_EDGE"; v.voronoi_dimensions = "3D"; v.distance = "CHEBYCHEV"
            v.inputs["Scale"].default_value = scale; v.inputs["Randomness"].default_value = rnd
            L(mp.outputs["Vector"], v.inputs["Vector"]); return v
        def seam(v, w):
            r = nt.nodes.new("ShaderNodeMapRange"); r.inputs["From Min"].default_value = 0.0; r.inputs["From Max"].default_value = w
            r.inputs["To Min"].default_value = 0.0; r.inputs["To Max"].default_value = 1.0
            L(v.outputs["Distance"], r.inputs["Value"]); return r          # 0 in the seam, 1 on the panel
        big = seam(edges(0.3, 0.12), 0.03)
        small = seam(edges(1.0, 0.2), 0.02)
        # only some of the small panels show (access hatches), masked by noise
        nz = nt.nodes.new("ShaderNodeTexNoise"); nz.inputs["Scale"].default_value = 0.6; L(mp.outputs["Vector"], nz.inputs["Vector"])
        mk = nt.nodes.new("ShaderNodeMapRange"); mk.inputs["From Min"].default_value = 0.66; mk.inputs["From Max"].default_value = 0.68
        L(nz.outputs["Fac"], mk.inputs["Value"])
        inv = nt.nodes.new("ShaderNodeMath"); inv.operation = "SUBTRACT"; inv.inputs[0].default_value = 1.0; L(small.outputs["Result"], inv.inputs[1])
        hs = nt.nodes.new("ShaderNodeMath"); hs.operation = "MULTIPLY"; L(inv.outputs["Value"], hs.inputs[0]); L(mk.outputs["Result"], hs.inputs[1])
        smallMask = nt.nodes.new("ShaderNodeMath"); smallMask.operation = "SUBTRACT"; smallMask.inputs[0].default_value = 1.0; L(hs.outputs["Value"], smallMask.inputs[1])
        panel = nt.nodes.new("ShaderNodeMath"); panel.operation = "MULTIPLY"; L(big.outputs["Result"], panel.inputs[0]); L(smallMask.outputs["Value"], panel.inputs[1])
        # colour: seams dark, slight per-panel tone variation and a faint grime noise
        tone = nt.nodes.new("ShaderNodeTexNoise"); tone.inputs["Scale"].default_value = 0.25; tone.inputs["Detail"].default_value = 6
        L(mp.outputs["Vector"], tone.inputs["Vector"])
        tr = nt.nodes.new("ShaderNodeMapRange"); tr.inputs["To Min"].default_value = 0.82; tr.inputs["To Max"].default_value = 1.08
        L(tone.outputs["Fac"], tr.inputs["Value"])
        sc = nt.nodes.new("ShaderNodeMapRange"); sc.inputs["To Min"].default_value = 0.25; sc.inputs["To Max"].default_value = 1.0
        L(panel.outputs["Value"], sc.inputs["Value"])
        k = nt.nodes.new("ShaderNodeMath"); k.operation = "MULTIPLY"; L(tr.outputs["Result"], k.inputs[0]); L(sc.outputs["Result"], k.inputs[1])
        col = nt.nodes.new("ShaderNodeMix"); col.data_type = "RGBA"; col.blend_type = "MULTIPLY"; col.inputs["Factor"].default_value = 1
        col.inputs["A"].default_value = (*color, 1); L(k.outputs["Value"], col.inputs["B"])
        L(col.outputs["Result"], b.inputs["Base Color"])
        # roughness: seams and grime rougher
        rr = nt.nodes.new("ShaderNodeMapRange"); rr.inputs["To Min"].default_value = rough + 0.35; rr.inputs["To Max"].default_value = rough
        L(panel.outputs["Value"], rr.inputs["Value"])
        gr = nt.nodes.new("ShaderNodeMath"); gr.operation = "MULTIPLY_ADD"; L(tone.outputs["Fac"], gr.inputs[0]); gr.inputs[1].default_value = 0.12; L(rr.outputs["Result"], gr.inputs[2])
        L(gr.outputs["Value"], b.inputs["Roughness"])
        # the seams are real grooves for the light
        bp = nt.nodes.new("ShaderNodeBump"); bp.inputs["Strength"].default_value = 0.4; bp.inputs["Distance"].default_value = 0.04
        L(panel.outputs["Value"], bp.inputs["Height"]); L(bp.outputs["Normal"], b.inputs["Normal"])
    return m

M = {
    "paint": mat("Paint red", (0.42, 0.02, 0.025), metal=0.25, rough=0.3, coat=0.6, panels=True),
    "graphite": mat("Graphite", (0.045, 0.05, 0.058), metal=0.75, rough=0.32, panels=True),
    "belly": mat("Belly", (0.02, 0.022, 0.026), metal=0.5, rough=0.45, panels=True),
    "steel": mat("Bare metal", (0.55, 0.56, 0.58), metal=1.0, rough=0.22),
    "dark": mat("Dark metal", (0.03, 0.032, 0.036), metal=0.85, rough=0.3),
    "glass": mat("Canopy glass", (0.004, 0.007, 0.012), metal=0.0, rough=0.03, emit=(0.05, 0.2, 0.45), strength=0.03, coat=1.0),
    "glow": mat("Engine core", (0.0, 0.0, 0.0), emit=(0.55, 0.75, 1.0), strength=40.0),
    "vent": mat("Vent glow", (0.05, 0.02, 0.0), emit=(1.0, 0.42, 0.08), strength=3.0),
    "grille": mat("Grille", (0.01, 0.01, 0.012), metal=0.6, rough=0.6),
    "white": mat("Marking white", (0.8, 0.8, 0.78), rough=0.4),
    "red": mat("Nav red", (0, 0, 0), emit=(1.0, 0.08, 0.05), strength=12.0),
    "green": mat("Nav green", (0, 0, 0), emit=(0.1, 1.0, 0.3), strength=12.0),
    "lamp": mat("Lamp white", (0, 0, 0), emit=(1, 0.97, 0.9), strength=10.0),
    "frame": mat("Canopy frame", (0.03, 0.032, 0.036), metal=0.85, rough=0.3),
}

def obj_from_bm(bm, name, material, smooth=True):
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    o = bpy.data.objects.new(name, me); scene.collection.objects.link(o)
    o.data.materials.append(M[material] if isinstance(material, str) else material)
    if smooth:
        for p in o.data.polygons: p.use_smooth = True
    return o

def finish(o, bevel=0.18, segs=3, angle=35, weighted=True, sub=0):
    if bevel > 0:
        b = o.modifiers.new("Bevel", "BEVEL"); b.width = bevel; b.segments = segs; b.limit_method = "ANGLE"
        b.angle_limit = math.radians(angle); b.harden_normals = True
    if sub: s = o.modifiers.new("Sub", "SUBSURF"); s.levels = sub; s.render_levels = sub
    if weighted:
        w = o.modifiers.new("WN", "WEIGHTED_NORMAL"); w.keep_sharp = True
    return o

def mirror(pts):
    out = list(pts)
    for p in reversed(pts[1:]):
        q = (-p[0], p[1])
        if out[-1] != q: out.append(q)
    if out[0] == out[-1]: out.pop()
    return out

def slab(name, outline, height_fn, material, cuts=4):
    """an outline (x, z in game units) filled, subdivided, and lifted into a top and bottom surface by height_fn(x, z) → (top, bottom) in game units"""
    bm = bmesh.new()
    pts = mirror(outline)
    vs = [bm.verts.new((x, z, 0)) for x, z in pts]
    face = bm.faces.new(vs)
    bmesh.ops.triangulate(bm, faces=[face], quad_method="BEAUTY", ngon_method="BEAUTY")
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=cuts, use_grid_fill=True)
    bmesh.ops.beautify_fill(bm, faces=bm.faces[:], edges=bm.edges[:])
    # extrude down to make the slab, then place every vertex
    ret = bmesh.ops.extrude_face_region(bm, geom=bm.faces[:])
    bottom = {v for v in ret["geom"] if isinstance(v, bmesh.types.BMVert)}
    for v in bm.verts:
        x, z = v.co.x, v.co.y
        top, bot = height_fn(x, z)
        y = bot if v in bottom else top
        v.co = G(x, y, z)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, material)

# ---------------------------------------------------------------- main hull: same outline, wings taper to thin tips
hull_outline = [(0, -0.8), (0.16, -0.42), (0.34, -0.05), (0.68, 0.3), (0.64, 0.44), (0.3, 0.38), (0.18, 0.5)]
def hull_h(x, z):
    a = min(1.0, abs(x) / 0.68)
    half = 0.072 - 0.05 * a ** 1.15                  # 2.6 m thick at the root, under a metre at the tips
    nose = min(1.0, (z + 0.8) / 0.35)               # thinner toward the nose point
    half *= 0.45 + 0.55 * nose
    return (half, -half * 0.85)
hull = finish(slab("Hull", hull_outline, hull_h, "paint", cuts=5), bevel=0.35, segs=4, angle=28)

# ---------------------------------------------------------------- spine: a domed fairing along the top
spine_outline = [(0, -0.52), (0.12, -0.2), (0.22, 0.2), (0.2, 0.47)]
def half_w(outline, z):
    pts = outline
    for (x0, z0), (x1, z1) in zip(pts, pts[1:]):
        if z0 <= z <= z1: return x0 + (x1 - x0) * (z - z0) / max(z1 - z0, 1e-6)
    return pts[-1][0] if z > pts[-1][1] else 0.0
def spine_h(x, z):
    w = max(half_w(spine_outline, z), 1e-4); u = min(1.0, abs(x) / w)
    crest = 0.055 * min(1.0, (z + 0.52) / 0.3) * (1.0 if z < 0.4 else max(0.4, 1 - (z - 0.4) / 0.12))
    return (0.06 + crest * math.sqrt(max(0.0, 1 - u * u)) + 0.012, 0.03)
spine = finish(slab("Spine", spine_outline, spine_h, "graphite", cuts=5), bevel=0.25, segs=3, angle=30)

# ---------------------------------------------------------------- belly keel
belly_outline = [(0, -0.6), (0.14, -0.2), (0.26, 0.25), (0.22, 0.46)]
def belly_h(x, z):
    w = max(half_w(belly_outline, z), 1e-4); u = min(1.0, abs(x) / w)
    deep = 0.045 * min(1.0, (z + 0.6) / 0.4)
    return (-0.03, -0.06 - deep * math.sqrt(max(0.0, 1 - u * u)) - 0.01)
belly = finish(slab("Belly", belly_outline, belly_h, "belly", cuts=4), bevel=0.25, segs=3, angle=30)

# ---------------------------------------------------------------- canopy: a smooth teardrop in the old canopy's place, with frames
c = (0, 0.128, -0.25); half = (0.068, 0.04, 0.2)
bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=24, location=G(*c))
can = bpy.context.object; can.name = "Canopy"
can.scale = (half[0] * S, half[2] * S, half[1] * S)
# taper the back of the bubble into the spine
for v in can.data.vertices:
    if v.co.y > 0: v.co.y *= 1.25; v.co.z *= 1 - 0.35 * v.co.y
can.data.materials.append(M["glass"]); bpy.ops.object.shade_smooth()
# frame: struts cast onto the glass surface, plus a sill where the glass meets the fairing
from mathutils.bvhtree import BVHTree
bpy.context.view_layer.update()
bpy.ops.object.select_all(action="DESELECT"); can.select_set(True); bpy.context.view_layer.objects.active = can
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
bvh = BVHTree.FromObject(can, bpy.context.evaluated_depsgraph_get())
def on_glass(px, py_, from_dir):
    o = Vector((px, py_, 0)) - from_dir * 40
    hit = bvh.ray_cast(o - can.location * 0 , from_dir)
    return hit[0]
def strut(points, w=0.09, m="frame"):
    pts = [p for p in points if p is not None]
    if len(pts) < 2: return
    cd = bpy.data.curves.new("strut", "CURVE"); cd.dimensions = "3D"; cd.bevel_depth = w; cd.bevel_resolution = 3
    sp = cd.splines.new("POLY"); sp.points.add(len(pts) - 1)
    for i, p in enumerate(pts): sp.points[i].co = (*(p + can.location), 1)
    o = bpy.data.objects.new("Frame", cd); scene.collection.objects.link(o); o.data.materials.append(M[m])
hx, hy, hz = half[0] * S, half[2] * S, half[1] * S
down = Vector((0, 0, -1))
def cast_top(lx, ly):   # lx, ly in canopy-local metres
    o = Vector((lx, ly, hz * 3)); h = bvh.ray_cast(o, down); return (h[0] + Vector((0, 0, 0.04))) if h[0] else None
strut([cast_top(0, ly) for ly in [hy * (-0.95 + 1.2 * i / 40) for i in range(41)]], w=0.08)              # centre spine
for fy in (-0.45, 0.05):                                                                                    # cross bows
    ly = fy * hy
    strut([cast_top(lx, ly) for lx in [hx * (-0.97 + 1.94 * i / 30) for i in range(31)]], w=0.1)
sill = []
for i in range(73):
    a = 2 * math.pi * i / 72
    d = Vector((math.cos(a), math.sin(a), 0))
    h = bvh.ray_cast(d * 60 + Vector((0, 0, hz * 0.05)), -d)
    if h[0]: sill.append(h[0] + d * 0.04)
strut(sill, w=0.16, m="graphite")

# ---------------------------------------------------------------- engines: a lofted engine bay blending into three nacelles
def superellipse(cx, cy, a, b, n, count=40):
    pts = []
    for i in range(count):
        t = 2 * math.pi * i / count; c_, s_ = math.cos(t), math.sin(t)
        pts.append((cx + a * math.copysign(abs(c_) ** (2 / n), c_), cy + b * math.copysign(abs(s_) ** (2 / n), s_)))
    return pts
def loft(name, sections, material, cap=True):
    """sections: [(z, [(x, y), ...])] in game units, all with the same point count"""
    bm = bmesh.new(); rings = []
    for z, pts in sections: rings.append([bm.verts.new(G(x, y, z)) for x, y in pts])
    n = len(rings[0])
    for a, b2 in zip(rings, rings[1:]):
        for i in range(n): j = (i + 1) % n; bm.faces.new((a[i], a[j], b2[j], b2[i]))
    if cap: bm.faces.new(rings[0][::-1]); bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, material)
bay = loft("Engine bay", [(0.26, superellipse(0, 0.02, 0.2, 0.055, 2.6)), (0.36, superellipse(0, 0.015, 0.24, 0.07, 3.0)),
                          (0.46, superellipse(0, 0.008, 0.25, 0.075, 3.4)), (0.53, superellipse(0, 0.004, 0.235, 0.065, 3.4))], "graphite")
finish(bay, bevel=0, weighted=False, sub=2)
def lathe(name, profile, at, material, segs=40, cap_front=False):
    """profile: list of (radius, aft) in metres, aft measured toward the tail; spun about the engine axis"""
    bm = bmesh.new(); rings = []
    for r, aft in profile:
        rings.append([bm.verts.new(at + Vector((r * math.cos(2 * math.pi * i / segs), -aft, r * math.sin(2 * math.pi * i / segs)))) for i in range(segs)])
    for a, b2 in zip(rings, rings[1:]):
        for i in range(segs): j = (i + 1) % segs; bm.faces.new((a[i], a[j], b2[j], b2[i]))
    if cap_front: bm.faces.new(rings[0][::-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    return obj_from_bm(bm, name, material)
for x in (-0.15, 0.0, 0.15):
    r = 0.046 * S; at = G(x, 0, 0.6)
    # nacelle cowl: grows out of the bay and tapers toward the exit
    lathe("Nacelle", [(r * 0.9, -7.0), (r * 1.3, -5.6), (r * 1.4, -3.6), (r * 1.36, -1.0), (r * 1.22, 0.3)], at, "graphite")
    # nozzle petals: a bare-metal ring that flares open at the exit, with a hot inner lip
    lathe("Nozzle", [(r * 1.2, -0.2), (r * 1.18, 0.4), (r * 1.26, 1.4), (r * 1.32, 1.9), (r * 1.2, 1.95), (r * 1.06, 1.3), (r * 0.98, 0.2), (r * 0.9, -0.6)], at, "steel")
    for k in range(10):   # the petals' seams
        a0 = 2 * math.pi * k / 10
        bpy.ops.mesh.primitive_cube_add(size=1, location=at + Vector((r * 1.29 * math.cos(a0), -1.15, r * 1.29 * math.sin(a0))))
        p_ = bpy.context.object; p_.scale = (0.05, 1.5, 0.05); p_.rotation_euler = (0, -a0, 0); p_.data.materials.append(M["dark"])
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=r * 0.9, depth=0.1, location=at + Vector((0, 0.5, 0)), rotation=(math.pi / 2, 0, 0))
    bpy.context.object.data.materials.append(M["glow"])
    bpy.ops.mesh.primitive_cone_add(vertices=24, radius1=r * 0.45, depth=1.6, location=at + Vector((0, -0.2, 0)), rotation=(-math.pi / 2, 0, 0))
    bpy.context.object.data.materials.append(M["dark"])   # the centre body

# ---------------------------------------------------------------- recessed glowing vents on the wings and a dorsal intake
def vent(center, w, d, rot_z, slats=7):
    bpy.ops.mesh.primitive_cube_add(size=1, location=center); g = bpy.context.object
    g.scale = (w, d, 0.12); g.rotation_euler = (0, 0, rot_z); g.data.materials.append(M["grille"]); finish(g, bevel=0.05, segs=2)
    for i in range(slats):
        f = (i + 0.5) / slats - 0.5
        off = Vector((f * w * math.cos(rot_z), f * w * math.sin(rot_z), 0.07))
        bpy.ops.mesh.primitive_cube_add(size=1, location=center + off); s = bpy.context.object
        s.scale = (w / slats * 0.42, d * 0.85, 0.04); s.rotation_euler = (0, 0, rot_z); s.data.materials.append(M["vent"])
for sx in (1, -1):
    for z, w in ((0.06, 0.24), (0.2, 0.3)):
        x = sx * (0.3 + z * 0.6)
        top = hull_h(x, z)[0]
        vent(G(x, top + 0.002, z), w * S * 0.8, 0.075 * S * 0.8, sx * 0.62)
spine_top = spine_h(0, 0.25)[0]
vent(G(0, spine_top - 0.004, 0.27), 0.14 * S, 0.1 * S, 0, slats=9)

# ---------------------------------------------------------------- leading-edge strips, wingtip fins, nav lights, landing-light, hull number
for sx in (1, -1):
    # small canted wingtip fin
    bm = bmesh.new()
    prof = [(0.0, 0.0), (0.0, 0.11), (0.05, 0.13), (0.055, 0.09)]      # (height, aft) in game units: a swept fin
    vs = [bm.verts.new((0.0, -(0.32 + a_) * S, h * S)) for h, a_ in prof]
    face = bm.faces.new(vs)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    for v in ext["geom"]:
        if isinstance(v, bmesh.types.BMVert): v.co.x += 0.18
    for v in bm.verts: v.co.x -= 0.09
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    f = obj_from_bm(bm, "Fin", "graphite"); f.location = G(sx * 0.66, hull_h(0.66, 0.36)[0] - 0.004, 0) ; f.location.y = 0
    f.rotation_euler = (0, sx * math.radians(18), 0); finish(f, bevel=0.06, segs=2, angle=30)
    bpy.ops.mesh.primitive_uv_sphere_add(radius=0.22, location=G(sx * 0.665, 0.012, 0.36)); n = bpy.context.object
    n.data.materials.append(M["green" if sx > 0 else "red"])
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.25, location=G(0, 0.0, -0.805)); bpy.context.object.data.materials.append(M["lamp"])
# hull number on the left wing
bpy.ops.object.text_add(location=G(-0.42, hull_h(-0.42, 0.2)[0] + 0.0012, 0.2))
t = bpy.context.object; t.data.body = "K-07"; t.data.extrude = 0.01; t.data.size = 2.4
t.rotation_euler = (0, 0, math.radians(180 - 35)); t.data.materials.append(M["white"])
# a red-and-white stripe on the spine
for i, mname in enumerate(("white", "paint", "white")):
    bpy.ops.mesh.primitive_cube_add(size=1, location=G(0, spine_h(0, -0.3)[0] + 0.0005, -0.3 + i * 0.012)); s = bpy.context.object
    s.scale = (0.12 * S, 0.3, 0.008 * S); s.data.materials.append(M[mname])

# ---------------------------------------------------------------- engineering details
# cockpit fairing: blends the canopy into the spine
bpy.ops.mesh.primitive_uv_sphere_add(segments=40, ring_count=20, location=G(0, 0.105, -0.2))
fair = bpy.context.object; fair.name = "Cockpit fairing"; fair.scale = (0.085 * S, 0.27 * S, 0.034 * S)
fair.data.materials.append(M["graphite"]); bpy.ops.object.shade_smooth()
# intakes at the wing roots: a cowl with a dark mouth and a splitter
for sx in (1, -1):
    base = G(sx * 0.15, 0.07, -0.1)
    bpy.ops.mesh.primitive_cube_add(size=1, location=base); cw = bpy.context.object
    cw.scale = (0.06 * S, 0.16 * S, 0.035 * S); cw.rotation_euler = (math.radians(4), 0, sx * math.radians(-12))
    cw.data.materials.append(M["graphite"]); finish(cw, bevel=0.35, segs=3, angle=40)
    bpy.ops.mesh.primitive_cube_add(size=1, location=base + Vector((0, -0.16 * S * 0.5 - 0.02, 0))); mo = bpy.context.object
    mo.scale = (0.05 * S, 0.12, 0.027 * S); mo.rotation_euler = cw.rotation_euler; mo.data.materials.append(M["grille"])
    bpy.ops.mesh.primitive_cube_add(size=1, location=base + Vector((0, -0.16 * S * 0.5 - 0.06, 0))); sp = bpy.context.object
    sp.scale = (0.004 * S, 0.3, 0.03 * S); sp.rotation_euler = cw.rotation_euler; sp.data.materials.append(M["steel"])
# twin cannons slung under the wings
for sx in (1, -1):
    x = sx * 0.3
    for zz, r, L, m in ((-0.02, 0.32, 0.26 * S, "graphite"), (-0.2, 0.16, 0.12 * S, "steel")):
        bpy.ops.mesh.primitive_cylinder_add(vertices=20, radius=r, depth=L, location=G(x, -0.045, zz), rotation=(math.pi / 2, 0, 0))
        o = bpy.context.object; o.data.materials.append(M[m]); finish(o, bevel=0.06, segs=2, angle=40)
    bpy.ops.mesh.primitive_torus_add(major_radius=0.2, minor_radius=0.06, location=G(x, -0.045, -0.262), rotation=(math.pi / 2, 0, 0))
    bpy.context.object.data.materials.append(M["dark"])
    bpy.ops.mesh.primitive_cube_add(size=1, location=G(x, -0.03, 0.0)); py = bpy.context.object      # pylon
    py.scale = (0.25, 0.14 * S, 0.02 * S); py.data.materials.append(M["dark"]); finish(py, bevel=0.05, segs=2)
# lift-jet ports on the belly: dark rings with a faint glow
for p in ((0.2, -0.15), (-0.2, -0.15), (0.26, 0.3), (-0.26, 0.3)):
    y = hull_h(*p)[1] - 0.003
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.035 * S * 1.15, depth=0.25, location=G(p[0], y, p[1]))
    bpy.context.object.data.materials.append(M["dark"])
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=0.035 * S * 0.8, depth=0.27, location=G(p[0], y, p[1]))
    bpy.context.object.data.materials.append(mat("Lift glow", (0, 0, 0), emit=(0.45, 0.65, 1.0), strength=2.0))
# a short antenna and a sensor blister behind the canopy
bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=0.05, depth=2.2, location=G(0.04, spine_h(0.04, 0.12)[0] + 0.03, 0.12), rotation=(math.radians(-20), 0, 0))
bpy.context.object.data.materials.append(M["steel"])
bpy.ops.mesh.primitive_uv_sphere_add(radius=0.55, location=G(-0.05, spine_h(-0.05, 0.05)[0], 0.05)); bl = bpy.context.object
bl.scale = (1, 1.4, 0.55); bl.data.materials.append(M["dark"]); bpy.ops.object.shade_smooth()

# ---------------------------------------------------------------- decals: printed onto the hull surface
def decal(poly, material, lift=0.0008):
    bm = bmesh.new()
    vs = [bm.verts.new((x, z, 0)) for x, z in poly]
    f = bm.faces.new(vs); bmesh.ops.triangulate(bm, faces=[f])
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=3, use_grid_fill=True)
    for v in bm.verts:
        x, z = v.co.x, v.co.y; v.co = G(x, hull_h(x, z)[0] + lift, z)
    return obj_from_bm(bm, "Decal", material)
hz_mat = mat("Hazard", (0.9, 0.55, 0.05), rough=0.45)
for sx in (1, -1):
    # a white band across each wing, just inboard of the tip, following the sweep
    decal([(sx * 0.52, 0.17), (sx * 0.56, 0.21), (sx * 0.5, 0.4), (sx * 0.46, 0.39)][::sx], "white")
    decal([(sx * 0.585, 0.24), (sx * 0.6, 0.255), (sx * 0.555, 0.415), (sx * 0.54, 0.41)][::sx], "white")
    # hazard chevrons ahead of the wing-root intakes
    for i in range(3):
        z0 = -0.2 - i * 0.02
        decal([(sx * 0.13, z0), (sx * 0.17, z0 - 0.012), (sx * 0.17, z0 - 0.006), (sx * 0.13, z0 + 0.006)][::sx], hz_mat)
    # NO STEP stencil on the wing root
    bpy.ops.object.text_add(location=G(sx * 0.28, hull_h(0.28, 0.32)[0] + 0.001, 0.32))
    t2 = bpy.context.object; t2.data.body = "NO STEP"; t2.data.size = 0.7; t2.data.extrude = 0.005
    t2.rotation_euler = (0, 0, 0); t2.data.align_x = "CENTER"; t2.data.materials.append(M["white"])

# ---------------------------------------------------------------- export for the game

if True:   # studio lighting and camera (saved into the .blend too)
    # studio: dark backdrop, key sun, cool rim, soft fill
    w = bpy.data.worlds.new("World"); scene.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.03, 0.035, 0.05, 1)
    w.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
    nt_ = w.node_tree; bg = nt_.nodes["Background"]
    sky = nt_.nodes.new("ShaderNodeTexSky"); sky.sky_type = "NISHITA"; sky.sun_elevation = math.radians(25)
    sbg = nt_.nodes.new("ShaderNodeBackground"); sbg.inputs["Strength"].default_value = 0.25
    nt_.links.new(sky.outputs["Color"], sbg.inputs["Color"])
    lp = nt_.nodes.new("ShaderNodeLightPath"); mx = nt_.nodes.new("ShaderNodeMixShader")
    nt_.links.new(lp.outputs["Is Camera Ray"], mx.inputs["Fac"])
    nt_.links.new(sbg.outputs["Background"], mx.inputs[1]); nt_.links.new(bg.outputs["Background"], mx.inputs[2])
    nt_.links.new(mx.outputs["Shader"], nt_.nodes["World Output"].inputs["Surface"])
    def light(kind, loc, energy, color=(1, 1, 1), size=None, rot=None):
        ld = bpy.data.lights.new(kind, kind); ld.energy = energy; ld.color = color
        if size and kind == "AREA": ld.size = size
        o = bpy.data.objects.new(kind, ld); scene.collection.objects.link(o); o.location = loc
        if rot: o.rotation_euler = rot
        return o
    light("SUN", (0, 0, 50), 6.0, (1.0, 0.96, 0.9), rot=(math.radians(40), math.radians(-25), math.radians(35)))
    light("AREA", (-40, 30, 20), 25000, (0.55, 0.7, 1.0), size=20).rotation_euler = (math.radians(60), 0, math.radians(-120))
    light("AREA", (30, -40, -10), 9000, (1.0, 0.85, 0.75), size=25).rotation_euler = (math.radians(110), 0, math.radians(40))
    scene.render.engine = "BLENDER_EEVEE_NEXT" if "BLENDER_EEVEE_NEXT" in [e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items] else "BLENDER_EEVEE"
    try:
        scene.eevee.use_raytracing = True
        scene.eevee.taa_render_samples = 64
    except Exception: pass
    scene.view_settings.view_transform = "AgX"; scene.view_settings.look = "AgX - Punchy"
    scene.render.resolution_x, scene.render.resolution_y = 1400, 860
    cam = bpy.data.objects.new("Cam", bpy.data.cameras.new("Cam")); scene.collection.objects.link(cam); scene.camera = cam
    cam.data.lens = 55
    target = Vector((0, 4, 0))
    def shoot(name, pos):
        if not DO_RENDER: return
        cam.location = pos
        d = target - cam.location; cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = os.path.join(OUT, name); bpy.ops.render.render(write_still=True)
    scene.render.resolution_x, scene.render.resolution_y = 1920, 1080
    shoot("hero.png", Vector((38, -46, 14)))
    scene.render.resolution_x, scene.render.resolution_y = 1400, 860
    shoot("front34.png", Vector((48, -62, 26)))
    shoot("rear34.png", Vector((-45, 70, 22)))
    shoot("low.png", Vector((35, -55, -14)))
    shoot("top.png", Vector((0.1, 6, 150)))
    shoot("side.png", Vector((90, 4, 6)))
for o in scene.objects: o.select_set(False)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "kestrel.blend"))
print("done", OUT)
