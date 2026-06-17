# APIUsageStatus

> **语言：** [English](README.md) | 简体中文

一个专为 macOS 13 设计的纯菜单栏 macOS 应用，实时监控 MiniMax / DeepSeek 的 API 用量与余额。
**因主流同类应用不兼容 macOS13，故本项目仅为自用脚手架项目。**

## 功能概览

- **菜单栏图标** — SF Pro 8pt 渲染，2 行堆叠布局，每个启用实例独立占一个槽位（数量无上限），宽度由内容决定
- **用量面板** — 点击图标弹出浮动窗口，展示用量卡片、错误汇总、手动刷新和设置入口
- **周配额展示** — MiniMax 实例卡片底部展示周窗口进度条；无限额计划用青蓝辉光条动画呈现
- **阈值告警** — 配额百分比或余额金额触发 macOS 系统通知，点击通知查看详情
- **余额追踪** — 记录历史快照，按周/月/近7天/近30天展示日均消耗
- **零外部依赖** — 仅使用 AppKit、SwiftUI、Security 等系统框架。OpenCode Go 供应商需本地安装 `opencode` CLI

<img src="docs/README_assets/ScreenShot.png" alt="用量面板截图" style="max-width: 100%;">

### 支持的供应商

| 供应商 | 监控维度 | 数据来源 |
|--------|---------|---------|
| MiniMax | 每个 `model_name`（如 `general` 文本、`video` 非文本）的 5h 窗口与周窗口剩余百分比 | `www.minimaxi.com/v1/token_plan/remains` |
| DeepSeek | 充值金额、赠送金额、总余额、货币单位 | `api.deepseek.com/user/balance` |
| GitHub Copilot | 月度 `premium_interactions` 剩余百分比（Free / Pro / Pro+ / Business / Enterprise 全覆盖） | `api.github.com/copilot_internal/user` |
| OpenCode Go | 5h / 每周 / 每月窗口的美元用量（上限 $12 / $30 / $60） | 本地 SQLite，通过 `opencode db` CLI 读取 |

### 凭据配置

各供应商的认证方式不同。所有凭证均存储在 macOS Keychain（InternetPassword 类型），不会以明文落盘。

- **MiniMax** — 粘贴 MiniMax 开发者控制台签发的 Token Plan Key。该 Key 与按量计费 API Key 相互独立。
- **DeepSeek** — 粘贴 DeepSeek 开放平台账户的 API Key。
- **GitHub Copilot** — 粘贴 **GitHub Personal Access Token (PAT)**。与前两者不同，Copilot 自身不签发 API Key，而是通过你的 GitHub 身份访问。

  PAT 生成步骤：
  1. 打开 https://github.com/settings/tokens
  2. 点击 **Generate new token** → **Generate new token (classic)**（注意：Fine-grained PAT 不支持 `copilot` scope）
  3. **Note**：任意备注，如 `api-usage-status-copilot`
  4. **Expiration**：建议 90 天（或按需 `No expiration`）
  5. **Scopes**：**只勾** `copilot` —— 最小权限原则
  6. 点击 **Generate token**，**立即复制**（GitHub 仅展示一次）
  7. 粘贴到本应用 Settings → Add Instance → Provider `GitHub Copilot` → API Key 框

  注意事项：
  - Token 对应的 GitHub 账号必须已开通 Copilot 订阅（Free / Pro / Pro+ / Business / Enterprise 均可）
  - 可随时在 https://github.com/settings/tokens 撤销

- **OpenCode Go** — 无需 API Key。供应商通过 shell 调用本地 `opencode` CLI（需安装在 `~/.opencode/bin/opencode`、`/usr/local/bin/opencode` 或 `/opt/homebrew/bin/opencode`），直接读取 OpenCode SQLite 数据库（`~/.local/share/opencode/opencode.db`）中的用量数据。详见 `docs/provider-interfaces/opencode_go.md`

## 系统要求

| 项目 | 要求 |
|------|------|
| macOS | ≥ 13.0（Ventura） |
| Xcode | ≥ 14.3（Swift 5.9） |
| 可选 | [XcodeGen](https://github.com/yonaskolb/XcodeGen)（用于重新生成 .xcodeproj） |

## 构建与运行

### 1. 生成 Xcode 项目（如需要）

```bash
brew install xcodegen
xcodegen generate
```

### 2. 命令行构建

```bash
# Debug 构建
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Debug \
  build

# Release 构建（ad-hoc 签名）
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Release \
  build
```

### 3. Xcode 中运行

```bash
open APIUsageStatus.xcodeproj
```

然后 Cmd+R 运行。应用启动后会在菜单栏显示 `?` 图标（无 Dock 图标）。

### 4. 首次配置

1. 点击菜单栏图标 → **Settings**
2. 点击 **+**（首次使用点击 **Add Your First Instance**）添加实例
3. 选择供应商 —— MiniMax 可选择要跟踪的模型及窗口（5h / weekly）；其他供应商自动配置默认指标
4. 输入显示名和 2-3 个字符的简称（用于菜单栏），粘贴 API Key（保存在 Keychain 中）
5. 配置告警阈值
6. 菜单栏图标将自动刷新为用量状态

## 运行测试

```bash
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Debug \
  test
```

或在 Xcode 中按 Cmd+U。

### 测试套件（共 159 个用例，不含已弃用）

| 套件 | 数量 | 覆盖范围 |
|------|------|---------|
| BalanceCalculatorTests | 14 | 消耗计算、跨日归档、充值检测、日均统计、历史裁剪 |
| MiniMaxResponseParserTests | 11 | 正常解析、鉴权错误、业务错误、畸形 JSON、多模型、周字段 |
| DeepSeekResponseParserTests | 8 | CNY 优先解析、降级回退、is_available=false、空数组 |
| CopilotResponseParserTests | 12 | GitHub Copilot API 响应解析、token scopes、错误响应 |
| RetryPolicyTests | 6 | 重试行为、退避延迟、最大尝试次数 |
| WeeklyQuotaTests | 10 | 周字段解析、isUnlimited 判定、缺失字段回退 |
| FlowingGlowBarTests | 5 | 辉光条相位、宽度、几何约束 |
| MenuBarIconRendererTests | 15 | 属性断言+快照：呼吸状态跟踪、阴影、动画生命周期、单色模式、多槽位 |
| OpenCodeResponseParserTests | 11 | 真实数据解析、窗口算法测试、makeResponse 结构验证 |
| ShellProcessRunnerTests | 4 | 成功执行、可执行文件不存在、非零退出码、超时 |
| BreathingMathTests | 17 | 呼吸动画相位、阴影半径、阴影透明度、配置校验 |
| InstanceCardViewTests | 12 | 渲染（显示名、subtitle、shortName 徽章、切换开关、按钮）、编辑/删除回调、供应商显示名映射 |
| SettingsViewModelTests | 12 | 侧边栏导航（Services/General/About）、表单绑定（刷新间隔、色彩模式、开机自启、通知） |
| ProviderPickerAndThresholdTests | 13 | 供应商选择器 UI、MiniMax 模型选择、阈值校验（配额 + 余额） |
| StatusDotViewTests | 2 | trackingOn/trackingOff 颜色令牌的像素级快照验证 |
| EmptyStateGuideViewTests | 4 | 空状态渲染（图标、文字、CTA 按钮）、按钮回调 |
| ProviderIconTests | 3 | 全部 4 个供应商的 SF Symbol 名称映射 |
| ~~PixelFontEngineTests~~ | ~~58~~ | ~~（已弃用）原像素字模引擎测试，代码已注释，不参与运行~~ |

## 部署到 /Applications

```bash
# 复制 Release 包
cp -R build/Release/APIUsageStatus.app /Applications/

# 首次运行需绕过 Gatekeeper（右键 → 打开），或执行：
xattr -cr /Applications/APIUsageStatus.app
```

> 注意：`xattr -cr` 仅适用于从外部获取的 `.app` 包（例如从网络下载、从外接硬盘拷贝、或从 release 压缩包解压）。本地编译产物的 `.app` 不会带隔离标记，无需此命令。

然后在应用的 Settings 中启用「开机自启」即可。

## 项目结构

```
APIUsageStatus/
├── APIUsageStatusApp.swift        # @main 入口 + NSApplicationDelegate
├── MenuBar/                       # 菜单栏图标与用量面板控制器
├── Views/                         # SwiftUI 视图（面板/卡片/设置/详情）
├── AppState/                      # 运行时状态 Actor + @MainActor 代理
├── Models/                        # 数据模型（实例/余额/阈值/全局设置、BreathingMath）
├── Services/                      # 核心服务（Keychain/持久化/刷新/通知/开机自启）
├── Shell/                         # Shell 进程执行（OpenCode Go 供应商使用）
├── Network/                       # HTTP 客户端 + 重试策略
├── Suppliers/                     # 供应商协议 + MiniMax / DeepSeek / Copilot / OpenCode 实现
├── Balance/                       # 余额计算器 + 历史快照
├── PixelFont/                     # ⚠️ 已弃用：原像素字体引擎（代码已注释）
├── Extensions/                    # Date/Decimal/String 扩展
├── Utilities/                     # 日志 + 原子写入 + CVDisplayLinkRunner（呼吸动画驱动）
├── Resources/                     # Info.plist + AppIcon 源文件
└── Assets.xcassets/               # 编译期 AppIcon 图标集
APIUsageStatusTests/
├── BalanceCalculatorTests.swift
├── MiniMaxResponseParserTests.swift
├── DeepSeekResponseParserTests.swift
├── CopilotResponseParserTests.swift
├── RetryPolicyTests.swift
├── WeeklyQuotaTests.swift
├── FlowingGlowBarTests.swift
├── MenuBarIconRendererTests.swift
├── OpenCodeResponseParserTests.swift
├── ShellProcessRunnerTests.swift
├── BreathingMathTests.swift
├── ~~PixelFontEngineTests.swift~~  # 已弃用（代码已注释）
└── ReferenceImages/               # 快照测试金标准图片
```

## 安全与隐私

- **⚠️ App Sandbox** — **已关闭**，以便 OpenCode Go 供应商能通过 `Process.run()` 执行 `opencode db` 命令读取本地 SQLite 数据库。这是查询 OpenCode Go 用量的唯一途径（无公开 REST API）。权衡说明：
  - **获得**：OpenCode Go 实时用量监控（5h / 每周 / 每月窗口），直接从本地数据读取，无需等待官方 API。
  - **失去**：macOS App Sandbox 保护。应用理论上可以访问当前用户可访问的任何文件，以及启动子进程。但本项目为自编译自用——仅与已知的 HTTPS API 端点通信，仅启动 `opencode` CLI，不处理不可信用户输入。在个人使用场景下，实际攻击面增加可忽略不计。详见 `docs/provider-interfaces/opencode_go.md`。
  - **若不使用 OpenCode Go**：唯一需要关闭沙箱的代码路径是 `ShellProcessRunner`（仅由 `OpenCodeSupplier` 调用）。MiniMax / DeepSeek / Copilot 供应商在开启或关闭沙箱下行为完全一致。
- **API Key** — 存储在 Keychain（InternetPassword 类型），不落磁盘明文
- **网络** — 仅 HTTPS 访问供应商 API，不传输任何用户数据
- **日志** — os.Logger，生产环境自动屏蔽敏感信息
