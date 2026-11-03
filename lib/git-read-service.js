import { createHash, randomUUID } from "node:crypto";
import { basename, isAbsolute, relative, resolve, sep } from "node:path";
import { lstat, realpath } from "node:fs/promises";
import { createBundledGitReadProvider } from "./git-read-bundled-provider.js";

const MAX_GRAPH_TIPS = 5;
const MAX_TRACKED_FILES = 200;
const FILE_HISTORY_DEFAULT_LIMIT = 20;
const FILE_HISTORY_MAX_LIMIT = 100;
const FILE_HISTORY_MAX_COMMITS = 5000;
const FILE_HISTORY_TIMEOUT_MS = 20_000;
const MAX_FILE_HISTORY_SNAPSHOTS = 8;
const REF_KIND_ORDER = { head: 0, localBranch: 1, remoteBranch: 2, other: 3 };
const FILE_HISTORY_REASONS = new Set(["not-tracked", "no-history", "path-invalid"]);

function failure(code, status, message = code) {
	const error = new Error(message);
	error.code = code;
	error.status = status;
	return error;
}

// The provider contract is additive: v1.1.0 providers expose the new methods,
// while legacy v1.0.0 providers stay compatible and their raw ref strings are
// projected into the structured DTO by this facade.
const providerCompatible = (provider) => /^1\.\d+\.\d+$/.test(String(provider?.contractVersion ?? ""))
	&& ["repositoryRoot", "branches", "resolveTip", "graph", "commit"].every((method) => typeof provider[method] === "function");

const compareText = (left, right) => left < right ? -1 : left > right ? 1 : 0;
const refShortName = (name) => name === "HEAD" ? "HEAD" : String(name).replace(/^refs\/(?:heads|remotes|tags)\//, "");
const trimSubject = (value) => [...String(value)].slice(0, 200).join("");
const emptyRefDetails = () => ({ refsDetail: [], tagsDetail: [] });
const sortRefDetails = (rows) => rows.sort((left, right) => (REF_KIND_ORDER[left.kind] ?? 9) - (REF_KIND_ORDER[right.kind] ?? 9) || compareText(left.name, right.name));
const sortTagDetails = (rows) => rows.sort((left, right) => compareText(left.name, right.name));

/** Project provider-owned ref records onto the commit they resolve to. */
function refDetailsFromRecords(records, commitOid, { fullTags = false } = {}) {
	const target = String(commitOid ?? "").toLowerCase();
	const refs = [], tags = [], seen = new Set();
	for (const record of Array.isArray(records) ? records : []) {
		if (!record || String(record.commitOid ?? "").toLowerCase() !== target) continue;
		const name = typeof record.name === "string" ? record.name : "";
		if (!name) continue;
		const shortName = typeof record.shortName === "string" && record.shortName ? record.shortName : refShortName(name);
		if (record.kind === "tag") {
			const key = `tag\0${shortName}`;
			if (seen.has(key)) continue;
			seen.add(key);
			const tag = { name, shortName, oid: target, annotated: record.annotated === true };
			if (fullTags) {
				if (typeof record.tagger === "string" && record.tagger) tag.tagger = record.tagger;
				const date = Number(record.date);
				if (Number.isFinite(date) && date > 0) tag.date = date;
				if (typeof record.subject === "string" && record.subject) tag.subject = trimSubject(record.subject);
				if (typeof record.hint === "string" && record.hint) tag.hint = record.hint;
			}
			tags.push(tag);
			continue;
		}
		const kind = ["head", "localBranch", "remoteBranch"].includes(record.kind) ? record.kind : "other";
		const key = `${kind}\0${shortName}`;
		if (seen.has(key)) continue;
		seen.add(key);
		const detail = { kind, name, shortName, oid: target };
		if (record.current === true) detail.current = true;
		refs.push(detail);
	}
	return { refsDetail: sortRefDetails(refs), tagsDetail: sortTagDetails(tags) };
}

/**
 * String fallback for legacy providers: parse raw decorations such as
 * `HEAD -> refs/heads/main`, `refs/remotes/origin/main` and
 * `tag: refs/tags/v1.0.0`. Annotated metadata is unavailable here, so tags
 * are advertised as lightweight name-level entries.
 */
function refDetailsFromLegacyRefs(rawRefs, commitOid, { tags = [] } = {}) {
	const target = String(commitOid ?? "");
	const refs = [], tagRows = [], seen = new Set();
	let currentBranch = null;
	const addRef = (kind, name, shortName, extra = {}) => {
		const key = `${kind}\0${shortName}`;
		if (seen.has(key)) return;
		seen.add(key);
		refs.push({ kind, name, shortName, oid: target, ...extra });
	};
	const addTag = (value) => {
		let name = String(value ?? "").trim();
		if (name.startsWith("tag: ")) name = name.slice(5).trim();
		if (!name) return;
		if (!name.startsWith("refs/tags/")) name = `refs/tags/${name}`;
		const shortName = name.slice(10);
		if (!shortName) return;
		const key = `tag\0${shortName}`;
		if (seen.has(key)) return;
		seen.add(key);
		tagRows.push({ name, shortName, oid: target, annotated: false });
	};
	const addRefValue = (value) => {
		const raw = String(value ?? "").trim();
		if (!raw) return;
		if (raw === "HEAD") return addRef("head", "HEAD", "HEAD", { current: true });
		if (raw.startsWith("HEAD -> ")) {
			addRef("head", "HEAD", "HEAD", { current: true });
			const next = raw.slice(8).trim();
			if (!next) return undefined;
			// Providers may decorate with shortened branch names (`HEAD -> main`)
			// instead of full ref names; normalize the branch form here. The target
			// of HEAD is by definition the current branch, marked after parsing.
			if (next.startsWith("refs/heads/")) { currentBranch = next.slice(11); return addRef("localBranch", next, currentBranch); }
			if (next.startsWith("refs/")) return addRefValue(next);
			currentBranch = next;
			return addRef("localBranch", `refs/heads/${next}`, next);
		}
		if (raw.startsWith("tag: ")) return addTag(raw.slice(5));
		if (raw === "refs/stash") return;
		if (raw.startsWith("refs/heads/")) return addRef("localBranch", raw, raw.slice(11));
		if (raw.startsWith("refs/remotes/")) return raw.endsWith("/HEAD") ? undefined : addRef("remoteBranch", raw, raw.slice(13));
		if (raw.startsWith("refs/tags/")) return addTag(raw);
		return addRef("other", raw, raw);
	};
	for (const raw of Array.isArray(rawRefs) ? rawRefs : []) addRefValue(raw);
	for (const raw of Array.isArray(tags) ? tags : []) addTag(raw);
	// `current` is set once HEAD has been seen, so decoration order does not matter.
	if (currentBranch !== null) {
		const row = refs.find((entry) => entry.kind === "localBranch" && entry.shortName === currentBranch);
		if (row) row.current = true;
	}
	return { refsDetail: sortRefDetails(refs), tagsDetail: sortTagDetails(tagRows) };
}

const mergeRefDetails = (primary, secondary) => {
	const refs = new Map(), tags = new Map();
	for (const row of [...primary.refsDetail, ...secondary.refsDetail]) {
		const key = `${row.kind}\0${row.shortName}`;
		if (!refs.has(key)) refs.set(key, row);
	}
	for (const row of [...primary.tagsDetail, ...secondary.tagsDetail]) {
		if (!tags.has(row.shortName)) tags.set(row.shortName, row);
	}
	return { refsDetail: sortRefDetails([...refs.values()]), tagsDetail: sortTagDetails([...tags.values()]) };
};

const HISTORY_STATUS_WORDS = { added: "A", modified: "M", deleted: "D", renamed: "R", copied: "C", "type-changed": "T" };
const historyStatus = (value) => {
	const text = String(value ?? "").trim();
	const word = HISTORY_STATUS_WORDS[text.toLowerCase()];
	if (word) return word;
	const upper = text.toUpperCase();
	return ["A", "M", "D", "R", "C", "T"].includes(upper[0]) ? upper[0] : "M";
};

/** Session-authorized read facade over an optional external or bundled provider. */
export function createGitReadService(ctx, { bundledProvider, now = () => Date.now(), snapshotTtlMs = 5 * 60_000, pollIntervalMs = 30_000, onChanged } = {}) {
	const get = (name) => { try { return ctx.get?.(name); } catch { return undefined; } };
	const external = get("gitReadProvider");
	let externalAvailable = false;
	try { externalAvailable = providerCompatible(external) && external.capabilities?.().available === true; } catch {}
	const bundled = bundledProvider ?? createBundledGitReadProvider(ctx);
	const provider = externalAvailable ? external : bundled;
	const bindings = new Map();
	const repositoryIdFor = (sessionId, root) => `repo_${createHash("sha256").update(`${sessionId}\0${root}`).digest("base64url").slice(0, 32)}`;
	const inside = (child, parent) => {
		const path = relative(resolve(parent), resolve(child));
		return path === "" || (path !== ".." && !path.startsWith(`..${sep}`) && !isAbsolute(path));
	};
	const authorizedRoot = async (cwd) => {
		if (typeof cwd !== "string" || !cwd) throw failure("repository-not-authorized", 403);
		try {
			const canonicalCwd = await realpath(cwd);
			const workspacePaths = get("workspaceRegistry")?.list?.()?.map((entry) => entry?.path) ?? [];
			const workspaces = await Promise.all(workspacePaths.filter((path) => typeof path === "string").map((path) => realpath(path).catch(() => null)));
			if (!workspaces.some((path) => path && inside(canonicalCwd, path))) throw failure("repository-not-authorized", 403);
			const root = await realpath(await provider.repositoryRoot(canonicalCwd));
			if (!inside(canonicalCwd, root) || !workspaces.some((path) => path && inside(root, path))) throw failure("repository-not-authorized", 403);
			return root;
		} catch (error) {
			if (["git-provider-unavailable", "not-git-repository"].includes(error?.code)) throw failure(error.code, error.status);
			throw failure("repository-not-authorized", 403);
		}
	};
	const session = (sessionId) => {
		if (typeof sessionId !== "string" || sessionId === "") throw failure("session-not-found", 404);
		const value = get("sessions")?.get?.(sessionId);
		if (!value) throw failure("session-not-found", 404);
		return value;
	};
	const binding = async (sessionId, repositoryId) => {
		const value = bindings.get(repositoryId);
		if (!value || value.sessionId !== sessionId) throw failure("repository-not-authorized", 403);
		const current = session(sessionId);
		const currentRoot = await authorizedRoot(current?.header?.cwd);
		if (currentRoot !== value.root) throw failure("repository-not-authorized", 403);
		return value;
	};
	const worktreeSnapshots = new Map();
	const snapshots = new Map();
	const fileCursors = new Map();
	const historySnapshots = new Map();
	const historyCursors = new Map();
	const refSignatures = new Map();
	const keepBounded = (map, maximum) => {
		while (map.size > maximum) map.delete(map.keys().next().value);
	};
	const prune = () => {
		for (const [id, item] of snapshots) if (item.expiresAt <= now()) snapshots.delete(id);
		for (const [id, item] of fileCursors) if (item.expiresAt <= now()) fileCursors.delete(id);
		for (const [id, item] of historySnapshots) if (item.expiresAt <= now()) historySnapshots.delete(id);
		for (const [id, item] of historyCursors) if (item.expiresAt <= now()) historyCursors.delete(id);
	};
	let pollTimer = null;
	let pollInFlight = null;
	let unsubscribeProvider = null;
	const validOid = (value) => typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(value);
	const safeFilePath = (value) => typeof value === "string" && value !== "" && !isAbsolute(value) && !/^(?:[A-Za-z]:[\\/]|\\\\|[a-z][a-z\d+.-]*:\/\/)/i.test(value) && !value.split(/[\\/]/).includes("..") && !value.includes("\0");
	const validRef = (value) => value === "HEAD" || (typeof value === "string" && /^refs\/(?:heads|remotes)\/[A-Za-z0-9._/-]+$/.test(value) && !value.includes("..") && !value.includes("//") && !value.includes("@{") && !/(^|\/)\.|\/$|\.lock(?:\/|$)|[/.]$/.test(value));
	const stale = () => failure("graph-stale", 409);
	const hasNewFileMethods = (candidate) => typeof candidate?.files === "function" && typeof candidate?.fileHistory === "function";
	const bundledProviderReady = () => {
		try { return bundled.capabilities?.().available === true; } catch { return false; }
	};
	// Truthful capability: only the ACTIVE provider may serve the new endpoints.
	// A legacy external provider must not be mixed with bundled data (its graph
	// and commit facts come from a different source); a bundled provider also
	// needs its Git subprocess to be usable.
	const fileHistoryFeature = () => {
		if (!hasNewFileMethods(provider)) return false;
		if (provider !== bundled) return true;
		return bundledProviderReady();
	};
	const fileReader = () => {
		if (!hasNewFileMethods(provider)) throw failure("provider-incompatible", 503);
		return provider;
	};
	const readRefRecords = async (root) => {
		if (typeof provider.refs !== "function") return null;
		try {
			const records = await provider.refs(root);
			return Array.isArray(records) ? records : null;
		} catch { return null; }
	};
	const capabilities = () => {
		const base = provider.capabilities?.() ?? { available: true, reason: null };
		return {
			contractVersion: "1.1.0", available: base.available !== false,
			reason: ["git-provider-unavailable", "workspace-registry-unavailable"].includes(base.reason) ? base.reason : null,
			readOnly: true, provider: provider === external ? "external" : "bundled",
			features: {
				repository: true, branches: true, graph: true, commit: true, worktree: true, preview: true,
				// Both flags are independent and additive: refsDetail can be
				// synthesized from legacy strings; fileHistory is true only when the
				// active provider implements the new methods (see fileHistoryFeature).
				refsDetail: true, fileHistory: fileHistoryFeature(),
			},
		};
	};
	/**
	 * Normalize a client-supplied path to a repository-relative POSIX path.
	 * Returns null for paths that escape the repository (reported as
	 * `path-invalid`), and throws 400 for directories.
	 */
	const normalizeHistoryPath = async (root, input) => {
		if (typeof input !== "string" || input === "" || input.includes("\0")) return null;
		// Windows-style absolute paths cannot be mapped on a POSIX host; report
		// them as invalid instead of treating them as a relative filename.
		if (/^(?:[A-Za-z]:[\\/]|\\\\)/.test(input) && !isAbsolute(input)) return null;
		const candidate = isAbsolute(input) ? resolve(input) : resolve(root, input);
		const rel = relative(root, candidate);
		if (rel === "") throw failure("path-invalid", 400);
		if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) return null;
		const normalized = sep === "/" ? rel : rel.split(sep).join("/");
		try {
			const info = await lstat(candidate);
			if (info.isDirectory()) throw failure("path-invalid", 400);
		} catch (error) {
			if (error?.code === "path-invalid") throw error;
		}
		return normalized;
	};
	const service = {
		capabilities,
		async capabilitiesForSession(sessionId) {
			const current = session(sessionId);
			const base = capabilities();
			if (!base.available) return base;
			try {
				await authorizedRoot(current?.header?.cwd);
				return base;
			} catch (error) {
				const reason = ["not-git-repository", "git-provider-unavailable"].includes(error?.code)
					? error.code : "repository-not-authorized";
				return { ...base, available: false, reason };
			}
		},
		async repositoryForSession(sessionId) {
			const current = session(sessionId);
			const root = await authorizedRoot(current?.header?.cwd);
			const repositoryId = repositoryIdFor(sessionId, root);
			bindings.set(repositoryId, { sessionId, root });
			keepBounded(bindings, 256);
			const rawInfo = typeof provider.repositoryInfo === "function" ? await provider.repositoryInfo(root) : {};
			if (typeof provider.refSignature === "function") refSignatures.set(repositoryId, await provider.refSignature(root));
			return {
				repositoryId, name: basename(root) || "repository",
				...(validOid(rawInfo.headOid) ? { headOid: rawInfo.headOid } : {}),
				...(typeof rawInfo.currentBranch === "string" && rawInfo.currentBranch.startsWith("refs/heads/") && validRef(rawInfo.currentBranch) ? { currentBranch: rawInfo.currentBranch } : {}),
				detached: rawInfo.detached === true, empty: rawInfo.empty === true,
			};
		},
		async worktree(sessionId, repositoryId) {
			const authorized = await binding(sessionId, repositoryId);
			let reader = typeof provider.worktree === "function" ? provider : bundled;
			let raw = await reader.worktree(authorized.root);
			if (typeof raw?.signature !== "string" || raw.signature === "" || !Array.isArray(raw.entries)) {
				reader = bundled;
				raw = await reader.worktree(authorized.root);
			}
			const entries = (raw.entries ?? []).filter((entry) => safeFilePath(entry.path)).slice(0, 2000);
			const snapshotId = createHash("sha256").update(`${repositoryId}\0${raw.signature}\0${JSON.stringify(entries)}`).digest("base64url");
			worktreeSnapshots.set(snapshotId, { sessionId, repositoryId, root: authorized.root, signature: raw.signature, entries, reader, expiresAt: now() + snapshotTtlMs });
			keepBounded(worktreeSnapshots, 128);
			return { repositoryId, snapshotId, staged: entries.filter((e) => e.index).map(({ path, oldPath, status, conflicted }) => ({ path, ...(oldPath ? { oldPath } : {}), status, conflicted })), unstaged: entries.filter((e) => e.worktree).map(({ path, oldPath, status, conflicted }) => ({ path, ...(oldPath ? { oldPath } : {}), status, conflicted })), untracked: entries.filter((e) => e.status === "untracked").map(({ path, status, conflicted }) => ({ path, status, conflicted })), truncated: (raw.entries ?? []).length > 2000 };
		},
		async preview(sessionId, repositoryId, { kind, snapshotId, path, oid } = {}) {
			const authorized = await binding(sessionId, repositoryId);
			if (!safeFilePath(path) || !["staged", "unstaged", "untracked", "commit"].includes(kind)) throw failure("preview-invalid", 400);
			const reader = bundled;
			let raw;
			if (kind === "commit") {
				if (!validOid(oid)) throw failure("invalid-oid", 400);
				const commit = typeof provider.commit === "function"
					? await provider.commit(authorized.root, oid)
					: await reader.commit(authorized.root, oid);
				const commitFile = (Array.isArray(commit?.files) ? commit.files : []).find((file) => file.path === path || file.oldPath === path);
				if (!commitFile) throw failure("preview-file-not-found", 404);
				raw = { ...await reader.commitPreview(authorized.root, oid, path), ...(commitFile.oldPath ? { oldPath: commitFile.oldPath } : {}) };
			} else {
				const snap = worktreeSnapshots.get(snapshotId);
				if (!snap || snap.sessionId !== sessionId || snap.repositoryId !== repositoryId || snap.root !== authorized.root || snap.expiresAt <= now()) throw stale();
				const current = await snap.reader.worktree(authorized.root);
				if (current.signature !== snap.signature) throw stale();
				const member = snap.entries.find((entry) => entry.path === path && (kind === "untracked" ? entry.status === "untracked" : kind === "staged" ? entry.index : entry.worktree));
				if (!member) throw failure("preview-file-not-found", 404);
				if (member.conflicted) raw = { diff: "", binary: false, notice: "merge conflict preview omitted" };
				else {
					const previewReader = typeof snap.reader.worktreePreview === "function" ? snap.reader : reader;
					const preview = await previewReader.worktreePreview(authorized.root, kind, path);
					const afterPreview = await snap.reader.worktree(authorized.root);
					if (afterPreview.signature !== snap.signature) throw stale();
					raw = { ...preview, ...(member.oldPath ? { oldPath: member.oldPath } : {}) };
				}
			}
			let diff = String(raw.diff ?? ""); const max = 512 * 1024; const truncated = raw.truncated === true || Buffer.byteLength(diff) > max;
			if (Buffer.byteLength(diff) > max) diff = Buffer.from(diff).subarray(0, max).toString("utf8");
			const binary = raw.binary === true || /Binary files? .* differ/.test(diff) || diff.includes("GIT binary patch");
			let notice = raw.notice;
			if (!notice && binary) { notice = "binary preview omitted"; diff = ""; }
			else if (!notice && /(?:new file mode|old mode|new mode) 120000/.test(diff)) { notice = "symlink text preview omitted"; diff = ""; }
			else if (!notice && /^\+(?:Subproject commit )|^-(?:Subproject commit )/m.test(diff)) { notice = "submodule preview omitted"; diff = ""; }
			else if (!notice && !/^@@/m.test(diff) && /^(?:old mode|new mode) /m.test(diff)) { notice = "file mode changed; no text changes"; diff = ""; }
			return { repositoryId, kind, path, ...(raw.oldPath ? { oldPath: raw.oldPath } : {}), diff, truncated, binary, additions: raw.additions ?? null, deletions: raw.deletions ?? null, ...(notice ? { notice } : {}) };
		},
		async branches(sessionId, repositoryId) {
			const authorized = await binding(sessionId, repositoryId);
			if (typeof provider.branches !== "function") throw failure("provider-incompatible", 503);
			const rows = await provider.branches(authorized.root);
			const branches = (Array.isArray(rows) ? rows : []).filter((row) => row && row.name !== "HEAD" && validRef(row.name) && validOid(row.oid)).map((row) => ({
				name: row.name, displayName: row.name.replace(/^refs\/(?:heads|remotes)\//, ""), oid: row.oid,
				kind: row.name.startsWith("refs/remotes/") ? "remote" : "local", current: row.current === true,
				tracking: typeof row.tracking === "string" && row.tracking.startsWith("refs/remotes/") && validRef(row.tracking) ? row.tracking : null,
				ahead: Math.max(0, Number(row.ahead) || 0), behind: Math.max(0, Number(row.behind) || 0),
			}));
			return { repositoryId, branches };
		},
		async commit(sessionId, repositoryId, oid, { filesCursor, filesLimit = 100 } = {}) {
			const authorized = await binding(sessionId, repositoryId);
			if (!validOid(oid)) throw failure("invalid-oid", 400);
			if (typeof provider.commit !== "function") throw failure("provider-incompatible", 503);
			const limit = Math.max(1, Math.min(200, Number(filesLimit) || 100));
			prune();
			let offset = 0;
			if (filesCursor) {
				const saved = fileCursors.get(filesCursor);
				if (!saved || saved.expiresAt <= now() || saved.sessionId !== sessionId || saved.repositoryId !== repositoryId || saved.oid !== String(oid).toLowerCase()) throw failure("invalid-files-cursor", 400);
				offset = saved.offset;
			}
			const value = await provider.commit(authorized.root, oid);
			const allFiles = (Array.isArray(value.files) ? value.files : []).filter((file) => safeFilePath(file?.path) && (file.oldPath == null || safeFilePath(file.oldPath))).map((file) => ({
				path: String(file.path ?? ""), ...(typeof file.oldPath === "string" ? { oldPath: file.oldPath } : {}),
				status: String(file.status ?? "modified"), binary: file.binary === true,
				additions: file.additions == null ? null : Math.max(0, Number(file.additions) || 0),
				deletions: file.deletions == null ? null : Math.max(0, Number(file.deletions) || 0),
			}));
			const items = allFiles.slice(offset, offset + limit);
			let nextCursor = null;
			if (offset + items.length < allFiles.length) {
				nextCursor = randomUUID();
				fileCursors.set(nextCursor, { sessionId, repositoryId, oid: value.oid.toLowerCase(), offset: offset + items.length, expiresAt: now() + snapshotTtlMs });
				keepBounded(fileCursors, 1024);
			}
			const stats = allFiles.reduce((sum, file) => ({ additions: sum.additions + (file.additions ?? 0), deletions: sum.deletions + (file.deletions ?? 0), files: sum.files + 1 }), { additions: 0, deletions: 0, files: 0 });
			const commitOid = String(value.oid ?? oid);
			const legacyRefs = Array.isArray(value.refs) ? value.refs.map(String) : [];
			const legacyTags = Array.isArray(value.tags) ? value.tags.map(String) : [];
			const records = await readRefRecords(authorized.root);
			const refDetails = mergeRefDetails(
				records ? refDetailsFromRecords(records, commitOid, { fullTags: true }) : emptyRefDetails(),
				refDetailsFromLegacyRefs(legacyRefs, commitOid, { tags: legacyTags }),
			);
			return {
				repositoryId, oid: commitOid, parents: Array.isArray(value.parents) ? value.parents.map(String) : [],
				author: String(value.author ?? ""), timestamp: Number(value.timestamp) || 0, message: String(value.message ?? ""),
				refs: legacyRefs, tags: legacyTags, refsDetail: refDetails.refsDetail, tagsDetail: refDetails.tagsDetail,
				stats, files: { items, total: allFiles.length, nextCursor },
			};
		},
		async graph(sessionId, repositoryId, { tips, snapshotId, cursor, limit = 100 } = {}) {
			const authorized = await binding(sessionId, repositoryId);
			prune();
			const pageSize = Math.max(1, Math.min(200, Number(limit) || 100));
			let snapshot, offset = 0;
			if (snapshotId !== undefined || cursor !== undefined) {
				if (!snapshotId || !cursor) throw stale();
				snapshot = snapshots.get(snapshotId);
				if (!snapshot || snapshot.sessionId !== sessionId || snapshot.repositoryId !== repositoryId || snapshot.root !== authorized.root || snapshot.expiresAt <= now()) throw stale();
				offset = snapshot.cursors.get(cursor);
				if (!Number.isInteger(offset)) throw stale();
			} else {
				const selected = tips === undefined ? [{ name: "HEAD", tipOid: null }] : tips;
				if (!Array.isArray(selected) || selected.length > MAX_GRAPH_TIPS) throw failure("graph-too-many-tips", 400);
				if (selected.length === 0) throw failure("graph-tip-invalid", 400);
				const names = selected.map((tip) => tip?.name);
				if (new Set(names).size !== names.length || names.some((name) => !validRef(name)) || selected.some((tip) => tip?.tipOid != null && !validOid(tip.tipOid))) throw failure("graph-tip-invalid", 400);
				const resolved = [];
				for (const tip of selected) {
					let oid;
					try { oid = await provider.resolveTip(authorized.root, tip.name); }
					catch (error) {
						if (tip.name === "HEAD" && error?.code === "git-command-failed") continue;
						throw failure("graph-tip-invalid", 409);
					}
					if (!validOid(oid)) throw failure("graph-tip-invalid", 409);
					if (tip.tipOid != null && tip.tipOid.toLowerCase() !== oid.toLowerCase()) throw failure("graph-tip-invalid", 409);
					resolved.push({ name: tip.name, tipOid: oid });
				}
				snapshot = { id: randomUUID(), sessionId, repositoryId, root: authorized.root, tips: resolved, expiresAt: now() + snapshotTtlMs, cursors: new Map() };
				snapshots.set(snapshot.id, snapshot);
				keepBounded(snapshots, 128);
			}
			for (const tip of snapshot.tips) {
				let current;
				try { current = await provider.resolveTip(authorized.root, tip.name); } catch { throw stale(); }
				if (current.toLowerCase() !== tip.tipOid.toLowerCase()) throw stale();
			}
			let rawCommits;
			try { rawCommits = await provider.graph(authorized.root, { refs: snapshot.tips.map((tip) => tip.tipOid), offset, limit: pageSize }); }
			catch (error) {
				for (const tip of snapshot.tips) {
					let current;
					try { current = await provider.resolveTip(authorized.root, tip.name); } catch { snapshots.delete(snapshot.id); throw stale(); }
					if (current.toLowerCase() !== tip.tipOid.toLowerCase()) { snapshots.delete(snapshot.id); throw stale(); }
				}
				throw error;
			}
			for (const tip of snapshot.tips) {
				let current;
				try { current = await provider.resolveTip(authorized.root, tip.name); } catch { snapshots.delete(snapshot.id); throw stale(); }
				if (current.toLowerCase() !== tip.tipOid.toLowerCase()) { snapshots.delete(snapshot.id); throw stale(); }
			}
			const records = await readRefRecords(authorized.root);
			const commits = (Array.isArray(rawCommits) ? rawCommits : []).map((row) => {
				const oid = String(row.oid ?? "");
				const legacy = Array.isArray(row.refs) ? row.refs.map(String) : [];
				// Graph rows only guarantee name-level refs plus `annotated`; full
				// tag metadata is reserved for commit details.
				const refDetails = mergeRefDetails(
					records ? refDetailsFromRecords(records, oid) : emptyRefDetails(),
					refDetailsFromLegacyRefs(legacy, oid),
				);
				return {
					oid, parents: Array.isArray(row.parents) ? row.parents.map(String) : [],
					author: String(row.author ?? ""), timestamp: Number(row.timestamp) || 0, subject: String(row.subject ?? ""),
					refs: legacy, refsDetail: refDetails.refsDetail, tagsDetail: refDetails.tagsDetail,
				};
			});
			let nextCursor = null;
			if (commits.length === pageSize) {
				nextCursor = randomUUID();
				snapshot.cursors.set(nextCursor, offset + commits.length);
				keepBounded(snapshot.cursors, 128);
			}
			return { repositoryId, snapshotId: snapshot.id, tips: snapshot.tips, commits, nextCursor };
		},
		async files(sessionId, repositoryId, { q, limit } = {}) {
			const authorized = await binding(sessionId, repositoryId);
			const pageSize = Math.max(1, Math.min(MAX_TRACKED_FILES, Number(limit) || MAX_TRACKED_FILES));
			const query = typeof q === "string" ? q : "";
			const raw = await fileReader().files(authorized.root, { q: query, limit: pageSize });
			const files = [...new Set((Array.isArray(raw?.files) ? raw.files : [])
				.map((path) => String(path ?? ""))
				.filter((path) => safeFilePath(path)))].sort(compareText).slice(0, pageSize);
			return { repositoryId, files, truncated: raw?.truncated === true };
		},
		async fileHistory(sessionId, repositoryId, { path, cursor, limit } = {}) {
			const authorized = await binding(sessionId, repositoryId);
			const pageSize = Math.max(1, Math.min(FILE_HISTORY_MAX_LIMIT, Number(limit) || FILE_HISTORY_DEFAULT_LIMIT));
			prune();
			const normalized = await normalizeHistoryPath(authorized.root, path);
			if (normalized === null) {
				return { repositoryId, path: String(path ?? ""), entries: [], nextCursor: null, truncated: false, reason: "path-invalid" };
			}
			let snapshot = null, offset = 0;
			if (cursor !== undefined && cursor !== null && cursor !== "") {
				const saved = historyCursors.get(String(cursor));
				if (!saved || saved.expiresAt <= now() || saved.sessionId !== sessionId || saved.repositoryId !== repositoryId || saved.path !== normalized) throw failure("invalid-history-cursor", 400);
				snapshot = historySnapshots.get(saved.snapshotId);
				if (!snapshot || snapshot.expiresAt <= now() || snapshot.root !== authorized.root) throw failure("invalid-history-cursor", 400);
				offset = saved.offset;
			}
			if (!snapshot) {
				const raw = await fileReader().fileHistory(authorized.root, normalized, {
					maxCommits: FILE_HISTORY_MAX_COMMITS,
					timeoutMs: FILE_HISTORY_TIMEOUT_MS,
				});
				const reason = FILE_HISTORY_REASONS.has(raw?.reason) ? raw.reason : null;
				const entries = (Array.isArray(raw?.entries) ? raw.entries : []).map((entry) => ({
					oid: String(entry?.oid ?? ""),
					shortOid: String(entry?.shortOid ?? String(entry?.oid ?? "").slice(0, 7)),
					author: String(entry?.author ?? ""),
					timestamp: Number(entry?.timestamp) || 0,
					subject: String(entry?.subject ?? ""),
					status: historyStatus(entry?.status),
				})).filter((entry) => validOid(entry.oid));
				if (reason && entries.length === 0) {
					return { repositoryId, path: normalized, entries: [], nextCursor: null, truncated: false, reason };
				}
				snapshot = {
					id: randomUUID(), sessionId, repositoryId, root: authorized.root, path: normalized,
					entries, truncated: raw?.truncated === true, expiresAt: now() + snapshotTtlMs,
				};
				historySnapshots.set(snapshot.id, snapshot);
				keepBounded(historySnapshots, MAX_FILE_HISTORY_SNAPSHOTS);
			}
			const items = snapshot.entries.slice(offset, offset + pageSize);
			let nextCursor = null;
			if (offset + items.length < snapshot.entries.length) {
				nextCursor = randomUUID();
				historyCursors.set(nextCursor, {
					sessionId, repositoryId, path: normalized, snapshotId: snapshot.id,
					offset: offset + items.length, expiresAt: now() + snapshotTtlMs,
				});
				keepBounded(historyCursors, 1024);
			}
			return { repositoryId, path: normalized, entries: items, nextCursor, truncated: snapshot.truncated };
		},
		_pollOnce() {
			if (pollInFlight) return pollInFlight;
			pollInFlight = (async () => {
			for (const [repositoryId, authorized] of bindings) {
				try {
					await binding(authorized.sessionId, repositoryId);
					if (typeof provider.refSignature === "function") {
						const signature = await provider.refSignature(authorized.root);
						const previous = refSignatures.get(repositoryId); refSignatures.set(repositoryId, signature);
						if (previous !== undefined && previous !== signature) onChanged?.(repositoryId, "refs");
					}
				} catch { bindings.delete(repositoryId); refSignatures.delete(repositoryId); }
			}
			})().finally(() => { pollInFlight = null; });
			return pollInFlight;
		},
		start() {
			if (unsubscribeProvider || pollTimer) return;
			if (typeof provider.subscribeChanges === "function") {
				try { unsubscribeProvider = provider.subscribeChanges((change) => {
					void (async () => {
						for (const [repositoryId, authorized] of bindings) {
							if (change?.root !== authorized.root) continue;
							try {
								await binding(authorized.sessionId, repositoryId);
								if (typeof provider.refSignature === "function") {
									const signature = await provider.refSignature(authorized.root);
									const previous = refSignatures.get(repositoryId);
									refSignatures.set(repositoryId, signature);
									if (previous === signature) continue;
								}
								onChanged?.(repositoryId);
							} catch { bindings.delete(repositoryId); refSignatures.delete(repositoryId); }
						}
					})();
				}); } catch { unsubscribeProvider = null; }
				if (typeof unsubscribeProvider !== "function") unsubscribeProvider = null;
			}
			// Ref polling is server-side; worktree polling stays scoped to an open mobile page.
			pollTimer = setInterval(() => { void service._pollOnce(); }, pollIntervalMs);
			pollTimer.unref?.();
		},
		stop() {
			if (pollTimer) clearInterval(pollTimer);
			pollTimer = null;
			try { unsubscribeProvider?.(); } catch { /* optional provider teardown must not break host shutdown */ }
			unsubscribeProvider = null;
			return pollInFlight ?? Promise.resolve();
		},
	};
	return service;
}
