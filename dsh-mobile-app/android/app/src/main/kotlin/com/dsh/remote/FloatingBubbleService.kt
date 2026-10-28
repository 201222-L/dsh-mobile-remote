package com.dsh.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
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
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale

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
    private var petView: PetView? = null
    private var petManifest: PetManifest? = null
    private var petModel: PetAnimationModel? = null
    private val petReducer = PetStateReducer()
    private var petHeightDp = 96
    private var petReducedMotion = false
    private var petEdgeHide = true
    private var petRenderedVersion = -1L
    private var petLastClip: String? = null
    private var petTucked = false
    private var petIdleNextAt = 0L
    private var petStatusShownAt = 0L
    private var petStatusState = ""
    private var latestSessionTitle: String? = null
    private var latestProgress: Pair<Int, Int>? = null
    private var badge: TextView? = null
    private var tip: LinearLayout? = null
    private var tipTitle: TextView? = null
    private var tipDetail: TextView? = null
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
    private var panelBalance: TextView? = null
    private var panelStatus: TextView? = null
    private var panelExit: TextView? = null
    // 用量与额度区块（v3.2）：展开面板时按需获取 + 客户端节流；
    // 不可用时整块消失，降级为上方/下方单行余额（点击语义不变）。
    private var panelUsage: LinearLayout? = null
    private var panelUsageRows: LinearLayout? = null
    private var panelUsageStale: TextView? = null
    // 用量与额度取数状态（线程间仅 volatile；渲染一律走 mainHandler.post/renderUsageBlock）
    @Volatile private var allowancePayload: org.json.JSONObject? = null
    @Volatile private var allowanceFetchedAt = 0L
    @Volatile private var allowanceFetching = false
    @Volatile private var allowanceLastFetchStart = 0L
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
    // v2.7.2 review(FS2)：持有当前 SSE 连接，onDestroy 时 disconnect 解除 readLine 阻塞
    @Volatile private var sseConn: java.net.HttpURLConnection? = null
    @Volatile private var agentsRunning = false
    @Volatile private var lowBalance = false
    @Volatile private var balanceTotal: Double? = null // 最近一次余额（面板常驻显示）
    // 余额预警（v2.7.1）：判定完全以 App 端推送的配置为准；报警为事件式（亮 60s 消退，不常亮）
    @Volatile private var alertEnabled = false
    @Volatile private var alertThreshold = 10.0
    @Volatile private var balanceAlerting = false // 事件式亮起中（60s 自动消退）
    private var lastBalanceAlertAt = 0L // 上次报警时间（30 分钟防抖）
    // v3.0.0：以下字段仅 mainHandler 线程读写（markNotif 统一 mainHandler.post）——消除 SSE
    // 线程与主线程并发导致 notifCount 丢失/去重误判的竞态
    private var notifCount = 0
    private var lastActivity = 0L
    private var lastNotif = 0L
    private var lastNotifKey = ""
    private var lastNotifAt = 0L
    @Volatile private var firstJobsFrame = true // 首个 jobs 帧是连接回放：只学习不通知
    // v2.7.2 review：已弹通知 id 集合（去重，上限 200）
    private val seenNotifIds = java.util.LinkedHashSet<String>()

    // v2.7.2：屏幕尺寸与贴边状态跟踪（旋转后按新尺寸重贴边）
    private var lastScreenW = 0
    private var lastScreenH = 0
    private var edgeSide = 1 // 贴边目标侧：-1 左 / +1 右
    private var edgeHidden = false // 是否处于贴边半隐藏缩进态
    private var lastRenderX = 0 // 最近一次稳定位置的渲染 x（旋转判断贴左/贴右用）

    // 未读增量对比（补"事件驱动之外的提示"：重连窗口/离线期间新增的通知）
    private var lastUnreadCount = 0
    private var firstUnreadCheck = true // 首次检查只记录基线，不提示存量
    /** 每 60 秒对比未读数，增量则提示（防抖：最近 60 秒已提示过则只更新基线）。
     *  v2.7.2 review(M3)：顺带做运行状态超时回落——漏收 turn/end（断档）时球不再永远亮着。 */
    private val unreadCheckRunnable: Runnable = object : Runnable {
        override fun run() {
            checkUnreadDelta()
            // 5 分钟无任何活动且无通知 → 回暗态（兜底：事件断档时球不常亮）
            if (agentsRunning && notifCount == 0 && System.currentTimeMillis() - lastActivity > 5 * 60 * 1000L) {
                agentsRunning = false
                applyPetChange(petReducer.onAgentStatus("idle", false))
            }
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
    /** 贴边后 5 秒无操作才缩进（用户反馈：松手立即缩进导致点击不稳定）。 */
    private val autoHideRunnable = Runnable { autoHideToEdge() }
    /** 宠物脉冲/overlay 终点与空闲微动作调度（250ms 一次，不逐帧驱动）。 */
    private val petTickRunnable = object : Runnable {
        override fun run() {
            if (petModel == null) return
            val now = System.currentTimeMillis()
            if (petModel?.tick(now) == true) renderPet(animate = true)
            maybePlayIdleMicro(now)
            mainHandler.postDelayed(this, 250)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        running = true
        petHeightDp = prefsInt("flutter.dsh_mr_pet_height", 96).coerceIn(56, 160)
        petReducedMotion = prefsBool("flutter.dsh_mr_pet_reduced_motion", false)
        petEdgeHide = prefsBool("flutter.dsh_mr_pet_edge_hide", true)
        createChannel()
        // v2.9.0 review(A1)：Android 14+ 显式传 FGS 类型（SPECIAL_USE，manifest 已声明子类型；
        // 2 参形式已废弃且依赖 manifest 推断）。低版本不识别 SPECIAL_USE 位 → 保持 2 参。
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, buildNotification(), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIF_ID, buildNotification())
        }
        addPet()
        addStatusBubble()
        showStatus(PetCopy.onboarding(language()), statusDetail(), 6000, false)
        addScrim()   // z 序：宠物 < 状态气泡 < scrim < 面板
        addPanel()
        startSse()
        // 余额定时自查（30 分钟一次，不依赖 App 打开设置页触发）
        mainHandler.postDelayed(balanceCheckRunnable, 30 * 60 * 1000L)
        // 未读增量对比（60 秒一次，补重连/离线期间的通知提示）
        mainHandler.postDelayed(unreadCheckRunnable, 20000)
        // 宠物 pulse / overlay 终点与空闲微动作
        mainHandler.postDelayed(petTickRunnable, 250)
        petIdleNextAt = System.currentTimeMillis() + randomIdleInterval()
    }

    /** 余额自查：每 30 分钟拉一次 /m/api/balance，低余额时亮起 + 气泡 + 面板按钮变红。 */
    private val balanceCheckRunnable: Runnable = object : Runnable {
        override fun run() {
            Thread({
                try {
                    val txt = httpGet("balance", 8000) ?: return@Thread
                    // v3.2：CNY 优先（与详情页同口径），修掉旧 balance_infos[0] 位置取值
                    val v = UsagePanelModel.deepseekBalanceFromBalancePayload(txt) ?: 0.0
                    if (v > 0) onBalance("$v:")
                } catch (_: Exception) {
                    // v2.8.0 review：httpGet 只吞网络/HTTP 异常，200 但畸形响应体的 JSONException 需在此兜底
                }
            }, "dsh-bubble-balance").start()
            mainHandler.postDelayed(this, 30 * 60 * 1000L)
        }
    }

    override fun onDestroy() {
        running = false
        sseAlive = false
        // v2.7.2 review(FS2/FS4)：interrupt 对阻塞在 socket readLine 的线程无效——
        // 必须 disconnect 连接才能解除阻塞；动画也要取消，否则下一帧 updateViewLayout
        // 操作已移除的视图 → IllegalArgumentException 崩溃
        runCatching { sseConn?.disconnect() }
        sseConn = null
        sseThread?.interrupt()
        bubbleAnim?.cancel()
        bubbleAnim = null
        // v3.0.0：面板展开/收起是 ViewPropertyAnimator（Choreographer 驱动，removeCallbacksAndMessages
        // 取消不了），销毁时显式取消——配 placePanel 判空双保险，杜绝 after-destroy NPE
        panel?.let { runCatching { it.animate().cancel() } }
        petView?.release()
        petView = null
        mainHandler.removeCallbacksAndMessages(null)
        bubble?.let { runCatching { wm?.removeView(it) } }
        tip?.let { runCatching { wm?.removeView(it) } }
        panel?.let { runCatching { wm?.removeView(it) } }
        scrim?.let { runCatching { wm?.removeView(it) } }
        bubble = null; tip = null; panel = null; panelParams = null; scrim = null
        petModel = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.getStringExtra("balance")?.let { onBalance(it) }
        // 余额预警配置（App 端推送：开关 + 阈值，宠物面板的充值按钮以此为准）
        intent?.getBooleanExtra("alert_enabled", alertEnabled)?.let { alertEnabled = it }
        intent?.getDoubleExtra("alert_threshold", alertThreshold)?.let { alertThreshold = it }
        if (intent?.hasExtra("pet_height") == true) {
            val next = intent.getIntExtra("pet_height", petHeightDp).coerceIn(56, 160)
            if (next != petHeightDp) {
                petHeightDp = next
                resizePet()
            }
        }
        if (intent?.hasExtra("pet_reduced_motion") == true) {
            petReducedMotion = intent.getBooleanExtra("pet_reduced_motion", false)
            petView?.setAnimationRunning(!petReducedMotion && !petTucked)
        }
        if (intent?.hasExtra("pet_edge_hide") == true) {
            petEdgeHide = intent.getBooleanExtra("pet_edge_hide", true)
            if (!petEdgeHide && petTucked) slideOut()
        }
        // NOT_STICKY：只有用户主动开开关才启动；App 被杀/覆盖安装后系统不自动复活
        // （修复：设置页开关是"关"但宠物却出现的现象）
        return START_NOT_STICKY
    }

    // ── 前台通知 ──
    private fun createChannel() {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val ch = NotificationChannel(CHANNEL_ID, "DSH Remote 桌面宠物", NotificationManager.IMPORTANCE_LOW)
        ch.setShowBadge(false)
        nm.createNotificationChannel(ch)
    }

    private fun buildNotification(): Notification {
        // Phase 2(K3)：Intent 构造与 openApp 共用（mainIntent 收敛）
        val pi = PendingIntent.getActivity(this, 0, mainIntent(), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(text("DSH Remote 桌面宠物运行中", "DSH Remote pet is running"))
            .setContentText(text("点击回到 App", "Tap to open the app"))
            .setSmallIcon(R.drawable.deepseek_logo)
            .setContentIntent(pi)
            .setOngoing(true)
            .build()
    }

    /** 当前屏幕尺寸（v2.7.2，API 30+ 用 currentWindowMetrics——旋转后最可靠）。 */
    private fun screenSize(): android.graphics.Point {
        val wm = this.wm
        if (wm != null && Build.VERSION.SDK_INT >= 30) {
            val b = wm.currentWindowMetrics.bounds
            return android.graphics.Point(b.width(), b.height())
        }
        return android.graphics.Point(resources.displayMetrics.widthPixels, resources.displayMetrics.heightPixels)
    }

    /**
     * 系统给 overlay 窗口应用的水平/垂直偏移（v2.7.2 修复）：
     * 渲染位置 = attrs.x + offsetX、attrs.y + offsetY。
     * 横屏（ROTATION_90）时系统会把窗口整体右移（挖孔/状态栏安全区，实测 144px），
     * 不扣除偏移会导致贴边计算把球推到屏幕外（"横屏悬浮球消失"）。
     */
    /**
     * 系统给 overlay 窗口应用的水平/垂直偏移（渲染位置 = attrs.x + offsetX、attrs.y + offsetY）。
     * 实测 rootWindowInsets 在 overlay 窗口上不可靠（本机返回 108 而实际 144），
     * 改用 display 级权威数据 defaultDisplay.cutout（API 29+）：
     * - 竖屏：挖孔在顶部 → safeInsetTop（本机 144）
     * - 横屏 ROTATION_90：挖孔转到左侧 → safeInsetLeft（144）
     * - 翻转 180°（ROTATION_270）：挖孔转到右侧 → safeInsetLeft=0（系统右侧收窄，左不推）
     */
    private fun overlayInsetLeft(): Int {
        val wm = this.wm ?: return 0
        // v2.7.2 review(M5)：Display.getCutout 是 API 28+（Android 9 首个挖孔版本），门限用 28
        if (Build.VERSION.SDK_INT >= 28) {
            val c = wm.defaultDisplay.cutout
            if (c != null && c.safeInsetLeft > 0) return c.safeInsetLeft
        }
        @Suppress("DEPRECATION")
        return bubble?.rootWindowInsets?.systemWindowInsetLeft ?: 0
    }

    private fun overlayInsetTop(): Int {
        val wm = this.wm ?: return 0
        if (Build.VERSION.SDK_INT >= 28) {
            val c = wm.defaultDisplay.cutout
            if (c != null && c.safeInsetTop > 0) return c.safeInsetTop
        }
        @Suppress("DEPRECATION")
        return bubble?.rootWindowInsets?.systemWindowInsetTop ?: 0
    }

    /** 球当前渲染位置（attrs + 系统偏移）。 */
    private fun bubbleRenderX(): Int = (bubbleParams?.x ?: 0) + overlayInsetLeft()
    private fun bubbleRenderY(): Int = (bubbleParams?.y ?: 0) + overlayInsetTop()

    /** 旋转/配置变更：按新屏尺寸恢复贴边（渲染坐标计算，扣除系统 inset 偏移）。 */
    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        repositionForOrientation()
        // relayout 完成后 insets 才更新为最新方向的值，用新值再校正一次
        bubble?.post { repositionForOrientation() }
    }

    private fun repositionForOrientation() {
        val p = bubbleParams ?: return
        val root = bubble ?: return
        val wm = this.wm ?: return
        val size = screenSize()
        if (lastScreenW <= 0) lastScreenW = size.x
        val petW = petWidthPx()
        val petH = petHeightPx()
        val offX = overlayInsetLeft()
        // 无条件贴边（v2.7.2 修正）：按旋转前渲染位置判断贴左/贴右，保持隐藏状态——
        // 不再保留"自由位置"，竖屏↔横屏/翻转 180°/页面跳转后宠物都自动回到边上
        val center = lastRenderX + petW / 2
        edgeSide = if (center < lastScreenW / 2) -1 else 1
        val newRenderX = if (edgeSide < 0) {
            if (edgeHidden) -petW + edgePeekPx() else 0
        } else {
            if (edgeHidden) size.x - edgePeekPx() else size.x - petW
        }
        p.x = newRenderX - offX
        val offY = overlayInsetTop()
        val ry = p.y + offY
        p.y = ry.coerceIn(0, size.y - petH) - offY
        lastScreenW = size.x
        lastScreenH = size.y
        lastRenderX = newRenderX
        wm.updateViewLayout(root, p)
        positionStatusBubble()
        updateBadgePosition()
        if (panelVisible) placePanel()
    }

    private fun addPet() {
        val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        this.wm = wm
        // v2.9.0 review(A9)：悬浮窗权限兜底——运行时被收回/绕过检查时优雅退出，
        // 不再抛 BadTokenException 崩掉前台服务
        if (!android.provider.Settings.canDrawOverlays(this)) {
            android.util.Log.w("DSHRemote", "pet: overlay permission missing/revoked; stopping")
            stopSelf()
            return
        }
        val manifest = runCatching {
            assets.open("pet-manifest.json").use {
                PetManifest.parse(it.bufferedReader(Charsets.UTF_8).readText())
            }
        }.getOrElse {
            android.util.Log.e("DSHRemote", "pet: manifest load failed", it)
            null
        }
        if (manifest == null) {
            stopSelf()
            return
        }
        petManifest = manifest
        petModel = PetAnimationModel(manifest)
        val petW = petWidthPx()
        val petH = petHeightPx()
        val root = FrameLayout(this)
        root.layoutParams = FrameLayout.LayoutParams(petW, petH)

        val view = PetView(this)
        root.addView(view, FrameLayout.LayoutParams(petW, petH))
        petView = view

        val bd = TextView(this)
        bd.text = "0"
        bd.textSize = 9f
        bd.setTextColor(Color.WHITE)
        bd.gravity = Gravity.CENTER
        bd.setPadding(dp(5), 0, dp(5), 0)
        bd.setMinWidth(dp(14))
        // v2.7.1：胶囊徽标（圆角=高一半），骑在球右上外缘（上移/右移出球）
        bd.background = roundedRect(Color.parseColor("#E5484D"), 8f)
        bd.visibility = View.GONE
        val badgeLp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, dp(16), Gravity.TOP or Gravity.END
        )
        badgeLp.topMargin = -dp(3)
        badgeLp.rightMargin = -dp(2)
        root.clipChildren = false
        root.clipToPadding = false
        root.addView(bd, badgeLp)

        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            petW, petH, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, // 允许越出屏幕（贴边半隐藏必需）
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        // 启动即贴右边缘（完全露出），垂直落在屏幕中下部，避开状态栏
        val initSize = screenSize()
        lastScreenW = initSize.x
        lastScreenH = initSize.y
        edgeSide = 1
        edgeHidden = false
        params.x = initSize.x - petW
        lastRenderX = initSize.x - petW
        params.y = (initSize.y * 0.58f).toInt().coerceIn(0, (initSize.y - petH).coerceAtLeast(0))
        wm.addView(root, params)
        // 启动后 5 秒无操作自动缩进（贴边常驻，无需先拖动）
        mainHandler.postDelayed(autoHideRunnable, 5000)

        val gd = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onDown(e: MotionEvent): Boolean = true

            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                if (isEdgeHidden()) {
                    slideOut()
                    return true
                }
                handlePetTap(e.x, e.y, doubleTap = false)
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (isEdgeHidden()) {
                    slideOut()
                    return true
                }
                handlePetTap(e.x, e.y, doubleTap = true)
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                if (isEdgeHidden()) {
                    slideOut()
                    mainHandler.postDelayed({ if (petModel != null && !panelVisible) showPanel() }, 260)
                } else {
                    togglePanel()
                }
            }
        })
        root.setOnTouchListener { _, ev ->
            if (ev.actionMasked == MotionEvent.ACTION_DOWN) {
                mainHandler.removeCallbacks(autoHideRunnable)
            }
            gd.onTouchEvent(ev)
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    // 开始拖动前取消进行中的贴边/缩进动画（否则动画下一帧会覆盖拖动位置）
                    bubbleAnim?.cancel()
                    // 自愈：若宠物因旋转等落在越界位置，先钳回允许范围再开始拖
                    val size = screenSize()
                    val w = petWidthPx()
                    val h = petHeightPx()
                    val offX = overlayInsetLeft()
                    val offY = overlayInsetTop()
                    val minX = -w + edgePeekPx()
                    val maxX = maxOf(minX, size.x - edgePeekPx())
                    val cx = (params.x + offX).coerceIn(minX, maxX) - offX
                    val cy = (params.y + offY).coerceIn(0, (size.y - h).coerceAtLeast(0)) - offY
                    if (cx != params.x || cy != params.y) {
                        params.x = cx
                        params.y = cy
                        wm.updateViewLayout(root, params)
                    }
                    downX = ev.rawX; downY = ev.rawY
                    startX = params.x; startY = params.y
                    moved = false
                    root.animate().scaleX(0.96f).scaleY(0.96f).setDuration(80).start()
                    root.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = ev.rawX - downX
                    val dy = ev.rawY - downY
                    if (!moved && (Math.abs(dx) > dp(12f) || Math.abs(dy) > dp(12f))) {
                        moved = true
                        beginDrag()
                    }
                    if (moved) {
                        // 拖动钳制：允许贴边半隐藏的 24dp 探出，按渲染坐标扣 inset 后写回
                        val size = screenSize()
                        val w = petWidthPx()
                        val h = petHeightPx()
                        val offX = overlayInsetLeft()
                        val offY = overlayInsetTop()
                        val minX = -w + edgePeekPx()
                        val maxX = maxOf(minX, size.x - edgePeekPx())
                        val rx = (startX + dx.toInt() + offX).coerceIn(minX, maxX)
                        val ry = (startY + dy.toInt() + offY).coerceIn(0, (size.y - h).coerceAtLeast(0))
                        params.x = rx - offX
                        params.y = ry - offY
                        lastRenderX = rx // 拖动中旋转也能按当前渲染位置贴边
                        wm.updateViewLayout(root, params)
                        if (panelVisible) hidePanel()
                        positionStatusBubble()
                        updateBadgePosition()
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    root.animate().scaleX(1f).scaleY(1f).setDuration(140)
                        .setInterpolator(android.view.animation.OvershootInterpolator(1.6f)).start()
                    if (moved) {
                        moved = false
                        endDrag()
                        snapToEdgeVisible()
                    } else {
                        scheduleAutoHide()
                    }
                    true
                }
                MotionEvent.ACTION_CANCEL -> {
                    root.animate().scaleX(1f).scaleY(1f).setDuration(120).start()
                    if (moved) {
                        moved = false
                        endDrag()
                        snapToEdgeVisible()
                    } else {
                        scheduleAutoHide()
                    }
                    true
                }
                else -> false
            }
        }
        bubble = root
        bubbleParams = params
        badge = bd
        renderPet(animate = false)
    }

    /** 宠物状态气泡：标题 + 详情，点开面板；出现数秒后自动收起。 */
    private fun addStatusBubble() {
        val wm = this.wm ?: return
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(11), dp(8), dp(11), dp(8))
        root.background = roundedRect(Color.parseColor("#F21A1D24"), 12f)
        root.visibility = View.GONE
        val title = TextView(this)
        title.setTextColor(Color.WHITE)
        title.textSize = 12f
        title.maxLines = 2
        title.ellipsize = android.text.TextUtils.TruncateAt.END
        title.maxWidth = dp(230)
        val detail = TextView(this)
        detail.setTextColor(Color.parseColor("#9AA3AF"))
        detail.textSize = 10.5f
        detail.maxLines = 2
        detail.ellipsize = android.text.TextUtils.TruncateAt.END
        detail.maxWidth = dp(230)
        detail.setPadding(0, dp(2), 0, 0)
        root.addView(title, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.addView(detail, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT))
        root.setOnClickListener {
            if (isEdgeHidden()) slideOut() else if (panelVisible) hidePanel() else togglePanel()
        }
        val type = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        else @Suppress("DEPRECATION") WindowManager.LayoutParams.TYPE_PHONE
        val params = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT, WindowManager.LayoutParams.WRAP_CONTENT, type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT
        )
        params.gravity = Gravity.TOP or Gravity.START
        wm.addView(root, params)
        tip = root
        tipTitle = title
        tipDetail = detail
        tipParams = params
    }

    private fun showStatus(title: String, detail: String, ttlMs: Long, important: Boolean) {
        val tv = tip ?: return
        // 贴边藏起来时不弹普通状态；等待/出错等重要状态仍提示（气泡贴在可见边缘）。
        if (petTucked && !important) return
        tipTitle?.text = title
        tipDetail?.text = detail
        tipDetail?.visibility = if (detail.isEmpty()) View.GONE else View.VISIBLE
        tv.visibility = View.VISIBLE
        positionStatusBubble()
        mainHandler.removeCallbacks(hideTipRunnable)
        mainHandler.postDelayed(hideTipRunnable, ttlMs)
        petStatusShownAt = System.currentTimeMillis()
    }

    /** 旧调用点（通知/余额）保留：标题 + 当前任务详情，5 秒收起。 */
    private fun showTip(text: String) {
        showStatus(text, statusDetail(), 5000, false)
    }

    private fun hideStatus() {
        tip?.visibility = View.GONE
        mainHandler.removeCallbacks(hideTipRunnable)
    }

    /** 气泡定位：宠物正上方紧贴，水平居中于可见部分；顶部空间不足放下方。 */
    private fun positionStatusBubble() {
        val tv = tip ?: return
        if (tv.visibility != View.VISIBLE) return
        val p = tipParams ?: return
        val bp = bubbleParams ?: return
        val wm = this.wm ?: return
        val size = screenSize()
        val petW = petWidthPx()
        val petH = petHeightPx()
        // 实际宽高（首次显示未测量时用估算，布局完成后重定位）
        val tipW = if (tv.width > 0) tv.width else dp(180)
        val tipH = if (tv.height > 0) tv.height else dp(46)
        val bx = bp.x + overlayInsetLeft()
        val by = bp.y + overlayInsetTop()
        val visCenter = (maxOf(0, bx) + minOf(size.x, bx + petW)) / 2
        p.x = (visCenter - tipW / 2).coerceIn(dp(4), (size.x - tipW - dp(4)).coerceAtLeast(dp(4)))
        val above = by - tipH - dp(6)
        p.y = if (above >= dp(6)) {
            above
        } else {
            (by + petH + dp(6)).coerceAtMost((size.y - tipH - dp(4)).coerceAtLeast(dp(4)))
        }
        wm.updateViewLayout(tv, p)
        if (tv.width == 0) {
            tv.post { if (tip?.visibility == View.VISIBLE) positionStatusBubble() }
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

    private fun scheduleAutoHide() {
        mainHandler.removeCallbacks(autoHideRunnable)
        if (petEdgeHide && !panelVisible) {
            mainHandler.postDelayed(autoHideRunnable, 5000)
        }
    }

    /** 松手后吸附到边缘（完全露出），供 5 秒无操作后的缩进做基线。 */
    private fun snapToEdgeVisible() {
        val p = bubbleParams ?: return
        val size = screenSize()
        val petW = petWidthPx()
        val center = bubbleRenderX() + petW / 2
        edgeSide = if (center < size.x / 2) -1 else 1
        edgeHidden = false
        petTucked = false
        petView?.setDimmed(false)
        petView?.setAnimationRunning(!petReducedMotion)
        lastScreenW = size.x
        lastScreenH = size.y
        val renderX = if (edgeSide < 0) 0 else size.x - petW
        lastRenderX = renderX
        animateX(renderX - overlayInsetLeft())
        updateBadgePosition()
        scheduleAutoHide()
    }

    /** 5 秒无操作后缩进：只露 24dp，并降低透明度 + 去饱和/轻度模糊，尽量不挡屏幕。 */
    private fun autoHideToEdge() {
        if (!petEdgeHide || panelVisible || bubble == null) return
        val p = bubbleParams ?: return
        val size = screenSize()
        val edgePeek = edgePeekPx()
        val petW = petWidthPx()
        val center = bubbleRenderX() + petW / 2
        edgeSide = if (center < size.x / 2) -1 else 1
        edgeHidden = true
        petTucked = true
        hideStatus()
        petView?.setDimmed(true)
        petView?.setAnimationRunning(false)
        lastScreenW = size.x
        lastScreenH = size.y
        val renderX = if (edgeSide < 0) -petW + edgePeek else size.x - edgePeek
        lastRenderX = renderX
        animateX(renderX - overlayInsetLeft())
        updateBadgePosition()
    }

    /** 水平滑动动画（吸附/缩进/滑出统一用）；球移动时气泡同步跟随。
     *  v2.7.2 review(FS4)：持有 animator 引用，onDestroy 取消、新动画前取消旧动画。 */
    private var bubbleAnim: android.animation.ValueAnimator? = null
    private fun animateX(target: Int) {
        val p = bubbleParams ?: return
        val wm = this.wm ?: return
        val root = bubble ?: return
        val from = p.x
        if (from == target) return
        bubbleAnim?.cancel()
        val anim = android.animation.ValueAnimator.ofInt(from, target)
        bubbleAnim = anim
        anim.duration = 240
        anim.interpolator = android.view.animation.DecelerateInterpolator()
        anim.addUpdateListener {
            if (bubble == null) return@addUpdateListener // 服务已销毁：停止动画帧
            p.x = it.animatedValue as Int
            wm.updateViewLayout(root, p)
            if (panelVisible) placePanel()
            positionStatusBubble() // 气泡跟随宠物移动（缩进/滑出期间不错位）
            updateBadgePosition()
        }
        anim.addListener(object : android.animation.AnimatorListenerAdapter() {
            override fun onAnimationEnd(animation: android.animation.Animator) {
                if (bubbleAnim === animation) bubbleAnim = null
            }
            override fun onAnimationCancel(animation: android.animation.Animator) {
                if (bubbleAnim === animation) bubbleAnim = null
            }
        })
        anim.start()
    }

    /** 宠物是否处于贴边半隐藏状态（按渲染坐标判断）。 */
    private fun isEdgeHidden(): Boolean {
        val p = bubbleParams ?: return false
        val size = screenSize()
        val petW = petWidthPx()
        val rx = p.x + overlayInsetLeft()
        return rx < -dp(2) || rx + petW > size.x + dp(2)
    }

    /** 从半隐藏滑出到完全可见。 */
    private fun slideOut() {
        val p = bubbleParams ?: return
        val size = screenSize()
        val petW = petWidthPx()
        edgeHidden = false
        petTucked = false
        petView?.setDimmed(false)
        petView?.setAnimationRunning(!petReducedMotion)
        lastScreenW = size.x
        lastScreenH = size.y
        val rx = p.x + overlayInsetLeft()
        val renderX = if (rx < size.x / 2) 0 else size.x - petW
        lastRenderX = renderX
        animateX(renderX - overlayInsetLeft())
        updateBadgePosition()
        scheduleAutoHide()
    }

    // ── 迷你面板（单击展开，球旁小卡片）──
    private fun addPanel() {
        val wm = this.wm ?: return
        val width = dp(248)
        val root = LinearLayout(this)
        root.orientation = LinearLayout.VERTICAL
        root.setPadding(dp(12), dp(8), dp(12), dp(10))
        root.background = roundedRect(Color.parseColor("#F21A1D24"), 14f)
        root.visibility = View.GONE

        // 标题行
        val head = LinearLayout(this)
        head.orientation = LinearLayout.HORIZONTAL
        head.gravity = Gravity.CENTER_VERTICAL
        val title = TextView(this)
        title.text = text("DSH 大肥鱼", "DSH BigFish")
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

        // 当前宠物状态（一行，随 SSE 状态更新）
        val status = TextView(this)
        status.setTextColor(Color.parseColor("#9AA3AF"))
        status.textSize = 10.5f
        status.maxLines = 1
        status.ellipsize = android.text.TextUtils.TruncateAt.END
        status.setPadding(0, 0, 0, dp(4))
        root.addView(status, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, dp(18)))
        panelStatus = status

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
        // 行内标题（不走 sectionLabel：它带区块级上下 padding，会破坏水平对齐）
        val secNotifs = TextView(this)
        secNotifs.text = text("最近通知", "Notifications")
        secNotifs.setTextColor(Color.parseColor("#9AA3AF"))
        secNotifs.textSize = 10.5f
        // 文本在容器内垂直居中 + 去掉字体上下留白：与徽标/查看全部的视觉中心对齐
        secNotifs.gravity = Gravity.CENTER_VERTICAL
        secNotifs.setIncludeFontPadding(false)
        notifHead.addView(secNotifs, LinearLayout.LayoutParams(0, dp(24), 1f))
        val badgeUnread = TextView(this)
        badgeUnread.text = "0"
        badgeUnread.setTextColor(Color.WHITE)
        badgeUnread.textSize = 8f
        badgeUnread.gravity = Gravity.CENTER
        // 去掉字体上下留白：小字号胶囊在固定高度容器里数字不再视觉偏下
        badgeUnread.setIncludeFontPadding(false)
        badgeUnread.setPadding(dp(4), 0, dp(4), 0)
        // 最小宽度要足够大：单数字（"1"）时若只有 12dp 会接近正圆，
        // 18dp 保证单数字也呈现胶囊（两端半圆 + 平段）
        badgeUnread.setMinWidth(dp(18))
        badgeUnread.background = roundedRect(Color.parseColor("#E5484D"), 6f)
        badgeUnread.visibility = View.GONE
        notifHead.addView(badgeUnread, LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, dp(12)))
        val viewAll = TextView(this)
        viewAll.text = text("查看全部 →", "View all →")
        viewAll.setTextColor(Color.parseColor("#6C8CFF"))
        viewAll.textSize = 10.5f
        viewAll.gravity = Gravity.CENTER_VERTICAL
        viewAll.setIncludeFontPadding(false)
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

        // 用量与额度区块（v3.2）：整块可点 → App 用量页；不可用时降级为下方单行余额。
        // 每来源一行：金额行保留文字（Balance 无分母不画条），配额行只出细条与颜色、不出数字。
        val usageRoot = LinearLayout(this)
        usageRoot.orientation = LinearLayout.VERTICAL
        usageRoot.visibility = View.GONE
        val uHead = LinearLayout(this)
        uHead.orientation = LinearLayout.HORIZONTAL
        uHead.gravity = Gravity.CENTER_VERTICAL
        val uLabel = TextView(this)
        uLabel.text = text("用量与额度", "Usage & allowance")
        uLabel.setTextColor(Color.parseColor("#9AA3AF"))
        uLabel.textSize = 10.5f
        uLabel.gravity = Gravity.CENTER_VERTICAL
        uLabel.setIncludeFontPadding(false)
        uHead.addView(uLabel, LinearLayout.LayoutParams(0, dp(24), 1f))
        val uMore = TextView(this)
        uMore.text = text("详情 ▸", "Details ▸")
        uMore.setTextColor(Color.parseColor("#6C8CFF"))
        uMore.textSize = 10.5f
        uMore.gravity = Gravity.CENTER_VERTICAL
        uMore.setIncludeFontPadding(false)
        uMore.setPadding(dp(8), 0, 0, 0)
        uHead.addView(uMore, LinearLayout.LayoutParams(dp(60), dp(24)))
        usageRoot.addView(uHead)
        val uRows = LinearLayout(this)
        uRows.orientation = LinearLayout.VERTICAL
        usageRoot.addView(uRows)
        val uStale = TextView(this)
        uStale.setTextColor(Color.parseColor("#5C6470"))
        uStale.textSize = 10f
        uStale.setPadding(0, dp(2), 0, 0)
        uStale.visibility = View.GONE
        usageRoot.addView(uStale)
        usageRoot.setOnClickListener { hidePanel(); openUsage() }
        root.addView(usageRoot)
        panelUsage = usageRoot
        panelUsageRows = uRows
        panelUsageStale = uStale

        // 常驻余额行（区块不可用时的降级显示；区块可见时隐藏。点击去充值；低余额红色）
        val balanceRow = TextView(this)
        balanceRow.gravity = Gravity.CENTER_VERTICAL
        balanceRow.textSize = 12.5f
        balanceRow.setPadding(dp(2), dp(6), dp(2), 0)
        balanceRow.setOnClickListener { hidePanel(); openCharge() }
        root.addView(balanceRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(26)))
        panelBalance = balanceRow

        // 底部按钮（浅灰胶囊，与深色弹窗协调）
        val btnRow = LinearLayout(this)
        btnRow.orientation = LinearLayout.HORIZONTAL
        btnRow.gravity = Gravity.CENTER_VERTICAL
        val openBtn = TextView(this)
        openBtn.text = text("打开 App", "Open App")
        openBtn.setTextColor(Color.WHITE)
        openBtn.textSize = 12.5f
        openBtn.gravity = Gravity.CENTER
        openBtn.background = roundedRect(Color.parseColor("#3A3F47"), 20f)
        openBtn.setOnClickListener { hidePanel(); openMain() }
        btnRow.addView(openBtn, LinearLayout.LayoutParams(0, dp(36), 1f))
        val chargeBtn = TextView(this)
        chargeBtn.text = text("去充值", "Top up")
        chargeBtn.setTextColor(Color.WHITE)
        chargeBtn.textSize = 12.5f
        chargeBtn.gravity = Gravity.CENTER
        chargeBtn.background = roundedRect(Color.parseColor("#3A3F47"), 20f)
        chargeBtn.setOnClickListener { hidePanel(); openCharge() }
        btnRow.addView(chargeBtn, LinearLayout.LayoutParams(0, dp(36), 1f))
        val gap = View(this)
        btnRow.addView(gap, LinearLayout.LayoutParams(dp(8), 1))
        root.addView(btnRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(36)))
        panelCharge = chargeBtn

        // 关闭宠物入口（旧的"长按退出"已改为长按开面板）
        val exit = TextView(this)
        exit.text = text("关闭宠物", "Turn off pet")
        exit.setTextColor(Color.parseColor("#5C6470"))
        exit.textSize = 10.5f
        exit.gravity = Gravity.CENTER
        exit.setPadding(0, dp(6), 0, 0)
        exit.setOnClickListener { hidePanel(); exitBubble("panel") }
        root.addView(exit, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT, dp(24)))
        panelExit = exit

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
        if (petTucked || isEdgeHidden()) {
            // 贴边藏着时先把宠物滑出来，再展开面板
            slideOut()
            mainHandler.postDelayed({ if (!panelVisible && petModel != null) showPanel() }, 260)
            return
        }
        val p = panel ?: return
        val pp = panelParams ?: return
        panelVisible = true
        mainHandler.removeCallbacks(autoHideRunnable)
        hideStatus()
        updatePanelStatus()
        placePanel()
        scrim?.visibility = View.VISIBLE // 拦截面板外点击（透明，不遮挡视觉）
        p.visibility = View.VISIBLE
        // 生长动画：从球方向位移 + 放大 + 淡入（球在左→从左长出，球在上→从上长出）
        val bp = bubbleParams ?: return
        val size = screenSize()
        val bx = bp.x + overlayInsetLeft()
        val by = bp.y + overlayInsetTop()
        val dirX = if (bx < size.x / 2) -1f else 1f
        val dirY = if (by < size.y / 2) -1f else 1f
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
        postState()
        refreshPanelData()
        // 用量与额度：先落节流/在途标记再渲染——fetchAllowance 同步置 in-flight 后，
        // 紧接的 render 即呈「查询中…」，避免首次展开先闪一帧降级单行
        val usageModel = currentUsageModel()
        if (usageModel.fetchDue) fetchAllowance()
        renderUsageBlock(currentUsageModel())
        // 面板开着期间周期刷新（兜底）
        mainHandler.removeCallbacks(panelRefreshRunnable)
        mainHandler.postDelayed(panelRefreshRunnable, 5000)
    }

    /** 面板贴球展开：随球所在象限选择方向（左上/右上/左下/右下），始终完整在屏内。 */
    private fun placePanel() {
        // v3.0.0：onDestroy 后 panel 已置空，但面板展开动画(ViewPropertyAnimator 经
        // Choreographer 驱动，removeCallbacksAndMessages 取消不了)的 withEndAction 仍会回调
        // placePanel——此时 updateViewLayout(null,..) 主线程 NPE 杀进程，必须提前拦下
        val view = panel ?: return
        if (!panelVisible) return
        val pp = panelParams ?: return
        val bp = bubbleParams ?: return
        val wm = this.wm ?: return
        val size = screenSize()
        val pw = dp(248)
        // 用面板实际高度（首次打开前未测量时用估算值）
        val ph = if ((view.height ?: 0) > 0) view.height else dp(340)
        val sw = size.x
        val sh = size.y
        // 用渲染坐标（宠物实际显示位置）计算面板位置
        val bx = bp.x + overlayInsetLeft()
        val by = bp.y + overlayInsetTop()
        val petW = petWidthPx()
        val petH = petHeightPx()
        val visLeft = maxOf(0, bx)
        val visRight = minOf(sw, bx + petW)
        val ballBottom = by + petH
        // 水平：宠物可见部分在左半 → 面板放右侧；否则放左侧
        val onLeftSide = (visLeft + visRight) / 2 < sw / 2
        pp.x = if (onLeftSide) visRight + dp(4) else visLeft - pw - dp(4)
        if (pp.x < 0) pp.x = 0
        if (pp.x + pw > sw) pp.x = sw - pw
        // 垂直：宠物在上半 → 面板顶部对齐；下半 → 面板底部对齐
        val onTop = by < sh / 2
        if (onTop) {
            pp.y = by
        } else {
            pp.y = ballBottom - ph
        }
        if (pp.y < dp(40)) pp.y = dp(40)
        if (pp.y + ph > sh) pp.y = sh - ph - dp(20)
        wm.updateViewLayout(view, pp)
    }

    private fun hidePanel() {
        val p = panel ?: return
        panelVisible = false
        scrim?.visibility = View.GONE
        mainHandler.removeCallbacks(panelRefreshRunnable)
        // 面板关闭后 5 秒无操作自动缩进（宠物保持可见便于再次操作）
        scheduleAutoHide()
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
            // v2.8.0 review：三段独立 runCatching——任一段畸形响应只跳过该段，
            // 不牵连后续请求与 renderPanel（旧单 try 会在解析异常时整轮跳过面板刷新）
            // 运行中会话（bootstrap agents）
            val running = mutableListOf<Triple<String, String, String>>() // (id, status, title)
            runCatching {
                httpGet("bootstrap")?.let { txt ->
                    val agents = JSONObject(txt).optJSONArray("agents") ?: JSONArray()
                    for (i in 0 until agents.length()) {
                        val a = agents.optJSONObject(i) ?: continue
                        val st = a.optString("status")
                        if (isActive(st)) {
                            // v2.7.2 review(M4)：agent.id 即 session.id（内核校验 id === session.id），
                            // 无需剥前缀；直接传原始 id 给 App。
                            // v2.9：优先展示标题（bootstrap 已附 title），空则回退 id 短码（renderPanel 派生）。
                            val title = a.optString("title").ifEmpty { a.optString("id") }
                            running.add(Triple(a.optString("id"), st, title))
                        }
                    }
                }
            }

            // 最近通知（标题/未读/时间；字段与插件端 items 一致）
            val notifs = mutableListOf<Map<String, Any>>()
            var unreadCount = 0
            runCatching {
                httpGet("notifications")?.let { txt ->
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
            }

            // 余额（面板打开时顺带刷新常驻余额行，静默不弹提示；金额取 CNY 优先，与详情页同口径）
            runCatching {
                httpGet("balance")?.let { txt ->
                    UsagePanelModel.deepseekBalanceFromBalancePayload(txt)?.let { v ->
                        if (v > 0) applyBalance(v, tip = false)
                    }
                }
            }

            mainHandler.post {
                // 面板打开 = 已看：更新未读基线（下次增量从当前起算）
                lastUnreadCount = unreadCount
                firstUnreadCheck = false
                renderPanel(running, notifs, unreadCount)
            }
        }, "dsh-bubble-panel").apply { isDaemon = true; start() }
    }

    private fun renderPanel(running: List<Triple<String, String, String>>, notifs: List<Map<String, Any>>, unreadCount: Int) {
        val box = panelSessions ?: return
        box.removeAllViews()
        if (running.isNotEmpty()) {
            latestSessionTitle = running.first().third
        } else if (notifs.isNotEmpty()) {
            (notifs.first()["title"] as? String)?.takeIf { it.isNotBlank() }?.let {
                latestSessionTitle = it
            }
        }
        updatePanelStatus()
        val secS = panelSessionsSec
        if (running.isEmpty()) {
            // 无运行中会话 → 区块保留，显示占位文案（面板不空）
            secS?.visibility = View.VISIBLE
            box.visibility = View.VISIBLE
            val empty = TextView(this)
            empty.text = text("暂无运行中的会话", "No active sessions")
            empty.setTextColor(Color.parseColor("#5C6470"))
            empty.textSize = 11f
            empty.setPadding(0, dp(2), 0, dp(2))
            box.addView(empty)
        } else {
            secS?.visibility = View.VISIBLE
            box.visibility = View.VISIBLE
            for ((id, st, title) in running.take(3)) {
                val row = TextView(this)
                val dot = if (st == "waiting") "◉" else "●"
                // v2.9：展示会话标题（超宽省略号截断）；openSession 必须传原始 id（App 按 sessionId 与 SSE 帧比对）
                row.text = "$dot $title"
                row.setTextColor(Color.WHITE)
                row.textSize = 12.5f
                row.maxLines = 1
                row.ellipsize = android.text.TextUtils.TruncateAt.END
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
            // 无通知 → 区块保留，显示占位文案（面板不空）
            secN?.visibility = View.VISIBLE
            nbox.visibility = View.VISIBLE
            badgeN?.visibility = View.GONE
            val empty = TextView(this)
            empty.text = text("暂无通知", "No notifications")
            empty.setTextColor(Color.parseColor("#5C6470"))
            empty.textSize = 11f
            empty.setPadding(0, dp(2), 0, dp(2))
            nbox.addView(empty)
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
            (panelCharge as? TextView)?.background = roundedRect(Color.parseColor("#E5484D"), 20f)
        } else {
            (panelCharge as? TextView)?.background = roundedRect(Color.parseColor("#3A3F47"), 20f)
        }
        updateBalanceRow()
        // 用量与额度区块随每次面板刷新重绘（数据到达/余额变化后颜色与行数也能跟上）
        renderUsageBlock(currentUsageModel())
    }

    // ── 宠物状态渲染 ──
    private fun setState() {
        updateBadge()
        renderPet(animate = false)
    }

    /** 把状态机的 active 片段交给 PetView；同一段不重复解码。 */
    private fun renderPet(animate: Boolean) {
        val model = petModel ?: return
        val view = petView ?: return
        if (model.activeVersion == petRenderedVersion) {
            updateBadge()
            return
        }
        petRenderedVersion = model.activeVersion
        val clip = model.activeClip
        val fade = animate && model.crossfadeMs(petLastClip, clip.name) != null
        view.showClip(clip, fade)
        petLastClip = clip.name
        view.setAnimationRunning(!petReducedMotion && !petTucked)
        updateBadge()
        updatePanelStatus()
    }

    private fun updateBadge() {
        val bd = badge ?: return
        if (notifCount > 0) {
            bd.text = if (notifCount > 99) "99+" else "$notifCount"
            bd.visibility = View.VISIBLE
        } else {
            bd.visibility = View.GONE
        }
        updateBadgePosition()
    }

    /** 贴边缩进时红点跟着移到露出的那一侧，否则会藏到屏幕外。 */
    private fun updateBadgePosition() {
        val bd = badge ?: return
        val lp = bd.layoutParams as? FrameLayout.LayoutParams ?: return
        val hidden = isEdgeHidden()
        lp.gravity = when {
            !hidden -> Gravity.TOP or Gravity.END
            edgeSide < 0 -> Gravity.TOP or Gravity.END
            else -> Gravity.TOP or Gravity.START
        }
        lp.topMargin = if (hidden) dp(4) else -dp(3)
        lp.rightMargin = if (!hidden) -dp(2) else if (edgeSide < 0) dp(2) else 0
        lp.leftMargin = if (hidden && edgeSide > 0) dp(2) else 0
        bd.layoutParams = lp
    }

    private fun updatePanelStatus() {
        val tv = panelStatus ?: return
        val lang = language()
        tv.text = PetCopy.stateLabel(petReducer.state, lang) + " · " +
            PetCopy.status(petReducer.state, petReducer.activity, lang)
    }

    private fun statusDetail(): String {
        val lang = language()
        val title = latestSessionTitle
            ?.takeIf { it.isNotBlank() }
            ?.let { if (it.length > 24) it.take(24) + "…" else it }
        val progress = latestProgress
        val parts = mutableListOf<String>()
        if (title != null) parts.add(title)
        if (progress != null && progress.second > 0) {
            parts.add(
                if (lang == "en") "Completed ${progress.first}/${progress.second}"
                else "已完成 ${progress.first}/${progress.second} 步",
            )
        }
        return if (parts.isEmpty()) PetCopy.waitingDetail(lang) else parts.joinToString(" · ")
    }

    private fun language(): String = prefs("flutter.dsh_mr_language") ?: "zh"

    private fun applyPetChange(change: PetStateChange?) {
        if (change == null) return
        val model = petModel ?: return
        val now = System.currentTimeMillis()
        if (change.pulse) {
            val clipName = model.manifest.stateMap[change.state]
            val ttl = model.manifest.clips[clipName]?.durationMs ?: 5000L
            model.applyPulse(change.state, ttl, now, change.resumeState, change.resumeActivity)
        } else {
            model.applyState(change.state, change.activity)
        }
        agentsRunning = petReducer.state == "WORKING" ||
            petReducer.state == "THINKING" ||
            petReducer.state == "WAITING"
        renderPet(animate = true)
        announceState(change, now)
    }

    private fun announceState(change: PetStateChange, now: Long) {
        if (change.state == "IDLE") return
        val important = !change.pulse && (change.state == "WAITING" || change.state == "ERROR")
        if (!important && change.state == petStatusState && now - petStatusShownAt < 4000) return
        // 贴边藏起来时，完成/等待/出错短暂探头，播完再缩回去；普通工作状态不打扰。
        if (petTucked && (important || change.state == "SUCCESS")) {
            slideOut()
            mainHandler.removeCallbacks(autoHideRunnable)
            mainHandler.postDelayed(
                autoHideRunnable,
                if (change.state == "SUCCESS") 6000L else 8000L,
            )
        }
        petStatusState = change.state
        val lang = language()
        val ttl = when (change.state) {
            "SUCCESS" -> 5000L
            "WAITING", "ERROR" -> 8000L
            else -> 4500L
        }
        showStatus(PetCopy.status(change.state, change.activity, lang), statusDetail(), ttl, important)
    }

    private fun maybePlayIdleMicro(now: Long) {
        val model = petModel ?: return
        if (petReducedMotion || petTucked || panelVisible) return
        if (model.baseState != "IDLE" || model.hasOverlay || model.pulseState != null) {
            petIdleNextAt = now + 10_000
            return
        }
        if (now < petIdleNextAt) return
        val clip = model.pickIdleMicro()
        if (clip != null && model.playIdleMicro(clip, now)) {
            renderPet(animate = true)
        }
        petIdleNextAt = now + randomIdleInterval()
    }

    private fun randomIdleInterval(): Long {
        val (lower, upper) = petModel?.idleMicroInterval("normal") ?: (25_000L to 45_000L)
        if (upper <= lower) return lower
        return lower + (Math.random() * (upper - lower)).toLong()
    }

    private fun handlePetTap(x: Float, y: Float, doubleTap: Boolean) {
        val model = petModel ?: return
        val lang = language()
        val clip: String
        val message: String
        if (doubleTap) {
            clip = "head_pat"
            message = PetCopy.interaction(clip, true, lang)
        } else {
            val w = petWidthPx().toFloat()
            val h = petHeightPx().toFloat()
            clip = when {
                y < h * 0.45f -> "head_pat"
                x > w * 0.72f -> "tail"
                else -> "poke"
            }
            message = PetCopy.interaction(clip, false, lang)
        }
        if (!petReducedMotion) {
            if (!model.playInteraction(clip, System.currentTimeMillis())) return
            renderPet(animate = true)
        }
        showStatus(message, statusDetail(), 1800, false)
        bubble?.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
        scheduleAutoHide()
    }

    private fun beginDrag() {
        val model = petModel ?: return
        petTucked = false
        petView?.setDimmed(false)
        petView?.setAnimationRunning(!petReducedMotion)
        model.playOverlay("dragging", System.currentTimeMillis())
        renderPet(animate = false)
        hideStatus()
        mainHandler.removeCallbacks(autoHideRunnable)
        if (panelVisible) hidePanel()
    }

    private fun endDrag() {
        val model = petModel ?: return
        model.playOverlay("dragging_release", System.currentTimeMillis())
        renderPet(animate = false)
    }

    /** 通知红点：同 key 5 秒内合并（SSE 回放/重复事件防抖），60 秒后自动消退。 */
    private fun markNotif(key: String, text: String) {
        // v3.0.0：整段收敛到主线程——SSE 线程(:connectSse/handleFrame)与主线程调用点可能并发，
        // 非原子 ++ / 非 volatile 读写会丢计数、去重误判；post 后串行执行即无竞态
        mainHandler.post {
            val now = System.currentTimeMillis()
            if (key == lastNotifKey && now - lastNotifAt < 5000) return@post
            lastNotifKey = key
            lastNotifAt = now
            notifCount++
            lastNotif = now
            setState(); showTip(text)
            // 红点 60 秒后自动消退（用户没看也不残留）
            mainHandler.removeCallbacks(clearNotifRunnable)
            mainHandler.postDelayed(clearNotifRunnable, 60000)
        }
    }

    private val clearNotifRunnable = Runnable {
        notifCount = 0
        postState()
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
        val base = baseUrl() ?: return true
        val token = prefs("flutter.dsh_mr_token") ?: return true
        val url = URL("$base/m/api/events")
        val conn = url.openConnection() as HttpURLConnection
        sseConn = conn // v2.7.2 review(FS2)：onDestroy 时 disconnect 解除 readLine 阻塞
        conn.connectTimeout = 8000
        // v3.0.0：readTimeout 0→50s——插件 SSE 每 25s 必有 ": ping" 心跳，50s 只会在
        // 静默死链（TCP 已死但无 FIN/RST：切网/路由器丢连接/PC 休眠）时触发 IOException，
        // 让重连循环兜底；此前 0=无限阻塞，死链后通知断供且永不恢复
        conn.readTimeout = 50_000
        conn.setRequestProperty("x-mobile-token", token)
        conn.setRequestProperty("Accept", "text/event-stream")
        val code = conn.responseCode
        if (code != 200) {
            conn.disconnect()
            sseConn = null
            return false
        }
        val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
        var line: String?
        while (sseAlive) {
            try {
                line = reader.readLine() ?: break
            } catch (_: Exception) {
                break // onDestroy disconnect 后 readLine 抛 IOException → 正常退出
            }
            if (!line.startsWith("data: ")) continue
            val data = line.removePrefix("data: ")
            try {
                handleFrame(JSONObject(data))
            } catch (_: Exception) {
            }
        }
        runCatching { reader.close() }
        runCatching { conn.disconnect() }
        if (sseConn === conn) sseConn = null
        return false
    }

    private fun handleFrame(o: JSONObject) {
        when (o.optString("type")) {
            "session/event" -> handleSessionEvent(o)
            "session/jobs" -> handleJobs(o)
            // v2.7.2：通知（含审批/提问 needs-answer）统一由插件端 mobile/notify 帧驱动，
            // mobile/frame 只承载弹窗数据（App 消费），悬浮球不再自行 markNotif，避免双弹
            "mobile/notify" -> handleNotify(o)
            // v2.7.2 review：顶层 agent/status 帧——running 立即亮，idle 且无近期活动则暗；
            // 忽略子代理帧（child=true，插件端已标记），避免子代理状态干扰全局球
            "agent/status" -> {
                if (!o.optBoolean("child")) {
                    val st = o.optString("status")
                    val now = System.currentTimeMillis()
                    if (st == "running") {
                        agentsRunning = true
                        lastActivity = now
                        applyPetChange(petReducer.onAgentStatus("running", false))
                    } else if (st == "idle" && now - lastActivity > 3000) {
                        agentsRunning = false
                        applyPetChange(petReducer.onAgentStatus("idle", false))
                    }
                }
            }
        }
    }

    /** v2.7.2：插件端真结束判定后推送的通知（完成/失败/需要回答），与 App 通知中心同源。 */
    private fun handleNotify(o: JSONObject) {
        val n = o.optJSONObject("notification") ?: return
        val kind = n.optString("kind")
        val sid = n.optString("sessionId")
        val label = when (kind) {
            "completed" -> text("任务完成", "Task done")
            "failed" -> text("任务失败", "Task failed")
            "needs-answer" -> text("需要你回答", "Your input needed")
            else -> text("通知", "Notification")
        }
        val short = if (sid.length > 8) sid.take(8) else sid
        // v2.7.2 review：seen 集合按通知 id 去重（重连补发同一通知不再重复弹），有上限
        val nid = "notif-${n.optString("id")}"
        if (!seenNotifIds.add(nid)) return
        if (seenNotifIds.size > 200) {
            val it = seenNotifIds.iterator()
            if (it.hasNext()) {
                it.next()
                it.remove()
            }
        }
        markNotif(nid, "$label · $short")
        applyPetChange(petReducer.onNotify(kind))
    }

    private fun handleSessionEvent(o: JSONObject) {
        val ev = o.optJSONObject("event") ?: return
        val type = ev.optString("type")
        val data = ev.optJSONObject("data")
        val now = System.currentTimeMillis()
        when (type) {
            "turn/start" -> {
                agentsRunning = true
                lastActivity = now
                applyPetChange(petReducer.onTurnStart())
            }
            "thinking/start", "step/start", "assistant/chunk", "assistant/message" -> {
                lastActivity = now
                // 高频 chunk 只在非 THINKING/WORKING 时切换，避免反复重绘
                applyPetChange(petReducer.onThinking())
            }
            "tool/call" -> {
                agentsRunning = true
                lastActivity = now
                applyPetChange(petReducer.onToolCall(data?.optString("name")))
            }
            "tool/result" -> {
                lastActivity = now
                applyPetChange(
                    petReducer.onToolResult(
                        data?.optString("name"),
                        data?.optBoolean("isError") == true,
                    ),
                )
            }
            "turn/end" -> {
                agentsRunning = false
                lastActivity = now
                val reasonKind = data?.optJSONObject("reason")?.optString("kind")
                // 完成提示以插件端 mobile/notify 的"真结束"为准；这里只处理错误/阻塞
                applyPetChange(petReducer.onTurnEnd(reasonKind))
            }
            "todo/write" -> updateProgress(data)
        }
        // 面板打开时即时刷新（会话状态变化同步）
        refreshPanelIfOpen()
    }

    private fun updateProgress(data: JSONObject?) {
        val todos = data?.optJSONArray("todos") ?: return
        var completed = 0
        for (i in 0 until todos.length()) {
            val status = todos.optJSONObject(i)?.optString("status")
            if (status == "completed") completed++
        }
        latestProgress = if (todos.length() > 0) completed to todos.length() else null
        updatePanelStatus()
    }

    private fun handleJobs(o: JSONObject) {
        val jobs = o.optJSONArray("jobs") ?: return
        var running = false
        firstJobsFrame = false
        for (i in 0 until jobs.length()) {
            val j = jobs.optJSONObject(i) ?: continue
            val st = j.optString("status")
            if (isBusy(st)) running = true
        }
        // v2.7.2：任务终态通知由插件端 mobile/notify 帧统一驱动（真结束判定），
        // 这里只保留运行状态指示；连接回放帧只学习不弹。
        // review：false 路径不再覆盖 agentsRunning——jobs 帧不校验 sessionId，
        // 任何会话"无运行 job"都会把球误灭（与主轮次 turn/start 是两套信号）；
        // 熄灭交给 turn/end 与 unreadCheckRunnable 的 5 分钟回落
        if (running) {
            agentsRunning = true
            lastActivity = System.currentTimeMillis()
            postState()
        }
        // 面板打开时即时刷新
        refreshPanelIfOpen()
    }

    /** 余额联动：App 侧刷新余额后经 channel 推送（string "total:currency"）。 */
    private fun onBalance(s: String) {
        val parts = s.split(":")
        val total = parts.firstOrNull()?.toDoubleOrNull() ?: return
        applyBalance(total, tip = true)
    }

    /** 应用余额：存值 + 更新面板常驻余额行；tip=true 时按 App 预警配置报警（事件式，不常亮）。 */
    private fun applyBalance(total: Double, tip: Boolean) {
        balanceTotal = total
        lowBalance = alertEnabled && total < alertThreshold
        mainHandler.post {
            setState()
            updateBalanceRow()
            if (tip && lowBalance) {
                // 事件式提醒：亮 60 秒自动消退；30 分钟防抖（余额持续低时不反复打扰）
                val now = System.currentTimeMillis()
                if (now - lastBalanceAlertAt >= 30 * 60 * 1000L) {
                    lastBalanceAlertAt = now
                    balanceAlerting = true
                    mainHandler.removeCallbacks(clearBalanceAlertRunnable)
                    mainHandler.postDelayed(clearBalanceAlertRunnable, 60000)
                    showStatus(
                        text(
                            "余额不足 ¥" + String.format(Locale.ROOT, "%.2f", total) + "，点我去充值",
                            "Low balance ¥" + String.format(Locale.ROOT, "%.2f", total) + " — tap to top up",
                        ),
                        statusDetail(),
                        6000,
                        true,
                    )
                }
            }
        }
    }

    /** 余额报警亮起消退（60 秒后回到暗态）。 */
    private val clearBalanceAlertRunnable = Runnable {
        balanceAlerting = false
        postState()
    }

    /** 面板常驻余额行：有值显示余额（低余额红色），无值显示占位。 */
    private fun updateBalanceRow() {
        val tv = panelBalance ?: return
        val t = balanceTotal
        if (t == null) {
            tv.text = text("余额 --", "Balance --")
            tv.setTextColor(Color.parseColor("#9AA3AF"))
        } else {
            tv.text = text("余额 ¥" + String.format(Locale.ROOT, "%.2f", t), "Balance ¥" + String.format(Locale.ROOT, "%.2f", t))
            tv.setTextColor(if (lowBalance) Color.parseColor("#FF6B6B") else Color.WHITE)
        }
    }

    // ── 用量与额度区块（v3.2）──────────────────────────────────────
    /** 当前区块状态快照（读 volatile 字段，拼给纯模型；可在任意线程调用）。 */
    private fun currentUsageModel(): UsagePanelModel.View = UsagePanelModel.build(
        UsagePanelModel.State(
            allowancePayload, allowanceFetchedAt, allowanceFetching, allowanceLastFetchStart,
            lowBalance, System.currentTimeMillis()
        )
    )

    /**
     * 渲染区块。区块可见时隐藏单行余额（区块内的 DeepSeek 行承担金额展示）；
     * 不可见时恢复单行余额（降级路径，点击语义保持为去充值）。仅主线程调用。
     */
    private fun renderUsageBlock(m: UsagePanelModel.View) {
        val root = panelUsage ?: return
        val bal = panelBalance ?: return
        if (!m.blockVisible) {
            root.visibility = View.GONE
            bal.visibility = View.VISIBLE
            return
        }
        bal.visibility = View.GONE
        root.visibility = View.VISIBLE
        val rowsBox = panelUsageRows ?: return
        rowsBox.removeAllViews()
        if (m.querying) {
            val q = TextView(this)
            q.text = text("查询中…", "Loading…")
            q.setTextColor(Color.parseColor("#5C6470"))
            q.textSize = 11f
            q.setPadding(0, dp(2), 0, dp(2))
            rowsBox.addView(q)
        } else {
            for (row in m.rows) rowsBox.addView(usageRowView(row))
        }
        val st = panelUsageStale ?: return
        if (m.stale) {
            st.text = text("上次更新：", "Updated: ") + relTime(allowanceFetchedAt)
            st.visibility = View.VISIBLE
        } else {
            st.visibility = View.GONE
        }
    }

    /** 一行：左侧来源名 + 右侧金额文字（金额行）或并排细条（配额行）。整行可点 → App 用量页。 */
    private fun usageRowView(row: UsagePanelModel.SourceRow): View {
        val line = LinearLayout(this)
        line.orientation = LinearLayout.HORIZONTAL
        line.gravity = Gravity.CENTER_VERTICAL
        line.setPadding(0, dp(2), 0, dp(2))
        val title = TextView(this)
        title.text = row.title
        title.setTextColor(Color.parseColor("#B4BCC6"))
        title.textSize = 11f
        title.maxLines = 1
        title.ellipsize = android.text.TextUtils.TruncateAt.END
        line.addView(title, LinearLayout.LayoutParams(dp(76), dp(19)))
        if (row.isBalance) {
            val amt = TextView(this)
            val t = row.balance?.text ?: ""
            amt.text = if (t.isEmpty()) text("--", "--") else t
            amt.setTextColor(if (row.balance?.low == true) Color.parseColor("#FF6B6B") else Color.WHITE)
            amt.textSize = 12.5f
            line.addView(amt, LinearLayout.LayoutParams(0, dp(19), 1f))
        } else {
            val bars = LinearLayout(this)
            bars.orientation = LinearLayout.HORIZONTAL
            bars.gravity = Gravity.CENTER_VERTICAL
            for (b in row.bars) {
                bars.addView(usageQuotaCell(b), LinearLayout.LayoutParams(0, dp(19), 1f).apply { setMargins(dp(1), 0, dp(1), 0) })
            }
            line.addView(bars, LinearLayout.LayoutParams(0, dp(19), 1f))
        }
        line.setOnClickListener { hidePanel(); openUsage() }
        return line
    }

    /** 配额单元格：上为窗口短标签（与进度条居中对齐），下为细条。 */
    private fun usageQuotaCell(b: UsagePanelModel.Bar): View {
        val cell = LinearLayout(this)
        cell.orientation = LinearLayout.VERTICAL
        cell.gravity = Gravity.CENTER_HORIZONTAL
        val label = TextView(this)
        label.text = windowShortLabel(b.label)
        label.setTextColor(Color.parseColor("#9AA3AF"))
        label.textSize = 8.5f
        label.gravity = Gravity.CENTER_HORIZONTAL
        label.maxLines = 1
        cell.addView(label, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(10)))
        cell.addView(usageBarView(b), LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(5)))
        return cell
    }

    /** 窗口短标签（与详情页同语义、取简短版）：5h / 每周 / 每月；未知保留原始短标签。 */
    private fun windowShortLabel(raw: String): String = when (raw) {
        "5h" -> text("5h", "5h")
        "weekly" -> text("每周", "weekly")
        "monthly" -> text("每月", "monthly")
        else -> raw
    }

    /** 细条：轨道 + 按剩余比例填充的颜色段（配色沿用 DshTheme 暗色语义色，与详情页一致）。 */
    private fun usageBarView(b: UsagePanelModel.Bar): View {
        val track = LinearLayout(this)
        track.orientation = LinearLayout.HORIZONTAL
        track.background = roundedRect(Color.parseColor("#3A3F47"), 2.5f)
        val color = when (b.severity) {
            UsagePanelModel.Severity.OK -> Color.parseColor("#4CB86F")
            UsagePanelModel.Severity.WARN -> Color.parseColor("#D9A94A")
            UsagePanelModel.Severity.DANGER -> Color.parseColor("#E0655F")
        }
        if (b.ratio > 0.0) {
            val fill = View(this)
            fill.background = roundedRect(color, 2.5f)
            track.addView(fill, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, b.ratio.toFloat()))
        }
        track.addView(View(this), LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, (1.0 - b.ratio).toFloat()))
        return track
    }

    /**
     * 用量与额度拉取：后台线程 + 20 秒超时（面板异步更新，不阻塞 UI）。
     * 成功时缓存 payload 并让预警金额与显示的 DeepSeek 金额同口径；失败静默保留旧值。
     */
    private fun fetchAllowance() {
        if (allowanceFetching) return
        allowanceFetching = true
        allowanceLastFetchStart = System.currentTimeMillis()
        mainHandler.post { renderUsageBlock(currentUsageModel()) }
        Thread({
            try {
                val txt = httpGet("account-usage", 20000)
                val parsed = txt?.let { runCatching { org.json.JSONObject(it) }.getOrNull() }
                if (parsed != null && parsed.optBoolean("ok", false)) {
                    allowancePayload = parsed
                    allowanceFetchedAt = System.currentTimeMillis()
                    // Q12：面板金额与预警金额同口径（CNY 优先），显示与判定一致
                    UsagePanelModel.deepseekAmount(parsed)?.let { amt -> if (amt > 0) applyBalance(amt, tip = false) }
                }
            } catch (_: Exception) {
                // httpGet 已吞网络/HTTP 异常；此处只兜 JSON 意外
            } finally {
                allowanceFetching = false
            }
            mainHandler.post { renderUsageBlock(currentUsageModel()) }
        }, "dsh-bubble-usage").apply { isDaemon = true; start() }
    }

    // ── 动作 ──
    private fun openMain() = openApp()

    private fun openSession(sessionId: String) = openApp("open_session", sessionId)

    private fun openCharge() = openApp("open_charge", true)

    /** 打开 App 通知页（MainActivity extra，Flutter 侧处理）。 */
    private fun openNotifs() = openApp("open_notifs", true)

    /** 打开 App 用量与额度页（MainActivity extra，Flutter 侧处理）。 */
    private fun openUsage() = openApp("open_usage", true)

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

    // ── 公共 helper（Phase 0 收敛：统一 HTTP 骨架/刷新/跳转/圆角/状态判断） ──
    /** 规范化插件 base URL（去尾部 / 与 /m）。 */
    private fun baseUrl(): String? {
        val base = prefs("flutter.dsh_mr_base") ?: return null
        var b = base.trim()
        if (b.endsWith("/")) b = b.dropLast(1)
        if (b.endsWith("/m")) b = b.dropLast(2)
        return b
    }

    /** GET 一个 /m/api 端点；非 200 或异常返回 null（各调用点语义一致：失败静默）。 */
    private fun httpGet(path: String, timeoutMs: Int = 5000): String? {
        val base = baseUrl() ?: return null
        val token = prefs("flutter.dsh_mr_token") ?: return null
        return try {
            val conn = URL("$base/m/api/$path").openConnection() as HttpURLConnection
            conn.connectTimeout = timeoutMs
            // v2.9.0 review(A3)：读超时补齐（默认 0=无限——服务端接受连接但慢回 body 时
            // 后台线程永久阻塞、inflight 累积；SSE 的 connectSse readTimeout=0 是刻意保留长连）
            conn.readTimeout = timeoutMs
            conn.setRequestProperty("x-mobile-token", token)
            try {
                if (conn.responseCode != 200) return null
                conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            null
        }
    }

    /** 主线程刷新 UI。 */
    private fun postState() = mainHandler.post { setState() }

    /** 主 App 启动 Intent（悬浮球跳转与前台通知共用）。
     *  extra 仅支持 String/Boolean/Int（对应 Intent.putExtra 重载）；两个参数必须成对传或都不传。 */
    private fun mainIntent(extraName: String? = null, extraValue: Any? = null): Intent {
        require((extraName == null) == (extraValue == null)) { "extraName/extraValue must be passed together" }
        val i = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        if (extraName != null && extraValue != null) {
            when (extraValue) {
                is String -> i.putExtra(extraName, extraValue)
                is Boolean -> i.putExtra(extraName, extraValue)
                is Int -> i.putExtra(extraName, extraValue)
                else -> throw IllegalArgumentException("unsupported extra type: ${extraValue::class.java.simpleName}")
            }
        }
        return i
    }

    /** 打开主 App，可携带一个面板动作 extra。 */
    private fun openApp(extraName: String? = null, extraValue: Any? = null) {
        startActivity(mainIntent(extraName, extraValue))
    }

    /** 圆角矩形背景。 */
    private fun roundedRect(color: Int, rDp: Float): GradientDrawable =
        GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(rDp).toFloat()
            setColor(color)
        }

    /** 状态是否为"有任务/等待中"（bootstrap 判定）。 */
    private fun isActive(st: String) = st == "running" || st == "waiting"

    /** 状态是否为"执行中/停止中"（jobs 判定）。 */
    private fun isBusy(st: String) = st == "running" || st == "stopping"

    /** 未读增量对比：重连/离线期间新增的通知也能提示（不只靠实时事件）。
     *  Phase 0 收敛：HTTP 失败直接跳过——基线只在首次成功时建立，
     *  瞬时失败不会把基线清零导致下次误报存量（review 确认：比旧逻辑更稳）。 */
    private fun checkUnreadDelta() {
        if (panelVisible) return // 面板开着=正在看，不打扰
        Thread({
            try {
                val txt = httpGet("notifications") ?: return@Thread
                val unread = JSONObject(txt).optInt("unread")
                mainHandler.post {
                    if (firstUnreadCheck) {
                        // 首次（服务启动）：只记录基线，不提示存量
                        firstUnreadCheck = false
                        lastUnreadCount = unread
                        return@post
                    }
                    if (unread > lastUnreadCount) {
                        val diff = unread - lastUnreadCount
                        // 防抖：事件驱动刚提示过（60 秒内）则只更新基线，避免重复气泡
                        if (System.currentTimeMillis() - lastNotifAt > 60000) {
                            markNotif("unread-delta", text("有 $diff 条新通知", "$diff new notification" + if (diff > 1) "s" else ""))
                        }
                        lastUnreadCount = unread
                    } else {
                        lastUnreadCount = unread
                    }
                }
            } catch (_: Exception) {}
        }, "dsh-bubble-unread").apply { isDaemon = true; start() }
    }

    private fun exitBubble(why: String) {
        stopSelf()
    }

    private fun petHeightPx(): Int = dp(petHeightDp)

    private fun petWidthPx(): Int {
        val manifest = petManifest ?: return (petHeightPx() * 288f / 229f).toInt()
        return (petHeightPx().toFloat() * manifest.canvasWidth / manifest.canvasHeight).toInt()
    }

    /** 贴边缩进时保留的可见宽度：至少 24dp，且不小于宠物画布的 45%（避免只露出透明边）。 */
    private fun edgePeekPx(): Int = maxOf(dp(24), (petWidthPx() * 0.45f).toInt())

    /** 设置页改大小后原地缩放，不重建窗口。 */
    private fun resizePet() {
        val p = bubbleParams ?: return
        val root = bubble ?: return
        val wm = this.wm ?: return
        val w = petWidthPx()
        val h = petHeightPx()
        val size = screenSize()
        // 改大小后如果正处于贴边隐藏，立即按新宽度重新缩进；否则保持原可见位置。
        val renderX = if (petTucked) {
            if (edgeSide < 0) -w + edgePeekPx() else size.x - edgePeekPx()
        } else {
            val minX = -w + edgePeekPx()
            val maxX = maxOf(minX, size.x - edgePeekPx())
            bubbleRenderX().coerceIn(minX, maxX)
        }
        val renderY = bubbleRenderY().coerceIn(0, (size.y - h).coerceAtLeast(0))
        p.width = w
        p.height = h
        p.x = renderX - overlayInsetLeft()
        p.y = renderY - overlayInsetTop()
        root.layoutParams = FrameLayout.LayoutParams(w, h)
        petView?.layoutParams = FrameLayout.LayoutParams(w, h)
        lastRenderX = renderX
        lastScreenW = size.x
        lastScreenH = size.y
        wm.updateViewLayout(root, p)
        positionStatusBubble()
        updateBadgePosition()
        if (panelVisible) placePanel()
    }

    private fun prefs(key: String): String? {
        val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return sp.getString(key, null)
    }

    private fun prefsInt(key: String, fallback: Int): Int {
        val sp = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        // Flutter shared_preferences 在 Android 上把 Dart int 存成 Long；getInt 会 ClassCastException。
        return try {
            sp.getInt(key, fallback)
        } catch (_: ClassCastException) {
            try {
                sp.getLong(key, fallback.toLong()).toInt()
            } catch (_: ClassCastException) {
                fallback
            }
        }
    }

    private fun prefsBool(key: String, fallback: Boolean): Boolean =
        getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getBoolean(key, fallback)

    private fun text(zh: String, en: String): String {
        val lang = prefs("flutter.dsh_mr_language") ?: "zh"
        return if (lang == "en") en else zh
    }

    private fun dp(v: Float): Int = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v, resources.displayMetrics).toInt()
    private fun dp(v: Int): Int = dp(v.toFloat())
}
