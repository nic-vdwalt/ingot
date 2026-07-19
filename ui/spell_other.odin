#+build !darwin
#+build !windows
package ui

// Stub spellcheck backend for platforms without a native spellchecker
// integration (Linux, BSD). spell_available() reports false and the composer
// renders without squiggles.

_spell_backend_init :: proc() -> bool {
	return false
}

_spell_backend_check :: proc(word: string) -> bool {
	return true
}

_spell_backend_suggest :: proc(word: string, allocator := context.allocator) -> []string {
	return nil
}

_spell_backend_learn :: proc(word: string) {
}
