package odingate

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// Integer baselines (`{"path:key": n}`) serve two ratchets:
//   - style proc-limit: the baseline raises the allowed length for one key
//     (non-monotonic; no stale check).
//   - monotonic counters: a recorded count may only shrink, and a key whose
//     current count is zero must be removed.
Int_Baseline :: map[string]int

// String-list baselines (`{"path:proc": ["risk", ...]}`) record accepted
// assertion debt; a key may not grow new risks and must be removed when clear.
List_Baseline :: map[string][]string

baseline_load_ints :: proc(path: string) -> (baseline: Int_Baseline, ok: bool) {
	assert(path != "", "baseline_load_ints: empty path")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odingate: cannot read baseline %s: %v", path, err)
		return baseline, false
	}
	value, parse_err := json.parse(data, parse_integers = true)
	if parse_err != nil {
		fmt.eprintfln("odingate: baseline %s is not valid JSON: %v", path, parse_err)
		return baseline, false
	}
	object, is_object := value.(json.Object)
	if !is_object {
		fmt.eprintfln("odingate: baseline %s must be a JSON object", path)
		return baseline, false
	}
	for key, entry in object {
		#partial switch number in entry {
		case json.Integer:
			baseline[strings.clone(key)] = int(number)
		case json.Float:
			baseline[strings.clone(key)] = int(number)
		case:
			fmt.eprintfln("odingate: baseline %s: %s is not an integer", path, key)
			return baseline, false
		}
	}
	return baseline, true
}

baseline_load_lists :: proc(path: string) -> (baseline: List_Baseline, ok: bool) {
	assert(path != "", "baseline_load_lists: empty path")
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintfln("odingate: cannot read baseline %s: %v", path, err)
		return baseline, false
	}
	value, parse_err := json.parse(data)
	if parse_err != nil {
		fmt.eprintfln("odingate: baseline %s is not valid JSON: %v", path, parse_err)
		return baseline, false
	}
	object, is_object := value.(json.Object)
	if !is_object {
		fmt.eprintfln("odingate: baseline %s must be a JSON object", path)
		return baseline, false
	}
	for key, entry in object {
		array, is_array := entry.(json.Array)
		if !is_array {
			fmt.eprintfln("odingate: baseline %s: %s is not a list", path, key)
			return baseline, false
		}
		items := make([dynamic]string)
		for item in array {
			text, is_string := item.(json.String)
			if !is_string {
				fmt.eprintfln("odingate: baseline %s: %s has a non-string entry", path, key)
				return baseline, false
			}
			append(&items, strings.clone(text))
		}
		baseline[strings.clone(key)] = items[:]
	}
	return baseline, true
}

// baseline_check_monotonic compares current counts with the baseline and
// reports growth and stale entries using the Python guards' wording.
// `advice` is appended after the count message when non-empty.
baseline_check_monotonic :: proc(
	report: ^Report,
	current: map[string]int,
	baseline: Int_Baseline,
	advice: proc(key: string) -> string,
) {
	assert(report != nil, "baseline_check_monotonic: nil report")
	for key, count in current {
		allowed := baseline[key] or_else 0
		if count <= allowed do continue
		hint := advice != nil ? advice(key) : ""
		if hint != "" {
			report_addf(
				report,
				key_path(key),
				0,
				"%s: increased from %d to %d; %s",
				key,
				allowed,
				count,
				hint,
			)
		} else {
			report_addf(
				report,
				key_path(key),
				0,
				"%s: increased from %d to %d",
				key,
				allowed,
				count,
			)
		}
	}
	for key in baseline {
		if (current[key] or_else 0) == 0 {
			report_addf(report, key_path(key), 0, "%s: stale baseline entry; remove it", key)
		}
	}
}

// key_path returns the `path` half of a `path:key` baseline key.
key_path :: proc(key: string) -> string {
	index := strings.index_byte(key, ':')
	return index < 0 ? key : key[:index]
}

// sorted_keys returns a map's keys in byte order for deterministic output.
sorted_keys :: proc(m: map[string]$V, allocator := context.allocator) -> []string {
	keys := make([]string, len(m), allocator)
	index := 0
	for key in m {
		keys[index] = key
		index += 1
	}
	assert(index == len(keys), "sorted_keys: key count drifted")
	slice.sort(keys)
	return keys
}

// print_int_map writes `{ "key": n, ... }` with sorted keys, matching the
// json.dumps(indent=2, sort_keys=True) shape the Python --measure modes used.
print_int_map :: proc(file: ^os.File, m: map[string]int, indent: string = "") {
	assert(file != nil, "print_int_map: nil file")
	keys := sorted_keys(m)
	if len(keys) == 0 {
		fmt.fprint(file, "{}")
		return
	}
	fmt.fprintln(file, "{")
	for key, index in keys {
		comma := index + 1 < len(keys) ? "," : ""
		fmt.fprintfln(file, "%s  %s: %d%s", indent, json_quote(key), m[key], comma)
	}
	fmt.fprintf(file, "%s}", indent)
}

json_quote :: proc(text: string, allocator := context.allocator) -> string {
	builder := strings.builder_make(allocator)
	strings.write_byte(&builder, '"')
	for char in text {
		switch char {
		case '"':
			strings.write_string(&builder, "\\\"")
		case '\\':
			strings.write_string(&builder, "\\\\")
		case '\n':
			strings.write_string(&builder, "\\n")
		case:
			strings.write_rune(&builder, char)
		}
	}
	strings.write_byte(&builder, '"')
	return strings.to_string(builder)
}
