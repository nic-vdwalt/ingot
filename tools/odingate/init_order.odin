package odingate

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"

// Port of scripts/check_init_order.py: keep `_default_context_init` the only
// `@(init)` procedure in `gfx`. The ordering between `@(init)` procedures
// inside a package is filename order and `context.odin` does not sort first,
// so a second one in an earlier-named file would read the default context id
// before it is assigned. Test sources are scanned too.

INIT_ORDER_PACKAGE :: "gfx/"
INIT_ORDER_ALLOWED_PATH :: "gfx/context.odin"
INIT_ORDER_ALLOWED_NAME :: "_default_context_init"

Init_Procedure :: struct {
	path: string,
	name: string,
	line: int,
}

// init_procedures_for_source lists every procedure carrying an `@(init)`
// attribute element; prose mentioning the attribute never matches because
// attributes are read from the AST.
init_procedures_for_source :: proc(source: ^Source, found: ^[dynamic]Init_Procedure) {
	assert(source != nil && found != nil, "init_procedures_for_source: nil argument")
	for decl in top_level_value_decls(source.file, context.temp_allocator) {
		if decl.is_mutable || !has_attribute(decl.attributes[:], "init") do continue
		if len(decl.values) == 0 do continue
		if _, is_proc := decl.values[0].derived_expr.(^ast.Proc_Lit); !is_proc do continue
		for name_expr in decl.names {
			ident, ok := name_expr.derived_expr.(^ast.Ident)
			if !ok do continue
			append(found, Init_Procedure{source.rel_path, ident.name, decl.attributes[0].pos.line})
		}
	}
}

@(private = "file")
init_procedure_less :: proc(a, b: Init_Procedure) -> bool {
	if a.path != b.path do return a.path < b.path
	return a.line < b.line
}

// init_order_check reports every `@(init)` other than the permitted one, a
// missing permitted declaration, and a duplicated one.
init_order_check :: proc(found: []Init_Procedure, report: ^Report) {
	assert(report != nil, "init_order_check: nil report")
	sorted := make([]Init_Procedure, len(found), context.temp_allocator)
	copy(sorted, found)
	slice.sort_by(sorted, init_procedure_less)
	allowed := 0
	for entry in sorted {
		if entry.path == INIT_ORDER_ALLOWED_PATH && entry.name == INIT_ORDER_ALLOWED_NAME {
			allowed += 1
			continue
		}
		report_addf(report, entry.path, entry.line, "unexpected @(init) procedure %s", entry.name)
	}
	if allowed == 0 {
		report_addf_raw(
			report,
			INIT_ORDER_ALLOWED_PATH,
			0,
			"%s: %s is missing; the default context id would never be assigned",
			INIT_ORDER_ALLOWED_PATH,
			INIT_ORDER_ALLOWED_NAME,
		)
	}
	if allowed > 1 {
		report_addf_raw(
			report,
			INIT_ORDER_ALLOWED_PATH,
			0,
			"%s: %s is declared %d times",
			INIT_ORDER_ALLOWED_PATH,
			INIT_ORDER_ALLOWED_NAME,
			allowed,
		)
	}
}

INIT_ORDER_ADVICE ::
	"\n@(init) order within a package is filename order, and\n" +
	"gfx/context.odin does not sort first - roughly half of gfx\n" +
	"precedes it. A second @(init) in an earlier-named file runs\n" +
	"before _default_context_init and reads an unassigned context id,\n" +
	"which aliases resource handles rather than failing loudly.\n" +
	"\n" +
	"Call the initialisation from _default_context_init instead of\n" +
	"adding another @(init) to the package."

run_init_order :: proc(options: ^Options) -> int {
	assert(options != nil, "run_init_order: nil options")
	files := filter_paths(options.files, {INIT_ORDER_PACKAGE}, nil, nil)
	report: Report
	sources := load_sources(options.root, files, &report)
	found := make([dynamic]Init_Procedure)
	for &source in sources do init_procedures_for_source(&source, &found)
	if options.report {
		slice.sort_by(found[:], init_procedure_less)
		for entry in found do fmt.printfln("%s:%d: %s", entry.path, entry.line, entry.name)
		return EXIT_OK
	}
	init_order_check(found[:], &report)
	assert(len(sources) <= len(files), "run_init_order: more sources than files")
	code := report_emit(&report, os.stderr)
	if code != EXIT_OK do fmt.eprintln(INIT_ORDER_ADVICE)
	return code
}
