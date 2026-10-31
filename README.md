# MaiBot 一键部署（Android）

在安卓手机上用 **Termux + Debian 容器** 跑 [MaiBot](https://github.com/Mai-with-u/MaiBot) 与 [NapCat](https://github.com/NapNeko/NapCatQQ) 的控制台 App。

App 不重做 MaiBot 的网页界面，只负责：把环境装好、把服务拉起来、把 **MaiBot WebUI** 和 **NapCat WebUI** 用手机浏览器打开，并把 QQ 适配器接到 NapCat 上。

> v2.0.0 起移除了此前「在 App 内重做 WebUI」的实验方案（原生管理页 / 内嵌 WebView / 内置插件管理），恢复为 1.6.x 的单页布局并重新排版。
> v2.0.1 把界面上的「联系作者 QQ」换成项目主页入口，问题统一到仓库 Issues。
> v2.0.2 修复两个严重问题：`screen` 会话名改用精确匹配（此前守护会话 `.maibot-watchdog` 会被误判成 MaiBot 在运行，掩盖真正的故障）；HTTP 检测在没有 `curl` 时改用 `/dev/tcp` 兜底，且只要端口在监听就把地址交给浏览器，不再把可用 WebUI 误判成打不开。日志区从页面里移回独立底部面板，可单独滑动并自动跟随最新一行。
> v2.0.3 解决「MaiBot 会话在、8001 永远不监听」：`start` 先显式 `uv sync` 再用 `uv run --no-sync` 启动（此前 `uv run` 卡在 Building 阶段，日志只剩一行），启动后等待 8001 并在失败时打印日志；新增「修复依赖」按钮。NapCat 启动前确保 Xvfb 在、并区分「会话残留」与「QQ 真在跑」；连接诊断补充虚拟环境、uv、Xvfb 与真实进程列表；修正适配器状态把 `qq_account` 行尾注释当成 QQ 号的解析错误。
> v2.0.4 诊断增强：输出 `screen -ls` 原始内容并标出 **Dead 会话**（进程早已退出、只剩空壳，这是「以前能用、现在不动」的典型现场），检查 `.venv` 里的 Python 是否可用、`uv.lock` 是否比 `.venv` 新（说明依赖没同步完）、代码最后一次更新时间、NapCat / QQ 是否还在、剩余磁盘空间。依赖同步改为 **阿里云 → 清华 → 官方 PyPI** 依次回退。
> v2.0.5 修复「会话在、WebUI 打不开、点启动没反应」：**Dead 空壳会话不再算作"正在运行"**（旧版本会让「启动 MaiBot」「启动 NapCat」直接返回，守护和掉线重启也一起失效），启动前自动 `screen -wipe` 清理；MaiBot 改用 **虚拟环境解释器直接启动**（不再 `uv run`，避免每次都卡在 `Building maibot @ ...`）；NapCat 的 Xvfb 改为独立会话常驻，启动前清理 `/tmp/.X1-lock`，`ulimit -c 0` 防止 core 写满存储，并在日志里记录 **QQ 真实退出码/信号**（139 段错误、137 内存不足）；诊断新增 QQ 构建号（NapCat 要求 ≥40768）、缺失动态库、`/dev/shm`、Xvfb 日志与崩溃转储；修复 Termux 菜单新增「25)清理残留 26)重装QQ」。
> v2.0.6 镜像连通性与界面顺序：安装前**逐个实测国内镜像**（Debian / PyPI / QQ CDN / GitHub 代理），不可达的直接跳过并在日志里说明，`apt`/`uv` 只在可用的源上重试；镜像候选扩到清华 / 阿里云 / 中科大 / 腾讯云 / 华为云 / 南大 / 上交，PyPI 增加腾讯云与华为云，新增 **Termux 菜单 27)镜像测速** 与诊断里的镜像可用性行；QQ 安装包换成 **官方 3.2.34-53644**（官方页面给的 3.2.18 地址已 404），已装 QQ 构建号低于 40768 时**自动重装**，NapCat 版本查询增加 GitHub 代理兜底；界面改为**安装优先**：首次安装向导与项目反馈提到最上面，服务状态 / WebUI / 适配器 / 保活居中，第 0-3 步与「打不开先点这里」在下方。

## 功能

- **安装**：一键初始化 Debian 容器、部署 / 更新 MaiBot、安装 NapCat
- **运行**：启动 / 停止 MaiBot 与 NapCat，一键启动全部
- **WebUI**：
  - 打开 MaiBot WebUI（`http://127.0.0.1:8001/`）
  - 打开 NapCat WebUI（自动探测 6099–6199 实际端口，并带上 `webui.json` 里的 Token）
  - **WebUI 可用性自检**：端口开着不算数，会真的发一次 HTTP 请求；打不开时说明是没启动、端口没监听，还是页面没准备好，而不是给一个打不开的链接
- **适配器**：一键把官方「统一 QQ 连接器」的连接参数写入 MaiBot，并检查 QQ 号、端口与插件状态
- **保活**：常驻守护、掉线自动重启、开机自启、关闭电池优化
- **后台任务**：安装期间可以切后台或锁屏，通知栏与页面日志持续显示进度

## 运行链路

```
QQ → NapCat → 正向 WebSocket ws://127.0.0.1:3001 → 统一 QQ 连接器 → MaiBot
```

> 旧的独立 NapCat 适配器（`MaiBot-Napcat-Adapter`）已归档，现在使用官方插件
> [MaiBot-SnowLuma-Adapter](https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter)（统一 QQ 连接器），
> 同一个插件同时支持 NapCat 与 SnowLuma。

## 环境要求

- Android 7.0（API 24）及以上
- [Termux](https://f-droid.org/en/packages/com.termux/)（F-Droid 版或 GitHub 版，二者不要混装）
- 首次安装约需数 GB 空间和稳定网络
- 建议接通电源并关闭电池优化

## 安装

从 [Releases](../../releases) 或 `dist/` 目录下载 APK 安装：

```
dist/MaiBot-OneKey-v2.0.6.apk
```

## 镜像与国内网络

安装脚本不依赖单一镜像：Debian / Termux / PyPI / QQ 安装包 / GitHub 代理都有一组国内候选，**每次安装前先逐个探测**，连不上的直接跳过（日志里会打 `[注意] ... 不可达（安装时会自动跳过该来源）`），只用实测可达的源。

2026-10 实测（大陆网络）：

| 用途 | 可达 | 备注 |
| --- | --- | --- |
| Debian | 阿里云、中科大、腾讯云、华为云、南大、上交 | 清华部分网络会返回 403，排第一但不依赖 |
| Termux | 中科大、上交、北大、南大、华为云 | 同上 |
| PyPI | 阿里云（最快）、腾讯云、华为云、中科大、官方 PyPI | uv 用 `UV_DEFAULT_INDEX` 指定 |
| QQ 安装包 | `qqdl.gtimg.cn` 的 3.2.34-53644 | 官方页面给的 3.2.18 链接已 404 |
| GitHub | `gh-proxy.com`（代理） | 直连 `api.github.com` 常失败，脚本会自动改走代理 |

想在手机上自己复测：Termux 菜单 `27)镜像测速`，或

```bash
bash ~/maibot-onekey.sh mirrors
```

「连接诊断」里也会给出当前 Debian / PyPI 源能否连通。

## 使用步骤

1. 安装并首次打开 Termux，等它完成基础环境初始化。
2. App 点 **修复 Termux 通信** → 允许「运行 Termux 命令」→ 在 Termux 里粘贴执行复制的命令 → 彻底退出 Termux 再打开。
3. 点 **检查安装条件**，通过后点 **按顺序安装：Debian → MaiBot**。
4. （可选）首次想在终端里看着跑一次，可在 Termux 执行：
   ```bash
   bash ~/maibot-onekey.sh fg
   ```
   新版 MaiBot 不再需要交互确认协议，直接回 App 点 **启动 MaiBot** 即可。
5. 回到 App 点 **启动 MaiBot** → **打开 MaiBot WebUI**，登录并设置固定 Token、模型等。
6. 填写机器人 QQ 号 → **保存 QQ 号**（同时写入 NapCat 正向 WS 3001）→ **安装 NapCat** → **启动 NapCat** → **打开 NapCat WebUI** 扫码登录。
7. 在 **MaiBot WebUI → 插件管理** 里从 Git 安装：
   ```
   https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter
   ```
8. 回到 App 点 **一键配置适配器**，写入 `client.server=127.0.0.1`、`client.port=3001`、`client_type=auto`，并同步 `bot_config.toml` 的 `platform=qq`、`qq_account`。
9. **停止 MaiBot → 启动 MaiBot** 让配置生效，点 **检测适配器连接状态** 确认链路。

排查顺序：WebUI 能不能打开 → 适配器插件是否启用 → 3001 是否监听 → 两边 QQ 号是否一致 → 适配器访问策略是否放行该群。

打不开 WebUI 时：先点 **连接诊断**，重点看三行——

- `screen 会话 maibot` 显示 `dead`：手机重启后留下的空壳会话，直接点 **启动 MaiBot**，脚本会自己清掉再启动。
- 日志停在 `Building maibot @ ...`：旧版本用 `uv run` 启动时卡在构建；v2.0.5 起改用虚拟环境解释器启动，不再出现。
- `8001 端口：未监听` 且 mai.log 里有 Python 报错：按提示点 **修复依赖**，再把日志贴到 Issues。

NapCat 起不来时，日志末尾会有 `QQ 进程已退出，退出码 N`：`139/134/132` 是原生崩溃，`137` 是被系统（内存不足）杀掉。诊断里会一并打印 QQ 构建号（NapCat 要求 ≥40768，过旧就重装 QQ）、缺失动态库和 `/dev/shm` 状况。Termux 菜单里另有 `25)清理残留` 与 `26)重装QQ`。

## 构建

```bash
cd MaibotApp
./gradlew assembleRelease
```

- 有 `MaibotApp/maibot.jks` 时自动签名；没有时产出未签名 APK（`app-release-unsigned.apk`）。
- 签名密码可用环境变量覆盖：`MAIBOT_KEYSTORE_PASSWORD`、`MAIBOT_KEY_ALIAS`、`MAIBOT_KEY_PASSWORD`。
- 首次构建使用腾讯云 Gradle 镜像下载发行包；如不需要，可修改 `gradle/wrapper/gradle-wrapper.properties` 中的 `distributionUrl`。

## 项目结构

```
MaibotApp/
  app/src/main/assets/maibot-onekey.sh      # 安装 / 启动 / 诊断脚本（核心逻辑）
  app/src/main/java/com/maibot/app/         # MainActivity、TaskSession、TermuxRunner 等
  app/src/main/res/layout/activity_main.xml # 单页界面
verify-v136-regressions.ps1                 # 安装脚本回归测试
verify-v200-ui.ps1                          # 界面与 WebUI/适配器接线检查
dist/                                       # 构建好的 APK
```

## 安全说明

- 三个 WebUI（MaiBot 8001、NapCat 6099、NapCat WS 3001）默认只监听 `127.0.0.1`，仅本机可访问。
- NapCat WebUI Token 由脚本随机生成，`webui.json` 权限 600。
- App 只允许打开 `127.0.0.1` / `localhost` 的地址，避免把 Token 发到外部站点。
- 插件安装会在 MaiBot 环境中执行第三方代码，请只安装可信来源。

## 免责声明

本项目是个人维护的安装助手，**不是** MaiBot、NapCat、Termux 或 QQ 的官方项目。
使用第三方插件、登录 QQ 账号产生的风险由使用者自行承担。

## 致谢

- [MaiBot](https://github.com/Mai-with-u/MaiBot)
- [MaiBot-SnowLuma-Adapter（统一 QQ 连接器）](https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter)
- [NapCat](https://github.com/NapNeko/NapCatQQ)
- [Termux](https://github.com/termux/termux-app)

## 许可证

[MIT](LICENSE)
