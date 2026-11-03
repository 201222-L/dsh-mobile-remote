package com.dsh.remote

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.security.MessageDigest

object AppUpdateInstaller {
    @Suppress("DEPRECATION")
    private fun certificates(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
        return (signatures ?: emptyArray()).map {
            MessageDigest.getInstance("SHA-256").digest(it.toByteArray()).joinToString("") { b -> "%02x".format(b) }
        }.toSet()
    }

    @Suppress("DEPRECATION")
    fun verify(activity: Activity, args: Map<*, *>): String? {
        val path = args["path"] as? String ?: return "apk-path-invalid"
        val file = File(path).canonicalFile
        val root = File(activity.cacheDir, "updates").canonicalFile
        if (file.parentFile != root || !file.isFile || file.length() > 300L * 1024 * 1024) return "apk-path-invalid"
        if (file.length() != (args["size"] as? Number)?.toLong()) return "artifact-size-mismatch"
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        if (digest.digest().joinToString("") { "%02x".format(it) } != args["sha256"]) return "artifact-hash-mismatch"
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val apk = activity.packageManager.getPackageArchiveInfo(file.path, flags) ?: return "apk-invalid"
        val current = activity.packageManager.getPackageInfo(activity.packageName, flags)
        if (apk.packageName != activity.packageName || apk.versionName != args["versionName"]) return "apk-identity-mismatch"
        val code = if (Build.VERSION.SDK_INT >= 28) apk.longVersionCode else apk.versionCode.toLong()
        val installed = if (Build.VERSION.SDK_INT >= 28) current.longVersionCode else current.versionCode.toLong()
        if (code != (args["versionCode"] as? Number)?.toLong() || code <= installed) return "apk-not-newer"
        val candidateCerts = certificates(apk)
        if (candidateCerts.isEmpty() || candidateCerts != certificates(current) || args["certificate"] !in candidateCerts) return "certificate-mismatch"
        return null
    }

    fun launch(activity: Activity, path: String): String {
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            return "permission-required"
        }
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.updates", File(path))
        activity.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
        return "installer-started"
    }
}
