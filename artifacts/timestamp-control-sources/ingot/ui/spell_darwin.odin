#+build darwin
package ui

// macOS spellcheck backend: NSSpellChecker via the Objective-C runtime.
//
// AppKit is already loaded (raylib runs on Cocoa), so no extra linkage is
// needed. All calls run on the main thread inside the frame loop, which is
// what NSSpellChecker expects. Autoreleased return values (guess arrays) are
// drained with a scoped pool so nothing accumulates under GLFW's event pump.

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

@(objc_class = "NSSpellChecker")
NS_Spell_Checker :: struct {
	using _: intrinsics.objc_object,
}

// NSNotFound: checkSpellingOfString: returns it as the range location when no
// misspelling was found.
@(private = "file")
NS_NOT_FOUND :: NS.UInteger(max(NS.Integer))

// AppKit exposes one shared process spell checker. Runtime-owned Spell_System
// values retain independent caches, ignored words, and generations.
@(private = "file")
g_spell_checker: ^NS_Spell_Checker

_spell_backend_init :: proc() -> bool {
	g_spell_checker = intrinsics.objc_send(
		^NS_Spell_Checker,
		NS_Spell_Checker,
		"sharedSpellChecker",
	)
	return g_spell_checker != nil
}

_spell_backend_check :: proc(word: string) -> bool {
	if g_spell_checker == nil do return true
	pool := NS.AutoreleasePool_alloc()->init()
	defer pool->drain()
	ns := NS.String_alloc()->initWithOdinString(word)
	defer ns->release()
	r := intrinsics.objc_send(
		NS.Range,
		g_spell_checker,
		"checkSpellingOfString:startingAt:",
		ns,
		NS.Integer(0),
	)
	return r.location == NS_NOT_FOUND
}

_spell_backend_suggest :: proc(word: string, allocator := context.allocator) -> []string {
	if g_spell_checker == nil do return nil
	pool := NS.AutoreleasePool_alloc()->init()
	defer pool->drain()
	ns := NS.String_alloc()->initWithOdinString(word)
	defer ns->release()
	rng := NS.Range{0, ns->length()}
	guesses := intrinsics.objc_send(
		^NS.Array,
		g_spell_checker,
		"guessesForWordRange:inString:language:inSpellDocumentWithTag:",
		rng,
		ns,
		(^NS.String)(nil), // automatic language
		NS.Integer(0),
	)
	if guesses == nil do return nil
	n := min(int(guesses->count()), SPELL_MAX_SUGGESTIONS)
	if n == 0 do return nil
	out := make([]string, n, allocator)
	for i in 0 ..< n {
		s := (^NS.String)(guesses->object(NS.UInteger(i)))
		out[i] = strings.clone(s->odinString(), allocator)
	}
	return out
}

_spell_backend_learn :: proc(word: string) {
	if g_spell_checker == nil do return
	ns := NS.String_alloc()->initWithOdinString(word)
	defer ns->release()
	intrinsics.objc_send(nil, g_spell_checker, "learnWord:", ns)
}
