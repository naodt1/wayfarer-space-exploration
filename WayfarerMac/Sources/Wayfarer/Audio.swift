import Foundation
import AVFoundation

/// Everything is synthesised live: an engine hum that opens with the throttle, an afterburner roar,
/// and short one-shot effects. M mutes.
final class Audio: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode!
    private var sr = 48000.0
    var muted = false { didSet { tMaster = muted ? 0 : 0.5 * volume } }
    var volume: Float = 0.8 { didSet { tMaster = muted ? 0 : 0.5 * volume } }
    var musicVolume: Float = 0.6 { didSet { tMusic = musicOn ? musicVolume / 0.6 : 0 } }

    // targets written from the main thread, smoothed on the audio thread
    private var tHum: Float = 0, tFreq: Float = 40, tCut: Float = 200, tRoar: Float = 0, tRoarF: Float = 700, tMaster: Float = 0.5, tJet: Float = 0
    private var jetLvl: Float = 0, bpJet = Biquad()
    private var hum: Float = 0, freq: Float = 40, cut: Float = 200, roar: Float = 0, roarF: Float = 700, master: Float = 0.5
    private var p1 = 0.0, p2 = 0.0, p3 = 0.0, brown = 0.0, brown2 = 0.0
    private var lpHum = Biquad(), lpRumble = Biquad(), bpRoar = Biquad(), lpDeep = Biquad()
    private var counter = 0

    // ambient music: slow evolving pad chords and sparse soft bells (N toggles it)
    var musicOn = true { didSet { tMusic = musicOn ? musicVolume / 0.6 : 0 } }
    private var tMusic: Float = 1, musicLvl: Float = 0
    private var padF = [Double](repeating: 110, count: 4), padT = [Double](repeating: 110, count: 4)
    private var padPh = [Double](repeating: 0, count: 8)
    private var chordT = 0.0, chordI = 0, bellT = 2.0, musicTime = 0.0
    private var lpPad = Biquad(), lpPad2 = Biquad()
    private static let chords: [[Double]] = [[45, 52, 60, 64], [41, 48, 57, 64], [48, 55, 59, 64], [43, 50, 59, 62], [45, 52, 59, 64], [41, 53, 57, 60]]
    private static let bells: [Double] = [69, 72, 74, 76, 79, 81, 84, 86]
    private static func hz(_ n: Double) -> Double { 440 * pow(2, (n - 69) / 12) }

    private struct Voice {
        var kind = 0                 // 0 oscillator, 1 white noise, 2 brown noise
        var wave = 0                 // 0 sine 1 triangle 2 saw 3 square
        var f0 = 440.0, f1 = 440.0   // oscillator pitch or filter cutoff sweep
        var dur = 0.1, vol = 0.1, attack = 0.008, delay = 0.0
        var filter = 0               // 0 lowpass 1 bandpass 2 highpass
        var t = 0.0, phase = 0.0, brown = 0.0
        var bq = Biquad()
    }
    private var voices: [Voice] = []
    private var pending: [Voice] = []
    private let lock = NSLock()

    init() {
        let out = engine.outputNode.inputFormat(forBus: 0)
        sr = out.sampleRate > 0 ? out.sampleRate : 48000
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        bpJet.set(1, 1800, 0.7, sr); lpRumble.set(0, 400, 0.7, sr); lpDeep.set(0, 160, 0.7, sr); bpRoar.set(1, 700, 0.5, sr); lpHum.set(0, 220, 0.9, sr); lpPad.set(0, 1100, 0.6, sr); lpPad2.set(0, 1100, 0.6, sr)
        for i in 0..<4 { padF[i] = Audio.hz(Audio.chords[0][i]); padT[i] = padF[i] }
        node = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frameCount, abl -> OSStatus in
            self.render(Int(frameCount), UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
    }

    // MARK: engine voice
    var pitch: Float = 1          // bigger ships sound deeper
    func engine(throttle: Double, ab: Double, on: Bool) {
        let t = Float(throttle), a = Float(ab)
        tHum = on ? 0.11 * (0.45 + t) * (2 - pitch) : 0
        tFreq = (38 + t * 34 + a * 22) * pitch
        tCut = (160 + t * 700 + a * 1400) * pitch
        tRoar = on ? a * 0.22 : 0
        tRoarF = 700 * (0.7 + a * 0.6)
    }

    // MARK: one-shots
    private func push(_ v: Voice) { lock.lock(); pending.append(v); lock.unlock() }
    private func blip(_ f: Double, _ dur: Double = 0.06, _ vol: Double = 0.1, _ wave: Int = 0, _ delay: Double = 0) {
        var v = Voice(); v.kind = 0; v.wave = wave; v.f0 = f; v.f1 = f; v.dur = dur; v.vol = vol; v.delay = delay; push(v)
    }
    private func sweep(brown: Bool, filter: Int, _ f0: Double, _ f1: Double, _ dur: Double, _ vol: Double, _ attack: Double = 0.05, _ delay: Double = 0) {
        var v = Voice(); v.kind = brown ? 2 : 1; v.filter = filter; v.f0 = f0; v.f1 = f1; v.dur = dur; v.vol = vol; v.attack = attack; v.delay = delay; push(v)
    }
    private func boom(_ f0: Double, _ f1: Double, _ dur: Double, _ vol: Double, _ delay: Double = 0) {
        var v = Voice(); v.kind = 0; v.wave = 0; v.f0 = f0; v.f1 = f1; v.dur = dur; v.vol = vol; v.attack = 0.002; v.delay = delay; push(v)
    }
    func jet(_ level: Double) { tJet = Float(level) * 0.22 }
    /// footstep crunch; muffled where the air is thin
    func step(_ v: Double, air: Bool) {
        let a = air ? 1.0 : 0.45
        sweep(brown: true, filter: 0, 520 * a + 120, 80, 0.16, 0.32 * v * a + 0.06, 0.004)
        sweep(brown: false, filter: 1, 2200, 900, 0.07, 0.05 * v * a, 0.003)
    }
    func hatch() { sweep(brown: false, filter: 1, 3200, 300, 0.7, 0.28, 0.02); blip(110, 0.18, 0.12, 3, 0.55); boom(90, 40, 0.3, 0.4) }
    func scan() { sweep(brown: false, filter: 1, 300, 4200, 1.1, 0.16, 0.05); blip(1760, 0.5, 0.05, 0, 0.05); blip(1320, 0.6, 0.04, 0, 0.35) }
    func discover() { for (i, f) in [523.0, 659, 784, 1047].enumerated() { blip(f, 0.9, 0.07, 1, Double(i) * 0.12) }; sweep(brown: false, filter: 1, 600, 3000, 1.6, 0.08, 0.3) }
    func tick(_ lvl: Int) { blip(420 + Double(lvl) * 70, 0.045, 0.06, 1) }
    func full() { blip(880, 0.12, 0.09, 1); blip(1320, 0.22, 0.09, 1, 0.09) }
    /// afterburner light-off: a chest-thumping boom, then the roar building
    func burnerOn() {
        boom(150, 24, 1.3, 1.0); boom(75, 30, 1.6, 0.7, 0.04)                          // thump
        boom(48, 26, 2.6, 0.9, 0.02)                                                    // sub-bass tail
    }
    /// sonic boom: the double crack of the shock waves, then thunder rolling away
    func sonicBoom() {
        for d in [0.0, 0.11] {
            sweep(brown: false, filter: 2, 7000, 1500, 0.07, 1.0, 0.001, d)
            boom(95, 22, 1.4, 1.0, d)
        }
        sweep(brown: true, filter: 0, 700, 45, 3.2, 0.9, 0.01, 0.05)
        sweep(brown: false, filter: 1, 900, 120, 2.4, 0.25, 0.02, 0.1)
    }
    func burnerOff() { boom(80, 32, 0.9, 0.35) }
    func denied() { blip(190, 0.14, 0.08, 3); blip(150, 0.16, 0.08, 3, 0.12) }
    func servo() { var v = Voice(); v.kind = 0; v.wave = 2; v.f0 = 140; v.f1 = 230; v.dur = 0.5; v.vol = 0.05; v.attack = 0.05; push(v); blip(320, 0.06, 0.08, 3, 0.52) }
    /// a heavy ship settling onto its legs: a deep impact, the hull groaning, gravel rattling away
    func heavyLand(_ k: Double) {
        boom(70, 22, 1.8 + k, 0.9 + 0.1 * k); boom(42, 20, 2.6 + k, 0.8 * k, 0.05)
        boom(130, 60, 0.5, 0.4, 0.02)
        sweep(brown: true, filter: 0, 300, 40, 2.6 + k, 0.5 * k, 0.02, 0.1)
        blip(55, 1.4, 0.18 * k, 2, 0.35); blip(41, 1.8, 0.14 * k, 2, 0.6)        // the frame creaking under the load
    }
    func thud() { boom(80, 32, 0.35, 0.7); sweep(brown: true, filter: 0, 600, 80, 0.4, 0.5, 0.005) }
    func lift() { sweep(brown: true, filter: 0, 120, 900, 2.5, 0.45, 0.6) }
    func beep() { blip(660, 0.08, 0.08); blip(990, 0.12, 0.08, 0, 0.1) }
    func arrive() { blip(990, 0.1, 0.08); blip(740, 0.1, 0.08, 0, 0.11); blip(1180, 0.25, 0.07, 0, 0.22) }
    func powerDown() { sweep(brown: false, filter: 0, 1800, 90, 2.2, 0.22, 0.05); boom(120, 30, 1.6, 0.35); blip(660, 0.12, 0.06); blip(440, 0.2, 0.06, 0, 0.15); blip(220, 0.5, 0.05, 0, 0.32); boom(60, 40, 0.25, 0.5, 1.6) }
    func powerUp() { blip(220, 0.15, 0.05); blip(440, 0.15, 0.06, 0, 0.14); blip(880, 0.3, 0.06, 1, 0.28); sweep(brown: false, filter: 1, 120, 2600, 1.6, 0.2, 0.6); boom(40, 90, 1.2, 0.3) }

    // MARK: audio thread
    private func render(_ n: Int, _ bufs: UnsafeMutableAudioBufferListPointer) {
        if lock.try() { voices.append(contentsOf: pending); pending.removeAll(keepingCapacity: true); lock.unlock() }
        let k: Float = 1 - exp(-1 / Float(sr) / 0.2)
        let L = bufs[0].mData!.assumingMemoryBound(to: Float.self), R = bufs.count > 1 ? bufs[1].mData!.assumingMemoryBound(to: Float.self) : L
        let dt = 1 / sr
        for i in 0..<n {
            hum += (tHum - hum) * k; freq += (tFreq - freq) * k * 0.6; cut += (tCut - cut) * k; roar += (tRoar - roar) * k * 1.5; roarF += (tRoarF - roarF) * k
            master += (tMaster - master) * k * 3
            if counter % 64 == 0 { lpHum.set(0, Double(cut), 0.9, sr); bpRoar.set(1, Double(roarF), 0.5, sr) }
            counter &+= 1
            // engine: two detuned saws, a sub sine and a brown-noise rumble through a lowpass
            let f = Double(freq)
            p1 += f * dt; p2 += f * 1.013 * dt; p3 += f * 0.5 * dt
            p1 -= floor(p1); p2 -= floor(p2); p3 -= floor(p3)
            let white = Double.random(in: -1...1)
            brown = (brown + 0.02 * white) / 1.02
            let saw = ((p1 * 2 - 1) + (p2 * 2 - 1)) * 0.35 + sin(p3 * 2 * .pi) * 0.35
            var s = lpHum.run(saw + lpRumble.run(brown * 3.5)) * Double(hum)
            // afterburner roar
            if roar > 0.0005 {
                brown2 = (brown2 + 0.02 * Double.random(in: -1...1)) / 1.02
                s += lpDeep.run(brown2 * 3.5) * 2.2 * Double(roar)          // a deep rumble only, no hiss

            }
            // one-shots
            var vi = 0
            while vi < voices.count {
                var v = voices[vi]
                if v.delay > 0 { v.delay -= dt; voices[vi] = v; vi += 1; continue }
                let tt = v.t / v.dur
                let fNow = v.f0 * pow(v.f1 / v.f0, min(tt, 1))
                let env = v.t < v.attack ? v.vol * v.t / v.attack : v.vol * pow(0.0001 / v.vol, (v.t - v.attack) / max(v.dur - v.attack, 1e-3))
                var x: Double
                if v.kind == 0 {
                    v.phase += fNow * dt; v.phase -= floor(v.phase)
                    switch v.wave {
                    case 1: x = 1 - 4 * abs(v.phase - 0.5)
                    case 2: x = v.phase * 2 - 1
                    case 3: x = v.phase < 0.5 ? 1 : -1
                    default: x = sin(v.phase * 2 * .pi)
                    }
                } else {
                    let wn = Double.random(in: -1...1)
                    if v.kind == 2 { v.brown = (v.brown + 0.02 * wn) / 1.02; x = v.brown * 3.5 } else { x = wn }
                    if Int(v.t * sr) % 32 == 0 { v.bq.set(v.filter, fNow, 0.8, sr) }
                    x = v.bq.run(x)
                }
                s += x * env
                v.t += dt
                if v.t >= v.dur { voices.remove(at: vi); continue }
                voices[vi] = v; vi += 1
            }
            // music
            musicLvl += (tMusic - musicLvl) * k * 0.15
            if musicLvl > 0.0005 {
                musicTime += dt; chordT += dt
                if chordT > 11 { chordT = 0; chordI = (chordI + 1) % Audio.chords.count; for j in 0..<4 { padT[j] = Audio.hz(Audio.chords[chordI][j]) } }
                var pad = 0.0
                for j in 0..<4 {
                    padF[j] += (padT[j] - padF[j]) * dt * 0.6                      // notes glide slowly into the next chord
                    padPh[j] += padF[j] * dt; padPh[j] -= floor(padPh[j])
                    padPh[j + 4] += padF[j] * 1.004 * dt; padPh[j + 4] -= floor(padPh[j + 4])
                    let swell = 0.75 + 0.25 * sin(musicTime * (0.11 + Double(j) * 0.037) + Double(j) * 1.7)
                    pad += (sin(padPh[j] * 2 * .pi) + sin(padPh[j + 4] * 2 * .pi) * 0.8 + sin(padPh[j] * 4 * .pi) * 0.18) * swell
                }
                s += lpPad2.run(lpPad.run(pad)) * 0.028 * Double(musicLvl)
                bellT -= dt
                if bellT <= 0 {
                    bellT = Double.random(in: 1.8...5.5)
                    var v = Voice(); v.kind = 0; v.wave = 0
                    v.f0 = Audio.hz(Audio.bells.randomElement()!); v.f1 = v.f0; v.dur = 4.5; v.vol = 0.035 * Double(musicLvl); v.attack = 0.01
                    voices.append(v)
                    if Bool.random() { var e = v; e.delay = 0.38; e.vol *= 0.45; voices.append(e) }   // a soft echo
                }
            }
            jetLvl += (tJet - jetLvl) * k * 4
            if jetLvl > 0.0005 { s += bpJet.run(white) * Double(jetLvl) }
            let out = Float(tanh(s * 0.9)) * master
            L[i] = out; R[i] = out
        }
    }
}

struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0, z1 = 0.0, z2 = 0.0
    /// type 0 lowpass, 1 bandpass, 2 highpass (RBJ cookbook)
    mutating func set(_ type: Int, _ f: Double, _ q: Double, _ sr: Double) {
        let w = 2 * Double.pi * min(max(f, 10), sr * 0.45) / sr, cs = cos(w), sn = sin(w), alpha = sn / (2 * q)
        var nb0, nb1, nb2: Double
        switch type {
        case 1: nb0 = alpha; nb1 = 0; nb2 = -alpha
        case 2: nb0 = (1 + cs) / 2; nb1 = -(1 + cs); nb2 = (1 + cs) / 2
        default: nb0 = (1 - cs) / 2; nb1 = 1 - cs; nb2 = (1 - cs) / 2
        }
        let a0 = 1 + alpha
        b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0; a1 = -2 * cs / a0; a2 = (1 - alpha) / a0
    }
    @inline(__always) mutating func run(_ x: Double) -> Double { let y = b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y }
}
