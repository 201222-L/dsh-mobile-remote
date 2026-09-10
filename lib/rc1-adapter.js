/**
 * DSH 0.1.2-rc.1 Remote adapter.
 *
 * Keep the RC1 endpoint and named-argument contract in one dependency-free
 * module so the mobile HTTP API does not mirror Typert details everywhere.
 */
import { relative, isAbsolute, sep } from "node:path";

export const RC1_REMOTE_EVENT_RESULT = "$events/result";

export function pathWithinWorkspace(root, target) {
	const rel = relative(root, target);
	return rel === "" || (!isAbsolute(rel) && rel !== ".." && !rel.startsWith(`..${sep}`));
}

export function rc1RemoteSpec(method, payload = {}) {
	const value = payload && typeof payload === "object" ? payload : {};
	switch (method) {
		case "session.models":
			return { namespace: "session", method: "modelCatalog", args: {} };
		case "session.history":
		case "session.control":
			return { namespace: "session", method: "control", args: {} };
		case "session.list":
			return { namespace: "session", method: "list", args: { _request: {} } };
		case "session.page":
			return { namespace: "session", method: "page", args: { request: value } };
		case "session.selectModel":
			return { namespace: "session", method: "selectModel", args: { request: value } };
		case "session.prompt":
			return { namespace: "session", method: "prompt", args: { request: value } };
		case "session.attachment":
			return { namespace: "session", method: "attachment", args: { request: value } };
		case "session.updateQueue":
			return { namespace: "session", method: "updateQueue", args: { request: value } };
		case "session.fork":
			return { namespace: "session", method: "fork", args: { request: value } };
		case "session.cancel":
			return { namespace: "session", method: "cancel", args: { request: value } };
		case "workspace.archiveSession":
			return { namespace: "workspace", method: "archiveSession", args: { request: value } };
		case "settings.update": {
			const args = { ns: value.ns, patch: value.patch };
			if (Number.isInteger(value.expectedRevision)) args.expectedRevision = value.expectedRevision;
			return { namespace: "settings", method: "update", args };
		}
		case "subagent.list":
			return { namespace: "subagents", method: "list", args: { parentSessionId: value.parentSessionId } };
		case "subagent.interrupt":
			return {
				namespace: "subagents",
				method: "interruptByParent",
				args: {
					childSessionId: value.childSessionId,
					parentSessionId: value.parentSessionId,
					mode: value.mode,
				},
			};
		case "goal.create":
			return {
				namespace: "goals",
				method: "create",
				args: {
					agentId: value.sessionId,
					request: {
						objective: value.objective,
						...(value.maxGoalRounds === undefined ? {} : { maxGoalRounds: value.maxGoalRounds }),
					},
				},
			};
		case "goal.edit":
			return {
				namespace: "goals",
				method: "edit",
				args: { agentId: value.sessionId, ref: value.ref, request: value.request },
			};
		case "goal.pause":
		case "goal.resume":
		case "goal.complete":
		case "goal.clear":
			return {
				namespace: "goals",
				method: method.slice("goal.".length),
				args: { agentId: value.sessionId, ref: value.ref },
			};
		default:
			throw Object.assign(new Error(`RC1 Remote method is not mapped: ${method}`), {
				code: "rc1-method-unmapped",
				status: 501,
			});
	}
}

/** Validate RC1 user-question answers without trusting the mobile UI. */
export function validateQuestionAnswers(questions, answers) {
	if (!Array.isArray(questions) || questions.length === 0 || !Array.isArray(answers) || answers.length !== questions.length) {
		return { ok: false, code: "question-answer-invalid", detail: "每个问题必须恰好对应一个答案" };
	}
	const byId = new Map();
	for (const answer of answers) {
		if (!answer || typeof answer !== "object" || typeof answer.id !== "string" || byId.has(answer.id)) {
			return { ok: false, code: "question-answer-invalid", detail: "答案 id 无效或重复" };
		}
		byId.set(answer.id, answer);
	}
	for (const question of questions) {
		if (!question || typeof question.id !== "string") {
			return { ok: false, code: "question-answer-invalid", detail: "问题 id 无效" };
		}
		const answer = byId.get(question.id);
		if (!answer) return { ok: false, code: "question-answer-invalid", detail: `缺少问题 ${question.id} 的答案` };
		const selected = answer.selected ?? [];
		const custom = answer.custom ?? "";
		if (!Array.isArray(selected) || selected.some((label) => typeof label !== "string")) {
			return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 的 selected 无效` };
		}
		if (typeof custom !== "string") return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 的 custom 无效` };
		if (new Set(selected).size !== selected.length) return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 的选项重复` };
		const labels = new Set((Array.isArray(question.options) ? question.options : [])
			.filter((option) => option && typeof option.label === "string")
			.map((option) => option.label));
		if (selected.some((label) => !labels.has(label))) return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 含未声明选项` };
		if (!question.multiSelect && selected.length > 1) return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 只能单选` };
		if (!question.multiSelect && custom.trim() !== "" && selected.length > 0) return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 不能同时提交选项和自定义答案` };
		if (selected.length === 0 && custom.trim() === "") return { ok: false, code: "question-answer-invalid", detail: `问题 ${question.id} 未回答` };
	}
	return { ok: true };
}

export function normalizeRc1ModelCatalog(value) {
	if (!value || typeof value !== "object") return value;
	const current = value.current ?? (value.default && typeof value.default === "object" ? value.default : undefined);
	return { ...value, ...(current ? { current } : {}) };
}

export function imageLimitsFromRc1SessionList(value, sessionId) {
	const row = value?.items?.find?.((item) => item?.sessionId === sessionId);
	return row?.projections?.values?.imageLimits ?? null;
}

export function foldRc1ModelSelection(events) {
	let lastUsed = null;
	let pending = null;
	for (const event of Array.isArray(events) ? events : []) {
		if (event?.type === "model/selection" && isModelSelection(event.data)) {
			if (!sameModelSelection(pending, event.data)) pending = event.data;
			continue;
		}
		if (event?.type !== "request/header") continue;
		const config = event.data?.header?.config;
		if (typeof config?.provider !== "string" || typeof config?.model !== "string") continue;
		const used = {
			provider: config.provider,
			model: config.model,
			...(config.reasoningEffort === undefined ? {} : { reasoningEffort: String(config.reasoningEffort) }),
		};
		lastUsed = used;
		if (sameModelSelection(pending, used)) pending = null;
	}
	return pending ?? lastUsed;
}

export function modelSelectionFromRc1SessionList(value, sessionId) {
	const row = value?.items?.find?.((item) => item?.sessionId === sessionId);
	const selection = row?.projections?.values?.modelSelection?.next;
	return isModelSelection(selection) ? selection : null;
}

export function sessionIdFromRc1AgentId(agentId) {
	return typeof agentId === "string" ? agentId.replace(/^session:/, "") : "";
}

export function sessionEventsOf(session) {
	if (!session || typeof session !== "object") return [];
	if (typeof session.snapshotEvents === "function") {
		try {
			const events = session.snapshotEvents();
			return Array.isArray(events) ? events : [];
		} catch {
			// A Session may be disposed between lookup and snapshot.
		}
	}
	return Array.isArray(session.events) ? session.events : [];
}

function isModelSelection(value) {
	return value && typeof value === "object"
		&& typeof value.provider === "string" && value.provider !== ""
		&& typeof value.model === "string" && value.model !== ""
		&& (value.reasoningEffort === undefined || typeof value.reasoningEffort === "string");
}

function sameModelSelection(left, right) {
	return !!left && !!right
		&& left.provider === right.provider
		&& left.model === right.model
		&& left.reasoningEffort === right.reasoningEffort;
}
