package com.dsh.remote

import android.content.Context
import android.graphics.BitmapFactory
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import android.graphics.ImageDecoder
import android.graphics.RenderEffect
import android.graphics.Shader
import android.graphics.drawable.Animatable
import android.graphics.drawable.AnimatedImageDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.util.Log
import android.widget.FrameLayout
import android.widget.ImageView
import java.util.concurrent.Executors

/**
 * 宠物渲染层：两层 ImageView 做 100ms 交叉淡化；API 28+ 用 AnimatedImageDrawable
 * 直接播 animated WebP，API 24-27 退化为静态首帧（互动与状态文字仍工作）。
 */
class PetView(context: Context) : FrameLayout(context) {
    private val current = ImageView(context)
    private val next = ImageView(context)
    private val executor = Executors.newSingleThreadExecutor()
    private var requestId = 0
    private var currentClip: String? = null
    private var activeDrawable: Drawable? = null
    private var activeIsCurrent = true
    private var animationRunning = true
    private var dimmed = false
    private var blurWhenDimmed = true

    init {
        clipChildren = false
        clipToPadding = false
        addView(next, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        addView(current, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        current.scaleType = ImageView.ScaleType.FIT_CENTER
        next.scaleType = ImageView.ScaleType.FIT_CENTER
        next.alpha = 0f
        contentDescription = "DSH desktop pet"
    }

    fun showClip(clip: PetClip, animate: Boolean) {
        if (clip.name == currentClip) {
            if (animationRunning) startDrawable(activeDrawable)
            return
        }
        val token = ++requestId
        executor.execute {
            val drawable = load(clip)
            post {
                if (token != requestId || !isAttachedToWindow) {
                    stopDrawable(drawable)
                    return@post
                }
                applyClip(drawable, clip, animate)
            }
        }
    }

    fun setAnimationRunning(running: Boolean) {
        if (animationRunning == running) return
        animationRunning = running
        if (running) startDrawable(activeDrawable) else stopDrawable(activeDrawable)
    }

    fun setDimmed(dim: Boolean) {
        if (dimmed == dim) return
        dimmed = dim
        animate().alpha(if (dim) 0.45f else 1f).setDuration(180).start()
        val filter = if (dim) {
            ColorMatrixColorFilter(ColorMatrix().apply { setSaturation(0.4f) })
        } else {
            null
        }
        current.colorFilter = filter
        next.colorFilter = filter
        if (Build.VERSION.SDK_INT >= 31) {
            setRenderEffect(
                if (dim && blurWhenDimmed) {
                    RenderEffect.createBlurEffect(3f, 3f, Shader.TileMode.CLAMP)
                } else {
                    null
                },
            )
        }
    }

    fun release() {
        requestId++
        stopDrawable(activeDrawable)
        activeDrawable = null
        current.setImageDrawable(null)
        next.setImageDrawable(null)
        executor.shutdownNow()
    }

    private fun applyClip(drawable: Drawable?, clip: PetClip, animate: Boolean) {
        if (drawable == null) {
            Log.w(TAG, "pet clip unavailable: ${clip.name}")
            return
        }
        val target = if (activeIsCurrent) next else current
        val source = if (activeIsCurrent) current else next
        val fade = animate && currentClip != null && source.drawable != null
        val old = source.drawable

        target.setImageDrawable(drawable)
        target.alpha = if (fade) 0f else 1f
        if (fade) {
            target.animate().alpha(1f).setDuration(FADE_MS).start()
            source.animate().alpha(0f).setDuration(FADE_MS).withEndAction {
                source.setImageDrawable(null)
                stopDrawable(old)
            }.start()
        } else {
            source.animate().cancel()
            source.setImageDrawable(null)
            source.alpha = 0f
            stopDrawable(old)
        }

        activeIsCurrent = !activeIsCurrent
        activeDrawable = drawable
        currentClip = clip.name
        if (animationRunning) startDrawable(drawable)
    }

    private fun load(clip: PetClip): Drawable? {
        return try {
            if (Build.VERSION.SDK_INT >= 28) {
                val source = ImageDecoder.createSource(context.assets, "pet/${clip.file}")
                val drawable = ImageDecoder.decodeDrawable(source) { decoder, _, _ ->
                    // 动画 WebP 走软件分配，避免硬件位图 + AnimatedImageDrawable 的兼容问题。
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                }
                (drawable as? AnimatedImageDrawable)?.repeatCount =
                    if (clip.loop) AnimatedImageDrawable.REPEAT_INFINITE else 0
                drawable
            } else {
                context.assets.open("pet/${clip.file}").use { stream ->
                    BitmapFactory.decodeStream(stream)?.let { BitmapDrawable(resources, it) }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "load pet clip ${clip.name} failed", e)
            null
        }
    }

    private fun startDrawable(drawable: Drawable?) {
        (drawable as? Animatable)?.start()
    }

    private fun stopDrawable(drawable: Drawable?) {
        (drawable as? Animatable)?.stop()
    }

    companion object {
        private const val TAG = "DSHRemotePet"
        private const val FADE_MS = 100L
    }
}
