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
 * 后台提醒保活（issue #55）。
 *
 * 只负责把进程保持在前台（一条低干扰常驻通知），不自己连 SSE——审批/提问帧仍由
 * Flutter 侧（Dart isolate）接收并发本地通知。系统冻结后台进程时这条链路才断。
 *
 * 与 FloatingBubbleService（桌面宠物）互斥：两者都是 specialUse 前台服务，
 * 同时开会留下两条常驻通知，因此由 MainActivity 在启动时先停另一个。
 */
class KeepAliveService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        createChannel()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF_ID,
                notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIF_ID, notification)
        }
        return START_STICKY
    }

    /** 用户划掉最近任务：诚实退出，避免"通知还在、进程已死"的假在线。 */
    override fun onTaskRemoved(rootIntent: Intent?) {
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            "后台提醒",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "保持连接，审批与提问即时提醒"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val open = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("已连接 · 审批会即时提醒")
            .setContentText("保持后台连接，收到审批或提问立即提醒")
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentIntent(pi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .build()
    }

    companion object {
        const val ACTION_STOP = "com.dsh.remote.STOP_KEEP_ALIVE"
        private const val CHANNEL_ID = "dsh_keep_alive"
        private const val NOTIF_ID = 1041

        @Volatile
        var running = false
            private set
    }
}
