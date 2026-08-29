# Pointer input

Ingot exposes a bounded raw pointer-event stream for applications that need
mouse, touch, or pen identity beyond the existing mouse-compatible controls.
The stream is current-frame input, not a gesture system or retained widget tree.

Each event contains a pointer ID, device type, logical position, lifecycle kind,
changed and held buttons, normalized pressure, and primary-pointer status.
Events are ordered as received and remain valid only for the current frame.

## Ownership

Applications own persistent pointer state and every tap, pan, pinch, drawing, or
capture policy. Ingot stores no per-widget pointer behavior. Copy only the values
needed after the frame into a bounded caller-owned structure.

A `Cancel` means the host took the sequence away. Remove that pointer without
activating it. Never reinterpret cancellation as `Up`.

The queue retains its first 64 events. If `Pointer_Events_Overflowed`,
`Surface_Pointer_Events_Overflowed`, `ui.frame_pointer_events_overflowed`, or
`gfx.context_pointer_events_overflowed` is true, discard all caller-owned active
pointer state. The stream's causal lifecycle is incomplete, so an application
must not infer a missing `Up` or continue a gesture.

```odin
Pointer_State :: struct {
	active: [16]fit.Pointer_Id,
	count:  int,
}

pointer_update :: proc(builder: ^fit.Builder, state: ^Pointer_State) {
	assert(builder != nil && state != nil)
	if fit.Pointer_Events_Overflowed(builder) {
		state.count = 0
		return
	}
	for event in fit.Pointer_Events(builder) {
		switch event.kind {
		case .Down:
			if state.count < len(state.active) {
				state.active[state.count] = event.id
				state.count += 1
			}
		case .Up, .Cancel:
			for id, index in state.active[:state.count] {
				if id != event.id do continue
				state.active[index] = state.active[state.count - 1]
				state.count -= 1
				break
			}
		case .Move:
		}
	}
}
```

The same contract is available through `ui.frame_pointer_events`. Raw events are
not modal-filtered; applications implementing custom interactions own their
routing and overlay policy. Existing widgets continue to use the established
modal-aware mouse path.

## Compatibility projection

Existing controls still use mouse position, button, and wheel snapshots. On the
web, touch taps continue to project to a mouse click and one-finger pans continue
to project to wheel scrolling. Mouse and pen retain their existing precise
mouse-compatible path.

Do not treat raw and compatibility input as independent actions. For example, a
custom canvas can consume raw touch events while standard buttons use existing
mouse interaction, but processing both streams for the same canvas gesture would
double-count one physical input.

## Platform support

Web builds expose bounded simultaneous browser pointer IDs, mouse/touch/pen
types, primary status, and normalized pen pressure. Browser cancellation,
pointer-capture loss, focus loss, visibility loss, and teardown produce bounded
cancellation behavior.

Current native GLFW and SDL3 builds expose ordered mouse events only. The SDL3
backend does not yet expose native touch, pen, pressure, or simultaneous-contact
data. Check
`gfx.capabilities()` before selecting platform-dependent interactions:

- `pointer_events` reports the raw stream.
- `multi_pointer` reports simultaneous contact support.
- `pointer_pressure` reports meaningful pressure support.

Pointer positions use logical window or canvas coordinates with a top-left
origin. `buttons` is the post-event held mask. `button` is meaningful only for
`Down` and `Up`; `Move` and `Cancel` use `None`. `Cancel` always carries zero
buttons and zero pressure.
