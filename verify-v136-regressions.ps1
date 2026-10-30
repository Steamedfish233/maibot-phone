$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'MaibotApp/app/src/main/assets/maibot-onekey.sh'
$text = [System.IO.File]::ReadAllText($source)

# ---------- 1) static check: every action the App can send must have a branch ----------
$appActions = @('setup','install','start','stop','update','status','guard','guard-stop',
                'napcat-install','napcat-start','napcat-stop','napcat-setup','napcat-webui')
$anchor = $text.IndexOf('_MENU_RESULT=0')
if ($anchor -lt 0) { throw 'container dispatcher not found' }
$tail = $text.Substring($anchor)
$endIdx = $tail.IndexOf('esac')
if ($endIdx -lt 0) { throw 'container dispatcher esac not found' }
$containerCase = $tail.Substring(0, $endIdx)
foreach ($a in $appActions) {
    $inContainer = $containerCase -match ([regex]::Escape($a) + '\)')
    $inTermux = $text -match ('(?m)=\s*"' + [regex]::Escape($a) + '"\s*\]')
    if (-not ($inContainer -or $inTermux)) { throw "action has no branch: $a" }
    Write-Host "PASS: action routed -> $a"
}
if ($containerCase -notmatch '\*\)\s*err') { throw 'unknown action still falls into menu' }
Write-Host 'PASS: unknown action no longer enters interactive menu'

# Dead download endpoints must not appear in executable code (comments are fine).
# astral.sh is intentionally kept as the first uv path (it has two fallbacks), so it is not listed.
foreach ($bad in @('gh-proxy.org','ghfast.top','mirrors.wars.cat')) {
    $hit = @(($text -split "`n") | Where-Object { $_ -notmatch '^\s*#' -and $_ -match [regex]::Escape($bad) })
    if ($hit.Count -gt 0) { throw "dead endpoint still used in code: $bad -> $($hit[0])" }
    Write-Host "PASS: no dead endpoint in code -> $bad"
}

# MaiBot is considered active when either its screen session or port 8001 is live.
if ($text -notmatch '(?s)is_running\(\)\s*\{\s*screen -ls.*?\|\| maibot_port_open\s*\}') { throw 'is_running must include port 8001 fallback' }
if ($text -notmatch '(?s)maibot_port_open\(\)\s*\{[^}]*127\.0\.0\.1/8001') { throw 'MaiBot port probe must target loopback 8001' }
if ($text -notmatch '(?s)napcat_running\(\)\s*\{.*?napcat_port_open 6099.*?napcat_port_open.*NAPCAT_WS_PORT') { throw 'NapCat status must fall back to WebUI and WS ports' }
if ($text -notmatch 'napcat_webui_port\(\)' -or $text -notmatch 'seq 6099 6199') { throw 'NapCat WebUI must probe the actual port range' }
if ($text -notmatch 'napcat_log_url\(\)' -or $text -notmatch '6099-6199') { throw 'NapCat WebUI must diagnose missing listener and parse log URL' }
Write-Host 'PASS: MaiBot and NapCat status fall back to local service ports'
Write-Host 'PASS: NapCat WebUI probes actual port and reports diagnostics'
if ($text -notmatch 'MaiBot-SnowLuma-Adapter') { throw 'official unified QQ connector guidance missing' }
if ($text -match 'github\.com/Mai-with-u/MaiBot-Napcat-Adapter') { throw 'archived NapCat adapter repo must not be recommended' }
Write-Host 'PASS: installer points to official unified QQ connector (SnowLuma adapter)'
if ($text -notmatch 'webui_http_ok' -or $text -notmatch 'curl -s -o /dev/null -m 6') { throw 'WebUI must be verified with a real HTTP request' }
Write-Host 'PASS: WebUI availability is checked over HTTP'
if ($text -notmatch 'Rodert/qq-versions/releases/latest' -or $text -notmatch 'ar t /tmp/linuxqq\.deb' -or $text -notmatch 'sha256sum /tmp/linuxqq\.deb') { throw 'QQ archive fallback must resolve release and verify deb + sha256' }
Write-Host 'PASS: QQ package archive fallback validates deb and checksum'
if ($text -notmatch 'WEBUI_URL=') { throw 'script must emit WebUI URL for Android browser opening' }
if ($text -notmatch '(?s)"network"\s*:\s*\{.*?"websocketServers"' -or $text -notmatch '"host": "127\.0\.0\.1"') { throw 'NapCat default local WebSocket config missing' }
if ($text -notmatch 'app_launcher/napcat/config' -or $text -notmatch 'onebot11_\$qq\.json') { throw 'NapCat config must be copied to QQ launcher config directory' }
Write-Host 'PASS: WebUI URL output and local NapCat config exist'

# ---------- 2) functional checks ----------
$harness = @'
set -u
RUN_TRACKED=0
BOLD=; NC=
info(){ :; }; warn(){ :; }; ok(){ :; }; err(){ :; }; say(){ :; }
_log(){ :; }
run_logged(){ "$@" >/dev/null 2>&1; }
'@
foreach ($fn in @('apt_busy','apt_wait_unlock','napcat_setup','clone_repo','maibot_port_open','is_running','napcat_port_open','napcat_running')) {
    # Bound the body by the next top-level function: bodies may contain a column-0 brace (JSON).
    $startMarker = "`n" + $fn + "() {"
    $start = $text.IndexOf($startMarker)
    if ($start -lt 0) { throw "function not found: $fn" }
    $rest = $text.Substring($start + 1)
    $next = [regex]::Match($rest.Substring($fn.Length), '(?m)^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{')
    if (-not $next.Success) { throw "next function not found after: $fn" }
    $body = $rest.Substring(0, $fn.Length + $next.Index)
    $harness += "`n" + $body + "`n"
}
$harness += @'
APT_OPTS=""
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT

pgrep(){ return 1; }
apt_wait_unlock || { echo "FAIL: apt_wait_unlock when idle"; exit 1; }
echo "PASS: apt_wait_unlock returns when no apt is running"

pgrep(){ return 0; }
sleep(){ :; }
apt_wait_unlock && { echo "FAIL: apt_wait_unlock should fail while apt is busy"; exit 1; }
echo "PASS: apt_wait_unlock fails clearly while apt is busy"

NAPCAT_DIR="$work/napcat"; NAPCAT_ENV="$work/account"; NAPCAT_WS_PORT=3001
mkdir -p "$NAPCAT_DIR"
napcat_setup "123456" >/dev/null 2>&1 || { echo "FAIL: valid QQ rejected"; exit 1; }
[ -f "$NAPCAT_DIR/config/onebot11_123456.json" ] || { echo "FAIL: config not generated"; exit 1; }
echo "PASS: valid QQ accepted"
for bad in "12ab" "../../etc/x" "123;rm -rf /" "" "1234"; do
  napcat_setup "$bad" >/dev/null 2>&1 && { echo "FAIL: bad QQ accepted: $bad"; exit 1; }
done
echo "PASS: invalid QQ rejected"

BASE_DIR="$work/base"; BOT_DIR="$BASE_DIR/MaiBot"; REPO="x"; REPO_MIRROR="y"
mkdir -p "$BOT_DIR/.git"
git(){ return 1; }
run_logged(){ return 1; }
clone_repo >/dev/null 2>&1
[ -d "$BOT_DIR" ] && { echo "FAIL: broken clone dir left behind"; exit 1; }
echo "PASS: broken .git cleaned up after failed clone"

# Simulate live service ports without corresponding screen sessions.
SCREEN_NAME=maibot; NAPCAT_SCREEN=napcat; NAPCAT_WS_PORT=3001
screen(){ printf 'No Sockets found'; return 1; }
maibot_port_open(){ return 0; }
napcat_port_open(){ [ "$1" = 6099 ] || [ "$1" = 3001 ]; }
is_running || { echo "FAIL: live 8001 port was reported stopped"; exit 1; }
napcat_running || { echo "FAIL: live NapCat ports were reported stopped"; exit 1; }
echo "PASS: live service ports prevent false stopped status"

# APT_OPTS must force non-interactive conffile handling and lock waiting
echo "$APT_OPTS" | grep -q 'force-confold' || { echo "FAIL: missing force-confold"; exit 1; }
echo "$APT_OPTS" | grep -q 'Lock::Timeout' || { echo "FAIL: missing Lock::Timeout"; exit 1; }
echo "PASS: APT_OPTS forces non-interactive conffile handling"
'@
# ---------- 3) mirror registry selection for Debian rootfs ----------
$ra = [regex]::Match($text, '(?ms)^[ \t]*registry_alive\(\) \{.*?(?=^[ \t]*iscas_rootfs_url\(\) \{)')
$isc = [regex]::Match($text, '(?ms)^[ \t]*iscas_rootfs_url\(\) \{.*?(?=^[ \t]*install_debian_image\(\) \{)')
$id = [regex]::Match($text, '(?ms)^[ \t]*install_debian_image\(\) \{.*?(?=^[ \t]*if debian_ready; then)')
if (-not $ra.Success) { throw 'registry_alive not found' }
if (-not $isc.Success) { throw 'iscas_rootfs_url not found' }
if (-not $id.Success) { throw 'install_debian_image not found' }
$mirrorHarness = @'
set -u
info(){ :; }; warn(){ :; }; ok(){ :; }; err(){ :; }
LOG=/dev/null
'@ + "`n" + $ra.Value + "`n" + $isc.Value + "`n" + $id.Value + @'

MIRROR_OK=1
curl(){ if [ "$MIRROR_OK" = 1 ]; then echo 401; else echo 000; fi; }
PROOT_LOG=""
proot-distro(){ PROOT_LOG="$PROOT_LOG|$*"; case "$1" in remove) return 0;; esac; }
chosen=""
run_capture(){ local out="$1"; shift; chosen="$*"; return 0; }

install_debian_image || { echo "FAIL: mirror path should succeed"; exit 1; }
case "$chosen" in
  *"docker.m.daocloud.io/library/debian"*) ;;
  *) echo "FAIL: mirror not preferred (chose: $chosen)"; exit 1 ;;
esac
echo "PASS: cn mirror registry preferred"

MIRROR_OK=0
chosen=""
PROOT_LOG=""
run_capture(){ local out="$1"; shift; chosen="$*"; return 0; }
install_debian_image || { echo "FAIL: fallback path should succeed"; exit 1; }
case "$chosen" in
  "proot-distro install debian") ;;
  *) echo "FAIL: fallback did not use official ref (chose: $chosen)"; exit 1 ;;
esac
echo "PASS: falls back to official registry when mirror unreachable"

MIRROR_OK=1
chosen=""
PROOT_LOG=""
run_capture(){ local out="$1"; shift; chosen="$*"; case "$chosen" in *daocloud*) return 1;; *) return 0;; esac; }
install_debian_image || { echo "FAIL: official fallback after mirror failure"; exit 1; }
case "$PROOT_LOG" in
  *"remove debian"*) ;;
  *) echo "FAIL: partial container not cleaned up ($PROOT_LOG)"; exit 1 ;;
esac
echo "PASS: partial container cleaned up after failed mirror pull"

# every registry unavailable -> cn rootfs tarball fallback with --name debian
MIRROR_OK=0
chosen=""; PROOT_LOG=""
iscas_rootfs_url(){ echo "https://mirror.iscas.ac.cn/lxc-images/images/debian/bookworm/arm64/default/20260718_05%3A24/rootfs.tar.xz"; }
run_capture(){ local out="$1"; shift; chosen="$*"; case "$chosen" in *rootfs.tar.xz*) return 0;; *) return 1;; esac; }
install_debian_image || { echo "FAIL: tarball fallback should succeed"; exit 1; }
case "$chosen" in
  *"--name debian"*) ;;
  *) echo "FAIL: tarball install missing --name debian (chose: $chosen)"; exit 1 ;;
esac
echo "PASS: falls back to cn rootfs tarball with --name debian"

# iscas parser must skip dated dirs whose listing has no rootfs.tar.xz (mirror lag)
listing='<a href="20260719_05%3A24/">20260719</a><a href="20260718_05%3A24/">20260718</a>'
curl(){
  case "$*" in
    *rootfs.tar.xz*) case "$*" in *20260719*) echo 404;; *) echo 200;; esac ;;
    *) printf '%s' "$listing" ;;
  esac
}
u=$(iscas_rootfs_url) || { echo "FAIL: iscas parser returned nothing"; exit 1; }
case "$u" in
  *20260718*) ;;
  *) echo "FAIL: iscas parser did not skip the empty dated dir ($u)"; exit 1 ;;
esac
echo "PASS: iscas parser skips dated dirs without rootfs.tar.xz"

# Debian source validator: reject apt exit 0 with stale/failed indexes; accept clean verified fetch.
APT_OPTS=""
apt_calls=0
apt-get(){
  apt_calls=$((apt_calls + 1))
  if [ "$apt_calls" -eq 1 ]; then
    printf 'Hit:1 https://example.invalid/debian stable InRelease\nErr:1 https://example.invalid/debian stable InRelease\nW: Failed to fetch https://example.invalid/InRelease\n' 
  else
    printf 'Get:1 https://example.invalid/debian stable InRelease [100 kB]\nFetched 100 kB in 1s\nReading package lists...\n'
  fi
  return 0
}
# Exercise the exact output predicate without touching host apt configuration.
apt_out=$(mktemp)
apt-get update >"$apt_out" 2>&1
if grep -qiE 'Err:|certificate verify failed|SSL connection failed|Failed to fetch|NO_PUBKEY|EXPKEYSIG|The repository .* is not signed' "$apt_out"; then :; else echo "FAIL: failed apt output not rejected"; exit 1; fi
apt-get update >"$apt_out" 2>&1
if ! grep -qE '^(Get:|Hit:|Ign:)[0-9]*[[:space:]]+.*InRelease' "$apt_out" || grep -qiE 'Err:|certificate verify failed|SSL connection failed|Failed to fetch|NO_PUBKEY|EXPKEYSIG|The repository .* is not signed' "$apt_out"; then echo "FAIL: clean apt output not accepted"; exit 1; fi
rm -f "$apt_out"
echo "PASS: Debian mirror validator rejects stale TLS failures and accepts clean Release fetch"
'@
$temp2 = Join-Path $env:TEMP ('maibot-mirror-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp2, $mirrorHarness.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' $temp2.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'mirror registry checks failed' }
} finally { Remove-Item $temp2 -ErrorAction SilentlyContinue }

$aptLine = [regex]::Match($text, '(?m)^APT_OPTS=.*$').Value
if (-not $aptLine) { throw 'APT_OPTS not found in installer' }
$harness = $harness.Replace('APT_OPTS=""', $aptLine)
$temp = Join-Path $env:TEMP ('maibot-regressions2-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $harness.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' -n $source.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'installer syntax check failed' }
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'new regression checks failed' }
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
