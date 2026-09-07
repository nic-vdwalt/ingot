import argparse
import csv
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


def parse_value(element, values):
    if "id" in element.attrib:
        values[element.attrib["id"]] = (element.text or "", element.attrib.get("fmt", ""))
    if "ref" in element.attrib:
        return values.get(element.attrib["ref"], ("", ""))
    return element.text or "", element.attrib.get("fmt", "")


def evaluate_trace(path):
    root = ET.parse(path).getroot()
    values = {}
    intervals = []
    for row in root.iter("row"):
        cells = list(row)
        if len(cells) < 18:
            continue
        row_values = [parse_value(cell, values) for cell in cells]
        try:
            start = int(row_values[0][0])
            duration = int(row_values[1][0])
            channel = row_values[2][0]
            label = row_values[6][1] or row_values[6][0]
            command_buffer = int(row_values[15][0])
        except (IndexError, ValueError):
            continue
        match = re.search(r"mechanism\.render\.(\d+):mechanism\.(render|resolve)", label)
        if match:
            intervals.append({
                "iteration": int(match.group(1)),
                "kind": match.group(2),
                "channel": channel,
                "start_ns": start,
                "duration_ns": duration,
                "end_ns": start + duration,
                "command_buffer_id": command_buffer,
            })
    grouped = {}
    for interval in intervals:
        grouped.setdefault((interval["iteration"], interval["command_buffer_id"]), []).append(interval)
    rows = []
    for group in grouped.values():
        fragments = [entry for entry in group
                     if entry["kind"] == "render" and entry["channel"] == "Fragment"]
        resolves = [entry for entry in group if entry["kind"] == "resolve"]
        if not fragments or not resolves:
            continue
        fragment = fragments[0]
        resolve = resolves[0]
        rows.append({
            "iteration": fragment["iteration"],
            "command_buffer_id": fragment["command_buffer_id"],
            "fragment_start_ns": fragment["start_ns"],
            "fragment_end_ns": fragment["end_ns"],
            "resolve_start_ns": resolve["start_ns"],
            "resolve_end_ns": resolve["end_ns"],
            "resolve_start_minus_fragment_end_ns": resolve["start_ns"] - fragment["end_ns"],
            "blit_before_fragment_end": resolve["start_ns"] < fragment["end_ns"],
        })
    rows.sort(key=lambda row: row["iteration"])
    deltas = sorted(row["resolve_start_minus_fragment_end_ns"] for row in rows)
    before = sum(row["blit_before_fragment_end"] for row in rows)
    return {
        "source": str(path),
        "pairs": len(rows),
        "blit_before_fragment_end": before,
        "blit_before_fragment_fraction": before / len(rows) if rows else None,
        "minimum_resolve_start_minus_fragment_end_ns": deltas[0] if deltas else None,
        "median_resolve_start_minus_fragment_end_ns": deltas[len(deltas) // 2] if deltas else None,
        "maximum_resolve_start_minus_fragment_end_ns": deltas[-1] if deltas else None,
        "rows": rows,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_xml")
    parser.add_argument("--output")
    parser.add_argument("--csv")
    arguments = parser.parse_args()
    result = evaluate_trace(arguments.trace_xml)
    text = json.dumps(result, indent=1) + "\n"
    if arguments.output:
        Path(arguments.output).write_text(text)
    if arguments.csv and result["rows"]:
        with Path(arguments.csv).open("w", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=result["rows"][0].keys())
            writer.writeheader()
            writer.writerows(result["rows"])
    print(text, end="")


if __name__ == "__main__":
    main()
