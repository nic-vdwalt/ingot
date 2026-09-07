// Qualifies one Aesir recording for the causal ledger: loads it with Aesir's
// own reader, runs the exact identity join and the summary, and prints one
// JSON object. It claims nothing itself; the numbers are what Aesir would
// show, so the ledger can cite Aesir rather than the target.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "src:memwatch"

Qualification :: struct {
	path:                string,
	complete:            bool,
	truncated:           bool,
	telemetry_records:   int,
	telemetry_health:    memwatch.Telemetry_Health_Record,
	exact_join:          memwatch.Exact_Join_Coverage,
	exact_join_healthy:  bool,
	gpu_attributed:      int,
	gpu_reliability:     memwatch.GPU_Reliability,
	gpu_reliability_why: string,
	presentation_ms:     memwatch.Distribution,
	displayed_ms:        memwatch.Distribution,
	host_cpu_ms:         memwatch.Distribution,
	renderer_cpu_ms:     memwatch.Distribution,
	deadline_samples:    int,
	deadline_misses:     int,
	delivery_gaps:       int,
	first_frame:         u64,
	last_frame:          u64,
	delivery_frames:     int,
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: qualify_recording <recording.jsonl>")
		os.exit(2)
	}
	data := memwatch.recording_read(os.args[1])
	summary := memwatch.recording_summarize(&data)
	result := Qualification {
		path               = os.args[1],
		complete           = data.complete,
		truncated          = data.terminal.truncated,
		telemetry_records  = len(data.telemetry),
		telemetry_health   = data.telemetry_health,
		exact_join         = summary.exact_join,
		exact_join_healthy = memwatch.recording_exact_join_healthy(summary.exact_join),
		gpu_attributed     = summary.exact_gpu_ms.count,
		presentation_ms    = summary.exact_presentation_ms,
		displayed_ms       = summary.displayed_ms,
		host_cpu_ms        = summary.host_cpu_ms,
		renderer_cpu_ms    = summary.renderer_cpu_ms,
		deadline_samples   = summary.deadline_samples,
		deadline_misses    = summary.deadline_misses,
		delivery_gaps      = summary.delivery_gaps,
	}
	for record in data.telemetry {
		value := record.telemetry
		if value.gpu_reliability != .Unknown {
			result.gpu_reliability = value.gpu_reliability
			result.gpu_reliability_why = value.gpu_reliability_why
		}
		for delivery in value.deliveries {
			result.delivery_frames += 1
			if result.first_frame == 0 || delivery.frame < result.first_frame {
				result.first_frame = delivery.frame
			}
			result.last_frame = max(result.last_frame, delivery.frame)
		}
	}
	text, marshal_error := json.marshal(result, {pretty = true})
	if marshal_error != nil do os.exit(1)
	fmt.println(string(text))
}
