package com.dsh.remote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import java.util.Locale

/**
 * 只在用户发起的文件传输期间提高进程优先级；网络与私有断点仍由 Dart 唯一管理。
 * 不依赖宠物/提醒保活开关，不重启任务；Doze 或系统撤销后由已有断点恢复。
 */
class DownloadService : Service() {
    companion object {
        const val CHANNEL_ID = "dsh_downloads"
        const val NOTIFICATION_ID = 0xDBD
        const val ACTION_PAUSE = "com.dsh.remote.download.PAUSE"
        internal val session = DownloadSessionState()
        @Volatile var running = false
            private set
        var stopping = false
            private set
        var onPaused: ((String, String) -> Unit)? = null
        private var instance: DownloadService? = null

        fun progress(id: String, received: Long, total: Long?) {
            if (session.update(id, received, total)) instance?.refreshNotification()
        }

        fun finish(id: String) {
            if (!session.end(id)) return
            stopping = instance != null
            instance?.stopForeground(STOP_FOREGROUND_REMOVE)
            instance?.stopSelf()
        }
    }

    private var ownerId: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, text("文件下载", "File downloads"), NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) })
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("id")
        if (id == null || session.id != id) {
            if (session.id == null) stopSelf()
            return START_NOT_STICKY
        }
        if (intent.action == ACTION_PAUSE) {
            pause(id, "user")
            return START_NOT_STICKY
        }
        ownerId = id
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(NOTIFICATION_ID, notification(id), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification(id))
            }
            running = true
        } catch (_: Exception) {
            pause(id, "service-unavailable")
        }
        return START_NOT_STICKY
    }

    /** Android 15+ dataSync 预算由系统累计；收到回调即停止，不靠重启服务重置预算。 */
    override fun onTimeout(startId: Int, fgsType: Int) {
        session.id?.let { pause(it, "system-time-limit") } ?: stopSelf()
    }

    override fun onDestroy() {
        val id = ownerId
        if (id != null && session.id == id) {
            session.end(id)
            runCatching { onPaused?.invoke(id, "service-stopped") }
        }
        if (instance === this) {
            running = false
            stopping = false
            instance = null
        }
        super.onDestroy()
    }

    private fun pause(id: String, reason: String) {
        if (!session.end(id)) return
        running = false
        stopping = true
        // 引擎解绑/桥回调失败不能阻止系统要求的服务停止。
        runCatching { onPaused?.invoke(id, reason) }
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun refreshNotification() {
        val id = session.id ?: return
        if (running) getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification(id))
    }

    private fun text(zh: String, en: String): String =
        if (getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.dsh_mr_language", "zh") == "en") en else zh

    private fun notification(id: String): Notification {
        val pause = PendingIntent.getService(this, 0,
            Intent(this, DownloadService::class.java).setAction(ACTION_PAUSE).putExtra("id", id),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 1,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val bytes = String.format(Locale.ROOT, "%.1f MiB", session.received / 1048576.0)
        val size = session.total
        val progress = size?.let { ((session.received.toDouble() / it) * 1000).toInt().coerceIn(0, 1000) } ?: 0
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID) else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        builder.setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(text("正在下载文件", "Downloading a file"))
            .setContentText(bytes)
            .setContentIntent(open)
            .setOngoing(true).setOnlyAlertOnce(true).setShowWhen(false)
            .setProgress(1000, progress, size == null)
            .addAction(Notification.Action.Builder(null, text("暂停", "Pause"), pause).build())
        if (Build.VERSION.SDK_INT >= 31) builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
        return builder.build()
    }
}
