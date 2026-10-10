// odingate is the Odin-source gate for ingot: it parses tracked `.odin` files
// with core:odin/parser and checks Tiger Style and package-boundary rules on
// the AST. It replaces the regex-based Python guards; each rule keeps the
// message strings those scripts emitted so CI logs and docs stay valid.
//
// Usage:
//
//	odingate <rule> [--root R] [--files-from F] [--baseline B] [--measure]
//	                [--print-procedures] [--packages a,b] [--consumer-root R]*
//	                [--binding-allow P]* [--raylib-vendor D] [--report]
//
// The file list comes from the shell (`git ls-files '*.odin'`) through
// --files-from so this program never shells out; `-` reads the list from
// stdin. Without --files-from the root is walked for `.odin` files, which
// also sees untracked files, so gates should always pass the list explicitly.
package odingate

import "core:fmt"
import "core:os"
import "core:strings"

Options :: struct {
	rule:             string,
	root:             string,
	files_from:       string,
	baseline:         string,
	measure:          bool,
	print_procedures: bool,
	report:           bool,
	help:             bool,
	packages:         string,
	consumer_roots:   [dynamic]string,
	binding_allows:   [dynamic]string,
	raylib_vendor:    string,
	files:            []string,
}

Rule :: struct {
	name:  string,
	run:   proc(options: ^Options) -> int,
	usage: string,
}

EXIT_OK :: 0
EXIT_FINDINGS :: 1
EXIT_USAGE :: 2

RULES := [?]Rule {
	{"parse", run_parse, "report files core:odin/parser cannot parse"},
	{"style", run_style, "line/procedure limits, recursion, loop bounds, assert purity"},
	{"assertions", run_assertions, "uncovered pointer/index/queue/ownership/state/input risks"},
	{"gfx-context", run_gfx_context, "explicit ^Context routing and gfx package-global inventory"},
	{"ui-api-layers", run_ui_api_layers, "fit/ui/ui_gfx layering in the framework and consumers"},
	{"init-order", run_init_order, "_default_context_init is the only @(init) in gfx"},
}

main :: proc() {
	options, ok := parse_args(os.args[1:])
	if !ok {
		print_usage(os.stderr)
		os.exit(EXIT_USAGE)
	}
	if options.help && options.rule == "" {
		print_usage(os.stdout)
		os.exit(EXIT_OK)
	}
	rule, found := find_rule(options.rule)
	if !found {
		fmt.eprintfln("odingate: unknown rule %q", options.rule)
		print_usage(os.stderr)
		os.exit(EXIT_USAGE)
	}
	if options.help {
		fmt.printfln("usage: odingate %s [options]\n\n%s\n", rule.name, rule.usage)
		print_usage(os.stdout)
		os.exit(EXIT_OK)
	}
	if !resolve_files(&options) {
		os.exit(EXIT_USAGE)
	}
	os.exit(rule.run(&options))
}

find_rule :: proc(name: string) -> (rule: Rule, found: bool) {
	for candidate in RULES {
		if candidate.name == name do return candidate, true
	}
	return {}, false
}

print_usage :: proc(file: ^os.File) {
	assert(file != nil, "print_usage: nil file")
	fmt.fprintln(file, "usage: odingate <rule> [options]")
	fmt.fprintln(file, "rules:")
	for rule in RULES {
		fmt.fprintfln(file, "  %-16s %s", rule.name, rule.usage)
	}
	fmt.fprintln(file, "options:")
	fmt.fprintln(file, "  --root R            repository root (default: current directory)")
	fmt.fprintln(file, "  --files-from F      newline-separated .odin paths relative to root")
	fmt.fprintln(file, "                      (\"-\" reads stdin; omit to walk the root)")
	fmt.fprintln(file, "  --baseline B        JSON baseline for rules that ratchet")
	fmt.fprintln(file, "  --measure           print a JSON inventory instead of checking")
	fmt.fprintln(file, "  --print-procedures  style: list procedures over the length limit")
	fmt.fprintln(file, "  --packages a,b      assertions: override the scanned package list")
	fmt.fprintln(file, "  --consumer-root R   ui-api-layers: extra consumer tree (repeatable)")
	fmt.fprintln(file, "  --binding-allow P   ui-api-layers: path allowed to import bindings")
	fmt.fprintln(file, "  --raylib-vendor D   gfx-context: vendor/raylib directory")
	fmt.fprintln(file, "  --report            init-order: list @(init) procedures")
	fmt.fprintln(file, "  --help              show this text or a rule's usage")
}

parse_args :: proc(args: []string) -> (options: Options, ok: bool) {
	options.root = "."
	index := 0
	for index < len(args) {
		arg := args[index]
		index += 1
		switch arg {
		case "--help", "-h":
			options.help = true
			continue
		case "--measure":
			options.measure = true
			continue
		case "--print-procedures":
			options.print_procedures = true
			continue
		case "--report":
			options.report = true
			continue
		}
		if !strings.has_prefix(arg, "--") {
			if options.rule != "" {
				fmt.eprintfln("odingate: unexpected positional argument %q", arg)
				return options, false
			}
			options.rule = arg
			continue
		}
		if index >= len(args) {
			fmt.eprintfln("odingate: %s needs a value", arg)
			return options, false
		}
		value := args[index]
		index += 1
		switch arg {
		case "--root":
			options.root = value
		case "--files-from":
			options.files_from = value
		case "--baseline":
			options.baseline = value
		case "--packages":
			options.packages = value
		case "--consumer-root":
			append(&options.consumer_roots, value)
		case "--binding-allow":
			append(&options.binding_allows, value)
		case "--raylib-vendor":
			options.raylib_vendor = value
		case:
			fmt.eprintfln("odingate: unknown option %s", arg)
			return options, false
		}
	}
	return options, true
}

resolve_files :: proc(options: ^Options) -> bool {
	assert(options != nil, "resolve_files: nil options")
	if options.files_from == "" {
		files, ok := collect_odin_files(options.root, "")
		if !ok {
			fmt.eprintfln("odingate: cannot walk %s", options.root)
			return false
		}
		options.files = files[:]
		return true
	}
	data: []byte
	err: os.Error
	if options.files_from == "-" {
		data, err = os.read_entire_file(os.stdin, context.allocator)
	} else {
		data, err = os.read_entire_file(options.files_from, context.allocator)
	}
	if err != nil {
		fmt.eprintfln("odingate: cannot read file list %s: %v", options.files_from, err)
		return false
	}
	files := make([dynamic]string)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if trimmed == "" do continue
		append(&files, strings.clone(trimmed))
	}
	options.files = files[:]
	return true
}

run_parse :: proc(options: ^Options) -> int {
	assert(options != nil, "run_parse: nil options")
	report: Report
	sources := load_sources(options.root, options.files, &report)
	assert(len(sources) <= len(options.files), "run_parse: more sources than files")
	return report_emit(&report, os.stdout)
}
