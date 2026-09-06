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
    for sample in samples:
        assert sample["status"] == 4 and not sample["error"], sample
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
    return {"submissions": len(samples), "known_clear_failures": 8,
            "production_repair_validated": False}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("capture", type=pathlib.Path)
    parser.add_argument("--library", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    args = parser.parse_args()
    records = [json.loads(line) for line in args.capture.read_text().splitlines()]
    result = evaluate(records)
    root = pathlib.Path(__file__).resolve().parents[2]
    files = [pathlib.Path(__file__), pathlib.Path(__file__).with_name("native.swift"),
             args.capture, args.library]
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
