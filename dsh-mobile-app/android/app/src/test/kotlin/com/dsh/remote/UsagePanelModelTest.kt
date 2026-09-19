package com.dsh.remote

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 面板模型 seam 的纯 JVM 单测（无 Android 框架依赖，见 issue #2 Testing Decisions 1-8）。
 */
class UsagePanelModelTest {
    private val now = 5_000_000_000L

    private fun state(
        payload: JSONObject? = null,
        payloadFetchedAtMs: Long = 0L,
        fetchInFlight: Boolean = false,
        lastFetchStartMs: Long = now, // 默认刚拉过：避免干扰 fetchDue 断言
        lowBalance: Boolean = false,
    ) = UsagePanelModel.State(payload, payloadFetchedAtMs, fetchInFlight, lastFetchStartMs, lowBalance, now)

    private fun payload(sourcesJson: String): JSONObject =
        JSONObject("""{"ok":true,"fetchedAt":"2030-01-01T00:00:00Z","sources":$sourcesJson}""")

    // ── 取数决策（Testing Decisions 3）───────────────────────────────
    @Test
    fun `从未拉取且无在途请求时应发起拉取`() {
        val v = UsagePanelModel.build(state(payload = null, lastFetchStartMs = 0))
        assertTrue(v.fetchDue)
        assertFalse(v.blockVisible)
    }

    @Test
    fun `节流窗内不重复拉取`() {
        val v = UsagePanelModel.build(state(payload = null, lastFetchStartMs = now - 60_000))
        assertFalse(v.fetchDue)
    }

    @Test
    fun `超过节流窗应再次拉取`() {
        val v = UsagePanelModel.build(state(payload = null, lastFetchStartMs = now - UsagePanelModel.FETCH_THROTTLE_MS))
        assertTrue(v.fetchDue)
    }

    @Test
    fun `在途请求时不发起第二次拉取`() {
        val v = UsagePanelModel.build(state(payload = null, fetchInFlight = true, lastFetchStartMs = now - 120_000))
        assertFalse(v.fetchDue)
        assertTrue(v.blockVisible)
        assertTrue(v.querying)
    }

    // ── 降级（Testing Decisions 4）───────────────────────────────────
    @Test
    fun `从未成功且不在拉取时区块不可见`() {
        val v = UsagePanelModel.build(state(payload = null, lastFetchStartMs = now - 1000))
        assertFalse(v.blockVisible)
        assertTrue(v.rows.isEmpty())
    }

    @Test
    fun `拉取失败但保留上次值时区块仍可见`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"deepseek","title":"DeepSeek","kind":"balance","amount":"12.50","currency":"CNY"}]"""),
            payloadFetchedAtMs = now - 120_000, lastFetchStartMs = now - 150_000))
        assertTrue(v.blockVisible)
        assertEquals(1, v.rows.size)
    }

    @Test
    fun `空来源视为有载荷但零行`() {
        val v = UsagePanelModel.build(state(payload = payload("[]"), payloadFetchedAtMs = now - 1000))
        assertTrue(v.blockVisible)
        assertTrue(v.rows.isEmpty())
        assertFalse(v.stale)
    }

    // ── 行形状：金额行 vs 配额行；主 bucket 选取；窗口排序（Testing Decisions 5）─
    @Test
    fun `金额行保留文字并优先 CNY`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"deepseek","title":"DeepSeek","kind":"balance","amount":"12.50","currency":"CNY"}]"""),
            payloadFetchedAtMs = now - 1000))
        assertEquals(1, v.rows.size)
        val row = v.rows[0]
        assertTrue(row.isBalance)
        assertEquals("¥12.50", row.balance?.text)
        assertFalse(row.balance?.low == true)
    }

    @Test
    fun `低余额时金额行携带 low 标记`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"deepseek","title":"DeepSeek","kind":"balance","amount":"5.00","currency":"CNY"}]"""),
            payloadFetchedAtMs = now - 1000, lowBalance = true))
        assertTrue(v.rows[0].balance?.low == true)
    }

    @Test
    fun `金额行只有非 CNY 币种时带币种前缀`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"deepseek","title":"DeepSeek","kind":"balance","amount":"3.00","currency":"USD"}]"""),
            payloadFetchedAtMs = now - 1000))
        assertEquals("\$USD 3.00", v.rows[0].balance?.text)
    }

    @Test
    fun `金额来源无金额时整行跳过`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"deepseek","title":"DeepSeek","kind":"balance"}]"""),
            payloadFetchedAtMs = now - 1000))
        assertTrue(v.rows.isEmpty())
    }

    @Test
    fun `配额行窗口按周期升序排列且无数字文本`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"codex","title":"Codex","kind":"quota","windows":[
            {"window":"weekly","remainingPercent":64},
            {"window":"5h","remainingPercent":45}]}]"""), payloadFetchedAtMs = now - 1000))
        assertEquals(1, v.rows.size)
        val row = v.rows[0]
        assertFalse(row.isBalance)
        assertEquals(2, row.bars.size)
        assertEquals(0.45, row.bars[0].ratio, 1e-9) // 5h 在前
        assertEquals(0.64, row.bars[1].ratio, 1e-9)
        assertEquals(UsagePanelModel.Severity.WARN, row.bars[0].severity)
        assertEquals(UsagePanelModel.Severity.OK, row.bars[1].severity)
    }

    @Test
    fun `OpenCode 三窗口按 5h 周 月 排序`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"opencode-go","title":"OpenCode Go","kind":"quota","windows":[
            {"window":"monthly","remainingPercent":76},
            {"window":"weekly","remainingPercent":83},
            {"window":"5h","remainingPercent":91}]}]"""), payloadFetchedAtMs = now - 1000))
        assertEquals(listOf(0.91, 0.83, 0.76), v.rows[0].bars.map { it.ratio })
    }

    @Test
    fun `附加 bucket 窗口不上面板`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"codex","title":"Codex","kind":"quota","windows":[
            {"window":"5h","remainingPercent":72},
            {"window":"Personal · 5h","remainingPercent":80}]}]"""), payloadFetchedAtMs = now - 1000))
        assertEquals(1, v.rows[0].bars.size)
    }

    @Test
    fun `配额来源没有任何可用窗口时整行跳过`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"codex","title":"Codex","kind":"quota","windows":[]}]"""),
            payloadFetchedAtMs = now - 1000))
        assertTrue(v.rows.isEmpty())
    }

    @Test
    fun `限流窗口保留为 0 与限流标记`() {
        val v = UsagePanelModel.build(state(payload = payload("""[{"id":"opencode-go","title":"OpenCode Go","kind":"quota","windows":[
            {"window":"weekly","remainingPercent":0,"limited":true}]}]"""), payloadFetchedAtMs = now - 1000))
        val bar = v.rows[0].bars[0]
        assertEquals(0.0, bar.ratio, 1e-9)
        assertTrue(bar.limited)
        assertEquals(UsagePanelModel.Severity.DANGER, bar.severity)
    }

    // ── 严重度分档（Testing Decisions 6）──────────────────────────────
    @Test
    fun `严重度分档边界`() {
        assertEquals(UsagePanelModel.Severity.DANGER, UsagePanelModel.severityOf(0.0))
        assertEquals(UsagePanelModel.Severity.DANGER, UsagePanelModel.severityOf(0.199))
        assertEquals(UsagePanelModel.Severity.WARN, UsagePanelModel.severityOf(0.2))
        assertEquals(UsagePanelModel.Severity.WARN, UsagePanelModel.severityOf(0.49))
        assertEquals(UsagePanelModel.Severity.OK, UsagePanelModel.severityOf(0.5))
        assertEquals(UsagePanelModel.Severity.OK, UsagePanelModel.severityOf(1.0))
    }

    @Test
    fun `比例裁剪拒绝非法值`() {
        assertEquals(null, UsagePanelModel.clampRatio(-1.0))
        assertEquals(null, UsagePanelModel.clampRatio(101.0))
        assertEquals(null, UsagePanelModel.clampRatio(Double.NaN))
        assertEquals(0.5, UsagePanelModel.clampRatio(50.0) ?: -1.0, 1e-9)
    }

    // ── 过期标注（Testing Decisions 7）────────────────────────────────
    @Test
    fun `新鲜数据不标注过期`() {
        val v = UsagePanelModel.build(state(payload = payload("[]"), payloadFetchedAtMs = now - 1000))
        assertFalse(v.stale)
    }

    @Test
    fun `超过过期窗的数据被标注`() {
        val v = UsagePanelModel.build(state(payload = payload("[]"),
            payloadFetchedAtMs = now - UsagePanelModel.STALE_AFTER_MS))
        assertTrue(v.stale)
    }

    // ── 币种偏好（Testing Decisions 8）────────────────────────────────
    @Test
    fun `balance 载荷非 CNY 在前仍返回 CNY 金额`() {
        val raw = """{"ok":true,"balance":{"is_available":true,"balance_infos":[
            {"currency":"USD","total_balance":"3.00"},
            {"currency":"CNY","total_balance":"12.50"}]}}"""
        assertEquals(12.50, UsagePanelModel.deepseekBalanceFromBalancePayload(raw) ?: 0.0, 1e-9)
    }

    @Test
    fun `balance 载荷只有单一币种时取其金额`() {
        val raw = """{"ok":true,"balance":{"balance_infos":[
            {"currency":"USD","total_balance":"3.00"}]}}"""
        assertEquals(3.00, UsagePanelModel.deepseekBalanceFromBalancePayload(raw) ?: 0.0, 1e-9)
    }

    @Test
    fun `account-usage 中 deepseek 来源的金额取回`() {
        val p = payload("""[{"id":"opencode-go","title":"OpenCode Go","kind":"quota","windows":[]},
            {"id":"deepseek","title":"DeepSeek","kind":"balance","amount":"12.50","currency":"CNY"}]""")
        assertEquals(12.50, UsagePanelModel.deepseekAmount(p) ?: 0.0, 1e-9)
    }

    @Test
    fun `account-usage 无 deepseek 来源时返回 null`() {
        assertEquals(null, UsagePanelModel.deepseekAmount(payload("[]")))
        assertEquals(null, UsagePanelModel.deepseekAmount(null))
    }

    // ── 工具函数 ──────────────────────────────────────────────────────
    @Test
    fun `金额文本币种约定`() {
        assertEquals("¥12.50", UsagePanelModel.balanceText(12.5, "CNY"))
        assertEquals("3.00", UsagePanelModel.balanceText(3.0, ""))
        assertEquals("\$USD 3.00", UsagePanelModel.balanceText(3.0, "USD"))
    }

    @Test
    fun `窗口标签到周期的映射`() {
        assertEquals(18_000L, UsagePanelModel.windowOrderSeconds("5h"))
        assertEquals(604_800L, UsagePanelModel.windowOrderSeconds("weekly"))
        assertEquals(2_592_000L, UsagePanelModel.windowOrderSeconds("monthly"))
        assertEquals(2_700L, UsagePanelModel.windowOrderSeconds("45m"))
        assertEquals(1_209_600L, UsagePanelModel.windowOrderSeconds("2w"))
        assertEquals(Long.MAX_VALUE, UsagePanelModel.windowOrderSeconds("garbage"))
        assertEquals(Long.MAX_VALUE, UsagePanelModel.windowOrderSeconds(""))
    }
}