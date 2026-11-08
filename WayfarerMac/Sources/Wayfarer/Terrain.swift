import Foundation
import Metal
import simd

// Cube-sphere quadtree terrain. Every tile is a grid of vertices pushed out to the
// planet's height function; tiles split as the camera approaches. Tiles are built on
// background threads so flying never stalls.

private let FACES: [(n: D3, r: D3, u: D3)] = [
    (D3(1, 0, 0), D3(0, 0, -1), D3(0, 1, 0)), (D3(-1, 0, 0), D3(0, 0, 1), D3(0, 1, 0)),
    (D3(0, 1, 0), D3(1, 0, 0), D3(0, 0, -1)), (D3(0, -1, 0), D3(1, 0, 0), D3(0, 0, 1)),
    (D3(0, 0, 1), D3(1, 0, 0), D3(0, 1, 0)), (D3(0, 0, -1), D3(-1, 0, 0), D3(0, 1, 0)),
]

@inline(__always) func cubeDir(_ f: Int, _ u: Double, _ v: Double) -> D3 {
    let F = FACES[f]
    let p = F.n + F.r * u + F.u * v
    let x2 = p.x * p.x, y2 = p.y * p.y, z2 = p.z * p.z
    return D3(p.x * sqrt(1 - y2 / 2 - z2 / 2 + y2 * z2 / 3),
              p.y * sqrt(1 - z2 / 2 - x2 / 2 + z2 * x2 / 3),
              p.z * sqrt(1 - x2 / 2 - y2 / 2 + x2 * y2 / 3))
}

let TERRAIN_STRIDE = 19              // floats per vertex: pos3 normal3 colour3 elev1 detailUV3 layerWeights6
let TRI_F = 20.0                     // detail texture repeats every 50 m (must match the shader)
private let SEG = 28
private let SPLIT = 3.0

final class ChunkMesh {
    let vb: MTLBuffer
    let ib: MTLBuffer
    let indexCount: Int
    let radius: Float
    init(vb: MTLBuffer, ib: MTLBuffer, indexCount: Int, radius: Float) { self.vb = vb; self.ib = ib; self.indexCount = indexCount; self.radius = radius }
}

final class Node {
    unowned let world: World
    let face: Int, x: Double, y: Double, size: Double, depth: Int
    let dir: D3, center: D3, ws: Double
    var mesh: ChunkMesh?
    var children: [Node]?
    var covered = false
    var building = false
    var alive = true

    init(world: World, face: Int, x: Double, y: Double, size: Double, depth: Int) {
        self.world = world; self.face = face; self.x = x; self.y = y; self.size = size; self.depth = depth
        dir = simd_normalize(cubeDir(face, x + size / 2, y + size / 2))
        // deep chunks sit on the real surface height so LOD distance is measured to the ground, not to sea level
        if depth >= 5 {
            let e = world.height(dir.x, dir.y, dir.z, min(world.baseOct + depth, 12), nil)
            center = dir * (world.R + (world.sea ? max(e, 0) : e))
        } else { center = dir * world.R }
        ws = world.R * size * 0.785
    }

    func dispose() {
        alive = false; mesh = nil
        children?.forEach { $0.dispose() }
        children = nil
    }
}

func buildChunk(_ node: Node, device: MTLDevice) -> ChunkMesh? {
    let P = node.world, N = node.depth <= 3 ? 64 : SEG, M = N + 3, R = P.R
    let oct = min(P.baseOct + node.depth, P.maxOct)
    let ctx = P.craterSubset(center: node.dir, size: node.size)
    var ext = [D3](repeating: .zero, count: M * M)
    var dirs = [D3](repeating: .zero, count: M * M)
    var elev = [Double](repeating: 0, count: M * M)
    for j in 0..<M {
        for i in 0..<M {
            let d = cubeDir(node.face, node.x + Double(i - 1) / Double(N) * node.size, node.y + Double(j - 1) / Double(N) * node.size)
            let e = P.height(d.x, d.y, d.z, oct, ctx)
            let r = R + (P.sea ? max(e, 0) : e), k = j * M + i
            ext[k] = d * r; dirs[k] = d; elev[k] = e
        }
    }
    let inner = (N + 1) * (N + 1), total = inner + 4 * (N + 1)
    var v = [Float](repeating: 0, count: total * TERRAIN_STRIDE)
    let c = node.center
    // wrap on a 1 km period (20 units): every texture scale and 3-4-5 rotation used in the shader repeats exactly on it, so chunk edges never seam
    let cm = D3((c.x * TRI_F).truncatingRemainder(dividingBy: 20), (c.y * TRI_F).truncatingRemainder(dividingBy: 20), (c.z * TRI_F).truncatingRemainder(dividingBy: 20))
    var radius: Float = 0
    for j in 0...N {
        for i in 0...N {
            let k = (j + 1) * M + (i + 1), o = j * (N + 1) + i
            let p = ext[k] - c
            let a = ext[k + 1] - ext[k - 1], b = ext[k + M] - ext[k - M]
            var n = simd_cross(a, b); let nl = simd_length(n); n = nl > 0 ? n / nl : dirs[k]
            let slope = 1 - simd_dot(n, dirs[k])
            let col = P.colorFn(dirs[k].x, dirs[k].y, dirs[k].z, elev[k], slope)
            let tri = cm + p * TRI_F
            let base = o * TERRAIN_STRIDE
            v[base] = Float(p.x); v[base + 1] = Float(p.y); v[base + 2] = Float(p.z)
            v[base + 3] = Float(n.x); v[base + 4] = Float(n.y); v[base + 5] = Float(n.z)
            v[base + 6] = Float(col.x); v[base + 7] = Float(col.y); v[base + 8] = Float(col.z)
            v[base + 9] = Float(elev[k])
            v[base + 10] = Float(tri.x); v[base + 11] = Float(tri.y); v[base + 12] = Float(tri.z)
            let mw = P.materialFn(dirs[k].x, dirs[k].y, dirs[k].z, elev[k], slope)
            for q in 0..<6 { v[base + 13 + q] = mw[q] }
            radius = max(radius, Float(simd_length(p)))
        }
    }
    // skirts hide cracks between tiles of different detail
    var edges: [[Int]] = [[], [], [], []]
    for t in 0...N { edges[0].append(t); edges[1].append(N * (N + 1) + t); edges[2].append(t * (N + 1)); edges[3].append(t * (N + 1) + N) }
    let drop = node.ws / Double(N) * 1.5 + 0.02
    var s = inner
    var skirt: [[Int]] = []
    for e in edges {
        var row: [Int] = []
        for o in e {
            let k = (o / (N + 1) + 1) * M + (o % (N + 1)) + 1
            let sb = s * TERRAIN_STRIDE, ob = o * TERRAIN_STRIDE
            for q in 0..<TERRAIN_STRIDE { v[sb + q] = v[ob + q] }
            v[sb] -= Float(dirs[k].x * drop); v[sb + 1] -= Float(dirs[k].y * drop); v[sb + 2] -= Float(dirs[k].z * drop)
            row.append(s); s += 1
        }
        skirt.append(row)
    }
    var idx: [UInt16] = []
    idx.reserveCapacity(N * N * 6 + 4 * N * 6)
    for j in 0..<N {
        for i in 0..<N {
            let a = j * (N + 1) + i, b = a + 1, cc = a + N + 1, d = cc + 1
            idx += [UInt16(a), UInt16(b), UInt16(d), UInt16(a), UInt16(d), UInt16(cc)]
        }
    }
    for (ei, e) in edges.enumerated() {
        let sr = skirt[ei]
        for t in 0..<N { idx += [UInt16(e[t]), UInt16(sr[t]), UInt16(e[t + 1]), UInt16(e[t + 1]), UInt16(sr[t]), UInt16(sr[t + 1])] }
    }
    guard let vb = device.makeBuffer(bytes: v, length: v.count * 4, options: .storageModeShared),
          let ib = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared) else { return nil }
    return ChunkMesh(vb: vb, ib: ib, indexCount: idx.count, radius: radius + Float(drop))
}

final class Terrain: @unchecked Sendable {
    let device: MTLDevice
    let worlds: [World]
    private let queue = DispatchQueue(label: "wayfarer.terrain", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var finished: [(Node, ChunkMesh?)] = []
    private var inFlight = 0
    private let maxInFlight = max(4, ProcessInfo.processInfo.activeProcessorCount * 2)
    private var requests: [(Node, Double)] = []
    private(set) var draw: [Node] = []
    private(set) var tiles = 0, deepest = 0, pending = 0

    init(device: MTLDevice, worlds: [World]) {
        self.device = device; self.worlds = worlds
        for w in worlds { w.roots = (0..<6).map { Node(world: w, face: $0, x: -1, y: -1, size: 2, depth: 0) } }
        // build every root tile up front so no world ever pops in
        let roots = worlds.flatMap { $0.roots }
        var built = [ChunkMesh?](repeating: nil, count: roots.count)
        let lk = NSLock()
        DispatchQueue.concurrentPerform(iterations: roots.count) { i in
            let m = buildChunk(roots[i], device: device)
            lk.lock(); built[i] = m; lk.unlock()
        }
        for (i, r) in roots.enumerated() { r.mesh = built[i] }
    }

    func update(camPos: D3) {
        lock.lock()
        let done = finished; finished.removeAll(keepingCapacity: true)
        lock.unlock()
        for (n, m) in done { n.building = false; inFlight -= 1; if n.alive { n.mesh = m } }

        draw.removeAll(keepingCapacity: true); requests.removeAll(keepingCapacity: true)
        tiles = 0; deepest = 0
        for w in worlds {
            let camL = camPos - w.pos
            for r in w.roots { visit(r, camL) }
        }
        pending = requests.count
        requests.sort { $0.1 < $1.1 }
        for (n, _) in requests {
            if inFlight >= maxInFlight { break }
            if n.building || n.mesh != nil { continue }
            n.building = true; inFlight += 1
            let dev = device
            queue.async { [weak self] in
                let m = buildChunk(n, device: dev)
                guard let self else { return }
                self.lock.lock(); self.finished.append((n, m)); self.lock.unlock()
            }
        }
    }

    private func visit(_ n: Node, _ camL: D3) {
        let d = simd_distance(camL, n.center)
        let want = n.depth < n.world.maxDepth && d < n.ws * (n.children != nil ? SPLIT * 1.15 : SPLIT)
        if want {
            if n.children == nil {
                let h = n.size / 2, w = n.world
                n.children = [Node(world: w, face: n.face, x: n.x, y: n.y, size: h, depth: n.depth + 1),
                              Node(world: w, face: n.face, x: n.x + h, y: n.y, size: h, depth: n.depth + 1),
                              Node(world: w, face: n.face, x: n.x, y: n.y + h, size: h, depth: n.depth + 1),
                              Node(world: w, face: n.face, x: n.x + h, y: n.y + h, size: h, depth: n.depth + 1)]
            }
            let mark = draw.count, markTiles = tiles
            var all = true
            for c in n.children! { visit(c, camL); if !c.covered { all = false } }
            if !all {
                draw.removeSubrange(mark...); tiles = markTiles
                if n.mesh != nil { draw.append(n); tiles += 1 } else { requests.append((n, d / n.ws - 100)) }
            }
            n.covered = all || n.mesh != nil
        } else {
            if let ch = n.children { ch.forEach { $0.dispose() }; n.children = nil }
            if n.mesh != nil { draw.append(n); tiles += 1; deepest = max(deepest, n.depth) } else { requests.append((n, d / n.ws)) }
            n.covered = n.mesh != nil
        }
    }

    /// true once nothing is waiting to be built (used by the snapshot tool)
    var idle: Bool { lock.lock(); defer { lock.unlock() }; return inFlight == 0 && finished.isEmpty }
}
