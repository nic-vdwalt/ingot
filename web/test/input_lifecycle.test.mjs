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
	ingot_web_pointer() {},
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
			ingot_web_pointer: (...args) => events.push(["pointer", ...args]),
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
	assert.deepEqual(
		events.filter((e) => e[0] === "pointer").map((e) => e[3]),
		[1, 0, 2],
	);
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
	assert.equal(events.filter((e) => e[0] === "pointer").at(-1)[3], 3);
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

test("simultaneous pointer IDs and pen pressure remain distinct", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });

	await canvas.dispatch("pointerdown", { ...touch(21, 10, 20), buttons: 1, pressure: 0.75, isPrimary: true });
	await canvas.dispatch("pointerdown", { ...touch(22, 30, 40), buttons: 1, pressure: 0.5 });
	await canvas.dispatch("pointerdown", {
		pointerType: "pen", pointerId: 23, button: 0, buttons: 1,
		offsetX: 50, offsetY: 60, pressure: 0.625, isPrimary: true,
	});
	const raw = events.filter((e) => e[0] === "pointer");
	assert.deepEqual(raw.map((e) => e[1]), [21, 22, 23]);
	assert.deepEqual(raw.map((e) => e[2]), [2, 2, 3]);
	assert.equal(raw[2][8], 0.625);
	assert.equal(raw[2][9], true);
	detach();
});

test("pointer buttons remap browser right and middle bits", async () => {
	const canvas = stubDocument.getElementById("ingot-canvas");
	const { events, exports: ex } = recorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });
	await canvas.dispatch("pointerdown", {
		pointerType: "mouse", pointerId: 31, button: 2, buttons: 2,
		offsetX: 5, offsetY: 6,
	});
	await canvas.dispatch("pointermove", {
		pointerType: "mouse", pointerId: 31, button: -1, buttons: 6,
		offsetX: 6, offsetY: 7,
	});
	const raw = events.filter((e) => e[0] === "pointer");
	assert.equal(raw[0][4], 1);
	assert.equal(raw[0][5], 2);
	assert.equal(raw[1][5], 6);
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

// --- keyboard forwarding ----------------------------------------------------
//
// Canvas-drawn text fields get their keys through the hidden IME proxy, a
// real <textarea>. Editing keys must reach the engine as key events and must
// not also drive the proxy's own default behaviour - an unconsumed Enter
// types a newline into a value the engine never reads.

function keyRecorder() {
	const keys = [];
	return {
		keys,
		exports: { ...exports, ingot_web_key: (k, down, repeat) => keys.push([k, down, repeat]) },
	};
}

const keyEvent = (code, extra = {}) => {
	let prevented = false;
	return {
		code,
		key: code,
		repeat: false,
		ctrlKey: false,
		metaKey: false,
		preventDefault: () => { prevented = true; },
		get prevented() { return prevented; },
		...extra,
	};
};

test("editing keys reach the engine from the IME proxy", async () => {
	const { keys, exports: ex } = keyRecorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });
	const ime = stubDocument.getElementById("ingot-ime");
	assert.ok(ime, "the IME proxy must exist");

	for (const code of ["Enter", "Backspace", "Delete", "ArrowLeft", "Tab"]) {
		await ime.dispatch("keydown", keyEvent(code));
	}

	assert.deepEqual(keys.map((k) => k[0]), [257, 259, 261, 263, 258]);
	assert.ok(keys.every((k) => k[1] === true), "every keydown must report a press");
	detach();
});

test("Enter and Backspace are consumed so the proxy never edits itself", async () => {
	const { exports: ex } = keyRecorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });
	const ime = stubDocument.getElementById("ingot-ime");

	for (const code of ["Enter", "Backspace", "Tab", "ArrowUp"]) {
		const event = keyEvent(code);
		await ime.dispatch("keydown", event);
		assert.equal(event.prevented, true, `${code} must be consumed`);
	}
	// A printable key is not ours to swallow: the browser still owns
	// composition and the char callback carries the value.
	const letter = keyEvent("KeyA", { key: "a" });
	await ime.dispatch("keydown", letter);
	assert.equal(letter.prevented, false, "printable keys must not be consumed");
	detach();
});

test("key repeat is reported as repeat, not as a fresh press", async () => {
	const { keys, exports: ex } = keyRecorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });
	const ime = stubDocument.getElementById("ingot-ime");

	await ime.dispatch("keydown", keyEvent("Backspace"));
	await ime.dispatch("keydown", keyEvent("Backspace", { repeat: true }));
	await ime.dispatch("keyup", keyEvent("Backspace"));

	assert.deepEqual(keys, [[259, true, false], [259, true, true], [259, false, false]]);
	detach();
});

test("pointer events synchronize Option held before canvas focus", async () => {
	const { keys, exports: ex } = keyRecorder();
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });
	const canvas = stubDocument.getElementById("ingot-canvas");
	const pointer = {
		pointerType: "mouse", pointerId: 7, button: 0,
		offsetX: 5, offsetY: 6, altKey: true,
		shiftKey: false, ctrlKey: false, metaKey: false,
	};

	await canvas.dispatch("pointerdown", pointer);
	await canvas.dispatch("pointermove", pointer);
	assert.deepEqual(keys, [[342, true, false]]);
	await canvas.dispatch("pointerup", { ...pointer, altKey: false });
	assert.deepEqual(keys, [[342, true, false], [342, false, false]]);
	detach();
});

test("pointer leave preserves captured drag input", async () => {
	const events = [];
	const ex = {
		...exports,
		ingot_web_key: (k, down, repeat) => events.push(["key", k, down, repeat]),
		ingot_web_mouse_button: (b, down) => events.push(["button", b, down]),
		ingot_web_hover: (hovered) => events.push(["hover", hovered]),
	};
	const detach = globalThis.ingotInput.attach("ingot-canvas", { exports: ex });
	const canvas = stubDocument.getElementById("ingot-canvas");
	const pointer = {
		pointerType: "mouse", pointerId: 7, button: 0,
		offsetX: 5, offsetY: 6, altKey: true,
		shiftKey: false, ctrlKey: false, metaKey: false,
	};

	await canvas.dispatch("pointerdown", pointer);
	await canvas.dispatch("pointerleave", pointer);
	assert.equal(events.some((event) => event[0] === "hover" && event[1] === false), false);
	assert.equal(events.some((event) => event[0] === "key" && event[2] === false), false);
	assert.equal(events.some((event) => event[0] === "button" && event[2] === false), false);
	detach();
});
