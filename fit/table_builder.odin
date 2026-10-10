package fit

import "ingot:ui"

TABLE_COLUMNS_MAX :: 16
#assert(TABLE_COLUMNS_MAX <= ui.TABLE_COLUMN_COUNT_MAX)

Table_State :: struct {
	columns: [TABLE_COLUMNS_MAX]Table_Column,
	parent:  Parent,
	row:     Parent,
	count:   i32,
	cell:    i32,
	open:    bool,
}

Table_Cell_Options :: struct {
	role:  Text_Role,
	ink:   Ink,
	trunc: Truncate_Side,
	size:  Size_Options,
}

table_begin :: proc(parent: Parent, table: ^Table_State, columns: []Table_Column) {
	_ = parent_validate(parent)
	assert(table != nil && !table.open, "fit.table_begin: invalid state")
	assert(
		len(columns) > 0 && len(columns) <= TABLE_COLUMNS_MAX,
		"fit.table_begin: invalid columns",
	)
	copy(table.columns[:], columns)
	table.count = i32(len(columns))
	table.open = true
	table.parent = column(parent)
}

table_row :: proc(table: ^Table_State, height: i32 = 0) {
	assert(table != nil && table.open && table.row.builder == nil, "fit.table_row: invalid state")
	assert(table.cell == 0 && table.count > 0, "fit.table_row: invalid columns")
	options: Container_Options
	if height > 0 do options.size.height = fixed(height)
	table.row = row(table.parent, options)
}

table_cell :: proc(table: ^Table_State, text: string, options: Table_Cell_Options = {}) {
	assert(table != nil && table.open && table.row.builder != nil, "fit.table_cell: row not open")
	assert(table.cell >= 0 && table.cell < table.count, "fit.table_cell: row full")
	assert(text != "", "fit.table_cell: empty text")
	column := table.columns[table.cell]
	builder := parent_select(table.row)
	ui.fit_builder_table_cell(
		&builder.inner,
		{
			text = text,
			role = options.role,
			ink = options.ink,
			trunc = options.trunc,
			numeric = column.numeric,
		},
		{track = column.track, size = options.size},
	)
	parent_clear(builder)
	table.cell += 1
}

table_row_end :: proc(table: ^Table_State) {
	assert(
		table != nil && table.open && table.row.builder != nil,
		"fit.table_row_end: row not open",
	)
	assert(table.cell == table.count, "fit.table_row_end: incomplete row")
	table.cell = 0
	table.row = {}
}

table_end :: proc(table: ^Table_State) {
	assert(table != nil && table.open && table.row.builder == nil, "fit.table_end: invalid state")
	assert(table.cell == 0 && table.count > 0, "fit.table_end: invalid columns")
	table^ = {}
}
