package com.dsh.remote

import android.Manifest
import android.app.Activity
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** 引擎只转交传输生命周期，不向原生服务传 URL、口令或远端路径。 */
internal class DownloadBridge(private val activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dsh/download")
    private val handler = Handler(Looper.getMainLooper())
    var foreground = false
    private var closed = false
    private val paused: (String, String) -> Unit = { id, reason ->
        if (!closed) channel.invokeMethod("paused", mapOf("id" to id, "reason" to reason))
    }

    init {
        DownloadService.onPaused = paused
        channel.setMethodCallHandler { call, result ->
            val id = call.argument<String>("id")
            if (id == null || !Regex("[A-Za-z0-9-]{1,100}").matches(id)) {
                result.error("download-id-invalid", "Invalid download identity", null)
                return@setMethodCallHandler
            }
            when (call.method) {
                "start" -> start(id, result)
                "progress" -> {
                    DownloadService.progress(id,
                        call.argument<Number>("received")?.toLong() ?: 0,
                        call.argument<Number>("total")?.toLong())
                    result.success(null)
                }
                "finish" -> { DownloadService.finish(id); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun start(id: String, result: MethodChannel.Result, retry: Int = 0) {
        if (!foreground || closed) {
            result.success(mapOf("running" to false, "reason" to "app-background"))
            return
        }
        if (DownloadService.stopping) {
            if (retry < 30) handler.postDelayed({ start(id, result, retry + 1) }, 100)
            else result.success(mapOf("running" to false, "reason" to "service-unavailable"))
            return
        }
        val manager = activity.getSystemService(NotificationManager::class.java)
        if ((Build.VERSION.SDK_INT >= 33 && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) ||
            (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) ||
            (Build.VERSION.SDK_INT >= 26 && manager.getNotificationChannel(DownloadService.CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE)) {
            result.success(mapOf("running" to false, "reason" to "notification-disabled"))
            return
        }
        if (!DownloadService.session.begin(id)) {
            result.error("download-in-progress", "Another file is downloading", null)
            return
        }
        try {
            val intent = Intent(activity, DownloadService::class.java).putExtra("id", id)
            if (Build.VERSION.SDK_INT >= 26) activity.startForegroundService(intent) else activity.startService(intent)
            // startForegroundService 返回不代表服务已进入运行态，等待实际 onStartCommand。
            fun confirm(attempt: Int) {
                if (closed) {
                    DownloadService.finish(id)
                    result.success(mapOf("running" to false, "reason" to "engine-detached"))
                } else if (DownloadService.running && DownloadService.session.id == id) {
                    result.success(mapOf("running" to true))
                } else if (attempt >= 30 || DownloadService.session.id != id) {
                    DownloadService.finish(id)
                    result.success(mapOf("running" to false, "reason" to "service-unavailable"))
                } else handler.postDelayed({ confirm(attempt + 1) }, 100)
            }
            confirm(0)
        } catch (_: Exception) {
            DownloadService.finish(id)
            result.success(mapOf("running" to false, "reason" to "service-unavailable"))
        }
    }

    fun close() {
        closed = true
        if (DownloadService.onPaused === paused) {
            DownloadService.onPaused = null
            DownloadService.session.id?.let { DownloadService.finish(it) }
        }
        channel.setMethodCallHandler(null)
    }
}
