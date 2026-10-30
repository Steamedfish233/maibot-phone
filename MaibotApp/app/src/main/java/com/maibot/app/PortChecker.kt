package com.maibot.app

import java.net.InetSocketAddress
import java.net.Socket
import kotlin.concurrent.thread

/**
 * 通过 TCP 连接检测本机端口是否监听，用于判断 MaiBot / NapCat 是否在运行。
 */
object PortChecker {

    fun check(port: Int, timeoutMs: Int = 1500, callback: (Boolean) -> Unit) {
        thread {
            val ok = try {
                Socket().use { s ->
                    s.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
                    true
                }
            } catch (_: Exception) {
                false
            }
            callback(ok)
        }
    }
}