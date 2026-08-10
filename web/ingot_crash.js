// ingot_crash.js - on-device crash reporting for ingot web demos.
//
// Mobile browsers have no reachable console, so a wasm trap in the
// requestAnimationFrame step (odin.js stops scheduling and never reports why)
// or an Odin panic is otherwise indistinguishable from a black canvas. This
// mirrors recent console output into a panel on the page and surfaces
// uncaught errors and rejections there.
//
// Load this BEFORE odin.js/wgpu.js so nothing is missed, and give the page a
// #crash element (any block element) plus a #msg status element.
//
// Root cause vs cascade: a GPU failure usually produces one meaningful line
// (an Odin `gfx:` log) followed by a pile of derived exceptions as the null
// device propagates through the wgpu glue. The FIRST fatal reason is kept as
// the headline and later ones are listed underneath, because the last error
// is almost never the useful one.
//
// BLACK BOX: the in-page panel cannot report the failure that matters most on
// a phone. When iOS Safari kills a tab for memory pressure the process is
// terminated outright - no error event, no rejection, no final frame, and
// nothing left running to draw a panel with. To catch those, breadcrumbs are
// mirrored into sessionStorage as the app runs and the record is cleared on
// pagehide. If the next load still FINDS a record, the previous session never
// reached pagehide - it was killed - and its last breadcrumbs are shown as a
// post-mortem. That turns an invisible tab death into a readable report on
// reload, with no USB cable and no desktop browser.
(function () {
	"use strict";

	// Bounded ring: enough lines to carry the engine's startup logs, small
	// enough to stay readable on a phone screen.
	const RING_MAX = 40;
	// Cascade failures can arrive by the hundreds once a device is null.
	const CASCADE_MAX = 5;
	// Console lines matching this are engine-authored failures worth
	// promoting to the panel on their own, without waiting for a throw.
	const FATAL_PATTERN = /panic|assert|fatal|gfx: /i;

	// --- black box --------------------------------------------------------
	// sessionStorage (not localStorage) so a report belongs to one tab, does
	// not leak between tabs, and does not outlive the browsing session.
	//
	// The key is namespaced by path because sessionStorage is shared by every
	// same-origin document in a tab, INCLUDING iframes. The marketing page
	// embeds four demos at once, and with a single shared key each demo read,
	// on boot, the record a SIBLING was still actively writing. That record
	// has heartbeats in it - the sibling is alive and rendering - so every
	// demo reported a healthy neighbour as a crashed previous session. The
	// same collision destroyed real evidence in the other direction: any one
	// demo shutting down cleanly removed the shared key out from under the
	// others, so a genuine kill afterwards had nothing to recover. One record
	// per document keeps each session's black box its own.
	const BOX_KEY = "ingot.blackbox:" + location.pathname;
	// The pre-namespace key. sessionStorage survives a reload, so a tab left
	// open across this change would otherwise carry a poisoned shared record
	// for the rest of its life. It is never read again, only cleared.
	const BOX_LEGACY_KEY = "ingot.blackbox";
	// Breadcrumbs kept across a kill. Deliberately smaller than RING_MAX:
	// this is rewritten to storage repeatedly, and the last handful of lines
	// is what identifies the phase that died.
	const BOX_CRUMBS_MAX = 20;
	// One pathological line (a whole shader source, a base64 blob) must not
	// consume the storage quota by itself.
	const BOX_CRUMB_CHARS_MAX = 200;
	// Writing on every crumb would add a synchronous storage hit to the frame
	// loop and perturb the very frames being measured. Coalesce to at most
	// one write per interval; a kill loses at most this much history, which
	// is the right trade for not distorting the measurement.
	const BOX_FLUSH_INTERVAL_MS = 1000;

	// --- heartbeat ---------------------------------------------------------
	// Breadcrumbs are console-driven, and a healthy engine logs nothing. The
	// first real capture proved the cost of that: a killed tab produced a
	// single "session start" crumb and no other evidence at all.
	//
	// The heartbeat fixes the blind spot by recording liveness on a timer -
	// how long the tab survived, whether the rAF loop was still running, and
	// what probes (notably the wasm heap size) report. A tab killed for
	// memory then leaves a visible growth curve instead of silence.
	const HEARTBEAT_INTERVAL_MS = 1000;
	// Heartbeats share the crumb ring, so this bounds how much history a
	// steady heartbeat can evict. 20 crumbs at 1s is ~20s of history, which
	// covers "open the page, tap the section, watch it die".
	const HEARTBEAT_PROBES_MAX = 8;

	const ring = [];
	const cascade = [];
	let headline = null;

	const box = {
		crumbs: [],
		started: "",
		dirty: false,
		lastFlush: 0,
		// Set once the session is closed or the box is disabled, so a late
		// crumb cannot resurrect a record already cleared.
		closed: false,
	};
	let postMortem = null;

	// storage probes sessionStorage defensively: private browsing and
	// storage-disabled contexts throw on ACCESS, not just on write. The panel
	// must keep working when the black box cannot.
	function storage() {
		try {
			return window.sessionStorage || null;
		} catch (_) {
			return null;
		}
	}

	function element(id) {
		return document.getElementById(id);
	}

	// boxFlush persists the breadcrumbs. `force` bypasses the coalescing
	// interval for the two moments that matter: a fatal reason, and pagehide.
	function boxFlush(force) {
		if (box.closed) return;
		if (!box.dirty && !force) return;
		const now = Date.now();
		if (!force && now - box.lastFlush < BOX_FLUSH_INTERVAL_MS) return;
		const store = storage();
		if (!store) return;
		box.lastFlush = now;
		box.dirty = false;
		try {
			store.setItem(BOX_KEY, JSON.stringify({
				started: box.started,
				path: location.pathname,
				crumbs: box.crumbs,
			}));
		} catch (_) {
			// Quota exceeded or storage revoked mid-session. Disable the box
			// rather than throwing inside the app it exists to diagnose.
			box.closed = true;
		}
	}

	function boxRecord(line) {
		if (box.closed) return;
		const text = line.length > BOX_CRUMB_CHARS_MAX
			? line.slice(0, BOX_CRUMB_CHARS_MAX) + "..."
			: line;
		box.crumbs.push(Math.round(performance.now()) + "ms " + text);
		if (box.crumbs.length > BOX_CRUMBS_MAX) box.crumbs.shift();
		box.dirty = true;
		boxFlush(false);
	}

	// boxClose marks this session as ended normally by removing the record.
	// Its ABSENCE on the next load is exactly the signal that the tab lived;
	// its presence is the signal that it was killed.
	function boxClose() {
		if (box.closed) return;
		box.closed = true;
		boxForget(BOX_KEY);
	}

	// boxForget drops a key without touching this session's state, for the
	// legacy record that must be evicted but must never be reported.
	function boxForget(key) {
		const store = storage();
		if (!store) return;
		try {
			store.removeItem(key);
		} catch (_) { /* nothing useful to do about a failed cleanup */ }
	}

	// boxRecover reads and clears any record left by a previous session in
	// this tab. Read-and-clear makes recovery one-shot: reloading twice must
	// not report the same death again.
	//
	// A record is only treated as a crash when the previous session actually
	// got running, evidenced by at least one heartbeat. Without that check a
	// reload issued while the module was still downloading looks identical to
	// a kill, and reporting it would cry wolf on an ordinary refresh. A
	// session that dies before its first heartbeat had no frames to lose, so
	// nothing diagnostic is given up.
	//
	// "Previous session in this tab" has to mean the previous session of THIS
	// document. A sibling demo running concurrently in another iframe is not a
	// corpse, and reporting its live heartbeats as a death is a pure false
	// alarm - see BOX_KEY for how that reached production.
	function boxRecover() {
		const store = storage();
		if (!store) return null;
		let raw = null;
		try {
			raw = store.getItem(BOX_KEY);
			if (raw) store.removeItem(BOX_KEY);
		} catch (_) {
			return null;
		}
		if (!raw) return null;
		try {
			const parsed = JSON.parse(raw);
			if (!parsed || !Array.isArray(parsed.crumbs)) return null;
			// Belt and braces alongside the namespaced key: a post-mortem
			// attributed to the wrong demo is worse than no post-mortem,
			// because it sends the next reader into unrelated code.
			if (parsed.path !== undefined && parsed.path !== location.pathname) {
				return null;
			}
			const ran = parsed.crumbs.some((crumb) => crumb.includes("HEARTBEAT"));
			if (!ran) return null;
			return parsed;
		} catch (_) {
			// A truncated write (killed mid-setItem) leaves invalid JSON.
			// Nothing to report, but do not let it break startup.
			return null;
		}
	}

	function postMortemText() {
		if (!postMortem) return "";
		const crumbs = postMortem.crumbs.length > 0
			? postMortem.crumbs.join("\n")
			: "(no breadcrumbs recorded)";
		// "Did not shut down cleanly", not "was killed": the same evidence is
		// produced by a hard browser crash, a force-quit, and some reload
		// paths where pagehide never fires. Overstating it would send the
		// next reader hunting a memory bug that may not exist.
		return "PREVIOUS SESSION DID NOT SHUT DOWN CLEANLY\n" +
			"It ended without reaching pagehide - most often an OS memory kill,\n" +
			"which produces no JavaScript error. Tap this panel to dismiss.\n\n" +
			crumbs + "\n\n" + "-".repeat(48) + "\n\n";
	}

	// dismissed suppresses a post-mortem the reader has already seen, so the
	// report never becomes furniture on a demo that is running fine.
	let dismissed = false;

	function render() {
		const crash = element("crash");
		const msg = element("msg");
		// Only a LIVE crash may touch #msg. On the demo pages that element is
		// a full-screen opaque overlay (position:absolute; inset:0), so
		// showing it for a previous session's post-mortem hides a demo that
		// is rendering perfectly - which is exactly the regression this guard
		// exists to prevent. A live crash is different: there is nothing
		// working underneath to obscure.
		if (msg && headline !== null) {
			msg.hidden = false;
			msg.textContent = "crashed - details below";
		}
		if (!crash) return;
		let text = dismissed ? "" : postMortemText();
		if (headline !== null) {
			text += "reason: " + headline;
			if (cascade.length > 0) {
				text += "\n\nfollow-on errors (usually consequences, not causes):\n" +
					cascade.join("\n");
			}
			text += "\n\nrecent console output:\n" + ring.join("\n");
		}
		if (text === "") {
			crash.style.display = "none";
			return;
		}
		crash.style.display = "block";
		crash.textContent = text;
	}

	// A post-mortem is informational, not fatal, so it must be dismissable.
	// Attached once, lazily, because #crash may not exist on an embedder's
	// page.
	function attachDismiss() {
		const crash = element("crash");
		if (!crash || !crash.addEventListener) return;
		crash.addEventListener("click", () => {
			// Only the post-mortem is dismissable. A live crash report stays:
			// the app is broken and hiding that would be misleading.
			if (headline !== null) return;
			dismissed = true;
			render();
		});
	}

	function show(reason) {
		const text = reason === undefined || reason === null || reason === ""
			? "(no reason reported)"
			: String(reason);
		if (headline === null) {
			headline = text;
		} else if (text !== headline && cascade.length < CASCADE_MAX &&
			!cascade.includes(text)) {
			cascade.push(text);
		}
		// Persist immediately: whatever follows a fatal reason may be the
		// thing that kills the tab, and then this is all that survives.
		boxRecord("FATAL " + text);
		boxFlush(true);
		render();
	}

	function record(line) {
		ring.push(line);
		if (ring.length > RING_MAX) ring.shift();
		boxRecord(line);
		// Engine failures are logged before the trap unwinds, so promote them
		// even if the browser swallows the subsequent error event.
		if (FATAL_PATTERN.test(line)) show(line);
	}

	for (const level of ["log", "warn", "error"]) {
		const original = console[level].bind(console);
		console[level] = function (...args) {
			try {
				record(args.map((a) => typeof a === "string" ? a : String(a)).join(" "));
			} catch (_) { /* never let reporting break the app */ }
			original(...args);
		};
	}

	// --- heartbeat ---------------------------------------------------------

	const probes = [];
	let frames = 0;
	let heartbeatTimer = null;

	// countFrame is chained onto requestAnimationFrame so the heartbeat can
	// report whether the render loop is still ticking. A stalled loop and a
	// killed tab look identical in storage otherwise.
	function installFrameCounter() {
		const original = window.requestAnimationFrame;
		if (typeof original !== "function") return;
		window.requestAnimationFrame = function (callback) {
			return original.call(window, (timestamp) => {
				frames += 1;
				return callback(timestamp);
			});
		};
	}

	function heartbeat() {
		const parts = ["frames=" + frames];
		for (const probe of probes) {
			try {
				const value = probe.read();
				if (value !== undefined && value !== null) {
					parts.push(probe.name + "=" + value);
				}
			} catch (_) {
				// A probe that throws is a broken diagnostic, not a reason to
				// stop recording the rest.
			}
		}
		boxRecord("HEARTBEAT " + parts.join(" "));
		// Forced: an unforced flush could coalesce away the very last
		// heartbeat before a kill, which is the one that matters most.
		boxFlush(true);
	}

	function startHeartbeat() {
		if (heartbeatTimer !== null) return;
		if (typeof setInterval !== "function") return;
		installFrameCounter();
		heartbeatTimer = setInterval(heartbeat, HEARTBEAT_INTERVAL_MS);
	}

	window.addEventListener("error", (event) => {
		const where = event.filename
			? " (" + event.filename + ":" + event.lineno + ")"
			: "";
		show(event.message + where);
	});

	window.addEventListener("unhandledrejection", (event) => {
		const reason = event.reason;
		const detail = reason && reason.message ? reason.message : reason;
		show("unhandled rejection: " + detail);
	});

	// pagehide is the last event iOS Safari reliably delivers before a tab is
	// backgrounded or closed; it does not fire unload at all. Reaching here
	// means this session ended on its own terms.
	window.addEventListener("pagehide", boxClose);

	// A page restored from the back/forward cache is the same session waking
	// up, not a new one: no script re-runs, so nothing else would re-arm the
	// box. pagehide has already closed it, and without this the recorder stays
	// dead for the rest of the document's life - a later kill would leave no
	// evidence at all, which is the one case the black box exists for.
	window.addEventListener("pageshow", (event) => {
		if (!event || !event.persisted) return;
		if (!storage()) return;
		box.closed = false;
		boxRecord("restored from bfcache");
		boxFlush(true);
	});

	box.started = new Date().toISOString();
	boxForget(BOX_LEGACY_KEY);
	postMortem = boxRecover();
	boxRecord("session start " + navigator.userAgent);
	boxFlush(true);
	startHeartbeat();
	if (postMortem) {
		// Render into #crash only; see render() for why #msg is off limits
		// here. The demo keeps running behind the panel.
		const start = () => {
			attachDismiss();
			render();
		};
		if (document.readyState === "loading") {
			window.addEventListener("DOMContentLoaded", start);
		} else {
			start();
		}
	}

	window.ingotCrash = {
		report: show,
		crashed: () => headline !== null,
		// True when the PREVIOUS session in this tab ended without shutting
		// down cleanly. Informational only: a page must NOT use this to keep
		// a loading overlay up, because the current session may be running
		// perfectly and the overlay would hide it.
		recovered: () => postMortem !== null,
		// Breadcrumb from application code, for phases the console does not
		// cover ("entered stress section"), so a kill can be attributed.
		mark: (label) => {
			boxRecord("MARK " + label);
			boxFlush(true);
		},
		// Register a named value sampled by every heartbeat. The wasm heap
		// size (ingot_web.js) is the one that matters: a tab killed under
		// memory pressure leaves a visible growth curve behind, which is
		// otherwise unobservable from inside the page.
		watch: (name, read) => {
			if (typeof read !== "function") return false;
			if (probes.length >= HEARTBEAT_PROBES_MAX) return false;
			probes.push({name, read});
			return true;
		},
	};
	// Back-compat with pages that check the older hook name.
	window.__ingotCrashed = () => headline !== null;

	// Test-only hook, mirroring ingot_web.js's. Guarded so browsers never see
	// it and no behavior changes.
	if (typeof globalThis.__ingot_crash_test_hook === "function") {
		globalThis.__ingot_crash_test_hook({
			boxRecord,
			boxFlush,
			boxClose,
			boxRecover,
			render,
			heartbeat,
			state: () => ({box, postMortem, headline, probes, frames}),
			limits: {
				BOX_KEY,
				BOX_LEGACY_KEY,
				BOX_CRUMBS_MAX,
				BOX_CRUMB_CHARS_MAX,
				HEARTBEAT_PROBES_MAX,
			},
		});
	}
})();
