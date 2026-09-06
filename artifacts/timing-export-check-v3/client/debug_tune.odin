// debug_tune.odin is the GPU-free core of the debug panel: the tunable-value
// store, the invalidation actions edits trigger, and the terrain reference the
// click-to-scope seam (debug_terrain_locate, per demo) fills in. Kept separate
// from debug_panel.odin so the value model stays unit-testable without a
// window, mirroring how profile.odin splits from profile_overlay.odin.
package main

import shared "../shared"
import "core:math"
import "core:strconv"
import ecs "ingot:ecs"

DEBUG_FILTER_MAX :: 96
DEBUG_OPEN_DURATION :: f32(0.18)
DEBUG_SCAN_DURATION :: f32(0.70)
DEBUG_SCOPE_FLASH_DURATION :: f32(0.32)
DEBUG_CHROME_PERIOD :: f32(2.40)
DEBUG_CARET_HALF_PERIOD :: f32(0.53)

Debug_Animation_Sample :: struct {
	open_progress: f32,
	scan_progress: f32,
	scan_visible:  bool,
	chrome_pulse:  f32,
	scope_flash:   f32,
	caret_visible: bool,
}

debug_animation_sample :: proc(
	elapsed, scope_elapsed, caret_elapsed: f32,
) -> Debug_Animation_Sample {
	open_linear := clamp(max(elapsed, 0) / DEBUG_OPEN_DURATION, 0, 1)
	open_inverse := 1 - open_linear
	open_progress := 1 - open_inverse * open_inverse * open_inverse
	scan_elapsed := max(elapsed - DEBUG_OPEN_DURATION, 0)
	scan_visible := elapsed >= DEBUG_OPEN_DURATION && scan_elapsed < DEBUG_SCAN_DURATION
	scan_progress := clamp(scan_elapsed / DEBUG_SCAN_DURATION, 0, 1)
	phase := math.mod(max(elapsed, 0), DEBUG_CHROME_PERIOD) / DEBUG_CHROME_PERIOD
	chrome_pulse := 0.5 + 0.5 * math.sin(phase * 2 * math.PI)
	scope_linear := 1 - clamp(max(scope_elapsed, 0) / DEBUG_SCOPE_FLASH_DURATION, 0, 1)
	caret_step := int(max(caret_elapsed, 0) / DEBUG_CARET_HALF_PERIOD)
	return {
		open_progress = open_progress,
		scan_progress = scan_progress,
		scan_visible = scan_visible,
		chrome_pulse = chrome_pulse,
		scope_flash = scope_linear * scope_linear,
		caret_visible = caret_step & 1 == 0,
	}
}

Debug_Filter :: struct {
	text:   [DEBUG_FILTER_MAX]u8,
	length: int,
	cursor: int,
}

debug_filter_text :: proc(filter: ^Debug_Filter) -> string {
	assert(filter != nil, "debug filter: nil filter")
	return transmute(string)filter.text[:filter.length]
}

_debug_filter_ascii_lower :: proc(value: u8) -> u8 {
	if value >= 'A' && value <= 'Z' do return value + ('a' - 'A')
	return value
}

_debug_filter_contains :: proc(text, token: string) -> bool {
	if len(token) == 0 do return true
	if len(token) > len(text) do return false
	text_bytes := transmute([]u8)text
	token_bytes := transmute([]u8)token
	for start in 0 ..= len(text_bytes) - len(token_bytes) {
		matched := true
		for offset in 0 ..< len(token_bytes) {
			if _debug_filter_ascii_lower(text_bytes[start + offset]) !=
			   _debug_filter_ascii_lower(token_bytes[offset]) {
				matched = false
				break
			}
		}
		if matched do return true
	}
	return false
}

debug_filter_matches :: proc(query: string, parts: ..string) -> bool {
	query_bytes := transmute([]u8)query
	start := 0
	for start < len(query_bytes) {
		for start < len(query_bytes) && query_bytes[start] <= ' ' do start += 1
		if start >= len(query_bytes) do break
		end := start
		for end < len(query_bytes) && query_bytes[end] > ' ' do end += 1
		token := query[start:end]
		matched := false
		for part in parts {
			if _debug_filter_contains(part, token) {
				matched = true
				break
			}
		}
		if !matched do return false
		start = end
	}
	return true
}

debug_filter_insert :: proc(filter: ^Debug_Filter, text: string) -> bool {
	assert(filter != nil, "debug filter: nil filter")
	if len(text) == 0 do return false
	if len(text) > DEBUG_FILTER_MAX - filter.length do return false
	for byte in transmute([]u8)text {
		if byte < 0x20 || byte > 0x7e do return false
	}
	for index := filter.length; index > filter.cursor; index -= 1 {
		filter.text[index + len(text) - 1] = filter.text[index - 1]
	}
	copy(filter.text[filter.cursor:], transmute([]u8)text)
	filter.length += len(text)
	filter.cursor += len(text)
	return true
}

debug_filter_insert_rune :: proc(filter: ^Debug_Filter, codepoint: rune) -> bool {
	if codepoint < 0x20 || codepoint > 0x7e do return false
	bytes := [1]u8{u8(codepoint)}
	return debug_filter_insert(filter, transmute(string)bytes[:])
}

debug_filter_backspace :: proc(filter: ^Debug_Filter) -> bool {
	assert(filter != nil, "debug filter: nil filter")
	if filter.cursor <= 0 do return false
	for index in filter.cursor ..< filter.length {
		filter.text[index - 1] = filter.text[index]
	}
	filter.cursor -= 1
	filter.length -= 1
	return true
}

debug_filter_delete :: proc(filter: ^Debug_Filter) -> bool {
	assert(filter != nil, "debug filter: nil filter")
	if filter.cursor >= filter.length do return false
	for index in filter.cursor + 1 ..< filter.length {
		filter.text[index - 1] = filter.text[index]
	}
	filter.length -= 1
	return true
}

debug_filter_clear :: proc(filter: ^Debug_Filter) {
	assert(filter != nil, "debug filter: nil filter")
	filter.length = 0
	filter.cursor = 0
}

// Ceiling for the flora density multiplier; beyond ~4x the per-tile pools
// saturate and the scatter asserts on overflow long before the visuals help.
DEBUG_FLORA_DENSITY_MAX :: f32(3)
DEBUG_EXTENSION_SECTION_MAX :: 16

Debug_Extension_Section_Key :: enum u8 {
	Section_0,
	Section_1,
	Section_2,
	Section_3,
	Section_4,
	Section_5,
	Section_6,
	Section_7,
	Section_8,
	Section_9,
	Section_10,
	Section_11,
	Section_12,
	Section_13,
	Section_14,
	Section_15,
}

// debug_extension_section_key_valid protects conversions from demo-owned
// values before they index the panel's fixed collapse mask.
debug_extension_section_key_valid :: proc(key: Debug_Extension_Section_Key) -> bool {
	return int(key) >= 0 && int(key) < DEBUG_EXTENSION_SECTION_MAX
}

// Debug_Tuning holds value-like constants promoted to runtime for the debug
// panel. Defaults reproduce the compile-time values exactly, so a build that
// never opens the panel behaves identically. Constants that size arrays
// (FLORA_*_MAX, TERRAIN_CHUNK_*) deliberately stay compile-time.
Debug_Tuning :: struct {
	// Multiplies every scatter chance in flora_default_config; applied on
	// the next flora regenerate/stream, not retroactively.
	flora_density_scale: f32,
}

debug_tuning_default :: proc() -> Debug_Tuning {
	return {flora_density_scale = 1}
}

// Package-level rather than Client_State-resident because the background
// flora scatter reads it through flora_default_config without a Client_State;
// a single f32 read is reload- and thread-benign for a debug multiplier.
debug_tuning := Debug_Tuning {
	flora_density_scale = 1,
}

// Debug_Apply names the minimal invalidation an edit needs. Cheap actions run
// on every changed widget; World_Regenerate is only ever wired to an explicit
// button because it tears the whole map down.
Debug_Apply :: enum u8 {
	None,
	Flora_Regenerate,
	Flora_Mark_Dirty,
	Water_Rebuild,
	World_Regenerate,
}

// debug_apply dispatches one invalidation action against live client state.
debug_apply :: proc(value: ^Client_State, action: Debug_Apply) {
	assert(value != nil, "debug_apply: nil state")
	switch action {
	case .None:
	case .Flora_Regenerate:
		if value.world_ready && value.flora.ready {
			flora_regenerate(&value.flora, &value.terrain, &value.world, &value.ruins)
		}
	case .Flora_Mark_Dirty:
		flora_mark_dirty(&value.flora)
	case .Water_Rebuild:
		value.terrain.water_dirty = true
	case .World_Regenerate:
		if value.world_ready {
			value.regenerate_seed = value.world.foundation.seed
			value.regenerate_pending = true
		}
	}
}

Debug_Target_Kind :: enum u8 {
	World,
	Entity,
	Flora_Item,
	Surface,
}

Debug_Category :: enum u8 {
	World,
	Water,
	Terrain,
	Weather,
	Entities,
	Hud,
	Camera,
}

DEBUG_CATEGORY_COUNT :: len(Debug_Category)
DEBUG_CATEGORY_ORDER :: [DEBUG_CATEGORY_COUNT]Debug_Category {
	.World,
	.Water,
	.Terrain,
	.Weather,
	.Entities,
	.Hud,
	.Camera,
}
DEBUG_CATEGORY_TITLES :: [Debug_Category]string {
	.World    = "WORLD",
	.Water    = "WATER",
	.Terrain  = "TERRAIN",
	.Weather  = "WEATHER",
	.Entities = "ENTITIES",
	.Hud      = "HUD",
	.Camera   = "CAMERA",
}

Debug_Detail_Mode :: enum u8 {
	Simple,
	Advanced,
}

Debug_Detail_Tier :: enum u8 {
	Simple,
	Advanced,
}

debug_detail_visible :: proc(mode: Debug_Detail_Mode, tier: Debug_Detail_Tier) -> bool {
	return tier == .Simple || mode == .Advanced
}

Debug_Tab_Id :: struct {
	category: Debug_Category,
}

Debug_Tab_Entry :: struct {
	id:    Debug_Tab_Id,
	title: string,
}

DEBUG_TAB_MAX :: DEBUG_CATEGORY_COUNT

Debug_Tab_Registry :: struct {
	entries: [DEBUG_TAB_MAX]Debug_Tab_Entry,
	count:   int,
}

debug_tab_category :: proc(category: Debug_Category) -> Debug_Tab_Id {
	return {category = category}
}

debug_tab_default :: proc() -> Debug_Tab_Id {
	return debug_tab_category(.World)
}

debug_tab_registry_add :: proc(
	registry: ^Debug_Tab_Registry,
	id: Debug_Tab_Id,
	title: string,
) {
	assert(registry != nil, "debug tabs: nil registry")
	assert(title != "", "debug tabs: empty title")
	for index in 0 ..< registry.count {
		if registry.entries[index].id == id do return
	}
	assert(registry.count < DEBUG_TAB_MAX, "debug tabs: registry full")
	registry.entries[registry.count] = {id, title}
	registry.count += 1
}

debug_tab_registry_index :: proc(registry: ^Debug_Tab_Registry, id: Debug_Tab_Id) -> (int, bool) {
	assert(registry != nil, "debug tabs: nil registry")
	for index in 0 ..< registry.count {
		if registry.entries[index].id == id do return index, true
	}
	return 0, false
}

debug_tab_select_valid :: proc(
	registry: ^Debug_Tab_Registry,
	selected: Debug_Tab_Id,
) -> Debug_Tab_Id {
	assert(registry != nil, "debug tabs: nil registry")
	if _, ok := debug_tab_registry_index(registry, selected); ok do return selected
	fallback := debug_tab_default()
	if _, ok := debug_tab_registry_index(registry, fallback); ok do return fallback
	if registry.count > 0 do return registry.entries[0].id
	return fallback
}

debug_tab_body_visible :: proc(filtering: bool, selected, candidate: Debug_Tab_Id) -> bool {
	return filtering || selected == candidate
}

debug_pill_row_count :: proc(widths: []i32, available_width, gap: i32) -> int {
	if len(widths) == 0 do return 0
	assert(available_width > 0, "debug pills: invalid available width")
	assert(gap >= 0, "debug pills: invalid gap")
	rows := 1
	x := i32(0)
	for width in widths {
		pill_width := clamp(width, 1, available_width)
		if x > 0 && x + gap + pill_width > available_width {
			rows += 1
			x = 0
		}
		if x > 0 do x += gap
		x += pill_width
	}
	return rows
}

Debug_Surface_Kind :: enum u8 {
	Terrain,
	Ocean_Surface,
	Seafloor,
}

Debug_Entity_Ref :: struct {
	net_id: shared.Net_Id,
	entity: ecs.Entity,
}

// debug_target_resolve is the compatibility priority rule until all targets
// participate in nearest-distance candidate arbitration.
debug_target_resolve :: proc(entity_hit, flora_hit, surface_hit: bool) -> Debug_Target_Kind {
	if entity_hit do return .Entity
	if flora_hit do return .Flora_Item
	if surface_hit do return .Surface
	return .World
}

// Debug_Terrain_Ref names one render chunk (flat grid) or render patch
// (cube-sphere) plus the sampled surface data at the clicked point. Filled by
// the demo seam debug_terrain_locate; chunk_index feeds debug_terrain_remesh
// so the panel never re-derives world-model indexing.
Debug_Terrain_Ref :: struct {
	// Cube face index; -1 on the flat world.
	face:           i32,
	chunk_x:        i32,
	chunk_y:        i32,
	chunk_index:    int,
	grid_x:         i32,
	grid_y:         i32,
	height:         f32,
	biome:          shared.Biome_Id,
	point:          [3]f32,
	surface_normal: [3]f32,
	// World-space box the scope outline draws; sized by the demo because
	// only it knows the chunk's world extent.
	bounds_center:  [3]f32,
	bounds_size:    [3]f32,
	valid:          bool,
}

Debug_Surface_Ref :: struct {
	kind:    Debug_Surface_Kind,
	terrain: Debug_Terrain_Ref,
}

Debug_Target :: struct {
	kind:        Debug_Target_Kind,
	entity:      Debug_Entity_Ref,
	flora_index: int,
	surface:     Debug_Surface_Ref,
}

debug_target_world :: proc() -> Debug_Target {
	return {kind = .World, flora_index = -1}
}

debug_target_entity :: proc(net_id: shared.Net_Id, entity: ecs.Entity) -> Debug_Target {
	return {kind = .Entity, entity = {net_id, entity}, flora_index = -1}
}

debug_target_flora :: proc(index: int) -> Debug_Target {
	return {kind = .Flora_Item, flora_index = index}
}

debug_target_surface :: proc(kind: Debug_Surface_Kind, terrain: Debug_Terrain_Ref) -> Debug_Target {
	return {kind = .Surface, flora_index = -1, surface = {kind, terrain}}
}

debug_pin_placement_ready :: proc(armed, terrain_hit: bool) -> bool {
	return armed && terrain_hit
}

debug_target_same_identity :: proc(a, b: Debug_Target) -> bool {
	if a.kind != b.kind do return false
	switch a.kind {
	case .World:
		return true
	case .Entity:
		if u64(a.entity.net_id) > 0 || u64(b.entity.net_id) > 0 {
			return a.entity.net_id == b.entity.net_id
		}
		return a.entity.entity == b.entity.entity
	case .Flora_Item:
		return a.flora_index == b.flora_index
	case .Surface:
		return(
			a.surface.kind == b.surface.kind &&
			a.surface.terrain.valid &&
			b.surface.terrain.valid &&
			a.surface.terrain.face == b.surface.terrain.face &&
			a.surface.terrain.grid_x == b.surface.terrain.grid_x &&
			a.surface.terrain.grid_y == b.surface.terrain.grid_y
		)
	}
	return false
}

// debug_parse_f32 parses a prefs float, falling back on malformed or
// non-finite input so a hand-edited settings file can never poison a
// multiplier with NaN (which would fail every clamp comparison).
debug_parse_f32 :: proc(text: string, fallback: f32) -> f32 {
	parsed, ok := strconv.parse_f32(text)
	if !ok do return fallback
	if !(parsed > -1e30 && parsed < 1e30) do return fallback
	return parsed
}
