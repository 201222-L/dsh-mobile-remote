import { createHash, randomUUID } from "node:crypto";
import { basename, isAbsolute, relative, resolve, sep } from "node:path";
import { realpath } from "node:fs/promises";
import { createBundledGitReadProvider } from "./git-read-bundled-provider.js";

const MAX_GRAPH_TIPS = 5;

function failure(code, status, message = code) {
	const error = new Error(message);
	error.code = code;
	error.status = status;
	return error;
}

const providerCompatible = (provider) => provider?.contractVersion === "1.0.0"
	&& ["repositoryRoot", "branches", "resolveTip", "graph", "commit"].every((method) => typeof provider[method] === "function");

/** Session-authorized read facade over an optional external or bundled provider. */
export function createGitReadService(ctx, { bundledProvider, now = () => Date.now(), snapshotTtlMs = 5 * 60_000, pollIntervalMs = 30_000, onChanged } = {}) {
	const get = (name) => { try { return ctx.get?.(name); } catch { return undefined; } };
	const external = get("gitReadProvider");
	let externalAvailable = false;
	try { externalAvailable = providerCompatible(external) && external.capabilities?.().available === true; } catch {}
	const provider = externalAvailable ? external : (bundledProvider ?? createBundledGitReadProvider(ctx));
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
	const refSignatures = new Map();
	const keepBounded = (map, maximum) => {
		while (map.size > maximum) map.delete(map.keys().next().value);
	};
	const prune = () => {
		for (const [id, item] of snapshots) if (item.expiresAt <= now()) snapshots.delete(id);
		for (const [id, item] of fileCursors) if (item.expiresAt <= now()) fileCursors.delete(id);
	};
	let pollTimer = null;
	let unsubscribeProvider = null;
	const validOid = (value) => typeof value === "string" && /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(value);
	const safeFilePath = (value) => typeof value === "string" && value !== "" && !isAbsolute(value) && !/^(?:[A-Za-z]:[\\/]|\\\\|[a-z][a-z\d+.-]*:\/\/)/i.test(value) && !value.split(/[\\/]/).includes("..") && !value.includes("\0");
	const validRef = (value) => value === "HEAD" || (typeof value === "string" && /^refs\/(?:heads|remotes)\/[A-Za-z0-9._/-]+$/.test(value) && !value.includes("..") && !value.includes("//") && !value.includes("@{") && !/(^|\/)\.|\/$|\.lock(?:\/|$)|[/.]$/.test(value));
	const stale = () => failure("graph-stale", 409);
	const capabilities = () => {
		const base = provider.capabilities?.() ?? { available: true, reason: null };
		return {
			contractVersion: "1.0.0", available: base.available !== false,
			reason: ["git-provider-unavailable", "workspace-registry-unavailable"].includes(base.reason) ? base.reason : null,
			readOnly: true, provider: provider === external ? "external" : "bundled",
			features: { repository: true, branches: true, graph: true, commit: true, worktree: true, preview: true },
		};
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
			let reader = typeof provider.worktree === "function" ? provider : createBundledGitReadProvider(ctx);
			let raw = await reader.worktree(authorized.root);
			if (typeof raw?.signature !== "string" || raw.signature === "" || !Array.isArray(raw.entries)) {
				reader = createBundledGitReadProvider(ctx);
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
			const reader = createBundledGitReadProvider(ctx);
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
			return { repositoryId, oid: String(value.oid ?? ""), parents: Array.isArray(value.parents) ? value.parents.map(String) : [], author: String(value.author ?? ""), timestamp: Number(value.timestamp) || 0, message: String(value.message ?? ""), refs: Array.isArray(value.refs) ? value.refs.map(String) : [], tags: Array.isArray(value.tags) ? value.tags.map(String) : [], stats, files: { items, total: allFiles.length, nextCursor } };
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
			const commits = (Array.isArray(rawCommits) ? rawCommits : []).map((row) => ({
				oid: String(row.oid ?? ""), parents: Array.isArray(row.parents) ? row.parents.map(String) : [],
				author: String(row.author ?? ""), timestamp: Number(row.timestamp) || 0, subject: String(row.subject ?? ""),
				refs: Array.isArray(row.refs) ? row.refs.map(String) : [],
			}));
			let nextCursor = null;
			if (commits.length === pageSize) {
				nextCursor = randomUUID();
				snapshot.cursors.set(nextCursor, offset + commits.length);
				keepBounded(snapshot.cursors, 128);
			}
			return { repositoryId, snapshotId: snapshot.id, tips: snapshot.tips, commits, nextCursor };
		},
		async _pollOnce() {
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
		},
	};
	return service;
}
