$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'MaibotApp/app/src/main/assets/maibot-onekey.sh'
$text = [System.IO.File]::ReadAllText($source)
$test = @'
set -u
RUN_TRACKED=0
BOLD=; NC=
err(){ :; }; warn(){ :; }; info(){ :; }; ok(){ :; }; say(){ :; }
'@
foreach ($name in @('update','sync_deps','webui_log_tail','start','prepare_bot','logs','sync_napcat_config',
                    'maibot_port_open','napcat_port_open','screen_session_state','screen_session_running',
                    'screen_wipe_dead','screen_drop','maibot_process_running','stop_maibot',
                    'qq_process_running','xvfb_running','ensure_xvfb','patch_qq_main','napcat_inject',
                    'napcat_own_log_tail','napcat_webui_port','napcat_start')) {
    $match = [regex]::Match($text, '(?ms)^' + $name + '\(\) \{.*?^\}')
    if (!$match.Success) { throw "Function not found: $name" }
    $test += "`n" + $match.Value + "`n"
}
$test += @'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
BOT_DIR="$work/bot"; LOG_FILE="$work/mai.log"; SCREEN_NAME=maibot
NAPCAT_DIR="$work/napcat"; NAPCAT_ENV="$work/account"; NAPCAT_SCREEN=napcat; NAPCAT_LOG="$work/napcat.log"
NAPCAT_WS_PORT=3001; XVFB_SCREEN=napcat-xvfb; XVFB_LOG="$work/xvfb.log"; QQ_LAUNCH_FLAGS="--no-sandbox"
QQ_BIN="$work/qq"; QQ_APP_DIR="$work/qq-app"; QQ_LAUNCHER_DIR="$QQ_APP_DIR/app_launcher"; QQ_NAPCAT_DIR="$QQ_LAUNCHER_DIR/napcat"
PYPI_MIRRORS="https://mirrors.aliyun.com/pypi/simple https://pypi.tuna.tsinghua.edu.cn/simple"
QQ_MIN_BUILD=40768; LINUXQQ_URL="https://example.invalid/linuxqq.deb"
# mirror probing must not block the tests: pretend the first mirror is reachable
mirror_alive(){ return 0; }
mkdir -p "$BOT_DIR/.git" "$BOT_DIR/data" "$NAPCAT_DIR"
# uv / run_logged are only used for dependency sync; make sync "succeed" so the
# tests reach the launch-failure branches below.
uv(){ return 0; }
have(){ return 0; }
PY_INDEX_URL="https://example.invalid/simple"
run_logged(){ :; }
maibot_port_open(){ return 1; }
screen_session_running(){ return 1; }
is_running(){ return 0; }
update && { echo 'FAIL: live update accepted'; exit 1; }
echo 'PASS: running update rejected'
is_running(){ return 1; }
start && { echo 'FAIL: first-start accepted'; exit 1; }
echo 'PASS: missing first-start config rejected'
touch "$BOT_DIR/data/webui.json"
: > "$BOT_DIR/bot.py"
screen(){ return 1; }; sleep(){ :; }
maibot_process_running(){ return 0; }
start && { echo 'FAIL: bot launch failure swallowed'; exit 1; }
echo 'PASS: bot launch failure propagates'
printf 'line one\nline two\n' > "$LOG_FILE"
MAIBOT_QUERY=1
result=$(logs)
[ "$result" = "$(cat "$LOG_FILE")" ] || exit 1
echo 'PASS: query logs returns snapshot'
printf 'ACCOUNT=123\n' > "$NAPCAT_ENV"
: > "$NAPCAT_DIR/napcat.mjs"
napcat_running(){ return 1; }
# Port probing must be stubbed: this host may already have 6099/8001 in use,
# which would hide the launch-failure path.
napcat_port_open(){ return 1; }
napcat_webui_port(){ return 1; }
# A fake QQ tree, so the injector and the start pre-flight run for real.
QQ_APP_DIR="$work/qq/resources/app"
QQ_BIN="$work/qq/qq"
QQ_LAUNCHER_DIR="$QQ_APP_DIR/app_launcher"
QQ_NAPCAT_DIR="$QQ_LAUNCHER_DIR/napcat"
mkdir -p "$QQ_LAUNCHER_DIR"
printf '{"name":"qq","version":"3.2.34-53644","main":"./app_launcher/index.js"}\n' > "$QQ_APP_DIR/package.json"
: > "$QQ_LAUNCHER_DIR/index.js"
napcat_inject >"$work/inject.out" 2>&1 || { echo 'FAIL: napcat_inject failed'; cat "$work/inject.out"; exit 1; }
[ -f "$QQ_APP_DIR/loadNapCat.js" ] || { echo 'FAIL: loadNapCat.js was not written'; exit 1; }
[ -f "$QQ_NAPCAT_DIR/napcat.mjs" ] || { echo 'FAIL: napcat.mjs was not copied into QQ'; exit 1; }
grep -qE '"main"[[:space:]]*:[[:space:]]*"\./loadNapCat\.js"' "$QQ_APP_DIR/package.json" \
  || { echo 'FAIL: QQ package.json main was not patched'; cat "$QQ_APP_DIR/package.json"; exit 1; }
echo 'PASS: NapCat is injected the official way (loadNapCat.js + package.json main)'
napcat_start && { echo 'FAIL: NapCat launch failure swallowed'; exit 1; }
echo 'PASS: NapCat launch failure propagates'
# The generated launcher must be valid bash and must keep the real QQ exit code.
bash -n "$NAPCAT_DIR/start_qq.sh" || { echo 'FAIL: generated start_qq.sh is not valid bash'; exit 1; }
grep -q 'PIPESTATUS' "$NAPCAT_DIR/start_qq.sh" || { echo 'FAIL: start_qq.sh lost the QQ exit code'; exit 1; }
grep -q -- '--no-sandbox' "$NAPCAT_DIR/start_qq.sh" || { echo 'FAIL: start_qq.sh lost --no-sandbox'; exit 1; }
grep -q 'ulimit -c 0' "$NAPCAT_DIR/start_qq.sh" || { echo 'FAIL: start_qq.sh lost the core-dump guard'; exit 1; }
echo 'PASS: generated NapCat launcher is valid and records the exit code'
# A leftover Dead session (process gone, empty shell) must never be reported as
# "already running": that was the bug where the start button did nothing at all.
SCREEN_CALLS="$work/screen-calls"
screen(){
  case "$1" in
    -ls) printf 'There are screens on:\n\t111.maibot\t(Dead ???)\n' ;;
    *) : ;;
  esac
}
: > "$SCREEN_CALLS"
maibot_process_running(){ return 1; }
out=$(start 2>&1) && { echo 'FAIL: dead session made start succeed'; exit 1; }
echo "$out" | grep -q '已在运行' && { echo 'FAIL: dead session treated as already running'; exit 1; }
echo 'PASS: start is not blocked by a dead session'
# prepare_bot only syncs dependencies and must fail loudly when the source is missing.
rm -f "$BOT_DIR/bot.py"
prepare_bot && { echo 'FAIL: prepare_bot accepted a missing bot.py'; exit 1; }
echo 'PASS: prepare_bot refuses to run without the source'
'@
$temp = Join-Path $env:TEMP ('maibot-regressions-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $test.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' -n $source.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'Installer syntax failed' }
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'Installer regressions failed' }
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
