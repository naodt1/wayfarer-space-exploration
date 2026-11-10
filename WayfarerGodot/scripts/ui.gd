## The interface, built in code to match the Mac game's SwiftUI HUD (WayfarerMac/Sources/Wayfarer/main.swift):
## the title screen (wordmark, live ship, picker, LAUNCH), the flight readout (planet, ship, altitude, speed, throttle,
## fuel, hints, messages), the pause menu (Resume · Ship ‹ › · Settings · Main menu), settings and controls panels.
## Menus work with the keyboard (↑ ↓ select, ← → change, Enter confirm, Esc back) and with the mouse.
class_name GameUI
extends CanvasLayer

signal launch
signal change_ship(delta: int)          # title screen picker
signal pick_ship(index: int)            # pause menu: switch to this ship
signal resume
signal main_menu
signal quit_game
signal settings_changed

const ACCENT := Color(0.62, 0.83, 1.0)
const INK := Color(0.02, 0.07, 0.12)
const FUEL := Color(0.4, 0.95, 0.95)
const WARN := Color(1.0, 0.45, 0.3)
const ORANGE := Color(1.0, 0.7, 0.3)

var font_light: SystemFont
var font_reg: SystemFont
var font_semi: SystemFont
var title_root: Control
var pause_root: Control
var controls_root: Control
var hud_root: Control
var settings_root: Control

# title
var t_name: Label; var t_role: Label; var t_dots: HBoxContainer; var t_stats: HBoxContainer; var t_tags: HBoxContainer
# flight readout
var h_planet: Label; var h_ship: Label; var h_alt: Label; var h_speed: Label
var h_ab: Label; var h_thr: ColorRect; var h_fuel: ColorRect; var h_fuel_pct: Label; var h_fps: Label; var h_hint: Label
var h_warn: Label; var h_reticle: Control
var message: Label; var message_t := 0.0
# pause menu
var menu_sel := 0
var menu_ship := 0
var cur_ship := 0
var roster: Array = []
var p_rows: Array[PanelContainer] = []
var p_ship_name: Label; var p_ship_role: Label; var p_ship_hint: Label; var p_dots: HBoxContainer
# settings
var set_sel := 0
var s_rows: Array[PanelContainer] = []
var s_vals: Array[Label] = []
var s_arrows: Array = []

func _init() -> void:
	# the Mac app's system font (SF Pro), Segoe UI on Windows; rendered as a distance field so it stays sharp at any
	# window size, with subpixel positioning like the system text
	var fam := ["SF Pro Display", "SF Pro Text", ".AppleSystemUIFont", "Helvetica Neue", "Segoe UI Variable Display", "Segoe UI", "Arial"]
	font_light = _sys(fam, 250); font_reg = _sys(fam, 400); font_semi = _sys(fam, 600)
	_build_title(); _build_hud(); _build_pause(); _build_settings(); _build_controls()
	message = _label("", 15, Color.WHITE, font_semi, 3)
	message.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP); message.offset_top = 180
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; message.grow_horizontal = Control.GROW_DIRECTION_BOTH
	message.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5)); message.add_theme_constant_override("shadow_outline_size", 2)
	add_child(message)

# ------------------------------------------------------------------ helpers
func _sys(fam: Array, weight: int) -> SystemFont:
	var f := SystemFont.new(); f.font_names = PackedStringArray(fam); f.font_weight = weight
	f.oversampling = 2.0
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO; f.hinting = TextServer.HINTING_LIGHT
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	return f

func _label(text: String, size: int, color: Color, font: Font = null, spacing := 0) -> Label:
	var l := Label.new(); l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	var fv := FontVariation.new(); fv.base_font = font if font != null else font_reg; fv.spacing_glyph = spacing
	l.add_theme_font_override("font", fv)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.28))
	l.add_theme_constant_override("shadow_offset_x", 0); l.add_theme_constant_override("shadow_offset_y", 1)
	l.add_theme_constant_override("shadow_outline_size", 0)
	return l

func _box(bg: Color, radius: int, border := Color(0, 0, 0, 0), bw := 0, mx := 20, my := 12) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new(); sb.bg_color = bg
	sb.set_corner_radius_all(radius); sb.border_color = border; sb.set_border_width_all(bw)
	sb.content_margin_left = mx; sb.content_margin_right = mx; sb.content_margin_top = my; sb.content_margin_bottom = my
	sb.anti_aliasing = true
	return sb

func _bar(w: float, h: float, col: Color) -> Array:
	var holder := Control.new(); holder.custom_minimum_size = Vector2(w, h); holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bg := Panel.new(); bg.size = Vector2(w, h); bg.add_theme_stylebox_override("panel", _box(Color(1, 1, 1, 0.18), 2, Color(0, 0, 0, 0), 0, 0, 0))
	var fg := ColorRect.new(); fg.color = col; fg.size = Vector2(w * 0.5, h)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE; fg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(bg); holder.add_child(fg)
	return [holder, fg]

func _vignette(top: bool, h: float, a: float) -> TextureRect:
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, a if top else 0.0)); g.set_color(1, Color(0, 0, 0, 0.0 if top else a))
	var gt := GradientTexture2D.new(); gt.gradient = g; gt.fill_from = Vector2(0, 0); gt.fill_to = Vector2(0, 1); gt.width = 4; gt.height = 64
	var tr := TextureRect.new(); tr.texture = gt; tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if top: tr.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE); tr.offset_bottom = h
	else: tr.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE); tr.offset_top = -h
	return tr

func _keycap(k: String, what: String) -> HBoxContainer:
	var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", 6); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cap := PanelContainer.new(); cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0), 4, Color(1, 1, 1, 0.35), 1, 6, 1))
	cap.add_child(_label(k, 10, Color(1, 1, 1, 0.9), font_semi))
	hb.add_child(cap); hb.add_child(_label(what, 11, Color(1, 1, 1, 0.6)))
	return hb

func _dim() -> ColorRect:
	var d := ColorRect.new(); d.color = Color(0, 0, 0, 0.55); d.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return d

func _centered_panel(parent: Control, width: float, pad := 30) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0.6), 20, Color(0, 0, 0, 0), 0, pad, pad))
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER); panel.grow_horizontal = Control.GROW_DIRECTION_BOTH; panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	parent.add_child(panel)
	var vb := VBoxContainer.new(); vb.custom_minimum_size = Vector2(width, 0); vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)
	return vb

# ------------------------------------------------------------------ title screen
func _build_title() -> void:
	title_root = Control.new(); title_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	title_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title_root)
	title_root.add_child(_vignette(true, 240, 0.55)); title_root.add_child(_vignette(false, 300, 0.7))
	var mark := VBoxContainer.new(); mark.position = Vector2(48, 40); mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.add_theme_constant_override("separation", 8)
	mark.add_child(_label("WAYFARER", 40, Color.WHITE, font_light, 16))
	mark.add_child(_label("A quiet solar system, generated as you fly · land anywhere", 13, Color(1, 1, 1, 0.6)))
	title_root.add_child(mark)
	var col := VBoxContainer.new(); col.alignment = BoxContainer.ALIGNMENT_END
	col.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM); col.grow_horizontal = Control.GROW_DIRECTION_BOTH; col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	col.offset_bottom = -56; col.add_theme_constant_override("separation", 18)
	title_root.add_child(col)
	var row := HBoxContainer.new(); row.alignment = BoxContainer.ALIGNMENT_CENTER; row.add_theme_constant_override("separation", 28)
	var mid := VBoxContainer.new(); mid.custom_minimum_size = Vector2(320, 0); mid.add_theme_constant_override("separation", 6)
	t_name = _label("KESTREL", 34, Color.WHITE, font_semi, 10); t_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t_role = _label("", 12, ACCENT, font_semi, 3); t_role.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	t_dots = HBoxContainer.new(); t_dots.alignment = BoxContainer.ALIGNMENT_CENTER; t_dots.add_theme_constant_override("separation", 6)
	mid.add_child(t_name); mid.add_child(t_role); mid.add_child(t_dots)
	row.add_child(_arrow("‹", -1)); row.add_child(mid); row.add_child(_arrow("›", 1))
	col.add_child(row)
	t_stats = HBoxContainer.new(); t_stats.alignment = BoxContainer.ALIGNMENT_CENTER; t_stats.add_theme_constant_override("separation", 26)
	col.add_child(t_stats)
	t_tags = HBoxContainer.new(); t_tags.alignment = BoxContainer.ALIGNMENT_CENTER; t_tags.add_theme_constant_override("separation", 8)
	col.add_child(t_tags)
	var go := Button.new(); go.text = "LAUNCH"; go.focus_mode = Control.FOCUS_NONE
	go.add_theme_font_size_override("font_size", 14)
	var fv := FontVariation.new(); fv.base_font = font_semi; fv.spacing_glyph = 5; go.add_theme_font_override("font", fv)
	go.add_theme_stylebox_override("normal", _box(ACCENT, 30, Color(0, 0, 0, 0), 0, 34, 13))
	go.add_theme_stylebox_override("hover", _box(ACCENT.lightened(0.15), 30, Color(0, 0, 0, 0), 0, 34, 13))
	go.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.1), 30, Color(0, 0, 0, 0), 0, 34, 13))
	for k in ["font_color", "font_hover_color", "font_pressed_color"]: go.add_theme_color_override(k, INK)
	go.pressed.connect(func(): launch.emit())
	var chip := PanelContainer.new(); chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0.15), 5, Color(0, 0, 0, 0), 0, 6, 3))
	var cl := _label("ENTER", 9, INK, font_semi, 1); cl.remove_theme_color_override("font_shadow_color"); chip.add_child(cl)
	go.add_child(chip); chip.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT); chip.offset_left = -70; chip.offset_right = -22
	go.custom_minimum_size = Vector2(240, 0)
	go.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var gc := CenterContainer.new(); gc.add_child(go); col.add_child(gc)
	var hints := HBoxContainer.new(); hints.add_theme_constant_override("separation", 18)
	hints.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT); hints.offset_left = 48; hints.offset_bottom = -26; hints.offset_top = -48
	hints.add_child(_keycap("← →", "ship")); hints.add_child(_keycap("K", "controls")); hints.add_child(_keycap(",", "settings")); hints.add_child(_keycap("ESC", "quit"))
	title_root.add_child(hints)
	var drag := _label("DRAG TO LOOK AROUND", 10, Color(1, 1, 1, 0.4), font_reg, 3)
	drag.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT); drag.offset_right = -48; drag.offset_bottom = -28; drag.offset_left = -300; drag.offset_top = -46
	drag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	title_root.add_child(drag)

func _arrow(t: String, d: int) -> Button:
	var b := Button.new(); b.text = t; b.flat = true; b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 40); b.add_theme_font_override("font", font_light)
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.7)); b.add_theme_color_override("font_hover_color", ACCENT)
	b.pressed.connect(func(): change_ship.emit(d))
	return b

func _dots(box: HBoxContainer, index: int, count: int, wide: float, narrow: float) -> void:
	for c in box.get_children(): c.queue_free()
	for i in count:
		var d := Panel.new(); d.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.add_theme_stylebox_override("panel", _box(ACCENT if i == index else Color(1, 1, 1, 0.25), 2, Color(0, 0, 0, 0), 0, 0, 0))
		d.custom_minimum_size = Vector2(wide if i == index else narrow, 4)
		box.add_child(d)

static func size_text(spec: Dictionary) -> String:
	var sz: float = spec["size_m"]
	return ("%.1f km" % (sz / 1000.0)) if sz >= 1000.0 else ("%d m" % int(sz))

func show_ship(spec: Dictionary, index: int, count: int) -> void:
	t_name.text = String(spec["name"]).to_upper()
	t_role.text = "%s · %s" % [spec["role"], size_text(spec)]
	_dots(t_dots, index, count, 22, 8)
	for c in t_stats.get_children(): c.queue_free()
	for st in spec["stats"]:
		var vb := VBoxContainer.new(); vb.add_theme_constant_override("separation", 5); vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		vb.add_child(_label(st[0], 9, Color(1, 1, 1, 0.5), font_semi, 2))
		var b := _bar(90, 3, ACCENT); (b[1] as ColorRect).size.x = 90.0 * float(st[1])
		vb.add_child(b[0]); t_stats.add_child(vb)
	for c in t_tags.get_children(): c.queue_free()
	for tg in spec["tags"]:
		var pc := PanelContainer.new(); pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pc.add_theme_stylebox_override("panel", _box(Color(1, 1, 1, 0.08), 12, Color(0, 0, 0, 0), 0, 8, 4))
		pc.add_child(_label(String(tg).to_upper(), 9, Color(1, 1, 1, 0.75), font_semi, 1))
		t_tags.add_child(pc)

# ------------------------------------------------------------------ flight readout
func _build_hud() -> void:
	hud_root = Control.new(); hud_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); hud_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud_root)
	# top left: planet, ship, altitude, speed
	var tl := VBoxContainer.new(); tl.position = Vector2(24, 24); tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tl.add_theme_constant_override("separation", 4)
	h_planet = _label("EARTH", 24, Color.WHITE, font_semi, 3)
	h_ship = _label("KESTREL · STRIKE FIGHTER", 11, Color(1, 1, 1, 0.6))
	h_alt = _label("", 13, Color.WHITE); h_speed = _label("", 13, Color.WHITE)
	tl.add_child(h_planet); tl.add_child(h_ship); tl.add_child(h_alt); tl.add_child(h_speed)
	hud_root.add_child(tl)
	# bottom left: afterburner, throttle and fuel bars
	var bl := VBoxContainer.new(); bl.mouse_filter = Control.MOUSE_FILTER_IGNORE; bl.add_theme_constant_override("separation", 8)
	bl.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT); bl.offset_left = 24; bl.offset_bottom = -24; bl.grow_vertical = Control.GROW_DIRECTION_BEGIN
	h_ab = _label("AFTERBURNER", 13, ORANGE, font_semi, 4)
	h_ab.add_theme_color_override("font_shadow_color", Color(1, 0.5, 0.1, 0.5)); h_ab.add_theme_constant_override("shadow_outline_size", 3)
	bl.add_child(h_ab)
	bl.add_child(_label("THROTTLE", 10, Color(1, 1, 1, 0.55), font_reg, 2))
	var tb := _bar(180, 4, ACCENT); h_thr = tb[1]; bl.add_child(tb[0])
	var fr := HBoxContainer.new(); fr.add_theme_constant_override("separation", 8); fr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	fr.add_child(_label("FUEL", 10, Color(1, 1, 1, 0.55), font_reg, 2))
	h_fuel_pct = _label("100%", 10, FUEL); fr.add_child(h_fuel_pct)
	var sp := Control.new(); sp.custom_minimum_size = Vector2(0, 4); bl.add_child(sp)
	bl.add_child(fr)
	var fb := _bar(180, 4, FUEL); h_fuel = fb[1]; bl.add_child(fb[0])
	hud_root.add_child(bl)
	# bottom centre: the hint line
	h_hint = _label("", 12, ACCENT, font_reg, 2)
	h_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM); h_hint.offset_top = -48; h_hint.offset_bottom = -30
	h_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH; h_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(h_hint)
	# top right: the menu chip
	var chip := PanelContainer.new(); chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.add_theme_stylebox_override("panel", _box(Color(0, 0, 0, 0.3), 6, Color(0, 0, 0, 0), 0, 10, 5))
	chip.add_child(_label("ESC  MENU · CHANGE SHIP", 10, Color(1, 1, 1, 0.55), font_semi, 2))
	chip.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT); chip.offset_right = -20; chip.offset_top = 20; chip.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	hud_root.add_child(chip)
	# bottom right: frame rate
	h_fps = _label("", 11, Color(1, 1, 1, 0.6))
	h_fps.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT); h_fps.offset_right = -24; h_fps.offset_bottom = -24; h_fps.offset_left = -160; h_fps.offset_top = -44
	h_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	hud_root.add_child(h_fps)
	# fuel warning, top centre
	h_warn = _label("", 15, Color(1, 0.35, 0.25), font_semi, 4)
	h_warn.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP); h_warn.offset_top = 110
	h_warn.grow_horizontal = Control.GROW_DIRECTION_BOTH; h_warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hud_root.add_child(h_warn)
	# the reticle
	h_reticle = Control.new(); h_reticle.set_anchors_and_offsets_preset(Control.PRESET_CENTER); h_reticle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h_reticle.draw.connect(func(): h_reticle.draw_arc(Vector2.ZERO, 9.0, 0.0, TAU, 40, Color(1, 1, 1, 0.35), 1.0, true))
	hud_root.add_child(h_reticle)

## planet, ship line ("KESTREL · STRIKE FIGHTER" or "ON FOOT"), altitude and speed text, throttle 0-1, afterburner 0-1, fuel 0-1
func update_hud(planet: String, ship_line: String, alt: String, speed: String, throttle: float, ab: float, fuel: float, hint: String, on_foot: bool, warn := "") -> void:
	h_planet.text = planet.to_upper()
	h_ship.text = ship_line
	h_alt.text = "altitude " + alt; h_speed.text = "speed " + speed
	h_thr.size.x = 180.0 * clampf(throttle, 0.0, 1.0)
	h_thr.color = ACCENT.lerp(Color(1.0, 0.55, 0.35), clampf(ab * 2.0, 0.0, 1.0))
	h_ab.visible = ab > 0.05; h_ab.modulate.a = ab
	var fc := WARN if fuel < 0.2 else FUEL
	h_fuel.size.x = 180.0 * clampf(fuel, 0.0, 1.0); h_fuel.color = fc
	h_fuel_pct.text = "%d%%" % int(round(fuel * 100.0)); h_fuel_pct.add_theme_color_override("font_color", fc)
	h_hint.text = hint.to_upper()
	h_fps.text = "%d fps" % Engine.get_frames_per_second() if GameSettings.show_fps else ""
	h_reticle.visible = not on_foot
	h_warn.text = warn
	h_warn.modulate.a = (1.0 if int(Time.get_ticks_msec() / 500) % 2 == 0 else 0.35) if fuel <= 0.0 else 0.9

var marks_root: Control
## world markers: [{pos, text, edge, auto}]
func update_marks(list: Array) -> void:
	if marks_root == null:
		marks_root = Control.new(); marks_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT); marks_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud_root.add_child(marks_root)
		marks_root.draw.connect(_draw_marks)
	marks_root.set_meta("list", list)
	marks_root.queue_redraw()

func _draw_marks() -> void:
	var list: Array = marks_root.get_meta("list", [])
	var f := font_semi
	for m in list:
		var p: Vector2 = m.pos
		var col := ACCENT if m.auto else Color(1, 1, 1, 0.6 if m.edge else 0.9)
		marks_root.draw_arc(p, 7.0, 0.0, TAU, 32, col, 1.5, true)
		if m.edge: marks_root.draw_circle(p, 3.0, col)
		var t: String = m.text
		var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		marks_root.draw_string(f, p + Vector2(-w * 0.5 + 1, 23), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0, 0, 0, 0.6))
		marks_root.draw_string(f, p + Vector2(-w * 0.5, 22), t, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)

func say(text: String) -> void:
	message.text = text.to_upper(); message_t = 2.6

func _process(dt: float) -> void:
	message_t -= dt
	message.modulate.a = clampf(message_t / 0.6, 0.0, 1.0) if message_t < 0.6 else 1.0

# ------------------------------------------------------------------ pause menu
func _build_pause() -> void:
	pause_root = Control.new(); pause_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(pause_root)
	pause_root.add_child(_dim())
	var vb := _centered_panel(pause_root, 380)
	var t := _label("PAUSED", 30, Color.WHITE, font_light, 14); vb.add_child(t)
	var sp := Control.new(); sp.custom_minimum_size = Vector2(0, 4); vb.add_child(sp)
	# 0 resume
	vb.add_child(_menu_row(0, _row_text("RESUME", "ESC")))
	# 1 ship
	var ship := VBoxContainer.new(); ship.add_theme_constant_override("separation", 4); ship.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ship.add_child(_label("SHIP", 10, Color(1, 1, 1, 0.5), font_reg, 3))
	var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", 12); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(_label("‹", 22, Color(1, 1, 1, 0.6), font_light))
	p_ship_name = _label("KESTREL", 18, Color.WHITE, font_semi, 4); hb.add_child(p_ship_name)
	hb.add_child(_label("›", 22, Color(1, 1, 1, 0.6), font_light))
	var fill := Control.new(); fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL; fill.mouse_filter = Control.MOUSE_FILTER_IGNORE; hb.add_child(fill)
	p_dots = HBoxContainer.new(); p_dots.add_theme_constant_override("separation", 5); p_dots.alignment = BoxContainer.ALIGNMENT_CENTER; hb.add_child(p_dots)
	ship.add_child(hb)
	p_ship_role = _label("", 11, ACCENT); ship.add_child(p_ship_role)
	p_ship_hint = _label("", 10, Color(1, 1, 1, 0.45)); ship.add_child(p_ship_hint)
	vb.add_child(_menu_row(1, ship))
	vb.add_child(_menu_row(2, _row_text("SETTINGS", "sound · mouse · graphics")))
	vb.add_child(_menu_row(3, _row_text("MAIN MENU", "restart from orbit")))
	vb.add_child(_menu_row(4, _row_text("QUIT GAME", "")))
	var h := _label("↑ ↓ SELECT · ENTER CONFIRM · ESC RESUME", 10, Color(1, 1, 1, 0.45), font_reg, 2)
	var sp2 := Control.new(); sp2.custom_minimum_size = Vector2(0, 2); vb.add_child(sp2)
	vb.add_child(h)
	pause_root.visible = false

func _row_text(a: String, b: String) -> HBoxContainer:
	var hb := HBoxContainer.new(); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(a, 14, Color.WHITE, font_semi, 4); l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(l); hb.add_child(_label(b, 10, Color(1, 1, 1, 0.5)))
	return hb

func _menu_row(i: int, content: Control) -> PanelContainer:
	var pc := PanelContainer.new(); pc.custom_minimum_size = Vector2(380, 0)
	pc.add_child(content)
	pc.mouse_entered.connect(func(): menu_sel = i; _refresh_pause())
	pc.gui_input.connect(func(ev):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			menu_sel = i
			if i == 1:   # click the left or right half to pick the ship, a double click switches
				menu_step(-1 if ev.position.x < pc.size.x * 0.5 else 1)
			else: menu_confirm())
	p_rows.append(pc)
	return pc

func _refresh_pause() -> void:
	for i in p_rows.size():
		var on := i == menu_sel
		p_rows[i].add_theme_stylebox_override("panel", _box(Color(ACCENT, 0.22) if on else Color(1, 1, 1, 0.05), 12, ACCENT if on else Color(0, 0, 0, 0), 2 if on else 0, 20, 12))
	if roster.is_empty(): return
	var sp: Dictionary = roster[menu_ship]
	p_ship_name.text = String(sp["name"]).to_upper()
	p_ship_role.text = "%s · %s" % [sp["role"], size_text(sp)]
	var same := menu_ship == cur_ship
	p_ship_hint.text = "current ship · ← → to choose another" if same else "ENTER to switch here · ← → to choose"
	p_ship_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.45 if same else 0.85))
	_dots(p_dots, menu_ship, roster.size(), 14, 6)

func open_pause(ships: Array, current: int) -> void:
	roster = ships; cur_ship = current; menu_ship = current; menu_sel = 0
	pause_root.visible = true; settings_root.visible = false; controls_root.visible = false
	_refresh_pause()

func close_pause() -> void:
	pause_root.visible = false; controls_root.visible = false; settings_root.visible = false

func menu_move(d: int) -> void:
	menu_sel = (menu_sel + d + p_rows.size()) % p_rows.size(); _refresh_pause()

func menu_step(d: int) -> void:
	if menu_sel != 1: menu_sel = 1
	menu_ship = (menu_ship + d + roster.size()) % roster.size(); _refresh_pause()

func menu_confirm() -> void:
	match menu_sel:
		0: resume.emit()
		1:
			if menu_ship != cur_ship: pick_ship.emit(menu_ship)
			resume.emit()
		2: open_settings()
		3: main_menu.emit()
		4: quit_game.emit()

# ------------------------------------------------------------------ settings panel (same rows as the Mac, plus PC display options)
const S_ROWS := ["Sound volume", "Music volume", "Mouse sensitivity", "Invert mouse Y", "Graphics quality", "Show frame rate", "Full screen",
	"Resolution", "VSync", "Frame limit"]

func _build_settings() -> void:
	settings_root = Control.new(); settings_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(settings_root)
	settings_root.add_child(_dim())
	var vb := _centered_panel(settings_root, 500, 32)
	vb.add_theme_constant_override("separation", 8)
	var t := _label("SETTINGS", 26, Color.WHITE, font_light, 12); vb.add_child(t)
	var sp := Control.new(); sp.custom_minimum_size = Vector2(0, 8); vb.add_child(sp)
	for i in S_ROWS.size():
		var pc := PanelContainer.new()
		var hb := HBoxContainer.new(); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE; hb.add_theme_constant_override("separation", 8)
		var n := _label(S_ROWS[i], 14, Color.WHITE); n.size_flags_horizontal = Control.SIZE_EXPAND_FILL; hb.add_child(n)
		var la := _label("‹", 14, Color(1, 1, 1, 0.2)); hb.add_child(la)
		var v := _label("", 13, Color(1, 1, 1, 0.8), font_semi); v.custom_minimum_size = Vector2(200, 0); v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; hb.add_child(v)
		var ra := _label("›", 14, Color(1, 1, 1, 0.2)); hb.add_child(ra)
		pc.add_child(hb)
		var idx := i
		pc.mouse_entered.connect(func(): set_sel = idx; _refresh_settings())
		pc.gui_input.connect(func(ev):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				set_sel = idx; cycle_setting(idx, -1 if ev.position.x < pc.size.x * 0.6 else 1))
		vb.add_child(pc); s_rows.append(pc); s_vals.append(v); s_arrows.append([la, ra])
	var keys := HBoxContainer.new(); keys.add_theme_constant_override("separation", 16); keys.mouse_filter = Control.MOUSE_FILTER_IGNORE
	keys.add_child(_keycap("↑ ↓", "select")); keys.add_child(_keycap("← →", "change")); keys.add_child(_keycap("ESC", "done"))
	var sp2 := Control.new(); sp2.custom_minimum_size = Vector2(0, 6); vb.add_child(sp2)
	vb.add_child(keys)
	vb.add_child(_label("Saved automatically.", 10, Color(1, 1, 1, 0.35)))
	vb.add_child(_label("Models by Jungle Jim, xaxary, Oscar Creativo · CC BY 4.0 · Sketchfab", 10, Color(1, 1, 1, 0.35)))
	settings_root.visible = false

func _refresh_settings() -> void:
	var pct := func(v: float) -> String: return "%d%%" % int(round(v * 100.0))
	var vals := [pct.call(GameSettings.volume), pct.call(GameSettings.music), "%.2f×" % GameSettings.mouse_sens,
		"On" if GameSettings.invert_y else "Off", ["Performance", "Balanced", "High", "Maximum"][GameSettings.quality],
		"On" if GameSettings.show_fps else "Off", "On" if GameSettings.fullscreen else "Off",
		("Auto · %d%%" % int(round(GameSettings.applied_scale * 100.0))) if GameSettings.render_scale <= 0.0 else "%d%%%s" % [int(round(GameSettings.render_scale * 100.0)), " (native)" if GameSettings.render_scale >= 0.999 else ""],
		"On" if GameSettings.vsync else "Off", "Off" if GameSettings.fps_cap == 0 else "%d fps" % GameSettings.fps_cap]
	for i in s_rows.size():
		var on := i == set_sel
		s_rows[i].add_theme_stylebox_override("panel", _box(Color(ACCENT, 0.18) if on else Color(1, 1, 1, 0.04), 10, Color(ACCENT, 0.8) if on else Color(0, 0, 0, 0), 1 if on else 0, 18, 10))
		s_vals[i].text = vals[i]
		s_vals[i].add_theme_color_override("font_color", ACCENT if on else Color(1, 1, 1, 0.8))
		for a in s_arrows[i]: (a as Label).add_theme_color_override("font_color", Color(1, 1, 1, 0.7 if on else 0.2))

## step one row left (-1) or right (+1), save, and tell the game
func cycle_setting(row: int, d: int) -> void:
	match row:
		0: GameSettings.volume = clampf(GameSettings.volume + 0.1 * d, 0.0, 1.0)
		1: GameSettings.music = clampf(GameSettings.music + 0.1 * d, 0.0, 1.0)
		2: GameSettings.mouse_sens = clampf(GameSettings.mouse_sens + 0.25 * d, 0.25, 3.0)
		3: GameSettings.invert_y = not GameSettings.invert_y
		4: GameSettings.quality = (GameSettings.quality + d + 4) % 4
		5: GameSettings.show_fps = not GameSettings.show_fps
		6: GameSettings.fullscreen = not GameSettings.fullscreen
		7:
			var i := GameSettings.SCALES.find(GameSettings.render_scale)
			if i < 0: i = GameSettings.SCALES.size() - 1
			GameSettings.render_scale = GameSettings.SCALES[clampi(i + d, 0, GameSettings.SCALES.size() - 1)]
		8: GameSettings.vsync = not GameSettings.vsync
		9:
			var i := GameSettings.FPS_CAPS.find(GameSettings.fps_cap)
			GameSettings.fps_cap = GameSettings.FPS_CAPS[(maxi(i, 0) + d + GameSettings.FPS_CAPS.size()) % GameSettings.FPS_CAPS.size()]
	GameSettings.save_all()
	_refresh_settings()
	settings_changed.emit()

func open_settings() -> void:
	set_sel = 0; _refresh_settings(); settings_root.visible = true

func close_settings() -> void:
	settings_root.visible = false

func settings_move(d: int) -> void:
	set_sel = (set_sel + d + s_rows.size()) % s_rows.size(); _refresh_settings()

# ------------------------------------------------------------------ controls panel (K)
func _build_controls() -> void:
	controls_root = Control.new(); controls_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	controls_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(controls_root)
	var d := _dim(); d.mouse_filter = Control.MOUSE_FILTER_IGNORE; controls_root.add_child(d)
	var vb := _centered_panel(controls_root, 0, 32)
	vb.add_theme_constant_override("separation", 18)
	var head := HBoxContainer.new(); head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var t := _label("CONTROLS", 22, Color.WHITE, font_light, 10); t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t); head.add_child(_keycap("K", "close"))
	vb.add_child(head)
	var cols := HBoxContainer.new(); cols.add_theme_constant_override("separation", 36); cols.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(cols)
	var groups := [
		["FLIGHT", [["Mouse", "steer · click to capture"], ["W / S", "throttle"], ["A / D", "roll"], ["Arrows", "pitch and yaw"],
			["Shift", "afterburner (full throttle)"], ["Space", "brake"], ["G", "hover · W S height"], ["L", "land · take off"]]],
		["SHIP", [["C", "camera distance"], ["E", "step outside · board"], ["X", "jump out and fly as the robot"]]],
		["ON FOOT", [["WASD", "walk"], ["Shift", "run"], ["Space", "jump · hold for jetpack"], ["X", "fly like a superhero"], ["R", "call your ship"], ["E", "board the ship"]]],
		["GAME", [["Esc", "menu · change ship"], [",", "settings"], ["K", "this panel"], ["F11", "full screen"]]]]
	for g in groups:
		var gv := VBoxContainer.new(); gv.add_theme_constant_override("separation", 7); gv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		gv.add_child(_label(g[0], 10, ACCENT, font_semi, 3))
		for row in g[1]:
			var hb := HBoxContainer.new(); hb.add_theme_constant_override("separation", 10); hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var k := _label(row[0], 11, Color.WHITE, font_semi); k.custom_minimum_size = Vector2(52, 0)
			hb.add_child(k); hb.add_child(_label(row[1], 12, Color(1, 1, 1, 0.65)))
			gv.add_child(hb)
		cols.add_child(gv)
	controls_root.visible = false

func toggle_controls() -> void:
	controls_root.visible = not controls_root.visible

func set_screen(title: bool, paused: bool) -> void:
	title_root.visible = title
	hud_root.visible = not title and not paused
	if not paused: pause_root.visible = false
