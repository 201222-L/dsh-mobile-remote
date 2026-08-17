package com.dsh.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Outline
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.TypedValue
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewOutlineProvider
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL

/**
 * 悬浮球常驻服务（v2.7）：
 * - 圆形 DeepSeek 蓝鲸 logo 小球（暗态=灰度半透明；亮态=原色 + 呼吸光晕）
 * - 自己连插件 SSE（/m/api/events），App 被杀仍工作
 * - 单击 → 球旁展开迷你面板（运行中会话 / 最近通知 / 快捷按钮），点外或再点收起
 * - 双击 → 打开主 App；长按 → 退出悬浮球
 * - 事件气泡：5 秒自动收起，不抢焦点
 */
class FloatingBubbleService : Service() {
    companion object {
        const val CHANNEL_ID = "dsh_bubble"
        const val NOTIF_ID = 0xDBB
        @Volatile var running = false
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var wm: WindowManager? = null
    private var bubble: View? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var logoImg: BubbleView? = null
    private var badge: TextView? = null
    private var tip: TextView? = null
    private var tipParams: WindowManager.LayoutParams? = null

    // 迷你面板
    private var panel: View? = null
    private var panelParams: WindowManager.LayoutParams? = null
    private var panelSessions: LinearLayout? = null
    private var panelSessionsSec: View? = null
    private var panelNotifs: LinearLayout? = null
    private var panelNotifsSec: View? = null
    private var panelNotifsBadge: TextView? = null
    private var panelCharge: View? = null
    private var panelVisible = false
    private var scrim: View? = null // 全屏透明触摸层：点击面板外部关闭（位于面板窗口之下）
    private var lastPanelRefresh = 0L
    /** 面板打开期间 5 秒周期兜底刷新（事件驱动之外的状态变化也能跟上）。 */
    private val panelRefreshRunnable: Runnable = Runnable {
        if (panelVisible) {
            refreshPanelData()
            mainHandler.postDelayed(panelRefreshRunnable, 5000)
        }
    }

    private var sseThread: Thread? = null
    @Volatile private var sseAlive = false
    @Volatile private var agentsRunning = false
    @Volatile private var lowBalance = false
    private var notifCount = 0
    private var lastActivity = 0L
    private var lastNotif = 0L
    private var lastNotifKey = ""
    private var lastNotifAt = 0L
    private val seenJobs = mutableSetOf<String>()
    @Volatile private var firstJobsFrame = true // 首个 jobs 帧是连接回放：只学习不通知
    private var bubbleDp = 52

    // 未读增量对比（补"事件驱动之外的提示"：重连窗口/离线期间新增的通知）
    private var lastUnreadCount = 0
    private var firstUnreadCheck = true // 首次检查只记录基线，不提示存量
    /** 每 60 秒对比未读数，增量则提示（防抖：最近 60 秒已提示过则只更新基线）。 */
    private val unreadCheckRunnable: Runnable = object : Runnable {
        override fun run() {
            checkUnreadDelta()
            mainHandler.postDelayed(this, 60000)
        }
    }

    // 拖动/点击判定
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var moved = false
    private var lastTap = 0L
    private val longPressRunnable = Runnable { exitBubble("long-press") }
    /** 贴边后 5 秒无操作才缩进（用户反馈：松手立即缩进导致点击不稳定）。 */
    private val autoHideRunnable = Runnable { autoHideToEdge() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannel()
        startForeground(NOTIF_ID, buildNotification())
        addBubble()
        addTipView()
        addScrim()   // z 序：球 < scrim < 面板
        addPanel()
        startSse()
        // 余额定时自查（30 分钟一次，不依赖 App 打开设置页触发）
        mainHandler.postDelayed(balanceCheckRunnable, 30 * 60 * 1000L)
        // 未读增量对比（60 秒一次，补重连/离线期间的通知提示）
        mainHandler.postDelayed(unreadCheckRunnable, 20000)
    }

    /** 余额自查：每 30 分钟拉一次 /m/api/balance，低余额时亮起 + 气泡 + 面板按钮变红。 */
    private val balanceCheckRunnable: Runnable = object : Runnable {
        override fun run() {
            Thread({
                try {
                    val base = prefs("flutter.dsh_mr_base") ?: return@Thread
                    val token = prefs("flutter.dsh_mr_token") ?: return@Thread
                    var b = base.trim()
                    if (b.endsWith("/")) b = b.dropLast(1)
                    if (b.endsWith("/m")) b = b.dropLast(2)
                    val conn = URL("$b/m/api/balance").openConnection() as HttpURLConnection
                    conn.connectTimeout = 8000
                    conn.setRequestProperty("x-mobile-token", token)
                    if (conn.responseCode == 200) {
                        val txt = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                        val infos = JSONObject(txt).optJSONObject("balance")?.optJSONArray("balance_infos")
                        val first = infos?.optJSONObject(0)
                        val total = first?.opt("total_balance")
                        val v = when (total) {
                            is Number -> total.toDouble()
                            is String -> total.toDoubleOrNull() ?: 0.0
                            else -> 0.0
                        }
                        if (v > 0) onBalance("$v:")
                    }
                    conn.disconnect()
                } catch (_: Exception) {}
            }, "dsh-bubble-balance").start()
            mainHandler.postDelayed(this, 30 * 60 * 1000L)
        }
    }

    override fun onDestroy() {
        running = false
        sseAlive = false
        sseThread?.interrupt()
        mainHandler.removeCallbacksAndMessages(null)
        bubble?.let { runCatching { wm?.removeView(it) } }
        tip?.let { runCatching { wm?.removeView(it) } }
        panel?.let { runCatching { wm?.removeView(it) } }
        scrim?.let { runCatching { wm?.removeView(it) } }
        bubble = null; tip = null; panel = null; scrim = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra("balance")?.let { onBalance(it) }
        return START_STICKY
    }

    // ── 前台通知 ──
    private fun createChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val ch = NotificationChannel(CHANNEL_ID, "DSH Remote 悬浮球", NotificationManager.IMPORTANCE_LOW)
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        val openIntent = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pi = PendingIntent.getActivity(this, 0, openIntent, PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(text("DSH Remote 悬浮球运行中", "DSH Remote bubble is running"))
            .setContentText(text("点击回到 App", "Tap to open the app"))
            .setSmallIcon(R.drawable.deepseek_logo)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    // ── 悬浮球视图（圆形，白底蓝鲸官方图标样式）──
    /** 自绘圆形鲸鱼球：透明背景（无白底圆），圆形裁剪显示鲸鱼。 */
    inner class BubbleView(context: android.content.Context) : View(context) {
        private val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG)
        private val bmp = android.graphics.BitmapFactory.decodeResource(resources, R.drawable.deepseek_logo)
        private val shader = bmp?.let { android.graphics.BitmapShader(it, android.graphics.Shader.TileMode.CLAMP, android.graphics.Shader.TileMode.CLAMP) }

        fun setGray(gray: Boolean) {
            paint.colorFilter = if (gray) {
                android.graphics.ColorMatrixColorFilter(android.graphics.ColorMatrix().apply { setSaturation(0f) })
            } else null
            invalidate()
        }

        override fun onDraw(canvas: android.graphics.Canvas) {
            if (shader == null || bmp == null) return
            val c = width / 2f
            val r = minOf(width, height) / 2f
            // 位图缩放到直径 2r，鲸鱼（占位图 75%）完整落在圆内
            val m = android.graphics.Matrix()
            m.setScale(r * 2f / bmp.width, r * 2f / bmp.height)
            shader.setLocalMatrix(m)
            paint.shader = shader
            canvas.drawCircle(c, c, r, paint)
        }
    }

    private fun addBubble() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        this.wm = wm
        val size = dp(bubbleDp)
        val root = FrameLayout(this)
        root.layoutParams = FrameLayout.LayoutParams(size, size)

        val img = BubbleView(this)
        root.addView(img, FrameLayout.LayoutParams(size, size))

        val bd = TextView(this)
        bd.text = "0"
        bd.textSize = 9f
        bd.setTextColor(Color.WHITE)
        bd.gravity = Gravity.CENTER
        bd.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.parseColor("#E5484D"))
        }
        bd.visibility = View.GONE
        root.addView(bd, FrameLayout.LayoutParams(dp(18), dp(18), Gravity.TOP or Gravity.END))

        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            size, size, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, // 允许越出屏幕（贴边半隐藏必需）
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        // 启动即贴右边缘（完全露出，无需手动拖动吸附）
        params.x = resources.displayMetrics.widthPixels - size
        params.y = dp(240)
        wm.addView(root, params)
        // 启动后 5 秒无操作自动缩进（贴边常驻，无需先拖动）
        mainHandler.postDelayed(autoHideRunnable, 5000)

        val gd = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                android.util.Log.i("DSHRemote", "bubble: tap confirmed")
                // 半隐藏状态先滑出（不触发面板），完全露出后再单击才展开面板
                if (isEdgeHidden()) {
                    slideOut()
                    return true
                }
                togglePanel()
                return true
            }
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (isEdgeHidden()) slideOut()
                else { hidePanel(); openMain() }
                return true
            }
            override fun onLongPress(e: MotionEvent) {
                exitBubble("long-press")
            }
        })
        root.setOnTouchListener { v, ev ->
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
                // 用户操作：取消自动缩进
                mainHandler.removeCallbacks(autoHideRunnable)
            }
            gd.onTouchEvent(ev)
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.rawX; downY = ev.rawY
                    startX = params.x; startY = params.y
                    moved = false
                    mainHandler.postDelayed(longPressRunnable, 600)
                    // 按压反馈：球轻微缩小（"捏一下"）
                    root.animate().scaleX(0.88f).scaleY(0.88f).setDuration(80).start()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downX; val dy = ev.rawY - downY
                    if (Math.abs(dx) > dp(12f) || Math.abs(dy) > dp(12f)) {
                        moved = true
                        mainHandler.removeCallbacks(longPressRunnable)
                    }
                    if (moved) {
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        wm.updateViewLayout(root, params)
                        // 拖动时收起面板；气泡若在显示中则跟随
                        if (panelVisible) hidePanel()
                        positionTip()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    mainHandler.removeCallbacks(longPressRunnable)
                    // 回弹到原尺寸（overshoot 手感）
                    root.animate().scaleX(1f).scaleY(1f).setDuration(140)
                        .setInterpolator(android.view.animation.OvershootInterpolator(1.6f)).start()
                    if (moved) {
                        android.util.Log.i("DSHRemote", "bubble: drag end, snap + schedule auto-hide")
                        snapToEdgeVisible()
                        mainHandler.postDelayed(autoHideRunnable, 5000)
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    mainHandler.removeCallbacks(longPressRunnable)
                    root.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                    true
                }
                else -> false
            }
        }
        bubble = root
        bubbleParams = params
        logoImg = img
        badge = bd
        setState()
    }

    /** 事件气泡（悬浮球上方，5 秒自动收起）。 */
    private fun addTipView() {
        val wm = this.wm ?: return
        val tv = TextView(this)
        tv.setTextColor(Color.WHITE)
        tv.textSize = 12f
        tv.setPadding(dp(12), dp(7), dp(12), dp(7))
        tv.background = GradientDrawable().apply {
            cornerRadius = dp(8).toFloat()
            setColor(Color.parseColor("#E61A1D24"))
        }
        tv.visibility = View.GONE
        tv.setOnClickListener { openMain() }
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        wm.addView(tv, params)
        tip = tv
        tipParams = params
    }

    private fun showTip(text: String) {
        val tv = tip ?: return
        tv.text = text
        tv.visibility = View.VISIBLE
        positionTip()
        mainHandler.removeCallbacks(hideTipRunnable)
        mainHandler.postDelayed(hideTipRunnable, 5000)
    }

    /** 气泡定位：球正上方紧贴（8dp），水平居中于球可见部分；顶部空间不足放球下方。
     *  使用气泡实际测量宽度定位（修复：硬编码 170dp 与实际内容宽度不符 → 窄气泡
     *  被按宽气泡钳制，飘到屏幕中间）。 */
    private fun positionTip() {
        val tv = tip ?: return
        if (tv.visibility != View.VISIBLE) return
        val p = tipParams ?: return
        val bp = bubbleParams ?: return
        val wm = this.wm ?: return
        val metrics = resources.displayMetrics
        val bd = dp(bubbleDp)
        // 实际宽度（首次显示未测量时用估算，布局完成后重定位）
        val tipW = if (tv.width > 0) tv.width else dp(170)
        // 水平：居中于球可见部分，钳制屏内
        val visCenter = (maxOf(0, bp.x) + minOf(metrics.widthPixels, bp.x + bd)) / 2
        p.x = (visCenter - tipW / 2).coerceIn(dp(4), metrics.widthPixels - tipW - dp(4))
        // 垂直：球上方紧贴（气泡高约 30dp + 8dp 间距）；顶部空间不足放球下方
        val above = bp.y - dp(38)
        p.y = if (above >= dp(6)) above else bp.y + bd + dp(6)
        wm.updateViewLayout(tv, p)
        // 首次测量前定位：布局完成后按实际宽度重新定位
        if (tv.width == 0) {
            tv.post { if (tip?.visibility == View.VISIBLE) positionTip() }
        }
    }

    private val hideTipRunnable = Runnable { tip?.visibility = View.GONE }

    /** 全屏透明触摸层：面板打开时接收"面板外"点击 → 关闭面板。
     *  在 onCreate 中先于面板添加，保证 z 序在面板之下、球之上。 */
    private fun addScrim() {
        val wm = this.wm ?: return
        val v = View(this)
        v.setBackgroundColor(Color.TRANSPARENT)
        v.setOnClickListener { hidePanel() }
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        wm.addView(v, params)
        v.visibility = View.GONE
        scrim = v
    }

    /** 松手后吸附到边缘（完全露出），供 5 秒无操作后的缩进做基线。 */
    private fun snapToEdgeVisible() {
        val p = bubbleParams ?: return
        val metrics = resources.displayMetrics
        val bd = dp(bubbleDp)
        val center = p.x + bd / 2
        animateX(if (center < metrics.widthPixels / 2) 0 else metrics.widthPixels - bd)
    }

    /** 5 秒无操作后缩进：只露 16dp，其余藏进屏幕边缘。 */
    private fun autoHideToEdge() {
        val p = bubbleParams ?: return
        val metrics = resources.displayMetrics
        val edgePeek = dp(16)
        val bd = dp(bubbleDp)
        val center = p.x + bd / 2
        val target = if (center < metrics.widthPixels / 2) {
            -bd + edgePeek
        } else {
            metrics.widthPixels - edgePeek
        }
        android.util.Log.i("DSHRemote", "bubble: auto-hide to x=$target")
        animateX(target)
    }

    /** 水平滑动动画（吸附/缩进/滑出统一用）；球移动时气泡同步跟随。 */
    private fun animateX(target: Int) {
        val p = bubbleParams ?: return
        val wm = this.wm ?: return
        val from = p.x
        if (from == target) return
        val anim = android.animation.ValueAnimator.ofInt(from, target)
        anim.duration = 240
        anim.interpolator = android.view.animation.DecelerateInterpolator()
        anim.addUpdateListener {
            p.x = it.animatedValue as Int
            wm.updateViewLayout(bubble, p)
            if (panelVisible) placePanel()
            positionTip() // 气泡跟随球移动（缩进/滑出期间不错位）
        }
        anim.start()
    }

    /** 球是否处于贴边半隐藏状态（x 为负 = 左缩进；右侧越出屏幕 = 右缩进）。
     *  完全露出时 x=0（左）或 x=sw-bd（右，x+bd==sw 正好贴边不算隐藏）。 */
    private fun isEdgeHidden(): Boolean {
        val p = bubbleParams ?: return false
        val metrics = resources.displayMetrics
        val bd = dp(bubbleDp)
        return p.x < -dp(2) || p.x + bd > metrics.widthPixels + dp(2)
    }

    /** 从半隐藏滑出到完全可见。 */
    private fun slideOut() {
        val p = bubbleParams ?: return
        val metrics = resources.displayMetrics
        val bd = dp(bubbleDp)
        animateX(if (p.x < metrics.widthPixels / 2) 0 else metrics.widthPixels - bd)
    }

    // ── 迷你面板（单击展开，球旁小卡片）──
    private fun addPanel() {
        val wm = this.wm ?: return
        val width = dp(248)
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(12), dp(8), dp(12), dp(10))
        root.background = GradientDrawable().apply {
            cornerRadius = dp(14).toFloat()
            setColor(Color.parseColor("#F21A1D24"))
        }
        root.visibility = View.GONE

        // 标题行
        val head = LinearLayout(this)
        head.orientation = LinearLayout.HORIZONTAL
        head.gravity = Gravity.CENTER_VERTICAL
        val title = TextView(this)
        title.text = text("DSH Remote", "DSH Remote")
        title.setTextColor(Color.WHITE)
        title.textSize = 13f
        title.setTypeface(null, android.graphics.Typeface.BOLD)
        head.addView(title, LinearLayout.LayoutParams(0, dp(26), 1f))
        val close = TextView(this)
        close.text = "✕"
        close.setTextColor(Color.parseColor("#9AA3AF"))
        close.textSize = 15f
        close.gravity = Gravity.CENTER
        close.setPadding(dp(8), 0, 0, 0)
        close.setOnClickListener { hidePanel() }
        head.addView(close, LinearLayout.LayoutParams(dp(30), dp(26)))
        root.addView(head)

        // 运行中会话
        val secSessions = sectionLabel(text("运行中的会话", "Active sessions"))
        root.addView(secSessions)
        panelSessionsSec = secSessions
        val sessionsBox = LinearLayout(this)
        sessionsBox.orientation = LinearLayout.VERTICAL
        root.addView(sessionsBox)
        panelSessions = sessionsBox

        // 最近通知（区块头：标题 + 未读徽标 + 查看全部入口）
        val notifHead = LinearLayout(this)
        notifHead.orientation = LinearLayout.HORIZONTAL
        notifHead.gravity = Gravity.CENTER_VERTICAL
        val secNotifs = sectionLabel(text("最近通知", "Notifications"))
        notifHead.addView(secNotifs, LinearLayout.LayoutParams(0, dp(24), 1f))
        val badgeUnread = TextView(this)
        badgeUnread.text = "0"
        badgeUnread.setTextColor(Color.WHITE)
        badgeUnread.textSize = 8.5f
        badgeUnread.gravity = Gravity.CENTER
        badgeUnread.setPadding(dp(3), 0, dp(3), 0)
        badgeUnread.background = GradientDrawable().apply {
            cornerRadius = dp(7).toFloat()
            setColor(Color.parseColor("#E5484D"))
        }
        badgeUnread.visibility = View.GONE
        notifHead.addView(badgeUnread, LinearLayout.LayoutParams(dp(20), dp(14)))
        val viewAll = TextView(this)
        viewAll.text = text("查看全部 →", "View all →")
        viewAll.setTextColor(Color.parseColor("#6C8CFF"))
        viewAll.textSize = 10.5f
        viewAll.setPadding(dp(8), 0, 0, 0)
        viewAll.setOnClickListener { hidePanel(); openNotifs() }
        notifHead.addView(viewAll, LinearLayout.LayoutParams(dp(64), dp(24)))
        root.addView(notifHead)
        panelNotifsSec = notifHead
        panelNotifsBadge = badgeUnread
        val notifsBox = LinearLayout(this)
        notifsBox.orientation = LinearLayout.VERTICAL
        root.addView(notifsBox)
        panelNotifs = notifsBox

        // 底部按钮（浅灰胶囊，与深色弹窗协调）
        val btnRow = LinearLayout(this)
        btnRow.orientation = LinearLayout.HORIZONTAL
        btnRow.gravity = Gravity.CENTER_VERTICAL
        val openBtn = TextView(this)
        openBtn.text = text("打开 App", "Open App")
        openBtn.setTextColor(Color.WHITE)
        openBtn.textSize = 12.5f
        openBtn.gravity = Gravity.CENTER
        openBtn.background = GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(Color.parseColor("#3A3F47"))
        }
        openBtn.setOnClickListener { hidePanel(); openMain() }
        btnRow.addView(openBtn, LinearLayout.LayoutParams(0, dp(36), 1f))
        val chargeBtn = TextView(this)
        chargeBtn.text = text("去充值", "Top up")
        chargeBtn.setTextColor(Color.WHITE)
        chargeBtn.textSize = 12.5f
        chargeBtn.gravity = Gravity.CENTER
        chargeBtn.background = GradientDrawable().apply {
            cornerRadius = dp(20).toFloat()
            setColor(Color.parseColor("#3A3F47"))
        }
        chargeBtn.setOnClickListener { hidePanel(); openCharge() }
        btnRow.addView(chargeBtn, LinearLayout.LayoutParams(0, dp(36), 1f))
        val gap = View(this)
        btnRow.addView(gap, LinearLayout.LayoutParams(dp(8), 1))
        root.addView(btnRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(36)))
        panelCharge = chargeBtn

        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            width, WindowManager.LayoutParams.WRAP_CONTENT, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        wm.addView(root, params)
        panel = root
        panelParams = params
    }

    private fun sectionLabel(t: String): TextView {
        val tv = TextView(this)
        tv.text = t
        tv.setTextColor(Color.parseColor("#9AA3AF"))
        tv.textSize = 10.5f
        tv.setPadding(0, dp(8), 0, dp(3))
        return tv
    }

    private fun togglePanel() {
        if (panelVisible) hidePanel() else showPanel()
    }

    private fun showPanel() {
        val p = panel ?: return
        val pp = panelParams ?: return
        panelVisible = true
        placePanel()
        scrim?.visibility = View.VISIBLE // 拦截面板外点击（透明，不遮挡视觉）
        p.visibility = View.VISIBLE
        // 生长动画：从球方向位移 + 放大 + 淡入（球在左→从左长出，球在上→从上长出）
        val bp = bubbleParams ?: return
        val metrics = resources.displayMetrics
        val dirX = if (bp.x < metrics.widthPixels / 2) -1f else 1f
        val dirY = if (bp.y < metrics.heightPixels / 2) -1f else 1f
        p.translationX = dirX * dp(28).toFloat()
        p.translationY = dirY * dp(16).toFloat()
        p.alpha = 0f
        p.scaleX = 0.9f
        p.scaleY = 0.9f
        p.animate().translationX(0f).translationY(0f).alpha(1f).scaleX(1f).scaleY(1f)
            .setDuration(200)
            .setInterpolator(android.view.animation.DecelerateInterpolator())
            .withEndAction { placePanel() } // 布局完成后按实际高度重新定位
            .start()
        // 逐项浮现：标题/内容/按钮错开淡入上移（stagger）
        val root = p as? LinearLayout
        if (root != null) {
            var i = 0
            for (ci in 0 until root.childCount) {
                val child = root.getChildAt(ci)
                if (child.visibility != View.VISIBLE) continue
                child.alpha = 0f
                child.translationY = dp(8).toFloat()
                child.animate().alpha(1f).translationY(0f)
                    .setStartDelay(60L + i * 40L)
                    .setDuration(160)
                    .start()
                i++
            }
        }
        // 打开面板 = 已读：清红点
        notifCount = 0
        mainHandler.removeCallbacks(clearNotifRunnable)
        mainHandler.post { setState() }
        refreshPanelData()
        // 面板开着期间周期刷新（兜底）
        mainHandler.removeCallbacks(panelRefreshRunnable)
        mainHandler.postDelayed(panelRefreshRunnable, 5000)
    }

    /** 面板贴球展开：随球所在象限选择方向（左上/右上/左下/右下），始终完整在屏内。 */
    private fun placePanel() {
        val pp = panelParams ?: return
        val bp = bubbleParams ?: return
        val wm = this.wm ?: return
        val metrics = resources.displayMetrics
        val pw = dp(248)
        // 用面板实际高度（首次打开前未测量时用估算值）
        val ph = if ((panel?.height ?: 0) > 0) panel!!.height else dp(300)
        val sw = metrics.widthPixels
        val sh = metrics.heightPixels
        val ballRight = bp.x + dp(bubbleDp)
        val ballBottom = bp.y + dp(bubbleDp)
        // 水平：球在左半 → 面板放球右侧；右半 → 面板放球左侧（贴边）
        val onLeftSide = bp.x < sw / 2
        pp.x = if (onLeftSide) ballRight + dp(4) else bp.x - pw - dp(4)
        if (pp.x < 0) pp.x = 0
        if (pp.x + pw > sw) pp.x = sw - pw
        // 垂直：球在上半 → 面板顶部对齐球顶部；下半 → 面板底部对齐球底部
        val onTop = bp.y < sh / 2
        if (onTop) {
            pp.y = bp.y
        } else {
            pp.y = ballBottom - ph
        }
        if (pp.y < dp(40)) pp.y = dp(40)
        if (pp.y + ph > sh) pp.y = sh - ph - dp(20)
        wm.updateViewLayout(panel, pp)
    }

    private fun hidePanel() {
        val p = panel ?: return
        panelVisible = false
        scrim?.visibility = View.GONE
        mainHandler.removeCallbacks(panelRefreshRunnable)
        // 面板关闭后 5 秒无操作自动缩进（球保持可见便于再次操作）
        mainHandler.removeCallbacks(autoHideRunnable)
        mainHandler.postDelayed(autoHideRunnable, 5000)
        // 收起动画：淡出 + 缩小（动画期间若重新打开则不隐藏）
        p.animate().alpha(0f).scaleX(0.9f).scaleY(0.9f).setDuration(120)
            .withEndAction { if (!panelVisible) p.visibility = View.GONE }
            .start()
    }

    /** 事件到达时刷新面板（2 秒节流，面板关闭时 no-op）。 */
    private fun refreshPanelIfOpen() {
        if (!panelVisible) return
        val now = System.currentTimeMillis()
        if (now - lastPanelRefresh < 2000) return
        lastPanelRefresh = now
        mainHandler.post { refreshPanelData() }
    }

    private fun refreshPanelData() {
        Thread({
            try {
                val base = prefs("flutter.dsh_mr_base") ?: return@Thread
                val token = prefs("flutter.dsh_mr_token") ?: return@Thread
                var b = base.trim()
                if (b.endsWith("/")) b = b.dropLast(1)
                if (b.endsWith("/m")) b = b.dropLast(2)

                // 运行中会话（bootstrap agents）
                val running = mutableListOf<Pair<String, String>>()
                try {
                    val conn = URL("$b/m/api/bootstrap").openConnection() as HttpURLConnection
                    conn.connectTimeout = 5000
                    conn.setRequestProperty("x-mobile-token", token)
                    if (conn.responseCode == 200) {
                        val txt = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                        val agents = JSONObject(txt).optJSONArray("agents") ?: JSONArray()
                        for (i in 0 until agents.length()) {
                            val a = agents.optJSONObject(i) ?: continue
                            val st = a.optString("status")
                            if (st == "running" || st == "waiting") {
                                running.add(a.optString("id").replace("session:", "") to st)
                            }
                        }
                    }
                    conn.disconnect()
                } catch (_: Exception) {}

                // 最近通知（标题/未读/时间；字段与插件端 items 一致）
                val notifs = mutableListOf<Map<String, Any>>()
                var unreadCount = 0
                try {
                    val conn = URL("$b/m/api/notifications").openConnection() as HttpURLConnection
                    conn.connectTimeout = 5000
                    conn.setRequestProperty("x-mobile-token", token)
                    if (conn.responseCode == 200) {
                        val txt = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                        val j = JSONObject(txt)
                        val list = j.optJSONArray("items") ?: JSONArray()
                        unreadCount = j.optInt("unread")
                        for (i in 0 until Math.min(3, list.length())) {
                            val n = list.optJSONObject(i) ?: continue
                            notifs.add(mapOf(
                                "title" to n.optString("title").ifEmpty { text("通知", "Notification") },
                                "unread" to n.optBoolean("unread"),
                                "time" to n.optLong("time"),
                            ))
                        }
                    }
                    conn.disconnect()
                } catch (_: Exception) {}

                mainHandler.post {
                    // 面板打开 = 已看：更新未读基线（下次增量从当前起算）
                    lastUnreadCount = unreadCount
                    firstUnreadCheck = false
                    renderPanel(running, notifs, unreadCount)
                }
            } catch (_: Exception) {}
        }, "dsh-bubble-panel").apply { isDaemon = true; start() }
    }

    private fun renderPanel(running: List<Pair<String, String>>, notifs: List<Map<String, Any>>, unreadCount: Int) {
        val box = panelSessions ?: return
        box.removeAllViews()
        val secS = panelSessionsSec
        if (running.isEmpty()) {
            // 无运行中会话 → 整个区块隐藏（不留占位文案）
            secS?.visibility = View.GONE
            box.visibility = View.GONE
        } else {
            secS?.visibility = View.VISIBLE
            box.visibility = View.VISIBLE
            for ((id, st) in running.take(3)) {
                val row = TextView(this)
                val dot = if (st == "waiting") "◉" else "●"
                // id 形如 "session:<uuid>"，去掉前缀显示短码
                val short = id.removePrefix("session:").take(8)
                row.text = "$dot $short"
                row.setTextColor(Color.WHITE)
                row.textSize = 12.5f
                row.setPadding(0, dp(3), 0, dp(3))
                row.setOnClickListener { hidePanel(); openSession(id) }
                box.addView(row)
            }
        }
        val nbox = panelNotifs ?: return
        nbox.removeAllViews()
        val secN = panelNotifsSec
        val badgeN = panelNotifsBadge
        if (notifs.isEmpty()) {
            // 无通知 → 整个区块隐藏
            secN?.visibility = View.GONE
            nbox.visibility = View.GONE
        } else {
            secN?.visibility = View.VISIBLE
            nbox.visibility = View.VISIBLE
            // 未读徽标（与 App 铃铛同源）
            badgeN?.text = if (unreadCount > 99) "99+" else "$unreadCount"
            badgeN?.visibility = if (unreadCount > 0) View.VISIBLE else View.GONE
            for (n in notifs) {
                val unread = n["unread"] as? Boolean ?: false
                val title = n["title"] as? String ?: ""
                val time = (n["time"] as? Number)?.toLong() ?: 0L
                val row = LinearLayout(this)
                row.orientation = LinearLayout.HORIZONTAL
                row.gravity = Gravity.CENTER_VERTICAL
                row.setPadding(0, dp(3), 0, dp(3))
                row.setOnClickListener { hidePanel(); openNotifs() }
                val dot = TextView(this)
                dot.text = if (unread) "●" else "○"
                dot.setTextColor(if (unread) Color.parseColor("#4D6BFE") else Color.parseColor("#5C6470"))
                dot.textSize = 10f
                row.addView(dot, LinearLayout.LayoutParams(dp(16), dp(20)))
                val titleTv = TextView(this)
                titleTv.text = title
                titleTv.setTextColor(if (unread) Color.WHITE else Color.parseColor("#B4BCC6"))
                titleTv.textSize = 12f
                titleTv.maxLines = 1
                titleTv.ellipsize = android.text.TextUtils.TruncateAt.END
                row.addView(titleTv, LinearLayout.LayoutParams(0, dp(20), 1f))
                val timeTv = TextView(this)
                timeTv.text = relTime(time)
                timeTv.setTextColor(Color.parseColor("#5C6470"))
                timeTv.textSize = 10f
                row.addView(timeTv, LinearLayout.LayoutParams(dp(52), dp(20)))
                nbox.addView(row)
            }
        }
        panelCharge?.visibility = View.VISIBLE // 充值按钮常显（余额低时红色强调，见 renderPanel）
        if (lowBalance) {
            (panelCharge as? TextView)?.background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                setColor(Color.parseColor("#E5484D"))
            }
        } else {
            (panelCharge as? TextView)?.background = GradientDrawable().apply {
                cornerRadius = dp(20).toFloat()
                setColor(Color.parseColor("#3A3F47"))
            }
        }
    }

    // ── 状态渲染 ──
    private fun setState() {
        val img = logoImg ?: return
        if (agentsRunning || lowBalance || notifCount > 0) {
            // 亮态：原色 + 过渡到全不透明
            animateAlpha(img, 1f)
            img.setGray(false)
        } else {
            // 暗态：灰度 + 过渡到半透明（亮暗切换不瞬变）
            animateAlpha(img, 0.55f)
            img.setGray(true)
        }
        val bd = badge ?: return
        if (notifCount > 0) {
            bd.text = if (notifCount > 99) "99+" else "$notifCount"
            bd.visibility = View.VISIBLE
        } else {
            bd.visibility = View.GONE
        }
    }

    /** 亮度过渡（180ms）：亮/暗切换不瞬变。 */
    private fun animateAlpha(view: View, target: Float) {
        if (view.alpha == target) return
        val anim = android.animation.ValueAnimator.ofFloat(view.alpha, target)
        anim.duration = 180
        anim.addUpdateListener { view.alpha = it.animatedValue as Float }
        anim.start()
    }

    /** 通知红点：同 key 5 秒内合并（SSE 回放/重复事件防抖），60 秒后自动消退。 */
    private fun markNotif(key: String, text: String) {
        val now = System.currentTimeMillis()
        if (key == lastNotifKey && now - lastNotifAt < 5000) return
        lastNotifKey = key
        lastNotifAt = now
        notifCount++
        lastNotif = now
        mainHandler.post { setState(); showTip(text) }
        // 红点 60 秒后自动消退（用户没看也不残留）
        mainHandler.removeCallbacks(clearNotifRunnable)
        mainHandler.postDelayed(clearNotifRunnable, 60000)
    }

    private val clearNotifRunnable = Runnable {
        notifCount = 0
        mainHandler.post { setState() }
    }

    // ── SSE：自己连插件事件流 ──
    private fun startSse() {
        sseAlive = true
        sseThread = Thread({
            var backoff = 1000L
            while (sseAlive) {
                try {
                    connectSse()
                } catch (e: Exception) {
                    // 网络/解析错误：退避重连
                }
                if (!sseAlive) break
                Thread.sleep(backoff)
                backoff = (backoff * 2).coerceAtMost(30000)
            }
        }, "dsh-bubble-sse").apply { isDaemon = true; start() }
    }

    private fun connectSse(): Boolean {
        val base = prefs("flutter.dsh_mr_base") ?: return true
        val token = prefs("flutter.dsh_mr_token") ?: return true
        var baseUrl = base.trim()
        if (baseUrl.endsWith("/")) baseUrl = baseUrl.dropLast(1)
        if (baseUrl.endsWith("/m")) baseUrl = baseUrl.dropLast(2)
        val url = URL("$baseUrl/m/api/events")
        val conn = url.openConnection() as HttpURLConnection
        conn.connectTimeout = 8000
        conn.readTimeout = 0
        conn.setRequestProperty("x-mobile-token", token)
        conn.setRequestProperty("Accept", "text/event-stream")
        val code = conn.responseCode
        if (code != 200) {
            conn.disconnect()
            return false
        }
        val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
        var line: String?
        while (sseAlive) {
            line = reader.readLine() ?: break
            if (!line.startsWith("data: ")) continue
            val data = line.removePrefix("data: ")
            try {
                handleFrame(JSONObject(data))
            } catch (_: Exception) {
            }
        }
        runCatching { reader.close() }
        conn.disconnect()
        return false
    }

    private fun handleFrame(o: JSONObject) {
        when (o.optString("type")) {
            "session/event" -> handleSessionEvent(o)
            "session/jobs" -> handleJobs(o)
            "mobile/frame" -> {
                val f = o.optJSONObject("frame") ?: return
                val ft = f.optString("type")
                if (ft == "question/requested" || ft == "approval/requested") {
                    markNotif("frame-${f.optString("rpcId")}", text("需要你回答", "Your input needed"))
                }
            }
        }
    }

    private fun handleSessionEvent(o: JSONObject) {
        val ev = o.optJSONObject("event") ?: return
        val type = ev.optString("type")
        when {
            // 轮次开始/工具/思考 → 亮（轮次边界驱动，不靠超时猜，避免时亮时暗）
            type == "turn/start" ||
                type.contains("tool/") || type == "thinking/start" ||
                type == "agent/status" && ev.optJSONObject("data")?.optString("status") == "running" -> {
                agentsRunning = true
                lastActivity = System.currentTimeMillis()
                mainHandler.post { setState() }
            }
            type == "turn/end" -> {
                val data = ev.optJSONObject("data") ?: JSONObject()
                val reason = data.optJSONObject("reason")
                val kind = reason?.optString("kind") ?: ""
                // 轮次结束即提醒（红点+气泡）；同类 5 秒防抖合并、红点 60 秒自动消退，不残留
                if (kind == "completed") markNotif("turn-completed", text("任务完成", "Task done"))
                else if (kind == "failed" || kind == "error") markNotif("task-failed", text("任务失败", "Task failed"))
                else if (kind == "needs-answer") markNotif("needs-answer", text("需要你回答", "Your input needed"))
                // 轮次结束 → 回到暗态（无通知时）；等下一轮 turn/start 再亮
                agentsRunning = false
                lastActivity = System.currentTimeMillis()
                mainHandler.post { setState() }
            }
        }
        // 面板打开时即时刷新（会话状态变化同步）
        refreshPanelIfOpen()
    }

    private fun handleJobs(o: JSONObject) {
        val jobs = o.optJSONArray("jobs") ?: return
        var running = false
        var notified = false
        val replay = firstJobsFrame
        firstJobsFrame = false
        for (i in 0 until jobs.length()) {
            val j = jobs.optJSONObject(i) ?: continue
            val st = j.optString("status")
            val id = j.optString("id")
            if (st == "running" || st == "stopping") running = true
            // 任务终态：每个 job 只通知一次；连接回放帧只学习不通知（避免重启后误报历史任务）
            if ((st == "completed" || st == "failed") && id.isNotEmpty() && seenJobs.add(id) && !replay) {
                markNotif("job-$id", if (st == "completed") text("任务完成", "Task done") else text("任务失败", "Task failed"))
                notified = true
            }
        }
        agentsRunning = running
        if (running) {
            lastActivity = System.currentTimeMillis()
            mainHandler.post { setState() }
        } else if (notified) {
            mainHandler.post { setState() }
        }
        // 面板打开时即时刷新
        refreshPanelIfOpen()
    }

    /** 余额联动：App 侧刷新余额后经 channel 推送（string "total:currency"）。 */
    private fun onBalance(s: String) {
        val parts = s.split(":")
        val total = parts.firstOrNull()?.toDoubleOrNull() ?: return
        lowBalance = total < 10.0
        mainHandler.post {
            setState()
            if (lowBalance) showTip(text("余额不足 ¥" + String.format("%.1f", total) + "，点我去充值", "Low balance ¥" + String.format("%.1f", total) + " — tap to top up"))
        }
    }

    // ── 动作 ──
    private fun openMain() {
        val i = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        startActivity(i)
    }

    private fun openSession(sessionId: String) {
        val i = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("open_session", sessionId)
        startActivity(i)
    }

    private fun openCharge() {
        val i = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("open_charge", true)
        startActivity(i)
    }

    /** 打开 App 通知页（MainActivity extra，Flutter 侧处理）。 */
    private fun openNotifs() {
        val i = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .putExtra("open_notifs", true)
        startActivity(i)
    }

    /** 相对时间：刚刚 / N 分钟前 / N 小时前 / 日期。 */
    private fun relTime(ms: Long): String {
        if (ms <= 0) return ""
        val diff = System.currentTimeMillis() - ms
        val min = diff / 60000
        return when {
            min < 1 -> text("刚刚", "now")
            min < 60 -> text("${min}分钟前", "${min}m")
            min < 1440 -> text("${min / 60}小时前", "${min / 60}h")
            else -> {
                val d = java.util.Calendar.getInstance().apply { timeInMillis = ms }
                String.format("%02d-%02d", d.get(java.util.Calendar.MONTH) + 1, d.get(java.util.Calendar.DAY_OF_MONTH))
            }
        }
    }

    /** 未读增量对比：重连/离线期间新增的通知也能提示（不只靠实时事件）。 */
    private fun checkUnreadDelta() {
        if (panelVisible) return // 面板开着=正在看，不打扰
        Thread({
            try {
                val base = prefs("flutter.dsh_mr_base") ?: return@Thread
                val token = prefs("flutter.dsh_mr_token") ?: return@Thread
                var b = base.trim()
                if (b.endsWith("/")) b = b.dropLast(1)
                if (b.endsWith("/m")) b = b.dropLast(2)
                val conn = URL("$b/m/api/notifications").openConnection() as HttpURLConnection
                conn.connectTimeout = 5000
                conn.setRequestProperty("x-mobile-token", token)
                var unread = 0
                if (conn.responseCode == 200) {
                    val txt = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                    unread = JSONObject(txt).optInt("unread")
                }
                conn.disconnect()
                val u = unread
                mainHandler.post {
                    if (firstUnreadCheck) {
                        // 首次（服务启动）：只记录基线，不提示存量
                        firstUnreadCheck = false
                        lastUnreadCount = u
                        return@post
                    }
                    if (u > lastUnreadCount) {
                        val diff = u - lastUnreadCount
                        // 防抖：事件驱动刚提示过（60 秒内）则只更新基线，避免重复气泡
                        if (System.currentTimeMillis() - lastNotifAt > 60000) {
                            markNotif("unread-delta", text("有 $diff 条新通知", "$diff new notification" + if (diff > 1) "s" else ""))
                        }
                        lastUnreadCount = u
                    } else {
                        lastUnreadCount = u
                    }
                }
            } catch (_: Exception) {}
        }, "dsh-bubble-unread").apply { isDaemon = true; start() }
    }

    private fun exitBubble(why: String) {
        stopSelf()
    }

    private fun prefs(key: String): String? {
        val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return sp.getString(key, null)
    }

    private fun text(zh: String, en: String): String {
        val lang = prefs("flutter.dsh_mr_language") ?: "zh"
        return if (lang == "en") en else zh
    }

    private fun dp(v: Float): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()
    private fun dp(v: Int): Int = dp(v.toFloat())
}
