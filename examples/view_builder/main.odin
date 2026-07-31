// The view builder: an editor whose document is a view.
//
// It is three panes. The palette adds a node under the selection, the canvas
// plays the document through view.view_play exactly as a shipping consumer
// would, and the inspector edits the selected node's tokens.
//
// The canvas is the point. It is not a preview that approximates the runtime -
// it *is* the runtime, calling the same view_play against the same widgets. A
// builder whose preview had its own renderer would be a second implementation
// of the semantics, which is the thing this package is designed to avoid.
//
// Save writes a .ingv through prefs.write, which is atomic natively and backed
// by localStorage on web. Generating Odin source from that file is tools/viewc's
// job, deliberately not this program's: the builder produces documents, and how
// a consumer chooses to consume one is a separate decision.
package main

import "core:fmt"
import rl "ingot:gfx"
import "ingot:prefs"
import "ingot:ui"
import "ingot:ui_gfx"
import "ingot:view"

APP_NAME :: "ingot-view-builder"
VIEW_FILE :: "views/scratch.ingv"

// The binding table the canvas plays against. It is fixed and small because the
// builder's job is to lay out a document, not to model an application's state:
// a real consumer supplies its own table over the same document.
BINDING_BOOLEAN :: 0
BINDING_NUMBER :: 1
BINDING_INTEGER :: 2
BINDING_TEXT :: 3
BINDING_COUNT :: 4

Status :: struct {
	text:  string,
	error: bool,
}

State :: struct {
	doc:        view.View_Doc,
	selected:   i32,
	// Storage the played document binds to. One slot per kind, shared by every
	// node of that kind, which is enough to make the canvas interactive.
	flag:       bool,
	number:     f32,
	integer:    i32,
	box:        ui.Input_Box,
	slots:      [BINDING_COUNT]view.Binding,
	sink:       view.Event_Sink,
	status:     Status,
	// Kept so the encoded size is visible while editing: a document that will
	// not fit its bounds should be obvious before the save fails.
	last_bytes: int,
}

app: ui_gfx.App
state: State

main :: proc() {
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	ui.input_box_init(&state.box)
	seed_document(&state)
	_ = ui_gfx.app_run(
		&app,
		{
			width = 1100,
			height = 720,
			title = "Ingot view builder",
			flags = flags,
			target_fps = 60,
			event_waiting = true,
			session = {semantics_enabled = true},
		},
		{ui = draw, shutdown = shutdown},
		&state,
	)
}

draw :: proc(app: ^ui_gfx.App, form: ^ui.Ui, userdata: rawptr) {
	assert(app != nil && form != nil, "draw: invalid app or UI")
	data := cast(^State)userdata
	assert(data != nil, "draw: nil state")
	when SMOKE do smoke_step(data)
	ui.padding(form, .MD)
	ui.scope_begin(form, "builder")
	draw_toolbar(form, data)
	ui.space(form, .SM)
	ui.flex_row_begin(form, ui.remaining_rect(form).h, {ui.fixed(260), ui.grow(), ui.fixed(280)})
	draw_palette(form, data)
	draw_canvas(form, data)
	draw_inspector(form, data)
	ui.flex_row_end(form)
	ui.scope_end(form)
}

shutdown :: proc(app: ^ui_gfx.App, userdata: rawptr) {
	assert(app != nil && userdata != nil, "shutdown: invalid state")
	data := cast(^State)userdata
	ui.input_box_destroy(&data.box)
}

// bindings assembles the table fresh each frame. Rebuilding rather than caching
// keeps it correct if the state moves, and it is four assignments.
bindings :: proc(data: ^State) -> view.Bindings {
	assert(data != nil, "bindings: nil state")
	data.slots[BINDING_BOOLEAN] = view.bind_boolean(&data.flag)
	data.slots[BINDING_NUMBER] = view.bind_number(&data.number)
	data.slots[BINDING_INTEGER] = view.bind_integer(&data.integer)
	data.slots[BINDING_TEXT] = view.bind_text(&data.box)
	return view.Bindings{slots = data.slots[:], events = &data.sink}
}

set_status :: proc(data: ^State, text: string, is_error: bool = false) {
	assert(data != nil, "set_status: nil state")
	data.status = Status {
		text  = text,
		error = is_error,
	}
}

// save encodes the document and writes it through prefs, which is atomic on
// native and localStorage-backed on web. The encode buffer is temp-allocated:
// it lives for one frame and a builder should not hold a second copy of the
// document just to have somewhere to put bytes.
save :: proc(data: ^State) {
	assert(data != nil, "save: nil state")
	source := view.view_of(&data.doc)
	if result, ok := view.view_validate(source); !ok {
		set_status(
			data,
			fmt.tprintf("cannot save: %v at node %d", result.fault, result.node),
			true,
		)
		return
	}
	buffer := make([]u8, view.view_encoded_size(source), context.temp_allocator)
	written, encoded := view.view_encode(source, buffer)
	if !encoded {
		set_status(data, "cannot save: encoding failed", true)
		return
	}
	data.last_bytes = written
	if !prefs.write(APP_NAME, VIEW_FILE, buffer[:written]) {
		set_status(data, "cannot save: write failed", true)
		return
	}
	set_status(data, fmt.tprintf("saved %d bytes to %s", written, VIEW_FILE))
}

// load replaces the document only if the file decodes. A failed load leaves the
// editor exactly as it was, because losing unsaved work to a corrupt file on
// disk would be a worse outcome than not loading.
load :: proc(data: ^State) {
	assert(data != nil, "load: nil state")
	bytes, ok := prefs.read(APP_NAME, VIEW_FILE)
	if !ok {
		set_status(data, fmt.tprintf("no saved view at %s", VIEW_FILE), true)
		return
	}
	loaded := new(view.View_Doc, context.temp_allocator)
	result, decoded := view.view_decode(bytes, loaded)
	if !decoded {
		set_status(data, fmt.tprintf("cannot load: %v", result.fault), true)
		return
	}
	data.doc = loaded^
	data.selected = 0
	set_status(data, fmt.tprintf("loaded %d nodes", data.doc.count))
}
