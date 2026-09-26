import { realpath } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { createHash } from "node:crypto";

function gitError(code, status, message = code) {
	const error = new Error(message);
	error.code = code;
	error.status = status;
	return error;
}

/** Bundled, read-only Git provider. Every command uses the host subprocess service. */
export function createBundledGitReadProvider(ctx) {
	const get = (name) => {
		try { return ctx.get?.(name); } catch { return undefined; }
	};
	const subprocess = () => get("subprocess") ?? ctx.subprocess;
	const workspaces = () => (get("workspaceRegistry")?.list?.() ?? [])
		.map((entry) => entry?.path).filter((path) => typeof path === "string" && path !== "");
	const inside = (child, parent) => {
		const value = relative(resolve(parent), resolve(child));
		return value === "" || (value !== ".." && !value.startsWith(`..${sep}`) && !isAbsolute(value));
	};
	const assertWorkspace = async (path) => {
		if (typeof path !== "string" || path === "") throw gitError("workspace-not-allowed", 403);
		let canonical;
		try { canonical = await realpath(path); } catch { throw gitError("workspace-not-allowed", 403); }
		const roots = await Promise.all(workspaces().map((root) => realpath(root).catch(() => null)));
		if (!roots.some((root) => root && inside(canonical, root))) throw gitError("workspace-not-allowed", 403);
		return canonical;
	};
	const run = async (root, args) => {
		root = await assertWorkspace(root);
		const executor = subprocess();
		if (!executor?.spawn) throw gitError("git-provider-unavailable", 503);
		const child = executor.spawn({
			argv: [process.platform === "win32" ? "git.exe" : "git", "-C", root, ...args],
			cwd: root,
			env: { GIT_TERMINAL_PROMPT: "0", GCM_INTERACTIVE: "never" },
			stdio: { stdin: "ignore", stdout: { maxBytes: 8 * 1024 * 1024 }, stderr: { maxBytes: 1024 * 1024 } },
			graceMs: 10_000,
		});
		const done = await child.done;
		const stdout = (await child.collected?.stdout?.readFrom?.(0))?.text ?? "";
		const stderr = (await child.collected?.stderr?.readFrom?.(0))?.text ?? "";
		if (done?.exitCode !== 0) {
			if (/not a git repository/i.test(stderr)) throw gitError("not-git-repository", 404);
			throw gitError("git-command-failed", 400);
		}
		return stdout;
	};
	const repositoryRoot = async (cwd) => {
		const allowed = await assertWorkspace(cwd);
		const root = (await run(allowed, ["rev-parse", "--show-toplevel"])).trim();
		return assertWorkspace(root);
	};
	return {
		contractVersion: "1.0.0",
		capabilities() {
			const available = Boolean(subprocess()?.spawn) && workspaces().length > 0;
			return { available, reason: available ? null : !subprocess()?.spawn ? "git-provider-unavailable" : "workspace-registry-unavailable" };
		},
		repositoryRoot,
		async refSignature(root) {
			let refs = "";
			try { refs = await run(root, ["show-ref", "--head", "--dereference"]); } catch (error) { if (error?.code !== "git-command-failed") throw error; }
			return createHash("sha256").update(refs).digest("hex");
		},
		async repositoryInfo(root) {
			let currentBranch = null, headOid = null;
			try { currentBranch = (await run(root, ["symbolic-ref", "--quiet", "HEAD"])).trim() || null; } catch (error) { if (error?.code !== "git-command-failed") throw error; }
			try { headOid = (await run(root, ["rev-parse", "--verify", "HEAD"])).trim() || null; } catch (error) { if (error?.code !== "git-command-failed") throw error; }
			return { ...(headOid ? { headOid } : {}), ...(currentBranch ? { currentBranch } : {}), detached: Boolean(headOid && !currentBranch), empty: !headOid };
		},
		async resolveTip(root, ref) {
			return (await run(root, ["rev-parse", "--verify", `${ref}^{commit}`])).trim();
		},
		async graph(root, { refs, offset, limit }) {
			if (refs.length === 0) return [];
			const text = await run(root, ["log", "--topo-order", "--date-order", `--skip=${offset}`, `--max-count=${limit}`, "--decorate=full", "--format=%H%x1f%P%x1f%an%x1f%at%x1f%s%x1f%D%x00", ...refs]);
			return text.split("\0").map((record) => record.replace(/^[\r\n]+|[\r\n]+$/g, "")).filter(Boolean).map((record) => {
				const [oid, parents, author, timestamp, subject, decorations] = record.split("\x1f");
				return { oid, parents: parents ? parents.split(" ") : [], author, timestamp: Number(timestamp) || 0, subject, refs: decorations ? decorations.split(",").map((value) => value.trim()).filter(Boolean) : [] };
			});
		},
		async commit(root, oid) {
			if (typeof oid !== "string" || !/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(oid)) throw gitError("invalid-oid", 400);
			const metadata = (await run(root, ["show", "-s", "--format=%H%x1f%P%x1f%an%x1f%at%x1f%B%x00", oid])).split("\0")[0].split("\x1f");
			const [hash, parentText, author, timestamp, ...messageParts] = metadata;
			const statusParts = (await run(root, ["diff-tree", "--root", "--no-commit-id", "-r", "-M", "--name-status", "-z", hash])).split("\0");
			const files = [];
			for (let index = 0; index < statusParts.length;) {
				const code = statusParts[index++];
				if (!code) continue;
				const renamed = code.startsWith("R") || code.startsWith("C");
				const oldPath = renamed ? statusParts[index++] : undefined;
				const path = statusParts[index++];
				if (!path) break;
				const statuses = { A: "added", M: "modified", D: "deleted", R: "renamed", C: "copied", T: "type-changed" };
				files.push({ path, ...(oldPath ? { oldPath } : {}), status: statuses[code[0]] ?? "modified" });
			}
			const statParts = (await run(root, ["diff-tree", "--root", "--no-commit-id", "-r", "-M", "--numstat", "-z", hash])).split("\0");
			const stats = new Map();
			for (let index = 0; index < statParts.length;) {
				const record = statParts[index++];
				if (!record) continue;
				const firstTab = record.indexOf("\t");
				const secondTab = record.indexOf("\t", firstTab + 1);
				if (firstTab < 0 || secondTab < 0) continue;
				const added = record.slice(0, firstTab);
				const deleted = record.slice(firstTab + 1, secondTab);
				let path = record.slice(secondTab + 1);
				if (!path) { index++; path = statParts[index++] ?? ""; }
				stats.set(path, { binary: added === "-" || deleted === "-", additions: added === "-" ? null : Number(added), deletions: deleted === "-" ? null : Number(deleted) });
			}
			for (const file of files) Object.assign(file, stats.get(file.path) ?? { binary: false, additions: 0, deletions: 0 });
			return { oid: hash, parents: parentText ? parentText.split(" ") : [], author, timestamp: Number(timestamp) || 0, message: messageParts.join("\x1f").trim(), files };
		},
		async branches(root) {
			const text = await run(root, ["for-each-ref", "--format=%(HEAD)%09%(refname)%09%(objectname)%09%(upstream:short)%00", "refs/heads", "refs/remotes"]);
			const rows = text.split("\0").map((record) => record.replace(/^[\r\n]+|[\r\n]+$/g, "")).filter(Boolean);
			const branches = [];
			for (const row of rows) {
				const [head, ref, oid, upstream = ""] = row.split("\t");
				if (ref.endsWith("/HEAD")) continue;
				const local = ref.startsWith("refs/heads/");
				let ahead = 0, behind = 0;
				if (local && upstream) {
					const counts = (await run(root, ["rev-list", "--left-right", "--count", `${ref}...${upstream}`])).trim().split(/\s+/).map(Number);
					[ahead, behind] = counts;
				}
				branches.push({
					name: ref, displayName: ref.replace(/^refs\/(?:heads|remotes)\//, ""), oid,
					kind: local ? "local" : "remote", current: local && head === "*",
					tracking: local && upstream ? `refs/remotes/${upstream}` : null, ahead, behind,
				});
			}
			return branches;
		},
	};
}
