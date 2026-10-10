package odingate

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

// Port of scripts/check_odin_style.py: physical-line and procedure length
// limits, direct recursion, loops without a structural bound, and `assert`
// conditions that call procedures not known to be pure. Message strings are
// kept verbatim.

STYLE_LINE_LIMIT :: 100
STYLE_PROCEDURE_LIMIT :: 100

// Foreign bindings and platform shims mirror upstream declarations whose
// lines cannot be wrapped; they are excluded from the style scan.
STYLE_EXCLUDED_PREFIXES := [?]string {
	"accesskit/",
	"artifacts/",
	"libvterm/",
	"gfx/rlgl",
	"gfx/platform_web.odin",
	"net/curl_ffi.odin",
	"net/http_web.odin",
	"pty/pty_windows.odin",
	"ui/spell_windows.odin",
	"ui/window_style_windows.odin",
}

// `assert` and `assert_contextless` are @(disabled=ODIN_DISABLE_ASSERT): under
// -disable-assert the compiler drops the whole call, including its arguments.
// A condition that does work silently stops doing it, so conditions may only
// call procedures known to be pure. `ensure` is never disabled.
STYLE_PURE_BUILTINS := [?]string {
	"abs",
	"align_of",
	"auto_cast",
	"cap",
	"card",
	"cast",
	"clamp",
	"imag",
	"len",
	"max",
	"min",
	"offset_of",
	"raw_data",
	"real",
	"size_of",
	"transmute",
	"type_info_of",
	"type_of",
	"typeid_of",
	"c_int",
	"c_long",
	"c_uint",
}

// Pure queries defined outside the scanned tree (core:/base:), where no marker
// can be written. A procedure declared in this tree declares its purity with a
// `// tigerstyle: pure` marker instead; listing it here is reported.
STYLE_EXTERNAL_PURE_NAMES := [?]string {
	"atomic_load",
	"atomic_load_explicit",
	"builder_len",
	"has_prefix",
	"has_suffix",
	"memory",
	"to_string",
}

STYLE_PURE_SUFFIXES := [?]string {
	"_valid",
	"_finite",
	"_settled",
	"_fits",
	"_matches",
	"_active",
	"_ready",
	"_balanced",
	"_open",
	"_kind",
	"_count",
	"_capacity",
	"_size",
	"_format",
	"_phase",
	"_epoch",
	"_in_flight",
	"_available",
	"_focused",
	"_nodes",
	"_is_ancestor",
	"_child_count",
	"_schema",
	"_length",
	"_contains",
	"_equal",
	"_equals",
}

STYLE_MUTATORS := [?]string {
	"append",
	"append_elem",
	"append_elems",
	"inject_at",
	"delete",
	"free",
	"free_all",
	"new",
	"make",
	"clear",
	"resize",
	"reserve",
	"pop",
	"pop_front",
	"ordered_remove",
	"unordered_remove",
	"atomic_store",
	"atomic_store_explicit",
	"atomic_add",
	"atomic_sub",
	"atomic_exchange",
}

// Purity is declared where the procedure is written, not in a central list.
// The index collects marked procedure names and type names across every
// scanned file so a marker in one file is honoured in another.
Purity_Index :: struct {
	pure_names: map[string]bool,
	type_names: map[string]bool,
}

run_style :: proc(options: ^Options) -> int {
	assert(options != nil, "run_style: nil options")
	files := filter_paths(options.files, nil, STYLE_EXCLUDED_PREFIXES[:], nil)
	report: Report
	sources := load_sources(options.root, files, &report)
	baseline: Int_Baseline
	if options.baseline != "" {
		loaded, ok := baseline_load_ints(options.baseline)
		if !ok do return EXIT_USAGE
		baseline = loaded
	}
	index := style_build_purity_index(sources)
	for &source in sources {
		if options.print_procedures {
			style_print_procedures(&source)
			continue
		}
		style_check_source(&source, baseline, &index, &report)
	}
	assert(len(sources) <= len(files), "run_style: more sources than files")
	return report_emit(&report, os.stdout)
}

style_build_purity_index :: proc(sources: []Source) -> Purity_Index {
	index: Purity_Index
	for &source in sources {
		style_purity_scan(&source, &index, nil)
	}
	return index
}

style_print_procedures :: proc(source: ^Source) {
	assert(source != nil, "style_print_procedures: nil source")
	for entry in top_level_procs(source.file, context.temp_allocator) {
		lines := entry.end_line - entry.start_line + 1
		if lines > STYLE_PROCEDURE_LIMIT {
			fmt.printfln("\t\"%s:%s\": %d,", source.rel_path, entry.name, lines)
		}
	}
}

// style_check_source runs every style rule on one file. `index` may be nil,
// in which case the file's own declarations form the purity index (the
// single-file test path).
style_check_source :: proc(
	source: ^Source,
	baseline: Int_Baseline,
	index: ^Purity_Index,
	report: ^Report,
) {
	assert(source != nil, "style_check_source: nil source")
	assert(report != nil, "style_check_source: nil report")
	local_index: Purity_Index
	effective := index
	if effective == nil {
		style_purity_scan(source, &local_index, nil)
		effective = &local_index
	}
	style_purity_scan(source, nil, report)
	style_check_lines(source, report)
	for entry in top_level_procs(source.file, context.temp_allocator) {
		style_check_procedure(source, entry, baseline, report)
	}
	style_check_asserts(source, effective, report)
}

@(private = "file")
style_check_lines :: proc(source: ^Source, report: ^Report) {
	for line, index in source.lines {
		count := utf8.rune_count_in_string(line)
		if count > STYLE_LINE_LIMIT {
			report_addf(
				report,
				source.rel_path,
				index + 1,
				"line has %d characters; limit is %d",
				count,
				STYLE_LINE_LIMIT,
			)
		}
	}
}

@(private = "file")
style_check_procedure :: proc(
	source: ^Source,
	entry: Proc_Decl,
	baseline: Int_Baseline,
	report: ^Report,
) {
	assert(entry.lit != nil && entry.lit.body != nil, "style_check_procedure: bodiless proc")
	lines := entry.end_line - entry.start_line + 1
	key := source.rel_path != "" ? fmt.tprintf("%s:%s", source.rel_path, entry.name) : entry.name
	allowed := baseline[key] or_else STYLE_PROCEDURE_LIMIT
	if lines > allowed {
		report_addf(
			report,
			source.rel_path,
			entry.start_line,
			"procedure %s has %d lines; limit is %d",
			entry.name,
			lines,
			allowed,
		)
	}
	scan := body_scan(entry.lit.body, context.temp_allocator)
	for call in scan.calls {
		qualifier, name := callee_name(call)
		if qualifier != "" || name != entry.name do continue
		if _, is_ident := call.expr.derived_expr.(^ast.Ident); !is_ident do continue
		if call.pos.line == entry.start_line do continue
		report_addf(
			report,
			source.rel_path,
			call.pos.line,
			"direct recursion: procedure %s calls itself",
			entry.name,
		)
	}
	for loop in scan.loops {
		if style_loop_bounded(loop) do continue
		line := style_loop_line(loop)
		kind, rationale, ok := line_directive(source, preceding_nonblank_line(source.lines, line))
		if ok && kind == "allow-unbounded-loop" && rationale != "" do continue
		report_add(report, source.rel_path, line, "loop has no structurally provable upper bound")
	}
	for line in entry.start_line ..= entry.end_line {
		kind, rationale, ok := line_directive(source, line)
		if ok && kind == "allow-unbounded-loop" && rationale == "" {
			report_add(report, source.rel_path, line, "unbounded-loop waiver requires a rationale")
		}
	}
}

// style_loop_bounded mirrors loop_header_bounded(): `in` loops are bounded;
// a three-part loop needs a comparison and an assignment update (or len/cap
// in the condition when there is no update); a condition-only loop needs an
// ordering comparison or a time-like identifier.
style_loop_bounded :: proc(node: ^ast.Node) -> bool {
	assert(node != nil, "style_loop_bounded: nil node")
	#partial switch loop in node.derived {
	case ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
		return true
	case ^ast.For_Stmt:
		if loop.cond == nil do return false
		facts := expr_facts(loop.cond)
		if loop.init != nil || loop.post != nil {
			if loop.post == nil do return facts.has_len_or_cap
			_, is_assign := loop.post.derived_stmt.(^ast.Assign_Stmt)
			return facts.has_comparison && is_assign
		}
		return facts.has_ordering || facts.has_time_ident
	}
	return false
}

@(private = "file")
style_loop_line :: proc(node: ^ast.Node) -> int {
	#partial switch loop in node.derived {
	case ^ast.For_Stmt:
		return loop.for_pos.line
	case ^ast.Range_Stmt:
		return loop.for_pos.line
	case ^ast.Unroll_Range_Stmt:
		return loop.for_pos.line
	}
	return node.pos.line
}

// style_check_asserts walks every declaration (not only procedures) so an
// assert inside a procedure literal stored in a table is still checked.
@(private = "file")
style_check_asserts :: proc(source: ^Source, index: ^Purity_Index, report: ^Report) {
	assert(index != nil, "style_check_asserts: nil index")
	for decl in source.file.decls {
		scan := body_scan(decl, context.temp_allocator)
		for call in scan.calls {
			qualifier, name := callee_name(call)
			if qualifier != "" || (name != "assert" && name != "assert_contextless") do continue
			if _, is_ident := call.expr.derived_expr.(^ast.Ident); !is_ident do continue
			if len(call.args) == 0 do continue
			impure, found := style_first_impure_call(call.args[0], index)
			if !found do continue
			kind, rationale, ok := line_directive(
				source,
				preceding_nonblank_line(source.lines, call.pos.line),
			)
			if ok && kind == "allow-assert-call" && rationale != "" do continue
			report_addf(
				report,
				source.rel_path,
				call.pos.line,
				"assert condition calls '%s'; -disable-assert elides it. Hoist the call into a local",
				expr_source(source, impure.expr),
			)
		}
	}
}

@(private = "file")
style_first_impure_call :: proc(
	condition: ^ast.Expr,
	index: ^Purity_Index,
) -> (
	call: ^ast.Call_Expr,
	found: bool,
) {
	scan := body_scan(condition, context.temp_allocator)
	for candidate in scan.calls {
		name := leaf_ident(candidate.expr)
		if name == "" do continue
		if !style_name_is_pure(name, index) do return candidate, true
	}
	return nil, false
}

style_name_is_pure :: proc(name: string, index: ^Purity_Index) -> bool {
	assert(name != "", "style_name_is_pure: empty name")
	if is_basic_type_name(name) do return true
	for candidate in STYLE_PURE_BUILTINS do if name == candidate do return true
	for candidate in STYLE_EXTERNAL_PURE_NAMES do if name == candidate do return true
	if index != nil && (name in index.pure_names || name in index.type_names) do return true
	for prefix in ([?]string{"is_", "has_", "can_"}) {
		if strings.has_prefix(name, prefix) do return true
		if strings.contains(name, strings.concatenate({"_", prefix}, context.temp_allocator)) {
			return true
		}
	}
	if strings.has_prefix(name, "prepared_") && style_lower_ident(name[len("prepared_"):]) {
		return true
	}
	if strings.has_prefix(name, "terrain_recipe_validate_v") {
		digits := name[len("terrain_recipe_validate_v"):]
		if len(digits) > 0 && strings.trim_left(digits, "0123456789") == "" do return true
	}
	if strings.has_suffix(name, "_IsValid") do return true
	return has_any_suffix(name, STYLE_PURE_SUFFIXES[:])
}

@(private = "file")
style_lower_ident :: proc(text: string) -> bool {
	if len(text) == 0 do return false
	for char in text {
		if char != '_' && (char < 'a' || char > 'z') do return false
	}
	return true
}

// style_purity_scan records type names and pure-marked procedures into
// `index` (when non-nil) and reports dangling markers, in-tree declarations
// of external pure names, and mutation inside pure-marked bodies (when
// `report` is non-nil).
style_purity_scan :: proc(source: ^Source, index: ^Purity_Index, report: ^Report) {
	assert(source != nil, "style_purity_scan: nil source")
	proc_lines := make(map[int]string, context.temp_allocator)
	for decl in top_level_value_decls(source.file, context.temp_allocator) {
		if decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 do continue
		ident, is_ident := decl.names[0].derived_expr.(^ast.Ident)
		if !is_ident do continue
		value := decl.values[0]
		if is_type_expr(value) && index != nil do index.type_names[ident.name] = true
		is_proc := false
		#partial switch node in value.derived_expr {
		case ^ast.Proc_Lit, ^ast.Proc_Type:
			is_proc = true
		}
		if !is_proc do continue
		proc_lines[decl.pos.line] = ident.name
		if report != nil && style_is_external_pure_name(ident.name) {
			report_addf(
				report,
				source.rel_path,
				decl.pos.line,
				"%s is declared here; declare purity with a `// tigerstyle: pure` marker " +
				"instead of EXTERNAL_PURE_NAMES",
				ident.name,
			)
		}
	}
	marked := make(map[int]string, context.temp_allocator)
	for line_text, offset in source.lines {
		if !style_is_pure_marker(line_text) do continue
		following := style_next_declaration_line(source.lines, offset + 2)
		name, declared := proc_lines[following]
		if !declared {
			if report != nil {
				report_add(
					report,
					source.rel_path,
					offset + 1,
					"dangling pure marker: no procedure declaration follows",
				)
			}
			continue
		}
		if index != nil do index.pure_names[name] = true
		marked[following] = name
	}
	if report == nil do return
	for entry in top_level_procs(source.file, context.temp_allocator) {
		if marked[entry.decl.pos.line] != entry.name do continue
		style_check_pure_body(source, entry, report)
	}
}

@(private = "file")
style_is_external_pure_name :: proc(name: string) -> bool {
	for candidate in STYLE_EXTERNAL_PURE_NAMES do if name == candidate do return true
	return false
}

// style_is_pure_marker accepts `// tigerstyle: pure` with arbitrary spacing
// and nothing after `pure`, matching the Python PURE_MARKER pattern.
@(private = "file")
style_is_pure_marker :: proc(line: string) -> bool {
	text := strings.trim_space(line)
	if !strings.has_prefix(text, "//") do return false
	text = strings.trim_space(text[2:])
	if !strings.has_prefix(text, "tigerstyle:") do return false
	return strings.trim_space(text[len("tigerstyle:"):]) == "pure"
}

// style_next_declaration_line returns the first line at or after `start`
// (1-based) that is neither blank nor an attribute line, or 0.
@(private = "file")
style_next_declaration_line :: proc(lines: []string, start: int) -> int {
	for line := max(start, 1); line <= len(lines); line += 1 {
		text := strings.trim_space(lines[line - 1])
		if text == "" || strings.has_prefix(text, "@(") do continue
		return line
	}
	return 0
}

@(private = "file")
style_check_pure_body :: proc(source: ^Source, entry: Proc_Decl, report: ^Report) {
	assert(entry.lit != nil && entry.lit.body != nil, "style_check_pure_body: bodiless proc")
	params := param_names(entry.lit, context.temp_allocator)
	scan := body_scan(entry.lit.body, context.temp_allocator)
	for call in scan.calls {
		name := leaf_ident(call.expr)
		if name == "" || !style_is_mutator(name) do continue
		report_addf(
			report,
			source.rel_path,
			call.pos.line,
			"pure-marked proc %s mutates state: calls %s",
			entry.name,
			name,
		)
	}
	for assign in scan.assigns {
		for target in assign.lhs {
			if _, bare := target.derived_expr.(^ast.Ident); bare do continue
			root := root_ident(target)
			if root == "" || !style_name_in(root, params) do continue
			report_addf(
				report,
				source.rel_path,
				assign.pos.line,
				"pure-marked proc %s mutates state: writes through parameter %s",
				entry.name,
				root,
			)
		}
	}
}

@(private = "file")
style_is_mutator :: proc(name: string) -> bool {
	for candidate in STYLE_MUTATORS do if name == candidate do return true
	return strings.has_prefix(name, "atomic_compare_exchange")
}

@(private = "file")
style_name_in :: proc(name: string, names: []string) -> bool {
	for candidate in names do if name == candidate do return true
	return false
}
