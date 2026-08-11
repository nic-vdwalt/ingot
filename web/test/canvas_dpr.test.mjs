"use strict";

// Canvas backing-store scale.
//
// ingot_web.js caps devicePixelRatio at CANVAS_DPR_MAX before sizing the
// canvas, because a phone reporting dpr 3 on a 390x844 viewport produces an
// 1170x2532 framebuffer - about 12 MB per swapchain buffer, and a swapchain
// holds several. That cap changes rendering for every web user, so it is
// worth pinning.
//
// The critical property is not the clamp itself but the AGREEMENT between the
// two places the ratio is read: fitCanvas sizes the backing store, and the
// engine reads ingot_device_pixel_ratio to compute its framebuffer size as
// css x dpr. If those two ever disagree, gfx configures a swapchain that does
// not match the canvas - a whole-frame rendering bug with no error message.
// Capping one and not the other is exactly the mistake this file exists to
// catch.

import test from "node:test";
import assert from "node:assert/strict";
import { install, stubDocument } from "./dom_stub.mjs";

const installed = await install();

// A portrait iPhone viewport: the case the cap was introduced for.
const PHONE_CSS_WIDTH = 390;
const PHONE_CSS_HEIGHT = 844;

function withRatio(ratio, body) {
	const previous = globalThis.devicePixelRatio;
	globalThis.devicePixelRatio = ratio;
	try {
		return body();
	} finally {
		globalThis.devicePixelRatio = previous;
	}
}

function canvas() {
	return stubDocument.getElementById("ingot-canvas");
}

function reportedRatio() {
	return globalThis.ingotWeb.ingotImports().ingot_device_pixel_ratio();
}

function reportedSize() {
	const imports = globalThis.ingotWeb.ingotImports();
	return [imports.ingot_canvas_pixel_width(), imports.ingot_canvas_pixel_height()];
}

test("threaded binaries receive serial fallback imports", () => {
	const imports = installed.hook.box3dWorkerImports(null);
	assert.equal(imports.schedule(0, 0), false);
	assert.equal(imports.request_step(), false);
	assert.equal(imports.request_batch(30), false);
	assert.equal(imports.batch_ready(), false);
	assert.equal(imports.batch_elapsed_micros(), 0);
	assert.equal(imports.batch_step_count(), 0);
	assert.equal(imports.task_count(), 0);
	assert.equal(imports.queue_high_water(), 0);
	assert.equal(imports.failure_count(), 0);
	assert.equal(imports.completion_generation(), 0);
	assert.equal(imports.worker_count(), 1);
});

test("high device pixel ratios are capped", () => {
	// dpr 3 would cost 2.25x the pixels of dpr 2 for a difference few people
	// can see at arm's length.
	withRatio(3, () => assert.equal(reportedRatio(), 2));
	withRatio(4, () => assert.equal(reportedRatio(), 2));
});

test("ordinary device pixel ratios pass through untouched", () => {
	// The cap must not degrade the displays that were already fine.
	withRatio(1, () => assert.equal(reportedRatio(), 1));
	withRatio(1.5, () => assert.equal(reportedRatio(), 1.5));
	withRatio(2, () => assert.equal(reportedRatio(), 2));
});

test("an invalid ratio falls back to 1", () => {
	// Some embedded webviews report invalid values during viewport transitions;
	// sizing from one would produce an illegal or enormous surface.
	withRatio(0, () => assert.equal(reportedRatio(), 1));
	withRatio(-1, () => assert.equal(reportedRatio(), 1));
	withRatio(Infinity, () => assert.equal(reportedRatio(), 1));
	withRatio(NaN, () => assert.equal(reportedRatio(), 1));
	withRatio(undefined, () => assert.equal(reportedRatio(), 1));
});

test("fitCanvas and the engine agree on the ratio", () => {
	// The invariant: gfx computes its framebuffer as css x dpr, so whatever
	// fitCanvas used to size the backing store must be what the engine reads.
	// Asserting the product rather than the constant means this fails if
	// either side is changed alone.
	const element = canvas();
	element.setBoundingClientRect({ width: PHONE_CSS_WIDTH, height: PHONE_CSS_HEIGHT });
	withRatio(3, () => {
		globalThis.ingotWeb.fitCanvas();
		const ratio = reportedRatio();
		assert.equal(element.width, Math.round(PHONE_CSS_WIDTH * ratio));
		assert.equal(element.height, Math.round(PHONE_CSS_HEIGHT * ratio));
	});
});

test("the cap actually reduces the backing store on a phone", () => {
	// Guards against a future refactor that keeps the two sides in agreement
	// but drops the cap: 390x844 at dpr 3 is 1170x2532 (11.9 MB per buffer),
	// at dpr 2 it is 780x1688 (5.3 MB).
	const element = canvas();
	element.setBoundingClientRect({ width: PHONE_CSS_WIDTH, height: PHONE_CSS_HEIGHT });
	withRatio(3, () => {
		globalThis.ingotWeb.fitCanvas();
		assert.equal(element.width, 780);
		assert.equal(element.height, 1688);
		const megabytes = (element.width * element.height * 4) / (1024 * 1024);
		assert.ok(megabytes < 6, `expected under 6 MiB per buffer, got ${megabytes}`);
	});
});

test("resizing to a smaller css box shrinks the backing store", () => {
	// fitCanvas only assigns when the value differs; a stale larger buffer
	// would keep the memory it was meant to release.
	const element = canvas();
	element.setBoundingClientRect({ width: 1200, height: 800 });
	withRatio(2, () => {
		globalThis.ingotWeb.fitCanvas();
		assert.equal(element.width, 2400);
	});
	element.setBoundingClientRect({ width: 600, height: 400 });
	withRatio(2, () => {
		globalThis.ingotWeb.fitCanvas();
		assert.equal(element.width, 1200);
		assert.equal(element.height, 800);
	});
});

test("a degenerate css box still yields a usable canvas", () => {
	// A collapsed or hidden container reports zero; WebGPU cannot configure a
	// zero-sized surface, so fitCanvas must floor at one pixel.
	const element = canvas();
	element.setBoundingClientRect({ width: 0, height: 0 });
	withRatio(2, () => {
		globalThis.ingotWeb.fitCanvas();
		assert.ok(element.width >= 1);
		assert.ok(element.height >= 1);
	});
});

test("invalid and enormous css dimensions stay within WebGPU's portable bound", () => {
	const element = canvas();
	for (const size of [Infinity, NaN, Number.MAX_VALUE]) {
		element.setBoundingClientRect({ width: size, height: size });
		globalThis.ingotWeb.fitCanvas();
		assert.ok(element.width >= 1 && element.width <= 8192);
		assert.ok(element.height >= 1 && element.height <= 8192);
		assert.ok(element.width * element.height <= 4 * 1024 * 1024);
		assert.deepEqual(reportedSize(), [element.width, element.height]);
	}
});

test("the engine reads the validated backing store during viewport transitions", () => {
	const element = canvas();
	element.setBoundingClientRect({ width: PHONE_CSS_WIDTH, height: PHONE_CSS_HEIGHT });
	withRatio(3, () => globalThis.ingotWeb.fitCanvas());
	assert.deepEqual(reportedSize(), [780, 1688]);
	element.setBoundingClientRect({ width: 0, height: 0 });
	withRatio(Infinity, () => globalThis.ingotWeb.fitCanvas());
	assert.deepEqual(reportedSize(), [1, 1]);
});
