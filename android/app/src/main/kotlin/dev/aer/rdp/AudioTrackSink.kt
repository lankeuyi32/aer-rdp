package dev.aer.rdp

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.util.Log

class AudioTrackSink(private val context: Context) {
    private val audioManager: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    private var track: AudioTrack? = null
    private var focusRequest: AudioFocusRequest? = null
    private var hasAudioFocus: Boolean = false
    private var isPaused: Boolean = false
    private var isFocusLost: Boolean = false
    private var isTrackDead: Boolean = false
    private var loggedFirstWrite: Boolean = false
    private var lastHeadPosUnsigned: Long = 0L
    private var totalFramesWritten: Long = 0L
    private var frameBytes: Int = 4
    private var primeTargetBytes: Int = 0
    private var primedBytes: Int = 0
    private var isPriming: Boolean = true
    private var emptyPollsWhilePriming: Int = 0
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
                        if (!isPaused && !isTrackDead && !isPriming && t.playState != AudioTrack.PLAYSTATE_PLAYING) {
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

        frameBytes = channels * 2
        // 450ms ringbuffer absorbs H.264 high-res decode bursts and Wi-Fi jitter cleanly,
        // while 65ms pre-fill before play() prevents AudioFlinger resampler underruns.
        val target450msBytes = ((sampleRate.toLong() * 450L) / 1000L).toInt() * frameBytes
        val bufferBytes = maxOf(minBuf * 2, target450msBytes)
        maxBufferBytes = bufferBytes
        primeTargetBytes = (((sampleRate.toLong() * 65L) / 1000L).toInt() * frameBytes)
            .coerceAtMost(bufferBytes / 2)

        val attributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(encoding)
            .setSampleRate(sampleRate)
            .setChannelMask(channelMask)
            .build()

        val nativeSampleRate = AudioTrack.getNativeOutputSampleRate(AudioManager.STREAM_MUSIC)

        val createdTrack = try {
            val builder = AudioTrack.Builder()
                .setAudioAttributes(attributes)
                .setAudioFormat(format)
                .setBufferSizeInBytes(bufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                // Standard AudioFlinger mixer track gives smooth 44.1kHz->48kHz resampling
                // and deep glitch-free buffering (unlike tiny FastMixer LOW_LATENCY tracks).
                builder.setPerformanceMode(AudioTrack.PERFORMANCE_MODE_NONE)
            }
            val built = builder.build()
            if (built.state != AudioTrack.STATE_INITIALIZED) {
                try {
                    built.release()
                } catch (_: Throwable) {
                }
                null
            } else {
                built
            }
        } catch (_: Throwable) {
            null
        } ?: run {
            Log.e(
                "AerRdp",
                "AudioTrackSink.open failed building AudioTrack (rate=$sampleRate ch=$channels native=$nativeSampleRate)"
            )
            return false
        }

        requestFocus(attributes)
        isPaused = false
        isFocusLost = false
        isTrackDead = false
        loggedFirstWrite = false
        lastHeadPosUnsigned = 0L
        totalFramesWritten = 0L
        primedBytes = 0
        isPriming = true
        emptyPollsWhilePriming = 0
        pendingTail = null
        track = createdTrack

        try {
            createdTrack.setVolume(1.0f)
        } catch (t: Throwable) {
            Log.e("AerRdp", "AudioTrackSink.setVolume failed: ${t.message}")
            close()
            return false
        }
        Log.i(
            "AerRdp",
            "AudioTrackSink.open ok: rate=$sampleRate ch=$channels bits=$bitsPerSample nativeRate=$nativeSampleRate bufBytes=$bufferBytes primeBytes=$primeTargetBytes focus=$hasAudioFocus"
        )
        return true
    }

    @Synchronized
    fun writePcm(pcm: ByteArray): Map<String, Any> {
        val t = track ?: return mapOf(
            "framesPlayedDelta" to 0,
            "paused" to true
        )

        val (deltaFrames, headFrames) = consumeHeadDelta(t)
        val currentlyPaused = isPaused || isFocusLost || isTrackDead
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

        // If playback was running and completely drained its hardware buffer before a new burst,
        // re-prime 50ms before resuming so it doesn't stutter on an empty ringbuffer edge.
        val inFlightFrames = (totalFramesWritten - headFrames).coerceAtLeast(0L)
        if (!isPriming && t.playState == AudioTrack.PLAYSTATE_PLAYING && inFlightFrames == 0L && payload.isEmpty()) {
            try {
                t.pause()
            } catch (_: Throwable) {
            }
            isPriming = true
            primedBytes = 0
            emptyPollsWhilePriming = 0
        }

        if (payload.isNotEmpty()) {
            emptyPollsWhilePriming = 0
            val written = t.write(payload, 0, payload.size, AudioTrack.WRITE_NON_BLOCKING)
            if (written < 0) {
                Log.e("AerRdp", "AudioTrackSink.write error=$written")
                isTrackDead = true
                pauseTrackInternal()
                return mapOf(
                    "framesPlayedDelta" to deltaFrames,
                    "paused" to true
                )
            }
            if (written > 0) {
                totalFramesWritten += (written / frameBytes).toLong()
                if (isPriming) {
                    primedBytes += written
                    if (primedBytes >= primeTargetBytes) {
                        isPriming = false
                        startPlayingSafe(t)
                    }
                } else if (t.playState != AudioTrack.PLAYSTATE_PLAYING) {
                    startPlayingSafe(t)
                }
                if (!loggedFirstWrite) {
                    loggedFirstWrite = true
                    Log.i(
                        "AerRdp",
                        "AudioTrackSink first PCM write: written=$written/${payload.size} priming=$isPriming playState=${t.playState}"
                    )
                }
            }
            if (written in 1 until payload.size) {
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
                if (isPriming) {
                    isPriming = false
                    startPlayingSafe(t)
                }
            } else {
                pendingTail = null
            }
        } else if (isPriming && primedBytes > 0) {
            // Flush short system notification sounds (<65ms) once no further packet arrives for ~30ms.
            emptyPollsWhilePriming++
            if (emptyPollsWhilePriming >= 3) {
                isPriming = false
                emptyPollsWhilePriming = 0
                startPlayingSafe(t)
            }
        }

        return mapOf(
            "framesPlayedDelta" to deltaFrames,
            "paused" to false
        )
    }

    private fun startPlayingSafe(t: AudioTrack) {
        if (t.playState != AudioTrack.PLAYSTATE_PLAYING) {
            try {
                t.play()
            } catch (_: Throwable) {
            }
        }
    }

    @Synchronized
    fun pollPlayoutDelta(): Map<String, Any> {
        val t = track ?: return mapOf(
            "framesPlayedDelta" to 0,
            "paused" to true
        )
        val (deltaFrames, _) = consumeHeadDelta(t)
        var currentlyPaused = isPaused || isFocusLost || isTrackDead
        if (!currentlyPaused) {
            val tail = pendingTail
            if (tail != null && tail.isNotEmpty()) {
                val written = t.write(tail, 0, tail.size, AudioTrack.WRITE_NON_BLOCKING)
                if (written < 0) {
                    isTrackDead = true
                    pauseTrackInternal()
                    currentlyPaused = true
                } else {
                    if (written > 0) {
                        totalFramesWritten += (written / frameBytes).toLong()
                        if (isPriming) {
                            primedBytes += written
                            if (primedBytes >= primeTargetBytes) {
                                isPriming = false
                                startPlayingSafe(t)
                            }
                        }
                    }
                    if (written in 1 until tail.size) {
                        val remaining = tail.size - written
                        pendingTail = if (remaining <= maxBufferBytes) {
                            tail.copyOfRange(written, tail.size)
                        } else {
                            null
                        }
                    } else if (written == tail.size) {
                        pendingTail = null
                    }
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
        if (!isFocusLost && !isTrackDead) {
            if (!hasAudioFocus) {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
                requestFocus(attrs)
            }
            t.setVolume(1.0f)
            isPriming = true
            primedBytes = 0
            emptyPollsWhilePriming = 0
            lastHeadPosUnsigned = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            totalFramesWritten = lastHeadPosUnsigned
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
        totalFramesWritten = 0L
        primedBytes = 0
        isPriming = true
        emptyPollsWhilePriming = 0
        isPaused = false
        isFocusLost = false
        isTrackDead = false
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

    private fun consumeHeadDelta(t: AudioTrack): Pair<Int, Long> {
        return try {
            val rawHead = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
            val delta = (rawHead - lastHeadPosUnsigned) and 0xFFFFFFFFL
            lastHeadPosUnsigned = rawHead
            Pair(delta.coerceAtMost(Int.MAX_VALUE.toLong()).toInt(), rawHead)
        } catch (_: Throwable) {
            Pair(0, lastHeadPosUnsigned)
        }
    }

    private fun pauseTrackInternal() {
        pendingTail = null
        isPriming = true
        primedBytes = 0
        emptyPollsWhilePriming = 0
        track?.let { t ->
            try {
                if (t.playState == AudioTrack.PLAYSTATE_PLAYING) {
                    t.pause()
                }
                t.flush()
                lastHeadPosUnsigned = t.playbackHeadPosition.toLong() and 0xFFFFFFFFL
                totalFramesWritten = lastHeadPosUnsigned
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
