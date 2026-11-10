# Wayfarer for macOS

Native Swift + Metal version of the Wayfarer space-exploration game.

## Build and run

```bash
./build_app.sh                      # builds build/Wayfarer.app (release)
open build/Wayfarer.app
```

Requires macOS 14+ and Xcode command-line tools (Swift 5.9+). No external dependencies.

## Travel

The worlds are about 700,000 km apart. Cruise tops out at 2,500 km/s (×3 on afterburner), so a crossing takes about 5 minutes on autopilot (1–3), or under 2 on full afterburner. Distant worlds shine like bright stars with a label showing their distance and, when you're heading for one, the time to arrive.

Breaking Mach 1 in an atmosphere sets off a sonic boom with a shock ring, and a vapour cone wraps the hull in the transonic zone. Lighting the afterburner cracks and thumps, with a white-hot flash at the nozzles and a kick of the camera, then roars while it burns.

You can't land on the sea: L over water is refused and slow flight skims the surface. On foot you can paddle into the shallows but not out of your depth.

## Water

Earth and Verdance have seas. The water is lit by depth: sand shows through turquoise shallows and fades to deep blue (Verdance: teal) further out. Layered waves move at real deep-water speeds; there's sky reflection, sun glitter, surf washing up the beach, and darker wet sand at the waterline. Snapshot scenarios: `coast`, `coast-high`, `coast-low`, `coast-verdance` (COASTALT sets the camera height in metres).

## Ships

Choose on the title screen with ← →.

- **Kestrel**: 50 m strike fighter; agile, belly VTOL jets for hover and landing.
- **Atlas**: 1 km heavy carrier; slow to turn, heavy hover, deep engine rumble, huge tank (about 2.5 h at full throttle), bridge-style cockpit, eight belly VTOL jets. Too big for depot pads: it refuels when landed within about 800 m of a depot.
  Press **I** to leave the helm and walk the deck while she flies on (she levels off and holds course, or holds a hover): a 208 × 60 m observation lounge with window walls on both flanks, a holo table, a helm station, a 120 m corridor aft and a reactor hall. WASD walk, Shift run, Space jump, mouse look; **E** at the helm or **I** anywhere takes the controls again.
- **Condor**: 85 m heavy explorer; 1.5× top speed, deeper engine note, wingtip engine nacelles that swing down to vertical for hover, landing and when parked.

## Fuel and depots

Engines burn fuel: more with throttle, about 4× on afterburner, steadily while hovering (the Condor's bigger tank lasts about a third longer). At 20% and 5% you get a warning; at zero only weak reserve thrusters remain. Each world has six fuel depots (raised landing pads with tanks, a control building and a blinking beacon mast); nearby ones show as cyan FUEL markers, pinned to the screen edge when fuel is low. Land on a pad and the tank refills (about 11 s from empty).

## Controls

| Key | Action |
|---|---|
| Click / Enter | launch from the title screen (drag to turn the ship) |
| Esc | pause menu (releases the mouse): Resume · Ship ← → then Enter to swap ships right where you are (landed, on foot, hovering or flying) · Main menu (back to the title screen and ship selector, fresh tank) |
| Mouse | steer (click to capture) |
| W / S | throttle |
| A / D | roll |
| Arrows | pitch and yaw |
| Shift | afterburner (at full throttle) |
| Space | brake |
| 1 – 3 | autopilot to Earth, Ruber, Verdance |
| L | land (below 3 km) / take off |
| G | hover mode, at any height (or lift off into a hover): W/S height, ↑↓ forward/back, A/D strafe, ←→ turn, mouse looks around the ship (level camera), space brake, G again to fly |
| V | cockpit / chase view: per-ship cockpit (Kestrel: red rails and a wall of displays; Condor: ribbed bubble canopy and overhead console) with a green holographic flight HUD; the mouse turns your head while hovering or parked |
| C | camera: chase · orbit (the mouse swings the camera round the ship instead of steering, scroll wheel zooms, keys still fly) · pass-by (a camera ahead of you that you streak past, zooming to keep you in frame, up to 60 km/s) |
| I | leave the pilot's seat and walk around inside while the ship flies on (every ship, sized to it). Dark sci-fi panels with flowing LED strips. Kestrel: cabin with wing-view windows, bunks, and steep stairs up into the fighter cockpit. Condor: crew deck with window walls over the wings, lounge, bunks, galley, engine bay, and a stairwell up into the bubble cockpit. Atlas: lounge with floor-to-ceiling windows, corridor, reactor hall, and a lift (E on the glowing pad) up to the glass-domed bridge. Under each canopy the glass opens up for a full view; E at the pilot's seat sits you down to fly, I anywhere takes the controls |
| P | power the ship off / on (landed) |
| E | step outside when landed · board again |
| WASD / Shift / Space | on foot: walk · run · jump (hold for jetpack) |
| R | on foot: call your ship to you |
| Q | scan for signals (range grows with altitude) |
| Tab | logbook: discoveries per world |
| M | sound on / off |
| N | music on / off: a slow generative ambient soundtrack (evolving pad chords and soft bells) |
| F | call the emergency fuel tanker (tank below 60%): it flies out to you wherever you are, matches your speed, runs a fuel line across and fills you up |
| H | hide the interface |
| Ctrl-Cmd-F | full screen |

## Checking visuals without a window

```bash
.build/release/Wayfarer --snapshot shots/low.png --scenario low --size 1600x1000
```

Scenarios: `title`, `orbit`, `afterburner`, `ground`, `sunset`, `low`, `ruber`, `verdance`, `closeup`, `walk`, `run-ruber`, `jetpack`, `recall`, `site-monolith`, `site-wreck`, `site-crystal`, `beacons`, `discover`, `hover`, `hover-strafe`, `shipshot` (`YAW`, `PITCH` env); `depot`, `depot-approach`, `depot-ruber` (`DEPOT=n`); `COCKPIT=1`, `LOOKYAW`, `LOOKPITCH` env work with any scenario, `away` (on foot `AWAY=<metres>` from the ship).
`WAYFARER_SHIP=1` renders/tests with the Condor. `--landtest` checks touchdown speed, that the ship stays still once landed, and hover height-holding.
`--speedtest` prints top speeds at several altitudes. Snapshots also print GPU time per frame; add `--rockstats` for rock/grass instance counts.
Dev-only environment switches: `WAYFARER_NOSHADOW=1` turns shadows off; `WAYFARER_EXP="find=>replace"` patches the shader source at launch for quick experiments.

## Code map

| File | What it does |
|---|---|
| `Worlds.swift` | the three planets: terrain height and colour functions, atmosphere settings |
| `Noise.swift` | seeded simplex noise (identical to the web build, so worlds match) |
| `Terrain.swift` | cube-sphere quadtree; tiles built in parallel on all CPU cores |
| `Shaders.swift` | all Metal shaders: terrain, water, clouds, ship, flames, physically based atmosphere, bloom, ACES |
| `Renderer.swift` | frame encoding, two-cascade sun shadows, rock and grass instancing, adaptive render resolution |
| `Rocks.swift` | photo-scanned rocks (Poly Haven, CC0) with generated LODs, grass clumps, deterministic placement around the camera |
| `Meshes.swift` | Kestrel model, ship mesh builder, procedural textures |
| `Condor.swift` | Condor model with tilting nacelles, its hull texture |
| `Depots.swift` | fuel depots: placement, pad surface, model, fuel use and refuelling |
| `Atlas.swift` | Atlas carrier model and its hull texture |
| `Interior.swift` | walkable interiors for all three ships: layouts, collision, first-person walking aboard a flying ship |
| `Cockpit.swift` | cockpit interiors for both ships and the procedural display textures |
| `Game.swift` | flight, afterburner, autopilot, landing, power, cameras |
| `Audio.swift` | real-time synthesised engine and effects |
| `Walker.swift` | the explorer on foot, ship recall |
| `Discovery.swift` | discovery sites, scanner, saved progress |
| `Materials.swift` | photographic ground textures (CC0, ambientCG) |
| `main.swift` | window, input, HUD, snapshot tool |

## Roadmap

1. ✅ Native foundation: worlds, atmosphere scattering, Kestrel, flight, landing, sound
2. ✅ Walking on foot, ship recall, photo textures, exploration (scanner, sites, logbook)
2b. ✅ Sun shadows, scanned rocks, grass, full-detail terrain near the ground
3. Next: trees and plants, Albatross, volumetric clouds, real star map, a better explorer model


Fuel: a full tank lasts about 35 min at full throttle in the Kestrel, an hour in the Condor and two and a half hours in the Atlas (afterburner burns about four times faster). Below 20% a warning shows on screen; at 0 the engines go dark, the ship coasts and glides down, and F calls the emergency tanker.

## Atlas cargo bay and rover

The Atlas carries three six-wheeled rovers in a cargo bay low in its belly; one is yours to drive. When the Atlas lands (with a heavy, ground-shaking touchdown and a burst of dust) the belly doors slide open. Take the second lift pad in the lounge down to the bay, walk up to the rover and press E. Drive onto the cargo lift and wait a moment (or press E): it lowers you about 70 m to the ground, and you drive off across the planet (W/S drive, A/D steer, Shift boost, Space brake, mouse looks around, E to get out and walk). Drive or walk back onto the lowered lift and it carries you up into the bay. O opens or closes the cargo doors; the bay closes before take-off.

Big ships throw a broad shade on the ground under them as they hover and land, and kick up dust. Calling your ship (R on foot) only works when it's powered and fuelled, and it flies over at a few hundred km/h, so from far away it takes a while.

## Settings and the app

Press , (or ⌘, from the menu bar, or Settings in the Esc menu) for settings: sound and music volume, mouse sensitivity, invert mouse Y, graphics quality (Auto holds the frame rate; Performance, Balanced and Maximum fix the internal resolution), show frame rate, and full screen. They're saved between launches. K shows all the controls.

With "Show frame rate" on, the corner readout also shows memory: RAM (the app's footprint, as Activity Monitor counts it) and GPU (what Metal has allocated). Typical: about 1.1–1.25 GB RAM and 470–620 MB GPU.

The app has its own icon (Assets/AppIcon.icns, rendered from the Kestrel over Earth), a proper menu bar (About, Settings, Hide, Quit, Full Screen ⌃⌘F, Minimize) and is tagged as a game. To install it, copy build/Wayfarer.app into /Applications.

## Ships modelled in Blender

The Kestrel's hull is now a proper 3D model built in Blender (Tools/blender/kestrel.py, about 33,000 triangles) with the same outline as before: bevelled surfaces, panel seams, a framed canopy, flared nozzles, intakes, cannons and markings. It's exported with Tools/blender/export_ship.py, which joins the parts, unwraps them, bakes colour, roughness and normal maps (2048²) and writes Assets/Ships/kestrel.mesh plus two textures. The game loads it at start-up and falls back to the old procedural hull if the files are missing (WAYFARER_OLDSHIPS=1 forces the old one).

    Blender -b -P Tools/blender/kestrel.py -- shots/kestrel_v3 render
    Blender -b shots/kestrel_v3/kestrel.blend -P Tools/blender/export_ship.py -- Assets/Ships kestrel 35.714285714 2048
    ./build_app.sh

## CL505 (imported model)

A fourth ship, the CL505: a 32 m interceptor. Its hull is "Spaceship CL505" by Jungle Jim, licensed under Creative Commons Attribution (CC BY 4.0), downloaded from Sketchfab; the credit also appears in the game's About panel and Settings. The original file is in SourceModels/cl505/. Tools/blender/prep_cl505.py scales it to 32 m and turns it to the game's axes; export_ship.py with `keepuv` bakes onto the model's own texture layout:

    Blender -b -P Tools/blender/prep_cl505.py -- SourceModels/cl505/cl505_4k.glb SourceModels/cl505
    Blender -b SourceModels/cl505/cl505.blend -P Tools/blender/export_ship.py -- Assets/Ships cl505 22.857142857 2048 keepuv

The model carries its own landing wheels; in cockpit view its canopy is opened up around the pilot. It has no walkable interior.

## Credits

All by Jungle Jim (https://sketchfab.com/jungle_jim), licensed under Creative Commons Attribution 4.0:
- "Spaceship CL505" — the CL505 ship
- "Heron Spaceship V2 (animated)" — the Heron ship and the traffic round the orbital station
- "Giant Round Spacestation" — the city-station in orbit over Earth
- "Brutalist Skyscraper Tower", "Cyberpunk Background Apartment Building", "Cyberpunk Cargo Truck", "Sci-fi O.B. Robot Unit TH-ICC02 (animated)" — the outpost town by Earth's first depot
- "Spaceship Corridor" — the Atlas's main corridor
- "Sci-fi Supercomputer", "Sci-fi Chairs x4", "Sci-fi City Material Texture 2k" — the Atlas bridge, lounge and reactor core
- "Alien Space Nebula 1 (Skybox)" — the sky in space; "Landscape of an Alien Planet (Skybox)" — the lounge's big display

Also CC BY 4.0:
- "UNSA cruiser / spaceship" by xaxary (https://sketchfab.com/Xaxary) — the Atlas hull (1.3 km)
- "spaceship corridor/hallway" by zaki razzaque (https://sketchfab.com/Zakirazzaque) — the Atlas hallway from the reactor hall to the bridge lift
- Ground textures: ambientCG (CC0). Rocks: Poly Haven (CC0).

The Atlas hull is also a Blender model now (Tools/blender/atlas.py, about 105,000 triangles, 4096² textures: stepped terraces, a lit machinery trench along both flanks, a forked prow and a raked command tower). It keeps the old footprint so the lounge windows, cargo lift, corridor, reactor hall and bridge bubble still line up:

    Blender -b -P Tools/blender/atlas.py -- shots/atlas_v3 render
    Blender -b shots/atlas_v3/atlas.blend -P Tools/blender/export_ship.py -- Assets/Ships atlas 500 4096

## Downloaded models

Originals live in SourceModels/new. Tools/blender/batch_props.sh prepares each (prep_prop.py: pose, scale to metres, decimate) into SourceModels/prepped and bakes it (export_ship.py: colour, roughness, normals, metalness and glow) into Assets/Props or Assets/Ships. Props.swift places them: the outpost town (scenario `outpost`, `outpost-street`), the orbital station with Heron traffic (`station`), and the Atlas's corridor, bridge, lounge, reactor and cargo bay.

## Player character and car

On foot you are the Bot Blast R-325 ("FREE CHARACTER BOT BLAST R-325" by Oscar Creativo, CC BY 4.0, https://sketchfab.com/3d-models/free-character-bot-blast-r-325-by-oscar-creativo-7c3843d203aa4044ae38f7a74645b345), skinned on the GPU. It replaced the orange robot ("Sci-fi O.B. Robot Unit TH-ICC02" by Jungle Jim). Tools/blender/prep_skinned.py exports its 142-joint skeleton, skin weights and its idle animation (Assets/Characters); CharacterRig.swift plays the idle when you stand still and drives the legs, arms, spine and head with code for walking, running, jumping and the jetpack.

The rover is the cyberpunk cargo truck (Jungle Jim, CC BY 4.0), split by Tools/blender/prep_truck.py into a body and a wheel: the eight wheels spin, the front axle steers (the rear a little), each wheel rides its own suspension over the ground, and the body leans in turns and dips under throttle and braking. Headlights, brake lights and a dust trail. Top speed 160 km/h, 270 with Shift.

## Atlas: the UNSA cruiser hull

The Atlas is now the UNSA cruiser, scaled to 1.3 km (prep_prop.py length=1300 rotz=180, baked at 4096). The decks are fitted inside it: the lounge is 160 m wide with windows on both flanks, the JJ corridor runs aft to the reactor hall, the new hallway (five 19 m segments, end walls removed) continues to a lobby where a lift rises straight up to the bridge in the command tower. The cargo bay moved aft to the deep part of the keel (ATLAS_BAY_DZ). Constants: ATLAS_EYE, ATLAS_BAY_DZ, ATLAS_DOOR_Y, ATLAS_HALL in Interior.swift.

### Trees, bushes and flowers

"Low poly trees, flowers and grass" by Márcio Meireles (CC BY 4.0, https://sketchfab.com/3d-models/low-poly-trees-flowers-and-grass-442904f26b87407d98871b50b49c4169), exported by Tools/blender/prep_flora.py into Assets/Models/flora. Flora.swift loads them; RockField (Rocks.swift) scatters trees out to 1.1 km in forest and grassland, with groves and clearings, autumn and bare trees on dry land, none on beaches, rock, snow, steep ground, depot pads or the town; bushes and flowers out to 75 m. They sway in the wind, the sun shines through the leaves, and nearby trees cast leaf-shaped shadows.

### Superhero landings

Slamming into the ground leaves cracks (Cracks.swift): a scorched crater with jagged fissures and side branches, glowing molten orange for a second or two, cooling to dark lines and fading after about 20 s. The impact sound is a sharp crack, a body blow, a sub-bass boom, the ground splitting and debris raining down (Audio.heroImpact). Flying as the robot now sounds like air rushing past (Audio.flight), not a hiss.
