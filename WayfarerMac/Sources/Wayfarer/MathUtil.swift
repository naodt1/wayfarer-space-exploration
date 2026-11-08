import Foundation
import simd

typealias D3 = SIMD3<Double>
typealias F3 = SIMD3<Float>
typealias F4 = SIMD4<Float>

@inline(__always) func clampd(_ v: Double, _ a: Double, _ b: Double) -> Double { max(a, min(b, v)) }
@inline(__always) func ss(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clampd((x - e0) / (e1 - e0), 0, 1); return t * t * (3 - 2 * t)
}
@inline(__always) func damp(_ a: Double, _ b: Double, _ r: Double, _ dt: Double) -> Double { a + (b - a) * (1 - exp(-r * dt)) }
@inline(__always) func mixd(_ a: D3, _ b: D3, _ t: Double) -> D3 { a + (b - a) * t }

extension SIMD3 where Scalar == Double {
    var f: F3 { F3(Float(x), Float(y), Float(z)) }
}

/// sRGB hex -> linear colour (matches THREE.Color colour management)
func linearColor(_ hex: Int) -> D3 {
    func c(_ v: Int) -> Double {
        let s = Double(v) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }
    return D3(c((hex >> 16) & 255), c((hex >> 8) & 255), c(hex & 255))
}

/// Reversed-Z perspective with an infinite far plane: depth 1 at near, 0 at infinity.
func perspectiveReversedInfinite(fovyRadians: Float, aspect: Float, near: Float) -> float4x4 {
    let y = 1 / tan(fovyRadians * 0.5), x = y / aspect
    return float4x4(columns: (F4(x, 0, 0, 0), F4(0, y, 0, 0), F4(0, 0, 0, -1), F4(0, 0, near, 0)))
}

/// Orientation whose -Z axis points along `forward` and +Y leans toward `up`.
func lookRotation(forward: D3, up: D3) -> simd_quatd {
    let z = simd_normalize(-forward)
    var x = simd_cross(up, z)
    if simd_length_squared(x) < 1e-12 { x = simd_cross(D3(0, 0, 1), z); if simd_length_squared(x) < 1e-12 { x = D3(1, 0, 0) } }
    x = simd_normalize(x)
    let y = simd_cross(z, x)
    return simd_quatd(simd_double3x3(columns: (x, y, z)))
}

func slerpShort(_ a: simd_quatd, _ b: simd_quatd, _ t: Double) -> simd_quatd {
    var b = b
    if simd_dot(a.vector, b.vector) < 0 { b = simd_quatd(vector: -b.vector) }
    return simd_slerp(a, b, t)
}

func axisAngle(_ axis: D3, _ angle: Double) -> simd_quatd { simd_quatd(angle: angle, axis: axis) }

/// rotation (+ optional uniform scale) and translation into a float matrix
func modelMatrix(rel: D3, q: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), scale: D3 = D3(1, 1, 1)) -> float4x4 {
    let r = simd_double3x3(q)
    let c0 = r.columns.0 * scale.x, c1 = r.columns.1 * scale.y, c2 = r.columns.2 * scale.z
    return float4x4(columns: (F4(c0.f, 0), F4(c1.f, 0), F4(c2.f, 0), F4(rel.f, 1)))
}

func viewMatrix(_ camQ: simd_quatd) -> float4x4 {
    let r = simd_double3x3(camQ).transpose
    return float4x4(columns: (F4(r.columns.0.f, 0), F4(r.columns.1.f, 0), F4(r.columns.2.f, 0), F4(0, 0, 0, 1)))
}

func rotateY(_ v: D3, _ a: Double) -> D3 { D3(v.x * cos(a) + v.z * sin(a), v.y, -v.x * sin(a) + v.z * cos(a)) }
