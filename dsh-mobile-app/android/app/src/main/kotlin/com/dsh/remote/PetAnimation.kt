package com.dsh.remote

import org.json.JSONObject
import kotlin.random.Random

/** 一组宠物动作的元数据（由 tools/build_pet_assets.py 生成）。 */
data class PetClip(
    val name: String,
    val file: String,
    val frames: Int,
    val frameMs: Int,
    val loop: Boolean,
) {
    val durationMs: Long get() = frames.toLong() * frameMs
}

/** 手机端 pet-manifest.json 的解析结果。 */
data class PetManifest(
    val canvasWidth: Int,
    val canvasHeight: Int,
    val clips: Map<String, PetClip>,
    val stateMap: Map<String, String>,
    val workingActivityMap: Map<String, String>,
    val idleMicroClips: List<String>,
    val idleMicroIntervalsMs: Map<String, Pair<Long, Long>>,
    val interactionCooldownMs: Long,
) {
    val idleClip: String get() = stateMap["IDLE"]?.takeIf { it in clips } ?: clips.keys.first()

    companion object {
        fun parse(raw: String): PetManifest {
            val root = JSONObject(raw)
            val canvas = root.getJSONObject("canvas")
            val clipObj = root.getJSONObject("clips")
            val clips = buildMap {
                for (key in clipObj.keys()) {
                    val item = clipObj.getJSONObject(key)
                    put(
                        key,
                        PetClip(
                            name = key,
                            file = item.getString("file"),
                            frames = item.getInt("frames"),
                            frameMs = item.getInt("frameMs"),
                            loop = item.optBoolean("loop", true),
                        ),
                    )
                }
            }
            require(clips.isNotEmpty()) { "pet manifest has no clips" }

            val stateObj = root.getJSONObject("stateMap")
            val stateMap = buildMap {
                for (key in stateObj.keys()) put(key, stateObj.getString(key))
            }
            require(stateMap["IDLE"] in clips) { "pet manifest has no idle clip" }

            val activityObj = root.optJSONObject("workingActivityMap")
            val activityMap = buildMap {
                if (activityObj != null) {
                    for (key in activityObj.keys()) {
                        val clip = activityObj.getString(key)
                        if (clip in clips) put(key, clip)
                    }
                }
            }

            val microArray = root.optJSONArray("idleMicroClips")
            val microClips = buildList {
                if (microArray != null) {
                    for (i in 0 until microArray.length()) {
                        val clip = microArray.optString(i)
                        if (clip in clips) add(clip)
                    }
                }
            }

            val intervalObj = root.optJSONObject("idleMicroIntervalsMs")
            val intervals = buildMap {
                if (intervalObj != null) {
                    for (key in intervalObj.keys()) {
                        val range = intervalObj.optJSONArray(key) ?: continue
                        if (range.length() >= 2) {
                            put(key, range.getLong(0) to range.getLong(1))
                        }
                    }
                }
            }

            return PetManifest(
                canvasWidth = canvas.getInt("width"),
                canvasHeight = canvas.getInt("height"),
                clips = clips,
                stateMap = stateMap,
                workingActivityMap = activityMap,
                idleMicroClips = microClips,
                idleMicroIntervalsMs = intervals,
                interactionCooldownMs = root.optLong("interactionCooldownMs", 1200L),
            )
        }
    }
}

/**
 * 与 dsh-dafeiyu 的动画状态机同构：基础状态 + 一次性 overlay + 完成/失败 pulse。
 * 这里只负责"该播哪段"，帧推进交给 PetView（AnimatedImageDrawable）。
 */
class PetAnimationModel(val manifest: PetManifest) {
    var baseState = "IDLE"
        private set
    var baseActivity: String? = null
        private set
    var baseClipName = clipFor("IDLE", null)
        private set

    var overlayClipName: String? = null
        private set
    var overlayEndsAtMs = 0L
        private set

    var pulseState: String? = null
        private set
    var pulseClipName: String? = null
        private set
    var pulseDeadlineMs = 0L
        private set

    var activeClipName = baseClipName
        private set
    var activeVersion = 0L
        private set

    private var lastInteractionMs = Long.MIN_VALUE
    private var lastIdleMicro: String? = null

    val activeClip: PetClip
        get() = manifest.clips[activeClipName] ?: manifest.clips.getValue(manifest.idleClip)

    val isDragging: Boolean
        get() = overlayClipName in DRAG_CLIPS

    val hasOverlay: Boolean
        get() = overlayClipName != null

    /** 当前 overlay / pulse 结束后要回到的片段。 */
    private fun underlayClipName(): String = pulseClipName ?: baseClipName

    fun applyState(state: String, activity: String? = null) {
        if (state !in manifest.stateMap) return
        baseState = state
        baseActivity = activity
        baseClipName = clipFor(state, activity)
        // IDLE 的重复快照不能取消完成/失败 pulse（dafeiyu 同规则）。
        if (state != "IDLE") {
            pulseState = null
            pulseClipName = null
            pulseDeadlineMs = 0
            if (overlayClipName !in DRAG_CLIPS) {
                overlayClipName = null
                overlayEndsAtMs = 0
            }
        }
        if (overlayClipName == null) activate(underlayClipName())
    }

    fun applyPulse(
        state: String,
        ttlMs: Long,
        nowMs: Long,
        resumeState: String? = null,
        resumeActivity: String? = null,
    ): Boolean {
        if (state !in manifest.stateMap || ttlMs <= 0) return false
        if (resumeState != null && resumeState in manifest.stateMap) {
            baseState = resumeState
            baseActivity = resumeActivity
            baseClipName = clipFor(resumeState, resumeActivity)
        }
        val clip = manifest.clips[clipFor(state, null)] ?: return false
        val previousDeadline = if (pulseState == state) pulseDeadlineMs else 0L
        pulseState = state
        pulseClipName = clip.name
        pulseDeadlineMs = maxOf(nowMs + ttlMs, previousDeadline, nowMs + clip.durationMs)
        if (overlayClipName !in DRAG_CLIPS) {
            overlayClipName = null
            overlayEndsAtMs = 0
        }
        if (overlayClipName == null) activate(clip.name)
        return true
    }

    fun playOverlay(clipName: String, nowMs: Long): Boolean {
        val clip = manifest.clips[clipName] ?: return false
        overlayClipName = clipName
        overlayEndsAtMs = if (clip.loop) 0L else nowMs + clip.durationMs
        activate(clipName)
        return true
    }

    fun clearOverlay() {
        if (overlayClipName == null) return
        overlayClipName = null
        overlayEndsAtMs = 0
        activate(underlayClipName())
    }

    fun playInteraction(clipName: String, nowMs: Long): Boolean {
        if (clipName !in INTERACTION_CLIPS) return false
        if (pulseState != null) return false
        if (overlayClipName in INTERACTION_CLIPS || overlayClipName in DRAG_CLIPS) return false
        if (lastInteractionMs != Long.MIN_VALUE &&
            nowMs - lastInteractionMs < manifest.interactionCooldownMs
        ) {
            return false
        }
        if (!playOverlay(clipName, nowMs)) return false
        lastInteractionMs = nowMs
        return true
    }

    fun playIdleMicro(clipName: String, nowMs: Long): Boolean {
        if (baseState != "IDLE" || overlayClipName != null || pulseState != null) return false
        if (clipName !in manifest.idleMicroClips) return false
        lastIdleMicro = clipName
        return playOverlay(clipName, nowMs)
    }

    fun pickIdleMicro(random: Random = Random.Default): String? {
        val choices = manifest.idleMicroClips
        if (choices.isEmpty()) return null
        var clip = choices[random.nextInt(choices.size)]
        if (choices.size > 1 && clip == lastIdleMicro) {
            clip = choices[(choices.indexOf(clip) + 1) % choices.size]
        }
        return clip
    }

    fun idleMicroInterval(activityLevel: String): Pair<Long, Long> =
        manifest.idleMicroIntervalsMs[activityLevel]
            ?: manifest.idleMicroIntervalsMs["normal"]
            ?: (25_000L to 45_000L)

    /** 推进 pulse / overlay 的终点；返回 active 片段是否变化。 */
    fun tick(nowMs: Long): Boolean {
        var changed = false
        if (pulseDeadlineMs > 0 && nowMs >= pulseDeadlineMs) {
            pulseState = null
            pulseClipName = null
            pulseDeadlineMs = 0
            if (overlayClipName == null) changed = activate(underlayClipName())
        }
        if (overlayClipName != null && overlayEndsAtMs > 0 && nowMs >= overlayEndsAtMs) {
            overlayClipName = null
            overlayEndsAtMs = 0
            changed = activate(underlayClipName()) || changed
        }
        return changed
    }

    fun crossfadeMs(previousClip: String?, currentClip: String?): Long? {
        if (previousClip == null || currentClip == null) return null
        if (previousClip == currentClip) return null
        if (previousClip in DRAG_CLIPS || currentClip in DRAG_CLIPS) return null
        return 100L
    }

    private fun clipFor(state: String, activity: String?): String {
        if (state == "WORKING" && activity != null) {
            manifest.workingActivityMap[activity]?.let { return it }
        }
        return manifest.stateMap[state] ?: manifest.stateMap.getValue("IDLE")
    }

    private fun activate(name: String): Boolean {
        val safe = if (name in manifest.clips) name else manifest.idleClip
        if (safe == activeClipName) return false
        activeClipName = safe
        activeVersion++
        return true
    }

    companion object {
        val DRAG_CLIPS = setOf("dragging", "dragging_release")
        val INTERACTION_CLIPS = setOf("head_pat", "poke", "tail")
    }
}
