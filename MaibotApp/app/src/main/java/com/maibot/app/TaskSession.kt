package com.maibot.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock

/**
 * 任务会话：把「任务是否在跑 / 日志内容 / 任务标题」从 Activity 中抽离出来。
 *
 * 为什么需要它：
 *  1. 安装任务本身在 Termux 中独立执行，App 只负责轮询日志。若日志状态绑在 Activity 上，
 *     退到后台、旋转屏幕或 Activity 重建后就会和任务失联（旧版即如此）。
 *  2. 任务期间需要前台服务（见 [KeepAliveService.beginTask]），这样 App 在后台仍被允许
 *     调用 Termux 的 RunCommandService 读取日志；通知栏同时显示当前进度。
 *  3. App 进程若被系统清理，只要 Termux 里的安装还在跑，回到 App 时可通过
 *     [TermuxRunner.reconnect] 重新接上日志（见 [recoverIfNeeded]）。
 *
 * 线程约定：所有公开方法都从主线程调用，所有回调都在主线程触发。
 */
object TaskSession {

    interface Listener {
        fun onLogChanged(text: String, running: Boolean, title: String)
        fun onFinished(success: Boolean)
    }

    /** 日志缓冲上限；只保留尾部，避免长时间安装把内存和渲染拖垮 */
    private const val MAX_LOG_CHARS = 20_000

    /** 日志合并刷新间隔：下载时日志很密，逐行刷新会让界面抖动 */
    private const val FLUSH_MS = 200L

    /** 通知栏进度刷新间隔，避免每行日志都 notify */
    private const val NOTIFY_MS = 1_200L

    private val main = Handler(Looper.getMainLooper())
    private val listeners = ArrayList<Listener>()
    private val log = StringBuilder()

    /** 清掉脚本/工具输出里的 ANSI 颜色码，避免界面出现 ⟦1;34m 之类乱码 */
    private val ansiPattern = Regex("\u001B\\[[0-9;]*[A-Za-z]")

    private var appContext: Context? = null
    private var flushScheduled = false
    private var foreground = false
    private var lastNotifyAt = 0L

    /** 主界面是否可见：后台完成任务时补一条结果通知 */
    @Volatile
    private var uiVisible = false

    @Volatile
    var running = false
        private set

    @Volatile
    var title = ""
        private set

    private val flushRunnable = Runnable {
        flushScheduled = false
        notifyNow()
    }

    fun isRunning(): Boolean = running

    fun isUiVisible(): Boolean = uiVisible

    fun onUiShown() {
        uiVisible = true
    }

    fun onUiHidden() {
        uiVisible = false
    }

    fun attach(listener: Listener) {
        synchronized(listeners) {
            if (!listeners.contains(listener)) listeners.add(listener)
        }
        listener.onLogChanged(snapshot(), running, title)
    }

    fun detach(listener: Listener) {
        synchronized(listeners) { listeners.remove(listener) }
    }

    fun snapshot(): String = synchronized(log) { log.toString() }

    fun text(): String = snapshot()

    /** 短操作（预检、查询、修复提示等）开始，写入日志并占用“进行中”状态 */
    fun begin(context: Context, operationTitle: String) {
        appContext = context.applicationContext
        title = operationTitle
        foreground = false
        running = true
        synchronized(log) {
            log.setLength(0)
            log.append("===== ").append(operationTitle).append(" =====\n")
        }
        notifyNow()
    }

    /** 追加一行日志（主线程或任意线程均可，实际渲染会合并到主线程） */
    fun append(line: String) {
        if (line == "__CLEAR__") {
            synchronized(log) { log.setLength(0) }
            scheduleFlush()
            return
        }
        val clean = if (line.indexOf('\u001B') >= 0) line.replace(ansiPattern, "") else line
        synchronized(log) {
            log.append(clean).append('\n')
            if (log.length > MAX_LOG_CHARS) {
                // 从下一行开始裁，避免把一行的开头切在半截
                val cut = log.length - MAX_LOG_CHARS
                val nl = log.indexOf("\n", cut)
                log.delete(0, if (nl >= 0) nl + 1 else cut)
            }
        }
        scheduleFlush()
    }

    /** 短操作结束 */
    fun end() {
        if (!running) return
        running = false
        foreground = false
        notifyNow()
    }

    /**
     * 启动一个 Termux 任务。
     *
     * @param nextAction / nextTitle 非空表示顺序任务：本步成功后自动接下一步
     *        （例如 Debian 初始化成功后自动部署 MaiBot）。
     */
    fun start(
        context: Context,
        action: String,
        operationTitle: String,
        nextAction: String? = null,
        nextTitle: String? = null
    ) {
        if (running) return
        val ctx = context.applicationContext
        appContext = ctx
        title = operationTitle
        foreground = true
        running = true
        synchronized(log) {
            log.setLength(0)
            log.append("===== ").append(operationTitle).append(" =====\n")
        }

        val prefs = Prefs(ctx)
        prefs.pendingTaskAction = action
        prefs.pendingTaskTitle = operationTitle

        // 先进入前台服务，再开始访问 Termux：切后台后轮询日志才不会被系统拦截。
        KeepAliveService.beginTask(ctx, operationTitle)
        notifyNow()

        TermuxRunner.run(
            ctx,
            action,
            onStatus = { line -> append(line) },
            onProgress = { line -> append(line) },
            onFinish = { success, code ->
                finishTask(ctx, action, success, code, nextAction, nextTitle)
            }
        )
    }

    /**
     * App 进程中断后重开：若存在“进行中任务”标记，探测 Termux 里任务是否还在跑。
     * 仍在运行则接续日志，已结束则展示退出码和补读的最后日志。
     */
    fun recoverIfNeeded(context: Context) {
        if (running) return
        val ctx = context.applicationContext
        val prefs = Prefs(ctx)
        val previousAction = prefs.pendingTaskAction ?: return
        val previousTitle = prefs.pendingTaskTitle ?: previousAction

        appContext = ctx
        title = "恢复上次任务：$previousTitle"
        foreground = true
        running = true
        synchronized(log) {
            log.setLength(0)
            log.append("===== 恢复上次任务：").append(previousTitle).append(" =====\n")
        }
        KeepAliveService.beginTask(ctx, title)
        notifyNow()
        TermuxRunner.reconnect(
            ctx,
            onProgress = { line -> append(line) },
            onFinish = { success, code -> finishRecovered(ctx, success, code) }
        )
    }

    private fun finishTask(
        ctx: Context,
        action: String,
        success: Boolean,
        code: Int,
        nextAction: String?,
        nextTitle: String?
    ) {
        append("")
        when {
            success -> append(">>> 任务完成（成功）")
            code == -1 -> append(">>> 任务未能启动，或日志跟踪已中断，请按上方提示处理后重试。")
            else -> {
                append(">>> 任务结束（退出码 $code）")
                append(">>> 若上方日志里有 [错误] 字样，按提示处理后重新点按钮即可，已下载的部分会接着续传。")
            }
        }
        val chain = success && nextAction != null && nextTitle != null
        if (nextAction != null && !success) {
            append("顺序安装已停止，不会继续后续步骤；处理错误后可重新安装。")
        }
        if (success && action == "install") {
            append("下一步：打开 Termux，执行 bash ~/maibot-onekey.sh fg，阅读并确认首次协议；然后配置模型密钥。QQ 登录在 NapCat 中另行完成。")
        }
        if (chain) {
            append("Debian 初始化成功，接下来部署 MaiBot。")
        }

        Prefs(ctx).clearPendingTask()

        if (chain) {
            val safeAction = nextAction ?: return
            val safeTitle = nextTitle ?: return
            // 直接进入下一阶段：start() 要求非运行态，但中间不通知界面，
            // 避免两个阶段之间按钮和日志面板闪一下。前台服务保持连续。
            running = false
            start(ctx, safeAction, safeTitle)
            fireFinished(true)
            return
        }

        running = false
        foreground = false
        if (!uiVisible) {
            KeepAliveService.notifyResult(ctx, success, resultDetail(success, code, snapshot()))
        }
        KeepAliveService.endTask(ctx)
        notifyNow()
        fireFinished(success)
    }

    private fun finishRecovered(ctx: Context, success: Boolean, code: Int) {
        append("")
        when {
            code == TermuxRunner.RECONNECT_NOT_FOUND ->
                append(">>> 没有检测到仍在 Termux 中运行的任务，可能已经结束或被系统清理。可在 Termux 执行：tail -n 80 ~/.maibot-run.log")
            success -> append(">>> 上次任务已完成（成功）")
            else -> append(">>> 上次任务已结束（退出码 $code）")
        }
        running = false
        foreground = false
        if (!uiVisible) {
            KeepAliveService.notifyResult(ctx, success, resultDetail(success, code, snapshot()))
        }
        Prefs(ctx).clearPendingTask()
        KeepAliveService.endTask(ctx)
        notifyNow()
        fireFinished(success)
    }

    private fun resultDetail(success: Boolean, code: Int, text: String): String {
        val head = when {
            success -> "任务完成（成功）"
            code == -1 -> "任务未能启动，或日志跟踪已中断"
            code == TermuxRunner.RECONNECT_NOT_FOUND -> "没有检测到仍在 Termux 中运行的任务"
            else -> "任务结束（退出码 $code）"
        }
        val last = lastLine(text)
        return if (last.isBlank()) head else "$head\n$last"
    }

    private fun scheduleFlush() {
        if (flushScheduled) return
        flushScheduled = true
        main.postDelayed(flushRunnable, FLUSH_MS)
    }

    private fun notifyNow() {
        flushScheduled = false
        main.removeCallbacks(flushRunnable)

        val text = snapshot()
        val state = running
        val currentTitle = title
        val copy = synchronized(listeners) { listeners.toList() }
        copy.forEach { it.onLogChanged(text, state, currentTitle) }

        val ctx = appContext
        if (foreground && state && ctx != null) {
            val now = SystemClock.elapsedRealtime()
            if (now - lastNotifyAt >= NOTIFY_MS) {
                lastNotifyAt = now
                KeepAliveService.updateTask(currentTitle, lastLine(text))
            }
        }
    }

    private fun lastLine(text: String): String {
        val trimmed = text.trimEnd('\n')
        if (trimmed.isBlank()) return "任务运行中 ..."
        val idx = trimmed.lastIndexOf('\n')
        val line = if (idx >= 0) trimmed.substring(idx + 1) else trimmed
        return line.take(140).ifBlank { "任务运行中 ..." }
    }

    private fun fireFinished(success: Boolean) {
        val copy = synchronized(listeners) { listeners.toList() }
        copy.forEach { it.onFinished(success) }
    }
}
