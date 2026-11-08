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
        # panel seams: two offset brick grids in object space (metres) darken thin lines and roughen them
        tc = nt.nodes.new("ShaderNodeTexCoord")
        mp = nt.nodes.new("ShaderNodeMapping"); mp.inputs["Scale"].default_value = (1, 1, 1)
        nt.links.new(tc.outputs["Object"], mp.inputs["Vector"])
        def bricks(scale, w, h, off):
            br = nt.nodes.new("ShaderNodeTexBrick")
            br.inputs["Scale"].default_value = scale
            br.inputs["Mortar Size"].default_value = 0.012
            br.inputs["Brick Width"].default_value = w; br.inputs["Row Height"].default_value = h
            br.offset = off
            br.inputs["Color1"].default_value = (1, 1, 1, 1); br.inputs["Color2"].default_value = (0.92, 0.92, 0.92, 1)
            br.inputs["Mortar"].default_value = (0, 0, 0, 1)
            nt.links.new(mp.outputs["Vector"], br.inputs["Vector"])
            return br
        b1 = bricks(0.11, 0.55, 0.28, 0.37)
        b1.inputs["Mortar Size"].default_value = 0.008
        b1.inputs["Mortar"].default_value = (0.45, 0.45, 0.45, 1)
        b1.inputs["Color2"].default_value = (0.9, 0.9, 0.9, 1)
        mix = b1
        tint = nt.nodes.new("ShaderNodeMix"); tint.data_type = "RGBA"; tint.blend_type = "MULTIPLY"; tint.inputs["Factor"].default_value = 1
        tint.inputs["A"].default_value = (*color, 1)
        nt.links.new(b1.outputs["Color"], tint.inputs["B"])
        nt.links.new(tint.outputs["Result"], b.inputs["Base Color"])
        mix_out = b1.outputs["Color"]
        # seams are rougher
        inv = nt.nodes.new("ShaderNodeMath"); inv.operation = "MULTIPLY_ADD"
        bw = nt.nodes.new("ShaderNodeRGBToBW"); nt.links.new(mix_out, bw.inputs["Color"])
        nt.links.new(bw.outputs["Val"], inv.inputs[0]); inv.inputs[1].default_value = -0.5; inv.inputs[2].default_value = rough + 0.5
        nt.links.new(inv.outputs["Value"], b.inputs["Roughness"])
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
# frame: a centre rib and two hoops
def hoop(fz, w=0.16):
    t = (fz) ; r = math.sqrt(max(0.0, 1 - t * t))
    bpy.ops.mesh.primitive_torus_add(major_radius=1, minor_radius=w / (half[0] * S) / 2, major_segments=48, minor_segments=8,
                                     location=G(c[0], c[1], c[2] + fz * half[2]), rotation=(math.pi / 2, 0, 0))
    o = bpy.context.object; o.scale = (half[0] * S * r * 1.02, half[1] * S * r * 1.04, half[0] * S * r * 1.02)
    o.data.materials.append(M["dark"]); bpy.ops.object.shade_smooth(); return o
for fz in (-0.35, 0.25): hoop(fz)
bpy.ops.mesh.primitive_cylinder_add(vertices=8, radius=0.07, depth=half[2] * S * 1.7, location=G(c[0], c[1] + half[1] * 0.98, c[2] + 0.01), rotation=(math.pi / 2, 0, 0))
rib = bpy.context.object; rib.data.materials.append(M["dark"])

# ---------------------------------------------------------------- engines: three flared nozzles in a rounded housing
bpy.ops.mesh.primitive_cube_add(size=1, location=G(0, 0.0, 0.5))
house = bpy.context.object; house.name = "Engine housing"; house.scale = (0.52 * S, 0.1 * S, 0.14 * S)
house.data.materials.append(M["graphite"]); finish(house, bevel=0.6, segs=4, angle=60)
def lathe(name, profile, at, material, segs=40):
    """profile: list of (radius, z) in metres, spun about the engine axis (game z)"""
    bm = bmesh.new()
    rings = []
    for r, zz in profile:
        ring = [bm.verts.new((r * math.cos(2 * math.pi * i / segs), zz, r * math.sin(2 * math.pi * i / segs))) for i in range(segs)]
        rings.append(ring)
    for a, b in zip(rings, rings[1:]):
        for i in range(segs):
            j = (i + 1) % segs
            bm.faces.new((a[i], a[j], b[j], b[i]))
    for v in bm.verts: v.co += at
    o = obj_from_bm(bm, name, material); finish(o, bevel=0, weighted=False)
    return o
for x in (-0.15, 0.0, 0.15):
    r = 0.046 * S
    at = G(x, 0, 0.6)
    # outer shroud flaring out toward the exhaust, inner throat, glowing core
    lathe("Nozzle", [(r * 1.05, -2.6), (r * 1.1, -1.2), (r * 1.22, 0.4), (r * 1.3, 0.9), (r * 1.18, 1.0), (r * 0.95, 0.8), (r * 0.8, -0.6)], at, "steel")
    for k in range(3):
        lathe("Ring", [(r * (1.115 + 0.002 * k), -1.0 + k * 0.45), (r * 1.14, -0.85 + k * 0.45), (r * 1.115, -0.7 + k * 0.45)], at, "dark")
    bpy.ops.mesh.primitive_cylinder_add(vertices=40, radius=r * 0.8, depth=0.1, location=at + Vector((0, -0.55, 0)), rotation=(math.pi / 2, 0, 0))
    core = bpy.context.object; core.data.materials.append(M["glow"])

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
    bpy.ops.mesh.primitive_cube_add(size=1, location=G(sx * 0.655, 0.03, 0.37)); f = bpy.context.object
    f.scale = (0.12, 0.12 * S, 0.05 * S); f.rotation_euler = (math.radians(-12), sx * math.radians(14), 0)
    f.data.materials.append(M["graphite"]); finish(f, bevel=0.08, segs=2)
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
# engine nacelles: a rounded cowl round each nozzle instead of a plain box
for x in (-0.15, 0.0, 0.15):
    bpy.ops.mesh.primitive_cylinder_add(vertices=32, radius=0.046 * S * 1.32, depth=0.2 * S, location=G(x, 0.0, 0.47), rotation=(math.pi / 2, 0, 0))
    cowl = bpy.context.object; cowl.data.materials.append(M["graphite"]); finish(cowl, bevel=0.3, segs=3, angle=40)
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

# ---------------------------------------------------------------- export for the game
for o in scene.objects: o.select_set(o.type in {"MESH", "FONT"})
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "kestrel.blend"))

if DO_RENDER:
    # studio: dark backdrop, key sun, cool rim, soft fill
    w = bpy.data.worlds.new("World"); scene.world = w; w.use_nodes = True
    w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.03, 0.035, 0.05, 1)
    w.node_tree.nodes["Background"].inputs["Strength"].default_value = 1.0
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
print("done", OUT)
