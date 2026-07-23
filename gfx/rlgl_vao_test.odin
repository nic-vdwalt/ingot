#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

@(test)
vao_layout_accepts_replaced_instance_buffer :: proc(t: ^testing.T) {
	buffers := [2]Vao_Buffer {
		{id = 1, buf = wg.Buffer(uintptr(1)), size = 96},
		{id = 3, buf = wg.Buffer(uintptr(3)), size = 1200 * 40},
	}
	attrs := [5]Vao_Attr {
		{location = 0, comps = 2, offset = 0, stride = 16, buffer_idx = 0},
		{location = 1, comps = 2, offset = 8, stride = 16, buffer_idx = 0},
		{location = 2, comps = 4, offset = 0, stride = 40, buffer_idx = 1, divisor = 1},
		{location = 3, comps = 4, offset = 16, stride = 40, buffer_idx = 1, divisor = 1},
		{location = 4, comps = 2, offset = 32, stride = 40, buffer_idx = 1, divisor = 1},
	}
	vao: Vao
	append(&vao.buffers, ..buffers[:])
	append(&vao.attrs, ..attrs[:])
	defer delete(vao.buffers)
	defer delete(vao.attrs)
	testing.expect(t, _vao_layout_valid(&vao))
	testing.expect_value(t, vao.buffers[1].size, u64(1200 * 40))
}

@(test)
vao_layout_rejects_duplicate_shader_locations :: proc(t: ^testing.T) {
	buffers := [1]Vao_Buffer{{id = 1, buf = wg.Buffer(uintptr(1)), size = 96}}
	attrs := [2]Vao_Attr {
		{location = 0, comps = 2, stride = 16, buffer_idx = 0},
		{location = 0, comps = 2, offset = 8, stride = 16, buffer_idx = 0},
	}
	vao: Vao
	append(&vao.buffers, ..buffers[:])
	append(&vao.attrs, ..attrs[:])
	defer delete(vao.buffers)
	defer delete(vao.attrs)
	testing.expect(t, !_vao_layout_valid(&vao))
	testing.expect_value(t, len(vao.attrs), 2)
}

@(test)
vao_layout_rejects_missing_or_short_buffers :: proc(t: ^testing.T) {
	buffers := [1]Vao_Buffer{{id = 1, buf = nil, size = 0}}
	attrs := [1]Vao_Attr{{location = 0, comps = 4, offset = 4, stride = 16, buffer_idx = 0}}
	vao: Vao
	append(&vao.buffers, ..buffers[:])
	append(&vao.attrs, ..attrs[:])
	defer delete(vao.buffers)
	defer delete(vao.attrs)
	testing.expect(t, !_vao_layout_valid(&vao))
	vao.buffers[0] = {
		id   = 1,
		buf  = wg.Buffer(uintptr(1)),
		size = 16,
	}
	testing.expect(t, !_vao_layout_valid(&vao))
}
