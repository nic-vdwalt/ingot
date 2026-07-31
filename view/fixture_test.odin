#+build !js
package view

import "core:testing"

// The committed fixture. It is embedded with #load rather than read from disk,
// which makes the test independent of the runner's working directory and
// exercises the same embedding path a web consumer must use, since there is no
// filesystem there to read a view from.
//
// Whether the generated .odin beside it is current is checked by the
// view/generate package, which owns the generator.
FIXTURE_INGV := #load("testdata/settings.ingv", []u8)

@(test)
test_committed_fixture_decodes_and_validates :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := new(View_Doc, context.temp_allocator)
	result, ok := view_decode(FIXTURE_INGV, doc)
	testing.expectf(t, ok, "committed fixture does not decode: %v", result)
	if !ok do return
	testing.expect(t, doc.count > 0, "committed fixture is empty")
	// A successful decode has already validated, so re-running it must agree.
	// Disagreement would mean validation is not deterministic, which would make
	// every other guarantee in the package conditional.
	validated, valid := view_validate(view_of(doc))
	testing.expectf(t, valid, "decoded fixture does not validate: %v", validated)
}

@(test)
test_committed_fixture_covers_the_interesting_shapes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := new(View_Doc, context.temp_allocator)
	_, ok := view_decode(FIXTURE_INGV, doc)
	testing.expect(t, ok, "committed fixture does not decode")
	if !ok do return

	// The fixture is the shared input for the round-trip and generator tests,
	// so it has to keep exercising a container, a flex run with tracks, a
	// binding, and a presentational node. A fixture that quietly narrowed would
	// weaken several tests at once without failing any of them.
	seen: [View_Kind]bool
	bound := 0
	tracked := 0
	for index in 0 ..< int(doc.count) {
		node := doc.nodes[index]
		seen[node.kind] = true
		if node.binding != VIEW_BINDING_NONE do bound += 1
		if node.track != {} do tracked += 1
	}
	testing.expect(t, seen[.Panel], "fixture lost its container")
	testing.expect(t, seen[.Flex_Row], "fixture lost its flex run")
	testing.expect(t, seen[.Button], "fixture lost its buttons")
	testing.expect(t, seen[.Section_Header], "fixture lost its presentational node")
	testing.expect(t, bound >= 2, "fixture lost its bindings")
	testing.expect(t, tracked >= 2, "fixture lost its declared tracks")
}
