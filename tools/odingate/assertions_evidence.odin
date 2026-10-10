package odingate

import "core:odin/ast"
import "core:strings"

// Evidence predicates for the assertions rule. Each mirrors one function in
// scripts/check_assertions.py and judges only the risk it is passed; the
// discharge cascade in assert_discharged combines them in the same order.

@(private = "file")
S :: proc(parts: ..string) -> []string {
	out := make([]string, len(parts), context.temp_allocator)
	copy(out, parts)
	return out
}

// --- shared AST queries ---------------------------------------------------

// assert_before reports whether `node` starts before the operation.
@(private = "file")
assert_before :: proc(node: ^ast.Node, op: Index_Op) -> bool {
	return node != nil && op.node != nil && node.pos.offset < op.node.pos.offset
}

// assert_local_block returns the innermost block containing the operation;
// evidence inside it is "local" in the sense matching_block_prefix() used.
@(private = "file")
assert_local_block :: proc(body: ^Proc_Body, op: Index_Op) -> ^ast.Block_Stmt {
	best: ^ast.Block_Stmt
	for block in body.scan.blocks {
		if !node_contains(block, op.node) do continue
		if best == nil || node_contains(best, block) do best = block
	}
	return best
}

// assert_is_len_of reports `len(target)`/`cap(target)` for the op's target.
@(private = "file")
assert_is_len_of :: proc(body: ^Proc_Body, expr: ^ast.Expr, target: string) -> bool {
	arg, ok := expr_is_len_call(expr)
	if !ok do return false
	return expr_source(body.source, arg, context.temp_allocator) == target
}

// assert_int_literal returns the value of an integer literal expression.
@(private = "file")
assert_int_literal :: proc(expr: ^ast.Expr) -> (value: int, ok: bool) {
	if expr == nil do return
	lit, is_lit := expr_unparen(expr).derived_expr.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .Integer do return
	return parse_uint(lit.tok.text)
}

// assert_is_upper_const reports an UPPER_CASE identifier (a named constant).
@(private = "file")
assert_is_upper_const :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	ident, ok := expr_unparen(expr).derived_expr.(^ast.Ident)
	return ok && is_upper_const(ident.name)
}

// assert_cond_orders_expr: `cond` contains an ordering comparison with
// `needle` on either side.
@(private = "file")
assert_cond_orders_expr :: proc(body: ^Proc_Body, cond, needle: ^ast.Expr) -> bool {
	for binary in expr_binaries(cond, is_ordering_op) {
		if expr_has_expr(body.source, binary.left, needle) do return true
		if expr_has_expr(body.source, binary.right, needle) do return true
	}
	return false
}

// assert_cond_upper_bounds: `cond` orders the index expression against
// `len(target)` or a named constant (`i < len(xs)`, `i < MAX`).
@(private = "file")
assert_cond_upper_bounds :: proc(body: ^Proc_Body, cond: ^ast.Expr, op: Index_Op) -> bool {
	for binary in expr_binaries(cond, is_ordering_op) {
		left_e := expr_has_expr(body.source, binary.left, op.index_expr)
		right_e := expr_has_expr(body.source, binary.right, op.index_expr)
		if !left_e && !right_e do continue
		other := left_e ? binary.right : binary.left
		if assert_is_len_of(body, other, op.target) do return true
		if assert_is_upper_const(other) do return true
	}
	return false
}

// assert_binding_of returns the single value bound to `name` by a `:=`
// declaration or `=` assignment that starts before the operation.
@(private = "file")
assert_bindings_of :: proc(
	body: ^Proc_Body,
	name: string,
	op: Index_Op,
	allocator := context.temp_allocator,
) -> []^ast.Expr {
	values := make([dynamic]^ast.Expr, allocator)
	for decl in body.scan.decls {
		if !assert_before(decl, op) || len(decl.values) != 1 do continue
		if decl_single_name(decl) == name do append(&values, decl.values[0])
	}
	for assign in body.scan.assigns {
		if !assert_before(assign, op) || len(assign.lhs) != 1 || len(assign.rhs) != 1 do continue
		if expr_source(body.source, assign.lhs[0], context.temp_allocator) == name {
			append(&values, assign.rhs[0])
		}
	}
	return values[:]
}

// assert_if_exits_on: an `if` before the operation whose condition satisfies
// `accept` and whose then-branch returns, breaks, or continues.
@(private = "file")
assert_guard_before :: proc(
	body: ^Proc_Body,
	op: Index_Op,
	accept: proc(body: ^Proc_Body, cond: ^ast.Expr, op: Index_Op) -> bool,
) -> bool {
	for if_stmt in body.scan.ifs {
		if !assert_before(if_stmt, op) do continue
		if accept(body, if_stmt.cond, op) && stmt_exits(if_stmt.body) do return true
	}
	return false
}

// assert_range_over: a `for e in ...` before the op iterating `e`; when
// `over_len` is set the range must be `0 ..< len(target)`.
@(private = "file")
assert_range_over :: proc(body: ^Proc_Body, op: Index_Op, over_len: bool) -> bool {
	for loop in body.scan.loops {
		if !assert_before(loop, op) do continue
		range, ok := loop.derived.(^ast.Range_Stmt)
		if !ok || len(range.vals) == 0 do continue
		if expr_source(body.source, range.vals[0], context.temp_allocator) != op.expression do continue
		if !over_len do return true
		bounds, is_binary := expr_unparen(range.expr).derived_expr.(^ast.Binary_Expr)
		if !is_binary || bounds.op.kind != .Range_Half do continue
		if low, is_int := assert_int_literal(bounds.left); !is_int || low != 0 do continue
		if assert_is_len_of(body, bounds.right, op.target) do return true
	}
	return false
}

// --- index ----------------------------------------------------------------

@(private = "file")
assert_element_index_proven :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	if assert_range_over(body, op, true) do return true
	for assertion in body.assertions {
		if assertion.offset >= op.node.pos.offset do continue
		if assert_cond_upper_bounds(body, assertion.cond, op) do return true
		if assert_cond_orders_expr(body, assertion.cond, op.index_expr) do return true
		if assert_cond_orders_expr(body, assertion.cond, op.target_expr) do return true
	}
	for if_stmt in body.scan.ifs {
		if !assert_before(if_stmt, op) do continue
		if assert_cond_upper_bounds(body, if_stmt.cond, op) do return true
	}
	if assert_resolved_by_call(body, op) &&
	   assert_guard_before(body, op, assert_cond_negative_index) {
		return true
	}
	if size, fixed := assert_fixed_array_size(body, op.target); fixed {
		if constant, is_int := assert_int_literal(op.index_expr); is_int do return constant < size
	}
	if assert_modulo_of_len(body, op) {
		for binary in body.scan.binaries {
			if !assert_before(binary, op) do continue
			if binary.op.kind == .Gt && assert_is_len_of(body, binary.left, op.target) {
				if zero, ok := assert_int_literal(binary.right); ok && zero == 0 do return true
			}
			if binary.op.kind == .Lt && assert_is_len_of(body, binary.right, op.target) {
				if zero, ok := assert_int_literal(binary.left); ok && zero == 0 do return true
			}
		}
		return false
	}
	local := assert_local_block(body, op)
	for assertion in body.assertions {
		if assertion.offset >= op.node.pos.offset || !node_contains(local, assertion.call) do continue
		if expr_has_expr(body.source, assertion.cond, op.index_expr) &&
		   expr_has_expr(body.source, assertion.cond, op.target_expr) {
			return true
		}
	}
	return false
}

@(private = "file")
assert_cond_negative_index :: proc(body: ^Proc_Body, cond: ^ast.Expr, op: Index_Op) -> bool {
	binary, ok := expr_unparen(cond).derived_expr.(^ast.Binary_Expr)
	if !ok || binary.op.kind != .Lt do return false
	if !expr_has_expr(body.source, binary.left, op.index_expr) do return false
	zero, is_int := assert_int_literal(binary.right)
	return is_int && zero == 0
}

// assert_resolved_by_call: the index was bound from a call before the op
// (`i := find_slot(...)`), so a sign guard is the author's bound.
@(private = "file")
assert_resolved_by_call :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	for value in assert_bindings_of(body, op.expression, op) {
		if _, is_call := expr_unparen(value).derived_expr.(^ast.Call_Expr); is_call do return true
	}
	return false
}

// assert_fixed_array_size finds `target: [N]T` among parameters and local
// declarations and returns N.
@(private = "file")
assert_fixed_array_size :: proc(body: ^Proc_Body, target: string) -> (size: int, ok: bool) {
	if body.lit.type != nil && body.lit.type.params != nil {
		for field in body.lit.type.params.list {
			for name_expr in field.names {
				ident, is_ident := name_expr.derived_expr.(^ast.Ident)
				if !is_ident || ident.name != target do continue
				if size, ok = assert_array_type_len(field.type); ok do return
			}
		}
	}
	for decl in body.scan.decls {
		if decl.type == nil do continue
		for name in decl_names(decl) {
			if name != target do continue
			if size, ok = assert_array_type_len(decl.type); ok do return
		}
	}
	return
}

@(private = "file")
assert_array_type_len :: proc(type: ^ast.Expr) -> (size: int, ok: bool) {
	if type == nil do return
	array, is_array := type.derived_expr.(^ast.Array_Type)
	if !is_array || array.len == nil do return
	return assert_int_literal(array.len)
}

// assert_modulo_of_len reports an index of the form `x % len(target)`.
@(private = "file")
assert_modulo_of_len :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	if op.index_expr == nil do return false
	binary, ok := expr_unparen(op.index_expr).derived_expr.(^ast.Binary_Expr)
	if !ok || binary.op.kind != .Mod do return false
	return assert_is_len_of(body, binary.right, op.target)
}

// assert_bound_stated: a comparison `left <= right` (or `right >= left`)
// anywhere before the operation.
@(private = "file")
assert_le_before :: proc(body: ^Proc_Body, op: Index_Op, left, right: string) -> bool {
	for binary in body.scan.binaries {
		if !assert_before(binary, op) do continue
		l := expr_source(body.source, binary.left, context.temp_allocator)
		r := expr_source(body.source, binary.right, context.temp_allocator)
		if binary.op.kind == .Lt_Eq && l == left && r == right do return true
		if binary.op.kind == .Gt_Eq && l == right && r == left do return true
	}
	return false
}

@(private = "file")
assert_slice_index_proven :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	assert(op.kind == .Slice, "assert_slice_index_proven: not a slice")
	if op.low == nil && op.high == nil do return true
	if op.low == nil && assert_is_len_of(body, op.high, op.target) do return true
	low := op.low != nil ? expr_source(body.source, op.low, context.temp_allocator) : ""
	high := op.high != nil ? expr_source(body.source, op.high, context.temp_allocator) : ""
	len_target := strings.concatenate({"len(", op.target, ")"}, context.temp_allocator)
	ok := true
	if op.low != nil do ok &&= assert_le_before(body, op, "0", low)
	if op.low != nil && op.high != nil do ok &&= assert_le_before(body, op, low, high)
	if op.high != nil do ok &&= assert_le_before(body, op, high, len_target)
	if ok do return true
	if op.high != nil && assert_is_min_clamp_of_len(body, op.high, op.target) {
		return op.low == nil || assert_le_before(body, op, "0", low)
	}
	return false
}

// assert_is_min_clamp_of_len: `min(.., len(target))` / `clamp(.., len(target))`.
@(private = "file")
assert_is_min_clamp_of_len :: proc(body: ^Proc_Body, high: ^ast.Expr, target: string) -> bool {
	call, ok := expr_unparen(high).derived_expr.(^ast.Call_Expr)
	if !ok || !callee_is(call, {"min", "clamp"}) do return false
	for arg in call.args do if assert_is_len_of(body, arg, target) do return true
	return false
}

@(private = "file")
assert_index_contract_present :: proc(body: ^Proc_Body) -> bool {
	if len(body.ops) == 0 do return false
	for op in body.ops {
		if op.kind == .Slice {
			if !assert_slice_index_proven(body, op) do return false
		} else if !assert_element_index_proven(body, op) {
			return false
		}
	}
	return true
}

// --- authored assertions --------------------------------------------------

ASSERT_QUEUE_WORDS := [?]string{"count", "head", "tail"}
ASSERT_OWNERSHIP_WORDS := [?]string{"nil", "owner", "owned", "allocator"}
ASSERT_STATE_CONTRACT_WORDS := [?]string{"state", "running", "active", "session", "frame", "open"}
ASSERT_UNTRUSTED_WORDS := [?]string {
	"count",
	"size",
	"offset",
	"cursor",
	"parsed",
	"status",
	"ok",
	"err",
}

// assert_cond_has_len_call: a `len(..)`/`cap(..)` call under `cond`.
@(private = "file")
assert_cond_has_len_call :: proc(cond: ^ast.Expr) -> bool {
	return expr_calls_named(cond, "len") || expr_calls_named(cond, "cap")
}

@(private = "file")
assert_authored_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	if len(body.assertions) == 0 do return false
	for assertion in body.assertions {
		cond := assertion.cond
		switch risk {
		case .Pointer:
			if expr_has_nil_compare(cond) do return true
		case .Index:
			for binary in expr_binaries(cond, is_ordering_op) {
				if assert_cond_has_len_call(binary.right) || assert_is_upper_const(binary.right) do return true
				if assert_cond_has_len_call(binary.left) || assert_is_upper_const(binary.left) do return true
			}
		case .Queue:
			if expr_mentions_any(cond, ASSERT_QUEUE_WORDS[:]) do return true
			if assert_cond_has_len_call(cond) do return true
		case .Ownership:
			if expr_mentions_any(cond, ASSERT_OWNERSHIP_WORDS[:]) do return true
			if assert_cond_has_len_call(cond) do return true
		case .State:
			if expr_mentions_any(cond, ASSERT_STATE_CONTRACT_WORDS[:]) do return true
		case .Untrusted_Input:
			if expr_mentions_any(cond, ASSERT_UNTRUSTED_WORDS[:]) do return true
			if assert_cond_has_len_call(cond) do return true
		}
	}
	return false
}

// --- structural -----------------------------------------------------------

ASSERT_RELEASE_CALLS := [?]string{"delete", "free", "destroy"}
ASSERT_ALLOC_CALLS := [?]string{"make", "new", "clone", "resize"}
ASSERT_OWNERSHIP_GUARD_WORDS := [?]string{"nil", "ok", "err", "result"}
ASSERT_FAILURE_WORDS := [?]string{"last_error", "error", "fault"}
ASSERT_UNTRUSTED_GUARD_WORDS := [?]string {
	"len",
	"count",
	"size",
	"offset",
	"cursor",
	"parsed",
	"status",
	"ok",
	"err",
}

// assert_guard_conds lists every `if` and assertion condition in the body.
@(private = "file")
assert_guard_conds :: proc(body: ^Proc_Body, allocator := context.temp_allocator) -> []^ast.Expr {
	conds := make([dynamic]^ast.Expr, allocator)
	for if_stmt in body.scan.ifs do append(&conds, if_stmt.cond)
	for assertion in body.assertions do if assertion.cond != nil do append(&conds, assertion.cond)
	return conds[:]
}

// assert_cond_compares_word: a comparison with `word` mentioned on a side.
@(private = "file")
assert_cond_compares_word :: proc(cond: ^ast.Expr, word: string, ordering_only: bool) -> bool {
	accept := ordering_only ? is_ordering_op : is_comparison_op
	for binary in expr_binaries(cond, accept) {
		if expr_mentions(binary.left, word) || expr_mentions(binary.right, word) do return true
	}
	return false
}

// assert_cond_compares_len: `len(..)`/`cap(..)` as a comparison operand.
@(private = "file")
assert_cond_compares_len :: proc(cond: ^ast.Expr, ordering_only: bool) -> bool {
	accept := ordering_only ? is_ordering_op : is_comparison_op
	for binary in expr_binaries(cond, accept) {
		for side in ([?]^ast.Expr{binary.left, binary.right}) {
			if _, ok := expr_is_len_call(side); ok do return true
		}
	}
	return false
}

// assert_writes_leaf: an assignment to a target whose leaf name is `word`.
@(private = "file")
assert_writes_leaf :: proc(body: ^Proc_Body, word: string) -> bool {
	for assign in body.scan.assigns {
		for leaf in assign_lhs_leaves(assign) do if leaf == word do return true
	}
	return false
}

// assert_writes_any_leaf: any of `words` is assigned.
@(private = "file")
assert_writes_any_leaf :: proc(body: ^Proc_Body, words: []string) -> bool {
	for word in words do if assert_writes_leaf(body, word) do return true
	return false
}

// assert_defer_or_if_mentions: a `defer` statement or `if` condition
// mentioning `word`.
@(private = "file")
assert_defer_or_if_mentions :: proc(body: ^Proc_Body, word: string) -> bool {
	for if_stmt in body.scan.ifs do if expr_mentions(if_stmt.cond, word) do return true
	for defer_stmt in body.scan.defers {
		if stmt_mentions(body.source, defer_stmt.stmt, word) do return true
	}
	return false
}

@(private = "file")
assert_defer_or_if_has_len :: proc(body: ^Proc_Body) -> bool {
	for if_stmt in body.scan.ifs {
		if expr_calls_named(if_stmt.cond, "len") || expr_calls_named(if_stmt.cond, "cap") do return true
	}
	for defer_stmt in body.scan.defers {
		if stmt_calls_named(defer_stmt.stmt, "len") do return true
		if stmt_calls_named(defer_stmt.stmt, "cap") do return true
	}
	return false
}

// assert_param_passed_to_call: `param` is a bare argument of some call.
@(private = "file")
assert_param_passed_to_call :: proc(body: ^Proc_Body, param: string) -> bool {
	for call in body.scan.calls {
		for arg in call.args {
			ident, ok := expr_unparen(arg).derived_expr.(^ast.Ident)
			if ok && ident.name == param do return true
		}
	}
	return false
}

// assert_nil_asserted: an assertion comparing `name` with nil.
@(private = "file")
assert_nil_asserted :: proc(body: ^Proc_Body, name: string) -> bool {
	for assertion in body.assertions {
		for binary in expr_binaries(assertion.cond, is_comparison_op) {
			operand, ok := expr_nil_compare(binary)
			if ok && expr_mentions(operand, name) do return true
		}
	}
	return false
}

// assert_any_if_nil_compare: an `if` statement or `x if c else y`
// expression whose condition compares with nil.
@(private = "file")
assert_any_if_nil_compare :: proc(body: ^Proc_Body) -> bool {
	for if_stmt in body.scan.ifs do if expr_has_nil_compare(if_stmt.cond) do return true
	for ternary in body.scan.ternaries do if expr_has_nil_compare(ternary.cond) do return true
	return false
}

@(private = "file")
assert_structural_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	switch risk {
	case .Index:
		if len(body.ops) == 0 do return true
		for op in body.ops do if !assert_structural_index(body, op) do return false
		return true
	case .Pointer:
		if len(body.pointer_params) > 0 {
			for param in body.pointer_params {
				if assert_nil_asserted(body, param) do continue
				if !assert_param_passed_to_call(body, param) do return false
			}
			return true
		}
		if assert_any_if_nil_compare(body) do return true
		return !assert_has_transmute(body) && !assert_calls_any(body, ASSERT_RAW_POINTER_CALLS[:])
	case .Queue:
		if assert_bounded_push(body) do return true
		for cond in assert_guard_conds(body) {
			for word in ASSERT_QUEUE_WORDS do if assert_cond_compares_word(cond, word, false) do return true
			if assert_cond_compares_len(cond, false) do return true
		}
		return false
	case .Ownership:
		for word in ASSERT_OWNERSHIP_GUARD_WORDS {
			if assert_defer_or_if_mentions(body, word) do return true
		}
		if assert_defer_or_if_has_len(body) do return true
		return !assert_calls_any(body, ASSERT_RELEASE_CALLS[:])
	case .State:
		guarded := false
		for cond in assert_guard_conds(body) {
			for word in ASSERT_STATE_CONTRACT_WORDS {
				if assert_cond_compares_word(cond, word, false) do guarded = true
			}
		}
		transition := assert_writes_any_leaf(body, ASSERT_STATE_WORDS[:])
		failure := assert_writes_any_leaf(body, ASSERT_FAILURE_WORDS[:])
		return guarded || !transition || failure
	case .Untrusted_Input:
		for if_stmt in body.scan.ifs {
			for word in ASSERT_UNTRUSTED_GUARD_WORDS {
				if assert_cond_compares_word(if_stmt.cond, word, false) do return true
			}
		}
		return false
	}
	return false
}

// assert_bounded_push: `if !x_reserve(...) do return` style guards — an `if`
// whose condition calls something named reserve/append/push and exits.
@(private = "file")
assert_bounded_push :: proc(body: ^Proc_Body) -> bool {
	for if_stmt in body.scan.ifs {
		if !stmt_exits(if_stmt.body) do continue
		for call in expr_calls(if_stmt.cond) {
			_, name := callee_name(call)
			if strings.contains(name, "reserve") ||
			   strings.contains(name, "append") ||
			   strings.contains(name, "push") {
				return true
			}
		}
	}
	return false
}

@(private = "file")
assert_structural_index :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	if op.kind == .Slice do return true
	index := expr_unparen(op.index_expr)
	if _, is_int := assert_int_literal(index); is_int do return true
	if assert_is_upper_const(index) do return true
	if call, is_call := index.derived_expr.(^ast.Call_Expr); is_call {
		if callee_is(call, {"int", "i32", "u32"}) && len(call.args) == 1 do return true
	}
	if binary, is_binary := index.derived_expr.(^ast.Binary_Expr);
	   is_binary && binary.op.kind == .Mod {
		return true
	}
	if ident, is_ident := index.derived_expr.(^ast.Ident); is_ident {
		name := ident.name
		for value in assert_bindings_of(body, name, op) {
			if call, is_call := expr_unparen(value).derived_expr.(^ast.Call_Expr); is_call {
				if callee_is(call, {"clamp", "min", "max"}) do return true
				if callee_has_suffix(call, "index") ||
				   callee_has_suffix(call, "slot") ||
				   callee_has_suffix(call, "range") {
					return true
				}
			}
		}
		if assert_tested_before(body, op, name) && assert_target_mentioned_before(body, op) do return true
		if assert_membership_before(body, op, name) do return true
		if assert_comma_ok_lookup_before(body, op, name) do return true
	}
	for if_stmt in body.scan.ifs {
		binary, ok := expr_unparen(if_stmt.cond).derived_expr.(^ast.Binary_Expr)
		if !ok || (binary.op.kind != .Lt && binary.op.kind != .Gt_Eq) do continue
		if expr_has_expr(body.source, binary.left, op.index_expr) &&
		   expr_has_expr(body.source, binary.right, op.target_expr) {
			return true
		}
	}
	return assert_range_over(body, op, false)
}

// assert_tested_before: an `if` or loop condition before the op mentions the
// index name.
@(private = "file")
assert_tested_before :: proc(body: ^Proc_Body, op: Index_Op, name: string) -> bool {
	for if_stmt in body.scan.ifs {
		if assert_before(if_stmt, op) && expr_mentions(if_stmt.cond, name) do return true
	}
	for loop in body.scan.loops {
		if !assert_before(loop, op) do continue
		#partial switch stmt in loop.derived {
		case ^ast.For_Stmt:
			if expr_mentions(stmt.cond, name) do return true
		case ^ast.Range_Stmt:
			for value in stmt.vals do if expr_mentions(value, name) do return true
		}
	}
	return false
}

// assert_target_mentioned_before: the target appears anywhere before the op.
@(private = "file")
assert_target_mentioned_before :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	leaf := leaf_of_dotted(op.target)
	for ident in body.scan.idents {
		if ident.pos.offset < op.node.pos.offset && ident.name == leaf do return true
	}
	return false
}

// assert_membership_before: `name in target` / `name not_in target` (or the
// target's leaf field) before the op.
@(private = "file")
assert_membership_before :: proc(body: ^Proc_Body, op: Index_Op, name: string) -> bool {
	leaf := leaf_of_dotted(op.target)
	for binary in body.scan.binaries {
		if !assert_before(binary, op) do continue
		if binary.op.kind != .In && binary.op.kind != .Not_In do continue
		if !expr_mentions(binary.left, name) do continue
		right := expr_source(body.source, binary.right, context.temp_allocator)
		if right == op.target || leaf_ident(binary.right) == leaf do return true
	}
	return false
}

// assert_comma_ok_lookup_before: `v, ok := target[name]` before the op.
@(private = "file")
assert_comma_ok_lookup_before :: proc(body: ^Proc_Body, op: Index_Op, name: string) -> bool {
	for decl in body.scan.decls {
		if !assert_before(decl, op) do continue
		lookup, ok := is_comma_ok_lookup(decl)
		if !ok do continue
		if expr_source(body.source, lookup.expr, context.temp_allocator) != op.target do continue
		if expr_source(body.source, lookup.index, context.temp_allocator) == name do return true
	}
	for assign in body.scan.assigns {
		if !assert_before(assign, op) || len(assign.lhs) != 2 || len(assign.rhs) != 1 do continue
		lookup, ok := expr_unparen(assign.rhs[0]).derived_expr.(^ast.Index_Expr)
		if !ok do continue
		if expr_source(body.source, lookup.expr, context.temp_allocator) != op.target do continue
		if expr_source(body.source, lookup.index, context.temp_allocator) == name do return true
	}
	return false
}

// --- risk contracts -------------------------------------------------------

// Assert_Contract is one guard the text version collected as a "contract
// line": an assertion condition, an if/when/loop condition, or a deferred
// statement. Exactly one of `expr`/`stmt` is set.
@(private = "file")
Assert_Contract :: struct {
	expr: ^ast.Expr,
	stmt: ^ast.Stmt,
}

@(private = "file")
assert_contract_node :: proc(contract: Assert_Contract) -> ^ast.Node {
	if contract.expr != nil do return contract.expr
	return contract.stmt
}

// assert_contract_nodes lists the conditions of assertions, ifs, whens,
// loops, and the statements of defers.
@(private = "file")
assert_contract_nodes :: proc(
	body: ^Proc_Body,
	allocator := context.temp_allocator,
) -> []Assert_Contract {
	nodes := make([dynamic]Assert_Contract, allocator)
	for assertion in body.assertions {
		if assertion.cond != nil do append(&nodes, Assert_Contract{expr = assertion.cond})
	}
	for if_stmt in body.scan.ifs do append(&nodes, Assert_Contract{expr = if_stmt.cond})
	for when_stmt in body.scan.whens do append(&nodes, Assert_Contract{expr = when_stmt.cond})
	for loop in body.scan.loops {
		#partial switch stmt in loop.derived {
		case ^ast.For_Stmt:
			if stmt.cond != nil do append(&nodes, Assert_Contract{expr = stmt.cond})
		case ^ast.Range_Stmt:
			append(&nodes, Assert_Contract{expr = stmt.expr})
		}
	}
	for defer_stmt in body.scan.defers do append(&nodes, Assert_Contract{stmt = defer_stmt.stmt})
	return nodes[:]
}

// assert_contract_mentions: some contract mentions every one of `words`.
@(private = "file")
assert_contract_mentions :: proc(body: ^Proc_Body, words: []string) -> bool {
	for contract in assert_contract_nodes(body) {
		node := assert_contract_node(contract)
		all := true
		for word in words do if !node_mentions(body.source, node, word) do all = false
		if all do return true
	}
	return false
}

// assert_contract_compares: some contract condition compares with `word`.
@(private = "file")
assert_contract_compares :: proc(body: ^Proc_Body, word: string, ordering_only: bool) -> bool {
	for contract in assert_contract_nodes(body) {
		if contract.expr == nil do continue
		if assert_cond_compares_word(contract.expr, word, ordering_only) do return true
	}
	return false
}

@(private = "file")
assert_contract_nil_compares :: proc(body: ^Proc_Body, name: string) -> bool {
	for contract in assert_contract_nodes(body) {
		if contract.expr == nil do continue
		for binary in expr_binaries(contract.expr, is_comparison_op) {
			operand, is_nil := expr_nil_compare(binary)
			if is_nil && expr_mentions(operand, name) do return true
		}
	}
	return false
}

// assert_contract_len_of: some contract calls `len(name..)`.
@(private = "file")
assert_contract_len_of :: proc(body: ^Proc_Body, name: string) -> bool {
	for contract in assert_contract_nodes(body) {
		for call in node_calls(assert_contract_node(contract)) {
			arg, ok := expr_is_len_call(call)
			if ok && expr_mentions(arg, name) do return true
		}
	}
	return false
}

@(private = "file")
assert_pointer_contract :: proc(body: ^Proc_Body) -> bool {
	names := make([dynamic]string, context.temp_allocator)
	for cast_expr in body.scan.casts {
		if cast_expr.tok.kind != .Transmute do continue
		if name := root_ident(cast_expr.expr); name != "" do append(&names, name)
	}
	for call in body.scan.calls {
		if !callee_is(call, ASSERT_RAW_POINTER_CALLS[:]) || len(call.args) == 0 do continue
		if name := expr_source(body.source, call.args[0], context.temp_allocator); name != "" {
			append(&names, name)
		}
	}
	for param in body.pointer_params do append(&names, param)
	if len(names) == 0 do return true
	for name in names {
		leaf := leaf_of_dotted(name)
		if assert_contract_nil_compares(body, leaf) do continue
		if assert_return_guards_nil(body, leaf) do continue
		return false
	}
	return true
}

// assert_return_guards_nil: `return x != nil && ...`.
@(private = "file")
assert_return_guards_nil :: proc(body: ^Proc_Body, name: string) -> bool {
	for ret in body.scan.returns {
		for result in ret.results {
			binary, ok := expr_unparen(result).derived_expr.(^ast.Binary_Expr)
			if !ok || binary.op.kind != .Cmp_And do continue
			operand, is_nil := expr_nil_compare(binary.left)
			if is_nil && expr_mentions(operand, name) do return true
		}
	}
	return false
}

// assert_append_targets lists the `&x` targets of append calls.
@(private = "file")
assert_append_targets :: proc(body: ^Proc_Body, allocator := context.temp_allocator) -> []string {
	targets := make([dynamic]string, allocator)
	for call in body.scan.calls {
		if !callee_is(call, {"append"}) || len(call.args) == 0 do continue
		unary, ok := expr_unparen(call.args[0]).derived_expr.(^ast.Unary_Expr)
		if !ok || unary.op.kind != .And do continue
		append(&targets, expr_source(body.source, unary.expr, allocator))
	}
	return targets[:]
}

@(private = "file")
assert_queue_contract :: proc(body: ^Proc_Body) -> bool {
	if len(body.scan.dyn_types) > 0 do return true
	dynamic_targets := assert_dynamic_targets(body)
	for target in assert_append_targets(body) {
		if assert_name_in(target, dynamic_targets) do continue
		capacity := assert_contract_len_lt_cap(body, target)
		bounded := false
		for word in ([?]string{"count", "head", "tail", "capacity"}) {
			if assert_contract_mentions(body, {leaf_of_dotted(target), word}) do bounded = true
		}
		if !capacity && !bounded do return false
	}
	if assert_calls_any(body, {"ordered_remove", "unordered_remove"}) &&
	   !assert_index_contract_present(body) {
		return false
	}
	for word in ASSERT_QUEUE_WORDS {
		if !assert_writes_leaf(body, word) do continue
		if !assert_contract_compares(body, word, true) do return false
		break
	}
	return true
}

// assert_contract_len_lt_cap: `len(t) < cap(t)` in a contract node.
@(private = "file")
assert_contract_len_lt_cap :: proc(body: ^Proc_Body, target: string) -> bool {
	for contract in assert_contract_nodes(body) {
		if contract.expr == nil do continue
		for binary in expr_binaries(contract.expr, is_ordering_op) {
			if binary.op.kind != .Lt do continue
			left, is_len := expr_is_len_call(binary.left)
			right, is_cap := expr_is_len_call(binary.right)
			if !is_len || !is_cap do continue
			if expr_source(body.source, left, context.temp_allocator) == target &&
			   expr_source(body.source, right, context.temp_allocator) == target {
				return true
			}
		}
	}
	return false
}

// assert_dynamic_targets: names declared `x: [dynamic]T` or bound from
// `make([dynamic]T, ..)`.
@(private = "file")
assert_dynamic_targets :: proc(body: ^Proc_Body, allocator := context.temp_allocator) -> []string {
	targets := make([dynamic]string, allocator)
	for decl in body.scan.decls {
		is_dynamic := false
		if decl.type != nil {
			if _, ok := decl.type.derived_expr.(^ast.Dynamic_Array_Type); ok do is_dynamic = true
		}
		if call, ok := decl_call(decl); ok && assert_is_make_dynamic(call) do is_dynamic = true
		if is_dynamic do for name in decl_names(decl) do append(&targets, name)
	}
	for assign in body.scan.assigns {
		call, ok := assign_call(assign)
		if !ok || !assert_is_make_dynamic(call) do continue
		for target in assign.lhs do append(&targets, expr_source(body.source, target, allocator))
	}
	return targets[:]
}

@(private = "file")
assert_is_make_dynamic :: proc(call: ^ast.Call_Expr) -> bool {
	if !callee_is(call, {"make"}) || len(call.args) == 0 do return false
	_, ok := call.args[0].derived_expr.(^ast.Dynamic_Array_Type)
	return ok
}

@(private = "file")
assert_name_in :: proc(name: string, names: []string) -> bool {
	for candidate in names do if candidate == name do return true
	return false
}

@(private = "file")
assert_ownership_contract :: proc(body: ^Proc_Body) -> bool {
	allocations := make([dynamic]string, context.temp_allocator)
	releases := make([dynamic]string, context.temp_allocator)
	for decl in body.scan.decls {
		call, ok := decl_call(decl)
		if !ok || !callee_is(call, ASSERT_ALLOC_CALLS[:]) do continue
		for name in decl_names(decl) do append(&allocations, name)
	}
	for assign in body.scan.assigns {
		call, ok := assign_call(assign)
		if !ok || !callee_is(call, ASSERT_ALLOC_CALLS[:]) do continue
		for target in assign.lhs do append(&allocations, leaf_ident(target))
	}
	for call in body.scan.calls {
		if !callee_is(call, ASSERT_RELEASE_CALLS[:]) || len(call.args) == 0 do continue
		target := expr_unparen(call.args[0])
		if unary, ok := target.derived_expr.(^ast.Unary_Expr); ok && unary.op.kind == .And {
			target = expr_unparen(unary.expr)
		}
		append(&releases, leaf_ident(target))
	}
	contracts := assert_contract_nodes(body)
	for name in allocations {
		if name == "" do continue
		if assert_contract_mentions(body, {name, "nil"}) do continue
		if assert_contract_len_of(body, name) do continue
		if assert_contract_mentions(body, {name, "ok"}) do continue
		if assert_contract_mentions(body, {name, "err"}) do continue
		if assert_defer_mentions(body, name) do continue
		return false
	}
	for name in releases {
		if name == "" do continue
		if assert_contract_mentions(body, {name, "nil"}) do continue
		if assert_defer_mentions(body, name) do continue
		if assert_contract_mentions(body, {name, "owner"}) do continue
		if assert_contract_mentions(body, {name, "owned"}) do continue
		return false
	}
	return (len(allocations) == 0 && len(releases) == 0) || len(contracts) > 0
}

@(private = "file")
assert_defer_mentions :: proc(body: ^Proc_Body, name: string) -> bool {
	for defer_stmt in body.scan.defers {
		if stmt_mentions(body.source, defer_stmt.stmt, name) do return true
	}
	return false
}

@(private = "file")
assert_state_contract :: proc(body: ^Proc_Body) -> bool {
	for field in ASSERT_STATE_WORDS {
		if !assert_writes_leaf(body, field) do continue
		if !assert_contract_compares(body, field, false) do return false
	}
	return true
}

ASSERT_UNTRUSTED_CALL_PREFIXES := [?]string{"parse", "decode", "read", "recv"}

@(private = "file")
assert_untrusted_contract :: proc(body: ^Proc_Body) -> bool {
	for decl in body.scan.decls {
		call, ok := decl_call(decl)
		if !ok || !assert_is_untrusted_call(call) do continue
		for name in decl_names(decl) {
			if !assert_untrusted_checked(body, name) do return false
		}
	}
	for assign in body.scan.assigns {
		call, ok := assign_call(assign)
		if !ok || !assert_is_untrusted_call(call) do continue
		for target in assign.lhs {
			if !assert_untrusted_checked(body, leaf_ident(target)) do return false
		}
	}
	return true
}

@(private = "file")
assert_is_untrusted_call :: proc(call: ^ast.Call_Expr) -> bool {
	for prefix in ASSERT_UNTRUSTED_CALL_PREFIXES do if callee_has_prefix(call, prefix) do return true
	return false
}

// assert_untrusted_checked: the decoded value is compared or measured in a
// guard, or validated in the value a `return` hands to the caller
// (`return data, err == nil && len(data) > 0`).
@(private = "file")
assert_untrusted_checked :: proc(body: ^Proc_Body, name: string) -> bool {
	if name == "" do return true
	if assert_contract_compares(body, name, false) do return true
	if assert_contract_len_of(body, name) do return true
	for ret in body.scan.returns {
		for result in ret.results {
			if assert_cond_compares_word(result, name, false) do return true
			for call in expr_calls(result) {
				arg, ok := expr_is_len_call(call)
				if ok && expr_mentions(arg, name) do return true
			}
		}
	}
	return false
}

assert_risk_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	switch risk {
	case .Index:
		return assert_index_contract_present(body)
	case .Pointer:
		return assert_pointer_contract(body)
	case .Queue:
		return assert_queue_contract(body)
	case .Ownership:
		return assert_ownership_contract(body)
	case .State:
		return assert_state_contract(body)
	case .Untrusted_Input:
		return assert_untrusted_contract(body)
	}
	return false
}

// --- reviewed / inferred --------------------------------------------------

// assert_cond_compares_term: a comparison under `cond` with one side
// mentioning `term`; "len(" / "cap(" mean a call to that builtin.
@(private = "file")
assert_cond_compares_term :: proc(cond: ^ast.Expr, term: string) -> bool {
	for binary in expr_binaries(cond, is_comparison_op) {
		for side in ([?]^ast.Expr{binary.left, binary.right}) {
			if strings.has_suffix(term, "(") {
				if expr_calls_named(side, term[:len(term) - 1]) do return true
			} else if expr_mentions(side, term) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
assert_reviewed_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	if len(body.assertions) == 0 do return false
	terms: []string
	switch risk {
	case .Pointer:
		terms = S("nil")
	case .Index:
		terms = S("len(", "cap(")
	case .Queue:
		terms = S("len(", "cap(", "count", "head", "tail")
	case .Ownership:
		terms = S("nil", "len(", "cap(", "owner", "owned", "allocator")
	case .State:
		terms = S("state", "running", "active", "session", "frame", "open")
	case .Untrusted_Input:
		terms = S("len(", "ok", "err", "result", "status", "parsed")
	}
	for assertion in body.assertions {
		for term in terms do if assert_cond_compares_term(assertion.cond, term) do return true
	}
	return false
}

@(private = "file")
assert_inferred_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	switch risk {
	case .Index:
		guarded := false
		for if_stmt in body.scan.ifs {
			if expr_calls_named(if_stmt.cond, "len") do guarded = true
			if len(expr_binaries(if_stmt.cond, is_ordering_op)) > 0 do guarded = true
		}
		if guarded && (len(body.scan.returns) > 0 || len(body.scan.branches) > 0) do return true
		if len(body.ops) == 0 do return false
		for op in body.ops {
			if op.kind == .Slice do continue
			if _, is_int := assert_int_literal(op.index_expr); is_int do continue
			if assert_is_upper_const(op.index_expr) do continue
			if !assert_pair_bound_before(body, op) do return false
		}
		return true
	case .Pointer:
		if assert_any_if_nil_compare(body) do return true
		return(
			(assert_calls_any(body, {"raw_data"}) || assert_has_transmute(body)) &&
			assert_calls_any(body, {"len"}) \
		)
	case .Ownership:
		for word in ASSERT_OWNERSHIP_GUARD_WORDS {
			if assert_defer_or_if_mentions(body, word) do return true
		}
		if !assert_calls_any(body, ASSERT_RELEASE_CALLS[:]) do return false
		for assign in body.scan.assigns {
			if len(assign.lhs) != 1 || len(assign.rhs) != 1 do continue
			if _, is_deref := expr_unparen(assign.lhs[0]).derived_expr.(^ast.Deref_Expr);
			   is_deref {
				lit, ok := expr_unparen(assign.rhs[0]).derived_expr.(^ast.Comp_Lit)
				if ok && len(lit.elems) == 0 do return true
			}
			if expr_is_nil(assign.rhs[0]) do return true
		}
		return false
	case .Queue:
		for cond in assert_guard_conds(body) {
			for word in ASSERT_QUEUE_WORDS do if expr_mentions(cond, word) do return true
			if assert_cond_has_len_call(cond) do return true
		}
		return assert_calls_any(body, {"append"}) && len(body.scan.dyn_types) > 0
	case .State:
		for cond in assert_guard_conds(body) {
			if expr_mentions_any(cond, ASSERT_STATE_CONTRACT_WORDS[:]) do return true
		}
		transition := assert_writes_any_leaf(body, ASSERT_STATE_WORDS[:])
		return transition && assert_calls_any(body, {"destroy", "close", "stop", "run"})
	case .Untrusted_Input:
		return false
	}
	return false
}

// assert_pair_bound_before: a loop or assertion before the op that mentions
// both the index expression and the target.
@(private = "file")
assert_pair_bound_before :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	leaf := leaf_of_dotted(op.target)
	for loop in body.scan.loops {
		if !assert_before(loop, op) do continue
		header: ^ast.Expr
		#partial switch stmt in loop.derived {
		case ^ast.Range_Stmt:
			if expr_mentions(stmt.expr, leaf) {
				for value in stmt.vals do if expr_has_expr(body.source, value, op.index_expr) do return true
			}
			header = stmt.expr
		case ^ast.For_Stmt:
			header = stmt.cond
		}
		if header != nil &&
		   expr_has_expr(body.source, header, op.index_expr) &&
		   expr_mentions(header, leaf) {
			return true
		}
	}
	for assertion in body.assertions {
		if assertion.offset >= op.node.pos.offset do continue
		if expr_has_expr(body.source, assertion.cond, op.index_expr) &&
		   expr_mentions(assertion.cond, leaf) {
			return true
		}
	}
	return false
}

@(private = "file")
assert_recognized_dynamic_append :: proc(body: ^Proc_Body) -> bool {
	declared := assert_dynamic_targets(body)
	found := false
	for target in assert_append_targets(body) {
		found = true
		if !assert_name_in(target, declared) do return false
	}
	return found
}

// --- cascade --------------------------------------------------------------

assert_uncovered_risks :: proc(body: ^Proc_Body, risks: Risk_Set) -> Risk_Set {
	uncovered: Risk_Set
	for risk in Risk {
		if risk not_in risks do continue
		if assert_risk_contract(body, risk) do continue
		if assert_authored_contract(body, risk) do continue
		if assert_structural_contract(body, risk) do continue
		uncovered += {risk}
	}
	if uncovered == {} do return {}
	if .Index in uncovered && assert_authored_contract(body, .Index) do uncovered -= {.Index}
	return uncovered
}

ASSERT_TRIVIAL_STATEMENTS_MAX :: 12
ASSERT_TRIVIAL_CALLS_MAX :: 1
ASSERT_FORWARDER_STATEMENTS_MAX :: 20

ASSERT_MUTATION_CALLS := [?]string {
	"append",
	"inject_at",
	"ordered_remove",
	"unordered_remove",
	"make",
	"new",
	"delete",
	"free",
	"destroy",
	"clone",
	"resize",
}

// assert_body_stmts returns the top-level statements of the body.
@(private = "file")
assert_body_stmts :: proc(body: ^Proc_Body) -> []^ast.Stmt {
	return block_stmts(body.lit.body)
}

// assert_is_trivial: a short body that returns, makes at most one call
// (conversions included), and carries only pointer/state risk.
assert_is_trivial :: proc(body: ^Proc_Body, risks: Risk_Set) -> bool {
	stmts := assert_body_stmts(body)
	if len(stmts) == 0 do return true
	if len(stmts) > ASSERT_TRIVIAL_STATEMENTS_MAX do return false
	wrapper := risks - {.Pointer, .State}
	if wrapper != {} do return false
	if len(body.scan.returns) == 0 do return false
	return len(body.scan.calls) <= ASSERT_TRIVIAL_CALLS_MAX
}

assert_has_dominating_guard :: proc(body: ^Proc_Body, risks: Risk_Set) -> bool {
	for risk in Risk {
		if risk not_in risks do continue
		if assert_risk_contract(body, risk) do continue
		if assert_authored_contract(body, risk) do continue
		if assert_structural_contract(body, risk) do continue
		return false
	}
	return true
}

// assert_is_thin_forwarder: every top-level statement is a call, a binding
// of a call, or a return of a call, with no control flow or mutation.
assert_is_thin_forwarder :: proc(body: ^Proc_Body, risks: Risk_Set) -> bool {
	stmts := assert_body_stmts(body)
	if len(stmts) == 0 || len(stmts) > ASSERT_FORWARDER_STATEMENTS_MAX do return false
	if risks & {.Index, .Queue, .Ownership, .Untrusted_Input} != {} do return false
	if len(body.scan.ifs) > 0 || len(body.scan.whens) > 0 do return false
	if len(body.scan.switches) > 0 || len(body.scan.loops) > 0 do return false
	if assert_mutation_syntax(body) do return false
	for stmt in stmts do if !assert_is_forward_statement(stmt) do return false
	return true
}

// assert_mutation_syntax: an assignment through a field or subscript, or a
// call that allocates, frees, or edits a container.
@(private = "file")
assert_mutation_syntax :: proc(body: ^Proc_Body) -> bool {
	for assign in body.scan.assigns {
		for target in assign.lhs {
			#partial switch _ in expr_unparen(target).derived_expr {
			case ^ast.Selector_Expr, ^ast.Index_Expr, ^ast.Matrix_Index_Expr:
				return true
			}
		}
	}
	return assert_calls_any(body, ASSERT_MUTATION_CALLS[:])
}

// assert_is_forward_statement accepts `callee(...)`, `x :?= callee(...)`,
// `return`, and `return callee(...)`.
@(private = "file")
assert_is_forward_statement :: proc(stmt: ^ast.Stmt) -> bool {
	if stmt == nil do return false
	#partial switch node in stmt.derived_stmt {
	case ^ast.Expr_Stmt:
		return assert_is_call_shape(node.expr)
	case ^ast.Return_Stmt:
		if len(node.results) == 0 do return true
		return len(node.results) == 1 && assert_is_call_shape(node.results[0])
	case ^ast.Value_Decl:
		if len(node.values) != 1 do return false
		return assert_is_call_shape(node.values[0])
	case ^ast.Assign_Stmt:
		if node.op.kind != .Eq || len(node.rhs) != 1 do return false
		return assert_is_call_shape(node.rhs[0])
	}
	return false
}

@(private = "file")
assert_is_call_shape :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	call, ok := expr_unparen(expr).derived_expr.(^ast.Call_Expr)
	if !ok do return false
	_, name := callee_name(call)
	return name != ""
}

assert_discharged :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	if assert_reviewed_contract(body, risk) do return true
	if assert_structural_contract(body, risk) do return true
	if assert_inferred_contract(body, risk) do return true
	if assert_authored_contract(body, risk) do return true
	switch risk {
	case .Queue:
		return assert_recognized_dynamic_append(body)
	case .Index:
		return len(body.scan.loops) > 0 || len(body.scan.switches) > 0
	case .Pointer:
		if assert_calls_any(body, {"raw_data"}) || assert_has_transmute(body) {
			return len(body.pointer_params) == 0
		}
		return false
	case .Ownership, .State, .Untrusted_Input:
		return false
	}
	return false
}
