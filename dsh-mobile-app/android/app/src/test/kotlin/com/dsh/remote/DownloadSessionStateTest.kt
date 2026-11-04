package com.dsh.remote

import org.junit.Assert.*
import org.junit.Test

class DownloadSessionStateTest {
    @Test fun staleCallbacksCannotOverwriteOrStopTheNextTransfer() {
        val state = DownloadSessionState()
        assertTrue(state.begin("first"))
        assertFalse(state.begin("second"))
        assertTrue(state.update("first", 5, 10))
        assertTrue(state.end("first"))
        assertTrue(state.begin("second"))
        assertFalse(state.update("first", 10, 10))
        assertFalse(state.end("first"))
        assertEquals("second", state.id)
        assertEquals(0L, state.received)
    }

    @Test fun resumedAndRestartedTransfersReportTheirActualProgress() {
        val state = DownloadSessionState()
        assertTrue(state.begin("download"))
        assertTrue(state.update("download", 400, 1000))
        assertTrue(state.begin("download"))
        assertEquals(400L, state.received)
        assertTrue(state.update("download", 0, 2000)) // If-Range changed: restart
        assertEquals(0L, state.received)
        assertEquals(2000L, state.total)
        assertTrue(state.update("download", 20, null))
        assertNull(state.total)
        assertFalse(state.update("download", -1, 100))
    }
}
