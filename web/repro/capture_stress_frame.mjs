// Captures real Stress frames from the ingot gallery in headless desktop
// Chrome and writes them as stress-frame.json for the repro page's replay
// mode. The viewport and frame limits match the iPhone runs, so the replay
// on the phone draws what the gallery drew there.
//
//   node web/repro/capture_stress_frame.mjs [--url <gallery url>] [--out <file>] [--frames N]
//
// Defaults to the live gallery. The gallery only records when its
// ingot_web.js has installGpuCapture, so point --url at a local server over
// a restaged public_html to capture before deploying.

import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9334;
const PROFILE_DIR = "/tmp/ingot-capture-profile";
const CHUNK_CHARS = 4 * 1024 * 1024;
const CAPTURE_TIMEOUT_MS = 30000;
const NAV_TIMEOUT_MS = 20000;
const POLL_MS = 250;

function parseArgs(argv) {
	const args = {
		url: "https://openalloy.ai/demos/ingot-gallery/",
		out: path.join(path.dirname(fileURLToPath(import.meta.url)), "stress-frame.json"),
		frames: 3,
	};
	for (let i = 0; i < argv.length; i += 1) {
		const flag = argv[i];
		const value = argv[i + 1];
		if (flag === "--url" && value) args.url = value;
		else if (flag === "--out" && value) args.out = path.resolve(value);
		else if (flag === "--frames" && value) args.frames = Number(value);
		else throw new Error("unknown or incomplete argument: " + flag);
		i += 1;
	}
	if (!(args.frames >= 1 && args.frames <= 8)) throw new Error("--frames must be 1..8");
	return args;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
	const args = parseArgs(process.argv.slice(2));
	const pageUrl = new URL(args.url);
	pageUrl.searchParams.set("ingot_autoscroll", "1");
	pageUrl.searchParams.set("ingot_capture", String(args.frames));
	pageUrl.searchParams.set("ingot_fps", "30");
	pageUrl.searchParams.set("ingot_dpr", "1.5");

	fs.rmSync(PROFILE_DIR, { recursive: true, force: true });
	const chrome = spawn(CHROME, [
		"--headless=new", "--enable-unsafe-webgpu", "--enable-features=Vulkan",
		`--remote-debugging-port=${PORT}`, `--user-data-dir=${PROFILE_DIR}`, "--no-first-run", "about:blank",
	], { stdio: "ignore" });
	try {
		await run(args, pageUrl.toString());
	} finally {
		chrome.kill();
	}
}

async function run(args, pageUrl) {
	let target = null;
	for (let i = 0; i < 50 && !target; i += 1) {
		await sleep(200);
		try {
			const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
			target = list.find((t) => t.type === "page");
		} catch (_) {}
	}
	if (!target) throw new Error("Chrome did not expose a CDP page target");

	const ws = new WebSocket(target.webSocketDebuggerUrl);
	await new Promise((resolve, reject) => {
		ws.addEventListener("open", resolve);
		ws.addEventListener("error", reject);
	});
	let nextId = 1;
	const waiting = new Map();
	const consoleLines = [];
	ws.addEventListener("message", (event) => {
		const msg = JSON.parse(event.data);
		if (msg.id && waiting.has(msg.id)) {
			waiting.get(msg.id)(msg);
			waiting.delete(msg.id);
		}
		if (msg.method === "Runtime.consoleAPICalled") {
			consoleLines.push(msg.params.args.map((a) => a.value ?? a.description).join(" "));
		}
		if (msg.method === "Runtime.exceptionThrown") {
			const details = msg.params.exceptionDetails;
			consoleLines.push("EXC " + details.text + " " + (details.exception?.description || ""));
		}
	});
	const send = (method, params = {}) => new Promise((resolve) => {
		const id = nextId++;
		waiting.set(id, resolve);
		ws.send(JSON.stringify({ id, method, params }));
	});
	const evaluate = async (expression) => {
		const reply = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
		if (reply.error) throw new Error(reply.error.message);
		if (reply.result.exceptionDetails) {
			throw new Error("page threw: " + (reply.result.exceptionDetails.exception?.description ||
				reply.result.exceptionDetails.text));
		}
		return reply.result.result.value;
	};
	const fail = (message) => {
		const tail = consoleLines.slice(-15).map((line) => "  console: " + line).join("\n");
		throw new Error(message + (tail ? "\n" + tail : ""));
	};

	await send("Runtime.enable");
	await send("Page.enable");
	await send("Emulation.setDeviceMetricsOverride", {
		width: 390, height: 668, deviceScaleFactor: 3, mobile: true,
	});
	console.log("opening " + pageUrl);
	await send("Page.navigate", { url: pageUrl });

	const bootDeadline = Date.now() + NAV_TIMEOUT_MS;
	let state = null;
	while (Date.now() < bootDeadline) {
		await sleep(POLL_MS);
		state = await evaluate(`window.__ingotCapture ? window.__ingotCapture.state : null`);
		if (state) break;
	}
	if (!state) fail("window.__ingotCapture never appeared; is this ingot_web.js new enough?");

	const findStress = `(() => {
		const all = Array.from(document.querySelectorAll("button, [role=button], [role=tab], [role=link], a, [role=option], [role=treeitem]"));
		const label = (el) => (el.getAttribute("aria-label") || el.textContent || "").trim();
		const hit = all.find((el) => label(el) === "Stress");
		if (hit) {
			const box = hit.getBoundingClientRect();
			if (box.width > 0 && box.height > 0) {
				return { found: true, x: box.left + box.width / 2, y: box.top + box.height / 2 };
			}
		}
		return { found: false, labels: Array.from(new Set(all.map(label).filter(Boolean))).slice(0, 80) };
	})()`;
	const clickDeadline = Date.now() + NAV_TIMEOUT_MS;
	let click = null;
	while (Date.now() < clickDeadline) {
		click = await evaluate(findStress);
		if (click.found) break;
		await sleep(POLL_MS);
	}
	if (!click || !click.found) {
		fail("no semantic-mirror control labelled Stress; found: " + JSON.stringify(click && click.labels));
	}
	// The gallery redraws on demand and the mirror element only flags an
	// activation for the next frame, so press the real canvas button with
	// input events, which also wake the frame loop.
	const pointer = { x: click.x, y: click.y, button: "left", clickCount: 1 };
	await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: click.x, y: click.y });
	await sleep(100);
	await send("Input.dispatchMouseEvent", { type: "mousePressed", ...pointer });
	await sleep(80);
	await send("Input.dispatchMouseEvent", { type: "mouseReleased", ...pointer });
	console.log(`clicked Stress at ${Math.round(click.x)},${Math.round(click.y)}`);

	const captureDeadline = Date.now() + CAPTURE_TIMEOUT_MS;
	while (Date.now() < captureDeadline) {
		state = await evaluate(`window.__ingotCapture.state`);
		if (state === "done") break;
		await sleep(POLL_MS);
	}
	if (state !== "done") {
		const info = await evaluate(`({ submits: window.__ingotCapture.submits, section: window.__ingotCapture.section,
			stress: Array.from(document.querySelectorAll("[aria-label=Stress]")).map((el) => el.tagName + ":" + (el.getAttribute("role") || "") + ":" + el.style.left + "," + el.style.top + ":" + el.style.width + "x" + el.style.height) })`);
		fail(`capture did not finish (state=${state} submits=${info.submits} section=${JSON.stringify(info.section)} stress=${JSON.stringify(info.stress)})`);
	}

	const length = await evaluate(`window.__ingotCaptureText = window.__ingotCapture.json(), window.__ingotCaptureText.length`);
	let text = "";
	for (let offset = 0; offset < length; offset += CHUNK_CHARS) {
		text += await evaluate(`window.__ingotCaptureText.slice(${offset}, ${offset + CHUNK_CHARS})`);
	}
	if (text.length !== length) fail(`fetched ${text.length} of ${length} characters`);
	const capture = JSON.parse(text);
	if (!capture.surface || !capture.frames || capture.frames.length !== args.frames) {
		fail("capture JSON is missing surface or frames");
	}
	fs.writeFileSync(args.out, text);
	ws.close();

	const draws = capture.frames.map((frame) => frame.ops.filter((op) =>
		op.op === "pass" && (op.method === "draw" || op.method === "drawIndexed")).length);
	const uploads = capture.frames.map((frame) => Math.round(frame.ops.reduce((sum, op) =>
		sum + (op.b64 ? op.b64.length * 3 / 4 : 0), 0) / 1024));
	console.log(`wrote ${args.out} (${(text.length / 1024).toFixed(0)} KiB)`);
	console.log(`frames=${capture.frames.length} draws/frame=${draws.join(",")} uploadKiB/frame=${uploads.join(",")}`);
	console.log(`surface=${capture.surface.width}x${capture.surface.height} ${capture.surface.format} objects=${capture.objects.length}`);
	if (capture.warnings.length) console.log("warnings: " + capture.warnings.join("; "));
}

main().catch((error) => {
	console.error("capture failed: " + (error && error.stack ? error.stack : error));
	process.exit(1);
});
