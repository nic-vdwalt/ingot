package gfx

POINTER_EVENTS_MAX :: 64
POINTER_ID_NATIVE_MOUSE :: Pointer_Id(0)
POINTER_BUTTON_NONE :: Pointer_Button(-1)
POINTER_BUTTON_MASK :: Pointer_Buttons(0x7f)

Pointer_Id :: distinct u32

Pointer_Type :: enum u8 {
	Unknown,
	Mouse,
	Touch,
	Pen,
}

Pointer_Event_Kind :: enum u8 {
	Move,
	Down,
	Up,
	Cancel,
}

Pointer_Button :: enum i8 {
	None    = -1,
	Left    = 0,
	Right   = 1,
	Middle  = 2,
	Side    = 3,
	Extra   = 4,
	Forward = 5,
	Back    = 6,
}

Pointer_Buttons :: distinct u16

Pointer_Event :: struct {
	id:           Pointer_Id,
	position:     Vector2,
	pressure:     f32,
	buttons:      Pointer_Buttons,
	kind:         Pointer_Event_Kind,
	pointer_type: Pointer_Type,
	button:       Pointer_Button,
	primary:      bool,
}

pointer_event_valid :: proc "contextless" (event: Pointer_Event) -> bool {
	button := i32(event.button)
	if i32(event.pointer_type) < i32(Pointer_Type.Unknown) ||
	   i32(event.pointer_type) > i32(Pointer_Type.Pen) ||
	   i32(event.kind) < i32(Pointer_Event_Kind.Move) ||
	   i32(event.kind) > i32(Pointer_Event_Kind.Cancel) ||
	   button < -1 ||
	   button > i32(Pointer_Button.Back) ||
	   u16(event.buttons) & ~u16(POINTER_BUTTON_MASK) != 0 ||
	   !(event.pressure >= 0 && event.pressure <= 1) {
		return false
	}
	if event.kind == .Down || event.kind == .Up do return button >= 0
	if button != -1 do return false
	if event.kind == .Cancel do return event.buttons == 0 && event.pressure == 0
	return true
}

@(private = "package")
pointer_stage :: proc "contextless" (input: ^Input, event: Pointer_Event) -> bool {
	if input == nil do return false
	assert_contextless(pointer_event_valid(event), "pointer_stage: invalid event")
	assert_contextless(
		input.st_pointer_event_count >= 0 && input.st_pointer_event_count <= POINTER_EVENTS_MAX,
		"pointer_stage: invalid count",
	)
	if input.st_pointer_event_count == POINTER_EVENTS_MAX {
		input.st_pointer_events_overflowed = true
		return false
	}
	input.st_pointer_events[input.st_pointer_event_count] = event
	input.st_pointer_event_count += 1
	return true
}

@(private = "package")
pointer_publish_staged :: proc(input: ^Input) {
	assert(input != nil, "pointer_publish_staged: nil input")
	assert(
		input.st_pointer_event_count >= 0 && input.st_pointer_event_count <= POINTER_EVENTS_MAX,
		"pointer_publish_staged: invalid count",
	)
	input.pointer_event_count = input.st_pointer_event_count
	copy(
		input.pointer_events[:input.pointer_event_count],
		input.st_pointer_events[:input.st_pointer_event_count],
	)
	input.pointer_events_overflowed = input.st_pointer_events_overflowed
	input.st_pointer_event_count = 0
	input.st_pointer_events_overflowed = false
}

context_pointer_events :: proc(ctx: ^Context) -> []Pointer_Event {
	if ctx == nil do return nil
	assert(
		ctx.inp.pointer_event_count >= 0 && ctx.inp.pointer_event_count <= POINTER_EVENTS_MAX,
		"context_pointer_events: invalid count",
	)
	return ctx.inp.pointer_events[:ctx.inp.pointer_event_count]
}

context_pointer_events_overflowed :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.inp.pointer_events_overflowed
}
