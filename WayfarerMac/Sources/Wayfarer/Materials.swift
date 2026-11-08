import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

/// Ground material layers, in texture-array order.
enum Layer: Int, CaseIterable { case grass = 0, forest, rock, sand, snow, redRock }
let LAYER_COUNT = Layer.allCases.count
private let layerFolders = ["Grass004", "Ground078", "Rock058", "Ground054", "Snow010A", "Rock029"]

/// Finds the Assets folder whether running from the .app bundle or from .build/ during development.
func assetsURL() -> URL? {
    var candidates: [URL] = []
    if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("Assets")) }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<5 { candidates.append(dir.appendingPathComponent("Assets")); dir = dir.deletingLastPathComponent() }
    candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Assets"))
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Terrain").path) }
}

struct TerrainMaterials {
    let albedo: MTLTexture          // 2D array, sRGB colour
    let packed: MTLTexture          // 2D array: R,G = normal xy, B = roughness, A = ambient occlusion
    let means: [SIMD4<Float>]       // average linear colour of each layer (used to tint toward each world's palette)
}

private func decodeRGBA(_ url: URL, size: Int, srgb: Bool) -> [UInt8]? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var px = [UInt8](repeating: 0, count: size * size * 4)
    let cs = srgb ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    return px
}

func loadTerrainMaterials(device: MTLDevice, size: Int = 2048) -> TerrainMaterials? {
    guard let base = assetsURL()?.appendingPathComponent("Terrain") else { print("terrain textures not found"); return nil }
    func arrayTex(_ fmt: MTLPixelFormat) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray; d.pixelFormat = fmt; d.width = size; d.height = size; d.arrayLength = LAYER_COUNT
        d.mipmapLevelCount = Int(log2(Double(size))) + 1; d.usage = .shaderRead; d.storageMode = .shared
        return device.makeTexture(descriptor: d)!
    }
    let albedo = arrayTex(.rgba8Unorm_srgb), packed = arrayTex(.rgba8Unorm)
    var means = [SIMD4<Float>](repeating: SIMD4(0.3, 0.3, 0.3, 1), count: LAYER_COUNT)
    let region = MTLRegionMake2D(0, 0, size, size)
    // decode the 24 images in parallel
    var results = [(color: [UInt8], pack: [UInt8])?](repeating: nil, count: LAYER_COUNT)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: LAYER_COUNT) { i in
        let dir = base.appendingPathComponent(layerFolders[i])
        guard let c = decodeRGBA(dir.appendingPathComponent("Color.jpg"), size: size, srgb: true),
              let n = decodeRGBA(dir.appendingPathComponent("NormalGL.jpg"), size: size, srgb: false),
              let r = decodeRGBA(dir.appendingPathComponent("Roughness.jpg"), size: size, srgb: false) else { return }
        let ao = decodeRGBA(dir.appendingPathComponent("AmbientOcclusion.jpg"), size: size, srgb: false)
        var p = [UInt8](repeating: 255, count: size * size * 4)
        for k in 0..<(size * size) {
            p[k * 4] = n[k * 4]; p[k * 4 + 1] = n[k * 4 + 1]; p[k * 4 + 2] = r[k * 4]; p[k * 4 + 3] = ao?[k * 4] ?? 255
        }
        lock.lock(); results[i] = (c, p); lock.unlock()
    }
    for i in 0..<LAYER_COUNT {
        guard let r = results[i] else { print("missing textures for \(layerFolders[i])"); return nil }
        albedo.replace(region: region, mipmapLevel: 0, slice: i, withBytes: r.color, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        packed.replace(region: region, mipmapLevel: 0, slice: i, withBytes: r.pack, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
        // mean linear colour, sampled sparsely
        var acc = SIMD3<Double>(0, 0, 0); var n = 0
        for k in stride(from: 0, to: size * size, by: 97) {
            func lin(_ v: UInt8) -> Double { let s = Double(v) / 255; return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
            acc += SIMD3(lin(r.color[k * 4]), lin(r.color[k * 4 + 1]), lin(r.color[k * 4 + 2])); n += 1
        }
        let m = acc / Double(n)
        means[i] = SIMD4(Float(m.x), Float(m.y), Float(m.z), 1)
    }
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
    bl.generateMipmaps(for: albedo); bl.generateMipmaps(for: packed); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return TerrainMaterials(albedo: albedo, packed: packed, means: means)
}
