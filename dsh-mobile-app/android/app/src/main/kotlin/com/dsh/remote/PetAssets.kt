package com.dsh.remote

import android.content.Context
import io.flutter.embedding.engine.loader.ApplicationInfoLoader

/** 首页和桌面宠物共用 APK 内的 Flutter asset bundle；不需要启动 Dart 引擎。 */
internal object PetAssets {
    fun key(context: Context, relative: String): String =
        ApplicationInfoLoader.load(context.applicationContext).flutterAssetsDir + "/assets/$relative"
}
