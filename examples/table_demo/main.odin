// Ingot tables demo: a resizable, reorderable, sortable, hideable table with a
// pinned header over a virtual-scrolled body, plus layout persistence through
// the prefs package. This is the app-layer companion to ui's core:*-only table
// primitives — it owns the data, the sort, and the on-disk layout file.
//
//	odin run examples/table_demo -collection:ingot=.
//
// Drag a header border to resize a column, drag a header to reorder, click a
// header to sort, tick "Columns" to show the visibility menu, and use
// Save/Load to persist the layout (widths, order, visibility, sort) between
// runs via the platform prefs directory.
package main

import "core:fmt"
import "ingot:prefs"
import ui "ingot:ui"
import "ingot:ui_gfx"

APP_NAME :: "ingot-table-demo"
LAYOUT_FILE :: "table-layout.txt"

Row :: struct {
	name:  string,
	count: int,
	state: string,
}

App_State :: struct {
	columns:   [3]ui.Table_Column,
	rows:      [dynamic]Row,
	table:     ui.Table_State,
	style:     ui.Table_Style,
	selected:  int,
	show_menu: bool,
	status:    string,
}

app: ui_gfx.App
state: App_State

main :: proc() {
	state.columns = {
		{label = "Name", track = ui.grow(3, 0)},
		{label = "Count", track = ui.fixed(90), numeric = true},
		{label = "State", track = ui.grow(2, 0)},
	}
	state.style = ui.table_style_default()
	state.selected = -1
	seed_rows(&state)
	// Restore a saved layout, or seed a fresh one.
	load_layout(&state)

	_ = ui_gfx.app_run(
		&app,
		{
			width = 900,
			height = 620,
			title = "Ingot tables demo",
			session = {semantics_enabled = true},
		},
		{ui = draw},
		&state,
	)
	delete(state.rows)
}

seed_rows :: proc(data: ^App_State) {
	names := []string {
		"alpha",
		"bravo",
		"charlie",
		"delta",
		"echo",
		"foxtrot",
		"golf",
		"hotel",
		"india",
		"juliet",
		"kilo",
		"lima",
		"mike",
		"november",
		"oscar",
		"papa",
		"quebec",
		"romeo",
		"sierra",
		"tango",
		"uniform",
		"victor",
		"whiskey",
		"xray",
	}
	states := []string{"idle", "running", "blocked", "done"}
	for name, index in names {
		append(
			&data.rows,
			Row{name = name, count = (index * 37) % 500, state = states[index % len(states)]},
		)
	}
}

draw :: proc(app: ^ui_gfx.App, form: ^ui.Ui, user_data: rawptr) {
	assert(app != nil && form != nil && user_data != nil, "draw: invalid argument")
	data := cast(^App_State)user_data

	ui.padding(form, .MD)
	ui.label(form, "Ingot tables demo", ui.ui_frame_metrics(form.frame).FONT_SIZE_TITLE)
	ui.label(form, "Resize borders, drag headers to reorder, click to sort, tick Columns to hide.")
	ui.space(form, .SM)

	ui.row_begin(form, 30, .SM, .Center)
	if ui.button(form, "save", "Save layout") {
		save_layout(data)
		data.status = "Saved layout"
	}
	if ui.button(form, "load", "Load layout") {
		load_layout(data)
		data.status = "Loaded layout"
	}
	ui.checkbox(form, "toggle-menu", "Columns", &data.show_menu)
	if len(data.status) > 0 do ui.label(form, data.status)
	ui.row_end(form)

	if data.show_menu {
		ui.space(form, .XS)
		_ = ui.table_visibility_menu(form, "cols", data.columns[:], &data.table, 24)
	}

	ui.space(form, .SM)
	sort_rows(data)

	win := ui.table_begin(
		form,
		"tbl",
		data.columns[:],
		&data.table,
		data.style,
		28,
		len(data.rows),
	)
	last := min(win.first + win.visible_rows, len(data.rows))
	for index in win.first ..< last {
		row := data.rows[index]
		result := ui.table_row(
			form,
			&data.table,
			index,
			row.name,
			selected = data.selected == index,
		)
		if result.clicked do data.selected = index
		ui.cell(form, row.name)
		ui.cell_value(form, fmt.tprintf("%d", row.count))
		ui.cell(form, row.state)
		ui.table_row_close(form)
	}
	ui.table_end(form, &data.table)
}

// sort_rows orders the caller-owned data by the current header sort. The library
// never sorts data; only the direction indicator lives in Table_State.
sort_rows :: proc(data: ^App_State) {
	column := int(data.table.sort.column)
	if column < 0 do return
	rows := data.rows[:]
	// Insertion sort ascending (stable, tiny data), then reverse for descending.
	for i in 1 ..< len(rows) {
		j := i
		for j > 0 && row_less(rows[j], rows[j - 1], column) {
			rows[j], rows[j - 1] = rows[j - 1], rows[j]
			j -= 1
		}
	}
	if data.table.sort.descending {
		for i in 0 ..< len(rows) / 2 {
			rows[i], rows[len(rows) - 1 - i] = rows[len(rows) - 1 - i], rows[i]
		}
	}
}

row_less :: proc(a, b: Row, column: int) -> bool {
	switch column {
	case 0:
		return a.name < b.name
	case 1:
		return a.count < b.count
	case 2:
		return a.state < b.state
	}
	return false
}

// save_layout encodes the caller-owned layout and writes it through prefs.
save_layout :: proc(data: ^App_State) {
	blob := ui.table_layout_encode(&data.table, context.temp_allocator)
	_ = prefs.write(APP_NAME, LAYOUT_FILE, blob)
}

// load_layout reads the layout file and decodes it; on a missing or drifted
// file it falls back to a fresh seed so the table always renders.
load_layout :: proc(data: ^App_State) {
	if bytes, ok := prefs.read(APP_NAME, LAYOUT_FILE, context.temp_allocator); ok {
		if ui.table_layout_decode(bytes, &data.table, data.columns[:]) do return
	}
	data.table.initialized = false // force a clean reseed on missing/drifted file
	ui.table_state_init(&data.table, data.columns[:])
}
