import Foundation

/// mulberry32 — bit-identical to the JavaScript version so the worlds match the web build
final class Mulberry {
    private var s: UInt32
    init(_ seed: UInt32) { s = seed }
    func next() -> Double {
        s = s &+ 0x6D2B79F5
        var t = (s ^ (s >> 15)) &* (1 | s)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296.0
    }
}

private let GRAD: [Double] = [1,1,0,-1,1,0,1,-1,0,-1,-1,0,1,0,1,-1,0,1,1,0,-1,-1,0,-1,0,1,1,0,-1,1,0,1,-1,0,-1,-1]

/// Seeded 3D simplex noise (Gustavson), same tables/permutation as the web build.
final class Simplex: @unchecked Sendable {
    private let perm: UnsafeMutablePointer<Int32>
    private let pm: UnsafeMutablePointer<Int32>
    private let gr: UnsafeMutablePointer<Double>

    init(_ seed: UInt32) {
        let rnd = Mulberry(seed)
        var p = [Int32](0..<256)
        var i = 255
        while i > 0 {
            let j = Int(rnd.next() * Double(i + 1))
            p.swapAt(i, j); i -= 1
        }
        perm = .allocate(capacity: 512); pm = .allocate(capacity: 512); gr = .allocate(capacity: GRAD.count)
        for k in 0..<512 { perm[k] = p[k & 255]; pm[k] = (perm[k] % 12) * 3 }
        for k in 0..<GRAD.count { gr[k] = GRAD[k] }
    }

    @inline(__always) func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let F3 = 1.0 / 3.0, G3 = 1.0 / 6.0
        let s = (x + y + z) * F3
        let i = Int(floor(x + s)), j = Int(floor(y + s)), k = Int(floor(z + s))
        let t = Double(i + j + k) * G3
        let x0 = x - Double(i) + t, y0 = y - Double(j) + t, z0 = z - Double(k) + t
        var i1 = 0, j1 = 0, k1 = 0, i2 = 0, j2 = 0, k2 = 0
        if x0 >= y0 {
            if y0 >= z0 { i1 = 1; i2 = 1; j2 = 1 }
            else if x0 >= z0 { i1 = 1; i2 = 1; k2 = 1 }
            else { k1 = 1; i2 = 1; k2 = 1 }
        } else {
            if y0 < z0 { k1 = 1; j2 = 1; k2 = 1 }
            else if x0 < z0 { j1 = 1; j2 = 1; k2 = 1 }
            else { j1 = 1; i2 = 1; j2 = 1 }
        }
        let x1 = x0 - Double(i1) + G3, y1 = y0 - Double(j1) + G3, z1 = z0 - Double(k1) + G3
        let x2 = x0 - Double(i2) + 2 * G3, y2 = y0 - Double(j2) + 2 * G3, z2 = z0 - Double(k2) + 2 * G3
        let x3 = x0 - 1 + 3 * G3, y3 = y0 - 1 + 3 * G3, z3 = z0 - 1 + 3 * G3
        let ii = i & 255, jj = j & 255, kk = k & 255
        var n = 0.0
        var tt = 0.6 - x0 * x0 - y0 * y0 - z0 * z0
        if tt > 0 { let g = Int(pm[ii + Int(perm[jj + Int(perm[kk])])]); tt *= tt; n += tt * tt * (gr[g] * x0 + gr[g + 1] * y0 + gr[g + 2] * z0) }
        tt = 0.6 - x1 * x1 - y1 * y1 - z1 * z1
        if tt > 0 { let g = Int(pm[ii + i1 + Int(perm[jj + j1 + Int(perm[kk + k1])])]); tt *= tt; n += tt * tt * (gr[g] * x1 + gr[g + 1] * y1 + gr[g + 2] * z1) }
        tt = 0.6 - x2 * x2 - y2 * y2 - z2 * z2
        if tt > 0 { let g = Int(pm[ii + i2 + Int(perm[jj + j2 + Int(perm[kk + k2])])]); tt *= tt; n += tt * tt * (gr[g] * x2 + gr[g + 1] * y2 + gr[g + 2] * z2) }
        tt = 0.6 - x3 * x3 - y3 * y3 - z3 * z3
        if tt > 0 { let g = Int(pm[ii + 1 + Int(perm[jj + 1 + Int(perm[kk + 1])])]); tt *= tt; n += tt * tt * (gr[g] * x3 + gr[g + 1] * y3 + gr[g + 2] * z3) }
        return 32 * n
    }
}

@inline(__always) func fbm(_ n: Simplex, _ x: Double, _ y: Double, _ z: Double, _ freq0: Double, _ oct: Int, _ gain: Double = 0.5) -> Double {
    var s = 0.0, a = 1.0, norm = 0.0, freq = freq0
    for _ in 0..<max(oct, 0) { s += a * n(x * freq, y * freq, z * freq); norm += a; a *= gain; freq *= 2.03 }
    return norm > 0 ? s / norm : 0
}

@inline(__always) func ridged(_ n: Simplex, _ x: Double, _ y: Double, _ z: Double, _ freq0: Double, _ oct: Int, _ gain: Double = 0.5) -> Double {
    var s = 0.0, a = 1.0, norm = 0.0, w = 1.0, freq = freq0
    for _ in 0..<max(oct, 0) {
        var v = 1 - abs(n(x * freq, y * freq, z * freq)); v *= v * w; w = clampd(v * 1.6, 0, 1)
        s += a * v; norm += a; a *= gain; freq *= 2.07
    }
    return norm > 0 ? s / norm : 0
}
