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

Table_Begin :: proc(parent: Parent, table: ^Table_State, columns: []Table_Column) {
	_ = parent_validate(parent)
	assert(table != nil && !table.open, "Fit.Table_Begin: invalid state")
	assert(
		len(columns) > 0 && len(columns) <= TABLE_COLUMNS_MAX,
		"Fit.Table_Begin: invalid columns",
	)
	copy(table.columns[:], columns)
	table.count = i32(len(columns))
	table.open = true
	table.parent = Column(parent)
}

Table_Row :: proc(table: ^Table_State, height: i32 = 0) {
	assert(table != nil && table.open && table.row.builder == nil, "Fit.Table_Row: invalid state")
	assert(table.cell == 0 && table.count > 0, "Fit.Table_Row: invalid columns")
	options: Container_Options
	if height > 0 do options.size.height = Fixed(height)
	table.row = Row(table.parent, options)
}

Table_Cell :: proc(table: ^Table_State, text: string, options: Table_Cell_Options = {}) {
	assert(table != nil && table.open && table.row.builder != nil, "Fit.Table_Cell: row not open")
	assert(table.cell >= 0 && table.cell < table.count, "Fit.Table_Cell: row full")
	assert(text != "", "Fit.Table_Cell: empty text")
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
		{track = to_track(column.track), size = to_size(options.size)},
	)
	parent_clear(builder)
	table.cell += 1
}

Table_Row_End :: proc(table: ^Table_State) {
	assert(
		table != nil && table.open && table.row.builder != nil,
		"Fit.Table_Row_End: row not open",
	)
	assert(table.cell == table.count, "Fit.Table_Row_End: incomplete row")
	table.cell = 0
	table.row = {}
}

Table_End :: proc(table: ^Table_State) {
	assert(table != nil && table.open && table.row.builder == nil, "Fit.Table_End: invalid state")
	assert(table.cell == 0 && table.count > 0, "Fit.Table_End: invalid columns")
	table^ = {}
}
