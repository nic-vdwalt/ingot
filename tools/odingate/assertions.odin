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

// Index_Op is one subscript, slice, or `ordered_remove`/`unordered_remove`
// call. `target`/`expression` are the collapsed source text of the operands
// (what the author wrote); the node handles are what the predicates query.
// `offset` is relative to the executable body text.
Index_Op :: struct {
	target:      string,
	expression:  string,
	offset:      int,
	kind:        Index_Kind,
	node:        ^ast.Node,
	target_expr: ^ast.Expr,
	index_expr:  ^ast.Expr, // element index or remove position; nil for slices
	low:         ^ast.Expr, // slice bounds; nil when omitted
	high:        ^ast.Expr,
}

// Proc_Body is the per-procedure view the predicates read: the literal and
// its single bounded scan, plus the derived lists every predicate would
// otherwise recompute.
Proc_Body :: struct {
	name:              string,
	line:              int,
	lit:               ^ast.Proc_Lit,
	source:            ^Source,
	scan:              Body_Scan,
	assertions:        []Assertion,
	exec_start:        int, // source offset just inside the body's `{`
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

// proc_body builds the view for one top-level procedure.
proc_body :: proc(source: ^Source, entry: Proc_Decl, allocator := context.allocator) -> Proc_Body {
	assert(source != nil, "proc_body: nil source")
	assert(entry.lit != nil && entry.lit.body != nil, "proc_body: bodiless procedure")
	open := entry.lit.body.pos.offset
	close := entry.lit.body.end.offset - 1
	assert(open < close, "proc_body: inverted body span")
	assert(source.masked[open] == '{' && source.masked[close] == '}', "proc_body: body braces")
	body := Proc_Body {
		name       = entry.name,
		line       = entry.start_line,
		lit        = entry.lit,
		source     = source,
		exec_start = open + 1,
	}
	body.scan = body_scan(entry.lit.body, allocator)
	body.assertions = collect_assertions(&body.scan, allocator)
	body.ops = assert_index_operations(&body, allocator)
	body.pointer_params = assert_pointer_parameter_names(entry.lit, allocator)
	body.has_pointer_param = assert_has_pointer_parameter(entry.lit)
	body.is_c = proc_is_c(entry.lit)
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

// assert_has_pointer_parameter reports a `^T` parameter, including one
// declared inside a nested procedure-type parameter (`cb: proc(p: ^T)`).
assert_has_pointer_parameter :: proc(lit: ^ast.Proc_Lit) -> bool {
	assert(lit != nil, "assert_has_pointer_parameter: nil literal")
	if lit.type == nil || lit.type.params == nil do return false
	for field in lit.type.params.list {
		if assert_type_has_pointer_param(field.type, 0) do return true
	}
	return false
}

ASSERT_TYPE_NEST_MAX :: 8

// assert_type_has_pointer_param walks a parameter type and the parameter
// types of any nested procedure types, bounded by ASSERT_TYPE_NEST_MAX.
@(private = "file")
assert_type_has_pointer_param :: proc(type: ^ast.Expr, depth: int) -> bool {
	pending := make([dynamic]^ast.Expr, context.temp_allocator)
	append(&pending, type)
	for _ in 0 ..< ASSERT_TYPE_NEST_MAX * 8 {
		if len(pending) == 0 do return false
		current := pop(&pending)
		if current == nil do continue
		#partial switch node in current.derived_expr {
		case ^ast.Pointer_Type:
			return true
		case ^ast.Paren_Expr:
			append(&pending, node.expr)
		case ^ast.Proc_Type:
			if node.params == nil do continue
			for field in node.params.list do append(&pending, field.type)
		}
	}
	return false
}

// assert_dotted_target returns the trailing identifier/selector chain of a
// subscript target as written (`a.b` for `a.b[i]`, `bindings` for
// `slots[0].bindings[i]`); ok is false when the target ends in a call,
// subscript, or dereference, which no bound can be stated against by name.
assert_dotted_target :: proc(
	expr: ^ast.Expr,
	allocator := context.allocator,
) -> (
	target: string,
	ok: bool,
) {
	parts := make([dynamic]string, context.temp_allocator)
	current := expr
	for _ in 0 ..< ASSERT_TYPE_NEST_MAX * 8 {
		if current == nil do break
		#partial switch node in current.derived_expr {
		case ^ast.Ident:
			if node.name == "nil" do return "", false
			inject_at(&parts, 0, node.name)
			return strings.join(parts[:], ".", allocator), true
		case ^ast.Selector_Expr:
			if node.field == nil do return "", false
			inject_at(&parts, 0, node.field.name)
			current = node.expr
		case ^ast.Paren_Expr:
			current = node.expr
		case:
			if len(parts) == 0 do return "", false
			return strings.join(parts[:], ".", allocator), true
		}
	}
	return "", false
}

// assert_comma_ok_indexes collects the subscripts that are the single value
// of a two-name declaration or assignment (`v, ok := m[k]`): a map lookup
// with no bound to violate.
assert_comma_ok_indexes :: proc(
	scan: ^Body_Scan,
	allocator := context.temp_allocator,
) -> map[^ast.Index_Expr]bool {
	lookups := make(map[^ast.Index_Expr]bool, allocator)
	for decl in scan.decls {
		if index, ok := is_comma_ok_lookup(decl); ok do lookups[index] = true
	}
	for assign in scan.assigns {
		if len(assign.lhs) != 2 || len(assign.rhs) != 1 do continue
		if index, ok := expr_unparen(assign.rhs[0]).derived_expr.(^ast.Index_Expr); ok {
			lookups[index] = true
		}
	}
	return lookups
}

// assert_index_operations lists element and slice subscripts on dotted
// targets (comma-ok map lookups excluded) and ordered/unordered_remove calls,
// sorted by offset.
assert_index_operations :: proc(body: ^Proc_Body, allocator := context.allocator) -> []Index_Op {
	assert(body != nil && body.source != nil, "assert_index_operations: nil body")
	ops := make([dynamic]Index_Op, allocator)
	lookups := assert_comma_ok_indexes(&body.scan)
	for index in body.scan.indexes {
		if index in lookups do continue
		target := expr_unparen(index.expr)
		name, named := assert_dotted_target(target, allocator)
		if !named do continue
		append(
			&ops,
			Index_Op {
				target = name,
				expression = expr_source(body.source, index.index, allocator),
				offset = index.pos.offset - body.exec_start,
				kind = .Element,
				node = index,
				target_expr = target,
				index_expr = index.index,
			},
		)
	}
	for cell in body.scan.matrices {
		target := expr_unparen(cell.expr)
		name, named := assert_dotted_target(target, allocator)
		if !named do continue
		row := expr_source(body.source, cell.row_index, allocator)
		column := expr_source(body.source, cell.column_index, allocator)
		append(
			&ops,
			Index_Op {
				target = name,
				expression = strings.concatenate({row, ", ", column}, allocator),
				offset = cell.pos.offset - body.exec_start,
				kind = .Element,
				node = cell,
				target_expr = target,
				index_expr = cell.row_index,
				high = cell.column_index,
			},
		)
	}
	for slice_expr in body.scan.slices {
		target := expr_unparen(slice_expr.expr)
		name, named := assert_dotted_target(target, allocator)
		if !named do continue
		low := slice_expr.low != nil ? expr_source(body.source, slice_expr.low, allocator) : ""
		high := slice_expr.high != nil ? expr_source(body.source, slice_expr.high, allocator) : ""
		append(
			&ops,
			Index_Op {
				target = name,
				expression = strings.concatenate({low, ":", high}, allocator),
				offset = slice_expr.pos.offset - body.exec_start,
				kind = .Slice,
				node = slice_expr,
				target_expr = target,
				low = slice_expr.low,
				high = slice_expr.high,
			},
		)
	}
	for call in body.scan.calls {
		if !callee_is(call, {"ordered_remove", "unordered_remove"}) do continue
		if len(call.args) < 2 do continue
		target := expr_unparen(call.args[0])
		if unary, is_unary := target.derived_expr.(^ast.Unary_Expr);
		   is_unary && unary.op.kind == .And {
			target = expr_unparen(unary.expr)
		}
		name, named := assert_dotted_target(target, allocator)
		if !named do continue
		append(
			&ops,
			Index_Op {
				target = name,
				expression = expr_source(body.source, call.args[1], allocator),
				offset = call.pos.offset - body.exec_start,
				kind = .Remove,
				node = call,
				target_expr = target,
				index_expr = call.args[1],
			},
		)
	}
	slice.sort_by(ops[:], proc(a, b: Index_Op) -> bool {return a.offset < b.offset})
	assert(
		len(ops) <=
		len(body.scan.indexes) +
			len(body.scan.slices) +
			len(body.scan.matrices) +
			len(body.scan.calls),
	)
	return ops[:]
}

// --- risk detection -------------------------------------------------------

ASSERT_QUEUE_CALLS := [?]string{"append", "inject_at", "ordered_remove", "unordered_remove"}
ASSERT_OWNERSHIP_CALLS := [?]string{"new", "delete", "free", "destroy", "clone", "resize"}
ASSERT_STATE_WORDS := [?]string{"state", "running", "active", "session"}
ASSERT_UNTRUSTED_PREFIXES := [?]string{"decode", "read", "recv"}
ASSERT_RAW_POINTER_CALLS := [?]string{"raw_data", "raw_ptr"}

assert_risks_for :: proc(body: ^Proc_Body) -> Risk_Set {
	assert(body != nil, "assert_risks_for: nil body")
	risks: Risk_Set
	if assert_pointer_syntax(body) do risks += {.Pointer}
	if assert_index_syntax(body) do risks += {.Index}
	if assert_calls_any(body, ASSERT_QUEUE_CALLS[:]) do risks += {.Queue}
	if assert_calls_any(body, ASSERT_OWNERSHIP_CALLS[:]) do risks += {.Ownership}
	if assert_state_write(body) do risks += {.State}
	if assert_untrusted_call(body) do risks += {.Untrusted_Input}
	if body.has_pointer_param && !body.is_c do risks += {.Pointer}
	return risks
}

// assert_calls_any reports a call to any of `names` in the body.
assert_calls_any :: proc(body: ^Proc_Body, names: []string) -> bool {
	for call in body.scan.calls do if callee_is(call, names) do return true
	return false
}

// assert_has_transmute reports a `transmute(T)x` in the body.
assert_has_transmute :: proc(body: ^Proc_Body) -> bool {
	for cast_expr in body.scan.casts do if cast_expr.tok.kind == .Transmute do return true
	return false
}

// assert_pointer_syntax: a dereference, a raw pointer conversion, or a
// transmute.
@(private = "file")
assert_pointer_syntax :: proc(body: ^Proc_Body) -> bool {
	if len(body.scan.derefs) > 0 do return true
	if assert_calls_any(body, ASSERT_RAW_POINTER_CALLS[:]) do return true
	return assert_has_transmute(body)
}

// assert_index_syntax: any subscript or slice that is not a comma-ok map
// lookup, or an ordered/unordered_remove call.
@(private = "file")
assert_index_syntax :: proc(body: ^Proc_Body) -> bool {
	if len(body.scan.slices) > 0 || len(body.scan.matrices) > 0 do return true
	lookups := assert_comma_ok_indexes(&body.scan)
	for index in body.scan.indexes do if index not_in lookups do return true
	return assert_calls_any(body, {"ordered_remove", "unordered_remove"})
}

// assert_state_write: an assignment (any operator) whose target's leaf name
// is a lifecycle word.
@(private = "file")
assert_state_write :: proc(body: ^Proc_Body) -> bool {
	for assign in body.scan.assigns {
		for leaf in assign_lhs_leaves(assign) {
			for word in ASSERT_STATE_WORDS do if leaf == word do return true
		}
	}
	return false
}

// assert_untrusted_call: a call whose unqualified name starts with
// decode/read/recv.
@(private = "file")
assert_untrusted_call :: proc(body: ^Proc_Body) -> bool {
	for call in body.scan.calls {
		for prefix in ASSERT_UNTRUSTED_PREFIXES do if callee_has_prefix(call, prefix) do return true
	}
	return false
}

// --- driver ---------------------------------------------------------------

Assert_Skip :: enum {
	None,
	Trivial,
	Forwarder,
	Dominated,
}

ASSERT_SKIP_NAMES := [Assert_Skip]string {
	.None      = "-",
	.Trivial   = "trivial",
	.Forwarder = "forwarder",
	.Dominated = "dominated",
}

// Assert_Trace is the full verdict for one procedure: the risks detected,
// why the procedure was skipped (if it was), which risks a predicate
// discharged, and which remain uncovered. `--report` prints one line per
// entry so two implementations of the rule can be diffed procedure by
// procedure rather than only on the final finding count.
Assert_Trace :: struct {
	path:       string,
	name:       string,
	line:       int,
	risks:      Risk_Set,
	skip:       Assert_Skip,
	discharged: Risk_Set,
	uncovered:  Risk_Set,
}

// assert_trace_proc evaluates one procedure through the same cascade as the
// gate: skip predicates first, then per-risk coverage and discharge.
assert_trace_proc :: proc(source: ^Source, entry: Proc_Decl) -> Assert_Trace {
	assert(source != nil, "assert_trace_proc: nil source")
	body := proc_body(source, entry, context.temp_allocator)
	trace := Assert_Trace {
		path  = source.rel_path,
		name  = entry.name,
		line  = entry.start_line,
		risks = assert_risks_for(&body),
	}
	switch {
	case assert_is_trivial(&body, trace.risks):
		trace.skip = .Trivial
	case assert_is_thin_forwarder(&body, trace.risks):
		trace.skip = .Forwarder
	case assert_has_dominating_guard(&body, trace.risks):
		trace.skip = .Dominated
	}
	if trace.skip != .None do return trace
	for risk in Risk {
		if risk not_in trace.risks do continue
		if risk not_in assert_uncovered_risks(&body, trace.risks) do continue
		if assert_discharged(&body, risk) {
			trace.discharged += {risk}
		} else {
			trace.uncovered += {risk}
		}
	}
	return trace
}

assert_traces_for_source :: proc(
	source: ^Source,
	allocator := context.allocator,
) -> []Assert_Trace {
	assert(source != nil, "assert_traces_for_source: nil source")
	traces := make([dynamic]Assert_Trace, allocator)
	for entry in top_level_procs(source.file, context.temp_allocator) {
		append(&traces, assert_trace_proc(source, entry))
	}
	return traces[:]
}

assert_findings_for_source :: proc(
	source: ^Source,
	allocator := context.allocator,
) -> []Assert_Finding {
	assert(source != nil, "assert_findings_for_source: nil source")
	findings := make([dynamic]Assert_Finding, allocator)
	for trace in assert_traces_for_source(source, context.temp_allocator) {
		if trace.uncovered == {} do continue
		append(&findings, Assert_Finding{trace.path, trace.name, trace.line, trace.uncovered})
	}
	return findings[:]
}

@(private = "file")
assert_trace_less :: proc(a, b: Assert_Trace) -> bool {
	if a.path != b.path do return a.path < b.path
	if a.name != b.name do return a.name < b.name
	return a.line < b.line
}

// assert_print_traces writes the parity trace, sorted by `path:name`, as
// `path:name risks=[a,b] skip=<reason> discharged=[..] uncovered=[..]`.
assert_print_traces :: proc(file: ^os.File, traces: []Assert_Trace) {
	assert(file != nil, "assert_print_traces: nil file")
	sorted := make([]Assert_Trace, len(traces), context.temp_allocator)
	copy(sorted, traces)
	slice.sort_by(sorted, assert_trace_less)
	for trace in sorted {
		fmt.fprintfln(
			file,
			"%s:%s risks=[%s] skip=%s discharged=[%s] uncovered=[%s]",
			trace.path,
			trace.name,
			strings.join(risk_set_names(trace.risks), ",", context.temp_allocator),
			ASSERT_SKIP_NAMES[trace.skip],
			strings.join(risk_set_names(trace.discharged), ",", context.temp_allocator),
			strings.join(risk_set_names(trace.uncovered), ",", context.temp_allocator),
		)
	}
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
	if options.report {
		traces := make([dynamic]Assert_Trace)
		for &source in sources {
			if !source.parse_ok do continue
			append(&traces, ..assert_traces_for_source(&source))
		}
		assert_print_traces(os.stdout, traces[:])
		return EXIT_OK
	}
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
