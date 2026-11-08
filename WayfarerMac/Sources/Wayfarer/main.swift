import AppKit
import MetalKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - HUD

/// fast-changing numbers for the cockpit's holographic HUD, kept apart so updating them every frame
/// doesn't redraw the rest of the interface
struct HoloState {
    var pitch = 0.0, roll = 0.0, heading = 0.0, fov = 72.0
    var speed = "0", speedUnit = "m/s", alt = "0", altUnit = "m", throttle = 0.0, afterburner = 0.0
    var vtol = false, gear = false, hover = false, power = true, landed = false
    var planet = ""
    var fuel = 1.0
}
final class HoloModel: ObservableObject { @Published var s = HoloState() }

func fillHolo(_ g: Game) -> HoloState {
    var h = HoloState()
    let a = g.attitude
    h.pitch = a.pitch; h.roll = a.roll; h.heading = a.heading; h.fov = g.fov
    let v = g.v * 1000
    if v < 10000 { h.speed = String(format: "%.0f", v); h.speedUnit = "m/s" } else { h.speed = String(format: "%.1f", g.v); h.speedUnit = "km/s" }
    let alt = max(0, g.alt) * 1000
    if alt < 10000 { h.alt = String(format: "%.0f", alt); h.altUnit = "m" } else { h.alt = String(format: "%.1f", alt / 1000); h.altUnit = "km" }
    h.throttle = g.mode == .hover ? 0.5 : g.throttle; h.afterburner = g.abLevel
    h.vtol = g.vtol > 0.4 || g.tilt > 0.5; h.gear = g.gear > 0.5; h.hover = g.mode == .hover; h.power = g.power; h.landed = g.mode == .landed
    h.planet = g.near.name; h.fuel = g.fuel
    return h
}

/// green holographic flight display drawn over the cockpit view (helmet-fixed)
struct CockpitHUD: View {
    @ObservedObject var h: HoloModel
    var body: some View {
        SwiftUI.Canvas { ctx, size in
            let s = h.s
            let g = Color(red: 0.55, green: 1.0, blue: 0.45)
            let W = size.width, H = size.height, cx = W / 2, cy = H / 2
            let pxDeg = H / max(20, s.fov)
            ctx.addFilter(.shadow(color: g.opacity(0.6), radius: 3))
            func stroke(_ p: Path, _ a: Double = 0.85, _ w: Double = 1.4) { ctx.stroke(p, with: .color(g.opacity(a)), lineWidth: w) }
            func label(_ t: String, _ x: Double, _ y: Double, _ sz: Double = 12, _ anchor: UnitPoint = .center, _ a: Double = 0.9) {
                ctx.draw(Text(t).font(.system(size: sz, weight: .medium).monospacedDigit()).foregroundColor(g.opacity(a)), at: CGPoint(x: x, y: y), anchor: anchor)
            }
            // pitch ladder and horizon, rolled with the ship
            var lad = ctx
            lad.translateBy(x: cx, y: cy); lad.rotate(by: .degrees(-s.roll))
            lad.clip(to: Path(ellipseIn: CGRect(x: -W * 0.22, y: -H * 0.3, width: W * 0.44, height: H * 0.6)))
            for p in stride(from: -80, through: 80, by: 10) {
                let y = (s.pitch - Double(p)) * pxDeg
                if abs(y) > H * 0.32 { continue }
                let half = p == 0 ? W * 0.2 : W * 0.065, gap = W * 0.03
                var path = Path()
                path.move(to: CGPoint(x: -half, y: y)); path.addLine(to: CGPoint(x: -gap, y: y))
                path.move(to: CGPoint(x: gap, y: y)); path.addLine(to: CGPoint(x: half, y: y))
                if p != 0 {   // end ticks point toward the horizon
                    let t = p > 0 ? 7.0 : -7.0
                    path.move(to: CGPoint(x: -half, y: y)); path.addLine(to: CGPoint(x: -half, y: y + t))
                    path.move(to: CGPoint(x: half, y: y)); path.addLine(to: CGPoint(x: half, y: y + t))
                }
                lad.stroke(path, with: .color(g.opacity(p == 0 ? 0.9 : 0.6)), style: StrokeStyle(lineWidth: p == 0 ? 1.8 : 1.2, dash: p < 0 ? [8, 5] : []))
                if p != 0 {
                    lad.draw(Text("\(abs(p))").font(.system(size: 10).monospacedDigit()).foregroundColor(g.opacity(0.7)), at: CGPoint(x: half + 14, y: y))
                    lad.draw(Text("\(abs(p))").font(.system(size: 10).monospacedDigit()).foregroundColor(g.opacity(0.7)), at: CGPoint(x: -half - 14, y: y))
                }
            }
            // boresight
            var bore = Path()
            bore.move(to: CGPoint(x: cx - 26, y: cy)); bore.addLine(to: CGPoint(x: cx - 10, y: cy)); bore.addLine(to: CGPoint(x: cx - 5, y: cy + 7))
            bore.addLine(to: CGPoint(x: cx, y: cy)); bore.addLine(to: CGPoint(x: cx + 5, y: cy + 7)); bore.addLine(to: CGPoint(x: cx + 10, y: cy)); bore.addLine(to: CGPoint(x: cx + 26, y: cy))
            stroke(bore, 0.95, 1.6)
            // speed (left) and altitude (right) boxes with short scales
            for (side, value, unit, title) in [(-1.0, s.speed, s.speedUnit, "VEL"), (1.0, s.alt, s.altUnit, "ALT")] {
                let x = cx + side * W * 0.24
                var scale = Path()
                scale.move(to: CGPoint(x: x, y: cy - H * 0.17)); scale.addLine(to: CGPoint(x: x, y: cy + H * 0.17))
                for k in -6...6 { let y = cy + Double(k) * H * 0.028; scale.move(to: CGPoint(x: x, y: y)); scale.addLine(to: CGPoint(x: x - side * (k % 2 == 0 ? 12 : 6), y: y)) }
                stroke(scale, 0.6, 1.1)
                let bw = 74.0, bx = side < 0 ? x - bw - 16 : x + 16
                stroke(Path(CGRect(x: bx, y: cy - 13, width: bw, height: 26)), 0.9, 1.4)
                label(value, bx + bw / 2, cy, 15)
                label(unit, bx + bw / 2, cy + 22, 10, .center, 0.6)
                label(title, side < 0 ? x : x, cy - H * 0.17 - 14, 11)
            }
            // throttle and boost bar beside the speed scale
            let tx = cx - W * 0.24 - 108, th = H * 0.26, ty = cy + th / 2
            stroke(Path(CGRect(x: tx, y: ty - th, width: 10, height: th)), 0.6, 1.1)
            ctx.fill(Path(CGRect(x: tx + 2, y: ty - th * s.throttle, width: 6, height: th * s.throttle)), with: .color(s.afterburner > 0.05 ? Color.orange.opacity(0.85) : g.opacity(0.7)))
            label("THR", tx + 5, ty + 14, 10)
            let fx = tx - 36
            stroke(Path(CGRect(x: fx, y: ty - th, width: 10, height: th)), 0.6, 1.1)
            ctx.fill(Path(CGRect(x: fx + 2, y: ty - th * s.fuel, width: 6, height: th * s.fuel)), with: .color(s.fuel < 0.2 ? Color.orange.opacity(0.9) : Color.cyan.opacity(0.75)))
            label("FUEL", fx + 5, ty + 14, 10)
            label("\(Int((s.fuel * 100).rounded()))", fx + 5, ty - th - 12, 10)
            // heading strip
            let hy = H * 0.1, span = 60.0
            var strip = Path()
            for d in stride(from: -40, through: 400, by: 5) {
                var off = Double(d) - s.heading
                if off > 180 { off -= 360 } else if off < -180 { off += 360 }
                if abs(off) > span / 2 { continue }
                let x = cx + off / span * W * 0.42
                let big = d % 30 == 0
                strip.move(to: CGPoint(x: x, y: hy)); strip.addLine(to: CGPoint(x: x, y: hy + (big ? 12 : 6)))
                if big {
                    let n = ((d % 360) + 360) % 360
                    let txt = n == 0 ? "N" : n == 90 ? "E" : n == 180 ? "S" : n == 270 ? "W" : "\(n / 10)"
                    label(txt, x, hy - 10, 11, .center, 0.8)
                }
            }
            stroke(strip, 0.7, 1.2)
            stroke(Path(CGRect(x: cx - 26, y: hy + 18, width: 52, height: 20)), 0.9, 1.3)
            label(String(format: "%03.0f", s.heading), cx, hy + 28, 13)
            // system indicators along the bottom of the display
            let flags = [("VTOL", s.vtol), ("GEAR", s.gear), ("HOVER", s.hover), ("BOOST", s.afterburner > 0.05), ("PWR", s.power)]
            let fy = cy + H * 0.2, fw = 58.0, total = Double(flags.count) * (fw + 8)
            for (i, f) in flags.enumerated() {
                let x = cx - total / 2 + Double(i) * (fw + 8)
                let r = CGRect(x: x, y: fy, width: fw, height: 20)
                if f.1 { ctx.fill(Path(r), with: .color(g.opacity(0.18))) }
                stroke(Path(r), f.1 ? 0.95 : 0.35, 1.2)
                label(f.0, x + fw / 2, fy + 10, 10, .center, f.1 ? 1 : 0.4)
            }
            label(s.planet.uppercased(), cx, fy + 40, 11, .center, 0.6)
        }
        .allowsHitTesting(false)
    }
}

final class HUDModel: ObservableObject {
    @Published var title = true
    @Published var cockpit = false
    let holo = HoloModel()
    @Published var shipName = "Kestrel"
    @Published var shipRole = "STRIKE FIGHTER"
    @Published var shipIndex = 0
    @Published var shipCount = 2
    @Published var controlsOpen = false
    @Published var settingsOpen = false
    @Published var settingsSel = 0
    @Published var settingsRows: [(String, String)] = []
    @Published var showFPS = false
    @Published var planet = "Earth"
    @Published var altitude = ""
    @Published var speed = ""
    @Published var throttle = 0.0
    @Published var afterburner = 0.0
    @Published var hint = ""
    @Published var message = ""
    @Published var messageVisible = false
    @Published var fps = ""
    @Published var hidden = false
    @Published var marker: (x: Double, y: Double, text: String, edge: Bool)? = nil
    @Published var onFoot = false
    @Published var signals: [(x: Double, y: Double, text: String, edge: Bool)] = []
    @Published var depots: [(x: Double, y: Double, text: String, edge: Bool)] = []
    @Published var fuel = 1.0
    @Published var fuelWarn = ""
    @Published var worldMarks: [(x: Double, y: Double, text: String, edge: Bool)] = []
    @Published var logbook = false
    @Published var paused = false
    @Published var menuSel = 0
    @Published var menuShipName = ""
    @Published var menuShipRole = ""
    @Published var menuShipIndex = 0
    @Published var currentShipIndex = 0
    @Published var progress: [(String, Int, Int)] = []
    @Published var bannerTitle = ""
    @Published var bannerSub = ""
    @Published var bannerVisible = false
    private var bannerToken = 0
    func showBanner(_ t: String, _ s: String) {
        bannerToken += 1; let tk = bannerToken
        bannerTitle = t; bannerSub = s
        withAnimation(.easeOut(duration: 0.4)) { bannerVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in guard let self, self.bannerToken == tk else { return }; withAnimation(.easeIn(duration: 0.8)) { self.bannerVisible = false } }
    }
    private var token = 0
    func say(_ s: String) {
        token += 1; let t = token
        message = s
        withAnimation(.easeOut(duration: 0.25)) { messageVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard let self, self.token == t else { return }
            withAnimation(.easeIn(duration: 0.6)) { self.messageVisible = false }
        }
    }
}

/// one-line ship summary for the selectors
func shipBlurb(_ i: Int) -> String { [" · 50 m · agile · cabin (I)", " · 26 m · the fastest", " · 1.3 km · capital ship · walk the deck (I)", " · 32 m · fast and nimble"][max(0, min(i, 3))] }

struct HUDView: View {
    @ObservedObject var m: HUDModel
    let accent = Color(red: 0.62, green: 0.83, blue: 1.0)
    var body: some View {
        ZStack {
            if !m.title && !m.hidden && m.cockpit { CockpitHUD(h: m.holo) }
            if m.title { titleScreen } else if !m.hidden { flightHUD }
            if m.paused && !m.title && !m.settingsOpen { pauseMenu }
            if m.controlsOpen && !m.settingsOpen { controlsPanel }
            if m.settingsOpen { settingsPanel }
            Text(m.message).font(.system(size: 15, weight: .medium)).tracking(3).textCase(.uppercase)
                .foregroundColor(.white).shadow(color: .black.opacity(0.6), radius: 6)
                .opacity(m.messageVisible ? 1 : 0).frame(maxHeight: .infinity, alignment: .top).padding(.top, 180)
        }
    }
    // MARK: title screen: wordmark top left, the live ship in the middle, a ship picker and launch along the bottom
    struct ShipCard { let length: String; let stats: [(String, Double)]; let tags: [String] }
    static let cards: [ShipCard] = [
        ShipCard(length: "50 m", stats: [("SPEED", 0.55), ("AGILITY", 1.0), ("RANGE", 0.25), ("SIZE", 0.15)], tags: ["cabin", "fighter cockpit"]),
        ShipCard(length: "26 m", stats: [("SPEED", 1.0), ("AGILITY", 1.0), ("RANGE", 0.35), ("SIZE", 0.08)], tags: ["racer", "model by Jungle Jim · CC BY"]),
        ShipCard(length: "1.3 km", stats: [("SPEED", 0.65), ("AGILITY", 0.25), ("RANGE", 1.0), ("SIZE", 1.0)], tags: ["walkable decks", "bridge", "cargo bay + rover"]),
        ShipCard(length: "32 m", stats: [("SPEED", 0.7), ("AGILITY", 1.0), ("RANGE", 0.3), ("SIZE", 0.1)], tags: ["fighter cockpit", "model by Jungle Jim · CC BY"])]
    func keyCap(_ k: String) -> some View {
        Text(k).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9))
            .padding(.horizontal, 6).padding(.vertical, 2).background(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.35), lineWidth: 1))
    }
    var titleScreen: some View {
        let card = HUDView.cards[max(0, min(m.shipIndex, HUDView.cards.count - 1))]
        return ZStack {
            // soft vignettes top and bottom keep the text readable without a heavy panel
            VStack(spacing: 0) {
                LinearGradient(colors: [Color.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom).frame(height: 240)
                Spacer()
                LinearGradient(colors: [.clear, Color.black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 300)
            }
            // wordmark
            VStack(alignment: .leading, spacing: 8) {
                Text("WAYFARER").font(.system(size: 40, weight: .ultraLight)).tracking(16).foregroundColor(.white)
                Text("A quiet solar system, generated as you fly · land anywhere").font(.system(size: 13)).foregroundColor(.white.opacity(0.6))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 48).padding(.top, 40)
            // ship picker + launch, centred along the bottom
            VStack(spacing: 18) {
                HStack(alignment: .center, spacing: 28) {
                    Text("‹").font(.system(size: 40, weight: .ultraLight)).foregroundColor(.white.opacity(0.7))
                    VStack(spacing: 6) {
                        Text(m.shipName.uppercased()).font(.system(size: 34, weight: .semibold)).tracking(10).foregroundColor(.white)
                        Text("\(m.shipRole) · \(card.length)").font(.system(size: 12, weight: .medium)).tracking(3).foregroundColor(accent)
                        HStack(spacing: 6) { ForEach(0..<m.shipCount, id: \.self) { i in Capsule().fill(i == m.shipIndex ? accent : Color.white.opacity(0.25)).frame(width: i == m.shipIndex ? 22 : 8, height: 4) } }.padding(.top, 4)
                    }.frame(minWidth: 320)
                    Text("›").font(.system(size: 40, weight: .ultraLight)).foregroundColor(.white.opacity(0.7))
                }
                HStack(spacing: 26) {
                    ForEach(card.stats, id: \.0) { name, v in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name).font(.system(size: 9, weight: .semibold)).tracking(2).foregroundColor(.white.opacity(0.5))
                            ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.15)).frame(width: 90, height: 3); Capsule().fill(accent).frame(width: 90 * v, height: 3) }
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(card.tags, id: \.self) { t in Text(t.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundColor(.white.opacity(0.75)).padding(.horizontal, 8).padding(.vertical, 4).background(Capsule().fill(Color.white.opacity(0.08))) }
                }
                HStack(spacing: 12) {
                    Text("LAUNCH").font(.system(size: 14, weight: .semibold)).tracking(5)
                    Text("ENTER").font(.system(size: 9, weight: .bold)).tracking(1).padding(.horizontal, 6).padding(.vertical, 3).background(Color.black.opacity(0.15)).cornerRadius(5)
                }.foregroundColor(Color(red: 0.02, green: 0.07, blue: 0.12)).padding(.horizontal, 34).padding(.vertical, 13).background(accent).cornerRadius(30)
                .shadow(color: accent.opacity(0.5), radius: 18).padding(.top, 6)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 56)
            // small key hints in the corners
            HStack(spacing: 18) {
                HStack(spacing: 6) { keyCap("← →"); Text("ship") }
                HStack(spacing: 6) { keyCap("K"); Text("controls") }
                HStack(spacing: 6) { keyCap(","); Text("settings") }
                HStack(spacing: 6) { keyCap("⌘Q"); Text("quit") }
            }.font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 48).padding(.bottom, 26)
            Text("DRAG TO LOOK AROUND").font(.system(size: 10)).tracking(3).foregroundColor(.white.opacity(0.4))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(.trailing, 48).padding(.bottom, 28)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    // MARK: controls panel (K)
    static let controlGroups: [(String, [(String, String)])] = [
        ("FLIGHT", [("Mouse", "steer · click to capture"), ("W / S", "throttle"), ("A / D", "roll"), ("Arrows", "pitch and yaw"), ("Shift", "afterburner (full throttle)"),
                    ("Space", "brake"), ("1 – 3", "autopilot to a world"), ("G", "hover · W S height"), ("L", "land · take off")]),
        ("SHIP", [("V", "cockpit / chase view"), ("C", "camera: chase · orbit · pass-by"), ("I", "walk around inside"), ("E", "use · step outside · board"),
                  ("P", "power off / on (landed)"), ("F", "emergency fuel tanker"), ("O", "Atlas cargo bay"), ("Q", "scan for signals")]),
        ("ON FOOT", [("WASD", "walk"), ("Shift", "run"), ("Space", "jump · hold for jetpack"), ("X", "fly like a superhero"), ("R", "call your ship"), ("E", "drive the rover")]),
        ("GAME", [("Esc", "menu · change ship"), ("Tab", "logbook"), (",", "settings"), ("M", "sound"), ("N", "music"), ("H", "hide interface")])]
    var controlsPanel: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 18) {
                HStack { Text("CONTROLS").font(.system(size: 22, weight: .light)).tracking(10); Spacer(); keyCap("K"); Text("close").font(.system(size: 11)).foregroundColor(.white.opacity(0.5)) }
                HStack(alignment: .top, spacing: 36) {
                    ForEach(HUDView.controlGroups, id: \.0) { title, rows in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(title).font(.system(size: 10, weight: .semibold)).tracking(3).foregroundColor(accent).padding(.bottom, 4)
                            ForEach(rows, id: \.1) { k, d in
                                HStack(spacing: 10) { Text(k).font(.system(size: 11, weight: .semibold, design: .rounded)).frame(width: 52, alignment: .leading); Text(d).foregroundColor(.white.opacity(0.65)) }
                            }
                        }.font(.system(size: 12))
                    }
                }
            }.foregroundColor(.white).padding(32).background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.6))).frame(maxWidth: 1100)
        }
    }
    // MARK: settings panel
    var settingsPanel: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 8) {
                Text("SETTINGS").font(.system(size: 26, weight: .light)).tracking(12).padding(.bottom, 12)
                ForEach(Array(m.settingsRows.enumerated()), id: \.offset) { i, row in
                    HStack {
                        Text(row.0).font(.system(size: 14))
                        Spacer()
                        Text("‹").foregroundColor(.white.opacity(i == m.settingsSel ? 0.7 : 0.2))
                        Text(row.1).font(.system(size: 13, weight: .semibold)).foregroundColor(i == m.settingsSel ? accent : .white.opacity(0.8)).frame(minWidth: 200)
                        Text("›").foregroundColor(.white.opacity(i == m.settingsSel ? 0.7 : 0.2))
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(i == m.settingsSel ? accent.opacity(0.18) : Color.white.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(i == m.settingsSel ? accent.opacity(0.8) : .clear, lineWidth: 1.2))
                }
                HStack(spacing: 16) {
                    HStack(spacing: 6) { keyCap("↑ ↓"); Text("select") }; HStack(spacing: 6) { keyCap("← →"); Text("change") }; HStack(spacing: 6) { keyCap("ESC"); Text("done") }
                }.font(.system(size: 11)).foregroundColor(.white.opacity(0.55)).padding(.top, 10)
                Text("Saved automatically.").font(.system(size: 10)).foregroundColor(.white.opacity(0.35))
                Text("Models by Jungle Jim · CC BY 4.0 · Sketchfab — full list in About").font(.system(size: 10)).foregroundColor(.white.opacity(0.35))
            }.foregroundColor(.white).padding(32).frame(width: 560).background(RoundedRectangle(cornerRadius: 20).fill(Color.black.opacity(0.6)))
        }
    }
    var pauseMenu: some View {
        func row(_ i: Int, _ content: some View) -> some View {
            content.frame(width: 340, alignment: .leading).padding(.horizontal, 20).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(m.menuSel == i ? accent.opacity(0.22) : Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(m.menuSel == i ? accent : .clear, lineWidth: 1.5))
        }
        let same = m.menuShipIndex == m.currentShipIndex
        return ZStack {
            Color.black.opacity(0.55)
            VStack(alignment: .leading, spacing: 10) {
                Text("PAUSED").font(.system(size: 30, weight: .light)).tracking(14).foregroundColor(.white).padding(.bottom, 10)
                row(0, HStack { Text("RESUME").font(.system(size: 14, weight: .semibold)).tracking(4); Spacer(); Text("ESC").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)) })
                row(1, VStack(alignment: .leading, spacing: 4) {
                    Text("SHIP").font(.system(size: 10)).tracking(3).foregroundColor(.white.opacity(0.5))
                    HStack(spacing: 12) {
                        Text("‹").font(.system(size: 22, weight: .light)).foregroundColor(.white.opacity(0.6))
                        Text(m.menuShipName.uppercased()).font(.system(size: 18, weight: .semibold)).tracking(4)
                        Text("›").font(.system(size: 22, weight: .light)).foregroundColor(.white.opacity(0.6))
                        Spacer()
                        HStack(spacing: 5) { ForEach(0..<m.shipCount, id: \.self) { i in Capsule().fill(i == m.menuShipIndex ? accent : Color.white.opacity(0.25)).frame(width: i == m.menuShipIndex ? 14 : 6, height: 4) } }
                    }
                    Text(m.menuShipRole + shipBlurb(m.menuShipIndex)).font(.system(size: 11)).foregroundColor(accent)
                    Text(same ? "current ship · ← → to choose another" : "ENTER to switch here · ← → to choose").font(.system(size: 10)).foregroundColor(.white.opacity(same ? 0.45 : 0.85))
                })
                row(2, HStack { Text("SETTINGS").font(.system(size: 14, weight: .semibold)).tracking(4); Spacer(); Text("sound · mouse · graphics").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)) })
                row(3, HStack { Text("MAIN MENU").font(.system(size: 14, weight: .semibold)).tracking(4); Spacer(); Text("restart from orbit").font(.system(size: 10)).foregroundColor(.white.opacity(0.5)) })
                Text("↑ ↓ select · ENTER confirm · ESC resume").font(.system(size: 10)).tracking(2).foregroundColor(.white.opacity(0.45)).padding(.top, 8)
            }.foregroundColor(.white).padding(30).background(Color.black.opacity(0.55)).cornerRadius(20)
        }
    }
    var flightHUD: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.planet.uppercased()).font(.system(size: 24, weight: .semibold)).tracking(3)
                Text(m.onFoot ? "ON FOOT" : "\(m.shipName.uppercased()) · \(m.shipRole)").font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                (Text("altitude ").foregroundColor(.white.opacity(0.55)) + Text(m.altitude)).font(.system(size: 13).monospacedDigit())
                (Text("speed ").foregroundColor(.white.opacity(0.55)) + Text(m.speed)).font(.system(size: 13).monospacedDigit())
            }.foregroundColor(.white).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(24)
            VStack(alignment: .leading, spacing: 8) {
                if m.afterburner > 0.05 {
                    Text("AFTERBURNER").font(.system(size: 13, weight: .semibold)).tracking(4)
                        .foregroundColor(Color(red: 1, green: 0.7, blue: 0.3)).shadow(color: .orange, radius: 8).opacity(m.afterburner)
                }
                Text("THROTTLE").font(.system(size: 10)).tracking(2).foregroundColor(.white.opacity(0.55))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 180, height: 4)
                    Capsule().fill(m.afterburner > 0.05 ? AnyShapeStyle(LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(accent))
                        .frame(width: 180 * m.throttle, height: 4)
                }
                let fuelCol = m.fuel < 0.2 ? Color(red: 1, green: 0.45, blue: 0.3) : Color(red: 0.4, green: 0.95, blue: 0.95)
                HStack(spacing: 8) {
                    Text("FUEL").font(.system(size: 10)).tracking(2).foregroundColor(.white.opacity(0.55))
                    Text("\(Int((m.fuel * 100).rounded()))%").font(.system(size: 10).monospacedDigit()).foregroundColor(fuelCol)
                }.padding(.top, 4)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18)).frame(width: 180, height: 4)
                    Capsule().fill(fuelCol).frame(width: 180 * max(0, min(1, m.fuel)), height: 4)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(24)
            if !m.fuelWarn.isEmpty {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let on = Int(ctx.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
                    Text(m.fuelWarn).font(.system(size: 15, weight: .bold)).tracking(4)
                        .foregroundColor(Color(red: 1, green: 0.35, blue: 0.25)).opacity(m.fuel <= 0 ? (on ? 1 : 0.35) : 0.9)
                        .padding(.horizontal, 16).padding(.vertical, 8).background(Color.black.opacity(0.45)).cornerRadius(8)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).padding(.top, 110)
            }
            Text(m.hint).font(.system(size: 12)).tracking(2).textCase(.uppercase).foregroundColor(accent)
                .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 30)
            Text(m.showFPS ? m.fps : "").font(.system(size: 11).monospacedDigit()).foregroundColor(.white.opacity(0.6))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(24)
            Text("ESC  MENU · CHANGE SHIP").font(.system(size: 10, weight: .medium)).tracking(2).foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.black.opacity(0.3)).cornerRadius(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
            if !m.onFoot && !m.cockpit { Circle().stroke(Color.white.opacity(0.35), lineWidth: 1).frame(width: 18, height: 18) }
            GeometryReader { geo in
                ForEach(Array(m.depots.enumerated()), id: \.offset) { _, dp in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2).stroke(Color(red: 0.4, green: 0.95, blue: 0.95), lineWidth: 2)
                            .background(RoundedRectangle(cornerRadius: 2).fill(dp.edge ? Color(red: 0.4, green: 0.95, blue: 0.95) : .clear))
                            .frame(width: 10, height: 10).rotationEffect(.degrees(45)).shadow(color: .cyan, radius: 6)
                        Text(dp.text).font(.system(size: 10).monospacedDigit()).tracking(2).foregroundColor(Color(red: 0.5, green: 0.95, blue: 0.95)).shadow(color: .black.opacity(0.8), radius: 4)
                    }.position(x: dp.x * geo.size.width, y: dp.y * geo.size.height)
                }
                ForEach(Array(m.worldMarks.enumerated()), id: \.offset) { _, wm in
                    VStack(spacing: 4) {
                        Circle().stroke(Color.white.opacity(0.85), lineWidth: 1.5).frame(width: 14, height: 14).shadow(color: .white, radius: 4)
                        Text(wm.text).font(.system(size: 10).monospacedDigit()).tracking(2).foregroundColor(.white.opacity(wm.edge ? 0.6 : 0.9)).shadow(color: .black.opacity(0.8), radius: 4)
                    }.position(x: wm.x * geo.size.width, y: wm.y * geo.size.height)
                }
                ForEach(Array(m.signals.enumerated()), id: \.offset) { _, sg in
                    VStack(spacing: 4) {
                        Circle().stroke(Color(red: 1, green: 0.72, blue: 0.3), lineWidth: 2).background(Circle().fill(sg.edge ? Color(red: 1, green: 0.72, blue: 0.3) : .clear)).frame(width: 10, height: 10)
                            .shadow(color: .orange, radius: 6)
                        Text(sg.text).font(.system(size: 10).monospacedDigit()).tracking(2).foregroundColor(Color(red: 1, green: 0.78, blue: 0.4)).shadow(color: .black.opacity(0.8), radius: 4)
                    }.position(x: sg.x * geo.size.width, y: sg.y * geo.size.height)
                }
            }
            if m.bannerVisible {
                VStack(spacing: 8) {
                    Text("DISCOVERED").font(.system(size: 12, weight: .semibold)).tracking(8).foregroundColor(Color(red: 1, green: 0.78, blue: 0.4))
                    Text(m.bannerTitle).font(.system(size: 40, weight: .light)).tracking(4).foregroundColor(.white)
                    Text(m.bannerSub).font(.system(size: 13)).tracking(2).foregroundColor(.white.opacity(0.7))
                }.shadow(color: .black.opacity(0.7), radius: 12).transition(.opacity).frame(maxHeight: .infinity, alignment: .top).padding(.top, 110)
            }
            if m.logbook {
                VStack(alignment: .leading, spacing: 10) {
                    Text("LOGBOOK").font(.system(size: 12, weight: .semibold)).tracking(6).foregroundColor(accent)
                    ForEach(m.progress, id: \.0) { name, n, total in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(name).font(.system(size: 15)); Spacer(); Text("\(n) / \(total)").font(.system(size: 13).monospacedDigit()).foregroundColor(.white.opacity(0.7)) }
                            ZStack(alignment: .leading) { Capsule().fill(Color.white.opacity(0.15)).frame(height: 4); Capsule().fill(accent).frame(width: 240 * Double(n) / Double(max(total, 1)), height: 4) }.frame(width: 240)
                        }
                    }
                    Text("Q scan · land near a signal · walk up to it").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }.foregroundColor(.white).padding(22).frame(width: 290).background(Color.black.opacity(0.6)).cornerRadius(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing).padding(.trailing, 24)
            }
            if let mk = m.marker {
                GeometryReader { geo in
                    VStack(spacing: 5) {
                        Rectangle().stroke(accent, lineWidth: 2).background(mk.edge ? accent : Color.clear).frame(width: 11, height: 11).rotationEffect(.degrees(45))
                            .shadow(color: accent, radius: 6)
                        Text(mk.text).font(.system(size: 11).monospacedDigit()).tracking(2).foregroundColor(accent).shadow(color: .black.opacity(0.8), radius: 4)
                    }.position(x: mk.x * geo.size.width, y: mk.y * geo.size.height)
                }
            }
        }
    }
}

final class PassthroughHosting<V: View>: NSHostingView<V> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - game view (input)

final class GameView: MTKView {
    var game: Game!
    var hud: HUDModel!
    var audio: Audio?
    private var captured = false
    private var downAt = NSPoint.zero
    private var dragged = 0.0
    override var acceptsFirstResponder: Bool { true }

    /// macOS "scaled" display modes draw into a canvas larger than the panel (a 4K monitor set to look like
    /// 3008×1692 uses a 6016×3384 canvas, then shrinks it). Draw at most a real 4K panel's worth of pixels
    /// and let the system scale; the HUD is a separate layer, so text stays pin-sharp.
    static let maxOutputPixels = 3840.0 * 2160.0
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); fitDrawable() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); fitDrawable() }
    func fitDrawable() {
        autoResizeDrawable = false
        let backing = window?.backingScaleFactor ?? 2, pts = bounds.size
        let s = min(backing, sqrt(GameView.maxOutputPixels / max(1, pts.width * pts.height)))
        drawableSize = CGSize(width: max(64, floor(pts.width * s)), height: max(64, floor(pts.height * s)))
    }

    /// settings and the controls panel sit on top of everything
    func openSettings() { hud.settingsOpen = true; hud.settingsSel = 0; refreshSettings(); release() }
    func refreshSettings() { hud.settingsRows = Settings.shared.rows(fullscreen: window?.styleMask.contains(.fullScreen) ?? false) }
    func applySettings() {
        let st = Settings.shared
        audio?.volume = Float(st.volume); audio?.musicVolume = Float(st.music)
        hud.showFPS = st.showFPS
        loop?.fixedScale = st.fixedScale
    }
    weak var loop: Loop?
    override func keyDown(with e: NSEvent) {
        if hud.settingsOpen {
            if e.isARepeat && ![Key.left, Key.right].contains(e.keyCode) { return }
            switch e.keyCode {
            case Key.esc, 43: hud.settingsOpen = false
            case Key.up, Key.w: hud.settingsSel = (hud.settingsSel + Settings.rowCount - 1) % Settings.rowCount
            case Key.down, Key.s: hud.settingsSel = (hud.settingsSel + 1) % Settings.rowCount
            case Key.left, Key.right, Key.a, Key.d, Key.enter, Key.space:
                let dir = (e.keyCode == Key.left || e.keyCode == Key.a) ? -1 : 1
                if Settings.shared.adjust(hud.settingsSel, dir) { window?.toggleFullScreen(nil) }
                applySettings(); audio?.tick(5)
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.refreshSettings() }
            refreshSettings(); return
        }
        if hud.controlsOpen && (e.keyCode == 40 || e.keyCode == Key.esc) { hud.controlsOpen = false; return }
        if e.keyCode == 43 && !e.isARepeat && !game.paused { openSettings(); return }                 // ,
        if e.keyCode == 40 && !e.isARepeat && !game.paused { hud.controlsOpen.toggle(); return }       // K
        if game.paused && e.keyCode == Key.enter && game.menuSel == 2 { openSettings(); return }
        if game.paused {
            if !e.isARepeat { game.menuKey(e.keyCode); syncMenu() }
            return
        }
        if e.keyCode == Key.esc { release(); if game.mode != .title { game.openMenu(); syncMenu() }; return }
        if e.keyCode == Key.h && !e.isARepeat { hud.hidden.toggle() }
        if e.keyCode == Key.tab && !e.isARepeat { hud.logbook.toggle(); hud.progress = game.progressText(); return }
        if e.keyCode == Key.m && !e.isARepeat { if let a = audio { a.muted.toggle(); hud.say(a.muted ? "sound off" : "sound on") } }
        if e.keyCode == 45 && !e.isARepeat { if let a = audio { a.musicOn.toggle(); hud.say(a.musicOn ? "music on" : "music off") } }
        game.keys.insert(e.keyCode)
        if !e.isARepeat { game.keyDown(e.keyCode) }
    }
    override func keyUp(with e: NSEvent) { game.keys.remove(e.keyCode) }
    /// push the menu state to the HUD straight away (the HUD otherwise refreshes a few times a second)
    func syncMenu() {
        hud.paused = game.paused; hud.menuSel = game.menuSel
        let s = game.ships[game.menuShip]
        hud.menuShipName = s.name; hud.menuShipRole = s.role; hud.menuShipIndex = game.menuShip; hud.currentShipIndex = game.shipIndex
        hud.title = game.mode == .title
        if game.paused { release() }
    }
    override func flagsChanged(with e: NSEvent) {
        let now = e.modifierFlags.contains(.shift)
        if now && !game.shift { game.shiftPressed() }
        game.shift = now
    }
    override func mouseDown(with e: NSEvent) {
        downAt = e.locationInWindow; dragged = 0
        if game.paused { return }
        game.dragging = true
        if game.mode != .title && (game.mode != .landed || game.aboard.on) && !captured { capture() }
    }
    override func mouseUp(with e: NSEvent) {
        game.dragging = false
        if game.paused { return }
        if game.mode == .title && dragged < 4 { game.launch() }
    }
    override func mouseDragged(with e: NSEvent) { dragged += abs(e.deltaX) + abs(e.deltaY); game.mouse += mouseDelta(e) }
    func mouseDelta(_ e: NSEvent) -> SIMD2<Double> { let st = Settings.shared; return SIMD2(Double(e.deltaX), Double(e.deltaY) * (st.invertY ? -1 : 1)) * st.mouseSens }
    override func scrollWheel(with e: NSEvent) { game.zoomCamera(Double(e.scrollingDeltaY) * (e.hasPreciseScrollingDeltas ? 0.15 : 1)) }
    override func mouseMoved(with e: NSEvent) { if captured && !game.paused && !hud.settingsOpen { game.mouse += mouseDelta(e) } }
    func capture() { CGAssociateMouseAndMouseCursorPosition(0); NSCursor.hide(); captured = true }
    func release() { if captured { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide(); captured = false } }
}

// MARK: - frame loop

final class Loop: NSObject, MTKViewDelegate {
    var fixedScale: Double? = nil      // graphics quality: nil adapts the resolution to hold the frame rate
    let game: Game, renderer: Renderer, terrain: Terrain, hud: HUDModel
    private var last = CACurrentMediaTime(), hudT = 0.0, fpsAcc = 0.0, fpsN = 0, slow = 0, fast = 0
    init(game: Game, renderer: Renderer, terrain: Terrain, hud: HUDModel) { self.game = game; self.renderer = renderer; self.terrain = terrain; self.hud = hud }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        let now = CACurrentMediaTime(), dt = min(0.05, now - last); last = now
        game.update(dt)
        terrain.update(camPos: game.camPos)
        guard let drawable = view.currentDrawable, let cb = renderer.queue.makeCommandBuffer() else { return }
        renderer.encode(cb, output: drawable.texture)
        cb.present(drawable); cb.commit()

        fpsAcc += dt; fpsN += 1; hudT += dt
        let inCockpit = game.cockpitView && game.mode != .walk && game.mode != .title && !game.aboard.on
        if inCockpit != hud.cockpit { hud.cockpit = inCockpit }
        if inCockpit { hud.holo.s = fillHolo(game) }
        if hudT > 0.12 {
            let fps = Double(fpsN) / fpsAcc
            // hold a smooth frame rate by adjusting the internal resolution
            if let fs = fixedScale { renderer.renderScale = fs }
            else if fps < 55 { slow += 1; fast = 0; if slow > 6 { renderer.renderScale = max(0.45, renderer.renderScale * 0.9); slow = 0 } }
            else if fps > 75 && fixedScale == nil { fast += 1; slow = 0; if fast > 30 && renderer.renderScale < 1 { renderer.renderScale = min(1, renderer.renderScale * 1.05); fast = 0 } }
            hudT = 0; fpsAcc = 0; fpsN = 0
            hud.title = game.mode == .title
            hud.shipName = game.ship.name; hud.shipRole = game.ship.role; hud.shipIndex = game.shipIndex; hud.shipCount = game.ships.count
            hud.planet = game.near.name
            hud.onFoot = game.mode == .walk
            hud.altitude = game.mode == .walk ? "on foot" : fmtDist(max(0, game.alt))
            hud.speed = fmtDist(game.v) + "/s" + (game.airDensity > 0.01 && game.mode == .fly ? String(format: "  ·  Mach %.1f", game.mach) : "")
            hud.throttle = game.throttle; hud.afterburner = game.abLevel
            let fw: String
            if game.tanker.active { fw = game.tanker.phase == 0 ? "EMERGENCY TANKER INBOUND" : game.tanker.phase == 1 ? "REFUELLING · \(Int(game.fuel * 100))%" : "" }
            else if game.mode == .title || game.dockedAt != nil { fw = "" }
            else if game.fuel <= 0 { fw = "OUT OF FUEL · ENGINES DEAD · PRESS F FOR AN EMERGENCY TANKER" }
            else if game.fuel < 0.1 { fw = "FUEL CRITICAL · \(Int(game.fuel * 100))% · PRESS F FOR A TANKER" }
            else if game.fuel < 0.2 { fw = "LOW FUEL · \(Int(game.fuel * 100))% · F FOR A TANKER" }
            else { fw = "" }
            if fw != hud.fuelWarn { hud.fuelWarn = fw }
            let mem = memoryStats(renderer.device)
            hud.fps = "\(Int(fps.rounded())) fps · render \(renderer.targetW)×\(renderer.targetH) → screen \(renderer.outputW)×\(renderer.outputH) · \(terrain.tiles) tiles · RAM \(Int(mem.ramMB)) MB · GPU \(Int(mem.gpuMB)) MB"
            switch game.mode {
            case _ where game.driving:
                hud.hint = "ROVER · W S drive · A D steer · shift boost · space brake · mouse looks round · E get out" + (game.aboard.on && game.onCargoLift ? " · E on the lift: raise / lower" : "")
            case _ where game.aboard.on && game.nearRover: hud.hint = "E · drive the rover"
            case _ where game.aboard.on && game.onCargoLift: hud.hint = game.cargoOpen ? "CARGO LIFT · walk off onto the ground · wait or E to go up" : "CARGO LIFT · wait a moment or E to go down" + (game.mode == .landed ? "" : " (land first)")
            case _ where game.mode == .walk && game.nearRover: hud.hint = "E · drive the rover"
            case _ where game.aboard.on:
                hud.hint = game.aboard.lift != nil ? "" : game.nearHelm.map { "E · " + ($0.seat ? "sit down and fly" : "take the controls from \($0.word)") } ?? (game.nearLift.map { $0.to.y > $0.from.y ? "E · lift up to the bridge" : "E · lift down to the lounge" } ?? "ABOARD THE \(game.ship.name.uppercased()) · WASD walk · shift run · space jump · E use · I back to the controls")
            case .landed: hud.hint = game.ship.cargo != nil && game.power ? "landed · X fly out · I go aboard (cargo bay: lift pad by the lounge) · O cargo doors · E step outside · W or L take off" : game.dockedAt != nil && game.fuel < 0.999 ? "refuelling · \(Int(game.fuel * 100))%" : game.power ? "landed on \(game.near.name) · X fly out · E step outside · P power down · W or L take off · G hover" : "ship powered down · P to power up · E step outside"
            case .walk: hud.hint = game.w.flying ? "FLYING · W forward · shift boost · space climb · X drop" : game.sh.active ? "your ship is on its way · \(fmtDist(simd_distance(game.w.pos, game.pos))) out" : game.nearShip ? "press E to board the \(game.ship.name)" : "WASD walk · shift run · space jump · X FLY · R call your ship"
            case .landing: hud.hint = "touching down…"
            case .hover: hud.hint = "E jump out · HOVER · W S height · ↑ ↓ forward/back · A D strafe · ← → turn · mouse look · L land · G fly · V cockpit" + (game.ship.deck != nil ? " · I walk the deck" : "")
            case .fly: hud.hint = game.alt < 3 ? "L to land · G to hover · V cockpit · C camera" + (game.ship.deck != nil ? " · I walk the deck" : "") : (!game.hintsSeen.contains("scanned") && game.time - game.launchTime > 4 ? "press Q to scan for signals" : "")
            default: hud.hint = ""
            }
            if game.mode == .walk, let P = game.w.world {
                let up = simd_normalize(game.pos - P.pos)
                var pr = game.project(game.pos + up * game.size * 0.35, aspect: Double(renderer.lastAspect))
                let off = pr.behind || pr.x < 0.04 || pr.x > 0.96 || pr.y < 0.07 || pr.y > 0.93
                if off {   // pin to the screen edge, pointing toward the ship
                    var dx = pr.x - 0.5, dy = pr.y - 0.5
                    let m = max(abs(dx) / 0.46, abs(dy) / 0.43, 1e-6); dx /= m; dy /= m
                    pr.x = 0.5 + dx; pr.y = 0.5 + dy
                }
                hud.marker = (pr.x, pr.y, game.sh.active ? "INBOUND" : fmtDist(simd_distance(game.w.pos, game.pos)), off)
            } else { hud.marker = nil }
            // signal markers for scanned, undiscovered sites
            let origin = game.mode == .walk ? game.w.pos : game.pos
            var sigs: [(x: Double, y: Double, text: String, edge: Bool)] = []
            if game.mode != .title {
                for s in game.sites.filter({ $0.scanned && !$0.discovered }).sorted(by: { simd_distance(origin, $0.pos) < simd_distance(origin, $1.pos) }).prefix(6) {
                    let d = simd_distance(origin, s.pos)
                    var pr = game.project(s.pos + s.dir * 0.03, aspect: Double(renderer.lastAspect))
                    let off = pr.behind || pr.x < 0.04 || pr.x > 0.96 || pr.y < 0.07 || pr.y > 0.93
                    if off { var dx = pr.x - 0.5, dy = pr.y - 0.5; let mm = max(abs(dx) / 0.46, abs(dy) / 0.43, 1e-6); dx /= mm; dy /= mm; pr.x = 0.5 + dx; pr.y = 0.5 + dy }
                    sigs.append((pr.x, pr.y, (d < 3 ? s.kind.title.uppercased() + " · " : "SIGNAL · ") + fmtDist(d), off))
                }
            }
            hud.signals = sigs
            // fuel depots: nearest on this world; pinned to the screen edge when fuel runs low
            hud.fuel = game.fuel
            var dps: [(x: Double, y: Double, text: String, edge: Bool)] = []
            if game.mode != .title {
                let low = game.fuel < 0.3
                let here = game.depots.filter { $0.world === game.near }.sorted { simd_distance(origin, $0.pos) < simd_distance(origin, $1.pos) }
                for dp in here.prefix(low ? 3 : 4) {
                    let d = simd_distance(origin, dp.pos)
                    if !low && d > 400 { continue }
                    if game.mode == .walk && d > 8 && !low { continue }
                    var pr = game.project(dp.pos + dp.dir * 0.08, aspect: Double(renderer.lastAspect))
                    let off = pr.behind || pr.x < 0.04 || pr.x > 0.96 || pr.y < 0.07 || pr.y > 0.93
                    if off && !low { continue }
                    if off { var dx = pr.x - 0.5, dy = pr.y - 0.5; let mm = max(abs(dx) / 0.46, abs(dy) / 0.43, 1e-6); dx /= mm; dy /= mm; pr.x = 0.5 + dx; pr.y = 0.5 + dy }
                    dps.append((pr.x, pr.y, "FUEL · " + (d < 5 ? dp.name.uppercased() + " · " : "") + fmtDist(d), off))
                }
            }
            hud.depots = dps
            // the other worlds: a label with the distance and, when you're heading there, the time to arrive
            var wms: [(x: Double, y: Double, text: String, edge: Bool)] = []
            if game.mode == .fly || game.mode == .hover || game.mode == .takeoff {
                for (i, P) in game.worlds.enumerated() where P !== game.near || simd_distance(origin, P.pos) > P.R * 4 {
                    let d = simd_distance(origin, P.pos) - P.R
                    var pr = game.project(P.pos, aspect: Double(renderer.lastAspect))
                    let off = pr.behind || pr.x < 0.04 || pr.x > 0.96 || pr.y < 0.07 || pr.y > 0.93
                    if off { var dx = pr.x - 0.5, dy = pr.y - 0.5; if pr.behind { dx = -dx; dy = -dy }; let mm = max(abs(dx) / 0.46, abs(dy) / 0.43, 1e-6); dx /= mm; dy /= mm; pr.x = 0.5 + dx; pr.y = 0.5 + dy }
                    let closing = game.mode == .fly ? simd_dot(game.forward, simd_normalize(P.pos - game.pos)) * game.v : 0
                    var t = "\(i + 1) · \(P.name.uppercased()) · " + fmtDist(d)
                    if closing > 1 && d > 2000 { let s = d / closing; t += s < 120 ? String(format: " · %.0f s", s) : String(format: " · %.0f min", s / 60) }
                    wms.append((pr.x, pr.y, t, off))
                }
            }
            hud.worldMarks = wms
            if hud.logbook { hud.progress = game.progressText() }
        }
    }
}

func fmtDist(_ km: Double) -> String {
    km < 1 ? "\(Int((km * 1000).rounded())) m" : km < 1000 ? String(format: km < 10 ? "%.2f km" : "%.1f km", km) : String(format: "%.1fk km", km / 1000)
}

// MARK: - headless snapshot (used to check visuals without a window)

func runSnapshot(args: [String]) {
    UserDefaults.standard.removeObject(forKey: "wayfarer.discovered.snapshot")
    func arg(_ k: String) -> String? { if let i = args.firstIndex(of: k), i + 1 < args.count { return args[i + 1] }; return nil }
    let out = arg("--snapshot")!, scenario = arg("--scenario") ?? "title"
    let sz = (arg("--size") ?? "1600x1000").split(separator: "x").map { Int($0)! }
    let device = MTLCreateSystemDefaultDevice()!
    let worlds = makeWorlds()
    let terrain = Terrain(device: device, worlds: worlds)
    let game = Game(worlds: worlds, ships: allShips(device: device))
    game.shipIndex = Int(ProcessInfo.processInfo.environment["WAYFARER_SHIP"] ?? "0") ?? 0
    let renderer = try! Renderer(device: device, game: game, terrain: terrain)
    renderer.maxPixels = 1e9
    setupScenario(game, scenario)
    let env = ProcessInfo.processInfo.environment
    if env["COCKPIT"] != nil { game.cockpitView = true }
    if let y = env["LOOKYAW"] { game.lookYaw = Double(y)! }
    if let p = env["LOOKPITCH"] { game.lookPitch = Double(p)! }
    if let c = env["CAM"] { game.camMode = Int(c)! }
    if let v = env["SHOWCASE"]?.split(separator: ",").compactMap({ Double($0) }), v.count == 3 { game.showcaseYaw = v[0]; game.showcasePitch = v[1]; game.showcaseZoom = v[2] }
    if env["TANKER"] != nil { game.fuel = 0.25; game.callTanker(); for _ in 0..<(23 * 60) { game.update(1.0 / 60) } }
    if let y = env["EXTYAW"] { game.extYaw = Double(y)! }
    if let p = env["EXTPITCH"] { game.extPitch = Double(p)! }
    if let z = env["EXTZOOM"] { game.extZoom = Double(z)! }
    if env["ABOARD"] != nil {   // dev: walk the deck; ABOARD="x,z,yaw,pitch" in metres / radians
        game.goAboard()
        let v = env["ABOARD"]!.split(separator: ",").compactMap { Double($0) }
        if v.count >= 3 { game.aboard.p.x = v[0]; game.aboard.p.z = v[1]; game.aboard.yaw = v[2] }
        if v.count >= 4 { game.aboard.pitch = v[3] }
        if v.count >= 5 { game.aboard.p.y = v[4] }
        else if let dk = game.ship.deck { game.aboard.p.y = dk.floor(v[0], v[1], near: game.aboard.p.y) ?? dk.anyFloor(v[0], v[1]) ?? game.aboard.p.y }
    }
    let dt = 1.0 / 60
    let frames = Int(arg("--frames") ?? "900")!
    for i in 0..<frames {
        game.update(dt); terrain.update(camPos: game.camPos)
        if i > 30 && terrain.idle && terrain.pending == 0 && arg("--frames") == nil { break }
        if !terrain.idle { usleep(4000) }
    }
    if let h = env["HEAT"].flatMap(Double.init) { game.heat = h }
    if env["BOOM"] != nil { game.vapor = 1; game.shockT = 0.35; game.kick = 0.6 }
    for _ in 0..<20 { game.update(dt); terrain.update(camPos: game.camPos) }
    if let cc = env["CHARCAM"]?.split(separator: ",").compactMap({ Double($0) }), cc.count >= 2, game.mode == .walk, let P = game.w.world {
        // dev: look at the character from the side (yaw around it, distance in metres)
        let up = simd_normalize(game.w.pos - P.pos), f = game.w.fwd, r = simd_normalize(simd_cross(f, up))
        let dir = f * cos(cc[0]) + r * sin(cc[0])
        game.camPos = game.w.pos + dir * cc[1] * 0.001 + up * 0.0011
        game.camQ = lookRotation(forward: simd_normalize(game.w.pos + up * 0.001 - game.camPos), up: up)
        game.fov = 50
        for _ in 0..<6 { terrain.update(camPos: game.camPos); usleep(3000) }
    }
    if let rt = env["LIFTRIDE"].flatMap(Double.init), let d = game.ship.deck {   // dev: ride lift 0 from the lounge for rt seconds
        game.aboard.p = d.lifts[0].a + D3(0, 0, -0.3); game.aboard.yaw = 0; game.aboard.pitch = Double(env["LIFTPITCH"] ?? "0") ?? 0
        game.aboardUse()
        let n = Int(rt * 60); for _ in 0..<n { game.update(dt) }
        game.aboard.yaw = Double(env["LIFTYAW"] ?? "0") ?? 0
        game.update(dt)
        for _ in 0..<10 { terrain.update(camPos: game.camPos); usleep(3000) }
    }
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: renderer.outputFormat, width: sz[0], height: sz[1], mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]; d.storageMode = .shared
    let tex = device.makeTexture(descriptor: d)!
    renderer.settleRocks()
    let cb = renderer.queue.makeCommandBuffer()!
    renderer.encode(cb, output: tex); cb.commit(); cb.waitUntilCompleted()
    var gpuMs: [Double] = []
    for _ in 0..<8 {   // time a few extra frames on the GPU
        let c2 = renderer.queue.makeCommandBuffer()!
        renderer.encode(c2, output: tex); c2.commit(); c2.waitUntilCompleted()
        gpuMs.append((c2.gpuEndTime - c2.gpuStartTime) * 1000)
    }
    print(String(format: "gpu %.2f ms/frame (median of 8)", gpuMs.sorted()[4]))
    var px = [UInt8](repeating: 0, count: sz[0] * sz[1] * 4)
    tex.getBytes(&px, bytesPerRow: sz[0] * 4, from: MTLRegionMake2D(0, 0, sz[0], sz[1]), mipmapLevel: 0)
    for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) } // BGRA -> RGBA
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &px, width: sz[0], height: sz[1], bitsPerComponent: 8, bytesPerRow: sz[0] * 4, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    if game.cockpitView && game.mode != .walk && game.mode != .title && !game.aboard.on {   // draw the cockpit HUD over the frame
        let holo = HoloModel(); holo.s = fillHolo(game)
        MainActor.assumeIsolated {
            let r = ImageRenderer(content: CockpitHUD(h: holo).frame(width: CGFloat(sz[0]) / 2, height: CGFloat(sz[1]) / 2))
            r.scale = 2
            if let hi = r.cgImage { ctx.draw(hi, in: CGRect(x: 0, y: 0, width: sz[0], height: sz[1])) }
        }
    }
    if let which = ProcessInfo.processInfo.environment["TITLEUI"] {   // dev: draw the title screen (or a panel) over the frame
        MainActor.assumeIsolated {
            let hm = HUDModel(); hm.title = true; hm.shipCount = game.ships.count; hm.shipIndex = game.shipIndex
            hm.shipName = game.ship.name; hm.shipRole = game.ship.role
            if which == "controls" { hm.controlsOpen = true }
            if which == "settings" { hm.settingsOpen = true; hm.settingsSel = 2; hm.settingsRows = Settings.shared.rows(fullscreen: false) }
            let r = ImageRenderer(content: HUDView(m: hm).frame(width: CGFloat(sz[0]) / 2, height: CGFloat(sz[1]) / 2))
            r.scale = 2
            if let hi = r.cgImage { ctx.draw(hi, in: CGRect(x: 0, y: 0, width: sz[0], height: sz[1])) }
        }
    }
    if ProcessInfo.processInfo.environment["WAYFARER_MENU"] != nil {   // dev: draw the pause menu over the frame
        MainActor.assumeIsolated {
            let hm = HUDModel(); game.openMenu(); game.menuShip = 2; game.menuSel = 1
            hm.paused = true; hm.menuSel = 1; hm.shipCount = game.ships.count; hm.menuShipIndex = 2; hm.currentShipIndex = game.shipIndex
            hm.menuShipName = game.ships[2].name; hm.menuShipRole = game.ships[2].role; hm.title = false; hm.hidden = true
            let r = ImageRenderer(content: HUDView(m: hm).frame(width: CGFloat(sz[0]) / 2, height: CGFloat(sz[1]) / 2))
            r.scale = 2
            if let hi = r.cgImage { ctx.draw(hi, in: CGRect(x: 0, y: 0, width: sz[0], height: sz[1])) }
        }
    }
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil); CGImageDestinationFinalize(dest)
    print("discovered: \(game.sites.filter { $0.discovered }.map { $0.id })")
    let mem = memoryStats(device)
    print(String(format: "memory: RAM %.0f MB · GPU %.0f MB", mem.ramMB, mem.gpuMB))
    print("wrote \(out) · tiles \(terrain.tiles) deepest \(terrain.deepest) · mode \(game.mode) alt \(String(format: "%.3f", game.alt))")
}

/// deterministic test placements
func setupScenario(_ g: Game, _ name: String) {
    func spot(_ w: World, lit: Double, minH: Double, maxH: Double, seed: UInt32) -> D3 {
        let r = Mulberry(seed), sun = simd_normalize(g.sunPos - w.pos)
        for _ in 0..<60000 {
            let d = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1))
            let h = w.height(d.x, d.y, d.z, 10)
            if h > minH && h < maxH && abs(simd_dot(d, sun) - lit) < 0.05 && abs(d.y) < 0.6 { return d }
        }
        return sun
    }
    func landAt(_ wi: Int, lit: Double, minH: Double = 0.5, maxH: Double = 3, yaw: Double = 2.4, pitch: Double = 0.2, seed: UInt32 = 5) {
        let w = g.worlds[wi], d = spot(w, lit: lit, minH: minH, maxH: maxH, seed: seed)
        g.mode = .landed; g.landedOn = w; g.gear = 1; g.gearTarget = 1; g.landedK = 1
        g.pos = w.pos + d * (w.groundRadius(d) + g.gearH)
        let t = simd_normalize(simd_cross(d, D3(0, 1, 0)))
        g.q = lookRotation(forward: t, up: d)
        g.orbitYaw = yaw; g.orbitPitch = pitch
        g.camPos = g.pos + g.q.act(D3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * 0.14)
    }
    switch name {
    case "orbit": g.launch(); g.throttle = 0.4
    case "afterburner": g.launch(); g.throttle = 1; g.ab = true; g.abLevel = 1
    case "ground": landAt(0, lit: 0.6, minH: 1.5, maxH: 4, seed: 11)
    case "closeup", "closeup-ruber", "closeup-verdance", "closeup-rock":
        let wi = name == "closeup-ruber" ? 1 : name == "closeup-verdance" ? 2 : 0
        landAt(wi, lit: 0.55, minH: name == "closeup-rock" ? 6 : (wi == 1 ? -100 : 1.5), maxH: name == "closeup-rock" ? 12 : (wi == 1 ? 100 : 4), seed: 11)
        // stand 2 m above the ground about 25 m from the ship, looking across the terrain
        let w = g.worlds[wi], up = simd_normalize(g.pos - w.pos)
        let side = simd_normalize(simd_cross(up, D3(0, 1, 0)))
        var cp = g.pos + side * 0.08; let cu = simd_normalize(cp - w.pos); cp = w.pos + cu * (w.groundRadius(cu) + 0.002)
        let look = simd_normalize(side * 1.0 + simd_cross(up, side) * 0.6 - up * 0.12)
        g.overrideCam = (cp, lookRotation(forward: look, up: cu))
    case "sunset": landAt(0, lit: 0.06, yaw: 0.4, pitch: 0.12, seed: 9)
    case "ruber": landAt(1, lit: 0.5, minH: -100, maxH: 100)
    case "site-monolith", "site-wreck", "site-crystal", "discover":
        let kind: SiteKind = name == "site-wreck" ? .wreck : name == "site-crystal" ? .crystal : .monolith
        let si = g.sites.firstIndex { $0.kind == kind }!
        let st = g.sites[si], P = st.world
        let side = simd_normalize(simd_cross(st.dir, D3(0, 1, 0)))
        let shipDir = simd_normalize(st.pos + side * 0.25 - P.pos)
        g.mode = .landed; g.landedOn = P; g.gear = 1; g.gearTarget = 1; g.landedK = 1
        g.pos = P.pos + shipDir * (P.groundRadius(shipDir) + g.gearH)
        g.q = lookRotation(forward: simd_normalize(simd_cross(shipDir, D3(0, 1, 0))), up: shipDir)
        g.camPos = g.pos; g.enterWalk()
        let wd = simd_normalize(st.pos + side * (name == "discover" ? 0.02 : 0.09) - P.pos)
        g.w.pos = P.pos + wd * P.groundRadius(wd); g.w.camPos = g.w.pos
        var f = st.pos - g.w.pos; f -= wd * simd_dot(f, wd); g.w.camFwd = simd_normalize(f); g.w.fwd = g.w.camFwd; g.w.pitch = 0.1
        g.sites[si].scanned = true
        if name == "discover" { g.keys = [Key.w] }
    case "beacons":
        let P = g.worlds[0]
        for i in g.sites.indices where g.sites[i].world === P { g.sites[i].scanned = true }
        let st = g.sites.first { $0.world === P }!
        let d = simd_normalize(st.dir + simd_normalize(simd_cross(st.dir, D3(0, 1, 0))) * 0.06)
        g.mode = .fly; g.pos = P.pos + d * (P.groundRadius(d) + 25)
        g.q = lookRotation(forward: simd_normalize(st.pos - g.pos + d * -2), up: d); g.camQ = g.q; g.snapCamera(); g.throttle = 0
    case "walk", "run-ruber", "walk-verdance", "jetpack", "recall", "stand", "run", "fly", "fly-boost", "hover-hero", "hero-land":
        let wi = name == "run-ruber" ? 1 : name == "walk-verdance" ? 2 : 0
        landAt(wi, lit: 0.5, minH: wi == 1 ? -100 : 1.5, maxH: wi == 1 ? 100 : 4, seed: 11)
        g.camPos = g.pos; g.enterWalk()
        g.w.camFwd = simd_quatd(angle: 2.2, axis: simd_normalize(g.w.pos - g.worlds[wi].pos)).act(g.w.camFwd)
        if name == "jetpack" { g.keys = [Key.space, Key.w] } else if name != "recall" && name != "stand" { g.keys = [Key.w] }
        if name == "run-ruber" || name == "run" { g.shift = true }
        if ["fly", "fly-boost", "hover-hero", "hero-land"].contains(name) {
            g.keys = []; g.keyDown(Key.x)
            g.keys = name == "hover-hero" ? [] : [Key.w]; g.shift = name == "fly-boost"; g.w.pitch = name == "hero-land" ? 1.1 : -0.25
            for _ in 0..<(name == "hero-land" ? 120 : 240) { g.update(1.0 / 60) }
            if name == "hero-land" { g.keys = [Key.w]; g.w.pitch = 1.4; var n = 0; while !g.w.onGround && n < 2000 { g.update(1.0 / 60); n += 1 }; g.keys = []; for _ in 0..<20 { g.update(1.0 / 60) } }
        }
        if name == "recall" {
            let P = g.worlds[wi], d = simd_normalize(g.w.pos + g.w.camFwd * 0.6 - P.pos)
            g.w.pos = P.pos + d * P.groundRadius(d); g.w.camPos = g.w.pos
            g.summonShip()
        }
    case "away":   // on foot, AWAY metres from the ship, looking back at it
        landAt(0, lit: 0.6, minH: 1.5, maxH: 4, seed: 11)
        g.camPos = g.pos; g.enterWalk()
        let P = g.worlds[0], dist = Double(ProcessInfo.processInfo.environment["AWAY"] ?? "100")! / 1000
        let up0 = simd_normalize(g.pos - P.pos), side = simd_normalize(simd_cross(up0, D3(0, 1, 0)))
        let d = simd_normalize(g.pos + side * dist - P.pos)
        g.w.pos = P.pos + d * P.groundRadius(d)
        var f = g.pos - g.w.pos; f -= d * simd_dot(f, d); g.w.camFwd = simd_normalize(f); g.w.fwd = g.w.camFwd; g.w.pitch = 0.05
        g.w.camPos = g.w.pos
        for _ in 0..<60 { g.update(1.0 / 60) }
    case "shipshot":   // close orbit view of the landed ship (YAW, PITCH env to turn the camera)
        landAt(0, lit: 0.62, minH: 1.5, maxH: 4, seed: 11)
        g.orbitYaw = Double(ProcessInfo.processInfo.environment["YAW"] ?? "0.7")!
        g.orbitPitch = Double(ProcessInfo.processInfo.environment["PITCH"] ?? "0.22")!
        for _ in 0..<240 { g.update(1.0 / 60) }
    case "depot", "depot-approach", "depot-ruber":   // parked on (or hovering toward) a fuel depot pad
        let wi = name == "depot-ruber" ? 1 : 0, P = g.worlds[wi]
        let dp = g.depots.filter { $0.world === P }[Int(ProcessInfo.processInfo.environment["DEPOT"] ?? "0") ?? 0]
        let side = simd_normalize(simd_cross(dp.dir, D3(0, 1, 0)))
        if name == "depot-approach" {
            let d = simd_normalize(dp.dir + side * (0.7 / P.R))
            g.mode = .fly; g.pos = P.pos + d * (g.surfaceR(P, d) + 0.12)
            g.q = lookRotation(forward: simd_normalize(dp.pos - g.pos), up: d); g.snapCamera(); g.update(1.0 / 60)
            g.toggleHover(); for _ in 0..<60 { g.update(1.0 / 60) }
        } else {
            g.mode = .landed; g.landedOn = P; g.gear = 1; g.gearTarget = 1; g.landedK = 1; g.tilt = 1
            g.pos = P.pos + dp.dir * (dp.padR + g.gearH)
            g.q = lookRotation(forward: simd_normalize(simd_cross(dp.dir, side)), up: dp.dir)
            g.fuel = 0.35; g.checkDock()
            g.orbitYaw = 2.4; g.orbitPitch = 0.35
            for _ in 0..<90 { g.update(1.0 / 60) }
        }
    case "verdance": landAt(2, lit: 0.5)
    case "hover", "hover-strafe":   // hovering low over Earth, moving forward (and sideways)
        landAt(0, lit: 0.6, minH: 1.5, maxH: 4, seed: 11)
        g.toggleHover(); g.hoverAlt = 0.012
        g.keys = name == "hover" ? [Key.up] : [Key.up, Key.d]
        for _ in 0..<240 { g.update(1.0 / 60) }
        g.snapCamera()
    case "coast", "coast-verdance", "coast-high", "coast-low":   // standing on a beach looking out to sea (COASTALT metres up)
        let wi = name == "coast-verdance" ? 2 : 0, w = g.worlds[wi]
        let r = Mulberry(21), sun = simd_normalize(g.sunPos - w.pos)
        var found: (D3, D3)? = nil
        for _ in 0..<200000 where found == nil {
            let d = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1))
            if abs(simd_dot(d, sun) - 0.5) > 0.12 || abs(d.y) > 0.7 { continue }
            let h = w.height(d.x, d.y, d.z, 12)
            if h < 0.004 || h > 0.03 { continue }
            let t1 = simd_normalize(simd_cross(d, D3(0, 1, 0))), t2 = simd_cross(d, t1)
            for k in 0..<8 {
                let a = Double(k) / 8 * .pi * 2, dir = t1 * cos(a) + t2 * sin(a)
                let q = simd_normalize(d + dir * (0.6 / w.R))
                if w.height(q.x, q.y, q.z, 12) < -0.02 { found = (d, dir); break }
            }
        }
        let (d, seaDir) = found ?? (sun, simd_normalize(simd_cross(sun, D3(0, 1, 0))))
        landAt(wi, lit: 0.5, minH: -1, maxH: 1)
        g.pos = w.pos + d * (w.groundRadius(d) + g.gearH); g.q = lookRotation(forward: seaDir, up: d)
        let alt = Double(ProcessInfo.processInfo.environment["COASTALT"] ?? (name == "coast-high" ? "400" : name == "coast-low" ? "2" : "25"))! / 1000
        let back = simd_normalize(d - seaDir * (0.03 / w.R)), cu = back
        let cp = w.pos + cu * (w.groundRadius(cu) + alt)
        g.overrideCam = (cp, lookRotation(forward: simd_normalize(seaDir - d * (alt > 0.1 ? 0.35 : 0.08)), up: d))
    case "cargo", "cargo-bay", "drive", "drive-turn":   // the Atlas parked with its cargo lift down and the rover out on the ground
        landAt(0, lit: 0.55, minH: 0.4, maxH: 1.2, seed: 13)
        g.cargoWant = true; g.doorK = 1; g.liftWant = true; g.liftK = 1
        for _ in 0..<5 { g.update(1.0 / 60) }
        let P = g.worlds[0], up = simd_normalize(g.pos - P.pos), c = g.ship.cargo!
        let liftW = g.pos + g.q.act(D3((c.lift.x0 + c.lift.x1) / 2, g.cargoLiftY ?? 0, (c.lift.z0 + c.lift.z1) / 2) * 0.001)
        let fwd = g.q.act(D3(0, 0, -1)), side = simd_normalize(simd_cross(fwd, up))
        let rp = simd_normalize(liftW + fwd * 0.03 + side * 0.012 - P.pos)
        g.rover.inShip = false; g.rover.world = P; g.rover.wpos = P.pos + rp * P.groundRadius(rp); g.rover.wup = rp
        g.rover.wfwd = simd_normalize(side - rp * simd_dot(side, rp))
        if name.hasPrefix("drive") {
            g.mode = .walk; g.w.world = P; g.w.pos = g.rover.wpos; g.driving = true; g.rover.speed = 32
            g.keys = name == "drive-turn" ? [Key.w, Key.a] : [Key.w]
            g.rover.camYaw = Double(ProcessInfo.processInfo.environment["ROVERYAW"] ?? "0.5")!
            for _ in 0..<150 { g.update(1.0 / 60) }
            g.rover.camYaw = Double(ProcessInfo.processInfo.environment["ROVERYAW"] ?? "0.5")!
            g.update(1.0 / 60)
        } else if name == "cargo-bay" {
            g.mode = .landed; g.aboard = AboardState(on: true, p: D3(-4, c.floorY, -190), yaw: 0.2, pitch: -0.25)
            g.rover.inShip = true; g.rover.p = D3(6, c.floorY, -205); g.rover.yaw = 0.3
            g.liftK = 0; g.liftWant = false
        } else {
            let cp0 = simd_normalize(liftW + side * 0.16 + fwd * 0.12 - P.pos)
            let cp = P.pos + cp0 * (P.groundRadius(cp0) + 0.012)
            g.overrideCam = (cp, lookRotation(forward: simd_normalize(liftW + up * 0.02 - cp), up: up))
        }
    case "outpost", "outpost-street":   // the town by the first Earth depot
        let P = g.worlds[0], d = g.outpostDir, up = d
        let east = simd_normalize(simd_cross(D3(0, 1, 0), up)), north = simd_cross(up, east)
        g.mode = .landed; g.landedOn = P; g.gear = 1; g.gearTarget = 1; g.landedK = 1
        let sd = simd_normalize(d - (east * 1.0 + north * 0.6) / P.R); g.pos = P.pos + sd * (P.groundRadius(sd) + g.gearH); g.q = g.levelQuat(up: sd)
        let street = name == "outpost-street"
        let cdir = simd_normalize(d - (east * (street ? 0.25 : 0.7) + north * (street ? 0.05 : 0.35)) / P.R)
        let cp = P.pos + cdir * (P.groundRadius(cdir) + (street ? 0.002 : 0.12))
        let tgt = P.pos + d * (P.groundRadius(d) + (street ? 0.06 : 0.03))
        g.overrideCam = (cp, lookRotation(forward: simd_normalize(tgt - cp), up: up))
    case "station":   // looking at the orbital station with traffic round it
        let P = g.worlds[0], up = simd_normalize(g.stationPos - P.pos)
        let side = simd_normalize(simd_cross(up, D3(0, 1, 0)))
        g.launch(); g.pos = g.stationPos + side * 14 + up * 3; g.q = lookRotation(forward: simd_normalize(g.stationPos - g.pos), up: up); g.v = 0; g.throttle = 0
        for _ in 0..<5 { g.update(1.0 / 60) }
        let cp = g.stationPos + side * 9 + up * 2.5
        g.overrideCam = (cp, lookRotation(forward: simd_normalize(g.stationPos - cp), up: up))
    case "low": // flying low over Earth looking at the horizon
        let w = g.worlds[0], d = spot(w, lit: 0.45, minH: 1, maxH: 6, seed: 3)
        g.mode = .fly; g.pos = w.pos + d * (w.groundRadius(d) + 1.2)
        g.q = lookRotation(forward: simd_normalize(simd_cross(d, D3(0, 1, 0))), up: d); g.camQ = g.q; g.snapCamera(); g.throttle = 0.3
    default: break
    }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var loop: Loop!
    func applicationDidFinishLaunching(_ n: Notification) {
        let device = MTLCreateSystemDefaultDevice()!
        let worlds = makeWorlds()
        let terrain = Terrain(device: device, worlds: worlds)
        let game = Game(worlds: worlds, ships: allShips(device: device))
        let audio = Audio()
        game.sfx = audio
        let hud = HUDModel()
        game.say = { s in DispatchQueue.main.async { hud.say(s) } }
        game.banner = { t, s in DispatchQueue.main.async { hud.showBanner(t, s) } }
        game.loadProgress()
        let renderer: Renderer
        do { renderer = try Renderer(device: device, game: game, terrain: terrain) } catch { fatalError("shader build failed: \(error)") }

        let frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Wayfarer"; window.center(); window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        let view = GameView(frame: frame, device: device)
        renderer.maxPixels = 6.0e6
        view.colorPixelFormat = renderer.outputFormat; view.framebufferOnly = true; view.preferredFramesPerSecond = 120
        view.game = game; view.hud = hud; view.audio = audio
        loop = Loop(game: game, renderer: renderer, terrain: terrain, hud: hud)
        view.delegate = loop
        view.loop = loop; view.applySettings()
        let hostView = PassthroughHosting(rootView: HUDView(m: hud))
        hostView.frame = frame; hostView.autoresizingMask = [.width, .height]
        view.addSubview(hostView)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.fitDrawable()
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    var gameView: GameView? { window?.contentView as? GameView }
    @objc func showSettings() { gameView?.openSettings() }
    @objc func showAbout() {
        let credits = NSAttributedString(string: "Models by Jungle Jim (sketchfab.com/jungle_jim), CC BY 4.0: Spaceship CL505, Heron Spaceship V2, Giant Round Spacestation, Brutalist Skyscraper Tower, Cyberpunk Apartment Building, Cyberpunk Cargo Truck, Sci-fi O.B. Robot Unit, Spaceship Corridor, Sci-fi Supercomputer, Sci-fi Chairs x4, Sci-fi City Material, Alien Space Nebula 1 and Landscape of an Alien Planet skyboxes. \"UNSA cruiser / spaceship\" by xaxary and \"spaceship corridor/hallway\" by zaki razzaque, CC BY 4.0.\nGround textures: ambientCG (CC0). Rocks: Poly Haven (CC0).",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

func runSpeedTest() {
    let device = MTLCreateSystemDefaultDevice()!
    let worlds = makeWorlds()
    let g = Game(worlds: worlds, ships: allShips(device: device))
    g.shipIndex = Int(ProcessInfo.processInfo.environment["WAYFARER_SHIP"] ?? "0") ?? 0
    let E = worlds[0]
    var msgs: [String] = []; g.say = { msgs.append($0) }
    print("alt(km)   engines        afterburner")
    for alt in [0.5, 2.5, 10.0, 30.0, 80.0, 400.0] {
        var row = String(format: "%7.1f ", alt)
        for burn in [false, true] {
            let d = simd_normalize(D3(0.3, 0.2, 0.93))
            g.mode = .fly; g.auto = -1; g.ab = false; g.abLevel = 0; g.v = 0; g.throttle = 1
            msgs = []
            g.pos = E.pos + d * (E.groundRadius(d) + alt + g.gearH)
            g.q = lookRotation(forward: simd_normalize(simd_cross(d, D3(0, 1, 0))), up: d)
            g.update(0.016)
            if burn { g.toggleBurner() }
            for _ in 0..<600 {   // 10 s, holding altitude so we measure the limit at that height
                g.update(1.0 / 60)
                let u = simd_normalize(g.pos - E.pos); g.pos = E.pos + u * (E.groundRadius(u) + alt + g.gearH)
            }
            row += String(format: "  %8.3f km/s M%-5.1f", g.v, g.mach) + (burn && !g.ab ? " (blocked)" : "")
        }
        print(row)
    }
}

/// headless check of landing softness, stillness after touchdown, and hover height-holding
func runLandTest() {
    let device = MTLCreateSystemDefaultDevice()!
    let worlds = makeWorlds(), E = worlds[0]
    let g = Game(worlds: worlds, ships: allShips(device: device))
    g.shipIndex = Int(ProcessInfo.processInfo.environment["WAYFARER_SHIP"] ?? "0") ?? 0
    g.say = { _ in }
    var d = simd_normalize(D3(0.3, 0.2, 0.93))
    do { let r = Mulberry(31); for _ in 0..<50000 { let q = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1)); let h = E.height(q.x, q.y, q.z, 12); if h > 1.5 && h < 3 { d = q; break } } }   // dry land
    func agl() -> Double { simd_distance(g.pos, E.pos) - E.groundRadius(simd_normalize(g.pos - E.pos)) - g.gearH }
    g.mode = .fly; g.pos = E.pos + d * (E.groundRadius(d) + g.gearH + 0.3); g.q = lookRotation(forward: simd_normalize(simd_cross(d, D3(0, 1, 0))), up: d)
    g.v = 0.02; g.update(0.016); g.startLanding()
    var last = simd_distance(g.pos, E.pos), touch = 0.0, t = 0.0
    while g.mode == .landing && t < 60 { g.update(1.0 / 60); t += 1.0 / 60; let a = simd_distance(g.pos, E.pos); if g.mode == .landing { touch = (last - a) * 60 }; last = a }
    print(String(format: "landing: %.1f s, touchdown speed %.2f m/s", t, touch * 1000))
    let p0 = g.pos; var maxMove = 0.0
    for _ in 0..<240 { g.update(1.0 / 60); maxMove = max(maxMove, simd_distance(g.pos, p0)) }
    print(String(format: "after touchdown: ship moved %.3f m over 4 s (mode %@)", maxMove * 1000, "\(g.mode)"))
    g.toggleHover()
    for _ in 0..<300 { g.update(1.0 / 60) }
    print(String(format: "hover: holding %.1f m above ground (target %.1f m)", agl() * 1000, g.hoverAlt * 1000))
    g.keys = [Key.up]
    var minA = 1e9, maxA = 0.0
    for i in 0..<600 { g.update(1.0 / 60); if i > 120 { minA = min(minA, agl()); maxA = max(maxA, agl()) } }
    print(String(format: "hover forward: %.1f m/s, height %.1f–%.1f m over rolling terrain", g.v * 1000, minA * 1000, maxA * 1000))
    // hover high up: enter at 40 km, climb with W, descend with S
    g.keys = []; g.mode = .fly; g.pos = E.pos + d * (E.groundRadius(d) + g.gearH + 40); g.v = 0.5; g.update(1.0 / 60)
    g.toggleHover(); for _ in 0..<120 { g.update(1.0 / 60) }
    let a0 = agl(); g.keys = [Key.w]; for _ in 0..<180 { g.update(1.0 / 60) }
    let a1 = agl(); g.keys = [Key.s]; for _ in 0..<360 { g.update(1.0 / 60) }
    print(String(format: "high hover: mode %@ · %.1f km → W 3 s → %.1f km → S 6 s → %.1f km", "\(g.mode)", a0, a1, agl()))
    g.keys = []; for _ in 0..<600 { g.update(1.0 / 60) }
    g.keys = [Key.s]; while agl() > 2.5 { g.update(1.0 / 60) }
    g.keys = []; g.startLanding(); t = 0
    while g.mode == .landing && t < 60 { g.update(1.0 / 60); t += 1.0 / 60 }
    // fuel: burn rates, running dry, and refuelling on a depot pad
    g.fuel = 1; g.takeOff(); for _ in 0..<240 { g.update(1.0 / 60) }
    g.throttle = 1; let f0 = g.fuel; for _ in 0..<600 { g.throttle = 1; g.update(1.0 / 60) }
    let perMinFull = (f0 - g.fuel) * 6 * 100
    g.toggleBurner(); let f1 = g.fuel; for _ in 0..<600 { g.throttle = 1; g.update(1.0 / 60) }
    let perMinAB = (f1 - g.fuel) * 6 * 100
    print(String(format: "fuel: full throttle %.1f%%/min (tank lasts %.0f min) · afterburner %.1f%%/min (%.1f min)", perMinFull, 100 / perMinFull, perMinAB, 100 / perMinAB))
    g.setBurner(false); g.fuel = 0.0005; for _ in 0..<120 { g.throttle = 1; g.update(1.0 / 60) }
    print(String(format: "empty tank: throttle capped at %.2f", g.throttle))
    let dp = g.depots.first { $0.world === E }!
    g.mode = .landed; g.landedOn = E; g.pos = E.pos + dp.dir * (dp.padR + g.gearH); g.fuel = 0.1; g.checkDock()
    let surfOK = abs(g.surfaceR(E, dp.dir) - dp.padR) < 1e-9
    t = 0; while g.fuel < 1 && t < 60 { g.update(1.0 / 60); t += 1.0 / 60 }
    print(String(format: "depot %@: pad is the surface %@ · docked %@ · refuelled 10%%→%.0f%% in %.1f s", dp.name, surfOK ? "yes" : "NO", g.dockedAt != nil ? "yes" : "NO", g.fuel * 100, t))
    print("depots per world: \(worlds.map { w in g.depots.filter { $0.world === w }.count })")
    g.mode = .landed; t = 0
    while g.mode == .landing && t < 60 { g.update(1.0 / 60); t += 1.0 / 60 }
    print(String(format: "hover → land: %.1f s, mode %@", t, "\(g.mode)"))
    // pause menu: swap ship while landed and on foot, then back to the title screen
    func gap() -> Double { let W = g.landedOn!, u = simd_normalize(g.pos - W.pos); return (simd_distance(g.pos, W.pos) - g.surfaceR(W, u) - g.gearH) * 1000 }
    g.openMenu(); let frozen = g.time; g.update(1.0 / 60)
    g.menuKey(Key.right); g.menuKey(Key.right); g.menuKey(Key.enter)
    print(String(format: "menu: time frozen %@ · landed swap → %@, gear gap %.2f m, paused %@", g.time == frozen ? "yes" : "NO", g.ship.name, gap(), g.paused ? "yes" : "no"))
    g.swapShip(to: 0); g.enterWalk(); g.swapShip(to: 2)
    print(String(format: "on foot swap → %@: explorer %.0f m from centre (hull half-width %.0f m), near ship %@", g.ship.name, simd_distance(g.w.pos, g.pos) * 1000, 0.2 * g.size / g.ship.length * 1000, g.nearShip ? "yes" : "NO"))
    g.openMenu(); g.menuKey(Key.down); g.menuKey(Key.down); g.menuKey(Key.down); g.menuKey(Key.enter)
    print("main menu: mode \(g.mode), ship \(g.ship.name), fuel \(Int(g.fuel * 100))%")
    // the sea: no landing on water, from flight or from a hover
    do {
        g.returnToTitle(); g.shipIndex = 0; g.launch()
        let r = Mulberry(77); var seaDir = D3(1, 0, 0)
        for _ in 0..<50000 { let d = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1)); if E.height(d.x, d.y, d.z, 12) < -0.05 { seaDir = d; break } }
        g.pos = E.pos + seaDir * (E.R + 0.03); g.q = g.levelQuat(up: seaDir); g.near = E; g.alt = 0.03; g.v = 0.02; g.throttle = 0
        g.toggleHover(); g.startLanding()
        print("water: L over the sea → mode \(g.mode) (should stay hover), over water \(g.landingOverWater())")
        g.toggleHover(); g.throttle = 0; g.v = 0.01
        for _ in 0..<300 { g.update(1.0 / 60) }
        print("water: slow flight down to the sea → mode \(g.mode) (should not land)")
    }
    // sonic boom: accelerate low on afterburner through Mach 1
    do {
        g.returnToTitle(); g.shipIndex = 0; g.launch()
        let d = simd_normalize(D3(0.3, 0.2, 0.93))
        g.pos = E.pos + d * (E.groundRadius(d) + 2.5); g.q = g.levelQuat(up: d); g.v = 0.25; g.throttle = 1
        var t = 0.0, boomAt = -1.0
        while t < 30 && boomAt < 0 { g.update(1.0 / 60); t += 1.0 / 60; if g.shockT < 0.02 { boomAt = t } }
        print(String(format: "sonic boom: %@ %.2f s after pushing to full throttle from Mach %.2f · vapour %.2f", boomAt >= 0 ? "yes" : "NO", boomAt, 0.25 / 0.343, g.vapor))
    }
    // walking aboard mid-trip: autopilot and afterburner carry on
    do {
        g.returnToTitle(); g.shipIndex = 2; g.launch()
        for _ in 0..<60 { g.update(1.0 / 30) }
        g.keyDown(Key.two); for _ in 0..<300 { g.update(1.0 / 30) }
        g.throttle = 1; g.toggleBurner()
        let d0 = simd_distance(g.pos, worlds[1].pos), ab0 = g.ab
        g.keyDown(Key.i)
        for _ in 0..<600 { g.update(1.0 / 30) }
        let d1 = simd_distance(g.pos, worlds[1].pos)
        print(String(format: "aboard mid-trip: autopilot %@ · afterburner %@→%@ · closed %.0fk km in 20 s", g.auto == 1 ? "still on" : "OFF", ab0 ? "on" : "off", g.ab ? "on" : "OFF", (d0 - d1) / 1000))
        g.keyDown(Key.i)
    }
    // orbit camera: moving the mouse swings the camera, not the ship
    do {
        g.returnToTitle(); g.shipIndex = 0; g.launch(); g.keyDown(Key.c)
        for _ in 0..<10 { g.update(1.0 / 60) }
        let q0 = g.q, y0 = g.extYaw
        for _ in 0..<30 { g.mouse = SIMD2(20, 6); g.update(1.0 / 60) }
        let turned = abs(simd_dot(q0.vector, g.q.vector)) < 0.99999
        print(String(format: "orbit camera: mouse moved the camera %.2f rad · ship turned %@", g.extYaw - y0, turned ? "YES (bad)" : "no"))
        g.keyDown(Key.c); g.keyDown(Key.c)
    }
    // running dry in the air, then the emergency tanker
    do {
        g.returnToTitle(); g.shipIndex = 1; g.launch()
        let d = simd_normalize(D3(0.3, 0.2, 0.93))
        g.pos = E.pos + d * (E.groundRadius(d) + 3.0); g.q = g.levelQuat(up: d); g.v = 0.4; g.throttle = 0.6; g.fuel = 0.0001
        for _ in 0..<180 { g.update(1.0 / 60) }
        let a0 = g.alt
        for _ in 0..<300 { g.update(1.0 / 60) }
        print(String(format: "dry: engines %.2f (0 = dark) · throttle %.1f · gliding down %.0f m in 5 s · speed %.0f m/s", g.engineK, g.throttle, (a0 - g.alt) * 1000, g.v * 1000))
        g.keyDown(Key.f)
        var t = 0.0; var docked = -1.0
        while g.tanker.active && t < 90 { g.update(1.0 / 30); t += 1.0 / 30; if docked < 0 && g.tanker.phase == 1 { docked = t } }
        print(String(format: "tanker: docked after %.0f s · tank %.0f%% · gone after %.0f s", docked, g.fuel * 100, t))
        g.fuel = 0.9; g.keyDown(Key.f); print("tanker at 90%: active \(g.tanker.active) (should be false)")
    }
    // Atlas: heavy landing, the cargo bay opens, drive the rover out and back in
    do {
        g.returnToTitle(); g.shipIndex = 2; g.launch()
        let r = Mulberry(5); var dir = D3(0, 0, 1)
        for _ in 0..<80000 {
            let d = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1))
            let h = E.height(d.x, d.y, d.z, 12); if h < 0.3 || h > 1.2 { continue }
            var flat = true
            let a1 = simd_normalize(simd_cross(d, D3(0, 1, 0))), a2 = simd_cross(d, a1)
            for (x, y) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0), (0.7, 0.7), (-0.7, -0.7)] {
                let q2 = simd_normalize(d + (a1 * x + a2 * y) * (0.5 / E.R)); if abs(E.height(q2.x, q2.y, q2.z, 12) - h) > 0.012 { flat = false; break }
            }
            if flat { dir = d; break }
        }
        g.pos = E.pos + dir * (E.groundRadius(dir) + g.gearH + 0.3); g.q = g.levelQuat(up: dir); g.v = 0; g.near = E
        g.mode = .landing
        var t = 0.0; while g.mode == .landing && t < 120 { g.update(1.0 / 30); t += 1.0 / 30 }
        let kicked = g.kick
        t = 0; while g.doorK < 1 && t < 60 { g.update(1.0 / 30); t += 1.0 / 30 }
        print(String(format: "atlas landing: %@ · camera kick %.2f · cargo doors open after %.0f s · ground %.0f m below the bay floor", "\(g.mode)", kicked, t, g.ship.cargo!.floorY - g.cargoGround))
        g.keyDown(Key.i); g.aboard.p = g.rover.p + D3(3, 0, 0); g.keyDown(Key.e)
        g.rover.yaw = 0; g.keys = [Key.w]
        t = 0; while t < 40 && !(g.rover.p.z < g.ship.cargo!.lift.z1 - 10) { g.update(1.0 / 30); t += 1.0 / 30 }    // onto the lift
        g.keys = []; g.rover.speed = 0
        while !g.cargoOpen && t < 80 { g.update(1.0 / 30); t += 1.0 / 30 }                    // it takes us down
        g.keys = [Key.w]
        while g.rover.inShip && t < 120 { g.update(1.0 / 30); t += 1.0 / 30 }
        for _ in 0..<90 { g.update(1.0 / 30) }
        g.keys = []; for _ in 0..<60 { g.update(1.0 / 30) }
        let out = !g.rover.inShip, away = simd_distance(g.rover.wpos, g.pos) * 1000
        print(String(format: "rover: drove out %@ after %.0f s · now %.0f m from the ship's centre · mode %@", out ? "yes" : "NO", t, away, "\(g.mode)"))
        // drive back: point at the lift and go
        let c = g.ship.cargo!, liftW = g.pos + g.q.act(D3((c.lift.x0 + c.lift.x1) / 2, g.cargoLiftY ?? 0, (c.lift.z0 + c.lift.z1) / 2) * 0.001)
        let u = simd_normalize(g.rover.wpos - E.pos); var to = liftW - g.rover.wpos; to -= u * simd_dot(to, u); g.rover.wfwd = simd_normalize(to)
        g.keys = [Key.w]; t = 0; while !g.rover.inShip && t < 60 { g.update(1.0 / 30); t += 1.0 / 30 }
        g.keys = []; for _ in 0..<30 { g.update(1.0 / 30) }
        print(String(format: "rover: back aboard %@ after %.0f s · aboard %@", g.rover.inShip ? "yes" : "NO", t, g.aboard.on ? "yes" : "no"))
        for _ in 0..<200 { g.update(1.0 / 30) }       // the lift brings us up
        g.keyDown(Key.e); g.setCargoDoor(false)    // out of the rover, close the doors
        t = 0; while g.doorK > 0 && t < 90 { g.update(1.0 / 30); t += 1.0 / 30 }
        print(String(format: "cargo bay closed after %.0f s (door %.2f)", t, g.doorK))
        // calling the ship from afar: refused when powered down, takes a while when not
        g.keyDown(Key.i)
        g.enterWalk(); g.togglePower()
        let side = simd_normalize(simd_cross(dir, D3(0, 1, 0)))
        let far = simd_normalize(dir + side * (5.0 / E.R)); g.w.pos = E.pos + far * E.groundRadius(far)
        g.summonShip(); let refused = !g.sh.active
        g.togglePower(); g.summonShip()
        t = 0; while g.sh.active && t < 300 { g.update(1.0 / 30); t += 1.0 / 30 }
        print(String(format: "summon: refused while powered down %@ · came 5 km in %.0f s (incl. spool-up)", refused ? "yes" : "NO", t))
    }
    // atmospheric entry: dive in from space at full throttle, 25° down; time from the top of the air to 5 km
    do {
        g.returnToTitle(); g.shipIndex = 0; g.launch()
        let d = simd_normalize(D3(0.3, 0.2, 0.93)), top = E.atmo.top
        g.pos = E.pos + d * (E.R + top + 20); let flat = simd_normalize(simd_cross(d, D3(0, 1, 0)))
        g.q = lookRotation(forward: simd_normalize(flat * cos(0.44) - d * sin(0.44)), up: d); g.v = 9; g.throttle = 1
        var t = 0.0, inside = -1.0, peak = 0.0
        while t < 600 && g.alt > 5 && g.mode == .fly {
            g.update(1.0 / 30); t += 1.0 / 30
            if inside < 0 && g.airDensity > 0 { inside = t }
            peak = max(peak, g.heat)
            if g.alt > 5 { let up = simd_normalize(g.pos - E.pos); g.q = lookRotation(forward: simd_normalize(simd_cross(up, simd_cross(g.forward, up)) * cos(0.44) - up * sin(0.44)), up: up) }
        }
        print(String(format: "entry: %.0f s from the edge of the air (%.0f km) down to 5 km · speed now %.1f km/s · peak re-entry glow %.2f", t - max(inside, 0), top, g.v, peak))
    }
    // calling a ship: engines spool up first (longer for big ships), then she climbs away by her weight
    for si in [0, 2] {
        g.returnToTitle(); g.shipIndex = si
        let d = simd_normalize(D3(0.31, 0.21, 0.93)); var dir = d
        do { let r = Mulberry(UInt32(40 + si)); for _ in 0..<50000 { let q = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1)); let h = E.height(q.x, q.y, q.z, 12); if h > 1 && h < 2.5 { dir = q; break } } }
        g.mode = .landed; g.landedOn = E; g.near = E; g.pos = E.pos + dir * (E.groundRadius(dir) + g.gearH); g.q = g.levelQuat(up: dir); g.gear = 1
        g.enterWalk()
        let side = simd_normalize(simd_cross(dir, D3(0, 1, 0))), far = simd_normalize(dir + side * (3.0 / E.R)); g.w.pos = E.pos + far * E.groundRadius(far)
        g.summonShip(); let p0 = g.pos
        var t = 0.0, lift = -1.0
        while g.sh.active && t < 400 { g.update(1.0 / 30); t += 1.0 / 30; if lift < 0 && simd_distance(g.pos, p0) > 0.001 { lift = t } }
        print(String(format: "summon %@: engines spool %.1f s before lifting · arrived 3 km away after %.0f s", g.ship.name, lift, t))
    }
    // the robot: boost to Mach 1+ for a sonic boom; drop out of a ship hovering in space
    do {
        g.returnToTitle(); g.shipIndex = 0
        var dir = D3(0, 1, 0)
        do { let r = Mulberry(61); for _ in 0..<50000 { let q = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1)); let h = E.height(q.x, q.y, q.z, 12); if h > 1 && h < 2.5 { dir = q; break } } }
        g.mode = .landed; g.landedOn = E; g.near = E; g.pos = E.pos + dir * (E.groundRadius(dir) + g.gearH); g.q = g.levelQuat(up: dir); g.gear = 1
        g.enterWalk(); g.keyDown(Key.x); g.w.pitch = -0.3; g.keys = [Key.w]; g.shift = true
        var t = 0.0, boom = -1.0, top = 0.0
        while t < 15 { g.update(1.0 / 60); t += 1.0 / 60; top = max(top, simd_length(g.w.vel + simd_normalize(g.w.pos - E.pos) * g.w.vUp)); if boom < 0 && g.heroBoomT < 0.02 { boom = t } }
        g.keys = []; g.shift = false
        print(String(format: "robot flight: top speed %.0f m/s (Mach %.1f) · sonic boom %@ after %.1f s", top * 1000, top / 0.343, boom >= 0 ? "yes" : "NO", boom))
        g.returnToTitle(); g.shipIndex = 0
        g.mode = .landed; g.landedOn = E; g.near = E; g.pos = E.pos + dir * (E.groundRadius(dir) + g.gearH); g.q = g.levelQuat(up: dir); g.gear = 1
        g.toggleHover(); g.hoverAlt = 150; for _ in 0..<60 { g.update(1.0 / 60) }; g.pos = E.pos + dir * (E.R + 150); g.alt = 150
        g.keyDown(Key.e)
        print("drop out at 150 km (space): on foot \(g.mode == .walk ? "yes" : "NO") · ship still hovering \(g.parkedHover ? "yes" : "NO")")
    }
    // stepping out of a low hover, and climbing back in
    do {
        g.returnToTitle(); g.shipIndex = 0
        var dir = D3(0, 1, 0)
        do { let r = Mulberry(52); for _ in 0..<50000 { let q = simd_normalize(D3(r.next() * 2 - 1, r.next() * 2 - 1, r.next() * 2 - 1)); let h = E.height(q.x, q.y, q.z, 12); if h > 1 && h < 2.5 { dir = q; break } } }
        g.mode = .landed; g.landedOn = E; g.near = E; g.pos = E.pos + dir * (E.groundRadius(dir) + g.gearH); g.q = g.levelQuat(up: dir); g.power = true; g.fuel = 1
        g.toggleHover(); g.hoverAlt = 0.015
        for _ in 0..<300 { g.update(1.0 / 60) }
        let shipAlt = g.alt
        g.keyDown(Key.e)
        let out = g.mode == .walk
        for _ in 0..<180 { g.update(1.0 / 60) }
        let onGround = g.w.onGround, altAfter = g.alt
        // walk back under her and board
        let up = simd_normalize(g.pos - E.pos), under = simd_normalize(g.pos - up * simd_dot(g.pos - E.pos, up) * 0 - E.pos)
        g.w.pos = E.pos + under * E.groundRadius(under)
        g.keyDown(Key.e)
        print(String(format: "hover exit: ship at %.0f m → out %@, landed on the ground %@, ship still hovering at %.0f m · back aboard → mode %@", shipAlt * 1000, out ? "yes" : "NO", onGround ? "yes" : "NO", altAfter * 1000, "\(g.mode)"))
        g.hoverAlt = 0.4; for _ in 0..<600 { g.update(1.0 / 60) }; g.keyDown(Key.e)
        print("hover exit from \(Int(g.alt * 1000)) m: allowed \(g.mode == .walk ? "yes" : "NO")")
    }
    // the trip: autopilot from Earth orbit to each world
    for target in [1, 2] {
        g.returnToTitle(); g.shipIndex = 0; g.launch()
        for _ in 0..<60 { g.update(1.0 / 30) }
        g.keyDown(target == 1 ? Key.two : Key.three)
        var t = 0.0
        while g.auto >= 0 && t < 3600 { g.update(1.0 / 30); t += 1.0 / 30 }
        let d0 = simd_distance(E.pos, worlds[target].pos)
        print(String(format: "trip to %@ (%.0fk km): %.1f min on autopilot", worlds[target].name, d0 / 1000, t / 60))
    }
    // walk the Atlas deck while she flies on by herself
    g.shipIndex = 2; g.launch(); g.throttle = 0.5
    for _ in 0..<300 { g.update(1.0 / 60) }
    g.keyDown(Key.i)
    let ap0 = g.pos, alt0 = g.alt, sp0 = g.v
    g.aboard.p.x = 0.5; g.aboard.p.z = 12; g.aboard.yaw = .pi
    g.keys = [Key.w]; g.shift = true
    var maxZ = -1e9, minZ = 1e9
    for i in 0..<3600 {          // a minute of running: aft down the corridor, then turn around
        if i == 1800 { g.aboard.yaw += .pi }
        g.update(1.0 / 60); maxZ = max(maxZ, g.aboard.p.z); minZ = min(minZ, g.aboard.p.z)
    }
    g.keys = []; g.shift = false
    let dk = g.ship.deck!
    let inside = dk.walkable(g.aboard.p.x, g.aboard.p.z, g.aboard.p.y)
    print(String(format: "aboard: ran z %.0f…%.0f m (corridor ends at 140, hall at 200) · inside %@ · ship flew %.1f km, speed %.0f→%.0f m/s, alt %.2f→%.2f km, mode %@",
                 minZ, maxZ, inside ? "yes" : "NO", simd_distance(ap0, g.pos), sp0 * 1000, g.v * 1000, alt0, g.alt, "\(g.mode)"))
    // walk out of every lift car through its doors (the bottom one used to be boxed in)
    do {
        let dk = g.ship.deck!
        for (li, l) in dk.lifts.enumerated() {
            for (st, yaw) in [(l.a, dk.liftYaws[li].a), (l.b, dk.liftYaws[li].b)] {
                g.aboard.p = st; g.aboard.lift = nil; g.aboard.onFloor = true
                g.aboard.yaw = yaw + 0.0          // doors face -z rotated by yaw → the view direction that walks out
                g.keys = [Key.w]; for _ in 0..<150 { g.update(1.0 / 60) }; g.keys = []
                let out = simd_distance(SIMD2(g.aboard.p.x, g.aboard.p.z), SIMD2(st.x, st.z))
                print(String(format: "lift exit %d%@: walked %.1f m out %@", li, st == l.a ? "a" : "b", out, out > 4 ? "ok" : "BLOCKED"))
            }
        }
    }
    // ride the lift up to the bridge
    let lift = dk.lifts[0]
    g.aboard.p = lift.a; g.keyDown(Key.e); for _ in 0..<720 { g.update(1.0 / 60) }
    print(String(format: "lift: lounge %.1f m → %.1f m (bridge floor %.1f) %@", lift.a.y, g.aboard.p.y, lift.b.y, abs(g.aboard.p.y - lift.b.y) < 0.01 ? "ok" : "FAILED"))
    g.keyDown(Key.i)
    print("back at the helm: aboard \(g.aboard.on), mode \(g.mode)")
    // the smaller ships' cabins: wander around for 30 s in every direction, never leaving the floor plan
    for si in [0, 1] where g.ships[si].deck != nil {
        g.returnToTitle(); g.shipIndex = si; g.launch(); g.throttle = 0.4
        for _ in 0..<120 { g.update(1.0 / 60) }
        g.keyDown(Key.i)
        let dk = g.ship.deck!
        var ok = true, minX = 1e9, maxX = -1e9, minZ = 1e9, maxZ = -1e9
        g.keys = [Key.w]; g.shift = true
        for i in 0..<1800 {
            if i % 150 == 0 { g.aboard.yaw += 1.9 }
            g.update(1.0 / 60)
            let p = g.aboard.p
            ok = ok && dk.walkable(p.x, p.z, p.y); minX = min(minX, p.x); maxX = max(maxX, p.x); minZ = min(minZ, p.z); maxZ = max(maxZ, p.z)
        }
        g.keys = []; g.shift = false
        // walk from the cabin straight up the stairs into the cockpit
        g.aboard = AboardState(on: true, p: dk.spawn, yaw: 0, pitch: 0); g.cockpitView = false
        g.keys = [Key.w]; for _ in 0..<900 { g.update(1.0 / 60) }; g.keys = []
        let topY = g.aboard.p.y, seatY = dk.helms[0].p.y
        print(String(format: "%@ stairs: walked from floor %.1f m up to %.1f m (cockpit floor %.1f) %@", g.ship.name, dk.spawn.y, topY, seatY, abs(topY - seatY) < 0.05 ? "ok" : "NOT THERE"))
        g.aboard.p = dk.helms[0].p; let helm = g.nearHelm != nil; g.keyDown(Key.e)
        print(String(format: "%@ cabin: roamed x %.1f…%.1f z %.1f…%.1f m · always on the floor %@ · E at %@ → seated %@", g.ship.name, minX, maxX, minZ, maxZ, ok ? "yes" : "NO", dk.helms[0].word, helm && !g.aboard.on && g.cockpitView ? "yes" : "FAILED"))
    }
}

let args = CommandLine.arguments
if args.contains("--speedtest") { runSpeedTest(); exit(0) }
if args.contains("--landtest") { runLandTest(); exit(0) }
if args.contains("--snapshot") {
    runSnapshot(args: args)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let menu = NSMenu(), appItem = NSMenuItem(); menu.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "About Wayfarer", action: #selector(AppDelegate.showAbout), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ","))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Hide Wayfarer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "Quit Wayfarer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    let viewItem = NSMenuItem(); menu.addItem(viewItem)
    let viewMenu = NSMenu(title: "View")
    viewMenu.addItem(NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"))
    viewMenu.items.last!.keyEquivalentModifierMask = [.command, .control]
    viewItem.submenu = viewMenu
    let winItem = NSMenuItem(); menu.addItem(winItem)
    let winMenu = NSMenu(title: "Window")
    winMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    winItem.submenu = winMenu; app.windowsMenu = winMenu
    appItem.submenu = appMenu; app.mainMenu = menu
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
