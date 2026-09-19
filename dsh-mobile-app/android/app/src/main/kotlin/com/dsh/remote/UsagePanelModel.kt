package com.dsh.remote

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * 悬浮球面板「用量与额度」区块的纯模型与决策（seam，见 GitLab issue #2 的 Testing Decisions）。
 *
 * 刻意不依赖任何 Android 框架类型：普通 JVM 即可单测（UsagePanelModelTest），
 * 服务只负责喂入 JSON / 时间并把渲染模型画出来。
 *
 * 领域约定（CONTEXT.md / docs/adr/0002）：
 * - Balance 是金额、Quota 是时间窗口容量，二者永不相加；
 * - 区块只展示每个来源主 bucket 的窗口，附加 bucket（服务端命名「名称 · 5h」）留在详情页；
 * - 配额窗口只以细条 + 颜色表意、不出任何百分比数字；金额项保留文字；
 * - 只有金额参与预警，配额窗口永不（该判定在服务侧，与本模型无关）。
 */
object UsagePanelModel {
    /** 展开面板触发一次拉取的节流窗。 */
    const val FETCH_THROTTLE_MS = 2 * 60 * 1000L

    /** 上次成功数据超过该时长即在区块下标注相对时间。 */
    const val STALE_AFTER_MS = 10 * 60 * 1000L

    /** 每个配额来源最多画多少条细条（防异常多的窗口撑爆面板行）。 */
    const val MAX_BARS_PER_ROW = 4

    enum class Severity { OK, WARN, DANGER }

    data class Bar(val ratio: Double, val severity: Severity, val limited: Boolean)

    data class BalanceLine(val text: String, val low: Boolean)

    data class SourceRow(
        val title: String,
        val isBalance: Boolean,
        val balance: BalanceLine?,
        val bars: List<Bar>,
    )

    /** 区块渲染模型 + 是否该发起拉取的决策，全部由纯输入推导。 */
    data class View(
        val blockVisible: Boolean,
        val querying: Boolean,
        val rows: List<SourceRow>,
        val stale: Boolean,
        val fetchDue: Boolean,
    )

    /** 服务侧喂入的完整状态快照（读 volatile 字段拼装，线程无关）。 */
    data class State(
        val payload: JSONObject?,
        val payloadFetchedAtMs: Long,
        val fetchInFlight: Boolean,
        val lastFetchStartMs: Long,
        val lowBalance: Boolean,
        val nowMs: Long,
    )

    fun build(state: State): View {
        val hasPayload = state.payload != null
        val rows = mutableListOf<SourceRow>()
        var stale = false
        if (hasPayload) {
            if (state.payloadFetchedAtMs > 0 && state.nowMs - state.payloadFetchedAtMs >= STALE_AFTER_MS) {
                stale = true
            }
            val sources = state.payload!!.optJSONArray("sources") ?: JSONArray()
            for (i in 0 until sources.length()) {
                val s = sources.optJSONObject(i) ?: continue
                rows.addAll(rowsFor(s, state.lowBalance))
            }
        }
        val fetchDue = !state.fetchInFlight && state.nowMs - state.lastFetchStartMs >= FETCH_THROTTLE_MS
        return View(
            blockVisible = hasPayload || state.fetchInFlight,
            querying = state.fetchInFlight && !hasPayload,
            rows = rows,
            stale = stale,
            fetchDue = fetchDue,
        )
    }

    /** 单个来源 → 0..1 行（无法呈现的来源直接跳过，区块不显示错误文本）。 */
    fun rowsFor(s: JSONObject, lowBalance: Boolean): List<SourceRow> {
        val kind = s.optString("kind")
        val title = s.optString("title").ifEmpty { s.optString("id") }
        return when (kind) {
            "balance" -> {
                val amount = parseAmount(s.opt("amount"))
                if (amount == null) emptyList()
                else listOf(SourceRow(title, true, BalanceLine(balanceText(amount, s.optString("currency")), lowBalance), emptyList()))
            }
            "quota" -> {
                val windows = s.optJSONArray("windows") ?: JSONArray()
                val bars = mutableListOf<Bar>()
                val sorted = (0 until windows.length())
                    .mapNotNull { windows.optJSONObject(it) }
                    .filter { isMainBucketWindow(it.optString("window")) }
                    .sortedBy { windowOrderSeconds(it.optString("window")) }
                for (w in sorted) {
                    val ratio = clampRatio(w.optDouble("remainingPercent", -1.0))
                    if (ratio == null) continue
                    bars.add(Bar(ratio, severityOf(ratio), w.optBoolean("limited")))
                    if (bars.size >= MAX_BARS_PER_ROW) break
                }
                if (bars.isEmpty()) emptyList()
                else listOf(SourceRow(title, false, null, bars))
            }
            else -> emptyList()
        }
    }

    /** 主 bucket 判定：服务端把附加 bucket 窗口命名为「名称 · 窗口」（如 "Personal · 5h"）。 */
    fun isMainBucketWindow(label: String): Boolean = !label.contains(" · ")

    /** 窗口标签 → 周期秒（未知标签排最后，保持服务端顺序稳定）。 */
    fun windowOrderSeconds(label: String): Long {
        val t = label.trim()
        return when {
            t == "5h" -> 18_000L
            t == "weekly" -> 604_800L
            t == "monthly" -> 2_592_000L
            else -> {
                val m = Regex("^(\\d+)([smhdw])$").find(t)
                if (m != null) {
                    val n = m.groupValues[1].toLongOrNull() ?: 0L
                    when (m.groupValues[2]) {
                        "s" -> n
                        "m" -> n * 60
                        "h" -> n * 3600
                        "d" -> n * 86400
                        "w" -> n * 604800
                        else -> Long.MAX_VALUE
                    }
                } else Long.MAX_VALUE
            }
        }
    }

    /** 剩余比例 → 严重度（与详情页 _quotaColor 同阈值：<20% 危险，<50% 警告）。 */
    fun severityOf(ratio: Double): Severity = when {
        ratio < 0.2 -> Severity.DANGER
        ratio < 0.5 -> Severity.WARN
        else -> Severity.OK
    }

    /** remainingPercent（服务端 0..100）→ 0..1 剩余比例；非法值返回 null。 */
    fun clampRatio(percent: Double): Double? {
        if (percent.isNaN() || percent < 0.0 || percent > 100.0) return null
        return percent / 100.0
    }

    /** 金额文本：CNY → ¥；空币种 → 裸数字；其它 → "$<currency> "。与详情页同口径。 */
    fun balanceText(amount: Double, currency: String): String {
        val num = String.format(Locale.ROOT, "%.2f", amount)
        return when {
            currency == "CNY" -> "¥$num"
            currency.isEmpty() || currency == "null" -> num
            else -> "\$$currency $num"
        }
    }

    fun parseAmount(v: Any?): Double? = when (v) {
        is Number -> if (v.toDouble().isFinite()) v.toDouble() else null
        is String -> v.toDoubleOrNull()?.takeIf { it.isFinite() }
        else -> null
    }

    /**
     * 解析 `/m/api/balance` 响应：优先 CNY（与详情页 normalizeDeepSeekBalance 同口径，
     * 修掉旧的 balance_infos[0] 位置取值）。调用方保证是 200 响应的合法 JSON。
     */
    fun deepseekBalanceFromBalancePayload(raw: String): Double? = try {
        val body = JSONObject(raw)
        val infos = body.optJSONObject("balance")?.optJSONArray("balance_infos")
            ?: body.optJSONArray("balance_infos")
        if (infos == null || infos.length() == 0) return null
        val first = infos.optJSONObject(0) ?: return null
        val cny = (0 until infos.length())
            .mapNotNull { infos.optJSONObject(it) }
            .firstOrNull { it.optString("currency") == "CNY" }
        parseAmount((cny ?: first).opt("total_balance"))
    } catch (_: Exception) {
        null
    }

    /** account-usage 里 deepseek 来源的金额（服务端已优先 CNY，这里只按来源取数）。 */
    fun deepseekAmount(payload: JSONObject?): Double? {
        if (payload == null) return null
        val sources = payload.optJSONArray("sources") ?: return null
        for (i in 0 until sources.length()) {
            val s = sources.optJSONObject(i) ?: continue
            if (s.optString("id") == "deepseek") return parseAmount(s.opt("amount"))
        }
        return null
    }
}