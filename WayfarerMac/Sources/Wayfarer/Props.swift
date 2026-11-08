import Foundation
import Metal
import simd

// Props: models by Jungle Jim (CC BY 4.0, see README › Credits), prepared by Tools/blender/batch_props.sh into
// Assets/Props/<name>.mesh (metres) with baked albedo/roughness, normal and (when they glow) emission maps.
// Each placed copy is anchored to a planet's surface, an orbit, or a ship's deck.

struct PropAsset { let mesh: GPUMesh; let skin: BakedSkin; let emit: MTLTexture? }

enum PropAnchor {
    case surface(world: Int, dir: D3, yaw: Double)          // stands on the ground; yaw turns it about the local up
    case orbit(world: Int, offset: D3, spin: Double)          // fixed above a world (km from its centre), turning slowly
    case deck(ship: Int, pos: D3, yaw: Double)                // inside a ship, deck metres
}
struct PropInstance {
    let asset: String
    let anchor: PropAnchor
    var scale = 1.0
    var sink = 0.0                                            // metres pushed into the ground (surface props)
    var glow: Float = 1.0                                     // emission strength
    var baseR = 0.0                                           // surface props: radius of their base from the world centre (km)
}

/// footprint radius (m) of each asset at scale 1, for collision and seating on slopes
let PROP_RADIUS: [String: Double] = ["tower": 12, "apartments": 19, "truck": 4.5, "robot": 1.2, "computer": 3.8, "station": 21,
                                     "chair1": 0.4, "chair2": 0.4, "chair3": 0.4, "chair4": 0.4]

/// loads Assets/Props/<name>.* (nil if missing)
func loadPropAsset(device: MTLDevice, name: String) -> PropAsset? {
    guard let base = assetsURL()?.appendingPathComponent("Props") else { return nil }
    return loadBakedModel(device: device, dir: base, name: name)
}

extension Game {
    /// where the downloaded models go. Ship-deck props also add collision to the deck.
    func placeProps() {
        props.removeAll()
        let E = worlds[0]
        // ---- an outpost town beside the first fuel depot on Earth: towers, apartment blocks, trucks and work robots
        if let dp = depots.first(where: { $0.world === E }) {
            let up = dp.dir, east = simd_normalize(simd_cross(D3(0, 1, 0), up)), north = simd_cross(up, east)
            func at(_ e: Double, _ n: Double) -> D3 { simd_normalize(up + (east * e + north * n) / (E.R * 1000)) }
            // a compact town: four towers round a plaza, apartment blocks in a ring, trucks on the approach road from the depot
            let cx = 620.0, cn = 260.0
            var town: [(String, Double, Double, Double, Double)] = [            // asset, east m, north m, yaw, scale
                ("tower", cx - 45, cn - 45, 0.0, 1.35), ("tower", cx + 45, cn - 45, 0.0, 1.0), ("tower", cx - 45, cn + 45, 0.0, 1.1), ("tower", cx + 45, cn + 45, 0.0, 0.85)]
            for k in 0..<8 {                                            // the apartment ring, facing the plaza
                let a = Double(k) / 8 * .pi * 2 + 0.2, r = 150.0
                town.append(("apartments", cx + cos(a) * r, cn + sin(a) * r, -a + .pi / 2, 1.0))
            }
            for k in 0..<5 { town.append(("truck", 160 + Double(k) * 75, 70 + Double(k) * 32, 0.4 + (k % 2 == 0 ? 0 : .pi), 1.0)) }   // the depot road
            town += [("truck", cx + 8, cn - 18, 1.57, 1.0), ("truck", cx - 10, cn + 12, 0.1, 1.0)]
            town += [("robot", 90, 40, 3.5, 1.0), ("robot", 105, 58, 2.2, 1.0), ("robot", cx + 18, cn + 2, 0.4, 1.0), ("robot", cx - 20, cn - 6, 2.9, 1.0)]
            for (a, e, n, yaw, sc) in town {
                let d = at(e, n), r = (PROP_RADIUS[a] ?? 5) * sc
                // stand on the lowest ground under the footprint so nothing floats on a slope
                let a1 = simd_normalize(simd_cross(d, D3(0, 1, 0))), a2 = simd_cross(d, a1)
                var lo = E.groundRadius(d)
                for (x, y) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] { lo = min(lo, E.groundRadius(simd_normalize(d + (a1 * x + a2 * y) * (r / 1000 / E.R)))) }
                var p = PropInstance(asset: a, anchor: .surface(world: 0, dir: d, yaw: yaw), scale: sc, sink: (E.groundRadius(d) - lo) * 1000 + 1.0)
                p.baseR = lo - 0.001
                props.append(p)
            }
            outpostDir = at(cx, cn)
        }
        // ---- a 4 km city-station in orbit over Earth, near where you start
        let toSun = simd_normalize(sunPos - E.pos)
        let up0 = simd_normalize(rotateY(toSun, 1.05) + D3(0, 0.2, 0))
        let side = simd_normalize(simd_cross(up0, D3(0, 1, 0)))
        stationPos = E.pos + simd_normalize(up0 * 0.97 + side * 0.24) * (E.R + 230)
        props.append(PropInstance(asset: "station", anchor: .orbit(world: 0, offset: stationPos - E.pos, spin: 0.01), scale: 100, glow: 1.6))

        // ---- aboard the Atlas
        let atlas = 2, fy = -6.0, bf = ATLAS_EYE.y - 1.5, dz = ATLAS_EYE.z - 200, bz = ATLAS_BAY_DZ
        var deckProps: [PropInstance] = [
            // the corridor: a real sci-fi hall replacing the plain one (it runs along x in the model: turned to run aft)
            PropInstance(asset: "corridor", anchor: .deck(ship: atlas, pos: D3(0, fy - corridorFloor * 0.75, 80), yaw: .pi / 2), scale: 0.75),
            // supercomputers: bridge back wall and the reactor hall
            PropInstance(asset: "computer", anchor: .deck(ship: atlas, pos: D3(-5, bf, 222.8 + dz), yaw: .pi)),
            PropInstance(asset: "computer", anchor: .deck(ship: atlas, pos: D3(5, bf, 222.8 + dz), yaw: .pi)),
            PropInstance(asset: "computer", anchor: .deck(ship: atlas, pos: D3(21.8, fy, 152), yaw: -.pi / 2)),
            PropInstance(asset: "computer", anchor: .deck(ship: atlas, pos: D3(21.8, fy, 192), yaw: -.pi / 2)),
            PropInstance(asset: "computer", anchor: .deck(ship: atlas, pos: D3(-21.8, fy, 152), yaw: .pi / 2)),
            PropInstance(asset: "computer", anchor: .deck(ship: atlas, pos: D3(-21.8, fy, 192), yaw: .pi / 2)),
            // the new hallway (zaki razzaque, CC BY 4.0): segments from the reactor hall to the bridge lift
            PropInstance(asset: "hallway", anchor: .deck(ship: atlas, pos: D3(0, fy, ATLAS_HALL.z0 + ATLAS_HALL.seg * 0.5), yaw: 0)),
            PropInstance(asset: "hallway", anchor: .deck(ship: atlas, pos: D3(0, fy, ATLAS_HALL.z0 + ATLAS_HALL.seg * 1.5), yaw: 0)),
            PropInstance(asset: "hallway", anchor: .deck(ship: atlas, pos: D3(0, fy, ATLAS_HALL.z0 + ATLAS_HALL.seg * 2.5), yaw: 0)),
            PropInstance(asset: "hallway", anchor: .deck(ship: atlas, pos: D3(0, fy, ATLAS_HALL.z0 + ATLAS_HALL.seg * 3.5), yaw: 0)),
            PropInstance(asset: "hallway", anchor: .deck(ship: atlas, pos: D3(0, fy, ATLAS_HALL.z0 + ATLAS_HALL.seg * 4.5), yaw: 0)),
            // the reactor's core: a sphere of lit panels round the glowing column
            PropInstance(asset: "citysphere", anchor: .deck(ship: atlas, pos: D3(0, fy + 9.5, 175), yaw: 0), scale: 6.5, glow: 2.2),
            // work robots in the cargo bay
            PropInstance(asset: "robot", anchor: .deck(ship: atlas, pos: D3(12, -64, -214 + bz), yaw: 2.6)),
            PropInstance(asset: "truck", anchor: .deck(ship: atlas, pos: D3(-17, -64, -205 + bz), yaw: .pi / 2)),
            PropInstance(asset: "truck", anchor: .deck(ship: atlas, pos: D3(-17, -64, -188 + bz), yaw: .pi / 2)),
            PropInstance(asset: "robot", anchor: .deck(ship: atlas, pos: D3(-9, -64, -196 + bz), yaw: -0.5)),
            // bridge station chairs
            PropInstance(asset: "chair3", anchor: .deck(ship: atlas, pos: D3(-6.0, bf, 212 + dz), yaw: -.pi / 2)),
            PropInstance(asset: "chair3", anchor: .deck(ship: atlas, pos: D3(6.0, bf, 212 + dz), yaw: .pi / 2)),
            // the lounge's big display shows a far-off alien landscape
            PropInstance(asset: "picture", anchor: .deck(ship: atlas, pos: D3(0, fy + 8.0, -39.75), yaw: 0), glow: 1.1)]
        // lounge: rows of chairs looking out of the window walls
        for (i, z) in [-35.0, -29, -23, -13, -1, 5, 11, 15].enumerated() {
            let kind = "chair\(i % 4 + 1)"
            deckProps.append(PropInstance(asset: kind, anchor: .deck(ship: atlas, pos: D3(66, fy, z), yaw: .pi / 2)))
            deckProps.append(PropInstance(asset: kind, anchor: .deck(ship: atlas, pos: D3(-66, fy, z), yaw: -.pi / 2)))
        }
        props += deckProps
        // collision for what stands on the Atlas's decks (not the corridor itself)
        if var d = ships[atlas].deck {
            for p in deckProps {
                guard case let .deck(_, pos, _) = p.anchor, !["corridor", "citysphere", "picture", "hallway"].contains(p.asset) else { continue }
                let r = (PROP_RADIUS[p.asset] ?? 1) * p.scale * (p.asset == "computer" ? 0.55 : 1) + 0.35
                d.obstacles.append(DeckObstacle(x0: pos.x - r, x1: pos.x + r, z0: pos.z - r, z1: pos.z + r, y: pos.y, round: true))
            }
            // the corridor model is wider than the old one: let you walk its full floor
            d.rooms.append(DeckRoom(x0: -corridorHalfW * 0.75 + 0.4, x1: corridorHalfW * 0.75 - 0.4, z0: 21, z1: 139, y0: fy, y1: fy))
            ships[atlas].deck = d
        }
    }

    /// AI ships flying circuits round the station
    func trafficShips() -> [(pos: D3, q: simd_quatd)] {
        let E = worlds[0], up = simd_normalize(stationPos - E.pos)
        let a1 = simd_normalize(simd_cross(up, D3(0, 1, 0))), a2 = simd_cross(up, a1)
        var out: [(pos: D3, q: simd_quatd)] = []
        for k in 0..<5 {
            let r = 4.5 + Double(k) * 1.3, w = 0.45 / r * (k % 2 == 0 ? 1 : -1), ph = Double(k) * 1.3 + time * w
            let tilt = 0.25 * sin(Double(k) * 2.1)
            let p = stationPos + (a1 * cos(ph) + a2 * sin(ph)) * r + up * (tilt * r * sin(ph) + Double(k - 2) * 0.6)
            let vel = (a1 * -sin(ph) + a2 * cos(ph)) * (w > 0 ? 1 : -1) + up * (tilt * cos(ph))
            out.append((p, lookRotation(forward: simd_normalize(vel), up: up)))
        }
        return out
    }
}

extension Renderer {
    /// camera-relative model matrix of a prop, or nil when it isn't drawn this frame
    func propModel(_ p: PropInstance, cam: D3, shipModel: simd_double4x4, aboardShip: Int?) -> simd_double4x4? {
        let g = game
        switch p.anchor {
        case let .surface(wi, dir, yaw):
            let W = g.worlds[wi], pos = W.pos + dir * p.baseR
            if simd_distance(pos, cam) > 70 { return nil }
            let east = simd_normalize(simd_cross(D3(0, 1, 0), dir)), north = simd_cross(dir, east)
            let xb = east * cos(yaw) + north * sin(yaw), zb = simd_cross(xb, dir)
            let basis = simd_double4x4(columns: (SIMD4(xb, 0), SIMD4(dir, 0), SIMD4(zb, 0), SIMD4(0, 0, 0, 1)))
            return translate(pos - cam) * basis * scaleM(D3(repeating: p.scale * 0.001))
        case let .orbit(wi, off, spin):
            let pos = g.worlds[wi].pos + off
            if simd_distance(pos, cam) > 6000 { return nil }
            let up = simd_normalize(off)
            let q = simd_quatd(from: D3(0, 1, 0), to: up) * simd_quatd(angle: g.time * spin, axis: D3(0, 1, 0))
            return translate(pos - cam) * simd_double4x4(q) * scaleM(D3(repeating: p.scale * 0.001))
        case let .deck(si, pos, yaw):
            guard aboardShip == si else { return nil }
            let S = g.ships[si], uM = S.length / (S.size * 1000)
            return shipModel * scaleM(D3(repeating: uM)) * translate(pos) * eulerXYZ(D3(0, yaw, 0)) * scaleM(D3(repeating: p.scale))
        }
    }
}
