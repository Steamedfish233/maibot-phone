package com.maibot.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * 接收 Termux 通过 RUN_COMMAND 的 PendingIntent 回传的执行结果。
 *
 * Termux 侧的发送点是 ResultSender.sendCommandResultDataToPendingIntent()：
 *     resultIntent.putExtra("result", Bundle{stdout, stderr, exitCode, err, errmsg})
 *     resultConfig.resultPendingIntent.send(context, Activity.RESULT_OK, resultIntent)
 *
 * 也就是说 PendingIntent 由本 App 创建（见 TermuxRunner.buildPendingIntent），
 * Termux 只是拿着它 send 一次，广播最终以本 App 的身份投递到这个 receiver，
 * 所以 exported=false 就够了，其它 App 无法伪造。
 */
class TermuxResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        TermuxRunner.deliver(intent)
    }
}
