$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Fail([string]$message) { throw "FAIL: $message" }
function Pass([string]$message) { Write-Host "PASS: $message" }

function Read-Text([string]$path) {
    if (!(Test-Path -LiteralPath $path)) { Fail "missing file: $path" }
    return [System.IO.File]::ReadAllText($path)
}

$layoutPath = Join-Path $root 'MaibotApp/app/src/main/res/layout/activity_main.xml'
$mainPath = Join-Path $root 'MaibotApp/app/src/main/java/com/maibot/app/MainActivity.kt'
$manifestPath = Join-Path $root 'MaibotApp/app/src/main/AndroidManifest.xml'
$gradlePath = Join-Path $root 'MaibotApp/app/build.gradle.kts'
$scriptPath = Join-Path $root 'MaibotApp/app/src/main/assets/maibot-onekey.sh'
$kotlinDir = Join-Path $root 'MaibotApp/app/src/main/java/com/maibot/app'

# 1. native WebUI replacement must be gone
foreach ($name in @('MaiBotApi', 'MaiBotMobileActivity', 'MaiBotWebUiActivity', 'PluginManagerActivity')) {
    if (Test-Path -LiteralPath (Join-Path $kotlinDir "$name.kt")) { Fail "obsolete class still present: $name.kt" }
}
$manifest = Read-Text $manifestPath
foreach ($name in @('MaiBotMobileActivity', 'MaiBotWebUiActivity', 'PluginManagerActivity')) {
    if ($manifest.Contains($name)) { Fail "manifest still declares $name" }
}
if ($manifest.Contains('usesCleartextTraffic')) {
    Fail 'cleartext WebView flag must be removed together with the embedded WebUI'
}
Pass 'native WebUI replacement removed'

# 2. single-page layout, log inside the page
[xml]$doc = [System.IO.File]::ReadAllText($layoutPath)
$ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
$ns.AddNamespace('android', 'http://schemas.android.com/apk/res/android')
$rootElement = $doc.DocumentElement
if ($rootElement.LocalName -ne 'LinearLayout') { Fail 'root layout must be a LinearLayout' }
if ($rootElement.GetAttribute('orientation', 'http://schemas.android.com/apk/res/android') -ne 'vertical') {
    Fail 'root layout orientation must be vertical'
}
$page = $doc.SelectSingleNode("//*[@android:id='@+id/page_scroll']", $ns)
$svLog = $doc.SelectSingleNode("//*[@android:id='@+id/sv_log']", $ns)
$logPanel = $doc.SelectSingleNode("//*[@android:id='@+id/log_panel']", $ns)
if ($page -eq $null) { Fail 'missing page_scroll' }
if ($svLog -eq $null) { Fail 'missing sv_log' }
if ($logPanel -eq $null) { Fail 'missing log_panel' }
# 日志面板必须在页面 ScrollView 之外：嵌进去会形成嵌套纵向滚动，
# 日志既不能单独滑动，也无法可靠地自动滚到最新一行。
if ($logPanel.ParentNode -ne $rootElement) { Fail 'log_panel must be a direct child of the root layout' }
$cursor = $svLog.ParentNode
while ($cursor -ne $null) {
    if ($cursor -eq $page) { Fail 'sv_log must not be nested inside page_scroll' }
    $cursor = $cursor.ParentNode
}
if ($page.GetAttribute('layout_height', 'http://schemas.android.com/apk/res/android') -ne '0dp') {
    Fail 'page_scroll needs weight-based height so the log panel keeps its space'
}
Pass 'log panel is separate from the page scroller (no nested scrolling)'

foreach ($id in @('btn_webui', 'btn_napcat_webui', 'btn_webui_check', 'btn_adapter_setup',
                  'btn_adapter_status', 'btn_napcat_setup', 'btn_github', 'btn_doctor',
                  'tv_log', 'tv_log_copy', 'tv_log_clear', 'tv_log_toggle', 'et_qq')) {
    if ($doc.SelectSingleNode("//*[@android:id='@+id/$id']", $ns) -eq $null) { Fail "missing control: $id" }
}
Pass 'WebUI / adapter / project-link / log controls present'

# 联系作者 QQ 已改为项目 GitHub 主页
$xmlText = Read-Text $layoutPath
if ($xmlText -match '1131546788') { Fail 'author QQ is still shown in the layout' }
if ($xmlText -match 'textIsSelectable') { Fail 'textIsSelectable not allowed in the log area' }
if ($xmlText -notmatch 'Steamedfish233/maibot-phone') { Fail 'layout must show the project repository' }
Pass 'author QQ replaced by the project repository link'

# The screen is ordered install-first: a fresh install is the very first task, so the
# first-run wizard (and the project/feedback link) must sit above the daily-use blocks.
# ASCII-only markers on purpose: this file is read as ANSI by Windows PowerShell.
$posGuide = $xmlText.IndexOf('@+id/btn_install_guide')
$posGithub = $xmlText.IndexOf('@+id/btn_github')
$posStatus = $xmlText.IndexOf('@+id/tv_maibot')
$posWebui = $xmlText.IndexOf('@+id/btn_webui')
if ($posGuide -lt 0 -or $posGithub -lt 0 -or $posStatus -lt 0 -or $posWebui -lt 0) {
    Fail 'install guide / project link / status / webui controls are missing'
}
if ($posGuide -gt $posStatus) { Fail 'first-run wizard must come before the status section' }
if ($posGithub -gt $posWebui) { Fail 'project + feedback link must come before the WebUI section' }
if ($xmlText -notmatch 'v2\.0\.7"') { Fail 'install wizard header does not show the current version' }
if ($xmlText -match 'v2\.0\.6"') { Fail 'install wizard header still shows the previous version' }
Pass 'first-run wizard and project feedback are placed first'

# 3. MainActivity behaviour
$main = Read-Text $mainPath
foreach ($needle in @(
    'quickQuery(R.id.btn_webui, "webui"',
    'quickQuery(R.id.btn_napcat_webui, "napcat-webui"',
    'quickQuery(R.id.btn_webui_check, "webui-check"',
    'quickQuery(R.id.btn_adapter_status, "adapter-status"',
    'runAction("adapter-setup $qq"',
    'Intent.ACTION_VIEW',
    'WEBUI_URL=',
    'WEBUI_UNAVAILABLE=1',
    'TaskSession.attach',
    'TaskSession.recoverIfNeeded',
    'PROJECT_URL = "https://github.com/Steamedfish233/maibot-phone"',
    'findViewById<Button>(R.id.btn_github)',
    'quickQuery(R.id.btn_doctor, "doctor"',
    'private fun scrollLogToBottom()')) {
    if (!$main.Contains($needle)) { Fail "MainActivity missing: $needle" }
}
foreach ($forbidden in @('MaiBotMobileActivity', 'MaiBotWebUiActivity', 'PluginManagerActivity')) {
    if ($main.Contains($forbidden)) { Fail "MainActivity still references $forbidden" }
}
if ($main -notmatch 'startsWith\("http://127\.0\.0\.1:"\)') { Fail 'openWebUi must restrict to loopback' }
Pass 'MainActivity opens WebUI in the browser and wires adapter actions'

# 4. script: real HTTP check + adapter configuration
$sh = Read-Text $scriptPath
foreach ($needle in @('webui_http_ok', 'webui_http_code', 'webui-check)', 'adapter-setup)',
                  'toml_set_key', 'MaiBot-SnowLuma-Adapter', 'plugins/MaiBot-SnowLuma-Adapter',
                  'client_type', 'qq_account', 'adapter-status)')) {
    if (!$sh.Contains($needle)) { Fail "installer script missing: $needle" }
}
if ($sh.Contains('github.com/Mai-with-u/MaiBot-Napcat-Adapter')) {
    Fail 'script still points users at the archived NapCat adapter repository'
}
if ($sh -notmatch 'curl -s -o /dev/null -m 6') { Fail 'WebUI check must perform a real HTTP request' }
if ($sh -notmatch 'seq 6099 6199') { Fail 'NapCat WebUI port probing missing' }
Pass 'installer script verifies WebUI over HTTP and configures the official adapter'

# 5. version
$gradle = Read-Text $gradlePath
if (!$gradle.Contains('versionName = "2.0.7"')) { Fail 'versionName is not 2.0.7' }
if (!$gradle.Contains('versionCode = 35')) { Fail 'versionCode is not 35' }
Pass 'version 2.0.7 (35)'

# 6. APK metadata when built
$apk = Join-Path $root 'MaibotApp/app/build/outputs/apk/release/app-release.apk'
if (Test-Path -LiteralPath $apk) {
    $aapt2 = Join-Path $root 'android-sdk/build-tools/34.0.0/aapt2.exe'
    if (Test-Path -LiteralPath $aapt2) {
        $badging = & $aapt2 dump badging $apk 2>$null | Select-Object -First 1
        if ($badging -notmatch "versionName='2.0.7'") { Fail "APK versionName mismatch: $badging" }
        if ($badging -notmatch "versionCode='35'") { Fail "APK versionCode mismatch: $badging" }
        Pass 'APK version metadata'
    }
}

Write-Host 'ALL CHECKS PASSED'
