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

PascalCase is reserved for names `vendor:raylib` declares. Ingot-only graphics
capabilities are snake_case: `context_*` for an explicit owner, `frame_*` for
the frame seam, and plain wrappers such as `set_frame_strategy` or
`request_redraw` for the default owner.

## `ingot:fit`

Start with the [Fit guide](fit-guide.md) for executable timing, lifetime,
component, typed-command, and custom-geometry recipes.

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
	_ = fit.run(&app, {width = 720, height = 480, title = "App"}, Draw)
}

Draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Settings", {role = .Title})
	fit.button(root, "save", "Save", fit.action(Save))
}
```

Custom themes use the same value-owned path. Every interaction swatch is
explicit; Ingot does not synthesize colors:

```odin
theme := fit.theme_from_palette({
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
fit.set_theme(&app, theme)
```

Use `theme_set_color` for an advanced single-role override. Validate editable
palettes with `theme_validate`, or use `try_set_theme` to reject an invalid value
without changing the active theme.

The builder is bounded and immediate. Root containers return an opaque
current-build `fit.Parent`; child containers and leaves consume Parent values.
There is no prepared-container open state or balancing call. `scope` returns a
Parent with a derived component identity and no additional layout node. `center`
is the root-only full-window centering convenience. Parent values are invalid
outside the draw that created them and must never be retained.

Responsive Flow and track Grid are part of this same declaration model. Their
track slices and `grid_cell` values are borrowed current-build inputs; they do
not create retained layout or widget state. Descend to `fit.Surface` or
`ingot:ui` only when the application owns explicit geometry or host lifecycle.

`render` consumes the declaration synchronously and dispatches activated Builder
actions before returning. Actions run in the activating frame but cannot change
the description already being rendered. `button_delayed` plus `Signal` is the
advanced later-build path; borrowed Surface and Region controls return
interaction directly inside their render callback. `measure` plus `render_at`
supports caller-owned placement without introducing a
retained widget tree. A `custom` render callback receives a borrowed
`fit.Surface` for same-frame interaction and explicit geometry; the Surface is
valid only for that callback and must not be retained.

`canvas` is the root convenience for applications whose whole content uses
explicit geometry. `canvas_leaf` provides the same borrowed Surface callback in
a measured Builder slot, allowing ordinary declarative composition around
bounded explicit-geometry islands. Use `px(surface, value)` only for logical
design constants; rectangles
returned by layout and render callbacks are already physical. `region_open` and
`region_close` may own one optional identity scope for a bounded region.

Explicit drawing keeps the borrowed Surface visible at each paint or interaction
call. Begun layout helpers instead bind that Surface to caller-owned state until
`End`, avoiding two repeated owner arguments without introducing ambient state:

```odin
canvas :: proc(surface: ^fit.Surface, root: fit.Rect, user_data: rawptr) -> bool {
	layout: fit.Layout_State
	fit.layout_begin(surface, &layout, root, gap = fit.px(surface, 8))
	fit.layout_row(&layout, fit.px(surface, 40))
	cell := fit.layout_remaining(&layout)
	fit.layout_pop(&layout)
	fit.layout_end(&layout)

	theme := fit.get_theme_tokens(surface)
	fit.fill_rect(surface, cell, theme.background_panel)
	fit.text(surface, "Explicit surface", cell.x, cell.y)
	return false
}
```

### Modal Builder composition

Open with `fit.surface_modal_open` before ordinary input processing, then render
with `fit.surface_modal_builder_with`. The modal owns pointer, keyboard, focus,
paint tier, clipping, and semantics until closed. Outside dismissal is opt-in.
Use `fit.modal_take_close` when the close source matters. Set `Modal_Options.scope`
to `.Host` with a positive `host` rectangle for a pane-bounded modal; viewport
scope remains the default.

Custom-content anchored surfaces use `fit.surface_popup_open` followed by
`fit.surface_popup_builder_with`. Popup options provide anchor, viewport,
preferred size, placement, focus, and dismissal policy. Consume a child-handled
key with `fit.key_pressed_consume` before the owning modal or popup ends.

`Layout_State`, `Grid_State`, `Flow_State`, `Fit_Column_State`, and
`Vertical_Cursor_State` are zero-value ready, must be balanced, and may be reused
after their `End`. The longer `Surface_Layout_*`, `Surface_Grid_*`,
`Surface_Flow_*`, and `Surface_Fit_Column_*` spellings remain source-compatible.
Neither vocabulary implicitly scales geometry.

For caller-owned scheduling, use the `fit.App` lifecycle explicitly:

```odin
main :: proc() {
	if !fit.init(&app, {width = 720, height = 480, title = "App"}, {draw = Draw}) {
		fmt.eprintfln("init: %v (%v)", fit.last_error(&app), fit.last_graphics_error(&app))
		return
	}
	defer fit.destroy(&app)
	if !fit.start(&app) do return
	for fit.get_state(&app) == .Running {
		if !fit.tick(&app) do break
	}
	if fit.get_state(&app) == .Running do _ = fit.stop(&app)
}
```

`fit.Session` is reserved for bounded integration inside an externally owned
graphics loop. It still yields only `fit.Builder`; it does not expose runtime,
frame, adapter, paint, or platform internals.

### Ownership and cleanup

`App` owns the graphics/UI lifecycle. Its callback user data must remain valid
until destruction; shutdown runs before the session and graphics context are
released. Destroy only a ready or stopped App, and stop a running App first.
Destruction resets callback bindings but retains caller-configured Builder
storage for reuse. That storage remains caller-owned and must outlive its use.

`Session` integrates into an externally owned graphics loop and does not close
that graphics context. `session_destroy` clears the wrapper, including Builder
storage bindings; rebind custom storage after reinitialization. Its draw callback
and user data are borrowed for `session_draw` only. A successful draw call may
skip the callback when no graphics frame is available; success does not promise
that a frame was presented. Callback bindings are cleared on that path too.

Parents and Surfaces must not escape their build/render callbacks. Balance begun
layout and region scopes before returning; never destroy an App or Session with
an open frame. Scale hooks are installed by shared session initialization for
explicit and convenience App entry points alike. As before, hooks are installed
after initial DPI setup and observe subsequent scale changes.

### Theme snapshots

`get_theme_tokens` / `surface_theme_tokens` returns a value snapshot of selected
active-theme colors and substrate settings. It is not a mirror of every backend
theme field. Fetch it again after changing the theme or window appearance; an
existing snapshot does not update itself. Active backgrounds are distinct from
the source swatches used to derive windowed and fullscreen appearance.

Use `theme_get_color` for named theme roles, `theme_pigment` for pigments, and
`surface_reduced_motion` for the active reduced-motion preference. New backend
fields do not automatically become public snapshot fields.

## Boundary maintenance contract

`fit` owns the consumer vocabulary, `ui` owns renderer-independent behavior and
layout, and `ui_gfx` owns graphics integration. New overloads adapt arguments to
one canonical implementation; they must not duplicate widget behavior.

Boundary types fall into two categories, and the category decides whether a
`fit` type may alias its `ui` counterpart:

- **Vocabulary** may alias. A `fit` type is vocabulary when it is closed value
  data: every field is itself consumer vocabulary, the `ui` name carries no
  engine, host, or renderer prefix, and `fit` would never want a different
  shape. `Color`, `Rect`, `Track`, `Space`, `Ink`, `Icon`, `Theme_Role`,
  `Pointer_Event`, `Table_Column`, `Modal_Close_Reason`, and `Action` are
  vocabulary. Each alias is listed in `FIT_PUBLIC_ALIAS_ALLOW` in
  `scripts/check_ui_api_layers.py`; adding one is a reviewed allowlist edit.
  Aliasing buys literal compatibility with `ui` and removes a converter.
- **Engine, host, and renderer** types must be distinct projections or mapped
  enums, never aliases. These are `ui.Prepared_*` (layout engine), `ui.Ui_*`
  (frame internals), `ui_gfx.*` (managed host), `gfx.*` (renderer), and any
  `fit` type that embeds one of them. `State`, `Frame_Pacing`, `Error`,
  `Graphics_Error`, `Session_Config`, `Frame_Diagnostics`, `Renderer_Peaks`,
  `Size_Options`, `Transition`, `Container_*`, `Flow_Options`, `Grid_Options`,
  `Attachment_Options`, and every `*_Options` that carries a `Size_Options` are
  in this category. `FIT_ENGINE_TYPE` in `scripts/check_ui_api_layers.py`
  rejects a public alias to any of those namespaces regardless of the
  allowlist. Projecting buys insulation: the engine can add, rename, or remove
  backend fields and members without changing what a `fit` consumer compiles
  against, and `fit` may expose a selected field set rather than every backend
  field.

Within the second category:

- Distinct enums map by meaning, not declaration order. Where the backing type
  and ordinals are identical the conversion casts through the backing integer
  and a `#assert` beside the declaration pins size and member count; a contract
  test in `fit/boundary_contract_test.odin` still checks every public member
  and, for flags, each bit individually as well as in combinations.
- Value projections copy field by field, and a contract test asserts every
  field of a fully populated source reaches the target.
- Binary storage boundaries (`Storage_Node`) retain their size, alignment, and
  layout checks and are the one opaque exception to the engine rule.

Builder actions dispatch in the activating render; delayed signals are consumed
by a later build. Legacy bool outputs and borrowed Surface controls retain their
existing timing. Overload unification must not erase those differences.

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
