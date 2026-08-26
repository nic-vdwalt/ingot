package fit

import "ingot:ui"

Pointer_Events :: proc(builder: ^Builder) -> []Pointer_Event {
	assert(builder != nil && builder.bound, "Fit.Pointer_Events: builder not bound")
	return ui.frame_pointer_events(builder.root.frame)
}

Pointer_Events_Overflowed :: proc(builder: ^Builder) -> bool {
	assert(builder != nil && builder.bound, "Fit.Pointer_Events_Overflowed: builder not bound")
	return ui.frame_pointer_events_overflowed(builder.root.frame)
}

Surface_Pointer_Events :: proc(surface: ^Surface) -> []Pointer_Event {
	return ui.frame_pointer_events(surface_ui(surface).frame)
}

Surface_Pointer_Events_Overflowed :: proc(surface: ^Surface) -> bool {
	return ui.frame_pointer_events_overflowed(surface_ui(surface).frame)
}
