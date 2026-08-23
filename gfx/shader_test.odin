#+build !js
package gfx

import "core:strings"
import "core:testing"

@(test)
shader_wgsl_layout_supported_types :: proc(t: ^testing.T) {
	size, alignment, ok := _wgsl_type_layout("f32")
	testing.expect(t, ok)
	testing.expect_value(t, size, u32(4))
	testing.expect_value(t, alignment, u32(4))
	size, alignment, ok = _wgsl_type_layout("vec3<f32>")
	testing.expect(t, ok)
	testing.expect_value(t, size, u32(12))
	testing.expect_value(t, alignment, u32(16))
	size, alignment, ok = _wgsl_type_layout("mat4x4<f32>")
	testing.expect(t, ok)
	testing.expect_value(t, size, u32(64))
	testing.expect_value(t, alignment, u32(16))
	_, _, unsupported := _wgsl_type_layout("array<f32, 4>")
	testing.expect(t, !unsupported)
}

@(test)
shader_checked_alignment_rejects_overflow :: proc(t: ^testing.T) {
	aligned, ok := _shader_checked_align(17, 16)
	testing.expect(t, ok)
	testing.expect_value(t, aligned, u32(32))
	_, zero_ok := _shader_checked_align(17, 0)
	testing.expect(t, !zero_ok)
	_, power_ok := _shader_checked_align(17, 3)
	testing.expect(t, !power_ok)
	_, overflow_ok := _shader_checked_align(max(u32), 16)
	testing.expect(t, !overflow_ok)
}

@(test)
shader_reflection_accepts_empty_and_mixed_layouts :: proc(t: ^testing.T) {
	empty, empty_total, empty_ok := _reflect_uniforms("struct U {}")
	defer _shader_uniforms_destroy(empty)
	testing.expect(t, empty_ok)
	testing.expect_value(t, len(empty), 0)
	testing.expect_value(t, empty_total, u32(16))

	uniforms, total, ok := _reflect_uniforms("struct U { vector: vec3<f32>, scalar: f32 }")
	defer _shader_uniforms_destroy(uniforms)
	testing.expect(t, ok)
	testing.expect_value(t, len(uniforms), 2)
	testing.expect_value(t, uniforms[0].offset, u32(0))
	testing.expect_value(t, uniforms[1].offset, u32(12))
	testing.expect_value(t, total, u32(16))

	projection_source :=
		"struct Uniforms { projection: vec4<f32>, };\n" +
		"struct U { exposure: f32, quality: f32 }"
	custom, custom_total, custom_ok := _reflect_uniforms(projection_source)
	defer _shader_uniforms_destroy(custom)
	testing.expect(t, custom_ok)
	testing.expect_value(t, len(custom), 2)
	testing.expect_value(t, custom_total, u32(16))
}

@(test)
shader_reflection_rejects_malformed_and_unsupported_members :: proc(t: ^testing.T) {
	_, _, unsupported := _reflect_uniforms("struct U { good: f32, bad: bool }")
	testing.expect(t, !unsupported)
	_, _, missing_colon := _reflect_uniforms("struct U { bad }")
	testing.expect(t, !missing_colon)
	_, _, missing_brace := _reflect_uniforms("struct U { value: f32")
	testing.expect(t, !missing_brace)
	_, _, empty_name := _reflect_uniforms("struct U { : f32 }")
	testing.expect(t, !empty_name)
}

@(test)
shader_reflection_enforces_member_limit :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "struct U {")
	for index in 0 ..< SHADER_UNIFORMS_MAX + 1 {
		strings.write_string(&builder, "value")
		strings.write_rune(&builder, rune('a' + index % 26))
		strings.write_string(&builder, ": f32,")
	}
	strings.write_rune(&builder, '}')
	_, _, ok := _reflect_uniforms(strings.to_string(builder))
	testing.expect(t, !ok)
}

@(test)
shader_source_size_validation_is_overflow_safe :: proc(t: ^testing.T) {
	maximum := strings.repeat("x", SHADER_SOURCE_BYTES_MAX, context.temp_allocator)
	testing.expect(t, _shader_source_size_valid(maximum, "", false))
	testing.expect(t, !_shader_source_size_valid(maximum, "x", true))
	vertex := maximum[:SHADER_SOURCE_BYTES_MAX - 2]
	testing.expect(t, _shader_source_size_valid(vertex, "x", true))
	testing.expect(t, !_shader_source_size_valid(vertex, "xx", true))
}

@(test)
shader_uniform_total_validation_checks_ranges :: proc(t: ^testing.T) {
	valid := [1]Shader_Uniform{{offset = 12, size = 4}}
	testing.expect(t, _shader_uniforms_valid(valid[:], 16))
	bad_offset := [1]Shader_Uniform{{offset = 17, size = 0}}
	testing.expect(t, !_shader_uniforms_valid(bad_offset[:], 16))
	bad_size := [1]Shader_Uniform{{offset = 12, size = 8}}
	testing.expect(t, !_shader_uniforms_valid(bad_size[:], 16))
	testing.expect(t, !_shader_uniforms_valid(nil, 15))
}

@(test)
shader_mode_is_context_bound :: proc(t: ^testing.T) {
	first := new(Context)
	defer free(first)
	second := new(Context)
	defer free(second)
	first.id = 2
	second.id = 3
	first_shader := Shader {
		id = _resource_handle_make_context(first.id, 0, 1),
	}
	second_shader := Shader {
		id = _resource_handle_make_context(second.id, 0, 1),
	}

	context_begin_shader_mode(first, first_shader)
	context_begin_shader_mode(second, second_shader)
	testing.expect_value(t, first.rend.active_shader, first_shader.id)
	testing.expect_value(t, second.rend.active_shader, second_shader.id)
	context_end_shader_mode(first)
	testing.expect_value(t, first.rend.active_shader, u32(0))
	testing.expect_value(t, second.rend.active_shader, second_shader.id)
}
