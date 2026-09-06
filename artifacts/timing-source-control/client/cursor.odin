// cursor.odin draws the custom animated pointer: the OS cursor is hidden
// during play and a mode-aware procedural cursor (arrow + orbiting ring
// arcs, or a terraform crosshair) is drawn on top of the HUD. Colors mirror
// the placement/terraform feedback so the cursor itself telegraphs validity.
package main

import shared "../shared"
import "core:math"
import fit "ingot:fit"
import rl "ingot:gfx"

CURSOR_RING_RADIUS :: f32(11)
CURSOR_RING_THICKNESS :: f32(2.5)
CURSOR_Z :: fit.Z_Order(600)
// Degrees per second the orbit arcs sweep; slow enough to read as idle motion.
CURSOR_SPIN_SPEED :: f32(120)
// Exponential decay rate of the click pulse (radius kick on press).
CURSOR_PULSE_DECAY :: f32(6.0)

Cursor_State :: struct {
	time:             f32,
	pulse:            f32,
	drawn_this_frame: bool,
	targeted:         bool,
}

Cursor_Visual_Mode :: enum u8 {
	Normal,
	Target,
	Grab,
	Terraform,
}

Cursor_Visual_Sample :: struct {
	mode:   Cursor_Visual_Mode,
	radius: f32,
}

cursor_visual_command_count :: proc(mode: Cursor_Visual_Mode) -> int {
	switch mode {
	case .Normal:
		return 7
	case .Target:
		return 12
	case .Grab:
		return 14
	case .Terraform:
		return 8
	}
	assert(false, "cursor command count: invalid mode")
	return 0
}

cursor_visual_sample :: proc(targeted, grab, terraform: bool, pulse: f32) -> Cursor_Visual_Sample {
	mode := Cursor_Visual_Mode.Normal
	if targeted do mode = .Target
	else if grab do mode = .Grab
	else if terraform do mode = .Terraform
	return {mode, CURSOR_RING_RADIUS * (1 + 0.35 * clamp(pulse, 0, 1))}
}

cursor_target_register :: proc(value: ^Client_State, surface: ^fit.Surface, rect: fit.Rect) {
	assert(value != nil && surface != nil, "cursor target: invalid argument")
	point := fit.Mouse_Position(surface)
	value.cursor.targeted =
		value.cursor.targeted ||
		(point.x >= f32(rect.x) &&
				point.x < f32(rect.x + rect.w) &&
				point.y >= f32(rect.y) &&
				point.y < f32(rect.y + rect.h))
}

cursor_update :: proc(value: ^Client_State, frame_dt: f32) {
	assert(value != nil, "cursor_update: nil state")
	assert(frame_dt >= 0, "cursor_update: negative dt")
	value.cursor.targeted = false
	value.cursor.time += frame_dt
	if rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT) {
		value.cursor.pulse = 1
	}
	value.cursor.pulse *= math.exp(-CURSOR_PULSE_DECAY * frame_dt)
}

// cursor_color picks the accent from the same state the world markers use.
// The terraform branch reads the identical UI_TERRAFORM_* constants the
// highlight mesh does, so the pointer and the footprint under it can never
// disagree about what the brush is about to do.
cursor_color :: proc(value: ^Client_State) -> rl.Color {
	assert(value != nil, "cursor_color: nil state")
	if value.mode == .Terraform {
		if !terraform_affordable(value) do return UI_CURSOR_INVALID
		// The tint follows the armed tool, not the sculpt state, so the
		// player sees what the brush will do before pressing.
		switch value.terraform_tool {
		case .Raise:
			return UI_TERRAFORM_RAISE
		case .Lower:
			return UI_TERRAFORM_LOWER
		case .Level:
			return UI_TERRAFORM_LEVEL
		}
		return UI_CURSOR_VALID
	}
	// Inspect mode: plain pointer, no placement-validity coloring.
	if value.mode != .Build do return UI_CURSOR_VALID
	if !value.hover_valid do return UI_CURSOR_NEUTRAL
	// Whole-footprint validity from the armed anchor, matching the sim rule.
	if !shared.placement_footprint_allowed(
		&value.world,
		value.selected_kind,
		value.place_x,
		value.place_y,
		value.hover_face,
	) {
		return UI_CURSOR_INVALID
	}
	return UI_CURSOR_VALID
}

Cursor_Draw_Context :: struct {
	point:  fit.Point,
	sample: Cursor_Visual_Sample,
	color:  rl.Color,
	angle:  f32,
}

cursor_draw_reserved :: proc(surface: ^fit.Surface, user_data: rawptr) {
	assert(surface != nil && user_data != nil, "cursor reserved draw: invalid argument")
	draw := cast(^Cursor_Draw_Context)user_data
	switch draw.sample.mode {
	case .Target:
		_cursor_target(surface, draw.point, draw.sample.radius, draw.angle, draw.color)
	case .Grab:
		_cursor_grab(surface, draw.point, draw.sample.radius, draw.angle, draw.color)
	case .Terraform:
		_cursor_crosshair(surface, draw.point, draw.sample.radius, draw.angle, draw.color)
	case .Normal:
		_cursor_ring(surface, draw.point, draw.sample.radius, draw.angle, draw.color)
		_cursor_arrow(surface, draw.point, draw.color)
	}
}

cursor_draw_visual :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	sample: Cursor_Visual_Sample,
) -> bool {
	assert(value != nil && surface != nil, "cursor visual draw: invalid argument")
	draw := Cursor_Draw_Context {
		point  = fit.Mouse_Position(surface),
		sample = sample,
		color  = UI_CURSOR_VALID if sample.mode == .Target else cursor_color(value),
		angle  = value.cursor.time * CURSOR_SPIN_SPEED,
	}
	return fit.Layer_With_Reserved_Paint(
		surface,
		CURSOR_Z,
		cursor_visual_command_count(sample.mode),
		cursor_draw_reserved,
		&draw,
	)
}

cursor_draw :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "cursor_draw: nil state")
	assert(surface != nil, "cursor_draw: nil surface")
	if !game_custom_cursor_active(value) do return
	sample := cursor_visual_sample(
		value.cursor.targeted,
		value.grab_pan.active,
		value.mode == .Terraform,
		value.cursor.pulse,
	)
	value.cursor.drawn_this_frame = cursor_draw_visual(value, surface, sample)
}

@(private = "file")
_cursor_target :: proc(
	surface: ^fit.Surface,
	point: fit.Point,
	radius, angle: f32,
	color: rl.Color,
) {
	lock_radius := radius * 0.82
	_cursor_ring(surface, point, lock_radius, -angle * 1.5, color)
	gap := lock_radius * 0.52
	reach := lock_radius * 1.18
	thickness := CURSOR_RING_THICKNESS
	fit.Line(
		surface,
		{point.x - reach, point.y - gap},
		{point.x - gap, point.y - gap},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x - gap, point.y - reach},
		{point.x - gap, point.y - gap},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x + gap, point.y - gap},
		{point.x + reach, point.y - gap},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x + gap, point.y - reach},
		{point.x + gap, point.y - gap},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x - reach, point.y + gap},
		{point.x - gap, point.y + gap},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x - gap, point.y + gap},
		{point.x - gap, point.y + reach},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x + gap, point.y + gap},
		{point.x + reach, point.y + gap},
		thickness,
		fit.Color(color),
	)
	fit.Line(
		surface,
		{point.x + gap, point.y + gap},
		{point.x + gap, point.y + reach},
		thickness,
		fit.Color(color),
	)
}

// Two opposing 100-degree arcs orbiting the tip; drop shadow first.
_cursor_ring :: proc(
	surface: ^fit.Surface,
	point: fit.Point,
	radius, angle: f32,
	color: rl.Color,
) {
	inner := radius - CURSOR_RING_THICKNESS / 2
	outer := radius + CURSOR_RING_THICKNESS / 2
	shadow := fit.Point{point.x + 1.5, point.y + 1.5}
	fit.Surface_Ring(
		surface,
		shadow,
		inner,
		outer,
		angle,
		angle + 100,
		24,
		fit.Color(UI_CURSOR_SHADOW),
	)
	fit.Surface_Ring(
		surface,
		shadow,
		inner,
		outer,
		angle + 180,
		angle + 280,
		24,
		fit.Color(UI_CURSOR_SHADOW),
	)
	fit.Surface_Ring(surface, point, inner, outer, angle, angle + 100, 24, fit.Color(color))
	fit.Surface_Ring(surface, point, inner, outer, angle + 180, angle + 280, 24, fit.Color(color))
}

// Arrow head: shadow triangle, dark outline triangle, then the fill.
// Vertices wind counter-clockwise so the fill rasterizes.
_cursor_arrow :: proc(surface: ^fit.Surface, point: fit.Point, color: rl.Color) {
	tip := point
	left := fit.Point{point.x, point.y + 15}
	right := fit.Point{point.x + 10.5, point.y + 10.5}
	fit.Surface_Triangle(
		surface,
		{tip.x + 1.5, tip.y + 1.5},
		{left.x + 1.5, left.y + 1.5},
		{right.x + 1.5, right.y + 1.5},
		fit.Color(UI_CURSOR_SHADOW),
	)
	fit.Surface_Triangle(
		surface,
		{tip.x - 1, tip.y - 1},
		{left.x - 1, left.y + 2},
		{right.x + 2, right.y + 1},
		fit.Color(UI_CURSOR_OUTLINE),
	)
	fit.Surface_Triangle(surface, tip, left, right, fit.Color(color))
}

_cursor_grab :: proc(
	surface: ^fit.Surface,
	point: fit.Point,
	radius, angle: f32,
	color: rl.Color,
) {
	motion := rl.GetMouseDelta()
	speed := min(math.sqrt(motion.x * motion.x + motion.y * motion.y), f32(12))
	pulse := 0.5 + 0.5 * math.sin(angle * math.PI / 90)
	grab_radius := radius * (0.72 + 0.06 * pulse - 0.012 * speed)
	_cursor_ring(surface, point, grab_radius, -angle * 1.5, color)
	shadow := fit.Point{point.x + 1.5, point.y + 1.5}
	fit.Surface_Fill_Circle(surface, shadow, 5.5, fit.Color(UI_CURSOR_SHADOW))
	fit.Surface_Fill_Circle(surface, point, 4.5, fit.Color(color))
	directions := [4]fit.Point{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
	for direction in directions {
		start := fit.Point{point.x + direction.x * 5, point.y + direction.y * 5}
		finish := fit.Point {
			point.x + direction.x * (grab_radius - 2),
			point.y + direction.y * (grab_radius - 2),
		}
		fit.Line(
			surface,
			{start.x + 1.5, start.y + 1.5},
			{finish.x + 1.5, finish.y + 1.5},
			3.5,
			fit.Color(UI_CURSOR_SHADOW),
		)
		fit.Line(surface, start, finish, 2, fit.Color(color))
	}
}

// Terraform crosshair: four ticks around a free center plus the orbit arcs,
// so the sculpt anchor stays visible under the cursor.
_cursor_crosshair :: proc(
	surface: ^fit.Surface,
	point: fit.Point,
	radius, angle: f32,
	color: rl.Color,
) {
	gap := radius * 0.45
	reach := radius * 1.1
	fit.Line(surface, {point.x + gap, point.y}, {point.x + reach, point.y}, 2, fit.Color(color))
	fit.Line(surface, {point.x - gap, point.y}, {point.x - reach, point.y}, 2, fit.Color(color))
	fit.Line(surface, {point.x, point.y + gap}, {point.x, point.y + reach}, 2, fit.Color(color))
	fit.Line(surface, {point.x, point.y - gap}, {point.x, point.y - reach}, 2, fit.Color(color))
	_cursor_ring(surface, point, radius * 1.4, -angle, color)
}
