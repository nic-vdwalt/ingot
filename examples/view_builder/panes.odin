// The builder's panes: toolbar, palette, canvas, and the drag machinery.
//
// The canvas plays the document through view.view_play_traced against the same
// widgets a shipping consumer would use, so what the user sees is the runtime.
// The trace is what makes it editable: hover, selection, and drop targeting
// are hit-tests over the per-node rects it records.
package main

import "core:fmt"
import ui "ingot:fit"
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
		{ui.fit(200), ui.fixed(110), ui.fixed(80), ui.fixed(80), ui.grow()},
		gap = .SM,
	)
	ui.label(form, "Ingot view builder", ui.Text_Role.Title, ui.Ink.Heading)
	draw_mode_toggle(form, data)
	if ui.button(form, "save", "Save") do save(data)
	if ui.button(form, "load", "Load") do load(data)
	draw_status(form, data)
	ui.flex_row_end(form)
}

// draw_mode_toggle is one button showing the mode you would switch TO, because
// a two-state toggle labelled with its current state reads ambiguously.
draw_mode_toggle :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_mode_toggle: invalid arguments")
	label := data.mode == .Edit ? "▶ Live" : "✎ Edit"
	style := data.mode == .Edit ? ui.Btn_Style.Secondary : ui.Btn_Style.Primary
	if ui.button(form, "mode", label, style) do toggle_mode(data)
}

toggle_mode :: proc(data: ^State) {
	assert(data != nil, "toggle_mode: nil state")
	data.mode = data.mode == .Edit ? .Live : .Edit
	set_status(
		data,
		data.mode == .Edit ? "edit mode: click to select" : "live mode: widgets active",
	)
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

// --- palette -----------------------------------------------------------------

draw_palette :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_palette: invalid arguments")
	ui.scope_begin(form, "palette")
	defer ui.scope_end(form)
	// A column, not a panel: panel_begin swallows the parent's remaining space
	// instead of taking a flex track, so a panel cannot sit in the flex row.
	ui.column_begin(form, 0, .XS)
	defer ui.column_end(form)
	ui.padding(form, .SM)
	ui.label(form, "Drag onto the canvas", ui.Text_Role.Label, ui.Ink.Heading)
	ui.label(form, "or click to add to selection", ui.Text_Role.Note, ui.Ink.Muted)
	ui.space(form, .SM)
	ui.label(form, "Containers", ui.Text_Role.Label, ui.Ink.Secondary)
	for kind in PALETTE_CONTAINERS do palette_row(form, data, kind)
	ui.space(form, .SM)
	ui.label(form, "Widgets", ui.Text_Role.Label, ui.Ink.Secondary)
	for kind in PALETTE_LEAVES do palette_row(form, data, kind)
}

// palette_row is a manual widget rather than ui.button, because a button fires
// on release and a drag has to start on press. interact gives press/hover on
// the row's rect; the drag state machine in drag_frame does the rest.
palette_row :: proc(form: ^ui.Ui, data: ^State, kind: view.View_Kind) {
	assert(form != nil && data != nil, "palette_row: invalid arguments")
	rect := ui.slot_next(form, ui.remaining_rect(form).w, 24)
	if rect.w <= 0 || rect.h <= 0 do return
	act := ui.interact(form.frame, ui.rect_f32(rect))
	visual: ui.Visual_State = .Rest
	if act.hovered do visual = .Hover
	if data.drag.armed && data.drag.kind == kind do visual = .Pressed
	ui.draw_surface(form.frame, ui.rect_f32(rect), .Chip, visual, .SM)
	metrics := ui.ui_frame_metrics(form.frame)
	text_y := rect.y + (rect.h - metrics.FONT_SIZE_LABEL) / 2
	ui.text(form.frame, fmt.tprintf("%v", kind), rect.x + 8, text_y, .Label, .Primary)
	if act.hovered do ui.request_cursor(form.frame, .POINTING_HAND)
	if act.pressed {
		data.drag = Drag {
			kind   = kind,
			origin = ui.get_mouse_position(form.frame),
			armed  = true,
		}
	}
}

// --- drag state machine ------------------------------------------------------

// drag_frame runs after every pane has drawn, so the ghost and the drop
// highlight paint above the whole frame and the release handler sees the final
// trace. It owns the whole armed -> active -> released lifecycle.
drag_frame :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "drag_frame: invalid arguments")
	if !data.drag.armed do return
	mouse := ui.get_mouse_position(form.frame)

	if !data.drag.active {
		delta := ui.Vector2{mouse.x - data.drag.origin.x, mouse.y - data.drag.origin.y}
		if delta.x * delta.x + delta.y * delta.y >= DRAG_THRESHOLD_PX * DRAG_THRESHOLD_PX {
			data.drag.active = true
		}
	}

	if data.drag.active {
		ui.request_cursor(form.frame, .POINTING_HAND)
		target := drop_target(data, mouse)
		drag_overlays(form, data, mouse, target)
		if !ui.is_mouse_button_down(form.frame, .LEFT) {
			drag_drop(data, target)
			return
		}
		return
	}

	// Armed but never crossed the threshold: a release is a plain click, which
	// adds under the current selection - the keyboard-friendly path.
	if !ui.is_mouse_button_down(form.frame, .LEFT) {
		kind := data.drag.kind
		data.drag = {}
		add_node_into(data, add_target(data), kind)
	}
}

// drop_target resolves the container under the mouse, but only while the mouse
// is over the canvas: a drop on the palette or inspector must not insert.
drop_target :: proc(data: ^State, mouse: ui.Vector2) -> i32 {
	assert(data != nil, "drop_target: nil state")
	if !point_in_rect(mouse, data.canvas) do return view.VIEW_NODE_NONE
	source := view.view_of(&data.doc)
	target := view.trace_container_at(&data.trace, source, mouse)
	if target == view.VIEW_NODE_NONE && data.doc.count > 0 {
		// Over the canvas but below the last element: land in the root, so a
		// drop on empty canvas space still does the obvious thing.
		if view.view_kind_is_container(data.doc.nodes[0].kind) do return 0
	}
	return target
}

// drag_overlays paints the ghost chip and the drop-target highlight on a
// popup layer with input claimed, so nothing beneath reacts mid-drag.
drag_overlays :: proc(form: ^ui.Ui, data: ^State, mouse: ui.Vector2, target: i32) {
	assert(form != nil && data != nil, "drag_overlays: invalid arguments")
	frame := form.frame
	theme := ui.ui_frame_theme(frame)
	ui.layer_begin(frame, ui.Z_POPUP, claim = ui.rect_f32(data.canvas))
	defer ui.layer_end(frame)

	if target != view.VIEW_NODE_NONE {
		rect := view.trace_rect(&data.trace, target)
		if rect.w > 0 && rect.h > 0 {
			ui.draw_rectangle_lines_ex(frame, ui.rect_f32(rect), 2, theme.fg_accent)
			tint := theme.fg_accent
			tint.a = 24
			ui.draw_rectangle_rec(frame, ui.rect_f32(rect), tint)
		}
	}

	label := fmt.tprintf("%v", data.drag.kind)
	metrics := ui.ui_frame_metrics(frame)
	width := ui.measure_text_string_frame(frame, label, metrics.FONT_SIZE_LABEL) + 20
	chip := ui.Float_Rect{mouse.x + 12, mouse.y + 12, f32(width), 26}
	ui.draw_rectangle_rounded(frame, chip, 0.4, 8, theme.bg_panel)
	ui.draw_rectangle_rounded_lines_ex(frame, chip, 0.4, 8, 1, theme.fg_accent)
	ui.draw_text_string(
		frame,
		label,
		i32(chip.x) + 10,
		i32(chip.y) + (26 - metrics.FONT_SIZE_LABEL) / 2,
		metrics.FONT_SIZE_LABEL,
		theme.fg_primary,
	)
}

// drag_drop commits or cancels. Only a release over a live container mutates
// the document; anywhere else the drag simply evaporates, because a missed
// drop should never insert somewhere surprising.
drag_drop :: proc(data: ^State, target: i32) {
	assert(data != nil, "drag_drop: nil state")
	kind := data.drag.kind
	data.drag = {}
	if target == view.VIEW_NODE_NONE {
		set_status(data, "drop cancelled")
		return
	}
	add_node_into(data, target, kind)
}

// --- canvas ------------------------------------------------------------------

// draw_canvas plays the document. It refuses to play an invalid one rather than
// letting view_play's ensure calls fire: an editor mid-edit is exactly where an
// invalid document is expected, so it is an operating condition here, handled,
// not a programmer error.
draw_canvas :: proc(form: ^ui.Ui, data: ^State) {
	assert(form != nil && data != nil, "draw_canvas: invalid arguments")
	ui.scope_begin(form, "canvas")
	defer ui.scope_end(form)
	ui.column_begin(form, 0, .SM)
	defer ui.column_end(form)
	ui.padding(form, .SM)
	mode_note := data.mode == .Edit ? "Canvas — click to select" : "Canvas — live"
	ui.label(form, mode_note, ui.Text_Role.Label, ui.Ink.Heading)
	ui.separator(form)
	data.canvas = ui.remaining_rect(form)

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
	view.view_play_traced(form, source, &table, &data.trace)
	ui.scope_end(form)

	if data.mode == .Edit {
		canvas_edit_overlay(form, data, source)
	} else {
		report_events(form, data, source)
	}
}

// canvas_edit_overlay is Edit mode's interaction layer: it claims input over
// the canvas so the played widgets are inert, outlines the hovered element,
// outlines and tags the selection, and turns clicks into selection changes.
//
// Known edge, accepted: keyboard focus a widget acquired in Live mode can
// persist into Edit mode, because the claim occludes hover, not focus. It is
// cosmetic - Edit mode's overlay swallows the clicks that would use it.
canvas_edit_overlay :: proc(form: ^ui.Ui, data: ^State, source: view.View) {
	assert(form != nil && data != nil, "canvas_edit_overlay: invalid arguments")
	frame := form.frame
	theme := ui.ui_frame_theme(frame)
	ui.layer_begin(frame, ui.Z_POPUP, claim = ui.rect_f32(data.canvas))
	defer ui.layer_end(frame)

	mouse := ui.get_mouse_position(frame)
	over_canvas := point_in_rect(mouse, data.canvas)

	// Hover feedback, suppressed while a drag is in flight: the drop highlight
	// is the feedback then, and two competing outlines read as noise.
	hovered := i32(view.VIEW_NODE_NONE)
	if over_canvas && !data.drag.active {
		hovered = view.trace_node_at(&data.trace, source, mouse)
		if hovered != view.VIEW_NODE_NONE && hovered != data.selected {
			rect := view.trace_rect(&data.trace, hovered)
			ui.draw_rectangle_lines_ex(frame, ui.rect_f32(rect), 1, theme.border_color)
			ui.request_cursor(frame, .POINTING_HAND)
		}
	}

	// Selection outline + kind tag.
	selected := view.trace_rect(&data.trace, data.selected)
	if selected.w > 0 && selected.h > 0 {
		ui.draw_rectangle_lines_ex(frame, ui.rect_f32(selected), 2, theme.fg_accent)
		selection_tag(frame, data, selected)
	}

	if over_canvas && !data.drag.active && ui.is_mouse_button_pressed(frame, .LEFT) {
		select_node(data, hovered != view.VIEW_NODE_NONE ? hovered : i32(view.VIEW_NODE_NONE))
	}
}

// selection_tag draws the selected node's kind in a small chip pinned to the
// top-left of its outline, so what is selected is always named on the canvas
// itself rather than only in the inspector.
selection_tag :: proc(frame: ^ui.Ui_Frame, data: ^State, selected: ui.Rect_I32) {
	assert(frame != nil && data != nil, "selection_tag: invalid arguments")
	theme := ui.ui_frame_theme(frame)
	label := fmt.tprintf("%v", data.doc.nodes[data.selected].kind)
	metrics := ui.ui_frame_metrics(frame)
	size := metrics.FONT_SIZE_NOTE
	width := ui.measure_text_string_frame(frame, label, size) + 10
	tag_h := size + 6
	tag := ui.Float_Rect{f32(selected.x), f32(selected.y - tag_h - 2), f32(width), f32(tag_h)}
	// Keep the tag on screen when the selection touches the canvas top.
	if tag.y < f32(data.canvas.y) do tag.y = f32(selected.y) + 2
	ui.draw_rectangle_rounded(frame, tag, 0.5, 6, theme.fg_accent)
	ui.draw_text_string(frame, label, i32(tag.x) + 5, i32(tag.y) + 3, size, theme.fg_on_accent)
}

// report_events shows what the played document did this frame in Live mode.
report_events :: proc(form: ^ui.Ui, data: ^State, source: view.View) {
	assert(form != nil && data != nil, "report_events: invalid arguments")
	if data.sink.count == 0 do return
	for index in 0 ..< int(data.sink.count) {
		event := data.sink.events[index]
		key := view.view_text(source, event.key_offset, event.key_length)
		set_status(data, fmt.tprintf("fired: %s", key))
	}
}

point_in_rect :: proc(point: ui.Vector2, rect: ui.Rect_I32) -> bool {
	if rect.w <= 0 || rect.h <= 0 do return false
	x := i32(point.x)
	y := i32(point.y)
	return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}
