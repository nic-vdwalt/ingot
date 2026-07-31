// The builder's panes: toolbar, palette, canvas, inspector.
//
// The canvas is the one that matters. It plays the document through
// view.view_play against the same widgets a shipping consumer would use, so
// what the user sees is the runtime rather than an approximation of it.
package main

import "core:fmt"
import "ingot:ui"
import "ingot:view"

PALETTE_CONTAINERS := [?]view.View_Kind{.Row, .Column, .Panel, .Flex_Row, .Flex_Column}

PALETTE_LEAVES := [?]view.View_Kind {
	.Button,
	.Icon_Button,
	.Back_Button,
	.Checkbox,
	.Radio,
	.Slider,
	.Text_Input,
	.Collapsible_Header,
	.Label,
	.Section_Header,
	.Status_Pill,
	.Kv_Row,
	.Progress_Bar,
	.Spinner,
	.Separator,
	.Spacer,
}

draw_toolbar :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_toolbar: invalid arguments")
	ui.scope_begin(form, "toolbar")
	defer ui.scope_end(form)
	ui.flex_row_begin(
		form,
		30,
		{ui.fit(220), ui.fixed(90), ui.fixed(90), ui.fixed(90), ui.grow()},
		gap = .SM,
	)
	ui.label(form, "Ingot view builder", ui.Text_Role.Title, ui.Ink.Heading)
	if ui.button(form, "save", "Save") do save(data)
	if ui.button(form, "load", "Load") do load(data)
	if ui.button(form, "delete", "Delete") do delete_node(data)
	draw_status(form, data)
	ui.flex_row_end(form)
}

// draw_status reports validity every frame rather than only after an action.
// A document that has stopped validating should say so while it is being
// edited, not at the moment the user tries to save it.
draw_status :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_status: invalid arguments")
	if data.status.text != "" {
		ink: ui.Ink = data.status.error ? .Danger : .Secondary
		ui.label(form, data.status.text, ui.Text_Role.Note, ink)
		return
	}
	result, ok := view.view_validate(view.view_of(&data.doc))
	if !ok {
		ui.label(
			form,
			fmt.tprintf("invalid: %v at %d", result.fault, result.node),
			ui.Text_Role.Note,
			ui.Ink.Danger,
		)
		return
	}
	ui.label(form, fmt.tprintf("%d nodes, valid", data.doc.count), ui.Text_Role.Note, ui.Ink.Muted)
}

draw_palette :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_palette: invalid arguments")
	ui.scope_begin(form, "palette")
	defer ui.scope_end(form)
	// A column, not a panel: panel_begin opens through push_column, which
	// swallows the parent's remaining space instead of taking a flex track, so
	// a panel cannot be a direct child of the flex row in draw.
	ui.column_begin(form, 0, .XS)
	defer ui.column_end(form)
	ui.padding(form, .SM)
	ui.label(form, "Containers", ui.Text_Role.Label, ui.Ink.Heading)
	for kind in PALETTE_CONTAINERS {
		if ui.button(
			form,
			fmt.tprintf("%v", kind),
			fmt.tprintf("%v", kind),
			ui.Btn_Style.Secondary,
		) {
			add_node(data, kind)
		}
	}
	ui.space(form, .SM)
	ui.label(form, "Widgets", ui.Text_Role.Label, ui.Ink.Heading)
	for kind in PALETTE_LEAVES {
		if ui.button(form, fmt.tprintf("%v", kind), fmt.tprintf("%v", kind), ui.Btn_Style.Ghost) {
			add_node(data, kind)
		}
	}
}

// draw_canvas plays the document. It refuses to play an invalid one rather than
// letting view_play's ensure calls fire: an editor mid-edit is exactly where an
// invalid document is expected, so it is an operating condition here, handled,
// not a programmer error.
draw_canvas :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_canvas: invalid arguments")
	ui.scope_begin(form, "canvas")
	defer ui.scope_end(form)
	// A column, not a panel: panel_begin opens through push_column, which
	// swallows the parent's remaining space instead of taking a flex track, so
	// a panel cannot be a direct child of the flex row in draw.
	ui.column_begin(form, 0, .SM)
	defer ui.column_end(form)
	ui.padding(form, .SM)
	ui.label(form, "Canvas", ui.Text_Role.Label, ui.Ink.Heading)
	ui.separator(form)

	source := view.view_of(&data.doc)
	result, ok := view.view_validate(source)
	if !ok {
		ui.label(
			form,
			fmt.tprintf("cannot render: %v", result.fault),
			ui.Text_Role.Body,
			ui.Ink.Danger,
		)
		return
	}
	table := bindings(data)
	if _, bound := view.view_bindings_ok(source, &table); !bound {
		ui.label(form, "cannot render: bindings do not match", ui.Text_Role.Body, ui.Ink.Danger)
		return
	}
	// The scope keeps the played document's identities from colliding with the
	// builder's own widgets, which share this Ui.
	ui.scope_begin(form, "document")
	view.view_play(form, source, &table)
	ui.scope_end(form)
	report_events(form, data)
}

// report_events shows what the played document did this frame. It is how the
// builder demonstrates the event sink, and it doubles as feedback that a button
// in the canvas is genuinely live rather than painted.
report_events :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "report_events: invalid arguments")
	if data.sink.count == 0 do return
	source := view.view_of(&data.doc)
	for index in 0 ..< int(data.sink.count) {
		event := data.sink.events[index]
		key := view.view_text(source, event.key_offset, event.key_length)
		set_status(data, fmt.tprintf("fired: %s", key))
	}
}
