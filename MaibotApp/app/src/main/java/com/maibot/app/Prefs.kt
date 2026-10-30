package com.maibot.app

import android.content.Context

/**
 * 本地开关与任务标记存储：守护服务、掉线自动拉起、开机自启，
 * 以及“App 进程中断时仍有任务在 Termux 中跑”的恢复标记。
 */
class Prefs(context: Context) {

    private val sp = context.applicationContext
        .getSharedPreferences("maibot_prefs", Context.MODE_PRIVATE)

    /** 前台守护服务（常驻通知 + 唤醒锁） */
    var keepAlive: Boolean
        get() = sp.getBoolean("keep_alive", false)
        set(v) = sp.edit().putBoolean("keep_alive", v).apply()

    /** 检测到端口掉线时自动重新拉起 MaiBot / NapCat */
    var autoRestart: Boolean
        get() = sp.getBoolean("auto_restart", false)
        set(v) = sp.edit().putBoolean("auto_restart", v).apply()

    /** 手机开机后自动启动 */
    var autoStart: Boolean
        get() = sp.getBoolean("auto_start", false)
        set(v) = sp.edit().putBoolean("auto_start", v).apply()

    /**
     * 已启动但尚未正常收尾的任务。App 进程被杀后重新打开时，用它判断
     * 是否需要去 Termux 里探测并重新连接日志；任务正常结束会立即清除。
     */
    var pendingTaskAction: String?
        get() = sp.getString("pending_task_action", null)
        set(v) = sp.edit().putString("pending_task_action", v).apply()

    var pendingTaskTitle: String?
        get() = sp.getString("pending_task_title", null)
        set(v) = sp.edit().putString("pending_task_title", v).apply()

    fun clearPendingTask() {
        sp.edit()
            .remove("pending_task_action")
            .remove("pending_task_title")
            .apply()
    }
}
