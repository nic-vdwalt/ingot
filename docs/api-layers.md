# Supported API layers

Ingot has two primary consumer entry points and two advanced UI layers.

## `ingot:gfx`

Use `ingot:gfx` as a raylib-compatible import. Keep the PascalCase window,
input, resource, drawing, camera, and audio calls used by the documented
compatibility subset. `ingot:gfx/rlgl` is available only where compatibility is
explicitly documented.

```odin
import rl "ingot:gfx"

main :: proc() {
	rl.InitWindow(800, 450, "App")
	defer rl.CloseWindow()
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		rl.DrawText("Hello", 24, 24, 24, rl.RAYWHITE)
		rl.EndDrawing()
	}
}
```

The PascalCase API is the supported migration vocabulary and each procedure
calls an explicit implementation with the default owner. The narrow owner-bound
`Frame` seam exists for framework bridges and documented multi-context hosts; it
is not a second general drawing vocabulary and never changes ambient state.

## `ingot:fit`

Use `ingot:fit` for UI applications. `fit.App` owns the graphics/UI lifecycle,
and the callback receives the recommended declaration object: `fit.Builder`.

```odin
import fit "ingot:fit"

app: fit.App

Save :: proc(user_data: rawptr) {
	_ = user_data
	save()
}

main :: proc() {
	_ = fit.Run(&app, {width = 720, height = 480, title = "App"}, Draw)
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Settings", {role = .Title})
	fit.Button(root, "save", "Save", fit.action(Save))
}
```

Custom themes use the same value-owned path. Every interaction swatch is
explicit; Ingot does not synthesize colors:

```odin
theme := fit.Theme_From_Palette({
	basis = .Dark,
	ground = {18, 20, 24, 255},
	surface = {28, 31, 36, 255},
	surface_raised = {38, 42, 48, 255},
	control = {48, 53, 61, 255},
	control_hover = {62, 69, 79, 255},
	control_pressed = {78, 87, 99, 255},
	foreground = {238, 241, 244, 255},
	foreground_muted = {174, 182, 190, 255},
	accent = {126, 200, 255, 255},
	foreground_on_accent = {17, 19, 24, 255},
	danger = {255, 145, 145, 255},
	foreground_on_danger = {17, 19, 24, 255},
	success = {142, 226, 166, 255},
	border = {104, 115, 126, 255},
	focus = {126, 200, 255, 230},
})
fit.Set_Theme(&app, theme)
```

Use `Theme_Set_Color` for an advanced single-role override. Validate editable
palettes with `Theme_Validate`, or use `Try_Set_Theme` to reject an invalid value
without changing the active theme.

The builder is bounded and immediate. Root containers return an opaque
current-build `fit.Parent`; child containers and leaves consume Parent values.
There is no prepared-container open state or balancing call. `Scope` returns a
Parent with a derived component identity and no additional layout node. `Center`
is the root-only full-window centering convenience. Parent values are invalid
outside the draw that created them and must never be retained.
`Render` consumes the declaration synchronously and dispatches activated Builder
actions before returning. Actions run in the activating frame but cannot change
the description already being rendered. `Button_Delayed` plus `Signal` is the
advanced later-build path; borrowed Surface and Region controls return
interaction directly inside their render callback. `Measure` plus `Render_At`
supports caller-owned placement without introducing a
retained widget tree. A `Custom` render callback receives a borrowed
`fit.Surface` for same-frame interaction and explicit geometry; the Surface is
valid only for that callback and must not be retained.

`Canvas` is the root convenience for applications whose whole content uses
explicit geometry. `Canvas_Leaf` provides the same borrowed Surface callback in
a measured Builder slot, allowing ordinary declarative composition around
bounded explicit-geometry islands. Use `Px(surface, value)` only for logical
design constants; rectangles
returned by layout and render callbacks are already physical. `Region_Open` and
`Region_Close` may own one optional identity scope for a bounded region.

Explicit drawing keeps the borrowed Surface visible at each paint or interaction
call. Begun layout helpers instead bind that Surface to caller-owned state until
`End`, avoiding two repeated owner arguments without introducing ambient state:

```odin
canvas :: proc(surface: ^fit.Surface, root: fit.Rect, user_data: rawptr) -> bool {
	layout: fit.Layout_State
	fit.Layout_Begin(surface, &layout, root, gap = fit.Px(surface, 8))
	fit.Layout_Row(&layout, fit.Px(surface, 40))
	cell := fit.Layout_Remaining(&layout)
	fit.Layout_Pop(&layout)
	fit.Layout_End(&layout)

	theme := fit.Get_Theme_Tokens(surface)
	fit.Fill_Rect(surface, cell, theme.background_panel)
	fit.Text(surface, "Explicit surface", cell.x, cell.y)
	return false
}
```

### Modal Builder composition

Open with `fit.Surface_Modal_Open` before ordinary input processing, then render
with `fit.Surface_Modal_Builder_With`. The modal owns pointer, keyboard, focus,
paint tier, clipping, and semantics until closed. Outside dismissal is opt-in.
Use `fit.Modal_Take_Close` when the close source matters. Set `Modal_Options.scope`
to `.Host` with a positive `host` rectangle for a pane-bounded modal; viewport
scope remains the default.

Custom-content anchored surfaces use `fit.Surface_Popup_Open` followed by
`fit.Surface_Popup_Builder_With`. Popup options provide anchor, viewport,
preferred size, placement, focus, and dismissal policy. Consume a child-handled
key with `fit.Key_Pressed_Consume` before the owning modal or popup ends.

`Layout_State`, `Grid_State`, `Flow_State`, `Fit_Column_State`, and
`Vertical_Cursor_State` are zero-value ready, must be balanced, and may be reused
after their `End`. The longer `Surface_Layout_*`, `Surface_Grid_*`,
`Surface_Flow_*`, and `Surface_Fit_Column_*` spellings remain source-compatible.
Neither vocabulary implicitly scales geometry.

For caller-owned scheduling, use the `fit.App` lifecycle explicitly:

```odin
main :: proc() {
	if !fit.Init(&app, {width = 720, height = 480, title = "App"}, {draw = Draw}) do return
	defer fit.Destroy(&app)
	if !fit.Start(&app) do return
	for fit.Get_State(&app) == .Running {
		if !fit.Tick(&app) do break
	}
	if fit.Get_State(&app) == .Running do _ = fit.Stop(&app)
}
```

`fit.Session` is reserved for bounded integration inside an externally owned
graphics loop. It still yields only `fit.Builder`; it does not expose runtime,
frame, adapter, paint, or platform internals.

## API map contract

The API map presents `ingot:fit` and `ingot:gfx` as parallel primary entry
points. Package swimlanes show implementation ownership, while permanent badges
classify cards as `PRIMARY`, `ADVANCED`, or `INTERNAL`. The advanced
`ingot:ui` and managed `ingot:ui_gfx` hosts remain supported application APIs;
direct Adapter lifecycle calls remain internal.

The animated path names six stages of one UI frame:

1. `fit.App` provides the primary managed UI lifecycle.
2. Managed `ui_gfx.App` and `ui_gfx.Session` hosts provide the advanced
   lifecycle path.
3. `ui` records renderer-independent immediate-mode UI work.
4. Application callbacks perform same-frame work through the selected API layer.
5. `ui` produces paint, semantics, and platform output.
6. The internal Adapter replays output through primary `gfx` presentation.

Hover and animation are implemented inside the borrowed Surface callback. The
map retains only application-owned selection and timing values; it never retains
the Surface.

## Advanced UI layers

`ingot:ui` and `ingot:ui_gfx` retain the passive runtime, per-frame input and
paint state, prepared layout engine, explicit widget primitives, text backend,
platform output, accessibility bridge, and replay implementation. They are
supported advanced application imports for callers that need direct control and
can own the additional lifecycle and layout responsibilities.

`ui_gfx.App` and `ui_gfx.Session` are the managed graphics hosts for this layer.
`Prepared_Ui`, direct Adapter lifecycle calls, undocumented bridge details, and
the removed `Fit_Node` tree remain implementation details rather than public APIs.
