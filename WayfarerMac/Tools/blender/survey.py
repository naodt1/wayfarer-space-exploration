# Blender -b -P survey.py -- <model.glb> <out.png>
import bpy, sys, os
from mathutils import Vector
a = sys.argv[sys.argv.index("--") + 1:]; SRC, OUT = a[0], a[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
sc = bpy.context.scene; dg = bpy.context.evaluated_depsgraph_get()
lo = Vector((1e9,)*3); hi = Vector((-1e9,)*3); tris = 0
for o in sc.objects:
    if o.type != "MESH": continue
    for c in o.bound_box:
        w = o.matrix_world @ Vector(c); lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    me = o.evaluated_get(dg).to_mesh(); me.calc_loop_triangles(); tris += len(me.loop_triangles)
sz = hi - lo
print(f"SURVEY {os.path.basename(SRC)} tris {tris} size x{sz.x:.2f} y{sz.y:.2f} z{sz.z:.2f} anims {len(bpy.data.actions)}")
ctr = (lo + hi) / 2; R = sz.length
w = bpy.data.worlds.new("W"); sc.world = w; w.use_nodes = True; w.node_tree.nodes["Background"].inputs["Color"].default_value = (0.35, 0.37, 0.4, 1)
ld = bpy.data.lights.new("s", "SUN"); ld.energy = 3; so = bpy.data.objects.new("s", ld); sc.collection.objects.link(so); so.rotation_euler = (0.8, 0.2, 0.7)
cam = bpy.data.objects.new("c", bpy.data.cameras.new("c")); sc.collection.objects.link(cam); sc.camera = cam
cam.data.clip_end = R * 20 + 100
big = "skybox" in SRC
if big:
    cam.location = ctr; cam.rotation_euler = (1.5, 0, 0.3); cam.data.lens = 18
else:
    cam.location = ctr + Vector((1, -1.3, 0.8)).normalized() * R * 1.2; cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y").to_euler(); cam.data.lens = 40
sc.render.engine = "BLENDER_EEVEE_NEXT"; sc.render.resolution_x = 480; sc.render.resolution_y = 360; sc.eevee.taa_render_samples = 16
sc.render.filepath = OUT; bpy.ops.render.render(write_still=True)
