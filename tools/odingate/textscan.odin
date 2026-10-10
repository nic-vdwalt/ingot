package odingate

import "core:strings"

// Small text matchers over masked source lines. The assertion-discipline
// predicates reason about what an author wrote on a line (an `if` comparing
// `len(x)`, an `assert` mentioning a pointer and `nil`), so they need
// word-bounded search and ordered-token matching rather than a full regex
// engine. All scans are bounded by TEXT_SCAN_MAX iterations.

TEXT_SCAN_MAX :: 1 << 20

is_word_byte :: proc(b: byte) -> bool {
	return b == '_' || (b >= '0' && b <= '9') || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

is_space_byte :: proc(b: byte) -> bool {
	return b == ' ' || b == '\t'
}

is_upper_byte :: proc(b: byte) -> bool {
	return b >= 'A' && b <= 'Z'
}

is_digit_byte :: proc(b: byte) -> bool {
	return b >= '0' && b <= '9'
}

// find_word returns the first index at or after `from` where `word` occurs
// with word boundaries on the ends that are word characters, or -1.
find_word :: proc(text, word: string, from := 0) -> int {
	assert(word != "", "find_word: empty word")
	assert(from >= 0, "find_word: negative start")
	start := from
	for _ in 0 ..< TEXT_SCAN_MAX {
		if start > len(text) do return -1
		rel := strings.index(text[start:], word)
		if rel < 0 do return -1
		at := start + rel
		if word_bounded(text, at, at + len(word)) do return at
		start = at + 1
	}
	return -1
}

// word_bounded mirrors regex  at `start` and `end`: a boundary exists where
// exactly one of the two neighbouring bytes is a word byte; text edges count
// as non-word.
word_bounded :: proc(text: string, start, end: int) -> bool {
	assert(start >= 0 && end <= len(text) && start < end, "word_bounded: span outside text")
	return is_boundary(text, start) && is_boundary(text, end)
}

is_boundary :: proc(text: string, pos: int) -> bool {
	before := pos > 0 && is_word_byte(text[pos - 1])
	after := pos < len(text) && is_word_byte(text[pos])
	return before != after
}

has_word :: proc(text, word: string) -> bool {
	return find_word(text, word) >= 0
}

has_any_word :: proc(text: string, words: []string) -> bool {
	for word in words {
		if has_word(text, word) do return true
	}
	return false
}

// skip_spaces returns the first index at or after `pos` that is not a space
// or tab.
skip_spaces :: proc(text: string, pos: int) -> int {
	index := pos
	for index < len(text) && is_space_byte(text[index]) do index += 1
	return index
}

// Part of a seq_match pattern. Literal parts match their text with word
// boundaries on word-character ends; the specials match classes of tokens.
Seq_Kind :: enum {
	Literal, // text with regex  semantics at both ends
	Plain, // text matched as a bare substring
	Order, // one of < <= > >=
	Eq, // one of == !=
	Order_Eq, // one of < <= > >= ==
	Cmp, // one of < <= > >= == !=
	Upper, // a token starting with an uppercase letter
	Int, // a run of digits
	Ident, // an identifier
	Dotted, // an identifier chain a.b.c
}

Seq_Part :: struct {
	kind:     Seq_Kind,
	text:     string,
	adjacent: bool, // must follow the previous part after only spaces/tabs
}

// seq_part parses the compact pattern syntax used by the predicates: a
// leading "~" marks adjacency, a leading "=" marks a bare substring, the
// "@..." names select token classes, and anything else is a word-bounded
// literal (regex  at both ends).
seq_part :: proc(spec: string) -> Seq_Part {
	assert(spec != "", "seq_part: empty spec")
	part: Seq_Part
	rest := spec
	if strings.has_prefix(rest, "~") {
		part.adjacent = true
		rest = rest[1:]
	}
	if strings.has_prefix(rest, "=") {
		part.kind = .Plain
		part.text = rest[1:]
		assert(part.text != "", "seq_part: empty plain literal")
		return part
	}
	if strings.has_prefix(rest, "!") {
		part.kind = .Literal
		part.text = rest[1:]
		assert(part.text != "", "seq_part: empty word literal")
		return part
	}
	switch rest {
	case "@ORDER":
		part.kind = .Order
	case "@EQ":
		part.kind = .Eq
	case "@ORDEQ":
		part.kind = .Order_Eq
	case "@CMP":
		part.kind = .Cmp
	case "@UPPER":
		part.kind = .Upper
	case "@INT":
		part.kind = .Int
	case "@IDENT":
		part.kind = .Ident
	case "@DOTTED":
		part.kind = .Dotted
	case:
		part.kind = .Literal
		part.text = rest
	}
	assert(part.kind != .Literal || part.text != "", "seq_part: empty literal")
	return part
}

// seq_match_at tries to match one part exactly at `pos`.
@(private = "file")
seq_match_at :: proc(text: string, pos: int, part: Seq_Part) -> (end: int, ok: bool) {
	if pos >= len(text) do return pos, false
	switch part.kind {
	case .Literal:
		if !strings.has_prefix(text[pos:], part.text) do return pos, false
		end = pos + len(part.text)
		return end, word_bounded(text, pos, end)
	case .Plain:
		if !strings.has_prefix(text[pos:], part.text) do return pos, false
		return pos + len(part.text), true
	case .Order:
		return match_order(text, pos)
	case .Eq:
		return match_eq(text, pos)
	case .Order_Eq:
		if end, ok = match_order(text, pos); ok do return end, true
		if pos + 1 < len(text) && text[pos] == '=' && text[pos + 1] == '=' do return pos + 2, true
		return pos, false
	case .Cmp:
		if end, ok = match_order(text, pos); ok do return end, true
		return match_eq(text, pos)
	case .Upper:
		if !is_upper_byte(text[pos]) do return pos, false
		end = pos + 1
		for end < len(text) &&
		    (is_upper_byte(text[end]) || is_digit_byte(text[end]) || text[end] == '_') {
			end += 1
		}
		return end, true
	case .Int:
		end = pos
		for end < len(text) && is_digit_byte(text[end]) do end += 1
		return end, end > pos
	case .Ident:
		if !is_word_byte(text[pos]) || is_digit_byte(text[pos]) do return pos, false
		end = pos + 1
		for end < len(text) && is_word_byte(text[end]) do end += 1
		return end, true
	case .Dotted:
		if !is_word_byte(text[pos]) || is_digit_byte(text[pos]) do return pos, false
		end = pos + 1
		for end < len(text) && (is_word_byte(text[end]) || text[end] == '.') do end += 1
		return end, true
	}
	return pos, false
}

// match_order matches one of < <= > >= at `pos`.
@(private = "file")
match_order :: proc(text: string, pos: int) -> (end: int, ok: bool) {
	if pos >= len(text) || (text[pos] != '<' && text[pos] != '>') do return pos, false
	end = pos + 1
	if end < len(text) && text[end] == '=' do end += 1
	return end, true
}

// match_eq matches one of == != at `pos`.
@(private = "file")
match_eq :: proc(text: string, pos: int) -> (end: int, ok: bool) {
	if pos + 1 < len(text) && text[pos + 1] == '=' && (text[pos] == '=' || text[pos] == '!') {
		return pos + 2, true
	}
	return pos, false
}

// seq_match reports whether the parts occur in order in `text` starting at
// `from`, returning the end of the final part. Parts form groups: a
// non-adjacent anchor followed by its run of adjacent parts. Each anchor is
// tried at every candidate position until its whole chain matches, which is
// the backtracking a regex like `(<|>=)\s*[A-Z]+` performs; the gap between
// groups is unconstrained, so the earliest anchor is always the right one.
seq_match :: proc(text: string, specs: []string, from := 0) -> (end: int, ok: bool) {
	assert(len(specs) > 0, "seq_match: no parts")
	assert(from >= 0, "seq_match: negative start")
	parts := make([]Seq_Part, len(specs), context.temp_allocator)
	for spec, index in specs do parts[index] = seq_part(spec)
	pos := from
	index := 0
	for _ in 0 ..< len(parts) {
		if index >= len(parts) do break
		chain_end := index + 1
		for chain_end < len(parts) && parts[chain_end].adjacent do chain_end += 1
		chain := parts[index:chain_end]
		matched := false
		if parts[index].adjacent {
			end, matched = seq_match_chain(text, skip_spaces(text, pos), chain)
		} else {
			for candidate in pos ..< len(text) {
				end, matched = seq_match_chain(text, candidate, chain)
				if matched do break
			}
		}
		if !matched do return pos, false
		pos = end
		index = chain_end
	}
	assert(index == len(parts), "seq_match: parts left unconsumed")
	return pos, true
}

// seq_match_chain matches an anchor at exactly `pos` followed by its adjacent
// parts separated only by spaces and tabs.
@(private = "file")
seq_match_chain :: proc(text: string, pos: int, chain: []Seq_Part) -> (end: int, ok: bool) {
	assert(len(chain) > 0, "seq_match_chain: empty chain")
	end, ok = seq_match_at(text, pos, chain[0])
	if !ok do return pos, false
	for part in chain[1:] {
		at := skip_spaces(text, end)
		end, ok = seq_match_at(text, at, part)
		if !ok do return pos, false
	}
	return end, true
}

seq_in :: proc(text: string, specs: []string) -> bool {
	_, ok := seq_match(text, specs)
	return ok
}

// seq_in_lines reports whether any line matches the sequence.
seq_in_lines :: proc(lines: []string, specs: []string) -> bool {
	for line in lines {
		if seq_in(line, specs) do return true
	}
	return false
}

// seq_in_lines_any tries each alternative head followed by the shared tail,
// for patterns like `(assert|ensure|if)\s*\( ...`.
seq_in_lines_any :: proc(lines: []string, heads: []string, tail: []string) -> bool {
	assert(len(heads) > 0, "seq_in_lines_any: no heads")
	specs := make([dynamic]string, context.temp_allocator)
	for head in heads {
		clear(&specs)
		append(&specs, head)
		append(&specs, ..tail)
		if seq_in_lines(lines, specs[:]) do return true
	}
	return false
}

// split_lines splits on '\n' keeping a trailing partial line, which is how a
// prefix cut mid-line must behave for "same line" scans.
split_lines :: proc(text: string, allocator := context.temp_allocator) -> []string {
	return strings.split(text, "\n", allocator)
}

// strip_spaces removes every space and tab so loosely formatted comparisons
// such as `0 <= low` and `0<=low` compare equal.
strip_spaces :: proc(text: string, allocator := context.temp_allocator) -> string {
	builder := strings.builder_make(allocator)
	for char in text {
		if char != ' ' && char != '\t' do strings.write_rune(&builder, char)
	}
	return strings.to_string(builder)
}

// count_call_shapes counts `ident(` occurrences (identifier, optional
// spaces, open parenthesis) in `text`.
count_call_shapes :: proc(text: string) -> int {
	count := 0
	for index in 0 ..< len(text) {
		if text[index] != '(' do continue
		back := index - 1
		for back >= 0 && is_space_byte(text[back]) do back -= 1
		if back >= 0 && is_word_byte(text[back]) do count += 1
	}
	return count
}

// is_dotted_ident reports `a`, `a.b`, `a.b.c` shapes.
is_dotted_ident :: proc(text: string) -> bool {
	if text == "" do return false
	expect_ident := true
	for char, index in text {
		if expect_ident {
			if !(char == '_' || (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z')) {
				return false
			}
			expect_ident = false
			continue
		}
		if char == '.' {
			expect_ident = true
			continue
		}
		if !is_word_byte(text[index]) do return false
	}
	return !expect_ident
}

is_all_digits :: proc(text: string) -> bool {
	if text == "" do return false
	for char in text {
		if char < '0' || char > '9' do return false
	}
	return true
}

is_upper_const :: proc(text: string) -> bool {
	if text == "" || !is_upper_byte(text[0]) do return false
	for char in text[1:] {
		if !(char == '_' || (char >= 'A' && char <= 'Z') || (char >= '0' && char <= '9')) do return false
	}
	return true
}

leaf_of_dotted :: proc(text: string) -> string {
	index := strings.last_index_byte(text, '.')
	return index < 0 ? text : text[index + 1:]
}

first_of_dotted :: proc(text: string) -> string {
	index := strings.index_byte(text, '.')
	return index < 0 ? text : text[:index]
}

// any_line reports whether any line of `text` matches the sequence.
any_line :: proc(text: string, specs: []string) -> bool {
	return seq_in_lines(split_lines(text), specs)
}

// any_line_heads tries each head followed by the shared tail on every line.
any_line_heads :: proc(text: string, heads: []string, tail: []string) -> bool {
	return seq_in_lines_any(split_lines(text), heads, tail)
}

// spec_* build dynamic specs for identifiers taken from the source being
// checked: plain substring, word-bounded, and their adjacent variants.
spec_plain :: proc(text: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"=", text}, allocator)
}

spec_adjacent :: proc(text: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"~=", text}, allocator)
}

spec_word :: proc(text: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"!", text}, allocator)
}

spec_adj_word :: proc(text: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({"~!", text}, allocator)
}

// specs concatenates spec lists into one temp-allocated slice.
specs :: proc(parts: ..[]string) -> []string {
	total := 0
	for part in parts do total += len(part)
	out := make([]string, total, context.temp_allocator)
	index := 0
	for part in parts {
		for spec in part {
			out[index] = spec
			index += 1
		}
	}
	assert(index == total, "specs: count drifted")
	return out
}

// contains_any reports whether any of `needles` is a substring of `text`.
contains_any :: proc(text: string, needles: []string) -> bool {
	for needle in needles {
		if strings.contains(text, needle) do return true
	}
	return false
}

parse_uint :: proc(text: string) -> (value: int, ok: bool) {
	if !is_all_digits(text) do return 0, false
	for char in text {
		value = value * 10 + int(char - '0')
		if value > 1 << 40 do return 0, false
	}
	return value, true
}
