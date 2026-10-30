$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$source = Join-Path $root 'MaibotApp/app/src/main/assets/maibot-onekey.sh'

if (!(Test-Path -LiteralPath $source)) { throw "missing file: $source" }
$text = [System.IO.File]::ReadAllText($source)

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
                  'webui_http_code','webui_http_ok','webui_log_tail','webui','webui_check','napcat_webui')) {
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
'@

$temp = Join-Path $env:TEMP ('maibot-webui-status-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $harness.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'WebUI status regressions failed' }
    Write-Host 'ALL CHECKS PASSED'
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
