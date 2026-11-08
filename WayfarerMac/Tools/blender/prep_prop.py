# Wayfarer · prepare a downloaded model for the game.
#   Blender -b -P prep_prop.py -- <src.glb> <out.blend> [key=value ...]
# Options:
#   exclude=Plane,Foo      drop objects whose name contains any of these
#   xrange=a:b             keep only objects whose centre x (Blender units, as imported) lies in a…b
#   height=132 | length=26 | size=3000   scale so the model is that tall (z) / long (y) / large (largest side), metres
#   scale=1.15             or a plain scale factor
#   tris=60000             decimate to about this many triangles
#   rotz=90                turn about the vertical axis (degrees) after import
#   centre=ground|middle   ground: stand on z = 0, centred in x/y (default); middle: centred on all axes
#   bake_pose=1            animated models: keep the first frame's pose
import bpy, sys, math
from mathutils import Vector, Matrix
a = sys.argv[sys.argv.index("--") + 1:]
SRC, OUT = a[0], a[1]
opt = dict(kv.split("=", 1) for kv in a[2:])
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
sc = bpy.context.scene
sc.frame_set(0)
dg = bpy.context.evaluated_depsgraph_get()

# meshes, posed as in frame 0, turned into plain objects
keep = []
for o in list(sc.objects):
    if o.type != "MESH": continue
    if "exclude" in opt and any(k in o.name for k in opt["exclude"].split(",")): continue
    if "xrange" in opt:
        lo, hi = map(float, opt["xrange"].split(":"))
        c = o.matrix_world @ (sum((Vector(b) for b in o.bound_box), Vector()) / 8)
        if not (lo <= c.x <= hi): continue
    ev = o.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=dg)
    me.transform(o.matrix_world)
    n = bpy.data.objects.new(o.name, me); sc.collection.objects.link(n); keep.append(n)
for o in list(sc.objects):
    if o not in keep: bpy.data.objects.remove(o)
for o in keep: o.select_set(True)
bpy.context.view_layer.objects.active = keep[0]
if len(keep) > 1: bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active

def bounds():
    vs = [v.co for v in ob.data.vertices]
    return Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs))), Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
if "rotz" in opt:
    ob.data.transform(Matrix.Rotation(math.radians(float(opt["rotz"])), 4, "Z"))
lo, hi = bounds(); sz = hi - lo
k = 1.0
if "height" in opt: k = float(opt["height"]) / sz.z
elif "length" in opt: k = float(opt["length"]) / sz.y
elif "size" in opt: k = float(opt["size"]) / max(sz)
elif "scale" in opt: k = float(opt["scale"])
c = (lo + hi) / 2
base = Vector((c.x, c.y, lo.z)) if opt.get("centre", "ground") == "ground" else c
ob.data.transform(Matrix.Diagonal((k, k, k, 1.0)) @ Matrix.Translation(-base))
ob.data.update()

if "openends" in opt:     # a corridor segment: remove the walls that cap its two ends, so segments join into one hall
    import bmesh as _bm
    bm = _bm.new(); bm.from_mesh(ob.data)
    ys = [v.co.y for v in bm.verts]; y0, y1 = min(ys), max(ys); w = float(opt["openends"])
    dead = [f for f in bm.faces if abs(f.normal.y) > 0.85 and (f.calc_center_median().y < y0 + 0.4 or f.calc_center_median().y > y1 - 0.4)
            and abs(f.calc_center_median().x) < w and 0.05 < f.calc_center_median().z < 3.0]
    _bm.ops.delete(bm, geom=dead, context="FACES"); bm.to_mesh(ob.data); bm.free(); ob.data.update()
    print("opened ends:", len(dead), "faces removed")
if "tris" in opt:
    ob.data.calc_loop_triangles(); n = len(ob.data.loop_triangles); target = int(opt["tris"])
    if n > target:
        m = ob.modifiers.new("Dec", "DECIMATE"); m.ratio = target / n; m.use_collapse_triangulate = True
        bpy.ops.object.modifier_apply(modifier="Dec")
ob.data.calc_loop_triangles()
lo, hi = bounds()
print("PREP", OUT, "tris", len(ob.data.loop_triangles), "size", tuple(round(v, 2) for v in hi - lo), "scale", round(k, 4))
bpy.ops.wm.save_as_mainfile(filepath=OUT)
