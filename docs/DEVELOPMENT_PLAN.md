# 开发计划：API Usage Status

> **项目性质**：自用脚手架项目，不计划公开发布或上架 Mac App Store。
> **平台**：macOS 13+ (Ventura)
> **语言**：Swift 5.9+，Xcode 15.0+

---

## 总体概述

本计划将整个产品按 **8 个阶段（Phase 0–7）** 逐步交付。每个阶段有明确的交付物、风险和预估工期。阶段之间严格按依赖关系推进 —— 除非依赖项已稳定，否则不进入下一阶段。

### 全局风险清单

| 风险 | 等级 | 影响阶段 | 缓解措施 |
|------|------|----------|----------|
| MiniMax API 响应格式未公开 | 高 | Phase 1、2 | 提前拉取实际响应确认字段结构再编写 Parser |
| macOS 沙盒 + Keychain 在 ad-hoc 签名下行为不确定 | 中 | Phase 0、1 | Phase 0 即验证管道是否可用，尽早暴露问题 |
| 像素字模在 22pt 高度下的可读性不及预期 | 中 | Phase 2 | Phase 0/2 尽早实物渲染验证，必要时调整字符尺寸 |
| 菜单栏空间受限，多槽位可能被系统截断 | 低 | Phase 2 | 架构已限定最多 2 槽位，风险可控 |
| App Sandbox 文件路径在沙盒容器内读写权限问题 | 中 | Phase 1 | Phase 0 即验证基本文件 I/O |

---

## Phase 0：可行性原型（菜单栏骨架）

### 目标

验证 macOS 13 下 `NSStatusItem` + `NSPopover` + App Sandbox 管道可以正常工作，确认基本技术方案可行，为后续所有功能开发铺路。

### 交付物

- Xcode 项目创建完毕（Target 名称 `APIUsageStatus`，Bundle ID 确定）
- 启用 App Sandbox（`com.apple.security.app-sandbox` = true）
- 启用网络客户端权限（`com.apple.security.network.client` = true）
- `NSStatusItem` 在菜单栏显示，图标内容为单个 ASCII 字符 `?`（使用系统字体即可，无需像素字模）
- 左键单击 `?` 图标弹出 `NSPopover`
- `NSPopover` 内容为空（仅有占位文本或无内容的空白视图）
- 右键菜单含「退出」选项（功能完整）
- App 可以正常启动、显示图标、打开/关闭 Popover、退出

### 不在范围内

- 无任何数据模型（不创建 `Instance`、不加载 `instances.json`）
- 无任何网络请求
- 无 Keychain 访问
- 无设置窗口
- 无像素字模引擎
- 无后台刷新

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.1 菜单栏图标 | 菜单栏常驻 + `?` 符号 + Popover 交互 |
| PRD | §3.5 偏好设置 | 首次使用提示 |
| PRD | §4 用户交互流程 | 左键/右键交互图 |
| ARCHITECTURE | §1 高层架构概览 | 组件图、依赖方向 |
| ARCHITECTURE | §2.1 应用入口 | `APIUsageStatusApp` 启动入口 |
| ARCHITECTURE | §2.2 菜单栏控制器 | `MenuBarController` 设计 |
| ARCHITECTURE | §12 文件与目录结构 | 项目文件组织规范 |

### 依赖

- 无（项目从零开始）

### 产出物清单

- 完整的 Xcode 项目（`APIUsageStatus.xcodeproj`）
- `APIUsageStatusApp.swift`（`@main` + `NSApplicationDelegate`）
- `MenuBarController.swift`（`NSStatusItem` + `NSPopover` + 右键菜单）
- `.entitlements` 文件（App Sandbox + Network Client）
- `Info.plist`（LSUIElement = true，纯菜单栏应用，无 Dock 图标）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 沙盒下 `NSStatusItem` 行为受限 | 沙盒可能阻止部分菜单栏交互 | 立即在 Debug 构建下测试，若受限则评估关闭沙盒或调整 entitlements |
| `NSPopover` 在 macOS 13 行为异常 | 已知某些版本 Popover 有焦点/层级问题 | 测试点击 Popover 外部是否正常关闭、右键菜单是否正常弹出 |

### 预估工期

**1–2 天**（含项目初始化和踩坑时间）

---

## Phase 1：核心数据管道

### 目标

建立从「数据源头」（API）到「内存状态」（AppState）的完整数据流通路，使应用可以在后台拉取 API 数据、解析为内部模型、持久化到磁盘，并能在日志中验证数据正确性。本阶段结束时，数据可以在 Debug 控制台打印，但尚无 UI 展示。

### 交付物

#### 1a. 数据模型层
- `Instance`、`GlobalSettings`、`Thresholds` 等全部 Swift 模型定义完成
- `instances.json` 读写逻辑通过 `PersistenceService` 实现（原子写入）
- 启动弹性：`instances.json` 缺失时以空配置启动（显示 `?`）；文件损坏时记录错误日志并以空配置降级启动
- 余额历史弹性：`{uuid}.json` 损坏或缺失时重置基线（记录日志，该实例从全新基线开始跟踪）

#### 1b. Keychain 集成
- `KeychainService` 封装 `kSecClassInternetPassword` 的 CRUD
- `PersistenceService` 通过 `api_key_ref` 读写 API Key

#### 1c. 网络层
- `NetworkClient`（`URLSession` + `async/await`，30 秒超时）
- `Endpoint` 构建器
- 指数退避重试策略（最多 3 次）
- `RefreshError` 错误分类（网络超时/不可达/HTTP 错误/解析错误）

#### 1d. 供应商实现
- `Supplier` 协议 + `SupplierResponse` 模型定义
- `MiniMaxSupplier`：实现 `GET /v1/token_plan/remains`
  - **注意**：必须先拉取一次真实 API 响应，确认字段结构后再编写 `MiniMaxResponseParser`
- `DeepSeekSupplier`：实现 `GET /user/balance`
  - `DeepSeekResponseParser`：解析 `is_available`、`topped_up_balance`、`currency` 等字段
- `SupplierRegistry`：工厂方法，按 `provider` 字符串返回 `Supplier` 实例

#### 1e. AppState + 刷新服务
- `AppState` Actor：持有 `instances`、`slotViewDataList`、`refreshState`、`errorSummaries`、`globalSettings`
- `RefreshService` Actor：实现刷新周期编排（定时 `Task.sleep` 循环 + 手动触发）
  - 按 `api_key_ref` 分组去重
  - 串行调用各供应商 API
  - 解析结果写入 `AppState`
  - 对余额型实例触发 `BalanceCalculator` 计算
  - 货币自动修正（API 返回 currency 与实例当前值不同时更新）
- `AppStateProxy`（`@MainActor ObservableObject`）：桥接 Actor 数据到 SwiftUI

#### 1f. 持久化桥接
- `PersistenceService.loadInstances()` → 启动时恢复配置
- 每次刷新后即时保存余额快照到 `{uuid}.json`

#### 1g. 日志与工具基础设施
- `os.Logger` 初始化（subsystem: `com.example.APIUsageStatus`，按模块分 category）
- 日志级别：`.debug`（开发期响应解析）、`.info`（刷新周期）、`.error`（网络/API 错误）、`.fault`（数据损坏/Keychain 故障）
- API Key 等敏感值使用 `privacy: .private`，防止出现在 Console.app 输出中
- 必需的工具扩展：`Date+Extensions`（零点/周起始）、`Decimal+Extensions`（十进制格式化）、`FileManager+Atomic`（原子写入封装）

### 不在范围内

- 菜单栏图标渲染（Phase 0 的原型图标保留，不更新）
- Popover UI
- 设置窗口
- 通知
- 启动自启

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.3 支持的供应商与统计维度 | 供应商类型与统计维度定义 |
| PRD | §3.4 数据刷新 | 定时/手动/启动刷新、指数退避重试 |
| PRD | §3.6 数据安全 | Keychain 存储方案 |
| PRD | §3.7 余额型当日用量本地统计 | 持久化方案 |
| PRD | §3.8 配置数据持久化 | instances.json 完整 schema |
| PRD | 附录 A DeepSeek API | API 接口定义与响应字段 |
| PRD | 附录 B MiniMax API | API 接口定义 |
| ARCHITECTURE | §2.6 AppState | 核心状态 Actor 设计 |
| ARCHITECTURE | §2.7 刷新服务 | RefreshService Actor 设计 |
| ARCHITECTURE | §2.8 供应商协议 | Supplier 协议设计 |
| ARCHITECTURE | §2.9 持久化服务 | PersistenceService 设计 |
| ARCHITECTURE | §2.10 Keychain 服务 | KeychainService 设计 |
| ARCHITECTURE | §2.13 余额计算器 | BalanceCalculator 设计 |
| ARCHITECTURE | §2.14 供应商注册表 | SupplierRegistry 工厂设计 |
| ARCHITECTURE | §3 数据流图 | 整体数据流设计 |
| ARCHITECTURE | §4 数据模型与存储设计 | 数据模型与存储方案 |
| ARCHITECTURE | §5 Keychain 集成设计 | Keychain 集成方案 |
| ARCHITECTURE | §6 网络层设计 | NetworkClient 与指数退避 |
| ARCHITECTURE | §9 状态管理方案 | AppState + AppStateProxy 桥接 |
| ARCHITECTURE | §10 错误处理策略 | RefreshError 分类与处理 |
| ARCHITECTURE | §11 并发模型 | Actor 并发模型设计 |
| ARCHITECTURE | §13 ADR | ADR-002/Actor并发, ADR-004/Keychain方案, ADR-006/请求去重, ADR-007/余额追踪, ADR-009/原子写入 |

### 依赖

- **Phase 0**（Xcode 项目、App Sandbox 管道已确认可用）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| MiniMax API 响应结构不确定 | 官方文档未公开字段 | 先 VPN/代理抓包或直接调用一次获取示例响应 JSON，确认字段名后再实现 Parser |
| DeepSeek API 余额字段语义变化 | 若有版本变更 | 以 PRD 附录 A 为准，若实际返回不同则适配 |
| Swift Actor 可重入性问题 | Actor 内 `await` 后状态可能被其他调用交错修改 | 保持 Actor 方法简短，不在多步变更中间使用 `await` |
| 余额计算边界条件 | 首次刷新、充值、跨天等场景 | 编写 `BalanceCalculator` 单元测试覆盖所有边界情况 |

### 预估工期

**1.5–2 周**

---

## Phase 2：菜单栏图标渲染

### 目标

实现像素字模引擎和菜单栏渲染管线，使菜单栏图标可以实时反映数据状态。所有槽位以像素字模逐像素绘制，不依赖系统字体渲染。

### 交付物

#### 2a. 像素字模引擎
- `CharMapLetters`：A–Z 及符号字符（`%`、`¥`、`$`、`.`、`?`、`•`、`/`）的 5×7 硬编码位图
- `CharMapDigits`：0–9 的 3×5 硬编码位图
- `PixelFontEngine`：纯函数模块，提供 `renderChar`、`renderText`、`renderSlot` 等方法
- 像素缩放计算（在 22pt 槽位高度内确保清晰可读）

#### 2b. MenuBarIconRenderer
- 根据 `AppStateProxy.slotViewDataList` 数据动态生成 `NSImage`
- 单槽位布局（44pt × 22pt）：简称（左 2 字母）+ 进度条（中，3pt×18pt）+ 数值（右）
  - 配额型实例：简称 + 进度条 + 百分比数字
  - 余额型实例：简称 + 余额数值（不渲染进度条）
- 多槽位排列：按 `sort_order` 升序排列，`sort_order` 相同时按实例创建时间升序排列；最多显示 2 个槽位
- 槽位间间距：2pt

#### 2c. 特殊状态渲染
- 无实例配置：显示 `?`（像素字模）
- 启动加载中：显示 `•••`（像素字模，置灰 `#D6D0A0`）
- 全部禁用：显示 `NO API`（像素字模，置灰 `#D6D0A0`）
- 余额不可用：显示 `N/A`（像素字模，置灰 `#D6D0A0`）
- 刷新失败：上次成功数据以置灰色 `#D6D0A0` 渲染

#### 2d. 色彩模式
- **单色模式**：文字跟随系统菜单栏明暗主题（黑/白），进度条以填充比例编码阈值状态
- **彩色模式**：每个槽位根据阈值独立着色（安全 `#4CAF50` / 警告 `#FFC107` / 严重 `#F44336`）
- 严重阈值闪烁动画（1Hz，`Timer` + `alphaValue` 切换）

#### 2e. MenuBarController 数据绑定
- 观察 `AppStateProxy.slotViewDataList` 变化 → 自动触发重绘
- `AppStateProxy.refreshState` 变化 → idle/refreshing 状态处理
- 将渲染好的 `NSImage` 设置到 `NSStatusBarButton.image`

### 不在范围内

- Popover UI 内容（Phase 0 的空 Popover 保留）
- 设置窗口（用户尚无法配置实例，需通过硬编码或测试数据验证渲染效果）
- 通知

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.1 菜单栏图标 | 槽位尺寸 44pt×22pt、单行布局规则、像素字模、特殊状态 ?/•••/NO API/N/A、单色/彩色模式、严重闪烁、槽位排序与截断 |
| ARCHITECTURE | §2.3 菜单栏图标渲染器 | MenuBarIconRenderer 设计 |
| ARCHITECTURE | §2.11 像素字模引擎 | PixelFontEngine 设计 |
| ARCHITECTURE | §3.3 菜单栏渲染流程 | 渲染数据流 |
| ARCHITECTURE | §7 菜单栏渲染管线 | 槽位布局图、色彩模式逻辑、特殊状态表 |
| ARCHITECTURE | §8 像素字模系统设计 | 字符集 5×7/3×5、渲染算法、像素缩放 |
| ARCHITECTURE | §13 ADR | ADR-003/像素字模 |

### 依赖

- **Phase 1**（AppState、SlotViewData、RefreshService 已就绪）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 像素字模在 22pt 高度可读性不达标 | 2pt/px 像素在 Retina 屏幕上可能过小 | Phase 2 早期先渲染几个采样字符截图验证，必要时调整缩放比或字符尺寸 |
| 单色模式下阈值状态难以区分 | 仅靠进度条填充比例区分 0–50%/50–80%/80–100% | 实机测试，若不够直观可增加微妙的小标记（如进度条端点句柄） |
| 闪烁动画与菜单栏重绘冲突 | `NSStatusBarButton` 频繁重绘可能闪烁或卡顿 | 使用 `alphaValue` 切换而非完整重绘；控制 Timer 生命周期 |
| Retina 屏幕下像素绘制对齐问题 | 非整数坐标可能导致模糊 | 所有 `CGRect` 坐标取整，或使用 `NSView` 的 `layer` 绘制 |

### 预估工期

**1.5–2 周**（像素字模引擎约占 1 周，渲染管线约占 1 周）

---

## Phase 3：Popover 用量面板

### 目标

将 Phase 0 的空 Popover 替换为功能完整的用量详情面板。用户点击菜单栏图标后可以看到所有实例的用量卡片、错误摘要和操作按钮。

### 交付物

#### 3a. UsagePanelView（SwiftUI，Popover 内）
- 可滚动的卡片列表容器
- 错误摘要栏（当存在刷新失败的实例时，在面板顶部显示）
  - 区分错误类型：Network error / API Key invalid / API error (code: XXX)
  - 每项错误关联到具体实例
- 手动刷新按钮
- 「设置」入口按钮 → 打开设置窗口（Phase 4 实现窗口本体）
- 空状态视图（无实例配置时显示引导文案 + 「添加第一个服务」按钮）

#### 3b. UsageCardView（单实例用量卡片）
- **配额型实例卡片**：
  - 显示名（如「MiniMax-文字」）
  - 用量进度条（百分比 + 用量/上限数值）
  - 距下次定时刷新的分钟数
  - 自然天/周配额型额外显示「周期剩余天数」
- **余额型实例卡片**：
  - 显示名（如「DS-主号」）
  - 当前剩余余额（金额）
  - 当日用量（标注「约」）
  - 日均消耗（用户配置的统计周期分列展示）
- 最近一次刷新时间

#### 3c. 数据绑定
- `UsagePanelView` 观察 `AppStateProxy`：
  - `slotViewDataList` → 驱动卡片列表
  - `errorSummaries` → 驱动错误摘要栏
  - `refreshState` → 驱动刷新按钮状态
- 刷新按钮 → 调用 `AppStateProxy.triggerManualRefresh()`

### 不在范围内

- 设置窗口本体（仅保留入口按钮，点击可 placeholder 或无操作）
- InstanceDetailPanel（Phase 6）
- 通知（Phase 6）

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.2 用量面板 | 卡片展示规则、配额型/余额型卡片内容、错误摘要栏、手动刷新、日均消耗统计 |
| PRD | §4 用户交互流程 | 点击图标展开 Popover 交互 |
| ARCHITECTURE | §2.4 用量面板与独立详情面板 | UsagePanelView / UsageCardView / InstanceDetailPanel |
| ARCHITECTURE | §9.5 视图观察 | 视图层数据绑定设计 |

### 依赖

- **Phase 1**（AppState + AppStateProxy 数据桥接已就绪）
- **Phase 2**（菜单栏图标已正确反映数据状态）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| SwiftUI 在 `NSPopover` 内布局异常 | Popover 尺寸自适应可能不精确 | 使用 `fixedSize` 或手动设置 `preferredContentSize` |
| 大量实例时 Popover 过长 | ≥3 个实例全部展开导致面板超屏 | 列表加 `ScrollView`，必要时设置最大高度 |
| 余额型卡片日均消耗计算 | 多个统计周期同时展示导致卡片过高 | 使用紧凑布局（单行/双行切换），可折叠设计 |

### 预估工期

**1–1.5 周**

---

## Phase 4：设置窗口

### 目标

实现完整的设置窗口，用户可以在 GUI 中管理服务实例（增/删/改/排序）、配置阈值、调整全局偏好设置。所有变更即时持久化到 `instances.json`，并通过 `AppState` 刷新 UI。

### 交付物

#### 4a. SettingsWindow
- 包裹 SwiftUI `SettingsView` 的 `NSWindow`
- 通过 Popover 内的设置按钮和右键菜单「打开设置」均可打开

#### 4b. SettingsView（SwiftUI）
- 标签页式或列表式布局
- **实例列表**：
  - 现有实例列表（启用/禁用切换）
  - 添加实例按钮 → 进入 `InstanceEditorView`
  - 编辑按钮 → 进入 `InstanceEditorView`
  - 删除按钮（同步清理 `{uuid}.json` 和 Keychain）
  - 拖拽调整 `sort_order`（同 `api_key_ref` 实例间排序；跨 Key 的实例自由排序）
- **通用设置**：
  - 刷新间隔选择（1–60 分钟，默认 5）
  - 图标色彩模式（单色 / 彩色）
  - 开机自启开关（暂不实现实际功能，Phase 7 接入）
  - 通知开关（暂不实现实际功能，Phase 6 接入）

#### 4c. InstanceEditorView（添加/编辑实例表单）
- **基本字段**：
  - 供应商选择（MiniMax / DeepSeek）
  - 统计维度选择（与供应商联动：MiniMax → 文本模型 5h/非文本每日/周累计；DeepSeek → 余额）
  - 显示名（用户自定义，默认空）
  - 显示名简称（2 个大写字母，默认空）
  - API Key（输入框，保存到 Keychain）
  - 货币类型（仅余额型实例出现，默认 CNY，可选 CNY/USD）
- **阈值配置**（根据实例类型动态展示）：
  - 配额型：用量百分比警告线 / 严重线滑块
  - 余额型：余额警示阈值 / 严重阈值输入框
  - 余额型专属：日均消耗统计周期多选、历史保留天数

#### 4d. SettingsViewModel
- 协调 SwiftUI 视图与 `PersistenceService` / `AppState` 之间的读写
- 保存时：
  - `PersistenceService.saveInstances(...)` 写入 `instances.json`
  - 若 API Key 变更，`PersistenceService.saveApiKey(...)` 写入 Keychain
  - 若实例删除，清理关联文件和 Keychain 条目（若无其他实例共享同一 `api_key_ref`）
  - 通知 `AppState` 更新，触发 `AppStateProxy.syncFromState()`
- 若刷新间隔变更，通知 `RefreshService.restartTimer()`

#### 4e. 拖拽排序
- 实例列表支持通过拖拽手势调整 `sort_order`
- 拖拽完成后自动保存到 `instances.json`

### 不在范围内

- SMAppService 实际注册（Phase 7）
- 通知权限请求（Phase 6）

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.3 供应商与统计维度 | 实例管理 |
| PRD | §3.5 偏好设置 | 服务实例管理、配色与阈值、通用设置全部字段 |
| PRD | §3.8 配置数据持久化 | instances.json schema + 字段说明 + 实例删除清理规则 |
| ARCHITECTURE | §2.5 设置窗口 | SettingsWindow / SettingsViewModel |
| ARCHITECTURE | §3.4 设置写入流程 | 设置数据写入流程 |
| ARCHITECTURE | §4.1 内存模型 | Instance / GlobalSettings / Thresholds 等 Swift struct |
| ARCHITECTURE | §9 状态管理方案 | 状态管理设计 |

### 依赖

- **Phase 1**（PersistenceService、AppState、KeychainService 全部就绪）
- **Phase 3**（Popover 中有「设置」入口可点击）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 表单复杂度过高 | 配额型、余额型表单字段差异大，动态表单切换逻辑复杂 | 使用 SwiftUI `Group` + 条件渲染，将配额/余额字段拆分为独立 `View` |
| 拖拽排序与 SwiftUI List 兼容性 | SwiftUI 原生拖拽在 macOS 14+ 才完善 | 目标 macOS 13，需使用 `onMove` 或自定义拖拽手势 |
| 实例删除清理遗漏 | Keychain 残留、JSON 文件未删除 | 编写删除清理的单元测试，覆盖无共享 Key、有共享 Key 等场景 |
| 货币自动更新写回冲突 | 用户手动修改货币的同时 API 返回不同货币 | 明确优先级：API 返回值自动覆盖手动设置（PRD 已明确此行为） |

### 预估工期

**1.5–2 周**（设置表单和拖拽排序较复杂）

---

## Phase 5：余额跟踪

### 目标

实现 PRD §3.7 的完整余额跟踪逻辑：余额型实例的当日用量本地统计、日均消耗计算、历史记录存储和查询。所有计算在每次刷新后即时执行和持久化。

### 交付物

#### 5a. BalanceCalculator（纯函数模块）
- 实现以下核心逻辑：
  - 跨日检测 → 归档昨日 `today_usage` 到 `history`，重置 `today_date` 和 `today_usage`
  - `topped_up_balance` 差值计算（`current < latest` → 正常消耗，计入 `today_usage`）
  - 充值检测（`current > latest` → 不计消耗，更新 `last_topup_date`，更新基线）
  - 首次刷新处理（`latest_topped_up` 不存在 → 写基线，不计算消耗）
- 日均消耗计算：
  - 当前自然周（周日到今）
  - 当前自然月（1 日到今）
  - 倒数 7 天
  - 倒数 30 天
- 历史记录清理逻辑（按 `historyRetentionDays` 裁剪）

#### 5b. BalanceSnapshot 持久化
- 每次刷新后，`RefreshService` 调用 `BalanceCalculator` 计算，结果通过 `PersistenceService` 保存到 `{uuid}.json`
- 文件格式严格遵循 PRD §3.7 定义的 JSON schema

#### 5c. 余额型卡片 UI 增强（Phase 3 的 UsageCardView 补充）
- 当日用量（标注「约」）
- 日均消耗（用户配置的统计周期，分列展示）
- 「充值余额」vs「赠金余额」区分展示（仅 `topped_up_balance` 用于计算）

### 不在范围内

- 余额型通知（Phase 6）
- 图表/趋势展示（未来的增强，V1 不实现）

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.7 余额型当日用量本地统计 | 完整算法：跨日检测、topped_up_balance 差值、充值检测、日均消耗 4 种周期、历史保留天数 |
| PRD | 附录 A DeepSeek API | topped_up_balance 字段语义 |
| ARCHITECTURE | §2.13 余额计算器 | BalanceCalculator 设计 |
| ARCHITECTURE | §3.2 刷新周期 | 刷新周期中余额处理部分 |
| ARCHITECTURE | §4.1 数据模型 | BalanceSnapshot / DailyUsageEntry 模型 |
| ARCHITECTURE | §13 ADR | ADR-007/仅追踪 topped_up_balance |

### 依赖

- **Phase 1**（BalanceSnapshot 模型、PersistenceService、RefreshService 已就绪）
- **Phase 3**（UsageCardView 已存在，此阶段仅增强）
- **Phase 4**（用户已能配置统计周期和阈值）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 充值检测误判 | 短时间内多次充值可能只检测到一次 | 确保每次刷新都更新 `latest_topped_up`，差值判断逻辑覆盖所有情况 |
| 余额精度问题 | 字符串形式的十进制数值在比较和计算时需要精确处理 | 使用 `Decimal` 类型或保持字符串比较（两字符串都解析为 `Decimal` 后运算） |
| 历史数据无限增长 | 默认永久保留（`historyRetentionDays = 0`），长期运行每天写入导致文件增大 | 监控文件大小；暂无自动清理（用户可手动设置保留天数） |
| 跨天逻辑在时区边缘不准确 | 应用跨时区运行时零点判断可能出错 | 使用 `Calendar.current` 的 `isDateInToday` 进行跨天检测 |

### 预估工期

**1 周**

---

## Phase 6：通知系统

### 目标

实现阈值评估逻辑和 macOS 系统通知，当实例用量/余额触及严重阈值时主动提醒用户。点击通知可打开独立的实例详情面板。

### 交付物

#### 6a. NotificationManager
- 每次刷新完成后被 `RefreshService` 调用
- 遍历所有实例的最新数据，与配置的阈值进行比较
- **配额型**：用量百分比 ≥ 严重线（`usage_critical_percent`）→ 触发通知
- **余额型**：剩余余额 ≤ 严重阈值（`balance_critical`）→ 触发通知
- 通知内容包含：实例名称、当前用量/余额、阈值信息
- 通过 `UNUserNotificationCenter` 发送本地通知
- 应用首次启动时请求通知权限

#### 6b. InstanceDetailPanel（NSPanel）
- 点击通知后弹出的独立 `NSPanel`，展示触发通知的实例完整用量详情
- 内容与 `UsageCardView` 一致，但以独立窗口形式呈现
- `NSPanel` 属性：非依附式（`styleMask` 含 `.nonactivatingPanel`），失活时自动关闭（`hidesOnDeactivate = true`）

#### 6c. 通知开关
- 全局通知开关（`settings.notifications_enabled`），Phase 4 的 UI 在此阶段正式接入后端逻辑
- 通知关闭时，菜单栏图标仍正常显示阈值颜色和闪烁

### 不在范围内

- 通知分组/去重（同一实例在短时间内不重复通知 —— 可延后实现）
- 自定义通知操作按钮（如「立即刷新」）

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §3.1 菜单栏图标 | 严重阈值闪烁 |
| PRD | §3.5 偏好设置 | 通知开关、点击通知打开独立面板 |
| PRD | §4 用户交互流程 | 通知 → NSPanel |
| ARCHITECTURE | §2.4 InstanceDetailPanel | 独立详情面板设计 |
| ARCHITECTURE | §2.12 通知管理器 | NotificationManager 设计 |
| ARCHITECTURE | §3.2 刷新周期 | 刷新周期中阈值评估步骤 |
| ARCHITECTURE | §13 ADR | ADR-008/通知点击打开 NSPanel |

### 依赖

- **Phase 1**（RefreshService 调用 NotificationManager、AppState 数据可用）
- **Phase 2**（阈值颜色渲染已就绪，通知提供额外的主动提醒渠道）
- **Phase 3**（UsageCardView 内容可复用到 InstanceDetailPanel）
- **Phase 4**（用户已能配置阈值和通知开关）

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| 通知权限被用户拒绝 | 首次启动请求权限被拒后无法再触发 | 在设置中提供「打开系统偏好设置」入口引导用户手动开启 |
| 通知在免打扰模式下被抑制 | 用户正在开会时通知不会弹出 | 此为系统行为，应用无需特殊处理 |
| NSPanel 在 SwiftUI 中生命周期管理 | SwiftUI 的 `NSWindow` / `NSPanel` 封装可能出现双窗口或不释放 | 使用 `NSWindowController` 手动管理生命周期 |
| 重复通知骚扰 | 每次刷新都触发同一实例通知 | 后续迭代增加去重逻辑（同实例 24h 内不重复通知），V1 暂接受此行为 |

### 预估工期

**1 周**

---

## Phase 7：打磨与收尾

### 目标

对应用进行全面打磨：实现开机自启、优化动画和边缘情况、补充测试、性能验证，达到可日常使用的质量标准。

### 交付物

#### 7a. SMAppService 开机自启
- 在 Phase 4 设置的「Launch at Login」开关后端接入 `SMAppService.mainApp`
- 注册和注销逻辑
- 错误处理（注册失败时告知用户）

#### 7b. 菜单栏闪烁动画优化
- 严重阈值 1Hz 闪烁在 Phase 2 已实现基础版本，本阶段验证其在长时间运行下的稳定性
- 确保 Timer 在槽位退出严重状态后正确释放

#### 7c. 错误恢复边缘情况
- 网络恢复后自动重试（当前逻辑已有，验证完整性）
- 沙盒容器路径变化时的优雅降级
- Keychain 访问失败时的用户提示
- JSON 文件损坏时的回退策略（已在 Phase 1 设计中考虑，验证实现）

#### 7d. 测试
- `BalanceCalculatorTests`：覆盖跨天、充值、首次刷新、清零等边界情况
- `MiniMaxResponseParserTests`：使用真实 API 响应样本验证解析
- `DeepSeekResponseParserTests`：同上
- `RetryPolicyTests`：验证退避时间计算
- `PixelFontEngineTests`：验证字符渲染输出位图与预期一致
- `MenuBarIconRenderer` 快照测试：捕获渲染结果 `NSImage` 与参考图像对比

#### 7e. 性能验证
- 启动到首次展示时间 < 3s
- 后台 CPU 占用 < 1%（空闲状态）
- 内存常驻 < 50MB
- 使用 Xcode Instruments 验证

#### 7f. 部署验证
- ad-hoc 签名下可正常编译运行
- `xattr -cr` 去隔离标记后可直接双击运行
- SMAppService 开机自启在 ad-hoc 签名下工作正常
- 验证完整的本地部署流程（PRD §8.3）

### 需求来源

| 文档 | 章节 | 内容 |
|------|------|------|
| PRD | §5 非功能性需求 | 性能/可靠性/兼容性要求 |
| PRD | §7 成功指标 | 启动时间<3s / CPU<1% / 内存<50MB |
| PRD | §8 自用部署要求 | ad-hoc签名 / Gatekeeper / SMAppService / 本地部署流程 |
| ARCHITECTURE | §10.4 启动弹性 | 启动弹性设计 |
| ARCHITECTURE | §11.4 Timer 管理 | Timer 生命周期管理 |
| ARCHITECTURE | §14 质量属性分析 | 性能/可靠性/可维护性/可观测性/安全性/可测试性 |
| ARCHITECTURE | §13 ADR | ADR-001 至 ADR-010 全部采纳的决策 |
| ARCHITECTURE | 附录 A Entitlements 配置 | Entitlements 配置 |
| ARCHITECTURE | 附录 B 最低部署目标 | 最低部署目标 |

### 依赖

- **所有 Phase 0–6** 功能已实现

### 风险

| 风险 | 说明 | 缓解 |
|------|------|------|
| SMAppService 在 ad-hoc 签名下受限 | 某些 macOS 版本可能限制非签名应用开机自启 | 提前测试；若受限则降级为 Login Item 方案（LSSharedFileList） |
| 性能不达标 | 像素渲染或 SwiftUI 开销导致 CPU/内存过高 | Instruments 定位热点，必要时优化渲染缓存或降低刷新频率 |
| macOS 13 特定 bug | SwiftUI/Popover/StatusItem 在 Ventura 上可能有已知问题 | 开发期间使用 macOS 13 实机测试，避开已知问题的 API |

### 预估工期

**1–1.5 周**

---

## 阶段依赖关系总览

```
Phase 0（菜单栏骨架）
   │
   ▼
Phase 1（核心数据管道）
   │
   ├──────────────────────────┐
   ▼                          ▼
Phase 2（菜单栏渲染）    Phase 4（设置窗口）
   │                          │
   ▼                          │
Phase 3（用量面板）◄─────────┘
   │
   ├──────────────────────────┐
   ▼                          ▼
Phase 5（余额跟踪）     Phase 6（通知系统）
   │                          │
   └──────────┬───────────────┘
              ▼
         Phase 7（打磨收尾）
```

**关键依赖说明**：

- Phase 1 是一切功能的基础，必须最先完成（Phase 0 验证管道后）
- Phase 2 和 Phase 4 可以**并行开发**（各依赖 Phase 1，彼此不依赖）
- Phase 3 依赖 Phase 2（需要菜单栏图标已正常渲染），也依赖 Phase 4 的「设置」入口
- Phase 5 和 Phase 6 可以**并行开发**（各依赖 Phase 1 + Phase 3 + Phase 4）
- Phase 7 必须等待所有 Phase 0–6 完成后才能启动

---

## 工期汇总

| 阶段 | 内容 | 预估工期 | 累计 |
|------|------|----------|------|
| Phase 0 | 菜单栏骨架原型 | 1–2 天 | 2 天 |
| Phase 1 | 核心数据管道 | 1.5–2 周 | 2.5 周 |
| Phase 2 | 菜单栏图标渲染 | 1.5–2 周 | 4.5 周 |
| Phase 3 | 用量面板 | 1–1.5 周 | 6 周 |
| Phase 4 | 设置窗口 | 1.5–2 周 | 8 周 |
| Phase 5 | 余额跟踪 | 1 周 | 9 周 |
| Phase 6 | 通知系统 | 1 周 | 10 周 |
| Phase 7 | 打磨收尾 | 1–1.5 周 | 11.5 周 |

**总预估工期**：约 **10–12 周**（2.5–3 个月），按单人业余时间开发估算。

> **注意**：以上工期基于单人业余时间开发（约每周 10–15 小时有效编码时间）估算。如果是全职开发，工期可压缩至 4–6 周。

---

## 里程碑检查清单

在进入下一阶段之前，每个阶段必须满足：

### Phase 0 出口条件
- [ ] App 可正常编译、启动、退出
- [ ] 菜单栏显示 `?` 图标（系统字体即可）
- [ ] 左键点击可打开/关闭空 Popover
- [ ] 右键菜单可退出应用
- [ ] App Sandbox 已启用且不报错
- [ ] Gatekeeper 绕过（右键打开）流程已验证

### Phase 1 出口条件
- [ ] 所有数据模型编译通过
- [ ] `instances.json` 可正常读写（原子写入验证）
- [ ] Keychain CRUD 操作在沙盒中正常工作
- [ ] MiniMax 和 DeepSeek API 调用可在 Debug 日志中验证数据正确
- [ ] 重试逻辑（指数退避）被触发时行为正确
- [ ] 余额型实例刷新后 `BalanceSnapshot` 保存到 `{uuid}.json`

### Phase 2 出口条件
- [ ] 像素字模引擎覆盖全部所需字符（A–Z、0–9、符号）
- [ ] 槽位在 22pt 高度内像素清晰可辨（Retina 屏幕截图验证）
- [ ] 配额型和余额型槽位布局正确
- [ ] 单色/彩色模式均渲染正确
- [ ] 所有特殊状态（`?`、`•••`、`NO API`、`N/A`）渲染正确
- [ ] 严重阈值闪烁动画工作正常
- [ ] 无内存泄漏（Timer 正确释放）

### Phase 3 出口条件
- [ ] Popover 内滚动列表显示所有实例卡片
- [ ] 配额型卡片：进度条、用量/上限、下次刷新时间正确
- [ ] 余额型卡片：余额、当日用量（约）正确
- [ ] 错误摘要栏在故障实例存在时正确显示
- [ ] 刷新按钮可触发手动刷新并更新卡片
- [ ] 设置按钮可打开设置入口（或占位窗口）

### Phase 4 出口条件
- [ ] 所有表单字段可正常输入和保存
- [ ] 添加实例后菜单栏和 Popover 即时反映变化
- [ ] 实例删除同步清理 Keychain 和余额历史文件
- [ ] 拖拽排序后 `sort_order` 正确更新
- [ ] 保存后 `instances.json` 内容与 UI 一致
- [ ] 刷新间隔变更后 Timer 重启生效

### Phase 5 出口条件
- [ ] 跨天时 `today_usage` 正确归档到 `history`
- [ ] 充值事件被正确检测（`current > latest`）
- [ ] 日均消耗（4 种周期）计算结果正确
- [ ] 历史保留天数限制正确裁剪 `history`
- [ ] `{uuid}.json` 文件内容与预期 schema 一致

### Phase 6 出口条件
- [ ] 配额型实例达到严重线时触发系统通知
- [ ] 余额型实例低于严重阈值时触发系统通知
- [ ] 通知内容包含实例名称、当前值、阈值信息
- [ ] 点击通知打开 `InstanceDetailPanel`，显示该实例详情
- [ ] `InstanceDetailPanel` 失活时自动关闭
- [ ] 通知开关可正常关闭通知

### Phase 7 出口条件
- [ ] 所有单元测试通过
- [ ] 启动时间 < 3s
- [ ] 后台 CPU < 1%
- [ ] 内存 < 50MB
- [ ] SMAppService 开机自启正常
- [ ] ad-hoc 签名部署流程验证通过
- [ ] 在 macOS 13 实机上运行 24 小时无崩溃
