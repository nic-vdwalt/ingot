import argparse
import collections
import hashlib
import json
import pathlib
import subprocess


def evaluate(records):
    samples = [record for record in records if record.get("kind") == "sample"]
    assert len(samples) == 40, "incomplete matrix"
    assert [sample["submission"] for sample in samples] == list(range(1, 41))
    counts = collections.Counter()
    previous = None
    command_submissions = 0
    for sample in samples:
        assert sample["status"] == 4 and not sample["error"], sample
        command_submissions += 2 if sample.get("split_commands", False) else 1
        if "command_submissions" in sample:
            assert sample["command_submissions"] == command_submissions, sample
            assert sample["boundary_status"] == 4 and not sample["boundary_error"], sample
        ticks = sample["ticks"]
        assert len(ticks) == 4 and ticks[0] > 0 and ticks[1] >= ticks[0], sample
        counts[(sample["case"], sample["fresh"])] += 1
        if sample["case"] == "clear":
            if sample["fresh"]:
                assert ticks[2:] == [0, 0], "clear-only behavior changed; review oracle"
            else:
                assert previous is not None and ticks[2:] == previous["ticks"][2:]
                assert ticks[3] < ticks[0], "stale fragment regression not reproduced"
        else:
            assert ticks[2] >= ticks[0] and ticks[3] >= ticks[2], sample
        previous = sample
    assert len(counts) == 10 and all(count == 4 for count in counts.values())
    boundaries = [sample for sample in samples if "post_blit_ticks" in sample]
    for sample in boundaries:
        pair = sample["post_blit_ticks"]
        assert len(pair) == 2 and all(isinstance(tick, int) and tick >= 0 for tick in pair), sample
    reversed_pairs = sum(sample["post_blit_ticks"][1] < sample["post_blit_ticks"][0]
                         for sample in boundaries)
    missing = sum(min(sample["post_blit_ticks"]) == 0 for sample in boundaries)
    overlapping = sum(sample["post_blit_ticks"][0] < max(sample["ticks"])
                      for sample in boundaries)
    return {"submissions": len(samples), "command_submissions": command_submissions,
            "known_clear_failures": 8,
            "post_boundary_samples": len(boundaries),
            "post_boundary_missing": missing, "post_boundary_overlapping": overlapping,
            "post_boundary_reversed": reversed_pairs,
            "production_repair_validated": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--library", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--source", type=pathlib.Path,
                        default=pathlib.Path(__file__).with_name("native.swift"))
    args = parser.parse_args()
    records = [json.loads(line) for line in args.capture.read_text().splitlines()]
    result = evaluate(records)
    source_hash = hashlib.sha256(args.source.read_bytes()).hexdigest()
    captured_source_hash = records[0].get("source_sha256")
    if captured_source_hash is not None and captured_source_hash != source_hash:
        raise ValueError("capture/source mismatch; provide the captured --source snapshot")
    result["source_identity_verified"] = captured_source_hash == source_hash
    root = pathlib.Path(__file__).resolve().parents[2]
    files = [pathlib.Path(__file__), args.source, args.capture, args.library]
    result["sha256"] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in files}
    result["ingot_revision"] = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    diff = subprocess.check_output(["git", "-C", str(root), "diff", "HEAD"])
    result["tracked_diff_sha256"] = hashlib.sha256(diff).hexdigest()
    result["device"] = records[0]
    args.manifest.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
