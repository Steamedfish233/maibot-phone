#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
#  MaiBot 手机一键脚本（单文件自包含版）
#  - 在 Termux 内运行一次 setup：装容器 + 生成桌面图标
#  - 之后点桌面图标即可部署/启动/更新 MaiBot 与 NapCat
#
#  用法（在 Termux 内）：
#    bash maibot-onekey.sh setup     首次初始化（只需一次）
#    bash maibot-onekey.sh menu      进入管理菜单
#  桌面图标会自动调用：本脚本 + 对应子命令（如 start）
#
#  ---- 与 App 的进度通信协议（重要，改动时勿破坏） ----
#   App 侧 TermuxRunner 会周期性执行一条极短的命令，读取这些文件：
#     $HOME/.maibot-run.log    带时间戳的运行日志，App 逐行显示为"实时进度"
#     $HOME/.maibot-last-rc    任务退出码，App 据此判断"真的跑完了"
#   App 只读取这两个文件，不会干扰正在执行的部署任务。
# ============================================================

set -u

# ---------- 运行日志（供 App 实时读取，必须早于任何输出） ----------
RUN_ACTION="${1:-menu}"
STATE_HOME="${MAIBOT_STATE_HOME:-$HOME}"
# 容器的 HOME 是 /root；App 的通信文件必须放在绑定的 Termux HOME。
if [ -z "${PREFIX:-}" ] && [ -z "${MAIBOT_STATE_HOME:-}" ] && [ -d /termux-home ]; then
  STATE_HOME=/termux-home
fi
LOG="${MAIBOT_LOG:-$STATE_HOME/.maibot-run.log}"
RUN_TRACKED=1
case "$RUN_ACTION" in
  check|status|webui|webui-check|doctor|adapter-status|logs|token|napcat-check|napcat-status|napcat-webui|wd|watchdog) RUN_TRACKED=0 ;;
esac
[ "${MAIBOT_QUERY:-0}" = 1 ] && RUN_TRACKED=0

# 只由最外层任务初始化/结束通信文件；查询和守护进程不能干扰安装任务。
finish_run() {
  local rc=$?
  trap - EXIT
  {
    printf 'MAIBOT_EXIT=%s\n' "$rc"
    printf 'MAIBOT_DONE=1\n'
    printf 'MAIBOT_ACTION=%s\n' "$RUN_ACTION"
  } >> "$LOG" 2>/dev/null || true
  printf '%s\n' "$rc" > "$STATE_HOME/.maibot-last-rc" 2>/dev/null || true
  rm -f "$STATE_HOME/.maibot-run.pid" 2>/dev/null || true
  sync 2>/dev/null || true
  exit "$rc"
}
if [ "$RUN_TRACKED" -eq 1 ] && [ "${MAIBOT_NESTED:-0}" != 1 ]; then
  : > "$LOG" 2>/dev/null || true
  rm -f "$STATE_HOME/.maibot-last-rc" 2>/dev/null || true
  echo "$$" > "$STATE_HOME/.maibot-run.pid" 2>/dev/null || true
  trap finish_run EXIT
fi

# ---------- 通用工具 ----------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'
BLUE=$'\033[34m'; BOLD=$'\033[1m'; NC=$'\033[0m'

# 所有输出同时写日志文件（App 轮询 tail 显示）；进度条用 \r 原地刷新，不写日志
_ts(){ date '+%H:%M:%S' 2>/dev/null || echo '--:--:--'; }
_log(){ [ "$RUN_TRACKED" -eq 1 ] || return 0; printf '%s %s\n' "$(_ts)" "$*" >> "$LOG" 2>/dev/null || true; }
# 仅安装输出管道启用 pipefail，避免全局启用影响 grep -q 等短路管道。
run_logged() (
  set -o pipefail
  "$@" 2>&1 | while IFS= read -r l || [ -n "$l" ]; do _log "$l"; done
)
# 与 run_logged 相同，但把输出另存一份，便于失败后判断真实原因（而不是只说"检查网络"）
run_capture() {
  local out="$1"; shift
  ( set -o pipefail; "$@" 2>&1 | tee "$out" | while IFS= read -r l || [ -n "$l" ]; do _log "$l"; done )
}
_plain(){ printf '%s\n' "$*"; }
_plain_log(){ _plain "$*"; _log "$*"; }

say(){  _plain_log "$*"; }
info(){ printf '%s[信息]%s %s\n' "$BLUE" "$NC" "$*"; _log "[信息] $*"; }
ok(){   printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; _log "[ OK ] $*"; }
warn(){ printf '%s[注意]%s %s\n' "$YELLOW" "$NC" "$*"; _log "[注意] $*"; }
err(){  printf '%s[错误]%s %s\n' "$RED" "$NC" "$*"; _log "[错误] $*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- apt/dpkg 加固 ----------
# 两个坑必须显式处理，否则后台安装会失败或"看起来卡死"：
#   1) 用户在 Termux 里同时手动执行 apt → 锁被占用 → 直接失败；
#   2) dpkg 对 openssl.cnf 等配置文件弹交互式提问 → 无人应答 → 停在 0%。
# 因此：先等锁释放，并要求 dpkg 在冲突时保留本地版本（不需要人工输入）。
APT_OPTS="-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300"

apt_busy() {
  pgrep -x apt >/dev/null 2>&1 || pgrep -x apt-get >/dev/null 2>&1 || \
    pgrep -x dpkg >/dev/null 2>&1 || pgrep -x dpkg-deb >/dev/null 2>&1
}

apt_wait_unlock() {
  apt_busy || return 0
  warn "检测到已有 apt/dpkg 正在运行（可能是你在 Termux 里手动升级）"
  info "等待它结束，最多 5 分钟；请不要在 Termux 里同时执行 apt ..."
  local waited=0
  while apt_busy && [ "$waited" -lt 300 ]; do
    sleep 5
    waited=$((waited + 5))
    [ $((waited % 30)) -eq 0 ] && info "仍在等待其它 apt/dpkg 结束（已等 ${waited}s）..."
  done
  if apt_busy; then
    err "其它 apt/dpkg 仍在运行。请在 Termux 里等它彻底结束（或按 Ctrl+C 后再执行 dpkg --configure -a），然后重试。"
    return 1
  fi
  ok "其它 apt/dpkg 已结束，继续"
  return 0
}

# 步骤计数：[2/6] 标题
STEP_NO=0; STEP_ALL=6
step(){ STEP_NO=$((STEP_NO + 1)); _plain_log ""; _plain_log "===== [${STEP_NO}/${STEP_ALL}] $* ====="; }

# ---------- 网络自检：连不通就直接给出明确原因，避免"跑很久没效果" ----------
# 逐个探测安装真正会用到的国内镜像（Debian / PyPI / QQ CDN / GitHub 代理），
# 不可达的会打 [注意]，后续步骤会自动跳过它们；一个都连不上才判定网络不通。
net_check() {
  info "检查网络与国内镜像连通性（逐个实测，约 10 秒）..."
  local okcnt=0 total=0 item label url
  for item in \
    "清华 Debian|https://mirrors.tuna.tsinghua.edu.cn/debian/dists/bookworm/Release" \
    "阿里云 Debian|https://mirrors.aliyun.com/debian/dists/bookworm/Release" \
    "中科大 Debian|https://mirrors.ustc.edu.cn/debian/dists/bookworm/Release" \
    "腾讯云 Debian|https://mirrors.cloud.tencent.com/debian/dists/bookworm/Release" \
    "阿里云 PyPI|https://mirrors.aliyun.com/pypi/simple/pip/" \
    "清华 PyPI|https://pypi.tuna.tsinghua.edu.cn/simple/pip/" \
    "腾讯云 PyPI|https://mirrors.cloud.tencent.com/pypi/simple/pip/" \
    "华为云 PyPI|https://mirrors.huaweicloud.com/repository/pypi/simple/pip/" \
    "QQ 安装包 CDN|$LINUXQQ_URL" \
    "GitHub 代理|${GITHUB_PROXY}" ; do
    label="${item%%|*}"
    url="${item#*|}"
    total=$((total + 1))
    if mirror_alive "$url"; then
      okcnt=$((okcnt + 1))
      ok "$label：可达"
    else
      warn "$label：不可达（安装时会自动跳过该来源）"
    fi
  done
  if [ "$okcnt" -eq 0 ]; then
    err "所有镜像都连不上：请检查手机是否联网、是否开了代理/VPN，然后重试"
    return 1
  fi
  ok "网络正常（$okcnt/$total 个镜像可达）"
  return 0
}

# 单独的"镜像连通性测试"入口（Termux 菜单 27 / bash $0 mirrors）
mirrors_check() {
  say ""
  say "${BOLD}===== 镜像连通性测试 =====${NC}"
  net_check
}

# ---------- 带进度条的下载（curl：断点续传 + 国内可达） ----------
# 用法：dl <输出路径> <URL...>   多个 URL 依次作为备用源
#
# 进度显示策略：
#   curl 自带的 --progress-bar 只写 stdout 且用 \r 原地刷新，App 读日志读不到，
#   所以这里改成"按秒采样文件大小 + 打印百分比并写日志"，这样：
#     - Termux 里看着有动态进度条
#     - App 日志区能看到 百分比 / 已下载大小 / 速度
dl() {
  local out="$1"; shift
  local name; name=$(basename "$out")
  for url in "$@"; do
    [ -z "$url" ] && continue
    info "开始下载：$name"
    info "下载来源：$url"

    rm -f "$out" 2>/dev/null

    # 后台启动下载，主流程按秒采样进度
    curl -fL --retry 2 --retry-delay 3 --connect-timeout 20 \
         --speed-time 60 --speed-limit 1024 \
         -C - -o "$out" "$url" >/dev/null 2>&1 &
    local pid=$!
    local waited=0
    local last_report=0

    while kill -0 "$pid" 2>/dev/null; do
      sleep 1
      waited=$((waited + 1))

      # 每 2 秒汇报一次进度
      if [ $((waited % 2)) -eq 0 ]; then
        local sz; sz=$(stat -c %s "$out" 2>/dev/null || echo 0)
        local human; human=$(du -h "$out" 2>/dev/null | cut -f1)
        local span=$((waited - last_report))
        [ "$span" -le 0 ] && span=1
        local speed; speed=$(awk -v s="$sz" -v t="$waited" 'BEGIN{printf "%.0f", (s/1024)/t}' 2>/dev/null || echo 0)

        if [ "$sz" -gt 0 ]; then
          printf '\r  已下载 %s（约 %s KB/s，用时 %ss）' "${human:-0}" "$speed" "$waited"
          _log "下载中：$name 已接收 ${human:-0}（约 ${speed} KB/s，用时 ${waited}s）"
        else
          printf '\r  正在连接 ... (%ss)' "$waited"
          _log "下载中：$name 正在连接 ... (${waited}s)"
        fi
        last_report=$waited
      fi

      # 超过 20 分钟仍未完成，视为卡死
      if [ "$waited" -ge 1200 ]; then
        warn "下载超时（20 分钟），中止：$name"
        kill "$pid" 2>/dev/null || true
        break
      fi
    done

    wait "$pid" 2>/dev/null
    local rc=$?
    printf '\n'  # 结束进度行

    if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
      ok "下载完成：$name（$(du -h "$out" 2>/dev/null | cut -f1)）"
      return 0
    fi

    warn "该来源失败（超时或网络不通），尝试下一个来源 ..."
    rm -f "$out" 2>/dev/null
  done
  err "全部下载来源均失败，请检查网络后重试"
  return 1
}

# ---------- 镜像加速 ----------
# 每个下载环节都准备多个候选源，并在使用前做一次连通性探测（mirror_alive）：
# 国内镜像经常出现「某个站被墙/被限流/路径变更」，固定顺序硬试会让安装卡很久。
# 2026-10 实测（大陆网络，任选其一即可，脚本会自己挑可用的）：
#   清华 mirrors.tuna.tsinghua.edu.cn   —— 部分网络会返回 403（被限流），所以只排第一但不依赖它
#   阿里云 mirrors.aliyun.com           —— Debian / PyPI 均可达，PyPI 最快
#   中科大 mirrors.ustc.edu.cn          —— Debian / Termux / PyPI 均可达
#   腾讯云 mirrors.cloud.tencent.com    —— Debian / PyPI 可达
#   华为云 repo.huaweicloud.com         —— Debian 可达；PyPI 走 /repository/pypi/simple
#   南大 mirror.nju.edu.cn / 上交 mirror.sjtu.edu.cn / 北大 mirrors.pku.edu.cn
# 已失效、不要再用：mirrors.wars.cat（404）、gh-proxy.org / ghfast.top（不可达）、
#   dldir1v6.qq.com 上的 QQ_3.2.18 安装包（404，官方页面仍在引用旧地址）。
TERMUX_MIRRORS="https://mirrors.tuna.tsinghua.edu.cn/termux https://mirrors.ustc.edu.cn/termux https://mirror.sjtu.edu.cn/termux https://mirrors.nju.edu.cn/termux https://mirrors.pku.edu.cn/termux https://mirrors.huaweicloud.com/termux"
TERMUX_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/termux"
# DEBIAN_MIRRORS 与 DEBIAN_SEC_MIRRORS 必须一一对应（按序号配对），新增时两边都要加。
# HTTP 源放在最后：仍然使用 Debian 签名校验，绝不关闭 apt 的签名验证。
DEBIAN_MIRRORS="https://mirrors.tuna.tsinghua.edu.cn/debian https://mirrors.aliyun.com/debian https://mirrors.ustc.edu.cn/debian https://mirrors.cloud.tencent.com/debian https://repo.huaweicloud.com/debian https://mirror.nju.edu.cn/debian https://mirror.sjtu.edu.cn/debian http://mirrors.aliyun.com/debian"
DEBIAN_SEC_MIRRORS="https://mirrors.tuna.tsinghua.edu.cn/debian-security https://mirrors.aliyun.com/debian-security https://mirrors.ustc.edu.cn/debian-security https://mirrors.cloud.tencent.com/debian-security https://repo.huaweicloud.com/debian-security https://mirror.nju.edu.cn/debian-security https://mirror.sjtu.edu.cn/debian-security http://mirrors.aliyun.com/debian-security"
DEBIAN_MIRROR="https://mirrors.tuna.tsinghua.edu.cn/debian"
# PyPI：阿里云最快，清华次之（部分网络 403），其余作兜底
PYPI_MIRRORS="https://mirrors.aliyun.com/pypi/simple https://pypi.tuna.tsinghua.edu.cn/simple https://mirrors.cloud.tencent.com/pypi/simple https://mirrors.huaweicloud.com/repository/pypi/simple https://mirrors.ustc.edu.cn/pypi/simple"
# GitHub 直连之外的代理（唯一实测可用者；gh-proxy.org / ghfast.top 均已失效）
GITHUB_PROXY="https://gh-proxy.com/"
# NapCat 官方要求 Linux QQ 构建号 >= 40768；3.2.34-53644 是官方安装器钉住的版本，
# 实测 qqdl.gtimg.cn 可达（官方 rainbow 页面给的 3.2.18 链接已经 404）。
LINUXQQ_URL="https://qqdl.gtimg.cn/qqfile/QQNT/9.9.36/beta/9ee04bef/linuxqq_3.2.34-53644_arm64.deb"
QQ_MIN_BUILD="40768"

# 镜像连通性探测：HEAD 拿状态码，不支持 HEAD 时退回 1 字节 Range 请求。
# 返回 0 表示 2xx/3xx（可用）；没有 curl 时不拦路，交给 apt/uv 自己判断。
mirror_alive() {
  local url="$1" code=""
  have curl || return 0
  code=$(curl -s -o /dev/null -w '%{http_code}' -I -L --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)
  case "$code" in 2*|3*) return 0 ;; esac
  code=$(curl -s -o /dev/null -w '%{http_code}' -L -r 0-0 --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)
  case "$code" in 2*|3*) return 0 ;; esac
  return 1
}

# Termux 包源换镜像：直接覆盖 sources.list，兼容新版/旧版格式，避免只 sed 匹配失败。
write_termux_source() {
  local mirror="$1" f="$PREFIX/etc/apt/sources.list"
  mkdir -p "$(dirname "$f")"
  printf '# MaiBot installer mirror\ndeb %s/apt/termux-main stable main\n' "$mirror" > "$f"
}

fix_termux_mirror() {
  [ -z "${PREFIX:-}" ] && return 0
  local m usable=""
  # 先探测，把不可达的源快速跳过（否则每次都要等 apt 超时）
  for m in $TERMUX_MIRRORS; do
    if mirror_alive "$m/apt/termux-main/dists/stable/Release"; then
      usable="$usable $m"
    else
      warn "Termux 源不可达，已跳过：$m"
    fi
  done
  # 探测全都失败（比如还没装 curl）时不放弃，仍然按原顺序让 apt 自己试
  [ -n "$usable" ] || usable="$TERMUX_MIRRORS"
  for m in $usable; do
    write_termux_source "$m"
    info "尝试 Termux 软件源：$m"
    if run_logged apt-get $APT_OPTS update -y; then
      ok "Termux 软件源已设置：$m"
      return 0
    fi
    warn "该源不可用，换下一个：$m"
  done
  err "所有 Termux 软件源都不可用，请检查网络，或在 Termux 执行 termux-change-repo"
  return 1
}

# 容器内 Debian 源换清华镜像
fix_debian_mirror() {
  local f=/etc/apt/sources.list code out sf i=0 idx=0 usable="" mirror sec
  # Preserve repository identity from either legacy or deb822 configuration.
  code=$( { grep -hoE '(bookworm|bullseye|trixie|forky)' "$f" /etc/apt/sources.list.d/*.sources 2>/dev/null || true; } | head -1)
  [ -z "$code" ] && code=bookworm
  mkdir -p /etc/apt/sources.list.d
  cp -f "$f" "$f.maibot.bak" 2>/dev/null || true
  for sf in /etc/apt/sources.list.d/*.sources; do
    [ -f "$sf" ] || continue
    cp -f "$sf" "$sf.maibot.bak" 2>/dev/null || true
    mv -f "$sf" "$sf.maibot.disabled" 2>/dev/null || true
  done

  # 先探测（主源 + security 源），不可达的直接跳过，省掉 apt 的长超时；
  # 万一探测本身不可用，再退回"逐个让 apt 自己试"。
  local idx=0 usable=""
  for mirror in $DEBIAN_MIRRORS; do
    idx=$((idx + 1))
    sec=$(echo "$DEBIAN_SEC_MIRRORS" | cut -d' ' -f"$idx")
    [ -z "$sec" ] && sec="$mirror"
    if mirror_alive "$mirror/dists/$code/Release" && mirror_alive "$sec/dists/$code-security/Release"; then
      usable="$usable $idx"
    else
      warn "Debian 源不可达，已跳过：$mirror"
    fi
  done
  [ -n "$usable" ] || { warn "镜像探测都没通过，改为逐个交给 apt 自己判断"; usable=$(seq 1 "$idx"); }

  for i in $usable; do
    mirror=$(echo "$DEBIAN_MIRRORS" | cut -d' ' -f"$i")
    sec=$(echo "$DEBIAN_SEC_MIRRORS" | cut -d' ' -f"$i")
    [ -z "$sec" ] && sec="$mirror"
    cat > "$f" <<EOF
deb $mirror $code main contrib non-free non-free-firmware
deb $mirror $code-updates main contrib non-free non-free-firmware
deb $sec $code-security main contrib non-free non-free-firmware
EOF
    info "验证 Debian 软件源：$mirror"
    # apt-get update can return 0 despite failed fetches when stale lists exist.
    # Require a successful InRelease fetch and no TLS/certificate/fetch errors.
    out=$(mktemp) || return 1
    if apt-get $APT_OPTS update -o Acquire::Retries=0 -o APT::Update::Error-Mode=any >"$out" 2>&1 \
       && grep -qE '^(Get:|Hit:)[0-9]*[[:space:]]+.*InRelease' "$out" \
       && ! grep -qiE 'Err:|certificate verify failed|SSL connection failed|Failed to fetch|NO_PUBKEY|EXPKEYSIG|The repository .* is not signed' "$out"; then
      rm -f "$out"
      ok "Debian 源验证通过（$code，$mirror）"
      return 0
    fi
    warn "该 Debian 源验证失败，尝试下一个；详情：$(grep -Ei 'Err:|certificate|SSL connection|Failed to fetch|NO_PUBKEY|EXPKEYSIG' "$out" | tail -1)"
    rm -f "$out"
  done
  err "所有 Debian 软件源都未通过签名与 TLS 验证；未关闭证书校验，请检查手机代理/DNS 或网络"
  return 1
}

# 统一的 apt 安装（非交互 + 失败明确报错）
apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  info "安装系统组件：$*"
  apt_wait_unlock || return 1
  if ! run_logged apt-get $APT_OPTS update -y; then
    err "软件包索引更新失败，请检查网络后重试"
    return 1
  fi
  if ! run_logged apt-get $APT_OPTS install -y --no-install-recommends "$@"; then
    err "组件安装失败：$*"
    return 1
  fi
  ok "组件就绪：$*"
  return 0
}

# ============================================================
#  Termux 层：检测到 $PREFIX 说明在 Termux（非容器）里运行
# ============================================================
if [ -n "${PREFIX:-}" ]; then

  termux_setup() {
    STEP_ALL=6
    step "环境初始化（Termux 层）"

    # 1. 脚本自就位
    local self
    self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    if [ "$self" != "$HOME/maibot-onekey.sh" ]; then
      cp "$self" "$HOME/maibot-onekey.sh"
      chmod +x "$HOME/maibot-onekey.sh"
    fi
    ok "脚本已就位：$HOME/maibot-onekey.sh"

    # 2. 先换国内源并完整升级，修复 curl/libcurl/openssl 半更新状态
    step "切换国内软件源并修复 Termux 包环境"
    # 若你正在 Termux 里手动 apt，这里先等它结束，避免抢锁失败
    apt_wait_unlock || return 1
    if ! fix_termux_mirror; then return 1; fi
    export DEBIAN_FRONTEND=noninteractive
    if ! run_logged apt-get $APT_OPTS full-upgrade -y; then
      err "Termux 基础库升级失败。请确认没有在 Termux 里同时手动执行 apt；"
      err "修复配置冲突可执行：dpkg --configure -a  然后重试"
      return 1
    fi
    step "安装 Termux 基础组件"
    if ! run_logged apt-get $APT_OPTS install -y proot-distro screen termux-tools curl; then
      err "基础组件安装失败，请检查网络后重试（常见原因：未换镜像源 / 无网络）"
      return 1
    fi
    have proot-distro || { err "proot-distro 未装上，终止"; return 1; }
    ok "proot-distro / screen / termux-tools 就绪"

    # 3. 允许外部 App（本 APK）调用 Termux，否则点按钮没反应
    mkdir -p "$HOME/.termux"
    touch "$HOME/.termux/termux.properties"
    if grep -q '^[[:space:]]*#\?[[:space:]]*allow-external-apps' "$HOME/.termux/termux.properties"; then
      sed -i 's/^[[:space:]]*#\?[[:space:]]*allow-external-apps.*/allow-external-apps=true/' "$HOME/.termux/termux.properties"
    else
      echo 'allow-external-apps=true' >> "$HOME/.termux/termux.properties"
    fi
    ok "已开启 allow-external-apps（本 App 可调用 Termux）"

    # 4. 唤醒锁：锁屏后不冻结 CPU（服务器模式关键）
    if have termux-wake-lock; then
      termux-wake-lock && ok "已获取 Termux 唤醒锁"
    else
      warn "未找到 termux-wake-lock（可执行 pkg install termux-tools）"
    fi

    # 5. 建 Debian 容器（带进度）
    step "创建 Debian 容器（优先国内镜像仓库，rootfs 约 47MB）"
    # list 会列出可安装发行版，空/残缺 rootfs 也不代表已安装。
    # 兼容新旧布局，并实际登录验证 Debian 的 shell 可运行。
    debian_ready() {
      local rootfs found=0
      for rootfs in "$PREFIX/var/lib/proot-distro/containers/debian/rootfs" \
                    "$PREFIX/var/lib/proot-distro/installed-rootfs/debian"; do
        if [ -s "$rootfs/etc/debian_version" ]; then
          found=1
          break
        fi
      done
      [ "$found" -eq 1 ] || return 1
      proot-distro login debian -- /bin/bash -c \
        'test -s /etc/debian_version && test -x /bin/bash' >/dev/null 2>&1
    }
    # proot-distro 5.x 改为从容器镜像仓库拉取 rootfs（默认 registry-1.docker.io），
    # 该地址在国内经常直接超时。refs.py 支持 "主机/仓库:标签" 形式，
    # 因此这里优先走国内镜像仓库，最后才回退官方源。
    # 已实测：docker.m.daocloud.io 能完整提供 library/debian 的 arm64 层（约 47MB）。
    registry_alive() {
      local code
      code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 6 --max-time 12 \
             "https://$1/v2/" 2>/dev/null || echo 000)
      [ "$code" = "401" ] || [ "$code" = "200" ]
    }

    # 从国内镜像站（ISCAS）解析一个"确实包含 rootfs.tar.xz"的日期目录。
    # 该镜像按日期分目录，最新目录常常还没同步到文件（空目录），因此必须逐个验证。
    iscas_rootfs_url() {
      local arch=arm64
      [ "$(uname -m)" = "x86_64" ] && arch=amd64
      local base="https://mirror.iscas.ac.cn/lxc-images/images/debian/bookworm/$arch/default"
      local listing d url
      listing=$(curl -s --connect-timeout 12 --max-time 25 "$base/" 2>/dev/null || true)
      [ -n "$listing" ] || return 1
      for d in $(printf '%s' "$listing" \
                 | grep -oE 'href="[0-9]{8}_[0-9]{2}(%3A|:)[0-9]{2}/"' \
                 | sed 's/href="//; s/"$//' | sort -r | head -6); do
        url="${base}/${d}rootfs.tar.xz"
        if [ "$(curl -sI -o /dev/null -w '%{http_code}' --connect-timeout 12 --max-time 25 "$url" 2>/dev/null)" = "200" ]; then
          printf '%s\n' "$url"
          return 0
        fi
      done
      return 1
    }

    install_debian_image() {
      local dlog="$HOME/.maibot-debian-install.log"
      local ref host
      # 依次尝试：daocloud（实测可完整提供 arm64 层）→ 1ms（同样实测可用）
      # → 官方 Docker Hub（部分网络可用）
      for ref in "docker.m.daocloud.io/library/debian" "docker.1ms.run/library/debian" "debian"; do
        host="${ref%%/*}"
        if [ "$host" != "$ref" ]; then
          if registry_alive "$host"; then
            ok "镜像仓库可用：$host"
          else
            warn "镜像仓库不可达，跳过：$host"
            continue
          fi
        fi
        info "拉取 Debian 镜像：$ref"
        if run_capture "$dlog" proot-distro install "$ref"; then
          ok "Debian 容器创建完成（来源：$ref）"
          return 0
        fi
        warn "该来源失败：$ref"
        # 清掉半成品，否则下次会被误判成"已安装"而跳过
        proot-distro remove debian >/dev/null 2>&1 || true
      done

      # 最后兜底：容器镜像仓库全不可用时，直接从国内镜像站导入 rootfs 压缩包。
      # 注意：这种方式不带 manifest.json，reset/run 子命令不可用（本脚本只用 login，不受影响）。
      local tarball=""
      if tarball=$(iscas_rootfs_url); then
        info "容器仓库均不可用，改用国内镜像站的 rootfs：$tarball"
        if run_capture "$dlog" proot-distro install "$tarball" --name debian; then
          ok "Debian 容器创建完成（来源：国内 rootfs 镜像站）"
          return 0
        fi
        warn "国内 rootfs 导入失败"
        proot-distro remove debian >/dev/null 2>&1 || true
      else
        warn "未能从国内镜像站解析到可用的 rootfs 压缩包"
      fi

      if grep -qiE 'timed out|timeout|cannot connect|connection refused|Errno 110|Errno 111|Temporary failure|network is unreachable' "$dlog" 2>/dev/null; then
        err "所有下载来源都连不上（这是网络可达性问题，不是你 Termux 配置错误）"
        info "可在 Termux 里手动重试，观察具体报错："
        info "    proot-distro install docker.m.daocloud.io/library/debian"
        info "若仍超时，请更换网络或使用代理后重试。"
      else
        err "Debian 容器创建失败：$(tail -n 3 "$dlog" 2>/dev/null | tr '\n' ' ')"
      fi
      info "完整报错见：$dlog"
      return 1
    }

    if debian_ready; then
      ok "Debian 容器已存在，跳过"
    else
      if ! install_debian_image; then return 1; fi
    fi
    if ! debian_ready; then
      err "Debian 容器安装后仍检测不到，请重试；也可在 Termux 里手动执行：proot-distro install debian"
      return 1
    fi

    # 6. 生成桌面图标脚本
    step "生成桌面快捷操作图标"
    mkdir -p "$HOME/.shortcuts"
    gen() {
      local label="$1" sub="$2" mode="$3"
      local f="$HOME/.shortcuts/$label.sh"
      if [ "$mode" = "live" ]; then
        printf '#!/data/data/com.termux/files/usr/bin/bash\nexec bash "$HOME/maibot-onekey.sh" %s\n' "$sub" > "$f"
      else
        {
          printf '#!/data/data/com.termux/files/usr/bin/bash\n'
          printf 'bash "$HOME/maibot-onekey.sh" %s\n' "$sub"
          printf 'echo ""\nread -r -p "[完成] 按回车关闭本窗口 " _\n'
        } > "$f"
      fi
      chmod +x "$f"
    }

    gen "一键部署MaiBot" "install"        "cmd"
    gen "启动全部服务"   "guard"          "cmd"
    gen "停止全部服务"   "guard-stop"     "cmd"
    gen "启动MaiBot"     "start"          "cmd"
    gen "前台启动MaiBot" "fg"             "live"
    gen "停止MaiBot"     "stop"           "cmd"
    gen "更新MaiBot"     "update"         "cmd"
    gen "MaiBot状态"     "status"         "cmd"
    gen "查看密钥"       "token"          "cmd"
    gen "MaiBot菜单"     ""               "live"
    gen "安装NapCat"     "napcat-install" "cmd"
    gen "配置QQ号"       "napcat-setup"   "live"
    gen "启动NapCat"     "napcat-start"   "cmd"
    gen "停止NapCat"     "napcat-stop"    "cmd"
    gen "NapCat登录码"   "napcat-webui"   "cmd"

    say ""
    ok "已生成 $(ls "$HOME/.shortcuts" | wc -l) 个桌面图标脚本（~/.shortcuts/）"
    say ""
    say "===== 后续步骤（只需一次）====="
    say " 1) 安装 Termux:Widget 插件："
    say "    https://github.com/termux/termux-widget/releases 下 APK 安装"
    say " 2) 主屏幕长按 → 添加小部件 → Termux:Widget → 拖到桌面"
    say " 3) 点桌面图标即可一键操作"
    say ""
    say "推荐首次流程：一键部署MaiBot → 启动MaiBot → 打开 MaiBot WebUI 配置模型"
    say "            → 安装NapCat → 配置QQ号 → 启动NapCat → NapCat登录码(扫码)"
    say "            → 最后执行「启动全部服务」进入 7×24 服务器模式"
    say ""
    ok "初始化完成！"
  }

  # ---------- Termux 层守护：唤醒锁 + 独立 screen 会话 ----------
  termux_guard() {
    local sub="$1"
    case "$sub" in
      guard-stop)
        screen -S maibot-watchdog -X quit >/dev/null 2>&1
        have termux-wake-lock && termux-wake-unlock >/dev/null 2>&1
        local rc=0
        proot-distro login debian --bind "$HOME:/termux-home" \
          -- env MAIBOT_STATE_HOME=/termux-home MAIBOT_LOG=/termux-home/.maibot-run.log \
          MAIBOT_NESTED=1 MAIBOT_QUERY="${MAIBOT_QUERY:-0}" bash /termux-home/maibot-onekey.sh allstop || rc=1
        if [ "$rc" -ne 0 ]; then
          err "停止服务时有步骤失败，请查看上方输出"
          return 1
        fi
        ok "已停止全部服务与守护"
        return 0
        ;;
    esac

    if ! have proot-distro; then
      err "环境未初始化，请先运行：bash ~/maibot-onekey.sh setup"
      return 1
    fi

    # 1) 唤醒锁：锁屏后 CPU 不被冻结
    if have termux-wake-lock; then
      termux-wake-lock >/dev/null 2>&1 && ok "Termux 唤醒锁已获取（锁屏不冻结）"
    fi

    # 2) 拉起容器内全部服务（幂等）
    info "启动 MaiBot 与 NapCat ..."
    local start_rc=0
    proot-distro login debian --bind "$HOME:/termux-home" \
      -- env MAIBOT_STATE_HOME=/termux-home MAIBOT_LOG=/termux-home/.maibot-run.log \
          MAIBOT_NESTED=1 MAIBOT_QUERY="${MAIBOT_QUERY:-0}" bash /termux-home/maibot-onekey.sh allstart || start_rc=1

    # 3) 独立守护会话：即使本 App 被杀，容器内也会自我恢复
    if have screen; then
      if screen -ls 2>/dev/null | grep -q "[.]maibot-watchdog"; then
        ok "守护进程已在运行"
      else
        screen -dmS maibot-watchdog bash "$HOME/maibot-onekey.sh" wd
        sleep 2
        screen -ls 2>/dev/null | grep -q "[.]maibot-watchdog" \
          && ok "守护进程已启动（掉线自动拉起）" || warn "守护进程启动失败"
      fi
    else
      warn "未安装 screen，跳过守护进程（可执行 pkg install screen）"
    fi

    if [ "$start_rc" -ne 0 ]; then
      say ""
      err "服务未能全部启动（守护已就绪）。请查看上方 [错误] 行处理后重试。"
      return 1
    fi

    say ""
    ok "服务器模式已开启：只要手机有电，MaiBot 就会持续运行"
    info "关闭请执行：bash $0 guard-stop"
    return 0
  }

  _LAYER_RC=0
  if [ "${1:-menu}" = "setup" ]; then
    termux_setup; _LAYER_RC=$?
  elif [ "${1:-}" = "guard" ] || [ "${1:-}" = "guard-stop" ] || [ "${1:-}" = "wake" ]; then
    termux_guard "${1:-}"; _LAYER_RC=$?
  else
    # 非 setup 命令：进容器执行同一脚本同一子命令
    if ! have proot-distro; then
      err "未安装 proot-distro，请先运行：bash ~/maibot-onekey.sh setup"
      exit 1
    fi
    proot-distro login debian --bind "$HOME:/termux-home" -- env MAIBOT_STATE_HOME=/termux-home MAIBOT_LOG=/termux-home/.maibot-run.log \
          MAIBOT_NESTED=1 MAIBOT_QUERY="${MAIBOT_QUERY:-0}" bash /termux-home/maibot-onekey.sh "$@"
    _LAYER_RC=$?
  fi
  # 把真实退出码交给 App：App 用它判断"这次初始化/操作到底成功没有"
  exit "$_LAYER_RC"
fi

# ============================================================
#  容器层：以下在 Debian 容器内执行
# ============================================================

export PATH="$HOME/.local/bin:$PATH"

# 万一仍需要下载 Python 解释器，让 uv 走 GitHub 代理而不是直连 GitHub
# （正常情况下 UV_PYTHON_DOWNLOADS=never 已禁止下载，这里只是保险）
export UV_PYTHON_INSTALL_MIRROR="${GITHUB_PROXY}https://github.com/astral-sh/python-build-standalone/releases/download"

# ---------- MaiBot 配置 ----------
REPO="https://github.com/Mai-with-u/MaiBot.git"
# gh-proxy.org 已实测不可达，改用 gh-proxy.com
REPO_MIRROR="${GITHUB_PROXY}https://github.com/Mai-with-u/MaiBot.git"
BASE_DIR="${MAIBOT_HOME:-$HOME/maimai}"
BOT_DIR="$BASE_DIR/MaiBot"
PY_INDEX_URL="${UV_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple}"
SCREEN_NAME="maibot"
LOG_FILE="$BOT_DIR/logs/mai.log"

# ---------- NapCat 配置 ----------
NAPCAT_DIR="$HOME/NapCat.linux.arm64"
NAPCAT_SCREEN="napcat"
# Xvfb 单独一个会话：以前它挂在 QQ 的启动脚本里，QQ 一崩脚本就退出，
# 显示 :1 跟着消失，之后每次启动都更难点亮。
XVFB_SCREEN="napcat-xvfb"
NAPCAT_LOG="$HOME/napcat.log"
NAPCAT_ENV="$HOME/.env"
# QQ 安装包地址与最低构建号见上方「镜像加速」段（LINUXQQ_URL / QQ_MIN_BUILD）
NAPCAT_FALLBACK_VERSION="v4.18.42"
NAPCAT_WS_PORT="3001"
# QQ 是 Electron：容器里 --no-sandbox 必需。其余开关保持与官方 Termux 配方一致，
# 需要额外加（如 --disable-gpu）时用环境变量 MAIBOT_QQ_FLAGS 覆盖即可，默认不动。
QQ_LAUNCH_FLAGS="${MAIBOT_QQ_FLAGS:---no-sandbox --enable-logging=stderr}"

# 运行状态不能只看 screen：用户也可能在前台/其他会话启动服务，或 screen 名称变更。
# 8001 本机 TCP 可连接时也视为 MaiBot 活着，避免 WebUI 可用但 status 误报停止。
maibot_port_open() {
  (exec 3<>/dev/tcp/127.0.0.1/8001) >/dev/null 2>&1
}
napcat_port_open() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}
# screen 会话名必须精确匹配：否则 ".maibot" 会命中 ".maibot-watchdog"，
# 让已经崩掉的 MaiBot 看起来"进程还在"，把真正的故障原因掩盖掉。
# 还要区分 Dead 会话：进程早退了、只剩空壳（手机/容器重启后最常见），
# screen -ls 照样列出来，旧实现当成"在运行"，于是「启动」直接返回、
# WebUI 永远起不来 —— 这就是"以前能用、现在不动"的现场。
screen_session_state() {
  local name="$1" line
  line=$(screen -ls 2>/dev/null | grep -E "[.]${name}[[:space:]]" | head -1)
  [ -n "$line" ] || { printf 'none'; return 0; }
  case "$line" in
    *Dead*) printf 'dead' ;;
    *)      printf 'live' ;;
  esac
}
screen_session_running() {
  [ "$(screen_session_state "$1")" = live ]
}
# 清理空壳会话：Dead 的会话 -X quit 是无效的，必须先 -wipe 让 screen 回收。
screen_wipe_dead() {
  screen -wipe >/dev/null 2>&1 || true
}
# 结束一个会话，并顺手回收它留下的空壳。
screen_drop() {
  screen -S "$1" -X quit >/dev/null 2>&1 || true
  screen_wipe_dead
}
maibot_process_running() {
  pgrep -f 'bot\.py' >/dev/null 2>&1
}
is_running() {
  maibot_port_open || maibot_process_running || screen_session_running "$SCREEN_NAME"
}
napcat_running() {
  qq_process_running \
    || napcat_port_open 6099 \
    || napcat_port_open "$NAPCAT_WS_PORT" \
    || screen_session_running "$NAPCAT_SCREEN"
}
# WebUI 到底有没有监听，比"进程在不在"更重要：MaiBot 崩了但守护会话还在时，
# 只有端口能说明 WebUI 是否真的可用。
maibot_webui_state() {
  if maibot_port_open; then
    printf 'running'
  elif screen_session_running "$SCREEN_NAME"; then
    printf 'noport'
  else
    printf 'stopped'
  fi
}
napcat_webui_port() {
  local p
  for p in $(seq 6099 6199); do
    if napcat_port_open "$p"; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}
napcat_log_url() {
  local f
  for f in "$NAPCAT_LOG" "$NAPCAT_DIR/napcat.log" "/opt/QQ/resources/app/app_launcher/napcat.log"; do
    [ -f "$f" ] || continue
    grep -Eo 'https?://(127\.0\.0\.1|localhost):[0-9]+/webui([^[:space:]]*)?' "$f" | tail -1 && return 0
  done
  return 1
}
sync_napcat_config() {
  local target="/opt/QQ/resources/app/app_launcher/napcat/config"
  [ -d "$target" ] || return 0
  mkdir -p "$target"
  cp -f "$NAPCAT_DIR/config"/onebot11_*.json "$target/" 2>/dev/null || true
  [ -f "$NAPCAT_DIR/config/webui.json" ] && cp -f "$NAPCAT_DIR/config/webui.json" "$target/webui.json"
  chmod 600 "$target"/*.json 2>/dev/null || true
}

check_env() {
  say ""
  say "${BOLD}===== 环境检查 =====${NC}"
  [ "$(uname -m)" = "aarch64" ] && ok "CPU aarch64" || warn "异常架构 $(uname -m)"
  local missing=""
  for c in git curl gcc jq screen; do
    have "$c" && ok "命令 $c 就绪" || { warn "缺少 $c"; missing="$missing $c"; }
  done
  have uv && ok "uv 已安装" || warn "uv 未安装（install 会自动装）"
  [ -n "$missing" ] && info "可执行：apt install -y$missing"
}

check_config() {
  say ""
  say "${BOLD}===== MaiBot 配置检查 =====${NC}"
  local ok_all=1
  ck(){ if [ -e "$1" ]; then ok "$2"; else warn "$2 缺失（$3）"; ok_all=0; fi; }
  ck "$BOT_DIR/.git"                     "MaiBot 源码"      "install"
  ck "$BOT_DIR/.venv"                    "Python 虚拟环境"   "install/update"
  ck "$BOT_DIR/config/bot_config.toml"   "Bot/WebUI 配置"    "首次启动生成"
  ck "$BOT_DIR/config/model_config.toml" "模型配置"          "首次启动生成"
  ck "$BOT_DIR/data/webui.json"          "WebUI 访问密钥"    "首次启动生成"
  [ "$ok_all" = "1" ] && ok "配置齐备" || warn "存在缺失项"
}

check() { check_env; check_config; }

install_system_deps() {
  fix_debian_mirror || return 1
  # python3/pip 必须预装：否则 uv 会去 GitHub 下载 Python 解释器（国内常失败），
  # pip 也是 uv 官方安装脚本不可用时的兜底手段。
  apt_install git curl wget ca-certificates build-essential jq screen unzip \
    python3 python3-venv python3-pip \
    || { err "系统依赖安装失败（可重试，或检查网络）"; return 1; }
}

# uv 官方安装脚本在 astral.sh 上，国内常不可达；这里额外准备
# "GitHub Release 直接下二进制" 与 "PyPI 镜像 pip" 两条兜底路径。
UV_FALLBACK_VERSION="v0.12.22"

install_uv_from_github() {
  local ver="$1" url bin tmpdir
  if [ -z "$ver" ]; then
    ver=$(curl -s --connect-timeout 15 https://api.github.com/repos/astral-sh/uv/releases/latest 2>/dev/null \
          | jq -r '.tag_name // empty' 2>/dev/null)
  fi
  [ -z "$ver" ] && ver="$UV_FALLBACK_VERSION"
  local asset="uv-aarch64-unknown-linux-gnu.tar.gz"
  tmpdir=$(mktemp -d) || return 1
  for url in \
    "https://github.com/astral-sh/uv/releases/download/$ver/$asset" \
    "${GITHUB_PROXY}https://github.com/astral-sh/uv/releases/download/$ver/$asset" ; do
    info "下载 uv 二进制（$ver）：$url"
    if curl -fL --connect-timeout 20 --retry 2 -o "$tmpdir/$asset" "$url" 2>/dev/null \
       && tar -xzf "$tmpdir/$asset" -C "$tmpdir" 2>/dev/null; then
      bin=$(find "$tmpdir" -type f -name uv 2>/dev/null | head -1)
      if [ -n "$bin" ]; then
        mkdir -p "$HOME/.local/bin"
        cp -f "$bin" "$HOME/.local/bin/uv" && chmod +x "$HOME/.local/bin/uv"
        local x; x=$(find "$tmpdir" -type f -name uvx 2>/dev/null | head -1)
        [ -n "$x" ] && { cp -f "$x" "$HOME/.local/bin/uvx"; chmod +x "$HOME/.local/bin/uvx"; }
        rm -rf "$tmpdir"
        return 0
      fi
    fi
  done
  rm -rf "$tmpdir"
  return 1
}

install_uv() {
  have uv && { ok "uv 已装，跳过"; return 0; }
  info "安装 uv（Python 包管理器）..."
  export UV_INSTALL_DIR="$HOME/.local/bin"

  # 路径 1：官方安装脚本
  local installer=""
  installer=$(mktemp) || installer=""
  if [ -n "$installer" ] \
     && run_logged curl -LsSf --connect-timeout 20 -o "$installer" https://astral.sh/uv/install.sh \
     && run_logged sh "$installer"; then
    rm -f "$installer"
    export PATH="$HOME/.local/bin:$PATH"
    have uv && { ok "uv 安装完成（官方脚本）"; return 0; }
  fi
  rm -f "$installer"

  # 路径 2：GitHub Release 二进制（直连失败自动走代理）
  warn "官方安装脚本不可用，改为直接下载 uv 二进制 ..."
  export PATH="$HOME/.local/bin:$PATH"
  if install_uv_from_github; then
    have uv && { ok "uv 安装完成（GitHub 二进制）"; return 0; }
  fi

  # 路径 3：PyPI 镜像 + pip 兜底
  warn "改用 PyPI 镜像安装 uv ..."
  local pipcmd=""
  have pip && pipcmd="pip"
  [ -z "$pipcmd" ] && have pip3 && pipcmd="pip3"
  if [ -n "$pipcmd" ]; then
    # pip 只认 PIP_INDEX_URL；UV_* 变量对 pip 无效（旧版本写错了，等于直连 PyPI）
    if PIP_INDEX_URL="$PY_INDEX_URL" run_logged "$pipcmd" install --user -U uv --break-system-packages; then
      export PATH="$HOME/.local/bin:$PATH"
      have uv && { ok "uv 安装完成（PyPI 镜像）"; return 0; }
    fi
    # 老版本 pip 不认识 --break-system-packages，去掉该参数再试一次
    PIP_INDEX_URL="$PY_INDEX_URL" run_logged "$pipcmd" install --user -U uv || true
    export PATH="$HOME/.local/bin:$PATH"
    have uv && { ok "uv 安装完成（PyPI 镜像）"; return 0; }
  else
    warn "未找到 pip/pip3，跳过 PyPI 兜底（可由 apt 安装 python3-pip）"
  fi

  err "uv 安装失败（三条路径都不可用）。请在 Termux 里执行 bash ~/maibot-onekey.sh install 查看完整报错"
  return 1
}

clone_repo() {
  mkdir -p "$BASE_DIR"
  # 只有当 .git 是一个可用仓库时才跳过；残缺的 .git 会让后续 uv sync 失败
  if [ -d "$BOT_DIR/.git" ]; then
    if git -C "$BOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
      ok "源码已存在，跳过克隆"
      return 0
    fi
    warn "检测到残缺的源码目录（.git 不完整），清理后重新克隆"
    rm -rf "$BOT_DIR"
  fi
  if [ -e "$BOT_DIR" ]; then
    err "源码目录已存在但不是 Git 仓库，保留原文件；请检查或备份后重试：$BOT_DIR"
    return 1
  fi
  info "克隆 MaiBot 源码（约 100MB，带进度）..."
  if run_logged git clone --progress --depth 1 "$REPO" "$BOT_DIR"; then
    [ -d "$BOT_DIR/.git" ] && { ok "源码克隆完成"; return 0; }
  fi
  warn "官方线路失败，切换国内代理镜像重试 ..."
  rm -rf "$BOT_DIR"
  if run_logged git clone --progress --depth 1 "$REPO_MIRROR" "$BOT_DIR"; then
    [ -d "$BOT_DIR/.git" ] && { ok "源码克隆完成（镜像）"; return 0; }
  fi
  # 镜像也失败时清掉残缺的 .git，否则下次会被误判成"源码已存在"而跳过克隆
  if [ -d "$BOT_DIR/.git" ] && ! git -C "$BOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
    rm -rf "$BOT_DIR"
  fi
  err "源码克隆失败，请检查网络后重试"
  return 1
}

install_deps() {
  cd "$BOT_DIR" || return 1
  # UV_PYTHON_DOWNLOADS=never：禁止 uv 去 GitHub 下载 Python 解释器（国内常失败），
  # 改用 apt 装好的系统 python3；这也是把 python3 加进系统依赖的原因。
  if [ ! -d ".venv" ]; then
    info "创建 Python 虚拟环境（使用系统 python3，不联网下载解释器）..."
    UV_PYTHON_DOWNLOADS=never run_logged uv venv --python python3 \
      || UV_PYTHON_DOWNLOADS=never run_logged uv venv \
      || { err "虚拟环境创建失败（确认已安装 python3：apt install python3 python3-venv）"; return 1; }
  fi
  info "安装 Python 依赖（约数百 MB，走阿里云 PyPI 镜像，请耐心等待）..."
  if UV_DEFAULT_INDEX="$PY_INDEX_URL" UV_INDEX_URL="$PY_INDEX_URL" UV_PYTHON_DOWNLOADS=never run_logged uv sync; then
    ok "Python 依赖安装完成"
    return 0
  fi
  err "依赖安装失败（常见原因：网络中断，可重试，已下载部分会复用）"
  return 1
}

install() {
  STEP_ALL=4
  STEP_NO=0
  say "${BOLD}===== 开始部署 MaiBot =====${NC}"
  net_check || return 1
  step "系统依赖"      ; install_system_deps || return 1
  step "uv 环境"       ; install_uv          || return 1
  step "拉取源码"      ; clone_repo          || return 1
  step "安装依赖"      ; install_deps        || return 1
  mkdir -p "$BOT_DIR/logs" "$BOT_DIR/data"
  say ""
  ok "MaiBot 部署完成"
  info "下一步：点「启动 MaiBot」，然后在 WebUI 里配置模型密钥"
  info "WebUI：http://127.0.0.1:8001   密钥：bash $0 token"
}

update() {
  [ -d "$BOT_DIR/.git" ] || { err "尚未部署，先 install"; return 1; }
  if is_running; then
    err "MaiBot 正在运行，请先停止再更新（后台任务不能交互确认）"
    return 1
  fi
  cd "$BOT_DIR" || return 1
  info "拉取代码 ..."
  git pull --ff-only || { err "拉取失败"; return 1; }
  info "更新依赖 ..."
  UV_DEFAULT_INDEX="$PY_INDEX_URL" UV_INDEX_URL="$PY_INDEX_URL" uv sync || { err "依赖更新失败"; return 1; }
  ok "更新完成，用 start 启动"
}

# 启动前必须先把依赖同步好。
# uv run 默认会先构建/安装项目；一旦构建卡住或失败，表现就是
# "screen 会话在、8001 永远不监听"，日志里只剩 Building maibot @ ...
sync_deps() {
  cd "$BOT_DIR" || return 1
  have uv || { err "找不到 uv：请先执行 install（或点「按顺序安装」）"; return 1; }
  # 国内网络下单一镜像经常抽风：先按实测顺序探测，跳过连不上的，
  # 可用源里依次回退（阿里云 → 清华 → 腾讯云 → 华为云 → 中科大 → 官方 PyPI）。
  # 每个源内部先试 --frozen（按 uv.lock 精确还原），锁文件过期再退回普通 sync。
  local url label list=""
  for url in $PYPI_MIRRORS; do
    if mirror_alive "$url/pip/"; then
      list="$list $url"
    else
      warn "PyPI 镜像不可达，已跳过：$url"
    fi
  done
  # 探测全失败时不放弃：仍然把候选源都试一遍，最后再兜底官方 PyPI
  [ -n "$list" ] || list=" $PYPI_MIRRORS"
  for url in $list ""; do
    if [ -n "$url" ]; then label="$url"; else label="官方 PyPI"; fi
    info "同步依赖（$label，首次或网络慢时可能要几分钟）..."
    if [ -n "$url" ]; then
      run_logged env UV_DEFAULT_INDEX="$url" UV_INDEX_URL="$url" uv sync --frozen && { ok "依赖已同步"; return 0; }
      run_logged env UV_DEFAULT_INDEX="$url" UV_INDEX_URL="$url" uv sync && { ok "依赖已同步"; return 0; }
    else
      run_logged uv sync --frozen && { ok "依赖已同步"; return 0; }
      run_logged uv sync && { ok "依赖已同步"; return 0; }
    fi
    warn "用 $label 同步失败，换下一个源重试"
  done
  err "依赖同步失败：所有源都没成功，基本是网络问题（可换网络后点「修复依赖」重试）"
  return 1
}

# 依赖坏了但不想重装时的修复入口
fix_deps() {
  say ""
  say "${BOLD}===== 修复依赖 =====${NC}"
  [ -d "$BOT_DIR" ] || { err "尚未部署，先 install"; return 1; }
  if is_running; then
    info "先停止 MaiBot 再修依赖"
    stop
  fi
  # 上一次卡死在 uv sync / uv run 的进程要清掉，否则它会一直占着 .venv 写锁
  stop_maibot
  sync_deps || return 1
  ok "依赖已修复，回到 App 点「启动 MaiBot」"
}

# 真正停掉 MaiBot：会话、bot.py，以及可能卡住的 uv（旧版本会永远停在 Building）
stop_maibot() {
  screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
  pkill -f 'bot\.py' 2>/dev/null || true
  pkill -f 'uv (sync|run)' 2>/dev/null || true
  screen_wipe_dead
  return 0
}

# 启动 MaiBot。
# 关键：不要用 `uv run` 启动。uv 运行前会同步环境并构建/安装项目本身
# （日志里只有一行 "Building maibot @ file://..."）；构建后端要走 build isolation
# 下载 setuptools，国内经常直接卡死，于是永远起不来、8001 永远不监听。
# 依赖已经 uv sync 过，这里直接复刻 uv run 的运行环境（VIRTUAL_ENV / PATH / .env），
# 用虚拟环境解释器启动，全程不联网、不构建。
start() {
  [ -d "$BOT_DIR" ] || { err "尚未部署，先 install"; return 1; }
  if [ ! -f "$BOT_DIR/data/webui.json" ]; then
    # 新版 MaiBot 不再需要前台确认协议，webui.json 由 WebUI 服务启动时生成。
    # 这里只提示、不拦截：拦下来只会让「启动」永远点不动。
    warn "还没有 data/webui.json（首次启动会由 MaiBot 自己生成）"
    info "启动后用「查看密钥」或 bash $0 token 取 WebUI 登录密钥"
  fi
  if maibot_port_open; then
    ok "MaiBot 已在运行，WebUI http://127.0.0.1:8001"
    return 0
  fi
  # 会话在、8001 却没监听：要么卡在依赖构建，要么只是重启后留下的空壳。
  # 旧版本在这里直接说"已在运行"就返回，用户怎么点都起不来。
  screen_wipe_dead
  if screen_session_running "$SCREEN_NAME" || maibot_process_running; then
    warn "检测到旧的 MaiBot 会话/进程，但 8001 没在监听，先清理再启动"
    stop_maibot
  fi
  mkdir -p "$BOT_DIR/logs"
  info "虚拟环境：$([ -x "$BOT_DIR/.venv/bin/python" ] && echo 已就绪 || echo 缺失，将由 uv sync 创建)"
  sync_deps || return 1
  if [ ! -f "$BOT_DIR/bot.py" ]; then
    err "找不到 $BOT_DIR/bot.py，源码不完整：点「更新 MaiBot」或重新部署"
    return 1
  fi
  cd "$BOT_DIR" || return 1
  local launch
  if [ -x "$BOT_DIR/.venv/bin/python" ]; then
    # PYTHONUNBUFFERED：输出经 tee 落盘，不设的话日志会攒在缓冲区里，看不出进度
    launch="cd '$BOT_DIR' || exit 1; export VIRTUAL_ENV='$BOT_DIR/.venv' PATH='$BOT_DIR/.venv/bin':\$PATH PYTHONUNBUFFERED=1 PYTHONUTF8=1; if [ -f .env ]; then set -a; . ./.env; set +a; fi; '$BOT_DIR/.venv/bin/python' -u bot.py"
  else
    warn "虚拟环境里没有 Python 解释器，退回 uv run（会重新同步，可能很慢）"
    launch="cd '$BOT_DIR' || exit 1; PYTHONUNBUFFERED=1 env UV_DEFAULT_INDEX='$PY_INDEX_URL' UV_INDEX_URL='$PY_INDEX_URL' uv run --no-sync python bot.py"
  fi
  # 把真正执行的命令行写进日志：以后排查不用再猜用的是哪种启动方式
  info "启动命令：$launch"
  screen -dmS "$SCREEN_NAME" bash -c "$launch 2>&1 | tee '$LOG_FILE'"
  info "等待 WebUI 监听 8001（最多 120 秒）..."
  local waited=0 seen=0
  while [ "$waited" -lt 120 ]; do
    sleep 1
    waited=$((waited + 1))
    maibot_port_open && break
    # 刚拉起的一瞬间进程还没建出来，所以"见过它活着、之后又消失"才算真失败
    if maibot_process_running || screen_session_running "$SCREEN_NAME"; then
      seen=1
    elif [ "$seen" = 1 ]; then
      break
    fi
  done
  if maibot_port_open; then
    ok "MaiBot 已启动，WebUI http://127.0.0.1:8001"
    return 0
  fi
  if maibot_process_running; then
    warn "进程在运行，但 120 秒内 8001 仍未监听"
  else
    err "MaiBot 进程已退出，启动失败"
  fi
  info "本地日志末尾（${LOG_FILE}）："
  webui_log_tail "$LOG_FILE" 25
  info "处理：点「修复依赖」→「启动 MaiBot」；仍不行点「连接诊断」并把输出发出来"
  return 1
}

fg_run() {
  [ -d "$BOT_DIR" ] || { err "尚未部署，先 install"; return 1; }
  cd "$BOT_DIR" || return 1
  info "前台启动（按住 Ctrl+C 退出；想看报错时用这个）..."
  if [ -x "$BOT_DIR/.venv/bin/python" ]; then
    PYTHONUNBUFFERED=1 "$BOT_DIR/.venv/bin/python" -u bot.py
  else
    uv run python bot.py
  fi
}

stop() {
  if ! is_running; then
    warn "MaiBot 未运行"
    screen_wipe_dead
    return 0
  fi
  stop_maibot
  ok "MaiBot 已停止"
}

restart() { stop; start; }

status() {
  say ""
  is_running && ok "MaiBot 运行中（$SCREEN_NAME） WebUI http://127.0.0.1:8001" || warn "MaiBot 未运行"
}

# 端口开着不等于页面能打开：真正发一次 HTTP 请求，避免把打不开的地址丢给浏览器。
# 容器里可能没有 curl（安装未完成时），此时用 bash 的 /dev/tcp 手工发请求兜底，
# 否则会永远返回 000，把好好的 WebUI 误判成"打不开"。
webui_http_code() {
  local url="$1" code="000" rest hostport host port path
  rest="${url#http://}"
  hostport="${rest%%/*}"
  if [ "$rest" = "$hostport" ]; then path="/"; else path="/${rest#*/}"; fi
  host="${hostport%%:*}"
  port="${hostport##*:}"
  if have curl; then
    # curl 失败时也会打印 000，再叠加兜底就会变成 000000，这里统一成一个值。
    code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$url" 2>/dev/null || true)
  elif [ -n "$host" ] && [ -n "$port" ]; then
    code=$( (
      exec 3<>"/dev/tcp/$host/$port" || exit 1
      printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$path" "$host" >&3
      IFS= read -r -t 6 line <&3
      printf '%s' "$line"
      exec 3<&- 3>&-
    ) 2>/dev/null | grep -Eo '[0-9]{3}' | head -1 )
  fi
  case "$code" in
    ''|*[!0-9]*) code=000 ;;
  esac
  printf '%s' "$code"
}
webui_http_ok() {
  local code
  code=$(webui_http_code "$1")
  [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" != "404" ]
}

# 只发一次诊断信息，避免重复请求
webui_log_tail() {
  local file="$1" lines="${2:-15}"
  [ -f "$file" ] || { info "（没有日志文件：$file）"; return 0; }
  tail -n "$lines" "$file" 2>/dev/null | while IFS= read -r l; do info "$l"; done
}

webui() {
  local state code
  state=$(maibot_webui_state)
  case "$state" in
    running)
      code=$(webui_http_code 'http://127.0.0.1:8001/')
      if [ "$code" = "000" ]; then
        warn "8001 已监听，但 HTTP 检测没通过（可能还在启动中）"
        info "仍然把地址交给浏览器；如果页面报错，等 10~30 秒再点一次"
      else
        ok "MaiBot WebUI 可用（HTTP $code）"
      fi
      info "MaiBot WebUI：http://127.0.0.1:8001"
      printf 'WEBUI_URL=%s\n' 'http://127.0.0.1:8001/'
      ;;
    noport)
      warn "MaiBot 进程在，但 8001 没有监听：WebUI 没起来"
      info "常见原因：MaiBot 启动失败、WebUI 被关闭、或还在初始化"
      webui_log_tail "$LOG_FILE" 15
      info "可先「停止 MaiBot」再「启动 MaiBot」；仍不行点「连接诊断」"
      printf 'WEBUI_UNAVAILABLE=1\n'
      ;;
    *)
      warn "MaiBot 未运行：先点「启动 MaiBot」"
      printf 'WEBUI_UNAVAILABLE=1\n'
      ;;
  esac
  return 0
}

# 一次性检查两个 WebUI 是否真的能打开（App 的「检测 WebUI」按钮）
webui_check() {
  say ""
  say "${BOLD}===== WebUI 可用性检测 =====${NC}"
  local code p state

  state=$(maibot_webui_state)
  case "$state" in
    running)
      code=$(webui_http_code 'http://127.0.0.1:8001/')
      if [ "$code" != "000" ]; then
        ok "MaiBot WebUI 可打开（HTTP $code）http://127.0.0.1:8001"
      else
        warn "8001 已监听，但 HTTP 无响应（HTTP $code）"
        info "多数是还在启动：等 10~30 秒再点一次"
      fi
      ;;
    noport)
      warn "MaiBot 进程在，但 8001 未监听：WebUI 没有起来"
      info "先「停止 MaiBot」再「启动 MaiBot」；仍失败看下面的日志"
      webui_log_tail "$LOG_FILE" 10
      ;;
    *)
      warn "MaiBot 未运行：点「启动 MaiBot」后再检测"
      ;;
  esac

  p=$(napcat_webui_port 2>/dev/null || true)
  if [ -n "$p" ]; then
    code=$(webui_http_code "http://127.0.0.1:$p/webui")
    if [ "$code" != "000" ]; then
      ok "NapCat WebUI 可打开（HTTP $code，端口 $p）"
    else
      warn "NapCat 端口 $p 已监听，但 HTTP 无响应（HTTP $code）"
      info "NapCat 可能还在启动或 QQ 尚未登录"
    fi
  elif napcat_running; then
    warn "NapCat 进程在（WS 端口 $NAPCAT_WS_PORT），但 WebUI 未监听（6099-6199）"
    info "在 App 点「停止 NapCat」再「启动 NapCat」，等扫码界面出现"
    webui_log_tail "$NAPCAT_LOG" 10
  else
    warn "NapCat 未运行：先「启动 NapCat」并扫码登录 QQ"
  fi
  return 0
}

# 打不开时的一次性排查：端口、进程、日志、适配器一起看
doctor() {
  say ""
  say "${BOLD}===== 连接诊断 =====${NC}"
  have curl && info "curl：可用" || warn "curl：不可用（HTTP 检测已改用 /dev/tcp 兜底）"
  info "容器内 HOME：$HOME"
  say ""
  say "--- MaiBot ---"
  # live=里面真的有进程；dead=进程早退了只剩空壳（旧版本会误判成"在运行"）；none=没有
  info "screen 会话 $SCREEN_NAME：$(screen_session_state "$SCREEN_NAME")"
  info "守护会话 maibot-watchdog：$(screen_session_state maibot-watchdog)"
  info "bot.py 进程：$(maibot_process_running && echo 有 || echo 无)"
  info "8001 端口：$(maibot_port_open && echo 已监听 || echo 未监听)"
  info "虚拟环境 .venv：$([ -x "$BOT_DIR/.venv/bin/python" ] && echo 已就绪 || echo 缺失)"
  info "uv：$(uv --version 2>/dev/null || echo 不可用)"
  info "首次配置 data/webui.json：$([ -f "$BOT_DIR/data/webui.json" ] && echo 已有 || echo 缺失，首次成功启动后自动生成)"
  if maibot_port_open; then
    info "HTTP 状态码：$(webui_http_code 'http://127.0.0.1:8001/')"
  fi
  if [ -f "$LOG_FILE" ]; then
    info "日志：${LOG_FILE}（$(wc -l < "$LOG_FILE" 2>/dev/null | tr -d ' ') 行，最后写入 $(date -r "$LOG_FILE" '+%m-%d %H:%M' 2>/dev/null || echo 未知)）"
  else
    info "日志：${LOG_FILE}（文件不存在）"
  fi
  webui_log_tail "$LOG_FILE" 15
  say ""
  say "--- NapCat ---"
  info "screen 会话 $NAPCAT_SCREEN：$(screen_session_state "$NAPCAT_SCREEN")"
  info "Xvfb 会话 $XVFB_SCREEN：$(screen_session_state "$XVFB_SCREEN")"
  info "QQ 进程：$(qq_process_running && echo 有 || echo 无)"
  info "Xvfb 显示 :1：$(xvfb_running && echo 有 || echo 无)"
  info "相关进程（最多 6 行）："
  ps -ef 2>/dev/null | grep -E 'qq|Xvfb|bot\.py' | grep -v grep | head -6 | while IFS= read -r l; do info "$l"; done
  local open_ports="" p
  for p in $(seq 6099 6199); do
    napcat_port_open "$p" && open_ports="$open_ports $p"
  done
  [ -n "$open_ports" ] && info "WebUI 端口：$open_ports" || info "WebUI 端口：6099-6199 都没有监听"
  info "WS 端口 $NAPCAT_WS_PORT：$(napcat_port_open "$NAPCAT_WS_PORT" && echo 已监听 || echo 未监听)"
  info "日志：${NAPCAT_LOG}"
  webui_log_tail "$NAPCAT_LOG" 15
  # QQ 是 Electron：/dev/shm 不可用时会静默崩在启动阶段，这里直接给出证据
  info "/dev/shm：$(ls -ld /dev/shm 2>/dev/null || echo 不存在)｜可用空间 $(df -h /dev/shm 2>/dev/null | tail -1 | awk '{print $4}' || echo 未知)"
  info "内存（MB）：$(free -m 2>/dev/null | sed -n '2p' | tr -s ' ' || echo 未知)"
  say "  -- QQ 现场证据（preload 之后静默退出时看这里）--"
  local qqver qqbuild
  if [ -f /opt/QQ/resources/app/package.json ] && have jq; then
    qqver=$(jq -r '.version // empty' /opt/QQ/resources/app/package.json 2>/dev/null)
    info "QQ 版本：${qqver:-未知}"
  fi
  if qqbuild=$(qq_build_version); then
    if [ "$qqbuild" -lt 40768 ]; then
      warn "QQ 构建号 $qqbuild 低于 NapCat 官方要求的 40768（推荐 3.2.34-53644）→ 建议重装 NapCat/QQ"
    else
      info "QQ 构建号：$qqbuild"
    fi
  fi
  info "X 锁残留：$([ -e /tmp/.X1-lock ] && echo 有（会挡住 Xvfb 启动，已自动清理）|| echo 无)｜/tmp/.X11-unix：$(ls /tmp/.X11-unix 2>/dev/null | tr '\n' ' ' || echo 无)"
  [ -f "$XVFB_LOG" ] && { info "Xvfb 日志末尾："; webui_log_tail "$XVFB_LOG" 5; }
  local missing=""
  for f in /opt/QQ/qq /opt/QQ/resources/app/wrapper.node; do
    [ -f "$f" ] || continue
    missing="$missing$(ldd "$f" 2>/dev/null | grep 'not found' | awk '{print $1}' | tr '\n' ' ')"
  done
  [ -n "$missing" ] && warn "缺失动态库：$missing（QQ 会在启动阶段直接崩，需要补依赖）" || info "动态库：/opt/QQ 依赖完整"
  [ -d "$HOME/.config/QQ/crash_files" ] && info "崩溃转储：$(ls -t "$HOME/.config/QQ/crash_files" 2>/dev/null | head -3 | tr '\n' ' ')"
  say ""
  say "--- 为什么会变成这样 ---"
  # Dead 会话 = 进程早就退了，只剩空壳；这正是"以前能用、现在不动"的典型现场
  local dead=0
  screen -ls 2>/dev/null | grep -q 'Dead' && dead=1
  screen -ls 2>/dev/null | while IFS= read -r l; do info "$l"; done
  [ "$dead" = 1 ] && warn "有 Dead 会话：进程早已退出，只剩空壳（旧版本会把它当成'运行中'，于是点「启动」没反应）"
  if [ -x "$BOT_DIR/.venv/bin/python" ]; then
    info "venv Python：$("$BOT_DIR/.venv/bin/python" -V 2>&1)"
  else
    warn "venv Python：缺失（依赖没装好，点「修复依赖」重建）"
  fi
  if [ -f "$BOT_DIR/uv.lock" ] && [ -d "$BOT_DIR/.venv" ] && [ "$BOT_DIR/uv.lock" -nt "$BOT_DIR/.venv" ]; then
    warn "uv.lock 比 .venv 新：依赖很可能没同步完 → 点「修复依赖」"
  fi
  [ -f "$BOT_DIR/.git/FETCH_HEAD" ] && info "最近一次更新代码：$(date -r "$BOT_DIR/.git/FETCH_HEAD" '+%Y-%m-%d %H:%M' 2>/dev/null || echo 未知)"
  info "NapCat 目录：$([ -d "$NAPCAT_DIR" ] && echo 存在 || echo 缺失)"
  info "QQ 程序 /opt/QQ/qq：$([ -x /opt/QQ/qq ] && echo 存在 || echo 缺失)"
  info "NapCat 注入的启动器：$(grep -c 'napcat\.mjs' /opt/QQ/resources/app/app_launcher/index.js 2>/dev/null | tr -d ' ') 处引用（0=没注入成功，重装 NapCat）"
  info "磁盘：$(df -h /root 2>/dev/null | tail -1)"
  say ""
  say "--- 镜像连通性（决定依赖/安装包能不能下载）---"
  mirror_alive "$DEBIAN_MIRROR/dists/bookworm/Release" && ok "Debian 源可用：$DEBIAN_MIRROR" || warn "Debian 源不可达：$DEBIAN_MIRROR"
  mirror_alive "$PY_INDEX_URL/pip/" && ok "PyPI 源可用：$PY_INDEX_URL" || warn "PyPI 源不可达：$PY_INDEX_URL"
  info "完整测速：Termux 菜单 27，或 bash ~/maibot-onekey.sh mirrors"
  say ""
  say "--- 适配器 ---"
  adapter_status
  say ""
  info "结论：MaiBot 需要「8001 已监听」，NapCat 需要「WebUI 端口已监听 + 3001 已监听」"
  if [ "$(screen_session_state "$SCREEN_NAME")" = dead ] || [ "$(screen_session_state "$NAPCAT_SCREEN")" = dead ]; then
    info "行动建议：直接点「启动 MaiBot」/「启动 NapCat」即可，新版会自动清掉这些空壳会话再启动"
  fi
  if grep -q 'QQ 进程已退出' "$NAPCAT_LOG" 2>/dev/null; then
    info "NapCat 日志里有 QQ 退出码：139=段错误，137=内存不足/被杀，可据此判断崩溃原因"
  fi
  return 0
}

logs() {
  if [ ! -f "$LOG_FILE" ]; then
    warn "日志文件不存在"
    return 1
  fi
  if [ "${MAIBOT_QUERY:-0}" = 1 ]; then
    tail -n 80 "$LOG_FILE"
  else
    tail -n 30 -f "$LOG_FILE"
  fi
}

token() {
  if [ -f "$BOT_DIR/data/webui.json" ]; then
    have jq && jq -r '.access_token' "$BOT_DIR/data/webui.json" || grep -o '"access_token"[^,]*' "$BOT_DIR/data/webui.json"
  else
    err "未找到 data/webui.json（尚未启动过）"
  fi
}

napcat_check() {
  say ""
  say "${BOLD}===== NapCat 检查 =====${NC}"
  [ -d "$NAPCAT_DIR" ] && ok "NapCat 目录" || warn "NapCat 未装（napcat-install）"
  [ -f "/opt/QQ/qq" ] && ok "Linux QQ" || warn "Linux QQ 未装"
  [ -f "$NAPCAT_ENV" ] && ok "QQ 号：$(grep ACCOUNT "$NAPCAT_ENV" | cut -d= -f2)" || warn "未配置 QQ 号（napcat-setup）"
  napcat_running && ok "NapCat 运行中" || warn "NapCat 未运行"
}

napcat_install() {
  STEP_ALL=4
  STEP_NO=0
  say "${BOLD}===== 开始安装 NapCat =====${NC}"

  step "系统依赖（含 Xvfb 虚拟显示，体积较大）"
  fix_debian_mirror
  apt_install libnss3 libnotify4 libsecret-1-0 libgbm1 libasound2 \
    fonts-wqy-zenhei gnutls-bin libglib2.0-dev libdbus-1-3 libgtk-3-0 \
    libxss1 libxtst6 libatspi2.0-0 libx11-xcb1 ffmpeg unzip jq curl xvfb \
    xauth libgssapi-krb5-2 libatk1.0-0 \
    || { err "依赖安装失败，可重试（已下载部分会复用）"; return 1; }

  step "安装 Linux QQ"
  # NapCat 要求 QQ 构建号 >= 40768：装得太旧会在启动阶段静默崩，所以旧版自动重装。
  local qq_build="" need_qq=0
  if [ ! -f "/opt/QQ/qq" ]; then
    need_qq=1
  elif [ "${MAIBOT_QQ_REINSTALL:-0}" = "1" ]; then
    need_qq=1
  elif qq_build=$(qq_build_version) && [ "$qq_build" -lt "$QQ_MIN_BUILD" ]; then
    warn "已安装的 QQ 构建号 $qq_build 低于 NapCat 要求的 $QQ_MIN_BUILD，自动重装"
    need_qq=1
  else
    ok "Linux QQ 已安装（构建号 ${qq_build:-未知}），跳过"
  fi
  if [ "$need_qq" = "1" ]; then
    # 候选顺序（2026-10 实测）：
    #   1) qqdl.gtimg.cn 的 3.2.34-53644 —— NapCat 官方安装器钉住的版本，实测可达
    #   2) im.qq.com 动态解析出的地址 —— 官方页面的地址可能已 404（如 3.2.18）
    #   3) Rodert/qq-versions 归档的最新 arm64 deb（带 SHA-256 校验）
    #   4) 归档固定包（API 不可达时）
    local official_url release_json asset_url asset_name expected_sum actual_sum
    official_url=$(curl -fsSL --connect-timeout 12 --max-time 25 \
      "https://im.qq.com/rainbow/linuxQQDownload" 2>/dev/null \
      | grep -oE 'https://dldir1[^" ]*arm64_01\.deb' | head -1)
    info "QQ 首选：$LINUXQQ_URL（NapCat 要求构建号 >= $QQ_MIN_BUILD）"
    [ -n "$official_url" ] && info "QQ 官方页面候选：$official_url"

    release_json=$(curl -fsSL --connect-timeout 12 --max-time 25 \
      "https://api.github.com/repos/Rodert/qq-versions/releases/latest" 2>/dev/null || true)
    [ -n "$release_json" ] || release_json=$(curl -fsSL --connect-timeout 12 --max-time 25 \
      "${GITHUB_PROXY}https://api.github.com/repos/Rodert/qq-versions/releases/latest" 2>/dev/null || true)
    # API 不可达时仍保留一份已核验的归档候选及其 SHA-256。
    asset_name=$(printf '%s' "$release_json" | jq -r '.assets[]? | select(.name | test("_arm64_01\\.deb$")) | .name' 2>/dev/null | head -1)
    if [ -n "$asset_name" ]; then
      asset_url=$(printf '%s' "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name == $n) | .browser_download_url' 2>/dev/null | head -1)
      info "QQ 归档最新备用包：$asset_name"
    else
      asset_name="QQ_3.2.32_260812_arm64_01.deb"
      asset_url="https://github.com/Rodert/qq-versions/releases/download/qq-packages-20260813-1d08f1d4/$asset_name"
      warn "GitHub API 不可用，使用已校验的固定备用包：$asset_name"
    fi

    # 按顺序尝试：首选官方 3.2.34（无公开摘要，靠 deb 格式与构建号校验）
    # → 官方页面地址 / 归档包 / 归档包走 GitHub 代理（归档包有摘要时校验 SHA-256）
    local qq_src="preferred"
    if ! dl /tmp/linuxqq.deb "$LINUXQQ_URL"; then
      qq_src="archive"
      warn "首选 QQ 包不可达，改用官方页面地址与 GitHub 归档 ..."
      if ! dl /tmp/linuxqq.deb "$official_url" "$asset_url" "${GITHUB_PROXY}${asset_url}"; then
        err "QQ 官方 CDN 与 GitHub 归档都不可达。请检查手机的代理/VPN 是否覆盖 Termux 流量"
        return 1
      fi
    fi
    if ! ar t /tmp/linuxqq.deb >/dev/null 2>&1; then
      err "下载结果不是有效的 Debian 安装包（可能是代理错误页），拒绝安装"
      rm -f /tmp/linuxqq.deb
      return 1
    fi
    if [ "$qq_src" = "archive" ] && [ -n "$asset_name" ]; then
      expected_sum=$(printf '%s' "$release_json" | jq -r --arg n "$asset_name" '.body // "" | split("\\n")[] | select(test("`" + $n + "`")) | match("[0-9a-f]{64}").string' 2>/dev/null | head -1)
      [ -n "$expected_sum" ] || [ "$asset_name" != "QQ_3.2.32_260812_arm64_01.deb" ] || expected_sum="8796ccfd66acc025ef18db37185532d40bc8c58921e17da6d28c295acbcf8f92"
      # 只有下载的确实是归档里那个包时才校验摘要，否则会把"官方页面地址"下载的包误判为校验失败
      expected_size=$(printf '%s' "$release_json" | jq -r --arg n "$asset_name" '.assets[]? | select(.name == $n) | .size' 2>/dev/null | head -1)
      actual_size=$(stat -c %s /tmp/linuxqq.deb 2>/dev/null || echo 0)
      if [ -n "$expected_sum" ] && [ -n "$expected_size" ] && [ "$expected_size" != "$actual_size" ]; then
        info "本次下载来自其它来源（$actual_size 字节 ≠ 归档 $expected_size 字节），跳过归档摘要校验"
        expected_sum=""
      fi
      if [ -n "$expected_sum" ]; then
        actual_sum=$(sha256sum /tmp/linuxqq.deb | awk '{print $1}')
        if [ "$expected_sum" != "$actual_sum" ]; then
          err "QQ 安装包 SHA-256 校验失败，已拒绝安装"
          rm -f /tmp/linuxqq.deb
          return 1
        fi
        ok "QQ 安装包 SHA-256 校验通过"
      else
        warn "该来源没有提供文件摘要，只通过 deb 格式与构建号检查"
      fi
    fi
    info "安装 Linux QQ 包 ..."
    if run_logged dpkg -i --force-depends /tmp/linuxqq.deb; then
      ok "Linux QQ 安装完成"
    else
      warn "dpkg 有警告，尝试补齐依赖 ..."
      run_logged apt-get install -y -f || { err "Linux QQ 依赖修复失败"; return 1; }
      [ -f "/opt/QQ/qq" ] || { err "Linux QQ 安装失败"; return 1; }
      ok "Linux QQ 安装完成（已补齐依赖）"
    fi
    rm -f /tmp/linuxqq.deb
    # dpkg -i --force-depends 会跳过依赖：缺库时 QQ 会在启动阶段静默崩掉，
    # 所以这里立刻检查一次，把问题在安装阶段就暴露出来。
    local misslib=""
    for f in /opt/QQ/qq /opt/QQ/resources/app/wrapper.node; do
      [ -f "$f" ] || continue
      misslib="$misslib$(ldd "$f" 2>/dev/null | grep 'not found' | awk '{print $1}' | tr '\n' ' ')"
    done
    if [ -n "$misslib" ]; then
      warn "QQ 仍缺少动态库：$misslib"
      info "已在尝试补齐：apt-get install -y -f"
      run_logged apt-get install -y -f || warn "补依赖失败，可稍后重试"
    else
      ok "QQ 动态库完整"
    fi
  fi

  step "下载 NapCat（带进度条）"
  if [ -f "$NAPCAT_DIR/napcat.mjs" ]; then
    ok "NapCat 已存在，跳过下载"
  else
    mkdir -p "$NAPCAT_DIR"
    local ver=""
    info "查询 NapCat 最新版本 ..."
    # 国内直连 api.github.com 经常失败，再走一次 GitHub 代理；都失败才用固定版本
    ver=$(curl -s --connect-timeout 12 --max-time 20 "https://api.github.com/repos/NapNeko/NapCatQQ/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')
    if [ -z "$ver" ]; then
      info "直连 GitHub API 失败，改用代理查询 ..."
      ver=$(curl -s --connect-timeout 12 --max-time 25 "${GITHUB_PROXY}https://api.github.com/repos/NapNeko/NapCatQQ/releases/latest" 2>/dev/null | jq -r '.tag_name // empty')
    fi
    if [ -z "$ver" ]; then
      warn "无法获取最新版本号，改用已知可用版本：$NAPCAT_FALLBACK_VERSION"
      ver="$NAPCAT_FALLBACK_VERSION"
    fi
    info "目标版本：$ver"
    # 直连 GitHub 优先；失败再走代理（gh-proxy.org / ghfast.top 已实测失效）
    dl /tmp/NapCat.Shell.zip \
      "https://github.com/NapNeko/NapCatQQ/releases/download/$ver/NapCat.Shell.zip" \
      "${GITHUB_PROXY}https://github.com/NapNeko/NapCatQQ/releases/download/$ver/NapCat.Shell.zip" \
      || return 1
    info "解压 NapCat ..."
    mkdir -p "$NAPCAT_DIR"
    if ! run_logged unzip -o /tmp/NapCat.Shell.zip -d "$NAPCAT_DIR"; then
      err "解压失败（下载文件可能不完整，请重试）"
      rm -rf "$NAPCAT_DIR"
      return 1
    fi
    rm -f /tmp/NapCat.Shell.zip
    chmod +x "$NAPCAT_DIR"/*.sh 2>/dev/null
    ok "NapCat 解压完成"
  fi

  # If the user already entered QQ before installation, generate its server configs now.
  if [ -f "$NAPCAT_ENV" ]; then
    local saved_qq
    saved_qq=$(sed -n 's/^ACCOUNT=//p' "$NAPCAT_ENV" | head -1)
    if [ -n "$saved_qq" ]; then
      napcat_setup "$saved_qq" || return 1
    fi
  fi

  step "注入 NapCat 到 QQ 启动器"
  local launcher="/opt/QQ/resources/app/app_launcher"
  if [ -d "$launcher" ]; then
    echo "(async () => {await import('file://$NAPCAT_DIR/napcat.mjs');})();" > "$launcher/index.js"
    ok "NapCat 已注入"
  else
    err "未找到 $launcher，注入失败（QQ 可能未正确安装）"
    return 1
  fi

  say ""
  ok "NapCat 安装完成"
  info "下一步：bash $0 napcat-setup <QQ号>"
  return 0
}

napcat_setup() {
  [ -d "$NAPCAT_DIR" ] || { err "NapCat 未装，先 napcat-install"; return 1; }
  local qq="${1:-}"
  [ -z "$qq" ] && { printf '请输入机器人 QQ 号：'; read -r qq; }
  # QQ 号会被拼进文件名和 JSON：必须只允许数字，否则可造成路径穿越/配置损坏
  case "$qq" in
    ''|*[!0-9]*) err "QQ 号只能是纯数字（收到：$qq）"; return 1 ;;
  esac
  if [ "${#qq}" -lt 5 ] || [ "${#qq}" -gt 15 ]; then
    err "QQ 号位数不正确（应为 5-15 位数字）"
    return 1
  fi
  mkdir -p "$NAPCAT_DIR/config"
  echo "ACCOUNT=$qq" > "$NAPCAT_ENV"
  chmod 600 "$NAPCAT_ENV" 2>/dev/null || true
  # 配置可在 NapCat 下载前生成；NapCat 安装后会直接复用。
  cat > "$NAPCAT_DIR/config/onebot11_$qq.json" <<EOF
{
  "network": {
    "httpServers": [],
    "httpClients": [],
    "websocketServers": [{
      "name": "MaiBot",
      "enable": true,
      "host": "127.0.0.1",
      "port": $NAPCAT_WS_PORT,
      "messagePostFormat": "array",
      "reportSelfMessage": false,
      "token": "",
      "enableForcePushEvent": true,
      "debug": false,
      "heartInterval": 30000
    }],
    "websocketClients": []
  },
  "musicSignUrl": "",
  "enableLocalFile2Url": true,
  "parseMultMsg": false
}
EOF
  # NapCat Shell reads the config under QQ's app_launcher; keep a local copy too.
  local launcher_cfg_dir="/opt/QQ/resources/app/app_launcher/napcat/config"
  if [ -d "/opt/QQ/resources/app/app_launcher/napcat" ]; then
    mkdir -p "$launcher_cfg_dir"
    cp -f "$NAPCAT_DIR/config/onebot11_$qq.json" "$launcher_cfg_dir/onebot11_$qq.json"
  fi
  # WebUI config path in Shell install; loopback host is intentionally local-only.
  local webui_cfg="$NAPCAT_DIR/config/webui.json" webui_token
  mkdir -p "$(dirname "$webui_cfg")"
  if [ ! -s "$webui_cfg" ]; then
    webui_token=$(od -An -N24 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$webui_token" ] || webui_token="$(date +%s)$RANDOM$RANDOM"
    cat > "$webui_cfg" <<EOF
{
  "host": "127.0.0.1",
  "port": 6099,
  "token": "$webui_token",
  "loginRate": 3
}
EOF
    chmod 600 "$webui_cfg" 2>/dev/null || true
  fi
  if [ -d "/opt/QQ/resources/app/app_launcher/napcat" ]; then
    cp -f "$webui_cfg" "/opt/QQ/resources/app/app_launcher/napcat/config/webui.json"
    chmod 600 "/opt/QQ/resources/app/app_launcher/napcat/config/webui.json" 2>/dev/null || true
  fi
  ok "已预配置正向 WebSocket：ws://127.0.0.1:$NAPCAT_WS_PORT（仅本机）"
  info "QQ 号已记录：$qq（NapCat 登录的 QQ 必须与它一致）"
  info "适配器不用旧 NapCat 适配器（已归档），装官方「统一 QQ 连接器」："
  info "  MaiBot WebUI → 插件管理 → 从 Git 安装：https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter"
  info "装好后回到 App 点「一键配置适配器」，会自动写入 127.0.0.1:$NAPCAT_WS_PORT 与 qq_account"
  info "NapCat WebUI：127.0.0.1:6099（随机 Token，仅本机访问）"
}

# QQ 的进程名/参数在不同版本里不一样，宽松匹配，避免把活着的 QQ 判成"没进程"。
qq_process_running() {
  pgrep -f 'QQ/qq' >/dev/null 2>&1 \
    || pgrep -f 'qq --no-sandbox' >/dev/null 2>&1 \
    || pgrep -x qq >/dev/null 2>&1
}

xvfb_running() {
  pgrep -f 'Xvfb :1' >/dev/null 2>&1
}

XVFB_LOG="$HOME/xvfb.log"

# Xvfb 用独立会话常驻：QQ 崩了它还在，重新启动 NapCat 时不用再等显示就绪。
# 崩过之后 /tmp/.X1-lock 会残留，不清掉 Xvfb 会直接拒绝启动（这是"以前能用、
# 现在显示起不来"的常见原因）。
ensure_xvfb() {
  xvfb_running && return 0
  rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
  screen_drop "$XVFB_SCREEN"
  screen -dmS "$XVFB_SCREEN" bash -c "ulimit -c 0 2>/dev/null; Xvfb :1 -screen 0 1080x760x16 +extension GLX +render > '$XVFB_LOG' 2>&1"
  local waited=0
  while [ "$waited" -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
    xvfb_running && { ok "虚拟显示 Xvfb :1 已就绪"; return 0; }
  done
  warn "Xvfb :1 没能起来（QQ 需要它才能显示扫码界面），日志末尾："
  webui_log_tail "$XVFB_LOG" 8
  return 1
}

# QQ 版本：NapCat 官方要求最低构建号 40768，过旧的 QQ 会在启动阶段静默崩。
qq_build_version() {
  local f="/opt/QQ/resources/app/package.json" v=""
  [ -f "$f" ] || return 1
  if have jq; then
    v=$(jq -r '.buildVersion // empty' "$f" 2>/dev/null)
  else
    v=$(sed -n 's/.*"buildVersion"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]\+\)"\{0,1\}.*/\1/p' "$f" 2>/dev/null | head -1)
  fi
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}

napcat_start() {
  [ -d "$NAPCAT_DIR" ] || { err "NapCat 未装"; return 1; }
  [ -f "$NAPCAT_ENV" ] || { warn "先 napcat-setup <QQ号>"; return 1; }
  [ -f "$NAPCAT_DIR/napcat.mjs" ] || { err "NapCat 文件不完整，先点「安装 NapCat」"; return 1; }
  source "$NAPCAT_ENV"
  # 端口在监听 = 真的活着，直接返回，别把正在登录的 QQ 踢掉。
  if napcat_port_open 6099 || napcat_port_open "$NAPCAT_WS_PORT"; then
    warn "NapCat 已在运行"
    return 0
  fi
  if qq_process_running; then
    warn "QQ 进程在，但 WebUI 端口（6099）和 WS 端口（$NAPCAT_WS_PORT）都没监听"
    info "可能还在启动或已卡死：等 30 秒再点一次；仍不行先「停止 NapCat」再启动"
    return 1
  fi
  # 会话在、进程没了（手机/容器重启后最常见的空壳）→ 清掉再来，
  # 否则旧版本会一直认为"NapCat 已在运行"。
  screen_wipe_dead
  screen_drop "$NAPCAT_SCREEN"
  ensure_xvfb || true
  cat > "$NAPCAT_DIR/start_qq.sh" <<EOF
#!/usr/bin/env bash
export DISPLAY=:1
export LANG=zh_CN.UTF-8
# 崩溃时可能写出巨大的 core，手机存储会被写满（NapCat issue #2060）
ulimit -c 0 2>/dev/null || true
# ELECTRON_ENABLE_LOGGING：Electron/Chromium 自己的报错也进日志，
# 否则"preload 之后什么都不打印"就永远查不出原因
export ELECTRON_ENABLE_LOGGING=1
cd "$NAPCAT_DIR" || exit 1
QQBIN="\$(command -v qq || echo /opt/QQ/qq)"
echo "[\$(date '+%F %T')] 启动 QQ：\$QQBIN $QQ_LAUNCH_FLAGS -q $ACCOUNT（DISPLAY=\$DISPLAY）" | tee -a "$NAPCAT_LOG"
"\$QQBIN" $QQ_LAUNCH_FLAGS -q "$ACCOUNT" 2>&1 | tee -a "$NAPCAT_LOG"
rc=\${PIPESTATUS[0]}
sig=""
[ "\$rc" -gt 128 ] 2>/dev/null && sig="（被信号 \$((rc - 128)) 杀死）"
echo "[\$(date '+%F %T')] QQ 进程已退出，退出码 \$rc\$sig；139/134/132=原生崩溃，137=内存不足被杀，1=普通报错" | tee -a "$NAPCAT_LOG"
EOF
  chmod +x "$NAPCAT_DIR/start_qq.sh"
  : > "$NAPCAT_LOG" 2>/dev/null || true
  sync_napcat_config
  screen -dmS "$NAPCAT_SCREEN" "$NAPCAT_DIR/start_qq.sh"
  local waited=0 webui_port="" seen=0
  while [ "$waited" -lt 60 ]; do
    sleep 1
    waited=$((waited + 1))
    webui_port=$(napcat_webui_port 2>/dev/null || true)
    [ -n "$webui_port" ] && break
    if qq_process_running; then
      seen=1
    elif [ "$seen" = 1 ]; then
      # QQ 起来过又没了：不用再等，日志里已经有退出码
      break
    fi
  done
  if [ -n "$webui_port" ]; then
    ok "NapCat 已启动，WebUI 端口：$webui_port"
    info "扫码：bash $0 napcat-webui"
    return 0
  fi
  err "NapCat 没能起来（WebUI 未监听），日志末尾："
  webui_log_tail "$NAPCAT_LOG" 25
  info "排查顺序：① 看日志里的「QQ 进程已退出，退出码」 ② 「安装 NapCat」重装依赖 ③ 执行 doctor 把输出发出来"
  return 1
}

# 停 NapCat 本体（区分开：它不打印成功信息，方便内部复用）
napcat_stop_core() {
  screen_drop "$NAPCAT_SCREEN"
  pkill -f "QQ/qq" 2>/dev/null || true
  pkill -f "qq --no-sandbox" 2>/dev/null || true
  pkill -x qq 2>/dev/null || true
  screen_drop "$XVFB_SCREEN"
  pkill -f "Xvfb :1" 2>/dev/null || true
  screen_wipe_dead
  return 0
}

napcat_stop() {
  if ! napcat_running; then
    warn "NapCat 未运行"
    screen_wipe_dead
    return 0
  fi
  napcat_stop_core
  ok "NapCat 已停止"
}

napcat_status() {
  say ""
  local p
  p=$(napcat_webui_port 2>/dev/null || true)
  if [ -n "$p" ]; then
    ok "NapCat 运行中（$NAPCAT_SCREEN） WebUI端口 $p WS端口 $NAPCAT_WS_PORT"
  elif napcat_running; then
    warn "NapCat 进程运行中，但 WebUI 端口未监听"
  else
    warn "NapCat 未运行"
  fi
}

napcat_webui() {
  local port cfg token url log_url code
  port=$(napcat_webui_port 2>/dev/null || true)
  if [ -z "$port" ]; then
    if napcat_running; then
      warn "NapCat 进程在，但 WebUI 没有监听（已检查 6099-6199）"
      info "NapCat 可能还没启动完，或者 WebUI 配置没被读取"
      info "先在 App 点「停止 NapCat」再「启动 NapCat」，等扫码界面出现"
    else
      warn "NapCat 未运行：先点「启动 NapCat」并扫码登录 QQ"
    fi
    webui_log_tail "$NAPCAT_LOG" 20
    printf 'WEBUI_UNAVAILABLE=1\n'
    return 0
  fi
  # NapCat Shell 的 config 目录位于启动器目录；也检查本脚本独立 NapCat 目录。
  cfg="/opt/QQ/resources/app/app_launcher/napcat/config/webui.json"
  [ -f "$cfg" ] || cfg="$NAPCAT_DIR/config/webui.json"
  token=""
  if [ -f "$cfg" ]; then
    if have jq; then
      token=$(jq -r '.token // .access_token // empty' "$cfg" 2>/dev/null)
    else
      # 容器里不一定装了 jq：用 sed 兜底读取 token，避免只能打开无 Token 的登录页。
      token=$(sed -n 's/.*"\(token\|access_token\)"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\2/p' "$cfg" 2>/dev/null | head -1)
    fi
  fi
  case "$token" in null) token="" ;; esac
  log_url=$(napcat_log_url 2>/dev/null || true)
  if [ -n "$log_url" ]; then
    url="$log_url"
    info "已从 NapCat 日志读取实际 WebUI 地址"
  elif [ -n "$token" ]; then
    url="http://127.0.0.1:$port/webui?token=$token"
  else
    url="http://127.0.0.1:$port/webui/"
    warn "未找到 WebUI Token；打开登录页后从 NapCat 日志确认 Token"
  fi
  code=$(webui_http_code "http://127.0.0.1:$port/webui")
  if [ "$code" = "000" ]; then
    # 端口确实在监听，就把地址交出去：可能只是还没准备好，浏览器能给出真实结果。
    warn "NapCat 端口 $port 已监听，但 HTTP 检测没通过（HTTP $code）"
    info "通常是在启动中或 QQ 还没登录，等一会儿再点一次"
  else
    ok "NapCat WebUI 可用（HTTP $code，端口 $port）"
  fi
  info "NapCat WebUI：$url"
  printf 'WEBUI_URL=%s\n' "$url"
}

# ---------- 适配器（统一 QQ 连接器）配置 ----------

# 在指定 TOML 节里设置一个键：存在则改值，不存在则补行，整节不存在则追加。
toml_set_key() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  [ -f "$file" ] || return 1
  tmp="$file.tmp.$$"
  awk -v sec="$section" -v key="$key" -v val="$value" '
    BEGIN { insec = 0; done = 0; found = 0 }
    /^[[:space:]]*\[/ {
      if (insec && !done) { print key " = " val; done = 1 }
      line = $0
      gsub(/^[[:space:]]+/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      insec = (line == "[" sec "]")
      if (insec) found = 1
      print
      next
    }
    {
      if (insec && $0 ~ ("^[[:space:]]*" key "[[:space:]]*=")) {
        if (!done) { print key " = " val; done = 1 }
        next
      }
      print
    }
    END {
      if (insec && !done) { print key " = " val }
      if (!found) { print ""; print "[" sec "]"; print key " = " val }
    }
  ' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

adapter_plugin_dir() {
  local d
  for d in "$BOT_DIR/plugins/MaiBot-SnowLuma-Adapter" "$BOT_DIR/plugins/MaiBot-Napcat-Adapter"; do
    [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
  done
  for d in "$BOT_DIR"/plugins/*/; do
    [ -f "$d/_manifest.json" ] || continue
    grep -qiE '"(id|name)"[[:space:]]*:[[:space:]]*"[^"]*(snowluma|napcat)[^"]*"' "$d/_manifest.json" 2>/dev/null \
      && { printf '%s\n' "${d%/}"; return 0; }
  done
  return 1
}

# 把 bot_config.toml 的机器人账号 + 适配器连接参数一次配好
adapter_setup() {
  local qq="${1:-}"
  case "$qq" in
    ''|*[!0-9]*) err "QQ 号只能是纯数字（收到：${qq:-空}）"; return 1 ;;
  esac
  if [ "${#qq}" -lt 5 ] || [ "${#qq}" -gt 15 ]; then
    err "QQ 号位数不正确（应为 5-15 位数字）"; return 1
  fi
  [ -d "$BOT_DIR" ] || { err "MaiBot 尚未部署，先执行 install"; return 1; }

  say ""
  say "${BOLD}===== 配置适配器连接 =====${NC}"
  local bot_cfg="$BOT_DIR/config/bot_config.toml"
  if [ -f "$bot_cfg" ]; then
    cp -f "$bot_cfg" "$bot_cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    toml_set_key "$bot_cfg" bot platform '"qq"'
    toml_set_key "$bot_cfg" bot qq_account "\"$qq\""
    ok "bot_config.toml：platform=qq，qq_account=$qq"
  else
    warn "未找到 config/bot_config.toml：先启动一次 MaiBot 生成配置，再回来点这里"
  fi

  local plugdir=""
  if plugdir=$(adapter_plugin_dir); then
    local cfg="$plugdir/config.toml"
    if [ ! -f "$cfg" ]; then
      cat > "$cfg" <<'ADAPTER_EOF'
[plugin]
enabled = true
qq_face_parse_mode = "description"
config_version = "2.5.0"

[client]
client_type = "auto"
server = "127.0.0.1"
port = 3001
token = ""
heartbeat_interval = 30.0
reconnect_delay_sec = 5.0
action_timeout_sec = 15.0
connection_id = ""

[chat_abilities]
enable_private_chat_tool = false
enable_poke_tool = false
enable_recall_tool = false
enable_mute_tool = false
enable_emoji_like_tool = false
enable_forward_tool = false

[notice]
enabled = true
enable_poke = true
enable_friend_recall = true
enable_group_recall = true
enable_group_ban = true
enable_group_msg_emoji_like = true
enable_group_upload = true
enable_group_increase = true
enable_group_decrease = true
enable_group_admin = true
enable_essence = true
enable_group_name = true

[filters]
ban_user_id = []
ban_qq_bot = false
regex_filter_enabled = false
regex_filter_mode = "blacklist"
regex_filter_patterns = []
regex_filter_show_dropped = false

[mute]
admin_users = []
allowed_groups = []
min_duration = 60
max_duration = 2592000

[debug]
enable_ada_debug_raw_message_log = false
enable_ada_debug_raw_outbound_message_log = false
ignore_self_message = false
ADAPTER_EOF
    else
      cp -f "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    toml_set_key "$cfg" plugin enabled true
    toml_set_key "$cfg" client client_type '"auto"'
    toml_set_key "$cfg" client server '"127.0.0.1"'
    toml_set_key "$cfg" client port "$NAPCAT_WS_PORT"
    grep -Eq '^[[:space:]]*token[[:space:]]*=' "$cfg" || toml_set_key "$cfg" client token '""'
    ok "适配器连接已写入：${cfg#$BOT_DIR/}"
    info "client_type=auto  server=127.0.0.1  port=$NAPCAT_WS_PORT"
  else
    warn "还没安装适配器插件，连接参数稍后自动写入"
    info "1) 先在 App 点「打开 MaiBot WebUI」"
    info "2) 左侧「插件管理」→ 从 Git 安装：https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter"
    info "3) 安装完成后回到 App，再点「一键配置适配器」"
  fi

  if napcat_port_open "$NAPCAT_WS_PORT"; then
    ok "NapCat 正向 WebSocket 端口 $NAPCAT_WS_PORT 已监听"
  else
    warn "NapCat 正向 WebSocket 端口 $NAPCAT_WS_PORT 未监听（启动 NapCat 后再试）"
  fi
  info "最后重启 MaiBot 使配置生效：点「停止 MaiBot」再点「启动 MaiBot」"
}

adapter_status() {
  say ""
  say "${BOLD}===== 适配器连接状态 =====${NC}"
  local plugdir="" cfg="" qq="" nap_qq="" port_ok="no"
  if plugdir=$(adapter_plugin_dir); then
    ok "适配器插件：${plugdir#$BOT_DIR/}"
    cfg="$plugdir/config.toml"
  else
    warn "适配器插件：未安装（MaiBot-SnowLuma-Adapter）"
  fi
  if [ -f "$BOT_DIR/config/bot_config.toml" ]; then
    # 必须先去掉行尾注释再取值：模板里 qq_account 后面常跟 "#..." 说明，
    # 直接取等号右侧会把注释当成 QQ 号（之前就误报成"两边 QQ 号不一致"）。
    qq=$(grep -E '^[[:space:]]*qq_account[[:space:]]*=' "$BOT_DIR/config/bot_config.toml" 2>/dev/null \
      | head -1 | cut -d= -f2 | sed 's/#.*//' | tr -d ' "'"'"'')
  fi
  [ -n "$qq" ] && ok "MaiBot qq_account：$qq" || warn "MaiBot qq_account：未设置（点「一键配置适配器」写入）"
  if [ -f "${NAPCAT_ENV:-}" ]; then
    nap_qq=$(grep -E '^[[:space:]]*ACCOUNT[[:space:]]*=' "$NAPCAT_ENV" 2>/dev/null | cut -d= -f2 | sed 's/#.*//' | tr -d ' "'"'"'')
  fi
  [ -n "$nap_qq" ] && ok "NapCat 登录 QQ：$nap_qq" || warn "NapCat 登录 QQ：未配置"
  if [ -n "$qq" ] && [ -n "$nap_qq" ] && [ "$qq" = "$nap_qq" ]; then
    ok "两边 QQ 号一致"
  elif [ -n "$qq" ] && [ -n "$nap_qq" ]; then
    warn "两边 QQ 号不一致，麦麦会把自己的消息当成别人"
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    if grep -Eq '^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true' "$cfg"; then
      ok "插件 enabled：true"
    else
      warn "插件 enabled 不是 true（不会建立连接）"
    fi
    local p
    p=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$cfg" | head -1 | cut -d= -f2 | tr -d ' ')
    [ -n "$p" ] && info "插件连接端口：$p" || warn "插件未写 port"
  fi
  napcat_port_open "$NAPCAT_WS_PORT" && { ok "NapCat WS 端口 $NAPCAT_WS_PORT：已监听"; port_ok="yes"; } \
    || warn "NapCat WS 端口 $NAPCAT_WS_PORT：未监听"
  if [ "$port_ok" = "yes" ] && [ -n "$plugdir" ]; then
    ok "链路就绪：QQ → NapCat → ws://127.0.0.1:$NAPCAT_WS_PORT → 适配器 → MaiBot"
  else
    info "链路未就绪，按上面的提示补齐（装插件 / 启动 NapCat / 配 QQ 号）"
  fi
}

# ---------- 服务器模式：全启 / 全停 / 自愈守护 ----------

allstart() {
  say ""
  say "${BOLD}===== 启动全部服务 =====${NC}"
  local rc=0
  if [ -f "$BOT_DIR/bot.py" ]; then
    start || rc=1
  else
    warn "MaiBot 尚未部署（缺 $BOT_DIR/bot.py），已跳过"
    info "请先在 App 点「按顺序安装：Debian → MaiBot」"
    rc=1
  fi
  if [ -f "$NAPCAT_ENV" ]; then
    napcat_start || rc=1
  else
    warn "NapCat 尚未配置 QQ 号，已跳过"
    info "请先执行 napcat-install，再 napcat-setup <QQ号>"
    rc=1
  fi
  return "$rc"
}

allstop() {
  say ""
  say "${BOLD}===== 停止全部服务 =====${NC}"
  stop
  napcat_stop
}

# 一键清理残留：手机重启、容器重装或 QQ/uv 崩过之后，screen 里常留下空壳会话，
# 或者有卡死的进程占着 .venv、端口。先清干净再启动，比反复点「启动」有效。
reset_sessions() {
  say ""
  say "${BOLD}===== 清理残留会话与进程 =====${NC}"
  stop_maibot
  napcat_stop_core
  screen_wipe_dead
  ok "已清理 MaiBot / NapCat / Xvfb 的会话与残留进程"
  info "接着点「启动 MaiBot」和「启动 NapCat」重新拉起即可"
}

watchdog() {
  local interval="${1:-60}"
  say ""
  info "守护进程运行中：每 ${interval} 秒检查一次，掉线自动拉起"
  local last_bot=0 last_nc=0 now
  while true; do
    now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$BOT_DIR/bot.py" ] && ! is_running; then
      if [ $((now - last_bot)) -ge 180 ]; then
        warn "$(date '+%m-%d %H:%M:%S') MaiBot 掉线，自动拉起"
        start
        last_bot=$now
      fi
    fi
    if [ -f "$NAPCAT_ENV" ] && ! napcat_running; then
      if [ $((now - last_nc)) -ge 180 ]; then
        warn "$(date '+%m-%d %H:%M:%S') NapCat 掉线，自动拉起"
        napcat_start
        last_nc=$now
      fi
    fi
    sleep "$interval"
  done
}

menu() {
  while true; do
    say ""
    say "${BOLD}===== MaiBot + NapCat 菜单 =====${NC}"
    say "  --- MaiBot ---"
    say "  1)检查 2)部署 3)更新 4)启动 5)前台 6)停止 7)重启 8)状态 9)日志 10)密钥"
    say "  --- NapCat ---"
    say "  11)检查 12)安装 13)配置QQ 14)启动 15)停止 16)状态 17)登录码"
    say "  --- 服务器模式 ---"
    say "  18)启动全部 19)停止全部"
    say "  --- 连接检查 ---"
    say "  20)检测WebUI 21)配置适配器 22)适配器状态 23)连接诊断 24)修复依赖 25)清理残留 26)重装QQ 27)镜像测速"
    say "  0)退出"
    printf '请输入 [0-27]：'
    read -r n
    case "$n" in
      1) check;; 2) install;; 3) update;; 4) start;; 5) fg_run;; 6) stop;;
      7) restart;; 8) status;; 9) logs;; 10) token;;
      11) napcat_check;; 12) napcat_install;; 13) napcat_setup "${2:-}";; 14) napcat_start;;
      15) napcat_stop;; 16) napcat_status;; 17) napcat_webui;;
      18) allstart;; 19) allstop;;
      20) webui_check;; 21) adapter_setup "${2:-}";; 22) adapter_status;; 23) doctor;; 24) fix_deps;;
      25) reset_sessions;; 26) MAIBOT_QQ_REINSTALL=1 napcat_install;; 27) mirrors_check;;
      0|q|Q) say "再见"; break;; *) warn "无效输入";;
    esac
  done
}

# ---- 容器层参数分发 ----
_MENU_RESULT=0
case "$RUN_ACTION" in
  check)          check ;;
  install)        install ;;
  update)         update ;;
  start)          start ;;
  fg)             fg_run ;;
  stop)           stop ;;
  restart)        restart ;;
  status)         status ;;
  logs)           logs ;;
  token)          token ;;
  allstart)       allstart ;;
  allstop)        allstop ;;
  wd|watchdog)    watchdog ;;
  napcat-install) napcat_install ;;
  napcat-qq)      MAIBOT_QQ_REINSTALL=1 napcat_install ;;
  napcat-setup)   napcat_setup "${2:-}" ;;
  napcat-start)   napcat_start ;;
  napcat-stop)    napcat_stop ;;
  napcat-status)  napcat_status ;;
  napcat-check)   napcat_check ;;
  napcat-webui)   napcat_webui ;;
  webui)          webui ;;
  webui-check)    webui_check ;;
  doctor)         doctor ;;
  fix-deps)       fix_deps ;;
  reset)          reset_sessions ;;
  mirrors)        mirrors_check ;;
  adapter-setup)  adapter_setup "${2:-}" ;;
  adapter-status) adapter_status ;;
  menu|"")        menu ;;
  *)              err "未知动作：$RUN_ACTION"; exit 2 ;;
esac
_MENU_RESULT=$?

# EXIT trap 统一完成通信文件（Termux setup/容器执行/提前失败均覆盖）。
exit "$_MENU_RESULT"