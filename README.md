# CodexBar

[![CI](https://github.com/kexinOvO/CodexBar/actions/workflows/ci.yml/badge.svg)](https://github.com/kexinOvO/CodexBar/actions/workflows/ci.yml)

原生 macOS 菜单栏应用，用来查看 **OpenAI Codex CLI 的额度与 Token 活动**。

CodexBar 只与本机已经安装并登录的 Codex CLI 协作：应用启动 `codex app-server`，通过 stdin/stdout 的结构化协议读取账户、额度和 Token 使用情况。当前版本已经**完全移除 PTY / TUI 自动化**，不会再模拟粘贴、回车或 slash command，也不会直接调用 OpenAI 的 HTTP 接口。

![CodexBar Popover 示例](docs/images/codexbar-popover.png)

## 当前状态

- 原生 SwiftUI + AppKit 菜单栏应用，无 Electron / Tauri、无第三方运行时依赖
- 当前工程版本：`2.0`
- 当前 Xcode 工程与 CI 使用 **Xcode 27**
- 当前 `MACOSX_DEPLOYMENT_TARGET = 27.0`
- 数据层已经迁移到 `codex app-server`
- `main` push 与 Pull Request 自动运行单元测试
- `v*` tag 自动构建 DMG 并创建 GitHub Release

> 当前工程的实际 deployment target 是 macOS 27.0。若要支持更早的 macOS，需要同时下调 target 并检查所使用 SwiftUI / AppKit API 的可用性，不能仅修改 README 中的版本号。

## 功能

### 额度

- 显示 5 小时额度与 Weekly 额度的剩余百分比
- 显示进度条和重置时间
- `Simple / Full` 两种额度展示模式
- 低额度状态使用警示样式
- Weekly `< 10%`、Weekly `< 5%`、5h `< 10%` 可分别开启通知

### Token 活动

- GitHub 风格活动热力图
- 读取 `dailyUsageBuckets` 的真实每日 Token 数，不再从终端颜色反推
- 热力图范围可调：6–10 个月
- 5 级活动强度：无活动 + 4 个活动等级
- Hover 显示日期与精确 Token 数
- Lifetime / Peak / Streak / Longest Task 概览
- 概览统计可单独隐藏

### 菜单栏与外观

- 菜单栏显示模式：
  - Icon only
  - Weekly remaining %
  - 5h + Weekly %
- System / Light / Dark 外观
- Default / Custom 主题色
- Custom 模式使用明度阶梯区分不同额度状态和热力图强度
- Popover 宽度可调：200–480 pt
- 左键打开 Popover；右键打开原生菜单
- 原生菜单包含立即刷新、设置、退出

### 自动刷新与缓存

- Status 默认每 5 分钟刷新
- Activity 默认每 30 分钟刷新
- 刷新间隔可在设置中调整
- 启动时先读取本地缓存，再后台获取最新数据
- 打开 Popover 时会检查数据新鲜度并按需刷新
- 刷新失败时保留上一份有效缓存，而不是清空界面
- 同类刷新有并发保护

### 设置

设置窗口使用原生 `Window` + `NavigationSplitView` + `Form`，分为三页：

| 页面 | 内容 |
| --- | --- |
| General | 登录时打开、Status / Activity 刷新间隔、低额度通知 |
| Appearance | 外观、主题色、菜单栏模式、额度模式、Popover 宽度、热力图范围、统计显示 |
| CLI | Codex 路径、自动检测、版本、最近查询、连接状态 |

### 本地化

当前工程包含：

- English
- 简体中文
- 繁體中文
- 日本語
- 한국어
- Deutsch

本地化资源集中在 `CodexBar/Localizable.xcstrings`。

## 数据架构

CodexBar 当前**不创建 PTY，也不打开 Codex TUI**。

```text
CodexBar
  └── codex app-server
        └── stdin / stdout
              ├── initialize
              ├── initialized
              ├── account/read
              ├── account/rateLimits/read
              └── account/usage/read
```

### 握手

启动 `codex app-server` 后：

1. CodexBar 发送 `initialize`
2. 收到初始化响应
3. CodexBar 发送 `initialized`
4. 再开始账户 / 额度 / usage 请求

Codex App Server 的 wire protocol 使用 request / response 语义，但当前上游协议的消息**不包含**标准 JSON-RPC 的：

```json
{"jsonrpc":"2.0"}
```

CodexBar 的协议测试会专门检查这一点，避免未来重构时误加字段。

### 账户

`account/read` 用于：

- 判断 Codex 是否已登录
- 获取 ChatGPT 账户 email
- 获取 plan 类型

如果需要认证但当前没有账户，CodexBar 会显示未登录状态，并提示执行：

```bash
codex login
```

### 额度

`account/rateLimits/read` 返回结构化额度窗口。

CodexBar **不依赖 primary / secondary 的位置**，而是按 `windowDurationMins` 匹配：

- 约 `300` 分钟 → 5h
- 约 `10,080` 分钟 → Weekly

剩余百分比使用：

```text
remaining = 100 - usedPercent
```

重置时间直接使用结构化 `resetsAt` 时间戳。

### Token Usage

`account/usage/read` 返回账户级 Token 活动，包括：

- Lifetime tokens
- Peak daily tokens
- Current streak
- Longest running task
- `dailyUsageBuckets`

CodexBar 使用精确 daily token 数生成热力图，并按峰值日计算 0–4 级强度。

## 为什么不再使用 TUI 自动化

旧方案需要：

```text
PTY
 → Codex TUI
 → 模拟粘贴
 → 模拟 Enter
 → 等待界面状态
 → 解析 ANSI / 终端文本
```

这种做法会受到 composer 残留、终端重绘、按键吞掉、slash command 自动完成等状态影响。

当前架构没有聊天输入框，也没有自动输入 slash command，因此下面这一类问题已经从运行路径中消失：

```text
/status/status
/usage daily/usage daily
/status/quit
```

仓库中原来的 `CodexSession`、`StatusParser`、`UsageParser`、`ANSIStyleScanner`、`ANSITextCleaner` 及相关测试均已移除。

## Codex CLI 检测

CodexBar 会验证候选可执行文件能否真正运行 `codex --version`，而不是只检查文件是否存在。

检测顺序：

1. 设置页中指定的路径
2. `/opt/homebrew/bin/codex`
3. `/usr/local/bin/codex`
4. 当前进程 `PATH`
5. 常见版本管理器 / 包管理器路径，例如 nvm、Volta、Bun、pnpm、asdf、`~/.local/bin` 等
6. 最后使用登录 shell 查询 `command -v codex`

npm 安装的 `codex` 可能是 Node wrapper。CodexBar 会尽可能解析到真正的原生 Codex 二进制；如果仍需 wrapper，则补齐对应 Node `bin` 路径。

设置页的 CLI 路径框遵循明确的行为：

- 输入非空时，“Detect”只验证用户填的那一个路径，不会静默切换到别的安装
- 输入为空时，“Detect”才进行整机自动检测
- 若 wrapper 最终解析到另一个可执行文件，会显示 `Resolved executable`

## 隐私与安全

CodexBar 不保存 ChatGPT Cookie，不解析 Codex 的登录凭据，也不会把 OpenAI access token 写入自己的缓存。

本地数据目录：

```text
~/Library/Application Support/CodexBar/
```

其中主要包含：

```text
settings.json
status.json
usage.json
CLIWorkspace/
```

安全措施：

- Application Support 目录权限收紧为 `0700`
- JSON 缓存写入后权限收紧为 `0600`
- 缓存使用原子写入
- 缓存损坏时删除损坏文件并重新获取
- `CLIWorkspace` 使用独立工作目录，避免项目目录里的 `AGENTS.md` / hooks 等影响辅助进程
- 子进程环境使用 allowlist，不会把整个开发环境无条件传给 Codex
- app-server 请求有超时控制
- 结束会先关闭 stdin 让 app-server 正常退出，必要时再终止进程及子进程

### 环境变量说明

为了兼容 Codex CLI 的正常登录、代理和自定义配置，CodexBar 会有选择地向 **Codex 子进程**透传必要环境变量，包括：

```text
HOME / USER / LOGNAME / SHELL / TMPDIR
LANG / LC_*
CODEX_HOME
OPENAI_API_KEY
OPENAI_BASE_URL
HTTP(S)_PROXY / ALL_PROXY / NO_PROXY
SSL_CERT_FILE / SSL_CERT_DIR / NODE_EXTRA_CA_CERTS
XDG_CONFIG_HOME / XDG_DATA_HOME / XDG_CACHE_HOME
```

这些变量不会被写入 CodexBar 的 JSON 缓存。诸如 `GITHUB_TOKEN`、AWS / npm 等与 Codex 无关的开发凭据不在 allowlist 中。

如果进程环境中没有显式 HTTP(S) 代理，CodexBar 还会尝试读取系统 HTTPS 代理并提供给 Codex 子进程。

## 构建

### 要求

- macOS 27.0（当前工程 deployment target）
- Xcode 27
- 已安装 Codex CLI

克隆后可以直接：

```bash
git clone https://github.com/kexinOvO/CodexBar.git
cd CodexBar

xcodebuild \
  -project CodexBar.xcodeproj \
  -scheme CodexBar \
  -configuration Debug \
  build
```

运行测试：

```bash
xcodebuild \
  -project CodexBar.xcodeproj \
  -scheme CodexBar \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  test
```

也可以直接用 Xcode 27 打开：

```text
CodexBar.xcodeproj
```

然后 `⌘R` 运行。

## App Sandbox

当前项目必须保持：

```text
ENABLE_APP_SANDBOX = NO
```

原因是 CodexBar 需要启动用户本机安装的 `codex` 可执行文件。打开 App Sandbox 会阻止这条运行路径。

当前工程同时开启：

```text
ENABLE_HARDENED_RUNTIME = YES
INFOPLIST_KEY_LSUIElement = YES
```

因此应用以菜单栏 App 形态运行，不额外显示 Dock 图标。

## CI

`.github/workflows/ci.yml` 会在：

- push 到 `main`
- Pull Request

时使用 `xcode-27` runner 执行 `xcodebuild test`。

同一分支的新 CI 会取消仍在运行的旧任务，避免连续提交造成无意义的 runner 排队。

当前测试重点覆盖：

- App Server wire envelope
- 额度窗口映射
- Usage 结构化数据映射
- 热力图强度算法
- Plan 映射
- 子进程环境变量隔离
- CacheStore 文件 / 目录权限
- Settings 容错解码与范围钳制
- 关键 SwiftUI 视图快照

## 打包与 Release

生成 DMG：

```bash
./scripts/create-dmg.sh
```

输出目录：

```text
dist/CodexBar-<version>.dmg
```

DMG 包含：

```text
CodexBar.app
Applications -> /Applications
```

推送 `v*` tag 后，`.github/workflows/release.yml` 会在 `xcode-27` runner 上：

1. 构建 DMG
2. 创建 / 更新 GitHub Release
3. 上传 `dist/CodexBar-*.dmg`
4. 自动生成 Release Notes

### 当前签名状态

`create-dmg.sh` 默认使用：

```text
CODE_SIGNING_ALLOWED=NO
CODE_SIGNING_REQUIRED=NO
```

因此当前自动 Release **默认不是 Developer ID 签名 / notarized 分发流程**。从 GitHub 下载的构建在 macOS 上可能触发 Gatekeeper 提示。

如果将来用于正式公开分发，建议再增加 Developer ID 签名、公证与 stapling 流程。

## 项目结构

```text
CodexBar/
├── CodexBar/
│   ├── CLI/
│   │   ├── CodexAppServer.swift
│   │   └── CodexLocator.swift
│   ├── Models/
│   ├── Parsing/
│   │   └── TokenFormatter.swift
│   ├── Services/
│   ├── UI/
│   ├── CodexBarApp.swift
│   └── Localizable.xcstrings
├── CodexBarTests/
├── docs/
├── scripts/
│   └── create-dmg.sh
└── .github/workflows/
    ├── ci.yml
    └── release.yml
```

## 已知限制

- 需要安装支持 `codex app-server`、`account/read`、`account/rateLimits/read`、`account/usage/read` 的 Codex CLI 版本
- App Server 协议仍可能随 Codex CLI 版本演进；旧版本不支持对应 method 时会明确报错并提示更新 CLI
- 当前**没有 TUI fallback**；这是有意设计，避免重新引入终端输入状态问题
- `account/usage/read` 需要 Codex CLI 能正常访问后端；网络或代理异常时 Activity 刷新会失败，但旧缓存仍会保留
- 当前 deployment target 是 macOS 27.0
- 当前自动生成的 DMG 默认未做 Developer ID 签名与 notarization

## 设计原则

CodexBar 的目标不是重新实现 Codex，也不是绕过 Codex CLI 的认证层。

它只负责：

```text
找到本机 Codex CLI
        ↓
启动 codex app-server
        ↓
读取结构化账户 / 额度 / Token 数据
        ↓
以原生 macOS 菜单栏界面展示
```

登录、凭据刷新、后端通信仍由 Codex CLI 自己负责。
