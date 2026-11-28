package com.carriez.flutter_hbb

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL

/**
 * 【HyDesk】安卓远控端后台保活 + 新设备上线通知（2026-11-28）。
 *
 * 与 HDeskConsole 运营台保活同源，但改由 Flutter 版复用：
 * - 前台服务常驻（常驻通知），切后台/锁屏不被系统回收，维持在线；
 * - 每 HEARTBEAT_MS 调 /api/verify（用 Dart 侧传入并存入 SharedPreferences 的
 *   license token + machine_id），既保活授权会话，又从响应的 devices 字段
 *   检测绑定设备数变化，增加时发「新设备上线」通知；
 * - token 失效（bad_token/expired）发通知提示重新激活。
 *
 * 凭证由 Dart 通过 MainActivity 的 MethodChannel start_keepalive 传入，
 * 本服务不直接读 Dart 的 local option（那是 Rust 侧存储，Kotlin 读不到）。
 */
class HyKeepAliveService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var lastDevices = -1
    private var lastCode = ""

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification("HyDesk", "后台保活中 · 在线保持"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        scope.launch {
            while (isActive) {
                try {
                    heartbeat()
                } catch (_: Exception) {
                }
                delay(HEARTBEAT_MS)
            }
        }
        return START_STICKY
    }

    private suspend fun heartbeat() {
        val prefs = getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val token = prefs.getString(PREF_TOKEN, "").orEmpty()
        val mid = prefs.getString(PREF_MID, "").orEmpty()
        val base = prefs.getString(PREF_BASE, "").orEmpty()
        if (token.isEmpty() || mid.isEmpty() || base.isEmpty()) return

        val payload = JSONObject().put("token", token).put("machine_id", mid).toString()
        val resp = postJson(if (base.endsWith("/")) base + "api/verify" else "$base/api/verify", payload)
            ?: return
        val ok = resp.optBoolean("ok", false)
        if (!ok) {
            val err = resp.optString("error", "")
            if (err == "bad_token" || err == "expired" || err == "machine_mismatch") {
                notify("HyDesk 授权已失效", "请重新打开 APP 激活以继续接收设备上线通知")
            }
            return
        }
        val devices = resp.optInt("devices", -1)
        val code = resp.optString("code", "")
        if (lastDevices >= 0 && code == lastCode && devices > lastDevices) {
            notify("新设备上线", "当前已绑定 $devices 台设备（新增 ${devices - lastDevices} 台）")
        }
        lastDevices = devices
        lastCode = code

        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, buildNotification("HyDesk", "后台保活中 · $devices 台设备"))
    }

    private fun postJson(urlStr: String, body: String): JSONObject? {
        var conn: HttpURLConnection? = null
        try {
            conn = URL(urlStr).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 12000
            conn.readTimeout = 12000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("Accept", "application/json")
            val os: OutputStream = conn.outputStream
            os.write(body.toByteArray(Charsets.UTF_8))
            os.flush()
            os.close()
            val reader = BufferedReader(InputStreamReader(conn.inputStream, Charsets.UTF_8))
            val sb = StringBuilder()
            var line: String?
            while (reader.readLine().also { line = it } != null) sb.append(line)
            reader.close()
            return JSONObject(sb.toString())
        } catch (_: Exception) {
            return null
        } finally {
            conn?.disconnect()
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "HyDesk 保活", NotificationManager.IMPORTANCE_LOW)
                        .apply { description = "后台保活与设备上线通知" }
                )
            }
        }
    }

    private fun buildNotification(title: String, text: String): Notification {
        val intent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pi = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val stopIntent = Intent(this, HyKeepAliveService::class.java).apply { action = ACTION_STOP }
        val stopPi = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(pi)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "停止保活", stopPi)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun notify(title: String, text: String) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_notify_more)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
        val pi = PendingIntent.getActivity(
            this, 2, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        builder.setContentIntent(pi)
        nm.notify(ALERT_NOTIFICATION_ID, builder.build())
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        const val PREFS = "hdesk_keepalive"
        const val PREF_TOKEN = "token"
        const val PREF_MID = "mid"
        const val PREF_BASE = "base"
        private const val CHANNEL_ID = "hdesk_keepalive"
        private const val NOTIFICATION_ID = 3001
        private const val ALERT_NOTIFICATION_ID = 3002
        private const val HEARTBEAT_MS = 30_000L
        const val ACTION_STOP = "com.carriez.flutter_hbb.KEEPALIVE_STOP"

        fun start(context: Context, token: String, mid: String, base: String) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            prefs.edit()
                .putString(PREF_TOKEN, token)
                .putString(PREF_MID, mid)
                .putString(PREF_BASE, base)
                .apply()
            val intent = Intent(context, HyKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, HyKeepAliveService::class.java))
        }
    }
}
