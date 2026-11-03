import { constants as fsConstants } from "node:fs";
import { realpath, open, lstat } from "node:fs/promises";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { createHash } from "node:crypto";

const UNTRACKED_PREVIEW_MAX = 512 * 1024;
const SIGNATURE_SAMPLE_BYTES = 4096;
const readOnlyNoFollow = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);
function sameRegularFile(expected, opened) {
	return expected.isFile() && opened.isFile() && expected.dev === opened.dev && expected.ino === opened.ino;
}
async function readPrefix(path, maximum, expected) {
	const handle = await open(path, readOnlyNoFollow);
	try {
		if (!sameRegularFile(expected, await handle.stat())) throw new Error("file changed while opening preview");
		const buffer = Buffer.alloc(maximum + 1);
		const { bytesRead } = await handle.read(buffer, 0, maximum + 1, 0);
		return { bytes: buffer.subarray(0, bytesRead), truncated: bytesRead > maximum };
	} finally { await handle.close(); }
}
async function sampledFileSignature(path, info) {
	const handle = await open(path, readOnlyNoFollow);
	try {
		if (!sameRegularFile(info, await handle.stat())) throw new Error("file changed while sampling worktree");
		const first = Buffer.alloc(Math.min(SIGNATURE_SAMPLE_BYTES, info.size));
		const firstRead = await handle.read(first, 0, first.length, 0);
		let last = Buffer.alloc(0);
		if (info.size > SIGNATURE_SAMPLE_BYTES) {
			last = Buffer.alloc(SIGNATURE_SAMPLE_BYTES);
			const read = await handle.read(last, 0, last.length, Math.max(0, info.size - last.length));
			last = last.subarray(0, read.bytesRead);
		}
		return createHash("sha256").update(`${info.dev}:${info.ino}:${info.size}:${info.mtimeMs}:${info.ctimeMs}:`).update(first.subarray(0, firstRead.bytesRead)).update(last).digest("hex");
	} finally { await handle.close(); }
}

function gitError(code, status, message = code) {
	const error = new Error(message);
	error.code = code;
	error.status = status;
	return error;
}

const refShortName = (name) => name === "HEAD" ? "HEAD" : String(name).replace(/^refs\/(?:heads|remotes|tags)\//, "");
const HISTORY_STATUS_LETTER = { A: "A", M: "M", D: "D", R: "R", C: "C", T: "T" };

/**
 * Parse `git log --format=%x00<meta> --name-status -M -z` output into file
 * history entries. Records are NUL-delimited: a `\x00` start marker, the
 * `\x1f`-separated metadata, then `\x00\n<status>` and its NUL-separated paths.
 * A deadline-aborted command may end mid-record; incomplete trailing records
 * are ignored while every fully parsed commit stays usable.
 */
function parseFileHistory(stdout) {
	const tokens = String(stdout ?? "").split("\0");
	const entries = [];
	let index = 0;
	while (index < tokens.length) {
		const metadata = tokens[index++];
		if (!metadata || metadata.startsWith("\n")) continue;
		const fields = metadata.split("\x1f");
		if (fields.length < 5) continue;
		const oid = fields[0];
		if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i.test(oid)) continue;
		let status = "M";
		if (index < tokens.length) {
			const marker = tokens[index];
			if (typeof marker === "string" && marker.startsWith("\n")) {
				index++;
				const code = marker.slice(1).trim();
				if (code) {
					status = HISTORY_STATUS_LETTER[code[0]] ?? "M";
					index += /^[RC]/.test(code) ? 2 : 1;
				}
			}
		}
		entries.push({
			oid,
			shortOid: fields[1] || oid.slice(0, 7),
			author: fields[2] ?? "",
			timestamp: Number(fields[3]) || 0,
			subject: fields.slice(4).join("\x1f"),
			status,
		});
	}
	return entries;
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
	const spawnGit = async (root, args, { disableFilters = false, allowNoMatches = false, timeoutMs = 0 } = {}) => {
		root = await assertWorkspace(root);
		const executor = subprocess();
		if (!executor?.spawn) throw gitError("git-provider-unavailable", 503);
		const noHooksPath = process.platform === "win32" ? "NUL" : "/dev/null";
		let filterOverrides = [];
		if (disableFilters) {
			const names = await run(root, ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process)$"], false, true);
			filterOverrides = names.split("\0").filter(Boolean).flatMap((name) => ["-c", `${name}=`]);
		}
		// A soft deadline aborts the command and returns the output collected so far,
		// so file history can degrade to a partial, explicitly truncated page instead
		// of failing the request. Hardening below is shared with the batch helper.
		const controller = timeoutMs > 0 ? new AbortController() : null;
		const timer = controller ? setTimeout(() => controller.abort(), timeoutMs) : null;
		try {
			const child = executor.spawn({
				argv: [
					process.platform === "win32" ? "git.exe" : "git",
					"-c", "core.fsmonitor=false",
					"-c", `core.hooksPath=${noHooksPath}`,
					...filterOverrides,
					"-C", root,
					"--no-optional-locks",
					...args,
				],
				cwd: root,
				// Prevent ambient Git repository/config overrides from redirecting a
				// session-authorized read. Undefined values are seam tombstones.
				env: {
					GIT_TERMINAL_PROMPT: "0",
					GCM_INTERACTIVE: "never",
					GIT_DIR: undefined,
					GIT_WORK_TREE: undefined,
					GIT_INDEX_FILE: undefined,
					GIT_COMMON_DIR: undefined,
					GIT_OBJECT_DIRECTORY: undefined,
					GIT_ALTERNATE_OBJECT_DIRECTORIES: undefined,
					GIT_CONFIG: undefined,
					GIT_CONFIG_PARAMETERS: undefined,
					GIT_CONFIG_COUNT: "0",
					// Trace destinations open files even for otherwise read-only Git commands.
					...Object.fromEntries(Object.keys(process.env).filter((key) => /^GIT_TRACE(?:2)?(?:_|$)/.test(key)).map((key) => [key, undefined])),
					GIT_TRACE: undefined,
					GIT_TRACE2: undefined,
					GIT_TRACE2_EVENT: undefined,
					GIT_TRACE2_PERF: undefined,
				},
				stdio: { stdin: "ignore", stdout: { maxBytes: 8 * 1024 * 1024 }, stderr: { maxBytes: 1024 * 1024 } },
				graceMs: 10_000,
				...(controller ? { signal: controller.signal } : {}),
			});
			let done;
			try { done = await child.done; } catch (error) {
				if (!controller?.signal.aborted) throw error;
				done = { exitCode: null };
			}
			const stdoutResult = await child.collected?.stdout?.readFrom?.(0);
			const stderrResult = await child.collected?.stderr?.readFrom?.(0);
			if (stdoutResult?.lossy || stderrResult?.lossy) {
				throw gitError("git-output-too-large", 413);
			}
			const stdout = stdoutResult?.text ?? "";
			const stderr = stderrResult?.text ?? "";
			if (controller?.signal.aborted) return { stdout, stderr, timedOut: true };
			if (done?.exitCode !== 0) {
				if (allowNoMatches && done?.exitCode === 1) return { stdout: "", stderr, timedOut: false };
				if (/not a git repository/i.test(stderr)) throw gitError("not-git-repository", 404);
				throw gitError("git-command-failed", 400);
			}
			return { stdout, stderr, timedOut: false };
		} finally {
			if (timer) clearTimeout(timer);
		}
	};
	const run = async (root, args, disableFilters = false, allowNoMatches = false) =>
		(await spawnGit(root, args, { disableFilters, allowNoMatches })).stdout;
	const repositoryRoot = async (cwd) => {
		const allowed = await assertWorkspace(cwd);
		const root = (await run(allowed, ["rev-parse", "--show-toplevel"])).trim();
		return assertWorkspace(root);
	};
	return {
		contractVersion: "1.1.0",
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
			const metadata = (await run(root, ["show", "-s", "--decorate=full", "--format=%H%x1f%P%x1f%an%x1f%at%x1f%D%x1f%B%x00", oid])).split("\0")[0].split("\x1f");
			const [hash, parentText, author, timestamp, decorations, ...messageParts] = metadata;
			const diffBase = parentText ? [parentText.split(" ")[0], hash] : ["--root", hash];
			const statusParts = (await run(root, ["diff-tree", "--no-commit-id", "-r", "-M", "--name-status", "-z", ...diffBase])).split("\0");
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
			const statParts = (await run(root, ["diff-tree", "--no-commit-id", "-r", "-M", "--numstat", "-z", ...diffBase])).split("\0");
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
			return {
				oid: hash, parents: parentText ? parentText.split(" ") : [], author, timestamp: Number(timestamp) || 0,
				message: messageParts.join("\x1f").trim(),
				refs: decorations ? decorations.split(",").map((value) => value.trim()).filter(Boolean) : [],
				files,
			};
		},
		/**
		 * All branch, remote, tag and HEAD refs with name-level facts plus
		 * annotated-tag metadata. Non-commit and nested tag targets carry a hint
		 * instead of failing the whole read.
		 */
		async refs(root) {
			const records = [];
			// NUL/US-delimited fields keep tagger names and tag subjects that contain
			// tabs intact; a tab-delimited line format would corrupt such records.
			const text = await run(root, ["for-each-ref", "--format=%(refname)%1f%(objectname)%1f%(objecttype)%1f%(HEAD)%1f%(taggername)%1f%(taggerdate:unix)%1f%(subject)%1f%(*objectname)%1f%(*objecttype)%1f%(type)%00", "refs/heads", "refs/remotes", "refs/tags"]);
			for (const raw of text.split("\0")) {
				const record = raw.replace(/^[\r\n]+|[\r\n]+$/g, "");
				if (!record) continue;
				const fields = record.split("\x1f");
				if (fields.length < 10) continue;
				// Peeled fields are fixed at the tail so a subject containing the
				// unit separator cannot swallow them.
				const [name, oid, objectType, headFlag, taggerName, taggerDate] = fields;
				const targetType = fields.at(-1); // %(type) is the direct tag target, including on Git 2.52+.
				const peeledType = fields.at(-2);
				const peeledOid = fields.at(-3);
				const subject = fields.slice(6, -3).join("\x1f");
				if (!name || !oid) continue;
				if (name.startsWith("refs/remotes/") && name.endsWith("/HEAD")) continue;
				if (name.startsWith("refs/heads/") || name.startsWith("refs/remotes/")) {
					const commit = objectType === "commit";
					records.push({
						name, shortName: refShortName(name),
						kind: name.startsWith("refs/heads/") ? "localBranch" : "remoteBranch",
						oid, commitOid: commit ? oid : null, current: headFlag === "*", annotated: false,
						...(commit ? {} : { hint: "non-commit-target" }),
					});
					continue;
				}
				if (!name.startsWith("refs/tags/")) continue;
				if (objectType !== "tag") {
					// Lightweight tag: the ref itself points at the target object.
					const commit = objectType === "commit";
					records.push({
						name, shortName: refShortName(name), kind: "tag",
						oid, commitOid: commit ? oid : null, current: false, annotated: false,
						...(commit ? {} : { hint: "non-commit-target" }),
					});
					continue;
				}
				let commitOid = null, hint;
				if (targetType === "tag" && peeledType === "commit") {
					commitOid = peeledOid;
					hint = "nested-tag";
				} else if (peeledType === "commit") commitOid = peeledOid;
				else if (peeledType === "tag") {
					// Nested tag: peel recursively; when the chain ends outside a
					// commit we still keep the name and advertise the hint.
					try { commitOid = (await run(root, ["rev-parse", "--verify", `${name}^{commit}`])).trim() || null; } catch { commitOid = null; }
					hint = commitOid ? "nested-tag" : "non-commit-target";
				} else hint = "non-commit-target";
				const date = Number(taggerDate);
				records.push({
					name, shortName: refShortName(name), kind: "tag", oid, commitOid, current: false, annotated: true,
					...(taggerName ? { tagger: taggerName } : {}),
					...(Number.isFinite(date) && date > 0 ? { date } : {}),
					...(subject ? { subject } : {}),
					...(hint ? { hint } : {}),
				});
			}
			let headOid = null;
			try { headOid = (await run(root, ["rev-parse", "--verify", "HEAD"])).trim() || null; } catch (error) { if (error?.code !== "git-command-failed") throw error; }
			if (headOid) records.unshift({ name: "HEAD", shortName: "HEAD", kind: "head", oid: headOid, commitOid: headOid, current: true, annotated: false });
			return records;
		},
		/** Tracked files at HEAD, bounded and filtered by a case-insensitive path substring. */
		async files(root, { q = "", limit = 200 } = {}) {
			const pageSize = Math.max(1, Math.min(200, Number(limit) || 200));
			// The recursive HEAD path list is bounded by the subprocess stdout cap
			// (8 MiB, see spawnGit). Repositories above that cap fail closed with
			// `git-output-too-large` (413) instead of returning a partial list; the
			// bound is documented in docs/03-api.md §6.19.7.
			let text;
			try { text = await run(root, ["ls-tree", "-r", "-z", "--name-only", "HEAD"]); } catch (error) {
				if (error?.code !== "git-command-failed") throw error;
				// An unborn HEAD is an empty repository, not a failure: /git/files
				// must answer 200 with an empty list for it.
				try { await run(root, ["rev-parse", "--verify", "HEAD"]); } catch (inner) {
					if (inner?.code === "git-command-failed") return { files: [], truncated: false };
					throw inner;
				}
				throw error;
			}
			const query = typeof q === "string" ? q.toLowerCase() : "";
			let paths = text.split("\0").filter((path) => path !== "");
			if (query) paths = paths.filter((path) => path.toLowerCase().includes(query));
			paths.sort((left, right) => left < right ? -1 : left > right ? 1 : 0);
			const truncated = paths.length > pageSize;
			return { files: paths.slice(0, pageSize), truncated };
		},
		/**
		 * Commits touching one file, newest first, with the change status that
		 * commit applied to the path. Bounded by `maxCommits` or the soft
		 * deadline; both report an explicitly truncated (partial) list.
		 */
		async fileHistory(root, path, { maxCommits = 5000, timeoutMs = 20000 } = {}) {
			if (typeof path !== "string" || path === "" || path.includes("\0")) throw gitError("git-command-failed", 400);
			const deadline = Date.now() + timeoutMs;
			const historyRun = (args) => spawnGit(root, args, { timeoutMs: Math.max(1, deadline - Date.now()) });
			try {
				const check = await historyRun(["rev-parse", "--verify", "HEAD"]);
				if (check.timedOut) return { entries: [], truncated: true };
			} catch (error) {
				if (error?.code === "git-command-failed") return { entries: [], truncated: false, reason: "no-history" };
				throw error;
			}
			let tracked = false;
			try {
				const tree = await historyRun(["ls-tree", "-z", "HEAD", "--", `:(literal)${path}`]);
				if (tree.timedOut) return { entries: [], truncated: true };
				for (const record of tree.stdout.split("\0")) {
					const separator = record.indexOf("\t");
					if (separator < 0) continue;
					const entryPath = record.slice(separator + 1);
					const entryType = record.slice(0, separator).split(" ")[1];
					// Directories, gitlinks and other tree entries are not file paths;
					// only blobs (regular files and symlinks) have a file history.
					if (entryPath === path && entryType === "blob") tracked = true;
				}
			} catch (error) {
				if (error?.code !== "git-command-failed") throw error;
			}
			if (!tracked) return { entries: [], truncated: false, reason: "not-tracked" };
			const cap = Math.max(1, Math.min(5000, Number(maxCommits) || 5000));
			const result = await historyRun(["--literal-pathspecs", "log", `--max-count=${cap + 1}`, "--format=%x00%H%x1f%h%x1f%an%x1f%at%x1f%s", "--name-status", "-M", "-z", "--", path]);
			let entries = parseFileHistory(result.stdout);
			let truncated = result.timedOut === true;
			if (entries.length > cap) {
				entries = entries.slice(0, cap);
				truncated = true;
			}
			return { entries, truncated };
		},
		async worktree(root) {
			const text = await run(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], true);
			const parts = text.split("\0"); const entries = [];
			for (let i = 0; i < parts.length;) {
				const record = parts[i++]; if (!record) continue;
				const code = record.slice(0, 2); let path = record.slice(3); let oldPath;
				if (/[RC]/.test(code)) { oldPath = parts[i++] ?? ""; }
				const status = code.includes("U") || code === "AA" || code === "DD" ? "conflicted" : code === "??" ? "untracked" : "modified";
				entries.push({ path, ...(oldPath ? { oldPath } : {}), status, conflicted: status === "conflicted", index: code[0] !== " " && code !== "??", worktree: code[1] !== " " && code !== "??" });
			}
			let signatureMaterial = text;
			for (const entry of entries) {
				if (entry.status !== "untracked" && !entry.worktree) continue;
				try { const target = resolve(root, entry.path); const info = await lstat(target); signatureMaterial += `\\0${entry.path}:${info.isSymbolicLink() ? "symlink" : info.isFile() ? await sampledFileSignature(target, info) : "special"}`; } catch { signatureMaterial += `\\0${entry.path}:missing`; }
			}
			try { signatureMaterial += await run(root, ["--literal-pathspecs", "diff", "--raw", "-z", "--no-abbrev", "HEAD"], true); } catch (error) { if (error?.code !== "git-command-failed") throw error; }
			try { signatureMaterial += await run(root, ["--literal-pathspecs", "diff", "--raw", "-z", "--no-abbrev", "--cached"], true); } catch (error) { if (error?.code !== "git-command-failed") throw error; }
			const signature = createHash("sha256").update(signatureMaterial).digest("hex");
			return { entries, signature };
		},
		async worktreePreview(root, kind, path) {
			const args = ["--literal-pathspecs", "diff", "--unified=999999", "--no-ext-diff", "--no-textconv", "--no-color", "--binary"];
			if (kind === "staged") args.push("--cached");
			args.push("--", path);
			if (kind === "untracked") {
				try {
					const target = resolve(root, path); const info = await lstat(target);
					if (info.isSymbolicLink()) return { diff: "", binary: false, additions: null, deletions: null, notice: "symlink preview omitted" };
					if (!info.isFile()) return { diff: "", binary: false, additions: null, deletions: null, notice: "special file preview omitted" };
					const { bytes, truncated } = await readPrefix(target, UNTRACKED_PREVIEW_MAX, info);
					const binary = bytes.includes(0);
					return { diff: binary ? "" : bytes.toString("utf8"), binary, truncated, additions: null, deletions: null, ...(binary ? { notice: "binary preview omitted" } : {}) };
				} catch { return { diff: "", binary: false, additions: 0, deletions: 0, notice: "unavailable" }; }
			}
			return { diff: await run(root, args, true), binary: false, additions: null, deletions: null };
		},
		async commitPreview(root, oid, path) {
			const commit = await this.commit(root, oid);
			if (!commit.parents.length) return { diff: await run(root, ["--literal-pathspecs", "diff-tree", "--root", "--no-commit-id", "-p", "-r", "--unified=999999", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", oid, "--", path]), binary: false };
			return { diff: await run(root, ["--literal-pathspecs", "diff", "--unified=999999", "--no-ext-diff", "--no-textconv", "--no-color", "--binary", `${oid}^1`, oid, "--", path]), binary: false };
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
