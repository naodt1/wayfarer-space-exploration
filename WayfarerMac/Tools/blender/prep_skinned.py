# Wayfarer · prepare a rigged, animated character for the game (GPU skinning).
#   Blender -b -P prep_skinned.py -- <src.glb> <out.blend> <out_dir> <name> [height=1.82] [tris=30000] [rotz=180] [step=2]
# Writes <out_dir>/<name>_rig.json: joints (name, parent, rest global matrix, inverse bind) in game axes
# (x right, y up, z back — the character faces -z), metres; and the source animation sampled every <step> frames
# as local joint transforms. The .blend holds the rest-posed, decimated mesh with its vertex groups, ready for
# export_ship.py ... skin (which bakes textures and writes <name>.mesh + <name>.weights).
import bpy, sys, json, math
from mathutils import Matrix, Vector
a = sys.argv[sys.argv.index("--") + 1:]
SRC, OUTBLEND, OUTDIR, NAME = a[:4]
opt = dict(kv.split("=", 1) for kv in a[4:])
H = float(opt.get("height", 1.82)); TRIS = int(opt.get("tris", 30000)); ROTZ = math.radians(float(opt.get("rotz", 180))); STEP = int(opt.get("step", 2))

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=SRC)
sc = bpy.context.scene
arm = [o for o in sc.objects if o.type == "ARMATURE"][0]
meshes = [o for o in sc.objects if o.type == "MESH" and any(m.type == "ARMATURE" for m in o.modifiers)]
for o in list(sc.objects):
    if o.type == "MESH" and o not in meshes: bpy.data.objects.remove(o)
action = arm.animation_data.action if arm.animation_data else None
f0, f1 = (int(action.frame_range[0]), int(action.frame_range[1])) if action else (0, 0)

# ---- measure the rest height, then build the transform T: scale to H, centre feet at the origin, turn to face -z (game)
arm.data.pose_position = "REST"; bpy.context.view_layer.update()
dg = bpy.context.evaluated_depsgraph_get()
lo = Vector((1e9,) * 3); hi = Vector((-1e9,) * 3)
for o in meshes:
    ev = o.evaluated_get(dg); me = ev.to_mesh()
    for v in me.vertices:
        w = o.matrix_world @ v.co; lo = Vector(map(min, lo, w)); hi = Vector(map(max, hi, w))
    ev.to_mesh_clear()
k = H / (hi.z - lo.z)
c = (lo + hi) / 2
T = Matrix.Rotation(ROTZ, 4, "Z") @ Matrix.Diagonal((k, k, k, 1)) @ Matrix.Translation(Vector((-c.x, -c.y, -lo.z)))
C = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))          # Blender → game axes
Ci = C.inverted()
def game(M): return C @ M @ Ci
def flat(M): return [M[r][cc] for cc in range(4) for r in range(4)]        # column-major

# ---- joints at rest
bones = list(arm.data.bones)
index = {b.name: i for i, b in enumerate(bones)}
restG = [game(T @ arm.matrix_world @ b.matrix_local) for b in bones]
joints = []
for i, b in enumerate(bones):
    joints.append({"name": b.name, "parent": index[b.parent.name] if b.parent else -1,
                   "rest": flat(restG[i]), "invBind": flat(restG[i].inverted())})

# ---- the animation, sampled: local transforms (relative to the parent's posed global)
frames = []
if action:
    arm.data.pose_position = "POSE"
    for f in range(f0, f1 + 1, STEP):
        sc.frame_set(f)
        G = [game(T @ arm.matrix_world @ arm.pose.bones[b.name].matrix) for b in bones]
        loc = []
        for i, b in enumerate(bones):
            Lm = (G[index[b.parent.name]].inverted() @ G[i]) if b.parent else G[i]
            t, q, sc3 = Lm.decompose()
            loc += [q.x, q.y, q.z, q.w, t.x, t.y, t.z, (sc3.x + sc3.y + sc3.z) / 3]
        frames.append(loc)
    arm.data.pose_position = "REST"; sc.frame_set(f0)
fps = sc.render.fps / sc.render.fps_base
json.dump({"joints": joints, "frames": frames, "fps": fps / STEP}, open(f"{OUTDIR}/{NAME}_rig.json", "w"))
print("RIG", len(joints), "joints,", len(frames), "frames at", round(fps / STEP, 2), "fps, scale", round(k, 4))

# ---- the mesh at rest: bake the rest pose in, keep vertex groups, join, transform, decimate
bpy.context.view_layer.update()
for o in meshes:
    if o.data.shape_keys:                      # facial shape keys: keep the base shape only
        o.shape_key_clear()
    for m in list(o.modifiers):
        if m.type == "ARMATURE": o.modifiers.remove(m)
    mw = o.matrix_world.copy(); o.parent = None; o.matrix_world = mw
bpy.data.objects.remove(arm)
bpy.ops.object.select_all(action="DESELECT")
for o in meshes: o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
if len(meshes) > 1: bpy.ops.object.join()
ob = bpy.context.view_layer.objects.active
ob.data.transform(T); ob.data.update()
ob.data.calc_loop_triangles(); n = len(ob.data.loop_triangles)
if n > TRIS:
    d = ob.modifiers.new("Dec", "DECIMATE"); d.ratio = TRIS / n
    bpy.ops.object.modifier_apply(modifier="Dec")
ob.data.calc_loop_triangles()
print("PREP", OUTBLEND, "tris", len(ob.data.loop_triangles), "groups", len(ob.vertex_groups))
json.dump([b.name for b in bones], open(f"{OUTDIR}/{NAME}_jointnames.json", "w"))
bpy.ops.wm.save_as_mainfile(filepath=OUTBLEND)
