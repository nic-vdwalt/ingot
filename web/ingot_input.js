// ingot_input.js - DOM input → ingot engine bridge.
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

	let detachCurrent = null;

	function attach(canvasId, wmi) {
		if (detachCurrent) detachCurrent();
		const canvas = document.getElementById(canvasId);
		if (!canvas) return () => {};
		const listeners = [];
		const pressedKeys = new Set();
		const pressedButtons = new Set();
		const listen = (target, type, handler, options) => {
			target.addEventListener(type, handler, options);
			listeners.push([target, type, handler, options]);
		};

		// Exports may not be set at attach time; read lazily at event time.
		const ex = () => (wmi && wmi.exports) ? wmi.exports : null;

		// Hidden IME proxy: a transparent textarea positioned at the caret by
		// the engine (ingot_ime_rect in ingot_web.js). The canvas never gets
		// browser composition events; this element does, giving canvas-drawn
		// text fields real IME (Pinyin, Japanese, dead keys).
		let ime = document.getElementById("ingot-ime");
		if (!ime) {
			ime = document.createElement("textarea");
			ime.id = "ingot-ime";
			ime.setAttribute("autocomplete", "off");
			ime.setAttribute("autocapitalize", "off");
			ime.setAttribute("autocorrect", "off");
			ime.setAttribute("spellcheck", "false");
			ime.setAttribute("tabindex", "-1");
			ime.style.cssText =
				"position:absolute;width:1px;height:1px;padding:0;border:0;" +
				"margin:0;outline:none;opacity:0;overflow:hidden;resize:none;" +
				"background:transparent;color:transparent;caret-color:transparent;" +
				"pointer-events:none;left:0;top:0;";
			document.body.appendChild(ime);
		}

		function onKeydown(e) {
			const x = ex();
			if (!x) return;
			// While the OS input method is composing, keydowns are IME-internal
			// (keyCode 229); the result arrives via compositionend instead.
			if (e.isComposing || e.keyCode === 229) return;
			const k = KEY[e.code];
			if (k !== undefined) {
				pressedKeys.add(k);
				x.ingot_web_key(k, true, e.repeat);
				if (CONSUME.has(k)) e.preventDefault();
			}
			// printable char (no ctrl/meta) → char queue, like GLFW's char cb
			if (!e.ctrlKey && !e.metaKey && e.key && e.key.length === 1) {
				x.ingot_web_char(e.key.codePointAt(0));
			}
		}

		function onKeyup(e) {
			const k = KEY[e.code];
			const x = ex();
			if (k !== undefined) pressedKeys.delete(k);
			if (x && k !== undefined) x.ingot_web_key(k, false, false);
		}

		listen(canvas, "keydown", onKeydown);
		listen(canvas, "keyup", onKeyup);
		listen(ime, "keydown", onKeydown);
		listen(ime, "keyup", onKeyup);

		// Composition events fire only on the proxy. Preedit updates stage the
		// in-progress string; the final composed text enters the same char
		// queue keystrokes use, so the Odin side needs no special casing.
		const forwardPreedit = (s) => {
			const x = ex();
			if (!x || !x.ingot_web_preedit_clear) return;
			x.ingot_web_preedit_clear();
			if (s) for (const ch of s) x.ingot_web_preedit_char(ch.codePointAt(0));
		};
		listen(ime, "compositionstart", function () {
			forwardPreedit("");
		});
		listen(ime, "compositionupdate", function (e) {
			forwardPreedit(e.data || "");
		});
		listen(ime, "compositionend", function (e) {
			forwardPreedit("");
			const x = ex();
			if (x && e.data) for (const ch of e.data) x.ingot_web_char(ch.codePointAt(0));
			ime.value = ""; // the engine owns the text; proxy is a conduit
		});
		// Non-composition input still mutates the proxy's value (chars are
		// forwarded from keydown); keep it empty so stale text can't leak into
		// the next composition.
		listen(ime, "input", function (e) {
			if (!e.isComposing) ime.value = "";
		});

		listen(canvas, "pointermove", function (e) {
			const x = ex();
			if (x) x.ingot_web_mouse_move(e.offsetX, e.offsetY);
		});

		listen(canvas, "pointerdown", function (e) {
			const x = ex();
			if (!x) return;
			canvas.focus();
			canvas.setPointerCapture && canvas.setPointerCapture(e.pointerId);
			x.ingot_web_mouse_move(e.offsetX, e.offsetY);
			const b = BTN[e.button];
			if (b !== undefined) {
				pressedButtons.add(b);
				x.ingot_web_mouse_button(b, true);
			}
		});

		listen(canvas, "pointerup", function (e) {
			const x = ex();
			if (!x) return;
			const b = BTN[e.button];
			if (b !== undefined) pressedButtons.delete(b);
			if (b !== undefined) x.ingot_web_mouse_button(b, false);
		});

		listen(canvas, "wheel", function (e) {
			const x = ex();
			if (!x) return;
			// Convert the browser wheel delta into the same "notch" units the
			// native GLFW backend feeds the engine, so scroll feels identical.
			// Sign is flipped: browser deltaY>0 = scroll down; GLFW yoffset>0 =
			// scroll up (raylib GetMouseWheelMove parity).
			//
			// GLFW on macOS scales precise (trackpad) Cocoa scrollingDeltaY by
			// 0.1 and passes mouse-wheel line deltas through as ~1/notch. The
			// browser's pixel deltaY is the same underlying NSEvent delta, so:
			//   - trackpad (fine pixel deltas): ×0.1  -> 1:1 with native momentum
			//   - mouse wheel (deltas quantized to ~100/120 px per notch, or line
			//     mode): normalize to ≈1 unit/notch, matching GLFW's coarse path
			let dx = e.deltaX, dy = e.deltaY;
			if (e.deltaMode !== 0) {
				// line (1) or page (2) units - discrete mouse wheel, already ~notches.
			} else {
				// pixel units. A physical wheel emits large deltas that are integer
				// multiples of a fixed step (120 in Chrome, 100 elsewhere); trackpad
				// deltas are small and finely grained (often fractional).
				const ay = Math.abs(dy);
				const coarse = ay >= 100 && (ay % 120 === 0 || ay % 100 === 0);
				const k = coarse ? 0.01 : 0.1;
				dx *= k; dy *= k;
			}
			x.ingot_web_wheel(-dx, -dy);
			e.preventDefault();
		}, { passive: false });

		const releaseHeldInput = () => {
			const x = ex();
			if (x) {
				for (const key of pressedKeys) x.ingot_web_key(key, false, false);
				for (const button of pressedButtons) x.ingot_web_mouse_button(button, false);
			}
			pressedKeys.clear();
			pressedButtons.clear();
		};
		listen(canvas, "pointercancel", releaseHeldInput);
		listen(canvas, "lostpointercapture", releaseHeldInput);
		listen(window, "blur", releaseHeldInput);
		listen(document, "visibilitychange", function () {
			if (document.visibilityState !== "visible") releaseHeldInput();
		});
		listen(canvas, "pointerenter", function () {
			const x = ex(); if (x) x.ingot_web_hover(true);
		});
		listen(canvas, "pointerleave", function () {
			const x = ex(); if (x) x.ingot_web_hover(false);
		});
		listen(canvas, "blur", function (e) {
			// Focus moving to the IME proxy is still "ours" - don't clear
			// held keys mid-typing.
			if (e.relatedTarget && e.relatedTarget.id === "ingot-ime") return;
			const x = ex(); if (x) x.ingot_web_hover(false);
		});
		// Suppress the browser context menu so right-click works as a UI button.
		listen(canvas, "contextmenu", function (e) { e.preventDefault(); });
		let active = true;
		const detach = () => {
			if (!active) return;
			active = false;
			releaseHeldInput();
			for (const [target, type, handler, options] of listeners) {
				target.removeEventListener(type, handler, options);
			}
			if (detachCurrent === detach) detachCurrent = null;
		};
		detachCurrent = detach;
		return detach;
	}

	function detach() {
		if (detachCurrent) detachCurrent();
	}

	window.ingotInput = { attach: attach, detach: detach };
})();
