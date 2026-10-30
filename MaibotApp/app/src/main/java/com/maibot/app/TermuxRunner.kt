package com.maibot.app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Base64
import androidx.core.content.ContextCompat
import java.security.MessageDigest
import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * 通过 Termux 的 RunCommandService 执行命令，并把结果 / 日志回传给界面。
 *
 * ── v1.2.3 修了什么（逐条对照 Termux 官方源码核对，不是猜的）────────────
 *
 * 旧版无论怎么点都只显示「无法与 Termux 通信：命令没有返回任何结果」，
 * 原因是通信协议写错了四处，任何一处都会让调用永远拿不到回执：
 *
 * 1) **权限**：Termux 的 AndroidManifest 里是
 *      <service android:name=".app.RunCommandService" android:exported="true"
 *               android:permission="com.termux.permission.RUN_COMMAND" />
 *    而 com.termux.permission.RUN_COMMAND 的 protectionLevel 是 **dangerous**，
 *    这类权限【不会在安装时自动授予】，调用方必须在 Manifest 声明
 *    uses-permission 之外，还要在运行时弹窗申请。旧版两条都没做，
 *    于是 startService 立刻抛 SecurityException，异常被吞掉后表现成"毫无结果"。
 *
 * 2) **回执通道**：RUN_COMMAND 只有两个合法通道：
 *      com.termux.RUN_COMMAND_PENDING_INTENT    （PendingIntent，本版使用）
 *      com.termux.RUN_COMMAND_RESULT_DIRECTORY  （写文件，跨 App 读不到，不用）
 *    旧版用的 com.termux.RUN_COMMAND_RESULT_RECEIVER 这个名字在
 *    TermuxConstants 里根本不存在，ResultReceiver 永远不会被回调 → 必然超时。
 *
 * 3) **回执字段**：Termux 由 TermuxPluginUtils.setPluginResultPendingIntentVariables()
 *    固定默认键：Intent extra "result" → Bundle{stdout, stderr, exitCode, err, errmsg}。
 *    旧版按 com.termux.RESULT_EXEC_OUTPUT 取值，同样取不到。
 *
 * 4) **Runner**：结果只对 Runner=app-shell（即 RUN_COMMAND_BACKGROUND=true）回传，
 *    所以这两个 extra 都要显式传。
 *
 * 另外，PendingIntent 的 fill-in Intent（Termux 侧 send(context, code, resultIntent)）
 * 只有在 PendingIntent 可变时 extras 才会被合并进来，因此 Android 12+ 必须用
 * FLAG_MUTABLE，否则结果照样丢。
 */
object TermuxRunner {

    const val TERMUX_PACKAGE = "com.termux"
    const val PERMISSION_RUN_COMMAND = "com.termux.permission.RUN_COMMAND"

    // ---- RUN_COMMAND intent extras（TermuxConstants.TERMUX_APP.RUN_COMMAND_SERVICE）----
    private const val ACTION_RUN_COMMAND = "com.termux.RUN_COMMAND"
    private const val EXTRA_COMMAND_PATH = "com.termux.RUN_COMMAND_PATH"
    private const val EXTRA_ARGUMENTS = "com.termux.RUN_COMMAND_ARGUMENTS"
    private const val EXTRA_WORKDIR = "com.termux.RUN_COMMAND_WORKDIR"
    private const val EXTRA_BACKGROUND = "com.termux.RUN_COMMAND_BACKGROUND"
    private const val EXTRA_RUNNER = "com.termux.RUN_COMMAND_RUNNER"
    private const val EXTRA_STDIN = "com.termux.RUN_COMMAND_STDIN"
    private const val EXTRA_COMMAND_LABEL = "com.termux.RUN_COMMAND_COMMAND_LABEL"
    private const val EXTRA_COMMAND_DESCRIPTION = "com.termux.RUN_COMMAND_COMMAND_DESCRIPTION"
    private const val EXTRA_PENDING_INTENT = "com.termux.RUN_COMMAND_PENDING_INTENT"

    /** 只有 app-shell 会把 stdout/stderr/exitCode 回传给我们 */
    private const val RUNNER_APP_SHELL = "app-shell"

    // ---- 回执 bundle 键（TermuxPluginUtils.setPluginResultPendingIntentVariables）----
    internal const val KEY_RESULT = "result"
    internal const val KEY_STDOUT = "stdout"
    internal const val KEY_STDERR = "stderr"
    internal const val KEY_EXIT_CODE = "exitCode"
    internal const val KEY_ERR = "err"
    internal const val KEY_ERRMSG = "errmsg"

    /** 我们自己塞进 PendingIntent 基础 Intent 里的请求号，用来把回执配回等待者 */
    internal const val EXTRA_REQUEST_ID = "com.maibot.app.TERMUX_REQUEST_ID"
    internal const val ACTION_RESULT = "com.maibot.app.TERMUX_RESULT"

    private const val TERMUX_HOME = "/data/data/com.termux/files/home"
    private const val TERMUX_PREFIX = "/data/data/com.termux/files/usr"
    private const val TERMUX_SH = "$TERMUX_PREFIX/bin/sh"

    private const val SCRIPT_SRC = "maibot-onekey.sh"

    private const val LOG_NAME = ".maibot-run.log"
    private const val RC_NAME = ".maibot-last-rc"
    private const val TAIL_NAME = ".maibot-tail.tmp"
    private const val PART_NAME = ".maibot-script.part"

    private const val MARK = "---MARK---"
    private const val LAUNCH_TOKEN = "MAIBOT_LAUNCHED"
    private const val SELFTEST_TOKEN = "MAIBOT_SELFTEST_OK"

    /** reconnect() 的退出码：Termux 中已找不到仍在运行的任务 */
    const val RECONNECT_NOT_FOUND = -2

    /** 单块下发字符数：走 stdin，不占命令行长度，只受 Binder 事务大小约束 */
    private const val CHUNK_CHARS = 3000

    /** 单次最多读取多少字节的新日志 */
    private const val MAX_READ_BYTES = 24_000

    /** 日志轮询间隔 */
    private const val POLL_MS = 1200L

    /** 简单命令的超时 */
    private const val TIMEOUT_CMD = 30_000L

    /** 启动脚本的超时（脚本本身用 setsid 脱离，会立刻返回） */
    private const val TIMEOUT_LAUNCH = 60_000L

    /** 用户在 Termux 里手动执行一次即可开启外部 App 调用 */
    const val REPAIR_COMMAND =
        "mkdir -p ~/.termux; sed -i '/^allow-external-apps=/d' ~/.termux/termux.properties 2>/dev/null; " +
            "echo 'allow-external-apps=true' >> ~/.termux/termux.properties; termux-reload-settings"

    private val main = Handler(Looper.getMainLooper())

    /** 在途请求：requestId -> 等待者 */
    private val waiters = ConcurrentHashMap<Int, Waiter>()

    private val sequence = AtomicInteger(1000)

    /** 同一时刻只允许一个日志轮询器 */
    @Volatile
    private var watcher: LogWatcher? = null
    @Volatile private var uiTaskActive = false
    fun isUiTaskActive(): Boolean = uiTaskActive

    // ------------------------------------------------------------------
    // 单次命令的执行结果
    // ------------------------------------------------------------------

    class ExecResult(
        val stdout: String?,
        val stderr: String?,
        val exitCode: Int,
        val errCode: Int,
        val errmsg: String?,
        val timeout: Boolean,
        val localError: String?
    ) {
        /**
         * Termux 侧明确报错，或本机就没发出去 / 没人回执。
         *
         * 注意 errCode 的语义：Termux 的 Errno 里
         *     ERRNO_SUCCESS = new Errno(TYPE, Activity.RESULT_OK, "Success")  // = -1
         *     ERRNO_FAILED  = new Errno(TYPE, Activity.RESULT_FIRST_USER + 1, "Failed")  // = 2
         * 即**成功时 err 是 -1**，失败才是正数。所以只能判 `> 0`；
         * 早期版本没带这个键时默认 0，也必须算成功。
         * （曾把它写成 `!= 0`，导致每条成功命令都被当成失败。）
         */
        val failed: Boolean
            get() = localError != null || timeout || errCode > 0 || !errmsg.isNullOrBlank()

        val success: Boolean
            get() = !failed && exitCode == 0

        val output: String
            get() = stdout ?: ""
    }

    private class Waiter {
        val latch = CountDownLatch(1)
        @Volatile var stdout: String? = null
        @Volatile var stderr: String? = null
        @Volatile var exitCode: Int = -1
        @Volatile var errCode: Int = 0
        @Volatile var errmsg: String? = null
    }

    // ------------------------------------------------------------------
    // Termux 基础操作
    // ------------------------------------------------------------------

    fun isTermuxInstalled(context: Context): Boolean {
        return try {
            context.packageManager.getPackageInfo(TERMUX_PACKAGE, 0)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** RUN_COMMAND 是 dangerous 权限，必须运行时申请；这里只查询当前状态 */
    fun hasRunCommandPermission(context: Context): Boolean {
        return try {
            ContextCompat.checkSelfPermission(context, PERMISSION_RUN_COMMAND) ==
                PackageManager.PERMISSION_GRANTED
        } catch (_: Exception) {
            false
        }
    }

    fun openTermux(context: Context): Boolean {
        if (isTermuxInstalled(context)) {
            val intent = context.packageManager.getLaunchIntentForPackage(TERMUX_PACKAGE)
            if (intent != null) {
                try {
                    context.startActivity(intent)
                    return true
                } catch (e: Exception) {
                    Log.e("TermuxRunner", "打开 Termux 失败", e)
                }
            }
        }
        return try {
            context.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse("https://f-droid.org/en/packages/com.termux/"))
            )
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun readScript(context: Context): String =
        context.assets.open(SCRIPT_SRC).use { String(it.readBytes(), Charsets.UTF_8) }

    // ------------------------------------------------------------------
    // 对外入口
    // ------------------------------------------------------------------

    /**
     * 启动一个动作，并开始实时回传日志。
     *
     * 只传 context + action（其余留空）表示"静默执行"：适合 KeepAliveService
     * 的后台自愈，不轮询日志、不与界面抢资源。
     */
    fun run(
        context: Context,
        action: String,
        onStatus: ((String) -> Unit)? = null,
        onProgress: ((String) -> Unit)? = null,
        onFinish: ((Boolean, Int) -> Unit)? = null
    ) {
        val quiet = onProgress == null && onFinish == null
        // 守护自愈不能中断界面正在跟踪的安装任务。
        if (quiet && uiTaskActive) return
        if (!quiet) uiTaskActive = true
        watcher?.stop()
        watcher = null
        val ctx = context.applicationContext

        Thread {
            if (!quiet) {
                // ---- 1. 自检：Termux 能不能跑命令、能不能把回执传回来 ----
                post(onStatus, "正在检查与 Termux 的通信 ...")
                val err = selfTest(ctx)
                if (err != null) {
                    post(onProgress, err)
                    post(onProgress, "")
                    post(onProgress, ">>> 任务未启动。")
                    finishOnce(onFinish, false, -1)
                    return@Thread
                }
                post(onStatus, "通信正常，正在下发脚本 ...")
            }

            // ---- 2. 下发脚本（分块走 stdin + SHA-256 校验）----
            try {
                stageScript(ctx, if (quiet) null else { m -> post(onStatus, m) })
            } catch (e: Exception) {
                if (quiet) return@Thread
                post(onProgress, "脚本下发失败：${e.message}")
                post(onProgress, "")
                post(onProgress, ">>> 任务未启动，请按上面的提示处理后重试。")
                finishOnce(onFinish, false, -1)
                return@Thread
            }

            // ---- 3. 后台拉起脚本，用回执确认真的启动了 ----
            if (!quiet) post(onStatus, "正在启动任务 ...")
            val launched = exec(ctx, launchCmd(action), TIMEOUT_LAUNCH)
            if (quiet) return@Thread

            val ok = launched.success && launched.output.contains(LAUNCH_TOKEN)
            if (!ok) {
                post(onProgress, "任务启动失败：${describe(launched)}")
                if (launched.errmsg != null) {
                    post(onProgress, "Termux 返回：${launched.errmsg}")
                }
                post(onProgress, "")
                post(onProgress, ">>> 请在 Termux 里手动执行一次下面的命令（只需一次）：")
                post(onProgress, "    $REPAIR_COMMAND")
                post(onProgress, ">>> 然后彻底退出 Termux 再打开，回到本 App 重新点按钮。")
                finishOnce(onFinish, false, -1)
                return@Thread
            }

            // ---- 4. 开始轮询日志 ----
            main.post {
                val w = LogWatcher(
                    ctx,
                    onProgress ?: {},
                    onFinish = { success, code ->
                        watcher = null
                        uiTaskActive = false
                        onFinish?.invoke(success, code)
                    },
                    isUiVisible = { TaskSession.isUiVisible() }
                )
                watcher = w
                w.start()
            }
        }.also { it.isDaemon = true }.start()
    }

    /**
     * App 进程被系统终止后，重新接续 Termux 中仍在进行（或刚刚结束）的任务。
     *
     * 只由 [TaskSession.recoverIfNeeded] 调用：
     *  - 读取 $HOME/.maibot-run.pid 判断安装进程是否仍活着（并核对命令行，避免 PID 复用误判）；
     *  - 补读日志尾部，避免重新连接后只看到一片空白；
     *  - 仍在跑：从当前文件末尾继续跟踪；已结束：读取退出码收尾。
     *
     * @param onFinish 参数 (success, code)；code == [RECONNECT_NOT_FOUND] 表示没找到任务
     */
    fun reconnect(
        context: Context,
        onProgress: (String) -> Unit,
        onFinish: (Boolean, Int) -> Unit
    ) {
        val ctx = context.applicationContext
        if (!isTermuxInstalled(ctx)) {
            post(onProgress, "未检测到 Termux，无法确认上次任务的状态。")
            finishOnce(onFinish, false, RECONNECT_NOT_FOUND)
            return
        }
        if (!hasRunCommandPermission(ctx)) {
            post(onProgress, permissionGuide())
            finishOnce(onFinish, false, RECONNECT_NOT_FOUND)
            return
        }

        // 重新连接期间同样禁止守护自愈抢 Termux。
        uiTaskActive = true
        watcher?.stop()
        watcher = null

        Thread {
            val res = try {
                exec(ctx, reconnectProbeCmd(), TIMEOUT_CMD)
            } catch (e: Exception) {
                ExecResult(null, null, -1, 0, null, false, "检查上次任务失败：${e.message}")
            }
            if (res.failed) {
                post(onProgress, "无法检查上次任务：${describe(res)}")
                post(onProgress, "可在 Termux 中执行：tail -n 80 ~/.maibot-run.log 查看。")
                finishOnce(onFinish, false, RECONNECT_NOT_FOUND)
                return@Thread
            }

            val raw = res.output
            val nl = raw.indexOf('\n')
            val header = (if (nl >= 0) raw.substring(0, nl) else raw).trim()
            val fields = HashMap<String, String>()
            header.split(' ').forEach { part ->
                val eq = part.indexOf('=')
                if (eq > 0) fields[part.substring(0, eq)] = part.substring(eq + 1)
            }
            val alive = fields["TRACK"] == "1"
            val size = fields["SIZE"]?.trim()?.toIntOrNull() ?: 0
            val rc = fields["RC"]?.trim()?.toIntOrNull()

            val encoded = if (nl >= 0) raw.substring(nl + 1).trim() else ""
            val tailText = try {
                if (encoded.isEmpty()) "" else String(Base64.decode(encoded, Base64.DEFAULT), Charsets.UTF_8)
            } catch (_: Exception) {
                ""
            }
            if (tailText.isNotBlank()) {
                post(onProgress, "—— 已从 Termux 补读最近的日志 ——")
                tailText.split("\n").forEach { line ->
                    if (line.isNotBlank()) post(onProgress, line.trimEnd('\r'))
                }
            }

            if (alive) {
                post(onProgress, "检测到 Termux 中仍有任务在运行，已重新连接；后续日志会继续显示。")
                main.post {
                    val w = LogWatcher(ctx, onProgress, { success, code ->
                        watcher = null
                        uiTaskActive = false
                        onFinish(success, code)
                    }, initialOffset = size, isUiVisible = { TaskSession.isUiVisible() })
                    watcher = w
                    w.start()
                }
            } else {
                if (rc == null) {
                    post(onProgress, "上次任务没有留下退出码，可能被系统终止。")
                } else {
                    post(onProgress, "上次任务已在 Termux 中结束（退出码 $rc）。")
                }
                finishOnce(onFinish, rc == 0, rc ?: RECONNECT_NOT_FOUND)
            }
        }.also { it.isDaemon = true }.start()
    }

    /** 探测脚本：是否仍在运行 + 日志大小、退出码与日志尾部（Base64，避免多字节截断） */
    private fun reconnectProbeCmd(): String = buildString {
        append("f=\"$TERMUX_HOME/$LOG_NAME\"; ")
        append("p=\$(cat \"$TERMUX_HOME/.maibot-run.pid\" 2>/dev/null); ")
        append("alive=0; ")
        append("if [ -n \"\$p\" ] && kill -0 \"\$p\" 2>/dev/null; then ")
        append("tr '\\0' ' ' < \"/proc/\$p/cmdline\" 2>/dev/null | grep -q maibot-onekey && alive=1; ")
        append("fi; ")
        append("sz=\$(wc -c < \"\$f\" 2>/dev/null || echo 0); ")
        append("rc=\$(cat \"$TERMUX_HOME/$RC_NAME\" 2>/dev/null); ")
        append("printf 'TRACK=%s SIZE=%s RC=%s\\n' \"\$alive\" \"\$sz\" \"\$rc\"; ")
        append("tail -c 12000 \"\$f\" 2>/dev/null | sed '1d' | base64 2>/dev/null")
    }

    /** 轻量动作：取一小段文本回来（"查看登录码""查看状态"） */
    fun query(context: Context, action: String, onResult: (String) -> Unit) {
        val ctx = context.applicationContext
        Thread {
            val text = try {
                val err = selfTest(ctx)
                if (err != null) {
                    err
                } else {
                    stageScript(ctx, null)
                    val res = exec(ctx, queryCmd(action), 180_000)
                    if (res.success) {
                        res.output.ifBlank { "（命令执行成功，但没有输出）" }
                    } else {
                        // 保留脚本 stdout：WebUI/诊断动作会把具体原因写在 stdout，不能只显示笼统退出码。
                        "执行失败：${describe(res)}" +
                            (res.output.takeIf { it.isNotBlank() }?.let { "\n脚本输出：\n${it.take(3000)}" } ?: "") +
                            (res.errmsg?.let { "\nTermux 返回：$it" } ?: "") +
                            (res.stderr?.takeIf { it.isNotBlank() }?.let { "\nstderr：${it.take(600)}" } ?: "")
                    }
                }
            } catch (e: Exception) {
                "执行失败：${e.message}"
            }
            main.post { onResult(text) }
        }.also { it.isDaemon = true }.start()
    }

    /** 只读预检：不下发脚本、不安装软件、不改日志。所有检查放在工作线程。 */
    fun diagnose(context: Context, onResult: (Boolean, String) -> Unit) {
        val ctx = context.applicationContext
        Thread {
            try {
                val error = selfTest(ctx)
                if (error != null) {
                    main.post { onResult(false, error) }
                    return@Thread
                }
                val probe = exec(ctx, "printf 'CPU: '; uname -m; " +
                    "printf '\\n存储空间（最后一列为可用容量）:\\n'; df -h \"$TERMUX_HOME\"; " +
                    "printf '\\n基础工具:\\n'; " +
                    "for c in bash base64 sha256sum tail head wc pgrep; do command -v \"\$c\" || exit 2; done; " +
                    "printf '\\napt/dpkg 占用: '; " +
                    "if pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; " +
                    "then printf '有其它 apt/dpkg 正在运行（安装时会被等待）\\n'; else printf '空闲\\n'; fi; " +
                    "printf '\\nDebian 镜像仓库: '; " +
                    "if command -v curl >/dev/null 2>&1; then " +
                    "code=\$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 https://docker.m.daocloud.io/v2/ 2>/dev/null || echo 000); " +
                    "case \"\$code\" in 401|200) printf '国内镜像可用（%s）\\n' \"\$code\";; *) printf '国内镜像不可达（%s），安装时会自动回退官方源\\n' \"\$code\";; esac; " +
                    "else printf 'curl 未安装（安装脚本会先装）\\n'; fi; " +
                    "printf '\\nDebian 状态: '; " +
                    "if command -v proot-distro >/dev/null 2>&1; then " +
                    "if proot-distro login debian -- /bin/true >/dev/null 2>&1; then printf '可进入\\n'; " +
                    "else printf '未安装或需要修复\\n'; fi; else printf '尚未安装 proot-distro\\n'; fi", TIMEOUT_CMD)
                val ready = probe.success
                val report = "Termux 已安装；命令权限已授权；外部调用与回执正常。\n\n" +
                    probe.output + (probe.stderr?.takeIf { it.isNotBlank() }?.let { "\n$it" } ?: "") +
                    if (ready) "\n建议：连接稳定 Wi-Fi、保留数 GB 空间并接通电源。预检通过不代表 MaiBot 已部署。"
                    else "\n预检失败：${describe(probe)}。请先完成 Termux 自身的基础环境初始化，再重试。"
                main.post { onResult(ready, report) }
            } catch (e: Exception) {
                main.post { onResult(false, "预检失败：${e.message}") }
            }
        }.also { it.isDaemon = true }.start()
    }

    // ------------------------------------------------------------------
    // 自检
    // ------------------------------------------------------------------

    /**
     * 确认 Termux 侧真的能执行命令并把结果回传。
     * @return null 表示一切正常；否则返回给用户看的错误说明
     */
    private fun selfTest(context: Context): String? {
        if (!isTermuxInstalled(context)) {
            return "未检测到 Termux。请先安装 Termux（推荐 F-Droid 版），装好后点【打开 Termux】\n" +
                "并等它把基础环境初始化完成（首次打开会自动下载解压基础包），再回来重试。"
        }
        if (!hasRunCommandPermission(context)) {
            return permissionGuide()
        }

        val res = exec(context, "printf '$SELFTEST_TOKEN'", TIMEOUT_CMD)
        if (res.localError != null) {
            return "无法把命令发给 Termux：${res.localError}\n" + permissionGuide()
        }
        if (res.timeout) {
            return "Termux 没有回执（等待超时）。常见原因：\n" +
                "① 权限弹窗被拒绝 → 请点【修复 Termux 通信】重新授权；\n" +
                "② Termux 被系统冻结 → 请先手动打开一次 Termux，再回到本 App；\n" +
                "③ 本 App 在后台被限制 → 请保持本 App 在前台再点按钮。"
        }
        if (!res.errmsg.isNullOrBlank()) {
            return errmsgGuide(res.errmsg)
        }
        if (!res.output.contains(SELFTEST_TOKEN)) {
            return "Termux 能执行命令，但回传内容异常（退出码 ${res.exitCode}，输出「${res.output.take(120)}」）。\n" +
                "请确认 Termux 已完整初始化（打开 Termux 执行一次 echo ok 有输出）。"
        }
        return null
    }

    private fun permissionGuide(): String =
        "缺少「运行 Termux 命令」权限。这个权限属于 dangerous 级，安装时不会自动授予，\n" +
            "必须在弹窗里点【允许】。\n" +
            "处理：点【修复 Termux 通信】按钮 → 在系统弹窗点【允许】→ 再重新点【初始化环境】。\n" +
            "若没有弹出授权窗口，请到：系统设置 → 应用 → MaiBot一键部署 → 权限，手动允许。"

    private fun errmsgGuide(errmsg: String): String {
        val lower = errmsg.lowercase()
        return if (lower.contains("external-apps") || lower.contains("external_apps")) {
            "Termux 拒绝了外部 App 的调用：它还没有开启 allow-external-apps。\n" +
                "（Termux 原文：${errmsg.replace("\n", " ")}）\n" +
                "\n" +
                "请打开 Termux，粘贴执行下面这一行（只需一次）：\n" +
                "    $REPAIR_COMMAND\n" +
                "然后**彻底退出 Termux**（从后台任务里划掉）再重新打开，回到本 App 点【初始化环境】。\n" +
                "（本 App 的【修复 Termux 通信】按钮会自动帮你复制这条命令。）"
        } else {
            "Termux 执行出错：${errmsg.replace("\n", " ")}"
        }
    }

    /** 把一次执行结果翻译成一句人话 */
    private fun describe(res: ExecResult): String = when {
        res.localError != null -> res.localError
        res.timeout -> "Termux 没有回执（超时）"
        !res.errmsg.isNullOrBlank() -> "Termux 报错：${res.errmsg}"
        res.errCode > 0 -> "Termux 错误码 ${res.errCode}（退出码 ${res.exitCode}）"
        else -> "退出码 ${res.exitCode}"
    }

    // ------------------------------------------------------------------
    // 脚本下发：分块写入 + SHA-256 校验
    // ------------------------------------------------------------------

    /**
     * 把内置脚本分块写入 $HOME/maibot-onekey.sh 并校验完整性。
     *
     * Termux AppShell 会给 stdin 追加换行，因此不能直接 cat 原文。
     * 每块 UTF-8 内容以 Base64 传入 stdin，解码后写入，最后校验原文 SHA-256。
     */
    private fun stageScript(context: Context, onStatus: ((String) -> Unit)?) {
        val text = readScript(context)
        val chunks = chunkText(text, CHUNK_CHARS)
        val expect = sha256Hex(chunks)
        val tmp = "$TERMUX_HOME/$PART_NAME"
        val existing = exec(context, "sha256sum \"$TERMUX_HOME/$SCRIPT_SRC\" 2>/dev/null | cut -d' ' -f1", TIMEOUT_CMD)
        // 直接比对哈希值，不依赖退出码判定，避免误跳过或误报。
        if (existing.localError == null && !existing.timeout && existing.errmsg == null &&
            existing.output.trim() == expect
        ) {
            onStatus?.invoke("脚本已是最新版本，跳过重复传输。")
            return
        }
        val cleaned = exec(context, "rm -f \"$tmp\"", TIMEOUT_CMD)
        if (!cleaned.success) {
            throw IllegalStateException(
                "无法准备脚本临时文件（${describe(cleaned)}）。请确认 Termux 可写、空间充足后重试。"
            )
        }

        chunks.forEachIndexed { index, chunk ->
            // Base64 解码忽略 AppShell 自动追加的换行，保留脚本的精确字节。
            val encoded = Base64.encodeToString(chunk.toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
            val res = exec(context, "base64 -d >> \"$tmp\"", TIMEOUT_CMD, stdin = encoded)
            if (!res.success) {
                execSync(context, "rm -f \"$tmp\"", TIMEOUT_CMD)
                throw IllegalStateException(
                    "脚本写入失败（第 ${index + 1}/${chunks.size} 块：${describe(res)}）"
                )
            }
            onStatus?.invoke("正在下发脚本 ... ${(index + 1) * 100 / chunks.size}%")
        }

        val hash = exec(context, "sha256sum \"$tmp\" 2>/dev/null | cut -d' ' -f1", TIMEOUT_CMD)
        val actual = hash.output.trim().lowercase()
        if (actual.isBlank()) {
            execSync(context, "rm -f \"$tmp\"", TIMEOUT_CMD)
            throw IllegalStateException(
                "无法校验脚本（sha256sum 不可用：${describe(hash)}）。请打开 Termux 执行：pkg install -y coreutils"
            )
        }
        if (actual != expect) {
            execSync(context, "rm -f \"$tmp\"", TIMEOUT_CMD)
            throw IllegalStateException(
                "脚本校验失败（期望 ${expect.take(12)}…，实际 ${actual.take(12)}…），请重试。"
            )
        }

        val mv = exec(context, "mv -f \"$tmp\" \"$TERMUX_HOME/${SCRIPT_SRC}\" && chmod 700 \"$TERMUX_HOME/${SCRIPT_SRC}\"", TIMEOUT_CMD)
        if (!mv.success) throw IllegalStateException("脚本落位失败（${describe(mv)}）")
    }

    /** 按字符切块，保证不把一个代理对劈成两半 */
    private fun chunkText(text: String, size: Int): List<String> {
        if (text.isEmpty()) return listOf("")
        val out = ArrayList<String>((text.length / size) + 1)
        var i = 0
        while (i < text.length) {
            var end = minOf(i + size, text.length)
            if (end < text.length && Character.isHighSurrogate(text[end - 1])) end++
            out.add(text.substring(i, end))
            i = end
        }
        return out
    }

    /** 对"实际发出去的内容"求哈希，避免编码差异导致误判 */
    private fun sha256Hex(chunks: List<String>): String {
        val md = MessageDigest.getInstance("SHA-256")
        chunks.forEach { md.update(it.toByteArray(Charsets.UTF_8)) }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    // ------------------------------------------------------------------
    // 命令构造
    // ------------------------------------------------------------------

    /**
     * 拉起脚本并后台执行。
     *
     * 用 setsid 让脚本脱离本次会话，这样 Termux 的命令执行完返回后部署任务仍能继续跑；
     * 结尾打印 [LAUNCH_TOKEN] 作为"真的启动了"的回执。
     */
    private fun launchCmd(action: String): String = buildString {
        append("cd \"$TERMUX_HOME\" || exit 1; ")
        // 尽早获取 Termux 唤醒锁：脚本内部要到第 4 步才获取，而前面的 apt 下载同样需要，
        // 否则用户一开始就切后台/锁屏时，Termux 可能被系统冻结、下载停滞。
        append("if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock >/dev/null 2>&1 || true; fi; ")
        append("rm -f \"$TERMUX_HOME/$LOG_NAME\" \"$TERMUX_HOME/$RC_NAME\"; ")
        append("L=; command -v setsid >/dev/null 2>&1 && L=setsid; ")
        append("\$L bash -c 'bash \"$TERMUX_HOME/$SCRIPT_SRC\" $action; rc=\$?; " +
            "printf \"%s\\n\" \"\$rc\" > \"$TERMUX_HOME/$RC_NAME\"' " +
            ">/dev/null 2>&1 </dev/null & ")
        append("printf '$LAUNCH_TOKEN'")
    }

    /** 轻量查询：直接取脚本输出（stdout 现在是纯文本，不需要 base64） */
    private fun queryCmd(action: String): String =
        "cd \"$TERMUX_HOME\" && MAIBOT_QUERY=1 bash \"$TERMUX_HOME/${SCRIPT_SRC}\" $action 2>&1"

    // ------------------------------------------------------------------
    // 与 Termux 通信（核心）
    // ------------------------------------------------------------------

    private fun buildPendingIntent(context: Context, requestId: Int): PendingIntent {
        val intent = Intent(context, TermuxResultReceiver::class.java).apply {
            action = ACTION_RESULT
            putExtra(EXTRA_REQUEST_ID, requestId)
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        // Android 12+ 必须显式声明可变性；只有可变 PendingIntent 才会合并 Termux 的
        // fill-in Intent extras（也就是真正的结果内容）。
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        return PendingIntent.getBroadcast(context, requestId, intent, flags)
    }

    /**
     * 给每条命令注入 Termux 的基础环境变量。
     *
     * 脚本用 `[ -n "$PREFIX" ]` 判断"我在 Termux 层还是容器层"（maibot-onekey.sh:187），
     * 而 AppShell 不保证继承完整的 Termux 环境；PREFIX/TMPDIR 缺失会让脚本走错分支
     * （误判成容器层 → 找不到 proot-distro）。这里显式补齐，消除这个不确定性。
     */
    private fun envPrefix(): String =
        "export HOME=$TERMUX_HOME; " +
            "export PREFIX=$TERMUX_PREFIX; " +
            "export TMPDIR=$TERMUX_PREFIX/tmp; " +
            "export PATH=$TERMUX_PREFIX/bin:$TERMUX_PREFIX/bin/applets:\$PATH; " +
            "export LD_LIBRARY_PATH=$TERMUX_PREFIX/lib; "

    /**
     * 执行一条命令并等回执。stdin 非空时同时把内容喂给命令的标准输入。
     */
    private fun exec(
        context: Context,
        cmd: String,
        timeoutMs: Long,
        stdin: String? = null
    ): ExecResult {
        if (!isTermuxInstalled(context)) {
            return ExecResult(null, null, -1, 0, null, false, "Termux 未安装")
        }

        val id = sequence.incrementAndGet()
        val waiter = Waiter()
        waiters[id] = waiter
        var pending: PendingIntent? = null

        try {
            pending = buildPendingIntent(context, id)
            val intent = Intent().apply {
                setClassName(TERMUX_PACKAGE, "com.termux.app.RunCommandService")
                action = ACTION_RUN_COMMAND
                // 用 Termux 自带的 sh；若 Termux 还没初始化完，它会通过 errmsg 明确告知
                putExtra(EXTRA_COMMAND_PATH, TERMUX_SH)
                putExtra(EXTRA_ARGUMENTS, arrayOf("-c", envPrefix() + cmd))
                putExtra(EXTRA_WORKDIR, TERMUX_HOME)
                putExtra(EXTRA_BACKGROUND, true)
                putExtra(EXTRA_RUNNER, RUNNER_APP_SHELL)
                putExtra(EXTRA_COMMAND_LABEL, "MaiBot 一键部署")
                putExtra(EXTRA_COMMAND_DESCRIPTION, "由 MaiBot 一键部署助手发起")
                putExtra(EXTRA_PENDING_INTENT, pending)
                putExtra(EXTRA_REQUEST_ID, id)
                if (stdin != null) putExtra(EXTRA_STDIN, stdin)
            }
            context.startService(intent)
        } catch (e: SecurityException) {
            waiters.remove(id)
            pending?.cancel()
            Log.e("TermuxRunner", "Termux 拒绝执行", e)
            return ExecResult(
                null, null, -1, 0, null, false,
                "缺少 com.termux.permission.RUN_COMMAND 授权（${e.message}）"
            )
        } catch (e: IllegalStateException) {
            waiters.remove(id)
            pending?.cancel()
            Log.e("TermuxRunner", "后台限制禁止启动服务", e)
            return ExecResult(
                null, null, -1, 0, null, false,
                "系统不允许本 App 在后台启动 Termux 服务，请保持本 App 在前台（或开启常驻守护）后重试"
            )
        } catch (e: Exception) {
            waiters.remove(id)
            pending?.cancel()
            Log.e("TermuxRunner", "startService 失败", e)
            return ExecResult(null, null, -1, 0, null, false, "无法调用 Termux：${e.message}")
        }

        return try {
            if (!waiter.latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                ExecResult(null, null, -1, 0, null, true, null)
            } else {
                ExecResult(
                    stdout = waiter.stdout,
                    stderr = waiter.stderr,
                    exitCode = waiter.exitCode,
                    errCode = waiter.errCode,
                    errmsg = waiter.errmsg?.takeIf { it.isNotBlank() },
                    timeout = false,
                    localError = null
                )
            }
        } finally {
            waiters.remove(id)
            pending.cancel()
        }
    }

    /** 供 TermuxResultReceiver 调用：把 Termux 的回执配回等待中的请求 */
    internal fun deliver(intent: Intent?) {
        if (intent == null) return
        val id = intent.getIntExtra(EXTRA_REQUEST_ID, -1)
        if (id < 0) return
        val waiter = waiters[id] ?: return

        val bundle: Bundle? = intent.getBundleExtra(KEY_RESULT)
        if (bundle != null) {
            waiter.stdout = bundle.getString(KEY_STDOUT)
            waiter.stderr = bundle.getString(KEY_STDERR)
            waiter.exitCode = bundle.getInt(KEY_EXIT_CODE, -1)
            waiter.errCode = bundle.getInt(KEY_ERR, 0)
            waiter.errmsg = bundle.getString(KEY_ERRMSG)
        } else {
            // 兜底：万一某个版本把结果平铺在顶层
            waiter.stdout = intent.getStringExtra(KEY_STDOUT)
            waiter.stderr = intent.getStringExtra(KEY_STDERR)
            waiter.exitCode = intent.getIntExtra(KEY_EXIT_CODE, -1)
            waiter.errCode = intent.getIntExtra(KEY_ERR, 0)
            waiter.errmsg = intent.getStringExtra(KEY_ERRMSG)

            // 回执来了但没有任何已知字段：把实际收到的 extras 原样报出来，
            // 便于一眼看出是不是协议又变了（而不是只显示一个"启动失败"）。
            if (waiter.stdout == null && waiter.stderr == null && waiter.errmsg == null) {
                val keys = intent.extras?.keySet()?.joinToString(", ") ?: "(无 extras)"
                waiter.errmsg = "Termux 回执格式无法识别，实际收到的 extras：[$keys]"
                Log.w("TermuxRunner", "无法识别的回执 extras: [$keys]")
            }
        }
        waiter.latch.countDown()
    }

    /** 同步执行，只关心是否成功 */
    private fun execSync(context: Context, cmd: String, timeoutMs: Long): Boolean =
        exec(context, cmd, timeoutMs).success

    private fun post(f: ((String) -> Unit)?, msg: String) {
        if (f == null) return
        main.post { f(msg) }
    }

    private fun finishOnce(f: ((Boolean, Int) -> Unit)?, ok: Boolean, code: Int) {
        uiTaskActive = false
        if (f == null) return
        main.post { f(ok, code) }
    }

    // ------------------------------------------------------------------
    // 日志轮询
    // ------------------------------------------------------------------

    /**
     * 按"字节偏移量"增量读取日志，全程在后台线程里跑。
     *
     * 每次让 Termux 侧把新增内容落到 $HOME/.maibot-tail.tmp，同时用 `wc -c` 报出
     * 真实字节数，因此偏移量永远是准确的（不会因为中文等多字节字符而错位、重复显示）。
     *
     * 回传格式（stdout 纯文本）：
     *     <日志文件字节数>|<本次新增字节数>|<退出码>\n---MARK---\n<新增日志>
     */
    private class LogWatcher(
        private val context: Context,
        private val onProgress: (String) -> Unit,
        private val onFinish: (Boolean, Int) -> Unit,
        initialOffset: Int = 0,
        private val isUiVisible: () -> Boolean = { true }
    ) {
        @Volatile
        private var stopped = false
        private var offset = initialOffset
        private var polls = 0
        private var announced = false
        private var warned = false
        private var readFailures = 0
        private var pendingUtf8 = ByteArray(0)
        private val decoder = Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPLACE)
            .onUnmappableCharacter(CodingErrorAction.REPLACE)

        private val worker = Thread { loop() }.also { it.isDaemon = true }

        fun start() {
            worker.start()
        }

        fun stop() {
            stopped = true
            worker.interrupt()
        }

        private fun loop() {
            while (!stopped) {
                polls++
                val res = try {
                    exec(context, pollCmd(offset + 1), TIMEOUT_CMD)
                } catch (_: InterruptedException) {
                    return
                } catch (e: Exception) {
                    ExecResult(null, null, -1, 0, null, false, "日志读取异常：${e.message}")
                }
                handle(res)
                if (stopped) return
                if (polls > 18_000) { // 约 6 小时上限（慢网络下的 Debian + MaiBot 安装可能超过 1 小时）
                    stopped = true
                    main.post {
                        onProgress("")
                        onProgress("[注意] 日志跟踪已达到 6 小时上限，已停止显示。Termux 中的任务可能仍在继续，请打开 Termux 查看。")
                        onFinish(false, -1)
                    }
                    return
                }
                try {
                    // 读日志失败时放慢重试；回到前台后成功一次即恢复原节奏。
                    Thread.sleep(if (readFailures > 0) 5_000L else POLL_MS)
                } catch (_: InterruptedException) {
                    return
                }
            }
        }

        private fun pollCmd(from: Int): String = buildString {
            append("f=\"$TERMUX_HOME/$LOG_NAME\"; t=\"$TERMUX_HOME/$TAIL_NAME\"; ")
            append("sz=\$(wc -c < \"\$f\" 2>/dev/null || echo 0); ")
            append("tail -c +$from \"\$f\" 2>/dev/null | head -c $MAX_READ_BYTES > \"\$t\" 2>/dev/null; ")
            append("n=\$(wc -c < \"\$t\" 2>/dev/null || echo 0); ")
            append("printf '%s|%s|' \"\$sz\" \"\$n\"; ")
            append("cat \"$TERMUX_HOME/$RC_NAME\" 2>/dev/null; ")
            append("printf '\\n$MARK\\n'; ")
            // 回执只传 ASCII，避免 Termux 在解码截断的 UTF-8 时丢失字节。
            append("base64 \"\$t\" 2>/dev/null")
        }

        private fun handle(res: ExecResult) {
            if (stopped) return

            if (res.failed) {
                readFailures++
                if (readFailures == 2 || readFailures % 60 == 0) {
                    main.post {
                        onProgress("")
                        onProgress("[注意] 暂时读不到任务日志（第 ${readFailures} 次重试）；Termux 中的任务可能仍在继续，稍后会自动重试。")
                    }
                }
                // 前台持续失败说明通信真的断了，及时报错；后台失败则一直重试，
                // 避免用户一切后台就被误判成“任务结束”（这正是旧版的问题）。
                if (readFailures >= 12 && isUiVisible()) {
                    stopped = true
                    main.post {
                        onProgress("[错误] 连续多次无法读取任务日志：${describe(res)}")
                        onProgress("这里只停止日志跟踪，Termux 中的安装可能仍在继续。请先打开 Termux 查看任务，不要立即重复安装。")
                        onFinish(false, -1)
                    }
                }
                return
            }
            val text = res.stdout
            if (text.isNullOrEmpty()) {
                if (polls == 12 && !warned) {
                    warned = true
                    main.post {
                        onProgress("")
                        onProgress("[注意] 暂时读不到任务日志。若长时间没有新内容，请在 Termux 里执行：")
                        onProgress("    bash ~/maibot-onekey.sh setup")
                        onProgress("查看真实报错，或确认已开启 allow-external-apps。")
                    }
                }
                return
            }

            val markIdx = text.indexOf(MARK)
            if (markIdx < 0) return

            val header = text.substring(0, markIdx).trim()
            val parts = header.split("|")
            val fileSize = parts.getOrNull(0)?.trim()?.toIntOrNull() ?: -1
            val chunkBytes = parts.getOrNull(1)?.trim()?.toIntOrNull() ?: 0
            val exitCode = parts.getOrNull(2)?.trim()?.toIntOrNull()

            // 日志被清空/重建（新一轮任务开始）→ 偏移量与完成标记一起复位
            if (fileSize in 0 until offset) {
                offset = 0
                announced = false
                pendingUtf8 = ByteArray(0)
                decoder.reset()
                return
            }

            val encoded = text.substring(markIdx + MARK.length).trim()
            val bytes = try { Base64.decode(encoded, Base64.DEFAULT) } catch (_: IllegalArgumentException) {
                handle(ExecResult(null, null, -1, 0, null, false, "日志编码无效"))
                return
            }
            if (bytes.size != chunkBytes) {
                handle(ExecResult(null, null, -1, 0, null, false, "日志字节数不匹配：$chunkBytes/${bytes.size}"))
                return
            }
            readFailures = 0
            val input = ByteBuffer.wrap(pendingUtf8 + bytes)
            val output = CharBuffer.allocate(input.remaining() + 1)
            val ended = exitCode != null && offset + chunkBytes >= fileSize
            decoder.decode(input, output, ended)
            pendingUtf8 = ByteArray(input.remaining()).also { input.get(it) }
            output.flip()
            val data = output.toString()
            if (chunkBytes > 0) {
                offset += chunkBytes
                data.split("\n").forEach { line ->
                    val l = line.trimEnd('\r')
                    if (l.isNotBlank()) main.post { onProgress(l) }
                }
            } else if (fileSize == 0 && polls == 12 && !warned) {
                warned = true
                main.post {
                    onProgress("[注意] 任务已启动，但日志文件仍为空。")
                    onProgress("如果 1 分钟内仍无输出，请在 Termux 里手动执行：bash ~/maibot-onekey.sh setup")
                }
            }

            // 退出码出现 → 任务真的结束了
            // 已结束也先读完剩余日志，避免最后一批错误被遗漏。
            if (exitCode != null && offset >= fileSize && !announced) {
                announced = true
                stopped = true
                main.postDelayed({ onFinish(exitCode == 0, exitCode) }, 600)
            }
        }
    }
}
