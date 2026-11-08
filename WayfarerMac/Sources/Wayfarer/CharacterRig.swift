import Foundation
import Metal
import simd

// The player character: a rigged model (the orange robot, "Sci-fi O.B. Robot Unit TH-ICC02" by Jungle Jim, CC BY 4.0)
// prepared by Tools/blender/prep_skinned.py. Its own idle animation plays when you stand still; walking, running,
// jumping and the jetpack are driven by code on top of a neutral frame of that idle (the same Pose the old astronaut
// used), and the mesh is skinned on the GPU.
//
// Character space: metres, x right, y up, z back (the character faces -z), feet at y = 0.

struct JointPose { var q: simd_quatd; var t: D3; var s: Double }

final class CharacterRig {
    static let shared: CharacterRig? = CharacterRig(name: "player")

    let names: [String]
    let parent: [Int]
    let invBind: [simd_double4x4]
    let frames: [[JointPose]]
    let fps: Double
    let base: Int                                  // the most neutral frame of the idle (feet under the hips, legs straight)
    private(set) var baseRot: [simd_quatd] = []   // each joint's global rotation in the base frame
    private var idx: [String: Int] = [:]

    init?(name: String) {
        guard let url = assetsURL()?.appendingPathComponent("Characters/\(name)_rig.json"),
              let data = try? Data(contentsOf: url),
              let js = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let joints = js["joints"] as? [[String: Any]], let fr = js["frames"] as? [[Double]], !fr.isEmpty else { return nil }
        names = joints.map { $0["name"] as? String ?? "" }
        parent = joints.map { $0["parent"] as? Int ?? -1 }
        func m(_ a: [Double]) -> simd_double4x4 {
            simd_double4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]), SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
        }
        invBind = joints.map { m($0["invBind"] as? [Double] ?? Array(repeating: 0, count: 16)) }
        let n = names.count
        frames = fr.map { f in (0..<n).map { j in
            let o = j * 8
            return JointPose(q: simd_quatd(ix: f[o], iy: f[o + 1], iz: f[o + 2], r: f[o + 3]).normalized, t: D3(f[o + 4], f[o + 5], f[o + 6]), s: f[o + 7])
        } }
        fps = js["fps"] as? Double ?? 12
        for (i, s) in names.enumerated() { idx[s] = i }
        // pick the calmest frame: feet straight under the thighs, knees nearly straight
        let nm = names
        func pos(_ g: [simd_double4x4], _ s: String) -> D3 { guard let i = nm.firstIndex(where: { $0.hasPrefix(s + "_") }) else { return .zero }; let c = g[i].columns.3; return D3(c.x, c.y, c.z) }
        var best = 0, bestScore = 1e9
        for (fi, f) in frames.enumerated() {
            let g = CharacterRig.globals(f, parent)
            var score = 0.0
            for side in ["L", "R"] {
                let th = pos(g, "CC_Base_\(side)_Thigh"), ca = pos(g, "CC_Base_\(side)_Calf"), ft = pos(g, "CC_Base_\(side)_Foot")
                score += abs(ft.x - th.x) * 2 + abs(ft.z - th.z) + simd_length(simd_normalize(ca - th) - simd_normalize(ft - ca))
            }
            if score < bestScore { bestScore = score; best = fi }
        }
        base = best
        let g = CharacterRig.globals(frames[base], parent)
        baseRot = g.map { simd_quatd(simd_double3x3(columns: (simd_normalize(D3($0.columns.0.x, $0.columns.0.y, $0.columns.0.z)),
                                                            simd_normalize(D3($0.columns.1.x, $0.columns.1.y, $0.columns.1.z)),
                                                            simd_normalize(D3($0.columns.2.x, $0.columns.2.y, $0.columns.2.z))))) }
    }
    /// names in the rig carry a numeric suffix (CC_Base_L_Thigh_024): look them up by prefix
    func joint(_ prefix: String) -> Int? {
        if let i = idx[prefix] { return i }
        return names.firstIndex { $0.hasPrefix(prefix + "_") }
    }
    static func local(_ p: JointPose) -> simd_double4x4 { translate(p.t) * simd_double4x4(p.q) * scaleM(D3(repeating: p.s)) }
    static func globals(_ f: [JointPose], _ parent: [Int]) -> [simd_double4x4] {
        var g = [simd_double4x4](repeating: simd_double4x4(1), count: f.count)
        for j in 0..<f.count { let l = local(f[j]); g[j] = parent[j] >= 0 ? g[parent[j]] * l : l }
        return g
    }
    private lazy var named: [String: Int] = {
        var d: [String: Int] = [:]
        for k in ["CC_Base_Hip", "CC_Base_Waist", "CC_Base_Spine01", "CC_Base_Spine02", "CC_Base_Head", "CC_Base_NeckTwist01",
                  "CC_Base_L_Thigh", "CC_Base_R_Thigh", "CC_Base_L_Calf", "CC_Base_R_Calf", "CC_Base_L_Foot", "CC_Base_R_Foot",
                  "CC_Base_L_Upperarm", "CC_Base_R_Upperarm", "CC_Base_L_Forearm", "CC_Base_R_Forearm"] { if let i = joint(k) { d[k] = i } }
        return d
    }()

    /// skin matrices (character space) for a moment of the idle blended with the code-driven pose.
    /// idleK: 1 = the robot's own idle animation, 0 = the neutral base frame + the walk/run/jump pose.
    func evaluate(idleTime: Double, idleK: Double, pose p: Pose, turn: Double, look: Double) -> (skin: [simd_float4x4], spine: simd_double4x4) {
        let n = names.count
        let fi = Int(idleTime * fps) % frames.count
        let fA = frames[base], fB = frames[fi]
        var loc = [JointPose](repeating: fA[0], count: n)
        for j in 0..<n {
            let a = fA[j], b = fB[j]
            loc[j] = JointPose(q: simd_slerp(a.q, b.q, idleK), t: a.t + (b.t - a.t) * idleK, s: a.s + (b.s - a.s) * idleK)
        }
        // code-driven rotations, in character space (x right, y up, z back), same conventions as the old astronaut
        let cr = p.crouch, mv = 1 - idleK
        var R: [Int: simd_quatd] = [:]
        func rx(_ a: Double) -> simd_quatd { simd_quatd(angle: a, axis: D3(1, 0, 0)) }
        func rz(_ a: Double) -> simd_quatd { simd_quatd(angle: a, axis: D3(0, 0, 1)) }
        let N = named
        if let i = N["CC_Base_L_Thigh"] { R[i] = rx((p.lt + cr * 0.6) * mv) }
        if let i = N["CC_Base_R_Thigh"] { R[i] = rx((p.rt + cr * 0.6) * mv) }
        if let i = N["CC_Base_L_Calf"] { R[i] = rx(-(p.lk + cr * 1.2) * mv) }
        if let i = N["CC_Base_R_Calf"] { R[i] = rx(-(p.rk + cr * 1.2) * mv) }
        if let i = N["CC_Base_L_Foot"] { R[i] = rx(-(p.lt - p.lk + cr * 0.6 - cr * 1.2) * 0.8 * mv) }
        if let i = N["CC_Base_R_Foot"] { R[i] = rx(-(p.rt - p.rk + cr * 0.6 - cr * 1.2) * 0.8 * mv) }
        if let i = N["CC_Base_L_Upperarm"] { R[i] = rx(p.la * mv) * rz(-(p.laz + 0.07) * mv) }
        if let i = N["CC_Base_R_Upperarm"] { R[i] = rx(p.ra * mv) * rz(-(p.raz - 0.07) * mv) }
        if let i = N["CC_Base_L_Forearm"] { R[i] = rx(p.le * 0.8 * mv) }
        if let i = N["CC_Base_R_Forearm"] { R[i] = rx(p.re * 0.8 * mv) }
        let bank = clampd(-turn * 0.06, -0.25, 0.25)
        if let i = N["CC_Base_Waist"] { R[i] = rx(-(p.lean + cr * 0.25) * 0.5 * mv) * rz(p.roll * mv) }
        if let i = N["CC_Base_Spine02"] { R[i] = rx(-(p.lean + cr * 0.25) * 0.5 * mv) * rz(bank * mv) }
        if let i = N["CC_Base_Head"] { R[i] = rx((p.lean * 0.5) * mv - look * 0.25) }
        let hip = N["CC_Base_Hip"]
        var g = [simd_double4x4](repeating: simd_double4x4(1), count: n)
        for j in 0..<n {
            var l = CharacterRig.local(loc[j])
            if let r = R[j] { l = l * simd_double4x4(baseRot[j].inverse * r * baseRot[j]) }
            g[j] = parent[j] >= 0 ? g[parent[j]] * l : l
            if j == hip { g[j].columns.3.y += (p.bob - cr * 0.16) * mv }
        }
        let skin = (0..<n).map { j -> simd_float4x4 in
            let m = g[j] * invBind[j]
            return simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
        }
        return (skin, g[N["CC_Base_Spine02"] ?? 0])
    }
}

/// the skinned mesh: geometry (9 floats per vertex), joints + weights (8 floats per vertex), baked textures
struct SkinnedModel { let model: PropAsset; let weights: MTLBuffer }
func loadSkinnedModel(device: MTLDevice, name: String) -> SkinnedModel? {
    guard let base = assetsURL()?.appendingPathComponent("Characters"), let m = loadBakedModel(device: device, dir: base, name: name),
          let w = try? Data(contentsOf: base.appendingPathComponent("\(name).weights")), w.count / 32 == m.mesh.count / 9 else { return nil }
    let buf = w.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: w.count, options: .storageModeShared)! }
    return SkinnedModel(model: m, weights: buf)
}
