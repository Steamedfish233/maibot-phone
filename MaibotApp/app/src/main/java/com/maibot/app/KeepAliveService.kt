package com.maibot.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.net.InetSocketAddress
import java.net.Socket

/**
 * 常驻前台服务：让手机作为 MaiBot 服务器持续运行；任务期间兼作安装任务的前台载体。
 *
 *  1. 常驻通知，提高进程优先级，避免被系统回收；
 *  2. 持有 PARTIAL_WAKE_LOCK，锁屏后 CPU 不被挂起；
 *  3. 每分钟检测 8001(MaiBot) / 6099(NapCat) 端口，掉线自动重新拉起；
 *  4. **任务模式**：安装/部署期间由 [beginTask] 临时拉起，通知栏显示当前进度。
 *     有前台服务在跑，App 切到后台后仍被允许调用 Termux 的 RunCommandService 轮询日志，
 *     不会出现“切后台 3 次读日志失败就以为任务结束了”的旧问题。任务结束且用户没有
 *     开启“常驻守护”时，服务会自动停止。
 */
class KeepAliveService : Service() {

    companion object {
        const val ACTION_START = "com.maibot.app.action.KEEPALIVE_START"

        private const val CHANNEL_ID = "maibot_keepalive"
        private const val NOTI_ID = 1001
        private const val RESULT_NOTI_ID = 1002
        private const val TICK_MS = 60_000L
        private const val FIRST_TICK_MS = 3_000L
        private const val RESTART_COOLDOWN_MS = 3 * 60_000L

        @Volatile
        var isRunning: Boolean = false
            private set

        @Volatile
        private var instance: KeepAliveService? = null

        /** 非空表示当前有安装/部署任务，通知栏显示任务进度 */
        @Volatile
        private var taskTitle: String? = null

        @Volatile
        private var taskText: String = ""

        @Volatile
        private var taskNotifyAt: Long = 0L

        fun start(context: Context) {
            val intent = Intent(context, KeepAliveService::class.java).setAction(ACTION_START)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    ContextCompat.startForegroundService(context, intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // 后台启动前台服务受限时忽略，等下一次触发（如打开 App、开机广播）
            }
        }

        fun stop(context: Context) {
            // 安装/部署任务期间不允许被“常驻守护”开关顺手停掉，否则后台日志跟踪会断。
            if (taskTitle != null) return
            try {
                context.stopService(Intent(context, KeepAliveService::class.java))
            } catch (_: Exception) {
            }
        }

        /** 任务开始：临时进入前台服务模式（即使“常驻守护”开关是关的） */
        fun beginTask(context: Context, title: String) {
            taskTitle = title
            taskText = "正在准备 ..."
            taskNotifyAt = 0L
            start(context)
        }

        /** 更新任务通知：标题 + 最近一行日志（内部限频，避免刷屏） */
        fun updateTask(title: String, line: String) {
            taskTitle = title
            if (line.isNotBlank()) taskText = line.trim()
            val now = SystemClock.elapsedRealtime()
            if (now - taskNotifyAt < 1_200L) return
            taskNotifyAt = now
            instance?.refreshNotification()
        }

        /** 任务结束：恢复端口状态通知；若用户没有开启常驻守护则停止服务 */
        fun endTask(context: Context) {
            taskTitle = null
            taskText = ""
            if (Prefs(context).keepAlive) {
                instance?.refreshNotification()
            } else {
                // 即使服务还没来得及 onCreate（任务瞬间失败），也要取消启动/停掉，避免残留通知与唤醒锁。
                try {
                    context.stopService(Intent(context, KeepAliveService::class.java))
                } catch (_: Exception) {
                }
            }
        }

        fun isTaskMode(): Boolean = taskTitle != null

        /**
         * 任务在后台结束时补一条可点击的结果通知：否则前台服务一停，通知栏会直接消失，
         * 用户无法判断是成功结束还是被系统杀掉。App 在前台时不打扰。
         */
        fun notifyResult(context: Context, success: Boolean, detail: String) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val ch = NotificationChannel(
                        CHANNEL_ID, "MaiBot 运行状态", NotificationManager.IMPORTANCE_LOW
                    )
                    ch.description = "保持手机作为 MaiBot 服务器持续运行，并显示安装进度"
                    ch.setShowBadge(false)
                    nm.createNotificationChannel(ch)
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                val pi = PendingIntent.getActivity(
                    context, 0, Intent(context, MainActivity::class.java), flags
                )
                val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_maibot)
                    .setContentTitle(if (success) "MaiBot 任务完成" else "MaiBot 任务结束")
                    .setContentText(detail.lineSequence().firstOrNull() ?: detail)
                    .setStyle(NotificationCompat.BigTextStyle().bigText(detail))
                    .setAutoCancel(true)
                    .setShowWhen(true)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .setContentIntent(pi)
                    .build()
                nm.notify(RESULT_NOTI_ID, notification)
            } catch (_: Exception) {
            }
        }

        /** 用户回到 App 后清掉“任务完成”通知 */
        fun clearResultNotification(context: Context) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(RESULT_NOTI_ID)
            } catch (_: Exception) {
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var maibotUp = false
    private var napcatUp = false
    private var lastMaibotTry = 0L
    private var lastNapcatTry = 0L
    private var guardTriggered = false

    private val ticker = object : Runnable {
        override fun run() {
            checkNow()
            handler.postDelayed(this, TICK_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        isRunning = true
        createChannel()
        acquireWakeLock()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        try {
            startForeground(NOTI_ID, buildNotification())
        } catch (_: Exception) {
        }

        // 开机自启场景：补一次 Termux 层守护（唤醒锁 + 独立守护会话 + 拉起服务）。
        // 安装/部署任务期间不做，避免和 apt / proot-distro 抢 Termux。
        if (!guardTriggered && taskTitle == null && Prefs(applicationContext).autoStart) {
            guardTriggered = true
            TermuxRunner.run(this, "guard")
        }

        handler.removeCallbacks(ticker)
        handler.postDelayed(ticker, FIRST_TICK_MS)
        // 仅“常驻守护”开启时才让系统在进程被杀后重启服务；纯任务模式没必要常驻。
        return if (Prefs(applicationContext).keepAlive) START_STICKY else START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        isRunning = false
        handler.removeCallbacks(ticker)
        releaseWakeLock()
        super.onDestroy()
    }

    // ---------------- 检测与自愈 ----------------

    private fun checkNow() {
        // 安装/部署期间端口状态无意义，而且拉起动作会干扰 apt；通知也由 TaskSession 更新。
        if (taskTitle != null) return

        val t = Thread {
            val maibot = portOpen(8001)
            val napcat = portOpen(6099)
            val prefs = Prefs(applicationContext)
            var relaunched = false

            if (prefs.autoRestart && TermuxRunner.isTermuxInstalled(applicationContext)) {
                val now = System.currentTimeMillis()
                if (!maibot && now - lastMaibotTry > RESTART_COOLDOWN_MS) {
                    lastMaibotTry = now
                    TermuxRunner.run(applicationContext, "start")
                    relaunched = true
                }
                if (!napcat && now - lastNapcatTry > RESTART_COOLDOWN_MS) {
                    lastNapcatTry = now
                    TermuxRunner.run(applicationContext, "napcat-start")
                    relaunched = true
                }
            }

            maibotUp = maibot
            napcatUp = napcat
            handler.post { refreshNotification(relaunched) }
        }
        t.isDaemon = true
        t.start()
    }

    private fun portOpen(port: Int, timeoutMs: Int = 1500): Boolean {
        return try {
            Socket().use { s ->
                s.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
                true
            }
        } catch (_: Exception) {
            false
        }
    }

    // ---------------- 通知 ----------------

    private fun refreshNotification(relaunched: Boolean = false) {
        try {
            notificationManager().notify(NOTI_ID, buildNotification(relaunched))
        } catch (_: Exception) {
        }
    }

    private fun buildNotification(relaunched: Boolean = false): Notification {
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val pi = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java), flags
        )
        val activeTask = taskTitle
        val title: String
        val text: String
        if (activeTask != null) {
            title = "MaiBot 任务进行中"
            text = "$activeTask\n${taskText.ifBlank { "任务运行中 ..." }}"
        } else {
            title = "MaiBot 服务器守护中"
            val status = buildString {
                append("MaiBot：").append(if (maibotUp) "运行中" else "已停止")
                append("　NapCat：").append(if (napcatUp) "运行中" else "已停止")
            }
            text = if (relaunched) "$status　（已自动尝试拉起）" else status
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_maibot)
            .setContentTitle(title)
            .setContentText(text.lineSequence().lastOrNull() ?: text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pi)
            .build()
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val ch = NotificationChannel(
                CHANNEL_ID, "MaiBot 运行状态", NotificationManager.IMPORTANCE_LOW
            )
            ch.description = "保持手机作为 MaiBot 服务器持续运行，并显示安装进度"
            ch.setShowBadge(false)
            notificationManager().createNotificationChannel(ch)
        }
    }

    // ---------------- 唤醒锁 ----------------

    private fun acquireWakeLock() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "maibot:keepalive")
            wakeLock?.setReferenceCounted(false)
            wakeLock?.acquire()
        } catch (_: Exception) {
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
    }
}
