package dev.aer.rdp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build

class AudioTrackSink(private val context: Context) {
    private val audioManager: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private var track: AudioTrack? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasAudioFocus: Boolean = false
    private var isPaused: Boolean = false
    private var isFocusLost: Boolean = false
    private var lastHeadPosUnsigned: Long = 0L
    private var maxBufferBytes: Int = 0
    private var pendingTail: ByteArray? = null

    private val focusListener = AudioManager.OnAudioFocusChangeListener { focusChange ->
        synchronized(this@AudioTrackSink) {
            when (focusChange) {
                AudioManager.AUDIOFOCUS_GAIN -> {
                    isFocusLost = false
                    hasAudioFocus = true
                    track?.let { t ->
                        t.setVolume(1.0f)
                        if (!isPaused && t.playState != AudioTrack.PLAYSTATE_PLAYING) {
                            t.play()
                            lastHeadPosUnsigned = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                        }
                    }
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                    track?.setVolume(0.2f)
                }
                AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                    isFocusLost = true
                    pauseTrackInternal()
                }
                AudioManager.AUDIOFOCUS_LOSS -> {
                    isFocusLost = true
                    hasAudioFocus = false
                    pauseTrackInternal()
                }
            }
        }
    }

    @Synchronized
    fun open(sampleRate: Int, channels: Int, bitsPerSample: Int): Boolean {
        close()

        if (sampleRate <= 0 || channels !in 1..2 || bitsPerSample != 16) {
            return false
        }

        val channelMask = if (channels == 1) {
            AudioFormat.CHANNEL_OUT_MONO
        } else {
            AudioFormat.CHANNEL_OUT_STEREO
        }
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minBuf = AudioTrack.getMinBufferSize(sampleRate, channelMask, encoding)
        if (minBuf <= 0) {
            return false
        }

        val frameBytes = channels * 2
        val target160msBytes = ((sampleRate.toLong() * 160L) / 1000L).toInt() * frameBytes
        val bufferBytes = maxOf(minBuf, target160msBytes)
        maxBufferBytes = bufferBytes

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(encoding)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()

        val builder = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufferBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
        }

        val createdTrack = try {
            builder.build()
        } catch (_: Throwable) {
            return false
        }

        if (createdTrack.state != AudioTrack.STATE_INITIALIZED) {
            createdTrack.release()
            return false
        }

        requestFocus(attributes)
        isPaused = false
        isFocusLost = false
        lastHeadPosUnsigned = 0L
        pendingTail = null
        track = createdTrack

        try {
            createdTrack.play()
        } catch (_: Throwable) {
            close()
            return false
        }
        return true
    }

    @Synchronized
    fun writePcm(pcm: ByteArray): Map<String, Any> {
        val t = track ?: return mapOf(
            "framesPlayedDelta" to 0,
            "paused" to true
        )

        val deltaFrames = consumeHeadDelta(t)
        val currentlyPaused = isPaused || isFocusLost
        if (currentlyPaused) {
            pendingTail = null
            return mapOf(
                "framesPlayedDelta" to deltaFrames,
                "paused" to true
            )
        }

        val tail = pendingTail
        val payload = when {
            tail != null && pcm.isNotEmpty() -> {
                val combined = ByteArray(tail.size + pcm.size)
                System.arraycopy(tail, 0, combined, 0, tail.size)
                System.arraycopy(pcm, 0, combined, tail.size, pcm.size)
                combined
            }
            tail != null -> tail
            else -> pcm
        }

        if (payload.isNotEmpty()) {
            val written = t.write(payload, 0, payload.size, AudioTrack.WRITE_NON_BLOCKING)
            if (written > 0 && written < payload.size) {
                val remaining = payload.size - written
                pendingTail = if (remaining <= maxBufferBytes) {
                    payload.copyOfRange(written, payload.size)
                } else {
                    null
                }
            } else if (written == payload.size) {
                pendingTail = null
            } else if (written == 0 && payload.size <= maxBufferBytes) {
                pendingTail = payload
            } else {
                pendingTail = null
            }
        }

        return mapOf(
            "framesPlayedDelta" to deltaFrames,
            "paused" to false
        )
    }

    @Synchronized
    fun pollPlayoutDelta(): Map<String, Any> {
        val t = track ?: return mapOf(
            "framesPlayedDelta" to 0,
            "paused" to true
        )
        val deltaFrames = consumeHeadDelta(t)
        val currentlyPaused = isPaused || isFocusLost
        if (!currentlyPaused) {
            val tail = pendingTail
            if (tail != null && tail.isNotEmpty()) {
                val written = t.write(tail, 0, tail.size, AudioTrack.WRITE_NON_BLOCKING)
                if (written > 0 && written < tail.size) {
                    val remaining = tail.size - written
                    pendingTail = if (remaining <= maxBufferBytes) {
                        tail.copyOfRange(written, tail.size)
                    } else {
                        null
                    }
                } else if (written == tail.size) {
                    pendingTail = null
                } else if (written < 0) {
                    pendingTail = null
                }
            }
        }
        return mapOf(
            "framesPlayedDelta" to deltaFrames,
            "paused" to currentlyPaused
        )
    }

    @Synchronized
    fun pause() {
        isPaused = true
        pauseTrackInternal()
    }

    @Synchronized
    fun resume() {
        isPaused = false
        val t = track ?: return
        if (!isFocusLost) {
            if (!hasAudioFocus) {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                requestFocus(attrs)
            }
            t.setVolume(1.0f)
            if (t.playState != AudioTrack.PLAYSTATE_PLAYING) {
                t.play()
            }
            lastHeadPosUnsigned = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        }
    }

    @Synchronized
    fun onActivityPause() {
        pause()
    }

    @Synchronized
    fun onActivityResume() {
        if (track != null) {
            resume()
        }
    }

    @Synchronized
    fun close() {
        pendingTail = null
        lastHeadPosUnsigned = 0L
        isPaused = false
        isFocusLost = false
        track?.let { t ->
            try {
                if (t.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    t.pause()
                }
                t.flush()
            } catch (_: Throwable) {
            }
            try {
                t.release()
            } catch (_: Throwable) {
            }
        }
        track = null
        abandonFocus()
    }

    private fun consumeHeadDelta(t: AudioTrack): Int {
        val rawHead = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        val delta = (rawHead - lastHeadPosUnsigned) and 0xFFFFFFFFL
        lastHeadPosUnsigned = rawHead
        return delta.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    private fun pauseTrackInternal() {
        pendingTail = null
        track?.let { t ->
            try {
                if (t.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    t.pause()
                }
                t.flush()
                lastHeadPosUnsigned = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            } catch (_: Throwable) {
            }
        }
    }

    private fun requestFocus(attributes: AudioAttributes) {
        val am = audioManager ?: return
        val res = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(true)
                .setOnAudioFocusChangeListener(focusListener)
                .build()
            focusRequest = req
            am.requestAudioFocus(req)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                focusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN
            )
        }
        hasAudioFocus = (res == AudioManager.AUDIOFOCUS_REQUEST_GRANTED)
    }

    private fun abandonFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(focusListener)
        }
        hasAudioFocus = false
    }
}
