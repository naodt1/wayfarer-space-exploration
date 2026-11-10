## Sound, synthesised like the Mac game's Audio.swift (no sound files): the engine hum that opens with the throttle,
## the afterburner rumble, superhero-flight wind, the jetpack, one-shots (sonic boom, superhero impact, footsteps,
## hatch, beeps, burner light-off) and the ambient music (slow pad chords and soft bells).
## One-shots are rendered once into wave buffers; the continuous sounds are looped noise/tones shaped live by
## volume, pitch and a low-pass filter on their own bus. WAYFARER_MUTE=1 silences everything.
class_name GameAudio
extends Node

const SR := 22050

var shots := {}                       # name -> AudioStreamWAV
var hum: AudioStreamPlayer; var roar: AudioStreamPlayer; var wind: AudioStreamPlayer; var jet: AudioStreamPlayer
var music: AudioStreamPlayer
var hum_lp: AudioEffectLowPassFilter; var wind_lp: AudioEffectLowPassFilter
var pool: Array[AudioStreamPlayer] = []
var t_hum := 0.0; var t_freq := 1.0; var t_cut := 200.0; var t_roar := 0.0; var t_wind := 0.0; var t_wind_f := 300.0; var t_jet := 0.0
var muted := false
var loaded := false

func _ready() -> void:
	muted = OS.get_environment("WAYFARER_MUTE") != ""
	_bus("Engine"); _bus("Wind"); _bus("Music")
	hum_lp = AudioEffectLowPassFilter.new(); AudioServer.add_bus_effect(AudioServer.get_bus_index("Engine"), hum_lp)
	wind_lp = AudioEffectLowPassFilter.new(); AudioServer.add_bus_effect(AudioServer.get_bus_index("Wind"), wind_lp)
	for i in 10:
		var p := AudioStreamPlayer.new(); add_child(p); pool.append(p)
	# build the sounds on a worker thread so the title screen isn't held up
	WorkerThreadPool.add_task(_build)

func _bus(n: String) -> void:
	AudioServer.add_bus(); var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, n); AudioServer.set_bus_send(i, "Master")

func _build() -> void:
	var loops := {
		"hum": _engine_loop(), "brown": _noise_loop(true, 3.0), "white": _noise_loop(false, 3.0),
		"music": _music_loop()}
	var one := {
		"boom": _render(1.6, [["boom", 150, 24, 1.3, 1.0, 0], ["boom", 75, 30, 1.6, 0.7, 0.04], ["boom", 48, 26, 2.6, 0.9, 0.02]]),
		"burner_off": _render(1.0, [["boom", 80, 32, 0.9, 0.35, 0]]),
		"sonic": _render(3.4, [["noise", 0, 7000, 1500, 0.07, 1.0, 0.001, 0], ["boom", 95, 22, 1.4, 1.0, 0], ["noise", 0, 7000, 1500, 0.07, 1.0, 0.001, 0.11],
			["boom", 95, 22, 1.4, 1.0, 0.11], ["brown", 0, 700, 45, 3.2, 0.9, 0.01, 0.05], ["noise", 1, 900, 120, 2.4, 0.25, 0.02, 0.1]]),
		"hatch": _render(0.9, [["noise", 1, 3200, 300, 0.7, 0.28, 0.02, 0], ["sq", 110, 110, 0.18, 0.12, 0.55], ["boom", 90, 40, 0.3, 0.4, 0]]),
		"beep": _render(0.25, [["sine", 660, 660, 0.08, 0.08, 0], ["sine", 990, 990, 0.12, 0.08, 0.1]]),
		"denied": _render(0.35, [["sq", 190, 190, 0.14, 0.08, 0], ["sq", 150, 150, 0.16, 0.08, 0.12]]),
		"step": _render(0.2, [["brown", 0, 640, 80, 0.16, 0.38, 0.004, 0], ["noise", 1, 2200, 900, 0.07, 0.05, 0.003, 0]]),
		"thud": _render(0.45, [["boom", 80, 32, 0.35, 0.7, 0], ["brown", 0, 600, 80, 0.4, 0.5, 0.005, 0]]),
		"lift": _render(2.5, [["brown", 0, 120, 900, 2.5, 0.45, 0.6, 0]]),
		"chime": _render(1.6, [["sine", 880, 880, 0.9, 0.14, 0], ["sine", 1318.5, 1318.5, 1.2, 0.12, 0.2], ["sine", 1760, 1760, 0.6, 0.04, 0.2]]),
		"doors": _render(0.9, [["noise", 1, 2400, 600, 0.7, 0.12, 0.05, 0], ["sine", 220, 180, 0.15, 0.08, 0.6]]),
		"impact": _hero_impact()}
	call_deferred("_built", loops, one)

func _built(loops: Dictionary, one: Dictionary) -> void:
	shots = one
	hum = _loop_player(loops.hum, "Engine"); roar = _loop_player(loops.brown, "Engine")
	wind = _loop_player(loops.brown, "Wind"); jet = _loop_player(loops.white, "Wind")
	music = _loop_player(loops.music, "Music")
	loaded = true
	print("AUDIO ready after %.1f s" % (Time.get_ticks_msec() / 1000.0))

func _loop_player(s: AudioStreamWAV, bus: String) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new(); p.stream = s; p.bus = bus; p.volume_db = -80.0; add_child(p); p.play()
	return p

# ------------------------------------------------------------------ live controls (called every frame)
var pitch := 1.0                       # bigger ships sound deeper
func engine(throttle: float, ab: float, on: bool) -> void:
	t_hum = (0.11 * (0.45 + throttle) * (2.0 - pitch)) if on else 0.0
	t_freq = (38.0 + throttle * 34.0 + ab * 22.0) * pitch / 55.0
	t_cut = (160.0 + throttle * 700.0 + ab * 1400.0) * pitch
	t_roar = ab * 0.22 if on else 0.0
func flight(k: float) -> void: t_wind = k; t_wind_f = 180.0 + 1100.0 * k
func jetpack(level: float) -> void: t_jet = level * 0.22

func _process(dt: float) -> void:
	if not loaded: return
	var master := 0.0 if muted else GameSettings.volume
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Master"), linear_to_db(maxf(master, 0.0001)))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index("Music"), linear_to_db(maxf(GameSettings.music * 0.8, 0.0001)))
	var k := 1.0 - exp(-dt / 0.2)
	hum.volume_db = linear_to_db(maxf(db_to_linear(hum.volume_db) + (t_hum * 3.0 - db_to_linear(hum.volume_db)) * k, 0.0001))
	hum.pitch_scale = lerpf(hum.pitch_scale, maxf(t_freq, 0.3), k * 0.6)
	hum_lp.cutoff_hz = lerpf(hum_lp.cutoff_hz, t_cut, k)
	roar.volume_db = linear_to_db(maxf(db_to_linear(roar.volume_db) + (t_roar * 6.0 - db_to_linear(roar.volume_db)) * k * 1.5, 0.0001))
	roar.pitch_scale = 0.5
	var wl := db_to_linear(wind.volume_db) + (t_wind * 2.2 - db_to_linear(wind.volume_db)) * k
	var gust := 0.8 + 0.2 * sin(Time.get_ticks_msec() * 0.0013) * sin(Time.get_ticks_msec() * 0.0071)
	wind.volume_db = linear_to_db(maxf(wl * gust, 0.0001))
	wind_lp.cutoff_hz = lerpf(wind_lp.cutoff_hz, t_wind_f * 1.5, k)
	jet.volume_db = linear_to_db(maxf(t_jet * 0.5 + t_wind * t_wind * 0.03, 0.0001))

# ------------------------------------------------------------------ one-shots
func play(name: String, vol := 1.0, pitch_s := 1.0) -> void:
	if not shots.has(name): return
	for p in pool:
		if not p.playing:
			p.stream = shots[name]; p.volume_db = linear_to_db(maxf(vol, 0.0001)); p.pitch_scale = pitch_s; p.play(); return

func step(v: float) -> void: play("step", 0.4 + v * 0.6, randf_range(0.9, 1.1))
func hero_impact(k: float) -> void: play("impact", 0.6 + 0.4 * k)
func sonic_boom() -> void: play("sonic")
func burner_on() -> void: play("boom")
func burner_off() -> void: play("burner_off")
func hatch() -> void: play("hatch")
func beep() -> void: play("beep")
func denied() -> void: play("denied")
func thud() -> void: play("thud")
func lift() -> void: play("lift")
func chime() -> void: play("chime")
func doors() -> void: play("doors")

## the lift car's ride: a low electric hum that swells while moving (k 0 … 1)
var lift_hum: AudioStreamPlayer
func lift_ride(k: float) -> void:
	if not loaded: return
	if lift_hum == null:
		lift_hum = AudioStreamPlayer.new(); lift_hum.stream = hum.stream; lift_hum.bus = "Wind"; lift_hum.pitch_scale = 1.6
		lift_hum.volume_db = -80.0; add_child(lift_hum); lift_hum.play()
	lift_hum.volume_db = linear_to_db(maxf(k * 0.25, 0.0001))
	lift_hum.pitch_scale = 1.4 + k * 0.4

## the lift's voice ("Bridge", "Going up"…): res://assets/sounds/<name>.wav, after an optional delay
func voice(name: String, delay := 0.0) -> void:
	var path := "res://assets/sounds/%s.wav" % name
	if not ResourceLoader.exists(path): return
	if delay > 0.0: await get_tree().create_timer(delay).timeout
	var p := AudioStreamPlayer.new(); p.stream = load(path); p.volume_db = -3.0; add_child(p); p.play()
	p.finished.connect(p.queue_free)

# ------------------------------------------------------------------ synthesis
## voices: ["boom", f0, f1, dur, vol, delay] · ["sine"/"sq", f0, f1, dur, vol, delay] · ["noise"/"brown", filter 0 lp 1 bp 2 hp, f0, f1, dur, vol, attack, delay]
func _render(length: float, voices: Array) -> AudioStreamWAV:
	var n := int(length * SR)
	var buf := PackedFloat32Array(); buf.resize(n)
	for v in voices:
		var kind: String = v[0]
		var noise := kind == "noise" or kind == "brown"
		var f0: float = v[2] if noise else v[1]; var f1: float = v[3] if noise else v[2]
		var dur: float = v[4] if noise else v[3]; var vol: float = v[5] if noise else v[4]
		var attack: float = v[6] if noise else (0.002 if kind == "boom" else 0.008)
		var delay: float = v[7] if noise else v[5]
		var filt: int = v[1] if noise else 0
		var ph := 0.0; var br := 0.0
		var bq := Biquad.new()
		var start := int(delay * SR); var m := int(dur * SR)
		for i in m:
			var j := start + i
			if j >= n: break
			var t := float(i) / SR; var tt := t / dur
			var f := f0 * pow(f1 / f0, minf(tt, 1.0))
			var env := vol * t / attack if t < attack else vol * pow(0.0001 / vol, (t - attack) / maxf(dur - attack, 1e-3))
			var x: float
			if noise:
				var wn := randf() * 2.0 - 1.0
				if kind == "brown": br = (br + 0.02 * wn) / 1.02; x = br * 3.5
				else: x = wn
				if i % 32 == 0: bq.set_filter(filt, f, 0.8, SR)
				x = bq.run(x)
			else:
				ph += f / SR; ph -= floor(ph)
				x = (1.0 if ph < 0.5 else -1.0) if kind == "sq" else sin(ph * TAU)
			buf[j] += x * env
	return _wav(buf, false)

func _hero_impact() -> AudioStreamWAV:
	var v := [["noise", 2, 9000, 1800, 0.06, 1.0, 0.0008, 0], ["noise", 1, 2600, 500, 0.18, 0.45, 0.001, 0.005],
		["boom", 140, 38, 0.55, 1.0, 0], ["boom", 95, 30, 0.9, 0.8, 0.01], ["boom", 52, 18, 3.4, 0.9, 0.03],
		["brown", 0, 500, 35, 4.5, 0.75, 0.01, 0.06]]
	for i in 12: v.append(["noise", 1, randf_range(1400, 3800), randf_range(500, 900), 0.05, 0.22, 0.001, 0.05 + i * 0.07 + randf() * 0.05])
	for i in 26: v.append(["brown", 1, randf_range(900, 2400), 400, 0.04, randf_range(0.05, 0.14), 0.001, randf_range(0.45, 1.9)])
	return _render(4.8, v)

func _noise_loop(brown: bool, secs: float) -> AudioStreamWAV:
	var n := int(secs * SR); var buf := PackedFloat32Array(); buf.resize(n); var b := 0.0
	for i in n:
		var wn := randf() * 2.0 - 1.0
		if brown: b = (b + 0.02 * wn) / 1.02; buf[i] = b * 3.5
		else: buf[i] = wn * 0.5
	# crossfade the ends so the loop has no click
	var fade := int(0.05 * SR)
	for i in fade: var a := float(i) / fade; buf[i] = buf[i] * a + buf[n - fade + i] * (1.0 - a)
	return _wav(buf.slice(0, n - fade), true)

## the engine: two detuned saws and a sub sine at 55 Hz (pitched live), plus a brown rumble
func _engine_loop() -> AudioStreamWAV:
	var n := SR * 2; var buf := PackedFloat32Array(); buf.resize(n)
	var p1 := 0.0; var p2 := 0.0; var p3 := 0.0; var b := 0.0
	var f := 55.0
	for i in n:
		p1 += f / SR; p2 += f * 1.0137 / SR; p3 += f * 0.5 / SR
		p1 -= floor(p1); p2 -= floor(p2); p3 -= floor(p3)
		b = (b + 0.02 * (randf() * 2.0 - 1.0)) / 1.02
		buf[i] = ((p1 * 2.0 - 1.0) + (p2 * 2.0 - 1.0)) * 0.35 + sin(p3 * TAU) * 0.35 + b * 2.0
	return _wav(buf, true)

## ambient music: six slow pad chords, 11 s each, and soft bells with the odd echo
func _music_loop() -> AudioStreamWAV:
	var chords := [[45, 52, 60, 64], [41, 48, 57, 64], [48, 55, 59, 64], [43, 50, 59, 62], [45, 52, 59, 64], [41, 53, 57, 60]]
	var bells := [69, 72, 74, 76, 79, 81, 84, 86]
	var sr := 16000
	var n := sr * 66; var buf := PackedFloat32Array(); buf.resize(n)
	var hz := func(m: float) -> float: return 440.0 * pow(2.0, (m - 69.0) / 12.0)
	var fr := [0.0, 0.0, 0.0, 0.0]; var ph := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	for j in 4: fr[j] = hz.call(chords[0][j])
	var lp1 := Biquad.new(); lp1.set_filter(0, 1100, 0.6, sr); var lp2 := Biquad.new(); lp2.set_filter(0, 1100, 0.6, sr)
	for i in n:
		var t := float(i) / sr
		var ci := int(t / 11.0) % 6
		var pad := 0.0
		for j in 4:
			fr[j] += (hz.call(chords[ci][j]) - fr[j]) * (0.6 / sr)
			ph[j] = fmod(ph[j] + fr[j] / sr, 1.0); ph[j + 4] = fmod(ph[j + 4] + fr[j] * 1.004 / sr, 1.0)
			var swell := 0.75 + 0.25 * sin(t * (0.11 + j * 0.037) + j * 1.7)
			pad += (sin(ph[j] * TAU) + sin(ph[j + 4] * TAU) * 0.8 + sin(ph[j] * 2.0 * TAU) * 0.18) * swell
		buf[i] = lp2.run(lp1.run(pad)) * 0.028 * 6.0
	# bells
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	var bt := 2.0
	while bt < 62.0:
		var f: float = hz.call(bells[rng.randi() % bells.size()])
		for echo in (2 if rng.randf() < 0.5 else 1):
			var st := int((bt + echo * 0.38) * sr); var vol := 0.035 * 6.0 * (0.45 if echo == 1 else 1.0)
			for i in int(4.5 * sr):
				if st + i >= n: break
				var tt := float(i) / sr
				buf[st + i] += sin(tt * f * TAU) * vol * pow(0.0001 / vol, tt / 4.5) * minf(1.0, tt / 0.01)
		bt += rng.randf_range(1.8, 5.5)
	var w := _wav(buf, true); w.mix_rate = sr
	return w

func _wav(buf: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray(); bytes.resize(buf.size() * 2)
	for i in buf.size():
		bytes.encode_s16(i * 2, int(clampf(tanh(buf[i] * 0.9), -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new(); w.format = AudioStreamWAV.FORMAT_16_BITS; w.mix_rate = SR; w.stereo = false; w.data = bytes
	if loop: w.loop_mode = AudioStreamWAV.LOOP_FORWARD; w.loop_end = buf.size()
	return w

class Biquad:
	var b0 := 1.0; var b1 := 0.0; var b2 := 0.0; var a1 := 0.0; var a2 := 0.0; var z1 := 0.0; var z2 := 0.0
	func set_filter(type: int, f: float, q: float, sr: float) -> void:
		var w := TAU * clampf(f, 10.0, sr * 0.45) / sr; var cs := cos(w); var sn := sin(w); var alpha := sn / (2.0 * q)
		var nb0: float; var nb1: float; var nb2: float
		match type:
			1: nb0 = alpha; nb1 = 0.0; nb2 = -alpha
			2: nb0 = (1.0 + cs) / 2.0; nb1 = -(1.0 + cs); nb2 = (1.0 + cs) / 2.0
			_: nb0 = (1.0 - cs) / 2.0; nb1 = 1.0 - cs; nb2 = (1.0 - cs) / 2.0
		var a0 := 1.0 + alpha
		b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0; a1 = -2.0 * cs / a0; a2 = (1.0 - alpha) / a0
	func run(x: float) -> float:
		var y := b0 * x + z1; z1 = b1 * x - a1 * y + z2; z2 = b2 * x - a2 * y; return y
