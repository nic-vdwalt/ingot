package ui

// Composer spellchecking: tokenizes the chat input, checks each word via the
// OS backend (spell.odin), and returns misspelled byte ranges for squiggle
// rendering. The scan is memoized on (text hash, len, caret, pill count) so
// an unchanged composer costs nothing per frame.

import rl "ingot:gfx"

// A misspelled word as a byte range [start, end) into the composer text.
Spell_Range :: struct {
	start: int,
	end:   int,
}

SPELL_SQUIGGLE_COLOR :: rl.Color{235, 90, 90, 220}

// Skip spellchecking entirely for very large drafts (e.g. a big paste): the
// per-word OS checker roundtrips would stall the frame loop on every edit
// and caret move. Squiggles simply disappear above this size.
SPELL_MAX_TEXT :: 8 * 1024

@(private = "file")
SC_Key :: struct {
	hash:  u64,
	len:   int,
	caret: int,
	pills: int,
}
@(private = "file") sc_key: SC_Key
@(private = "file") sc_valid: bool
@(private = "file") sc_ranges: [dynamic]Spell_Range

// spellcheck_invalidate drops the memoized scan so the next frame rescans
// even if the composer text is unchanged (needed after Learn/Ignore).
spellcheck_invalidate :: proc() {
	sc_valid = false
}

// spellcheck_ranges returns the misspelled ranges for the composer text.
// The word containing the caret is never flagged (no squiggle mid-typing);
// pill spans (@-mention paths) and "/command" composers are skipped.
spellcheck_ranges :: proc(text: string, caret: int, pills: ^[dynamic]Mention_Span) -> []Spell_Range {
	if !spell_available() do return nil
	if len(text) > SPELL_MAX_TEXT do return nil
	npills := 0
	if pills != nil do npills = len(pills)
	key := SC_Key{fnv1a64(text), len(text), caret, npills}
	if sc_valid && key == sc_key do return sc_ranges[:]
	sc_key = key
	sc_valid = true
	clear(&sc_ranges)
	if len(text) == 0 do return sc_ranges[:]
	// Command mode: "/command" composers are not prose.
	if text[0] == '/' do return sc_ranges[:]

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
		if end - start < 2 do continue
		if spell_skip_token(text, start, end) do continue
		// Never flag the word being typed; recheck once the caret leaves it.
		if caret >= start && caret <= end do continue
		if spell_in_pill(pills, start, end) do continue
		if spell_check_word(text[start:end]) do continue
		append(&sc_ranges, Spell_Range{start, end})
	}
	return sc_ranges[:]
}

// spellcheck_word_at returns the token bounds at a byte offset and whether it
// is a checkable, misspelled word. Unlike spellcheck_ranges this does not
// exclude the caret word, so right-click works on the word being typed.
spellcheck_word_at :: proc(text: string, off: int, pills: ^[dynamic]Mention_Span) -> (start, end: int, misspelled: bool) {
	if !spell_available() do return 0, 0, false
	if len(text) > SPELL_MAX_TEXT do return 0, 0, false
	if len(text) == 0 || len(text) > 0 && text[0] == '/' do return 0, 0, false
	o := off
	if o < 0 do o = 0
	if o > len(text) do o = len(text)
	// Snap to the token under/before the offset.
	if o >= len(text) || !spell_word_byte(text[o]) {
		if o == 0 || !spell_word_byte(text[o - 1]) do return 0, 0, false
		o -= 1
	}
	start = o
	for start > 0 && spell_word_byte(text[start - 1]) do start -= 1
	end = o
	for end < len(text) && spell_word_byte(text[end]) do end += 1
	start, end = spell_trim_token(text, start, end)
	if end - start < 2 do return 0, 0, false
	if spell_skip_token(text, start, end) do return 0, 0, false
	if spell_in_pill(pills, start, end) do return 0, 0, false
	return start, end, !spell_check_word(text[start:end])
}

// Word bytes: letters, digits, underscore, apostrophe, and UTF-8 continuation
// or lead bytes. Digits/underscores make identifiers form one token which is
// then rejected whole by spell_skip_token instead of leaking fragments.
@(private = "file")
spell_word_byte :: proc(c: u8) -> bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z':
		return true
	case c >= '0' && c <= '9':
		return true
	case c == '_' || c == '\'':
		return true
	case c >= 0x80:
		return true
	}
	return false
}

// Strip leading/trailing apostrophes ("'tis", "users'").
@(private = "file")
spell_trim_token :: proc(text: string, start, end: int) -> (int, int) {
	s, e := start, end
	for s < e && text[s] == '\'' do s += 1
	for e > s && text[e - 1] == '\'' do e -= 1
	return s, e
}

// Punctuation that joins word fragments into larger tokens (URLs, paths,
// emails, dotted names) that should not be spellchecked piecewise.
@(private = "file")
spell_join_punct :: proc(c: u8) -> bool {
	switch c {
	case '.', '/', '\\', ':', '-', '@', '#', '~':
		return true
	}
	return false
}

// spell_skip_token rejects tokens that are not prose words: identifiers
// (digits/underscores/camelCase), acronyms (all caps), and fragments of
// larger dotted/slashed tokens like "example.com" or "src/main.odin".
@(private = "file")
spell_skip_token :: proc(text: string, start, end: int) -> bool {
	upper := 0
	inner_upper := false
	for i in start ..< end {
		c := text[i]
		if (c >= '0' && c <= '9') || c == '_' do return true
		if c >= 'A' && c <= 'Z' {
			upper += 1
			if i > start do inner_upper = true
		}
	}
	// All-caps acronyms (API, TODO) and camelCase identifiers.
	if upper == end - start do return true
	if inner_upper do return true
	// Joined to an adjacent word by punctuation without whitespace on the
	// far side: part of a URL/path/email — skip. A sentence-ending period
	// ("word. Next") is not followed directly by a word byte, so it stays.
	if start >= 2 && spell_join_punct(text[start - 1]) && spell_word_byte(text[start - 2]) do return true
	if end + 1 < len(text) && spell_join_punct(text[end]) && spell_word_byte(text[end + 1]) do return true
	// Mentions/tags: "@name", "#topic".
	if start >= 1 && (text[start - 1] == '@' || text[start - 1] == '#') do return true
	return false
}

@(private = "file")
spell_in_pill :: proc(pills: ^[dynamic]Mention_Span, start, end: int) -> bool {
	if pills == nil do return false
	for p in pills {
		if start < p.end && end > p.start do return true
	}
	return false
}

// draw_squiggle draws a wavy underline spanning w pixels starting at (x, y).
draw_squiggle :: proc(x, y, w: i32, color: rl.Color) {
	if w <= 1 do return
	amp: f32 = 1.5
	half: f32 = 3 // px per half zigzag period
	x0 := f32(x)
	x1 := x0 + f32(w)
	yf := f32(y)
	up := true
	for cx := x0; cx < x1; cx += half {
		nx := min(cx + half, x1)
		ya := yf + (amp if up else -amp)
		yb := yf + (-amp if up else amp)
		rl.DrawLineEx({cx, ya}, {nx, yb}, 1.2, color)
		up = !up
	}
}
