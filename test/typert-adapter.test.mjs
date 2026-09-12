import test from "node:test";
import assert from "node:assert/strict";
import { modelSelectionFromRc1SessionList, pathWithinWorkspace, typertRemoteSpec, validateQuestionAnswers } from "../lib/typert-adapter.js";

test("maps RC1 plural Remote namespaces and named arguments", () => {
	assert.deepEqual(typertRemoteSpec("goal.create", { sessionId: "s", objective: "ship", maxGoalRounds: 3 }), {
		namespace: "goals", method: "create", args: {
			agentId: "s", request: { objective: "ship", maxGoalRounds: 3 },
		},
	});
	for (const action of ["pause", "resume", "complete", "clear"]) {
		assert.deepEqual(typertRemoteSpec(`goal.${action}`, { sessionId: "s", ref: { id: "g", revision: 2 } }), {
			namespace: "goals", method: action, args: { agentId: "s", ref: { id: "g", revision: 2 } },
		});
	}
	assert.deepEqual(typertRemoteSpec("session.control"), { namespace: "session", method: "control", args: {} });
	assert.equal(typertRemoteSpec("subagent.list", { parentSessionId: "p" }).namespace, "subagents");
	assert.equal(typertRemoteSpec("subagent.list", { parentSessionId: "p" }).method, "list");
	assert.equal(typertRemoteSpec("subagent.interrupt", { childSessionId: "c", parentSessionId: "p", mode: "continuable" }).method, "interruptByParent");
});

test("rejects paths outside or beside a workspace root", () => {
	assert.equal(pathWithinWorkspace("/work/project", "/work/project/file.txt"), true);
	assert.equal(pathWithinWorkspace("/work/project", "/work/project/../secret.txt"), false);
	assert.equal(pathWithinWorkspace("/work/project", "/work/project-other/file.txt"), false);
});

test("prefers RC1 pending model selection", () => {
	assert.deepEqual(modelSelectionFromRc1SessionList({ items: [{ sessionId: "s", projections: { values: { modelSelection: { next: { provider: "p", model: "m" }, lastUsed: { provider: "old", model: "old" } } } } }] }, "s"), { provider: "p", model: "m" });
});

test("validates question answers against the original request", () => {
	const questions = [
		{ id: "q1", multiSelect: false, options: [{ label: "yes" }, { label: "no" }] },
		{ id: "q2", multiSelect: true, options: [{ label: "a" }, { label: "b" }] },
	];
	assert.deepEqual(validateQuestionAnswers(questions, [
		{ id: "q1", selected: ["yes"] },
		{ id: "q2", selected: ["a", "b"] },
	]), { ok: true });
	assert.equal(validateQuestionAnswers(questions, [{ id: "q1", selected: ["yes"] }]).ok, false);
	assert.equal(validateQuestionAnswers(questions, [
		{ id: "q1", selected: ["maybe"] }, { id: "q2", custom: "answer" },
	]).ok, false);
	assert.equal(validateQuestionAnswers(questions, [
		{ id: "q1", selected: ["yes", "no"] }, { id: "q2", selected: ["a"] },
	]).ok, false);
	assert.equal(validateQuestionAnswers(questions, [
		{ id: "q1", selected: [], custom: "" }, { id: "q2", selected: ["a"] },
	]).ok, false);
	// RC1 requires selected even when custom text is present; null must not be coerced.
	assert.equal(validateQuestionAnswers(questions, [
		{ id: "q1", custom: "other" }, { id: "q2", selected: ["a"] },
	]).ok, false);
	assert.equal(validateQuestionAnswers(questions, [
		{ id: "q1", selected: null, custom: "other" }, { id: "q2", selected: ["a"] },
	]).ok, false);
	assert.equal(validateQuestionAnswers(questions, [
		{ id: "q1", selected: ["yes"], custom: null }, { id: "q2", selected: ["a"] },
	]).ok, false);
});
