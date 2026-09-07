#+build js
package main

// The web build is single-threaded; the serial path keeps the same signature
// and produces byte-identical output to the native striped path.

TERRAIN_BAKE_MAX_WORKERS :: 1

terrain_bake_worker_count :: proc() -> int {
	return 1
}

terrain_rows_parallel :: proc(
	row_start, row_end: int,
	data: rawptr,
	work: proc(data: rawptr, row_start, row_end: int),
) {
	assert(row_start <= row_end, "terrain_rows_parallel: bad range")
	assert(work != nil, "terrain_rows_parallel: nil work")
	if row_start >= row_end do return
	work(data, row_start, row_end)
}
