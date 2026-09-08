import html
import tempfile
import unittest
from pathlib import Path

from evaluate_planetforger_completion_trace import evaluate_trace


SUBMISSION_SCHEMA = """<schema name="metal-application-command-buffer-submissions">{}</schema>""".format(
    "".join("<col/>" for _ in range(15))
)


def submission_row(start, process, note, command_buffer, refs=False):
    cells = [f'<start-time id="start-{start}-{command_buffer}">{start}</start-time>']
    cells.extend("<sentinel/>" for _ in range(6))
    if refs:
        cells.append('<process ref="process-10"/>')
    else:
        cells.append(f'<process id="process-{command_buffer}" fmt="{process}">{process}</process>')
    cells.extend("<sentinel/>" for _ in range(2))
    escaped_note = html.escape(note, quote=True)
    cells.append(f'<narrative id="note-{start}-{command_buffer}" fmt="{escaped_note}">{escaped_note}</narrative>')
    cells.extend("<sentinel/>" for _ in range(3))
    cells.append(f'<metal-command-buffer-id id="cb-{start}-{command_buffer}">{command_buffer}</metal-command-buffer-id>')
    return "<row>" + "".join(cells) + "</row>"


def completion_row(timestamp, command_buffer, reference=None):
    timestamp_cell = (
        f'<start-time ref="completion-time-{reference}"/>'
        if reference is not None
        else f'<start-time id="completion-time-{timestamp}-{command_buffer}">{timestamp}</start-time>'
    )
    return (
        "<row>"
        + timestamp_cell
        + f'<metal-command-buffer-id id="completion-cb-{timestamp}-{command_buffer}">{command_buffer}</metal-command-buffer-id>'
        + "</row>"
    )


class PlanetForgerCompletionTraceTests(unittest.TestCase):
    def evaluate(self, submission_rows, completion_rows, minimum_pairs=1):
        with tempfile.TemporaryDirectory() as directory:
            submissions = Path(directory) / "submissions.xml"
            completions = Path(directory) / "completions.xml"
            submissions.write_text(
                f"<trace-query-result><node>{SUBMISSION_SCHEMA}{''.join(submission_rows)}</node></trace-query-result>"
            )
            completions.write_text(
                f"<trace-query-result><node><schema name=\"metal-command-buffer-completed\"/>{''.join(completion_rows)}</node></trace-query-result>"
            )
            return evaluate_trace(submissions, completions, minimum_pairs=minimum_pairs)

    def test_ordered_pair_with_unrelated_submission_and_refs(self):
        result = self.evaluate(
            [
                submission_row(100, "planetforger (7)", 'Committed " window "', 10),
                submission_row(120, "planetforger (7)", 'Committed " (wgpu internal) Transit "', 11, True),
                submission_row(160, "planetforger (7)", 'Committed " gpu timing completion resolve "', 12, True),
            ],
            [completion_row(150, 1), completion_row(150, 10), completion_row(150, 11, "150-1")],
        )
        self.assertEqual(result["pair_count"], 1)
        self.assertEqual(result["minimum_delay_ns"], 10)

    def test_excludes_unrelated_process(self):
        result = self.evaluate(
            [
                submission_row(10, "other (1)", 'Committed " window "', 1),
                submission_row(20, "other (1)", 'Committed " gpu timing completion resolve "', 2),
                submission_row(100, "planetforger (7)", 'Committed " window "', 10),
                submission_row(160, "planetforger (7)", 'Committed " gpu timing completion resolve "', 12, True),
            ],
            [completion_row(15, 1), completion_row(150, 10)],
        )
        self.assertEqual(result["rows"][0]["sample_command_buffer_id"], 10)

    def test_fifo_pairing_survives_later_sample_submissions(self):
        result = self.evaluate(
            [
                submission_row(100, "planetforger (7)", 'Committed " window "', 10),
                submission_row(120, "planetforger (7)", 'Committed " window "', 20),
                submission_row(160, "planetforger (7)", 'Committed " gpu timing completion resolve "', 12, True),
            ],
            [completion_row(150, 10), completion_row(155, 20)],
        )
        self.assertEqual(result["rows"][0]["sample_command_buffer_id"], 10)

    def test_generation_labels_are_exact_when_resolves_retire_out_of_order(self):
        result = self.evaluate(
            [
                submission_row(100, "planetforger (7)", 'Committed " window 10 "', 10),
                submission_row(110, "planetforger (7)", 'Committed " window 11 "', 20, True),
                submission_row(160, "planetforger (7)", 'Committed " gpu timing completion resolve 11 "', 21, True),
                submission_row(170, "planetforger (7)", 'Committed " gpu timing completion resolve 10 "', 12, True),
            ],
            [completion_row(150, 10), completion_row(155, 20)],
            minimum_pairs=2,
        )
        self.assertEqual(result["correlation"], "generation_label")
        self.assertEqual([row["generation"] for row in result["rows"]], [11, 10])
        self.assertEqual([row["sample_command_buffer_id"] for row in result["rows"]], [20, 10])

    def test_rejects_resolve_before_completion(self):
        with self.assertRaisesRegex(ValueError, "precede"):
            self.evaluate(
                [
                    submission_row(100, "planetforger (7)", 'Committed " window "', 10),
                    submission_row(140, "planetforger (7)", 'Committed " gpu timing completion resolve "', 12, True),
                ],
                [completion_row(150, 10)],
            )

    def test_rejects_missing_completion(self):
        with self.assertRaisesRegex(ValueError, "missing sampled"):
            self.evaluate(
                [
                    submission_row(100, "planetforger (7)", 'Committed " window "', 10),
                    submission_row(160, "planetforger (7)", 'Committed " gpu timing completion resolve "', 12, True),
                ],
                [],
            )

    def test_rejects_duplicate_sample_generation(self):
        with self.assertRaisesRegex(ValueError, "duplicate sampled generation"):
            self.evaluate(
                [
                    submission_row(100, "planetforger (7)", 'Committed " window 10 "', 10),
                    submission_row(110, "planetforger (7)", 'Committed " window 10 "', 20, True),
                    submission_row(160, "planetforger (7)", 'Committed " gpu timing completion resolve 10 "', 12, True),
                ],
                [completion_row(150, 10), completion_row(155, 20)],
            )

    def test_rejects_duplicate_completion_command_buffer_id(self):
        with self.assertRaisesRegex(ValueError, "duplicate completion"):
            self.evaluate(
                [],
                [completion_row(100, 10), completion_row(110, 10)],
            )

    def test_rejects_duplicate_command_buffer_id(self):
        with self.assertRaisesRegex(ValueError, "duplicate submission"):
            self.evaluate(
                [
                    submission_row(100, "planetforger (7)", 'Committed " window "', 10),
                    submission_row(110, "planetforger (7)", 'Committed " window "', 10, True),
                ],
                [],
            )


if __name__ == "__main__":
    unittest.main()
