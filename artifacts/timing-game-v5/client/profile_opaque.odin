package main

import "core:fmt"
import "core:os"
import rl "ingot:gfx"
import wg "vendor:wgpu"

OPAQUE_COMPONENT_NAMES :: [9]string {
	"split.opaque.sky",
	"split.opaque.terrain",
	"split.opaque.nodes",
	"split.opaque.vents",
	"split.opaque.fauna",
	"split.opaque.buildings",
	"split.opaque.selection",
	"split.opaque.flora",
	"split.opaque.marine",
}

profile_terrain_draw_label :: proc(face, patch, lod: int, textured: bool) -> string {
	assert(face >= 0 && face < 6)
	assert(patch >= 0 && patch < 64)
	assert(lod >= 0 && lod < TERRAIN_LOD_COUNT)
	material := "fallback"
	if textured do material = "baked"
	return fmt.tprintf("terrain.face%d.patch%d.lod%d.%s", face, patch, lod, material)
}

profile_terrain_draw_begin :: proc(pass: ^rl.Gpu_3D_Pass, face, patch, lod: int, textured: bool) {
	assert(pass != nil)
	when PROFILE_ENABLED {
		wg.RenderPassEncoderPushDebugGroup(pass.pass, profile_terrain_draw_label(face, patch, lod, textured))
	}
}

profile_terrain_draw_end :: proc(pass: ^rl.Gpu_3D_Pass) {
	assert(pass != nil)
	when PROFILE_ENABLED {
		wg.RenderPassEncoderPopDebugGroup(pass.pass)
	}
}

profile_opaque_split :: proc() -> bool {
	when PROFILE_ENABLED {
		return os.get_env("FORGE_PROFILE_OPAQUE", context.temp_allocator) == "split"
	}
	return false
}

opaque_component_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass, component: int) {
	assert(value != nil && pass != nil)
	assert(component >= 0 && component < len(OPAQUE_COMPONENT_NAMES))
	if component >= 2 && value.terrain.ocean.nearshore.fixture_active do return
	switch component {
	case 0:
		atmosphere_draw_sky(&value.atmosphere, pass, value.camera)
	case 1:
		terrain_draw_opaque(&value.terrain, pass, value.camera, &value.atmosphere)
	case 2:
		nodes_draw(value, pass, value.cursor.time)
	case 3:
		vents_draw(value, pass)
	case 4:
		fauna_draw(value, pass)
	case 5:
		draw_buildings(value, pass)
	case 6:
		draw_selection(value, pass)
	case 7:
		if planet_stream_visible(value.orbit.distance) {
			flora_draw(&value.flora, pass, value.camera)
		}
	case 8:
		marine_draw(value, pass)
	}
}

opaque_components_draw :: proc(value: ^Client_State, target: ^rl.Gpu_3D_Target) -> bool {
	assert(value != nil && target != nil)
	assert(value.graphics_ready)
	split := profile_opaque_split()
	value.opaque_draw_mask = 0
	names := OPAQUE_COMPONENT_NAMES
	name := "world.opaque"
	if split do name = OPAQUE_COMPONENT_NAMES[0]
	pass, ok := rl.begin_gpu_3d_named(target, value.camera, .Clear, name)
	if !ok do return false
	sun, moon := weather_orbital_lights(value)
	primary, secondary := water_underwater_medium_params(value.terrain.ocean.underwater)
	for component in 0 ..< len(OPAQUE_COMPONENT_NAMES) {
		if split && component > 0 {
			rl.end_gpu_3d(&pass)
			pass, ok = rl.begin_gpu_3d_named(target, value.camera, .Preserve, names[component])
			if !ok do return false
		}
		rl.set_gpu_3d_light(&pass, sun)
		rl.set_gpu_3d_secondary_light(&pass, moon)
		rl.set_gpu_3d_underwater_medium(&pass, primary, secondary)
		rl.set_gpu_3d_clip_plane(
			&pass,
			{value.camera.position.x, value.camera.position.y, value.camera.position.z, 0},
			component > 0 && value.planet_cutaway,
		)
		when PROFILE_ENABLED {
			wg.RenderPassEncoderPushDebugGroup(pass.pass, names[component][6:])
		}
		before := rl.renderer_stats().gpu3d_draws
		opaque_component_draw(value, &pass, component)
		when PROFILE_ENABLED {
			if rl.renderer_stats().gpu3d_draws > before {
				value.opaque_draw_mask |= u32(1) << u32(component)
			}
			wg.RenderPassEncoderPopDebugGroup(pass.pass)
		}
	}
	rl.end_gpu_3d(&pass)
	return true
}
