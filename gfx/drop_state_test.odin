#+build !js
package gfx

import "core:testing"

@(test)
drop_lifecycle_is_bounded_and_consumed :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	_drop_native_shutdown()
	defer _drop_native_shutdown()

	_drop_hover_stage(true)
	testing.expect(t, !IsFileDragOver())
	_drop_hover_publish(g)
	testing.expect(t, IsFileDragOver())
	_drop_complete()
	testing.expect(t, !IsFileDragOver())
	testing.expect(t, IsFileDropped())

	paths := [2]string{"/tmp/one", "/tmp/two"}
	testing.expect(t, _drop_paths_replace(paths[:]))
	testing.expect_value(t, len(g.drop.paths), 2)
	files := LoadDroppedFiles()
	testing.expect_value(t, files.count, u32(2))
	testing.expect(t, IsFileDropped())
	UnloadDroppedFiles(files)
	testing.expect_value(t, len(g.drop.paths), 0)
	testing.expect(t, !IsFileDropped())

	too_large := make([]u8, MAX_DROPPED_PATH_BYTES + 1, context.temp_allocator)
	overflow := [1]string{string(too_large)}
	testing.expect(t, !_drop_paths_replace(overflow[:]))
	testing.expect_value(t, len(g.drop.paths), 0)
	testing.expect(t, !IsFileDropped())

	_drop_hover_stage(true)
	_drop_hover_publish(g)
	_drop_state_reset()
	testing.expect(t, !IsFileDragOver())
	testing.expect(t, !IsFileDropped())
}

@(test)
drop_lifecycle_isolated_between_contexts :: proc(t: ^testing.T) {
	first := new(Context)
	second := new(Context)
	defer free(first)
	defer free(second)
	defer _drop_native_shutdown_context(first)
	defer _drop_native_shutdown_context(second)

	_drop_hover_stage_context(first, true)
	_drop_hover_publish(first)
	_drop_complete_context(second)
	testing.expect(t, context_is_file_drag_over(first))
	testing.expect(t, !context_is_file_drag_over(second))
	testing.expect(t, !context_is_file_dropped(first))
	testing.expect(t, context_is_file_dropped(second))

	first_paths := [1]string{"/tmp/first"}
	second_paths := [1]string{"/tmp/second"}
	testing.expect(t, _drop_paths_replace_context(first, first_paths[:]))
	testing.expect(t, _drop_paths_replace_context(second, second_paths[:]))
	first_files := context_load_dropped_files(first)
	second_files := context_load_dropped_files(second)
	testing.expect_value(t, first_files.count, u32(1))
	testing.expect_value(t, second_files.count, u32(1))
	testing.expect_value(t, string(first_files.paths[0]), "/tmp/first")
	testing.expect_value(t, string(second_files.paths[0]), "/tmp/second")

	context_unload_dropped_files(first, first_files)
	testing.expect(t, !context_is_file_dropped(first))
	testing.expect(t, context_is_file_dropped(second))
	testing.expect_value(t, len(first.drop.paths), 0)
	testing.expect_value(t, len(second.drop.paths), 1)
}
