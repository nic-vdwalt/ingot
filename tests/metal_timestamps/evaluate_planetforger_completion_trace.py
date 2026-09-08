import argparse
from collections import deque
import json
import math
import re
import xml.etree.ElementTree as ET
from pathlib import Path


SAMPLE_PATTERN = re.compile(r'Committed " window(?: (\d+))? "')
RESOLVE_PATTERN = re.compile(r'Committed " gpu timing completion resolve(?: (\d+))? "')


def parse_value(element, values):
    if "id" in element.attrib:
        if element.attrib["id"] in values:
            raise ValueError(f'duplicate XML id {element.attrib["id"]}')
        values[element.attrib["id"]] = (element.text or "", element.attrib.get("fmt", ""))
    if "ref" in element.attrib:
        reference = element.attrib["ref"]
        if reference not in values:
            raise ValueError(f"missing XML ref {reference}")
        return values[reference]
    return element.text or "", element.attrib.get("fmt", "")


def percentile(values, fraction):
    if not values:
        return None
    return values[math.ceil(fraction * len(values)) - 1]


def read_submissions(path, process_name):
    root = ET.parse(path).getroot()
    values = {}
    submissions = []
    command_buffer_ids = set()
    for row in root.iter("row"):
        cells = [parse_value(cell, values) for cell in row]
        if len(cells) < 15:
            continue
        process = cells[7][1] or cells[7][0]
        if process_name not in process:
            continue
        try:
            start_ns = int(cells[0][0])
            command_buffer_id = int(cells[14][0])
        except ValueError as error:
            raise ValueError("invalid submission timestamp or command-buffer ID") from error
        if command_buffer_id in command_buffer_ids:
            raise ValueError(f"duplicate submission command-buffer ID {command_buffer_id}")
        command_buffer_ids.add(command_buffer_id)
        note = cells[10][1] or cells[10][0]
        sample_match = SAMPLE_PATTERN.search(note)
        resolve_match = RESOLVE_PATTERN.search(note)
        submissions.append({
            "start_ns": start_ns,
            "note": note,
            "process": process,
            "command_buffer_id": command_buffer_id,
            "kind": "sample" if sample_match else "resolve" if resolve_match else "other",
            "generation": int((sample_match or resolve_match).group(1))
            if (sample_match or resolve_match) and (sample_match or resolve_match).group(1)
            else None,
        })
    submissions.sort(key=lambda row: row["start_ns"])
    return submissions


def read_completions(path):
    root = ET.parse(path).getroot()
    values = {}
    completions = {}
    for row in root.iter("row"):
        cells = [parse_value(cell, values) for cell in row]
        if len(cells) < 2:
            continue
        try:
            timestamp_ns = int(cells[0][0])
            command_buffer_id = int(cells[1][0])
        except ValueError as error:
            raise ValueError("invalid completion timestamp or command-buffer ID") from error
        if command_buffer_id in completions:
            raise ValueError(f"duplicate completion command-buffer ID {command_buffer_id}")
        completions[command_buffer_id] = timestamp_ns
    return completions


def evaluate_trace(submissions_path, completions_path, process_name="planetforger", minimum_pairs=50):
    submissions = read_submissions(submissions_path, process_name)
    completions = read_completions(completions_path)
    rows = []
    missing_completions = []
    pending_samples = deque()
    samples_by_generation = {}
    exact_identity = any(
        submission["kind"] == "resolve" and submission["generation"] is not None
        for submission in submissions
    )
    for submission in submissions:
        if submission["kind"] == "sample":
            generation = submission["generation"]
            if exact_identity:
                if generation is None:
                    continue
                if generation in samples_by_generation:
                    raise ValueError(f"duplicate sampled generation {generation}")
                samples_by_generation[generation] = submission
            else:
                pending_samples.append(submission)
            continue
        if submission["kind"] != "resolve":
            continue
        if exact_identity:
            generation = submission["generation"]
            if generation is None or generation not in samples_by_generation:
                raise ValueError(
                    f'resolve command buffer {submission["command_buffer_id"]} has no sampled generation'
                )
            sample = samples_by_generation.pop(generation)
        else:
            if not pending_samples:
                raise ValueError(
                    f'resolve command buffer {submission["command_buffer_id"]} has no pending sampled window'
                )
            sample = pending_samples.popleft()
        sample_id = sample["command_buffer_id"]
        completion_ns = completions.get(sample_id)
        if completion_ns is None:
            missing_completions.append(sample_id)
            continue
        delay_ns = submission["start_ns"] - completion_ns
        rows.append({
            "generation": submission["generation"],
            "sample_command_buffer_id": sample_id,
            "sample_submit_ns": sample["start_ns"],
            "sample_completion_ns": completion_ns,
            "resolve_command_buffer_id": submission["command_buffer_id"],
            "resolve_submit_ns": submission["start_ns"],
            "resolve_start_minus_sample_completion_ns": delay_ns,
            "resolve_before_sample_completion": delay_ns < 0,
        })
    if missing_completions:
        raise ValueError(f"missing sampled command-buffer completions: {sorted(set(missing_completions))}")
    if len(rows) < minimum_pairs:
        raise ValueError(f"expected at least {minimum_pairs} resolve pairs, found {len(rows)}")
    delays = sorted(row["resolve_start_minus_sample_completion_ns"] for row in rows)
    violations = sum(row["resolve_before_sample_completion"] for row in rows)
    if violations:
        raise ValueError(f"{violations} resolve submissions precede the sampled queue frontier completion")
    return {
        "submissions_source": str(submissions_path),
        "completions_source": str(completions_path),
        "process_name": process_name,
        "correlation": "generation_label" if exact_identity else "fifo_sample_completion_registration_order",
        "pair_count": len(rows),
        "missing_completions": 0,
        "resolves_before_sample_completion": violations,
        "minimum_delay_ns": delays[0],
        "median_delay_ns": percentile(delays, 0.5),
        "p95_delay_ns": percentile(delays, 0.95),
        "p99_delay_ns": percentile(delays, 0.99),
        "maximum_delay_ns": delays[-1],
        "rows": rows,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("submissions_xml")
    parser.add_argument("completions_xml")
    parser.add_argument("--process", default="planetforger")
    parser.add_argument("--minimum-pairs", type=int, default=50)
    parser.add_argument("--output")
    arguments = parser.parse_args()
    result = evaluate_trace(
        arguments.submissions_xml,
        arguments.completions_xml,
        arguments.process,
        arguments.minimum_pairs,
    )
    text = json.dumps(result, indent=1) + "\n"
    if arguments.output:
        Path(arguments.output).write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()
