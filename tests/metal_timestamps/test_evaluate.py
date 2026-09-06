import copy
import unittest

from evaluate import evaluate


def matrix():
    samples = []
    previous = None
    for fresh in (False, True):
        for repetition in range(4):
            for name in ("draw", "clear", "clipped", "discard", "depth"):
                submission = len(samples) + 1
                start = submission * 100
                ticks = [start, start + 10, start + 20, start + 30]
                if name == "clear":
                    ticks[2:] = [0, 0] if fresh else previous[2:]
                samples.append({
                    "kind": "sample", "case": name, "fresh": fresh,
                    "repetition": repetition, "submission": submission,
                    "status": 4, "error": "", "ticks": ticks,
                    "post_blit_ticks": [start + 40, start + 50],
                    "split_commands": True, "command_submissions": submission * 2,
                    "boundary_status": 4, "boundary_error": "",
                })
                previous = ticks
    return samples


class EvaluateTests(unittest.TestCase):
    def test_counts_actual_commands(self):
        result = evaluate(matrix())
        self.assertEqual(result["submissions"], 40)
        self.assertEqual(result["command_submissions"], 80)
        self.assertEqual(result["post_boundary_reversed"], 0)
        self.assertFalse(result["production_repair_validated"])

    def test_failed_boundary_is_reported_not_validated(self):
        samples = matrix()
        samples[0]["post_blit_ticks"] = [999999, 1]
        result = evaluate(samples)
        self.assertEqual(result["post_boundary_reversed"], 1)
        self.assertFalse(result["production_repair_validated"])

    def test_missing_and_overlapping_boundaries(self):
        samples = matrix()
        samples[0]["post_blit_ticks"] = [0, 0]
        result = evaluate(samples)
        self.assertEqual(result["post_boundary_missing"], 1)
        self.assertEqual(result["post_boundary_overlapping"], 1)

    def test_rejects_incomplete_or_failed_submissions(self):
        samples = matrix()
        for field, value in (("command_submissions", 1), ("boundary_status", 5),
                             ("boundary_error", "device lost"), ("submission", 2)):
            broken = copy.deepcopy(samples)
            broken[0][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                evaluate(broken)
        with self.assertRaises(AssertionError):
            evaluate(samples[:-1])


if __name__ == "__main__":
    unittest.main()
