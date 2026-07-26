# UI state and stable focus

Immediate mode describes how Ingot declares and derives an interface; it does
not mean useful applications have no persistent state. Ingot keeps long-lived
widget behavior in application data instead of a retained widget tree or hidden
map keyed by labels. Group state by screen or reusable component so ownership
and teardown follow that component's lifetime.

The complete state boundary is:

- Application components own values and persistent widget behavior.
- `Ui_Runtime` owns explicit window-lifetime services and reusable resources.
- `Ui_Frame` owns transient output and arbitration for one rendered frame.
- Stable IDs identify controls without becoming keys into a widget-state store.

See [Why immediate mode](immediate-mode.md) for the architectural argument and
[Testing Ingot](testing.md) for how this boundary is exercised.

```odin
Editor_Form :: struct {
	ui:      ui.Ui,
	title:   ui.Input_Box,
	enabled: bool,
}

editor_form_destroy :: proc(form: ^Editor_Form) {
	assert(form != nil)
	ui.input_box_destroy(&form.title)
}
```

Most state bundles are zero-value ready. `Input_Box` owns allocations for text,
undo history, mention pills, wrapped-line memoization, and spell scan results.
Do not copy it after first use. Call `input_box_destroy` before discarding its
owner. `input_box_reset` clears logical state while retaining reusable capacity.

## Runtime and frame ownership

Each window owns one `Ui_Runtime`; each rendered frame owns one `Ui_Frame`.
Initialize and destroy the runtime with the window, bracket drawing with
`ui_frame_begin` and `ui_frame_end`, and bind every layout root through
`ui_begin_frame`. Several roots may share a frame, while separate windows and
tests use separate runtime/frame pairs.

`Ui_Runtime` owns text and spell systems, theme, metrics, DPI tracking, and
style generations. `Ui_Frame` owns cursor arbitration, overlays, input routes,
interaction arbitration, semantics, accessibility actions, and pane-coordinate
scopes. Retained semantic snapshots contain only values and fixed buffers; live
focus pointers exist only in bounded registries while a frame is open and are
cleared by `ui_frame_end`. Cache results are borrowed until the owning system is
reset or destroyed. Persistent widget behavior never lives in either context:
keep `Button_State`, `Slider_State`, `Input_Box`, menu state, and scrollbar state
in the component that draws them. Stable IDs identify focus targets; they do not
own widget state.

Ingot has no implicit active runtime or frame. Geometry-level widgets receive a
`^Ui_Frame`; `Ui` overloads forward the frame attached by `ui_begin_frame`.
Text, wrap, and spell helpers receive their owning system explicitly. A host
must end every frame before beginning another frame on the same object.
Accessibility adapters may be process-limited by the operating-system bridge,
but semantic data and pending actions remain owned by the selected runtime and
frame. Markdown uses `Markdown_Context` for its frame, workspace paths, and cull
band. `Text_Input_State` owns its selection, wrap/spell memoization, undo data,
and spell menu; destroy it before its runtime.

Native applications using `ui_gfx.App_Session` destroy component/widget state,
then call `app_session_destroy`, which destroys `Ui_Frame`, `Adapter`, and
`Ui_Runtime` in order, and finally call `CloseWindow`. Low-level hosts perform
the same order explicitly. End the active frame before any of those steps.

Web `rl.run` installs the browser animation-frame callback and returns. State
read by that callback must have static or otherwise host-managed lifetime; do
not place it in a stack frame that returns. The managed JavaScript host owns the
running session. Call `session.destroy()` before replacing it, or
`ingotWeb.stop()` during page teardown. Shutdown is idempotent and detaches input,
cancels network work, removes semantic overlays, and closes the graphics
lifetime before a replacement session starts.

```odin
runtime: ui.Ui_Runtime
frame: ui.Ui_Frame
form: Editor_Form

ui.ui_runtime_init(&runtime)
ui.ui_frame_begin(&frame, &runtime)
ui.ui_begin_frame(&form.ui, &frame, x, y, w, h)
ui.ui_end(&form.ui)
ui.ui_frame_end(&frame)
editor_form_destroy(&form)
ui.ui_runtime_destroy(&runtime)
```

## Stable focus

New conditional or dynamic interfaces should pass explicit nonzero `Focus_Id`
values to auto-layout widgets. IDs are unique only within one `Ui` frame.
Registration order defines Tab order; the ID defines logical identity. Global
Tab intent may be captured before drawing, but is resolved at frame end against
only the controls registered during that same frame. Accessibility focus uses a
live current-frame link, while activation expires after the immediately
following frame if its target is absent.

```odin
TITLE_ID :: ui.Focus_Id(1)
ENABLED_ID :: ui.Focus_Id(2)
SAVE_ID :: ui.Focus_Id(3)

ui.ui_begin_frame(&form.ui, &frame, x, y, w, h)
ui.input(&form.ui, TITLE_ID, &form.title, "Title")
ui.checkbox(&form.ui, ENABLED_ID, "Enabled", &form.enabled)
if ui.btn(&form.ui, SAVE_ID, "Save") {
	save()
}
ui.ui_end(&form.ui)
```

Insertion and reorder do not transfer focus because the active ID remains the
same. If the focused ID is absent or disabled in the completed frame,
`ui_end` clears focus. Zero IDs, duplicates, overflow beyond 256 focusables,
and mixing stable with sequential registration in one frame are programmer
errors and assert.

Stable IDs should come from application identity, not row positions:

```odin
for item in items {
	id := ui.focus_id(item.id)
	if ui.btn(&list_ui, id, item.name) {
		open_item(item.id)
	}
}
```

The order of `items` may change without moving focus to another record. Keep
IDs stable for the lifetime of each logical control and avoid reusing a removed
record's ID for a different control.

## Scoped widget identity

`Widget_Id` is the canonical identity for conditional controls, collections,
and reusable components. A `Ui` owns a bounded `Id_Context`; scopes compose
explicit component and domain identity without retaining widget state.

```odin
ui.ui_id_root(&form, "settings")
ui.ui_id_push(&form, "accounts")
for account in accounts {
	id := ui.ui_id(&form, account.id)
	_ = ui.btn_ui_id(&form, id, account.name)
}
ui.ui_id_pop(&form)
ui.ui_id_pop(&form)
```

IDs are deterministic across frames and process launches, independent of labels,
pointers, source locations, and sibling order. Use stable domain IDs for list
rows rather than indexes. Focus and accessibility semantics share the generated
identity. All ID scopes must be closed before `ui_end`.

`Focus_Id`, `focus_id`, and `focus_id_string` remain supported compatibility
paths. They do not create a hidden widget-state store.

## Widget tiers

Most widgets ship in two call shapes. Pick one per screen and stay in it.

| Suffix | Status | Shape | Focus |
|---|---|---|---|
| `*_at` | Supported | Explicit `x, y, w, h` against a `^Ui_Frame` | Caller passes `Focus_Opt`, or omits it |
| `*_ui` | Supported | Carves a bounded slot from a `^Ui` and its `Layout` | Registered automatically when visible |

Use `*_at` for canvases, scroll-offset content, overlays, and custom geometry.
Positioning is your responsibility: scale every dimension through `ui_frame_sc`
so the result tracks the runtime UI scale.

```odin
metrics, style := ui.ui_frame_style(frame)
if ui.btn_at(frame, x, y, ui.ui_frame_sc(frame, 120), metrics.ROW_H_MD, "Save", .Primary) {
	save(app)
}
```

Use `*_ui` for bounded row, column, weighted, and flex forms. `ui_padding`,
`ui_row_begin`, `ui_column_begin`, `ui_panel_begin`, `ui_flex_begin`, and
`ui_fill` expose the same bounded single-pass layout engine. Standard `Space`
tokens resolve logical spacing once through the frame scale; metrics, measured
text, screen bounds, and parent rectangles are already physical. Every scope must be
balanced before `ui_end`. Overflow clips to the root and produces zero-area
slots rather than assertions.

`btn_ui_state` and `btn_ui_state_id` are deprecated: no consumer has needed
`Button_State` together with auto-layout. Use `btn_at_state` with an explicit
rect, or `btn_ui` when the press animation state is not required.

Both tiers share one interaction, focus, semantics, and paint pipeline — `*_ui`
resolves a rect and then calls the matching `*_at`. Mixing them in one frame is
legal; mixing them in one *form* is not, because focus registration must be
either sequential or stable for the whole `Ui` (see
[Sequential compatibility](#sequential-compatibility)).

## Explicit ownership boundary

Font, wrap, spell, theme, scale, markdown, and text-input APIs require their
owner explicitly. There is no default text or spell system, active runtime or
frame, ambient theme or metric mirror, or positional text-input compatibility
path. Native spell adapters may use process resources required by the operating
system, while logical caches, ignored words, and menu state remain explicitly
owned by runtimes and components.

## Sequential compatibility

Calls without an ID remain supported:

```odin
ui.checkbox(&form.ui, "Enabled", &form.enabled)
ui.btn(&form.ui, "Save")
```

They assign focus by current-frame call order. Use this only for fixed forms
whose focusable membership and order do not change. Insertion, removal, or
reordering can transfer sequential focus to the widget inheriting an ordinal.
The lower-level `Focus_Opt{&slot, id}` and `form_focus_cycle` APIs remain
available under the same constraint.

## Accessibility

The semantic layer records each complete focus link, so stable focus works
through app-wide focus scopes and assistive-technology focus actions. An
generated `Widget_Id` is the authoritative control identity. An explicit
semantic `field_id` remains available for application-global external identity,
and a focus link supplies compatibility identity only when neither is present.
`Focus_Id` remains scoped to one `Ui`. Duplicate semantic IDs
drop the later node and increment frame diagnostics. Focus-scope priority
selects the traversal tier; equal-priority scope IDs merge in draw order.

## Frame diagnostics

`ui_frame_diagnostics` returns a copied, allocation-free snapshot of input,
geometry, semantic, paint, and platform-output drops. Golden-path tests should
assert that every counter is zero. `draw_debug_overlay` displays the same data.
