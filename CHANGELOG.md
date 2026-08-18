# Changelog

All notable changes to Ingot are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Ingot uses pre-`1.0` versioning: source tags may contain documented public API
changes, including breaking changes. Pin an exact tag and read the changelog.
See the [versioning policy](docs/compatibility.md#versioning-policy).

## Unreleased

### Changed

- **Breaking:** `TERRAIN_RECIPE_VERSION_V2` is `4` and
  `TERRAIN_RECIPE_VERSION_V3` is `6`. Biome classification now reads a
  *landform* height and slope -- the same stack with the hill and detail
  octaves removed -- instead of the full rendered height. Hills exist to make
  ground look uneven, not to relabel it: at the default hill height a single
  71-unit bump reaches a slope near 0.44, which is enough to trip a rock
  profile's slope floor on otherwise uniform ground and fragment one province
  into a mottle. `Terrain_Sample_V2` gains `landform` and `landform_slope`,
  `Terrain_Surface_V3` gains `landform`, and `Terrain_Field_Buffer_V2` gains
  `landform_halo`, `landform`, and `landform_slope`. Persisted V2 and V3
  worlds must be regenerated rather than reinterpreted.
- **Breaking:** `Terrain_Biome_Region_Scratch` gains `component_offsets`
  (`cells + 1` entries) and `component_cells` (`cells`).
  `terrain_resolve_biome_regions` buckets cells by component with a counting
  sort each pass, so choosing a merge target walks only that component's own
  cells rather than sweeping the whole grid once per undersized component.
  Results are unchanged; the scan it replaced was quadratic once most
  components fell below `minimum_cells`, which is exactly what a
  province-scale minimum produces.
- **Breaking:** `TERRAIN_RECIPE_VERSION_V3` is `4`. Volume terrain now welds
  vertices on lattice-edge identity, derives caves and overhangs from real 3D
  noise instead of composed 2D slices, and exposes the terrace step, island
  jitter, island shape strength, and triplanar UV scale as recipe parameters.
  Persisted V3 worlds cooked against version `3` must be regenerated.
  `terrain_generate_volume_v3` returns a `Terrain_Volume_Result_V3` and
  `terrain_volume_requirements_v3` reports a weld-slot count, so both change
  arity; `Terrain_Volume_Buffer_V3` gains `normal_halo`, `weld_keys`, and
  `weld_values`. V1 and V2 terrain are untouched.
- A uniformly empty or solid volume chunk now succeeds with a named occupancy
  and zero counts instead of failing, because in a streaming world it is the
  ordinary result rather than an error.
- Fit inline capacity now defaults to 128 nodes instead of 64. Existing
  zero-value builders remain source-compatible; larger collections should still
  be chunked or virtualized.

### Added

- Spherical terrain V4 adds a tangent-adjusted six-face parameterisation,
  world-scale 3D surface noise, angular latitude, tangent-basis slope, and the
  same height/landform split V2 uses for stable biome classification. V1-V3 are
  unchanged. `warped_fractal_3d` supplies seam-free domain warping for the
  spherical stack; V4 intentionally defines no radial volume or mesh product.
- `Terrain_Recipe_V2` gains `moisture_bias`, `temperature_bias`,
  `latitude_offset`, and `coast_jitter`. Contrast can only widen a
  distribution about its midpoint, so before the biases no seed could be a
  globally dry or globally cold world; the equator was pinned to `y = 0`, so
  every world shared one north-south gradient; and the land-mask perturbation
  was a hardcoded constant, so coastline roughness could not vary by recipe.
  All four default to the previous behaviour. The biases are bounded by
  `TERRAIN_CLIMATE_BIAS_MAX_V2`, because a larger value cannot move a clamped
  channel any further.
- `terrain_height_terms_prevalidated_v2` and `Terrain_Height_Terms_V2` publish
  the height and landform surfaces from one evaluation of the 2D stack, so a
  caller that needs both never pays for it twice.
- `asset.cooked_mesh_v2_encode` and `asset.cooked_mesh_v2_encoded_size`: the
  first Odin writer for `INGMESH2`. It refuses everything the decoder refuses
  and reports the same `Cooked_Mesh_Fault`, and is checked both by round trip
  and byte for byte against the independent test writer.
- `procgen.cook_chain_from_policy` and `procgen.cook_chain_from_clusters` turn a
  generated `Mesh_View` into a `Cooked_Mesh_Chain` through the existing
  simplifier and cluster builder, adding the screen thresholds, per-level index
  rebasing, and forced error monotonicity `INGMESH2` requires. Thresholds mirror
  `tools/mesh_cook.py`, so a runtime-cooked asset and an offline-cooked one
  select the same level at the same distance.
- `procgen.noise_3d` and `procgen.fractal_3d`: value noise over eight lattice
  corners, matching `noise_2d`'s hashing, quintic fade, and per-octave seeding.
- `procgen.terrain_volume_occupancy_v3` culls a chunk from one 2D noise stack
  per column instead of a full three-dimensional sample pass, and
  `procgen.terrain_volume_count_v3` publishes exact counts so a streaming caller
  can size real buffers rather than the per-cell worst case.
- `procgen.terrain_density_prevalidated_v3` skips per-sample recipe validation
  for callers that validate once and then sample a field.
- Versioned bounded fuzz operation tapes, deterministic failure-class-preserving
  shrinking for `net` and `interact`, a canonical shared harness PRNG, and a
  committed regression corpus replayed by Unix and Windows test gates.
- Fit declarative composition adds token-styled `Section` and `Card` containers,
  parent-owned responsive selection, bounded nested Canvas leaves, and checked
  immediate Region, Pane, and Layer helpers while preserving ordinary Odin
  lexical nesting and the existing Builder API.
- Builder-native text input, progress, separator, spacer, shared-track table,
  and one-child scroll operations keep state caller-owned and lower to the same
  bounded prepared runtime.
- `fit.Canvas`: a bounded full-parent explicit-geometry root that removes the
  synthetic `Column` plus `Custom` measure/render bridge from applications.
- `fit.Px`, `fit.Region_Open`, `fit.Region_Close`, and string/integer-key region
  control overloads reduce explicit-surface scaling, scope, and identity
  ceremony while preserving physical `Rect` semantics and caller-owned state.
- Concise explicit-surface drawing and interaction calls, plus Surface-bound
  `Layout_State`, `Grid_State`, `Flow_State`, and `Fit_Column_State` operations,
  remove repeated prefixes and owner arguments. Existing `Surface_*` spellings
  remain source-compatible, and all explicit rectangles remain physical.
- `fit.Row_With`, `Column_With`, `Flow_With`, `Grid_With`, and
  `Attachment_With`, `Section_With`, and `Card_With`: immediately invoked,
  source-located container helpers that verify callback balance without
  retaining callbacks or component state.
- `fit.Scope` and `fit.Id`: explicit bounded component identity composition at
  the supported builder layer; source locations never participate in IDs.
- Native `fit.Checkbox`, `fit.Radio`, and `fit.Slider` prepared leaves with
  caller-owned values and deferred changed-output publication.
- `fit.Set_Storage`, `fit.Reset_Storage`, and `fit.Storage_Capacity` expose
  caller-provided bounded builder storage up to 8,192 nodes without hidden
  allocation or global struct growth.
- `view.doc_tail_rebuild`: re-derives the authoring tail cache from a
  document's links, for callers that write nodes directly instead of through
  `doc_add`. `view_decode` calls it after a successful decode.
- `ui.layer_begin`/`ui.layer_end`: the single raised-surface primitive. One
  call couples input occlusion (an optional claim rect), paint order (the z
  tier), and coordinates (the pane origin is zeroed, so every ordinary `draw_*`
  call inside a layer emits screen space). Popups, modals, tooltips, toasts,
  comboboxes, the date picker, chart hover cards, and the spell menu all run on
  layers now; a modal opened from inside a pane is no longer double-translated.
- `ui.draw_text_string`: string draw with soft backend-font fallback, the
  layer-friendly twin of `overlay_text`, so headless tests can paint text
  without a text backend.
- `gfx.Orbit_Camera_Bindings.drag_modifier` and `.pan_button`, with
  `gfx.orbit_camera_pointer_intent`: a bound modifier key gates drag-rotation
  and a distinct pan-button role marks grab-pan intent, so MOBA/RTS schemes
  (left-drag pans, modifier+drag rotates) no longer clear `pointer_drag` by
  hand. Zero-valued bindings keep the historical always-on drag behaviour.
- `gfx.Orbit_Camera_Grab_Pan` with `orbit_camera_grab_pan_begin/end/delta`:
  plane-anchored grab-pan that keeps a picked world point pinned under the
  cursor ray. The anchor pick stays with the application; the per-frame
  ray/plane math is now library code and feeds `Orbit_Camera_Input.pan`.
- `gfx.orbit_camera_input_poll` and `gfx.Orbit_Camera_Bindings`: an optional,
  opt-in binding layer that samples the default input context into
  `Orbit_Camera_Input`. Three examples carried a byte-identical copy of the same
  polling block. `gfx/camera.odin` stays free of input polling, so the pure
  `update_orbit_camera` path is unchanged and still accepts input from any
  source.
- `gfx.create_plane_mesh`, `gfx.plane_mesh_vertex_count`, and
  `gfx.plane_mesh_index_count`: a subdivided XY plane with `+Z` normals and
  documented row-major vertex order, bounded by `GPU_3D_PLANE_MAX_CELLS`. It is
  the topology half of a deforming surface, whose other half is
  `update_gpu_mesh_vertices`; the published counts let a caller size and check
  its own vertex buffer against the generator instead of re-deriving it.
- `examples/box3d_stack` now builds for WebGPU browsers through Odin's
  `vendor:box3d` WASM object and is covered by the web compile gate.
- `gfx.update_gpu_mesh_vertices`: rewrites an existing mesh's vertex buffer in
  place, keeping its indices, primitive, and handle. Deforming geometry changes
  positions and normals every frame while its topology never moves, so the only
  previous option - destroy and recreate - released and reallocated a GPU buffer
  per frame and burned a pool slot's generation for nothing. The vertex count
  stays fixed at creation, because a resize is a different mesh.
- `examples/box3d_water`: floating rigid bodies on an analytical travelling
  wave. Box3D has no fluid representation, so the water is a wave function the
  application owns and the coupling is one buoyancy-plus-drag force per body per
  fixed step. The surface mesh is driven by the same function the physics
  samples, so the picture and the simulation cannot disagree, and the wave phase
  advances only inside a simulation step so pause and single-step freeze both.
- `ui.route_block_z`, `ui.route_block_z_in`, and `ui.Z_NONE`: report the highest
  z claiming a point rather than a yes/no answer relative to one depth.
  `route_occluded_in` is now derived from it, so the two cannot disagree.

### Deprecated

- The `ui.overlay_*` group (`overlay_begin/end`, `overlay_rect`,
  `overlay_rect_lines`, `overlay_rounded`, `overlay_rounded_lines`,
  `overlay_line`, `overlay_text`, `overlay_text_str`): thin wrappers over
  `layer_begin`/`layer_end` + `draw_*` for one release, then removed. Passive
  groups now open a z scope, so a passive overlay opened below an already-open
  higher scope traps instead of silently painting out of order.
  `overlay_dropped` now reports the overlay list's `dropped_commands` counter;
  text overflow is counted in `dropped_text_bytes`.

### Changed

- **Breaking**: application-facing UI is consolidated under `ingot:fit`.
  `fit.App`, `fit.Session`, and the PascalCase `fit.Builder` vocabulary replace
  direct `ingot:ui`/`ingot:ui_gfx` hosting. The immutable `Fit_Node` tree,
  `App_Session` aliases, and legacy `fit` re-exports of `ui` are removed.
- **Breaking**: mutable active-context scopes, active-context routing machinery,
  and broad lower-case graphics wrappers are removed. Framework replay and
  documented multi-context hosts use the narrow owner-bound `gfx.Frame` seam;
  PascalCase remains source-compatible as thin explicit calls against the
  default owner. The historical graphics-context debt baselines are removed and
  the ownership guard now requires zero findings.
- **Breaking**: `ui.line_chart` and `ui.bar_chart` take `Chart_Facade_Options`
  only; the positional `(height, opts)` overloads and their proc groups are
  removed. Call sites migrate mechanically: `line_chart(u, series, &state, 80)`
  becomes `line_chart(u, series, &state, {height = 80})`.
- **Breaking**: the `view` document builder reports `view.Build_Error` instead
  of `bool`. `doc_intern`, `doc_add`, and `doc_add_keyed` return
  `(value, Build_Error)`; `doc_set_key`, `doc_set_label`, and `doc_set_value`
  return `Build_Error`. The zero value `.None` means success, so `or_return`
  composes as before, and a caller can finally distinguish a full node table
  from a full text blob from an invalid parent.
- **Breaking**: `gfx.orbit_camera_zoom_toward` takes `scroll: ^f32` and zeroes
  it, consuming the channel so the same scroll value can no longer also reach
  `update_orbit_camera` and double-apply the distance change.

### Fixed

- `.ingv` validation rejects NaN and infinite track/number fields before they
  reach layout or widget arithmetic. The decoder reports an invalid document,
  and the deterministic failing fuzz seed is retained as a byte-stable
  decode/re-encode regression.
- The historical assertion-risk baseline is removed. The assertion discipline
  guard now requires zero uncovered pointer, index, queue, ownership, state, or
  untrusted-input findings across authored packages.
- `view.doc_add_keyed` is transactional: when the label intern or the node
  append fails after earlier interns succeeded, the text blob is restored to
  its entry length instead of silently keeping unreferenced bytes.
- `view` document authoring is O(n): appending a node links through a per-parent
  tail cache instead of walking the whole sibling chain, so building a wide
  document (many children under one parent) no longer costs O(n²) link steps.

- `ui`: z-ordered input claims silently suppressed every click inside the
  claiming surface. `interact_frame_begin` latched press occlusion once per
  gesture, but it runs before any z scope opens, so a press inside a `Z_PANEL`
  or `Z_MODAL` claim resolved at the ambient `Z_CONTENT` and was recorded as
  occluded for every reader - including the panel's own widgets. Hover and
  pressed still resolved correctly inside the widget's scope, so affected
  buttons looked live and did nothing. Occlusion cannot be answered at frame
  begin because the answer depends on the reader's depth, so the latch now
  stores the blocking z and `interact` compares it against the widget's own.

## [0.1.5] - 2026-08-09

`0.1.4` was not published. This is a source-only release; no binaries,
installers, or web bundles are attached.

### Added

- Raylib-parity additions to `ingot:gfx`: `DrawRectanglePro` (rotated filled
  rectangle with origin pivot), `DrawFPS` (default-font FPS overlay), and the
  `PI`, `RAD2DEG`, `DEG2RAD` constants.
- Allocation-free native `screen_to_world_ray`, `intersect_plane`,
  `intersect_sphere`, and `intersect_bounds` queries with normalized rays and
  ROS-world hit positions, normals, and distances.
- Deterministic, delta-time camera motion helpers and matrix-driven Pro 3D entry
  points for compatibility and explicit GPU rendering.
- `ui_gfx.session_acquire_frame` and `session_present_frame`, an allocation-free
  capability pair that binds UI paint to its graphics owner and handles normal
  submission and frame-temporary cleanup. Existing low-level session frame APIs
  remain available for hosts with split lifecycle requirements.
- Context-bound `ui_gfx.App` hosting through `app_init_context`, `app_start`,
  `app_tick`, and `app_stop`, including a two-App native contract fixture.
- Shared bounded Unix/Windows gate manifests and cross-platform test supervision.

### Changed

- Pointer input claims now carry a z-order. `ui.route_claim` and
  `ui.route_claim_all` take an optional `z` (default `Z_PANEL`), and a widget is
  occluded only by claims *strictly above* its ambient z-scope (default
  `Z_CONTENT`). Equal z does not occlude, so a docked panel can claim its own
  rect, keep its own widgets interactive, and make the canvas beneath it inert -
  which a flat claim set could not express. Existing call sites are unchanged in
  both source and behaviour: every current claim is a popup or modal that should
  sit above content. New: `ui.Z_Order`, `ui.Z_CONTENT`, `ui.Z_PANEL`,
  `ui.Z_POPUP`, `ui.Z_MODAL`, `ui.Z_TOAST`, `ui.Z_TOOLTIP`, `ui.z_scope_begin`,
  `ui.z_scope_end`, `ui.frame_z`.
- `ui.overlay_begin` takes an optional `z` (default `Z_POPUP`) and, when it
  claims input, opens a matching z scope closed by `ui.overlay_end`.
- **Breaking:** 3D examples, generated primitives, and documented world-space
  behavior now use right-handed ROS coordinates: +X forward, +Y left, +Z up.
- UI paint replay now uses owner-validated graphics frames rather than the
  PascalCase compatibility surface. PascalCase remains the default-context
  raylib migration facade.

### Deprecated

- `ui.route_claim_backdrop`: retained for one release. Modals now claim the whole
  screen at `Z_MODAL` and draw inside a matching z scope, so the four-band
  construction that existed only to avoid self-occlusion is no longer needed.
  Replace with `ui.route_claim(frame, rect, ui.Z_MODAL)` plus
  `ui.z_scope_begin`/`ui.z_scope_end`.

### Added

- `ui.point_in_rect_i32`: hit-tests a pointer against a layout `Rect_I32`. Four
  independent copies of this predicate existed across the library's examples and
  its consumers, each re-deriving the half-open edge semantics.

## [0.1.3] - 2026-08-03

### Added

- `ingot:view`: saved views. A view is a flat, byte-copyable description of a
  UI that a tool can author, save, ship, and diff, replayed through the public
  `ui` facade by `view.view_play`. Format version 1 covers layout containers,
  buttons, the core form controls, and presentational widgets.
  - `View_Doc` is the mutable authoring buffer; `View` is the exactly-sized
    borrowed form `view_play` consumes, so a shipped view costs only its own
    node bytes rather than the authoring capacity.
  - `view_decode` validates and returns `ok = false` for any malformed input.
    It never asserts on file content, because a corrupt or truncated `.ingv` is
    an operating error and a view may arrive over a network.
  - `Bindings` is the consumer contract: the document owns no state, the caller
    supplies pointers and reads interaction from an `Event_Sink`. Identity comes
    from author-assigned keys, so a control survives relabelling and reordering.
  - `tools/viewc` compiles a `.ingv` into Odin source. It emits the document as
    a static `View` literal rather than as unrolled widget calls, so `view_play`
    stays the only implementation of what a node means and there is no second
    emitter to drift from it.
  - `view.Play_Trace` + `view_play_traced`: optional per-node rect recording
    over the same single walk, so a tool can hit-test the played frame
    (`trace_node_at`, `trace_container_at`). Builder instrumentation, not part
    of the wire format.
  - `doc_set_key` / `doc_set_label` / `doc_set_value` and `doc_text_compact`:
    text editing over the append-only blob, with compaction so an editing
    session cannot exhaust it.
  - `examples/view_builder` is a working builder whose canvas is the runtime: it
    plays the document being edited through the same `view_play` a shipping
    consumer uses. Widgets drag from the palette onto the canvas with a live
    drop-target highlight; in Edit mode clicking the canvas selects the element
    under the cursor (Live mode keeps widgets interactive); the inspector is a
    kind-aware config panel with real text fields for key/label/placeholder.
    `scripts/smoke-view-builder.sh` drives it headlessly.
  - `fuzz/run.sh view` fuzzes the decoder with random bytes, mutated files, and
    forged length fields.
  - See [the view format](docs/view-format.md).
- `Flex_Axis` and the optional `axis` argument on `flex_begin`: a caller can
  now state which way it believes a declared run travels, and a run opened
  against the wrong frame asserts instead of laying out silently wrong. Tracks
  meant for a row, declared on a column, carve the frame's HEIGHT into N bands
  so every cell draws at the same x - and because the run is still fully
  consumed, `flex_end`, `layout_pop` and `layout_end` all pass. The intent
  exists only at the call site, so only the call site can supply it.
  `.Unspecified` is the default and preserves existing behaviour exactly.
  A separate enum rather than a new `Layout_Kind` member on purpose: several
  places branch as `if kind == .Column { ... } else { ... }`, so an extra
  `Layout_Kind` state would be treated as a row by all of them.
- `table_row_begin` / `table_row_end`: carve one data row and open the
  header's column tracks across it in a single call, so a table row cannot be
  declared down the enclosing column. Pairs the `push_row` and the `flex_begin`
  that the two-step form left to every caller to remember.
- `gfx.renderer_peak_usage` and `Paint_List.peak_count` / `peak_text_len`:
  always-on high-water marks for the batch and paint buffers, reported by the
  gallery smoke run. Unlike `Renderer_Stats` these are not gated behind a
  build flag, because they are the evidence the fixed capacities are sized
  from - a bound nobody can measure is a guess.
- `Grid` (`grid_begin` / `grid_next` / `grid_end`): a bounded single-pass
  cell grid with exact column division, replacing per-cell x/y arithmetic.
- `Main_Align` justification (`Start` / `Center` / `End` / `Space_Between`)
  for declared flex runs, on `flex_begin`, `flex_row_begin`, and
  `flex_column_begin`.
- `end` now returns the consumed content extent, and `ROOT_EXTENT_OPEN`
  names the root height for a `Ui` inside a scrolling pane, removing the
  magic-height and end-of-section pad arithmetic from call sites.
- Semantic styling variants: `label` accepts `Text_Role` + `Ink`, and
  `status_pill`, `progress_bar`, `progress_bar_animated`, and `kv_row`
  accept `Ink` values (with muted-key / emphasized-value defaults for
  `kv_row`) instead of raw theme colors.
- `combobox`: a searchable dropdown with a filter text field, keyboard
  navigation, and a bounded overlay popup.
- `date_picker`: an ISO-date field with a calendar popup, plus pure
  `calendar_*` helpers (leap years, Zeller weekday, parse/format).
- `table_header` / `table_tracks` / `Table_Sort`: sortable table headers that
  share flex tracks with caller-drawn rows.
- `tab_bar`: a focusable tab strip with an accent underline.
- `toast_push` / `toasts_draw`: a bounded timed notification queue drawn on
  the overlay layer.
- `confirm_dialog`: a modal preset with Cancel / Confirm for destructive
  actions.
- A web form backend (`ui_runtime_set_web_form_backend`) so text inputs and
  submit buttons mirror into real browser form controls again; the graphics
  adapter installs it automatically.
- Surface design tokens (`ui/tokens.odin`): `Surface`, `Visual_State`,
  `Radius`, `Border`, `Elevation`, and `Tint`, resolved by `surface_colors`,
  `radius_ratio`, `radius_pixels`, `radius_segments`, `border_pixels`,
  `elevation_offset`, `tint_alpha`, and `color_tinted`. These are the missing
  peer of `Text_Role`/`Ink` (type and text color) and `Space` (spacing):
  nothing previously named what a *filled region* meant, so each widget
  answered independently and the answers drifted apart.
- `draw_surface`: one fill + border + shadow entry point for a token-styled
  region, so two widgets cannot disagree about the same surface class.
- Paper materials (`ui/material.odin`): `draw_shadow_hard`, `draw_rule_lines`,
  `draw_margin_rule`, `draw_dot_grid`, `dot_grid_fits`, `draw_paper_tooth`,
  `draw_wash`, `draw_pigment_block`, `draw_highlight_swipe`,
  `draw_scribble_fill`, `draw_tape_strip`, `draw_dog_ear`, and
  `draw_hand_underline`, each bounded by a named constant derived from the
  paint budget.
- `THEME_SKETCH_WARM` and `THEME_SKETCH_GREY` (`theme_sketch_warm` /
  `theme_sketch_grey`): toned sketchbook stock - kraft tan (190,158,116) and
  slate blue-grey (150,164,168) - carrying saturated artist pigments. Both
  clear full WCAG AA (4.5:1) across every reading ink and surface, which the
  existing dark and light palettes do not.
- `Pigment` enum and `Theme.pigments`: a paint table separate from the `fg_*`
  text inks, resolved by `theme_pigment` with a fallback to the matching ink so
  pigment-aware widgets need no branch on palettes that carry no paint.
  Pigment and ink were originally the same values, which made every pigment
  inherit a text role's duty to clear AA against the ground - and since the
  lightest pigment then dictated how light the paper could be, yellow ochre
  held the grounds two steps paler than real toned stock. Paint carries no
  text, so it is bound by no text rule; splitting the two is what let the
  grounds be properly toned.
- `Theme.chalk` and `draw_chalk_highlight`: the light direction. A white ground
  can only be worked darker, so a form is built entirely from shadow; a toned
  ground is worked both ways - ink below it, chalk above it. Ignoring that is
  why the first toned palettes read as dimmed light themes.
- `scatter_hash` / `scatter_unit`: a pure index hash for deterministic
  scattering. Frames are event-driven, so a random generator would reshuffle
  paper grain on every unrelated redraw and break capture reproducibility.
- `Theme.surface_pressed`, `fg_on_accent`, `caption_hover`, `caption_pressed`,
  `caption_close_hover`, `caption_close_pressed`, `spell_error`, `paper_rule`,
  `paper_tooth`, `graphite`, `highlighter`, `tape_color`, `ink_faded`, and
  `substrate`.
- `theme_ink`: the pure half of `text_ink`, so contrast can be audited without
  a live frame.
- `PAINT_COMMANDS_PEAK_4K` and `PAINT_COMMANDS_HEADROOM`: the measured 4K
  command peak and the room left over, so new per-frame decoration is bounded
  against real headroom rather than against the raw capacity.
- Gallery: a `Theme` section rendering the whole token system, including a
  Surface x Visual_State matrix driven by explicit state rather than by
  pointer position. Hover and pressed were previously unobservable in any
  screenshot, which is how two state defects shipped.
- `draw_hand_underline`: the doubled, unequal stroke pair a person makes when
  underlining by hand. A single straight rule under a heading reads as a
  border - the eye takes it as the top edge of whatever follows.
- `space_pixels`: the frame-level spacing resolver. The explicit tier owns its
  own geometry and has no `Ui` to ask, so it previously had to re-declare the
  spacing scale locally; `space_px` now delegates here so there is one table.
- Gallery: the theme control cycles Dark, Light, Sketch Warm and Sketch Grey
  instead of toggling a boolean, so both toned palettes are reachable. High
  contrast joined that same cycle, replacing a separate `high_contrast` boolean
  and its dedicated Contrast button: the two flags spanned eight combinations
  but only five were reachable, because selecting high contrast had to
  force-clear the palette - applying that palette discards the other choice
  entirely, so they were one decision modelled as two. As an enum the
  exclusivity is structural and the force-clear is gone. Reduced motion stays a
  separate control because it genuinely is orthogonal: it applies to every
  palette, high contrast included. Gallery smoke now derives its theme steps
  from the enum rather than a hand-written table, so a new palette is covered
  without anyone remembering to extend it. Before this work the paper materials
  had no callers at all - the aesthetic existed in the library but could not be
  seen from any application.
- Gallery: the `Theme` section is a sketchbook colour study - toned ground with
  paper grain, overlapping pigment washes, and measurements hung in a reserved
  margin column. `Selected` renders as a highlighter swipe and `Pressed` as a
  scribble, so the materials run every frame rather than only in tests.

### Changed

- `Substrate.margin` is now `Substrate.margin_rule`, and controls *only*
  whether the vertical rule is drawn. The body indent follows from
  `kind != .None`. The single flag previously meant both, so "keep the reserved
  margin column, drop the rule down it" could not be expressed - and the column
  is what keeps measurements out of the swatches they describe.
- `Theme.paper_margin` is replaced by `Theme.graphite` (pencil marks: heading
  underlines and captions). With the margin rule gone from the built-in
  palettes the old role had no meaning.
- `Substrate_Kind` gains `.Tooth`, the sketchbook substrate. The built-in
  themes no longer select `.Ruled`; `draw_rule_lines` and `draw_margin_rule`
  remain exported and tested for consumers who want writing paper.
- **Breaking:** `ui_gfx.App_Config.clear_color` is removed. The window
  background is now derived from the active theme by `ui_gfx.app_clear_color`.
  The field was a stored *copy* of `theme.bg_app`, and every theme switch had
  to remember to update it; `chart_demo` did not, so switching it to the light
  palette left a dark window. Applications should delete their `clear_color`
  assignment - the window now follows the theme automatically. Because every
  call site uses named-field literals, removing the field is a compile error
  rather than a silent behaviour change.
- Caption buttons, the spellcheck squiggle, and the split-drop hint read their
  colors from the palette instead of from file-local constants. The caption
  constants were a 15-alpha and a 10-alpha white wash, which is invisible on
  the high-contrast palette's pure black title bar.
- Disabled controls resolve to `fg_disabled` everywhere. `button_at` used
  `fg_muted_dim` while menus used `fg_disabled`, so a disabled button and a
  disabled menu item rendered in different colors in the same frame.
  `fg_muted_dim` is now `Ink.Muted` only.
- Gallery smoke runs theme *combinations* rather than four mutually exclusive
  steps, so high contrast with reduced motion is exercised.

### Fixed

- Windows remained visible while synchronous application and graphics shutdown
  completed after an OS close request. Windows now hide as soon as GLFW accepts
  the request, while macOS and Linux retain their native close behavior. The
  closing frame skips target-FPS pacing, the shutdown callback retains a valid
  graphics context, and all resources continue through ordered teardown.
- Markdown `[label](target)` links were not parsed, and the failure was not a
  clean one: parsing began at the scheme, so `[docs](https://x)` rendered as
  the literal text `[docs](`, then a live link reading the raw URL, then `)`.
  The markup was visible and the label was not. `Text_Span` gains `href`, which
  a bare URL sets to its own text, so a consumer never has to ask which
  spelling produced the span.
- Markdown links were never clickable. The type comment claimed they were, but
  nothing hit-tested them - they were accent-coloured underlined text and
  nothing more. `Markdown_Context` now records the hovered link during the draw
  pass, requests a pointer cursor, brightens the hovered span, and reports
  activation through `markdown_link_activated`. The package imports only
  `core:*` so it cannot open a URL itself; the application decides what
  following a link means, which also lets it route relative targets internally
  rather than handing every click to a browser.
- Dropdown, date-picker, and checkbox borders were passing an unscaled `1`
  where their own popups scaled correctly, so at 2x DPI a field's border was
  one physical pixel and its popup's was two. All borders now resolve through
  `border_pixels`.
- `THEME_HIGH_CONTRAST.button_pressed` was pure white, identical to
  `button_hover`, so a pressed high-contrast button gave no feedback
  distinguishable from hover.

## [0.1.1] - 2026-07-28

### Added

- `ui_gfx.Session` as the canonical owner for custom frame loops, with accessors
  for runtime, frame, input, output, and user-scale updates.
- Snapshot-backed viewport, time, DPI, FPS, and monitor-refresh frame queries.
- Balanced Canvas UI scopes for translated, clipped, renderer-independent paint.
- `gfx.FocusWindow` and the corresponding explicit-context window-focus API.
- A gallery header, theme-synchronized background, and redraws after theme
  changes.

### Changed

- `scripts/check_assertions.py` recognises `assert_contextless` as an
  assertion. `\bassert\b` never matches inside it, so every
  `proc "contextless"` - which is what a platform event callback must be -
  could only ever reach the gate as baseline debt, or be "fixed" by moving its
  contract to a caller that cannot enforce it.

- **Paint capacities right-sized from measurement.** `PAINT_COMMAND_CAP` is
  now `8192` (was `32768`) and `PAINT_TEXT_CAP` is `32768` (was `262144`),
  both overridable via `-define:INGOT_PAINT_COMMAND_CAP` /
  `INGOT_PAINT_TEXT_CAP`. These are inline arrays and `Ui_Output` holds two of
  them, so the old values reserved 8.4 MiB per app permanently. The gallery
  smoke run - every section including the 1000-button stress grid - peaks at
  2,046 commands and 7,138 text bytes at 3840x2160, so the new caps keep ~4x
  headroom over the heaviest measured frame while cutting `Ui_Output` to
  1.97 MiB. Overflow remains graceful and counted (`dropped_commands`,
  `dropped_text_bytes`); a consumer with heavier frames can raise either cap.
  Net effect on the web demo: initial wasm memory drops from 20.8 MB to
  12.5 MB.
- `gfx.BATCH_MAX_VERTICES` / `BATCH_MAX_INDICES` are now `#config`
  overridable. Their defaults are **unchanged**: the same measurement shows
  4K already reaching 41% of the vertex capacity, so these are correctly
  sized for desktop and only a target with a known-small framebuffer should
  lower them.
- `ui_gfx.App` now delegates UI lifecycle ownership to `Session`.
- Direct `ui_gfx.Adapter` lifecycle calls are classified as backend-only, and
  consumer checks enforce the documented UI API layers.
- UI focus uses stable widget IDs, facade APIs use rectangle bounds consistently,
  and facade scaling ownership is explicit.
- Chart and dropdown frame allocations are bounded.
- Gallery rendering receives its UI frame explicitly.
- `App_Session_Config`, `App_Session`, and `app_session_*` remain available
  through `v0.2.x` and are removed in `v0.3.0`.

### Fixed

- Web: every edge-driven key was dropped. The browser backend kept its own
  copy of the key/char/wheel staging buffer, named identically to the shared
  one in `Input`, and published it straight into `Input.pressed` / `released`
  / `repeat` from `platform_poll_events`; `_input_publish_staged` then
  assigned over the result later in the same `input_poll` and erased it.
  Typed characters kept working because they travel in the char ring, so the
  fault read as flaky input rather than a dead code path while Enter,
  Backspace, Delete, Tab and the arrow keys did nothing. The duplicate buffer
  is gone: the DOM entry points now stage into `g.inp` through the same
  `_stage_key` / `_stage_char` the GLFW callbacks use, leaving one staging
  buffer and one publisher, and `_input_publish_staged` asserts on entry that
  nothing published ahead of it so the ordering contract cannot rot again.
  Only the browser's live platform-query state (key held, cursor position,
  button held, hover) and the touch-tap button edges remain web-local.
- Web: Enter is consumed on the hidden IME proxy, so it can no longer insert a
  newline into the `<textarea>` value the engine never reads.
- `text_input` boxes tall enough to show two or more lines now type a newline
  on Enter instead of submitting, matching every platform's text area. New
  `text_input_visible_lines` / `text_input_default_submit` expose the rule.
  One-line fields are unchanged, and Shift+Enter still types a newline there.
- Enter no longer both accepts a spelling suggestion and inserts a newline in
  the same frame.
- Pane paint commands are emitted in screen coordinates.
- Gallery clear and navigation colors follow the active theme.
- Web application state uses retained userdata across asynchronous startup.

### Migration

| Previous surface | Replacement |
|---|---|
| `App_Session` | `Session` |
| `app_session_init*` | `session_init*` |
| `app_session_begin_frame*` | `session_begin_frame*` |
| `app_session_end_frame*` | `session_end_frame*` |
| `app_session_destroy` | `session_destroy` |
| Separate runtime/frame/input/output/adapter values | One `Session` |
| Direct pane matrix and mouse-offset setup | `canvas_begin` / `canvas_end` |
| Backend time and viewport polling in views | `frame_*` snapshot queries |

## [0.1.0] - 2026-07-27

First public source release. Ingot is an immediate-mode application framework
for Odin, built on `vendor:wgpu`, targeting macOS/Metal, Windows/D3D12,
Linux/Vulkan, and browser WASM/WebGPU from one application source.

### What this release does and does not claim

This is a **source** release. No binaries, installers, or web bundles are
distributed; see [the binary and web release checklist](docs/oss-release-checklist.md).

Validated:

- The portable core builds and its package tests pass on macOS, Linux, and
  Windows in CI (`scripts/test.sh`, `scripts/check.sh`).
- Deterministic, seed-recorded fuzz harnesses cover UI wrapping, text input,
  interaction, HTTP/WebSocket parsing, terminal pumping, and frame lifetimes.
- ASan and TSan runs cover the Odin-side networking and concurrency paths.
- The web gate compiles the gallery, Breakout, and demo to WASM and runs
  dependency-free Node lifecycle and semantic tests (`scripts/check-web.sh`).
- A windowed GPU smoke test drives every UI scale, theme, and gallery section
  through real event handlers (`scripts/smoke-gallery.sh`).
- Media capture is byte-reproducible across runs (`scripts/capture-media.sh`).

Not validated:

- Every row of the release validation matrix in
  [production readiness](docs/production-readiness.md) is still `Not recorded`.
  There is no revision-pinned evidence for macOS/Metal, Linux/Vulkan,
  Windows/D3D12, real browsers, public-Internet TLS, GPU drivers, or assistive
  technology. Compile-only and Node-only results are not treated as validation.
- Simultaneous native multi-window rendering lacks Metal, Vulkan, and D3D12
  evidence.
- Linux desktop polish has not reached parity with macOS and Windows.
- Real PTY/ConPTY, native dialogs, and screen-reader behaviour need
  representative hardware.

### Added

- **`ingot:gfx`** - windowing, WebGPU batch rendering, shapes, textures, text,
  input, audio, gamepads, cameras, and a raylib/rlgl-shaped 2D API. Includes
  affine `Camera2D` transforms, per-pipeline blend modes, render targets, an
  opt-in GPU 3D pipeline, coalesced stream uploads, a lazily baked embedded
  default font, and independent multi-context support.
- **`ingot:ui`** - renderer-independent immediate-mode widgets, bounded
  single-pass flow layout, constrained flex sizing, paint output, input
  snapshots, accessibility semantics, themes, charts, markdown, a unified diff
  viewer, listboxes, overlays, and adaptive frame pacing.
- **`ingot:ui_gfx`** - adapter that captures `gfx` input, replays UI paint
  output, applies platform output, and hosts an `App_Session`.
- **`ingot:net`** - background HTTP and self-healing reconnecting WebSockets,
  including verified `wss://` with loopback TLS tests.
- **`ingot:prefs`, `ingot:sys`** - native settings files and web `localStorage`
  behind one API; URLs, native file dialogs, and platform integration.
- **`ingot:term`, `ingot:libvterm`, `ingot:pty`** - libvterm bindings with
  committed static libraries, PTY pumping, key translation, `forkpty` on Unix,
  and ConPTY on Windows.
- **`ingot:accesskit`** - AccessKit C API bindings with native static libraries;
  UI semantics bridge to native accessibility, and mirror to the DOM on web.
- **`ingot:testx`** - deterministic PRNG and inline snapshot helpers.
- Stable widget identity: scoped widget IDs, app-wide keyboard focus traversal,
  and focus scoping by active UI layer.
- Accessible high-contrast and reduced-motion themes.
- Event-driven idle rendering on native and web, with explicit redraw requests.
- IME support and cursor-based UI layout.
- `gfx.SaveRenderTexturePng` for deterministic GPU readback, plus a gallery
  capture harness and `scripts/capture-media.sh` that regenerate every README
  image reproducibly.
- `gfx.SetMousePosition` (raylib parity) and `ui.input_box_set_text`.
- Reproducible cross-framework widget benchmarks against pinned Dear ImGui and
  egui adapters, with a dated Apple M2 Max baseline.
- Cross-platform CI, a validation-evidence schema, and repository hygiene,
  assertion, style, and `gfx` context gates.

### Changed

- Reimplemented Ingot as a pure-Odin WebGPU framework on `vendor:wgpu`,
  replacing the earlier raylib-backed prototype, and unified the native and web
  targets behind one platform seam.
- Moved to explicit UI runtime and frame ownership, with backend-neutral frame
  interfaces and primary paint streamed to graphics adapters.

### Fixed

- Render-target scissor rects now honour the y-flipped render-target
  projection. Clipped content drawn inside a render target previously mirrored
  its position, which could hide short clip bands such as a text input's inner
  clip entirely.
- Text truncation now measures through the same path auto-layout uses. Layout
  measured via the runtime text backend while truncation measured via the legacy
  text system, so labels that fit exactly were cut with an ellipsis.
- `ui.spinner` honours `reduced_motion`, matching the caret's contract. It
  previously animated regardless and kept idle event-driven applications
  repainting forever.
- Prevented a libvterm UTF-8 decode buffer overflow.
- Validated `LoadFontFromMemory`'s caller-supplied buffer.

[Unreleased]: https://github.com/Nic-vdwalt/ingot/compare/0.1.5...HEAD
[0.1.5]: https://github.com/Nic-vdwalt/ingot/compare/0.1.3...0.1.5
[0.1.3]: https://github.com/Nic-vdwalt/ingot/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/Nic-vdwalt/ingot/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/Nic-vdwalt/ingot/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/Nic-vdwalt/ingot/releases/tag/0.1.0
