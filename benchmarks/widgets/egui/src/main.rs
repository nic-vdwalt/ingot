use egui::{pos2, vec2, Button, Checkbox, Context, RawInput, Rect, Slider, TextEdit};
use serde::Serialize;
use std::env;
use std::process::ExitCode;
use std::time::Instant;

const WARMUP_DEFAULT: usize = 300;
const FRAMES_DEFAULT: usize = 2000;
const VIRTUAL_ROWS: usize = 40;
const VIRTUAL_OVERSCAN: usize = 2;
const FNV_BASIS: u64 = 1_469_598_103_934_665_603;
const FNV_PRIME: u64 = 1_099_511_628_211;

struct Options {
    workload: String,
    scale: usize,
    warmup: usize,
    frames: usize,
    repetition: usize,
}

#[derive(Serialize)]
struct Samples {
    build: Vec<u64>,
    finalize: Vec<u64>,
    frame: Vec<u64>,
}

#[derive(Serialize)]
struct Output {
    submitted_widgets: usize,
    visible_widgets: usize,
    paint_commands: usize,
    text_bytes: usize,
    dropped_commands: usize,
    dropped_text_bytes: usize,
}

#[derive(Serialize)]
struct Environment {
    os: &'static str,
    arch: &'static str,
    cpu: &'static str,
    toolchain: &'static str,
}

#[derive(Serialize)]
struct ResultRecord {
    schema_version: u32,
    framework: &'static str,
    framework_revision: &'static str,
    backend: &'static str,
    layer: &'static str,
    workload: String,
    scale: usize,
    repetition: usize,
    warmup_frames: usize,
    measured_frames: usize,
    valid: bool,
    invalid_reason: &'static str,
    state_checksum: u64,
    samples_ns: Samples,
    output: Output,
    environment: Environment,
}

fn parse_options() -> Option<Options> {
    let mut options = Options {
        workload: "labels_repeated".to_owned(),
        scale: 100,
        warmup: WARMUP_DEFAULT,
        frames: FRAMES_DEFAULT,
        repetition: 0,
    };
    for argument in env::args().skip(1) {
        if let Some(value) = argument.strip_prefix("--workload=") {
            options.workload = value.to_owned();
        } else if let Some(value) = argument.strip_prefix("--scale=") {
            options.scale = value.parse().ok()?;
        } else if let Some(value) = argument.strip_prefix("--warmup=") {
            options.warmup = value.parse().ok()?;
        } else if let Some(value) = argument.strip_prefix("--frames=") {
            options.frames = value.parse().ok()?;
        } else if let Some(value) = argument.strip_prefix("--repetition=") {
            options.repetition = value.parse().ok()?;
        } else {
            return None;
        }
    }
    (options.scale > 0 && options.frames > 0).then_some(options)
}

fn hash_u64(mut hash: u64, value: u64) -> u64 {
    for byte in value.to_le_bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

fn label_for(index: usize, unique: bool) -> String {
    if unique {
        format!("Widget {index:08}")
    } else {
        "Widget".to_owned()
    }
}

fn labels(ui: &mut egui::Ui, count: usize, unique: bool) -> usize {
    for index in 0..count {
        let rect = Rect::from_min_size(
            pos2((index % 10) as f32 * 126.0, (index / 10) as f32 * 18.0),
            vec2(124.0, 18.0),
        );
        ui.put(rect, egui::Label::new(label_for(index, unique)));
    }
    count
}

fn buttons(ui: &mut egui::Ui, count: usize) -> usize {
    for index in 0..count {
        let rect = Rect::from_min_size(
            pos2((index % 10) as f32 * 100.0, (index / 10) as f32 * 26.0),
            vec2(96.0, 24.0),
        );
        ui.push_id(index, |ui| {
            ui.put(rect, Button::new("Button"));
        });
    }
    count
}

fn mixed(
    ui: &mut egui::Ui,
    groups: usize,
    checked: &mut [bool],
    values: &mut [f32],
    text: &mut [String],
) -> usize {
    for index in 0..groups {
        let y = index as f32 * 30.0;
        ui.put(
            Rect::from_min_size(pos2(0.0, y), vec2(100.0, 24.0)),
            egui::Label::new("Label"),
        );
        ui.put(
            Rect::from_min_size(pos2(105.0, y), vec2(120.0, 24.0)),
            Checkbox::new(&mut checked[index], "Check"),
        );
        ui.put(
            Rect::from_min_size(pos2(230.0, y), vec2(140.0, 24.0)),
            Slider::new(&mut values[index], 0.0..=1.0),
        );
        ui.put(
            Rect::from_min_size(pos2(375.0, y), vec2(160.0, 24.0)),
            TextEdit::singleline(&mut text[index]),
        );
        ui.put(
            Rect::from_min_size(pos2(540.0, y), vec2(96.0, 24.0)),
            Button::new("Submit"),
        );
    }
    groups * 5
}

fn virtual_list(ui: &mut egui::Ui, logical_count: usize) -> usize {
    let submitted = logical_count.min(VIRTUAL_ROWS + VIRTUAL_OVERSCAN * 2);
    let start = logical_count
        .saturating_div(2)
        .saturating_sub(VIRTUAL_OVERSCAN);
    for offset in 0..submitted {
        let rect = Rect::from_min_size(pos2(0.0, offset as f32 * 18.0), vec2(320.0, 18.0));
        ui.put(rect, egui::Label::new(label_for(start + offset, true)));
    }
    submitted
}

fn table(ui: &mut egui::Ui, rows: usize, unique: bool) -> usize {
    for row in 0..rows {
        for column in 0..4 {
            let rect = Rect::from_min_size(
                pos2(column as f32 * 220.0, row as f32 * 18.0),
                vec2(216.0, 18.0),
            );
            ui.put(rect, egui::Label::new(label_for(row * 4 + column, unique)));
        }
    }
    rows * 4
}

fn workload(
    ui: &mut egui::Ui,
    options: &Options,
    frame: usize,
    checked: &mut [bool],
    values: &mut [f32],
    text: &mut [String],
) -> Option<usize> {
    match options.workload.as_str() {
        "labels_repeated" => Some(labels(ui, options.scale, false)),
        "labels_unique" | "list_full" => Some(labels(ui, options.scale, true)),
        "button_grid" | "accessibility" | "capacity" => Some(buttons(ui, options.scale)),
        "mixed_form" => Some(mixed(ui, options.scale, checked, values, text)),
        "list_virtual" => Some(virtual_list(ui, options.scale)),
        "table_repeated" => Some(table(ui, options.scale, false)),
        "table_unique" => Some(table(ui, options.scale, true)),
        "dynamic_churn" => ui
            .push_id(frame % options.scale, |ui| labels(ui, options.scale, true))
            .inner
            .into(),
        _ => None,
    }
}

fn main() -> ExitCode {
    let Some(options) = parse_options() else {
        return ExitCode::from(2);
    };
    let context = Context::default();
    let state_count = options.scale.max(1);
    let mut checked = vec![false; state_count];
    let mut values = vec![0.5; state_count];
    let mut text = vec!["Input".to_owned(); state_count];
    let mut build_samples = Vec::with_capacity(options.frames);
    let mut finalize_samples = Vec::with_capacity(options.frames);
    let mut checksum = FNV_BASIS;
    let mut submitted = 0;
    let mut paint_commands = 0;
    for frame in 0..(options.warmup + options.frames) {
        let input = RawInput {
            screen_rect: Some(Rect::from_min_size(pos2(0.0, 0.0), vec2(1280.0, 720.0))),
            ..Default::default()
        };
        let build_started = Instant::now();
        let output = context.run(input, |context| {
            egui::CentralPanel::default().show(context, |ui| {
                submitted = workload(ui, &options, frame, &mut checked, &mut values, &mut text)
                    .unwrap_or(0);
            });
        });
        let build_ns = build_started.elapsed().as_nanos() as u64;
        let finalize_started = Instant::now();
        paint_commands = output.shapes.len();
        let _primitives = context.tessellate(output.shapes, output.pixels_per_point);
        let finalize_ns = finalize_started.elapsed().as_nanos() as u64;
        if frame >= options.warmup {
            build_samples.push(build_ns);
            finalize_samples.push(finalize_ns);
            checksum = hash_u64(checksum, submitted as u64);
        }
    }
    if submitted == 0 {
        return ExitCode::from(2);
    }
    let result = ResultRecord {
        schema_version: 1,
        framework: "egui",
        framework_revision: "f2ab57d6987a9b7984f0637cc4d9f2fd173c507c",
        backend: "headless",
        layer: "core",
        workload: options.workload,
        scale: options.scale,
        repetition: options.repetition,
        warmup_frames: options.warmup,
        measured_frames: options.frames,
        valid: true,
        invalid_reason: "",
        state_checksum: checksum,
        samples_ns: Samples {
            build: build_samples,
            finalize: finalize_samples,
            frame: Vec::new(),
        },
        output: Output {
            submitted_widgets: submitted,
            visible_widgets: submitted.min(VIRTUAL_ROWS),
            paint_commands,
            text_bytes: 0,
            dropped_commands: 0,
            dropped_text_bytes: 0,
        },
        environment: Environment {
            os: env::consts::OS,
            arch: env::consts::ARCH,
            cpu: "runner",
            toolchain: "rust 1.90.0",
        },
    };
    println!(
        "{}",
        serde_json::to_string(&result).expect("result serialization")
    );
    ExitCode::SUCCESS
}
