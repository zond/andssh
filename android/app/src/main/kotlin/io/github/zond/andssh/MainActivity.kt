package io.github.zond.andssh

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val clipboardChannel = "andssh/clipboard"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            clipboardChannel
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSensitiveText" -> {
                    val text = call.argument<String>("text").orEmpty()
                    copySensitive(text)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Writes [text] to the system clipboard and flags it as sensitive so
    /// Android 13+ elides it from the paste-toast preview and other UI
    /// surfaces. Pre-API-33 we set the same data without the flag (the
    /// system just ignores unknown extras anyway).
    private fun copySensitive(text: String) {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText("andssh", text)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val extras = PersistableBundle().apply {
                putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
            }
            clip.description.extras = extras
        }
        cm.setPrimaryClip(clip)
    }
}
