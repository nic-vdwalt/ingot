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
`begin`. Several roots may share a frame, while separate windows and
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
`^Ui_Frame`; facade widgets forward the frame attached by `begin`.
Text, wrap, and spell helpers receive their owning system explicitly. A host
must end every frame before beginning another frame on the same object.
Accessibility adapters may be process-limited by the operating-system bridge,
but semantic data and pending actions remain owned by the selected runtime and
frame. Markdown uses `Markdown_Context` for its frame, workspace paths, and cull
band. `Text_Input_State` owns its selection, wrap/spell memoization, undo data,
and spell menu; destroy it before its runtime.

Native applications using `ui_gfx.Session` destroy component/widget state, then
call `session_destroy`, which destroys `Ui_Frame`, the backend adapter, and
`Ui_Runtime` in order, and finally call `CloseWindow`. End the active frame
before any of those steps.

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
ui.begin(&form.ui, &frame, {x, y, w, h})
ui.end(&form.ui)
ui.ui_frame_end(&frame)
editor_form_destroy(&form)
ui.ui_runtime_destroy(&runtime)
```

## Stable focus

Conditional or dynamic interfaces pass a generated `Widget_Id` to facade
widgets. IDs are unique only within one `Ui` frame. Registration order defines
Tab order; the ID defines logical identity. Global Tab intent may be captured
before drawing, but is resolved at frame end against only the controls
registered during that same frame. Accessibility focus uses a live
current-frame link, while activation expires after the immediately following
frame if its target is absent.

```odin
ui.begin(&form.ui, &frame, {x, y, w, h})
ui.scope_begin(&form.ui, "editor")
ui.text_input(
	&form.ui,
	"title",
	&form.title,
	"Title",
	ui.Text_Input_Options{semantics = {name = "Title"}},
)
ui.checkbox(&form.ui, "enabled", "Enabled", &form.enabled)
if ui.button(&form.ui, "save", "Save") {
	save()
}
ui.scope_end(&form.ui)
ui.end(&form.ui)
```

Insertion and reorder do not transfer focus because the active ID remains the
same. If the focused ID is absent or disabled in the completed frame,
`end` clears focus. Zero IDs, duplicates, overflow beyond 256 focusables,
and mixing stable with sequential registration in one frame are programmer
errors and assert.

Stable IDs should come from application identity, not row positions:

```odin
for item in items {
	if ui.button(&list_ui, item.id, item.name) {
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
ui.scope_begin(&form, "settings")
ui.scope_begin(&form, "accounts")
for account in accounts {
	id := ui.id(&form, account.id)
	_ = ui.button(&form, id, account.name)
}
ui.scope_end(&form)
ui.scope_end(&form)
```

IDs are deterministic across frames and process launches, independent of labels,
pointers, source locations, and sibling order. Use stable domain IDs for list
rows rather than indexes. Focus and accessibility semantics share the generated
identity. Labels never generate identity. All ID scopes must be closed before `end`.

`Focus_Id`, `focus_id`, and `focus_id_string` are the *explicit* tier's identity
model, not a compatibility path: an application that owns its own geometry owns
its own focus keys too, paired with a caller-owned `Focus_State`. They do not
create a hidden widget-state store. `Widget_Id` is a distinct type; `focus` is
the one place the two meet.

## Widget entry points

Facade widgets take a `^Ui` and a stable string/u64 key or explicit
`Widget_Id`. They consume one bounded slot in logical units and register focus
only when visible:

```odin
if ui.button(&form, "save", "Save", ui.Button_Options{style = .Primary}) {
	save(app)
}
```

Explicit widgets take a `^Ui_Frame` and a physical `Rect_I32`. Use them for
canvases, scroll-offset content, overlays, and custom geometry:

```odin
rect := ui.next(&layout, ui.ui_frame_sc(frame, 120))
if ui.button_at(frame, rect, "Save", .Primary, focus = save_focus) {
	save(app)
}
```

Each leaf-widget behavior variant has one canonical geometry shape per tier.
The `*_at` suffix marks explicit leaf geometry; `_state` and `_animated` mark
behavior variants. Explicit composition protocols keep lifecycle/subsystem
names. There are no `*_ui`, `*_ui_id`, or `*_auto` variants.

### Widget tiers

Interactive widgets take a `Widget_Id` on the facade because they register focus.
Presentational widgets take none: with no focus to register, there is nothing for
an identity to key.

| Widget | Facade | Explicit |
|---|---|---|
| button | `button(u, key/id, label, options)` | `button_at(frame, rect, label, options)`, `button_at_state` |
| checkbox | `checkbox(u, key/id, …)` | `checkbox_at` |
| radio | `radio(u, key/id, …)` | `radio_at` |
| slider | `slider(u, id, …)`, `slider_state` | `slider_at`, `slider_at_state` |
| dropdown | `dropdown(u, id, …)` | `dropdown_at` |
| text input | `text_input(u, key/id, box, placeholder, options)` | `text_input_at(frame, rect, box, placeholder, options)` |
| collapsible header | `collapsible_header(u, id, …)` | `collapsible_header_at` |
| icon button | `icon_btn(u, id, …)` | `icon_btn_at` |
| back button | `back_btn(u, id, …)` | `back_btn_at` |
| tooltip | `tooltip(u, …)` | `tooltip_at` |
| section header | `section_header(u, label)` | `section_header_at` |
| status pill | `status_pill(u, …)` | `status_pill_at` |
| progress bar | `progress_bar`, `progress_bar_animated` | `progress_bar_at`, `progress_bar_animated_at` |
| spinner | `spinner(u, …)` | `spinner_at` |
| sparkline | `sparkline(u, …)` | `sparkline_at` |
| line / bar chart | `line_chart`, `bar_chart` | `line_chart_at`, `bar_chart_at` |
| key/value row | `kv_row(u, …)` | `kv_row_at` |
| card background | `card_bg(u, …)` | `card_bg_at` |
| list row background | — | `list_row_bg_at` |
| listbox / pane / modal / context menu | — | explicit lifecycle protocols |
| overlay | — | explicit paint subsystem |
| markdown | — | `markdown_context` + `markdown_draw` |
| `Flow_Layout`, `Fit_Column` | — | explicit layout protocols, by design |

Facade and explicit entry points share interaction, focus, semantics, paint,
and option vocabulary. They differ only in who supplies geometry. Facade
dimensions are logical; roots, measured values, metrics, low-level layout, and
explicit rectangles are physical.

## Ownership reference

| Type | Zero-ready | Init required | Destroy required | Allocator / borrowing |
|---|---|---|---|---|
| `Ui` | yes | no | no | caller-owned bounded state |
| `Ui_Runtime` | no | `ui_runtime_init` | yes | owns text/spell resources |
| `Ui_Frame` | yes | opened by host/runtime | `ui_frame_destroy` after final frame | frame views expire at release |
| `Input_Box` | yes | optional `input_box_init` | yes after first allocation | builder allocator; `input_box_text` borrows |
| `Input_Box_Group` | yes | `input_box_group_init` | yes for grouped boxes | borrows caller's box slice |
| `Text_Input_State` | yes | no | yes after first allocation | owns undo, pills, and memos |
| `Chart_State` | yes | no | no | caller-owned values only |
| `Button_State`, `Slider_State` | yes | no | no | caller-owned values only |
| popup/dropdown/tooltip state | yes | no | no | caller-owned values only |
| `Session` | no | `session_init` | yes | owns runtime, frame, output, adapter |
| `App` | yes | `app_run`/`app_init` | shell on native; host on web | borrows userdata for run lifetime |
| `Ui_Output` | yes | no | no | fixed storage; paint text views borrow it |
| `Frame_View`, `Frame_String` | produced by frame | no | no | invalid after frame release |

Use `input_box_text_clone` when text must outlive a mutation or destruction of
its box. Aggregate forms may use `Input_Box_Group` or define one component
`destroy` procedure that calls each owning field's destroy procedure.

Ordinary containers consume intrinsic sizes. Flex containers consume one declared track per widget or `flex_slot_next` call. Every container and scope must be balanced before `end`. Overflow clips to the root and produces zero-area slots rather than retaining or repairing a widget hierarchy.

## Explicit ownership boundary

Font, wrap, spell, theme, scale, markdown, and text-input APIs require their
owner explicitly. There is no default text or spell system, active runtime or
frame, ambient theme or metric mirror, or positional text-input compatibility
path. Native spell adapters may use process resources required by the operating
system, while logical caches, ignored words, and menu state remain explicitly
owned by runtimes and components.

## Low-level ordinal focus

`Ui` has one focus model: generated `Widget_Id` values registered through
`focus`. The lower-level `Focus_Opt{&slot, id}` and `form_focus_cycle` APIs remain
available for explicit applications that deliberately own a fixed ordinal form.
They are not part of the facade: insertion, removal, or reordering transfers
ordinal focus to whichever control inherits the slot.

## Accessibility

The semantic layer records each complete focus link, so stable focus works
through app-wide focus scopes and assistive-technology focus actions. A
generated `Widget_Id` is the authoritative control identity. An explicit
semantic `field_id` remains available for application-global external identity,
and a focus link supplies the explicit tier's identity when neither is present.
`Focus_Id` is scoped by its caller-owned `Focus_State` / `Focus_Opt`. Duplicate semantic IDs
drop the later node and increment frame diagnostics. Focus-scope priority
selects the traversal tier; equal-priority scope IDs merge in draw order.

## Frame diagnostics

`ui_frame_diagnostics` returns a copied, allocation-free snapshot of input,
geometry, semantic, paint, and platform-output drops. Golden-path tests should
assert that every counter is zero. `draw_debug_overlay` displays the same data.
