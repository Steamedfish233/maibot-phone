$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'MaibotApp/app/src/main/assets/maibot-onekey.sh'

if (!(Test-Path -LiteralPath $source)) { throw "missing file: $source" }
$text = [System.IO.File]::ReadAllText($source)

# --- static checks: the start path must not rebuild dependencies on every launch ---
if ($text -notmatch 'uv run --no-sync python bot\.py') {
    throw 'start must launch with --no-sync so a stuck build cannot block the WebUI'
}
if ($text -notmatch '(?s)sync_deps\(\)\s*\{.*?uv sync --frozen.*?uv sync\b') {
    throw 'sync_deps must try the locked sync first and fall back'
}
if ($text -notmatch 'fix-deps\)\s+fix_deps') { throw 'fix-deps action must be routed' }
if ($text -notmatch 'qq_process_running\(\)') { throw 'NapCat must detect the real QQ process' }
if ($text -notmatch 'pypi\.tuna\.tsinghua\.edu\.cn') { throw 'dependency sync needs a mirror fallback chain' }
if ($text -notmatch "'Dead'") { throw 'doctor must spot dead screen sessions' }
if ($text -notmatch 'uv\.lock" -nt') { throw 'doctor must compare uv.lock against .venv' }
Write-Host 'PASS: start syncs deps first and launches with --no-sync'
Write-Host 'PASS: fix-deps action routed; QQ process detection present'
Write-Host 'PASS: doctor reports dead sessions and unsynced dependencies'

# ASCII-only on purpose: Windows PowerShell reads .ps1 as ANSI when there is no BOM,
# so non-ASCII text in this file would break parsing.
$harness = @'
set -u
say(){ :; }
info(){ echo "INFO:$*"; }
ok(){ echo "OK:$*"; }
warn(){ echo "WARN:$*"; }
err(){ echo "ERR:$*"; }
RED=; GREEN=; YELLOW=; BLUE=; BOLD=; NC=
SCREEN_NAME=maibot
NAPCAT_SCREEN=napcat
NAPCAT_WS_PORT=3001
'@

# Extract the real functions in dependency order: tests run the shipped code,
# not a copy of the logic.
foreach ($fn in @('screen_session_running','maibot_port_open','is_running','napcat_port_open',
                  'napcat_running','maibot_webui_state','napcat_webui_port','napcat_log_url',
                  'webui_http_code','webui_http_ok','webui_log_tail','webui','webui_check','napcat_webui',
                  'adapter_plugin_dir','adapter_status')) {
    $startMarker = "`n" + $fn + "() {"
    $start = $text.IndexOf($startMarker)
    if ($start -lt 0) { throw "function not found: $fn" }
    $rest = $text.Substring($start + 1)
    $next = [regex]::Match($rest.Substring($fn.Length), '(?m)^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{')
    if (-not $next.Success) { throw "next function not found after: $fn" }
    $harness += "`n" + $rest.Substring(0, $fn.Length + $next.Index) + "`n"
}

$harness += @'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
NAPCAT_DIR="$work/napcat"
NAPCAT_LOG="$work/napcat.log"
LOG_FILE=/dev/null
mkdir -p "$NAPCAT_DIR/config"
printf '%s\n' '{"host":"127.0.0.1","port":6100,"token":"abc123"}' > "$NAPCAT_DIR/config/webui.json"
: > "$NAPCAT_LOG"

# 1) without curl the /dev/tcp fallback must still return a real status code
have(){ return 1; }
code=$(webui_http_code 'http://127.0.0.1:8001/')
echo "INFO: /dev/tcp fallback code=$code"
code=$(webui_http_code 'http://127.0.0.1:9/')
[ "$code" = "000" ] || { echo "FAIL: closed port should be 000, got $code"; exit 1; }
echo "PASS: closed port reports 000 without curl"

# 2) a watchdog-only session must NOT count as MaiBot running
screen(){ printf 'There are screens on:\n\t111.maibot-watchdog\t(Detached)\n'; }
screen_session_running maibot && { echo "FAIL: watchdog session counted as MaiBot"; exit 1; }
screen_session_running maibot-watchdog || { echo "FAIL: watchdog session not detected"; exit 1; }
echo "PASS: watchdog session no longer counts as MaiBot"

# 3) session names match exactly
screen(){ printf 'There are screens on:\n\t222.maibot\t(Detached)\n'; }
screen_session_running maibot || { echo "FAIL: real session not detected"; exit 1; }
screen_session_running napcat && { echo "FAIL: napcat matched by maibot session"; exit 1; }
echo "PASS: session name matched exactly"

# 4) session but no listener: report unavailable, never a dead link
maibot_port_open(){ return 1; }
out=$(webui 2>&1) || true
echo "$out" | grep -q '^WEBUI_UNAVAILABLE=1$' || { echo "FAIL: closed 8001 not reported"; echo "$out"; exit 1; }
echo "$out" | grep -q '^WEBUI_URL=' && { echo "FAIL: dead link emitted for closed port"; exit 1; }
echo "PASS: session without listener reports unavailable"

# 5) port open but HTTP probe failed: still hand the URL over
maibot_port_open(){ return 0; }
webui_http_code(){ printf '000'; }
out=$(webui 2>&1) || true
echo "$out" | grep -q '^WEBUI_URL=http://127.0.0.1:8001/$' || { echo "FAIL: URL withheld although port is open"; echo "$out"; exit 1; }
echo "PASS: open port still yields a URL when HTTP probe fails"

# 6) NapCat: open port must yield the URL including its token
napcat_webui_port(){ printf '6100'; }
napcat_port_open(){ return 0; }
napcat_log_url(){ return 1; }
out=$(napcat_webui 2>&1) || true
echo "$out" | grep -q '^WEBUI_URL=http://127.0.0.1:6100/webui?token=abc123$' || { echo "FAIL: NapCat URL withheld"; echo "$out"; exit 1; }
echo "PASS: NapCat open port yields a URL with token"

# 7) NapCat with nothing listening: unavailable + no dead link
napcat_webui_port(){ return 1; }
napcat_running(){ return 1; }
out=$(napcat_webui 2>&1) || true
echo "$out" | grep -q '^WEBUI_UNAVAILABLE=1$' || { echo "FAIL: NapCat unavailable not reported"; exit 1; }
echo "$out" | grep -q '^WEBUI_URL=' && { echo "FAIL: NapCat emitted a dead link"; exit 1; }
echo "PASS: NapCat reports unavailable with guidance"

# 8) webui_check is diagnostic: a non-zero exit shows as a task failure in the app
screen(){ return 1; }
webui_check >/dev/null 2>&1 || { echo "FAIL: webui_check returned non-zero"; exit 1; }
echo "PASS: webui_check always exits 0"

# 9) adapter_status must not mistake an inline comment for the QQ account.
#    MaiBot's bot_config.toml ships with a trailing comment after qq_account.
BOT_DIR="$work/MaiBot"
mkdir -p "$BOT_DIR/config"
printf '%s\n' '[bot]' 'platform = "qq"' 'qq_account = "3980556598" # adapter fallback account' > "$BOT_DIR/config/bot_config.toml"
NAPCAT_ENV="$work/account"
printf '%s\n' 'ACCOUNT=3980556598' > "$NAPCAT_ENV"
napcat_port_open(){ return 1; }
out=$(adapter_status 2>&1) || true
echo "$out" | grep -q '3980556598' || { echo "FAIL: qq_account not parsed"; echo "$out"; exit 1; }
echo "$out" | grep -q 'adapter fallback account' && { echo "FAIL: comment leaked into qq_account"; exit 1; }
echo "PASS: adapter_status ignores the inline comment on qq_account"

# 10) an empty qq_account must not be replaced by its trailing comment
printf '%s\n' '[bot]' 'qq_account = "" # adapter fallback account' > "$BOT_DIR/config/bot_config.toml"
# NapCat side uses a different account so a leaked MaiBot value is distinguishable
printf '%s\n' 'ACCOUNT=1111111111' > "$NAPCAT_ENV"
out=$(adapter_status 2>&1) || true
echo "$out" | grep -q 'adapter fallback account' && { echo "FAIL: comment used as qq_account when empty"; exit 1; }
echo "$out" | grep -q '3980556598' && { echo "FAIL: stale account still reported as configured"; exit 1; }
echo "PASS: empty qq_account is not replaced by its comment"
'@

$temp = Join-Path $env:TEMP ('maibot-webui-status-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $harness.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'WebUI status regressions failed' }
    Write-Host 'ALL CHECKS PASSED'
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
