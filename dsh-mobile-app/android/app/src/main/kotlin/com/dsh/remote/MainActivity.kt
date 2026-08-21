package com.dsh.remote

import android.content.Intent
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var floatingChannel: MethodChannel? = null
    // v2.7.2 review(FS1)：悬浮球面板动作可能发生在冷启动（进程已被系统杀死时点"打开会话/充值/通知"），
    // 此时走 onCreate 而非 onNewIntent；Flutter 引擎未就绪前先暂存，configureFlutterEngine 后再投递。
    private var pendingOpenAction: String? = null // "charge" | "notifs" | "session:<id>"

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntentExtras(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        floatingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/floating")
        // 引擎就绪：投递冷启动暂存的面板动作
        deliverPendingAction()
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
    private fun handleIntentExtras(intent: Intent?) {
        if (intent == null) return
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
}
