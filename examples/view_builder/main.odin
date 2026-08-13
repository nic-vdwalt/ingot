// The view builder: an editor whose document is a view.
//
// Three panes. The palette on the left is a source of draggable widgets, the
// canvas in the middle plays the document, and the inspector on the right is a
// config panel for the selected element.
//
// The canvas is the point. It is not a preview that approximates the runtime -
// it *is* the runtime, calling the same view_play against the same widgets. A
// builder whose preview had its own renderer would be a second implementation
// of the semantics, which is the thing this package is designed to avoid.
//
// The canvas has two modes, because it has two contradictory jobs:
//
//   - Edit (default): an input-claiming overlay covers the canvas, so widgets
//     beneath are inert and the mouse selects. Hover outlines the element under
//     the cursor; click selects it; clicking empty canvas deselects. Dropping a
//     palette widget inserts it into the container under the cursor.
//   - Live: the widgets are interactive and the event sink reports what fired.
//
// Where each element sits on screen comes from view.Play_Trace, filled by
// view_play_traced each frame - the same data the trace tests hit headlessly.
//
// Save writes a .ingv through prefs.write, which is atomic natively and backed
// by localStorage on web. Generating Odin source from that file is
// tools/viewc's job, deliberately not this program's.
package main

import "core:fmt"
import rl "ingot:gfx"
import "ingot:prefs"
import ui "ingot:fit"
import ui_gfx "ingot:fit"
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

// A drag becomes real after the pointer moves this far from the press. Under
// the threshold a press-release is a click, which still adds under the current
// selection - the keyboard-friendly path.
DRAG_THRESHOLD_PX :: f32(4)

// Compact the text blob before an editing session can exhaust it. Three
// quarters leaves headroom for the frames between the check and the next edit.
COMPACT_THRESHOLD :: u32(view.VIEW_TEXT_BYTES_MAX * 3 / 4)

Mode :: enum u8 {
	Edit,
	Live,
}

// Drag is the palette drag state machine. armed = pressed on a row, threshold
// not yet crossed; active = a real drag with a ghost following the mouse.
Drag :: struct {
	kind:   view.View_Kind,
	origin: ui.Vector2,
	armed:  bool,
	active: bool,
}

Status :: struct {
	text:  string,
	error: bool,
}

State :: struct {
	doc:       view.View_Doc,
	selected:  i32,
	mode:      Mode,
	drag:      Drag,
	// Where every node landed last frame. Selection, hover, and drop targeting
	// are all hit-tests over this.
	trace:     view.Play_Trace,
	// The played document's on-screen area, kept so the drop logic knows
	// whether a release happened over the canvas at all.
	canvas:    ui.Rect_I32,
	// Storage the played document binds to. One slot per kind, shared by every
	// node of that kind, which is enough to make the Live canvas interactive.
	flag:      bool,
	number:    f32,
	integer:   i32,
	box:       ui.Input_Box,
	slots:     [BINDING_COUNT]view.Binding,
	sink:      view.Event_Sink,
	// Inspector text fields. box_owner is the node the fields were loaded
	// from: writeback compares against it, never against the current
	// selection, so changing selection mid-edit cannot write one node's text
	// into another.
	key_box:   ui.Input_Box,
	label_box: ui.Input_Box,
	value_box: ui.Input_Box,
	box_owner: i32,
	status:    Status,
}

app: ui_gfx.Host_App
state: State

main :: proc() {
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	ui.input_box_init(&state.box)
	ui.input_box_init(&state.key_box)
	ui.input_box_init(&state.label_box)
	ui.input_box_init(&state.value_box)
	state.box_owner = view.VIEW_NODE_NONE
	seed_document(&state)
	inspector_load(&state)
	_ = ui_gfx.app_run(
		&app,
		{
			width = 1100,
			height = 720,
			title = "Ingot view builder",
			flags = flags,
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			event_waiting = true,
			session = {semantics_enabled = true},
		},
		{ui = draw, shutdown = shutdown},
		&state,
	)
}

draw :: proc(app: ^ui_gfx.Host_App, form: ^ui.Ui, userdata: rawptr) {
	assert(app != nil && form != nil, "draw: invalid app or UI")
	data := cast(^State)userdata
	assert(data != nil, "draw: nil state")
	when SMOKE do smoke_step(data)
	// The blob accumulates garbage as the inspector re-interns text; compact
	// before it can fill, so an editing session never hits the hard cap.
	if data.doc.text_len > COMPACT_THRESHOLD do view.doc_text_compact(&data.doc)
	ui.padding(form, .MD)
	ui.scope_begin(form, "builder")
	draw_toolbar(form, data)
	ui.space(form, .SM)
	ui.flex_row_begin(form, ui.remaining_rect(form).h, {ui.fixed(240), ui.grow(), ui.fixed(300)})
	draw_palette(form, data)
	draw_canvas(form, data)
	draw_inspector(form, data)
	ui.flex_row_end(form)
	ui.scope_end(form)
	drag_frame(form, data)
}

shutdown :: proc(app: ^ui_gfx.Host_App, userdata: rawptr) {
	assert(app != nil && userdata != nil, "shutdown: invalid state")
	data := cast(^State)userdata
	ui.input_box_destroy(&data.box)
	ui.input_box_destroy(&data.key_box)
	ui.input_box_destroy(&data.label_box)
	ui.input_box_destroy(&data.value_box)
}

// select_node moves the selection and reloads the inspector fields. Every
// selection change funnels through here so the fields can never show one
// node's text while writing to another.
select_node :: proc(data: ^State, node: i32) {
	assert(data != nil, "select_node: nil state")
	if data.selected == node && data.box_owner == node do return
	data.selected = node
	inspector_load(data)
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
	inspector_load(data)
	set_status(data, fmt.tprintf("loaded %d nodes", data.doc.count))
}
