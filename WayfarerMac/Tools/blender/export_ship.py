# Wayfarer · export a ship built in Blender for the game.
#   Blender -b <ship>.blend -P export_ship.py -- <out_dir> <name> <metres_per_game_unit> [texture_size]
# Writes:
#   <name>.mesh      little-endian float32, 9 floats per vertex, 3 vertices per triangle:
#                    position (game model units: x right, y up, z aft), normal, uv (v flipped for Metal), material id
#   <name>_albedo.png   RGB base colour (sRGB), A roughness
#   <name>_normal.png   object-space normal in GAME axes, encoded n*0.5+0.5 (RGB)
# Material ids: 20 canopy frame (hidden from the pilot's seat), 17 painted, 18 metal, 3 glass, 5 engine glow, 19 vent glow, 12 lamp, 2 dark (nav-light lenses: the game draws its own glows)

import bpy, bmesh, sys, os, struct, math

argv = sys.argv[sys.argv.index("--") + 1:]
OUT, NAME, S = argv[0], argv[1], float(argv[2])
TEX = int(argv[3]) if len(argv) > 3 and argv[3].isdigit() else 2048
os.makedirs(OUT, exist_ok=True)
scene = bpy.context.scene

def game_id(m):
    n = (m.name if m else "").lower()
    if "glass" in n: return 3
    if "canopy frame" in n: return 20
    if "engine core" in n: return 5
    if "vent glow" in n or "lift glow" in n: return 19
    if "lamp" in n: return 12
    if "nav" in n: return 2
    if any(k in n for k in ("bare metal", "dark metal", "grille")): return 18
    return 17

# ---- one object: text to mesh, modifiers applied, joined
for o in list(scene.objects):
    if o.type not in {"MESH", "FONT", "CURVE"}: bpy.data.objects.remove(o)
bpy.ops.object.select_all(action="SELECT")
bpy.context.view_layer.objects.active = [o for o in scene.objects if o.type == "MESH"][0]
bpy.ops.object.convert(target="MESH")
bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# ---- UVs: smart projection into one atlas
# a fresh UV layer for the bake atlas; the model's own UVs stay the render layer its textures read from
uvs = ob.data.uv_layers
if len(uvs) == 0: uvs.new(name="UVMap")
for l in uvs: l.active_render = l == uvs[0]
KEEP_UV = "keepuv" in argv          # a downloaded model with a good texture layout: bake onto its own UVs
if KEEP_UV:
    uvs[0].name = "BakeUV"; uvs.active = uvs[0]
else:
    bake_uv = uvs.new(name="BakeUV"); uvs.active = bake_uv
    uvs[0].active_render = True
    bpy.ops.object.mode_set(mode="EDIT"); bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(55), island_margin=0.003, area_weight=0.0)
    bpy.ops.object.mode_set(mode="OBJECT")

# ---- bake colour, roughness and normals with Cycles
scene.render.engine = "CYCLES"; scene.cycles.samples = 4
try:
    scene.cycles.device = "GPU"
    prefs = bpy.context.preferences.addons["cycles"].preferences; prefs.compute_device_type = "METAL"; prefs.get_devices()
    for d in prefs.devices: d.use = True
except Exception: pass
def new_img(name, srgb=True):
    img = bpy.data.images.new(name, TEX, TEX, alpha=False, float_buffer=False)
    img.colorspace_settings.name = "sRGB" if srgb else "Non-Color"; return img
for i, m in enumerate(ob.data.materials):          # empty slots get a plain grey material so every face can bake
    if m is None:
        g = bpy.data.materials.new("Filler grey"); g.use_nodes = True; ob.data.materials[i] = g
def target(img):
    for m in ob.data.materials:
        nt = m.node_tree
        n = nt.nodes.get("BAKE_TARGET") or nt.nodes.new("ShaderNodeTexImage"); n.name = "BAKE_TARGET"; n.image = img
        nt.nodes.active = n
bk = scene.render.bake; bk.margin = 6; bk.use_clear = True
# glTF models often leave metalness out, which means "fully metallic" — and a metal's diffuse colour is black.
# So: bake the metalness on its own (routed through emission), then bake colour with metalness switched off.
def principled(m):
    return [n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED"] if m and m.use_nodes else []
saved = []
for m in ob.data.materials:
    for b in principled(m):
        nt = m.node_tree
        mi, ec, es = b.inputs["Metallic"], b.inputs["Emission Color"], b.inputs["Emission Strength"]
        saved.append((nt, b, mi.links[0].from_socket if mi.is_linked else None, mi.default_value,
                      ec.links[0].from_socket if ec.is_linked else None, tuple(ec.default_value), es.default_value))
def route_metal():
    for nt, b, msrc, mval, esrc, ecol, est in saved:
        ec = b.inputs["Emission Color"]
        for l in list(ec.links): nt.links.remove(l)
        if msrc is not None: nt.links.new(msrc, ec)
        else:
            textured = any(n.type == 'TEX_IMAGE' and n.name != 'BAKE_TARGET' for n in nt.nodes)
            v = 0.0 if (mval >= 0.999 and textured) else mval   # an unset glTF metalness (default 1) almost always means 'not metal'
            ec.default_value = (v, v, v, 1)
        b.inputs["Emission Strength"].default_value = 1.0
def restore_emission():
    for nt, b, msrc, mval, esrc, ecol, est in saved:
        ec = b.inputs["Emission Color"]
        for l in list(ec.links): nt.links.remove(l)
        if esrc is not None: nt.links.new(esrc, ec)
        ec.default_value = ecol; b.inputs["Emission Strength"].default_value = est
def metal_off():
    for nt, b, *_ in saved:
        mi = b.inputs["Metallic"]
        for l in list(mi.links): nt.links.remove(l)
        mi.default_value = 0.0
METAL_TEX = None
if not KEEP_UV:
    route_metal(); mtl = new_img("mtl", False); target(mtl); bpy.ops.object.bake(type="EMIT"); METAL_TEX = mtl
    restore_emission()
metal_off()
alb = new_img("alb"); target(alb)
bk.use_pass_direct = False; bk.use_pass_indirect = False; bk.use_pass_color = True
bpy.ops.object.bake(type="DIFFUSE")
rgh = new_img("rgh", False); target(rgh); bpy.ops.object.bake(type="ROUGHNESS")
nrm = new_img("nrm", False); target(nrm); bk.normal_space = "OBJECT"; bpy.ops.object.bake(type="NORMAL")
# emission (lit windows, screens): baked only when some material glows
def glows(m):
    if not m or not m.use_nodes: return False
    for n in m.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            st = n.inputs["Emission Strength"].default_value
            if n.inputs["Emission Color"].is_linked and st > 0: return True
            if st > 0 and max(n.inputs["Emission Color"].default_value[:3]) > 0.01: return True
        if n.type == "EMISSION": return True
    return False
HAS_EMIT = any(glows(m) for m in ob.data.materials)
if HAS_EMIT:
    emt = new_img("emt"); target(emt); bpy.ops.object.bake(type="EMIT")

# ---- write the textures (normal converted to game axes: game x = bx, y = bz, z = -by)
import numpy as np
def px(img): return np.array(img.pixels[:], dtype=np.float32).reshape(TEX, TEX, 4)
A, R, N = px(alb), px(rgh), px(nrm)
# metalness and ambient occlusion: from a glTF ORM texture (R occlusion, G roughness, B metal) when the model has one,
# carried into normal-map alpha as 0.5 + 0.5 * metal (alpha below 0.25 means "decide by material id" in the game)
metal = np.full((TEX, TEX), 0.1 / 1.0, np.float32); ao = np.ones((TEX, TEX), np.float32); have_orm = False
if KEEP_UV:
    for m in ob.data.materials:
        for l in m.node_tree.links:
            if l.to_socket.name == "Metallic" and l.from_node.type == "SEPARATE_COLOR":
                src = l.from_node.inputs[0].links[0].from_node
                if src.type == "TEX_IMAGE" and src.image:
                    im = src.image.copy(); im.scale(TEX, TEX)
                    orm = np.array(im.pixels[:], dtype=np.float32).reshape(TEX, TEX, 4)
                    ao, metal, have_orm = orm[:, :, 0], 0.5 + 0.5 * orm[:, :, 2], True
                    print("ORM texture", src.image.name)
                    break
        if have_orm: break
if METAL_TEX is not None: metal = 0.5 + 0.5 * px(METAL_TEX)[:, :, 0]
A = A.copy(); A[:, :, :3] *= (0.3 + 0.7 * ao)[:, :, None]       # occlusion darkens crevices and seams
outA = np.concatenate([A[:, :, :3], R[:, :, :1]], axis=2)
n = N[:, :, :3] * 2 - 1
g = np.stack([n[:, :, 0], n[:, :, 2], -n[:, :, 1]], axis=2) * 0.5 + 0.5
outN = np.concatenate([g, metal[:, :, None]], axis=2)
def save(arr, path, srgb):
    img = bpy.data.images.new("out", TEX, TEX, alpha=True)
    img.colorspace_settings.name = "sRGB" if srgb else "Non-Color"
    img.pixels[:] = arr.ravel().tolist() if False else arr.ravel()
    img.filepath_raw = path; img.file_format = "PNG"; img.save()
save(outA, os.path.join(OUT, f"{NAME}_albedo.png"), True)
save(outN, os.path.join(OUT, f"{NAME}_normal.png"), False)
emit_path = os.path.join(OUT, f"{NAME}_emit.png")
if HAS_EMIT:
    E = px(emt)
    if E[:, :, :3].max() > 0.02:
        save(np.concatenate([np.clip(E[:, :, :3], 0, 1), np.ones((TEX, TEX, 1), np.float32)], axis=2), emit_path, True)
        print("emission baked")
elif os.path.exists(emit_path): os.remove(emit_path)

# ---- the mesh
me = ob.data
me.calc_loop_triangles()
uvl = me.uv_layers["BakeUV"].data
cn = me.corner_normals if hasattr(me, "corner_normals") else None
buf = bytearray()
ids = [game_id(m) for m in me.materials]
for tri in me.loop_triangles:
    mid = ids[tri.material_index] if ids else 17
    for li in tri.loops:
        v = me.vertices[me.loops[li].vertex_index].co
        nn = cn[li].vector if cn is not None else me.loops[li].normal
        uv = uvl[li].uv
        buf += struct.pack("<9f", v.x / S, v.z / S, -v.y / S, nn.x, nn.z, -nn.y, uv.x, 1 - uv.y, float(mid))
open(os.path.join(OUT, f"{NAME}.mesh"), "wb").write(buf)
# skinned characters: 4 joint indices + 4 weights per written vertex (same order as the .mesh), from the vertex groups
if "skin" in argv:
    import json
    names = json.load(open(os.path.join(OUT, f"{NAME}_jointnames.json")))
    jix = {n: i for i, n in enumerate(names)}
    gname = {g.index: g.name for g in ob.vertex_groups}
    wb = bytearray()
    for tri in me.loop_triangles:
        for li in tri.loops:
            v = me.vertices[me.loops[li].vertex_index]
            gs = sorted(((g.weight, jix[gname[g.group]]) for g in v.groups if gname.get(g.group) in jix and g.weight > 0), reverse=True)[:4]
            tot = sum(w for w, _ in gs) or 1.0
            gs = [(w / tot, j) for w, j in gs] + [(0.0, 0)] * (4 - len(gs))
            if not any(w > 0 for w, _ in gs): gs = [(1.0, 0)] + [(0.0, 0)] * 3
            wb += struct.pack("<4f4f", *[float(j) for _, j in gs], *[w for w, _ in gs])
    open(os.path.join(OUT, f"{NAME}.weights"), "wb").write(wb)
    print("weights written for", len(me.loop_triangles) * 3, "vertices")
print("exported", len(me.loop_triangles), "triangles to", OUT)
