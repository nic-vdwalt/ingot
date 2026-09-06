#+build js
package shared

// JS fallback for the foundation row bake: no threads on wasm, so the whole
// row range runs serially. Output is identical to the parallel native path.

import procgen "ingot:procgen"

@(private)
_foundation_rows_generate :: proc(
	field: ^Foundation_Field,
	recipe: ^procgen.Terrain_Recipe_V3,
	raw_biomes: []procgen.Terrain_Biome_Blend_V2,
) -> bool {
	return _foundation_row_range(field, recipe, raw_biomes, 0, HEIGHTFIELD_RESOLUTION)
}
