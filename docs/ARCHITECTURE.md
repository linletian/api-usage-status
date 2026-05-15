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
│  MenuBarController, PopoverView, SettingsWindow  │
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
│  PixelFontEngine, NotificationManager,           │
│  Supplier 实现                                   │
└─────────────────────────────────────────────────┘
```

依赖方向**仅向下**。UI 层从 `AppState` 读取状态；服务层向 `AppState` 写入状态。无循环依赖。`PixelFontEngine` 为纯函数模块，不依赖任何其他模块。

---

## 2. 模块拆解

### 2.1 应用入口（`APIUsageStatusApp.swift`）

**职责**：应用生命周期、App Delegate、菜单栏初始化。

- `@main` App 结构体
- `AppDelegate`（NSApplicationDelegate）：设置 `NSStatusItem`，创建 `MenuBarController`
- 注册 `SMAppService` 以支持开机自启
- 请求通知权限

### 2.2 菜单栏控制器（`MenuBarController.swift`）

**职责**：持有 `NSStatusItem`，管理 `NSPopover`，协调图标渲染与点击处理。

- 管理单个可变长度的 `NSStatusItem`
- 监听 `AppState` 的槽位数据变化 → 触发重绘
- 左键单击 → 切换 Popover（Popover 内嵌 `UsagePanelView`）
- 右键 → `NSMenu`：立即刷新 / 打开设置 / 退出
- 通过 `MenuBarIconRenderer` 处理 `NSStatusBarButton` 的自定义绘制

### 2.3 菜单栏图标渲染器（`MenuBarIconRenderer.swift`）

**职责**：逐像素绘制菜单栏图标。

- 创建适配状态栏按钮尺寸的 `NSImage`
- 对每个活跃槽位（最多 2 个），使用 `PixelFontEngine` 渲染槽位布局
- 支持单色与彩色两种模式
- 处理特殊状态：`?`（无配置）、`NO API`（全部禁用）、`•••`（加载中）、`N/A`（余额不可用）
- 实现严重阈值的 1Hz 闪烁动画

### 2.4 用量面板与独立详情面板（`UsagePanelView.swift`、`UsageCardView.swift`、`InstanceDetailPanel.swift`）

**职责**：按实例展示用量卡片的 UI。

- `UsagePanelView`：承载可滚动的卡片列表 + 错误摘要栏 + 刷新按钮 + 设置入口（Popover 内）
- `UsageCardView`：单实例卡片 —— 配额型显示进度条 + 下次刷新剩余时间（分钟数），自然天/周配额型额外显示周期剩余天数；余额型显示余额 + 每日统计
- `InstanceDetailPanel`：点击通知后弹出的独立 `NSPanel`，展示单个实例的完整用量详情（与 UsageCardView 展示相同信息，但以独立窗口形式呈现，失活时自动关闭）
- 以上均为观察 `AppStateProxy` 的 SwiftUI 视图

### 2.5 设置窗口（`SettingsWindow.swift`、`SettingsViewModel.swift`）

**职责**：实例管理与全局设置。

- `SettingsWindow`：包裹 SwiftUI `SettingsView` 的 `NSWindow`
- `SettingsView`：基于标签页或列表的布局
  - 实例列表（添加/编辑/删除/排序）
  - 每实例阈值配置
  - 全局设置（刷新间隔、色彩模式、开机自启、通知开关）
- `SettingsViewModel`：在设置 UI 与 `PersistenceService`/`AppState` 之间协调
- 支持拖拽调整 `sort_order`

### 2.6 AppState（`AppState.swift`）

**职责**：应用运行时数据的唯一数据源。使用 **Actor**。

- 持有：
  - `instances: [Instance]` — 所有已配置实例
  - `slotViewDataList: [SlotViewData]` — 由 instances + 最新刷新结果派生的数据，供 UI 使用
  - `refreshState: RefreshState` — `.idle` 或 `.refreshing`（全局刷新进行中标志）
  - `errorSummaries: [ErrorSummary]` — 每实例错误信息，用于 Popover 错误栏
  - `globalSettings: GlobalSettings`
- 所有变更通过 Actor 上的 async 方法执行
- UI 通过 `AppStateProxy`（`@MainActor ObservableObject`）桥接观察，详见 §9

### 2.7 刷新服务（`RefreshService.swift`）

**职责**：编排刷新周期。使用 **Actor**。

- 管理定时刷新的 `Timer`，记录 `lastRefreshAt: Date` 用于计算下一次刷新的剩余分钟数
- 每次触发（定时或手动）：
  1. 按 `api_key_ref` 分组实例，以确定 HTTP 请求数量
  2. 对每组调用对应 `Supplier` 实现
  3. 以指数退避方式重试（最多 3 次）
  4. 解析响应，更新 `AppState`
  5. 对余额型实例触发余额历史计算，若 API 响应的 `currency` 与实例当前值不同，自动更新并写回 `instances.json`
  6. 对配额型实例计算时间派生字段（`nextRefreshMinutes`、`cycleRemainingDays`）
  7. 触发阈值评估与通知
- 应用终止时取消 Timer

### 2.8 供应商协议（`Supplier.swift`）

**职责**：定义 API 供应商的接口。

```swift
protocol Supplier {
    var provider: Provider { get }
    func fetchUsage(apiKey: String) async throws -> SupplierResponse
}

struct SupplierResponse {
    let rawData: [String: Any]  // dimension → value 映射
}
```

- `MiniMaxSupplier`：实现 `Supplier`。一次 HTTP 调用 `GET /v1/token_plan/remains` 返回 Token Plan 用量数据。实际响应格式待实现时确认（PRD 附录 B 注明官方文档未公开响应结构），`MiniMaxResponseParser` 作为适配层，将 API 响应字段映射为内部维度标识符（`text_model_5h` / `non_text_daily` / `weekly_total`）。解析逻辑实现前需先拉取实际 API 响应确认字段名与结构。
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

### 2.11 像素字模引擎（`PixelFontEngine.swift`）

**职责**：将文本渲染为像素位图。纯函数，无状态。

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
    │    MenuBarController：显示 "?"（0 个实例）或 "•••" 槽位（加载中状态）
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
Timer 触发 / 手动触发
    │
    ▼
RefreshService.performRefresh()
    │
    ├──▶ AppState.setRefreshState(.refreshing)
    │
    ├──▶ 按 api_key_ref 分组实例
    │     例如：实例 A、B 的 api_key_ref 均为 "minimax-token-plan"
    │           → 合并为一个 MiniMax 组
    │
    ├──▶ 对每个唯一 api_key_ref：
    │     │
    │     ├──▶ PersistenceService.getApiKey(ref) ──▶ KeychainService
    │     │
    │     ├──▶ SupplierRegistry.getSupplier(provider) ──▶ Supplier 实例
    │     │
    │     ├──▶ Supplier.fetchUsage(apiKey) ──▶ HTTP 请求 ──▶ API 服务器
    │     │         │
    │     │         ├── 成功 ──▶ 解析 SupplierResponse
    │     │         │
    │     │         └── 失败 ──▶ 指数退避重试（最多 3 次）
    │     │                              │
    │     │                              ├── 全部重试失败 ──▶ ErrorSummary
    │     │                              └── 重试成功 ──▶ SupplierResponse
    │     │
    │     └──▶ 映射 SupplierResponse → 每实例 SlotViewData
    │              （一次响应中提取多个 MiniMax 维度）
    │
    ├──▶ 对每个配额型实例，计算时间派生字段：
    │     │
    │     ├──▶ nextRefreshMinutes = refreshInterval - 上次刷新至今已过秒数 ÷ 60
    │     │
    │     └──▶ 按维度计算 cycleRemainingDays：
    │           - text_model_5h → nil（5h 滚动窗口无天概念）
    │           - non_text_daily → 距今日 23:59:59 天数（即 0 或 1）
    │           - weekly_total → 距本周日 23:59:59 天数
    │
    ├──▶ AppState.updateSlotData(slotViewDataList)
    │
    ├──▶ 对每个余额型实例：
    │     │
    │     ├──▶ BalanceCalculator.calculate(latestData, history) ──▶ 更新 BalanceSnapshot
    │     │     PersistenceService.saveBalanceSnapshot(uuid, snapshot)
    │     │
    │     └──▶ [自动修正货币] 若 API 响应含 currency 字段，且与实例当前 currency 不同：
    │              ├──▶ AppState 更新该实例的 currency
    │              └──▶ 若 currency 发生变更，PersistenceService.saveInstances(...) 写回 instances.json
    │
    ├──▶ NotificationManager.evaluateThresholds(instances, data)
    │         │
    │         └──▶ 若超过严重阈值则触发通知
    │
    ├──▶ AppState.setRefreshState(.idle)
    │     AppState.setErrorSummaries(errors)
    │
    ├──▶ AppStateProxy.syncFromState()
    │        （将 Actor 数据副本拉到 MainActor，触发 @Published → SwiftUI 重绘）
    │
    └──▶ MenuBarIconRenderer 触发重绘（观察 AppStateProxy）
         Popover 更新（观察 AppStateProxy）
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
    ├──▶ 创建 NSImage（高度 22pt × 总宽度）
    │
    ├──▶ 对每个槽位（最多 2 个）：
    │     │
    │     ├──▶ 确定槽位颜色（基于阈值 + 色彩模式）
    │     │
    │     ├──▶ PixelFontEngine.renderSlot(context, slotData, color)
    │     │     │
    │     │     ├──▶ renderText(shortName) → 2 字符 × 5×7 网格
    │     │     ├──▶ [配额型] renderProgressBar(percent) → 3pt × 18pt 进度条
    │     │     ├──▶ renderText(percentStr) → "82%"
    │     │     └──▶ [余额型] renderText(balanceStr) → "¥45"
    │     │
    │     └──▶ 若为严重阈值且在彩色模式下 → 启动 1Hz 闪烁 Timer
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
    var dimension: String       // 内部维度标识符："text_model_5h" | "non_text_daily" | "weekly_total" | "balance"
                                 // 注：与 API 响应字段名不一定相同，由 Parser 负责映射
    var displayName: String     // 用户自定义，如「MiniMax-文字」
    var shortName: String       // 2 个大写字母，用于菜单栏
    var apiKeyRef: String       // 引用 Keychain 条目；同 Key 的实例共享
    var enabled: Bool
    var sortOrder: Int
    var currency: String?       // "CNY" | "USD" | nil（nil 表示配额型）。余额型实例：每次 API 刷新时若响应含 currency 字段，自动更新为本值；用户也可手动设置初始值
    var thresholds: Thresholds
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
    let shortName: String           // 2 字母
    let instanceType: InstanceType
    let sortOrder: Int
    let colorState: ColorState

    enum InstanceType {
        case quota(percent: Double, usageValue: String, limitValue: String,
                   nextRefreshMinutes: Int,          // 距下次定时刷新的分钟数
                   cycleRemainingDays: Int?)           // 自然天/周配额型的周期剩余天数；5h 滚动窗口为 nil
        case balance(amount: String, isAvailable: Bool)
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
第 2 次：等待 1s + random(0, 1s)
第 3 次：等待 2s + random(0, 2s)
每组 API 总计最长等待时间：约 5s
```

```swift
func withRetry<T>(maxAttempts: Int = 3, operation: () async throws -> T) async throws -> T {
    var lastError: Error?
    for attempt in 0..<maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error
            if attempt < maxAttempts - 1 {
                let delay = pow(2.0, Double(attempt)) + Double.random(in: 0...1)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }
    throw lastError ?? RefreshError.maxRetriesExceeded
}
```

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

解析后的响应由 `MiniMaxResponseParser` 映射到内部维度标识符：

> **注意**：MiniMax 官方文档未公开 `GET /v1/token_plan/remains` 的响应体结构（PRD 附录 B）。实际字段名、嵌套层级、数据类型均需在实现时拉取 API 响应后确认。以下映射关系仅为规划性示意，不代表 API 真实字段：

| 内部维度标识符 | 含义 |
|---------------|------|
| `text_model_5h` | 文本模型 5 小时滚动窗口用量 |
| `non_text_daily` | 非文本模型每日配额用量 |
| `weekly_total` | 周累计请求数 |

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

### 7.1 槽位布局（44pt × 22pt）

每个槽位占据固定的 44pt × 22pt 区域（两个正方形宽度）。槽位内容以**单行水平**方式排列：

```
┌──────────────────────────────────────────────┐
│  MX  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  82% │  ← 配额型     │
│  2 字母    进度条          百分比              │
│              (3pt×18pt)    (像素字模)          │
└──────────────────────────────────────────────┘

┌──────────────────────────────────────────────┐
│  DS  ¥45                          │  ← 余额型  │
│  2 字母   余额数值                │            │
│           (像素字模)              │            │
└──────────────────────────────────────────────┘
```

**布局常量**：
- 简称：2 字符 × 每字符 5px 宽 = 10px，加 1px 间距 → 占据左侧约 12pt
- 进度条（仅配额型）：18pt 宽，3pt 高，垂直居中
- 数值文本：右对齐，占据剩余空间
- 槽位间间距：2pt

### 7.2 槽位选择（≥3 个实例）

当启用 ≥3 个实例时，菜单栏仅显示按 `sort_order`（升序）排列的**前 2 个**。其余实例仅在 Popover 面板中可见。这防止 macOS 截断菜单栏图标。

### 7.3 色彩模式逻辑

#### 色彩定义

| 用途 | 色值 | 说明 |
|------|------|------|
| 置灰色 | `#D6D0A0` | 所有非活跃状态（加载中/禁用/失败/余额不可用）统一置灰色。文字、进度条等所有槽位元素均以此色渲染 |
| 安全 | `#4CAF50` | 彩色模式下的正常状态 |
| 警告 | `#FFC107` | 彩色模式下的警告阈值 |
| 严重 | `#F44336` | 彩色模式下的严重阈值 |

**置灰实现方式**：不通过 `alphaValue` 或透明度操作，而是**直接以 `#D6D0A0` 作为渲染颜色传入 `PixelFontEngine`**，替换掉正常情况下应使用的颜色（无论单色还是彩色模式）。这避免了降 alpha 在单色模式下与系统外观颜色叠加后产生不可预期的视觉效果。

#### 单色模式
- 所有文字：跟随系统菜单栏外观（浅色主题黑色，深色主题白色）
- 进度条：填充比例编码阈值状态
  - 0–50%：空心轮廓（1px 描边，无填充）
  - 50–80%：下半部分实心填充
  - 80–100%：完全实心填充
- 严重阈值：整槽以 1Hz 频率闪烁（通过 `Timer` 切换 `NSView.alphaValue`）
- 余额型实例不闪烁，仅显示数值
- **非活跃状态**：整槽以 `#D6D0A0` 渲染所有元素，不闪烁

#### 彩色模式
- 每个槽位根据阈值独立着色：
  - 安全：绿色（`#4CAF50`）
  - 警告：黄/琥珀色（`#FFC107`）
  - 严重：红色（`#F44336`）
- 严重阈值：槽位以 1Hz 频率红色闪烁
- 余额型实例颜色根据剩余余额与阈值的比较决定
- **非活跃状态**：整槽以 `#D6D0A0` 渲染所有元素，不闪烁，与单色模式下外观一致

### 7.4 闪烁动画

```swift
// 于 MenuBarIconRenderer 中
func startFlashing(forSlot index: Int) {
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
        // 若槽位不再处于严重状态则停止
        guard self?.slotData[index].colorState == .critical else {
            timer.invalidate()
            return
        }
        // 切换可见性 → 触发重绘
        self?.flashingVisible.toggle()
        self?.triggerRepaint()
    }
}
```

### 7.5 特殊状态

所有非活跃状态统一以**置灰色 `#D6D0A0`** 渲染槽位全部内容（文字、进度条、符号），不依赖透明度操作。单色与彩色模式下置灰效果一致。

| 状态 | 视觉表现 | 渲染方式 |
|------|----------|----------|
| 无实例配置 | 单个 `?` 字符 | 以 `#D6D0A0` 渲染 |
| 加载中（首次刷新） | `•••`，进度条 | 以 `#D6D0A0` 渲染，进度条无填充 |
| 全部实例已禁用 | 像素字模 `NO API` | 以 `#D6D0A0` 渲染 |
| 余额不可用（`is_available = false`） | `N/A` | 以 `#D6D0A0` 渲染 |
| 刷新失败 | 上次成功数据照常显示，但全部元素以 `#D6D0A0` 渲染 | 以 `#D6D0A0` 替换正常颜色传入 `PixelFontEngine`，菜单栏不展示错误文字 |

> **设计理由**：选择固定色值 `#D6D0A0`（低饱和暖灰）而非降低 `alphaValue` 的方式，是因为：(1) 单色模式下 alpha 叠加系统黑/白色后视觉效果不稳定；(2) 固定色值在两种色彩模式和明暗主题下均能清晰传递「非活跃」语义，且与系统菜单栏常见的灰色图标风格协调。

---

## 8. 像素字模系统设计

### 8.1 字符集

**5×7 网格（字母 A-Z、符号字符）：**
- 5 列 × 7 行 = 每字符 35 位
- 用于：简称字母、`%`、`¥`、`$`、`.`、`?`、`•`、`/`

**3×5 网格（数字 0-9）：**
- 3 列 × 5 行 = 每字符 15 位
- 用于：百分比数字和余额金额
- 更紧凑，在有限槽位宽度内可容纳更多数字

### 8.2 数据结构

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
          [true, false, false, false, true],
          [true, true, true, true, true],
          [true, false, false, false, true],
          [true, false, false, false, true],
          [true, false, false, false, true]],

    "0": [[true, true, true],
          [true, false, true],
          [true, false, true],
          [true, false, true],
          [true, true, true]],
    // ... 完整字符集：A-Z, 0-9, %, ¥, $, ., ?, •, /
]
```

### 8.3 渲染算法

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

**像素缩放计算：**
- 槽位高度 = 22pt
- 可用垂直空间（扣除上下各 1pt 边距）= 20pt
- 5×7 字符：`scale = 20pt / 7 ≈ 2.85pt` → 向下取整以保证清晰度：2pt（14pt 高，居中）
- 3×5 数字：`scale = 20pt / 5 = 4pt`（但数字可能也使用相同的 2pt 缩放以保持一致性）
- 最终缩放值将在构建时通过视觉测试确定

### 8.4 文本渲染

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

槽位内容不使用任何系统字体 API（`NSFont`、`CTFont`、`attributedString`）。每个可见字符均通过 `CGContext.fill(rect:)` 调用绘制。

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

    // 变更方法（由服务层 Actor 调用，不由 UI 调用）
    func setInstances(_ newInstances: [Instance]) { ... }
    func updateSlotData(_ newData: [SlotViewData]) { ... }
    func setRefreshState(_ state: RefreshState) { ... }
    func setErrorSummaries(_ summaries: [ErrorSummary]) { ... }
    func updateSettings(_ settings: GlobalSettings) { ... }
}
```

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
        self.instances = i
        self.slotViewDataList = s
        self.refreshState = r
        self.errorSummaries = e
        self.globalSettings = g
    }

    func triggerManualRefresh() async {
        // 委托给 RefreshService，刷新完成后会回调 syncFromState()
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

- **保留最后已知数据**：刷新失败时，槽位显示上次成功数据，但所有元素以置灰色 `#D6D0A0` 渲染（详见 §7.3 色彩定义、§7.5 特殊状态）。Popover 显示上次成功刷新时间戳。
- **部分成功处理**：若组 A（MiniMax）成功但组 B（DeepSeek）失败，MiniMax 实例正常更新，DeepSeek 实例单独置灰。
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

1. 若 `instances.json` 不存在 → 以空配置启动，显示 `?`
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
6. **`PixelFontEngine` 无并发约束**：纯函数。可在任何上下文中调用，但实践中从 `@MainActor` 调用。

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
│   │   ├── MenuBarController.swift       # NSStatusItem 生命周期、Popover、菜单
│   │   └── MenuBarIconRenderer.swift     # NSImage 生成、像素绘制编排
│   │
│   ├── Views/
│   │   ├── UsagePanelView.swift          # Popover 内容 — 卡片列表 + 错误栏
│   │   ├── UsageCardView.swift           # 单实例用量卡片
│   │   ├── SettingsView.swift            # 设置窗口 SwiftUI 根视图
│   │   ├── InstanceEditorView.swift      # 添加/编辑实例表单
│   │   ├── ThresholdConfigView.swift     # 阈值滑块/输入框
│   │   ├── EmptyStateView.swift          # 「无实例」引导视图
│   │   └── InstanceDetailPanel.swift     # 通知点击后打开的独立 NSPanel（单实例用量详情）
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
│   │   ├── MiniMaxResponseParser.swift   # API 响应 → 内部维度标识符映射（字段待实现时确认）
│   │   └── DeepSeekResponseParser.swift  # 解析原始 JSON → 余额信息
│   │
│   ├── Balance/
│   │   ├── BalanceCalculator.swift       # 日用量计算、平均值、历史
│   │   └── BalanceSnapshot.swift         # 模型：每实例余额状态
│   │
│   ├── PixelFont/
│   │   ├── PixelFontEngine.swift         # 核心渲染：drawChar、drawText
│   │   ├── CharMapLetters.swift          # 5×7 位图：A-Z 及符号
│   │   └── CharMapDigits.swift           # 3×5 位图：0-9
│   │
│   ├── Models/
│   │   ├── Instance.swift                # 实例配置模型
│   │   ├── GlobalSettings.swift          # 全局设置模型
│   │   ├── Thresholds.swift              # 阈值配置（带关联值的枚举）
│   │   ├── SlotViewData.swift            # 运行时槽位渲染数据
│   │   ├── ErrorSummary.swift            # 刷新错误模型
│   │   ├── RefreshState.swift            # 刷新生命周期枚举
│   │   ├── ColorState.swift              # 阈值颜色状态枚举
│   │   └── SupplierResponse.swift        # 领域响应模型
│   │
│   ├── Extensions/
│   │   ├── Date+Extensions.swift         # 日期辅助（零点、周起始等）
│   │   ├── Decimal+Extensions.swift      # 十进制格式化
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
│   ├── RetryPolicyTests.swift
│   ├── PixelFontEngineTests.swift
│   └── PersistenceServiceTests.swift
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

### ADR-003：代码绘制的像素字模而非系统字体
**上下文**：菜单栏空间极为有限（每槽位 44pt × 22pt）。系统字体带抗锯齿在此尺寸下不可读。PRD 明确要求像素完美渲染。
**决策**：硬编码 5×7 / 3×5 位图，通过 `CGContext.fill(rect:)` 逐像素绘制。
**后果**：
- **收益**：绝对渲染控制，无字体加载问题，无抗锯齿模糊，极小尺寸下清晰度完美。
- **让步**：不支持硬编码字符集以外的 Unicode。不支持动态字体大小。新增字符需编辑位图常量。可接受，因为字符范围高度受限（2 字母代码、数字、符号）。

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
- **收益**：用户无需打开菜单栏 Popover 即可查看详情。Panel 独立且可由系统定位。
- **让步**：可能存在两个窗口同时显示相同数据（NSPanel + Popover）。可接受，因为它们都是只读视图，且 NSPanel 在失活时自动关闭。

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
- **菜单栏渲染**：`CGContext.fill(rect:)` 调用在 macOS 上由 GPU 加速。每槽位绘制约 500 个矩形（2 字符 × 35 像素 + 进度条 + 数字）微不足道 —— 亚毫秒级。
- **内存**：目标常驻 < 50MB。主要来源：AppState 模型（< 1KB）、余额历史（约 100 字节/天增长，约 36KB/年）、URLSession 缓存（瞬时）。
- **CPU**：后台刷新受 I/O 限制（HTTP）。JSON 解析为亚毫秒级。Timer 每 1–60 分钟触发一次。空闲时 CPU 使用可忽略不计。

### 14.2 可靠性
- **网络故障**：指数退避重试（3 次）。永久失败时，保留上次已知数据并以灰色显示。
- **文件 I/O**：原子写入防止损坏。读取损坏文件时优雅回退。
- **应用终止**：`RefreshService.stop()` 取消 Timer。无数据丢失，因为所有写入即时完成（非批量）。
- **沙盒**：App Sandbox 确保应用无法访问容器外文件。网络权限是唯一必需的能力。

### 14.3 可维护性
- **模块边界**：UI、状态、服务和供应商之间清晰分离。新增供应商只需实现 `Supplier` 协议并在 `SupplierRegistry` 中注册 —— 无需修改 RefreshService 或 UI。
- **纯领域逻辑**：`BalanceCalculator` 和 `PixelFontEngine` 无副作用，天然易于测试。
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
- **可单元测试的模块**：`BalanceCalculator`、`PixelFontEngine`、`RetryPolicy`、`MiniMaxResponseParser`、`DeepSeekResponseParser` —— 均为纯函数或确定性逻辑。
- **Actor 测试**：`AppState`、`RefreshService`、`PersistenceService` 可通过 await 其 async 方法并结合 mock/stub 依赖进行测试。
- **UI 测试**：SwiftUI Previews 结合 mock `AppStateProxy` 数据实现快速视觉迭代。
- **快照测试**：`MenuBarIconRenderer` 的输出可被捕获为 `NSImage` 并与参考图像对比。

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
