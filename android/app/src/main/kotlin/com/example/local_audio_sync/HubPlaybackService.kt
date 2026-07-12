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

/**
 * Hub(集約・再生)モードのフォアグラウンドサービス。
 *
 * miniaudio ミキサーの再生と UDP 受信・ビーコン送信をバックグラウンドでも
 * 継続させるために、mediaPlayback 種別のフォアグラウンド通知を出し、
 * WakeLock / MulticastLock を保持する。
 * (クライアント送信用の [AudioBroadcastService](mediaProjection 種別)とは別)
 */
class HubPlaybackService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startPlayback()
            ACTION_STOP -> stopSelf()
        }
        return START_STICKY
    }

    private fun startPlayback() {
        createNotificationChannel()
        val notification = buildNotification()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // Keep CPU alive
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "LocalAudioSync::HubWakeLock")
        wakeLock?.acquire(4 * 60 * 60 * 1000L) // 4 hours max

        // ビーコン(UDP ブロードキャスト)と mDNS 公開のために必要な端末がある
        val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
        multicastLock = wm.createMulticastLock("LocalAudioSync::HubMulticastLock")
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
                "Hub 再生",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Hub として音声を集約・再生中に表示"
                setSound(null, null)
            }
            val nm = getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Hub として再生中")
            .setContentText("クライアントの音声を受信してミックス再生しています")
            .setSmallIcon(android.R.drawable.ic_lock_silent_mode_off)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    companion object {
        const val ACTION_START = "com.example.local_audio_sync.START_HUB_PLAYBACK"
        const val ACTION_STOP = "com.example.local_audio_sync.STOP_HUB_PLAYBACK"
        private const val CHANNEL_ID = "hub_playback"
        private const val NOTIFICATION_ID = 1002
    }
}
