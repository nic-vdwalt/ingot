#+build !js
package ui

// Unit tests for the composer spellcheck tokenizer — the pure classification
// procs that decide which tokens reach the OS spell backend.

import "core:testing"

@(test)
spell_word_byte_classes :: proc(t: ^testing.T) {
	testing.expect(t, spell_word_byte('a'))
	testing.expect(t, spell_word_byte('Z'))
	testing.expect(t, spell_word_byte('5'))
	testing.expect(t, spell_word_byte('_'))
	testing.expect(t, spell_word_byte('\''))
	testing.expect(t, spell_word_byte(0xC3)) // UTF-8 lead byte
	testing.expect(t, !spell_word_byte(' '))
	testing.expect(t, !spell_word_byte('.'))
	testing.expect(t, !spell_word_byte('/'))
}

@(test)
spell_trim_token_strips_apostrophes :: proc(t: ^testing.T) {
	text := "''tis users''"
	s, e := spell_trim_token(text, 0, 5) // "''tis"
	testing.expect_value(t, text[s:e], "tis")
	s, e = spell_trim_token(text, 6, 13) // "users''"
	testing.expect_value(t, text[s:e], "users")
	// All-apostrophe tokens trim to empty.
	s, e = spell_trim_token("'''", 0, 3)
	testing.expect_value(t, e - s, 0)
}

@(test)
spell_skip_token_rejects_identifiers :: proc(t: ^testing.T) {
	// Digits and underscores mark identifiers.
	testing.expect(t, spell_skip_token("foo_bar", 0, 7))
	testing.expect(t, spell_skip_token("abc123", 0, 6))
	// All-caps acronyms and camelCase.
	testing.expect(t, spell_skip_token("API", 0, 3))
	testing.expect(t, spell_skip_token("camelCase", 0, 9))
	// Plain prose words pass.
	testing.expect(t, !spell_skip_token("hello", 0, 5))
	testing.expect(t, !spell_skip_token("Hello", 0, 5))
}

@(test)
spell_skip_token_rejects_joined_fragments :: proc(t: ^testing.T) {
	// Fragments of dotted/slashed tokens (URLs, paths, emails) are skipped.
	text := "example.com"
	testing.expect(t, spell_skip_token(text, 0, 7)) // "example" joined by '.'
	testing.expect(t, spell_skip_token(text, 8, 11)) // "com" after '.'
	path := "src/main"
	testing.expect(t, spell_skip_token(path, 0, 3))
	testing.expect(t, spell_skip_token(path, 4, 8))
	// A sentence-ending period does not join: "word. Next".
	sentence := "word. next"
	testing.expect(t, !spell_skip_token(sentence, 0, 4))
	// Mentions and tags are never prose.
	mention := "@name"
	testing.expect(t, spell_skip_token(mention, 1, 5))
}

@(test)
spell_in_pill_overlap :: proc(t: ^testing.T) {
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{5, 10})
	testing.expect(t, spell_in_pill(&pills, 5, 10))
	testing.expect(t, spell_in_pill(&pills, 8, 12)) // partial overlap counts
	testing.expect(t, !spell_in_pill(&pills, 0, 5)) // adjacency is not overlap
	testing.expect(t, !spell_in_pill(&pills, 10, 12))
	testing.expect(t, !spell_in_pill(nil, 0, 3))
}
