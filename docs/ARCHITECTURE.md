# 架构文档：API Usage Status

## ADR-001：项目架构

- **状态**：提议中
- **日期**：2026-05-14

---

## 目录

1. [高层架构概览](#1-高层架构概览)
2. [模块拆解](#2-模块拆解)
3. [数据流图](#3-数据流图)
4. [数据模型与存储设计](#4-数据模型与存储设计)
5. [Keychain 集成设计](#5-keychain-集成设计)
6. [网络层设计](#6-网络层设计)
7. [菜单栏渲染管线](#7-菜单栏渲染管线)
8. [像素字模系统设计](#8-像素字模系统设计)
9. [状态管理方案](#9-状态管理方案)
10. [错误处理策略](#10-错误处理策略)
11. [并发模型](#11-并发模型)
12. [文件与目录结构](#12-文件与目录结构)
13. [关键设计决策与权衡](#13-关键设计决策与权衡)
14. [质量属性分析](#14-质量属性分析)

---

## 1. 高层架构概览

### 1.1 架构风格

**模块化单体** —— 单进程 macOS 应用，内部模块边界清晰。对于菜单栏工具而言，微服务架构是过度设计；模块化单体在编译期间实现关注点分离，无需承担进程间通信（IPC）的运维开销。

### 1.2 组件图

```
┌──────────────────────────────────────────────────────────────────────┐
│                        API Usage Status.app                          │
│                                                                      │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────────┐ │
│  │  应用入口    │   │  菜单栏      │   │    设置窗口              │ │
│  │  (AppDelegate│   │  控制器      │   │    (NSWindow +           │ │
│  │   + @main)  │   │  (NSStatusBar│   │     SwiftUI)              │ │
│  │              │   │   + 渲染器)  │   │                          │ │
│  └──────┬───────┘   └──────┬───────┘   └────────────┬─────────────┘ │
│         │                  │                         │               │
│         └──────────────────┼─────────────────────────┘               │
│                            │                                         │
│              ┌─────────────┴─────────────┐                          │
│              │     AppState（Actor）     │                          │
│              │  - instances: [Instance]  │                          │
│              │  - slotData: [SlotData]   │                          │
│              │  - refreshState: enum     │                          │
│              │  - errorSummary: [Error]  │                          │
│              └─────────────┬─────────────┘                          │
│                            │                                         │
│     ┌──────────────────────┼──────────────────────┐                 │
│     │                      │                      │                 │
│  ┌──┴──────────┐   ┌───────┴───────┐   ┌─────────┴────────┐       │
│  │  服务层     │   │  持久化       │   │   像素字模       │       │
│  │  （Actor）  │   │  （Actor）    │   │   引擎           │       │
│  │             │   │               │   │   （纯函数）     │       │
│  │ - 刷新调度  │   │ - JSON 读/写  │   │                  │       │
│  │ - API HTTP  │   │ - Keychain    │   │ - 字符映射表    │       │
│  │ - 重试/退避 │   │   读/写       │   │ - 渲染器        │       │
│  │ - 请求去重  │   │ - 余额历史    │   │ - 布局计算      │       │
│  │             │   │   操作        │   │                  │       │
│  └──────┬──────┘   └───────┬───────┘   └─────────────────┘       │
│         │                  │                                       │
│         │          ┌───────┴───────┐                              │
│         │          │   文件系统    │                              │
│         │          │  + Keychain   │                              │
│         │          └───────────────┘                              │
│         │                                                          │
│  ┌──────┴──────────┐                                              │
│  │   供应商实现    │                                              │
│  │   （协议）      │                                              │
│  │                 │                                              │
│  │ - MiniMax       │                                              │
│  │ - DeepSeek      │                                              │
│  │ - （可扩展）    │                                              │
│  └─────────────────┘                                              │
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │  通知管理器                                                  │   │
│  │  - UNUserNotificationCenter                                  │   │
│  │  - 阈值评估                                                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘

         ┌──────────────────┐       ┌──────────────────┐
         │  MiniMax API     │       │  DeepSeek API    │
         │  （HTTPS）       │       │  （HTTPS）       │
         └──────────────────┘       └──────────────────┘
```

### 1.3 依赖方向

```
┌─────────────────────────────────────────────────┐
│          UI 层（SwiftUI + AppKit）              │
│  MenuBarController, UsagePanelWindow, SettingsWindow  │
└──────────────────────┬──────────────────────────┘
                       │ 依赖
┌──────────────────────▼──────────────────────────┐
│              AppState（Actor）                   │
│              唯一数据源                          │
└──────────────────────┬──────────────────────────┘
                       │ 依赖
┌──────────────────────▼──────────────────────────┐
│            领域 / 服务层                         │
│  RefreshService, PersistenceService,             │
│  NotificationManager,                            │
│  Supplier 实现                                   │
└─────────────────────────────────────────────────┘
```

依赖方向**仅向下**。UI 层从 `AppState` 读取状态；服务层向 `AppState` 写入状态。无循环依赖。

---

## 2. 模块拆解

### 2.1 应用入口（`APIUsageStatusApp.swift`）

**职责**：应用生命周期、App Delegate、菜单栏初始化。

- `@main` App 结构体
- `AppDelegate`（NSApplicationDelegate）：设置 `NSStatusItem`，创建 `MenuBarController`
- 注册 `SMAppService` 以支持开机自启
- 请求通知权限

### 2.2 菜单栏控制器（`MenuBarController.swift`）

**职责**：持有 `NSStatusItem`，管理浮动用量面板窗口（`NSWindow`），协调图标渲染与点击处理。

- 管理单个可变长度的 `NSStatusItem`
- 监听 `AppState` 的槽位数据变化 → 触发重绘
- 左键单击 → 切换浮动用量面板（`NSWindow` 内嵌 `UsagePanelView`，窗口失焦时自动关闭，模拟 popover 行为）
- 右键 → `NSMenu`：立即刷新 / 打开设置 / 退出
- 通过 `MenuBarIconRenderer` 处理 `NSStatusBarButton` 的自定义绘制

**为何用 `NSWindow` 替代 `NSPopover`**：`LSUIElement` 应用中的 `NSPopover` 存在已知问题 —— 键盘快捷键（Cmd+C/V 等）无法正确路由到文本输入框，影响 API Key 等输入体验。`NSWindow`（隐藏标题栏 + floating level）提供完全正常的键盘事件响应，同时通过 `NSWindowDelegate.windowDidResignKey` 实现点击外部自动关闭，行为与 popover 一致。

### 2.3 菜单栏图标渲染器（`MenuBarIconRenderer.swift`）

**职责**：使用系统字体绘制菜单栏图标。

- 创建适配状态栏按钮尺寸的 `NSImage`
- 对每个活跃槽位（最多 2 个），采用**双行层叠布局**：第一行绘制服务商简称（2 字母），第二行绘制余额或百分比，每行各自水平居中
- 字体：SF Pro Regular 8pt，配额型百分比使用等宽变体（`.monospacedSystemFont` 8pt）以保证数字对齐
- 1 个槽位时宽度自适应内容；2 个槽位时严格 50/50 等宽
- 支持单色与彩色两种模式
- 处理特殊状态：AI 品牌标识 + 循环 % 动画（两行布局，无实例时自动播放，有实例后停止，通过 startDefaultAnimation() / stopDefaultAnimation() / isDefaultAnimationRunning 管理）、`NO API`（全部禁用）、`•••`（加载中）、`N/A`（余额不可用）
- 实现严重阈值的呼吸动画（warning 4s 周期，critical 2.0s 周期）

### 2.4 用量面板与独立详情面板（`UsagePanelView.swift`、`UsageCardView.swift`、`InstanceDetailPanel.swift`）

**职责**：按实例展示用量卡片的 UI。

- `UsagePanelView`：承载可滚动的卡片列表 + 错误摘要栏 + 刷新按钮 + 设置入口（窗口内）
- `UsageCardView`：单实例卡片 —— 配额型显示进度条 + 下次刷新剩余时间（分钟数），自然天/周配额型额外显示周期剩余天数；余额型显示余额 + 每日统计。卡片底部 footer 区域左侧显示「See details」按钮（仅当 provider 有对应 Web 控制台 URL 时可见），点击通过 `NSWorkspace.shared.open(_:)` 在默认浏览器打开用量详情页。URL 映射逻辑集中在 `UsageCardView.providerURL`（按 `Provider` enum 派发）：DeepSeek / MiniMax / GitHub Copilot 直接返回硬编码 URL；OpenCode 调用 `OpenCodeWorkspaceResolver.cachedWorkspaceID()`（零 IO 同步读 UserDefaults），缓存未命中时兜底到 `https://opencode.ai/zh/go`。日志扫描在 App 启动时由 `OpenCodeWorkspaceResolver.prewarm()` 后台完成（详见 §2.15）；右侧显示最近一次刷新时间
- `InstanceDetailPanel`：点击通知后弹出的独立 `NSPanel`，展示单个实例的完整用量详情（与 UsageCardView 展示相同信息，但以独立窗口形式呈现，失活时自动关闭）
- 以上均为观察 `AppStateProxy` 的 SwiftUI 视图

### 2.5 设置窗口（`SettingsWindow.swift`、`SettingsViewModel.swift`）

**职责**：实例管理与全局设置。

- `SettingsWindow`：包裹 SwiftUI `SettingsView` 的 `NSWindow`，窗口关闭时若存在未保存变更则弹出提示框
- `SettingsView`：基于 macOS sidebar 导航（Services / General / About 三个分区，180pt 宽，SF Symbols 图标）
  - Services 分区：实例列表，每行使用 `InstanceCardView`（含 StatusDot 跟踪状态指示器、displayName + subtitle、shortName monospace 徽章、跟踪开关、编辑/删除按钮），支持拖拽排序（`.onMove`）
  - General 分区：全局设置（刷新间隔、菜单栏图标风格、开机自启、通知开关），使用 `.formStyle(.grouped)`
  - About 分区：应用图标 + 版本号
  - 底部 Save Changes 按钮仅在 `hasUnsavedChanges` 为 true 时显示
- `SettingsViewModel`：在设置 UI 与 `PersistenceService`/`AppState` 之间协调，跟踪 `hasUnsavedChanges` 状态
- 子组件：
  - `InstanceCardView`：紧凑型实例卡片行，布局为 StatusDotView → VStack(displayName + subtitle) → shortName 徽章 → 跟踪开关 → 编辑/删除按钮。指标可见性（`displayInMenuBar`）统一在 `InstanceEditorView` 中管理
  - `StatusDotView`：10×10pt 圆形指示器，`isTracking == true` 时为绿色（`Color.trackingOn`），否则灰色（`Color.trackingOff`）
  - `EmptyStateGuideView`：无实例时显示的居中引导视图，含 server.rack SF Symbol 图标、说明文字及「Add Your First Instance」CTA 按钮
- `Settings` 窗口通过 `Color+Theme.swift` 语义色彩令牌完全支持 Light/Dark 模式切换

### 2.6 AppState（`AppState.swift`）

**职责**：应用运行时数据的唯一数据源。使用 **Actor**。

- 持有：
  - `instances: [Instance]` — 所有已配置实例
  - `slotViewDataList: [SlotViewData]` — 由 instances + 最新刷新结果派生的数据，供 UI 使用
  - `refreshState: RefreshState` — `.idle` 或 `.refreshing`（全局刷新进行中标志）
  - `errorSummaries: [ErrorSummary]` — 每实例错误信息，用于面板错误栏
  - `globalSettings: GlobalSettings`
- 所有变更通过 Actor 上的 async 方法执行
- UI 通过 `AppStateProxy`（`@MainActor ObservableObject`）桥接观察，详见 §9

### 2.7 刷新服务（`RefreshService.swift`）

**职责**：编排刷新周期。使用 **Actor**。

- 管理定时刷新的 `Timer`，记录 `lastRefreshAt: Date`。"Next refresh" 倒计时的显示由 `UsagePanelView` 从 `AppStateProxy.lastRefreshAt` + `globalSettings.refreshIntervalMinutes` 派生,**不再通过 `InstanceType.quota` 关联值注入**
- 每次触发（定时或手动）：
  1. 按 `api_key_ref` 分组实例，以确定 HTTP 请求数量
  2. 对每组调用对应 `Supplier` 实现
  3. 以指数退避方式重试（最多 3 次）
  4. 解析响应，更新 `AppState`
  5. 对余额型实例触发余额历史计算，若 API 响应的 `currency` 与实例当前值不同，自动更新并写回 `instances.json`
  6. 触发阈值评估与通知
- 应用终止时取消 Timer

**Cycle 抢占与单实例刷新**

服务层通过 `cycleTask: Task<Void, Error>?` + `currentToken: CycleToken?` 槽位维护"当前正在跑的 performRefresh"，保证任意时刻最多一个 cycle 在执行。

- **手动全局 Refresh（`triggerManualRefresh`）**——抢占式：取消当前 `cycleTask`，等待其 unwrap，然后启动新一轮全量刷新。await `task.value` 时若旧的 cycle 因取消而抛 `CancellationError`，调用方吞掉（不再传播）
- **单实例刷新（`triggerInstanceRefresh(uuid:)`）**——非抢占：**仅当 `currentToken == nil` 时启动**；否则 no-op，避免打断用户已发起的定时/手动 cycle
- **定时刷新（`runPeriodicCycle`）**——非抢占：`currentToken != nil` 时跳过本轮，下个 tick 再检查。两个入口（手动/单实例）走 `runPreemptiveCycle(targetUUID:)`，定时走 `runPeriodicCycle()`
- **`CycleToken` 身份对象**：每次启动新 cycle 创建一个新的 `CycleToken` 实例；通过引用相等（`===`）判断"是否仍是当前 owner"。`runPreemptiveCycle` 在新建 token 之前**同步**调用旧 token 的 `markPreempted()`，随后才把新 token 写进 `currentToken`；旧 token 此刻已被标记，清理写入时读 `token.isPreempted == true` 即跳过
- **Token-Preempted Cleanup 不变量**：`performRefresh` 接收 `token: CycleToken` 参数；所有写入 AppState 的地方（包括每组的 `pushProgress()`、early-return、`catch CancellationError`、末尾清理）之前必须 `!token.isPreempted`。被抢占的旧 cycle（token 已被标记）跳过清理 → 新 owner 的写入不会被覆盖；末位 cycle（token 未被标记）正常清理 → `refreshState` 不卡在 `.refreshing`。这是 cycle-slot 的核心并发契约，由 `RefreshServiceCycleSlotTests` 锁住
- **被抢占 cycle 的错误处理**：`runPreemptiveCycle` 在 `await oldTask.value` 处用 `do/catch is CancellationError / catch` 区分——取消是预期路径（静默），非取消异常（如 Keychain 故障、解析崩溃）通过 `logger.error("Pre-empted cycle threw non-cancellation error: ...")` 记入日志，避免旧版 `try?` 静默吞咽导致的诊断盲区

**`performRefresh(targetUUID: String? = nil)`** 是单入口：

- `targetUUID == nil`：全量刷新。按 `api_key_ref` 逐组拉取，**每组完成后立刻通过 `pushProgress()` 推送到 UI**（流式逐组更新，不等所有组完成）。余额处理也在组内完成再推送
- `targetUUID != nil`：仅刷新该实例。`targetInstances` 数组只包含目标实例，`Dictionary(grouping:)` 按 `api_key_ref` 分组后**只对目标所在的组发请求**（supplier 调用仍按整组拉，但 `mapInstanceToSlotData` 只为组内目标生成 `SlotViewData`，兄弟实例的 slot 保留上次缓存）。MiniMax auto-discover 在 `targetUUID != nil` 时跳过——避免副作用污染兄弟实例的 metrics
- 入口处 `setRefreshingInstanceUUIDs(targetUUIDs)` 显示全部目标的菊花 → 每组完成后 `remainingRefreshing` 减去该组 UUID，逐步缩窄 → 末尾 `setRefreshingInstanceUUIDs([])` 确保所有菊花停止。每个 error catch 分支也调用 `pushProgress()` 将该组的错误状态立刻推送到 UI

**取消协作（详见 §6.3）**

`Task.cancel()` 必须能传达到网络层和 Shell 层：

- `URLSession.data(for:)` 自动抛 `URLError(.cancelled)`，`NetworkClient.mapURLError` 单独识别 `.cancelled` → 抛 `CancellationError`，**不**映射为 `.networkUnreachable`、**不**触发 RetryPolicy 重试
- `ShellProcessRunner.run` 用 `withTaskCancellationHandler` 包裹，在 `onCancel` 中立刻 `process.terminate()`（SIGTERM），不等 timeout
- `RetryPolicy.withRetry` 每次 `attempt` 顶端 `try Task.checkCancellation()`
- `performRefresh` 自身在每个 key 组循环顶端也调用 `try Task.checkCancellation()`，让取消尽快冒泡

### 2.8 供应商协议（`Supplier.swift`）

**职责**：定义 API 供应商的接口。

```swift
protocol Supplier {
    var provider: Provider { get }
    func fetchUsage(apiKey: String) async throws -> SupplierResponse
}

struct SupplierResponse {
    let rawData: [String: String]  // dimension → value 映射
}
```

- `MiniMaxSupplier`：实现 `Supplier`。一次 HTTP 调用 `GET /v1/token_plan/remains` 返回 Token Plan 用量数据。响应格式见 PRD 附录 B。`MiniMaxResponseParser` 作为适配层，将 API 响应字段映射为内部维度标识符（每个 `model_name` 作为独立维度）。
- `DeepSeekSupplier`：实现 `Supplier`。一次 HTTP 调用 `GET /user/balance` 返回余额信息。响应格式已在 PRD 附录 A 中明确定义。

### 2.9 持久化服务（`PersistenceService.swift`）

**职责**：读写所有持久化数据。使用 **Actor**。

- `instances.json` — 实例配置 + 全局设置的完整读写
- `{uuid}.json` — 每实例余额历史
- Keychain — API Key 的读写删除
- 提供原子保存操作（写入临时文件 → 重命名）
- 处理实例删除清理（JSON + Keychain）

### 2.10 Keychain 服务（`KeychainService.swift`）

**职责**：对 Keychain Services API 的轻量封装。

- 使用 `kSecClassInternetPassword`
- 属性：`kSecAttrServer` = `"APIUsageStatus"`、`kSecAttrAccount` = `api_key_ref`
- 方法：`store(key: String, for ref: String)`、`retrieve(for ref: String) -> String?`、`delete(for ref: String)`
- 仅被 `PersistenceService` 调用

### 2.11 像素字模引擎（`PixelFontEngine.swift`）— **已弃用**

> **状态**：代码已注释，保留文件供历史参考，待后续彻底删除。
>
> **弃用原因**：状态栏改回系统字体渲染（SF Pro 10 pt），像素字模在状态栏极窄空间内已不再必要，且系统字体在 Retina 屏幕下清晰度足够。参见 ADR-003 修订记录。

**原职责**（归档）：将文本渲染为像素位图。纯函数，无状态。

- 字符映射表：`[Character: [[Bool]]]` — 字母 5×7，数字 3×5
- `func renderChar(_ char: Character, size: CharSize) -> [[Bool]]`
- `func renderText(_ text: String, size: CharSize) -> [[Bool]]` — 水平拼接
- `func renderSlot(context: CGContext, data: SlotViewData, color: NSColor, mode: ColorMode)`
- 所有渲染通过 `CGContext.fill(rect:)` 完成 —— 每个点亮像素一个 `CGRect`

### 2.12 通知管理器（`NotificationManager.swift`）

**职责**：评估阈值并触发 macOS 系统通知。

- 每次刷新周期结束后调用
- 将每个实例的最新数据与配置的阈值进行比较
- 超过严重阈值时触发 `UNUserNotificationCenter` 通知
- 通知负载包含实例名称、当前值、阈值信息
- 点击通知打开 `InstanceDetailPanel`（独立 `NSPanel`，展示该实例完整用量详情，失活时自动关闭）

### 2.13 余额计算器（`BalanceCalculator.swift`）

**职责**：余额型实例日用量计算的纯逻辑模块。

- 实现 PRD §3.7 的算法：
  - 跨日检测与历史归档
  - `topped_up_balance` 差值计算
  - 充值检测（`current > latest`）
  - 可配置时间周期的日均消耗计算
- 无状态：接收输入数据，返回计算结果

### 2.14 供应商注册表（`SupplierRegistry.swift`）

**职责**：将 `(provider, dimension)` 映射到 `Supplier` 实现。

- 可用供应商及其维度的注册中心
- 工厂方法：根据 `provider` 字符串返回对应 `Supplier` 实例
- 被 `RefreshService` 用于分发 API 调用

### 2.15 Workspace ID 解析器（`OpenCodeWorkspaceResolver.swift`）

**职责**：为 OpenCode "See details" 按钮提供 workspace ID。

OpenCode 不在本地存储 workspace ID（详细排查见 `docs/provider-interfaces/opencode_workspace_resolver.md`），该解析器通过 `grep ~/.local/share/opencode/log/*.log` 抽取 Zen 后端在余额不足错误体中嵌入的 workspace URL，将 wrk_id 缓存到 `UserDefaults`（key：`opencode.workspaceID`）。

为避免 SwiftUI 视图层在主线程被 grep 阻塞，API 拆成三档：

- `cachedWorkspaceID()` —— 同步、零 IO，只读 UserDefaults。**view 层专用**。
- `resolveWorkspaceID()` —— 同步、可能阻塞 5s。供测试用。
- `prewarm()` —— `Task.detached(priority: .utility)`，在 `AppDelegate.applicationDidFinishLaunching` 末尾调用，清缓存后后台扫描。
- `refreshCache()` —— `Task.detached(priority: .utility)`，由 `RefreshService` 在每次 OpenCode 刷新成功后调用，清缓存后异步重扫，确保切换账号后无需重启即可感知 workspace ID 变化。

view 层始终调 `cachedWorkspaceID()`；缓存为空时 `UsageCardView.providerURL` 兜底到 `https://opencode.ai/zh/go`。

---

## 3. 数据流图

### 3.1 启动流程

```
应用启动
    │
    ▼
AppDelegate.applicationDidFinishLaunching()
    │
    ├──▶ PersistenceService.loadInstances() ──▶ 读取 instances.json
    │         │
    │         ▼
    │    AppState.setInstances(...)
    │         │
    │         ▼
    │    MenuBarController：显示 AI 品牌动画（0 个实例）或 "•••" 槽位（加载中状态）
    │         │
    │         ▼
    │    RefreshService.start()
    │         │
    │         ├──▶ 调度重复 Timer
    │         │
    │         └──▶ 立即触发首次刷新周期（async）
    │                   │
    │                   ▼
    │              [参见下方「刷新周期」]
    │              → 刷新完成后调用 AppStateProxy.syncFromState()
    │
    ├──▶ AppStateProxy.syncFromState()  （加载配置后触发 UI 初始渲染）
    │
    └──▶ 注册 SMAppService（若开启开机自启）
         请求通知权限
```

### 3.2 刷新周期（完整流程）

```
入口触发（Timer tick / triggerManualRefresh / triggerInstanceRefresh）
    │
    ├── triggerManualRefresh ──▶ runPreemptiveCycle(targetUUID: nil)
    │       标记 currentToken.isPreempted → 取消 cycleTask → 等待 unwrap → 启动新 cycle
    │
    ├── triggerInstanceRefresh(uuid) ──▶ 若 currentToken == nil 才启动
    │       runPreemptiveCycle(targetUUID: uuid)
    │       否则 no-op（"补刷新"手势不打断）
    │
    └── Timer tick ──▶ runPeriodicCycle()
            若 currentToken == nil 才启动；否则跳过本轮

            ▼
RefreshService.performRefresh(targetUUID: String?)
    │
    ├──▶ AppState.setRefreshState(.refreshing)
    ├──▶ AppState.setRefreshingInstanceUUIDs(targetUUIDs)
    │       （驱动面板卡片圆点的旋转 ProgressView）
    │
    ├──▶ 解析 targetUUID：
    │     nil → targetInstances = 所有 enabled 实例
    │     非 nil → targetInstances = filter { $0.uuid == targetUUID && $0.enabled }
    │              找不到时 silent bail（不动其他状态）
    │
    ├──▶ 按 api_key_ref 分组 targetInstances
    │     例如：实例 A、B 的 api_key_ref 均为 "minimax-token-plan"
    │           → 合并为一个 MiniMax 组
    │     单实例刷新时，组内只含目标实例（兄弟实例不在该组）
    │
    ├──▶ 对每个唯一 api_key_ref：
    │     │
    │     │ try Task.checkCancellation()   // 协作取消，详见 §6.3
    │     │
    │     ├──▶ PersistenceService.getApiKey(ref) ──▶ KeychainService
    │     │
    │     ├──▶ SupplierRegistry.getSupplier(provider) ──▶ Supplier 实例
    │     │
    │     ├──▶ Supplier.fetchUsage(apiKey) ──▶ HTTP 请求 ──▶ API 服务器
    │     │         │
    │     │         ├── 成功 ──▶ 解析 SupplierResponse
    │     │         │
    │     │         └── 失败 ──▶ 指数退避重试（最多 3 次，每次重试前
    │     │                              try Task.checkCancellation())
    │     │                              │
    │     │                              ├── 全部重试失败 ──▶ ErrorSummary
    │     │                              └── 重试成功 ──▶ SupplierResponse
    │     │
    │     └──▶ 映射 SupplierResponse → 组内每 Instance 的 SlotViewData
    │              （mapInstanceToSlotData 做 1:N 映射：
    │               遍历 instance.metrics，每个 MetricConfig 产生一个 MetricSnapshot）
    │
    └──▶ 组内后处理（每组完成后立即执行，不等其他组）：
          │
          ├──▶ 对每个配额型实例，解析响应时算出 `cycleEndTime`（基于 `<model>:end_time`
          │     毫秒时间戳转 `Date`）并存入 `MetricSnapshot`，同时派生
          │     `cycleRemainingSeconds`（`cycleEndTime - now`，向下取整到 0）以兼容
          │     `InstanceType.quota` 与测试 fixture。UI 层用 `TimelineView(.periodic(by: 60))`
          │     包装渲染：popover 打开时 `cycleEndTime - context.date` 每分钟重算一次，
          │     格式化为 `Xh Ym` / `Xm` / `Xd remaining`；popover 关闭时 timeline 自动停止
          │     （视图卸载）。Copilot 的 `<model>:end_time` 来自 `quota_reset_date_utc` 解析（支持毫秒精度 ISO 8601），缺失时回退到 `nextMonthlyResetMs()`（下月首日 UTC 零点），保证倒计时始终有值。其余供应商字段缺失则该行隐藏
          │
          ├──▶ [targetUUID == nil 时] MiniMax auto-discover：把响应中
          │     新发现的 model_name 加为 5h + weekly 两个 MetricConfig，
          │     更新 instance + 写回 instances.json
          │     （targetUUID != nil 时跳过，避免污染兄弟实例）
          │
          ├──▶ 对组内每个余额型实例：
          │     ├──▶ BalanceCalculator.calculate(latestData, history) ──▶ 更新 BalanceSnapshot
          │     │     PersistenceService.saveBalanceSnapshot(uuid, snapshot)
          │     └──▶ [自动修正货币] 若 API 响应含 currency 字段，且与实例当前 currency 不同：
          │              ├──▶ AppState 更新该实例的 currency
          │              └──▶ 若 currency 发生变更，PersistenceService.saveInstances(...)
          │                    写回 instances.json
          │
          ├──▶ 从 remainingRefreshing 集合中移除该组 UUID
          │
          ├──▶ AppState.mergeCycleResult(cycleSuccesses, cycleErroredUUIDs)
          │     （立刻合并到 _slotViewDataList，不等其他组；单实例刷新时该数组只含目标，
          │      兄弟实例 slot 保留上次缓存）
          │
          ├──▶ setErrorSummaries（累计至今的所有 error）：
          │     targetUUID == nil → 整组替换
          │     targetUUID != nil → 读旧值 → 过滤掉目标 UUID → 拼接本轮 errors
          │
          ├──▶ AppState.setRefreshingInstanceUUIDs(remainingRefreshing)
          │     （已完成组的实例立刻停止菊花，待处理组的实例继续转动）
          │
          └──▶ AppStateProxy.syncFromState()
                 （将 Actor 数据副本拉到 MainActor，触发 @Published → SwiftUI 重绘。
                  流式逐组推送：先拉到的供应商先出数据，后拉到的继续转菊花）

遍历完所有组后：
    │
    ├──▶ 按 sortOrder 排序 allSlotData
    │
    ├──▶ NotificationManager.evaluateThresholds(instances, data)
    │         │
    │         └──▶ 若超过严重阈值则触发通知
    │
    ├──▶ AppState.setRefreshState(.idle)
    │     AppState.setLastRefreshAt(Date())
    │
    ├──▶ AppState.setRefreshingInstanceUUIDs([])   // 末位清理：确保所有菊花停止
    │
    └──▶ AppStateProxy.syncFromState()
          面板末次重绘（所有圆点恢复为 OK/WARN/CRIT 静态度）

取消路径：
  catch CancellationError → setRefreshingInstanceUUIDs([])
                          → throw（由 runPreemptiveCycle / runPeriodicCycle 的
                            try { await task.value } catch { } 吞掉）
```

### 3.3 菜单栏渲染流程

```
AppStateProxy.slotViewDataList 发生变化（@Published 触发）
    │
    ▼
MenuBarController（观察者）
    │
    ▼
MenuBarIconRenderer.render()
    │
    ├──▶ 计算槽位宽度：1 槽位 = 内容宽，2 槽位 = max(宽A,宽B) × 2（50/50）
    │
    ├──▶ 创建 NSImage（高度 22pt × 总宽度，variableLength 自适应）
    │
    ├──▶ 对每个槽位（最多 2 个）：
    │     │
    │     ├──▶ 确定槽位颜色（基于阈值 + 色彩模式）
    │     │
    │     ├──▶ 双行层叠绘制（第一行简称、第二行数值，各行在槽位内水平居中）：
    │     │     │
    │     │     ├──▶ 第一行：简称（2 字母，SF Pro Regular 8pt）
    │     │     ├──▶ 第二行：[配额型] 百分比数字（等宽 8pt） [余额型] 余额数值
    │     │     └──▶ 两行通过上下 margin 对称分布在 22pt 内
    │     │
    │     └──▶ 若为 warning/critical 阈值 → 启动呼吸动画（`Timer.scheduledTimer` 0.2s = 5Hz 驱动，详见 `docs/menu-bar-breathing-animation.md` §4）
    │
    ├──▶ 设为 NSStatusBarButton.image
    │
    └──▶ NSStatusBarButton.needsDisplay = true
```

### 3.4 设置写入流程

```
用户在设置窗口中编辑配置
    │
    ▼
SettingsViewModel.save()
    │
    ├──▶ PersistenceService.saveInstances(instances, settings)
    │     │
    │     └──▶ 写入 instances.json（原子操作：临时文件 → 重命名）
    │
    ├──▶ 若 API Key 变更：
    │     └──▶ PersistenceService.saveApiKey(ref, key)
    │           └──▶ KeychainService.store(...)
    │
    ├──▶ 若实例被删除：
    │     ├──▶ 删除 {uuid}.json（余额历史）
    │     └──▶ 若无其他实例共享同一 api_key_ref：
    │           └──▶ KeychainService.delete(ref)
    │
    ├──▶ AppState.updateInstances(newInstances)
    │
    ├──▶ AppStateProxy.syncFromState()  （同步 UI）
    │
    └──▶ RefreshService.restartTimer()  （若刷新间隔变更）
```

---

## 4. 数据模型与存储设计

### 4.1 内存模型（Swift）

```swift
// === 实例配置 ===
struct Instance: Codable, Identifiable {
    let uuid: String            // UUID v4，不可变
    var provider: String        // "minimax" | "deepseek"
    var metrics: [MetricConfig] // 多指标配置列表（v2 schema）。每个 MetricConfig 描述一个 (provider, group, window) 三元组
    var displayName: String     // 用户自定义，如「MiniMax-文字」
    var shortName: String       // 2-3 个大写字母，用于菜单栏
    var apiKeyRef: String       // 引用 Keychain 条目；同 Key 的实例共享
    var trackingEnabled: Bool   // 是否启用刷新（v2 JSON key: "tracking_enabled"；旧版 "enabled" 由迁移路径处理）
    var sortOrder: Int
    var currency: String?       // "CNY" | "USD" | nil（nil 表示配额型）。余额型实例：每次 API 刷新时若响应含 currency 字段，自动更新为本值；用户也可手动设置初始值
    var thresholds: Thresholds

    // 计算属性，向后兼容：从 metrics.first?.key 派生
    var dimension: String { metrics.first?.key ?? "" }
    // 计算属性，向后兼容旧版 enabled 读写
    var enabled: Bool {
        get { trackingEnabled }
        set { trackingEnabled = newValue }
    }
}

// === 指标配置（持久化，写入 instances.json） ===
struct MetricConfig: Codable, Equatable {
    let key: String             // 稳定查找键，格式："{provider}.{group}.{window}" 或 "{provider}.balance"
    let group: String?          // 可选逻辑分组（如 MiniMax 的 "general"、"video"）
    let window: String?         // 可选时间窗口（如 "5h"、"weekly"、"monthly"）；非窗口指标为 nil
    var displayInMenuBar: Bool  // 是否在菜单栏图标中渲染（默认 true）
}

// === 指标快照（运行时，不持久化） ===
struct MetricSnapshot: Equatable {
    let key: String
    let group: String?
    let window: String?
    let percent: Double              // 用量百分比（可超过 100% 当开启套餐外余额消费时）
    let displayUsage: String         // 预格式化的用量字符串（如 "369"、"$15.00"、"¥42.50"）
    let displayLimit: String         // 预格式化的上限字符串（可为空）
    let overageUSD: Double           // OpenCode Go 超额消费的美元金额（无超额时为 0）
    let cycleEndTime: Date?          // 当前重置周期的绝对结束时间（UI 用 TimelineView 实时倒计时的权威源）
    let cycleRemainingSeconds: Int?  // 同次刷新时刻的剩余秒数快照（cycleEndTime - now，向下取整到 0），供 InstanceType.quota 等无 Date() 的调用方使用
    let colorState: ColorState
    let configIndex: Int             // 1-based 位置，用于稳定排序
    let displayInMenuBar: Bool
}

enum Thresholds: Codable {
    case quota(warningPercent: Int, criticalPercent: Int)
    case balance(warning: Decimal, critical: Decimal,
                 avgDailyPeriods: [AvgDailyPeriod],
                 historyRetentionDays: Int)
}

enum AvgDailyPeriod: String, Codable {
    case currentWeek
    case currentMonth
    case last7Days
    case last30Days
}

// === 全局设置 ===
struct GlobalSettings: Codable {
    var refreshIntervalMinutes: Int      // 1–60，默认 5
    var colorMode: ColorMode             // .monochrome | .color
    var launchAtLogin: Bool
    var notificationsEnabled: Bool
}

enum ColorMode: String, Codable {
    case monochrome
    case color
}

// === 运行时视图数据（不持久化） ===
struct SlotViewData {
    let uuid: String
    let displayName: String
    let shortName: String           // 2-3 字母
    let sortOrder: Int
    let provider: String            // 供应商标识（如 "deepseek" / "minimax"），用于「See details」按钮的 URL 映射

    // v2：多指标运行时快照。每次刷新由 MetricConfig + SupplierResponse 派生。
    // instanceType、colorState、dimension、weekly 均为计算属性，源自 metricSnapshots。
    var metricSnapshots: [MetricSnapshot]

    // Balance-specific fields for usage panel
    var todayUsage: String?
    var dailyAverages: [AvgDailyPeriod: Decimal]?

    // 计算属性：由 metricSnapshots.first 派生
    var instanceType: InstanceType { ... }
    // 计算属性：所有指标快照中最严重的颜色状态
    var colorState: ColorState { ... }
    // 计算属性：由 metricSnapshots.first?.key 派生
    var dimension: String { ... }
    // 计算属性：首个 window == "weekly" 的快照 → WeeklyQuota
    var weekly: WeeklyQuota? { ... }

    enum InstanceType {
        case quota(percent: Double, usageValue: String, limitValue: String,
                   cycleRemainingSeconds: Int?)   // 周期剩余秒数（基于 <metric>:end_time 算出）；缺失则 UI 倒计时行隐藏
        case balance(amount: String, totalBalance: String, grantedBalance: String,
                   isAvailable: Bool, currency: String?)
    }
}

enum ColorState {
    case normal       // 安全区
    case warning      // 超过警告阈值
    case critical     // 超过严重阈值
    case disabled     // 实例已禁用 → 置灰色 #D6D0A0
    case unavailable  // 余额 is_available = false → 置灰色 #D6D0A0
    case loading      // 首次刷新尚未完成 → 置灰色 #D6D0A0
    case error        // 刷新失败 → 置灰色 #D6D0A0
}

// === 刷新错误 ===
struct ErrorSummary: Identifiable {
    let id: String           // 实例 uuid
    let displayName: String
    let errorType: ErrorType
}

enum ErrorType {
    case networkTimeout
    case networkUnreachable
    case authFailed          // 401/403
    case apiError(code: Int)
}

// === 刷新状态 ===
enum RefreshState {
    case idle
    case refreshing
    // 错误按实例粒度记录在 errorSummaries 数组中，无需全局 error case
}

// === 余额快照（每实例持久化） ===
struct BalanceSnapshot: Codable {
    var latestToppedUp: String
    var latestToppedUpTs: Int64
    var lastTopupDate: String?          // "YYYY-MM-DD"
    var todayDate: String               // "YYYY-MM-DD"
    var todayUsage: String
    var history: [DailyUsageEntry]
}

struct DailyUsageEntry: Codable {
    let date: String     // "YYYY-MM-DD"
    let usage: String    // 以字符串存储十进制数值以确保精度
}

// === 供应商响应（内部领域模型） ===
struct SupplierResponse {
    let rawData: [String: Any]  // 解析后的 JSON
}
```

### 4.2 存储布局

```
~/Library/Containers/<bundle-id>/Data/Library/Application Support/
    ├── instances.json               # 实例配置 + 全局设置
    ├── <uuid-1>.json                # 实例 1 的余额历史
    ├── <uuid-2>.json                # 实例 2 的余额历史
    └── ...
```

### 4.3 原子文件写入

所有 JSON 写入均采用「先写临时文件再重命名」模式：

```swift
func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws {
    let tempURL = url.deletingPathExtension()
        .appendingPathExtension("tmp")
    let data = try JSONEncoder().encode(value)
    try data.write(to: tempURL, options: .atomic)
    try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
}
```

此方式可防止应用在写入中途崩溃导致的文件损坏。

---

## 5. Keychain 集成设计

### 5.1 存储方案

| 属性 | 值 |
|------|------|
| `kSecClass` | `kSecClassInternetPassword` |
| `kSecAttrServer` | `"APIUsageStatus"` |
| `kSecAttrAccount` | `api_key_ref`（如 `"minimax-token-plan"`） |
| `kSecValueData` | UTF-8 编码的 API Key 字符串 |

选择 `kSecClassInternetPassword` 而非 `kSecClassGenericPassword`，是因为前者提供 `kSecAttrServer` 属性，天然构成 `(server, account)` 两级查找键，与我们的 `api_key_ref` 模型直接对应。

### 5.2 API 接口

```swift
actor KeychainService {
    func store(key: String, for apiKeyRef: String) throws
    func retrieve(for apiKeyRef: String) throws -> String?
    func delete(for apiKeyRef: String) throws

    // 删除所有 server = "APIUsageStatus" 的条目（用于卸载清理）
    func deleteAll() throws
}
```

### 5.3 安全属性

- **永不以明文落盘**：API Key 仅存在于 Keychain（经 Secure Enclave 加密）和 HTTP 请求期间的短暂内存中。
- **内存卫生**：`RefreshService` 获取 Key，用于 HTTP 调用后，局部变量即出作用域自动释放。不缓存到 `UserDefaults`，不记录日志，不会意外出现在 JSON 文件中。
- **Ad-hoc 签名兼容**：在 macOS 上 Keychain 即使使用 ad-hoc 签名也可正常工作，无需付费开发者账号。另外不需要 `access-group` 权限（仅单应用访问）。
- **iCloud Keychain 同步**：由 macOS 系统设置控制。应用不配置也不阻止同步。

### 5.4 实例删除清理

删除实例时：
1. 从 `instances.json` 中移除该实例条目
2. 扫描剩余实例，检查是否有其他实例引用相同的 `api_key_ref`
3. 若无其他实例共享该 Key → `KeychainService.delete(for: apiKeyRef)`
4. 删除 `{uuid}.json` 余额历史

---

## 6. 网络层设计

### 6.1 请求去重

核心思路：共享相同 `api_key_ref` 的实例须合并为**一次** HTTP 请求。

```
输入：[实例 A（minimax，keyRef="minimax-token-plan"）、
       实例 B（minimax，keyRef="minimax-token-plan"）、
       实例 C（minimax，keyRef="minimax-token-plan"）、
       实例 D（deepseek，keyRef="deepseek-main"）]

分组：
  组 1：[A, B, C] → 1 次 MiniMax API 调用 → 响应解析为 3 个维度
  组 2：[D]       → 1 次 DeepSeek API 调用 → 余额信息

合计：4 个实例仅需 2 次 HTTP 请求
```

### 6.2 HTTP 客户端

使用 `URLSession` 配合 `async/await`。不需要第三方网络库。

```swift
actor NetworkClient {
    private let session: URLSession

    func request(_ endpoint: Endpoint, apiKey: String) async throws -> Data
}

struct Endpoint {
    let url: URL
    let method: String          // "GET"
    let headers: [String: String]  // Authorization, Content-Type
    let timeout: TimeInterval   // 默认 30s
}
```

- `URLSession` 配置 `waitsForConnectivity = false`（希望显式控制超时 → 重试）
- `timeoutIntervalForRequest = 30`
- 所有请求均使用 HTTPS

### 6.3 重试策略

**指数退避 + 抖动，最多 3 次：**

```
第 1 次：立即
第 2 次：等待 100ms + random(0, 50ms)
第 3 次：等待 1s + random(0, 1s) / 2s + random(0, 1s)
每组 API 总计最长等待时间：约 5s（不含单次请求 timeout）
```

**取消协作（`Task.cancel()` 协作前提）：**

- 每次 `attempt` 顶端调用 `try Task.checkCancellation()`——否则取消会被吞掉继续重试，导致手动抢占在网络慢时要等完整个重试链才生效（最坏 30s+30s+30s ≈ 90s）
- 抛出的 `CancellationError` **不**视为"网络错误重试"，因此重试策略在遇到 cancellation 时直接上抛，由外层 `performRefresh` 触发 `setRefreshingInstanceUUIDs([])` 清理

**网络层与 Shell 层的 cancellation 透传：**

- `NetworkClient.request` 捕获 `URLError(.cancelled)` 时**不**映射为 `.networkUnreachable`，而是直接 `throw CancellationError()`——否则会把"用户取消"伪装成"网络故障"，RetryPolicy 会对 cancellation 触发重试，浪费 30s+ 且日志误导
- `ShellProcessRunner.run` 用 `withTaskCancellationHandler { … } onCancel: { process.terminate() }` 包裹，在父任务被取消时立即给子进程发 SIGTERM（不等配置的 timeout）。Task.detached 内部的 `waitUntilExit()` / `readDataToEndOfFile()` 不需要主动取消——进程被 SIGTERM 后它们会自然返回

### 6.4 供应商实现

#### MiniMaxSupplier

```swift
struct MiniMaxSupplier: Supplier {
    let provider = Provider.minimax

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint(
            url: URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!,
            method: "GET",
            headers: ["Authorization": "Bearer \(apiKey)"],
            timeout: 30
        )
        let data = try await NetworkClient.shared.request(endpoint, apiKey: apiKey)
        return SupplierResponse(rawData: parseJSON(data))
    }
}
```

解析后的响应由 `MiniMaxResponseParser` 映射到内部维度标识符。每个 `model_name`（能力桶，如 `general`、`video`、`speech-hd`）作为一个独立的 `MetricConfig` 维度，`RefreshService.mapInstanceToSlotData()` 遍历 `instance.metrics` 将每个 `MetricConfig` 映射为一个 `MetricSnapshot`（1:N 映射）。

API 当前 schema（旧的 `current_interval_total_count` / `current_interval_usage_count` 字段已弃用，恒为 0；新字段为权威源）：

| 字段 | 类型 | 含义 |
|------|------|------|
| `model_name` | string | 能力桶标识（如 `general`、`video`、`speech-hd`、`music-2.6`、`image-01`），非具体模型名 |
| `current_interval_status` | int | 5h 区间配额状态（`1` = 生效，其他值视为未激活） |
| `current_interval_remaining_percent` | number | 5h 区间剩余百分比（0-100） |
| `current_weekly_status` | int | 周配额状态（`1` = 生效，其他值视为未激活） |
| `current_weekly_remaining_percent` | number | 周剩余百分比（0-100） |
| `start_time` / `end_time` / `remains_time` | int64 | 5h 区间时间窗（毫秒 / 秒） |
| `weekly_start_time` / `weekly_end_time` / `weekly_remains_time` | int64 | 周时间窗 |

百分比计算规则：

| 状态 | 计算规则 |
|------|----------|
| `current_interval_status == 1` | `usage_percent = 100 - current_interval_remaining_percent` |
| `current_interval_status != 1` | `usage_percent = 0`（区间未激活，不显示用量） |
| `current_weekly_status == 1` | 额外计算 `weekly_percent = 100 - current_weekly_remaining_percent` |

`rawData` 中每个 model_name 作为 key，存储百分比字符串（如 `"72.0"`），辅助字段用 `model_name:status`、`model_name:remaining`、`model_name:weekly_percent` 等格式。

`MiniMaxResponseParser` 的职责：接收原始 JSON → 提取对应字段值 → 分配至各维度实例。若 API 实际返回格式与预期不同，仅需修改此 Parser，不影响上游调用方。

#### DeepSeekSupplier

```swift
struct DeepSeekSupplier: Supplier {
    let provider = Provider.deepseek

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint(
            url: URL(string: "https://api.deepseek.com/user/balance")!,
            method: "GET",
            headers: ["Authorization": "Bearer \(apiKey)"],
            timeout: 30
        )
        let data = try await NetworkClient.shared.request(endpoint, apiKey: apiKey)
        return SupplierResponse(rawData: parseJSON(data))
    }
}
```

响应解析：
- 提取 `is_available`、`balance_infos`
- 优先取第一条 `CNY` 记录，若无 CNY 则取第一条
- 提取 `topped_up_balance` 作为主余额值

### 6.5 API 错误分类

```swift
enum RefreshError: Error {
    case networkTimeout
    case networkUnreachable
    case httpError(statusCode: Int)       // 401, 403, 500 等
    case parsingError(String)
    case maxRetriesExceeded

    var errorType: ErrorType {
        switch self {
        case .networkTimeout:       return .networkTimeout
        case .networkUnreachable:   return .networkUnreachable
        case .httpError(let code) where code == 401 || code == 403:
                                    return .authFailed
        case .httpError(let code):  return .apiError(code: code)
        default:                    return .apiError(code: 0)
        }
    }
}
```

---

## 7. 菜单栏渲染管线

### 7.1 槽位布局（variableLength × 22pt）

**多指标展开**：v2 schema 中，一个 `SlotViewData` 可能包含多个 `MetricSnapshot`。`MenuBarIconRenderer.expandToMetricSlots()` 在渲染前将每个启用可见（`displayInMenuBar == true`）的指标快照展开为独立的渲染槽位，确保一个 MiniMax 实例的 `general` 和 `video` 能力桶各自在菜单栏中独立显示。展开后的槽位按 `sortOrder` 排序。

槽位高度固定 22pt，宽度动态决定。槽位内容以**双行层叠**方式排列，每行各自水平居中：

```
┌──────────────────┐   ┌──────────────────┐
│       MX         │   │       DS         │ ← 第一行：简称
│      82%         │   │      ¥45         │ ← 第二行：数值
└──────────────────┘   └──────────────────┘
  ← 配额型槽位 →    4pt  ← 余额型槽位 →

  1 个槽位：宽度 = max(第一行宽, 第二行宽)
  2 个槽位：各占 50% 等宽，宽槽决定半宽，中间 4pt 间距
```

**布局常量**：
- 字体：SF Pro Regular 8pt（双行在 22pt 内紧凑可读）
- 第一行（简称）：2 字母，SF Pro Regular 8pt，槽位内水平居中
- 第二行（数值）：配额型用等宽数字（`.monospacedSystemFont` 8pt），余额型用 SF Pro Regular 8pt，槽位内水平居中
- 垂直居中：基于 `capHeight`（实际字形高度）计算基线，而非 `ascender`/`descender`（包含未使用的变音符号空间），使可见字形视觉居中
- 2 槽位时：两半之间间距 4pt，与两侧边距视觉效果一致

### 7.2 槽位选择（≥3 个实例）

当启用 ≥3 个实例时，菜单栏仅显示按 `sort_order`（升序）排列的**前 2 个**。其余实例仅在用量面板中可见。这防止 macOS 截断菜单栏图标。

### 7.3 色彩模式逻辑

#### 色彩定义

| 用途 | 色值 | 说明 |
|------|------|------|
| 置灰色 | `#D6D0A0` | 所有非活跃状态（加载中/禁用/余额不可用）统一置灰色。文字等所有槽位元素均以此色渲染。**注意**：刷新失败（陈旧）不再使用此色，详见 §7.5 |
| 安全 | `#4CAF50` | 彩色模式下的正常状态 |
| 警告 | `#FFC107` | 彩色模式下的警告阈值 |
| 严重 | `#F44336` | 彩色模式下的严重阈值 |

**置灰实现方式**：不通过 `alphaValue` 或透明度操作，而是**直接以 `#D6D0A0` 作为文字颜色传入 `NSAttributedString`**，替换掉正常情况下应使用的颜色（无论单色还是彩色模式）。这避免了降 alpha 在单色模式下与系统外观颜色叠加后产生不可预期的视觉效果。

#### SwiftUI 面板配色（`Color+Theme.swift`）

SwiftUI 面板使用独立的语义色彩令牌（与菜单栏 NSColor 互不影响）。每种颜色包含 light 和 dark 两种 hex 值，通过 `Color.init(light:dark:)` 自动根据系统外观切换。

| 令牌 | light | dark | 用途 |
|------|-------|------|------|
| `cardBg` | `0xFFFFFF` | `0x2C2C2E` | 正常卡片的背景色 |
| `cardBgDim` | `0xF5F5F5` | `0x232325` | 陈旧（缓存）卡片的背景色，与 `cardBg` 形成微弱色差以便用户识别缓存数据 |
| `textPrimary` | `0x1A1A1A` | `0xFFFFFF` | 正文 |
| `textSecondary` | `0x666666` | `0xAEAEB2` | 副文 |
| `warningBg` | `0xFFF3E0` | `0x4A3A00` | 错误 / 提示栏背景 |

#### 单色模式
- 所有文字：跟随系统菜单栏外观（浅色主题黑色，深色主题白色）
- 百分比数字本身即为用量信息载体，无需额外视觉编码
- 警告阈值：整槽以呼吸动画呈现（warning 4s 周期）
- 严重阈值：整槽以呼吸动画呈现（critical 2.0s 周期）
- 余额型实例无呼吸动画，仅显示数值
- **非活跃状态**：整槽以 `#D6D0A0` 渲染所有元素，不启动呼吸动画

#### 默认状态（无实例）

默认状态（无实例配置）根据用户设置的色彩模式渲染：
- **单色模式**：浅色背景下以黑色、深色背景下以白色渲染，跟随系统菜单栏原生图标风格。
- **彩色模式**：以 `safeColor`（`#4CAF50` 绿色）渲染，传达「就绪/等待配置」的语义，与正常状态的安全色保持一致。
不区分安全/警告/严重三种阈值色，因为实例追踪尚未启动。

#### 彩色模式
- 每个槽位根据阈值独立着色：
  - 安全：绿色（`#4CAF50`）
  - 警告：黄/琥珀色（`#FFC107`）
  - 严重：红色（`#F44336`）
- 警告阈值：槽位以呼吸动画呈现（warning 4s 周期，黄色 `#FFC107`）
- 严重阈值：槽位以呼吸动画呈现（critical 2.0s 周期，红色 `#F44336`）
- 余额型实例颜色根据剩余余额与阈值的比较决定
- **非活跃状态**：整槽以 `#D6D0A0` 渲染所有元素，不启动呼吸动画，与单色模式下外观一致

### 7.4 呼吸动画

呼吸动画由 `MenuBarIconRenderer.startBreathingAnimation()` / `stopBreathingAnimation()` 控制（详见 `docs/menu-bar-breathing-animation.md`）。启停由 `MenuBarController` 在每次数据刷新时根据 `renderer.needsBreathingAnimation()` / `renderer.isBreathingAnimationRunning()` 双重检查驱动。

### 7.5 特殊状态

所有非活跃状态统一以**置灰色 `#D6D0A0`** 渲染槽位全部内容（文字、符号），不依赖透明度操作。单色与彩色模式下置灰效果一致。

| 状态 | 视觉表现 | 渲染方式 |
|------|----------|----------|
| 无实例配置 | 两行布局：第一行 "AI"（居中，SF Pro Regular 8pt），第二行循环 "%"/"%%"/"%%%"（等宽 8pt，右对齐，1秒间隔），颜色跟随色彩模式（单色：白/黑；彩色：safeColor #4CAF50） | MenuBarIconRenderer.renderDefaultState() |
| 加载中（首次刷新） | `•••` | 以 `#D6D0A0` 系统字体渲染 |
| 全部实例已禁用 | `NO API` | 以 `#D6D0A0` 系统字体渲染 |
| 余额不可用（`is_available = false`） | `N/A` | 以 `#D6D0A0` 系统字体渲染 |
| 刷新失败 | 上次成功数据照常显示，但渲染时整体应用 80% 透明度 | 文字保留原阈值颜色（warning yellow / critical red / safe green），仅降低透明度；菜单栏不展示错误文字 |
| 刷新进行中（任意 cycle） | **无菜单栏视觉变化** | 菜单栏沿用上次成功数据渲染；刷新进度只在面板卡片圆点（→ 旋转 ProgressView）+ "Next refresh" 文案（→ "Refreshing…"）反馈，详见 §2.4 / PRD §3.4 |

**陈旧槽位 80% 透明度渲染**（2026-06-22）：刷新失败时陈旧（`isStale=true`）槽位的视觉信号简化为"在原阈值颜色上整体应用 80% 透明度"：

- 文字保留原始阈值颜色（warning yellow / critical red / safe green），不变色；单色模式下保留黑/白文字。
- 通过 `slotColor.withAlphaComponent(0.8)` 对文字 + 阴影呼吸一并降透明度。
- 不绘制 pill 背景、不切换为 `#D6D0A0` 灰色——避免视觉冲击过重。
- 陈旧 warning/critical 槽位**保留**呼吸动画（`colorState` 仍为 `.warning` / `.critical`），陈旧态只影响透明度、不影响动画。
- 陈旧检测与阈值判断**正交**：`colorState` 反映阈值，`isStale` 反映数据时效性，两个字段独立读取。
- 详见 `docs/menu-bar-stale-alpha.md`。

**ColorState.error 语义**（2026-06-22）：

- `colorState` 计算属性**始终**反映 `metricSnapshots` 聚合的阈值状态——**不再**有 `isStale ? .error` 短路。
- `isStale` 是存储字段（`Bool`，默认 `false`），由 `AppState.mergeCycleResult` 在刷新失败时置 `true`，刷新成功后重置为 `false`。**这是陈旧检测的唯一通道**——面板和菜单栏都从这里读取。
- 之前的 `SlotViewData.underlyingColorState` 已删除（无调用方后无存在必要）。`colorState` 始终反映真实阈值，不再需要"绕路"通道。
- 这一设计消除了之前"两个并行属性 + 短路逻辑"造成的阅读心智负担：阈值颜色始终来自 `colorState`，陈旧状态始终来自 `isStale`。

> **默认动画行为**：默认动画仅在无实例配置时运行，一旦添加实例即自动停止。

> **设计理由**（2026-06-22）：陈旧渲染从"挖空 pill + 灰色"改为"原阈值颜色 + 80% alpha"——视觉信号更克制（pill 强提示不再必要），并消除了挖空 pill 的复杂渲染逻辑（`CTLineDraw` + `destinationOut` 混合模式）。macOS 菜单栏的 NSImage 渲染管道会做正确的预乘 alpha 合成，0.8 alpha 在两种色彩模式 + 明暗主题下视觉效果稳定且一致。

---

## 8. 像素字模系统设计 — **已弃用（归档）**

> **状态**：代码已注释，保留文件供历史参考，待后续彻底删除。
>
> **弃用原因**：状态栏改回系统字体渲染（SF Pro 10 pt），像素字模在状态栏极窄空间内已不再必要，且系统字体在 Retina 屏幕下清晰度足够。参见 ADR-003 修订记录。

以下内容为原设计文档，仅作归档：

### 8.1 字符集（归档）

**5×7 网格（字母 A-Z、符号字符）：**
- 5 列 × 7 行 = 每字符 35 位
- 用于：简称字母、`%`、`¥`、`$`、`.`、`?`、`•`、`/`

**3×5 网格（数字 0-9）：**
- 3 列 × 5 行 = 每字符 15 位
- 用于：百分比数字和余额金额
- 更紧凑，在有限槽位宽度内可容纳更多数字

### 8.2 数据结构（归档）

```swift
enum CharSize {
    case small(Int, Int)  // 3×5 数字
    case normal(Int, Int) // 5×7 字母/符号
}

typealias Bitmap = [[Bool]]

// 字符映射表以编译时常量字典存储
let charMap: [Character: Bitmap] = [
    "A": [[false, true, true, true, false],
          [true, false, false, false, true],
          ...
]
```

### 8.3 渲染算法（归档）

```swift
func drawChar(_ char: Character, at origin: CGPoint, scale: CGFloat,
              in context: CGContext, color: NSColor) {
    guard let bitmap = charMap[char] else { return }
    context.setFillColor(color.cgColor)
    for (row, line) in bitmap.enumerated() {
        for (col, isLit) in line.enumerated() where isLit {
            let rect = CGRect(
                x: origin.x + CGFloat(col) * scale,
                y: origin.y + CGFloat(row) * scale,
                width: scale,
                height: scale
            )
            context.fill(rect)
        }
    }
}
```

### 8.4 文本渲染（归档）

```swift
func drawText(_ text: String, at origin: CGPoint, charSize: (Int, Int),
              scale: CGFloat, gap: CGFloat, in context: CGContext, color: NSColor) {
    var x = origin.x
    for char in text {
        drawChar(char, at: CGPoint(x: x, y: origin.y), scale: scale, in: context, color: color)
        x += CGFloat(charSize.0) * scale + gap
    }
}
```

原实现中槽位内容不使用任何系统字体 API，每个可见字符均通过 `CGContext.fill(rect:)` 调用绘制。

---

## 9. 状态管理方案

### 9.1 架构：基于 Actor 的单向数据流

```
┌──────────────┐     读取（async）     ┌──────────────┐
│   UI 层      │ ◄─────────────────── │   AppState   │
│  (MainActor) │                      │   （Actor）  │
│              │ ──── 变更 ──────────▶│              │
│              │   （async 调用）     │              │
└──────────────┘                      └──────┬───────┘
                                        ▲     │
                                        │     │
                                  读取  │     │ 写入
                                        │     ▼
                               ┌────────┴───────────┐
                               │   服务层            │
                               │   （Actor）         │
                               │   RefreshService    │
                               │   PersistenceService│
                               └─────────────────────┘
```

### 9.2 AppState Actor

`AppState` 是纯 Actor，仅持有原始数据并提供序列化的变更方法。Actor 本身**不**使用 `@Published`，也不遵循 `ObservableObject`——Actor 无法被 SwiftUI 直接观察。

```swift
actor AppState {
    private(set) var instances: [Instance] = []
    private(set) var slotViewDataList: [SlotViewData] = []
    private(set) var refreshState: RefreshState = .idle
    private(set) var errorSummaries: [ErrorSummary] = []
    private(set) var globalSettings: GlobalSettings = .default
    private(set) var refreshingInstanceUUIDs: Set<String> = []  // 驱动面板卡片圆点旋转动画

    // 变更方法（由服务层 Actor 调用，不由 UI 调用）
    func setInstances(_ newInstances: [Instance]) { ... }
    func updateSlotData(_ newData: [SlotViewData]) { ... }
    func setRefreshState(_ state: RefreshState) { ... }
    func setErrorSummaries(_ summaries: [ErrorSummary]) { ... }
    func updateSettings(_ settings: GlobalSettings) { ... }
    func setRefreshingInstanceUUIDs(_ uuids: Set<String>) { ... }
}
```

> **`refreshState` vs `refreshingInstanceUUIDs`**：`refreshState` 是全局 `.idle/.refreshing` 标志（驱动 Refresh 按钮的 spinner），只在一个 cycle 进入/退出时翻一次；`refreshingInstanceUUIDs` 是**当前 cycle 正在处理的具体实例集合**，由 `RefreshService.performRefresh` 在入口/三个退出点维护。前者用于按钮文案 + 倒计时切换，后者用于卡片圆点的旋转动画。两者都暴露给 UI，独立读取、独立使用。

### 9.3 AppStateProxy：SwiftUI 桥接层

`AppStateProxy` 是 `@MainActor class`，遵循 `ObservableObject`，以 `@Published` 属性持有 UI 所需数据的副本。它是 SwiftUI 应用与 Actor 状态之间的唯一桥梁。

```swift
@MainActor
final class AppStateProxy: ObservableObject {
    private let state: AppState

    @Published var instances: [Instance] = []
    @Published var slotViewDataList: [SlotViewData] = []
    @Published var refreshState: RefreshState = .idle
    @Published var errorSummaries: [ErrorSummary] = []
    @Published var globalSettings: GlobalSettings = .default
    @Published var refreshingInstanceUUIDs: Set<String> = []  // 驱动卡片圆点旋转动画

    init(state: AppState) {
        self.state = state
    }

    // 服务层在每次变更后调用此方法，将 Actor 最新数据拉取到 MainActor 副本
    func syncFromState() async {
        let i = await state.instances
        let s = await state.slotViewDataList
        let r = await state.refreshState
        let e = await state.errorSummaries
        let g = await state.globalSettings
        let refreshing = await state.refreshingInstanceUUIDs
        self.instances = i
        self.slotViewDataList = s
        self.refreshState = r
        self.errorSummaries = e
        self.globalSettings = g
        self.refreshingInstanceUUIDs = refreshing
    }

    func triggerManualRefresh() async {
        // 委托给 RefreshService，刷新完成后会回调 syncFromState()
    }

    func triggerInstanceRefresh(instanceUUID: String) async {
        // 单实例刷新入口；currentToken != nil 时 RefreshService 内部 no-op
        await refreshService.triggerInstanceRefresh(instanceUUID: instanceUUID)
    }
}
```

**数据流方向总结**：

```
服务层（Actor）  ──写入──▶  AppState（Actor）  ──syncFromState()──▶  AppStateProxy（@MainActor ObservableObject）
                                                                        │
                                                              SwiftUI 视图观察 @Published
```

- **服务层写入**：`RefreshService` / `PersistenceService` 通过 `await state.setInstances(...)` 等 async 方法写入 `AppState`，由 Actor 序列化，确保无数据竞争。
- **UI 层读取**：每次写入完成后，服务层调用 `await proxy.syncFromState()`，将 Actor 内部状态副本拉取到 `@MainActor`，触发 `@Published` 属性变更，驱动 SwiftUI 视图更新。
- **UI 层操作**：用户点击刷新等操作通过 `AppStateProxy` 委托给服务层，服务层执行完成后回调 `syncFromState()`。

### 9.4 为何选择 Actor + Proxy 两层架构？

- **数据竞争安全**：所有对 `AppState` 的变更通过 async actor 方法执行，由 Swift 运行时序列化。`actor` 声明即编译期保证无并发写入。
- **服务不在 MainActor 上运行**：`RefreshService` 和 `PersistenceService` 在后台 Actor 上执行 I/O 操作，不阻塞主线程。
- **UI 读取是同步安全的**：`AppStateProxy` 在 `@MainActor` 上持有 UI 数据的 `@Published` 副本。SwiftUI 视图同步读取，无需 `await`。Actor 保证 `syncFromState()` 读取到的数据一致。
- **Actor 不持有 `@Published` 的原因**：`@Published` 是 `ObservableObject` 的机制，而 `actor` 不能遵循 `ObservableObject`（`objectWillChange` 要求同步发送，与 Actor 的异步语义冲突）。通过 Proxy 桥接是官方推荐模式。

### 9.5 视图观察

```swift
struct UsagePanelView: View {
    @StateObject private var appStateProxy: AppStateProxy

    var body: some View {
        VStack {
            if !appStateProxy.errorSummaries.isEmpty {
                ErrorSummaryBar(errors: appStateProxy.errorSummaries)
            }
            ForEach(appStateProxy.slotViewDataList) { slot in
                UsageCardView(slot: slot)
            }
            RefreshButton(action: { await appStateProxy.triggerManualRefresh() })
        }
    }
}
```

`AppStateProxy` 在应用启动时创建一次，注入到 SwiftUI 视图层级中。每次刷新周期结束后，`RefreshService` 调用 `appStateProxy.syncFromState()` 触发 UI 更新。

---

## 10. 错误处理策略

### 10.1 错误分类

| 类别 | 来源 | 用户体验 |
|------|------|----------|
| 网络不可用 | 无网络连接 | 槽位变灰，错误栏显示："Network error, retrying in X min" |
| 网络超时 | 请求超过 30s | 槽位变灰，退避重试，失败后错误栏显示 |
| 认证失败（401/403） | API Key 无效/已过期 | 槽位变灰，错误栏显示："API Key invalid, check settings" |
| 服务端错误（5xx） | API 服务商宕机 | 槽位变灰，错误栏显示："API error (code: XXX)" |
| 解析错误 | API 响应格式变更 | 槽位变灰，错误栏显示："API error (code: 0)" — 日志记录用于调试 |
| JSON 文件损坏 | 文件系统问题 | 回退到默认值，记录错误日志，向用户通知一次 |
| Keychain 读取失败 | 系统问题 | 记录错误日志，实例视为已禁用 |

### 10.2 降级策略

- **保留最后已知数据**：刷新失败时，槽位显示上次成功数据。菜单栏：文字保留原阈值颜色、整体应用 80% 透明度（详见 §7.5 特殊状态）。面板：卡片背景使用 `cardBgDim`，footer 显示 `⚠ {错误信息}` + `Cached {elapsed} ago`（详见 §10.x 面板 footer）。面板显示上次成功刷新时间戳。
- **部分成功处理**：若组 A（MiniMax）成功但组 B（DeepSeek）失败，MiniMax 实例正常更新，DeepSeek 实例单独进入陈旧态（菜单栏 80% 透明度 / 面板 footer 陈旧提示）。

#### mergeCycleResult 合并策略（2026-06-21）

每个刷新周期结束后，`RefreshService` 调用 `AppState.mergeCycleResult(cycleSuccesses:cycleErroredUUIDs:)` 一次性合并结果：

1. **成功覆盖**：`cycleSuccesses` 中的槽位写入 `_slotViewDataList`（ `isStale=false`，`lastFetchedAt` 更新）。
2. **失败保留**：`cycleErroredUUIDs` 中的 UUID 在 `_slotViewDataList` 里保留原槽位数据，但 `isStale=true`（陈旧检测的唯一字段）。
3. **删除清理**：`mergeCycleResult` 内部读取 `_instances`（而非外面传入 UUID 快照），消除 `getInstances()` → `merge` 间的 TOCTOU 窗口。实例被删除后，下次 merge 自动清理其缓存槽位。

> **并发安全**：`mergeCycleResult` 内部构造字典时使用 last-wins 模式（`byUUID[uuid] = slot`）而非 `Dictionary(uniqueKeysWithValues:)`。后者在重复 UUID 时 crash——正常路径不会发生，但对调用方 bug 是防御性安全。

#### 面板 footer 陈旧提示（2026-06-22）

陈旧检测统一通过 `slot.isStale` 字段读取（详见 §7.5）。陈旧态与阈值颜色判断正交：阈值颜色来自 `slot.colorState`，陈旧状态来自 `slot.isStale`，两者独立。

**当 `slot.isStale == true`**（陈旧数据）：

- 卡片背景使用 `cardBgDim`（而非 `cardBg`），整体视觉变暗。
- Footer 右对齐显示两行（按此顺序）：
  1. `⚠ {errorType.errorMessage}`（来自 `errorSummaryByUUID`）
  2. `Cached {elapsed} ago`（基于 `slot.lastFetchedAt`，通过 `Date.timeSinceNow` 格式化）
- "See details" 按钮始终保留——用户即使在失败状态下也能跳转 Provider 页面。

**当 `slot.isStale == false`**（新鲜数据）：

- Footer 显示 `Updated HH:MM`（基于 `lastRefreshAt`），或 `Window expired`（当 `windowExpired == true` 时）。
- **无连锁故障**：每个 `api_key_ref` 组独立失败。一组的失败不会阻止或延迟其他组。

### 10.3 日志记录

使用 `os.Logger`（Apple 统一日志系统）：

```swift
import os.log

let logger = Logger(subsystem: "com.example.APIUsageStatus", category: "refresh")

logger.error("DeepSeek API 返回 500，keyRef=\(ref, privacy: .private)")
logger.info("刷新周期完成：4 个实例已更新，0 个错误")
```

日志级别：
- `.debug`：仅开发环境使用，包含详细的响应解析信息
- `.info`：正常运行事件（刷新开始/完成、配置变更）
- `.error`：可恢复的错误（网络故障、API 错误）
- `.fault`：不可恢复的错误（数据损坏、Keychain 故障）

API Key 和敏感值以 `privacy: .private` 记录，防止出现在控制台日志中。

### 10.4 启动弹性

1. 若 `instances.json` 不存在 → 以空配置启动，显示 AI 品牌动画
2. 若 `instances.json` 已损坏 → 记录错误日志，以空配置启动
3. 若 Keychain 包含过期条目 → 刷新时跳过（该实例将显示错误）
4. 若余额历史 JSON 已损坏 → 重置为全新基线（丢失历史但优雅恢复）

---

## 11. 并发模型

### 11.1 线程架构

```
┌─────────────────────────────────────────────────┐
│  MainActor（主线程 / MainActor.run）            │
│  ┌─────────────────────────────────────────┐    │
│  │ AppStateProxy（ObservableObject）       │    │
│  │ MenuBarController                       │    │
│  │ UsagePanelView（SwiftUI）               │    │
│  │ SettingsWindow（SwiftUI）               │    │
│  │ NotificationManager（UN delegate）       │    │
│  │ MenuBarIconRenderer（NSImage 绘制）     │    │
│  └─────────────────────────────────────────┘    │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  AppState Actor（全局 actor，串行）             │
│  序列化的状态变更                                │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  RefreshService Actor（全局 actor，串行）       │
│  Timer 调度、请求分发、解析                     │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  PersistenceService Actor（全局 actor，串行）   │
│  JSON 读写、Keychain 访问                       │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  URLSession（系统管理的线程池）                 │
│  串行的 async HTTP 请求（各 api_key_ref 组顺序执行）│
└─────────────────────────────────────────────────┘
```

### 11.2 关键并发规则

1. **UI 始终在 `@MainActor`**：所有 `NSView` 绘制、SwiftUI 视图、`NSStatusItem` 和 `NSMenu` 交互发生在主 Actor。
2. **`AppState` 是独立 Actor**：所有读/写均序列化。`AppStateProxy` 在 `@MainActor` 上持有 `@Published` 副本供 UI 读取；服务通过 async actor 方法写入 `AppState`，再通过 `syncFromState()` 同步到 UI。
3. **`RefreshService` 是独立 Actor**：确保不会有两个刷新周期同时运行。Timer 和手动触发均调用 `performRefresh()`，由 Actor 序列化。
4. **`PersistenceService` 是独立 Actor**：防止并发文件写入。
5. **`KeychainService` 是 `PersistenceService` 的下属**：仅由 `PersistenceService` 调用，继承其序列化保证。
6. **`PixelFontEngine` 已弃用**：原纯函数模块无并发约束，现代码已注释，不再参与渲染管线。

### 11.3 HTTP 请求执行策略

在单次刷新周期内，多个 `api_key_ref` 组**串行**执行。不尝试并发，原因：

1. `async let` 在 Actor 上下文内会继承 Actor 隔离，即使目标函数标记为 `nonisolated`，Swift 运行时也可能将子任务序列化到 Actor 的执行器上执行，导致实际为串行而非并发
2. Swift 5.9+ 对 Actor 内并发调度有所改进，但行为在不同版本/优化级别下表现不一致，难以保证并行
3. 本应用每次刷新周期最多涉及 2 个 `api_key_ref` 组（MiniMax + DeepSeek），串行执行的两轮 HTTP 往返时间（各约 1–3 秒）完全在可接受范围内，不会产生可感知的延迟

```swift
actor RefreshService {
    func performRefresh() async {
        let groups = groupInstancesByApiKeyRef(instances)

        // 顺序迭代所有组，串行发起 HTTP 请求
        for (keyRef, instances) in groups {
            guard !Task.isCancelled else { break }
            do {
                let result = try await fetchGroup(keyRef: keyRef, instances: instances)
                // 逐组累积结果
            } catch {
                // 单组失败不影响后续组
            }
        }

        await appState.updateSlotData(allResults)
    }

    private func fetchGroup(keyRef: String, instances: [Instance]) async throws -> GroupResult {
        let apiKey = try await persistence.getApiKey(keyRef)
        let supplier = SupplierRegistry.get(instances.first!.provider)
        return try await withRetry {
            try await supplier.fetchUsage(apiKey: apiKey)
        }
    }
}
```

各 `api_key_ref` 组串行执行，但组内多个实例共享同一 HTTP 响应（请求去重）。由于每组耗时极少（HTTP 往返 + 解析 < 3 秒），总刷新耗时在可接受范围。

### 11.4 Timer 管理

不依赖 `Timer` 类（需要绑定 RunLoop，与 Actor 隔离上下文配合困难且容易引入调度/取消传播相关 bug）。采用纯结构化并发的 `Task.sleep` 循环：

```swift
actor RefreshService {
    private var refreshTask: Task<Void, Never>?

    func start(interval: TimeInterval) async {
        refreshTask?.cancel()
        refreshTask = Task {
            // 初始立即刷新
            await performRefresh()
            // 周期性刷新
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break  // sleep 被取消时自动退出
                }
                guard !Task.isCancelled else { break }
                await performRefresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
    }
}
```

**方案对比**：

| 方案 | 问题 |
|------|------|
| `Timer.scheduledTimer` + RunLoop | Timer 依赖 RunLoop，Actor 上下文不含 RunLoop；需手动管理 mode、线程归属 |
| 自定义 `AsyncTimerSequence` 封装 Timer | 需处理 RunLoop 调度、取消双向传播、Timer 失效等边缘情况 |
| **`Task.sleep` 循环（选用）** | 纯 Swift 结构化并发原语，无 RunLoop 依赖，取消自动传播，Actor 内天然安全 |

> 注意：`Task.sleep` 以挂起而非阻塞方式等待，Actor 在 sleep 期间可响应其他调用。若需精确到秒的间隔（与 PRD 的 1–60 分钟分钟级粒度相符），`Task.sleep` 完全满足精度要求。
>
> **ADR：MenuBarIconRenderer 的 Timer 方案**：MenuBarIconRenderer 的默认动画（1Hz `Timer`）与呼吸动画（5Hz `Timer`）都使用 `Timer.scheduledTimer`，调度在 `@MainActor` 的主 RunLoop 上。这与 `RefreshService` 的 `Task.sleep` 方案不同：`@MainActor` 上下文天然拥有主线程 RunLoop，Timer 适用且无需额外管理；UI 动画不需要 `Task.sleep` 的结构化并发保证。两者与 `RefreshService` 的分工：菜单栏 UI 动画用 Timer（1Hz 文本轮播 / 5Hz shadow 插值），后台数据刷新用 `Task.sleep`（分钟级间隔，结构化并发）。

---

## 12. 文件与目录结构

```
APIUsageStatus/
├── APIUsageStatus.xcodeproj
├── APIUsageStatus/
│   ├── APIUsageStatusApp.swift           # @main 入口 + AppDelegate
│   │
│   ├── AppState/
│   │   ├── AppState.swift                # 中央状态 Actor
│   │   └── AppStateProxy.swift           # @MainActor 包装器，供 SwiftUI 使用
│   │
│   ├── MenuBar/
│   │   ├── MenuBarController.swift       # NSStatusItem 生命周期、用量面板（NSWindow）、菜单
│   │   └── MenuBarIconRenderer.swift     # NSImage 生成、像素绘制编排
│   │
│   ├── Views/
│   │   ├── EmptyStateGuideView.swift     # 无实例时的居中引导视图（CTA 按钮）
│   │   ├── EmptyStateView.swift          # （旧版）空状态视图
│   │   ├── InstanceCardView.swift        # 实例卡片行（StatusDot + shortName 徽章 + 跟踪开关 + 编辑/删除按钮）
│   │   ├── InstanceDetailPanel.swift     # 通知点击后打开的独立 NSPanel（单实例用量详情）
│   │   ├── InstanceEditorView.swift      # 添加/编辑实例表单
│   │   ├── SettingsView.swift            # 设置窗口 SwiftUI 根视图（sidebar 导航）
│   │   ├── SettingsViewModel.swift       # 设置视图模型
│   │   ├── SettingsWindow.swift          # Settings NSPanel 窗口管理
│   │   ├── StatusDotView.swift           # 10×10pt 跟踪状态圆形指示器
│   │   ├── ThresholdConfigView.swift     # 阈值滑块/输入框
│   │   ├── UsageCardView.swift           # 单实例用量卡片
│   │   └── UsagePanelView.swift          # 面板内容 — 卡片列表 + 错误栏
│   │
│   ├── Services/
│   │   ├── RefreshService.swift          # Timer + 刷新编排 Actor
│   │   ├── PersistenceService.swift      # JSON + Keychain 持久化 Actor
│   │   ├── KeychainService.swift         # Keychain CRUD Actor
│   │   ├── NotificationManager.swift     # 阈值评估 + UN 通知
│   │   └── AppLaunchService.swift        # SMAppService 注册
│   │
│   ├── Network/
│   │   ├── NetworkClient.swift           # URLSession 包装器 Actor
│   │   ├── Endpoint.swift                # URL 请求构建器
│   │   └── RetryPolicy.swift             # 指数退避逻辑
│   │
│   ├── Suppliers/
│   │   ├── Supplier.swift                # Supplier 协议 + 响应类型
│   │   ├── SupplierRegistry.swift        # 可用供应商注册表
│   │   ├── MiniMaxSupplier.swift         # MiniMax /v1/token_plan/remains
│   │   ├── DeepSeekSupplier.swift        # DeepSeek /user/balance
│   │   ├── MiniMaxResponseParser.swift   # API 响应 → 内部维度标识符映射（每个 model_name 独立维度）
│   │   └── DeepSeekResponseParser.swift  # 解析原始 JSON → 余额信息
│   │
│   ├── Balance/
│   │   ├── BalanceCalculator.swift       # 日用量计算、平均值、历史
│   │   └── BalanceSnapshot.swift         # 模型：每实例余额状态
│   │
│   ├── PixelFont/                        # ⚠️ 已弃用：代码已注释，保留文件供历史参考
│   │   ├── PixelFontEngine.swift         # 原核心渲染（已注释）
│   │   ├── CharMapLetters.swift          # 原 5×7 位图（已注释）
│   │   └── CharMapDigits.swift           # 原 3×5 位图（已注释）
│   │
│   ├── Models/
│   │   ├── Instance.swift                # 实例配置模型
│   │   ├── MetricConfig.swift            # 指标配置（持久化，写入 instances.json）
│   │   ├── MetricSnapshot.swift          # 指标运行时快照（不持久化）
│   │   ├── GlobalSettings.swift          # 全局设置模型（含 InstancesContainer + schema 版本化）
│   │   ├── Thresholds.swift              # 阈值配置（带关联值的枚举）
│   │   ├── SlotViewData.swift            # 运行时槽位渲染数据
│   │   ├── ErrorSummary.swift            # 刷新错误模型
│   │   ├── RefreshState.swift            # 刷新生命周期枚举
│   │   ├── ColorState.swift              # 阈值颜色状态枚举
│   │   └── SupplierResponse.swift        # 领域响应模型
│   │
│   ├── Extensions/
│   │   ├── Color+Theme.swift             # 语义色彩令牌（Light/Dark 双模式）
│   │   ├── Date+Extensions.swift         # 日期辅助（零点、周起始等）
│   │   ├── Decimal+Extensions.swift      # 十进制格式化
│   │   ├── Provider+Icon.swift           # Provider → SF Symbol 名映射
│   │   └── String+Extensions.swift       # UUID 校验等
│   │
│   ├── Resources/
│   │   └── Info.plist                    # 应用配置、沙盒权限
│   │
│   └── Utilities/
│       ├── FileManager+Atomic.swift      # 原子写入扩展
│       └── Logger.swift                  # os.Logger 便利包装器
│
├── APIUsageStatusTests/
│   ├── BalanceCalculatorTests.swift
│   ├── MiniMaxResponseParserTests.swift
│   ├── DeepSeekResponseParserTests.swift
│   ├── CopilotResponseParserTests.swift
│   ├── RetryPolicyTests.swift
│   ├── WeeklyQuotaTests.swift
│   ├── FlowingGlowBarTests.swift
│   ├── MenuBarIconRendererTests.swift
│   ├── OpenCodeResponseParserTests.swift
│   ├── ShellProcessRunnerTests.swift
│   ├── BreathingMathTests.swift
│   ├── PersistenceServiceTests.swift    # Schema 版本化 + v1→v2 迁移检测
│   ├── SchemaVersionTests.swift         # InstancesContainer schemaVersion 编解码
│   ├── RefreshServiceMappingTests.swift # 1:N 映射（Instance.metrics → MetricSnapshot）
│   ├── MetricConfigCodableTests.swift   # MetricConfig Codable 往返
│   └── InstanceDecodingTests.swift      # 旧格式/新格式 Instance 解码兼容性
│
└── docs/
    ├── PRD.md
    └── ARCHITECTURE.md
```

---

## 13. 关键设计决策与权衡

### ADR-001：模块化单体而非微服务
**上下文**：单用户 macOS 应用，无服务端组件。
**决策**：模块化单体 —— 所有代码在同一进程、同一 Xcode Target 中。
**后果**：构建、调试和部署更简单。无 IPC 开销。若未来需要服务端组件（如共享配置同步），可单独提取后端。

### ADR-002：基于 Actor 的并发而非锁/DispatchQueue
**上下文**：Swift 5.5+ 提供结构化并发及 Actor。
**决策**：对 `AppState`、`RefreshService`、`PersistenceService` 和 `KeychainService` 使用 Swift Actor（`actor`）。
**后果**：编译期数据竞争安全。序列化边界清晰。权衡：必须考虑 Actor 可重入性（Actor 内部的 `await` 会挂起，允许其他调用交错执行）。缓解措施：保持 Actor 方法简短，避免在多步变更中间使用 `await`。

### ADR-003：代码绘制的像素字模而非系统字体 — **已废弃**
**上下文**：菜单栏空间极为有限（每槽位 44pt × 22pt）。系统字体带抗锯齿在此尺寸下不可读。PRD 明确要求像素完美渲染。
**决策（V1 早期）**：硬编码 5×7 / 3×5 位图，通过 `CGContext.fill(rect:)` 逐像素绘制。
**修订（当前）**：改回系统字体（SF Pro 10 pt）。Retina 屏幕下 10pt 系统字体经抗锯齿处理后清晰度已足够；同时取消固定 44pt 槽位宽度限制，改用 `NSStatusItem.variableLength` 自适应比例字体宽度。
**后果**：
- ~~**收益**：绝对渲染控制，无字体加载问题，无抗锯齿模糊，极小尺寸下清晰度完美。~~（已不再适用）
- **原让步**：不支持硬编码字符集以外的 Unicode。不支持动态字体大小。新增字符需编辑位图常量。
- **新收益**：与用量面板字体风格统一（均为系统字体 10pt）；无需维护字符映射表；支持任意 Unicode 符号；动态宽度自适应，不受固定槽位宽度约束。

### ADR-004：`kSecClassInternetPassword` 而非 `kSecClassGenericPassword`
**上下文**：需要存储多把 API Key，每把以 `api_key_ref` 索引。
**决策**：使用 `kSecClassInternetPassword`，设置 `kSecAttrServer` = 常量应用标识符，`kSecAttrAccount` = `api_key_ref`。
**后果**：两级属性查找（`server` + `account`）自然映射到我们的 `api_key_ref` 模型。`kSecClassInternetPassword` 正是为此场景设计的（存储互联网服务凭证）。

### ADR-005：单文件 `instances.json` 而非多配置文件
**上下文**：实例配置和全局设置需要持久化。
**决策**：一个 `instances.json` 文件包含所有实例和全局设置。
**后果**：
- **收益**：简单的原子读写，易于备份，一致性推理简单（一配置一文件）。
- **让步**：无每实例配置隔离。若某实例配置损坏（原子写入下极低概率），将影响所有实例。缓解措施：余额数据保持每实例独立文件，使历史损坏不影响配置。

### ADR-006：刷新时按 `api_key_ref` 去重
**上下文**：多个实例可能共享同一 API Key（如 3 个 MiniMax 维度使用同一把 Key）。分别发起 HTTP 调用会浪费带宽并可能触发频率限制。
**决策**：刷新前按 `api_key_ref` 分组实例；每组仅一次 HTTP 调用；将结果分发给各实例。
**后果**：
- **收益**：最小化 HTTP 请求。防止冗余 API 调用。单故障点按 Key 而非按实例，但共享同一 Key 的实例命运本就相同。
- **让步**：若某个维度解析失败而其他成功，错误处理更为复杂。缓解措施：从同一原始响应中独立解析所有维度，报告每维度错误。

### ADR-007：余额追踪仅使用 `topped_up_balance`（排除 `granted_balance`）
**上下文**：DeepSeek 同时返回 `topped_up_balance`（用户充值余额）和 `granted_balance`（促销赠金）。赠金可能过期，若计入将产生虚假的"消耗"。
**决策**：仅追踪 `topped_up_balance`，忽略 `granted_balance`。
**后果**：
- **收益**：准确的消耗追踪。免于赠金过期导致的误报。
- **让步**：若用户耗尽 `topped_up_balance` 后开始使用 `granted_balance`，追踪的消耗将变得不准确。缓解措施：`is_available = true` 且 `topped_up_balance = 0` 是可检测的状态 —— 可在未来版本中添加特殊指示器。

### ADR-008：通知点击打开独立的 NSPanel
**上下文**：当通知触发时（如「MiniMax-文字 at 96%」），点击应展示详情。
**决策**：点击通知打开一个独立的、非依附的 `NSPanel`，显示该实例的用量详情。
**后果**：
- **收益**：用户无需打开菜单栏用量面板即可查看详情。Panel 独立且可由系统定位。
- **让步**：可能存在两个窗口同时显示相同数据（NSPanel + 用量面板）。可接受，因为它们都是只读视图，且 NSPanel 在失活时自动关闭。

### ADR-009：原子文件写入（临时文件 + 重命名）
**上下文**：写入 JSON 文件在崩溃/断电时存在损坏风险。
**决策**：先写入 `.tmp` 文件，再执行 `FileManager.replaceItemAt(_, withItemAt:)`。
**后果**：
- **收益**：磁盘上不会出现部分写入/损坏的 JSON。要么旧文件存在，要么完整的新文件存在。
- **让步**：代码比简单的 `Data.write(to:)` 稍复杂。成本可忽略不计。

### ADR-010：`os.Logger` 而非第三方日志库
**上下文**：需要日志用于调试和诊断。
**决策**：使用 Apple 的 `os.Logger`（统一日志系统）。
**后果**：
- **收益**：零依赖。集成 Console.app。隐私感知（`privacy: .private`）。低开销（在 Release 构建中编译为仅内存日志条目，除非被收集）。
- **让步**：无结构化日志输出，无远程日志发送。对本地应用可接受。

---

## 14. 质量属性分析

### 14.1 性能
- **菜单栏渲染**：`NSAttributedString.draw(at:)` 在 `NSImage.lockFocus()` 上下文中由 Core Text + Core Graphics 加速，每槽位仅需数次字符串绘制调用，微不足道 —— 亚毫秒级。
- **内存**：目标常驻 < 50MB。主要来源：AppState 模型（< 1KB）、余额历史（约 100 字节/天增长，约 36KB/年）、URLSession 缓存（瞬时）。
- **CPU**：后台刷新受 I/O 限制（HTTP）。JSON 解析为亚毫秒级。Timer 每 1–60 分钟触发一次。空闲时 CPU 使用可忽略不计。

### 14.2 可靠性
- **网络故障**：指数退避重试（3 次）。永久失败时，保留上次已知数据并以灰色显示。
- **文件 I/O**：原子写入防止损坏。读取损坏文件时优雅回退。
- **应用终止**：`RefreshService.stop()` 取消 Timer。无数据丢失，因为所有写入即时完成（非批量）。
- **沙盒**：App Sandbox 确保应用无法访问容器外文件。网络权限是唯一必需的能力。

### 14.3 可维护性
- **模块边界**：UI、状态、服务和供应商之间清晰分离。新增供应商只需实现 `Supplier` 协议并在 `SupplierRegistry` 中注册 —— 无需修改 RefreshService 或 UI。
- **纯领域逻辑**：`BalanceCalculator` 无副作用，天然易于测试。
- **类型安全**：所有领域概念使用强 Swift 类型（`ColorState`、`ErrorType`、`InstanceType`），在编译期防止非法状态。

### 14.4 可观测性
- **日志记录**：所有刷新周期、错误和状态变更通过 `os.Logger` 记录。
- **Console.app**：所有日志在 macOS 控制台中通过子系统过滤（`com.example.APIUsageStatus`）可见。
- **Debug 构建**：额外的 `.debug` 级别日志提供响应解析细节。

### 14.5 安全性
- **API Key**：专存于 Keychain。绝不出现于 UserDefaults、JSON 文件或日志输出中。
- **网络**：仅 HTTPS。证书验证由 ATS（App Transport Security）强制执行。
- **沙盒**：App Sandbox 处于激活状态。仅授予网络客户端权限。
- **无分析统计**：零数据收集。除 API 供应商外无网络请求。

### 14.6 可测试性
- **可单元测试的模块**：`BalanceCalculator`、`RetryPolicy`、`MiniMaxResponseParser`、`DeepSeekResponseParser` —— 均为纯函数或确定性逻辑。
- **Actor 测试**：`AppState`、`RefreshService`、`PersistenceService` 可通过 await 其 async 方法并结合 mock/stub 依赖进行测试。
- **UI 测试**：SwiftUI Previews 结合 mock `AppStateProxy` 数据实现快速视觉迭代。
- **属性断言测试 + 快照测试**：`MenuBarIconRenderer` 的呼吸状态跟踪和动画生命周期通过属性断言测试验证；渲染输出可被捕获为 `NSImage` 并与参考图像对比。

---

## 附录 A：Entitlements 配置

```xml
<!-- APIUsageStatus.entitlements -->
<dict>
    <!-- 必需：允许外发 HTTPS 请求 -->
    <key>com.apple.security.network.client</key>
    <true/>

    <!-- App Sandbox -->
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <!-- 可选：用于将来配置的导入/导出 -->
    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>
</dict>
```

---

## 附录 B：最低部署目标

| 配置项 | 值 |
|--------|------|
| macOS 部署目标 | 13.0（Ventura） |
| Swift 语言版本 | 5.9+ |
| Xcode | 15.0+ |

macOS 13 作为最低版本的原因：
- 开机自启所需的 `SMAppService` 需要 macOS 13+
- Swift Actor 和结构化并发在 Swift 5.7+（Xcode 14+、macOS 13）中已成熟
- `NavigationStack` 及现代 SwiftUI 模式需要 macOS 13+

---

*本文档为活文档。架构决策应以 ADR 形式记录，并随项目演进链接至本文档。*
