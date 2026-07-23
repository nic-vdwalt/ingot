package ui

import "core:strings"

SPELL_CACHE_MAX :: 4096
SPELL_MAX_SUGGESTIONS :: 5

Spell_System :: struct {
	initialized: bool,
	available:   bool,
	word_cache:  map[string]bool,
	ignored:     map[string]bool,
	generation:  u64,
}

@(private)
default_spell_system: Spell_System

spell_available_with :: proc(system: ^Spell_System) -> bool {
	assert(system != nil, "spell_available_with: nil system")
	if !system.initialized {
		system.initialized = true
		system.available = _spell_backend_init()
	}
	return system.available
}

spell_available :: proc() -> bool {
	return spell_available_with(&default_spell_system)
}

spell_check_word_with :: proc(system: ^Spell_System, word: string) -> bool {
	assert(system != nil, "spell_check_word_with: nil system")
	if !spell_available_with(system) do return true
	if word in system.ignored do return true
	if ok, hit := system.word_cache[word]; hit do return ok
	ok := _spell_backend_check(word)
	if len(system.word_cache) >= SPELL_CACHE_MAX {
		for key in system.word_cache do delete(key)
		delete(system.word_cache)
		system.word_cache = nil
	}
	system.word_cache[strings.clone(word)] = ok
	return ok
}

spell_check_word :: proc(word: string) -> bool {
	return spell_check_word_with(&default_spell_system, word)
}

spell_suggest_with :: proc(
	system: ^Spell_System,
	word: string,
	allocator := context.allocator,
) -> []string {
	assert(system != nil, "spell_suggest_with: nil system")
	if !spell_available_with(system) do return nil
	return _spell_backend_suggest(word, allocator)
}

spell_suggest :: proc(word: string, allocator := context.allocator) -> []string {
	return spell_suggest_with(&default_spell_system, word, allocator)
}

spell_learn_with :: proc(system: ^Spell_System, word: string) {
	assert(system != nil, "spell_learn_with: nil system")
	if !spell_available_with(system) do return
	_spell_backend_learn(word)
	if key, ok := system.word_cache[word]; ok {
		_ = key
		for owned in system.word_cache {
			if owned == word {
				delete_key(&system.word_cache, owned)
				delete(owned)
				break
			}
		}
	}
	system.generation += 1
}

spell_learn :: proc(word: string) {
	spell_learn_with(&default_spell_system, word)
}

spell_ignore_session_with :: proc(system: ^Spell_System, word: string) {
	assert(system != nil, "spell_ignore_session_with: nil system")
	if word not_in system.ignored do system.ignored[strings.clone(word)] = true
	system.generation += 1
}

spell_ignore_session :: proc(word: string) {
	spell_ignore_session_with(&default_spell_system, word)
}

spell_system_destroy :: proc(system: ^Spell_System) {
	assert(system != nil, "spell_system_destroy: nil system")
	for key in system.word_cache do delete(key)
	for key in system.ignored do delete(key)
	delete(system.word_cache)
	delete(system.ignored)
	system^ = {}
}
