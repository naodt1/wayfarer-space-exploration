# Blender -b -P inspect_import.py -- <model.glb> <out_dir>
import bpy, sys, os, math
from mathutils import Vector
a = sys.argv[sys.argv.index("--") + 1:]; SRC, OUT = a[0], a[1]; os.makedirs(OUT, exist_ok=True)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
sc = bpy.context.scene
meshes = [o for o in sc.objects if o.type == "MESH"]
lo = Vector((1e9,)*3); hi = Vector((-1e9,)*3); tris = 0
dg = bpy.context.evaluated_depsgraph_get()
for o in meshes:
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c); lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    me = o.evaluated_get(dg).to_mesh(); me.calc_loop_triangles(); tris += len(me.loop_triangles)
print("objects", len(meshes), "triangles", tris)
print("bounds", tuple(round(x, 3) for x in lo), tuple(round(x, 3) for x in hi), "size", tuple(round(x, 3) for x in hi - lo))
for m in bpy.data.materials:
    if not m.use_nodes: continue
    texs = [n.image.name + f" {n.image.size[0]}" for n in m.node_tree.nodes if n.type == "TEX_IMAGE" and n.image]
    print("material", m.name, texs)
for o in meshes[:30]: print("obj", o.name, len(o.data.polygons))
# renders from each axis
ctr = (lo + hi) / 2; R = (hi - lo).length
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True; w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.3, 0.32, 0.36, 1)
ld = bpy.data.lights.new("s", "SUN"); ld.energy = 4; so = bpy.data.objects.new("s", ld); sc.collection.objects.link(so); so.rotation_euler = (0.7, 0.3, 0.8)
cam = bpy.data.objects.new("c", bpy.data.cameras.new("c")); sc.collection.objects.link(cam); sc.camera = cam
cam.data.type = "ORTHO"; cam.data.ortho_scale = R * 1.05
sc.render.engine = "BLENDER_EEVEE_NEXT"; sc.render.resolution_x = 800; sc.render.resolution_y = 600
for name, d in (("px", (1,0,0)), ("py", (0,1,0)), ("pz", (0,0,1)), ("iso", (1,-1,0.7))):
    cam.location = ctr + Vector(d).normalized() * R * 2
    cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y" if name != "pz" else "Y").to_euler()
    sc.render.filepath = os.path.join(OUT, name + ".png"); bpy.ops.render.render(write_still=True)
