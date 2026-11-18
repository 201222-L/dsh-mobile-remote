import { createHash, randomUUID } from "node:crypto";
import { basename, dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { lstat, realpath } from "node:fs/promises";
import { createBundledGitReadProvider } from "./git-read-bundled-provider.js";

// task-28（issue #86 方案 B）：GET 仍 ≤32；POST 支持 ≤128（URL 16KB 限制解除）。
const MAX_GRAPH_TIPS_GET = 32;
const MAX_GRAPH_TIPS_POST = 128;
const GRAPH_DEADLINE_MS = 25_000;
// issue #93（全部分支模式）：refs/扫描/页大小。阈值必须高于正常仓库（211 分支）。
const GRAPH_ALL_PAGE_SIZE = 16;
const MAX_GRAPH_ALL_REFS = 4096;
const MAX_GRAPH_ALL_SCAN = 5000;
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
export function createGitReadService(ctx, { bundledProvider, now = () => Date.now(), snapshotTtlMs = 5 * 60_000, pollIntervalMs = 30_000, onChanged, graphDeadlineMs = GRAPH_DEADLINE_MS, onSnapshotDisposed } = {}) {
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
	const graphTimeout = () => failure("graph-timeout", 504);
	/** 单次 provider 调用的 25s 硬截止（provider 自身超时/挂起兜底）。 */
	const graphRace = async (factory, deadline) => {
		const remaining = Math.max(1, deadline - Date.now());
		const call = Promise.resolve().then(factory);
		let timer = null;
		const timeout = new Promise((_, reject) => {
			timer = setTimeout(() => reject(graphTimeout()), remaining);
		});
		try {
			return await Promise.race([call, timeout]);
		} finally {
			if (timer) clearTimeout(timer);
			// 超时后底层 promise 仍可能 settle：吞掉，避免 unhandledRejection。
			void call.catch(() => {});
		}
	};
	/** provider.refs 一次映射（name → commit oid）；无 refs 能力/调用失败返回 null → 逐 tip 回退。 */
	const graphRefsByName = async (root, deadline) => {
		if (typeof provider.refs !== "function") return null;
		try {
			const records = await graphRace(
				() => provider.refs(root, { timeoutMs: Math.max(1, deadline - Date.now()) }),
				deadline,
			);
			if (!Array.isArray(records)) return null;
			const byName = new Map();
			for (const record of records) {
				if (!record || typeof record.name !== "string") continue;
				byName.set(record.name, validOid(record.commitOid) ? String(record.commitOid) : null);
			}
			return byName;
		} catch (error) {
			if (error?.code === "graph-timeout") throw error;
			return null; // 外部 provider 无 refs/调用失败 → 逐 tip（兼容旧契约）
		}
	};
	/** 批量解析新快照 tips：一次 refs 映射优先，缺项才逐 tip resolveTip。 */
	const resolveGraphTips = async (root, selected, deadline) => {
		const byName = await graphRefsByName(root, deadline);
		const resolved = [];
		for (const tip of selected) {
			let oid;
			if (byName && byName.has(tip.name)) {
				oid = byName.get(tip.name);
				if (!validOid(oid)) throw failure("graph-tip-invalid", 409);
			} else {
				try {
					oid = await graphRace(() => provider.resolveTip(root, tip.name), deadline);
				} catch (error) {
					if (error?.code === "graph-timeout") throw error;
					if (tip.name === "HEAD" && error?.code === "git-command-failed") continue;
					throw failure("graph-tip-invalid", 409);
				}
				if (!validOid(oid)) throw failure("graph-tip-invalid", 409);
			}
			if (tip.tipOid != null && tip.tipOid.toLowerCase() !== oid.toLowerCase()) throw failure("graph-tip-invalid", 409);
			resolved.push({ name: tip.name, tipOid: oid });
			if (Date.now() > deadline) throw graphTimeout();
		}
		return resolved;
	};
	/** 续页/前后校验：一次 refs 映射比对 tips 未移动；失败抛 graph-stale。 */
	const verifyGraphTips = async (root, tips, deadline) => {
		const byName = await graphRefsByName(root, deadline);
		for (const tip of tips) {
			let current;
			if (byName && byName.has(tip.name)) current = byName.get(tip.name);
			else {
				try {
					current = await graphRace(() => provider.resolveTip(root, tip.name), deadline);
				} catch (error) {
					if (error?.code === "graph-timeout") throw error;
					throw stale();
				}
			}
			if (!validOid(current) || current.toLowerCase() !== tip.tipOid.toLowerCase()) throw stale();
			if (Date.now() > deadline) throw graphTimeout();
		}
	};
	/**
	 * issue #93：解析**全部分支**（refs/heads/* + refs/remotes/*，排除 /HEAD）。
	 * tags 不参与 tips；返回按 name 排序的 `{name, tipOid}`，供 provider.graph 使用。
	 * 超内部保护上限抛明确 graph-too-many-refs（绝不静默截断）。
	 */
	const resolveAllGraphRefs = async (root, deadline) => {
		const byName = await graphRefsByName(root, deadline);
		if (byName === null) throw failure("git-provider-unavailable", 503);
		const refs = [];
		for (const [name, oid] of byName) {
			if (!name.startsWith("refs/heads/") && !name.startsWith("refs/remotes/")) continue;
			if (name.endsWith("/HEAD")) continue;
			if (!validOid(oid)) continue; // 非 commit 目标的 branch 不进图（与 provider 语义一致）
			refs.push({ name, tipOid: String(oid) });
			if (Date.now() > deadline) throw graphTimeout();
		}
		refs.sort((a, b) => compareText(a.name, b.name));
		if (refs.length > MAX_GRAPH_ALL_REFS) {
			throw failure("graph-too-many-refs", 400, `all branch refs exceed ${MAX_GRAPH_ALL_REFS}`);
		}
		return refs;
	};
	/** 全部分支快照指纹：name+oid 排序后 sha256；任一分支新增/移动/删除都会变。 */
	const allRefsFingerprint = (refs) => createHash("sha256")
		.update(refs.map((ref) => `${ref.name}:${ref.tipOid}`).join("\n"))
		.digest("hex");
	const verifyAllGraphRefs = async (snapshot, root, deadline) => {
		const current = await resolveAllGraphRefs(root, deadline);
		if (allRefsFingerprint(current) !== snapshot.refFingerprint) throw stale();
	};
	/** graph 专用：readRefRecords 纳入同一 absolute deadline（挂起→504，不返回半页）。 */
	const readRefRecordsWithin = async (root, deadline) => {
		if (typeof provider.refs !== "function") return null;
		try {
			const records = await graphRace(
				() => provider.refs(root, { timeoutMs: Math.max(1, deadline - Date.now()) }),
				deadline,
			);
			return Array.isArray(records) ? records : null;
		} catch (error) {
			if (error?.code === "graph-timeout") throw error;
			return null;
		}
	};
	const capabilities = () => {
		const base = provider.capabilities?.() ?? { available: true, reason: null };
		return {
			contractVersion: "1.1.0", available: base.available !== false,
			reason: ["git-provider-unavailable", "workspace-registry-unavailable"].includes(base.reason) ? base.reason : null,
			readOnly: true, provider: provider === external ? "external" : "bundled",
			// task-28：POST graph 的 tips 上限（旧宿主缺该字段，App 回退 5/5）。
			graphTips: { max: MAX_GRAPH_TIPS_POST, getMax: MAX_GRAPH_TIPS_GET },
			// issue #93：全部分支模式（all=true）与内部保护阈值；旧宿主缺该字段 → App 回退选择档。
			graphAll: { pageSize: GRAPH_ALL_PAGE_SIZE, maxRefs: MAX_GRAPH_ALL_REFS, maxScan: MAX_GRAPH_ALL_SCAN },
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
		let candidate = isAbsolute(input) ? resolve(input) : resolve(root, input);
		// Windows clients can send an 8.3 alias while the authorized repository
		// uses its canonical long name. Canonicalize the nearest existing parent,
		// preserving the final filename (a tracked symlink is itself a file).
		let parent = dirname(candidate);
		const tail = [basename(candidate)];
		for (;;) {
			try { candidate = resolve(await realpath(parent), ...tail); break; }
			catch {
				const next = dirname(parent);
				if (next === parent) break;
				tail.unshift(basename(parent)); parent = next;
			}
		}
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
		/**
		 * 图分页。task-28：`maxTips` 由 HTTP 层按传输方式传入（GET=32 / POST=128），
		 * 续页可省略 tips；snapshotId/cursor 与传输方式无关（GET/POST 互通）。
		 */
		async graph(sessionId, repositoryId, { tips, snapshotId, cursor, limit = 100, maxTips = MAX_GRAPH_TIPS_GET, all = false, focus } = {}) {
			const authorized = await binding(sessionId, repositoryId);
			prune();
			const deadline = Date.now() + graphDeadlineMs;
			const tipCap = maxTips === MAX_GRAPH_TIPS_POST ? MAX_GRAPH_TIPS_POST : MAX_GRAPH_TIPS_GET;
			const allMode = all === true;
			// issue #93：全部分支模式固定每页 16；5/10 选择集保持原 limit 语义。
			const pageSize = allMode
				? GRAPH_ALL_PAGE_SIZE
				: Math.max(1, Math.min(200, Number(limit) || 100));
			let snapshot, offset = 0;
			let snapshotCreatedNow = false;
			if (snapshotId !== undefined || cursor !== undefined) {
				if (!snapshotId || !cursor) throw stale();
				snapshot = snapshots.get(snapshotId);
				if (!snapshot || snapshot.sessionId !== sessionId || snapshot.repositoryId !== repositoryId || snapshot.root !== authorized.root || snapshot.expiresAt <= now()) throw stale();
				if (allMode !== (snapshot.all === true)) throw stale();
				offset = snapshot.cursors.get(cursor);
				if (!Number.isInteger(offset)) throw stale();
			} else if (allMode) {
				// 全部分支：忽略 tips 选择集，自行解析 refs/heads/* + refs/remotes/*。
				const refs = await resolveAllGraphRefs(authorized.root, deadline);
				if (refs.length === 0) throw failure("graph-tip-invalid", 400, "no branch refs");
				const refFingerprint = allRefsFingerprint(refs);
				let focusOid = null;
				let focusIndex = null;
				if (typeof focus === "string" && focus !== "") {
					if (!validRef(focus) && !validOid(focus)) throw failure("graph-focus-invalid", 400);
					if (validOid(focus)) {
						focusOid = String(focus).toLowerCase();
					} else {
						const hit = refs.find((ref) => ref.name === focus);
						if (!hit) throw failure("graph-focus-invalid", 400, "focus is not a branch ref");
						focusOid = String(hit.tipOid).toLowerCase();
					}
					// 与图相同的 topo/date 顺序定位 focus；扫描上限明确报错，不静默截断。
					const scan = await graphRace(
						() => provider.graph(authorized.root, {
							refs: refs.map((ref) => ref.tipOid),
							offset: 0,
							limit: MAX_GRAPH_ALL_SCAN,
							timeoutMs: Math.max(1, deadline - Date.now()),
						}),
						deadline,
					);
					if (scan && scan.timedOut === true) throw graphTimeout();
					const rows = Array.isArray(scan) ? scan : [];
					focusIndex = rows.findIndex((row) => String(row?.oid ?? "").toLowerCase() === focusOid);
					if (focusIndex < 0) throw failure("graph-focus-not-found", 409, "focus commit not found within scan limit");
				}
				const pageStart = focusIndex === null ? 0 : Math.floor(focusIndex / pageSize) * pageSize;
				snapshot = {
					id: randomUUID(), sessionId, repositoryId, root: authorized.root,
					all: true, branchRefs: refs, refFingerprint,
					tips: refs.map((ref) => ({ name: ref.name, tipOid: ref.tipOid })),
					focusOid, focusIndex, pageStart,
					expiresAt: now() + snapshotTtlMs, cursors: new Map(),
				};
				snapshotCreatedNow = true;
				snapshots.set(snapshot.id, snapshot);
				keepBounded(snapshots, 128);
				offset = pageStart;
			} else {
				const selected = tips === undefined ? [{ name: "HEAD", tipOid: null }] : tips;
				if (!Array.isArray(selected) || selected.length > tipCap) throw failure("graph-too-many-tips", 400, `tips limit is ${tipCap}`);
				if (selected.length === 0) throw failure("graph-tip-invalid", 400);
				const names = selected.map((tip) => tip?.name);
				if (new Set(names).size !== names.length || names.some((name) => !validRef(name)) || selected.some((tip) => tip?.tipOid != null && !validOid(tip.tipOid))) throw failure("graph-tip-invalid", 400);
				// P0 批量解析：128 tips 只做一次 provider.refs（外部 provider 无 refs 才逐 tip）。
				const resolved = await resolveGraphTips(authorized.root, selected, deadline);
				snapshot = { id: randomUUID(), sessionId, repositoryId, root: authorized.root, all: false, tips: resolved, expiresAt: now() + snapshotTtlMs, cursors: new Map(), pageStart: 0 };
				snapshotCreatedNow = true;
				snapshots.set(snapshot.id, snapshot);
				keepBounded(snapshots, 128);
			}
			// 统一 snapshot 清理策略（re-review P1）：
			// - 纯 graph-timeout：本次请求**新建且尚未交付**的 initial 快照可删；
			//   已交付/续页快照保留至 TTL，同 cursor 可重试；
			// - graph-stale / ref 变化 / 鉴权失败等确定性失效：立即删除。
			// 该策略覆盖 pre/post verify、provider.graph、装饰 readRefRecords 所有阶段。
			const disposeSnapshot = () => {
				if (snapshots.delete(snapshot.id)) onSnapshotDisposed?.(snapshot.id);
			};
			const disposeOnGraphFailure = (error) => {
				if (error?.code === "graph-timeout") {
					if (snapshotCreatedNow) disposeSnapshot();
					return;
				}
				disposeSnapshot();
			};
			try {
				// 全部分支：指纹覆盖全部分支 refs（新增/移动/删除都 stale）；5/10：只校验选择集。
				if (snapshot.all === true) await verifyAllGraphRefs(snapshot, authorized.root, deadline);
				else await verifyGraphTips(authorized.root, snapshot.tips, deadline);
			} catch (error) {
				disposeOnGraphFailure(error);
				throw error;
			}
			const graphRefs = snapshot.all === true
				? snapshot.branchRefs.map((ref) => ref.tipOid)
				: snapshot.tips.map((tip) => tip.tipOid);
			let rawCommits;
			try {
				rawCommits = await graphRace(
					() => provider.graph(authorized.root, {
						refs: graphRefs,
						offset,
						limit: pageSize,
						timeoutMs: Math.max(1, deadline - Date.now()),
					}),
					deadline,
				);
				// provider 自报 timedOut（不得把半页当完整页返回）。
				if (rawCommits && rawCommits.timedOut === true) throw graphTimeout();
			} catch (error) {
				// 超时是明确失败（504 graph-timeout），不做 stale 转换（否则面板看不到）。
				// 已交付续页快照保留；非确定性 provider 错误保留快照供重试（verify 失败才 stale）。
				if (error?.code === "graph-timeout") {
					disposeOnGraphFailure(error);
					throw error;
				}
				try {
					if (snapshot.all === true) await verifyAllGraphRefs(snapshot, authorized.root, deadline);
					else await verifyGraphTips(authorized.root, snapshot.tips, deadline);
				} catch (verifyError) {
					// 混合错误：provider.graph 先抛临时 503，随后为判 stale 的二次
					// verify 因 deadline 挂起 —— 必须原样透传 504，并按统一策略
					// （已交付保留 / 未交付新建清理），不能误判成 ref 真变化的 stale。
					if (verifyError?.code === "graph-timeout") {
						disposeOnGraphFailure(verifyError);
						throw verifyError;
					}
					disposeSnapshot();
					throw stale();
				}
				throw error;
			}
			try {
				if (snapshot.all === true) await verifyAllGraphRefs(snapshot, authorized.root, deadline);
				else await verifyGraphTips(authorized.root, snapshot.tips, deadline);
			} catch (error) {
				disposeOnGraphFailure(error);
				throw error;
			}
			let records;
			try {
				records = await readRefRecordsWithin(authorized.root, deadline);
			} catch (error) {
				// 装饰（refs 记录）阶段超时同样按统一策略处理：已交付快照可重试。
				disposeOnGraphFailure(error);
				throw error;
			}
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
			// issue #93：双向分页。nextCursor 更早（offset+本页），prevCursor 更新（offset-页）。
			let nextCursor = null;
			if (commits.length === pageSize) {
				nextCursor = randomUUID();
				snapshot.cursors.set(nextCursor, offset + commits.length);
			}
			let prevCursor = null;
			if (offset > 0) {
				prevCursor = randomUUID();
				snapshot.cursors.set(prevCursor, Math.max(0, offset - pageSize));
			}
			keepBounded(snapshot.cursors, 256);
			return {
				repositoryId, snapshotId: snapshot.id, tips: snapshot.tips, commits,
				nextCursor, prevCursor,
				all: snapshot.all === true,
				pageSize,
				pageStart: offset,
				focusOid: snapshot.all === true ? snapshot.focusOid : null,
				hasNewer: offset > 0,
				hasOlder: nextCursor !== null,
			};
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
