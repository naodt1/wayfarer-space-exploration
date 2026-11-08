import Foundation
import Metal
import Darwin

/// memory use: the app's footprint in RAM (what Activity Monitor shows) and what Metal has allocated on the GPU
func memoryStats(_ device: MTLDevice) -> (ramMB: Double, gpuMB: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    let ram = kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    return (ram, Double(device.currentAllocatedSize) / 1_048_576)
}

// Player settings, saved between launches (UserDefaults). Open with the comma key, ⌘, from the menu bar, or from
// the Esc menu. ↑ ↓ pick a row, ← → change it, Esc closes.

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    var volume: Double { didSet { save() } }          // 0…1, all sound
    var music: Double { didSet { save() } }           // 0…1, the soundtrack
    var mouseSens: Double { didSet { save() } }       // 0.25…3
    var invertY: Bool { didSet { save() } }
    var quality: Int { didSet { save() } }            // 0 auto, 1 performance, 2 balanced, 3 maximum
    var showFPS: Bool { didSet { save() } }

    private init() {
        d.register(defaults: ["volume": 0.8, "music": 0.6, "mouseSens": 1.0, "invertY": false, "quality": 0, "showFPS": false])
        volume = d.double(forKey: "volume"); music = d.double(forKey: "music"); mouseSens = d.double(forKey: "mouseSens")
        invertY = d.bool(forKey: "invertY"); quality = d.integer(forKey: "quality"); showFPS = d.bool(forKey: "showFPS")
    }
    private func save() {
        d.set(volume, forKey: "volume"); d.set(music, forKey: "music"); d.set(mouseSens, forKey: "mouseSens")
        d.set(invertY, forKey: "invertY"); d.set(quality, forKey: "quality"); d.set(showFPS, forKey: "showFPS")
    }

    static let qualityNames = ["Auto (holds the frame rate)", "Performance", "Balanced", "Maximum"]
    /// fixed internal resolution for each quality level (nil = adaptive)
    var fixedScale: Double? { [nil, 0.6, 0.8, 1.0][max(0, min(3, quality))] }

    /// rows shown in the settings panel
    func rows(fullscreen: Bool) -> [(String, String)] {
        func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
        return [("Sound volume", pct(volume)), ("Music volume", pct(music)), ("Mouse sensitivity", String(format: "%.2f×", mouseSens)),
                ("Invert mouse Y", invertY ? "On" : "Off"), ("Graphics quality", Settings.qualityNames[quality]),
                ("Show frame rate", showFPS ? "On" : "Off"), ("Full screen", fullscreen ? "On" : "Off")]
    }
    static let rowCount = 7
    /// change a row by one step left (-1) or right (+1); returns true for the full-screen row (the caller toggles it)
    func adjust(_ row: Int, _ dir: Int) -> Bool {
        switch row {
        case 0: volume = min(1, max(0, volume + 0.1 * Double(dir)))
        case 1: music = min(1, max(0, music + 0.1 * Double(dir)))
        case 2: mouseSens = min(3, max(0.25, mouseSens + 0.25 * Double(dir)))
        case 3: invertY.toggle()
        case 4: quality = (quality + dir + 4) % 4
        case 5: showFPS.toggle()
        default: return true
        }
        return false
    }
}
