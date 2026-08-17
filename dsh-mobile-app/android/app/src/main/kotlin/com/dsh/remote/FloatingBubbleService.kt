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
import android.widget.ProgressBar
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
    private var logoImg: ImageView? = null
    private var badge: TextView? = null
    private var spinner: ProgressBar? = null
    private var tip: TextView? = null
    private var tipParams: WindowManager.LayoutParams? = null

    // 迷你面板
    private var panel: View? = null
    private var panelParams: WindowManager.LayoutParams? = null
    private var panelSessions: LinearLayout? = null
    private var panelNotifs: LinearLayout? = null
    private var panelEmpty: TextView? = null
    private var panelCharge: View? = null
    private var panelVisible = false

    private var sseThread: Thread? = null
    @Volatile private var sseAlive = false
    @Volatile private var agentsRunning = false
    @Volatile private var lowBalance = false
    private var notifCount = 0
    private var lastActivity = 0L
    private var lastNotif = 0L
    private var bubbleDp = 52

    // 拖动/点击判定
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var moved = false
    private var lastTap = 0L
    private val longPressRunnable = Runnable { exitBubble("long-press") }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        createChannel()
        startForeground(NOTIF_ID, buildNotification())
        addBubble()
        addTipView()
        addPanel()
        startSse()
    }

    override fun onDestroy() {
        running = false
        sseAlive = false
        sseThread?.interrupt()
        mainHandler.removeCallbacksAndMessages(null)
        bubble?.let { runCatching { wm?.removeView(it) } }
        tip?.let { runCatching { wm?.removeView(it) } }
        panel?.let { runCatching { wm?.removeView(it) } }
        bubble = null; tip = null; panel = null
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
    private fun addBubble() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        this.wm = wm
        val size = dp(bubbleDp)
        val root = FrameLayout(this)
        root.layoutParams = FrameLayout.LayoutParams(size, size)

        val img = ImageView(this)
        img.setImageResource(R.drawable.deepseek_logo)
        img.scaleType = ImageView.ScaleType.FIT_CENTER
        img.setPadding(dp(4), dp(4), dp(4), dp(4))
        // 圆形裁剪：白底蓝鲸 logo 圆形展示（官方 App 图标样式），无方块底
        img.outlineProvider = object : ViewOutlineProvider() {
            override fun getOutline(view: View, outline: Outline) {
                outline.setOval(0, 0, view.width, view.height)
            }
        }
        img.clipToOutline = true
        img.background = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.WHITE)
        }
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

        val sp = ProgressBar(this, null, android.R.attr.progressBarStyleSmall)
        sp.visibility = View.GONE
        root.addView(sp, FrameLayout.LayoutParams(dp(22), dp(22), Gravity.CENTER))

        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            size, size, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        params.x = dp(20)
        params.y = dp(240)
        wm.addView(root, params)

        val gd = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                togglePanel()
                return true
            }
            override fun onDoubleTap(e: MotionEvent): Boolean {
                hidePanel()
                openMain()
                return true
            }
            override fun onLongPress(e: MotionEvent) {
                exitBubble("long-press")
            }
        })
        root.setOnTouchListener { v, ev ->
            gd.onTouchEvent(ev)
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = ev.rawX; downY = ev.rawY
                    startX = params.x; startY = params.y
                    moved = false
                    mainHandler.postDelayed(longPressRunnable, 600)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downX; val dy = ev.rawY - downY
                    if (Math.abs(dx) > dp(6f) || Math.abs(dy) > dp(6f)) {
                        moved = true
                        mainHandler.removeCallbacks(longPressRunnable)
                    }
                    if (moved) {
                        params.x = startX + dx.toInt()
                        params.y = startY + dy.toInt()
                        wm.updateViewLayout(root, params)
                        // 拖动时收起面板
                        if (panelVisible) hidePanel()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    mainHandler.removeCallbacks(longPressRunnable)
                    if (moved) snapToEdge()
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    mainHandler.removeCallbacks(longPressRunnable)
                    true
                }
                else -> false
            }
        }
        bubble = root
        bubbleParams = params
        logoImg = img
        badge = bd
        spinner = sp
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
        val p = tipParams ?: return
        val bp = bubbleParams ?: return
        p.x = bp.x
        p.y = bp.y - dp(60)
        tv.text = text
        tv.visibility = View.VISIBLE
        wm?.updateViewLayout(tv, p)
        mainHandler.removeCallbacks(hideTipRunnable)
        mainHandler.postDelayed(hideTipRunnable, 5000)
    }

    private val hideTipRunnable = Runnable { tip?.visibility = View.GONE }

    private fun snapToEdge() {
        val p = bubbleParams ?: return
        val wm = this.wm ?: return
        val metrics = resources.displayMetrics
        val right = metrics.widthPixels - dp(bubbleDp)
        p.x = if (p.x < metrics.widthPixels / 2) 0 else right
        wm.updateViewLayout(bubble, p)
        if (panelVisible) placePanel()
    }

    // ── 迷你面板（单击展开，球旁小卡片）──
    private fun addPanel() {
        val wm = this.wm ?: return
        val width = dp(300)
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(14), dp(10), dp(14), dp(10))
        root.background = GradientDrawable().apply {
            cornerRadius = dp(16).toFloat()
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
        title.textSize = 14f
        title.setTypeface(null, android.graphics.Typeface.BOLD)
        head.addView(title, LinearLayout.LayoutParams(0, dp(30), 1f))
        val close = TextView(this)
        close.text = "✕"
        close.setTextColor(Color.parseColor("#9AA3AF"))
        close.textSize = 16f
        close.gravity = Gravity.CENTER
        close.setPadding(dp(8), 0, 0, 0)
        close.setOnClickListener { hidePanel() }
        head.addView(close, LinearLayout.LayoutParams(dp(32), dp(30)))
        root.addView(head)

        // 运行中会话
        val secSessions = sectionLabel(text("运行中的会话", "Active sessions"))
        root.addView(secSessions)
        val sessionsBox = LinearLayout(this)
        sessionsBox.orientation = LinearLayout.VERTICAL
        root.addView(sessionsBox)
        panelSessions = sessionsBox

        // 最近通知
        val secNotifs = sectionLabel(text("最近通知", "Recent notifications"))
        root.addView(secNotifs)
        val notifsBox = LinearLayout(this)
        notifsBox.orientation = LinearLayout.VERTICAL
        root.addView(notifsBox)
        panelNotifs = notifsBox

        val empty = TextView(this)
        empty.text = text("暂无", "None")
        empty.setTextColor(Color.parseColor("#9AA3AF"))
        empty.textSize = 12f
        empty.setPadding(0, dp(4), 0, dp(8))
        root.addView(empty)
        panelEmpty = empty

        // 底部按钮
        val btnRow = LinearLayout(this)
        btnRow.orientation = LinearLayout.HORIZONTAL
        btnRow.gravity = Gravity.CENTER_VERTICAL
        val openBtn = TextView(this)
        openBtn.text = text("打开 App", "Open App")
        openBtn.setTextColor(Color.WHITE)
        openBtn.textSize = 12.5f
        openBtn.gravity = Gravity.CENTER
        openBtn.background = GradientDrawable().apply {
            cornerRadius = dp(9).toFloat()
            setColor(Color.parseColor("#4D6BFE"))
        }
        openBtn.setOnClickListener { hidePanel(); openMain() }
        btnRow.addView(openBtn, LinearLayout.LayoutParams(0, dp(38), 1f))
        val chargeBtn = TextView(this)
        chargeBtn.text = text("去充值", "Top up")
        chargeBtn.setTextColor(Color.WHITE)
        chargeBtn.textSize = 12.5f
        chargeBtn.gravity = Gravity.CENTER
        chargeBtn.background = GradientDrawable().apply {
            cornerRadius = dp(9).toFloat()
            setColor(Color.parseColor("#E5484D"))
        }
        chargeBtn.setOnClickListener { hidePanel(); openCharge() }
        btnRow.addView(chargeBtn, LinearLayout.LayoutParams(0, dp(38), 1f))
        val gap = View(this)
        btnRow.addView(gap, LinearLayout.LayoutParams(dp(8), 1))
        root.addView(btnRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(38)))
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
        val bp = bubbleParams ?: return
        panelVisible = true
        placePanel()
        p.visibility = View.VISIBLE
        wm?.updateViewLayout(p, pp)
        // 刷新面板数据（异步）
        refreshPanelData()
    }

    private fun placePanel() {
        val pp = panelParams ?: return
        val bp = bubbleParams ?: return
        val wm = this.wm ?: return
        val metrics = resources.displayMetrics
        val pw = dp(300)
        // 球在左半边 → 面板放球右侧；否则放球左侧
        val onLeft = bp.x < metrics.widthPixels / 2
        pp.x = if (onLeft) bp.x + dp(bubbleDp) + dp(4) else bp.x - pw - dp(4)
        if (pp.x < 0) pp.x = 0
        if (pp.x + pw > metrics.widthPixels) pp.x = metrics.widthPixels - pw
        pp.y = bp.y - dp(40)
        if (pp.y < dp(60)) pp.y = dp(60)
        wm.updateViewLayout(panel, pp)
    }

    private fun hidePanel() {
        panelVisible = false
        panel?.visibility = View.GONE
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

                // 最近通知
                val notifs = mutableListOf<String>()
                try {
                    val conn = URL("$b/m/api/notifications").openConnection() as HttpURLConnection
                    conn.connectTimeout = 5000
                    conn.setRequestProperty("x-mobile-token", token)
                    if (conn.responseCode == 200) {
                        val txt = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                        val list = JSONObject(txt).optJSONArray("notifications") ?: JSONArray()
                        for (i in 0 until Math.min(3, list.length())) {
                            val n = list.optJSONObject(i) ?: continue
                            notifs.add(n.optString("title").ifEmpty { text("通知", "Notification") })
                        }
                    }
                    conn.disconnect()
                } catch (_: Exception) {}

                mainHandler.post { renderPanel(running, notifs) }
            } catch (_: Exception) {}
        }, "dsh-bubble-panel").apply { isDaemon = true; start() }
    }

    private fun renderPanel(running: List<Pair<String, String>>, notifs: List<String>) {
        val box = panelSessions ?: return
        box.removeAllViews()
        if (running.isEmpty()) {
            val tv = TextView(this)
            tv.text = text("暂无运行中的会话", "No active sessions")
            tv.setTextColor(Color.parseColor("#9AA3AF"))
            tv.textSize = 12f
            tv.setPadding(0, dp(2), 0, dp(4))
            box.addView(tv)
        } else {
            for ((id, st) in running.take(3)) {
                val row = TextView(this)
                val dot = if (st == "waiting") "◉" else "●"
                val name = if (id.length >= 8) id.substring(0, 8) else id
                row.text = "$dot $name"
                row.setTextColor(Color.WHITE)
                row.textSize = 12.5f
                row.setPadding(0, dp(3), 0, dp(3))
                row.setOnClickListener { hidePanel(); openSession(id) }
                box.addView(row)
            }
        }
        val nbox = panelNotifs ?: return
        nbox.removeAllViews()
        if (notifs.isEmpty()) {
            val tv = TextView(this)
            tv.text = text("暂无通知", "No notifications")
            tv.setTextColor(Color.parseColor("#9AA3AF"))
            tv.textSize = 12f
            tv.setPadding(0, dp(2), 0, dp(4))
            nbox.addView(tv)
        } else {
            for (t in notifs) {
                val row = TextView(this)
                row.text = "• $t"
                row.setTextColor(Color.parseColor("#DDE1E6"))
                row.textSize = 12f
                row.setPadding(0, dp(3), 0, dp(3))
                row.maxLines = 1
                row.ellipsize = android.text.TextUtils.TruncateAt.END
                nbox.addView(row)
            }
        }
        panelEmpty?.visibility = View.GONE
        panelCharge?.visibility = if (lowBalance) View.VISIBLE else View.GONE
        if (!lowBalance) {
            // 不显示去充值按钮时，打开按钮占满
            panelCharge?.layoutParams = LinearLayout.LayoutParams(0, dp(38), 1f)
        }
    }

    // ── 状态渲染 ──
    private fun setState() {
        val img = logoImg ?: return
        if (agentsRunning || lowBalance || notifCount > 0) {
            // 亮态：原色
            img.alpha = 1f
            img.colorFilter = null
        } else {
            // 暗态：灰度 + 半透明
            img.alpha = 0.45f
            img.colorFilter = android.graphics.ColorMatrixColorFilter(
                android.graphics.ColorMatrix().apply { setSaturation(0f) })
        }
        val bd = badge ?: return
        if (notifCount > 0) {
            bd.text = if (notifCount > 99) "99+" else "$notifCount"
            bd.visibility = View.VISIBLE
        } else {
            bd.visibility = View.GONE
        }
        val sp = spinner ?: return
        sp.visibility = if (agentsRunning) View.VISIBLE else View.GONE
    }

    private fun markNotif(text: String) {
        notifCount++
        lastNotif = System.currentTimeMillis()
        mainHandler.post { setState(); showTip(text) }
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
                    markNotif(text("需要你回答", "Your input needed"))
                }
            }
        }
    }

    private fun handleSessionEvent(o: JSONObject) {
        val ev = o.optJSONObject("event") ?: return
        val type = ev.optString("type")
        when {
            type.contains("tool/") || type == "thinking/start" || type == "turn/start" ||
                type == "agent/status" && ev.optJSONObject("data")?.optString("status") == "running" -> {
                agentsRunning = true
                lastActivity = System.currentTimeMillis()
                mainHandler.post { setState() }
            }
            type == "turn/end" -> {
                val data = ev.optJSONObject("data") ?: JSONObject()
                val reason = data.optJSONObject("reason")
                val kind = reason?.optString("kind") ?: ""
                if (kind == "completed") markNotif(text("任务完成", "Task done"))
                else if (kind == "failed" || kind == "error") markNotif(text("任务失败", "Task failed"))
                else if (kind == "needs-answer") markNotif(text("需要你回答", "Your input needed"))
                lastActivity = System.currentTimeMillis()
                mainHandler.removeCallbacks(idleCheckRunnable)
                mainHandler.postDelayed(idleCheckRunnable, 3000)
            }
        }
    }

    private val idleCheckRunnable = Runnable {
        if (System.currentTimeMillis() - lastActivity > 3000 && notifCount == 0 && !lowBalance) {
            agentsRunning = false
            mainHandler.post { setState() }
        }
    }

    private fun handleJobs(o: JSONObject) {
        val jobs = o.optJSONArray("jobs") ?: return
        var running = false
        var done = false
        for (i in 0 until jobs.length()) {
            val j = jobs.optJSONObject(i) ?: continue
            val st = j.optString("status")
            if (st == "running" || st == "stopping") running = true
            if (st == "completed" || st == "failed") done = true
        }
        agentsRunning = running
        lastActivity = System.currentTimeMillis()
        if (running) {
            mainHandler.post { setState() }
        } else if (done) {
            markNotif(text("任务完成", "Task done"))
            mainHandler.post { setState() }
        }
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
