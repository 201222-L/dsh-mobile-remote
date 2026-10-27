package com.dsh.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class PetAnimationModelTest {
    private fun manifest(): PetManifest = PetManifest.parse(
        """
        {
          "version": 1,
          "canvas": {"width": 288, "height": 229},
          "clips": {
            "idle": {"file": "idle.webp", "frames": 10, "frameMs": 100, "loop": true},
            "thinking": {"file": "thinking.webp", "frames": 10, "frameMs": 100, "loop": true},
            "working": {"file": "working.webp", "frames": 10, "frameMs": 100, "loop": true},
            "working_search": {"file": "working_search.webp", "frames": 10, "frameMs": 100, "loop": true},
            "working_command": {"file": "working_command.webp", "frames": 10, "frameMs": 100, "loop": true},
            "waiting": {"file": "waiting.webp", "frames": 10, "frameMs": 100, "loop": true},
            "success": {"file": "success.webp", "frames": 10, "frameMs": 100, "loop": false},
            "error": {"file": "error.webp", "frames": 5, "frameMs": 100, "loop": false},
            "head_pat": {"file": "head_pat.webp", "frames": 3, "frameMs": 100, "loop": false},
            "poke": {"file": "poke.webp", "frames": 3, "frameMs": 100, "loop": false},
            "tail": {"file": "tail.webp", "frames": 3, "frameMs": 100, "loop": false},
            "dragging": {"file": "dragging.webp", "frames": 10, "frameMs": 100, "loop": true},
            "dragging_release": {"file": "dragging_release.webp", "frames": 4, "frameMs": 100, "loop": false},
            "idle_stretch": {"file": "idle_stretch.webp", "frames": 4, "frameMs": 100, "loop": false},
            "idle_yawn": {"file": "idle_yawn.webp", "frames": 4, "frameMs": 100, "loop": false}
          },
          "stateMap": {
            "IDLE": "idle",
            "THINKING": "thinking",
            "WORKING": "working",
            "WAITING": "waiting",
            "SUCCESS": "success",
            "ERROR": "error",
            "DISCONNECTED": "idle"
          },
          "workingActivityMap": {"searching": "working_search", "commanding": "working_command"},
          "idleMicroClips": ["idle_stretch", "idle_yawn"],
          "idleMicroIntervalsMs": {"normal": [1000, 2000]},
          "interactionCooldownMs": 1200
        }
        """.trimIndent(),
    )

    @Test
    fun startsIdle() {
        val model = PetAnimationModel(manifest())
        assertEquals("idle", model.activeClipName)
        assertEquals("IDLE", model.baseState)
    }

    @Test
    fun stateAndActivityPickClip() {
        val model = PetAnimationModel(manifest())
        model.applyState("WORKING", "searching")
        assertEquals("working_search", model.activeClipName)
        model.applyState("WORKING", "commanding")
        assertEquals("working_command", model.activeClipName)
        model.applyState("WORKING", "editing")
        assertEquals("working", model.activeClipName)
        model.applyState("WAITING")
        assertEquals("waiting", model.activeClipName)
    }

    @Test
    fun interactionEndsAndHonorsCooldown() {
        val model = PetAnimationModel(manifest())
        assertTrue(model.playInteraction("head_pat", 1_000))
        assertEquals("head_pat", model.activeClipName)
        // 接近播完时仍保持 overlay
        assertFalse(model.tick(1_299))
        assertEquals("head_pat", model.activeClipName)
        // 播完回 idle
        assertTrue(model.tick(1_300))
        assertEquals("idle", model.activeClipName)
        // 冷却期内不允许再次互动
        assertFalse(model.playInteraction("poke", 1_500))
        assertTrue(model.playInteraction("poke", 2_201))
    }

    @Test
    fun pulseTakesOverAndReturnsToResumeState() {
        val model = PetAnimationModel(manifest())
        model.applyState("WORKING", "searching")
        assertTrue(model.applyPulse("SUCCESS", 1_000, 5_000, resumeState = "THINKING"))
        assertEquals("success", model.activeClipName)
        // pulse 未到期
        assertFalse(model.tick(5_500))
        // 到期后回到 THINKING
        assertTrue(model.tick(6_000))
        assertEquals("thinking", model.activeClipName)
    }

    @Test
    fun dragProtectsOverlayFromStateChanges() {
        val model = PetAnimationModel(manifest())
        assertTrue(model.playOverlay("dragging", 1_000))
        model.applyState("WORKING", "searching")
        assertEquals("dragging", model.activeClipName)
        assertTrue(model.playOverlay("dragging_release", 2_000))
        assertEquals("dragging_release", model.activeClipName)
        assertTrue(model.tick(2_400))
        assertEquals("working_search", model.activeClipName)
    }

    @Test
    fun idleMicroOnlyWhenIdleAndNotRepeating() {
        val model = PetAnimationModel(manifest())
        model.applyState("THINKING")
        assertFalse(model.playIdleMicro("idle_stretch", 1_000))
        model.applyState("IDLE")
        val first = model.pickIdleMicro(Random(1))!!
        assertTrue(model.playIdleMicro(first, 1_000))
        assertEquals(first, model.activeClipName)
        val second = model.pickIdleMicro(Random(1))!!
        assertTrue(first != second)
        assertFalse(model.playIdleMicro("idle_yawn", 1_100))
    }

    @Test
    fun crossfadeSkipsDrag() {
        val model = PetAnimationModel(manifest())
        assertEquals(100L, model.crossfadeMs("idle", "thinking"))
        assertNull(model.crossfadeMs("idle", "idle"))
        assertNull(model.crossfadeMs("idle", "dragging"))
        assertNull(model.crossfadeMs("dragging_release", "idle"))
    }
}
