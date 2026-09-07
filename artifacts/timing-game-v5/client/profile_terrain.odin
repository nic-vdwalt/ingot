package main

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:strings"

Profile_Terrain_Identity :: struct {
	variant: string,
	sha256: [64]u8,
	artifact_saved: bool,
	validation: string,
}

profile_terrain_digest :: proc(source: string) -> [64]u8 {
	digest: [32]u8
	_ = hash.hash_string_to_buffer(.SHA256, source, digest[:])
	encoded: [64]u8
	digits := "0123456789abcdef"
	for byte, index in digest {
		encoded[index * 2] = digits[byte >> 4]
		encoded[index * 2 + 1] = digits[byte & 15]
	}
	return encoded
}

profile_terrain_prepare :: proc(identity: ^Profile_Terrain_Identity) -> string {
	assert(identity != nil)
	when !PROFILE_ENABLED do return TERRAIN_SHADER
	if identity.variant == "" {
		selected := profile_terrain_variant()
		switch selected {
		case "reference": identity.variant = "reference"
		case "no-bump": identity.variant = "no-bump"
		case "no-strata": identity.variant = "no-strata"
		case "no-mapped-detail": identity.variant = "no-mapped-detail"
		case "baked-albedo", "geometric-normal", "material-controls": identity.variant = selected
		case: identity.validation = "invalid variant"; return ""
		}
	}
	source := profile_terrain_shader_variant(TERRAIN_SHADER, identity.variant)
	identity.sha256 = profile_terrain_digest(source)
	identity.validation = "not validated"
	path := os.get_env("AESIR_TELEMETRY", context.temp_allocator)
	if path != "" {
		artifact := fmt.tprintf("%s.terrain-%s.wgsl", path, string(identity.sha256[:]))
		identity.artifact_saved = os.write_entire_file(artifact, transmute([]u8)source) == nil
	}
	return source
}

profile_terrain_variant :: proc() -> string {
	when PROFILE_ENABLED {
		name := os.get_env("FORGE_PROFILE_TERRAIN", context.temp_allocator)
		if name != "" do return name
	}
	return "reference"
}

profile_terrain_shader_variant :: proc(source, variant: string) -> string {
	old, replacement: string
	switch variant {
	case "baked-albedo":
		old = "return vec4<f32>(color, 1.0);"
		replacement = "return vec4<f32>(baked_xy, 1.0);"
	case "geometric-normal":
		old = "return vec4<f32>(color, 1.0);"
		replacement = "return vec4<f32>(normal_geo * 0.5 + vec3<f32>(0.5), 1.0);"
	case "material-controls":
		old = "return vec4<f32>(color, 1.0);"
		replacement = "return vec4<f32>(controls, 1.0);"
	case "no-bump":
		old = "let normal = normalize(mapped_normal + world_bump);"
		replacement = "let normal = mapped_normal;"
	case "no-strata":
		old = "var rock_col = mix(vec3<f32>(0.33, 0.32, 0.30), vec3<f32>(0.57, 0.53, 0.47), strata_wide);"
		replacement = "var rock_col = vec3<f32>(0.45, 0.425, 0.385);"
	case "no-mapped-detail":
		old = "let mapped_detail = fade_mid * material_resolved;"
		replacement = "let mapped_detail = 0.0;"
	case:
		return source
	}
	assert(strings.count(source, old) == 1)
	result, _ := strings.replace_all(source, old, replacement, context.temp_allocator)
	return result
}

profile_terrain_shader :: proc() -> string {
	when PROFILE_ENABLED {
		return profile_terrain_shader_variant(TERRAIN_SHADER, profile_terrain_variant())
	}
	return TERRAIN_SHADER
}
