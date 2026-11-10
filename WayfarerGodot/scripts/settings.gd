## Player settings: display, graphics and controls. Saved to user://settings.cfg (on Windows that's
## %APPDATA%\Godot\app_userdata\Wayfarer, on a Mac ~/Library/Application Support/Godot/app_userdata/Wayfarer).
class_name GameSettings

const PATH := "user://settings.cfg"
const QUALITY := ["LOW", "MEDIUM", "HIGH", "ULTRA"]
const SCALES := [0.0, 0.5, 0.67, 0.75, 0.85, 1.0]      # 0 = Auto
const FPS_CAPS := [0, 30, 60, 120, 144]

static var fullscreen := true
static var render_scale := 0.0          # 3D resolution relative to the screen; 0 = Auto (a pixel budget that holds the frame rate)
static var auto_k := 1.0                # Auto: lowered while the frame rate is short, raised back when there's headroom
static var applied_scale := 1.0
static var quality := 2                 # index into QUALITY
static var vsync := true
static var fps_cap := 0
static var show_fps := false
static var mouse_sens := 1.0
static var invert_y := false
static var volume := 0.8
static var music := 0.6

static func load_all() -> void:
	var c := ConfigFile.new()
	if c.load(PATH) != OK: return
	fullscreen = c.get_value("display", "fullscreen", fullscreen)
	render_scale = c.get_value("display", "scale", render_scale)
	vsync = c.get_value("display", "vsync", vsync)
	fps_cap = c.get_value("display", "fps_cap", fps_cap)
	show_fps = c.get_value("display", "show_fps", show_fps)
	quality = c.get_value("graphics", "quality", quality)
	mouse_sens = c.get_value("controls", "mouse_sens", mouse_sens)
	invert_y = c.get_value("controls", "invert_y", invert_y)
	volume = c.get_value("sound", "volume", volume)
	music = c.get_value("sound", "music", music)

static func save_all() -> void:
	var c := ConfigFile.new()
	c.set_value("display", "fullscreen", fullscreen)
	c.set_value("display", "scale", render_scale)
	c.set_value("display", "vsync", vsync)
	c.set_value("display", "fps_cap", fps_cap)
	c.set_value("display", "show_fps", show_fps)
	c.set_value("graphics", "quality", quality)
	c.set_value("controls", "mouse_sens", mouse_sens)
	c.set_value("controls", "invert_y", invert_y)
	c.set_value("sound", "volume", volume)
	c.set_value("sound", "music", music)
	c.save(PATH)

## push the display and graphics settings into the engine; the game reads the rest (grass, mouse) itself
static func apply(vp: Viewport, env: Environment, sun: DirectionalLight3D) -> void:
	if OS.get_environment("WAYFARER_SHOT") == "":      # screenshot tests keep their fixed window
		var want := DisplayServer.WINDOW_MODE_FULLSCREEN if fullscreen else DisplayServer.WINDOW_MODE_WINDOWED
		if DisplayServer.window_get_mode() != want:
			DisplayServer.window_set_mode(want)
			if not fullscreen:
				var scr := DisplayServer.screen_get_usable_rect()
				var size := Vector2i(mini(1600, int(scr.size.x * 0.9)), mini(1000, int(scr.size.y * 0.9)))
				DisplayServer.window_set_size(size)
				DisplayServer.window_set_position(scr.position + (scr.size - size) / 2)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if vsync else DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = fps_cap
	apply_scale(vp)
	# graphics quality
	var E := func(k: String) -> bool: return OS.get_environment(k) != ""
	if E.call("WAYFARER_SHOT"):
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)      # tests never steal the keyboard
		if E.call("T_Q"): quality = int(OS.get_environment("T_Q"))
		if E.call("T_SS"): vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR; vp.scaling_3d_scale = float(OS.get_environment("T_SS"))
	vp.msaa_3d = [Viewport.MSAA_DISABLED, Viewport.MSAA_2X, Viewport.MSAA_2X, Viewport.MSAA_2X][quality]
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if quality == 0 else Viewport.SCREEN_SPACE_AA_DISABLED
	RenderingServer.directional_shadow_atlas_set_size([2048, 4096, 4096, 4096][quality], true)
	RenderingServer.directional_soft_shadow_filter_set_quality([RenderingServer.SHADOW_QUALITY_HARD, RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM, RenderingServer.SHADOW_QUALITY_SOFT_HIGH][quality])
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if quality == 0 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	env.ssao_enabled = quality >= 2
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_LOW if quality < 3 else RenderingServer.ENV_SSAO_QUALITY_MEDIUM, true, 0.5, 2, 50, 300)
	RenderingServer.environment_glow_set_use_bicubic_upscale(quality >= 2)
	env.glow_enabled = quality >= 1
	env.sdfgi_enabled = false

## how much grass to scatter at this quality (fraction of the full field)
static func grass_k() -> float:
	return [0.3, 0.55, 0.8, 1.0][quality]

static func test_overrides(vp: Viewport, env: Environment, sun: DirectionalLight3D) -> void:
	var E := func(k: String) -> bool: return OS.get_environment(k) != ""
	if E.call("T_NOMSAA"): vp.msaa_3d = Viewport.MSAA_DISABLED
	if E.call("T_NOSSAO"): env.ssao_enabled = false
	if E.call("T_NOSHADOW"): sun.shadow_enabled = false
	if E.call("T_NOGLOW"): env.glow_enabled = false
	if E.call("T_NOFOG"): env.fog_enabled = false

## the 3D resolution. Auto keeps the drawn pixel count inside a budget for the quality level (a 5K or 6K desktop
## canvas is 4-5 times a 4K screen: drawing it natively is what makes a game crawl) and FSR sharpens the upscale.
static func apply_scale(vp: Viewport) -> void:
	var win := DisplayServer.window_get_size()
	var pixels := float(win.x) * float(win.y)
	var sc := render_scale
	if sc <= 0.0:
		var budget: float = [1.2e6, 1.8e6, 2.5e6, 3.3e6][quality]
		sc = clampf(sqrt(budget / maxf(pixels, 1.0)) * auto_k, 0.3, 1.0)
	applied_scale = sc
	if OS.get_environment("T_SS") != "": return
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR if sc >= 0.999 else Viewport.SCALING_3D_MODE_FSR
	vp.scaling_3d_scale = sc
	vp.fsr_sharpness = 0.3

## Auto resolution: call about once a second with the measured frame rate
static var _good := 0
static func adapt(vp: Viewport, fps: float) -> void:
	if render_scale > 0.0: return
	var target := 60.0 if fps_cap == 0 else minf(60.0, float(fps_cap))
	if fps < target * 0.8 and auto_k > 0.5:
		auto_k = maxf(0.5, auto_k * 0.88); _good = 0; apply_scale(vp)
	elif fps >= target * 0.97:
		_good += 1
		if _good > 12 and auto_k < 1.0: auto_k = minf(1.0, auto_k * 1.06); _good = 6; apply_scale(vp)
	else: _good = 0
