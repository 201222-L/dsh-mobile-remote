import { randomBytes } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { constants as zstdConstants, zstdCompressSync } from "node:zlib";
import { join } from "node:path";

export const FIXTURE_CWD = "/fixture/workspace";
export const LARGE_FIXTURE_BYTES = 20 * 1024 * 1024;
const LARGE_FIXTURE_PAYLOAD_BYTES = 26 * 1024 * 1024;

const projectKey = (cwd) => `--${cwd.replace(/[\\/:]+/g, "-").replace(/^-+/, "")}--`;

/**
 * Write concatenated Zstandard frames containing physical JSONL rows matching
 * the released V3/V4 codecs. Each row is an independent frame, matching the
 * backend's header/append framing. This uses Node built-ins so the portable test
 * suite does not depend on whichever DSH host happens to be installed; the row
 * vocabulary is separately checked against the installed format catalog.
 */
export const writeSessionLogFixture = (root, {
	id,
	version,
	title = `Title ${id}`,
	largePayloadBytes = 0,
	createdAt = 1_700_000_000_000,
} = {}) => {
	if (version !== 3 && version !== 4) throw new RangeError("fixture version must be 3 or 4");
	const payload = largePayloadBytes > 0 ? randomBytes(largePayloadBytes).toString("base64") : `prompt for ${id}`;
	const header = {
		type: "session",
		version,
		id,
		createdAt,
		cwd: FIXTURE_CWD,
		isSeeded: false,
		delegationDepth: 0,
	};
	const event = (type, seq, data, surface = false) => ({
		type,
		seq,
		time: createdAt + seq,
		...(surface ? { surfaceOp: "append" } : {}),
		data,
	});
	const systemSource = version === 3
		? { kind: "plugin", plugin: "@deepseek-ai/dsh-system-prompt" }
		: { kind: "system-prompt" };
	const rows = [
		header,
		event("turn/start", 0, { turn: 1 }),
		event("step/start", 1, { turn: 1, step: 1 }),
		event("system/message", 2, {
			turn: 1,
			step: 1,
			message: {
				id: `system-${id}`,
				role: "system",
				source: systemSource,
				content: [{ type: "text", text: "fixture system prompt" }],
			},
		}, true),
		event("user/message", 3, {
			id: `user-${id}`,
			role: "user",
			source: { kind: "user" },
			content: [{ type: "text", text: payload }],
		}, true),
		event("assistant/message", 4, {
			turn: 1,
			step: 1,
			message: {
				id: `assistant-${id}`,
				role: "assistant",
				source: { kind: "model", provider: "deepseek", model: "fixture-model" },
				content: [{ type: "text", text: "fixture answer" }],
			},
			stream: [],
		}, true),
		event("step/end", 5, { turn: 1, step: 1 }),
		event("turn/end", 6, { turn: 1, reason: { kind: "completed" } }),
		event("session/title", 7, { title, messageSeqs: [], source: { kind: "user" } }),
	];
	const frames = rows.map((row) => zstdCompressSync(
		Buffer.from(`${JSON.stringify(row)}\n`, "utf8"),
		{ params: { [zstdConstants.ZSTD_c_checksumFlag]: 1 } },
	));
	const encoded = Buffer.concat(frames);
	const directory = join(root, projectKey(FIXTURE_CWD), id);
	mkdirSync(directory, { recursive: true });
	const file = join(directory, `session.v${version}.jsonl.zstd`);
	writeFileSync(file, encoded);
	return {
		root,
		id,
		version,
		title,
		file,
		header,
		frameLengths: frames.map((frame) => frame.byteLength),
		sizeBytes: encoded.byteLength,
	};
};

export const writeSessionCorpusFixtures = (root, { count = 8, largePayloadBytes = LARGE_FIXTURE_PAYLOAD_BYTES } = {}) => {
	if (!Number.isSafeInteger(count) || count < 2) throw new RangeError("count must be at least 2");
	const fixtures = [];
	for (let index = 0; index < count; index += 1) {
		fixtures.push(writeSessionLogFixture(root, {
			id: `fixture-${index}`,
			version: index % 2 === 0 ? 3 : 4,
			createdAt: 1_700_000_000_000 + index,
		}));
	}
	fixtures.push(writeSessionLogFixture(root, {
		id: "fixture-large-v4",
		version: 4,
		title: "Large fixture title",
		createdAt: 1_700_000_000_100,
		largePayloadBytes,
	}));
	return fixtures;
};
