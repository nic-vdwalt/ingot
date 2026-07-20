// ingot_input.js — DOM input → ingot engine bridge.
//
// Captures keyboard / pointer / wheel / focus events on the canvas and forwards
// them into the engine's exported input entry points (gfx/input_web.odin), which
// stage them for the next frame's poll. Browser KeyboardEvent.code strings are
// mapped here to ingot/raylib KeyboardKey integers (== GLFW values) so the Odin
// side stays backend-neutral.
(function () {
	"use strict";

	// KeyboardEvent.code → ingot KeyboardKey integer (see gfx/types.odin).
	const KEY = {
		Space: 32, Quote: 39, Comma: 44, Minus: 45, Period: 46, Slash: 47,
		Digit0: 48, Digit1: 49, Digit2: 50, Digit3: 51, Digit4: 52,
		Digit5: 53, Digit6: 54, Digit7: 55, Digit8: 56, Digit9: 57,
		Semicolon: 59, Equal: 61,
		KeyA: 65, KeyB: 66, KeyC: 67, KeyD: 68, KeyE: 69, KeyF: 70, KeyG: 71,
		KeyH: 72, KeyI: 73, KeyJ: 74, KeyK: 75, KeyL: 76, KeyM: 77, KeyN: 78,
		KeyO: 79, KeyP: 80, KeyQ: 81, KeyR: 82, KeyS: 83, KeyT: 84, KeyU: 85,
		KeyV: 86, KeyW: 87, KeyX: 88, KeyY: 89, KeyZ: 90,
		BracketLeft: 91, Backslash: 92, BracketRight: 93, Backquote: 96,
		Escape: 256, Enter: 257, Tab: 258, Backspace: 259, Insert: 260,
		Delete: 261, ArrowRight: 262, ArrowLeft: 263, ArrowDown: 264,
		ArrowUp: 265, PageUp: 266, PageDown: 267, Home: 268, End: 269,
		CapsLock: 280, ScrollLock: 281, NumLock: 282, PrintScreen: 283,
		Pause: 284,
		F1: 290, F2: 291, F3: 292, F4: 293, F5: 294, F6: 295, F7: 296,
		F8: 297, F9: 298, F10: 299, F11: 300, F12: 301,
		Numpad0: 320, Numpad1: 321, Numpad2: 322, Numpad3: 323, Numpad4: 324,
		Numpad5: 325, Numpad6: 326, Numpad7: 327, Numpad8: 328, Numpad9: 329,
		NumpadDecimal: 330, NumpadDivide: 331, NumpadMultiply: 332,
		NumpadSubtract: 333, NumpadAdd: 334, NumpadEnter: 335, NumpadEqual: 336,
		ShiftLeft: 340, ControlLeft: 341, AltLeft: 342, MetaLeft: 343,
		ShiftRight: 344, ControlRight: 345, AltRight: 346, MetaRight: 347,
		ContextMenu: 348,
	};

	// browser MouseEvent.button → ingot MouseButton (LEFT=0, RIGHT=1, MIDDLE=2)
	const BTN = { 0: 0, 1: 2, 2: 1, 3: 3, 4: 4 };

	// Keys we consume so the browser doesn't scroll/navigate when the canvas has
	// focus (arrows, space, tab, backspace, page up/down, home/end).
	const CONSUME = new Set([32, 258, 259, 262, 263, 264, 265, 266, 267, 268, 269]);

	function attach(canvasId, wmi) {
		const canvas = document.getElementById(canvasId);
		if (!canvas) return;

		// Exports may not be set at attach time; read lazily at event time.
		const ex = () => (wmi && wmi.exports) ? wmi.exports : null;

		canvas.addEventListener("keydown", function (e) {
			const k = KEY[e.code];
			const x = ex();
			if (!x) return;
			if (k !== undefined) {
				x.ingot_web_key(k, true, e.repeat);
				if (CONSUME.has(k)) e.preventDefault();
			}
			// printable char (no ctrl/meta) → char queue, like GLFW's char cb
			if (!e.ctrlKey && !e.metaKey && e.key && e.key.length === 1) {
				x.ingot_web_char(e.key.codePointAt(0));
			}
		});

		canvas.addEventListener("keyup", function (e) {
			const k = KEY[e.code];
			const x = ex();
			if (x && k !== undefined) x.ingot_web_key(k, false, false);
		});

		canvas.addEventListener("pointermove", function (e) {
			const x = ex();
			if (x) x.ingot_web_mouse_move(e.offsetX, e.offsetY);
		});

		canvas.addEventListener("pointerdown", function (e) {
			const x = ex();
			if (!x) return;
			canvas.focus();
			canvas.setPointerCapture && canvas.setPointerCapture(e.pointerId);
			x.ingot_web_mouse_move(e.offsetX, e.offsetY);
			const b = BTN[e.button];
			if (b !== undefined) x.ingot_web_mouse_button(b, true);
		});

		canvas.addEventListener("pointerup", function (e) {
			const x = ex();
			if (!x) return;
			const b = BTN[e.button];
			if (b !== undefined) x.ingot_web_mouse_button(b, false);
		});

		canvas.addEventListener("wheel", function (e) {
			const x = ex();
			if (!x) return;
			// Normalize to "notches" and flip sign: browser deltaY>0 = scroll
			// down; GLFW yoffset>0 = scroll up (raylib GetMouseWheelMove parity).
			let dx = e.deltaX, dy = e.deltaY;
			if (e.deltaMode === 0) { dx /= 100; dy /= 100; } // pixel → notch
			x.ingot_web_wheel(-dx, -dy);
			e.preventDefault();
		}, { passive: false });

		canvas.addEventListener("pointerenter", function () {
			const x = ex(); if (x) x.ingot_web_hover(true);
		});
		canvas.addEventListener("pointerleave", function () {
			const x = ex(); if (x) x.ingot_web_hover(false);
		});
		canvas.addEventListener("blur", function () {
			const x = ex(); if (x) x.ingot_web_hover(false);
		});
		// Suppress the browser context menu so right-click works as a UI button.
		canvas.addEventListener("contextmenu", function (e) { e.preventDefault(); });
	}

	window.ingotInput = { attach: attach };
})();
