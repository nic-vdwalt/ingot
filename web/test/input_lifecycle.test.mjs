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
