# UI state and stable focus

Ingot keeps long-lived widget state in application data. There is no retained
widget tree or hidden map keyed by labels. Group state by screen or reusable
component so ownership and teardown follow that component's lifetime.

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
undo history, mention pills, and wrapped-line memoization. Do not copy an
`Input_Box` after first use. Call `input_box_destroy` before discarding its
owner. `input_box_reset` clears logical state while retaining reusable builder
and undo-stack capacity.

## Stable focus

New conditional or dynamic interfaces should pass explicit nonzero `Focus_Id`
values to auto-layout widgets. IDs are unique only within one `Ui` frame.
Registration order defines Tab order; the ID defines logical identity.

```odin
TITLE_ID :: ui.Focus_Id(1)
ENABLED_ID :: ui.Focus_Id(2)
SAVE_ID :: ui.Focus_Id(3)

ui.ui_begin(&form.ui, x, y, w, h)
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
