package odingate

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// A top-level procedure declaration with the spans the rules key on.
// `start_line` is the first attribute line when attributes exist (matching the
// Python counter, which included the `@(` line), otherwise the declaration
// line; `end_line` is the closing brace of the body.
// Upper bound on statements visited while flattening file-scope declarations
// through `when` blocks; no package here nests anywhere near this deep.
SCAN_WORK_MAX :: 1 << 16

Proc_Decl :: struct {
	name:            string,
	decl:            ^ast.Value_Decl,
	lit:             ^ast.Proc_Lit,
	is_private:      bool,
	is_file_private: bool,
	is_deprecated:   bool,
	start_line:      int,
	end_line:        int,
}

// top_level_value_decls flattens file-scope declarations, descending through
// `when` blocks because platform-gated declarations are still declarations.
// The descent uses an explicit bounded work list rather than recursion.
top_level_value_decls :: proc(
	file: ^ast.File,
	allocator := context.allocator,
) -> []^ast.Value_Decl {
	assert(file != nil, "top_level_value_decls: nil file")
	decls := make([dynamic]^ast.Value_Decl, allocator)
	pending := make([dynamic]^ast.Stmt, context.temp_allocator)
	for index := len(file.decls) - 1; index >= 0; index -= 1 {
		append(&pending, file.decls[index])
	}
	for _ in 0 ..< SCAN_WORK_MAX {
		if len(pending) == 0 do break
		stmt := pop(&pending)
		if stmt == nil do continue
		#partial switch node in stmt.derived_stmt {
		case ^ast.Value_Decl:
			append(&decls, node)
		case ^ast.When_Stmt:
			append(&pending, node.else_stmt)
			append(&pending, node.body)
		case ^ast.Block_Stmt:
			for index := len(node.stmts) - 1; index >= 0; index -= 1 {
				append(&pending, node.stmts[index])
			}
		}
	}
	assert(len(pending) == 0, "top_level_value_decls: nesting exceeds SCAN_WORK_MAX")
	return decls[:]
}

// top_level_procs lists every procedure literal bound at file scope in source
// order. Foreign procedures (nil body) and procedure types are skipped.
top_level_procs :: proc(file: ^ast.File, allocator := context.allocator) -> []Proc_Decl {
	assert(file != nil, "top_level_procs: nil file")
	procs := make([dynamic]Proc_Decl, allocator)
	for decl in top_level_value_decls(file, context.temp_allocator) {
		collect_procs_in_value_decl(decl, &procs)
	}
	return procs[:]
}

@(private = "file")
collect_procs_in_value_decl :: proc(decl: ^ast.Value_Decl, procs: ^[dynamic]Proc_Decl) {
	assert(decl != nil, "collect_procs_in_value_decl: nil decl")
	if decl.is_mutable do return
	for name_expr, index in decl.names {
		if index >= len(decl.values) do break
		lit, is_lit := decl.values[index].derived_expr.(^ast.Proc_Lit)
		if !is_lit || lit.body == nil do continue
		ident, is_ident := name_expr.derived_expr.(^ast.Ident)
		if !is_ident do continue
		entry := Proc_Decl {
			name       = ident.name,
			decl       = decl,
			lit        = lit,
			start_line = decl.pos.line,
			end_line   = lit.body.end.line,
		}
		if len(decl.attributes) > 0 {
			entry.start_line = min(entry.start_line, decl.attributes[0].pos.line)
		}
		entry.is_private, entry.is_file_private = attribute_privacy(decl.attributes[:])
		entry.is_deprecated = has_attribute(decl.attributes[:], "deprecated")
		assert(entry.end_line >= entry.start_line, "collect_procs: body ends before start")
		append(procs, entry)
	}
}

// attribute_privacy reports `@(private)` / `@(private = "package")` as
// is_private and `@(private = "file")` as both.
attribute_privacy :: proc(attributes: []^ast.Attribute) -> (is_private, is_file_private: bool) {
	for attribute in attributes {
		for elem in attribute.elems {
			name, value := attribute_elem(elem)
			if name != "private" do continue
			is_private = true
			if value == "file" do is_file_private = true
		}
	}
	return
}

has_attribute :: proc(attributes: []^ast.Attribute, wanted: string) -> bool {
	for attribute in attributes {
		for elem in attribute.elems {
			name, _ := attribute_elem(elem)
			if name == wanted do return true
		}
	}
	return false
}

// attribute_elem splits `name` or `name = "value"` into its parts; string
// values are returned without quotes, other values as their source text.
attribute_elem :: proc(elem: ^ast.Expr) -> (name, value: string) {
	if elem == nil do return
	#partial switch node in elem.derived_expr {
	case ^ast.Ident:
		return node.name, ""
	case ^ast.Field_Value:
		field_ident, ok := node.field.derived_expr.(^ast.Ident)
		if !ok do return
		return field_ident.name, literal_text(node.value)
	}
	return
}

// literal_text returns a basic literal's text without surrounding quotes,
// or "" for anything that is not a literal.
literal_text :: proc(expr: ^ast.Expr) -> string {
	if expr == nil do return ""
	lit, ok := expr.derived_expr.(^ast.Basic_Lit)
	if !ok do return ""
	text := lit.tok.text
	if lit.tok.kind == .String && len(text) >= 2 {
		return text[1:len(text) - 1]
	}
	return text
}

// callee_name splits a call's callee into an optional qualifier and name:
// `foo(x)` -> ("", "foo"), `pkg.foo(x)` -> ("pkg", "foo"). Anything else
// (a call on an indexed or parenthesised expression) yields ("", "").
callee_name :: proc(call: ^ast.Call_Expr) -> (qualifier, name: string) {
	assert(call != nil, "callee_name: nil call")
	#partial switch node in call.expr.derived_expr {
	case ^ast.Ident:
		return "", node.name
	case ^ast.Selector_Expr:
		if node.field == nil do return "", ""
		if base, ok := node.expr.derived_expr.(^ast.Ident); ok {
			return base.name, node.field.name
		}
		return "", node.field.name
	}
	return "", ""
}

// comment_group_text joins a group's lines with newlines so markers that span
// a wrapped comment are still found by substring search.
comment_group_text :: proc(group: ^ast.Comment_Group, allocator := context.allocator) -> string {
	if group == nil do return ""
	builder := strings.builder_make(allocator)
	for token, index in group.list {
		if index > 0 do strings.write_byte(&builder, '\n')
		strings.write_string(&builder, token.text)
	}
	return strings.to_string(builder)
}

// comment_group_before returns the comment group whose last line is the
// nearest non-blank line above `line`, or nil. Blank lines between the comment
// and the target are skipped, which is what the Python guards' "previous
// non-blank line" waiver lookup did.
comment_group_before :: proc(source: ^Source, line: int) -> ^ast.Comment_Group {
	assert(source != nil, "comment_group_before: nil source")
	assert(line >= 1, "comment_group_before: line below 1")
	target := preceding_nonblank_line(source.lines, line)
	if target < 1 do return nil
	for group in source.file.comments {
		if len(group.list) == 0 do continue
		last := group.list[len(group.list) - 1]
		if last.pos.line + strings.count(last.text, "\n") == target do return group
	}
	return nil
}

// preceding_nonblank_line returns the 1-based number of the closest line above
// `line` that has non-whitespace content, or 0 when none exists.
preceding_nonblank_line :: proc(lines: []string, line: int) -> int {
	assert(line >= 1, "preceding_nonblank_line: line below 1")
	for candidate := min(line - 1, len(lines)); candidate >= 1; candidate -= 1 {
		if strings.trim_space(lines[candidate - 1]) != "" do return candidate
	}
	return 0
}

// comment_last_text returns the text of a group's final `//` token with the
// slashes and surrounding whitespace removed, e.g. "tigerstyle: pure".
comment_last_text :: proc(group: ^ast.Comment_Group) -> string {
	if group == nil || len(group.list) == 0 do return ""
	return comment_token_body(group.list[len(group.list) - 1].text)
}

comment_token_body :: proc(text: string) -> string {
	body := text
	if strings.has_prefix(body, "//") {
		body = body[2:]
	} else if strings.has_prefix(body, "/*") && strings.has_suffix(body, "*/") && len(body) >= 4 {
		body = body[2:len(body) - 2]
	}
	return strings.trim_space(body)
}

// tigerstyle_directive splits "tigerstyle: <kind> -- <rationale>" into its
// kind and rationale; ok is false when the text is not a tigerstyle comment.
tigerstyle_directive :: proc(text: string) -> (kind, rationale: string, ok: bool) {
	rest := strings.trim_space(text)
	if !strings.has_prefix(rest, "tigerstyle:") do return
	rest = strings.trim_space(rest[len("tigerstyle:"):])
	if separator := strings.index(rest, "--"); separator >= 0 {
		kind = strings.trim_space(rest[:separator])
		rationale = strings.trim_space(rest[separator + 2:])
	} else {
		kind = rest
	}
	return kind, rationale, kind != ""
}

// doc_contains reports whether a declaration's doc comment group carries
// `marker` (for `// tigerstyle: pure`).
doc_contains :: proc(decl: ^ast.Value_Decl, marker: string) -> bool {
	assert(decl != nil, "doc_contains: nil decl")
	if decl.docs == nil do return false
	for token in decl.docs.list {
		if strings.contains(token.text, marker) do return true
	}
	return false
}

// walk_body applies `visit` to every node under a procedure body.
walk_body :: proc(
	lit: ^ast.Proc_Lit,
	data: rawptr,
	visit: proc(v: ^ast.Visitor, n: ^ast.Node) -> ^ast.Visitor,
) {
	assert(lit != nil, "walk_body: nil literal")
	assert(lit.body != nil, "walk_body: foreign procedure has no body")
	visitor := ast.Visitor {
		visit = visit,
		data  = data,
	}
	ast.walk(&visitor, lit.body)
}

// Node_List gathers nodes of interest while walking; rules fill it with
// one visitor and then run pure predicates over the lists, so the single
// bounded walk is the only traversal.
Node_List :: [dynamic]^ast.Node

// param_names returns the identifiers declared by a procedure's parameters.
param_names :: proc(lit: ^ast.Proc_Lit, allocator := context.allocator) -> []string {
	assert(lit != nil, "param_names: nil literal")
	names := make([dynamic]string, allocator)
	if lit.type == nil || lit.type.params == nil do return names[:]
	for field in lit.type.params.list {
		for name_expr in field.names {
			if ident, ok := name_expr.derived_expr.(^ast.Ident); ok {
				append(&names, ident.name)
			}
		}
	}
	return names[:]
}

// root_ident returns the leftmost identifier of a selector/index/deref chain,
// e.g. `a.b[c].d^` -> "a", or "" when the chain does not start with one.
root_ident :: proc(expr: ^ast.Expr) -> string {
	current := expr
	for _ in 0 ..< 64 {
		if current == nil do return ""
		#partial switch node in current.derived_expr {
		case ^ast.Ident:
			return node.name
		case ^ast.Selector_Expr:
			current = node.expr
		case ^ast.Index_Expr:
			current = node.expr
		case ^ast.Slice_Expr:
			current = node.expr
		case ^ast.Deref_Expr:
			current = node.expr
		case ^ast.Paren_Expr:
			current = node.expr
		case ^ast.Unary_Expr:
			current = node.expr
		case ^ast.Implicit_Selector_Expr:
			return ""
		case:
			return ""
		}
	}
	return ""
}

// leaf_ident returns the rightmost field name of a selector chain or the bare
// identifier, e.g. `ctx.state` -> "state", `running` -> "running".
leaf_ident :: proc(expr: ^ast.Expr) -> string {
	current := expr
	for _ in 0 ..< 64 {
		if current == nil do return ""
		#partial switch node in current.derived_expr {
		case ^ast.Ident:
			return node.name
		case ^ast.Selector_Expr:
			return node.field != nil ? node.field.name : ""
		case ^ast.Deref_Expr:
			current = node.expr
		case ^ast.Paren_Expr:
			current = node.expr
		case:
			return ""
		}
	}
	return ""
}

// line_count_of returns the number of physical lines in `text`, counting a
// final line without a trailing newline (matches Python str.splitlines()).
line_count_of :: proc(text: string) -> int {
	if len(text) == 0 do return 0
	count := strings.count(text, "\n")
	if text[len(text) - 1] != '\n' do count += 1
	return count
}

// Body_Scan is the single bounded walk over a procedure body; rules then run
// pure predicates over these lists instead of walking again.
Body_Scan :: struct {
	calls:     [dynamic]^ast.Call_Expr,
	loops:     [dynamic]^ast.Node,
	assigns:   [dynamic]^ast.Assign_Stmt,
	idents:    [dynamic]^ast.Ident,
	ifs:       [dynamic]^ast.If_Stmt,
	defers:    [dynamic]^ast.Defer_Stmt,
	returns:   [dynamic]^ast.Return_Stmt,
	branches:  [dynamic]^ast.Branch_Stmt,
	indexes:   [dynamic]^ast.Index_Expr,
	slices:    [dynamic]^ast.Slice_Expr,
	decls:     [dynamic]^ast.Value_Decl,
	binaries:  [dynamic]^ast.Binary_Expr,
	casts:     [dynamic]^ast.Type_Cast,
	dyn_types: [dynamic]^ast.Dynamic_Array_Type,
	switches:  [dynamic]^ast.Node,
	whens:     [dynamic]^ast.When_Stmt,
	derefs:    [dynamic]^ast.Deref_Expr,
	matrices:  [dynamic]^ast.Matrix_Index_Expr,
	blocks:    [dynamic]^ast.Block_Stmt,
	selectors: [dynamic]^ast.Selector_Expr,
	ternaries: [dynamic]^ast.Ternary_If_Expr,
}

body_scan :: proc(root: ^ast.Node, allocator := context.allocator) -> Body_Scan {
	assert(root != nil, "body_scan: nil root")
	scan := Body_Scan {
		calls     = make([dynamic]^ast.Call_Expr, allocator),
		loops     = make([dynamic]^ast.Node, allocator),
		assigns   = make([dynamic]^ast.Assign_Stmt, allocator),
		idents    = make([dynamic]^ast.Ident, allocator),
		ifs       = make([dynamic]^ast.If_Stmt, allocator),
		defers    = make([dynamic]^ast.Defer_Stmt, allocator),
		returns   = make([dynamic]^ast.Return_Stmt, allocator),
		branches  = make([dynamic]^ast.Branch_Stmt, allocator),
		indexes   = make([dynamic]^ast.Index_Expr, allocator),
		slices    = make([dynamic]^ast.Slice_Expr, allocator),
		decls     = make([dynamic]^ast.Value_Decl, allocator),
		binaries  = make([dynamic]^ast.Binary_Expr, allocator),
		casts     = make([dynamic]^ast.Type_Cast, allocator),
		dyn_types = make([dynamic]^ast.Dynamic_Array_Type, allocator),
		switches  = make([dynamic]^ast.Node, allocator),
		whens     = make([dynamic]^ast.When_Stmt, allocator),
		derefs    = make([dynamic]^ast.Deref_Expr, allocator),
		matrices  = make([dynamic]^ast.Matrix_Index_Expr, allocator),
		blocks    = make([dynamic]^ast.Block_Stmt, allocator),
		selectors = make([dynamic]^ast.Selector_Expr, allocator),
		ternaries = make([dynamic]^ast.Ternary_If_Expr, allocator),
	}
	visitor := ast.Visitor {
		visit = body_scan_visit,
		data  = &scan,
	}
	ast.walk(&visitor, root)
	return scan
}

@(private = "file")
body_scan_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	scan := cast(^Body_Scan)v.data
	#partial switch derived in node.derived {
	case ^ast.Call_Expr:
		append(&scan.calls, derived)
	case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
		append(&scan.loops, node)
	case ^ast.Assign_Stmt:
		append(&scan.assigns, derived)
	case ^ast.Ident:
		append(&scan.idents, derived)
	case ^ast.If_Stmt:
		append(&scan.ifs, derived)
	case ^ast.Defer_Stmt:
		append(&scan.defers, derived)
	case ^ast.Return_Stmt:
		append(&scan.returns, derived)
	case ^ast.Branch_Stmt:
		append(&scan.branches, derived)
	case ^ast.Index_Expr:
		append(&scan.indexes, derived)
	case ^ast.Slice_Expr:
		append(&scan.slices, derived)
	case ^ast.Value_Decl:
		append(&scan.decls, derived)
	case ^ast.Binary_Expr:
		append(&scan.binaries, derived)
	case ^ast.Type_Cast:
		append(&scan.casts, derived)
	case ^ast.Dynamic_Array_Type:
		append(&scan.dyn_types, derived)
	case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		append(&scan.switches, node)
	case ^ast.When_Stmt:
		append(&scan.whens, derived)
	case ^ast.Deref_Expr:
		append(&scan.derefs, derived)
	case ^ast.Matrix_Index_Expr:
		append(&scan.matrices, derived)
	case ^ast.Block_Stmt:
		append(&scan.blocks, derived)
	case ^ast.Selector_Expr:
		append(&scan.selectors, derived)
	case ^ast.Ternary_If_Expr:
		append(&scan.ternaries, derived)
	}
	return v
}

// Assertion is one runtime assertion statement (`assert`, `ensure`, or
// `assert_contextless`) in a body. `#assert` is a compile-time directive and
// is never collected.
Assertion :: struct {
	call:   ^ast.Call_Expr,
	cond:   ^ast.Expr, // first argument; nil when the call has none
	facts:  Expr_Facts,
	offset: int,
}

ASSERTION_HEADS := [?]string{"assert", "ensure", "assert_contextless"}

// is_assertion_call reports whether `call` is a runtime assertion head.
is_assertion_call :: proc(call: ^ast.Call_Expr) -> bool {
	if call == nil do return false
	ident, ok := call.expr.derived_expr.(^ast.Ident)
	if !ok do return false
	for head in ASSERTION_HEADS do if ident.name == head do return true
	return false
}

// collect_assertions lists the assertion calls in a scan in source order.
collect_assertions :: proc(scan: ^Body_Scan, allocator := context.allocator) -> []Assertion {
	assert(scan != nil, "collect_assertions: nil scan")
	found := make([dynamic]Assertion, allocator)
	for call in scan.calls {
		if !is_assertion_call(call) do continue
		cond: ^ast.Expr = len(call.args) > 0 ? call.args[0] : nil
		append(&found, Assertion{call, cond, expr_facts(cond), call.pos.offset})
	}
	assert(len(found) <= len(scan.calls), "collect_assertions: more assertions than calls")
	return found[:]
}

// --- expression predicates ------------------------------------------------

// expr_mentions reports whether `name` appears as an identifier or selector
// field anywhere under `expr`.
expr_mentions :: proc(expr: ^ast.Expr, name: string) -> bool {
	if expr == nil || name == "" do return false
	probe := Expr_Mention {
		name = name,
	}
	visitor := ast.Visitor {
		visit = expr_mention_visit,
		data  = &probe,
	}
	ast.walk(&visitor, expr)
	return probe.found
}

@(private = "file")
Expr_Mention :: struct {
	name:  string,
	found: bool,
}

@(private = "file")
expr_mention_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	probe := cast(^Expr_Mention)v.data
	if probe.found do return nil
	#partial switch derived in node.derived {
	case ^ast.Ident:
		if derived.name == probe.name do probe.found = true
	case ^ast.Selector_Expr:
		if derived.field != nil && derived.field.name == probe.name do probe.found = true
	}
	return v
}

// expr_mentions_any reports whether any of `names` appears under `expr`.
expr_mentions_any :: proc(expr: ^ast.Expr, names: []string) -> bool {
	for name in names do if expr_mentions(expr, name) do return true
	return false
}

// expr_same reports whether two expressions have the same source text with
// whitespace collapsed; core:odin/ast has no structural equality.
expr_same :: proc(source: ^Source, a, b: ^ast.Expr) -> bool {
	if a == nil || b == nil do return false
	return(
		expr_source(source, a, context.temp_allocator) ==
		expr_source(source, b, context.temp_allocator) \
	)
}

// expr_unparen strips redundant parentheses.
expr_unparen :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	current := expr
	for _ in 0 ..< 64 {
		paren, ok := current.derived_expr.(^ast.Paren_Expr)
		if !ok do return current
		current = paren.expr
	}
	return current
}

// expr_is_nil reports whether `expr` is the literal `nil`.
expr_is_nil :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	ident, ok := expr_unparen(expr).derived_expr.(^ast.Ident)
	return ok && ident.name == "nil"
}

// expr_nil_compare returns the non-nil operand of `x == nil` / `nil != x`.
expr_nil_compare :: proc(expr: ^ast.Expr) -> (operand: ^ast.Expr, ok: bool) {
	if expr == nil do return
	binary, is_binary := expr_unparen(expr).derived_expr.(^ast.Binary_Expr)
	if !is_binary do return
	if binary.op.kind != .Cmp_Eq && binary.op.kind != .Not_Eq do return
	if expr_is_nil(binary.right) do return binary.left, true
	if expr_is_nil(binary.left) do return binary.right, true
	return
}

// expr_has_nil_compare reports whether any `== nil`/`!= nil` sits under `expr`.
expr_has_nil_compare :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	found := false
	visitor := ast.Visitor {
		visit = expr_nil_compare_visit,
		data  = &found,
	}
	ast.walk(&visitor, expr)
	return found
}

@(private = "file")
expr_nil_compare_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	found := cast(^bool)v.data
	if found^ do return nil
	if binary, ok := node.derived.(^ast.Binary_Expr); ok {
		if _, is_nil := expr_nil_compare(binary); is_nil do found^ = true
	}
	return v
}

// is_ordering_op reports `<`, `<=`, `>`, `>=`.
is_ordering_op :: proc(kind: tokenizer.Token_Kind) -> bool {
	#partial switch kind {
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return true
	}
	return false
}

// is_comparison_op reports the ordering operators plus `==` and `!=`.
is_comparison_op :: proc(kind: tokenizer.Token_Kind) -> bool {
	return is_ordering_op(kind) || kind == .Cmp_Eq || kind == .Not_Eq
}

// expr_binaries lists every binary expression under `expr` whose operator
// satisfies `accept`.
expr_binaries :: proc(
	expr: ^ast.Expr,
	accept: proc(kind: tokenizer.Token_Kind) -> bool,
	allocator := context.temp_allocator,
) -> []^ast.Binary_Expr {
	collector := Binary_Collector {
		accept = accept,
		found  = make([dynamic]^ast.Binary_Expr, allocator),
	}
	if expr == nil do return collector.found[:]
	visitor := ast.Visitor {
		visit = binary_collect_visit,
		data  = &collector,
	}
	ast.walk(&visitor, expr)
	return collector.found[:]
}

@(private = "file")
Binary_Collector :: struct {
	accept: proc(kind: tokenizer.Token_Kind) -> bool,
	found:  [dynamic]^ast.Binary_Expr,
}

@(private = "file")
binary_collect_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	collector := cast(^Binary_Collector)v.data
	if binary, ok := node.derived.(^ast.Binary_Expr); ok && collector.accept(binary.op.kind) {
		append(&collector.found, binary)
	}
	return v
}

// expr_ordering_against reports whether `expr` contains an ordering
// comparison with `name` mentioned on either side.
expr_ordering_against :: proc(expr: ^ast.Expr, name: string) -> bool {
	for binary in expr_binaries(expr, is_ordering_op) {
		if expr_mentions(binary.left, name) || expr_mentions(binary.right, name) do return true
	}
	return false
}

// expr_comparison_against reports whether `expr` contains any comparison with
// `name` mentioned on either side.
expr_comparison_against :: proc(expr: ^ast.Expr, name: string) -> bool {
	for binary in expr_binaries(expr, is_comparison_op) {
		if expr_mentions(binary.left, name) || expr_mentions(binary.right, name) do return true
	}
	return false
}

// expr_is_len_call reports whether `expr` is `len(x)`/`cap(x)` and returns
// its argument.
expr_is_len_call :: proc(expr: ^ast.Expr) -> (arg: ^ast.Expr, ok: bool) {
	if expr == nil do return
	call, is_call := expr_unparen(expr).derived_expr.(^ast.Call_Expr)
	if !is_call || len(call.args) != 1 do return
	_, name := callee_name(call)
	if name != "len" && name != "cap" do return
	return call.args[0], true
}

// expr_calls lists every call under `expr`.
expr_calls :: proc(expr: ^ast.Expr, allocator := context.temp_allocator) -> []^ast.Call_Expr {
	found := make([dynamic]^ast.Call_Expr, allocator)
	if expr == nil do return found[:]
	visitor := ast.Visitor {
		visit = call_collect_visit,
		data  = &found,
	}
	ast.walk(&visitor, expr)
	return found[:]
}

@(private = "file")
call_collect_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	found := cast(^[dynamic]^ast.Call_Expr)v.data
	if call, ok := node.derived.(^ast.Call_Expr); ok do append(found, call)
	return v
}

// expr_calls_named reports whether a call to `name` sits under `expr`.
expr_calls_named :: proc(expr: ^ast.Expr, name: string) -> bool {
	for call in expr_calls(expr) {
		_, callee := callee_name(call)
		if callee == name do return true
	}
	return false
}

// callee_has_prefix / callee_has_suffix test the unqualified callee name.
callee_has_prefix :: proc(call: ^ast.Call_Expr, prefix: string) -> bool {
	_, name := callee_name(call)
	return name != "" && strings.has_prefix(name, prefix)
}

callee_has_suffix :: proc(call: ^ast.Call_Expr, suffix: string) -> bool {
	_, name := callee_name(call)
	return name != "" && strings.has_suffix(name, suffix)
}

// callee_is reports whether the unqualified callee name is one of `names`.
callee_is :: proc(call: ^ast.Call_Expr, names: []string) -> bool {
	_, name := callee_name(call)
	if name == "" do return false
	for candidate in names do if name == candidate do return true
	return false
}

// node_contains reports whether `inner` lies within `outer`'s source span.
node_contains :: proc(outer, inner: ^ast.Node) -> bool {
	if outer == nil || inner == nil do return false
	return inner.pos.offset >= outer.pos.offset && inner.end.offset <= outer.end.offset
}

// block_stmts returns the statements of a block, or a single-statement
// slice for `do stmt` bodies.
block_stmts :: proc(stmt: ^ast.Stmt) -> []^ast.Stmt {
	if stmt == nil do return nil
	if block, ok := stmt.derived_stmt.(^ast.Block_Stmt); ok do return block.stmts
	return nil
}

// stmt_exits reports whether `stmt` is, or is a block containing at top
// level, a return/break/continue.
stmt_exits :: proc(stmt: ^ast.Stmt) -> bool {
	if stmt == nil do return false
	if stmt_is_exit(stmt) do return true
	if block, ok := stmt.derived_stmt.(^ast.Block_Stmt); ok {
		for inner in block.stmts do if stmt_is_exit(inner) do return true
	}
	return false
}

@(private = "file")
stmt_is_exit :: proc(stmt: ^ast.Stmt) -> bool {
	if stmt == nil do return false
	#partial switch _ in stmt.derived_stmt {
	case ^ast.Return_Stmt, ^ast.Branch_Stmt:
		return true
	}
	return false
}

// Index_Lookup is a `v, ok := m[k]` comma-ok map lookup: the declaration's
// single value is an index expression bound to two names.
is_comma_ok_lookup :: proc(decl: ^ast.Value_Decl) -> (index: ^ast.Index_Expr, ok: bool) {
	if decl == nil || len(decl.names) != 2 || len(decl.values) != 1 do return
	index, ok = decl.values[0].derived_expr.(^ast.Index_Expr)
	return
}

// decl_single_name returns the identifier of a one-name declaration.
decl_single_name :: proc(decl: ^ast.Value_Decl) -> string {
	if decl == nil || len(decl.names) != 1 do return ""
	ident, ok := decl.names[0].derived_expr.(^ast.Ident)
	return ok ? ident.name : ""
}

// decl_names lists every identifier a declaration binds.
decl_names :: proc(decl: ^ast.Value_Decl, allocator := context.temp_allocator) -> []string {
	names := make([dynamic]string, allocator)
	if decl == nil do return names[:]
	for name_expr in decl.names {
		if ident, ok := name_expr.derived_expr.(^ast.Ident); ok do append(&names, ident.name)
	}
	return names[:]
}

// decl_call returns the call a declaration's single value is, if any.
decl_call :: proc(decl: ^ast.Value_Decl) -> (call: ^ast.Call_Expr, ok: bool) {
	if decl == nil || len(decl.values) != 1 do return
	call, ok = expr_unparen(decl.values[0]).derived_expr.(^ast.Call_Expr)
	return
}

// assign_call returns the call an assignment's single rhs is, if any.
assign_call :: proc(assign: ^ast.Assign_Stmt) -> (call: ^ast.Call_Expr, ok: bool) {
	if assign == nil || len(assign.rhs) != 1 do return
	call, ok = expr_unparen(assign.rhs[0]).derived_expr.(^ast.Call_Expr)
	return
}

// assign_lhs_names lists the leaf names an assignment writes.
assign_lhs_leaves :: proc(
	assign: ^ast.Assign_Stmt,
	allocator := context.temp_allocator,
) -> []string {
	names := make([dynamic]string, allocator)
	if assign == nil do return names[:]
	for target in assign.lhs do append(&names, leaf_ident(target))
	return names[:]
}

// proc_is_c reports a `proc "c"` calling convention; the parser keeps the
// literal's quotes in the convention string.
proc_is_c :: proc(lit: ^ast.Proc_Lit) -> bool {
	if lit == nil || lit.type == nil do return false
	convention, ok := lit.type.calling_convention.(string)
	if !ok || len(convention) < 2 do return false
	name := convention[1:len(convention) - 1]
	return name == "c" || name == "cdecl"
}

// Expr_Facts summarises an expression subtree for the loop-bound predicate.
Expr_Facts :: struct {
	has_ordering:   bool, // < <= > >= !=
	has_comparison: bool, // the above plus ==
	has_len_or_cap: bool,
	has_time_ident: bool,
}

expr_facts :: proc(expr: ^ast.Expr) -> Expr_Facts {
	facts: Expr_Facts
	if expr == nil do return facts
	visitor := ast.Visitor {
		visit = expr_facts_visit,
		data  = &facts,
	}
	ast.walk(&visitor, expr)
	return facts
}

@(private = "file")
expr_facts_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	facts := cast(^Expr_Facts)v.data
	#partial switch derived in node.derived {
	case ^ast.Binary_Expr:
		#partial switch derived.op.kind {
		case .Lt, .Gt, .Lt_Eq, .Gt_Eq, .Not_Eq:
			facts.has_ordering = true
			facts.has_comparison = true
		case .Cmp_Eq:
			facts.has_comparison = true
		}
	case ^ast.Call_Expr:
		_, name := callee_name(derived)
		if name == "len" || name == "cap" do facts.has_len_or_cap = true
	case ^ast.Ident:
		if is_time_ident(derived.name) do facts.has_time_ident = true
	case ^ast.Selector_Expr:
		if derived.field != nil && is_time_ident(derived.field.name) do facts.has_time_ident = true
	}
	return v
}

@(private = "file")
is_time_ident :: proc(name: string) -> bool {
	for candidate in TIME_IDENTS {
		if strings.equal_fold(name, candidate) do return true
	}
	return false
}

TIME_IDENTS := [?]string{"time", "timeout", "deadline", "elapsed", "duration", "since"}

// is_type_expr reports whether a declaration value is a type (so a call on
// the declared name is a pure conversion rather than a procedure call).
is_type_expr :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	#partial switch node in expr.derived_expr {
	case ^ast.Distinct_Type,
	     ^ast.Struct_Type,
	     ^ast.Enum_Type,
	     ^ast.Union_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Bit_Field_Type,
	     ^ast.Matrix_Type,
	     ^ast.Map_Type,
	     ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Helper_Type,
	     ^ast.Typeid_Type:
		return true
	case ^ast.Ident:
		return is_basic_type_name(node.name)
	}
	return false
}

is_basic_type_name :: proc(name: string) -> bool {
	for candidate in BASIC_TYPE_NAMES {
		if name == candidate do return true
	}
	return false
}

BASIC_TYPE_NAMES := [?]string {
	"bool",
	"b8",
	"b16",
	"b32",
	"b64",
	"int",
	"uint",
	"i8",
	"i16",
	"i32",
	"i64",
	"i128",
	"u8",
	"u16",
	"u32",
	"u64",
	"u128",
	"uintptr",
	"f16",
	"f32",
	"f64",
	"rune",
	"string",
	"cstring",
	"rawptr",
}

// expr_source returns the source text of a node with whitespace collapsed to
// single spaces, for messages that quote what the author wrote.
expr_source :: proc(source: ^Source, node: ^ast.Node, allocator := context.allocator) -> string {
	assert(source != nil, "expr_source: nil source")
	assert(node != nil, "expr_source: nil node")
	start := clamp(node.pos.offset, 0, len(source.text))
	end := clamp(node.end.offset, start, len(source.text))
	fields := strings.fields(source.text[start:end], context.temp_allocator)
	return strings.join(fields, " ", allocator)
}

// line_directive parses a full-line `// tigerstyle: ...` comment on 1-based
// `line`; ok is false when the line is not such a comment.
line_directive :: proc(source: ^Source, line: int) -> (kind, rationale: string, ok: bool) {
	assert(source != nil, "line_directive: nil source")
	if line < 1 || line > len(source.lines) do return
	text := strings.trim_space(source.lines[line - 1])
	if !strings.has_prefix(text, "//") do return
	return tigerstyle_directive(text[2:])
}

// expr_has_expr reports whether `needle` occurs under `hay`: by identifier
// or selector-field name when `needle` is a bare identifier, otherwise by
// collapsed source text (core:odin/ast has no structural equality).
expr_has_expr :: proc(source: ^Source, hay, needle: ^ast.Expr) -> bool {
	if hay == nil || needle == nil do return false
	if ident, ok := expr_unparen(needle).derived_expr.(^ast.Ident); ok {
		return expr_mentions(hay, ident.name)
	}
	probe := Expr_Text_Probe {
		source = source,
		text   = expr_source(source, needle, context.temp_allocator),
	}
	visitor := ast.Visitor {
		visit = expr_text_probe_visit,
		data  = &probe,
	}
	ast.walk(&visitor, hay)
	return probe.found
}

@(private = "file")
Expr_Text_Probe :: struct {
	source: ^Source,
	text:   string,
	found:  bool,
}

@(private = "file")
expr_text_probe_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	probe := cast(^Expr_Text_Probe)v.data
	if probe.found do return nil
	#partial switch _ in node.derived {
	case ^ast.Ident,
	     ^ast.Selector_Expr,
	     ^ast.Index_Expr,
	     ^ast.Call_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Paren_Expr,
	     ^ast.Binary_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Basic_Lit:
		if expr_source(probe.source, node, context.temp_allocator) == probe.text do probe.found = true
	}
	return v
}

// node_mentions reports whether `name` appears as an identifier or selector
// field anywhere under `node` (statement or expression).
node_mentions :: proc(source: ^Source, node: ^ast.Node, name: string) -> bool {
	if node == nil || name == "" do return false
	probe := Expr_Mention {
		name = name,
	}
	visitor := ast.Visitor {
		visit = expr_mention_visit,
		data  = &probe,
	}
	ast.walk(&visitor, node)
	return probe.found
}

stmt_mentions :: proc(source: ^Source, stmt: ^ast.Stmt, name: string) -> bool {
	return node_mentions(source, stmt, name)
}

// node_calls lists every call under `node`.
node_calls :: proc(node: ^ast.Node, allocator := context.temp_allocator) -> []^ast.Call_Expr {
	found := make([dynamic]^ast.Call_Expr, allocator)
	if node == nil do return found[:]
	visitor := ast.Visitor {
		visit = call_collect_visit,
		data  = &found,
	}
	ast.walk(&visitor, node)
	return found[:]
}

stmt_calls_named :: proc(stmt: ^ast.Stmt, name: string) -> bool {
	for call in node_calls(stmt) {
		_, callee := callee_name(call)
		if callee == name do return true
	}
	return false
}
