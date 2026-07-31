// viewc compiles a .ingv document into Odin source.
//
// The output is a static View literal plus a string constant, not unrolled
// widget calls: view.view_play stays the only implementation of what a node
// means, so there is no second emitter to drift from it. What the consumer
// gains is a zero-parse load and a compile-time check of every enum and bound,
// and a format change becomes a compile error rather than a decode failure.
//
// Usage:
//
//	viewc <input.ingv> -out:<output.odin> [-package:<name>] [-symbol:<name>]
//	viewc <input.ingv> -check -out:<output.odin>
//
// -check regenerates in memory and compares against the file on disk, exiting
// non-zero if they differ. That is what lets a test prove the committed
// generated source is current without the test needing to write anything.
package viewc

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "ingot:view"
import gen "ingot:view/generate"

Options :: struct {
	input:        string,
	output:       string,
	package_name: string,
	symbol:       string,
	check:        bool,
}

EXIT_OK :: 0
EXIT_USAGE :: 2
EXIT_FAILED :: 1
EXIT_STALE :: 3

main :: proc() {
	options, ok := parse_arguments(os.args[1:])
	if !ok {
		usage()
		os.exit(EXIT_USAGE)
	}
	os.exit(run(options))
}

run :: proc(options: Options) -> int {
	data, read_error := os.read_entire_file(options.input, context.allocator)
	if read_error != nil {
		fmt.eprintfln("viewc: cannot read %s: %v", options.input, read_error)
		return EXIT_FAILED
	}
	defer delete(data)

	// The document is heap-allocated because View_Doc carries the full authoring
	// capacity and would be a large stack frame for no reason.
	doc := new(view.View_Doc)
	defer free(doc)
	result, decode_ok := view.view_decode(data, doc)
	if !decode_ok {
		fmt.eprintfln("viewc: %s is not a valid view: %v", options.input, result.fault)
		if result.fault == .Invalid_Document {
			fmt.eprintfln("viewc:   %v at node %d", result.validate.fault, result.validate.node)
		}
		return EXIT_FAILED
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	generated := gen.generate(
		&builder,
		view.view_of(doc),
		gen.Generate_Options {
			package_name = options.package_name,
			symbol = options.symbol,
			source_path = filepath.base(options.input),
		},
	)
	if !generated {
		fmt.eprintfln(
			"viewc: cannot generate with package %q symbol %q",
			options.package_name,
			options.symbol,
		)
		return EXIT_FAILED
	}
	source := strings.to_string(builder)
	if options.check do return check_output(options.output, source)
	return write_output(options.output, source)
}

// check_output compares without writing, so the freshness test can run in a
// read-only checkout and so a stale file is reported rather than silently
// repaired during an unrelated build.
check_output :: proc(path: string, source: string) -> int {
	existing, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		fmt.eprintfln("viewc: cannot read %s; run viewc without -check", path)
		return EXIT_STALE
	}
	defer delete(existing)
	if string(existing) == source do return EXIT_OK
	fmt.eprintfln("viewc: %s is stale; regenerate it with viewc", path)
	return EXIT_STALE
}

write_output :: proc(path: string, source: string) -> int {
	write_error := os.write_entire_file(path, transmute([]u8)source)
	if write_error != nil {
		fmt.eprintfln("viewc: cannot write %s: %v", path, write_error)
		return EXIT_FAILED
	}
	return EXIT_OK
}

// parse_arguments takes the input path positionally and everything else as a
// -flag:value pair, matching how the fuzz harnesses in this repository read
// their options.
parse_arguments :: proc(args: []string) -> (options: Options, ok: bool) {
	options.package_name = "views"
	for argument in args {
		switch {
		case argument == "-check":
			options.check = true
		case strings.has_prefix(argument, "-out:"):
			options.output = argument[len("-out:"):]
		case strings.has_prefix(argument, "-package:"):
			options.package_name = argument[len("-package:"):]
		case strings.has_prefix(argument, "-symbol:"):
			options.symbol = argument[len("-symbol:"):]
		case strings.has_prefix(argument, "-"):
			fmt.eprintfln("viewc: unknown flag %s", argument)
			return options, false
		case options.input == "":
			options.input = argument
		case:
			fmt.eprintfln("viewc: unexpected argument %s", argument)
			return options, false
		}
	}
	if options.input == "" || options.output == "" do return options, false
	// Defaulting the symbol to the input's stem is what makes the common case a
	// one-flag invocation: viewc login.ingv -out:login.odin.
	if options.symbol == "" {
		stem := filepath.stem(filepath.base(options.input))
		options.symbol = stem
	}
	return options, options.symbol != ""
}

usage :: proc() {
	fmt.eprintln("usage: viewc <input.ingv> -out:<output.odin> [-package:name] [-symbol:name]")
	fmt.eprintln("       viewc <input.ingv> -check -out:<output.odin>")
	fmt.eprintln("")
	fmt.eprintln("  -out:PATH      where to write the generated Odin source (required)")
	fmt.eprintln("  -package:NAME  package clause for the generated file (default: views)")
	fmt.eprintln("  -symbol:NAME   accessor name (default: the input file's stem)")
	fmt.eprintln("  -check         compare against the file on disk instead of writing")
}
