package dev.aer.rdp

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val audioChannelName = "dev.aer.rdp/audio"
    private var audioSink: AudioTrackSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val sink = audioSink ?: AudioTrackSink(applicationContext).also { audioSink = it }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioChannelName)
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
