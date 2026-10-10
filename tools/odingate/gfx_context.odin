package odingate

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Port of scripts/check_gfx_context.py: ingot:gfx routes every operation
// through an explicit ^Context. This rule forbids bare references to the
// package global `g`, the retired active-context API, `default_context()`
// escapes inside implementations, implicit drawing from ui_gfx, Ingot-only
// PascalCase procedures, and package globals that are not on the reviewed
// allow-list. Message strings are kept verbatim.

GFX_EXCLUDED_SUFFIXES := [?]string{"_test.odin", "_tests.odin", "_fuzz_test.odin"}
GFX_PASCAL_EXCLUDED_PREFIXES := [?]string{"gfx/rlgl/"}

GFX_ACTIVE_CONTEXT_NAMES := [?]string {
	"active_context",
	"_context_activate",
	"_context_restore",
	"Context_Scope",
	"context_scope_enter",
	"context_scope_leave",
}
GFX_IMPLICIT_DRAW_NAMES := [?]string {
	"BeginDrawing",
	"EndDrawing",
	"BeginScissorMode",
	"EndScissorMode",
	"context_scope_enter",
	"context_scope_leave",
}

Gfx_Controlled_Routing :: struct {
	key:   string,
	count: int,
}
// The two procedures that own the default-context slot touch `g` directly;
// every other reference is forbidden.
GFX_CONTROLLED_GLOBAL_ROUTING := [?]Gfx_Controlled_Routing {
	{"gfx/context.odin:default_context", 1},
	{"gfx/context.odin:set_default_context", 2},
}

Gfx_Allowed_Globals :: struct {
	path:  string,
	names: []string,
}
// Package-scope mutable declarations in ingot:gfx. Every entry is either
// process-wide by nature (one swizzled ObjC subclass, one COM vtable, one X
// display, one audio engine) or a per-window owner table keyed by native
// handle. Anything that routes a per-context event to a single hard-coded
// owner must live in Context instead; adding a name here is a review
// decision, not a fix.
GFX_ALLOWED_PACKAGE_GLOBALS := [?]Gfx_Allowed_Globals {
	{"gfx/audio_native.odin", {"g_audio"}},
	{"gfx/audio_web.odin", {"g_audio"}},
	{"gfx/batch.odin", {"BATCH_SHADER"}},
	{"gfx/context.odin", {"default_context_storage", "g", "context_id_next"}},
	{
		"gfx/dragdrop_darwin.odin",
		{
			"g_dd_orig_entered",
			"g_dd_orig_updated",
			"g_dd_orig_exited",
			"g_dd_orig_ended",
			"g_dd_orig_perform",
			"g_dd_views",
			"g_dd_owners",
			"g_dd_original_class",
			"g_dd_subclass",
		},
	},
	{
		"gfx/dragdrop_linux.odin",
		{
			"g_dd_resolved",
			"g_dd_ok",
			"g_dd_display",
			"g_dd_get_window",
			"g_dd_enter",
			"g_dd_leave",
			"g_dd_position",
			"g_dd_drop",
		},
	},
	{
		"gfx/dragdrop_windows.odin",
		{"g_dd_target_id", "g_dd_vtable", "g_dd_targets", "g_dd_ole_count"},
	},
	{"gfx/font_default.odin", {"DEFAULT_FONT_TTF"}},
	{"gfx/ime_darwin.odin", {"g_ime_swizzled", "g_ime_views", "g_ime_owners"}},
	{"gfx/loop_web.odin", {"g_web_callback"}},
	{"gfx/platform_native.odin", {"g_cursors", "glfw_live_windows", "_mono_epoch"}},
	{
		"gfx/platform_sdl3.odin",
		{"g_sdl_windows", "g_sdl_window_count", "g_sdl_cursors", "g_sdl_gamepads"},
	},
	{"gfx/platform_web.odin", {"g_web_ctx", "g_web_owner", "g_web_owner_epoch"}},
	{
		"gfx/presentation_darwin.odin",
		{
			"g_presentation_layers",
			"g_presentation_owners",
			"g_presentation_original_class",
			"g_presentation_subclass",
			"g_presentation_next",
		},
	},
	{"gfx/submission.odin", {"g_submission_id_next"}},
}

// PascalCase in ingot:gfx is reserved for the raylib migration facade: an
// exported PascalCase procedure must carry a name that vendor:raylib declares.
// The vocabulary is read from the pinned toolchain, never a hand-kept list.
Gfx_Raylib_Source :: struct {
	relative: string,
	prefix:   string,
}
GFX_RAYLIB_SOURCES := [?]Gfx_Raylib_Source {
	{"raylib.odin", ""},
	{"raymath.odin", ""},
	{"rlgl/rlgl.odin", "Rl"},
}

Gfx_Count_Kind :: enum u8 {
	Direct_Global,
	Active_Context,
	Implicit_Draw,
}

Gfx_Global_Decl :: struct {
	line: int,
	name: string,
}

// proc_decl_masked returns the masked text of a procedure's declaration from
// its first attribute line through the closing brace line.
proc_decl_masked :: proc(source: ^Source, entry: Proc_Decl) -> string {
	assert(source != nil, "proc_decl_masked: nil source")
	start := source.line_starts[entry.start_line]
	end := len(source.masked)
	if entry.end_line + 1 < len(source.line_starts) do end = source.line_starts[entry.end_line + 1]
	assert(start <= end, "proc_decl_masked: inverted span")
	return source.masked[start:end]
}

// gfx_count_in_text counts one kind of forbidden reference in masked text.
gfx_count_in_text :: proc(text: string, kind: Gfx_Count_Kind) -> int {
	switch kind {
	case .Direct_Global:
		return gfx_count_bare_g(text)
	case .Active_Context:
		count := 0
		for name in GFX_ACTIVE_CONTEXT_NAMES do count += count_words(text, name)
		return count
	case .Implicit_Draw:
		return gfx_count_implicit_draws(text)
	}
	return 0
}

// gfx_count_bare_g mirrors `(?<![A-Za-z0-9_.])g(?![A-Za-z0-9_])`.
@(private = "file")
gfx_count_bare_g :: proc(text: string) -> int {
	count := 0
	for index in 0 ..< len(text) {
		if text[index] != 'g' do continue
		if index > 0 && (is_word_byte(text[index - 1]) || text[index - 1] == '.') do continue
		if index + 1 < len(text) && is_word_byte(text[index + 1]) do continue
		count += 1
	}
	return count
}

count_words :: proc(text, word: string) -> int {
	count := 0
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_word(text, word, from)
		if at < 0 do break
		count += 1
		from = at + len(word)
	}
	return count
}

// gfx_count_implicit_draws mirrors `\b(Begin...|Draw[A-Z]\w*|context_scope_*)\s*\(`.
@(private = "file")
gfx_count_implicit_draws :: proc(text: string) -> int {
	count := 0
	index := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		if index >= len(text) do break
		if !is_word_byte(text[index]) || (index > 0 && is_word_byte(text[index - 1])) {
			index += 1
			continue
		}
		end := index
		for end < len(text) && is_word_byte(text[end]) do end += 1
		word := text[index:end]
		index = end
		next := skip_spaces(text, end)
		if next >= len(text) || text[next] != '(' do continue
		if gfx_is_implicit_draw_name(word) do count += 1
	}
	return count
}

@(private = "file")
gfx_is_implicit_draw_name :: proc(word: string) -> bool {
	for name in GFX_IMPLICIT_DRAW_NAMES do if word == name do return true
	return strings.has_prefix(word, "Draw") && len(word) > 4 && is_upper_byte(word[4])
}

// gfx_count_default_context mirrors `(?<![A-Za-z0-9_.])default_context\s*\(`.
gfx_count_default_context :: proc(text: string) -> int {
	count := 0
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		rel := strings.index(text[from:], "default_context")
		if rel < 0 do break
		at := from + rel
		from = at + 1
		if at > 0 && (is_word_byte(text[at - 1]) || text[at - 1] == '.') do continue
		next := skip_spaces(text, at + len("default_context"))
		if next < len(text) && text[next] == '(' do count += 1
	}
	return count
}

// gfx_counts_for_source counts one reference kind per procedure, keyed
// `path:proc`; procedures with zero references are omitted. A procedure that
// declares its own `g` (a local colour channel, say) shadows the package
// global, so its references are not routing and are not counted.
gfx_counts_for_source :: proc(source: ^Source, kind: Gfx_Count_Kind, counts: ^map[string]int) {
	assert(source != nil && counts != nil, "gfx_counts_for_source: nil argument")
	for entry in top_level_procs(source.file, context.temp_allocator) {
		if kind == .Direct_Global && gfx_declares_local(entry, "g") do continue
		count := gfx_count_in_text(proc_decl_masked(source, entry), kind)
		if count > 0 do counts[gfx_key(source.rel_path, entry.name)] = count
	}
}

// gfx_declares_local reports whether `name` is a parameter or a declared
// local anywhere in the procedure body.
@(private = "file")
gfx_declares_local :: proc(entry: Proc_Decl, name: string) -> bool {
	assert(entry.lit != nil && entry.lit.body != nil, "gfx_declares_local: bodiless proc")
	for param in param_names(entry.lit, context.temp_allocator) do if param == name do return true
	found := Gfx_Local_Search {
		name = name,
	}
	visitor := ast.Visitor {
		visit = gfx_local_search_visit,
		data  = &found,
	}
	ast.walk(&visitor, entry.lit.body)
	return found.found
}

@(private = "file")
Gfx_Local_Search :: struct {
	name:  string,
	found: bool,
}

@(private = "file")
gfx_local_search_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	search := cast(^Gfx_Local_Search)v.data
	if search.found do return nil
	decl, is_decl := node.derived.(^ast.Value_Decl)
	if !is_decl do return v
	for name_expr in decl.names {
		if ident, ok := name_expr.derived_expr.(^ast.Ident); ok && ident.name == search.name {
			search.found = true
			return nil
		}
	}
	return v
}

gfx_key :: proc(path, name: string) -> string {
	return strings.concatenate({path, ":", name})
}

// gfx_compatibility_facade accepts the one shape allowed to call
// default_context(): a public wrapper whose body is a single call forwarding
// to the context-taking implementation, with no control flow.
gfx_compatibility_facade :: proc(name, body: string) -> bool {
	assert(name != "", "gfx_compatibility_facade: empty name")
	for prefix in ([?]string{"_", "context_", "frame_", "adapter_"}) {
		if strings.has_prefix(name, prefix) do return false
	}
	if gfx_count_default_context(body) != 1 do return false
	if has_any_word(body, {"if", "when", "for", "switch", "defer"}) do return false
	callee, found := gfx_default_context_callee(body)
	if !found do return false
	if is_upper_byte(name[0]) {
		return(
			strings.has_prefix(callee, "context_") ||
			strings.has_prefix(callee, "Context") ||
			strings.has_prefix(callee, "_") \
		)
	}
	return strings.has_suffix(callee, name)
}

// gfx_default_context_callee finds the leftmost `callee(` whose argument
// text reaches `default_context(` through at most one level of nested
// parentheses and no `;{}` — the DEFAULT_CONTEXT_CALL regex.
@(private = "file")
gfx_default_context_callee :: proc(body: string) -> (callee: string, found: bool) {
	index := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		if index >= len(body) do break
		if !is_word_byte(body[index]) ||
		   is_digit_byte(body[index]) ||
		   (index > 0 && is_word_byte(body[index - 1])) {
			index += 1
			continue
		}
		end := index
		for end < len(body) && is_word_byte(body[end]) do end += 1
		open := skip_spaces(body, end)
		word := body[index:end]
		index = end
		if open >= len(body) || body[open] != '(' do continue
		if gfx_args_reach_default_context(body, open + 1) do return word, true
	}
	return "", false
}

@(private = "file")
gfx_args_reach_default_context :: proc(body: string, from: int) -> bool {
	pos := from
	for _ in 0 ..< TEXT_SCAN_MAX {
		if pos >= len(body) do return false
		if strings.has_prefix(body[pos:], "default_context") {
			next := skip_spaces(body, pos + len("default_context"))
			if next < len(body) && body[next] == '(' do return true
		}
		switch body[pos] {
		case ';', '{', '}', ')':
			return false
		case '(':
			close := pos + 1
			for close < len(body) && strings.index_byte(";{}()", body[close]) < 0 do close += 1
			if close >= len(body) || body[close] != ')' do return false
			pos = close + 1
		case:
			pos += 1
		}
	}
	return false
}

gfx_default_context_debt_for_source :: proc(source: ^Source, debt: ^map[string]int) {
	assert(source != nil && debt != nil, "gfx_default_context_debt_for_source: nil argument")
	for entry in top_level_procs(source.file, context.temp_allocator) {
		body := proc_decl_masked(source, entry)
		count := gfx_count_default_context(body)
		if count > 0 && !gfx_compatibility_facade(entry.name, body) {
			debt[gfx_key(source.rel_path, entry.name)] = count
		}
	}
}

gfx_zero_debt_failures :: proc(category: string, counts: map[string]int, report: ^Report) {
	assert(report != nil, "gfx_zero_debt_failures: nil report")
	for key in sorted_keys(counts, context.temp_allocator) {
		report_addf_raw(
			report,
			key_path(key),
			0,
			"%s: %s is forbidden (%d references)",
			key,
			category,
			counts[key],
		)
	}
}

// gfx_controlled_global_debt removes the exact expected counts of the two
// procedures that may touch `g`; a count that drifts is reported in full.
gfx_controlled_global_debt :: proc(
	counts: map[string]int,
	allocator := context.allocator,
) -> map[string]int {
	debt := make(map[string]int, allocator)
	for key, count in counts do debt[key] = count
	for entry in GFX_CONTROLLED_GLOBAL_ROUTING {
		if (debt[entry.key] or_else -1) == entry.count do delete_key(&debt, entry.key)
	}
	return debt
}

// gfx_package_global_declarations lists package-scope mutable declarations,
// descending through `when` blocks and skipping `@(rodata)`.
gfx_package_global_declarations :: proc(
	source: ^Source,
	allocator := context.allocator,
) -> []Gfx_Global_Decl {
	assert(source != nil, "gfx_package_global_declarations: nil source")
	decls := make([dynamic]Gfx_Global_Decl, allocator)
	for decl in top_level_value_decls(source.file, context.temp_allocator) {
		if !decl.is_mutable || has_attribute(decl.attributes[:], "rodata") do continue
		for name_expr in decl.names {
			if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
				append(&decls, Gfx_Global_Decl{ident.pos.line, ident.name})
			}
		}
	}
	return decls[:]
}

gfx_allowed_names :: proc(allowed: []Gfx_Allowed_Globals, path: string) -> []string {
	for entry in allowed do if entry.path == path do return entry.names
	return nil
}

// gfx_package_global_failures reports undeclared globals in file order and
// stale allow-list entries sorted by path and name.
gfx_package_global_failures :: proc(
	sources: []Source,
	allowed: []Gfx_Allowed_Globals,
	report: ^Report,
) {
	assert(report != nil, "gfx_package_global_failures: nil report")
	seen := make(map[string][dynamic]string, context.temp_allocator)
	for &source in sources {
		if has_any_prefix(source.rel_path, GFX_PASCAL_EXCLUDED_PREFIXES[:]) do continue
		permitted := gfx_allowed_names(allowed, source.rel_path)
		for decl in gfx_package_global_declarations(&source, context.temp_allocator) {
			if source.rel_path not_in seen {
				seen[source.rel_path] = make([dynamic]string, context.temp_allocator)
			}
			list := &seen[source.rel_path]
			assert(list != nil, "gfx_package_global_failures: seen entry vanished")
			append(list, decl.name)
			if !slice.contains(permitted, decl.name) {
				report_addf(
					report,
					source.rel_path,
					decl.line,
					"%s: undeclared gfx package global",
					decl.name,
				)
			}
		}
	}
	entries := make([]Gfx_Allowed_Globals, len(allowed), context.temp_allocator)
	copy(entries, allowed)
	slice.sort_by(entries, proc(a, b: Gfx_Allowed_Globals) -> bool {return a.path < b.path})
	for entry in entries {
		names := make([]string, len(entry.names), context.temp_allocator)
		copy(names, entry.names)
		slice.sort(names)
		present := seen[entry.path] or_else nil
		for name in names {
			if slice.contains(present[:], name) do continue
			report_addf_raw(
				report,
				entry.path,
				0,
				"%s: %s: stale ALLOWED_PACKAGE_GLOBALS entry (declaration not found)",
				entry.path,
				name,
			)
		}
	}
}

// gfx_pascal_case_violations reports exported PascalCase procedures whose
// names are not raylib vocabulary. Files marked `#+private` are skipped.
gfx_pascal_case_violations :: proc(source: ^Source, allowed: map[string]bool, report: ^Report) {
	assert(source != nil && report != nil, "gfx_pascal_case_violations: nil argument")
	for line in source.lines[:min(8, len(source.lines))] {
		if strings.has_prefix(line, "#+private") do return
	}
	for entry in top_level_procs(source.file, context.temp_allocator) {
		if !is_upper_byte(entry.name[0]) || entry.name in allowed do continue
		if entry.is_private || entry.is_deprecated do continue
		report_addf(
			report,
			source.rel_path,
			entry.decl.pos.line,
			"%s: Ingot-only PascalCase API; use snake_case (context_*, frame_*, or a default-owner wrapper)",
			entry.name,
		)
	}
}

// gfx_raylib_names reads every `Name ::` declaration from the vendor raylib
// sources; rlgl names gain the `Rl` prefix the binding applies.
gfx_raylib_names :: proc(
	vendor_root: string,
	allocator := context.allocator,
) -> (
	names: map[string]bool,
	ok: bool,
) {
	assert(vendor_root != "", "gfx_raylib_names: empty vendor root")
	names = make(map[string]bool, allocator)
	for entry in GFX_RAYLIB_SOURCES {
		path, join_err := filepath.join({vendor_root, entry.relative}, context.temp_allocator)
		if join_err != nil do return names, false
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintfln("odingate: raylib vocabulary source missing: %s", path)
			return names, false
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			name, declared := gfx_declaration_name(line)
			if !declared do continue
			names[strings.concatenate({entry.prefix, name}, allocator)] = true
		}
	}
	return names, true
}

// gfx_declaration_name mirrors `^\s*([A-Za-z_]\w*)\s*::`.
@(private = "file")
gfx_declaration_name :: proc(line: string) -> (name: string, ok: bool) {
	start := skip_spaces(line, 0)
	end := start
	for end < len(line) && is_word_byte(line[end]) do end += 1
	if end == start || is_digit_byte(line[start]) do return
	after := skip_spaces(line, end)
	if !strings.has_prefix(line[after:], "::") do return
	return line[start:end], true
}

@(private = "file")
gfx_print_measure :: proc(
	file: ^os.File,
	active, escapes, globals, draws: map[string]int,
	sources: []Source,
) {
	fmt.fprintln(file, "{")
	fmt.fprint(file, "  \"active_context_apis\": ")
	print_int_map(file, active, "  ")
	fmt.fprintln(file, ",")
	fmt.fprint(file, "  \"default_context_escapes\": ")
	print_int_map(file, escapes, "  ")
	fmt.fprintln(file, ",")
	fmt.fprint(file, "  \"globals\": ")
	print_int_map(file, globals, "  ")
	fmt.fprintln(file, ",")
	fmt.fprint(file, "  \"package_globals\": ")
	gfx_print_package_globals(file, sources)
	fmt.fprintln(file, ",")
	fmt.fprint(file, "  \"ui_gfx_implicit_draws\": ")
	print_int_map(file, draws, "  ")
	fmt.fprintln(file)
	fmt.fprintln(file, "}")
}

@(private = "file")
gfx_print_package_globals :: proc(file: ^os.File, sources: []Source) {
	paths := make([dynamic]string, context.temp_allocator)
	by_path := make(map[string][]Gfx_Global_Decl, context.temp_allocator)
	for &source in sources {
		if has_any_prefix(source.rel_path, GFX_PASCAL_EXCLUDED_PREFIXES[:]) do continue
		decls := gfx_package_global_declarations(&source, context.temp_allocator)
		if len(decls) == 0 do continue
		append(&paths, source.rel_path)
		by_path[source.rel_path] = decls
	}
	slice.sort(paths[:])
	if len(paths) == 0 {
		fmt.fprint(file, "{}")
		return
	}
	fmt.fprintln(file, "{")
	for path, index in paths {
		fmt.fprintfln(file, "    %s: [", json_quote(path, context.temp_allocator))
		decls := by_path[path]
		for decl, decl_index in decls {
			comma := decl_index + 1 < len(decls) ? "," : ""
			fmt.fprintfln(file, "      %s%s", json_quote(decl.name, context.temp_allocator), comma)
		}
		fmt.fprintfln(file, "    ]%s", index + 1 < len(paths) ? "," : "")
	}
	fmt.fprint(file, "  }")
}

run_gfx_context :: proc(options: ^Options) -> int {
	assert(options != nil, "run_gfx_context: nil options")
	vendor := options.raylib_vendor
	if vendor == "" {
		joined, err := filepath.join({ODIN_ROOT, "vendor", "raylib"})
		if err != nil do return EXIT_USAGE
		vendor = joined
	}
	raylib, raylib_ok := gfx_raylib_names(vendor)
	if !raylib_ok do return EXIT_USAGE
	report: Report
	gfx_files := filter_paths(options.files, {"gfx/"}, nil, GFX_EXCLUDED_SUFFIXES[:])
	ui_gfx_files := filter_paths(options.files, {"ui_gfx/"}, nil, GFX_EXCLUDED_SUFFIXES[:])
	gfx_sources := load_sources(options.root, gfx_files, &report)
	ui_gfx_sources := load_sources(options.root, ui_gfx_files, &report)
	globals, active, escapes, draws: map[string]int
	for &source in gfx_sources {
		gfx_counts_for_source(&source, .Direct_Global, &globals)
		gfx_counts_for_source(&source, .Active_Context, &active)
		gfx_default_context_debt_for_source(&source, &escapes)
	}
	for &source in ui_gfx_sources {
		gfx_counts_for_source(&source, .Active_Context, &active)
		gfx_default_context_debt_for_source(&source, &escapes)
		gfx_counts_for_source(&source, .Implicit_Draw, &draws)
	}
	if options.measure {
		gfx_print_measure(os.stdout, active, escapes, globals, draws, gfx_sources)
		return EXIT_OK
	}
	gfx_zero_debt_failures(
		"direct gfx global routing",
		gfx_controlled_global_debt(globals),
		&report,
	)
	gfx_zero_debt_failures("active-context API", active, &report)
	gfx_zero_debt_failures("internal default-context escape", escapes, &report)
	gfx_zero_debt_failures("ui_gfx implicit graphics routing", draws, &report)
	for &source in gfx_sources {
		if has_any_prefix(source.rel_path, GFX_PASCAL_EXCLUDED_PREFIXES[:]) do continue
		gfx_pascal_case_violations(&source, raylib, &report)
	}
	gfx_package_global_failures(gfx_sources, GFX_ALLOWED_PACKAGE_GLOBALS[:], &report)
	assert(len(gfx_sources) <= len(gfx_files), "run_gfx_context: more sources than files")
	return report_emit(&report, os.stdout)
}
