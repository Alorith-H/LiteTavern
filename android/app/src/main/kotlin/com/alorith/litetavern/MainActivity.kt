package com.alorith.litetavern

import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 额外职责：把下载好的 APK 交给系统安装器（v0.23.0 自动更新）。
 * 用平台通道而不是再加插件，保持零新依赖。
 */
class MainActivity : FlutterActivity() {
    private val installerChannel = "litetavern/installer"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, installerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("bad_path", "缺少安装包路径", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val apk = File(path)
                            if (!apk.exists() || !apk.isFile) {
                                result.error("missing_apk", "安装包不存在，请重新下载", null)
                                return@setMethodCallHandler
                            }
                            val uri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                apk
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("install_failed", e.message ?: "无法打开系统安装界面", null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
