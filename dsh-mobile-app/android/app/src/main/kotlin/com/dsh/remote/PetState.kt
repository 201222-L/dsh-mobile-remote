package com.dsh.remote

/**
 * 一次状态变化。pulse=true 表示"短促提示后回到 resumeState"，用于工具失败/任务完成；
 * 其余为持久基础状态（WAITING/ERROR 会保持到下一次 turn/start 或 agent running）。
 */
data class PetStateChange(
    val state: String,
    val activity: String? = null,
    val pulse: Boolean = false,
    val resumeState: String? = null,
    val resumeActivity: String? = null,
)

/**
 * 把 DSH 事件收敛成宠物状态。只做纯逻辑，方便 JVM 单测。
 * 规则对齐 dsh-dafeiyu：等待 > 失败 > 工作 > 思考 > 空闲，错误/等待不会被 idle 快照覆盖。
 */
class PetStateReducer {
    var state = "IDLE"
        private set
    var activity: String? = null
        private set

    private var waiting = false

    fun onTurnStart(): PetStateChange = transition("THINKING", null)

    fun onThinking(): PetStateChange? =
        if (state == "WORKING") null else transition("THINKING", null)

    fun onToolCall(name: String?): PetStateChange =
        transition("WORKING", activityOf(name), clearWaiting = true)

    fun onToolResult(name: String?, isError: Boolean): PetStateChange {
        if (!isError) return transition("THINKING", null)
        // 工具级失败只是短促提示；resume 到当前状态，不把整个任务判死。
        return PetStateChange(
            state = "ERROR",
            pulse = true,
            resumeState = state,
            resumeActivity = activity,
        )
    }

    fun onTurnEnd(reasonKind: String?): PetStateChange? = when (reasonKind) {
        "error", "interrupted", "aborted" -> enterError()
        "blocked" -> enterWaiting()
        else -> null
    }

    fun onNotify(kind: String?): PetStateChange? = when (kind) {
        // 完成提示不改变 durable state：pulse 结束后回到"仍在跑"或空闲。
        // 如果之前是等待/失败，完成通知意味着这一轮已经收尾，清掉持久标记。
        "completed" -> {
            waiting = false
            if (state == "ERROR" || state == "WAITING" || state == "SUCCESS") {
                state = "IDLE"
                activity = null
            }
            PetStateChange(
                state = "SUCCESS",
                pulse = true,
                resumeState = if (state == "WORKING" || state == "THINKING") "THINKING" else "IDLE",
            )
        }
        "failed" -> enterError()
        "needs-answer" -> enterWaiting()
        else -> null
    }

    fun onAgentStatus(status: String?, child: Boolean): PetStateChange? {
        if (child) return null
        return when (status) {
            "running" -> {
                // 新一轮/恢复运行：错误与等待都解除。
                if (state == "IDLE" || state == "SUCCESS" || state == "ERROR" || state == "DISCONNECTED") {
                    transition("THINKING", null)
                } else {
                    null
                }
            }
            "idle" -> {
                if (waiting || state == "ERROR" || state == "IDLE") null else transition("IDLE", null)
            }
            else -> null
        }
    }

    fun onDisconnected(): PetStateChange = transition("DISCONNECTED", null)

    fun onConnected(): PetStateChange =
        if (waiting) transition("WAITING", null) else transition("IDLE", null)

    private fun transition(
        next: String,
        nextActivity: String?,
        clearWaiting: Boolean = false,
    ): PetStateChange {
        if (next != "WAITING" || clearWaiting) waiting = false
        state = next
        activity = nextActivity
        return PetStateChange(next, nextActivity)
    }

    private fun enterError(): PetStateChange {
        waiting = false
        state = "ERROR"
        activity = null
        return PetStateChange("ERROR")
    }

    private fun enterWaiting(): PetStateChange {
        waiting = true
        state = "WAITING"
        activity = null
        return PetStateChange("WAITING")
    }

    companion object {
        fun activityOf(name: String?): String {
            val value = name.orEmpty().lowercase()
            // 待办/计划/审批类工具不是文件编辑，不套用 write/edit 关键词。
            if (Regex("todo|plan|question|approval").containsMatchIn(value)) return "using-tool"
            return when {
                Regex("search|grep|find|glob|web|read|fetch|open").containsMatchIn(value) -> "searching"
                Regex("write|edit|patch|replace|create|move|delete").containsMatchIn(value) -> "editing"
                Regex("test|check|lint|build|verify").containsMatchIn(value) -> "testing"
                Regex("shell|bash|exec|command|terminal|powershell").containsMatchIn(value) -> "commanding"
                else -> "using-tool"
            }
        }
    }
}
