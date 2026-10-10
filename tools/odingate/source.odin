package odingate

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

// A parsed source file. `file` keeps the whole AST plus `comments`, which the
// waiver lookups walk; `text` is the raw bytes for line-level rules.
Source :: struct {
	rel_path:    string,
	text:        string,
	masked:      string, // text with comments and string/rune literals blanked
	lines:       []string,
	line_starts: []int, // byte offset of each 1-based line's first character
	file:        ^ast.File,
	parse_ok:    bool,
}

// Parse errors are collected per file through a package-level sink because
// parser.Error_Handler carries no user pointer. The tool is single-threaded
// and loads files sequentially, so the sink is never shared between parses.
PARSE_ERRORS_MAX :: 64

Parse_Error :: struct {
	line:    int,
	message: string,
}

@(private = "file")
parse_error_sink: struct {
	count:  int,
	errors: [PARSE_ERRORS_MAX]Parse_Error,
}

@(private = "file")
record_parse_error :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	if parse_error_sink.count >= PARSE_ERRORS_MAX do return
	message := fmt.aprintf(format, ..args)
	parse_error_sink.errors[parse_error_sink.count] = {pos.line, message}
	parse_error_sink.count += 1
}

@(private = "file")
ignore_parse_warning :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
}

// parse_source parses `text` as `rel_path`. Parse errors become findings on
// `report` when it is non-nil so a syntax error fails the gate instead of
// silently skipping every rule for that file.
parse_source :: proc(rel_path, text: string, report: ^Report) -> Source {
	assert(rel_path != "", "parse_source: empty path")
	file := new(ast.File)
	file.fullpath = rel_path
	file.src = text
	p := parser.default_parser()
	p.err = record_parse_error
	p.warn = ignore_parse_warning
	parse_error_sink.count = 0
	ok := parser.parse_file(&p, file)
	if report != nil {
		for error in parse_error_sink.errors[:parse_error_sink.count] {
			report_add(report, rel_path, error.line, fmt.aprintf("parse error: %s", error.message))
		}
		if !ok && parse_error_sink.count == 0 {
			report_add(report, rel_path, 1, "parse error: parser returned failure")
		}
	}
	assert(file.pkg_name != "" || !ok || len(text) == 0, "parse_source: parsed file lacks package")
	return Source {
		rel_path = rel_path,
		text = text,
		masked = mask_source_text(text, file),
		lines = split_source_lines(text),
		line_starts = line_start_offsets(text),
		file = file,
		parse_ok = ok,
	}
}

// split_source_lines mirrors Python str.splitlines() for LF and CRLF input:
// a trailing newline does not produce an empty final line, and the carriage
// return is not part of the line.
split_source_lines :: proc(text: string, allocator := context.allocator) -> []string {
	lines := make([dynamic]string, allocator)
	rest := text
	for len(rest) > 0 {
		newline := strings.index_byte(rest, '\n')
		line := rest
		if newline >= 0 {
			line = rest[:newline]
			rest = rest[newline + 1:]
		} else {
			rest = ""
		}
		append(&lines, strings.trim_right(line, "\r"))
	}
	return lines[:]
}

// line_start_offsets returns the byte offset where each 1-based line begins;
// index 0 is unused so `line_starts[line]` reads naturally.
line_start_offsets :: proc(text: string, allocator := context.allocator) -> []int {
	starts := make([dynamic]int, allocator)
	append(&starts, 0)
	append(&starts, 0)
	for char, offset in text {
		if char == '\n' do append(&starts, offset + 1)
	}
	return starts[:]
}

// mask_source_text blanks comment tokens and string/rune literals with spaces
// while preserving length and newlines, so byte offsets from the AST still
// index into it and text searches cannot match inside prose.
mask_source_text :: proc(text: string, file: ^ast.File, allocator := context.allocator) -> string {
	assert(file != nil, "mask_source_text: nil file")
	buffer := make([]byte, len(text), allocator)
	copy(buffer, text)
	for group in file.comments {
		for token in group.list do mask_span(buffer, token.pos.offset, token.pos.offset + len(token.text))
	}
	visitor := ast.Visitor {
		visit = mask_literal_visit,
		data  = raw_data(buffer),
	}
	for decl in file.decls do ast.walk(&visitor, decl)
	return string(buffer)
}

@(private = "file")
mask_literal_visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil do return nil
	lit, is_lit := node.derived.(^ast.Basic_Lit)
	if !is_lit do return v
	#partial switch lit.tok.kind {
	case .String, .Rune:
		buffer := ([^]byte)(v.data)
		mask_bytes(buffer, lit.tok.pos.offset, lit.tok.pos.offset + len(lit.tok.text))
	}
	return v
}

@(private = "file")
mask_span :: proc(buffer: []byte, start, end: int) {
	for index in max(start, 0) ..< min(end, len(buffer)) {
		if buffer[index] != '\n' && buffer[index] != '\r' do buffer[index] = ' '
	}
}

@(private = "file")
mask_bytes :: proc(buffer: [^]byte, start, end: int) {
	assert(start >= 0 && end >= start, "mask_bytes: inverted span")
	for index in start ..< end {
		if buffer[index] != '\n' && buffer[index] != '\r' do buffer[index] = ' '
	}
}

// load_sources reads and parses every `rel_paths` entry under `root`.
// Unreadable files are findings, not crashes: a stale file list should fail
// the gate visibly.
load_sources :: proc(root: string, rel_paths: []string, report: ^Report) -> []Source {
	assert(root != "", "load_sources: empty root")
	sources := make([dynamic]Source, 0, len(rel_paths))
	for rel_path in rel_paths {
		full, join_err := filepath.join({root, rel_path})
		if join_err != nil {
			if report != nil do report_add(report, rel_path, 1, "cannot join path")
			continue
		}
		data, err := os.read_entire_file(full, context.allocator)
		if err != nil {
			if report != nil {
				report_add(report, rel_path, 1, fmt.aprintf("cannot read file: %v", err))
			}
			continue
		}
		append(&sources, parse_source(rel_path, string(data), report))
	}
	assert(len(sources) <= len(rel_paths), "load_sources: produced more sources than paths")
	return sources[:]
}

// collect_odin_files walks `root/sub` and returns `.odin` paths relative to
// `root`, sorted so output is deterministic across platforms.
collect_odin_files :: proc(root, sub: string) -> (files: [dynamic]string, ok: bool) {
	assert(root != "", "collect_odin_files: empty root")
	start := root
	if sub != "" {
		joined, join_err := filepath.join({root, sub})
		if join_err != nil do return files, false
		start = joined
	}
	if !os.is_directory(start) do return files, false
	walker: os.Walker = os.walker_create_path(start)
	defer os.walker_destroy(&walker)
	for info in os.walker_walk(&walker) {
		if _, err := os.walker_error(&walker); err != nil do continue
		if info.type == .Directory {
			base := filepath.base(info.fullpath)
			if base == ".git" || base == "artifacts" do os.walker_skip_dir(&walker)
			continue
		}
		if !strings.has_suffix(info.name, ".odin") do continue
		rel, rel_err := filepath.rel(root, info.fullpath)
		if rel_err != nil do continue
		append(&files, strings.clone(rel))
	}
	slice.sort(files[:])
	return files, true
}

// filter_prefix keeps paths starting with any of `prefixes`; an empty
// prefix list keeps everything.
filter_paths :: proc(
	paths: []string,
	prefixes: []string,
	exclude_prefixes: []string,
	exclude_suffixes: []string,
) -> []string {
	kept := make([dynamic]string, 0, len(paths))
	for path in paths {
		if len(prefixes) > 0 && !has_any_prefix(path, prefixes) do continue
		if has_any_prefix(path, exclude_prefixes) do continue
		if has_any_suffix(path, exclude_suffixes) do continue
		append(&kept, path)
	}
	assert(len(kept) <= len(paths), "filter_paths: kept more than given")
	return kept[:]
}

has_any_prefix :: proc(path: string, prefixes: []string) -> bool {
	for prefix in prefixes {
		if strings.has_prefix(path, prefix) do return true
	}
	return false
}

has_any_suffix :: proc(path: string, suffixes: []string) -> bool {
	for suffix in suffixes {
		if strings.has_suffix(path, suffix) do return true
	}
	return false
}
