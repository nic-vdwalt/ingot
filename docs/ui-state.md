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
scopes. Cache results are borrowed until the owning system is reset or
destroyed. Persistent widget behavior never lives in either context: keep
`Button_State`, `Slider_State`, `Input_Box`, menu state, and scrollbar state in
the component that draws them. Stable IDs identify focus targets; they do not
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

Native applications destroy widget state and `Ui_Runtime` before `CloseWindow`.
Web `rl.run` registers the browser animation-frame callback and returns, so web
applications must keep runtime state alive until an explicit browser shutdown
hook exists.

For macOS Retina verification, run `odin run examples/render_fixture
-collection:ingot=.` first on a standard-density display and then on a Retina
display. Move the live window between displays and confirm the boxed runtime
label, truncation row, and text input stay aligned and sharpen after the DPI
refresh without a mixed-atlas frame.

Consumers not yet migrated to this API must remain pinned to an earlier Ingot
revision. In particular, `ww-app` is intentionally deferred.

```odin
runtime: ui.Ui_Runtime
frame: ui.Ui_Frame
form: Editor_Form

ui.ui_runtime_init(&runtime)
ui.ui_frame_begin(&frame, &runtime)
ui.ui_begin_frame(&form.ui, &frame, x, y, w, h)
// Draw roots in the order their overlays and semantics should appear.
ui.ui_end(&form.ui)
ui.ui_frame_end(&frame)
```

## Stable focus

New conditional or dynamic interfaces should pass explicit nonzero `Focus_Id`
values to auto-layout widgets. IDs are unique only within one `Ui` frame.
Registration order defines Tab order; the ID defines logical identity.

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

## Legacy compatibility boundary

No-context font, wrap, spell, theme, scale, markdown, and positional text-input
APIs remain temporarily for source compatibility. New code must use
`Ui_Runtime`, `Ui_Frame`, explicit `Text_System`/`Spell_System`,
`Markdown_Context`, and caller-owned `Text_Input_State`. Runtime-aware internals
must not call no-context adapters. Removal is a separately reviewed breaking
release after known consumers are migrated.

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
through app-wide focus scopes and assistive-technology focus actions.
Accessibility node identity is still derived independently from explicit
semantic identity such as a text input's `field_id`; a `Focus_Id` is scoped to
one `Ui` and is not an application-global accessibility identifier.
