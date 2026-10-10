package odingate

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strings"

// Port of scripts/check_assertions.py: every authored procedure with
// pointer, index, queue, ownership, state, or untrusted-input risk must carry
// evidence (an assert, ensure, guard, or structural bound) that discharges
// each risk. Risk detection and evidence run over the masked procedure text
// exactly as the Python guard did, so the two agree finding-for-finding.

ASSERT_PACKAGES := [?]string {
	"examples/box3d_workers/",
	"gfx/",
	"ui/",
	"ui_gfx/",
	"view/",
	"term/",
	"prefs/",
	"net/",
	"sys/",
	"pty/",
	"testx/",
}
ASSERT_EXCLUDED_PREFIXES := [?]string{"accesskit/", "libvterm/", "gfx/rlgl"}
ASSERT_EXCLUDED_SUFFIXES := [?]string{"_test.odin", "_tests.odin", "_fuzz_test.odin"}

Risk :: enum u8 {
	Pointer,
	Index,
	Queue,
	Ownership,
	State,
	Untrusted_Input,
}
Risk_Set :: bit_set[Risk;u8]

RISK_NAMES := [Risk]string {
	.Pointer         = "pointer",
	.Index           = "index",
	.Queue           = "queue",
	.Ownership       = "ownership",
	.State           = "state",
	.Untrusted_Input = "untrusted_input",
}

risk_from_name :: proc(name: string) -> (risk: Risk, ok: bool) {
	for candidate in Risk {
		if RISK_NAMES[candidate] == name do return candidate, true
	}
	return .Pointer, false
}

Index_Kind :: enum u8 {
	Element,
	Slice,
	Remove,
}

Index_Op :: struct {
	target:     string,
	expression: string,
	offset:     int,
	kind:       Index_Kind,
}

// Proc_Body is the per-procedure view the predicates read: the masked text
// of the whole declaration, the executable text between its outer braces,
// and the derived lists every predicate would otherwise recompute.
Proc_Body :: struct {
	name:              string,
	line:              int,
	text:              string, // unmasked declaration text
	masked:            string, // masked declaration text
	executable:        string, // masked text inside the outer braces
	subscripts:        string, // executable with comma-ok map lookups blanked
	lines:             []string,
	contracts:         []string,
	ops:               []Index_Op,
	pointer_params:    []string,
	has_pointer_param: bool,
	is_c:              bool,
}

Assert_Finding :: struct {
	path:  string,
	name:  string,
	line:  int,
	risks: Risk_Set,
}

ASSERT_CONTRACT_WORDS := [?]string {
	"assert_contextless",
	"assert",
	"ensure",
	"if",
	"when",
	"for",
	"defer",
}
ASSERT_HEADS3 := [?]string{"assert_contextless", "assert", "ensure"}
ASSERT_HEADS4 := [?]string{"assert_contextless", "assert", "ensure", "if"}

// proc_body builds the view for one top-level procedure.
proc_body :: proc(source: ^Source, entry: Proc_Decl, allocator := context.allocator) -> Proc_Body {
	assert(source != nil, "proc_body: nil source")
	assert(entry.lit != nil && entry.lit.body != nil, "proc_body: bodiless procedure")
	start := source.line_starts[entry.start_line]
	end := len(source.text)
	if entry.end_line + 1 < len(source.line_starts) do end = source.line_starts[entry.end_line + 1]
	assert(start <= end, "proc_body: inverted declaration span")
	open := entry.lit.body.pos.offset
	close := entry.lit.body.end.offset - 1
	assert(open >= start && close < end && open < close, "proc_body: body outside declaration")
	assert(source.masked[open] == '{' && source.masked[close] == '}', "proc_body: body braces")
	body := Proc_Body {
		name       = entry.name,
		line       = entry.start_line,
		text       = source.text[start:end],
		masked     = source.masked[start:end],
		executable = source.masked[open + 1:close],
	}
	body.subscripts = assert_mask_map_lookups(body.executable, allocator)
	body.lines = strings.split(body.executable, "\n", allocator)
	contracts := make([dynamic]string, allocator)
	for line in body.lines {
		if has_any_word(line, ASSERT_CONTRACT_WORDS[:]) do append(&contracts, line)
	}
	body.contracts = contracts[:]
	body.ops = assert_index_operations(body, allocator)
	body.pointer_params = assert_pointer_parameter_names(entry.lit, allocator)
	body.has_pointer_param = assert_has_pointer_parameter(source, entry.lit)
	body.is_c = strings.contains(body.text, "proc \"c\"")
	return body
}

// assert_pointer_parameter_names lists `^T` parameters. Odin's grouped form
// `a, b: ^T` gives every name in the group the type. Names with a `using` or
// directive prefix are skipped, matching the text-based Python extraction.
assert_pointer_parameter_names :: proc(
	lit: ^ast.Proc_Lit,
	allocator := context.allocator,
) -> []string {
	assert(lit != nil, "assert_pointer_parameter_names: nil literal")
	names := make([dynamic]string, allocator)
	if lit.type == nil || lit.type.params == nil do return names[:]
	for field in lit.type.params.list {
		if field.type == nil do continue
		if _, is_pointer := field.type.derived_expr.(^ast.Pointer_Type); !is_pointer do continue
		if field.flags - {.Ellipsis} != {} do continue
		for name_expr in field.names {
			ident, ok := name_expr.derived_expr.(^ast.Ident)
			if ok && ident.name != "" do append(&names, ident.name)
		}
	}
	return names[:]
}

// assert_has_pointer_parameter mirrors the textual `:\s*\^` search over the
// parameter list, which also sees pointers inside nested procedure types.
assert_has_pointer_parameter :: proc(source: ^Source, lit: ^ast.Proc_Lit) -> bool {
	if lit.type == nil || lit.type.params == nil do return false
	params := lit.type.params
	start := clamp(params.pos.offset, 0, len(source.masked))
	end := clamp(params.end.offset, start, len(source.masked))
	text := source.masked[start:end]
	for index in 0 ..< len(text) {
		if text[index] != ':' do continue
		next := skip_spaces(text, index + 1)
		if next < len(text) && text[next] == '^' do return true
	}
	return false
}

// assert_mask_map_lookups blanks the subscript of every comma-ok map lookup
// `v, ok := m[key]`, preserving offsets. Arrays and slices have no comma-ok
// indexing form, so the shape is unambiguous and has no bound to violate.
assert_mask_map_lookups :: proc(executable: string, allocator := context.allocator) -> string {
	buffer := make([]byte, len(executable), allocator)
	copy(buffer, executable)
	for index in 0 ..< len(executable) {
		if executable[index] != '[' do continue
		if !assert_is_map_lookup_prefix(executable, index) do continue
		close := strings.index_byte(executable[index:], ']')
		if close < 0 do continue
		if strings.index_byte(executable[index:index + close], '\n') >= 0 do continue
		for position in index ..= index + close do buffer[position] = ' '
	}
	return string(buffer)
}

// assert_is_map_lookup_prefix reports whether the text before `open` ends in
// `ident , ident :?= dotted` with arbitrary spacing.
@(private = "file")
assert_is_map_lookup_prefix :: proc(text: string, open: int) -> bool {
	pos := assert_skip_back_spaces(text, open)
	dotted_start, has_dotted := assert_dotted_start(text, pos)
	if !has_dotted do return false
	pos = assert_skip_back_spaces(text, dotted_start)
	if pos == 0 || text[pos - 1] != '=' do return false
	pos -= 1
	if pos > 0 && text[pos - 1] == ':' do pos -= 1
	pos = assert_skip_back_spaces(text, pos)
	ident_start, has_ident := assert_ident_start(text, pos)
	if !has_ident do return false
	pos = assert_skip_back_spaces(text, ident_start)
	if pos == 0 || text[pos - 1] != ',' do return false
	pos = assert_skip_back_spaces(text, pos - 1)
	first_start, has_first := assert_ident_start(text, pos)
	if !has_first do return false
	return first_start == 0 || !is_word_byte(text[first_start - 1])
}

@(private = "file")
assert_skip_back_spaces :: proc(text: string, pos: int) -> int {
	index := pos
	for index > 0 && is_space_byte(text[index - 1]) do index -= 1
	return index
}

// assert_ident_start returns the start of the identifier ending at `end`.
@(private = "file")
assert_ident_start :: proc(text: string, end: int) -> (start: int, ok: bool) {
	start = end
	for start > 0 && is_word_byte(text[start - 1]) do start -= 1
	if start == end do return start, false
	return start, !is_digit_byte(text[start])
}

// assert_dotted_start returns the start of the `a.b.c` chain ending at `end`.
@(private = "file")
assert_dotted_start :: proc(text: string, end: int) -> (start: int, ok: bool) {
	start, ok = assert_ident_start(text, end)
	if !ok do return
	for start > 0 && text[start - 1] == '.' {
		previous, has_previous := assert_ident_start(text, start - 1)
		if !has_previous do break
		start = previous
	}
	return start, true
}

// assert_index_operations lists element and slice subscripts (map lookups
// already blanked) and ordered/unordered_remove calls, sorted by offset.
assert_index_operations :: proc(body: Proc_Body, allocator := context.allocator) -> []Index_Op {
	ops := make([dynamic]Index_Op, allocator)
	text := body.subscripts
	for index in 0 ..< len(text) {
		if text[index] != '[' do continue
		pos := assert_skip_back_spaces(text, index)
		start, has_target := assert_dotted_start(text, pos)
		if !has_target || (start > 0 && is_word_byte(text[start - 1])) do continue
		close := strings.index_byte(text[index:], ']')
		if close < 0 do continue
		inner := text[index + 1:index + close]
		if strings.index_byte(inner, '\n') >= 0 do continue
		expression := strings.trim_space(inner)
		if expression == "" do continue
		kind := strings.index_byte(expression, ':') >= 0 ? Index_Kind.Slice : Index_Kind.Element
		append(&ops, Index_Op{text[start:pos], expression, start, kind})
	}
	for name in ([?]string{"ordered_remove", "unordered_remove"}) {
		from := 0
		for _ in 0 ..< TEXT_SCAN_MAX {
			at := find_word(body.executable, name, from)
			if at < 0 do break
			from = at + len(name)
			op, ok := assert_remove_operation(body.executable, at, from)
			if ok do append(&ops, op)
		}
	}
	slice.sort_by(ops[:], proc(a, b: Index_Op) -> bool {return a.offset < b.offset})
	return ops[:]
}

@(private = "file")
assert_remove_operation :: proc(text: string, at, after: int) -> (op: Index_Op, ok: bool) {
	pos := skip_spaces(text, after)
	if pos >= len(text) || text[pos] != '(' do return
	pos = skip_spaces(text, pos + 1)
	if pos < len(text) && text[pos] == '&' do pos += 1
	pos = skip_spaces(text, pos)
	target_start := pos
	for pos < len(text) && (is_word_byte(text[pos]) || text[pos] == '.') do pos += 1
	if pos == target_start do return
	target := text[target_start:pos]
	pos = skip_spaces(text, pos)
	if pos >= len(text) || text[pos] != ',' do return
	pos = skip_spaces(text, pos + 1)
	expr_start := pos
	for pos < len(text) && text[pos] != ',' && text[pos] != ')' && text[pos] != '\n' do pos += 1
	expression := strings.trim_space(text[expr_start:pos])
	if expression == "" do return
	return Index_Op{target, expression, at, .Remove}, true
}

// --- risk detection -------------------------------------------------------

assert_risks_for :: proc(body: ^Proc_Body) -> Risk_Set {
	assert(body != nil, "assert_risks_for: nil body")
	risks: Risk_Set
	text := body.executable
	if assert_pointer_syntax(text) do risks += {.Pointer}
	if assert_index_syntax(body.subscripts) do risks += {.Index}
	if has_any_call(text, {"append", "inject_at", "ordered_remove", "unordered_remove"}) {
		risks += {.Queue}
	}
	if has_any_call(text, {"new", "delete", "free", "destroy", "clone", "resize"}) {
		risks += {.Ownership}
	}
	if assert_state_write(text) do risks += {.State}
	if assert_untrusted_call(text) do risks += {.Untrusted_Input}
	if body.has_pointer_param && !body.is_c do risks += {.Pointer}
	return risks
}

// has_call reports `name(` with word boundaries and optional spaces.
has_call :: proc(text, name: string) -> bool {
	return find_call(text, name) >= 0
}

find_call :: proc(text, name: string, from := 0) -> int {
	start := from
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_word(text, name, start)
		if at < 0 do return -1
		next := skip_spaces(text, at + len(name))
		if next < len(text) && text[next] == '(' do return at
		start = at + 1
	}
	return -1
}

has_any_call :: proc(text: string, names: []string) -> bool {
	for name in names do if has_call(text, name) do return true
	return false
}

@(private = "file")
assert_pointer_syntax :: proc(text: string) -> bool {
	for index in 1 ..< len(text) {
		if text[index] == '^' && is_word_byte(text[index - 1]) do return true
	}
	for name in ([?]string{"raw_data", "raw_ptr"}) {
		at := strings.index(text, name)
		for _ in 0 ..< TEXT_SCAN_MAX {
			if at < 0 do break
			next := skip_spaces(text, at + len(name))
			if next < len(text) && text[next] == '(' do return true
			rel := strings.index(text[at + 1:], name)
			at = rel < 0 ? -1 : at + 1 + rel
		}
	}
	return has_call(text, "transmute")
}

@(private = "file")
assert_index_syntax :: proc(text: string) -> bool {
	for index in 0 ..< len(text) {
		if text[index] != '[' do continue
		pos := assert_skip_back_spaces(text, index)
		if pos == 0 do continue
		prev := text[pos - 1]
		if !(is_word_byte(prev) || prev == ')' || prev == ']') do continue
		close := strings.index_byte(text[index:], ']')
		if close <= 1 do continue
		if strings.index_byte(text[index:index + close], '\n') >= 0 do continue
		return true
	}
	return has_any_call(text, {"ordered_remove", "unordered_remove"})
}

@(private = "file")
assert_state_write :: proc(text: string) -> bool {
	for word in ([?]string{"state", "running", "active", "session"}) {
		from := 0
		for _ in 0 ..< TEXT_SCAN_MAX {
			at := find_word(text, word, from)
			if at < 0 do break
			from = at + len(word)
			next := skip_spaces(text, from)
			if next >= len(text) do break
			if text[next] == '=' do return true
			if (text[next] == '+' || text[next] == '-') &&
			   next + 1 < len(text) &&
			   text[next + 1] == '=' {
				return true
			}
		}
	}
	return false
}

@(private = "file")
assert_untrusted_call :: proc(text: string) -> bool {
	for prefix in ([?]string{"decode", "read", "recv"}) {
		from := 0
		for _ in 0 ..< TEXT_SCAN_MAX {
			rel := strings.index(text[from:], prefix)
			if rel < 0 do break
			at := from + rel
			from = at + 1
			if at > 0 && is_word_byte(text[at - 1]) do continue
			end := at + len(prefix)
			for end < len(text) && is_word_byte(text[end]) do end += 1
			next := skip_spaces(text, end)
			if next < len(text) && text[next] == '(' do return true
		}
	}
	return false
}

// --- driver ---------------------------------------------------------------

assert_findings_for_source :: proc(
	source: ^Source,
	allocator := context.allocator,
) -> []Assert_Finding {
	assert(source != nil, "assert_findings_for_source: nil source")
	findings := make([dynamic]Assert_Finding, allocator)
	for entry in top_level_procs(source.file, context.temp_allocator) {
		body := proc_body(source, entry, context.temp_allocator)
		risks := assert_risks_for(&body)
		if assert_is_trivial(&body, risks) do continue
		if assert_is_thin_forwarder(&body, risks) do continue
		if assert_has_dominating_guard(&body, risks) do continue
		uncovered: Risk_Set
		for risk in Risk {
			if risk in assert_uncovered_risks(&body, risks) && !assert_discharged(&body, risk) {
				uncovered += {risk}
			}
		}
		if uncovered != {} {
			append(
				&findings,
				Assert_Finding{source.rel_path, entry.name, entry.start_line, uncovered},
			)
		}
	}
	return findings[:]
}

risk_set_names :: proc(risks: Risk_Set, allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, allocator)
	for risk in Risk do if risk in risks do append(&names, RISK_NAMES[risk])
	return names[:]
}

assert_finding_key :: proc(
	finding: Assert_Finding,
	allocator := context.temp_allocator,
) -> string {
	return strings.concatenate({finding.path, ":", finding.name}, allocator)
}

// assert_check_findings prints zero-debt failures, or with a baseline only
// the changes against it, using the Python guard's exact wording.
assert_check_findings :: proc(
	findings: []Assert_Finding,
	baseline: List_Baseline,
	has_baseline: bool,
	report: ^Report,
) {
	assert(report != nil, "assert_check_findings: nil report")
	seen := make(map[string]bool, context.temp_allocator)
	for finding in findings {
		key := assert_finding_key(finding)
		seen[key] = true
		names := risk_set_names(finding.risks)
		if !has_baseline {
			joined := strings.join(names, ", ", context.temp_allocator)
			report_addf_raw(
				report,
				finding.path,
				finding.line,
				"%s: uncovered assertion risks: %s",
				key,
				joined,
			)
			continue
		}
		allowed := baseline[key] or_else nil
		added := make([dynamic]string, context.temp_allocator)
		for name in names do if !assert_name_listed(name, allowed) do append(&added, name)
		removed := make([dynamic]string, context.temp_allocator)
		for name in allowed do if !assert_name_listed(name, names) do append(&removed, name)
		if len(added) > 0 {
			joined := strings.join(added[:], ", ", context.temp_allocator)
			report_addf_raw(
				report,
				finding.path,
				finding.line,
				"%s: uncovered assertion risks added: %s",
				key,
				joined,
			)
		}
		if len(removed) > 0 {
			slice.sort(removed[:])
			joined := strings.join(removed[:], ", ", context.temp_allocator)
			report_addf_raw(
				report,
				finding.path,
				finding.line,
				"%s: stale assertion baseline risks; remove: %s",
				key,
				joined,
			)
		}
	}
	if !has_baseline do return
	for key in sorted_keys(baseline, context.temp_allocator) {
		if key in seen do continue
		report_addf_raw(
			report,
			key_path(key),
			0,
			"%s: stale assertion baseline entry; remove it",
			key,
		)
	}
}

@(private = "file")
assert_name_listed :: proc(name: string, names: []string) -> bool {
	for candidate in names do if candidate == name do return true
	return false
}

// assert_validate_baseline rejects risk names the rule does not know.
assert_validate_baseline :: proc(baseline: List_Baseline) -> bool {
	for _, risks in baseline {
		for name in risks {
			if _, ok := risk_from_name(name); !ok do return false
		}
	}
	return true
}

assert_print_measurement :: proc(file: ^os.File, findings: []Assert_Finding) {
	assert(file != nil, "assert_print_measurement: nil file")
	by_risk := make(map[string]int, context.temp_allocator)
	for finding in findings {
		for name in risk_set_names(finding.risks) do by_risk[name] += 1
	}
	fmt.fprintln(file, "{")
	fmt.fprint(file, "  \"by_risk\": ")
	print_int_map(file, by_risk, "  ")
	fmt.fprintln(file, ",")
	keys := make([dynamic]string, context.temp_allocator)
	by_key := make(map[string]Assert_Finding, context.temp_allocator)
	for finding in findings {
		key := assert_finding_key(finding)
		append(&keys, key)
		by_key[key] = finding
	}
	slice.sort(keys[:])
	if len(keys) == 0 {
		fmt.fprintln(file, "  \"procedures\": {},")
	} else {
		fmt.fprintln(file, "  \"procedures\": {")
		for key, index in keys {
			names := risk_set_names(by_key[key].risks)
			quoted := make([dynamic]string, context.temp_allocator)
			for name in names do append(&quoted, json_quote(name, context.temp_allocator))
			comma := index + 1 < len(keys) ? "," : ""
			fmt.fprintfln(
				file,
				"    %s: [\n      %s\n    ]%s",
				json_quote(key, context.temp_allocator),
				strings.join(quoted[:], ",\n      ", context.temp_allocator),
				comma,
			)
		}
		fmt.fprintln(file, "  },")
	}
	fmt.fprintfln(file, "  \"uncovered\": %d", len(findings))
	fmt.fprintln(file, "}")
}

assert_packages_from_option :: proc(option: string) -> (packages: []string, ok: bool) {
	if option == "" do return ASSERT_PACKAGES[:], true
	list := make([dynamic]string)
	for part in strings.split(option, ",", context.temp_allocator) {
		prefix := strings.trim_space(part)
		if prefix == "" do continue
		if !strings.has_suffix(prefix, "/") do prefix = strings.concatenate({prefix, "/"})
		append(&list, strings.clone(prefix))
	}
	if len(list) == 0 {
		fmt.eprintln("odingate: --packages was empty after parsing")
		return nil, false
	}
	return list[:], true
}

run_assertions :: proc(options: ^Options) -> int {
	assert(options != nil, "run_assertions: nil options")
	packages, ok := assert_packages_from_option(options.packages)
	if !ok do return EXIT_USAGE
	files := filter_paths(
		options.files,
		packages,
		ASSERT_EXCLUDED_PREFIXES[:],
		ASSERT_EXCLUDED_SUFFIXES[:],
	)
	report: Report
	sources := load_sources(options.root, files, &report)
	findings := make([dynamic]Assert_Finding)
	for &source in sources {
		if !source.parse_ok do continue
		append(&findings, ..assert_findings_for_source(&source))
	}
	if options.measure {
		assert_print_measurement(os.stdout, findings[:])
		return EXIT_OK
	}
	baseline: List_Baseline
	has_baseline := options.baseline != ""
	if has_baseline {
		loaded, loaded_ok := baseline_load_lists(options.baseline)
		if !loaded_ok || !assert_validate_baseline(loaded) {
			fmt.eprintfln(
				"%s: expected an object mapping 'path:procedure' to risk names",
				options.baseline,
			)
			return EXIT_USAGE
		}
		baseline = loaded
	}
	assert_check_findings(findings[:], baseline, has_baseline, &report)
	assert(len(sources) <= len(files), "run_assertions: more sources than files")
	return report_emit(&report, os.stdout)
}
