import Foundation
import Metal
import simd

// MARK: - CL505: a 32 m interceptor
//
// Hull: "Spaceship CL505" by Jungle Jim, licensed under Creative Commons Attribution (CC BY 4.0), from Sketchfab.
// Imported into Blender (Tools/blender/prep_cl505.py), baked and exported by Tools/blender/export_ship.py.
// The model carries its own landing wheels, so the game draws no separate legs for it.

func buildCL505(device: MTLDevice) -> ShipModel? {
    guard let asset = loadShipAsset(device: device, name: "cl505") else { return nil }
    let eye = D3(0, 0.14, -0.06)
    var s = ShipModel(
        name: "CL505", role: "INTERCEPTOR", paint: 0, speedK: 1.15, pitch: 1.1, agility: 1.15, fuelEff: 0.3,
        hull: asset.mesh, leg: GPUMesh(device: device, verts: []), plume: plumeCone(device: device),
        eye: eye,
        cockpit: buildCockpit(device: device, style: .fighter, canopy: D3(0, 0.125, -0.06), half: D3(0.055, 0.05, 0.16), eye: eye, unitsPerMetre: 1.4 / 32),
        length: 1.4, size: 0.032, gearBottom: 0.197,
        legs: [],
        // measured from the model's rear (Tools/blender/find_nozzles.py): two main rings, four small thrusters
        engines: [(pos: D3(0.182, 0.024, 0.54), r: 0.048, pivot: -1), (pos: D3(-0.182, 0.024, 0.54), r: 0.048, pivot: -1),
                  (pos: D3(0.066, 0.1, 0.548), r: 0.02, pivot: -1), (pos: D3(-0.066, 0.1, 0.548), r: 0.02, pivot: -1),
                  (pos: D3(0.31, 0.018, 0.56), r: 0.018, pivot: -1), (pos: D3(-0.31, 0.018, 0.56), r: 0.018, pivot: -1)],
        vtols: [],
        navLights: [(D3(-0.63, 0.0, 0.3), SIMD3(1, 0.23, 0.23), 0.07), (D3(0.63, 0.0, 0.3), SIMD3(0.23, 1, 0.48), 0.07)],
        steadyLights: [(D3(0, 0.0, -0.7), SIMD3(1, 1, 1), 0.06)],
        landLights: [D3(0.2, -0.12, -0.3), D3(-0.2, -0.12, -0.3)])
    s.skin = asset.skin
    s.flame = (edge: SIMD3(0.25, 0.5, 2.4), core: SIMD3(1.2, 1.8, 3.4), hot: SIMD3(0.6, 1.2, 3.6), glow: D3(1.4, 0.35, 0.18))   // red-hot nozzles, blue flame
    s.canopyCut = (D3(0, 0.095, -0.24), D3(0.075, 0.4, 0.1))   // opened up around the pilot in cockpit view
    return s
}

// MARK: - Heron: a 26 m racer
// Hull: "Heron Spaceship V2 (animated)" by Jungle Jim, CC BY 4.0 (Sketchfab), posed as in its first frame.
func buildHeron(device: MTLDevice) -> ShipModel? {
    guard let asset = loadShipAsset(device: device, name: "heron") else { return nil }
    let eye = D3(0, 0.12, -0.28)
    var s = ShipModel(
        name: "Heron", role: "RACER", paint: 0, speedK: 1.6, pitch: 1.25, agility: 1.35, fuelEff: 0.4,
        hull: asset.mesh, leg: GPUMesh(device: device, verts: []), plume: plumeCone(device: device),
        eye: eye,
        cockpit: buildCockpit(device: device, style: .fighter, canopy: D3(0, 0.1, -0.28), half: D3(0.05, 0.05, 0.14), eye: eye, unitsPerMetre: 1.4 / 26),
        length: 1.4, size: 0.026, gearBottom: 0.2,
        legs: [],
        engines: [(pos: D3(0.001, -0.037, 0.432), r: 0.034, pivot: -1)],    // its red nozzle, measured from the model
        vtols: [],
        navLights: [(D3(-0.25, 0.0, 0.45), SIMD3(1, 0.23, 0.23), 0.06), (D3(0.25, 0.0, 0.45), SIMD3(0.23, 1, 0.48), 0.06)],
        steadyLights: [(D3(0, 0.0, -0.7), SIMD3(1, 1, 1), 0.05)],
        landLights: [D3(0, -0.15, -0.3)])
    s.skin = asset.skin
    s.flame = (edge: SIMD3(2.0, 0.25, 0.08), core: SIMD3(3.0, 0.9, 0.35), hot: SIMD3(3.4, 0.7, 0.2), glow: D3(1.6, 0.28, 0.1))   // its engine glows red
    s.canopyCut = (D3(0, 0.07, -0.42), D3(0.07, 0.4, -0.12))
    return s
}

/// every flyable ship, in selector order
func allShips(device: MTLDevice) -> [ShipModel] {
    // the Heron takes the Condor's place (the Condor stays in the code, unused)
    var ships = [buildKestrel(device: device), buildHeron(device: device) ?? buildCondor(device: device), buildAtlas(device: device)]
    if let c = buildCL505(device: device) { ships.append(c) }
    return ships
}
