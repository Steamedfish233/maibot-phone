$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'MaibotApp/app/src/main/assets/maibot-onekey.sh'

if (!(Test-Path -LiteralPath $source)) { throw "missing file: $source" }
$text = [System.IO.File]::ReadAllText($source)

# --- static checks ---
# Architecture (v2.0.7): proot-distro login carries --kill-on-exit, so a service
# started in a container-side screen session dies the moment the login returns.
# Services must instead run in the foreground of a login hosted by a Termux-side
# screen session. These checks are what keeps that from silently regressing.
if ($text -notmatch 'termux_service_start\(\)') { throw 'the Termux layer must own service startup' }
if ($text -notmatch 'termux_service_stop\(\)') { throw 'the Termux layer must own service shutdown' }
if ($text -notmatch 'termux_watchdog\(\)') { throw 'the watchdog must run in the Termux layer' }
if ($text -notmatch 'termux_service_up\(\)') { throw 'the Termux layer must probe service ports' }
if ($text -notmatch '\-\-kill-on-exit') { throw 'the kill-on-exit root cause must stay documented' }
if ($text -match 'screen -dmS "\$SCREEN_NAME"') {
    throw 'MaiBot must not be started in a container-side screen session (killed by --kill-on-exit)'
}
if ($text -match 'screen -dmS "\$NAPCAT_SCREEN"') {
    throw 'NapCat must not be started in a container-side screen session (killed by --kill-on-exit)'
}
if ($text -notmatch '"\$py" -u bot\.py 2>&1 \| tee') {
    throw 'start must run the bot in the foreground with the virtualenv interpreter'
}
if ($text -notmatch 'local py="\$BOT_DIR/\.venv/bin/python"') {
    throw 'start must resolve the virtualenv interpreter'
}
if ($text -notmatch 'prepare-bot\)\s+prepare_bot') { throw 'prepare-bot action must be routed' }
if ($text -notmatch 'NAPCAT_DISABLE_MULTI_PROCESS=1') { throw 'NapCat must retry in single-process mode' }
if ($text -notmatch 'repair_dpkg_state\(\)') { throw 'a broken dpkg/apt state must be repaired' }
if ($text -notmatch 'apt-get \$APT_OPTS install -y /tmp/linuxqq\.deb') {
    throw 'the QQ deb must be installed through apt so its dependencies are resolved'
}
if ($text -notmatch '(?s)sync_deps\(\)\s*\{.*?uv sync --frozen.*?uv sync\b') {
    throw 'sync_deps must try the locked sync first and fall back'
}
if ($text -notmatch 'fix-deps\)\s+fix_deps') { throw 'fix-deps action must be routed' }
if ($text -notmatch 'qq_process_running\(\)') { throw 'NapCat must detect the real QQ process' }
if ($text -notmatch 'pypi\.tuna\.tsinghua\.edu\.cn') { throw 'dependency sync needs a mirror fallback chain' }
if ($text -notmatch "'Dead'") { throw 'doctor must spot dead screen sessions' }
if ($text -notmatch 'screen_session_state\(\)') { throw 'a Dead screen session must be distinguished from a live one' }
if ($text -notmatch 'screen -wipe') { throw 'dead sessions must be reclaimed with screen -wipe' }
if ($text -notmatch 'ensure_xvfb\(\)') { throw 'Xvfb must be managed explicitly' }
if ($text -notmatch '\$\{PIPESTATUS\[0\]\}') { throw 'the QQ launch must log the real exit code via PIPESTATUS' }
if ($text -notmatch 'uv\.lock" -nt') { throw 'doctor must compare uv.lock against .venv' }
Write-Host 'PASS: services run in the foreground of Termux-hosted screen sessions'
Write-Host 'PASS: no container-side screen launch survives for MaiBot or NapCat'
Write-Host 'PASS: fix-deps / prepare-bot routed; QQ process detection present'
Write-Host 'PASS: dead sessions are reclaimed instead of blocking start'

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
XVFB_SCREEN=napcat-xvfb
NAPCAT_WS_PORT=3001
QQ_BIN=/opt/QQ/qq
QQ_APP_DIR=/opt/QQ/resources/app
QQ_LAUNCHER_DIR=$QQ_APP_DIR/app_launcher
QQ_NAPCAT_DIR=$QQ_LAUNCHER_DIR/napcat
'@

# Extract the real functions in dependency order: tests run the shipped code,
# not a copy of the logic.
foreach ($fn in @('screen_session_state','screen_session_running','screen_wipe_dead','screen_drop',
                  'maibot_port_open','maibot_process_running','is_running','napcat_port_open',
                  'qq_process_running','xvfb_running','napcat_running','maibot_webui_state',
                  'napcat_webui_port','napcat_log_url','mirror_alive',
                  'webui_http_code','webui_http_ok','webui_log_tail','webui','webui_check','napcat_webui',
                  'adapter_plugin_dir','adapter_status')) {
    # Match exactly one function body (up to the closing brace in column 0).
    # Matching "up to the next function" would also drag top-level assignments
    # that happen to sit between two functions into the harness.
    $m = [regex]::Match($text, '(?ms)^' + [regex]::Escape($fn) + '\(\) \{.*?^\}')
    if (-not $m.Success) { throw "function not found: $fn" }
    $harness += "`n" + $m.Value + "`n"
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

# 3b) A Dead session (process long gone, empty shell left) must NOT count as running:
#     the old code returned "already running" and the start button did nothing.
screen(){ printf 'There are screens on:\n\t333.maibot\t(Dead ???)\n\t334.napcat\t(Dead ???)\n'; }
[ "$(screen_session_state maibot)" = dead ] || { echo "FAIL: dead session not classified"; exit 1; }
[ "$(screen_session_state napcat)" = dead ] || { echo "FAIL: dead napcat session not classified"; exit 1; }
[ "$(screen_session_state maibot-watchdog)" = none ] || { echo "FAIL: missing session not classified"; exit 1; }
screen_session_running maibot && { echo "FAIL: dead session counted as running"; exit 1; }
maibot_process_running(){ return 1; }
maibot_port_open(){ return 1; }
is_running && { echo "FAIL: is_running true with only a dead session"; exit 1; }
echo "PASS: dead session no longer counts as running"

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

# 11) mirror probing: a 403/404 mirror must be skipped, a 200 mirror accepted.
#     (Kept last: it redefines have/curl.)
have(){ return 0; }
curl(){
  case "$*" in
    *ok-mirror*) printf '200' ;;
    *dead-mirror*) printf '403' ;;
    *) printf '404' ;;
  esac
}
mirror_alive 'https://ok-mirror/dists/bookworm/Release' || { echo "FAIL: 200 mirror rejected"; exit 1; }
mirror_alive 'https://dead-mirror/dists/bookworm/Release' && { echo "FAIL: 403 mirror accepted"; exit 1; }
mirror_alive 'https://missing-mirror/dists/bookworm/Release' && { echo "FAIL: 404 mirror accepted"; exit 1; }
echo "PASS: mirror probe skips unreachable mirrors and keeps working ones"
'@

$temp = Join-Path $env:TEMP ('maibot-webui-status-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $harness.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'WebUI status regressions failed' }
    Write-Host 'ALL CHECKS PASSED'
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
