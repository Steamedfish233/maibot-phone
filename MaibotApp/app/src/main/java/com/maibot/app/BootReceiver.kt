package com.maibot.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 开机自启：系统启动完成后恢复守护服务。
 *
 * 说明：这里不直接调用 Termux（后台启动外部服务会被系统限制），
 * 而是拉起前台守护服务，由它在前台服务状态下安全地驱动 Termux 恢复 MaiBot / NapCat。
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "android.intent.action.REBOOT"
        ) {
            return
        }

        val prefs = Prefs(context)
        if (!prefs.keepAlive && !prefs.autoStart) return

        KeepAliveService.start(context)
    }
}
