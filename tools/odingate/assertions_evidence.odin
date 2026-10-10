package odingate

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

@(private = "file")
prefix_lines :: proc(body: ^Proc_Body, offset: int) -> []string {
	return split_lines(body.executable[:clamp(offset, 0, len(body.executable))])
}

// assert_block_prefix returns the text from the innermost open `{` before
// `offset` up to `offset`, mirroring matching_block_prefix().
@(private = "file")
assert_block_prefix :: proc(body: ^Proc_Body, offset: int) -> string {
	text := body.executable
	depth := 0
	opening := 0
	for index in 0 ..< min(offset, len(text)) {
		switch text[index] {
		case '{':
			depth += 1
			opening = index + 1
		case '}':
			depth = max(0, depth - 1)
			opening = 0
			if depth > 0 {
				if at := strings.last_index_byte(text[:index], '{'); at >= 0 do opening = at + 1
			}
		}
	}
	return text[opening:clamp(offset, 0, len(text))]
}

// --- index ----------------------------------------------------------------

@(private = "file")
assert_element_index_proven :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	target := op.target
	expr := op.expression
	prefix := prefix_lines(body, op.offset)
	local := split_lines(assert_block_prefix(body, op.offset))
	e := spec_word(expr)
	t := spec_word(target)
	if seq_in_lines(
		prefix,
		S(
			"for",
			spec_adj_word(expr),
			"~in",
			"~=0",
			"~=..<",
			"~len",
			"~=(",
			spec_adj_word(target),
			"~=)",
		),
	) {
		return true
	}
	if seq_in_lines_any(
		prefix,
		ASSERT_HEADS4[:],
		S("~=(", e, "~=>=", "~=0", e, "~=<", "~len", "~=(", spec_adj_word(target), "~=)"),
	) {
		return true
	}
	if seq_in_lines_any(
		prefix,
		ASSERT_HEADS4[:],
		S("~=(", e, "~=<", "~len", "~=(", spec_adj_word(target), "~=)"),
	) {
		return true
	}
	if assert_target_contract(prefix, e, t) do return true
	if seq_in_lines(
		   prefix,
		   S("if", e, "~=>=", "~len", "~=(", spec_adj_word(target), "~=)", "=return"),
	   ) ||
	   seq_in_lines(
		   prefix,
		   S("if", e, "~=>=", "~len", "~=(", spec_adj_word(target), "~=)", "=continue"),
	   ) {
		return true
	}
	if seq_in_lines_any(prefix, ASSERT_HEADS4[:], S(e, "~@ORDER", "~@UPPER")) do return true
	resolved :=
		seq_in_lines(prefix, S(e, "~=:=", "~@DOTTED", "~=(", "=)")) ||
		seq_in_lines(prefix, S(e, "~==", "~@DOTTED", "~=(", "=)"))
	if resolved {
		if seq_in_lines(prefix, S("if", e, "~=<", "~=0", "=return")) ||
		   seq_in_lines(prefix, S("if", e, "~=<", "~=0", "=continue")) {
			return true
		}
	}
	if size, fixed := assert_fixed_array_size(body.executable, target); fixed {
		if constant, is_int := parse_uint(expr); is_int do return constant < size
	}
	if assert_modulo_of_len(expr, target) {
		return any_line(
			body.executable[:op.offset],
			S("len", "~=(", spec_adj_word(target), "~=)", "~=>", "~=0"),
		)
	}
	return seq_in_lines_any(local, ASSERT_HEADS3[:], S("~=(", e, t))
}

// assert_target_contract: an assertion on the same line mentioning the index
// expression or the target followed by an ordering comparison.
@(private = "file")
assert_target_contract :: proc(lines: []string, e, t: string) -> bool {
	return(
		seq_in_lines_any(lines, ASSERT_HEADS3[:], S("~=(", e, "@ORDER", "=)")) ||
		seq_in_lines_any(lines, ASSERT_HEADS3[:], S("~=(", t, "@ORDER", "=)")) \
	)
}

// assert_fixed_array_size finds `target: [N]` and returns N.
@(private = "file")
assert_fixed_array_size :: proc(text, target: string) -> (size: int, ok: bool) {
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_word(text, target, from)
		if at < 0 do return
		from = at + 1
		pos := skip_spaces(text, at + len(target))
		if pos >= len(text) || text[pos] != ':' do continue
		pos = skip_spaces(text, pos + 1)
		if pos >= len(text) || text[pos] != '[' do continue
		pos = skip_spaces(text, pos + 1)
		digits_start := pos
		for pos < len(text) && is_digit_byte(text[pos]) do pos += 1
		if pos == digits_start do continue
		digits := text[digits_start:pos]
		pos = skip_spaces(text, pos)
		if pos < len(text) && text[pos] == ']' do return parse_uint(digits)
	}
	return
}

// assert_modulo_of_len reports `... % len(target)` shapes.
@(private = "file")
assert_modulo_of_len :: proc(expr, target: string) -> bool {
	at := strings.index_byte(expr, '%')
	if at <= 0 do return false
	rest := strip_spaces(expr[at + 1:])
	return rest == strings.concatenate({"len(", target, ")"}, context.temp_allocator)
}

@(private = "file")
assert_slice_index_proven :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	colon := strings.index_byte(op.expression, ':')
	assert(colon >= 0, "assert_slice_index_proven: not a slice")
	low := strings.trim_space(op.expression[:colon])
	high := strings.trim_space(op.expression[colon + 1:])
	prefix := body.executable[:op.offset]
	if low == "" && high == "" do return true
	full := strings.concatenate({"len(", op.target, ")"}, context.temp_allocator)
	if low == "" && (high == "" || high == full) do return true
	ok := true
	if low != "" do ok &&= assert_prefix_has(prefix, S("=0", "~=<=", spec_adjacent(low)))
	if low != "" && high != "" {
		ok &&= assert_prefix_has(prefix, S(spec_plain(low), "~=<=", spec_adjacent(high)))
	}
	if high != "" {
		ok &&= assert_prefix_has(
			prefix,
			S(spec_plain(high), "~=<=", "~len", "~=(", spec_adj_word(op.target), "~=)"),
		)
	}
	if ok do return true
	if high != "" && assert_is_min_clamp_of_len(high, op.target) {
		return low == "" || assert_prefix_has(prefix, S("=0", "~=<=", spec_adjacent(low)))
	}
	return false
}

@(private = "file")
assert_prefix_has :: proc(prefix: string, parts: []string) -> bool {
	_, ok := seq_match(prefix, parts)
	return ok
}

@(private = "file")
assert_is_min_clamp_of_len :: proc(high, target: string) -> bool {
	head := ""
	if strings.has_prefix(high, "min") do head = "min"
	if strings.has_prefix(high, "clamp") do head = "clamp"
	if head == "" do return false
	rest := strings.trim_space(high[len(head):])
	if !strings.has_prefix(rest, "(") || !strings.has_suffix(rest, ")") do return false
	return seq_in(rest, S("len", "~=(", spec_adj_word(target), "~=)"))
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

// assert_assertion_texts returns each `assert(...)`/`ensure(...)` call text
// up to the closing parenthesis that ends a statement (multi-line allowed).
@(private = "file")
assert_assertion_texts :: proc(body: ^Proc_Body) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	text := body.executable
	for head in ASSERT_HEADS3 {
		from := 0
		for _ in 0 ..< TEXT_SCAN_MAX {
			at := find_call(text, head, from)
			if at < 0 do break
			from = at + len(head)
			if head == "assert" &&
			   at >= len("assert_contextless") - len("assert") &&
			   strings.has_suffix(text[:at + len(head)], "assert_contextless") {
				continue
			}
			end := assert_statement_close(text, at)
			append(&out, text[at:end])
		}
	}
	return out[:]
}

// assert_statement_close finds the `)` followed by `;`, newline, or end.
@(private = "file")
assert_statement_close :: proc(text: string, from: int) -> int {
	for index in from ..< len(text) {
		if text[index] != ')' do continue
		next := skip_spaces(text, index + 1)
		if next >= len(text) || text[next] == ';' || text[next] == '\n' do return index + 1
	}
	return len(text)
}

@(private = "file")
assert_authored_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	checks := assert_assertion_texts(body)
	if len(checks) == 0 do return false
	for check in checks {
		switch risk {
		case .Pointer:
			if assert_nil_compare(check) do return true
		case .Index:
			if seq_in(check, S("@ORDER", "~len", "~=(")) do return true
			if seq_in(check, S("@ORDER", "~@UPPER")) do return true
		case .Queue:
			if has_any_word(check, {"count", "head", "tail", "len", "cap"}) do return true
		case .Ownership:
			if has_any_word(check, {"nil", "owner", "owned", "allocator", "len", "cap"}) do return true
		case .State:
			if has_any_word(check, {"state", "running", "active", "session", "frame", "open"}) do return true
		case .Untrusted_Input:
			if has_any_word(
				check,
				{"len", "count", "size", "offset", "cursor", "parsed", "status", "ok", "err"},
			) {
				return true
			}
		}
	}
	return false
}

assert_nil_compare :: proc(text: string) -> bool {
	return seq_in(text, S("@EQ", "~nil")) || seq_in(text, S("nil", "~@EQ"))
}

// --- structural -----------------------------------------------------------

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
				p := spec_word(param)
				asserted := any_line_heads(
					body.executable,
					ASSERT_HEADS3[:],
					S("~=(", p, "@EQ", "~nil"),
				)
				passed := any_line(
					body.executable,
					S("@IDENT", "~=(", spec_adj_word(param), "~=)"),
				)
				if !asserted && !passed do return false
			}
			return true
		}
		if any_line(body.executable, S("if", "@EQ", "~nil")) do return true
		return !has_any_call(body.executable, {"transmute", "raw_data", "raw_ptr"})
	case .Queue:
		bounded := assert_bounded_push(body.executable)
		checked :=
			any_line_heads(body.executable, S("if", "assert", "ensure"), S("=count", "@ORDEQ")) ||
			any_line_heads(body.executable, S("if", "assert", "ensure"), S("=head", "@ORDEQ")) ||
			any_line_heads(body.executable, S("if", "assert", "ensure"), S("=tail", "@ORDEQ")) ||
			any_line_heads(
				body.executable,
				S("if", "assert", "ensure"),
				S("len", "~=(", "@ORDEQ"),
			) ||
			any_line_heads(body.executable, S("if", "assert", "ensure"), S("cap", "~=(", "@ORDEQ"))
		return bounded || checked
	case .Ownership:
		for word in ([?]string{"=nil", "=ok", "=err", "=result"}) {
			if any_line_heads(body.executable, S("defer", "if"), S(word)) do return true
		}
		if any_line_heads(body.executable, S("defer", "if"), S("len", "~=(")) do return true
		if any_line_heads(body.executable, S("defer", "if"), S("cap", "~=(")) do return true
		return !has_any_call(body.executable, {"delete", "free", "destroy"})
	case .State:
		guarded := false
		for word in ([?]string{"=state", "=running", "=active", "=session", "=frame", "=open"}) {
			if any_line_heads(body.executable, S("if", "assert", "ensure"), S(word, "@EQ")) do guarded = true
		}
		transition :=
			any_line(body.executable, S("state", "~==")) ||
			any_line(body.executable, S("running", "~==")) ||
			any_line(body.executable, S("active", "~==")) ||
			any_line(body.executable, S("session", "~=="))
		failure :=
			any_line(body.executable, S("last_error", "~==")) ||
			any_line(body.executable, S("error", "~==")) ||
			any_line(body.executable, S("fault", "~=="))
		return guarded || !transition || failure
	case .Untrusted_Input:
		for word in ([?]string {
				"=len",
				"=count",
				"=size",
				"=offset",
				"=cursor",
				"=parsed",
				"=status",
				"=ok",
				"=err",
			}) {
			if any_line(body.executable, S("if", word, "@CMP")) do return true
		}
		return false
	}
	return false
}

// assert_bounded_push: `if !x_reserve(...) do return` style guards.
@(private = "file")
assert_bounded_push :: proc(text: string) -> bool {
	for line in split_lines(text) {
		at := find_word(line, "if")
		if at < 0 do continue
		rest := line[at + 2:]
		if !contains_any(rest, {"reserve", "append", "push"}) do continue
		if !strings.contains(rest, "(") do continue
		if seq_in(rest, S("=)", "do", "return")) ||
		   seq_in(rest, S("=)", "do", "break")) ||
		   seq_in(rest, S("=)", "do", "continue")) {
			return true
		}
	}
	return false
}

@(private = "file")
assert_structural_index :: proc(body: ^Proc_Body, op: Index_Op) -> bool {
	if op.kind == .Slice do return true
	expr := op.expression
	if is_all_digits(expr) || is_upper_const(expr) do return true
	for conv in ([?]string{"int", "i32", "u32"}) {
		if strings.has_prefix(expr, conv) {
			rest := strings.trim_space(expr[len(conv):])
			if strings.has_prefix(rest, "(") &&
			   strings.has_suffix(rest, ")") &&
			   strings.index_byte(rest[1:len(rest) - 1], ')') < 0 &&
			   len(rest) > 2 {
				return true
			}
		}
	}
	prefix := body.executable[:op.offset]
	plines := split_lines(prefix)
	if is_dotted_ident(expr) {
		e := spec_word(expr)
		if seq_in_lines(plines, S(e, "~=:=", "~clamp", "~=(")) ||
		   seq_in_lines(plines, S(e, "~==", "~clamp", "~=(")) ||
		   seq_in_lines(plines, S(e, "~=:=", "~min", "~=(")) ||
		   seq_in_lines(plines, S(e, "~==", "~min", "~=(")) ||
		   seq_in_lines(plines, S(e, "~=:=", "~max", "~=(")) ||
		   seq_in_lines(plines, S(e, "~==", "~max", "~=(")) {
			return true
		}
		if assert_resolved_by_index_call(prefix, expr) do return true
		if (seq_in_lines(plines, S("if", e)) || seq_in_lines(plines, S("for", e))) &&
		   has_word(prefix, op.target) {
			return true
		}
	}
	if strings.contains(expr, "%") do return true
	if is_dotted_ident(expr) {
		e := spec_word(expr)
		t := spec_word(op.target)
		leaf := spec_word(leaf_of_dotted(op.target))
		if seq_in_lines(plines, S(e, "~in", t)) ||
		   seq_in_lines(plines, S(e, "~not_in", t)) ||
		   seq_in_lines(plines, S(e, "~in", leaf)) ||
		   seq_in_lines(plines, S(e, "~not_in", leaf)) {
			return true
		}
		if seq_in_lines(
			   plines,
			   S(
				   "@IDENT",
				   "~=,",
				   "~@IDENT",
				   "~=:=",
				   spec_adj_word(op.target),
				   "~=[",
				   spec_adj_word(expr),
				   "~=]",
			   ),
		   ) ||
		   seq_in_lines(
			   plines,
			   S(
				   "@IDENT",
				   "~=,",
				   "~@IDENT",
				   "~==",
				   spec_adj_word(op.target),
				   "~=[",
				   spec_adj_word(expr),
				   "~=]",
			   ),
		   ) {
			return true
		}
	}
	e := spec_word(expr)
	t := spec_word(op.target)
	if any_line(body.executable, S("if", e, "=<", t)) do return true
	if any_line(body.executable, S("if", e, "=>=", t)) do return true
	return seq_in_lines(plines, S("for", spec_adj_word(expr), "~in"))
}

// assert_resolved_by_index_call: `expr := something_index(...)` / `_slot(` /
// `_range(` assignments before the use.
@(private = "file")
assert_resolved_by_index_call :: proc(prefix, expr: string) -> bool {
	for line in split_lines(prefix) {
		at := find_word(line, expr)
		if at < 0 do continue
		pos := skip_spaces(line, at + len(expr))
		if pos < len(line) && line[pos] == ':' do pos += 1
		if pos >= len(line) || line[pos] != '=' do continue
		pos = skip_spaces(line, pos + 1)
		start := pos
		for pos < len(line) && (is_word_byte(line[pos]) || line[pos] == '.') do pos += 1
		callee := line[start:pos]
		if callee == "" do continue
		next := skip_spaces(line, pos)
		if next >= len(line) || line[next] != '(' do continue
		if strings.has_suffix(callee, "index") ||
		   strings.has_suffix(callee, "slot") ||
		   strings.has_suffix(callee, "range") {
			return true
		}
	}
	return false
}

// --- risk contracts -------------------------------------------------------

@(private = "file")
assert_pointer_contract :: proc(body: ^Proc_Body) -> bool {
	names := make([dynamic]string, context.temp_allocator)
	text := body.executable
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_call(text, "transmute", from)
		if at < 0 do break
		from = at + 1
		open := strings.index_byte(text[at:], '(')
		close := strings.index_byte(text[at:], ')')
		if open < 0 || close < open do continue
		pos := skip_spaces(text, at + close + 1)
		start := pos
		for pos < len(text) && is_word_byte(text[pos]) do pos += 1
		if pos > start && !is_digit_byte(text[start]) do append(&names, text[start:pos])
	}
	for name in ([?]string{"raw_data", "raw_ptr"}) {
		from = 0
		for _ in 0 ..< TEXT_SCAN_MAX {
			at := find_call(text, name, from)
			if at < 0 do break
			from = at + 1
			pos := skip_spaces(text, at + len(name))
			pos = skip_spaces(text, pos + 1)
			start := pos
			for pos < len(text) && (is_word_byte(text[pos]) || text[pos] == '.') do pos += 1
			if pos > start do append(&names, text[start:pos])
		}
	}
	for param in body.pointer_params do append(&names, param)
	if len(names) == 0 do return true
	for name in names {
		n := spec_word(name)
		if seq_in_lines(body.contracts, S(n, "~@EQ", "~nil")) do continue
		if any_line(text, S("return", n, "~=!=", "~nil", "~=&&")) do continue
		return false
	}
	return true
}

@(private = "file")
assert_queue_contract :: proc(body: ^Proc_Body) -> bool {
	text := body.executable
	if strings.contains(text, "[dynamic]") do return true
	dynamic_targets := assert_dynamic_targets(text)
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_call(text, "append", from)
		if at < 0 do break
		from = at + 1
		pos := skip_spaces(text, strings.index_byte(text[at:], '(') + at + 1)
		if pos >= len(text) || text[pos] != '&' do continue
		pos += 1
		start := pos
		for pos < len(text) && (is_word_byte(text[pos]) || text[pos] == '.') do pos += 1
		target := text[start:pos]
		if target == "" || assert_name_in(target, dynamic_targets[:]) do continue
		t := spec_adj_word(target)
		capacity := seq_in_lines(
			body.contracts,
			S("len", "~=(", t, "~=)", "~=<", "~cap", "~=(", t, "~=)"),
		)
		bounded := false
		for word in ([?]string{"=count", "=head", "=tail", "=capacity"}) {
			if seq_in_lines(body.contracts, S(spec_word(target), word)) do bounded = true
		}
		if !capacity && !bounded do return false
	}
	if has_any_call(text, {"ordered_remove", "unordered_remove"}) &&
	   !assert_index_contract_present(body) {
		return false
	}
	for word in ([?]string{"count", "head", "tail"}) {
		if !any_line(text, S(word, "~=+=")) &&
		   !any_line(text, S(word, "~=-=")) &&
		   !any_line(text, S(word, "~==")) {
			continue
		}
		if !seq_in_lines(body.contracts, S(word, "~@ORDEQ")) do return false
		break
	}
	return true
}

// assert_dynamic_targets: names declared `x: [dynamic` or `x := make([dynamic`.
@(private = "file")
assert_dynamic_targets :: proc(text: string) -> [dynamic]string {
	targets := make([dynamic]string, context.temp_allocator)
	for line in split_lines(text) {
		for index in 0 ..< len(line) {
			if !is_word_byte(line[index]) || (index > 0 && is_word_byte(line[index - 1])) do continue
			end := index
			for end < len(line) && is_word_byte(line[end]) do end += 1
			rest := line[end:]
			if seq_in(rest, S("~=:", "~=[dynamic")) ||
			   seq_in(rest, S("~=:=", "~make", "~=(", "~=[dynamic")) ||
			   seq_in(rest, S("~==", "~make", "~=(", "~=[dynamic")) {
				append(&targets, line[index:end])
			}
		}
	}
	return targets
}

@(private = "file")
assert_name_in :: proc(name: string, names: []string) -> bool {
	for candidate in names do if candidate == name do return true
	return false
}

@(private = "file")
assert_ownership_contract :: proc(body: ^Proc_Body) -> bool {
	text := body.executable
	allocations := make([dynamic]string, context.temp_allocator)
	releases := make([dynamic]string, context.temp_allocator)
	for line in split_lines(text) {
		for index in 0 ..< len(line) {
			if !is_word_byte(line[index]) || (index > 0 && is_word_byte(line[index - 1])) do continue
			end := index
			for end < len(line) && is_word_byte(line[end]) do end += 1
			rest := line[end:]
			for callee in ([?]string{"make", "new", "clone", "resize"}) {
				if seq_in(rest, S("~=:=", spec_adj_word(callee), "~=(")) ||
				   seq_in(rest, S("~==", spec_adj_word(callee), "~=(")) {
					append(&allocations, line[index:end])
				}
			}
		}
	}
	for callee in ([?]string{"delete", "free", "destroy"}) {
		from := 0
		for _ in 0 ..< TEXT_SCAN_MAX {
			at := find_call(text, callee, from)
			if at < 0 do break
			from = at + 1
			pos := skip_spaces(text, strings.index_byte(text[at:], '(') + at + 1)
			if pos < len(text) && text[pos] == '&' do pos += 1
			start := pos
			for pos < len(text) && (is_word_byte(text[pos]) || text[pos] == '.') do pos += 1
			if pos > start do append(&releases, text[start:pos])
		}
	}
	for name in allocations {
		n := spec_word(name)
		if !(seq_in_lines(body.contracts, S(n, "=nil")) ||
			   seq_in_lines(body.contracts, S(n, "len", "~=(")) ||
			   seq_in_lines(body.contracts, S(n, "=ok")) ||
			   seq_in_lines(body.contracts, S(n, "=err")) ||
			   seq_in_lines(body.contracts, S(n, "=defer"))) {
			return false
		}
	}
	for name in releases {
		n := spec_word(name)
		if !(seq_in_lines(body.contracts, S(n, "=nil")) ||
			   seq_in_lines(body.contracts, S(n, "=defer")) ||
			   seq_in_lines(body.contracts, S(n, "=owner")) ||
			   seq_in_lines(body.contracts, S(n, "=owned"))) {
			return false
		}
	}
	return (len(allocations) == 0 && len(releases) == 0) || len(body.contracts) > 0
}

@(private = "file")
assert_state_contract :: proc(body: ^Proc_Body) -> bool {
	for field in ([?]string{"state", "running", "active", "session"}) {
		if !any_line(body.executable, S(field, "~==")) do continue
		if !seq_in_lines(body.contracts, S(field, "~@EQ")) do return false
	}
	return true
}

@(private = "file")
assert_untrusted_contract :: proc(body: ^Proc_Body) -> bool {
	for line in split_lines(body.executable) {
		for index in 0 ..< len(line) {
			if !is_word_byte(line[index]) || (index > 0 && is_word_byte(line[index - 1])) do continue
			end := index
			for end < len(line) && is_word_byte(line[end]) do end += 1
			rest := line[end:]
			pos := skip_spaces(rest, 0)
			if pos < len(rest) && rest[pos] == ',' {
				pos = skip_spaces(rest, pos + 1)
				for pos < len(rest) && is_word_byte(rest[pos]) do pos += 1
				pos = skip_spaces(rest, pos)
			}
			if pos < len(rest) && rest[pos] == ':' do pos += 1
			if pos >= len(rest) || rest[pos] != '=' do continue
			pos = skip_spaces(rest, pos + 1)
			if !assert_untrusted_callee_at(rest, pos) do continue
			n := spec_word(line[index:end])
			if !(seq_in_lines(body.contracts, S(n, "@CMP")) ||
				   seq_in_lines(body.contracts, S(n, "len", "~=("))) {
				return false
			}
		}
	}
	return true
}

@(private = "file")
assert_untrusted_callee_at :: proc(text: string, pos: int) -> bool {
	for prefix in ([?]string{"parse", "decode", "read", "recv"}) {
		if !strings.has_prefix(text[pos:], prefix) do continue
		end := pos + len(prefix)
		for end < len(text) && is_word_byte(text[end]) do end += 1
		next := skip_spaces(text, end)
		if next < len(text) && text[next] == '(' do return true
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

@(private = "file")
assert_single_line_assertions :: proc(body: ^Proc_Body) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for line in body.lines {
		for head in ASSERT_HEADS3 {
			at := find_call(line, head, 0)
			if at < 0 do continue
			append(&out, line[at:])
			break
		}
	}
	return out[:]
}

@(private = "file")
assert_reviewed_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	assertions := assert_single_line_assertions(body)
	if len(assertions) == 0 do return false
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
	for assertion in assertions {
		for term in terms {
			parts := assert_term_specs(term)
			after := specs(parts, S("@CMP"))
			before := specs(S("@CMP"), parts)
			if seq_in(assertion, after) || seq_in(assertion, before) do return true
		}
	}
	return false
}

// assert_term_specs turns "len(" into a word-bounded `len` followed by an
// adjacent `(`, and plain words into word-bounded literals.
@(private = "file")
assert_term_specs :: proc(term: string) -> []string {
	if strings.has_suffix(term, "(") do return S(spec_word(term[:len(term) - 1]), "~=(")
	return S(spec_word(term))
}

@(private = "file")
assert_inferred_contract :: proc(body: ^Proc_Body, risk: Risk) -> bool {
	text := body.executable
	switch risk {
	case .Index:
		guarded :=
			(any_line(text, S("if", "len", "~=(")) || any_line(text, S("if", "@ORDER"))) &&
			has_any_word(text, {"return", "continue", "break"})
		if guarded do return true
		if len(body.ops) == 0 do return false
		for op in body.ops {
			if op.kind == .Slice || is_all_digits(op.expression) || is_upper_const(op.expression) do continue
			prefix := split_lines(text[:op.offset])
			heads := S("for", "assert_contextless", "assert", "ensure")
			pair := S(spec_word(op.expression), spec_word(op.target))
			if !seq_in_lines_any(prefix, heads, pair) do return false
		}
		return true
	case .Pointer:
		if any_line(text, S("if", "@EQ", "~nil")) do return true
		return has_any_call(text, {"raw_data", "transmute"}) && has_call(text, "len")
	case .Ownership:
		for word in ([?]string{"=nil", "=ok", "=err", "=result"}) {
			if any_line_heads(text, S("defer", "if"), S(word)) do return true
		}
		return(
			has_any_call(text, {"delete", "free", "destroy"}) &&
			(seq_in(text, S("=^", "~==", "~={}")) || seq_in(text, S("==", "~nil"))) \
		)
	case .Queue:
		heads := S("if", "assert_contextless", "assert", "ensure")
		if any_line_heads(text, heads, S("=count")) ||
		   any_line_heads(text, heads, S("=head")) ||
		   any_line_heads(text, heads, S("=tail")) ||
		   any_line_heads(text, heads, S("len", "~=(")) ||
		   any_line_heads(text, heads, S("cap", "~=(")) {
			return true
		}
		return has_call(text, "append") && strings.contains(text, "[dynamic")
	case .State:
		heads := S("if", "assert_contextless", "assert", "ensure")
		for word in ([?]string{"=state", "=running", "=active", "=session", "=frame", "=open"}) {
			if any_line_heads(text, heads, S(word)) do return true
		}
		transition :=
			any_line(text, S("state", "~==")) ||
			any_line(text, S("running", "~==")) ||
			any_line(text, S("active", "~==")) ||
			any_line(text, S("session", "~=="))
		return transition && has_any_call(text, {"destroy", "close", "stop", "run"})
	case .Untrusted_Input:
		return false
	}
	return false
}

@(private = "file")
assert_recognized_dynamic_append :: proc(body: ^Proc_Body) -> bool {
	text := body.executable
	declared := assert_dynamic_targets(text)
	found := false
	from := 0
	for _ in 0 ..< TEXT_SCAN_MAX {
		at := find_call(text, "append", from)
		if at < 0 do break
		from = at + 1
		pos := skip_spaces(text, strings.index_byte(text[at:], '(') + at + 1)
		if pos >= len(text) || text[pos] != '&' do continue
		start := pos + 1
		end := start
		for end < len(text) && is_word_byte(text[end]) do end += 1
		if end == start do continue
		found = true
		if !assert_name_in(text[start:end], declared[:]) do return false
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
	if .Index in uncovered {
		for assertion in assert_single_line_assertions(body) {
			if seq_in(assertion, S("@ORDER", "~len", "~=(")) ||
			   seq_in(assertion, S("@ORDER", "~@UPPER")) {
				uncovered -= {.Index}
				break
			}
		}
	}
	return uncovered
}

assert_is_trivial :: proc(body: ^Proc_Body, risks: Risk_Set) -> bool {
	if strings.trim_space(body.executable) == "" do return true
	statements := 0
	masked_lines := split_lines(body.masked)
	if len(masked_lines) > 2 {
		for line in masked_lines[1:len(masked_lines) - 1] {
			if strings.trim_space(line) != "" do statements += 1
		}
	}
	if statements > 12 do return false
	wrapper := risks - {.Pointer, .State}
	return wrapper == {} && has_word(body.masked, "return") && count_call_shapes(body.masked) <= 2
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

assert_is_thin_forwarder :: proc(body: ^Proc_Body, risks: Risk_Set) -> bool {
	statements := make([dynamic]string, context.temp_allocator)
	for line in body.lines {
		trimmed := strings.trim_space(line)
		if trimmed != "" do append(&statements, trimmed)
	}
	if len(statements) == 0 || len(statements) > 20 do return false
	if risks & {.Index, .Queue, .Ownership, .Untrusted_Input} != {} do return false
	if has_any_word(body.executable, {"if", "when", "switch", "for"}) do return false
	if assert_mutation_syntax(body.executable) do return false
	for statement in statements {
		if !assert_is_forward_statement(statement) do return false
	}
	return true
}

@(private = "file")
assert_mutation_syntax :: proc(text: string) -> bool {
	for index in 1 ..< len(text) {
		if text[index] != '=' do continue
		pos := index
		if pos > 0 && strings.index_byte("+-*/%", text[pos - 1]) >= 0 do pos -= 1
		pos = assert_back_spaces(text, pos)
		if pos > 0 && (text[pos - 1] == '.' || text[pos - 1] == ']') do return true
	}
	return has_any_call(
		text,
		{
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
		},
	)
}

@(private = "file")
assert_back_spaces :: proc(text: string, pos: int) -> int {
	index := pos
	for index > 0 && is_space_byte(text[index - 1]) do index -= 1
	return index
}

// assert_is_forward_statement accepts `[x :?= ]callee(...)` and
// `return[ callee(...)]`, with nothing after the closing parenthesis.
@(private = "file")
assert_is_forward_statement :: proc(statement: string) -> bool {
	if statement == "return" do return true
	text := statement
	if strings.has_prefix(text, "return ") {
		text = strings.trim_space(text[len("return "):])
		return assert_is_call_shape(text)
	}
	pos := 0
	for pos < len(text) && is_word_byte(text[pos]) do pos += 1
	if pos == 0 do return false
	rest := skip_spaces(text, pos)
	if rest < len(text) && text[rest] == ':' do rest += 1
	if rest < len(text) && text[rest] == '=' {
		return assert_is_call_shape(strings.trim_space(text[rest + 1:]))
	}
	return assert_is_call_shape(text)
}

@(private = "file")
assert_is_call_shape :: proc(text: string) -> bool {
	pos := 0
	for pos < len(text) && (is_word_byte(text[pos]) || text[pos] == '.') do pos += 1
	if pos == 0 || is_digit_byte(text[0]) do return false
	pos = skip_spaces(text, pos)
	return pos < len(text) && text[pos] == '(' && strings.has_suffix(text, ")")
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
		return has_any_word(body.executable, {"for", "switch"})
	case .Pointer:
		if has_any_call(body.executable, {"raw_data", "transmute"}) {
			return len(body.pointer_params) == 0
		}
		return false
	case .Ownership, .State, .Untrusted_Input:
		return false
	}
	return false
}
