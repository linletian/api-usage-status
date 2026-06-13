# APIUsageStatus

> **语言：** [English](README.md) | 简体中文

一个专为 macOS 13 设计的纯菜单栏 macOS 应用，实时监控 MiniMax / DeepSeek 的 API 用量与余额。
**因主流同类应用不兼容 macOS13，故本项目仅为自用脚手架项目。**

## 功能概览

- **菜单栏图标** — SF Pro 8pt 渲染，2 行堆叠布局，最多同时展示 2 个实例的用量状态
- **用量面板** — 点击图标弹出浮动窗口，展示用量卡片、错误汇总、手动刷新和设置入口
- **周配额展示** — MiniMax 实例卡片底部展示周窗口进度条；无限额计划用青蓝辉光条动画呈现
- **阈值告警** — 配额百分比或余额金额触发 macOS 系统通知，点击通知查看详情
- **余额追踪** — 记录历史快照，按周/月/近7天/近30天展示日均消耗
- **零外部依赖** — 仅使用 AppKit、SwiftUI、Security 等系统框架

<img src="docs/README_assets/ScreenShot.png" alt="用量面板截图" style="max-width: 100%;">

### 支持的供应商

| 供应商 | 监控维度 | API 端点 |
|--------|---------|---------|
| MiniMax | 每个 `model_name`（如 `general` 文本、`video` 非文本）的 5h 窗口与周窗口剩余百分比 | `www.minimaxi.com/v1/token_plan/remains` |
| DeepSeek | 充值金额、赠送金额、总余额、货币单位 | `api.deepseek.com/user/balance` |

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
2. 点击 **+** 添加实例
3. 选择供应商、填入维度、输入 API Key（保存在 Keychain 中）
4. 配置告警阈值
5. 菜单栏图标将自动刷新为用量状态

## 运行测试

```bash
xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Debug \
  test
```

或在 Xcode 中按 Cmd+U。

### 测试套件（共 64 个用例，不含已弃用）

| 套件 | 数量 | 覆盖范围 |
|------|------|---------|
| BalanceCalculatorTests | 14 | 消耗计算、跨日归档、充值检测、日均统计、历史裁剪 |
| MiniMaxResponseParserTests | 10 | 正常解析、鉴权错误、业务错误、畸形 JSON、多模型、周字段 |
| DeepSeekResponseParserTests | 8 | CNY 优先解析、降级回退、is_available=false、空数组 |
| RetryPolicyTests | 6 | 重试行为、退避延迟、最大尝试次数 |
| WeeklyQuotaTests | 10 | 周字段解析、isUnlimited 判定、缺失字段回退 |
| FlowingGlowBarTests | 5 | 辉光条相位、宽度、几何约束 |
| MenuBarIconRendererTests | 11 | 所有图标状态的快照对比测试 |
| ~~PixelFontEngineTests~~ | ~~58~~ | ~~（已弃用）原像素字模引擎测试，代码已注释，不参与运行~~ |

## 部署到 /Applications

```bash
# 复制 Release 包
cp -R build/Release/APIUsageStatus.app /Applications/

# 首次运行需绕过 Gatekeeper（右键 → 打开），或执行：
xattr -cr /Applications/APIUsageStatus.app
```

然后在应用的 Settings 中启用「开机自启」即可。

## 项目结构

```
APIUsageStatus/
├── APIUsageStatusApp.swift        # @main 入口 + NSApplicationDelegate
├── MenuBar/                       # 菜单栏图标与用量面板控制器
├── Views/                         # SwiftUI 视图（面板/卡片/设置/详情）
├── AppState/                      # 运行时状态 Actor + @MainActor 代理
├── Models/                        # 数据模型（实例/余额/阈值/全局设置）
├── Services/                      # 核心服务（Keychain/持久化/刷新/通知/开机自启）
├── Network/                       # HTTP 客户端 + 重试策略
├── Suppliers/                     # 供应商协议 + MiniMax / DeepSeek 实现
├── Balance/                       # 余额计算器 + 历史快照
├── PixelFont/                     # ⚠️ 已弃用：原像素字体引擎（代码已注释）
├── Extensions/                    # Date/Decimal/String 扩展
├── Utilities/                     # 日志 + 原子写入
├── Resources/                     # Info.plist + AppIcon 源文件
└── Assets.xcassets/               # 编译期 AppIcon 图标集
APIUsageStatusTests/
├── BalanceCalculatorTests.swift
├── MiniMaxResponseParserTests.swift
├── DeepSeekResponseParserTests.swift
├── RetryPolicyTests.swift
├── WeeklyQuotaTests.swift
├── FlowingGlowBarTests.swift
├── MenuBarIconRendererTests.swift
├── ~~PixelFontEngineTests.swift~~  # 已弃用（代码已注释）
└── ReferenceImages/               # 快照测试金标准图片
```

## 安全与隐私

- **App Sandbox** — 所有文件 I/O 限定在沙盒容器内
- **API Key** — 存储在 Keychain（InternetPassword 类型），不落磁盘明文
- **网络** — 仅 HTTPS 访问供应商 API，不传输任何用户数据
- **日志** — os.Logger，生产环境自动屏蔽敏感信息
