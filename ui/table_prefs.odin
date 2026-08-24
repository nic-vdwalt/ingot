// LIB-CANDIDATE: imports only core:*.
// Pure serialization for the persistable parts of a Table_State (column widths,
// display order, visibility, and sort). The codec produces and consumes a
// caller-owned byte buffer and performs no file I/O, so `ui` keeps its
// core:*-only boundary; the app layer pairs this with the prefs package to
// actually read and write a file. Decoding validates the blob against the
// current column set and refuses a mismatched or malformed layout, letting the
// caller fall back to table_state_init on schema drift.
package ui

import "core:fmt"
import "core:strconv"
import "core:strings"

TABLE_LAYOUT_VERSION :: 1

// table_layout_encode serializes widths, order, visibility, and sort into a
// compact, versioned, newline-delimited buffer owned by `allocator`. The state
// must already be initialized. Free the result with delete(buf, allocator).
table_layout_encode :: proc(st: ^Table_State, allocator := context.allocator) -> []u8 {
	assert(st != nil, "table_layout_encode: nil st")
	assert(st.initialized, "table_layout_encode: state not initialized")
	b: strings.Builder
	strings.builder_init(&b, allocator)

	table_layout_write_int(&b, TABLE_LAYOUT_VERSION)
	strings.write_byte(&b, ',')
	table_layout_write_int(&b, st.count)
	strings.write_byte(&b, '\n')

	for slot in 0 ..< st.count {
		if slot > 0 do strings.write_byte(&b, ',')
		table_layout_write_int(&b, int(st.order[slot]))
	}
	strings.write_byte(&b, '\n')

	for original in 0 ..< st.count {
		if original > 0 do strings.write_byte(&b, ',')
		table_layout_write_int(&b, st.visible[original] ? 1 : 0)
	}
	strings.write_byte(&b, '\n')

	for original in 0 ..< st.count {
		if original > 0 do strings.write_byte(&b, ',')
		table_layout_write_int(&b, int(st.width_px[original]))
	}
	strings.write_byte(&b, '\n')

	table_layout_write_int(&b, int(st.sort.column))
	strings.write_byte(&b, ',')
	table_layout_write_int(&b, st.sort.descending ? 1 : 0)
	strings.write_byte(&b, '\n')

	return b.buf[:]
}

// table_layout_decode parses a blob produced by table_layout_encode into `st`,
// but only when it is well-formed AND its column count matches `columns`; the
// order must be a permutation, at least one column must stay visible, widths
// must be non-negative, and the sort column must be in range. On any failure it
// returns false and leaves `st` untouched, so the caller can seed a fresh layout
// with table_state_init.
table_layout_decode :: proc(data: []u8, st: ^Table_State, columns: []Table_Column) -> bool {
	assert(st != nil, "table_layout_decode: nil st")
	assert(len(columns) > 0, "table_layout_decode: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_layout_decode: too many columns")

	lines: [5]string
	if !table_layout_split_lines(string(data), lines[:]) do return false

	header: [2]int
	if n, ok := table_layout_parse_ints(lines[0], header[:]); !ok || n != 2 do return false
	if header[0] != TABLE_LAYOUT_VERSION do return false
	count := header[1]
	if count != len(columns) do return false

	order: [TABLE_COLUMN_COUNT_MAX]int
	visible: [TABLE_COLUMN_COUNT_MAX]int
	widths: [TABLE_COLUMN_COUNT_MAX]int
	sort: [2]int
	if n, ok := table_layout_parse_ints(lines[1], order[:count]); !ok || n != count do return false
	if n, ok := table_layout_parse_ints(lines[2], visible[:count]); !ok || n != count do return false
	if n, ok := table_layout_parse_ints(lines[3], widths[:count]); !ok || n != count do return false
	if n, ok := table_layout_parse_ints(lines[4], sort[:]); !ok || n != 2 do return false

	// The order must be a permutation of 0..count-1.
	seen: [TABLE_COLUMN_COUNT_MAX]bool
	for slot in 0 ..< count {
		value := order[slot]
		if value < 0 || value >= count || seen[value] do return false
		seen[value] = true
	}
	// At least one visible column; widths non-negative.
	any_visible := false
	for original in 0 ..< count {
		if visible[original] != 0 && visible[original] != 1 do return false
		if visible[original] == 1 do any_visible = true
		if widths[original] < 0 do return false
	}
	if !any_visible do return false
	if sort[0] < -1 || sort[0] >= count do return false
	if sort[1] != 0 && sort[1] != 1 do return false

	// All valid: commit atomically.
	st.count = count
	for slot in 0 ..< count do st.order[slot] = u8(order[slot])
	for original in 0 ..< count {
		st.visible[original] = visible[original] == 1
		st.width_px[original] = i32(widths[original])
	}
	st.sort.column = i32(sort[0])
	st.sort.descending = sort[1] == 1
	st.initialized = true
	return true
}

@(private = "file")
table_layout_write_int :: proc(b: ^strings.Builder, value: int) {
	fmt.sbprint(b, value)
}

// table_layout_split_lines fills out[] with exactly len(out) newline-terminated
// lines; returns false if there are fewer.
@(private = "file")
table_layout_split_lines :: proc(text: string, out: []string) -> bool {
	produced := 0
	start := 0
	for index in 0 ..< len(text) {
		if text[index] == '\n' {
			if produced < len(out) do out[produced] = text[start:index]
			produced += 1
			start = index + 1
		}
	}
	return produced >= len(out)
}

// table_layout_parse_ints parses a comma-separated integer list into out[],
// returning the count and whether every field parsed. Empty fields fail.
@(private = "file")
table_layout_parse_ints :: proc(line: string, out: []int) -> (n: int, ok: bool) {
	start := 0
	for index in 0 ..= len(line) {
		if index == len(line) || line[index] == ',' {
			if start == index do return n, false
			if n >= len(out) do return n, false
			value, parsed := strconv.parse_int(line[start:index])
			if !parsed do return n, false
			out[n] = value
			n += 1
			start = index + 1
		}
	}
	return n, true
}
