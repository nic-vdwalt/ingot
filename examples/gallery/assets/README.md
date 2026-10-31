# Gallery assets

Cooked inputs for the Showcase section's GPU-3D viewport (`../showcase.odin`).
Both files are generated. Do not edit them by hand; re-run the cook instead.

| File | Bytes | Contents |
|---|---|---|
| `planet.imsh` | 875,502 | IMSH v1 mesh (`../imsh/imsh.odin`): 32,558 vertices, 59,083 triangles, 1 textured submesh, ROS basis |
| `planet_albedo.jpg` | 31,434 | 1024 x 1024 base-color texture, JPEG quality 86 |

Each file stays under 1 MiB, so neither needs an entry in
`docs/provenance/third-party-artifacts.json`.

## Source

- Input: `sample_2026-10-31T132832.448.glb` (9,568,572 bytes). It has 174,836
  vertices, 299,013 triangles, and one material. Both of its images are
  embedded as WebP (`EXT_texture_webp`); the base color is image 0.
- The GLB's own base-color image (image 0, a 2048 x 2048 WebP that is almost
  entirely black) is not used. The albedo is instead baked by
  `scripts/bake-cortex-albedo.py` in the cc-php-app landing-page cortex
  palette: the linear-space mix of `cool` (0.38, 0.62, 0.66) and `pearl`
  (0.86, 0.93, 0.92) at 0.30 from `neural-graph.js`'s cortex shader, plus a
  seeded grain. It is a flat material, so UV atlas seams cannot show; the
  folds read through the renderer's lighting. The Showcase's default Steel
  look ignores it and shades procedurally (`../showcase_steel.odin`); the
  Textured look uses it.
- The mesh is one connected surface built from nested thin-walled shells:
  every point of the anvil has about four layers 2-5 mm apart. Only about 28%
  of its triangles can be seen from outside.

## Command

```sh
python3 scripts/bake-cortex-albedo.py /tmp/cortex_albedo.png
odin build tools/meshcook -collection:ingot=. -out:/tmp/meshcook
/tmp/meshcook sample_2026-10-31T132832.448.glb examples/gallery/assets \
	-albedo:/tmp/cortex_albedo.png
```

The defaults are `-max-triangles:60000` and `-max-texture:1024`. With them,
the visibility pass kept 84,007 of the 299,013 source triangles, and vertex
clustering stopped at grid resolution 148, giving 32,558 vertices and 59,083
triangles. That result is within the 60,000-triangle cap and the u16
index range, and the file stays under 1 MiB.
Before clustering, `tools/meshcook/visibility.odin` drops every triangle that
no outside viewer can see, using depth renders from 128 directions. A cell is
far coarser than the gap between nested layers, so clustering them together
z-fought into a patchwork; `-keep-hidden` skips the pass.
Clustering is position-first: every vertex of one grid cell shares a single
position, and a cell splits only where uvs jump by more than
`COOK_UV_MERGE_DISTANCE` (an atlas seam). Splitting positions by uv instead
opened cracks along every atlas seam. That position is the point closest to
the source planes around the cell (`cluster_place_quadric`) rather than the
vertex mean, so straight edges and corners stay crisp. When several source
triangles collapse onto the same three cells, only the one whose winding best
matches its source normals is kept.
Normals are rebuilt from the cooked triangles (area-weighted per shared
position) rather than averaged from the source, because a coarse cell on a
thin feature mixes opposite-facing source normals that cancel. Where the
adjacent cooked faces still nearly cancel, the vertex takes the normal of its
largest face (`COOK_NORMAL_CANCEL_RATIO`). The rebuilt normals are then
smoothed with neighbours within `COOK_NORMAL_SMOOTH_ANGLE`, so flat faces lose
grid ripple and real creases stay sharp.
Given the same input, the cook writes the same bytes every time (see
`tools/meshcook/meshcook_test.odin`).
