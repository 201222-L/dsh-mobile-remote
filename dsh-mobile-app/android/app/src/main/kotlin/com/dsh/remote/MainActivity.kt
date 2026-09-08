package com.dsh.remote

import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var floatingChannel: MethodChannel? = null
    private var filesChannel: MethodChannel? = null
    // v3.1.2（csborbbnc 反馈）：系统文件选择器（ACTION_OPEN_DOCUMENT）结果回传暂存
    private var pendingPick: MethodChannel.Result? = null
    private val pickFileRequestCode = 2001
    // v2.7.2 review(FS1)：悬浮球面板动作可能发生在冷启动（进程已被系统杀死时点"打开会话/充值/通知"），
    // 此时走 onCreate 而非 onNewIntent；Flutter 引擎未就绪前先暂存，configureFlutterEngine 后再投递。
    private var pendingOpenAction: String? = null // "charge" | "notifs" | "session:<id>"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // v2.9.0 review(A2)：Android 13+ 运行时请求通知权限（manifest 已声明 POST_NOTIFICATIONS）——
        // 不请求则悬浮球"运行中/点击回到 App"前台服务通知被系统抑制，用户看不到常驻提示
        if (Build.VERSION.SDK_INT >= 33) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
                android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1001)
            }
        }
        handleIntentExtras(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        floatingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/floating")
        // v3.1.2（csborbbnc 反馈）：文件下载/上传原生通道
        filesChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/files")
        filesChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "saveToDownloads" -> {
                    val name = call.argument<String>("name") ?: "file"
                    val bytes = call.argument<ByteArray>("bytes")
                    if (bytes == null) {
                        result.error("bad-args", "missing bytes", null)
                        return@setMethodCallHandler
                    }
                    saveToDownloads(name, bytes, result)
                }
                "pickFile" -> pickFile(result)
                else -> result.notImplemented()
            }
        }
        // 引擎就绪：投递冷启动暂存的面板动作
        deliverPendingAction()
        // v2.7.2 review：Dart 侧 handler 注册可能晚于本回调——延迟再投一次 + consume 兜底
        android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({ deliverPendingAction() }, 800)
        floatingChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    startBubbleService()
                    result.success(true)
                }
                "stop" -> {
                    stopService(Intent(this, FloatingBubbleService::class.java))
                    result.success(true)
                }
                "isRunning" -> result.success(FloatingBubbleService.running)
                "canDrawOverlay" -> result.success(Settings.canDrawOverlays(this))
                "openOverlaySettings" -> {
                    openOverlaySettingsPage()
                    result.success(true)
                }
                // v2.7.2 review：冷启动动作兜底——Dart 首帧后主动拉取（投递失败时动作不丢）
                "consumeOpenPanel" -> {
                    result.success(pendingOpenAction)
                    pendingOpenAction = null
                }
                "notifyBalance" -> {
                    val v = call.argument<String>("value") ?: ""
                    // 服务未运行时忽略（否则余额刷新会把悬浮球拉起来，开关形同虚设）
                    if (FloatingBubbleService.running) {
                        val i = Intent(this, FloatingBubbleService::class.java).putExtra("balance", v)
                        startServiceCompat(i)
                    }
                    result.success(true)
                }
                "setBalanceAlert" -> {
                    // 余额预警配置（开关 + 阈值）推给悬浮球：悬浮球的报警判定完全以 App 端设置为依据
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val threshold = call.argument<String>("threshold")?.toDoubleOrNull() ?: 10.0
                    if (FloatingBubbleService.running) {
                        val i = Intent(this, FloatingBubbleService::class.java)
                            .putExtra("alert_enabled", enabled)
                            .putExtra("alert_threshold", threshold)
                        startServiceCompat(i)
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 悬浮球迷你面板动作（热启动路径）：暂存后投递（引擎就绪时立即生效）
        handleIntentExtras(intent)
    }

    /** 解析悬浮球面板动作 extra；onCreate（冷启动）与 onNewIntent（热启动）共用。 */
    private fun handleIntentExtras(intent: Intent?) {        if (intent == null) return
        when {
            intent.getBooleanExtra("open_charge", false) -> pendingOpenAction = "charge"
            intent.getBooleanExtra("open_notifs", false) -> pendingOpenAction = "notifs"
            else -> intent.getStringExtra("open_session")?.let { pendingOpenAction = "session:$it" }
        }
        deliverPendingAction()
    }

    /** 投递暂存的面板动作到 Flutter 侧（引擎未就绪时 no-op，等 configureFlutterEngine 再投）。 */
    private fun deliverPendingAction() {
        val action = pendingOpenAction ?: return
        val ch = floatingChannel ?: return
        when {
            action == "charge" -> ch.invokeMethod("openChargeRequested", null)
            action == "notifs" -> ch.invokeMethod("openNotifsRequested", null)
            action.startsWith("session:") -> {
                val sid = action.removePrefix("session:")
                if (sid.isNotEmpty()) ch.invokeMethod("openSessionRequested", sid)
            }
        }
        pendingOpenAction = null
    }

    private fun startBubbleService() {
        val i = Intent(this, FloatingBubbleService::class.java)
        startServiceCompat(i)
    }

    private fun startServiceCompat(i: Intent) {
        if (Build.VERSION.SDK_INT >= 26) {
            startForegroundService(i)
        } else {
            startService(i)
        }
    }

    private fun openOverlaySettingsPage() {
        try {
            val i = Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                android.net.Uri.parse("package:$packageName")
            )
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
        } catch (e: Exception) {
            val i = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
        }
    }

    // ── v3.1.2（csborbbnc 反馈）：文件保存 / 系统文件选择器 ──────────────────
    /** 保存到系统「下载」目录：Android 10+ 用 MediaStore（免权限）；更早版本退到应用下载目录。 */
    private fun saveToDownloads(name: String, bytes: ByteArray, result: MethodChannel.Result) {
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                val values = android.content.ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(name))
                    put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/DSH-Remote")
                }
                val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                    ?: throw IllegalStateException("MediaStore insert failed")
                contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
                    ?: throw IllegalStateException("openOutputStream failed")
                result.success("Download/DSH-Remote/$name")
            } else {
                val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                val f = File(dir, name)
                f.writeBytes(bytes)
                result.success("Android/data/com.dsh.remote/files/Download/$name")
            }
        } catch (e: Exception) {
            result.error("save-failed", e.message ?: "save failed", null)
        }
    }

    /** 系统文件选择器（ACTION_OPEN_DOCUMENT），结果经 onActivityResult 回传 {name, bytes}。 */
    private fun pickFile(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "already picking", null)
            return
        }
        pendingPick = result
        startActivityForResult(
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            },
            pickFileRequestCode,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == pickFileRequestCode) {
            val res = pendingPick
            pendingPick = null
            if (resultCode == RESULT_OK && data?.data != null) {
                val uri = data.data!!
                try {
                    val name = queryDisplayName(uri) ?: "file"
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: byteArrayOf()
                    res?.success(hashMapOf("name" to name, "bytes" to bytes))
                } catch (e: Exception) {
                    res?.error("read-failed", e.message ?: "read failed", null)
                }
            } else {
                res?.error("cancelled", null, null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val i = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (i >= 0 && c.moveToFirst()) return c.getString(i)
        }
        return uri.lastPathSegment
    }

    private fun mimeOf(name: String): String = when (name.substringAfterLast('.', "").lowercase()) {
        "txt", "md", "log" -> "text/plain"
        "json" -> "application/json"
        "pdf" -> "application/pdf"
        "png" -> "image/png"
        "jpg", "jpeg" -> "image/jpeg"
        "gif" -> "image/gif"
        "webp" -> "image/webp"
        "zip" -> "application/zip"
        "mp4" -> "video/mp4"
        else -> "application/octet-stream"
    }
}
