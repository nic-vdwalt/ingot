package fit

import "ingot:ui"

pointer_events :: proc(builder: ^Builder) -> []Pointer_Event {
	assert(builder != nil && builder.bound, "fit.pointer_events: builder not bound")
	return ui.frame_pointer_events(builder.root.frame)
}

pointer_events_overflowed :: proc(builder: ^Builder) -> bool {
	assert(builder != nil && builder.bound, "fit.pointer_events_overflowed: builder not bound")
	return ui.frame_pointer_events_overflowed(builder.root.frame)
}

surface_pointer_events :: proc(surface: ^Surface) -> []Pointer_Event {
	return ui.frame_pointer_events(surface_ui(surface).frame)
}

surface_pointer_events_overflowed :: proc(surface: ^Surface) -> bool {
	return ui.frame_pointer_events_overflowed(surface_ui(surface).frame)
}
