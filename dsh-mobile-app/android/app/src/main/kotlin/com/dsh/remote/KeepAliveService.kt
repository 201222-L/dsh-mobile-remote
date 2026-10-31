package com.dsh.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * 后台提醒保活服务（v3.3.3，issue #55）。
 *
 * 职责只有一个：**让进程别被系统冻死**。它自己不发任何业务通知，也不发 HTTP
 * 请求——审批/提问的判定、去重、撤销、点击跳转全部仍在 Dart 侧
 * （`attention.dart` + `local_notifications.dart`，已有单测覆盖）。
 *
 * 为什么需要它：Android 的 cached-app freezer 会把退到后台的进程冻结，
 * Dart isolate / SSE 随之停转。挂一个前台服务能让进程保持 active 状态，
 * 网络不受限。
 *
 * 历史教训（2026-10-31 评审）：本服务曾在 `AndroidManifest.xml` 中**没有声明**，
 * 连累 ka2/ka3/poll/poll2 四版 APK 的实验全部无效——`startForegroundService`
 * 对不存在的组件只在 logcat 打一行 `not found`，不抛异常，UI 照样显示"启动成功"。
 * 因此现在：
 *   - `MainActivity.startKeepAlive()` 先用 `resolveService` 校验组件可解析；
 *   - 构建脚本断言合并后的清单里确实有 `KeepAliveService`。
 *
 * 边界：划掉最近任务即退出（`onTaskRemoved`），不做"进程已死、通知还在"的假在线。
 */
class KeepAliveService : Service() {

    companion object {
        // v2：渠道重要度创建后不可修改，只能换 id。LOW 在 MIUI 上会被折叠，改用 DEFAULT。
        const val CHANNEL_ID = "dsh_keepalive_v2"
        const val NOTIFICATION_ID = 0xDBB
        const val ACTION_START = "com.dsh.remote.keepalive.START"
        const val ACTION_STOP = "com.dsh.remote.keepalive.STOP"

        /** 服务是否在运行（供 Dart 诊断 / 补启动判断）。 */
        @Volatile
        var running: Boolean = false
            private set

        /** 最近一次启动失败原因；成功时为 null。 */
        @Volatile
        var lastError: String? = null
            private set

        /** 本次启动时间戳（ms），用于诊断"跑了多久"。 */
        @Volatile
        var startedAt: Long = 0
            private set

        /**
         * 心跳计数：服务自己每 30 秒 +1（落在 prefs，跨冻结/重建可读）。
         *
         * 为什么需要它：真机上 App 退后台 90 秒内 Dart 侧一行日志都没有，但这既可能是
         * "整个进程被 MIUI 冻结"，也可能是"只有 Dart isolate 停转"——两种情况的解法完全
         * 不同（前者只能靠系统白名单，后者该把网络/通知下沉到原生）。
         * 原生心跳 + Dart 心跳一起看，才能判断到底冻在哪一层。
         */
        private const val PREFS = "dsh_keepalive"
        private const val KEY_BEAT_COUNT = "beatCount"
        private const val KEY_BEAT_AT = "beatAt"
        private const val BEAT_INTERVAL_MS = 30_000L

        fun beatStats(ctx: Context): Pair<Int, Long> {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return p.getInt(KEY_BEAT_COUNT, 0) to p.getLong(KEY_BEAT_AT, 0L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private val beatHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val beatRunnable = object : Runnable {
        override fun run() {
            val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val n = prefs.getInt(KEY_BEAT_COUNT, 0) + 1
            val now = System.currentTimeMillis()
            prefs.edit().putInt(KEY_BEAT_COUNT, n).putLong(KEY_BEAT_AT, now).apply()
            android.util.Log.i("DSH", "KeepAliveService beat #$n")
            beatHandler.postDelayed(this, BEAT_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        try {
            createChannel()
            startForegroundCompat()
            running = true
            lastError = null
            startedAt = System.currentTimeMillis()
            android.util.Log.i("DSH", "KeepAliveService started")
            beatHandler.postDelayed(beatRunnable, BEAT_INTERVAL_MS)
        } catch (e: Throwable) {
            running = false
            lastError = "${e.javaClass.simpleName}: ${e.message}"
            android.util.Log.e("DSH", "KeepAliveService start failed: $lastError")
            stopSelf()
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            startForegroundCompat()
            running = true
        } catch (e: Throwable) {
            running = false
            lastError = "${e.javaClass.simpleName}: ${e.message}"
            android.util.Log.e("DSH", "KeepAliveService restart failed: $lastError")
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        beatHandler.removeCallbacksAndMessages(null)
        android.util.Log.i("DSH", "KeepAliveService destroyed")
        super.onDestroy()
    }

    // ── 常驻通知 ─────────────────────────────────────────────────────────

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "后台连接",
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = "保持连接以便在后台收到审批提醒"
                setShowBadge(false)
            },
        )
    }

    private fun buildNotification(): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
        val pending = intent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("DSH Remote")
            .setContentText("已连接 · 审批会即时提醒")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
        if (pending != null) builder.setContentIntent(pending)
        return builder.build()
    }
}
