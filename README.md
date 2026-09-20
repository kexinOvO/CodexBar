# CodexBar

原生 macOS 菜单栏应用，用于查看 OpenAI Codex CLI 的额度与 Token 活动。

数据 **只通过本机已安装并登录的 Codex CLI** 获取（驱动其交互式 `/status` 与 `/usage daily` 命令），不使用 ChatGPT Cookie，不调用任何 OpenAI 未公开接口。

> 截图：*（预留位置 —— 打开 App 后点菜单栏图标即可截图 Popover / 设置窗口）*

## 系统要求

- macOS 14+（工程以 Xcode 27 构建，deployment target 27.0，可在项目设置中下调）
- Swift + SwiftUI + AppKit，无第三方依赖，无 Electron/Tauri

## 前置条件

1. 安装 Codex CLI（`npm i -g @openai/codex` 或 Homebrew）
2. 完成登录：

```bash
codex login
```

CodexBar 按以下顺序自动检测 codex：

1. 设置页里填写的路径（最高优先级）
2. `/opt/homebrew/bin/codex`、`/usr/local/bin/codex`
3. 进程 `PATH` 中的 `codex`
4. 扫描版本化安装根目录：`~/.workbuddy/binaries/node/versions/*/bin/codex`、`~/.nvm/versions/node/*/bin/codex`、`~/.volta/bin`、`~/.bun/bin`、`~/.local/bin`、`~/Library/pnpm`、`~/.asdf/shims` 等，按安装时间新→旧
5. 兜底询问用户的登录 shell：`$SHELL -ilc 'command -v codex'`

候选路径必须真正跑通 `codex --version` 才算命中。npm 全局安装会被自动解析到其内置的原生二进制（绕过 Node wrapper，便于进程清理）；解析不到时改为把 wrapper 所在 node 的 `bin` 目录注入子进程 `PATH`。

> **为什么检测要这么啰嗦**：macOS GUI App 由 Finder / `launchd` 启动时只继承 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`，你在终端里能跑的 `codex` 对它完全不可见；而 npm 的 `codex` 又是个 Node shebang 脚本（`#!/usr/bin/env node`），路径填对了、`node` 不在 `PATH` 里照样启动失败。另外 npm 对平台包有两种布局，都要认：平铺 `@openai/{codex, codex-darwin-arm64}`，以及嵌套 `@openai/codex/node_modules/@openai/codex-darwin-arm64`。

## 隐私说明

- 所有数据仅保存在本机：`~/Library/Application Support/CodexBar/`
- **不读取、不保存、不传输** ChatGPT Cookie、access token、密码
- 不读取 `~/.codex` 中与运行无关的内容；不修改用户的 Codex 配置
- 无 analytics / telemetry，无任何自动上传
- 缓存只保存解析后的字段（模型名、百分比、Token 统计等），带 `fetchedAt`
- 缓存损坏时自动删除并重新拉取；写入为原子操作

## 数据来源

- **额度**：在隔离的空目录（`~/Library/Application Support/CodexBar/CLIWorkspace`）中通过 PTY 启动 Codex CLI 交互会话，发送 `/status`，解析返回卡片（模型 / 账户与计划 / 5h limit / Weekly limit / 重置时间）。使用空目录可避免加载任何项目级配置、hooks 或 AGENTS.md；如出现目录信任提示会自动确认，且不关闭 Codex 的任何安全保护
- **Token 活动**：同一会话中依次尝试 `/usage daily` 与 `/usage` → "Show usage" 菜单，解析 12 个月热力图与 Lifetime / Peak / Streak / Longest task 统计
- CLI 会话有超时、退出清理（含 Node wrapper 的子孙进程级联 kill），退出 App 时终止所有子进程
- 解析器不依赖固定空格或 ANSI 样式：先剥离全部转义序列（含 DECSCUSR `\x1b[N q`、OSC、C0 控制符），再宽松匹配（忽略大小写 / 多余空白，支持 `150M`、`1.3B`、`4d`、`27m`、`1h 20m`、百分比与进度条长度换算）

## 如何编译

```bash
cd CodexBar
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -configuration Debug build
# 运行测试（29 个单元测试）
xcodebuild -project CodexBar.xcodeproj -scheme CodexBar test
# 或直接用 Xcode 打开 CodexBar.xcodeproj，⌘R 运行
```

### 构建配置：**不要**打开 App Sandbox

`ENABLE_APP_SANDBOX` 必须保持 `NO`（Debug / Release 两套配置都是）。App Sandbox 会禁止 `posix_spawn` 容器外的可执行文件，也就是彻底堵死「驱动本机 Codex CLI」这条路——即使路径填对了也会失败。Release 配置还需要 `INFOPLIST_KEY_LSUIElement = YES`（否则分发包会在 Dock 里多出一个图标）和正确的 `PRODUCT_BUNDLE_IDENTIFIER`。

## 功能

- **右键菜单**：右键（或 ⌃+左键）点菜单栏图标弹出原生 NSMenu —— 立即刷新（⌘R）/ 设置（⌘,）/ 退出 CodexBar（⌘Q）；左键仍是 Popover，菜单只在右键那一瞬间挂到 `NSStatusItem` 上、弹出后立刻摘掉，所以两种点击互不干扰；正在刷新时「立即刷新」自动置灰
- **额度区块**：5h / Weekly 剩余百分比 + 进度条 + 重置时间；无卡片背景，文字与进度条直接铺在 Popover 内容区（与外层 16pt 边距对齐，和其它区块视觉一致）；<10% 橙色警示、<5% 红色警告 + 右上角三角图标；单侧解析失败显示 Unavailable 不影响整体。**显示模式**（设置 › 外观 › 额度）可选 `简单` / `完整`：简单模式只留百分比与进度条，隐藏重置时间（含倒计时、绝对日期与「即将重置」），完整模式为默认
- **Popover 宽度**：200–480 pt 滑块可调（设置 › 外观 › 弹窗，步进 10 pt，默认 370）；读侧钳制，手改 settings.json 不会出现不可用的宽度；热力图格子尺寸随内容宽度联动重算
- **Token 活动热力图**：GitHub 风格，范围 6–10 个月可调（设置 › 外观 › 热力图），5 级强度（无活动 + 4 级），系统色 + 透明度区分强度，自动适配深浅色；无月份标签行（格子按周分列，hover 给出准确日期）；hover 提示只显示日期 + Token 数（无 Token 数但有活动的格子仅显示日期——强度已由格子深浅表达，不再重复文字；完全无活动的格子显示「无活动」）
- **概览统计**：Lifetime / Peak / Streak / Longest task，单位格式化（1K / 1M / 71.9M / 27 min / 4 days）
- **自动刷新**：status 每 5 分钟、usage 每 30 分钟（可调）；启动即显示缓存再后台刷新；打开 Popover 时 status 超 2 分钟 / usage 超 10 分钟立即刷新；同类刷新防并发；失败保留旧缓存
- **低额度通知**：Weekly <10% / <5%、5h <10%，各自可开关；同一周期每阈值只提醒一次，恢复后重新武装；权限懒请求
- **菜单栏模式**：Icon only / Weekly % / 5h+Weekly %；数据不可用时只显示图标
- **开机启动**：SMAppService，开关与系统注册状态实时同步
- **设置页（侧边栏分栏）**：窗口用 SwiftUI 的 `Window` scene（id `settings`，单实例，重复 `openWindow` 只是把已有窗口提到最前）承载一个 `NavigationSplitView`——左侧一级导航列出 3 个分类，右侧只渲染当前分类的分组 `Form`，互不串页；当前页名以左对齐工具栏标题的形态显示在内容区上方（macOS 26+ 新设计的标准偏好窗长相，与主流原生 App 的设置窗一致）：

  | 一级（侧边栏） | 右侧分组 |
  | --- | --- |
  | General | Startup（登录时打开）/ Refresh（Status / Activity 刷新间隔）/ Notifications（低额度阈值） |
  | Appearance | 配色（System-Light-Dark）/ 主题色（Default-Custom，Custom 时显示调色盘）/ Menu Bar / Quota / Popover（宽度滑块）/ Heatmap（含「用量统计」开关：是否显示热力图下方的 Lifetime / Peak / Streak / Longest task 摘要行） |
  | CLI | CLI 路径 / Diagnostics（版本、上次查询、连接状态） |

  一级分类按「一个话题一页」划分，而不是一个设置一页：配色、菜单栏显示内容、额度显示模式、热力图范围都只决定**界面上显示什么**，所以合并进 `Appearance`；登录时打开、两个刷新间隔与低额度阈值提醒都是「不看它的时候它自己怎么跑」（行为/时序/报警），所以合并进 `General`；CLI 是「它到底连的是哪个 codex」。配色行不带行标签（放在页内第一节，页名即标签，与 系统设置 › 外观 一致）。

  **主题色**：`ThemeColorMode`（Default / Custom）+ `themeColorHex`（`#RRGGBB`，存 `settings.json`）。Default 与历史行为逐字节一致（系统强调色 + 橙/红告警多色相调色板）；Custom 切到单色相后，用量状态与活动等级改用**明度阶梯**区分（`ThemeColor.shaded`，HSB 只动亮度）：浅色背景越严重越深、深色背景越严重越亮（各自唯一可读的方向）——额度 warning = severity 0.45、critical = 1.0，热力图 1–4 级 = 0.25/0.50/0.75/1.0，0 级保持中性灰。Custom 时 Popover 根部整体 `.tint`，控件强调色一并跟随；hex 解析失败安全回落 Default 调色板。首次切到 Custom 用 `#0A84FF` 播种取色盘。

  窗口完全按 SwiftUI 的标准做法搭，**不自己建窗口、不画任何背景 / 描边 / 阴影 / 玻璃**：`Window` scene（`.defaultLaunchBehavior(.suppressed)` 保证菜单栏 App 启动时不自动弹窗）+ `NavigationSplitView`（`List(selection:)` 侧边栏 + `.navigationSplitViewColumnWidth`）+ `Form(.grouped)` + `Section` + 原生 `Toggle` / `Picker` / `Slider` / `TextField` / `LabeledContent`。侧边栏材质通到窗口顶部、红绿灯覆盖在侧边栏上、左侧栏折叠按钮、玻璃与滚动边缘效果、页名标题，全部由系统决定；窗口可缩放（最小 620×420，开窗 700×560，`Appearance` 是最长的一页，超出时按系统惯例滚动）。用 `LabeledContent` 而非 `HStack { Text; Spacer; … }`，所以自定义行与 `Picker` 行的标签 / 数值天然对齐。

  > 历史：这一页先后用过 `NSWindow` 自建窗、系统 `Settings` scene（`TabView` Tab）两种容器。`Settings` scene 在 macOS 27 上把页名渲染在标题栏**居中**，与原生 App 设置窗（页名在内容区左上）不一致；`NavigationSplitView` 放进 `Settings` scene 又会在 macOS 27 把内容顶进标题栏。最终落在 `Window` scene + `NavigationSplitView`：形态与原生偏好窗一致，`Settings` scene 反而拿不到这个布局。

  打开方式两条路都走 `openWindow(id:)`：Popover 里的齿轮是 `Button` + `@Environment(\.openWindow)`；右键菜单的「设置」在 AppKit 侧直接调 `EnvironmentValues().openWindow(id:)`（macOS 14 起 `showSettingsWindow:` 选择器已失效 —— 它仍然返回 `true`，但什么都不做，是个坑）。开窗后补一刀 `makeKeyAndOrderFront`，否则 accessory App 的窗口可能开在当前 App 后面。

  偏好仍存在 `settings.json`（`AppSettings`），因为它们的变更要驱动副作用（刷新定时器、App 外观、通知重新武装）；`@AppStorage` 只用在纯视图状态上 —— 记住上次打开的页面（`Settings.selectedPane`），下次开窗回到同一页。CLI 路径栏：回车即校验并保存；输入框非空时「检测」**只**校验你填的那一条（不会偷偷换成别的安装），失败保留输入并给红色提示；输入框为空时「检测」扫描全机；npm wrapper 被解析成原生二进制时额外显示「实际调用的可执行文件」；关闭窗口再打开会把探测结果自动填回输入框
- **错误处理**：CLI 未安装、未登录、启动失败、解析失败、超时、缓存损坏、通知权限被拒、登录项注册失败 —— Popover 显示友好错误与缓存数据时间，单次异常不会导致崩溃

## 本地化

支持 **6 种语言**，跟随系统语言自动切换（无需手动选择）：

| 语言 | 标识 | 说明 |
| --- | --- | --- |
| 英语 | `en` | 源语言 / 开发语言 |
| 简体中文 | `zh-Hans` | |
| 繁体中文 | `zh-Hant` | 独立词条，非简繁转换 |
| 日语 | `ja` | |
| 韩语 | `ko` | |
| 德语 | `de` | |

词条集中在 `CodexBar/Localizable.xcstrings`（String Catalog，117 条），五种目标语言均为手写翻译，术语对齐各自语种 macOS 系统设置的原生措辞（例如 `Launch at Login` → `登录时打开` / `登入時打開` / `ログイン時に開く` / `로그인 시 열기` / `Bei Anmeldung öffnen`；`System Settings › General › Login Items` 也按各语种实际菜单名书写）。

### 实现要点

- **UI 文案**：SwiftUI 的 `Text` / `Toggle` / `Picker` / `Section` / `Label` 等传入字符串字面量即自动作为 `LocalizedStringKey` 查表；需要在非视图代码里取值的（枚举 `label`、错误描述、通知文案、`NSWindow.title`、`NSMenuItem.title`、格式化的数字单位）统一走 `String(localized:)`。
- **不翻译的内容**：品牌名 `CodexBar`（`Text(verbatim:)`）、CLI 命令 `codex login`（同样 verbatim，避免被误当作词条）、`K`/`M`/`B` 单位后缀、以及所有从 CLI 抓取的原始文本（模型名、套餐名、`01:13 on 23 Sep` 之类）。
- **日期与月份**：用 `setLocalizedDateFormatFromTemplate` 让 `DateFormatter` 跟随语言（`Reset 9月25日 16:24` / `Zurücksetzung: 25. Sept., 16:24`），不再硬编码 `"MMM d, HH:mm"`。
- **单复数**：`day` / `minute` 这类会变形的词**使用独立单数词条 + 代码分支**，而不是 String Catalog 的 plural variations。原因：catalog 的源语言（`en`）不会生成 `en.lproj`，其复数规则进不了 app bundle，英文会渲染成 `1 days ago`。显式词条在任意系统语言下结果一致，也便于逐条校对。
- **测试接缝**：`TokenFormatter.localizationBundle` 可注入。单测宿主是 CodexBar.app，`Bundle.main` 会跟随本机语言，`UsageParserTests` 在 `setUp` 里把它指向无本地化的测试 bundle，从而稳定断言源语言输出。

### 新增语言 / 文案

1. 在 `CodexBar/Localizable.xcstrings` 里加词条（用 Xcode 打开会以表格形式编辑，也可直接改 JSON）。
2. 工程 `knownRegions` 已含现有语言；新增语言需同步补上。
3. 自查覆盖率（编译期产出的 `.stringsdata` 就是权威清单，比人眼扫代码可靠）：

```bash
D=$(xcodebuild -project CodexBar.xcodeproj -scheme CodexBar -configuration Debug \
      -showBuildSettings | awk -F' = ' '/OBJECT_FILE_DIR_normal/{print $2; exit}')/arm64
grep -ho '"key": "[^"]*"' "$D"/*.stringsdata | sort -u   # 源码侧需本地化的全部键
```

## 已知限制

- CLI 的 TUI 在初始化/重绘期间可能吞掉键盘输入与回车，已通过就绪沉降期 + 多级重试缓解，但极端情况下 usage 仍可能拉取失败；此时 App 显示 "No activity data yet"（额度卡片不受影响，`/status` 正常）
- 若出现 "Do you trust the contents of this directory?" 且用户未确认，App 会自动按回车选择默认信任项；如不希望信任任何目录，请勿使用本工具
- CLI 未来改版（字段更名、布局变化）可能导致个别字段 Unavailable，解析失败为软降级而非崩溃
- 通知权限被系统拒绝后 App 无法再次弹窗，需到系统设置开启
- 若本机有多个 codex 安装，「自动检测」会选**安装时间最新**的那一个（通常是版本更新的），不一定是终端里 `codex` 解析到的那一个；想固定用哪个就在设置页填路径，或让输入框为空后点「检测」看它选中了谁
- Codex CLI 的 TUI 版本升级可能改变 `/status`、`/usage daily` 的输出布局，届时解析会降级为 Unavailable，需要跟着更新解析器

## 为什么不用 ChatGPT Cookie / 私有 API

- Cookie / token 属于用户敏感凭据，保存在第三方 App 中是持久化攻击面
- 未公开接口随时会变，且可能违反服务条款，导致账号风险
- Codex CLI 本身已持有合法登录态，驱动 CLI 是稳定、合规且零凭据接触的路径
