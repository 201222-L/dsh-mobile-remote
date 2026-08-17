package com.dsh.remote

import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.browser.customtabs.CustomTabsIntent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var floatingChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/custom_tabs")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrEmpty()) {
                            result.error("bad-url", "url required", null)
                        } else {
                            openCustomTab(url)
                            result.success(true)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        floatingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dsh/floating")
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
                        val i = Intent(this, FloatingBubbleService::class.java).putExtra("balance", v)
                        startServiceCompat(i)
                        result.success(true)
                    }
                    "consumeOpenPanel" -> {
                        result.success(false)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // 悬浮球迷你面板动作：通知 Flutter 侧执行（App 可能正在前台）
        if (intent.getBooleanExtra("open_charge", false)) {
            floatingChannel?.invokeMethod("openChargeRequested", null)
        }
        val session = intent.getStringExtra("open_session")
        if (session != null && session.isNotEmpty()) {
            floatingChannel?.invokeMethod("openSessionRequested", session)
        }
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
                Uri.parse("package:$packageName")
            )
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
        } catch (e: Exception) {
            val i = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION)
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(i)
        }
    }

    /** Chrome Custom Tabs 打开链接：复用浏览器登录态、支付可正常唤起；
     *  设备无 Custom Tabs 服务时兜底普通浏览器（ACTION_VIEW）。 */
    private fun openCustomTab(url: String) {
        try {
            val builder = CustomTabsIntent.Builder()
            builder.setShowTitle(true)
            builder.setToolbarColor(Color.parseColor("#1A1D24"))
            builder.setColorScheme(CustomTabsIntent.COLOR_SCHEME_DARK)
            builder.setInstantAppsEnabled(false)
            val intent = builder.build()
            intent.intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.launchUrl(this, Uri.parse(url))
        } catch (e: Exception) {
            val fallback = Intent(Intent.ACTION_VIEW, Uri.parse(url))
            fallback.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(fallback)
        }
    }
}
