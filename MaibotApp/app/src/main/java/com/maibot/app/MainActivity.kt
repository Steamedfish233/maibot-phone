package com.maibot.app

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat

/**
 * 主界面：只做三件事——装好 MaiBot、开两个 WebUI、把 QQ 适配器接上。
 *
 * 页面是单页滚动，日志放在页面末尾；不再内嵌 MaiBot 的 WebUI 页面
 * （手机屏幕放不下桌面版页面，原生重做也不现实），只负责把浏览器叫起来。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var tvTermux: TextView
    private lateinit var tvMaibot: TextView
    private lateinit var tvNapcat: TextView
    private lateinit var tvGuard: TextView
    private lateinit var tvLog: TextView
    private lateinit var tvLogTitle: TextView
    private lateinit var svLog: ScrollView
    private lateinit var pbLog: ProgressBar
    private lateinit var logPanel: LinearLayout
    private lateinit var tvLogToggle: TextView
    private lateinit var tvLogLatest: TextView
    private lateinit var etQq: EditText
    private lateinit var swKeepAlive: SwitchCompat
    private lateinit var swAutoRestart: SwitchCompat
    private lateinit var swAutoStart: SwitchCompat
    private lateinit var prefs: Prefs

    private val ui = Handler(Looper.getMainLooper())

    /** 等授权：授权成功后自动继续执行的动作（含顺序安装的下一步） */
    private var pendingAction: PendingRun? = null
    private var openTermuxAfterGrant = false
    private var checking = false
    private var pendingDiagnostic = false
    private var pendingAutoInstall = false
    private var diagnosticPassed = false

    /** 只有用户停在日志底部时才自动跟随，避免"正往回看就被拽到底" */
    private var autoScroll = true
    private var logExpanded = false
    private var lastRunning = false

    private data class PendingRun(
        val action: String,
        val msg: String,
        val nextAction: String? = null,
        val nextMsg: String? = null
    )

    companion object {
        private const val REQ_RUN_COMMAND = 1002

        /** 项目主页：原来的"联系作者 QQ"改成打开仓库，问题走 Issues。 */
        private const val PROJECT_URL = "https://github.com/Steamedfish233/maibot-phone"

        /** 这些动作会下载大量文件，值得提示关闭电池优化 */
        private val LONG_ACTIONS = setOf("setup", "install", "update", "napcat-install")

        private val BUSY_BUTTONS = listOf(
            R.id.btn_setup, R.id.btn_install, R.id.btn_start, R.id.btn_stop,
            R.id.btn_update, R.id.btn_napcat_install, R.id.btn_napcat_start,
            R.id.btn_napcat_stop, R.id.btn_napcat_setup, R.id.btn_napcat_webui,
            R.id.btn_allstart, R.id.btn_allstop, R.id.btn_webui, R.id.btn_webui_check,
            R.id.btn_adapter_setup, R.id.btn_adapter_status, R.id.btn_doctor, R.id.btn_fix_deps,
            R.id.btn_install_guide, R.id.btn_diagnose, R.id.btn_auto_install,
            R.id.btn_fix_termux, R.id.btn_github
        )
    }

    /**
     * 会话监听：日志和任务状态由 [TaskSession] 持有，本 Activity 只负责渲染。
     * 这样退到后台、旋转屏幕或重建后都能接回同一个安装任务。
     */
    private val sessionListener = object : TaskSession.Listener {
        override fun onLogChanged(text: String, running: Boolean, title: String) {
            val wasRunning = lastRunning
            lastRunning = running
            // 任务一开始就展开日志并恢复跟随，否则用户看不到进度。
            if (running && !wasRunning) {
                autoScroll = true
                if (!logExpanded) setLogExpanded(true)
            }
            renderLog(text, running, title)
            if (running) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
            setBusy(running)
            refreshStatus()
        }

        override fun onFinished(success: Boolean) {
            refreshStatus()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        prefs = Prefs(this)

        tvTermux = findViewById(R.id.tv_termux)
        tvMaibot = findViewById(R.id.tv_maibot)
        tvNapcat = findViewById(R.id.tv_napcat)
        tvGuard = findViewById(R.id.tv_guard)
        tvLog = findViewById(R.id.tv_log)
        tvLogTitle = findViewById(R.id.tv_log_title)
        svLog = findViewById(R.id.sv_log)
        pbLog = findViewById(R.id.pb_log)
        logPanel = findViewById(R.id.log_panel)
        tvLogToggle = findViewById(R.id.tv_log_toggle)
        tvLogLatest = findViewById(R.id.tv_log_latest)
        etQq = findViewById(R.id.et_qq)
        swKeepAlive = findViewById(R.id.sw_keepalive)
        swAutoRestart = findViewById(R.id.sw_autorestart)
        swAutoStart = findViewById(R.id.sw_autostart)

        bindSwitches()
        bindButtons()
        bindLog()
        askNotificationPermission()
        // 任务进行中或已有日志时默认展开，否则保持收起、给页面留空间。
        setLogExpanded(TaskSession.isRunning() || TaskSession.text().isNotBlank())
        refreshStatus()
    }

    override fun onStart() {
        super.onStart()
        TaskSession.onUiShown()
        KeepAliveService.clearResultNotification(this)
        TaskSession.attach(sessionListener)
        TaskSession.recoverIfNeeded(this)
    }

    override fun onStop() {
        TaskSession.detach(sessionListener)
        TaskSession.onUiHidden()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        syncSwitches()
        refreshStatus()
    }

    // ---------------- 日志 ----------------

    private fun bindLog() {
        // 向上翻立即暂停跟随；回到底部再恢复。
        svLog.setOnScrollChangeListener { _, _, scrollY, _, oldScrollY ->
            if (scrollY < oldScrollY) autoScroll = false
            else if (!svLog.canScrollVertically(1)) autoScroll = true
            updateLatestButton()
        }
        tvLogToggle.setOnClickListener { setLogExpanded(!logExpanded) }
        tvLogTitle.setOnClickListener { setLogExpanded(!logExpanded) }
        tvLogLatest.setOnClickListener {
            autoScroll = true
            svLog.fullScroll(View.FOCUS_DOWN)
            updateLatestButton()
        }
        findViewById<TextView>(R.id.tv_log_copy).setOnClickListener {
            val log = TaskSession.text()
            if (log.isBlank()) {
                toast("暂无日志可复制")
                return@setOnClickListener
            }
            copyToClipboard(log, "MaiBot 运行日志")
            toast("运行日志已复制")
        }
        findViewById<TextView>(R.id.tv_log_clear).setOnClickListener {
            if (TaskSession.isRunning()) {
                toast("任务进行中，结束后再清空")
                return@setOnClickListener
            }
            TaskSession.append("__CLEAR__")
            autoScroll = true
        }
    }

    private fun renderLog(text: String, running: Boolean, title: String) {
        val shown = text.ifBlank { "点上方按钮开始操作，进度会实时显示在这里。" }
        if (tvLog.text.toString() != shown) tvLog.text = shown
        tvLog.contentDescription = title
        pbLog.visibility = if (running) View.VISIBLE else View.GONE
        tvLogTitle.text = if (running) "运行日志 · 进行中" else "运行日志"
        scrollLogToBottom()
        updateLatestButton()
    }

    /**
     * 自动滚到最新一行。
     *
     * setText 之后 TextView 还没重新测量，立即 fullScroll 只会滚到"旧的底部"，
     * 看起来就是日志不跟着走。这里先让布局跑一轮，再滚；再补一次兜底，
     * 处理长行换行导致高度二次变化的情况。
     */
    private fun scrollLogToBottom() {
        if (!autoScroll) return
        svLog.post {
            svLog.fullScroll(View.FOCUS_DOWN)
            svLog.post { if (autoScroll) svLog.fullScroll(View.FOCUS_DOWN) }
        }
    }

    private fun updateLatestButton() {
        tvLogLatest.visibility =
            if (logExpanded && !autoScroll && svLog.canScrollVertically(1)) View.VISIBLE else View.GONE
    }

    private fun setLogExpanded(expanded: Boolean) {
        logExpanded = expanded
        svLog.visibility = if (expanded) View.VISIBLE else View.GONE
        tvLogToggle.text = if (expanded) "收起" else "展开"
        updateLatestButton()
        if (expanded) scrollLogToBottom()
    }

    // ---------------- 保活开关 ----------------

    private fun syncSwitches() {
        swKeepAlive.isChecked = prefs.keepAlive
        swAutoRestart.isChecked = prefs.autoRestart
        swAutoStart.isChecked = prefs.autoStart
    }

    private fun bindSwitches() {
        swKeepAlive.setOnCheckedChangeListener { _, checked ->
            prefs.keepAlive = checked
            if (checked) {
                askNotificationPermission()
                KeepAliveService.start(this)
                appendLog("已开启常驻守护：手机锁屏后 CPU 不会被冻结，App 会常驻通知栏。")
            } else {
                if (TaskSession.isRunning()) {
                    appendLog("已关闭常驻守护：当前安装任务结束后，常驻通知会自动停止。")
                    toast("安装任务仍在后台继续，结束后自动停止守护")
                } else {
                    KeepAliveService.stop(this)
                    appendLog("已关闭常驻守护。")
                }
            }
            refreshStatus()
        }

        swAutoRestart.setOnCheckedChangeListener { _, checked ->
            prefs.autoRestart = checked
            appendLog(
                if (checked) "已开启掉线自动重启：每分钟检测 8001/6099 端口，掉线会自动重新拉起。"
                else "已关闭掉线自动重启。"
            )
        }

        swAutoStart.setOnCheckedChangeListener { _, checked ->
            prefs.autoStart = checked
            if (checked && !prefs.keepAlive) {
                swKeepAlive.isChecked = true
                appendLog("已开启开机自启（同时开启常驻守护，确保重启后能自动恢复服务）")
            } else {
                appendLog(
                    if (checked) "已开启开机自启：手机重启后会自动恢复 MaiBot 与 NapCat。"
                    else "已关闭开机自启。"
                )
            }
        }
    }

    // ---------------- 按钮 ----------------

    private fun bindButtons() {
        findViewById<Button>(R.id.btn_battery).setOnClickListener { requestIgnoreBattery() }
        findViewById<Button>(R.id.btn_allstart).setOnClickListener {
            runAction("guard", "正在启动全部服务并开启守护")
        }
        findViewById<Button>(R.id.btn_allstop).setOnClickListener {
            runAction("guard-stop", "正在停止全部服务与守护")
        }

        findViewById<Button>(R.id.btn_termux).setOnClickListener {
            TermuxRunner.openTermux(this)
            toast(if (TermuxRunner.isTermuxInstalled(this)) "已打开 Termux" else "已打开下载页，装好后回来")
            refreshStatus()
        }
        findViewById<Button>(R.id.btn_refresh).setOnClickListener { refreshStatus() }

        findViewById<Button>(R.id.btn_fix_termux).setOnClickListener { fixTermuxCommunication() }
        findViewById<Button>(R.id.btn_github).setOnClickListener { openProjectRepo() }
        findViewById<Button>(R.id.btn_install_guide).setOnClickListener { showInstallGuide() }
        findViewById<Button>(R.id.btn_diagnose).setOnClickListener { checkInstallConditions() }
        findViewById<Button>(R.id.btn_auto_install).setOnClickListener {
            val builder = AlertDialog.Builder(this)
                .setTitle("按顺序安装 Debian 和 MaiBot")
                .setMessage(
                    "先检查通信与基础工具，再初始化 Debian，成功后继续部署 MaiBot。失败会停止，" +
                        "不会自动启动机器人、同意协议或填写模型密钥。\n\n" +
                        "安装会下载较多文件，请接通电源、连接稳定网络并预留数 GB 空间。" +
                        "安装期间可以切到后台或锁屏，通知栏会持续显示进度；请勿重复点击安装。\n\n" +
                        "若尚未关闭电池优化，建议先点「关闭电池优化」，否则锁屏较久后系统可能限制网络。"
                )
                .setPositiveButton("检查并安装") { _, _ -> checkInstallConditions(true) }
                .setNegativeButton("暂不安装", null)
            if (!isIgnoringBatteryOptimizations()) {
                builder.setNeutralButton("先关电池优化") { _, _ -> requestIgnoreBattery() }
            }
            builder.show()
        }

        click(R.id.btn_setup, "setup", "初始化环境（安装 Debian 容器）")
        click(R.id.btn_install, "install", "部署 MaiBot")
        click(R.id.btn_start, "start", "启动 MaiBot")
        click(R.id.btn_stop, "stop", "停止 MaiBot")
        click(R.id.btn_update, "update", "更新 MaiBot")
        click(R.id.btn_napcat_install, "napcat-install", "安装 NapCat")
        click(R.id.btn_napcat_start, "napcat-start", "启动 NapCat")
        click(R.id.btn_napcat_stop, "napcat-stop", "停止 NapCat")

        // WebUI 与自检：脚本确认地址可用后，交给手机浏览器打开。
        quickQuery(R.id.btn_webui, "webui", "打开 MaiBot WebUI")
        quickQuery(R.id.btn_napcat_webui, "napcat-webui", "打开 NapCat WebUI")
        quickQuery(R.id.btn_webui_check, "webui-check", "检测 WebUI 是否可用")
        quickQuery(R.id.btn_adapter_status, "adapter-status", "检测适配器连接状态")
        quickQuery(R.id.btn_doctor, "doctor", "连接诊断（打不开 WebUI 时先点这个）")
        click(R.id.btn_fix_deps, "fix-deps", "修复 MaiBot 依赖（uv sync）")

        findViewById<Button>(R.id.btn_napcat_setup).setOnClickListener {
            val qq = sanitizeQq(etQq.text.toString())
            if (qq == null) {
                toast("请填写正确的 QQ 号（5-15 位纯数字）")
                return@setOnClickListener
            }
            etQq.setText(qq)
            runAction("napcat-setup $qq", "配置 QQ 号 $qq")
        }

        findViewById<Button>(R.id.btn_adapter_setup).setOnClickListener {
            val qq = sanitizeQq(etQq.text.toString())
            if (qq == null) {
                toast("先在上面填写机器人 QQ 号（5-15 位纯数字）")
                return@setOnClickListener
            }
            etQq.setText(qq)
            runAction("adapter-setup $qq", "配置适配器连接（QQ $qq）")
        }
    }

    /**
     * QQ 号白名单校验，兼作命令注入防护。
     *
     * 这个值最终会被拼进交给 Termux 执行的 shell 命令里。若不做严格校验，
     * 输入 `123456; rm -rf $HOME; #` 这类内容就能以用户身份执行任意命令。
     * 因此这里只接受 5-15 位纯数字，任何其它字符（空格、分号、引号、$、反引号、
     * 换行等）一律判为非法并返回 null，从源头上保证拼进命令的字符串不可能
     * 携带 shell 元字符。
     */
    private fun sanitizeQq(raw: String): String? {
        val qq = raw.trim()
        // 只允许 ASCII 数字：\d 在部分实现里会匹配全角数字等，这里显式限定字符集
        if (qq.isEmpty() || qq.length !in 5..15) return null
        for (c in qq) {
            if (c !in '0'..'9') return null
        }
        return qq
    }

    private fun click(id: Int, action: String, msg: String) {
        findViewById<Button>(id).setOnClickListener { runAction(action, msg) }
    }

    /** 只打开本机回环地址，拒绝脚本意外返回的外部链接 */
    private fun openWebUi(url: String) {
        if (!url.startsWith("http://127.0.0.1:") && !url.startsWith("http://localhost:")) {
            appendLog("拒绝打开非本机 WebUI 地址：$url")
            return
        }
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            appendLog("已交给手机浏览器打开：$url")
        } catch (e: Exception) {
            appendLog("无法启动浏览器：${e.message ?: "未知错误"}；请手动访问 $url")
        }
    }

    /** 轻量动作：不需要进度条，直接把脚本输出贴出来 */
    private fun quickQuery(id: Int, action: String, msg: String) {
        findViewById<Button>(id).setOnClickListener {
            if (!ensureTermux()) return@setOnClickListener
            if (!ensureRunCommandPermission(null)) return@setOnClickListener
            if (TaskSession.isRunning()) {
                toast("有任务正在进行，请稍候")
                return@setOnClickListener
            }
            TaskSession.begin(this, msg)
            TaskSession.append("执行中 ...")
            TermuxRunner.query(this, action) { text ->
                if (text.isNullOrBlank()) {
                    TaskSession.append("没有拿到输出。可能是该功能尚未启动，或 Termux 未允许外部 App 执行命令。")
                    TaskSession.append("提示：请在 Termux 里执行一次  termux-setup-storage ，并确认已安装 Termux（F-Droid 版）。")
                } else {
                    var opened = false
                    text.trim().split("\n").forEach { line ->
                        TaskSession.append(line)
                        if (line.startsWith("WEBUI_UNAVAILABLE=1")) {
                            toast("WebUI 暂时打不开，日志里有原因")
                        }
                        if (line.startsWith("WEBUI_URL=")) {
                            val url = line.substringAfter('=').trim()
                            if (!opened) {
                                opened = true
                                openWebUi(url)
                            }
                        }
                    }
                }
                TaskSession.end()
            }
        }
    }

    // ---------------- 安装与修复 ----------------

    /** 打开项目主页；没有可用浏览器时退化为复制地址，至少让用户能手动访问。 */
    private fun openProjectRepo() {
        try {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(PROJECT_URL)))
            appendLog("已打开项目主页：$PROJECT_URL")
        } catch (e: Exception) {
            copyToClipboard(PROJECT_URL, "项目地址")
            toast("无法打开浏览器，已复制项目地址")
        }
    }

    private fun showInstallGuide() {
        if (TaskSession.isRunning()) { toast("有任务正在进行，请等待完成"); return }
        val installed = TermuxRunner.isTermuxInstalled(this)
        val message = if (!installed) {
            "先安装 Termux，再打开它等待基础环境初始化完成。\n\nF-Droid 与 GitHub 都是官方来源；不清楚 CPU 型号时可选择 GitHub 的 universal APK。已有 Termux 不要随意卸载：卸载会删除它内部的数据。Termux 插件必须与主程序来自同一来源。"
        } else {
            "1. 点击“授权并复制命令”，在系统窗口允许运行 Termux 命令。\n2. 在 Termux 长按 → Paste → 回车，执行复制的命令。\n3. 回到本 App 点击“检查安装条件”。\n4. 检查通过后点击“按顺序安装：Debian → MaiBot”；安装期间可以切到后台或锁屏，通知栏会显示进度。\n5. 首次运行需你在 Termux 确认相关协议，再配置模型密钥和 QQ 登录。"
        }
        val dialog = AlertDialog.Builder(this).setTitle("首次安装向导").setMessage(message)
            .setNegativeButton("稍后", null)
        if (installed) {
            dialog.setPositiveButton("授权并复制命令") { _, _ -> fixTermuxCommunication() }
                .setNeutralButton("检查条件") { _, _ -> checkInstallConditions() }
        } else {
            dialog.setPositiveButton("F-Droid 下载") { _, _ -> openDownload("https://f-droid.org/en/packages/com.termux/") }
                .setNeutralButton("GitHub 下载") { _, _ -> openDownload("https://github.com/termux/termux-app/releases") }
        }
        dialog.show()
    }

    private fun openDownload(url: String) {
        try { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
        catch (_: Exception) { toast("无法打开浏览器，请手动访问：$url") }
    }

    private fun checkInstallConditions(installAfter: Boolean = false) {
        if (TaskSession.isRunning()) { toast("有任务正在进行，请等待完成"); return }
        if (!ensureTermux()) return
        if (!TermuxRunner.hasRunCommandPermission(this)) {
            pendingDiagnostic = true
            pendingAutoInstall = installAfter
            ensureRunCommandPermission(null)
            return
        }
        checking = true
        TaskSession.begin(this, "检查安装条件")
        TaskSession.append("只检查环境，不下载软件、不修改 Termux 配置。")
        TermuxRunner.diagnose(this) { ready, report ->
            checking = false
            diagnosticPassed = ready
            TaskSession.append(report)
            TaskSession.end()
            refreshStatus()
            if (ready && installAfter) {
                runAction(
                    "setup",
                    "顺序安装 · 1/2：初始化 Debian",
                    "install",
                    "顺序安装 · 2/2：部署 MaiBot"
                )
            }
        }
    }

    private fun ensureTermux(): Boolean {
        if (!TermuxRunner.isTermuxInstalled(this)) {
            toast("请先安装 Termux")
            TermuxRunner.openTermux(this)
            return false
        }
        return true
    }

    /**
     * Termux 的 com.termux.permission.RUN_COMMAND 是 dangerous 级权限，
     * 安装 APK 时不会自动授予，必须运行时弹窗申请一次。
     *
     * @return true 表示已授权、可以继续；false 表示已弹窗或已给出提示
     */
    private fun ensureRunCommandPermission(retry: PendingRun?): Boolean {
        if (TermuxRunner.hasRunCommandPermission(this)) return true
        if (retry != null) pendingAction = retry
        toast("请在弹出的窗口点【允许】，授予「运行 Termux 命令」权限")
        ActivityCompat.requestPermissions(
            this, arrayOf(TermuxRunner.PERMISSION_RUN_COMMAND), REQ_RUN_COMMAND
        )
        return false
    }

    /** 一键修复：授权 + 把 Termux 侧需要手动执行的命令复制到剪贴板 + 打开 Termux */
    private fun fixTermuxCommunication() {
        if (TaskSession.isRunning()) { toast("有任务正在进行，请等待完成"); return }
        if (!ensureTermux()) return
        diagnosticPassed = false

        copyToClipboard(TermuxRunner.REPAIR_COMMAND, "Termux 修复命令")
        TaskSession.begin(this, "修复 Termux 通信")
        TaskSession.append("已把下面这行命令复制到剪贴板（在 Termux 里长按 → Paste 即可）：")
        TaskSession.append("")
        TaskSession.append(TermuxRunner.REPAIR_COMMAND)
        TaskSession.append("")
        TaskSession.append("请按这 4 步做一次（只需一次）：")
        TaskSession.append("① 若弹出授权窗口，点【允许】——这是 Termux 的“允许外部 App 运行命令”权限；")
        TaskSession.append("② 打开 Termux，在终端里粘贴上面那行并回车（开启 allow-external-apps）；")
        TaskSession.append("③ 彻底退出 Termux（从后台任务列表里划掉）再重新打开，让它读到新配置；")
        TaskSession.append("④ 回到本 App，点【初始化环境】。")
        TaskSession.end()

        if (!TermuxRunner.hasRunCommandPermission(this)) {
            openTermuxAfterGrant = true
            ActivityCompat.requestPermissions(
                this, arrayOf(TermuxRunner.PERMISSION_RUN_COMMAND), REQ_RUN_COMMAND
            )
        } else {
            TermuxRunner.openTermux(this)
            toast("命令已复制，请在 Termux 里粘贴执行")
        }
        refreshStatus()
    }

    private fun copyToClipboard(text: String, label: String) {
        try {
            val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            cm.setPrimaryClip(ClipData.newPlainText(label, text))
        } catch (e: Exception) {
            appendLog("复制到剪贴板失败：${e.message}")
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQ_RUN_COMMAND) return

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            toast("已授权，可以调用 Termux 了")
            if (openTermuxAfterGrant) {
                openTermuxAfterGrant = false
                TermuxRunner.openTermux(this)
                toast("命令已复制，请在 Termux 里粘贴执行")
            }
            val pending = pendingAction
            pendingAction = null
            if (pendingDiagnostic) {
                val continueInstall = pendingAutoInstall
                pendingDiagnostic = false
                pendingAutoInstall = false
                ui.postDelayed({ checkInstallConditions(continueInstall) }, 500)
            } else if (pending != null) {
                ui.postDelayed({
                    runAction(pending.action, pending.msg, pending.nextAction, pending.nextMsg)
                }, 500)
            }
        } else {
            pendingAction = null
            pendingDiagnostic = false
            pendingAutoInstall = false
            openTermuxAfterGrant = false
            toast("未授权：无法调用 Termux")
            AlertDialog.Builder(this).setTitle("需要运行 Termux 命令权限")
                .setMessage("授权被拒绝，安装不会继续。若系统不再弹窗，请打开本 App 的应用设置，进入权限页面允许“运行 Termux 命令”。")
                .setPositiveButton("打开应用设置") { _, _ ->
                    startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                }.setNegativeButton("稍后", null).show()
        }
        refreshStatus()
    }

    private fun runAction(
        action: String,
        msg: String,
        nextAction: String? = null,
        nextMsg: String? = null
    ) {
        if (!ensureTermux()) return
        if (!ensureRunCommandPermission(PendingRun(action, msg, nextAction, nextMsg))) return
        if (TaskSession.isRunning()) {
            toast("已有任务正在进行，请等它跑完（进度见运行日志）")
            return
        }

        TaskSession.start(this, action, msg, nextAction, nextMsg)
        if (action in LONG_ACTIONS && !isIgnoringBatteryOptimizations()) {
            TaskSession.append("[注意] 尚未关闭电池优化：锁屏较久后系统可能限制网络。建议点【关闭电池优化】；若仍变慢，请在系统设置里把 Termux 也设为“不优化 / 无限制”。")
            toast("提示：未关闭电池优化，锁屏后下载可能变慢")
        }
    }

    private fun appendLog(line: String) {
        TaskSession.append(line)
    }

    private fun setBusy(busy: Boolean) {
        BUSY_BUTTONS.forEach { id ->
            // 用 View 统一处理：按钮和「复制」文本按钮都会被禁用
            findViewById<View>(id)?.isEnabled = !busy
        }
    }

    // ---------------- 电池优化白名单 ----------------

    private fun isIgnoringBatteryOptimizations(): Boolean = try {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(packageName)
    } catch (_: Exception) {
        true
    }

    private fun requestIgnoreBattery() {
        try {
            if (isIgnoringBatteryOptimizations()) {
                toast("已在后台白名单中，无需重复设置")
                return
            }
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName")
                )
            )
            appendLog("请在弹窗中点击【允许】，这样系统就不会在后台冻结 MaiBot。若切后台后下载仍变慢，请到系统设置里把 Termux 也设为“不优化 / 无限制”。")
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                appendLog("请在列表中找到「MaiBot一键部署」，设为【不优化 / 允许后台运行】。")
            } catch (_: Exception) {
                toast("无法自动打开设置，请到 系统设置 → 电池 中手动允许后台运行")
            }
        }
    }

    private fun askNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted = ContextCompat.checkSelfPermission(
                this, Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                ActivityCompat.requestPermissions(
                    this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001
                )
            }
        }
    }

    private fun refreshStatus() {
        val running = TaskSession.isRunning()
        val installed = TermuxRunner.isTermuxInstalled(this)
        val granted = installed && TermuxRunner.hasRunCommandPermission(this)
        findViewById<TextView>(R.id.tv_install_guide).text = when {
            running && checking -> "当前步骤：检查 Termux 通信、基础工具和存储信息。"
            running -> "当前步骤：任务执行中。可以切到后台或锁屏，进度会继续显示在通知栏和下方运行日志；不要重复点击安装。"
            !installed -> "下一步：点击“开始首次安装向导”，安装 Termux 并完成首次初始化。"
            !granted -> "下一步：点击“修复 Termux 通信”，授权并在 Termux 中执行复制的命令。"
            !diagnosticPassed -> "下一步：点击“检查安装条件”。已授权不等于已开启外部命令，需通过通信测试。"
            else -> "通信和基础工具检查通过。可按顺序安装 Debian → MaiBot；已有环境会检查后复用。安装中可切后台。"
        }
        tvTermux.text = when {
            !installed -> "Termux：未安装（点下方按钮安装）"
            !granted -> "Termux：已安装，但未授权运行命令（点【修复 Termux 通信】）"
            else -> "Termux：已安装且已授权"
        }
        tvGuard.text = when {
            prefs.keepAlive && KeepAliveService.isRunning -> "守护服务：运行中（屏幕锁定也不冻结）"
            KeepAliveService.isRunning -> "守护服务：仅任务期间临时运行（结束后自动关闭）"
            else -> "守护服务：未开启"
        }
        PortChecker.check(8001) { tvMaibot.text = if (it) "MaiBot：运行中（8001）" else "MaiBot：未运行" }
        PortChecker.check(6099) { tvNapcat.text = if (it) "NapCat：运行中（6099）" else "NapCat：未运行" }
    }

    private fun toast(s: String) { Toast.makeText(this, s, Toast.LENGTH_SHORT).show() }
}
