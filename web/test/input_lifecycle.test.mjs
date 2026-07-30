import test from "node:test";
import assert from "node:assert/strict";
import { install, stubDocument } from "./dom_stub.mjs";

await install();
await import("../ingot_input.js");

const exports = {
	ingot_web_key() {},
	ingot_web_char() {},
	ingot_web_preedit_clear() {},
	ingot_web_preedit_char() {},
	ingot_web_mouse_move() {},
	ingot_web_mouse_button() {},
	ingot_web_wheel() {},
	ingot_web_hover() {},
};

test("input attach replaces the previous listener set", () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const first = globalThis.ingotInput.attach("ingot-canvas", { exports });
	assert.equal(canvas.listeners.get("keydown").length, 1);
	const second = globalThis.ingotInput.attach("ingot-canvas", { exports });
	assert.equal(canvas.listeners.get("keydown").length, 1);
	first();
	assert.equal(canvas.listeners.get("keydown").length, 1);
	second();
	assert.equal(canvas.listeners.has("keydown"), false);
});

test("input detach is idempotent", () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	globalThis.ingotInput.attach("ingot-canvas", { exports });
	globalThis.ingotInput.detach();
	globalThis.ingotInput.detach();
	assert.equal(canvas.listeners.size, 0);
});

// --- touch drag scrolling ---------------------------------------------------
//
// The engine scrolls panes from wheel deltas, and touch emits no `wheel`, so
// a one-finger drag is translated into wheel notches (see ingot_input.js).
// The whole design hinges on one threshold, and both sides of it are bugs:
// too eager and every tap scrolls instead of pressing a button, too lazy and
// short flicks feel dead. These tests pin both edges, plus the paths where a
// gesture is taken away mid-flight.

function recorder() {
	const events = [];
	return {
		events,
		exports: {
			...exports,
			ingot_web_mouse_move: (x, y) => events.push(["move", x, y]),
			ingot_web_mouse_button: (b, down) => events.push(["button", b, down]),
			ingot_web_wheel: (dx, dy) => events.push(["wheel", dx, dy]),
		},
	};
}

const touch = (pointerId, clientX, clientY, button = 0) => ({
	pointerType: "touch", pointerId, clientX, clientY,
	offsetX: clientX, offsetY: clientY, button,
});

test("a touch tap under the slop presses and releases once", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	await canvas.dispatch("pointerdown", touch(1, 100, 100));
	// A finger always rolls a little; 3 px must still read as a tap.
	await canvas.dispatch("pointermove", touch(1, 101, 103));
	await canvas.dispatch("pointerup", touch(1, 101, 103));

	const buttons = events.filter((e) => e[0] === "button");
	assert.deepEqual(buttons, [["button", 0, true], ["button", 0, false]]);
	assert.equal(events.some((e) => e[0] === "wheel"), false, "a tap must not scroll");
	detach();
});

test("a touch drag past the slop scrolls and never presses", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	await canvas.dispatch("pointerdown", touch(1, 100, 300));
	await canvas.dispatch("pointermove", touch(1, 100, 280));
	await canvas.dispatch("pointermove", touch(1, 100, 260));
	await canvas.dispatch("pointerup", touch(1, 100, 260));

	const wheels = events.filter((e) => e[0] === "wheel");
	assert.ok(wheels.length > 0, "dragging must produce wheel deltas");
	// Pressing the button under the finger while scrolling would activate
	// whatever the gesture started on - the bug this deferral exists to stop.
	assert.equal(events.some((e) => e[0] === "button"), false, "a drag must not click");
	// Dragging up (clientY decreasing) scrolls content the same direction a
	// wheel-down does: negative notches.
	assert.ok(wheels.every((e) => e[2] < 0), "upward drag must scroll one way");
	detach();
});

test("touch scroll direction follows the finger", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	await canvas.dispatch("pointerdown", touch(1, 100, 100));
	await canvas.dispatch("pointermove", touch(1, 100, 140));
	const down = events.filter((e) => e[0] === "wheel");
	assert.ok(down.length > 0 && down.every((e) => e[2] > 0),
		"dragging down must scroll the opposite way to dragging up");
	detach();
});

test("a cancelled touch abandons the pending tap", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	await canvas.dispatch("pointerdown", touch(1, 50, 50));
	// The OS taking the gesture (system swipe, incoming call) must not
	// activate the widget the finger happened to be resting on.
	await canvas.dispatch("pointercancel", touch(1, 50, 50));
	await canvas.dispatch("pointerup", touch(1, 50, 50));
	assert.equal(events.some((e) => e[0] === "button"), false);
	detach();
});

test("mouse input is unaffected by the touch path", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	const mouse = { pointerType: "mouse", pointerId: 7, button: 0, offsetX: 5, offsetY: 6 };
	await canvas.dispatch("pointerdown", mouse);
	// A mouse presses immediately - deferring it would add a frame of
	// latency to every desktop click.
	assert.deepEqual(events.filter((e) => e[0] === "button"), [["button", 0, true]]);
	await canvas.dispatch("pointerup", mouse);
	assert.deepEqual(
		events.filter((e) => e[0] === "button"),
		[["button", 0, true], ["button", 0, false]],
	);
	assert.equal(events.some((e) => e[0] === "wheel"), false);
	detach();
});

test("simultaneous touches are bounded", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	// A browser can drop pointerup when a gesture is stolen, so unbounded
	// tracking would accumulate forever.
	for (let i = 0; i < 40; i += 1) {
		await canvas.dispatch("pointerdown", touch(i, 10 + i, 10));
	}
	// The 11th onward are ignored: their taps do nothing rather than
	// growing the map.
	for (let i = 0; i < 40; i += 1) {
		await canvas.dispatch("pointerup", touch(i, 10 + i, 10));
	}
	const presses = events.filter((e) => e[0] === "button" && e[2] === true);
	assert.ok(presses.length <= 10, `expected <= 10 tracked taps, got ${presses.length}`);
	detach();
});
