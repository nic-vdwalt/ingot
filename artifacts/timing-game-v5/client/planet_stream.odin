package main

import shared "../shared"
import procgen "ingot:procgen"

Planet_Stream_Tile :: struct {
	face:   procgen.Terrain_Face_V4,
	tile_u: i32,
	tile_v: i32,
}

PLANET_STREAM_TILE_CELLS :: 32
PLANET_STREAM_TILES_PER_FACE :: shared.PLANET_FACE_CELLS / PLANET_STREAM_TILE_CELLS
PLANET_STREAM_DRAW_BLEND_LIMIT :: f32(0.98)
#assert(shared.PLANET_FACE_CELLS % PLANET_STREAM_TILE_CELLS == 0)

planet_stream_tile :: proc(direction: [3]f32) -> Planet_Stream_Tile {
	face, u, v := shared.planet_locate(direction)
	last := i32(PLANET_STREAM_TILES_PER_FACE - 1)
	return {
		face,
		clamp(i32(u) / PLANET_STREAM_TILE_CELLS, 0, last),
		clamp(i32(v) / PLANET_STREAM_TILE_CELLS, 0, last),
	}
}

planet_stream_position :: proc(tile: Planet_Stream_Tile, local_u, local_v, height: f32) -> [3]f32 {
	assert(local_u >= 0 && local_u <= 1, "planet_stream_position: local u")
	assert(local_v >= 0 && local_v <= 1, "planet_stream_position: local v")
	u := (f32(tile.tile_u) + local_u) * PLANET_STREAM_TILE_CELLS
	v := (f32(tile.tile_v) + local_v) * PLANET_STREAM_TILE_CELLS
	direction := shared.planet_direction_uv(tile.face, u, v)
	return shared.planet_position(direction, height)
}

planet_stream_visible :: proc(camera_distance: f32) -> bool {
	return planet_camera_blend(camera_distance) < PLANET_STREAM_DRAW_BLEND_LIMIT
}
