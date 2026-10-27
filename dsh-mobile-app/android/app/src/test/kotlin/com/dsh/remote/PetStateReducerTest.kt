package com.dsh.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PetStateReducerTest {
    @Test
    fun turnFlow() {
        val reducer = PetStateReducer()
        assertEquals("IDLE", reducer.state)
        assertEquals("THINKING", reducer.onTurnStart().state)
        assertEquals("WORKING", reducer.onToolCall("web_search").state)
        assertEquals("searching", reducer.activity)
        assertEquals("THINKING", reducer.onToolResult("web_search", false).state)
        assertEquals("WORKING", reducer.onToolCall("shell").state)
        assertEquals("commanding", reducer.activity)
    }

    @Test
    fun toolFailureIsPulseNotDurableError() {
        val reducer = PetStateReducer()
        reducer.onTurnStart()
        reducer.onToolCall("read_file")
        val change = reducer.onToolResult("read_file", true)
        assertTrue(change.pulse)
        assertEquals("ERROR", change.state)
        assertEquals("WORKING", change.resumeState)
        assertEquals("WORKING", reducer.state)
    }

    @Test
    fun blockedTurnsStayWaitingUntilNextTurn() {
        val reducer = PetStateReducer()
        reducer.onTurnStart()
        assertEquals("WAITING", reducer.onTurnEnd("blocked")?.state)
        assertNull(reducer.onAgentStatus("idle", false))
        assertEquals("WAITING", reducer.state)
        assertEquals("THINKING", reducer.onTurnStart().state)
    }

    @Test
    fun errorHoldsUntilNextTurn() {
        val reducer = PetStateReducer()
        reducer.onTurnStart()
        assertEquals("ERROR", reducer.onTurnEnd("error")?.state)
        assertNull(reducer.onAgentStatus("idle", false))
        assertEquals("ERROR", reducer.state)
        assertEquals("THINKING", reducer.onTurnStart().state)
    }

    @Test
    fun completionPulseKeepsRunningState() {
        val reducer = PetStateReducer()
        reducer.onTurnStart()
        reducer.onToolCall("edit_file")
        val change = reducer.onNotify("completed")!!
        assertTrue(change.pulse)
        assertEquals("SUCCESS", change.state)
        assertEquals("THINKING", change.resumeState)
        assertEquals("WORKING", reducer.state)
    }

    @Test
    fun notificationsMapToStates() {
        val reducer = PetStateReducer()
        assertEquals("WAITING", reducer.onNotify("needs-answer")?.state)
        assertEquals("ERROR", reducer.onNotify("failed")?.state)
        assertNull(reducer.onNotify("unknown"))
    }

    @Test
    fun completionClearsWaiting() {
        val reducer = PetStateReducer()
        reducer.onNotify("needs-answer")
        val change = reducer.onNotify("completed")!!
        assertTrue(change.pulse)
        assertEquals("IDLE", change.resumeState)
        assertEquals("IDLE", reducer.state)
    }

    @Test
    fun childAgentAndIdleDoNotOverride() {
        val reducer = PetStateReducer()
        reducer.onTurnStart()
        assertNull(reducer.onAgentStatus("running", true))
        assertEquals("THINKING", reducer.state)
        assertEquals("IDLE", reducer.onAgentStatus("idle", false)?.state)
        assertFalse(reducer.onAgentStatus("idle", false) != null) // 已空闲，重复快照无变化
    }

    @Test
    fun activityMapping() {
        assertEquals("searching", PetStateReducer.activityOf("Grep"))
        assertEquals("editing", PetStateReducer.activityOf("apply_patch"))
        assertEquals("testing", PetStateReducer.activityOf("run_tests"))
        assertEquals("commanding", PetStateReducer.activityOf("powershell"))
        assertEquals("using-tool", PetStateReducer.activityOf("todo_write"))
        assertEquals("using-tool", PetStateReducer.activityOf(null))
    }
}
