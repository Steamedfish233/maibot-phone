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
if ($page -eq $null) { Fail 'missing page_scroll' }
if ($svLog -eq $null) { Fail 'missing sv_log' }
if ($doc.SelectSingleNode("//*[@android:id='@+id/log_panel']", $ns) -ne $null) {
    Fail 'separate log_panel should be removed (1.6.x single-page layout)'
}
$cursor = $svLog.ParentNode
$insidePage = $false
while ($cursor -ne $null) {
    if ($cursor -eq $page) { $insidePage = $true; break }
    $cursor = $cursor.ParentNode
}
if (!$insidePage) { Fail 'sv_log should live inside the single page scroller' }
Pass 'single-page layout with in-page log'

foreach ($id in @('btn_webui', 'btn_napcat_webui', 'btn_webui_check', 'btn_adapter_setup',
                  'btn_adapter_status', 'btn_napcat_setup', 'tv_log', 'tv_log_copy', 'tv_log_clear', 'et_qq')) {
    if ($doc.SelectSingleNode("//*[@android:id='@+id/$id']", $ns) -eq $null) { Fail "missing control: $id" }
}
$xmlText = Read-Text $layoutPath
if ($xmlText -match 'textIsSelectable') { Fail 'textIsSelectable not allowed in the log area' }
Pass 'WebUI / adapter / log controls present'

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
    'TaskSession.recoverIfNeeded')) {
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
if (!$gradle.Contains('versionName = "2.0.0"')) { Fail 'versionName is not 2.0.0' }
if (!$gradle.Contains('versionCode = 28')) { Fail 'versionCode is not 28' }
Pass 'version 2.0.0 (28)'

# 6. APK metadata when built
$apk = Join-Path $root 'MaibotApp/app/build/outputs/apk/release/app-release.apk'
if (Test-Path -LiteralPath $apk) {
    $aapt2 = Join-Path $root 'android-sdk/build-tools/34.0.0/aapt2.exe'
    if (Test-Path -LiteralPath $aapt2) {
        $badging = & $aapt2 dump badging $apk 2>$null | Select-Object -First 1
        if ($badging -notmatch "versionName='2.0.0'") { Fail "APK versionName mismatch: $badging" }
        if ($badging -notmatch "versionCode='28'") { Fail "APK versionCode mismatch: $badging" }
        Pass 'APK version metadata'
    }
}

Write-Host 'ALL CHECKS PASSED'
