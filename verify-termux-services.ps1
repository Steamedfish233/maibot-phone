$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'MaibotApp/app/src/main/assets/maibot-onekey.sh'

if (!(Test-Path -LiteralPath $source)) { throw "missing file: $source" }
$text = [System.IO.File]::ReadAllText($source)

# --- static checks: the Termux layer is what keeps services alive ---
# proot-distro login runs proot with --kill-on-exit: everything started inside that
# login dies when it returns. The services therefore have to be hosted by a
# Termux-side screen session that keeps the login in the foreground.
# ASCII-only: Windows PowerShell reads this file as ANSI when there is no BOM.
foreach ($needle in @(
    'termux_screen_state()',
    'termux_port_open()',
    'termux_service_up()',
    'termux_service_start()',
    'termux_service_stop()',
    'termux_service_label()',
    'termux_write_runner()',
    'termux_start_bot()',
    'termux_start_napcat()',
    'termux_guard_start()',
    'termux_guard_stop()',
    'termux_watchdog()',
    'termux_state_report()',
    '.maibot-serve-')) {
    if (!$text.Contains($needle)) { throw "Termux layer missing: $needle" }
}
if ($text -notmatch 'MAIBOT_NESTED=1 MAIBOT_QUERY=0 \$extra') {
    throw 'the service runner must run the action in the foreground of one login'
}
if ($text -notmatch 'start\)\s+termux_start_bot') { throw 'start must be routed to the Termux layer' }
if ($text -notmatch 'stop\)\s+termux_service_stop bot') { throw 'stop must be routed to the Termux layer' }
if ($text -notmatch 'napcat-start\)\s+termux_start_napcat') { throw 'napcat-start must be routed to the Termux layer' }
if ($text -notmatch 'guard\)\s+termux_guard_start') { throw 'guard must be routed to the Termux layer' }
if ($text -notmatch 'wd\|watchdog\)\s+termux_watchdog') { throw 'watchdog must be routed to the Termux layer' }
Write-Host 'PASS: Termux layer owns service start/stop/watchdog and the guard routes to it'

# --- dynamic checks: run the shipped Termux-layer functions with stubs ---
$harness = @'
set -u
BOLD=; NC=
say(){ printf '%s\n' "$*"; }
info(){ printf 'INFO:%s\n' "$*"; }
ok(){ printf 'OK:%s\n' "$*"; }
warn(){ printf 'WARN:%s\n' "$*"; }
err(){ printf 'ERR:%s\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
sleep(){ :; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
HOME="$work/home"; mkdir -p "$HOME"
'@

# Termux-layer functions live at two-space indentation inside the PREFIX block.
foreach ($fn in @('termux_screen_state','termux_port_open','termux_log_tail','termux_service_up',
                  'termux_service_label','termux_write_runner','termux_service_start',
                  'termux_service_stop')) {
    $m = [regex]::Match($text, '(?ms)^  ' + [regex]::Escape($fn) + '\(\) \{.*?^  \}$')
    if (-not $m.Success) { throw "function not found: $fn" }
    $harness += "`n" + $m.Value + "`n"
}

$harness += @'

TERMUX_BOT_SCREEN="maibot"; TERMUX_NAPCAT_SCREEN="napcat"; TERMUX_WD_SCREEN="maibot-watchdog"
SCREEN_LOG="$work/screen-calls"; : > "$SCREEN_LOG"
UP_STATE="$work/up"; : > "$UP_STATE"
# screen stub: records calls, reports no session unless SESSIONS says otherwise
screen(){
  echo "$*" >> "$SCREEN_LOG"
  case "$1" in
    -ls) [ -s "$work/sessions" ] && cat "$work/sessions" ;;
    *) : ;;
  esac
  return 0
}
# proot-distro stub: record the nested login command instead of running it
proot-distro(){ echo "PROOT:$*" >> "$SCREEN_LOG"; return 0; }
# service state is driven by a marker file so the wait loop can be exercised
termux_service_up(){ [ -s "$UP_STATE" ]; }

# 1) the generated runner must run one foreground login for the requested action
termux_write_runner maibot start ""
runner="$HOME/.maibot-serve-maibot.sh"
[ -f "$runner" ] || { echo "FAIL: runner not generated"; exit 1; }
bash -n "$runner" || { echo "FAIL: generated runner is not valid bash"; exit 1; }
grep -q 'proot-distro login debian' "$runner" || { echo "FAIL: runner does not enter the container"; exit 1; }
grep -q 'bash /termux-home/maibot-onekey.sh start' "$runner" || { echo "FAIL: runner does not run the action"; exit 1; }
grep -q 'MAIBOT_NESTED=1 MAIBOT_QUERY=0' "$runner" || { echo "FAIL: runner lost the nested/query env"; exit 1; }
echo "PASS: runner runs one foreground login for the requested action"

# 2) starting a service must end up in a Termux-side screen session and wait for the port
: > "$UP_STATE"
SCREEN_LOG="$work/screen-calls"; : > "$SCREEN_LOG"
termux_service_start bot >"$work/out1" 2>&1
rc=$?
[ "$rc" -ne 0 ] || { echo "FAIL: start reported success although the port never opened"; exit 1; }
grep -q -- '-dmS maibot' "$SCREEN_LOG" || { echo "FAIL: no Termux-side screen session was created"; exit 1; }
grep -q 'FAIL' "$work/out1" && { echo "FAIL: unexpected FAIL marker"; exit 1; }
echo "PASS: service startup is hosted by a Termux-side screen session"

# 3) an already running service must not be restarted
echo up > "$UP_STATE"
: > "$SCREEN_LOG"
termux_service_start bot >"$work/out2" 2>&1 || { echo "FAIL: running service reported failure"; exit 1; }
grep -q -- '-dmS' "$SCREEN_LOG" && { echo "FAIL: running service was started twice"; exit 1; }
grep -q '^OK:' "$work/out2" || { echo "FAIL: running service was not reported as running"; exit 1; }
echo "PASS: an already running service is left alone"

# 4) a port that opens while waiting must be reported as success
: > "$UP_STATE"
SCREEN_LOG="$work/screen-calls"; : > "$SCREEN_LOG"
termux_service_up(){ echo up > "$UP_STATE"; [ -f "$work/first" ] && return 0; : > "$work/first"; return 1; }
termux_service_start bot >"$work/out3" 2>&1 || { echo "FAIL: service that came up was reported as failed"; exit 1; }
grep -q '^OK:' "$work/out3" || { echo "FAIL: success message missing"; exit 1; }
echo "PASS: a service that opens its port is reported as started"

# 5) stopping must end the Termux-side session and clean up inside the container
: > "$SCREEN_LOG"; : > "$UP_STATE"
termux_service_stop bot >/dev/null 2>&1
grep -q -- '-S maibot -X quit' "$SCREEN_LOG" || { echo "FAIL: stop did not quit the service session"; exit 1; }
grep -q 'PROOT:login debian' "$SCREEN_LOG" || { echo "FAIL: stop did not run the container cleanup"; exit 1; }
grep -q 'maibot-onekey.sh stop' "$SCREEN_LOG" || { echo "FAIL: stop did not ask the container to stop MaiBot"; exit 1; }
echo "PASS: stopping quits the Termux session and cleans the container"
'@

$temp = Join-Path $env:TEMP ('maibot-termux-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $harness.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\', '/')
    if ($LASTEXITCODE -ne 0) { throw 'Termux service regressions failed' }
    Write-Host 'ALL CHECKS PASSED'
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
