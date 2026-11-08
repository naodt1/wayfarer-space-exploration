# Blender -b <prepped.blend> -P find_nozzles.py -- <metres_per_game_unit>
# Finds the glowing (emissive) parts of a model, groups them into nozzles, and prints each one's centre, radius and
# facing in game units (x right, y up, z aft) — for ShipModel.engines.
import bpy, sys, math
from mathutils import Vector
S = float(sys.argv[sys.argv.index("--") + 1])
ob = [o for o in bpy.context.scene.objects if o.type == "MESH"][0]
def glows(m):
    if not m or not m.use_nodes: return False
    for n in m.node_tree.nodes:
        if n.type == "BSDF_PRINCIPLED":
            st = n.inputs["Emission Strength"].default_value
            if st > 0 and (n.inputs["Emission Color"].is_linked or max(n.inputs["Emission Color"].default_value[:3]) > 0.05): return True
        if n.type == "EMISSION": return True
    return False
gl = {i for i, m in enumerate(ob.data.materials) if glows(m)}
print("glowing materials", [ob.data.materials[i].name for i in gl])
faces = [p for p in ob.data.polygons if p.material_index in gl]
# cluster by proximity
clusters = []
for p in faces:
    c = p.center
    for cl in clusters:
        if (cl["c"] - c).length < 1.5:
            cl["pts"].append(p); cl["c"] = sum((q.center for q in cl["pts"]), Vector()) / len(cl["pts"]); break
    else: clusters.append({"c": c.copy(), "pts": [p]})
for cl in sorted(clusters, key=lambda c: -sum(p.area for p in c["pts"])):
    area = sum(p.area for p in cl["pts"]); n = sum((p.normal * p.area for p in cl["pts"]), Vector()).normalized()
    c = cl["c"]; r = math.sqrt(area / math.pi)
    g = (c.x / S, c.z / S, -c.y / S); gn = (n.x, n.z, -n.y)
    print("NOZZLE pos", tuple(round(v, 3) for v in g), "r", round(r / S, 3), "faces", len(cl["pts"]), "normal", tuple(round(v, 2) for v in gn))
