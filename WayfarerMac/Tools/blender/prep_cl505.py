# Normalise the downloaded CL505 for Wayfarer: 32 m long, centred, nose toward Blender +Y (game -z), then report
# where the engine nozzles, cockpit and gear are in game units (1 unit = LENGTH_M / 1.4 m).
import bpy, sys, os
from mathutils import Vector
a = sys.argv[sys.argv.index("--") + 1:]; SRC, OUT = a[0], a[1]
LENGTH_M = 32.0
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
ob = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
for o in bpy.context.scene.objects: o.select_set(o == ob)
bpy.context.view_layer.objects.active = ob
bpy.ops.object.parent_clear(type="CLEAR_KEEP_TRANSFORM")
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
vs = [v.co for v in ob.data.vertices]
lo = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs))); hi = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
k = LENGTH_M / (hi.y - lo.y); ctr = (lo + hi) / 2
for v in ob.data.vertices: v.co = (v.co - ctr) * k
ob.data.update()
for o in list(bpy.context.scene.objects):
    if o != ob: bpy.data.objects.remove(o)
os.makedirs(OUT, exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "cl505.blend"))
S = LENGTH_M / 1.4
def g(v): return (v.x / S, v.z / S, -v.y / S)
vs = [v.co for v in ob.data.vertices]
lo = Vector((min(v.x for v in vs), min(v.y for v in vs), min(v.z for v in vs))); hi = Vector((max(v.x for v in vs), max(v.y for v in vs), max(v.z for v in vs)))
print("REPORT bounds game", [round(x, 3) for x in g(lo)], [round(x, 3) for x in g(hi)])
# rear-most geometry: cluster by x to find the nozzles
rear = [v for v in vs if v.y < lo.y + (hi.y - lo.y) * 0.07]
cols = {}
for v in rear: cols.setdefault(round(v.x / 0.6), []).append(v)
for key in sorted(cols):
    c = cols[key]
    if len(c) < 20: continue
    m = sum((v for v in c), Vector()) / len(c)
    r = max((Vector((v.x, 0, v.z)) - Vector((m.x, 0, m.z))).length for v in c)
    print("REPORT rear cluster", key, "n", len(c), "centre game", [round(x, 3) for x in g(m)], "radius m", round(r, 2), "ymin", round(min(v.y for v in c), 2))
# lowest points (wheels) and highest near the front third (canopy)
low = sorted(vs, key=lambda v: v.z)[:200]
print("REPORT gear bottom game y", round(min(v.z for v in vs) / S, 4))
front = [v for v in vs if v.y > 0]
top = max(front, key=lambda v: v.z)
print("REPORT canopy top game", [round(x, 3) for x in g(top)])
