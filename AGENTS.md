# AGENTS.md — APIUsageStatus 项目指南

> 面向 AI 编码代理的项目说明。假设读者对本项目一无所知。

## 1. 项目概览

**APIUsageStatus** 是一个纯菜单栏（`LSUIElement`，无 Dock 图标）的 macOS 自用应用，实时监控多家 AI 服务商的 API 用量与余额：

| 供应商 | 监控维度 | 数据源 |
|--------|---------|--------|
| MiniMax | 多指标：每个能力桶（`general`/`video`/`speech-hd` 等 `model_name`）独立跟踪 5h + weekly 双窗口 | `www.minimaxi.com/v1/token_plan/remains` |
| DeepSeek | 充值/赠送/总余额、货币单位；峰谷时段指示（北京时间 09:00–12:00、14:00–18:00） | `api.deepseek.com/user/balance` |
| GitHub Copilot | 月度 `premium_interactions` 剩余百分比 | `api.github.com/copilot_internal/user` |
| OpenCode Go | 5h / weekly / monthly 窗口用量百分比（服务端记账，仅套餐内用量） | `opencode.ai/zen/go/v1/usage`（Zen API Key） |
| Kimi | 5h 滚动限流窗口 + 周订阅配额百分比 | `api.kimi.com/coding/v1/usages` |

功能：菜单栏双行堆叠图标（每启用 metric 一个槽位）、点击弹出用量面板、阈值告警系统通知、余额历史追踪（周/月/近7天/近30天日均）、Deep-Link 到各供应商 Web 控制台。

**技术栈**：Swift 5.9 / SwiftUI + AppKit，macOS ≥ 13.0，Xcode ≥ 14.3。**零外部依赖**——仅使用系统框架（AppKit、SwiftUI、Security、UserNotifications）。

## 2. 关键配置文件

- `project.yml` — XcodeGen 工程定义（target、构建设置、entitlements）。改 target/设置后运行 `xcodegen generate` 重新生成 `.xcodeproj`
- `APIUsageStatus.xcodeproj/` — 由 XcodeGen 生成，不要手工编辑
- `APIUsageStatus/Resources/Info.plist` — `LSUIElement=true`、版本号
- `APIUsageStatus/APIUsageStatus.entitlements` — **App Sandbox 已禁用**（`OpenCodeWorkspaceResolver` 需 shell 出 `/usr/bin/grep` 扫描本地 OpenCode 日志以恢复 workspace ID）；仅保留 network client 与 user-selected 文件只读权限
- `docs/ARCHITECTURE.md` — 权威架构文档（ADR-001），含模块拆解、数据流图、并发模型、Keychain/网络层设计
- `docs/PRD.md`、`docs/DEVELOPMENT_PLAN.md` — 产品需求与开发计划
- `docs/provider-interfaces/` — 各供应商 API 数据契约（minimax / deepseek / copilot / kimi / opencode_go）
- `.omo/plans/*.md` — 历史重构记录（见 §7 工作原则）

## 3. 代码组织与架构

**模块化单体**。依赖方向仅向下：UI 层 → `AppState`（Actor，唯一数据源）→ 服务层/供应商层。详细设计见 `docs/ARCHITECTURE.md`。

```
APIUsageStatus/
├── APIUsageStatusApp.swift   # @main 入口 + AppDelegate
├── MenuBar/                  # MenuBarController（NSStatusItem + 浮动面板窗口）+ MenuBarIconRenderer（SF Pro 8pt 双行绘制、呼吸动画）
├── Views/                    # SwiftUI 视图：UsagePanelView / UsageCardView / InstanceDetailPanel / SettingsWindow+SettingsView+SettingsViewModel / InstanceEditorView 等
├── AppState/                 # AppState（Actor，运行时唯一数据源）+ AppStateProxy（@MainActor ObservableObject 桥接）
├── Models/                   # Instance / MetricConfig / MetricSnapshot / SlotViewData / Thresholds / GlobalSettings / PeakPeriod / BreathingMath 等
├── Services/                 # RefreshService（Actor，刷新编排、cycle 抢占、单实例刷新）/ PersistenceService / KeychainService / NotificationManager / LimitRolloverDetector / AppLaunchService
├── Suppliers/                # Supplier 协议 + 各供应商实现与 Parser（MiniMax/DeepSeek/Copilot/OpenCode/Kimi）+ SupplierRegistry
├── Network/                  # NetworkClient（URLSession async/await）+ Endpoint + RetryPolicy（指数退避最多 3 次，协作取消）
├── Balance/                  # BalanceCalculator（纯逻辑）+ BalanceSnapshot
├── PixelFont/                # ⚠️ 已弃用：原像素字模引擎，代码已注释，保留供历史参考
├── Extensions/               # Date/Decimal/String/Color/Data 扩展、Provider 图标
├── Utilities/                # os.Logger 封装 + 原子文件写入
└── Resources/                # Info.plist + AppIcon 源文件
APIUsageStatusTests/          # 单元测试 + 快照测试；ReferenceImages/ 存快照基准 PNG
```

**核心并发约定**：

- `AppState`、`RefreshService`、`PersistenceService`、`KeychainService`、`NetworkClient` 均为 Actor；UI 通过 `AppStateProxy`（`@MainActor`）观察
- 刷新 cycle 槽位契约：任意时刻最多一个 cycle；手动刷新抢占式（`CycleToken` 引用相等判定 owner，被抢占方跳过清理写入），定时/单实例刷新非抢占；`Task.cancel()` 必须能穿透网络层（`URLError(.cancelled)` → `CancellationError` 不触发重试）
- **供应商特定逻辑只归属 Supplier/Parser 层**：通用执行路径（`AppState`/`RefreshService`）只识别 `MetricConfig.key` 与 `MetricCycleEndPolicy` 枚举，禁止出现 `Provider.xxx` 字面判断

**持久化**：`instances.json`（实例配置+全局设置）与 `{uuid}.json`（余额历史）存于 Application Support，一律原子写入（临时文件→重命名）；API Key 只存 Keychain（`kSecClassInternetPassword`，server=`"APIUsageStatus"`，account=`api_key_ref`），绝不明文落盘、不入日志。

## 4. 构建、签名与部署

### 环境问题（必读）

本机 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`（仅命令行工具），但 Xcode 安装在 `/Applications/Xcode.app`。直接跑 `xcodebuild` 会报 `tool 'xcodebuild' requires Xcode`。**所有 `xcodebuild` 命令前必须设置 `DEVELOPER_DIR`**。

### 编译

```bash
cd /Users/linletian/Documents/SoftwareWorkspace/api-usage-status

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Release \
  -derivedDataPath ./tmp/DerivedData \
  build
```

> `-derivedDataPath ./tmp/DerivedData` 是必须的：默认 DerivedData 路径（`~/Library/Developer/Xcode/DerivedData`）存在权限问题，会导致构建失败。

如需重新生成工程文件：`brew install xcodegen && xcodegen generate`。若 brew 安装失败（本机 macOS 13 无法源码构建 xcodegen），用 `tmp/xcodegen-dist/xcodegen/bin/xcodegen generate`（GitHub release 预编译二进制，已验证可用）。

### 签名

构建产物默认无签名，需 ad-hoc 签名后才能被 macOS 启动（系统通知也要求已签名，ad-hoc 足够）：

```bash
ditto tmp/DerivedData/Build/Products/Release/APIUsageStatus.app APIUsageStatus.app
codesign --force --sign - APIUsageStatus.app
```

> 用 `ditto` 而非 `cp`：`cp` 复制 App Bundle 扩展属性时可能因沙箱权限失败。
> 编译产物仅为 `.app` Bundle，不需要打包 `.zip`。

### 部署到 /Applications

沙箱无法直接写入 `/Applications`，**必须由用户手动执行**：

```bash
killall APIUsageStatus 2>/dev/null
rm -rf /Applications/APIUsageStatus.app
cp -R APIUsageStatus.app /Applications/
open /Applications/APIUsageStatus.app
```

### 一键构建+签名

```bash
cd /Users/linletian/Documents/SoftwareWorkspace/api-usage-status && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project APIUsageStatus.xcodeproj -scheme APIUsageStatus \
  -configuration Release -derivedDataPath ./tmp/DerivedData build && \
  ditto tmp/DerivedData/Build/Products/Release/APIUsageStatus.app APIUsageStatus.app && \
  codesign --force --sign - APIUsageStatus.app && \
  echo "构建+签名完成，请手动复制到 /Applications"
```

### xcodebuild 日志规范（强制）

xcodebuild 全量日志极大，会耗尽 context：

1. **严格禁止直接读取 xcodebuild 全量日志**（`2>&1` 直读或 `tee` 到文件再 `Read` 都算违规）
2. 优先使用 `xcbeautify` / `xcpretty` 等精简工具的静默参数包装
3. 必须用 `grep` 检索关键内容：`error:`、`warning:`、`Compiling`、`Linking`、测试失败用例名等
4. 确实需要读全量日志时，必须先向用户说明原因与范围并征得同意

## 5. 测试

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project APIUsageStatus.xcodeproj \
  -scheme APIUsageStatus \
  -configuration Debug \
  -derivedDataPath ./tmp/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  test
```

> `CODE_SIGNING_ALLOWED=NO` 是必须的：工程无 `DEVELOPMENT_TEAM`，test bundle 会被 ad-hoc 签名，macOS 拒绝 dlopen（`mapped file has no Team ID`），测试在加载阶段就失败。

**测试策略**：

- XCTest 框架，`@testable import APIUsageStatus`，无第三方测试库
- 覆盖：各供应商 Response Parser（MiniMax/DeepSeek/Copilot/OpenCode/Kimi）、RefreshService（cycle 槽位契约 `RefreshServiceCycleSlotTests`、映射）、PersistenceService、BalanceCalculator、RetryPolicy、菜单栏渲染、DeepSeek 峰谷窗口分类（`PeakPeriodTests`，21 个北京时间边界用例，其中 6 个覆盖 `policyVersion "2026-09"` 引入的周末短路规则——issue #19）、SwiftUI 视图
- **快照测试（Golden Master）**：`MenuBarIconRendererTests` 等将渲染结果与 `APIUsageStatusTests/ReferenceImages/*.png` 逐字节比对。基准 PNG 需提交 Git。渲染逻辑有意变更后重新生成基准：
  ```bash
  REGENERATE_MENUBAR_REFS=1 xcodebuild ... test   # 覆盖写入基准并通过
  # 然后不带环境变量重跑一次，验证新基准匹配
  ```
  首次运行缺基准时测试会生成 PNG 并**故意失败一次**（"Re-run test to verify"），属预期行为
- `PixelFontEngineTests.swift` 整体被 `#if false` 门控（对应已弃用的 PixelFont 模块），不运行
- 新增逻辑应配测试——项目对 parser、纯函数检测器（如 `LimitRolloverDetector.detect`）、边界分类均有成体系用例，照此模式补充

## 6. 代码风格约定

- 语言：Swift 5.9，严格并发模型（Actor 隔离、`@MainActor`）；纯逻辑（BalanceCalculator、Parser、LimitRolloverDetector）写成无状态纯函数便于测试
- 注释/文档：代码注释以英文为主，`docs/` 设计文档以中文为主，README 双语（`README.md` 英文 / `README_zh-CN.md` 中文）
- 语义色令牌集中在 `Extensions/Color+Theme.swift`，视图层不硬编码颜色，需支持 Light/Dark 模式
- 供应商响应字段映射全部收敛到对应 `*ResponseParser`，API 格式变化只改 Parser，不动上游
- 不引入第三方依赖；新增能力优先用系统框架实现

## 7. 工作原则（文档优先）

任何对源码、配置或工作流的修改，**先看文档，再动代码**：

1. **改之前先读**：先翻阅 `docs/`、`README*.md`、`AGENTS.md`、相关 `.omo/plans/`，确认要改的东西在文档里的当前表述。读不到对应文档 = 文档要补
2. **改代码的同时改文档**：源码与文档必须同 commit 提交。代码改了文档没改 = 提交不完整
3. **删代码先删文档**：被删除的 API、文件、机制，必须在删除 commit 之前先清理所有引用它的文档段落（包括 `docs/`、根目录 `README*.md`、相关 plan）。`grep` 出零结果才算清干净
4. **新机制先写设计文档**：任何引入新依赖、新动画机制、新持久化结构、新公共 API 的改动，开工前先在 `docs/` 下落一份说明（动机、对比、参数、生命周期），再写实现
5. **plan 是历史记录**：`.omo/plans/*.md` 记录某次重构的来龙去脉。不要为了"和当前 plan 一致"而保留过时实现，也不要重写历史 plan；新决策写进 `docs/`，必要时在 plan 顶部加 `> 状态：已被 X 方案取代` 指针

判定"文档已同步"的硬性检查：`git grep -nE "旧关键词|旧文件名" -- ':!*.lock' ':!build/' ':!tmp/'` 在新代码上无相关业务匹配。

## 8. 安全注意事项

- **API Key**：仅存 Keychain，绝不写入磁盘明文、`UserDefaults` 或日志
- **网络**：仅 HTTPS 访问各供应商已知 API 端点，不外传用户数据
- **App Sandbox 已禁用**：唯一原因是 `OpenCodeWorkspaceResolver` 需 shell 出 `/usr/bin/grep` 扫描 `~/.local/share/opencode/log/` 恢复 workspace ID（「See details」深链）。用量查询本身已走官方 HTTP API（`opencode.ai/zen/go/v1/usage`），无任何本地子进程依赖。改动时不得扩大子进程调用范围
- **日志**：os.Logger，生产环境敏感信息自动脱敏
- **ad-hoc 签名**下 Keychain 正常工作，无需付费开发者账号

## 9. 其他注意事项

- LSUIElement 应用无 Dock 图标，退出需通过菜单栏右键 → Quit
- MiniMax API 已迁移到新 schema（`current_interval_status` / `current_interval_remaining_percent` 替代旧 count 字段），用户实例的 `dimension` 需与 API 返回的 `model_name` 一致
- DeepSeek 峰谷判定固定为北京时间（UTC+8），边界评估粒度 60 秒，菜单栏 overlay 在窗口边缘最多晚一分钟翻转（见 `docs/provider-interfaces/deepseek.md` §11）
