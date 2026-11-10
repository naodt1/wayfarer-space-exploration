import Foundation
import Metal
import CoreGraphics
import ImageIO
import simd

// Trees, bushes and flowers: "Low poly trees, flowers and grass" by Márcio Meireles (CC BY 4.0), exported by
// Tools/blender/prep_flora.py into Assets/Models/flora. Each model is one or more parts (bark, leaves, petals, stem),
// each with its own texture; leaves and petals are alpha cut-outs. They are scattered by RockField (tiers 3 and 4)
// and drawn instanced with the tree shader (wind sway, light through the leaves, leaf-shaped shadows).

let FLORA_KIND = 200            // RockInstance.kind >= this: a flora model (index = kind - FLORA_KIND)
let TREE_RANGE = 1.1            // km: trees are drawn out to here
let BUSH_RANGE = 0.075          // km: bushes and flowers

let FLORA_CAP = 40000
struct FloraSeg { let model: Int; let start: Int; let count: Int; let shadow: Bool }
struct FloraPart { let mesh: RockLOD; let texture: MTLTexture; let cutout: Bool }
struct FloraModel { let name: String; let height: Float; let parts: [FloraPart]; var isTree: Bool { name.hasPrefix("tree") } }

final class FloraSet {
    let models: [FloraModel]
    init(models: [FloraModel]) { self.models = models }
    /// model indices by role, for placement
    func indices(_ match: (String) -> Bool) -> [Int] { models.indices.filter { match(models[$0].name) } }
}

func loadFlora(device: MTLDevice) -> FloraSet? {
    guard let dir = assetsURL()?.appendingPathComponent("Models/flora"),
          let data = try? Data(contentsOf: dir.appendingPathComponent("flora.json")),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { print("flora not found"); return nil }
    let q = device.makeCommandQueue()!, cb = q.makeCommandBuffer()!, bl = cb.makeBlitCommandEncoder()!
    var models: [FloraModel] = []
    for m in list {
        guard let name = m["name"] as? String, let parts = m["parts"] as? [[String: Any]] else { continue }
        var out: [FloraPart] = []
        for p in parts {
            guard let bin = p["bin"] as? String, let png = p["png"] as? String,
                  let raw = try? Data(contentsOf: dir.appendingPathComponent(bin)), raw.count >= 96 else { continue }
            let n = raw.count / 32
            let idx = (0..<UInt32(n)).map { $0 }
            let vb = raw.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: raw.count, options: .storageModeShared)! }
            let ib = device.makeBuffer(bytes: idx, length: idx.count * 4, options: .storageModeShared)!
            guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(png) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            // straight (not premultiplied) alpha, so cut-out edges keep their colour
            guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            for i in 0..<(w * h) {
                let a = Int(px[i * 4 + 3])
                if a > 0 && a < 255 { for c in 0..<3 { px[i * 4 + c] = UInt8(min(255, Int(px[i * 4 + c]) * 255 / a)) } }
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: w, height: h, mipmapped: true)
            d.usage = .shaderRead; d.storageMode = .shared
            let t = device.makeTexture(descriptor: d)!
            t.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: px, bytesPerRow: w * 4)
            bl.generateMipmaps(for: t)
            out.append(FloraPart(mesh: RockLOD(vb: vb, ib: ib, indexCount: n), texture: t, cutout: p["cutout"] as? Bool ?? false))
        }
        if !out.isEmpty { models.append(FloraModel(name: name, height: Float(m["height"] as? Double ?? 1), parts: out)) }
    }
    bl.endEncoding(); cb.commit(); cb.waitUntilCompleted()
    return models.isEmpty ? nil : FloraSet(models: models)
}
