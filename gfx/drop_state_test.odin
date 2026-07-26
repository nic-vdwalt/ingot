#+build !js
package gfx

import "core:testing"

@(test)
drop_lifecycle_is_bounded_and_consumed :: proc(t: ^testing.T) {
	_drop_native_shutdown()
	defer _drop_native_shutdown()

	_drop_hover_stage(true)
	testing.expect(t, !IsFileDragOver())
	_drop_hover_publish()
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
	_drop_hover_publish()
	_drop_state_reset()
	testing.expect(t, !IsFileDragOver())
	testing.expect(t, !IsFileDropped())
}
