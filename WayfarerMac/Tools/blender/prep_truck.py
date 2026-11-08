# Wayfarer · split the cyberpunk cargo truck (Jungle Jim, CC BY 4.0) into a body and one wheel, so the game can spin,
# steer and suspend the wheels. Same transform for both: straightened (the model sits 4.6° askew), turned so the cab
# faces Blender +y (game -z), wheel bottoms at z = 0, centred. Writes the wheel centres to <out_dir>/truck_wheels.json.
#   Blender -b -P prep_truck.py -- <src.glb> <out_dir_blend> <assets_dir>
import bpy, sys, json, math
from mathutils import Vector, Matrix
a = sys.argv[sys.argv.index("--") + 1:]; SRC, OUTB, ASSETS = a
bpy.ops.wm.read_factory_settings(use_empty=True); bpy.ops.import_scene.gltf(filepath=SRC)
sc = bpy.context.scene; sc.frame_set(0); dg = bpy.context.evaluated_depsgraph_get()
objs = [o for o in sc.objects if o.type == "MESH"]
def bake(o):
    me = bpy.data.meshes.new_from_object(o.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg); me.transform(o.matrix_world); return me
R = Matrix.Rotation(math.radians(-90 + 4.6), 4, "Z")
pts = []
for o in objs:
    for c in o.bound_box: pts.append(R @ (o.matrix_world @ Vector(c)))
lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts))); hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
T = Matrix.Translation(Vector((-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -lo.z))) @ R
wheels = [o for o in objs if "Wheel" in o.name]
centres = []
for o in wheels:
    c = T @ (o.matrix_world @ (sum((Vector(b) for b in o.bound_box), Vector()) / 8))
    centres.append([c.x, c.z, -c.y])                     # game axes: x right, y up, z back
ref = wheels[0]; refC = T @ (ref.matrix_world @ (sum((Vector(b) for b in ref.bound_box), Vector()) / 8))
radius = max(ref.dimensions.x, ref.dimensions.z) / 2
def save(meshes, path):
    for o in list(sc.objects): bpy.data.objects.remove(o)
    obs = []
    for me in meshes:
        o = bpy.data.objects.new("part", me); sc.collection.objects.link(o); obs.append(o)
    bpy.ops.object.select_all(action="DESELECT")
    for o in obs: o.select_set(True)
    bpy.context.view_layer.objects.active = obs[0]
    if len(obs) > 1: bpy.ops.object.join()
    bpy.ops.wm.save_as_mainfile(filepath=path)
body = []
for o in objs:
    if o in wheels: continue
    me = bake(o); me.transform(T); body.append(me)
wm = bake(ref); wm.transform(Matrix.Translation(-refC) @ T)
json.dump({"wheels": centres, "radius": radius, "length": hi.y - lo.y, "width": hi.x - lo.x, "height": hi.z - lo.z}, open(f"{ASSETS}/truck_wheels.json", "w"))
print("TRUCK length", round(hi.y - lo.y, 2), "width", round(hi.x - lo.x, 2), "wheels", len(centres), "radius", round(radius, 2))
save(body, f"{OUTB}/truckbody.blend")
save([wm], f"{OUTB}/truckwheel.blend")
