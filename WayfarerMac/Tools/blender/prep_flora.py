# Wayfarer · export a pack of plants (trees, bushes, flowers with alpha-cutout leaves) for the game.
#   Blender -b -P prep_flora.py -- <src.glb> <out_dir> [tex=1024]
# Objects are grouped into models by the name before the first "_" (Sketchfab exports name them
# "<model>_<material>_<n>"). Each model is moved so its base centre sits at the origin and written as one or more parts:
#   <out>/<model>_<k>.bin   float32 triangles, 8 floats per vertex: position (metres, game axes x right, y up, z back),
#                           normal, uv (v flipped for Metal)
#   <out>/<model>_<k>.png   that part's base-colour texture with its alpha (leaf cut-outs)
#   <out>/flora.json        [{name, height, parts: [{bin, png, cutout}]}]
import bpy, sys, os, json, struct
import numpy as np
from mathutils import Vector
a = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = a[0], a[1]
TEX = int(dict(kv.split("=", 1) for kv in a[2:]).get("tex", 1024))
os.makedirs(OUT, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
sc = bpy.context.scene
dg = bpy.context.evaluated_depsgraph_get()
groups = {}
for o in sc.objects:
    if o.type != "MESH": continue
    groups.setdefault(o.name.split("_")[0], []).append(o)

def base_texture(mat):
    if not mat or not mat.use_nodes: return None
    for n in mat.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            l = n.inputs["Base Color"].links
            if l and l[0].from_node.type == "TEX_IMAGE": return l[0].from_node.image
    for n in mat.node_tree.nodes:
        if n.type == "TEX_IMAGE" and n.image: return n.image
    return None

manifest = []
for name, objs in sorted(groups.items()):
    # bounds of the whole model, then the base centre (trunk foot) as the origin
    lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c); lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    # trunk foot: the centre of the lowest 15% of the geometry, so a leaning crown doesn't shift the base
    foot = Vector((0, 0, 0)); nf = 0
    for o in objs:
        ev = o.evaluated_get(dg); me = ev.to_mesh()
        for v in me.vertices:
            w = o.matrix_world @ v.co
            if w.z < lo.z + (hi.z - lo.z) * 0.15: foot += w; nf += 1
        ev.to_mesh_clear()
    foot = foot / max(nf, 1); origin = Vector((foot.x, foot.y, lo.z))
    parts = []
    for k, o in enumerate(objs):
        ev = o.evaluated_get(dg); me = ev.to_mesh(); me.calc_loop_triangles()
        uvl = me.uv_layers.active.data if me.uv_layers.active else None
        nm = o.matrix_world.to_3x3().inverted().transposed()
        buf = bytearray()
        for tri in me.loop_triangles:
            for li in tri.loops:
                v = me.vertices[me.loops[li].vertex_index]
                p = o.matrix_world @ v.co - origin
                n = (nm @ me.loops[li].normal).normalized() if hasattr(me.loops[li], "normal") else (nm @ v.normal).normalized()
                uv = uvl[li].uv if uvl else (0.0, 0.0)
                buf += struct.pack("<8f", p.x, p.z, -p.y, n.x, n.z, -n.y, uv[0], 1 - uv[1])
        mat = o.data.materials[0] if o.data.materials else None
        img = base_texture(mat)
        part = {"bin": f"{name}_{k}.bin", "png": None, "cutout": False}
        open(os.path.join(OUT, part["bin"]), "wb").write(buf)
        if img:
            im = img.copy(); im.scale(TEX, TEX)
            im.filepath_raw = os.path.join(OUT, f"{name}_{k}.png"); im.file_format = "PNG"; im.save()
            part["png"] = f"{name}_{k}.png"
            # cut-out if the texture has real transparency
            arr = np.empty(len(im.pixels), dtype=np.float32); im.pixels.foreach_get(arr)
            part["cutout"] = bool((arr[3::4] < 0.5).mean() > 0.01)
        ev.to_mesh_clear()
        parts.append(part)
        print("PART", name, k, len(me.loop_triangles) if False else len(buf) // 96, "tris", part)
    manifest.append({"name": name, "height": round(hi.z - lo.z, 3), "parts": parts})
json.dump(manifest, open(os.path.join(OUT, "flora.json"), "w"), indent=1)
print("FLORA", len(manifest), "models")
