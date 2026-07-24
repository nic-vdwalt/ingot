package ui

import "core:strings"


Spell_Range :: struct {
	start: int,
	end:   int,
}

SPELL_SQUIGGLE_COLOR :: Color{235, 90, 90, 220}
SPELL_MAX_TEXT :: 8 * 1024

Spellcheck_Memo :: struct {
	text:       string,
	caret:      int,
	pills:      []Mention_Span,
	generation: u64,
	ranges:     [dynamic]Spell_Range,
	valid:      bool,
}

spellcheck_memo_destroy :: proc(memo: ^Spellcheck_Memo) {
	assert(memo != nil, "spellcheck_memo_destroy: nil memo")
	delete(memo.text)
	delete(memo.pills)
	delete(memo.ranges)
	memo^ = {}
}

@(private)
spellcheck_pills_equal :: proc(a: []Mention_Span, b: ^[dynamic]Mention_Span) -> bool {
	if b == nil do return len(a) == 0
	if len(a) != len(b) do return false
	for span, i in a {
		if span != b[i] do return false
	}
	return true
}

@(private)
spellcheck_memo_set_key :: proc(
	memo: ^Spellcheck_Memo,
	text: string,
	caret: int,
	pills: ^[dynamic]Mention_Span,
	generation: u64,
) {
	delete(memo.text)
	delete(memo.pills)
	memo.text = strings.clone(text)
	memo.caret = caret
	memo.generation = generation
	if pills != nil && len(pills) > 0 {
		memo.pills = make([]Mention_Span, len(pills))
		copy(memo.pills, pills[:])
	}
	memo.valid = true
}

spellcheck_ranges_with :: proc(
	system: ^Spell_System,
	memo: ^Spellcheck_Memo,
	text: string,
	caret: int,
	pills: ^[dynamic]Mention_Span,
) -> []Spell_Range {
	assert(system != nil && memo != nil, "spellcheck_ranges_with: nil system or memo")
	if !spell_available_with(system) || len(text) > SPELL_MAX_TEXT {
		clear(&memo.ranges)
		memo.valid = false
		return nil
	}
	if memo.valid &&
	   memo.text == text &&
	   memo.caret == caret &&
	   memo.generation == system.generation &&
	   spellcheck_pills_equal(memo.pills, pills) {
		return memo.ranges[:]
	}
	spellcheck_memo_set_key(memo, text, caret, pills, system.generation)
	clear(&memo.ranges)
	if len(text) == 0 || text[0] == '/' do return memo.ranges[:]
	i := 0
	for i < len(text) {
		if !spell_word_byte(text[i]) {
			i += 1
			continue
		}
		start := i
		for i < len(text) && spell_word_byte(text[i]) do i += 1
		end := i
		start, end = spell_trim_token(text, start, end)
		if end - start < 2 || spell_skip_token(text, start, end) do continue
		if caret >= start && caret <= end do continue
		if spell_in_pill(pills, start, end) do continue
		if spell_check_word_with(system, text[start:end]) do continue
		append(&memo.ranges, Spell_Range{start, end})
	}
	return memo.ranges[:]
}

spellcheck_word_at_with :: proc(
	system: ^Spell_System,
	text: string,
	off: int,
	pills: ^[dynamic]Mention_Span,
) -> (
	start, end: int,
	misspelled: bool,
) {
	assert(system != nil, "spellcheck_word_at_with: nil system")
	if !spell_available_with(system) || len(text) > SPELL_MAX_TEXT do return 0, 0, false
	if len(text) == 0 || text[0] == '/' do return 0, 0, false
	o := clamp(off, 0, len(text))
	if o >= len(text) || !spell_word_byte(text[o]) {
		if o == 0 || !spell_word_byte(text[o - 1]) do return 0, 0, false
		o -= 1
	}
	start = o
	for start > 0 && spell_word_byte(text[start - 1]) do start -= 1
	end = o
	for end < len(text) && spell_word_byte(text[end]) do end += 1
	start, end = spell_trim_token(text, start, end)
	if end - start < 2 || spell_skip_token(text, start, end) do return 0, 0, false
	if spell_in_pill(pills, start, end) do return 0, 0, false
	return start, end, !spell_check_word_with(system, text[start:end])
}

@(private)
spell_word_byte :: proc(c: u8) -> bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	case c == '_' || c == '\'' || c >= 0x80:
		return true
	}
	return false
}

@(private)
spell_trim_token :: proc(text: string, start, end: int) -> (int, int) {
	s, e := start, end
	for s < e && text[s] == '\'' do s += 1
	for e > s && text[e - 1] == '\'' do e -= 1
	return s, e
}

@(private)
spell_join_punct :: proc(c: u8) -> bool {
	switch c {
	case '.', '/', '\\', ':', '-', '@', '#', '~':
		return true
	}
	return false
}

@(private)
spell_skip_token :: proc(text: string, start, end: int) -> bool {
	upper := 0
	inner_upper := false
	for i in start ..< end {
		c := text[i]
		if c >= '0' && c <= '9' || c == '_' do return true
		if c >= 'A' && c <= 'Z' {
			upper += 1
			if i > start do inner_upper = true
		}
	}
	if upper == end - start || inner_upper do return true
	if start >= 2 && spell_join_punct(text[start - 1]) && spell_word_byte(text[start - 2]) do return true
	if end + 1 < len(text) && spell_join_punct(text[end]) && spell_word_byte(text[end + 1]) do return true
	if start >= 1 && (text[start - 1] == '@' || text[start - 1] == '#') do return true
	return false
}

@(private)
spell_in_pill :: proc(pills: ^[dynamic]Mention_Span, start, end: int) -> bool {
	if pills == nil do return false
	for pill in pills {
		if start < pill.end && end > pill.start do return true
	}
	return false
}

draw_squiggle :: proc(x, y, w: i32, color: Color) {
	if w <= 1 do return
	amp: f32 = 1.5
	half: f32 = 3
	x0 := f32(x)
	x1 := x0 + f32(w)
	yf := f32(y)
	up := true
	for cx := x0; cx < x1; cx += half {
		nx := min(cx + half, x1)
		ya := yf + (amp if up else -amp)
		yb := yf + (-amp if up else amp)
		draw_line_ex(frame, {cx, ya}, {nx, yb}, 1.2, color)
		up = !up
	}
}
