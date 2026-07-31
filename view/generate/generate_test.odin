#+build !js
package view_generate

import "core:strings"
import "core:testing"
import "ingot:ui"
import "ingot:view"

// The generator's contract, checked here:
//
//   - Its output is valid Odin that a consumer can compile. check.sh builds the
//     committed fixture as a consumer would, which is the compile-level proof.
//   - Its output obeys the repository's physical style limits and odinfmt's
//     canonical form, rather than being excluded from the gate. A generator
//     that emits unformattable code makes every consumer's check.sh fail, which
//     is worse than failing here.
//   - It emits the array at its exact length. A [512]View_Node literal would put
//     ~69 KB of mostly zeros into .data and fail check_wasm_bloat.py.

@(private = "file")
fixture_doc :: proc(doc: ^view.View_Doc) {
	assert(doc != nil, "fixture_doc: nil doc")
	view.doc_reset(doc)
	root, _ := view.doc_add_keyed(
		doc,
		view.VIEW_NODE_NONE,
		.Panel,
		"root",
		"",
		view.View_Node{gap = .MD, padding = .LG},
	)
	view.doc_add_keyed(doc, root, .Section_Header, "", "Settings")
	view.doc_add_keyed(doc, root, .Checkbox, "enabled", "Enabled", view.View_Node{binding = 0})
	view.doc_add_keyed(
		doc,
		root,
		.Slider,
		"volume",
		"Volume",
		view.View_Node{binding = 1, number_hi = 1, number_step = 0.05},
	)
	row, _ := view.doc_add_keyed(
		doc,
		root,
		.Flex_Row,
		"actions",
		"",
		view.View_Node{size_main = 32, gap = .SM},
	)
	view.doc_add_keyed(
		doc,
		row,
		.Button,
		"save",
		"Save",
		view.View_Node{style = .Primary, track = ui.Track{kind = .Grow, weight = 1}},
	)
	view.doc_add_keyed(
		doc,
		row,
		.Button,
		"cancel",
		"Cancel",
		view.View_Node{style = .Ghost, track = ui.Track{kind = .Fixed, basis = 80}},
	)
}

@(private = "file")
generate_named :: proc(doc: ^view.View_Doc, symbol: string) -> string {
	assert(doc != nil, "generate_named: nil doc")
	builder := strings.builder_make(context.temp_allocator)
	ok := generate(&builder, view.view_of(doc), Generate_Options{symbol = symbol})
	assert(ok, "generate_named: generation failed")
	return strings.to_string(builder)
}

@(private = "file")
generate_fixture :: proc(doc: ^view.View_Doc) -> string {
	assert(doc != nil, "generate_fixture: nil doc")
	builder := strings.builder_make(context.temp_allocator)
	ok := generate(
		&builder,
		view.view_of(doc),
		Generate_Options {
			package_name = "views",
			symbol = "settings",
			source_path = "settings.ingv",
		},
	)
	assert(ok, "generate_fixture: generation failed")
	return strings.to_string(builder)
}

@(test)
test_generate_output_obeys_the_column_limit :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: view.View_Doc
	fixture_doc(&doc)
	source := generate_fixture(&doc)
	line := 1
	width := 0
	for index in 0 ..< len(source) {
		if source[index] == '\n' {
			testing.expectf(
				t,
				width <= GENERATE_LINE_COLUMNS,
				"line %d is %d columns",
				line,
				width,
			)
			line += 1
			width = 0
			continue
		}
		width += 1
	}
	testing.expect(t, width <= GENERATE_LINE_COLUMNS, "final line is too wide")
}

@(test)
test_generate_output_is_tab_indented :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: view.View_Doc
	fixture_doc(&doc)
	source := generate_fixture(&doc)
	// A leading space would fail odinfmt in the consumer's tree, where the file
	// is just another checked-in source file.
	at_line_start := true
	for index in 0 ..< len(source) {
		if at_line_start {
			testing.expectf(t, source[index] != ' ', "line indented with a space at %d", index)
		}
		at_line_start = source[index] == '\n'
	}
}

@(test)
test_generate_emits_the_exact_node_count :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: view.View_Doc
	fixture_doc(&doc)
	source := generate_fixture(&doc)
	// The literal must be sized to the document, never to the authoring
	// capacity: that is the whole reason View and View_Doc are separate types.
	testing.expect(t, strings.contains(source, "[7]view.View_Node"), "wrong array length")
	testing.expect(
		t,
		!strings.contains(source, "[512]view.View_Node"),
		"emitted the authoring capacity, which would bloat .data",
	)
}

@(test)
test_generate_is_deterministic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: view.View_Doc
	fixture_doc(&doc)
	first := strings.clone(generate_fixture(&doc), context.temp_allocator)
	second := generate_fixture(&doc)
	testing.expect_value(t, second, first)
}

@(test)
test_generate_rejects_an_unusable_symbol :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: view.View_Doc
	fixture_doc(&doc)
	unusable := [?]string{"", "9lives", "has space", "has-dash", "has.dot"}
	for name in unusable {
		builder := strings.builder_make(context.temp_allocator)
		ok := generate(&builder, view.view_of(&doc), Generate_Options{symbol = name})
		testing.expectf(t, !ok, "symbol %q should have been rejected", name)
	}
}

@(test)
test_generate_escapes_hostile_text :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc: view.View_Doc
	view.doc_reset(&doc)
	// A label containing a quote, a backslash and a newline must not be able to
	// break out of the string literal. A builder cannot stop a user typing
	// these, so the generator has to handle them.
	view.doc_add_keyed(&doc, view.VIEW_NODE_NONE, .Label, "", "say \"hi\"\\\nnow\x00\xff")
	source := generate_fixture(&doc)
	testing.expect(t, strings.contains(source, "\\\""), "quote was not escaped")
	testing.expect(t, strings.contains(source, "\\\\"), "backslash was not escaped")
	testing.expect(t, strings.contains(source, "\\n"), "newline was not escaped")
	testing.expect(t, strings.contains(source, "\\x00"), "NUL was not escaped")
	testing.expect(t, strings.contains(source, "\\xff"), "high byte was not escaped")
	// The text literal must carry exactly two unescaped quotes: its delimiters.
	// Scoped to that one line, because the file's import clause has quotes of
	// its own and counting the whole source would always find them.
	line, found := find_line(source, "_text :: ")
	testing.expect(t, found, "no text literal in the generated source")
	quotes := 0
	for index in 0 ..< len(line) {
		if line[index] != '"' do continue
		if index > 0 && line[index - 1] == '\\' do continue
		quotes += 1
	}
	testing.expect_value(t, quotes, 2)
}

@(test)
test_digest_changes_with_content :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	original: view.View_Doc
	fixture_doc(&original)
	base := view_digest(view.view_of(&original))

	changed: view.View_Doc
	fixture_doc(&changed)
	changed.nodes[1].ink = .Danger
	testing.expect(t, view_digest(view.view_of(&changed)) != base, "digest ignored a change")

	same: view.View_Doc
	fixture_doc(&same)
	testing.expect_value(t, view_digest(view.view_of(&same)), base)
}

@(private = "file")
find_line :: proc(source: string, needle: string) -> (line: string, found: bool) {
	start := 0
	for index in 0 ..< len(source) {
		if source[index] != '\n' do continue
		candidate := source[start:index]
		if strings.contains(candidate, needle) do return candidate, true
		start = index + 1
	}
	return "", false
}

// unescape_odin_string is a reference decoder for the escapes the generator
// emits. It exists so the escaper can be checked over every byte value without
// invoking the compiler; the compile-level proof is the committed fixture,
// which check.sh builds as a consumer would.
@(private = "file")
unescape_odin_string :: proc(literal: string) -> (out: []u8, ok: bool) {
	buffer := make([dynamic]u8, 0, len(literal), context.temp_allocator)
	index := 0
	for index < len(literal) {
		if literal[index] != '\\' {
			append(&buffer, literal[index])
			index += 1
			continue
		}
		if index + 1 >= len(literal) do return nil, false
		switch literal[index + 1] {
		case '"':
			append(&buffer, '"')
			index += 2
		case '\\':
			append(&buffer, '\\')
			index += 2
		case 'n':
			append(&buffer, '\n')
			index += 2
		case 't':
			append(&buffer, '\t')
			index += 2
		case 'r':
			append(&buffer, '\r')
			index += 2
		case 'x':
			if index + 3 >= len(literal) do return nil, false
			high := hex_value(literal[index + 2]) or_return
			low := hex_value(literal[index + 3]) or_return
			append(&buffer, high << 4 | low)
			index += 4
		case:
			return nil, false
		}
	}
	return buffer[:], true
}

@(private = "file")
hex_value :: proc(digit: u8) -> (value: u8, ok: bool) {
	switch digit {
	case '0' ..= '9':
		return digit - '0', true
	case 'a' ..= 'f':
		return digit - 'a' + 10, true
	case 'A' ..= 'F':
		return digit - 'A' + 10, true
	}
	return 0, false
}

@(test)
test_generate_escaping_round_trips_every_byte :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// Every byte 1..255 in one label. A single wrong escape anywhere corrupts a
	// shipped view silently, so the whole domain is checked rather than a
	// sample.
	original := make([]u8, 255, context.temp_allocator)
	for index in 0 ..< 255 do original[index] = u8(index + 1)

	doc := new(view.View_Doc, context.temp_allocator)
	view.doc_add_keyed(doc, view.VIEW_NODE_NONE, .Label, "", string(original))
	source := generate_named(doc, "probe")

	line, found := find_line(source, "_text :: ")
	testing.expect(t, found, "no text literal in the generated source")
	open_quote := strings.index_byte(line, '"')
	testing.expect(t, open_quote >= 0, "text literal has no opening quote")
	testing.expect(t, strings.has_suffix(line, "\""), "text literal has no closing quote")
	body := line[open_quote + 1:len(line) - 1]

	decoded, ok := unescape_odin_string(body)
	testing.expect(t, ok, "generated literal is not decodable")
	testing.expect_value(t, len(decoded), len(original))
	for index in 0 ..< min(len(decoded), len(original)) {
		testing.expectf(
			t,
			decoded[index] == original[index],
			"byte %d became %d",
			original[index],
			decoded[index],
		)
	}
}

// The committed fixture pair: the .ingv is the source of truth and the .odin
// beside it is what viewc produced from it. Regenerating and comparing is what
// stops the two drifting - a change to the generator that nobody reran viewc
// for fails here rather than shipping a stale file.
FIXTURE_INGV := #load("../testdata/settings.ingv", []u8)
FIXTURE_ODIN :: #load("../testdata/settings.odin", string)

@(test)
test_committed_fixture_is_current :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	doc := new(view.View_Doc, context.temp_allocator)
	result, ok := view.view_decode(FIXTURE_INGV, doc)
	testing.expectf(t, ok, "committed fixture does not decode: %v", result)
	if !ok do return

	builder := strings.builder_make(context.temp_allocator)
	generated := generate(
		&builder,
		view.view_of(doc),
		Generate_Options {
			package_name = "views",
			symbol = "settings",
			source_path = "settings.ingv",
		},
	)
	testing.expect(t, generated, "generation failed")
	testing.expect(
		t,
		strings.to_string(builder) == FIXTURE_ODIN,
		"view/testdata/settings.odin is stale; regenerate it with:\n" +
		"  odin run tools/viewc -collection:ingot=. -- view/testdata/settings.ingv \\\n" +
		"    -out:view/testdata/settings.odin -package:views -symbol:settings",
	)
}

// The document the fixture encodes must be the one this file builds, so a
// change to fixture_doc that nobody re-encoded is caught in the same run.
@(test)
test_committed_fixture_encodes_the_expected_document :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	decoded := new(view.View_Doc, context.temp_allocator)
	_, ok := view.view_decode(FIXTURE_INGV, decoded)
	testing.expect(t, ok, "committed fixture does not decode")
	if !ok do return

	expected := new(view.View_Doc, context.temp_allocator)
	fixture_doc(expected)
	testing.expect_value(t, decoded.count, expected.count)
	testing.expect_value(t, decoded.text_len, expected.text_len)
	for index in 0 ..< int(expected.count) {
		testing.expectf(
			t,
			decoded.nodes[index] == expected.nodes[index],
			"fixture node %d differs from the document this test builds",
			index,
		)
	}
}
