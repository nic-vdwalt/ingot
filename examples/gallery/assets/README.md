# Gallery assets

Cooked inputs for the Showcase section's GPU-3D viewport (`../showcase.odin`).
Both files are generated. Do not edit them by hand; re-run the cook instead.

| File | Bytes | Contents |
|---|---|---|
| `planet.imsh` | 816,438 | IMSH v1 mesh (`../imsh/imsh.odin`): 35,531 vertices, 41,311 triangles, 1 textured submesh, ROS basis |
| `planet_albedo.jpg` | 243,956 | 1024 x 1024 base-color texture, JPEG quality 86 |

Each file stays under 1 MiB, so neither needs an entry in
`docs/provenance/third-party-artifacts.json`.

## Source

- Input: `sample_2026-10-25T060634.109.glb` (11,622,368 bytes), a planet model
  generated with planetforger and exported by trimesh. It has 213,353 vertices,
  294,188 triangles, and one material whose base color and metallic-roughness
  images are embedded as WebP (`EXT_texture_webp`).
- `stb_image` cannot decode WebP, so the base-color image (image 0, buffer
  view 2) was decoded with `dwebp` 1.6.0 to a 2048 x 2048 PNG first. That PNG
  is passed with `-albedo:`.

## Command

```sh
dwebp planet_base_color.webp -o /tmp/planet_tex2.png
odin build tools/meshcook -collection:ingot=. -out:/tmp/meshcook
/tmp/meshcook sample_2026-10-25T060634.109.glb examples/gallery/assets \
	-albedo:/tmp/planet_tex2.png
```

The defaults are `-max-triangles:60000` and `-max-texture:1024`. With them,
vertex clustering stopped at grid resolution 56. That is the largest grid at
which the vertex count fits the u16 index range and the file stays under 1 MiB.
Given the same input, the cook writes the same bytes every time (see
`tools/meshcook/meshcook_test.odin`).
