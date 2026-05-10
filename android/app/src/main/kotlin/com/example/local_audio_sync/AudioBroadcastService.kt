package com.example.local_audio_sync

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

class AudioBroadcastService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startBroadcast()
            ACTION_STOP -> stopSelf()
        }
        return START_STICKY
    }

    private fun startBroadcast() {
        createNotificationChannel()
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // 内部音声(他アプリの音)を MediaProjection でキャプチャするので
            // mediaProjection 単独のフォアグラウンドサービス種別で起動する。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Keep CPU alive
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LocalAudioSync::WakeLock")
        wakeLock?.acquire(60 * 60 * 1000L) // 1 hour max

        // Allow UDP broadcast on Wi-Fi (required on some Android devices)
        val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        multicastLock = wm.createMulticastLock("LocalAudioSync::MulticastLock")
        multicastLock?.setReferenceCounted(true)
        multicastLock?.acquire()
    }

    override fun onDestroy() {
        super.onDestroy()
        wakeLock?.release()
        wakeLock = null
        multicastLock?.release()
        multicastLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "音声配信",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "ハブへの内部音声配信中に表示"
                setSound(null, null)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("内部音声を配信中")
            .setContentText("ローカルネットワークの Hub へ音声を送信しています")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        const val ACTION_START = "com.example.local_audio_sync.START_BROADCAST"
        const val ACTION_STOP = "com.example.local_audio_sync.STOP_BROADCAST"
        private const val CHANNEL_ID = "audio_broadcast"
        private const val NOTIFICATION_ID = 1001
    }
}
