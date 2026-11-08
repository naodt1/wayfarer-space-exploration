import Foundation
import Metal
import CoreGraphics
import ImageIO

// Ships modelled in Blender (Tools/blender) and exported with export_ship.py: a triangle mesh in the same vertex
// layout as the procedural ships, plus baked textures: albedo (RGB) + roughness (A), and an object-space normal map.

struct BakedSkin { let albedo: MTLTexture; let normal: MTLTexture }

/// decodes a PNG keeping straight (not premultiplied) alpha, so data in the alpha channel survives
private func decodeStraight(_ url: URL) -> (w: Int, h: Int, px: [UInt8])? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    if img.bitsPerComponent == 8, img.bitsPerPixel == 32, img.alphaInfo == .last, let data = img.dataProvider?.data as Data? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for y in 0..<h { for x in 0..<(w * 4) { px[y * w * 4 + x] = b[y * img.bytesPerRow + x] } }
        }
        return (w, h, px)
    }
    // fallback: draw (premultiplies; fine for images whose alpha is 1)
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, px)
}

private func texture(_ device: MTLDevice, _ url: URL, srgb: Bool) -> MTLTexture? {
    guard let (w, h, px) = decodeStraight(url) else { return nil }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm, width: w, height: h, mipmapped: true)
    d.usage = .shaderRead
    let t = device.makeTexture(descriptor: d)!
    t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
    bl.generateMipmaps(for: t); bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return t
}

/// loads Assets/Ships/<name>.mesh and its textures, or nil if they're missing (the procedural model is used instead)
func loadShipAsset(device: MTLDevice, name: String) -> (mesh: GPUMesh, skin: BakedSkin)? {
    guard ProcessInfo.processInfo.environment["WAYFARER_OLDSHIPS"] == nil, let base = assetsURL()?.appendingPathComponent("Ships"),
          let m = loadBakedModel(device: device, dir: base, name: name) else { return nil }
    return (m.mesh, m.skin)
}
/// <dir>/<name>.mesh plus <name>_albedo.png, <name>_normal.png and (optionally) <name>_emit.png
func loadBakedModel(device: MTLDevice, dir base: URL, name: String) -> PropAsset? {
    guard let data = try? Data(contentsOf: base.appendingPathComponent("\(name).mesh")), data.count % 36 == 0, data.count > 0,
          let a = texture(device, base.appendingPathComponent("\(name)_albedo.png"), srgb: true),
          let n = texture(device, base.appendingPathComponent("\(name)_normal.png"), srgb: false) else { return nil }
    let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let e = texture(device, base.appendingPathComponent("\(name)_emit.png"), srgb: true)
    return PropAsset(mesh: GPUMesh(device: device, verts: floats), skin: BakedSkin(albedo: a, normal: n), emit: e)
}
/// a plain image as a texture (sky panoramas, pictures)
func loadImageTexture(device: MTLDevice, _ url: URL) -> MTLTexture? { texture(device, url, srgb: true) }
