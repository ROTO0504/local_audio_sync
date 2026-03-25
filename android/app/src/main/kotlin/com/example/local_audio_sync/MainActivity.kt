package com.example.local_audio_sync

import android.app.Activity
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channel = "com.example.local_audio_sync/broadcast"
    private val screenAudioChannel = "com.example.local_audio_sync/screenAudio"

    private val MEDIA_PROJECTION_REQUEST_CODE = 1001
    private var pendingResult: MethodChannel.Result? = null

    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var captureThread: Thread? = null
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // EventChannel: streams raw PCM16 bytes from screen audio capture
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, screenAudioChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }
                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startBroadcast" -> {
                        val intent = Intent(this, AudioBroadcastService::class.java).apply {
                            action = AudioBroadcastService.ACTION_START
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stopBroadcast" -> {
                        val intent = Intent(this, AudioBroadcastService::class.java).apply {
                            action = AudioBroadcastService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }
                    "requestMediaProjection" -> {
                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                            // Screen audio capture requires Android 10+
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        pendingResult = result
                        val mpm = getSystemService(MEDIA_PROJECTION_SERVICE)
                                as MediaProjectionManager
                        startActivityForResult(
                            mpm.createScreenCaptureIntent(),
                            MEDIA_PROJECTION_REQUEST_CODE
                        )
                        // result is returned asynchronously from onActivityResult
                    }
                    "startScreenCapture" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            startScreenAudioCapture()
                        }
                        // Also start the foreground service so audio keeps running in background
                        val intent = Intent(this, AudioBroadcastService::class.java).apply {
                            action = AudioBroadcastService.ACTION_START
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    }
                    "stopScreenCapture" -> {
                        stopScreenAudioCapture()
                        val intent = Intent(this, AudioBroadcastService::class.java).apply {
                            action = AudioBroadcastService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == MEDIA_PROJECTION_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                val mpm = getSystemService(MEDIA_PROJECTION_SERVICE)
                        as MediaProjectionManager
                mediaProjection = mpm.getMediaProjection(resultCode, data)
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
        }
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun startScreenAudioCapture() {
        val mp = mediaProjection ?: return

        val config = AudioPlaybackCaptureConfiguration.Builder(mp)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()

        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(48000)
            .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
            .build()

        val minBuf = AudioRecord.getMinBufferSize(
            48000,
            AudioFormat.CHANNEL_IN_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        // Use at least 20ms of stereo PCM16 (960 frames × 2ch × 2bytes = 3840 bytes)
        val bufSize = maxOf(minBuf, 3840)

        val record = AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(config)
            .setAudioFormat(format)
            .setBufferSizeInBytes(bufSize)
            .build()

        audioRecord = record
        record.startRecording()

        captureThread = Thread {
            val buf = ByteArray(3840)
            while (!Thread.currentThread().isInterrupted) {
                val read = record.read(buf, 0, buf.size)
                if (read > 0) {
                    val copy = buf.copyOf(read)
                    mainHandler.post {
                        eventSink?.success(copy)
                    }
                }
            }
        }.also { it.start() }
    }

    private fun stopScreenAudioCapture() {
        captureThread?.interrupt()
        captureThread = null
        audioRecord?.stop()
        audioRecord?.release()
        audioRecord = null
        mediaProjection?.stop()
        mediaProjection = null
    }

    override fun onDestroy() {
        stopScreenAudioCapture()
        super.onDestroy()
    }
}
