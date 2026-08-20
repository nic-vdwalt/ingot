// Fit-only view document builder. The editor owns the document and bindings;
// Fit owns application lifecycle and frame composition.
package main

import "core:fmt"
import fit "ingot:fit"
import "ingot:prefs"
import "ingot:view"

APP_NAME :: "ingot-view-builder"
VIEW_FILE :: "views/scratch.ingv"
SMOKE :: #config(INGOT_SMOKE, false)

State :: struct {
	doc:      view.View_Doc,
	selected: i32,
	status:   string,
}

app: fit.App
state: State

main :: proc() {
	seed_document(&state)
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	_ = fit.Run(
		&app,
		{
			width = 1100,
			height = 720,
			title = "Ingot view builder",
			flags = flags,
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			event_waiting = !SMOKE,
			session = {semantics_enabled = true},
		},
		draw,
		&state,
	)
}

draw :: proc(builder: ^fit.Builder, ctx: rawptr) {
	data := cast(^State)ctx
	when SMOKE do smoke_step(data)
	root := fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Ingot view builder", {role = .Title})
	fit.Label(
		root,
		"The document is caller-owned; Fit rebuilds this editor every frame.",
		{ink = .Secondary},
	)
	actions := fit.Row(root, {gap = .SM})
	fit.Button(actions, "save", "Save", fit.action(save_action, data))
	fit.Button(actions, "load", "Load", fit.action(load_action, data))
	fit.Button(actions, "add", "Add label", fit.action(add_action, data))
	fit.Button(actions, "delete", "Delete last", fit.action(delete_action, data))
	fit.Label(root, fmt.tprintf("%d nodes", data.doc.count), {role = .Label})
	if data.status != "" do fit.Label(root, data.status, {ink = .Secondary})
	nodes := fit.Column(root, {gap = .XS})
	source := view.view_of(&data.doc)
	walk := view.walk_begin(source)
	for _ in 0 ..< view.WALK_STEPS_MAX {
		step, more := view.walk_next(&walk)
		if !more do break
		if step.event != .Enter do continue
		node := data.doc.nodes[step.node]
		label := view.view_text(source, node.label_offset, node.label_length)
		fit.Label(nodes, fmt.tprintf("%*s%v %s", int(step.depth) * 2, "", node.kind, label))
	}
}

save_action :: proc(ctx: rawptr) {
	data := cast(^State)ctx
	assert(data != nil, "save_action: nil state")
	save(data)
}

load_action :: proc(ctx: rawptr) {
	data := cast(^State)ctx
	assert(data != nil, "load_action: nil state")
	load(data)
}

add_action :: proc(ctx: rawptr) {
	data := cast(^State)ctx
	assert(data != nil, "add_action: nil state")
	add_label(data)
}

delete_action :: proc(ctx: rawptr) {
	data := cast(^State)ctx
	assert(data != nil, "delete_action: nil state")
	delete_last(data)
}

save :: proc(data: ^State) {
	source := view.view_of(&data.doc)
	if result, ok := view.view_validate(source); !ok {
		data.status = fmt.tprintf("invalid document: %v", result.fault)
		return
	}
	buffer := make([]u8, view.view_encoded_size(source), context.temp_allocator)
	written, encoded := view.view_encode(source, buffer)
	if !encoded || !prefs.write(APP_NAME, VIEW_FILE, buffer[:written]) {
		data.status = "save failed"
		return
	}
	data.status = fmt.tprintf("saved %d bytes", written)
}

load :: proc(data: ^State) {
	bytes, ok := prefs.read(APP_NAME, VIEW_FILE)
	if !ok {
		data.status = "no saved document"
		return
	}
	loaded := new(view.View_Doc, context.temp_allocator)
	if result, decoded := view.view_decode(bytes, loaded); !decoded {
		data.status = fmt.tprintf("load failed: %v", result.fault)
		return
	}
	data.doc = loaded^
	data.status = fmt.tprintf("loaded %d nodes", data.doc.count)
}
