# Super DD

<p align="center">
  <img src="Docs/Assets/app-icon.png" width="128" height="128" alt="Super DD app icon">
</p>

<p align="center">
  面向 macOS 26 及更新系统的原生多协议下载器。
</p>

<p align="center">
  <a href="https://github.com/IchenDEV/super-dd"><img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-111111?logo=apple"></a>
  <a href="https://www.swift.org"><img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white"></a>
  <a href="LICENSE"><img alt="Swift source MIT license" src="https://img.shields.io/badge/Swift_source-MIT-2F80ED"></a>
  <a href="THIRD_PARTY_NOTICES.md"><img alt="aria2-next GPLv2" src="https://img.shields.io/badge/aria2--next-GPLv2-5C6BC0"></a>
</p>

Super DD 使用 Swift 6、SwiftUI 和少量 AppKit 构建窗口、菜单、设置、通知及系统集成，通过本机 JSON-RPC 2.0 驱动独立的 `aria2-next` sidecar。项目不使用第三方 Swift Package、UI 框架、WebView、Electron、Tauri 或其他跨平台运行时。

> [!IMPORTANT]
> 当前版本为 `0.1.0 Preview`。核心下载体验已经可用，但 Motrix v2 的插件市场、MDXP、远程 headless 等生态能力仍在开发中。请以[功能对等矩阵](Docs/FEATURE_PARITY.md)为准，不将 Preview 版本描述为完整 Motrix 对等实现。

![Super DD 的 macOS 26 原生仪表盘](Docs/Assets/super-dd-dashboard.jpg)

## 特性

### 下载与任务

- HTTP、HTTPS、FTP、BitTorrent、Magnet、ED2K、Thunder 和 `.torrent` 文件
- 多任务、批量选择、搜索、暂停、继续、移除及 aria2 会话恢复
- 自定义文件名、目录、请求头、Cookie、Referer、User-Agent、校验和与代理
- BT 文件选择、Peer、Tracker、DHT v4/v6、PEX、LPD、加密和做种设置
- 全局及单任务限速、按星期与时间段调度、Tracker 源自动合并
- BT peer blocklist 与 ED2K `server.met` / `nodes.dat` 自动刷新

### macOS 原生体验

- 面向 macOS 26 的 SwiftUI 侧栏、工具栏、检查器、设置窗口和 Liquid Glass 材料
- 系统、浅色、深色外观，原生菜单与键盘操作，可访问性标签
- Notification Center 通知、Dock 活跃任务角标、菜单栏实时速率
- 登录启动、下载期间防止系统空闲睡眠、常用及最近下载目录
- `magnet://`、`ed2k://`、`thunder://`、`superdd://` 深链和 `.torrent` 文件关联

### 本机服务与数据

- 带独立 Secret 的 loopback aria2 JSON-RPC，端口冲突时自动恢复
- SQLite 完成/失败历史和数据库完整性检查
- 只绑定 `127.0.0.1` 的浏览器扩展 API：`/ping`、`/add`、`/version`、`/stat`、`/tasks`、`/pause-all`、`/resume-all`
- 可导出经过凭据脱敏的诊断 ZIP

## 快速开始

要求：

- macOS 26 或更新版本
- Xcode 26 或更新版本，包含 Swift 6.2 工具链
- Apple Silicon 或 Intel Mac

克隆并运行：

```bash
git clone https://github.com/IchenDEV/super-dd.git
cd super-dd
./script/build_and_run.sh
```

脚本会下载锁定版本的 `aria2-next 2.5.5` 并校验 SHA-256，使用 SwiftPM 构建应用，生成 `dist/SuperDD.app`，进行本地 ad-hoc 签名并启动。

> [!NOTE]
> ad-hoc 签名仅用于本机开发测试。当前仓库尚未提供经过 Developer ID 签名和 Apple 公证的发行包。

### 构建命令

| 命令 | 用途 |
| --- | --- |
| `./script/build_and_run.sh` | 构建、打包并启动应用 |
| `./script/build_and_run.sh --verify` | 构建后检查 bundle、签名、引擎和最低系统版本 |
| `./script/build_and_run.sh --logs` | 打开应用日志流 |
| `./script/build_and_run.sh --telemetry` | 查看轻量运行遥测 |
| `./script/build_and_run.sh --debug` | 使用 LLDB 启动 |
| `swift test` | 运行 Swift Testing 测试 |

## 架构

```text
SwiftUI / AppKit
      │
DownloadStore + native macOS services
      │ JSON-RPC 2.0 over loopback
aria2-next sidecar
```

Swift Package 只链接 Apple 系统框架及系统 SQLite，不包含外部 Swift 依赖。`aria2-next` 作为独立进程运行；应用为它生成专用 Secret，并将 RPC 绑定到 loopback。

```text
Sources/SuperDD/
├── App/          App 生命周期、菜单与场景
├── Models/       下载任务、设置和 JSON 值模型
├── Services/     aria2、历史、通知、网络及系统服务
├── Stores/       界面状态与任务协调
├── Support/      URL 规范化、格式化和端口恢复
└── Views/        原生任务、仪表盘、检查器和设置界面
```

更多实现与信任边界见[架构说明](Docs/ARCHITECTURE.md)。

## 数据与安全

应用数据位于 `~/Library/Application Support/SuperDD/`：

| 文件或目录 | 内容 |
| --- | --- |
| `settings.json` | 应用与引擎设置、扩展 API Secret |
| `aria2.session` | 未完成任务恢复信息 |
| `history.sqlite3` | 完成和失败历史 |
| `aria2-next.log` | 下载引擎日志 |
| `EngineResources/` | Tracker、ED2K 和 blocklist 缓存 |

- aria2 RPC 和扩展 API 仅监听 `127.0.0.1`。
- 扩展 API 除 `/ping` 与 `/version` 外均要求 Bearer Secret。
- 诊断导出会移除扩展 Secret 和代理密码。
- 端口冲突时应用会继续寻找本机空闲端口；实际端口显示在“设置 → Network”。

## 开发与验证

```bash
swift test
./script/build_and_run.sh --verify
```

当前测试覆盖 URL/Thunder/深链解析、JSON-RPC 认证、任务模型、SQLite 历史和诊断 ZIP 脱敏。提交前还应在真实应用中检查下载、浅色/深色外观、窄窗口布局和扩展 API。

## 路线图

完整状态见[功能对等矩阵](Docs/FEATURE_PARITY.md)。主要开放项包括：

- Motrix 插件沙箱、插件市场与 URL resolver 生态
- MDXP 设备配对和远程 headless 服务
- 签名更新通道及经过 Apple 公证的发行包
- Chrome、Edge、Firefox 扩展商店包
- UPnP / NAT-PMP、GeoIP peer 标识和更多本地化

## 参与贡献

欢迎提交 Issue 和 Pull Request。请保持实现原生、依赖最小且可验证：

1. 不引入第三方 UI 框架或跨平台运行时。
2. 功能变更同时更新测试和[功能对等矩阵](Docs/FEATURE_PARITY.md)。
3. 提交前运行 `swift test` 与 `./script/build_and_run.sh --verify`。
4. 不提交下载产生的数据、Secret、构建目录或 `aria2-next` 二进制。

## 许可与致谢

除另有说明外，Super DD 的 Swift 源码使用 [MIT License](LICENSE)。`aria2-next` 是独立的 GPLv2 下载引擎，并保留其 OpenSSL linking exception；构建脚本下载的二进制及其分发遵循对应上游许可证。完整声明见[第三方许可证](THIRD_PARTY_NOTICES.md)和仓库内附的 [GPLv2 文本](Legal/aria2-next-GPLv2.txt)。

项目的产品与下载能力参考 [Motrix Next](https://github.com/AnInsomniacy/motrix-next)、[Motrix](https://github.com/agalwood/Motrix) 和 [aria2-next](https://github.com/AnInsomniacy/aria2-next)。感谢这些项目及其贡献者。
