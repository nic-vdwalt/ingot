package fit

import "ingot:ui"

TABLE_COLUMNS_MAX :: 16
#assert(TABLE_COLUMNS_MAX <= ui.TABLE_COLUMN_COUNT_MAX)

Table_State :: struct {
	columns: [TABLE_COLUMNS_MAX]Table_Column,
	count:   i32,
	cell:    i32,
	open:    bool,
	row:     bool,
}

Table_Cell_Options :: struct {
	role:  Text_Role,
	ink:   Ink,
	trunc: Truncate_Side,
	size:  Size_Options,
}

Table_Begin :: proc(builder: ^Builder, table: ^Table_State, columns: []Table_Column) {
	assert(builder != nil && builder.bound, "Fit.Table_Begin: builder not bound")
	assert(table != nil && !table.open, "Fit.Table_Begin: invalid state")
	assert(
		len(columns) > 0 && len(columns) <= TABLE_COLUMNS_MAX,
		"Fit.Table_Begin: invalid columns",
	)
	copy(table.columns[:], columns)
	table.count = i32(len(columns))
	table.open = true
	Column(builder)
}

Table_Row :: proc(builder: ^Builder, table: ^Table_State, height: i32 = 0) {
	assert(builder != nil && builder.bound, "Fit.Table_Row: builder not bound")
	assert(table != nil && table.open && !table.row, "Fit.Table_Row: invalid state")
	assert(table.cell == 0 && table.count > 0, "Fit.Table_Row: invalid columns")
	options: Container_Options
	if height > 0 do options.size.height = Fixed(height)
	Row(builder, options)
	table.row = true
}

Table_Cell :: proc(
	builder: ^Builder,
	table: ^Table_State,
	text: string,
	options: Table_Cell_Options = {},
) {
	assert(builder != nil && builder.bound, "Fit.Table_Cell: builder not bound")
	assert(table != nil && table.open && table.row, "Fit.Table_Cell: row not open")
	assert(table.cell >= 0 && table.cell < table.count, "Fit.Table_Cell: row full")
	assert(text != "", "Fit.Table_Cell: empty text")
	column := table.columns[table.cell]
	ui.fit_builder_table_cell(
		&builder.inner,
		{
			text = text,
			role = ui.Text_Role(options.role),
			ink = ui.Ink(options.ink),
			trunc = ui.Truncate_Side(options.trunc),
			numeric = column.numeric,
		},
		{track = to_track(column.track), size = to_size(options.size)},
	)
	table.cell += 1
}

Table_Row_End :: proc(builder: ^Builder, table: ^Table_State) {
	assert(builder != nil && builder.bound, "Fit.Table_Row_End: builder not bound")
	assert(table != nil && table.open && table.row, "Fit.Table_Row_End: row not open")
	assert(table.cell == table.count, "Fit.Table_Row_End: incomplete row")
	End(builder)
	table.cell = 0
	table.row = false
}

Table_End :: proc(builder: ^Builder, table: ^Table_State) {
	assert(builder != nil && builder.bound, "Fit.Table_End: builder not bound")
	assert(table != nil && table.open && !table.row, "Fit.Table_End: invalid state")
	assert(table.cell == 0 && table.count > 0, "Fit.Table_End: invalid columns")
	End(builder)
	table^ = {}
}
