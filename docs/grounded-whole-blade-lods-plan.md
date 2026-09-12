## Implementation Steps

1. Propagate grounded constraints through discrete LOD cooking and add regression tests
2. Implement metadata-driven whole-blade reduction and geometric validation
3. Preserve blade metadata through Blender export and test actual triangulation
4. Tag and recook PlanetForger's four grass varieties with measured capacities
5. Verify asset previews, determinism and repository compatibility; document results

## Overview
Improve Ingot's offline mesh cooking so grounded models cannot acquire floating coarse LODs, and give authored grass a deterministic whole-blade reduction policy. This is a prerequisite repair for the paused PlanetForger grass plan, not permission to resume that plan or fix unrelated lineage-browser errors.

## Scope and decisions
- Change Python cooking/export tools, tests, documentation and the ForgeCore grass authoring metadata. No runtime mesh format, GPU ABI, Odin simplifier or simulation changes.
- Reuse the Python simplifier's existing `locked` support for general grounded discrete LODs. Do not redesign its normal/UV seam behavior; that is a separate potentially broad change.
- Add opt-in `grass_blades_2`, leaving existing `grass_2` behavior available for compatibility. The new policy retains complete blade components rather than collapsing their triangles.
- Use an explicit Blender integer FACE attribute `ingot_blade_id`. Do not infer blades by coincident positions: split normals/UVs duplicate vertices, while different blades may touch at identical positions.
- Author IDs on both sides of each blade. Metadata exists only during cooking and does not change INGMESH2.

## Inspected evidence
`ingot/tools/mesh_cook.py:506–524` already supports position-group locks, with incident triangle fans protected at `:478–488`. `build_lod_chain:605–635` does not supply locks. `blender_ingmesh_export.py:168–200` only checks grounding before cooking and expands corners by the full position/normal/scalar/UV key. Its `serialize_v2:203–223` passes no grounding or component metadata to `cook_mesh:947–980`.

The current PlanetForger coarse assets have minimum local Z of 0.304193 (Upright), 0.430105 (Reed) and 0.290366 (Tuft). Fine levels remain grounded. The original authoring scene is preserved. Existing untracked lineage-browser work prevents unrelated project compilation and is outside this plan.

## Files Changed and exact responsibilities
### `ingot/tools/mesh_cook.py`
- Add optional keyword-only `grounded=False`, `ground_tolerance`, and `blade_ids=None` parameters to `cook_mesh` and `build_lod_chain`, preserving existing callers. Validate finite, nonnegative tolerances; metadata length must equal input triangle count; IDs must be nonnegative integers (not booleans).
- Introduce small helpers for ground validation/root masks, blade validation, deterministic blade selection, conservative omitted-geometry error, and post-cook grounding validation. Keep production procedures bounded and within repository size conventions.
- For grounded generic discrete policies, derive the root mask from optimized source vertices using `abs(z) <= ground_tolerance`; pass it to `simplify(..., locked=root_mask)`. Reject a source outside the permitted ground interval. Validate every emitted LOD is grounded; never translate a detached coarse mesh downward to hide the problem. Constraints take priority over target count. Preserve the existing shorter-chain behavior when no strict reduction is possible.
- General grounding validation applies after both discrete and clustered cooking. This patch does not change cluster simplification or its locking scheme: if a grounded clustered result fails validation, report a named CookError rather than silently claiming preservation. Validate all emitted representations using the actual cluster/DAG data layout.
- Add `grass_blades_2: (1.0, 0.25)`. Dispatch before optimizing away input triangle ordering. Group original triangle triplets by authoritative blade ID; retain original vertex attributes and face orientation. Optimize only the selected geometry afterward. Do not route grass through positional-edge collapse.
- Reject `grass_blades_2` combined with clustered cooking, missing metadata, fewer than two removable blades, ungrounded blades, zero-height components, inconsistent scalar classification or missing opposite faces. Unknown metadata must never silently select generic simplification. Existing generic callers without new keywords behave as before.
- Opposite-face validation must handle opposite quad triangulation diagonals: validate oriented coverage on each planar blade segment, not just exact reversed triangle tuples. Canonicalize geometric positions for identity, partition by coplanar connected patches within each blade, cancel internal edges and require paired opposite oriented patch boundaries/areas. Reject degenerate/ambiguous/nonmanifold components with mesh/blade labels. Preserve exact original triangles for accepted blades; validators never repair geometry implicitly.
- Maintain increasing finite LOD errors, decreasing thresholds and strict index reduction. No serialization fields change.

### `ingot/tools/blender_ingmesh_export.py`
- `evaluated_mesh:~150`: ensure FACE integer attributes survive evaluated-mesh conversion and bmesh triangulation. Read the named layer before/after conversion and fail if required metadata is absent or malformed; do not rely on undocumented survival without a Blender integration fixture.
- `mesh_payload:168`: return one blade ID per exported triangle in an explicit additional metadata value. Read `triangle.polygon_index` after triangulation; front/back polygons receive the same ID. Leave the 9-float vertex format untouched.
- `collect_meshes:~226`, `serialize_v2:203` and any legacy serialization callers: carry the expanded internal payload consistently. Pass manifest grounding/tolerance and optional blade IDs into `cook_mesh`. Preserve legacy output behavior where supported; reject requests that require unavailable LOD semantics explicitly.
- Manifest validation accepts the new named policy through the existing policy table. The Blender attribute name is fixed/documented rather than adding arbitrary manifest interpretation. Unsupported `cluster` combinations fail early.
- After cooking, validate actual stored/decoded packed positions against grounding tolerance, accounting for quantization. Grounded levels contain source roots, so the lower bound should remain zero within the existing tolerance.

### `ingot/tools/test_mesh_cook.py`
Add deterministic synthetic grounded surfaces and multi-blade fixtures with both triangulation diagonal conventions, split normals/UVs, touching blades, unequal blade sizes and varied radii/heights. Cover legacy-policy compatibility, root locks through LOD optimization, independent blade IDs at identical positions, complete component retention, opposing faces, invalid metadata and nonfinite tolerances. Exercise one-blade input, too-small targets, malformed blades and clustered-policy rejection. Verify packed/unpacked round trips, no file-format changes, strictly cheaper coarse levels, bounded finite errors and byte-identical repeated cooking.

### `ingot/tools/test_blender_grass_export.py` (new Blender integration fixture)
Create a small temporary scene inside a workspace-local test directory, with integer FACE blade metadata, UVs and split normals. Exercise actual evaluated mesh conversion, triangulation, payload collection and serialized output for both quad triangulation patterns. Assert IDs survive; missing/incorrect metadata fails with actionable diagnostics. Do not let a Blender-only test break dependency-free unittest discovery: use an explicit Blender entry point or skip when bpy is unavailable. Keep all fixtures and temporary output inside the workspace.

### `forgecore/tools/refine_flora_blend.py`
`create_grass_variety`: record face ranges around each existing `add_blade` call, then attach integer FACE attribute `ingot_blade_id` to the created mesh. ID is the stable blade-loop index, shared by front/back faces and all segments. Do not change fine geometry, source IDs, material ownership, blade budgets or the original `flora.blend`. Validate face-attribute length before saving. Preserve the already implemented four varieties.

### `planetforger/assets/source/flora_manifest.json`
Change only grass IDs 4/5/6/12 from `grass_2` to `grass_blades_2`. Keep non-grass policies and asset identity unchanged.

### Generated assets and decoder capacities
Regenerate `planetforger/assets/source/flora_refined.blend` and `planetforger/assets/generated/flora.ingmesh` through existing commands. Update `forgecore/client/flora_assets.odin` aggregate limits using measured output, retaining enough capacity for existing sibling assets. Expect twelve meshes and 28 levels, but assert actual counts. This regeneration is the only resumption-like integration work authorized by this new plan; do not advance bookkeeping or steps of the paused grass plan.

### Documentation
Update `ingot/docs/cooked-mesh.md` with the opt-in policy, FACE metadata schema, grounding constraints, target-budget semantics and error/failure behavior. Update PlanetForger's asset notes only with verified counts/commands and any remaining blocker; no claims of native visual acceptance.

## Whole-blade selection algorithm
Input: validated source triangles, per-triangle blade IDs, nominal index ratio 0.25.
1. Build components by ID without positional merging. Validate every component is rooted, nondegenerate, double-sided and classified as grass.
2. Compute each blade's root centroid, tip height, projected root extent and triangle cost. Sort IDs for all ties; never depend on dict/set iteration or ambient RNG.
3. Produce a deterministic progressive selection: start with a tall outer silhouette representative, then choose the candidate with maximal minimum normalized distance to selected root/height descriptors. Normalize spatial and height dimensions by nonzero source extents. This distributes retained roots and height variety rather than retaining adjacent blades.
4. Select whole components until nearest feasible total cost to the nominal target is reached. Guarantee at least one retained blade and strict reduction; stop or fail descriptively when constraints make a second level impossible. Cost is a target, not permission to truncate a blade. Tie-break toward the lower total cost and then stable IDs. Bound work to O(B² + T) with explicit checked component/triangle limits consistent with cooker limits.
5. Emit complete source triangles for selected IDs and optimize once. Output vertices/UVs/normals/scalars must match source tuples; no re-authoring or merging across blades is permitted.
6. Compute a conservative finite geometric error for omitted triangles: assign each omitted triangle to a retained geometric vertex, and use the maximum vertex-to-assigned-point distance as an upper bound across that triangle. Choose a deterministic nearest retained representative to keep the bound useful; keep work bounded via per-blade representative sets rather than unrestricted triangle-pair searches. Retained geometry contributes zero. Enforce the existing strictly increasing error floor.
7. Revalidate grounding, complete components, opposing coverage, strict index reduction, bounds and serialization. Fail with mesh/blade/level context instead of silently falling back to unsafe collapse.

## Compatibility and risks
The low-level QEM algorithm and Odin simplifier remain unchanged. Ground protection is activated by explicit exporter metadata; old API calls preserve defaults. Generic grounded asset output may change due to locks; inspect counts and expect a shorter chain where necessary, not duplicate LODs. Whole-blade policy output changes are intentional and require recooking only opted-in assets. No dependency commits, pin rewrites or checkout resets are authorized. Preserve all unrelated work.

Potential pitfalls are Blender FACE-layer propagation, two-sided quads with different triangulation diagonals, overly conservative omitted-geometry errors and insufficient remaining silhouette at 25%. These require fixtures and previews before declaring acceptance. If 25% produces unacceptable silhouettes, adjust the new policy ratio based on measured results, documenting the change; do not change biological cover or add instances.

## Verification and acceptance
- Run `python3 -m unittest discover ingot/tools` from the workspace after each logical cooker change, then Blender fixture tests using the documented `tools/blender-5.2.0/Blender.app/Contents/MacOS/Blender` executable.
- Run Ingot `bash scripts/check.sh` and `bash scripts/test.sh` as repository gates; report unrelated failures without fixing them.
- Re-refine from the original source, cook, freshness-check, repeat from the original again and compare decoded geometry and cooked bytes. Blender scene container bytes need not be reproducible if they contain metadata timestamps.
- Audit every fine/coarse grass ID: grounded quantized minimum Z, complete rooted blades, both sides, cheaper coarse geometry, scalar/UV validity, finite monotonic errors, actual decoder capacities. Emit a per-ID report with retained blade count, triangles, bounds and error.
- Generate fine/coarse side-by-side previews for all four varieties using Blender to verify roots, distribution, silhouette and reverse-face visibility. Native wind/grassland performance acceptance stays in the separate paused plan.
- Attempt PlanetForger check/tests and existing sibling compatibility gates, preserving unrelated errors. Do not claim that the known lineage-browser compile failure was fixed. If project validation remains externally blocked, report it explicitly and leave the affected step incomplete.

## Completion boundary
Success means the offline pipeline can reliably emit grounded two-level grass assets using whole blades, with regression and export evidence, without modifying runtime formats. This does not unpause steps 2–6 of the grass presentation plan. No implementation has been performed for this new plan.
