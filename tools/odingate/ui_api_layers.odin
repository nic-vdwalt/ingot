package odingate

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// Port of scripts/check_ui_api_layers.py: `ingot:fit` is the public UI entry
// point, `ingot:ui`/`ingot:ui_gfx` are advanced layers. Examples must import
// fit as `fit` and never alias it as an internal package; fit's public
// declarations may not expose ui types except through the reviewed aliases;
// ui facade names follow the bare-name / `_at` leaf conventions; and
// consumer trees may not call the adapter lifecycle, legacy session, retired
// UI, retired graphics, or raw binding imports. Messages are verbatim.

UI_LAYERS_DELETED_NAMES := [?]string {
	"btn",
	"btn_at",
	"input_at",
	"ui_begin",
	"ui_begin_frame",
	"ui_end",
	"ui_focus",
	"ui_id",
	"ui_padding",
	"ui_slot",
}
UI_LAYERS_FORBIDDEN_FACADE_SUFFIXES := [?]string{"_ui", "_ui_id", "_auto"}
UI_LAYERS_RUNTIME_PREFIXES := [?]string{"ui_runtime_", "ui_frame_", "ui_output_", "ui_metrics"}
UI_LAYERS_EXPLICIT_LEAVES := [?]string {
	"back_btn_at",
	"bar_chart_at",
	"button_at",
	"button_at_state",
	"button_with_options_at",
	"card_bg_at",
	"checkbox_at",
	"collapsible_header_at",
	"dropdown_at",
	"icon_btn_at",
	"kv_row_at",
	"line_chart_at",
	"list_row_bg_at",
	"progress_bar_animated_at",
	"progress_bar_at",
	"radio_at",
	"section_header_at",
	"slider_at",
	"slider_at_state",
	"sparkline_at",
	"spinner_at",
	"status_pill_at",
	"text_input_at",
	"text_input_with_options_at",
	"tooltip_at",
}
UI_LAYERS_EXPLICIT_PROTOCOLS := [?]string {
	"context_menu",
	"listbox_begin",
	"modal_begin",
	"pane_begin",
	"pane_end",
	"selectable_row",
}
UI_LAYERS_ADAPTER_LIFECYCLE := [?]string {
	"adapter_attach_runtime",
	"adapter_begin_frame",
	"adapter_bind_frame",
	"adapter_destroy",
	"adapter_end_frame",
	"adapter_init",
	"adapter_init_context",
	"adapter_open_frame",
	"adapter_prepare_frame",
}
UI_LAYERS_EXAMPLE_INTERNAL_NAMES := [?]string {
	"Ui",
	"Ui_Frame",
	"Ui_Input",
	"Ui_Output",
	"Ui_Runtime",
	"Surface_Frame",
	"Host_App",
	"Host_Session",
}
UI_LAYERS_FIT_INTERNAL_NAMES := [?]string {
	"Adapter",
	"Ui",
	"Ui_Frame",
	"Ui_Input",
	"Ui_Output",
	"Ui_Runtime",
	"Host_App",
	"Host_Session",
	"Session_Frame",
}
UI_LAYERS_FIT_SPLIT_SESSION := [?]string {
	"Session_Begin",
	"Session_End",
	"session_begin",
	"session_end",
	"session_acquire_frame",
	"session_present_frame",
}
UI_LAYERS_RETIRED_UI := [?]string{"Fit_Node", "Fit_Prepared", "fit_tree", "fit_nodes"}
// frame_draw_* is the owner-bound Frame layer (docs/compatibility.md), not a
// retired name: ui_gfx and multi-context hosts draw through it.
UI_LAYERS_RETIRED_GFX := [?]string {
	"begin_frame",
	"context_begin_frame",
	"end_frame",
	"clear_frame",
	"draw_rect",
	"draw_circle",
}
UI_LAYERS_BINDING_PACKAGES := [?]string{"libvterm", "pty", "accesskit"}

// --- ui facade declarations -----------------------------------------------

Ui_Layers_Declaration :: struct {
	name:       string,
	line:       int,
	parameters: string, // raw text inside the parameter parentheses
	private:    bool,
	overload:   bool,
	body:       string, // raw text inside the overload braces
}

// ui_layers_declarations lists `lower_name :: proc(...)` procedures and
// `lower_name :: proc{...}` overload groups at file scope, with the raw text
// the Python regexes inspected: parameters for procedures, the brace body for
// groups. Privacy comes from an `@(private...)` attribute.
ui_layers_declarations :: proc(
	source: ^Source,
	allocator := context.allocator,
) -> []Ui_Layers_Declaration {
	assert(source != nil, "ui_layers_declarations: nil source")
	result := make([dynamic]Ui_Layers_Declaration, allocator)
	for decl in top_level_value_decls(source.file, context.temp_allocator) {
		if decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 do continue
		ident, is_ident := decl.names[0].derived_expr.(^ast.Ident)
		if !is_ident || !ui_layers_is_lower_ident(ident.name) do continue
		if ident.pos.column != 1 do continue
		is_private, _ := attribute_privacy(decl.attributes[:])
		entry := Ui_Layers_Declaration {
			name    = ident.name,
			line    = ident.pos.line,
			private = is_private,
		}
		#partial switch value in decl.values[0].derived_expr {
		case ^ast.Proc_Lit:
			if value.type == nil || value.type.params == nil do continue
			entry.parameters = ui_layers_inner_text(
				source,
				value.type.params.pos.offset,
				value.type.params.end.offset,
			)
		case ^ast.Proc_Type:
			if value.params == nil do continue
			entry.parameters = ui_layers_inner_text(
				source,
				value.params.pos.offset,
				value.params.end.offset,
			)
		case ^ast.Proc_Group:
			entry.overload = true
			entry.body = ui_layers_inner_text(source, value.open.offset + 1, value.close.offset)
		case:
			continue
		}
		append(&result, entry)
	}
	return result[:]
}

// ui_layers_inner_text returns source text for [open, close). Field_List
// spans start at the first token after `(` and end at `)`; Proc_Group spans
// are recorded at the braces, so the caller passes the offsets accordingly.
@(private = "file")
ui_layers_inner_text :: proc(source: ^Source, open, close: int) -> string {
	start := clamp(open, 0, len(source.text))
	end := clamp(close, start, len(source.text))
	return source.text[start:end]
}

@(private = "file")
ui_layers_is_lower_ident :: proc(name: string) -> bool {
	if name == "" do return false
	first := name[0]
	if !(first == '_' || (first >= 'a' && first <= 'z')) do return false
	for char in name[1:] {
		if !(char == '_' || (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9')) do return false
	}
	return true
}

// ui_layers_has_loose_rect mirrors _has_loose_rect(): `x, y, w, h: i32` as
// a group, or all four names present as separate parameters.
ui_layers_has_loose_rect :: proc(parameters: string) -> bool {
	compact, _ := strings.remove_all(strip_spaces(parameters), "\n", context.temp_allocator)
	if ui_layers_group_present(compact, "x,y,w,h:i32") do return true
	for name in ([?]string{"x", "y", "w", "h"}) {
		if !ui_layers_param_present(compact, name) do return false
	}
	return true
}

@(private = "file")
ui_layers_group_present :: proc(compact, group: string) -> bool {
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		rel := strings.index(compact[from:], group)
		if rel < 0 do return false
		at := from + rel
		from = at + 1
		before_ok := at == 0 || compact[at - 1] == ','
		after := at + len(group)
		after_ok := after == len(compact) || compact[after] == ','
		if before_ok && after_ok do return true
	}
	return false
}

@(private = "file")
ui_layers_param_present :: proc(compact, name: string) -> bool {
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		rel := strings.index(compact[from:], name)
		if rel < 0 do return false
		at := from + rel
		from = at + 1
		before_ok := at == 0 || compact[at - 1] == ','
		after := at + len(name)
		after_ok := after < len(compact) && (compact[after] == ',' || compact[after] == ':')
		if before_ok && after_ok do return true
	}
	return false
}

// ui_layers_rect_count counts `Rect_I32` parameters not preceded by `^`.
ui_layers_rect_count :: proc(parameters: string) -> int {
	count := 0
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_word(parameters, "Rect_I32", from)
		if at < 0 do break
		from = at + len("Rect_I32")
		if at > 0 && parameters[at - 1] == '^' do continue
		count += 1
	}
	return count
}

// ui_layers_violations applies the ui facade naming rules to one source.
ui_layers_violations :: proc(source: ^Source, report: ^Report) {
	assert(source != nil && report != nil, "ui_layers_violations: nil argument")
	for decl in ui_layers_declarations(source, context.temp_allocator) {
		if decl.private do continue
		name := decl.name
		params := decl.parameters
		if slice.contains(UI_LAYERS_DELETED_NAMES[:], name) {
			report_addf(report, source.rel_path, decl.line, "deleted UI API name: %s", name)
		}
		runtime_prefixed := has_any_prefix(name, UI_LAYERS_RUNTIME_PREFIXES[:])
		if strings.contains(params, "^Ui") && !strings.contains(params, "^Ui_Frame") {
			if strings.has_prefix(name, "ui_") && !runtime_prefixed {
				report_addf(
					report,
					source.rel_path,
					decl.line,
					"facade procedure must use a bare name: %s",
					name,
				)
			}
			if has_any_suffix(name, UI_LAYERS_FORBIDDEN_FACADE_SUFFIXES[:]) {
				report_addf(
					report,
					source.rel_path,
					decl.line,
					"forbidden facade suffix: %s",
					name,
				)
			}
		}
		if strings.has_prefix(name, "ui_") && !runtime_prefixed {
			report_addf(report, source.rel_path, decl.line, "reserved ui_ prefix: %s", name)
		}
		if slice.contains(UI_LAYERS_EXPLICIT_LEAVES[:], name) {
			if !strings.has_suffix(name, "_at") && !strings.has_suffix(name, "_at_state") {
				report_addf(
					report,
					source.rel_path,
					decl.line,
					"explicit leaf must end in _at: %s",
					name,
				)
			}
			if ui_layers_rect_count(params) != 1 {
				report_addf(
					report,
					source.rel_path,
					decl.line,
					"explicit leaf needs one Rect_I32: %s",
					name,
				)
			}
			if ui_layers_has_loose_rect(params) {
				report_addf(
					report,
					source.rel_path,
					decl.line,
					"explicit leaf uses loose x/y/w/h: %s",
					name,
				)
			}
		}
		if slice.contains(UI_LAYERS_EXPLICIT_PROTOCOLS[:], name) &&
		   ui_layers_has_loose_rect(params) {
			report_addf(
				report,
				source.rel_path,
				decl.line,
				"explicit protocol uses loose x/y/w/h: %s",
				name,
			)
		}
		if decl.overload && strings.contains(decl.body, "@(deprecated") {
			report_addf(
				report,
				source.rel_path,
				decl.line,
				"overload set contains deprecated member: %s",
				name,
			)
		}
	}
}

// --- fit public surface ---------------------------------------------------

// ui_layers_fit_public_violations scans fit's masked lines the way the
// Python did: a declaration line (`Name ::`) that is not preceded by an
// `@(private` attribute may not mention `ui.`/`ui_gfx.` or an internal UI
// type name unless it is one of the reviewed aliases.
ui_layers_fit_public_violations :: proc(source: ^Source, report: ^Report) {
	assert(source != nil && report != nil, "ui_layers_fit_public_violations: nil argument")
	masked_lines := split_source_lines(source.masked, context.temp_allocator)
	private_next := false
	for line, index in masked_lines {
		stripped := strings.trim_space(line)
		if strings.has_prefix(stripped, "@(private") {
			private_next = true
			continue
		}
		if stripped == "" ||
		   strings.has_prefix(stripped, "package ") ||
		   strings.has_prefix(stripped, "import ") {
			continue
		}
		_, is_declaration := ui_layers_declaration_head(stripped)
		opaque := strings.has_prefix(stripped, "Storage_Node :: distinct ui.Prepared_Node")
		allowed := slice.contains(UI_LAYERS_FIT_PUBLIC_ALIAS_ALLOW[:], stripped)
		if is_declaration && !private_next {
			if ui_layers_mentions_fit_internal(stripped) && !opaque && !allowed {
				report_add(
					report,
					source.rel_path,
					index + 1,
					"Fit public declaration exposes internal UI type",
				)
			}
			if has_any_word(stripped, UI_LAYERS_FIT_SPLIT_SESSION[:]) {
				report_add(
					report,
					source.rel_path,
					index + 1,
					"Fit public declaration exposes split session lifecycle",
				)
			}
		}
		if strings.has_suffix(stripped, "}") || strings.contains(stripped, "::") do private_next = false
	}
}

@(private = "file")
ui_layers_declaration_head :: proc(stripped: string) -> (name: string, ok: bool) {
	end := 0
	for end < len(stripped) && is_word_byte(stripped[end]) do end += 1
	if end == 0 || is_digit_byte(stripped[0]) do return
	after := skip_spaces(stripped, end)
	if !strings.has_prefix(stripped[after:], "::") do return
	return stripped[:end], true
}

@(private = "file")
ui_layers_mentions_fit_internal :: proc(text: string) -> bool {
	if seq_in(text, {"ui", "~=."}) || seq_in(text, {"ui_gfx", "~=."}) do return true
	return has_any_word(text, UI_LAYERS_FIT_INTERNAL_NAMES[:])
}

// --- examples and consumers -----------------------------------------------

// Ui_Layers_Match is one regex hit: the matched text and its line.
Ui_Layers_Match :: struct {
	text: string,
	line: int,
}

// ui_layers_import_matches finds `import <alias> "ingot:fit"` declarations
// whose alias satisfies `accept`.
@(private = "file")
ui_layers_fit_import_aliases :: proc(
	source: ^Source,
	allocator := context.allocator,
) -> []Ui_Layers_Match {
	matches := make([dynamic]Ui_Layers_Match, allocator)
	for decl in source.file.imports {
		if decl.relpath.text != "\"ingot:fit\"" || decl.name.text == "" do continue
		if decl.import_tok.pos.column != 1 &&
		   !ui_layers_line_starts_with_import(source, decl.import_tok.pos.line) {
			continue
		}
		end := decl.relpath.pos.offset + len(decl.relpath.text)
		append(
			&matches,
			Ui_Layers_Match{source.text[decl.import_tok.pos.offset:end], decl.import_tok.pos.line},
		)
	}
	return matches[:]
}

@(private = "file")
ui_layers_line_starts_with_import :: proc(source: ^Source, line: int) -> bool {
	if line < 1 || line > len(source.lines) do return false
	return strings.has_prefix(strings.trim_left_space(source.lines[line - 1]), "import")
}

@(private = "file")
ui_layers_import_alias :: proc(match_text: string) -> string {
	fields := strings.fields(match_text, context.temp_allocator)
	if len(fields) != 3 do return ""
	return fields[1]
}

// ui_layers_word_matches finds every word-bounded occurrence of any name in
// `names` within `text`, in source order, with 1-based lines.
ui_layers_word_matches :: proc(
	text: string,
	names: []string,
	allocator := context.allocator,
) -> []Ui_Layers_Match {
	matches := make([dynamic]Ui_Layers_Match, allocator)
	for index in 0 ..< len(text) {
		if !is_word_byte(text[index]) || (index > 0 && is_word_byte(text[index - 1])) do continue
		end := index
		for end < len(text) && is_word_byte(text[end]) do end += 1
		word := text[index:end]
		if slice.contains(names, word) {
			append(&matches, Ui_Layers_Match{word, strings.count(text[:index], "\n") + 1})
		}
	}
	return matches[:]
}

// ui_layers_call_matches finds `name(` with word boundaries for any name.
ui_layers_call_matches :: proc(
	text: string,
	names: []string,
	allocator := context.allocator,
) -> []Ui_Layers_Match {
	matches := make([dynamic]Ui_Layers_Match, allocator)
	for index in 0 ..< len(text) {
		if !is_word_byte(text[index]) || (index > 0 && is_word_byte(text[index - 1])) do continue
		end := index
		for end < len(text) && is_word_byte(text[end]) do end += 1
		next := skip_spaces(text, end)
		if next >= len(text) || text[next] != '(' do continue
		word := text[index:end]
		if slice.contains(names, word) {
			append(
				&matches,
				Ui_Layers_Match{text[index:next + 1], strings.count(text[:index], "\n") + 1},
			)
		}
	}
	return matches[:]
}

// ui_layers_prefix_matches finds words starting with any prefix. With
// `lower_only` the remainder must be `[a-z_0-9]*` (prepared_*, app_session_*);
// otherwise any identifier characters follow (legacy_*).
ui_layers_prefix_matches :: proc(
	text: string,
	prefixes: []string,
	lower_only: bool,
	allocator := context.allocator,
) -> []Ui_Layers_Match {
	matches := make([dynamic]Ui_Layers_Match, allocator)
	for index in 0 ..< len(text) {
		if !is_word_byte(text[index]) || (index > 0 && is_word_byte(text[index - 1])) do continue
		end := index
		for end < len(text) && is_word_byte(text[end]) do end += 1
		word := text[index:end]
		for prefix in prefixes {
			if !strings.has_prefix(word, prefix) do continue
			rest := word[len(prefix):]
			lower := true
			for char in rest {
				if !(char == '_' || (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9')) {
					lower = false
				}
			}
			if lower_only && !lower do continue
			append(&matches, Ui_Layers_Match{word, strings.count(text[:index], "\n") + 1})
			break
		}
	}
	return matches[:]
}

@(private = "file")
ui_layers_merge_sorted :: proc(lists: ..[]Ui_Layers_Match) -> []Ui_Layers_Match {
	all := make([dynamic]Ui_Layers_Match, context.temp_allocator)
	for list in lists do append(&all, ..list)
	return all[:]
}

@(private = "file")
ui_layers_report_matches :: proc(
	report: ^Report,
	path: string,
	matches: []Ui_Layers_Match,
	format: string,
) {
	for match in matches do report_addf(report, path, match.line, format, match.text)
}

// ui_layers_legacy_session_matches: `App_Session`, `App_Session_Config`, and
// `app_session_<lower>` words.
@(private = "file")
ui_layers_legacy_session_matches :: proc(
	text: string,
	allocator := context.allocator,
) -> []Ui_Layers_Match {
	words := ui_layers_word_matches(text, {"App_Session", "App_Session_Config"}, allocator)
	prefixed := ui_layers_prefix_matches(text, {"app_session_"}, true, allocator)
	merged := make([dynamic]Ui_Layers_Match, allocator)
	append(&merged, ..words)
	for match in prefixed do if match.text != "app_session_" do append(&merged, match)
	return merged[:]
}

// ui_layers_check_example applies the example rules to one examples/ file.
ui_layers_check_example :: proc(source: ^Source, report: ^Report) {
	assert(source != nil && report != nil, "ui_layers_check_example: nil argument")
	for match in ui_layers_fit_import_aliases(source, context.temp_allocator) {
		alias := ui_layers_import_alias(match.text)
		if alias == "ui" || alias == "ui_gfx" {
			report_addf(
				report,
				source.rel_path,
				match.line,
				"Fit imported as internal UI alias %s",
				match.text,
			)
		}
		if alias != "fit" {
			report_addf(
				report,
				source.rel_path,
				match.line,
				"example must import ingot:fit as fit: %s",
				match.text,
			)
		}
	}
	if !strings.contains(source.text, "\"ingot:fit\"") do return
	names := ui_layers_word_matches(
		source.masked,
		UI_LAYERS_EXAMPLE_INTERNAL_NAMES[:],
		context.temp_allocator,
	)
	legacy := ui_layers_prefix_matches(source.masked, {"legacy_"}, false, context.temp_allocator)
	matches := ui_layers_merge_sorted(names, legacy)
	slice.sort_by(matches, proc(a, b: Ui_Layers_Match) -> bool {return a.line < b.line})
	ui_layers_report_matches(
		report,
		source.rel_path,
		matches,
		"example exposes compatibility UI name %s",
	)
}

// ui_layers_check_adapter_calls reports adapter lifecycle calls outside the
// two files that own the adapter.
ui_layers_check_adapter_calls :: proc(source: ^Source, report: ^Report) {
	assert(source != nil && report != nil, "ui_layers_check_adapter_calls: nil argument")
	if source.rel_path == "ui_gfx/adapter.odin" || source.rel_path == "ui_gfx/session.odin" do return
	if strings.has_suffix(source.rel_path, "_test.odin") do return
	matches := ui_layers_call_matches(
		source.masked,
		UI_LAYERS_ADAPTER_LIFECYCLE[:],
		context.temp_allocator,
	)
	ui_layers_report_matches(
		report,
		source.rel_path,
		matches,
		"backend adapter call %s; use Session",
	)
}

// ui_layers_check_consumer applies every consumer rule to one file of a
// consumer tree; `path` is relative to that tree's root.
ui_layers_check_consumer :: proc(source: ^Source, binding_allowed: bool, report: ^Report) {
	assert(source != nil && report != nil, "ui_layers_check_consumer: nil argument")
	text := source.masked
	ui_layers_report_matches(
		report,
		source.rel_path,
		ui_layers_call_matches(text, UI_LAYERS_ADAPTER_LIFECYCLE[:], context.temp_allocator),
		"backend adapter call %s; use Session",
	)
	ui_layers_report_matches(
		report,
		source.rel_path,
		ui_layers_legacy_session_matches(text, context.temp_allocator),
		"legacy session API %s; use fit.Session",
	)
	retired := ui_layers_merge_sorted(
		ui_layers_word_matches(text, UI_LAYERS_RETIRED_UI[:], context.temp_allocator),
		ui_layers_prefix_matches(text, {"prepared_"}, true, context.temp_allocator),
	)
	slice.sort_by(retired, proc(a, b: Ui_Layers_Match) -> bool {return a.line < b.line})
	ui_layers_report_matches(
		report,
		source.rel_path,
		retired,
		"retired UI API %s; use fit.Builder",
	)
	ui_layers_report_matches(
		report,
		source.rel_path,
		ui_layers_call_matches(text, UI_LAYERS_RETIRED_GFX[:], context.temp_allocator),
		"retired graphics API %s; use PascalCase gfx",
	)
	if binding_allowed do return
	for decl in source.file.imports {
		for pkg in UI_LAYERS_BINDING_PACKAGES {
			wanted := strings.concatenate({"\"ingot:", pkg, "\""}, context.temp_allocator)
			if decl.relpath.text != wanted do continue
			report_addf(
				report,
				source.rel_path,
				decl.relpath.pos.line,
				"binding import %s; use the higher-level package",
				wanted,
			)
		}
	}
}

// --- driver ---------------------------------------------------------------

Ui_Layers_Tree :: struct {
	root:  string,
	files: []string, // relative to root, slash-separated, sorted
}

// ui_layers_tree lists the `.odin` files under `root/sub`: from the gate's
// `--files-from` list when one is given, otherwise by walking the directory
// (tests build throwaway trees and pass no list).
@(private = "file")
ui_layers_tree :: proc(root, sub: string, files: []string) -> Ui_Layers_Tree {
	if files != nil do return Ui_Layers_Tree{root, ui_layers_files_under(files, sub)}
	walked, _ := collect_odin_files(root, sub)
	return Ui_Layers_Tree{root, walked[:]}
}

@(private = "file")
ui_layers_files_under :: proc(files: []string, sub: string) -> []string {
	if sub == "" do return files
	prefix := strings.concatenate({sub, "/"}, context.temp_allocator)
	return filter_paths(files, {prefix}, nil, nil)
}

@(private = "file")
ui_layers_load :: proc(
	root: string,
	rel_path: string,
	report: ^Report,
) -> (
	source: Source,
	ok: bool,
) {
	full, join_err := filepath.join({root, rel_path}, context.temp_allocator)
	if join_err != nil do return
	data, read_err := os.read_entire_file(full, context.allocator)
	if read_err != nil {
		report_addf(report, rel_path, 1, "cannot read file: %v", read_err)
		return
	}
	return parse_source(rel_path, string(data), report), true
}

// ui_layers_check_repo runs the framework-side rules under `root`: examples/,
// fit/, ui/ (non-test), and adapter calls in examples/ and ui_gfx/. `files`
// is the slash-separated tracked file list; nil walks the tree instead.
ui_layers_check_repo :: proc(root: string, report: ^Report, files: []string = nil) {
	assert(root != "" && report != nil, "ui_layers_check_repo: bad argument")
	for rel in ui_layers_tree(root, "examples", files).files {
		if source, ok := ui_layers_load(root, rel, report); ok do ui_layers_check_example(&source, report)
	}
	for rel in ui_layers_tree(root, "fit", files).files {
		if ui_layers_dir(rel) != "fit" do continue
		if source, ok := ui_layers_load(root, rel, report); ok {
			ui_layers_fit_public_violations(&source, report)
		}
	}
	for rel in ui_layers_tree(root, "ui", files).files {
		if ui_layers_dir(rel) != "ui" || strings.has_suffix(rel, "_test.odin") do continue
		if source, ok := ui_layers_load(root, rel, report); ok do ui_layers_violations(&source, report)
	}
	for sub in ([?]string{"examples", "ui_gfx"}) {
		for rel in ui_layers_tree(root, sub, files).files {
			if source, ok := ui_layers_load(root, rel, report); ok {
				ui_layers_check_adapter_calls(&source, report)
			}
		}
	}
}

// ui_layers_check_consumers runs the consumer rules over each consumer root,
// skipping anything under the ingot checkout itself.
ui_layers_check_consumers :: proc(
	consumer_roots: []string,
	binding_allow: []string,
	ingot_root: string,
	report: ^Report,
) {
	assert(report != nil, "ui_layers_check_consumers: nil report")
	for root in consumer_roots {
		for rel in ui_layers_tree(root, "", nil).files {
			full, join_err := filepath.join({root, rel}, context.temp_allocator)
			if join_err != nil do continue
			if ui_layers_path_inside(full, ingot_root) do continue
			source, ok := ui_layers_load(root, rel, report)
			if !ok do continue
			allowed := false
			for allow in binding_allow do if ui_layers_same_path(allow, full) do allowed = true
			ui_layers_check_consumer(&source, allowed, report)
		}
	}
}

ui_layers_abs :: proc(path: string, allocator := context.allocator) -> string {
	absolute, err := filepath.abs(path, allocator)
	if err != nil do return path
	return absolute
}

// ui_layers_dir returns the directory part of a slash-separated relative path.
@(private = "file")
ui_layers_dir :: proc(rel: string) -> string {
	index := strings.last_index_byte(rel, '/')
	return index < 0 ? "" : rel[:index]
}

@(private = "file")
ui_layers_same_path :: proc(a, b: string) -> bool {
	return ui_layers_abs(a, context.temp_allocator) == ui_layers_abs(b, context.temp_allocator)
}

// ui_layers_path_inside reports whether `path` is `root` or lies under it.
// Both sides are made absolute and slash-normalised so the comparison holds
// on Windows, where filepath.abs returns backslashes.
ui_layers_path_inside :: proc(path, root: string) -> bool {
	p := rel_slash(ui_layers_abs(path, context.temp_allocator), context.temp_allocator)
	r := rel_slash(ui_layers_abs(root, context.temp_allocator), context.temp_allocator)
	if p == r do return true
	prefix :=
		strings.has_suffix(r, "/") ? r : strings.concatenate({r, "/"}, context.temp_allocator)
	return strings.has_prefix(p, prefix)
}

run_ui_api_layers :: proc(options: ^Options) -> int {
	assert(options != nil, "run_ui_api_layers: nil options")
	ingot_root := ui_layers_abs(options.root)
	for allow in options.binding_allows {
		inside := false
		for root in options.consumer_roots do if ui_layers_path_inside(allow, root) do inside = true
		if !inside {
			fmt.eprintfln(
				"binding allowance is outside every consumer root: %s",
				ui_layers_abs(allow),
			)
			return EXIT_USAGE
		}
	}
	report: Report
	ui_layers_check_repo(ingot_root, &report, options.files)
	ui_layers_check_consumers(
		options.consumer_roots[:],
		options.binding_allows[:],
		ingot_root,
		&report,
	)
	ui_layers_sort_report(&report)
	for finding in report.findings do fmt.eprintln(finding_text(finding, context.temp_allocator))
	return len(report.findings) > 0 ? EXIT_FINDINGS : EXIT_OK
}

// ui_layers_sort_report keeps findings in the discovery order the Python
// produced (per directory walk, then per rule); only ties within one file
// and rule need a stable order, which append order already gives.
@(private = "file")
ui_layers_sort_report :: proc(report: ^Report) {
	assert(report != nil, "ui_layers_sort_report: nil report")
}
UI_LAYERS_FIT_PUBLIC_ALIAS_ALLOW := [?]string {
	"Action :: ui.Fit_Action",
	"Action_Proc :: ui.Fit_Action_Proc",
	"Aspect_Ratio :: ui.Aspect_Ratio",
	"Attachment_Options :: ui.Prepared_Attachment_Options",
	"Attachment_Point :: ui.Attachment_Point",
	"Attachment_Target :: ui.Attachment_Target_Kind",
	"Border :: ui.Border",
	"Button_Options :: ui.Fit_Button_Options",
	"Button_Style :: ui.Btn_Style",
	"Calendar_Date :: ui.Calendar_Date",
	"Caption_Button :: ui.Caption_Button",
	"Caret_Blink :: ui.Caret_Blink",
	"Chart_Series :: ui.Chart_Series",
	"Color :: ui.Color",
	"Combobox_Item :: ui.Combobox_Item",
	"Confirm_Choice :: ui.Confirm_Choice",
	"Constraints :: ui.Intrinsic_Constraints",
	"Container_Effects :: ui.Prepared_Container_Effects",
	"Container_Options :: ui.Prepared_Container_Options",
	"Container_Surface :: ui.Prepared_Container_Surface",
	"Control_Motion_State :: ui.Control_Motion_State",
	"Control_Options :: ui.Fit_Control_Options",
	"Cross_Align :: ui.Cross_Align",
	"Custom_Options :: ui.Fit_Custom_Options",
	"Diff_Layout :: ui.Diff_Layout",
	"Diff_Row :: ui.Diff_Row",
	"Diff_Row_Kind :: ui.Diff_Row_Kind",
	"Diff_View_Options :: ui.Diff_View_Options",
	"Diff_View_Result :: ui.Diff_View_Result",
	"Elevation :: ui.Elevation",
	"Error :: ui_gfx.App_Error",
	"Float_Rect :: ui.Rect",
	"Flow_Options :: ui.Prepared_Flow_Options",
	"Focus_Id :: ui.Focus_Id",
	"Focus_Scope_Id :: ui.Focus_Scope_Id",
	"Focus_State :: ui.Focus_State",
	"Font_Face :: ui.Font_Face",
	"Frame_Diagnostics :: ui.Ui_Frame_Diagnostics",
	"Frame_Pacing :: ui_gfx.App_Frame_Pacing",
	"Graphics_Error :: gfx.Context_Error",
	"Grid_Auto_Flow :: ui.Grid_Auto_Flow",
	"Grid_Options :: ui.Prepared_Grid_Options",
	"Icon :: ui.Icon",
	"Ink :: ui.Ink",
	"Interaction :: ui.Interaction",
	"Label_Options :: ui.Fit_Label_Options",
	"Leaf_Options :: ui.Fit_Leaf_Options",
	"Listbox_Config :: ui.Listbox_Config",
	"Listbox_Keys :: ui.Listbox_Keys",
	"Listbox_Result :: ui.Listbox_Result",
	"Main_Align :: ui.Main_Align",
	"Markdown_Prepare_Status :: ui.Markdown_Prepare_Status",
	"Menu_Item :: ui.Menu_Item",
	"Modal_Close_Reason :: ui.Modal_Close_Reason",
	"Modal_Dismiss_Policy :: ui.Modal_Dismiss_Policy",
	"Modal_Id :: ui.Modal_Id",
	"Modal_Placement :: ui.Modal_Placement",
	"POINTER_EVENT_CAP :: ui.INPUT_POINTER_EVENT_CAP",
	"Pigment :: ui.Pigment",
	"Pointer_Button :: ui.Pointer_Button",
	"Pointer_Buttons :: ui.Pointer_Buttons",
	"Pointer_Event :: ui.Pointer_Event",
	"Pointer_Event_Kind :: ui.Pointer_Event_Kind",
	"Pointer_Id :: ui.Pointer_Id",
	"Pointer_Type :: ui.Pointer_Type",
	"Popup_Close_Reason :: ui.Popup_Close_Reason",
	"Popup_Id :: ui.Popup_Id",
	"Popup_Options :: ui.Popup_Config",
	"Popup_Placement :: ui.Popup_Placement",
	"Radius :: ui.Radius",
	"Rect :: ui.Rect_I32",
	"Scroll_Axis :: ui.Scroll_Axis",
	"Selectable_Row_Config :: ui.Selectable_Row_Config",
	"Selectable_Row_Result :: ui.Selectable_Row_Result",
	"Semantic_Flag :: ui.Sem_Flag",
	"Semantic_State :: ui.Sem_State",
	"Session_Config :: ui_gfx.Session_Config",
	"Size :: ui.Intrinsic_Size",
	"Size_Options :: ui.Prepared_Size",
	"Space :: ui.Space",
	"Spinner_Style :: ui.Spinner_Style",
	"Split_Pane_Result :: ui.Split_Pane_Result",
	"State :: ui_gfx.App_State",
	"Substrate_Kind :: ui.Substrate_Kind",
	"Surface_Kind :: ui.Surface",
	"Surface_Style :: ui.Surface_Style",
	"Table_Column :: ui.Table_Column",
	"Table_Sort :: ui.Table_Sort",
	"Tagged_Action_Proc :: ui.Fit_Tagged_Action_Proc",
	"Text_Metrics :: ui.Text_Metrics",
	"Text_Role :: ui.Text_Role",
	"Text_Span :: ui.Text_Span",
	"Theme_Basis :: ui.Theme_Basis",
	"Theme_Palette :: ui.Theme_Palette",
	"Theme_Role :: ui.Theme_Role",
	"Theme_Validation :: ui.Theme_Validation",
	"Theme_Validation_Code :: ui.Theme_Validation_Code",
	"Time_Of_Day :: ui.Time_Of_Day",
	"Tint :: ui.Tint",
	"Track :: ui.Track",
	"Track_Kind :: ui.Track_Kind",
	"Transition :: ui.Prepared_Transition",
	"Transition_Options :: ui.Transition_Options",
	"Transition_State :: ui.Transition_Rect_State",
	"Truncate_Side :: ui.Truncate_Side",
	"Variable_List_Window :: ui.Variable_List_Window",
	"Virtual_List_Window :: ui.Virtual_List_Window",
	"Visual_State :: ui.Visual_State",
	"Widget_Id :: ui.Widget_Id",
	"Z_Order :: ui.Z_Order",
}
