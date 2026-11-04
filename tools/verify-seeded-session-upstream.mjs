// Read-only reproduction for issue #20 against an isolated upstream npm install.
// node tools/verify-seeded-session-upstream.mjs /tmp/repro/node_modules/@deepseek-ai/dsh-session/lib/index.js
import assert from "node:assert/strict";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

if (!process.argv[2]) throw new Error("Pass an isolated dsh-session module path; no running Harness is needed.");
const { Session } = await import(pathToFileURL(resolve(process.argv[2])).href);
const id = "issue-20-synthetic";
const header = { id, version: 4, createdAt: 1, isSeeded: true };
const events = [0, 1].map((seq) => ({
	type: "plugin:issue-20/probe", seq, time: seq + 1, ignorable: true, data: {},
}));
const original = JSON.stringify({ header, events });
assert.throws(() => Session.create(id, structuredClone(events), structuredClone(header), 1), /seeded session constructor seed/);
Session.fromRestore(id, structuredClone(events), structuredClone(header), 1, "detached");
Session.create(id, [
	events[0],
	{ type: "session/end-seed", seq: 1, time: 2, data: { inherited: true } },
	{ ...events[1], seq: 2, time: 3 },
], structuredClone(header), 1);
assert.equal(JSON.stringify({ header, events }), original);
console.log("Unmarked legacy snapshot fails; restore succeeds; marked snapshot succeeds; source data unchanged.");
