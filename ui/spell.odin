package ui

// OS-native spellchecking for the chat composer.
//
// The shared API below delegates to a per-platform backend:
//   - macOS:   NSSpellChecker (spell_darwin.odin)
//   - Windows: ISpellChecker COM, Windows 8+ (spell_windows.odin)
//   - other:   no-op stubs (spell_other.odin) — spellcheck silently disabled.
//
// Word results are memoized so the per-frame composer scan only pays for
// words it has not seen before. A session-scoped ignore set backs the
// "Ignore" action in the suggestions menu; "Learn" goes to the OS user
// dictionary via the backend.

import "core:strings"

// Cap mirrors MEASURE_CACHE_MAX-style half-eviction caches elsewhere; a full
// clear is fine here because entries are cheap to recompute.
SPELL_CACHE_MAX :: 4096
SPELL_MAX_SUGGESTIONS :: 5

@(private = "file") spell_initialized: bool
@(private = "file") spell_ok: bool
@(private = "file") spell_word_cache: map[string]bool // word -> correctly spelled
@(private = "file") spell_ignored: map[string]bool // session-scope ignores

// spell_init lazily initialises the platform backend. Idempotent.
spell_init :: proc() {
	if spell_initialized do return
	spell_initialized = true
	spell_ok = _spell_backend_init()
}

// spell_available reports whether a working spellcheck backend exists.
spell_available :: proc() -> bool {
	spell_init()
	return spell_ok
}

// spell_check_word reports whether `word` is correctly spelled. Words are
// reported as correct when no backend is available or the word was ignored
// this session. Results are cached.
spell_check_word :: proc(word: string) -> bool {
	if !spell_available() do return true
	if word in spell_ignored do return true
	if ok, hit := spell_word_cache[word]; hit do return ok
	ok := _spell_backend_check(word)
	if len(spell_word_cache) >= SPELL_CACHE_MAX {
		clear(&spell_word_cache)
	}
	spell_word_cache[strings.clone(word)] = ok
	return ok
}

// spell_suggest returns up to SPELL_MAX_SUGGESTIONS replacement guesses for a
// misspelled word. Strings are allocated with `allocator`.
spell_suggest :: proc(word: string, allocator := context.allocator) -> []string {
	if !spell_available() do return nil
	return _spell_backend_suggest(word, allocator)
}

// spell_learn adds the word to the OS user dictionary and drops any stale
// cache entry so it is immediately considered correct.
spell_learn :: proc(word: string) {
	if !spell_available() do return
	_spell_backend_learn(word)
	delete_key(&spell_word_cache, word)
}

// spell_ignore_session hides squiggles for this word until the app restarts.
spell_ignore_session :: proc(word: string) {
	spell_ignored[strings.clone(word)] = true
}
