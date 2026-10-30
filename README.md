# MaiBot 一键部署（Android）

在安卓手机上用 **Termux + Debian 容器** 跑 [MaiBot](https://github.com/Mai-with-u/MaiBot) 与 [NapCat](https://github.com/NapNeko/NapCatQQ) 的控制台 App。

App 不重做 MaiBot 的网页界面，只负责：把环境装好、把服务拉起来、把 **MaiBot WebUI** 和 **NapCat WebUI** 用手机浏览器打开，并把 QQ 适配器接到 NapCat 上。

> v2.0.0 起移除了此前「在 App 内重做 WebUI」的实验方案（原生管理页 / 内嵌 WebView / 内置插件管理），恢复为 1.6.x 的单页布局并重新排版。

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
dist/MaiBot-OneKey-v2.0.0.apk
```

## 使用步骤

1. 安装并首次打开 Termux，等它完成基础环境初始化。
2. App 点 **修复 Termux 通信** → 允许「运行 Termux 命令」→ 在 Termux 里粘贴执行复制的命令 → 彻底退出 Termux 再打开。
3. 点 **检查安装条件**，通过后点 **按顺序安装：Debian → MaiBot**。
4. 首次启动需在 Termux 确认相关协议（前台运行一次）：
   ```bash
   bash ~/maibot-onekey.sh fg
   ```
5. 回到 App 点 **启动 MaiBot** → **打开 MaiBot WebUI**，登录并设置固定 Token、模型等。
6. 填写机器人 QQ 号 → **保存 QQ 号**（同时写入 NapCat 正向 WS 3001）→ **安装 NapCat** → **启动 NapCat** → **打开 NapCat WebUI** 扫码登录。
7. 在 **MaiBot WebUI → 插件管理** 里从 Git 安装：
   ```
   https://github.com/Mai-with-u/MaiBot-SnowLuma-Adapter
   ```
8. 回到 App 点 **一键配置适配器**，写入 `client.server=127.0.0.1`、`client.port=3001`、`client_type=auto`，并同步 `bot_config.toml` 的 `platform=qq`、`qq_account`。
9. **停止 MaiBot → 启动 MaiBot** 让配置生效，点 **检测适配器连接状态** 确认链路。

排查顺序：WebUI 能不能打开 → 适配器插件是否启用 → 3001 是否监听 → 两边 QQ 号是否一致 → 适配器访问策略是否放行该群。

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
