package dev.aer.rdp

import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Display
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import kotlin.math.abs

class MainActivity : FlutterActivity() {
    private val audioChannelName = "dev.aer.rdp/audio"
    private val displayChannelName = "dev.aer.rdp/display"
    private var audioSink: AudioTrackSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        volumeControlStream = AudioManager.STREAM_MUSIC
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val sink = audioSink ?: AudioTrackSink(applicationContext).also { audioSink = it }
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        val audioTaskQueue = messenger.makeBackgroundTaskQueue()

        MethodChannel(messenger, audioChannelName, StandardMethodCodec.INSTANCE, audioTaskQueue)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "open" -> {
                        val sampleRate = call.argument<Int>("sampleRate") ?: 48000
                        val channels = call.argument<Int>("channels") ?: 2
                        val bitsPerSample = call.argument<Int>("bitsPerSample") ?: 16
                        result.success(sink.open(sampleRate, channels, bitsPerSample))
                    }
                    "writePcm" -> {
                        val pcm = call.argument<ByteArray>("pcmBytes") ?: ByteArray(0)
                        result.success(sink.writePcm(pcm))
                    }
                    "pollPlayoutDelta" -> {
                        result.success(sink.pollPlayoutDelta())
                    }
                    "pause" -> {
                        sink.pause()
                        result.success(null)
                    }
                    "resume" -> {
                        sink.resume()
                        result.success(null)
                    }
                    "close" -> {
                        sink.close()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, displayChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setPreferredFrameRate" -> {
                        val fps = (call.argument<Number>("fps")?.toFloat() ?: 0f)
                        applyPreferredFrameRate(fps)
                        result.success(null)
                    }
                    "log" -> {
                        val msg = call.argument<String>("message") ?: ""
                        if (msg.isNotEmpty()) {
                            Log.i("AerRdp", msg)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun applyPreferredFrameRate(targetFps: Float) {
        try {
            val attrs = window.attributes
            if (targetFps <= 0f) {
                attrs.preferredRefreshRate = 0f
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    attrs.preferredDisplayModeId = 0
                }
                window.attributes = attrs
                return
            }

            attrs.preferredRefreshRate = targetFps
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val disp: Display? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    display
                } else {
                    @Suppress("DEPRECATION")
                    windowManager.defaultDisplay
                }
                val currentMode = disp?.mode
                val supported = disp?.supportedModes
                if (currentMode != null && !supported.isNullOrEmpty()) {
                    val sameRes = supported.filter {
                        it.physicalWidth == currentMode.physicalWidth &&
                            it.physicalHeight == currentMode.physicalHeight
                    }
                    val candidates = if (sameRes.isNotEmpty()) sameRes else supported.toList()
                    val best = candidates.minByOrNull { mode ->
                        val diff = mode.refreshRate - targetFps
                        if (diff >= -1.0f) abs(diff) else (1000f + abs(diff))
                    }
                    if (best != null) {
                        attrs.preferredDisplayModeId = best.modeId
                    }
                }
            }
            window.attributes = attrs
            Log.i("AerRdp", "Preferred refresh rate updated: targetFps=$targetFps modeId=${attrs.preferredDisplayModeId}")
        } catch (t: Throwable) {
            Log.w("AerRdp", "Failed to set preferred frame rate: ${t.message}")
        }
    }

    override fun onPause() {
        audioSink?.onActivityPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        audioSink?.onActivityResume()
    }

    override fun onDestroy() {
        audioSink?.close()
        audioSink = null
        super.onDestroy()
    }
}
