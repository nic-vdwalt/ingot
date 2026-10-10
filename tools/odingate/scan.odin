package odingate

import "core:odin/ast"
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

// Expr_Collector gathers nodes of interest while walking; rules fill it with
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
	calls:   [dynamic]^ast.Call_Expr,
	loops:   [dynamic]^ast.Node,
	assigns: [dynamic]^ast.Assign_Stmt,
	idents:  [dynamic]^ast.Ident,
}

body_scan :: proc(root: ^ast.Node, allocator := context.allocator) -> Body_Scan {
	assert(root != nil, "body_scan: nil root")
	scan := Body_Scan {
		calls   = make([dynamic]^ast.Call_Expr, allocator),
		loops   = make([dynamic]^ast.Node, allocator),
		assigns = make([dynamic]^ast.Assign_Stmt, allocator),
		idents  = make([dynamic]^ast.Ident, allocator),
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
	}
	return v
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
