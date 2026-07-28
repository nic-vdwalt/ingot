// node --test suite for the semantic overlay logic in web/ingot_web.js:
// frame-stamp GC, value-echo protocol, ARIA attributes, and activation
// staging - run against the hand-rolled DOM stub (dom_stub.mjs).
"use strict";

import { test } from "node:test";
import assert from "node:assert/strict";
import { install, stubDocument } from "./dom_stub.mjs";

const hookP = install();

// Sem_Role ordinals (ui/semantics.odin) and Sem_State bits used by
// syncSemanticControl.
const ROLE_BUTTON = 1, ROLE_CHECKBOX = 2, ROLE_SLIDER = 4, ROLE_DROPDOWN = 6;
const ROLE_OPTION = 15, ROLE_LISTBOX = 18;
const STATE_CHECKED = 1, STATE_DISABLED = 2, STATE_EXPANDED = 8, STATE_SELECTED = 16;

test("text input mirror: creation, aria-label, GC by frame stamp", async () => {
	const { hook } = await hookP;
	hook.beginSemanticFrame();
	hook.syncSemanticInput("login", "login-email", "email", "Email address", "", 10, 10, 200, 32, 0, 1, false);
	hook.endSemanticFrame();

	const input = stubDocument.getElementById("login-email");
	assert.ok(input, "input element created");
	assert.equal(input.getAttribute("aria-label"), "Email address");
	assert.equal(input.autocomplete, "username");
	assert.ok(stubDocument.getElementById("login"), "form created");

	// Not synced next frame -> GC removes both input and form.
	hook.beginSemanticFrame();
	hook.endSemanticFrame();
	assert.equal(stubDocument.getElementById("login-email"), null, "input GC'd");
	assert.equal(stubDocument.getElementById("login"), null, "form GC'd");
});

test("text input value-echo: Odin value wins unless user edited", async () => {
	const { hook } = await hookP;
	hook.beginSemanticFrame();
	hook.syncSemanticInput("f", "field", "n", "p", "odin1", 0, 0, 100, 30, 0, 0, false);
	const input = stubDocument.getElementById("field");
	assert.equal(input.value, "odin1", "Odin value adopted");

	// Odin-side change with no user edit: DOM follows.
	hook.beginSemanticFrame();
	hook.syncSemanticInput("f", "field", "n", "p", "odin2", 0, 0, 100, 30, 0, 0, false);
	assert.equal(input.value, "odin2", "Odin update propagates");

	// User edit: DOM value preserved, changed flag reported.
	input.value = "user-typed";
	hook.beginSemanticFrame();
	const flags = hook.syncSemanticInput("f", "field", "n", "p", "odin2", 0, 0, 100, 30, 0, 0, false);
	assert.equal(flags & 1, 1, "changed flag set");
	assert.equal(input.value, "user-typed", "user edit not clobbered");
	hook.endSemanticFrame();
	hook.beginSemanticFrame();
	hook.endSemanticFrame();
});

test("control mirror: roles, ARIA state, activation staging", async () => {
	const { hook } = await hookP;
	hook.beginSemanticFrame();
	assert.equal(hook.syncSemanticControl("1:1", ROLE_BUTTON, "Save", 0, 0, 80, 30, 0, 0, 0, 0), 0);
	assert.equal(hook.syncSemanticControl("1:2", ROLE_CHECKBOX, "On", 0, 40, 80, 24, STATE_CHECKED, 0, 0, 0), 0);
	hook.syncSemanticControl("1:3", ROLE_SLIDER, "Vol", 0, 80, 120, 24, 0, 40, 0, 100);
	hook.syncSemanticControl("1:4", ROLE_DROPDOWN, "Backend", 0, 120, 120, 28, STATE_EXPANDED, 0, 0, 0);
	hook.endSemanticFrame();

	const { semanticControls } = hook.semanticState();
	const btn = semanticControls.get("1:1").el;
	assert.equal(btn.tagName, "BUTTON");
	assert.equal(btn.getAttribute("aria-label"), "Save");
	const cb = semanticControls.get("1:2").el;
	assert.equal(cb.type, "checkbox");
	assert.equal(cb.checked, true);
	const sl = semanticControls.get("1:3").el;
	assert.equal(sl.type, "range");
	assert.equal(sl.value, "40");
	const dd = semanticControls.get("1:4").el;
	assert.equal(dd.getAttribute("aria-haspopup"), "listbox");
	assert.equal(dd.getAttribute("aria-expanded"), "true");

	// AT click on the button: staged, reported once on next sync.
	btn.dispatch("click");
	hook.beginSemanticFrame();
	const flags = hook.syncSemanticControl("1:1", ROLE_BUTTON, "Save", 0, 0, 80, 30, 0, 0, 0, 0);
	assert.equal(flags & 1, 1, "activation reported");
	const again = hook.syncSemanticControl("1:1", ROLE_BUTTON, "Save", 0, 0, 80, 30, 0, 0, 0, 0);
	assert.equal(again & 1, 0, "activation consumed, not repeated");
	hook.endSemanticFrame();

	// Disabled state propagates.
	hook.beginSemanticFrame();
	hook.syncSemanticControl("1:1", ROLE_BUTTON, "Save", 0, 0, 80, 30, STATE_DISABLED, 0, 0, 0);
	assert.equal(btn.disabled, true);
	hook.endSemanticFrame();

	// GC: none synced next frame -> all removed.
	hook.beginSemanticFrame();
	hook.endSemanticFrame();
	assert.equal(semanticControls.size, 0, "controls GC'd");
	assert.ok(!btn.isConnected, "button element removed from DOM");
});

test("control mirror: listbox roles and collection state", async () => {
	const { hook } = await hookP;
	hook.beginSemanticFrame();
	hook.syncSemanticControl("2:1", ROLE_LISTBOX, "Backends", 0, 0, 120, 80, 0, 0, 0, 0);
	hook.syncSemanticControl("2:2", ROLE_OPTION, "Vulkan", 0, 20, 120, 20, STATE_SELECTED, 0, 0, 0, 2, 4);
	hook.endSemanticFrame();

	const { semanticControls } = hook.semanticState();
	const listbox = semanticControls.get("2:1").el;
	assert.equal(listbox.getAttribute("role"), "listbox");
	const option = semanticControls.get("2:2").el;
	assert.equal(option.getAttribute("role"), "option");
	assert.equal(option.getAttribute("aria-selected"), "true");
	assert.equal(option.getAttribute("aria-posinset"), "2");
	assert.equal(option.getAttribute("aria-setsize"), "4");

	hook.beginSemanticFrame();
	hook.syncSemanticControl("2:2", ROLE_OPTION, "Vulkan", 0, 20, 120, 20, 0, 0, 0, 0);
	assert.equal(option.getAttribute("aria-selected"), "false");
	assert.equal(option.getAttribute("aria-posinset"), null);
	hook.endSemanticFrame();
	hook.beginSemanticFrame();
	hook.endSemanticFrame();
	assert.equal(semanticControls.size, 0, "listbox controls GC'd");
});

test("control mirror: role change replaces the element", async () => {
	const { hook } = await hookP;
	hook.beginSemanticFrame();
	hook.syncSemanticControl("9:9", ROLE_BUTTON, "X", 0, 0, 10, 10, 0, 0, 0, 0);
	const first = hook.semanticState().semanticControls.get("9:9").el;
	hook.syncSemanticControl("9:9", ROLE_CHECKBOX, "X", 0, 0, 10, 10, 0, 0, 0, 0);
	const second = hook.semanticState().semanticControls.get("9:9").el;
	assert.notEqual(first._uid, second._uid, "element recreated on role change");
	assert.equal(second.type, "checkbox");
	hook.endSemanticFrame();
	hook.beginSemanticFrame();
	hook.endSemanticFrame();
});

test("submit button: submit event reported once", async () => {
	const { hook } = await hookP;
	hook.beginSemanticFrame();
	assert.equal(hook.syncSemanticSubmit("form2", "Sign in", 0, 0, 100, 30, 0, 16, true), 0);
	const { semanticForms } = hook.semanticState();
	const form = semanticForms.get("form2");
	form.form.dispatch("submit", {});
	assert.equal(hook.syncSemanticSubmit("form2", "Sign in", 0, 0, 100, 30, 0, 16, true), 1, "submit reported");
	assert.equal(hook.syncSemanticSubmit("form2", "Sign in", 0, 0, 100, 30, 0, 16, true), 0, "submit consumed");
	hook.endSemanticFrame();
	hook.beginSemanticFrame();
	hook.endSemanticFrame();
});
