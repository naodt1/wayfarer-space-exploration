import Foundation
import Metal
import simd

// Exploration: hidden sites on every world. Scan (Q) to reveal their signals, then land and walk up to them.

enum SiteKind: Int { case monolith = 0, wreck, crystal
    var title: String { ["Ancient Monolith", "Crashed Freighter", "Crystal Spire"][rawValue] }
}

struct Site {
    let id: String
    let world: World
    let kind: SiteKind
    let dir: D3          // direction from the planet centre
    let pos: D3          // base position in world space (km)
    let yaw: Double
    var scanned = false
    var discovered = false
}

/// deterministic site placement: same worlds, same sites, every launch
func makeSites(worlds: [World]) -> [Site] {
    var out: [Site] = []
    let kinds: [[SiteKind]] = [[.monolith, .wreck], [.wreck, .monolith], [.crystal, .monolith]]
    for (wi, w) in worlds.enumerated() {
        let rnd = Mulberry(UInt32(900 + wi))
        var n = 0, tries = 0
        while n < 10 && tries < 20000 {
            tries += 1
            let d = simd_normalize(D3(rnd.next() * 2 - 1, rnd.next() * 2 - 1, rnd.next() * 2 - 1))
            let e = w.height(d.x, d.y, d.z, 12)
            if w.sea && e < 0.6 { continue }        // on land, clear of beaches
            if abs(d.y) > 0.85 { continue }         // not on the ice caps
            let kind = kinds[wi][n % 2]
            let p = w.pos + d * (w.groundRadius(d) - 0.0005)
            out.append(Site(id: "\(w.name)-\(n)", world: w, kind: kind, dir: d, pos: p, yaw: rnd.next() * .pi * 2))
            n += 1
        }
    }
    return out
}

/// site models, built in metres with the base at the origin
func buildSiteMeshes(device: MTLDevice) -> [GPUMesh] {
    var mono = MeshBuilder()
    mono.box(D3(3, 26, 1.3), D3(0, 10, 0), .dark)                       // extends 3 m into the ground
    for i in 0..<7 {
        let y = 3.5 + Double(i) * 2.6, w = i % 2 == 0 ? 2.2 : 1.4
        mono.box(D3(w, 0.16, 0.06), D3(0, y, -0.68), .cyan); mono.box(D3(w, 0.16, 0.06), D3(0, y, 0.68), .cyan)
    }
    for k in 0..<6 {
        let a = Double(k) / 6 * .pi * 2
        mono.box(D3(2.2, 1.2 + Double(k % 3) * 0.6, 1.6), D3(cos(a) * 5, 0.3, sin(a) * 5), .dark, rot: D3(0.2 * Double(k % 2), a, 0.15))
    }
    var wreck = MeshBuilder()
    wreck.box(D3(5, 4, 16), D3(0, 1.2, 0), .metal, rot: D3(0.12, 0.3, 0.35))
    wreck.box(D3(4, 3.2, 7), D3(6, 0.8, 9), .metal, rot: D3(-0.3, 0.9, -0.25))
    wreck.box(D3(14, 0.6, 5), D3(-6, 0.9, -2), .dark, rot: D3(0.05, 0.4, -0.28))
    wreck.box(D3(3, 2.6, 3.2), D3(1.5, 3.2, -6), .glass, rot: D3(0.3, 0.3, 0.4))
    for k in 0..<9 {
        let a = Double(k) * 2.3, r = 8 + Double(k % 4) * 3
        wreck.box(D3(1.2 + Double(k % 3), 0.5 + Double(k % 2) * 0.6, 1.5), D3(cos(a) * r, 0.2, sin(a) * r), k % 3 == 0 ? .dark : .metal, rot: D3(Double(k) * 0.5, a, Double(k) * 0.3))
    }
    wreck.box(D3(0.6, 0.6, 0.6), D3(0.5, 3.6, 2), .cyan)                   // flickering emergency light
    var crystal = MeshBuilder()
    let spikes: [(D3, Double, D3)] = [(D3(0, 0, 0), 9, D3(0, 0, 0)), (D3(2.5, 0, 1), 6, D3(0.3, 0, -0.35)), (D3(-2, 0, 1.5), 7, D3(-0.2, 0, 0.4)),
                                      (D3(1, 0, -2.5), 5, D3(-0.4, 0.5, 0.1)), (D3(-2.5, 0, -1.5), 4.5, D3(0.3, 0, 0.5)), (D3(3.5, 0, -1), 3.5, D3(0.2, 0, -0.6))]
    for (p, h, r) in spikes {
        let save = crystal.xform
        crystal.xform = crystal.xform * translate(p) * eulerXYZ(r)
        crystal.octahedron(1, scale: D3(h * 0.16, h * 0.62, h * 0.16), D3(0, h * 0.45, 0), .crystal)
        crystal.xform = save
    }
    return [GPUMesh(device: device, verts: mono.v), GPUMesh(device: device, verts: wreck.v), GPUMesh(device: device, verts: crystal.v)]
}

extension Game {
    static let discoverRadius = 0.045      // 45 m on foot
    static var progressKey: String { CommandLine.arguments.contains("--snapshot") ? "wayfarer.discovered.snapshot" : "wayfarer.discovered" }
    var scanRange: Double { max(60, (alt.isFinite ? alt : 0) * 5) }

    func loadProgress() {
        let found = Set(UserDefaults.standard.stringArray(forKey: Game.progressKey) ?? [])
        for i in sites.indices where found.contains(sites[i].id) { sites[i].discovered = true; sites[i].scanned = true }
    }
    private func saveProgress() {
        UserDefaults.standard.set(sites.filter { $0.discovered }.map { $0.id }, forKey: Game.progressKey)
    }

    func scan() {
        guard mode != .title else { return }
        if time - lastScan < 2.5 { return }
        lastScan = time; scanPulse = 0
        let origin = mode == .walk ? w.pos : pos
        var found = 0
        for i in sites.indices where !sites[i].discovered {
            if simd_distance(origin, sites[i].pos) < scanRange {
                if !sites[i].scanned { found += 1 }
                sites[i].scanned = true
            }
        }
        sfx?.scan()
        let known = sites.filter { $0.scanned && !$0.discovered && simd_distance(origin, $0.pos) < scanRange }.count
        if found > 0 { say("scan · \(found) new signal\(found == 1 ? "" : "s") detected") }
        else if known > 0 { say("scan · \(known) signal\(known == 1 ? "" : "s") in range") }
        else { say("scan · nothing within \(fmtDist(scanRange)) · try higher up") }
        if !hintsSeen.contains("scanned") { hintsSeen.insert("scanned") }
    }

    /// called every frame while on foot
    func checkDiscovery() {
        guard mode == .walk else { return }
        for i in sites.indices where !sites[i].discovered {
            if simd_distance(w.pos, sites[i].pos) < Game.discoverRadius {
                sites[i].discovered = true; sites[i].scanned = true
                saveProgress()
                sfx?.discover()
                let s = sites[i], n = sites.filter { $0.world === s.world && $0.discovered }.count
                let total = sites.filter { $0.world === s.world }.count
                banner?(s.kind.title, "\(s.world.name) · \(n) of \(total) discovered")
            }
        }
    }

    func progressText() -> [(String, Int, Int)] {
        worlds.map { w in (w.name, sites.filter { $0.world === w && $0.discovered }.count, sites.filter { $0.world === w }.count) }
    }
}
