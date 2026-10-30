$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot 'MaibotApp/app/src/main/assets/maibot-onekey.sh'
$text = [System.IO.File]::ReadAllText($source)
$test = @'
set -u
RUN_TRACKED=0
BOLD=; NC=
err(){ :; }; warn(){ :; }; info(){ :; }; ok(){ :; }; say(){ :; }
'@
foreach ($name in @('update','start','logs','sync_napcat_config','napcat_start','allstart')) {
    $match = [regex]::Match($text, '(?ms)^' + $name + '\(\) \{.*?^\}')
    if (!$match.Success) { throw "Function not found: $name" }
    $test += "`n" + $match.Value + "`n"
}
$test += @'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
BOT_DIR="$work/bot"; LOG_FILE="$work/mai.log"; SCREEN_NAME=maibot
NAPCAT_DIR="$work/napcat"; NAPCAT_ENV="$work/account"; NAPCAT_SCREEN=napcat; NAPCAT_LOG="$work/napcat.log"
mkdir -p "$BOT_DIR/.git" "$BOT_DIR/data" "$NAPCAT_DIR"
is_running(){ return 0; }
update && { echo 'FAIL: live update accepted'; exit 1; }
echo 'PASS: running update rejected'
is_running(){ return 1; }
start && { echo 'FAIL: first-start accepted'; exit 1; }
echo 'PASS: missing first-start config rejected'
touch "$BOT_DIR/data/webui.json"
screen(){ return 1; }; sleep(){ :; }
start && { echo 'FAIL: bot launch failure swallowed'; exit 1; }
echo 'PASS: bot launch failure propagates'
printf 'line one\nline two\n' > "$LOG_FILE"
MAIBOT_QUERY=1
result=$(logs)
[ "$result" = "$(cat "$LOG_FILE")" ] || exit 1
echo 'PASS: query logs returns snapshot'
printf 'ACCOUNT=123\n' > "$NAPCAT_ENV"
napcat_running(){ return 1; }
napcat_start && { echo 'FAIL: NapCat launch failure swallowed'; exit 1; }
echo 'PASS: NapCat launch failure propagates'
allstart && { echo 'FAIL: aggregate launch failure swallowed'; exit 1; }
echo 'PASS: allstart propagates failures'
'@
$temp = Join-Path $env:TEMP ('maibot-regressions-' + [guid]::NewGuid().ToString('N') + '.sh')
try {
    [System.IO.File]::WriteAllText($temp, $test.Replace("`r", ''), [System.Text.UTF8Encoding]::new($false))
    & 'D:\FOOL\Git\bin\bash.exe' -n $source.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'Installer syntax failed' }
    & 'D:\FOOL\Git\bin\bash.exe' $temp.Replace('\','/')
    if ($LASTEXITCODE -ne 0) { throw 'Installer regressions failed' }
} finally { Remove-Item $temp -ErrorAction SilentlyContinue }
