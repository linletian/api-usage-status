# 工程任务分解：API Usage Status

> 本文件将开发计划分解为可直接分配给工程师执行的独立任务。
> 每个任务边界清晰、有明确的输入/输出/验证标准，可独立追踪完成进度。

---

## 阶段依赖关系总览

```
Phase 0（菜单栏骨架原型）
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

**关键并行关系**：
- **Phase 2 ⟺ Phase 4**：Phase 1 完成后，菜单栏渲染（Phase 2）与设置窗口（Phase 4）可**并行开发**，彼此无依赖
- **Phase 5 ⟺ Phase 6**：Phase 3、Phase 4 完成后，余额跟踪（Phase 5）与通知系统（Phase 6）可**并行开发**

---

## Phase 0：可行性原型（菜单栏骨架）

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-0.1 | 创建 Xcode 项目并配置 App Sandbox 权限 | 项目基础设施 | 4h | 无 |
| T-0.2 | 实现应用入口与 AppDelegate | 应用入口 | 3h | T-0.1 |
| T-0.3 | 实现 MenuBarController（NSStatusItem + NSPopover + 右键菜单） | 菜单栏 | 5h | T-0.1, T-0.2 |

---

### T-0.1 创建 Xcode 项目并配置 App Sandbox 权限

**所属阶段**：Phase 0  
**预估工时**：4h  
**前置任务**：无

**输入**：
- 无（项目从零创建）

**工作内容**：
1. 在 Xcode 中创建新 macOS App 项目，Target 名称 `APIUsageStatus`，Interface 选择 `SwiftUI`，Language 选择 `Swift`
2. 配置 Deployment Target 为 `macOS 13.0`
3. 配置 `Info.plist`：添加 `Application is agent (UIElement)` = `YES`（`LSUIElement = true`），使应用不显示 Dock 图标，为纯菜单栏应用
4. 在 Target → Signing & Capabilities 中启用 App Sandbox，添加以下 entitlements：
   - `com.apple.security.app-sandbox` = `true`
   - `com.apple.security.network.client` = `true`
   - `com.apple.security.files.user-selected.read-only` = `true`（可选，未来导入/导出配置用）
5. 创建 `.entitlements` 文件，写入以上三项权限
6. 配置 Build Settings 中 Swift Language Version 为 Swift 5.9
7. 验证项目可编译通过（`Cmd+B`），确保无编译错误
8. 创建 ARCHITECTURE.md §12 中定义的基础目录结构（`AppState/`、`MenuBar/`、`Views/`、`Services/`、`Network/`、`Suppliers/`、`Balance/`、`PixelFont/`、`Models/`、`Extensions/`、`Utilities/`）

**输出文件**：
- `APIUsageStatus.xcodeproj` — Xcode 项目文件
- `APIUsageStatus/Resources/Info.plist` — 应用配置（含 LSUIElement）
- `APIUsageStatus/APIUsageStatus.entitlements` — 沙盒权限声明
- 全部空目录结构（占位，含 `.gitkeep` 或空文件夹）

**验证标准**：
- [ ] 项目编译通过，无任何编译错误或警告（允许 SwiftUI 默认模板的警告）
- [ ] `Info.plist` 中 `LSUIElement` = `true`
- [ ] `.entitlements` 文件中三项目权限均已配置
- [ ] 目录结构符合 ARCHITECTURE §12 定义

**需求追溯**：
- PRD: §5（非功能性需求 — 沙盒）、§8.2（Entitlements 配置）
- ARCHITECTURE: §12（文件与目录结构）、附录 A（Entitlements 配置）

---

### T-0.2 实现应用入口与 AppDelegate

**所属阶段**：Phase 0  
**预估工时**：3h  
**前置任务**：T-0.1

**输入**：
- T-0.1 产出的 Xcode 项目（含目录结构、entitlements）

**工作内容**：
1. 创建 `APIUsageStatusApp.swift`，定义 `@main` 结构体，内嵌 `AppDelegate` 类
2. `AppDelegate` 实现 `NSApplicationDelegate` 协议
3. 在 `applicationDidFinishLaunching(_:)` 中：
   - 初始化 `MenuBarController`（实例化并持有强引用）
   - 设置 `NSApp.setActivationPolicy(.accessory)`（确保纯菜单栏应用行为）
4. 移除 Xcode 模板默认的 `ContentView.swift` 和 `WindowGroup`（本应用无主窗口）
5. 在 `AppDelegate` 中添加 `applicationWillTerminate(_:)`，用于未来清理逻辑的占位
6. 验证应用可正常编译、启动后无 Dock 图标、进程在活动监视器中可见

**输出文件**：
- `APIUsageStatus/APIUsageStatusApp.swift` — `@main` 入口 + `NSApplicationDelegate`

**验证标准**：
- [ ] 应用编译通过
- [ ] 启动后 Dock 中无应用图标
- [ ] 活动监视器中可看到 `APIUsageStatus` 进程
- [ ] 退出进程（`Cmd+Q` 或活动监视器强制退出）无崩溃
- [ ] 菜单栏尚无可见图标（T-0.3 实现后才显示）

**需求追溯**：
- PRD: §3.1（菜单栏图标常驻）、§4（用户交互流程）
- ARCHITECTURE: §2.1（应用入口）、§3.1（启动流程）

---

### T-0.3 实现 MenuBarController（NSStatusItem + NSPopover + 右键菜单）

**所属阶段**：Phase 0  
**预估工时**：5h  
**前置任务**：T-0.1, T-0.2

**输入**：
- T-0.2 产出的 `APIUsageStatusApp.swift`（AppDelegate 已就绪，等待创建 `MenuBarController`）

**工作内容**：
1. 创建 `MenuBarController.swift`
2. 在 `init()` 中创建 `NSStatusItem`：
   - `NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)`
   - 设置 `button?.title` = `"?"`（使用系统字体，无需像素字模）
   - 设置 `button?.imagePosition` = `.imageOnly` 或仅使用 `.title`
3. 创建 `NSPopover`：
   - `behavior = .transient`（点击外部自动关闭）
   - 设置空内容视图（一个 `NSHostingView`，内部为静态占位文本如「用量面板（待开发）」）
4. 实现左键单击 `NSStatusBarButton`：
   - 点击时 `popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)`
   - 若 Popover 已显示则关闭
5. 实现右键菜单（`NSMenu`）：
   - 设置 `NSStatusItem.menu`（或通过 `button?.sendAction(on: .rightMouseDown)`）
   - 菜单项：「退出」（`terminate:` 选择器）
6. 验证所有交互：
   - 左键点击 `?` 图标 → Popover 弹出/关闭
   - 点击 Popover 外部 → Popover 自动关闭
   - 右键菜单 → 「退出」→ 应用正常退出

**输出文件**：
- `APIUsageStatus/MenuBar/MenuBarController.swift` — NSStatusItem + NSPopover + 右键菜单

**验证标准**：
- [ ] 应用启动后菜单栏显示 `?` 文本（系统字体）
- [ ] 左键点击 `?` → Popover 弹出，显示占位内容
- [ ] 左键再次点击 `?` 或点击 Popover 外部 → Popover 关闭
- [ ] 右键/长按 `?` → 弹出菜单，含「退出」选项
- [ ] 点击「退出」→ 应用正常终止
- [ ] 无内存泄漏（`NSStatusItem` 在 `deinit` 时被移除）

**需求追溯**：
- PRD: §3.1（菜单栏图标 — 无配置状态显示 `?`）、§4（用户交互流程 — 左键/右键交互图）
- ARCHITECTURE: §2.2（菜单栏控制器）、§3.1（启动流程）

---

## Phase 1：核心数据管道

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-1.1 | 定义所有 Swift 数据模型 | 数据模型 | 4h | 无 |
| T-1.2 | 实现 KeychainService | 安全/持久化 | 4h | T-1.1 |
| T-1.3 | 实现 PersistenceService | 持久化 | 6h | T-1.1, T-1.2 |
| T-1.4 | 实现 NetworkClient + Endpoint + RetryPolicy | 网络层 | 6h | T-1.1 |
| T-1.5 | 定义 Supplier 协议 + SupplierResponse + SupplierRegistry | 供应商层 | 2h | T-1.1 |
| T-1.6 | 实现 MiniMaxSupplier + MiniMaxResponseParser | 供应商 | 6h | T-1.4, T-1.5 |
| T-1.7 | 实现 DeepSeekSupplier + DeepSeekResponseParser | 供应商 | 4h | T-1.4, T-1.5 |
| T-1.8 | 实现 AppState Actor | 状态管理 | 4h | T-1.1 |
| T-1.9 | 实现 RefreshService Actor | 服务层 | 8h | T-1.3, T-1.4, T-1.5, T-1.6, T-1.7, T-1.8 |
| T-1.10 | 实现 AppStateProxy（@MainActor ObservableObject 桥接） | 状态管理 | 3h | T-1.8 |
| T-1.11 | 实现 Logger + 工具扩展 | 基础设施 | 3h | 无 |

---

### T-1.1 定义所有 Swift 数据模型

**所属阶段**：Phase 1  
**预估工时**：4h  
**前置任务**：无

**输入**：
- ARCHITECTURE §4.1 中定义的内存模型设计
- PRD §3.8 中定义的 `instances.json` schema
- PRD §3.7 中定义的余额快照 JSON schema

**工作内容**：
1. 创建 `Models/Instance.swift`：定义 `Instance` struct，包含所有字段（`uuid`, `provider`, `dimension`, `displayName`, `shortName`, `apiKeyRef`, `enabled`, `sortOrder`, `currency`, `thresholds`），遵循 `Codable`、`Identifiable`
2. 创建 `Models/Thresholds.swift`：定义 `Thresholds` enum（`quota` / `balance` 关联值），包含所有阈值字段（`usage_warning_percent`, `usage_critical_percent`, `balance_warning`, `balance_critical`, `avg_daily_periods`, `history_retention_days`），遵循 `Codable`
3. 创建 `Models/GlobalSettings.swift`：定义 `GlobalSettings` struct、`ColorMode` enum
4. 创建 `Models/SlotViewData.swift`：定义 `SlotViewData` struct、`InstanceType` enum（`quota` / `balance` 关联值）、`ColorState` enum（含 `.normal`, `.warning`, `.critical`, `.disabled`, `.unavailable`, `.loading`, `.error`）
5. 创建 `Models/ErrorSummary.swift`：定义 `ErrorSummary` struct、`ErrorType` enum、`RefreshError` enum（遵循 PRD/ARCH 的错误分类）
6. 创建 `Models/RefreshState.swift`：定义 `RefreshState` enum（`.idle`, `.refreshing`）
7. 创建 `Balance/BalanceSnapshot.swift`：定义 `BalanceSnapshot` struct、`DailyUsageEntry` struct、`AvgDailyPeriod` enum，遵循 `Codable`
8. 创建 `Models/SupplierResponse.swift`：定义 `SupplierResponse` struct
9. 为每个 `Codable` 模型编写 `CodingKeys`（使用 `snake_case` 映射，与 JSON 字段保持一致）
10. 为 `Thresholds` enum 编写自定义 `Codable` 实现（处理带关联值的 enum 编解码），确保与 `instances.json` schema 的 `thresholds` 对象结构一致

**输出文件**：
- `APIUsageStatus/Models/Instance.swift`
- `APIUsageStatus/Models/Thresholds.swift`
- `APIUsageStatus/Models/GlobalSettings.swift`
- `APIUsageStatus/Models/SlotViewData.swift`
- `APIUsageStatus/Models/ErrorSummary.swift`
- `APIUsageStatus/Models/RefreshState.swift`
- `APIUsageStatus/Models/SupplierResponse.swift`
- `APIUsageStatus/Balance/BalanceSnapshot.swift`

**验证标准**：
- [ ] 所有模型文件编译通过，无编译错误
- [ ] `Thresholds` enum 的 `Codable` 实现能正确编解码 PRD §3.8 中的示例 JSON 对象
- [ ] `Instance` struct 能正确编解码 `instances.json` 示例数据
- [ ] `BalanceSnapshot` struct 能正确编解码 PRD §3.7 中的余额历史 JSON 示例
- [ ] `ColorState` enum 覆盖所有 ARCHITECTURE §4.1 中定义的状态

**需求追溯**：
- PRD: §3.7（余额快照 schema）、§3.8（instances.json schema）
- ARCHITECTURE: §4.1（内存模型定义）、§4.2（存储布局）

---

### T-1.2 实现 KeychainService

**所属阶段**：Phase 1  
**预估工时**：4h  
**前置任务**：T-1.1

**输入**：
- T-1.1 产出的数据模型（`api_key_ref` 概念已在 `Instance` 模型中定义）
- ARCHITECTURE §5（Keychain 集成设计）

**工作内容**：
1. 创建 `Services/KeychainService.swift`，定义为 `actor`
2. 实现 `store(key:for:)` 方法：
   - 构造查询字典：`kSecClass` = `kSecClassInternetPassword`，`kSecAttrServer` = `"APIUsageStatus"`，`kSecAttrAccount` = `apiKeyRef`，`kSecValueData` = key 的 UTF-8 编码
   - 先调用 `SecItemCopyMatching` 检查条目是否已存在；若存在则用 `SecItemUpdate` 更新，否则用 `SecItemAdd` 新增
3. 实现 `retrieve(for:) -> String?` 方法：
   - 构造查询字典，设置 `kSecReturnData` = `true`、`kSecMatchLimit` = `kSecMatchLimitOne`
   - 调用 `SecItemCopyMatching`，提取返回的 `Data` 并解码为 `String`
4. 实现 `delete(for:)` 方法：
   - 构造查询字典，调用 `SecItemDelete`
5. 实现 `deleteAll()` 方法（用于卸载清理）：
   - 查询字典仅含 `kSecClass` + `kSecAttrServer`，调用 `SecItemDelete`
6. 错误处理：所有 `OSStatus` 返回值映射为 Swift `throw`，定义 `KeychainError` enum
7. 日志记录：使用 `os.Logger`（subsystem: `com.example.APIUsageStatus`，category: `keychain`），敏感值使用 `privacy: .private`

**输出文件**：
- `APIUsageStatus/Services/KeychainService.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 在 App Sandbox 启用的情况下，能在 Debug 构建中成功写入/读取/删除 Keychain 条目
- [ ] 重复写入同一 `api_key_ref` → 正确更新（而非重复添加）
- [ ] 删除不存在的条目 → 不抛出错误（幂等）
- [ ] 日志中不泄露 API Key 明文值（验证 Console.app 输出）

**需求追溯**：
- PRD: §3.6（数据安全 — Keychain 存储方案）
- ARCHITECTURE: §2.10（Keychain 服务）、§5（Keychain 集成设计）、ADR-004

---

### T-1.3 实现 PersistenceService

**所属阶段**：Phase 1  
**预估工时**：6h  
**前置任务**：T-1.1, T-1.2

**输入**：
- T-1.1 产出的所有数据模型（`Instance`, `GlobalSettings`, `BalanceSnapshot`）
- T-1.2 产出的 `KeychainService`
- ARCHITECTURE §2.9、§4.3

**工作内容**：
1. 创建 `Services/PersistenceService.swift`，定义为 `actor`
2. 实现 `loadInstances() -> ([Instance], GlobalSettings)`：
   - 从 Sandbox 容器路径读取 `instances.json`
   - 使用 `JSONDecoder` 解码为 `(instances: [Instance], settings: GlobalSettings)`
   - 启动弹性：文件不存在 → 返回空数组 + `GlobalSettings.default`；JSON 解析失败 → 记录 `.fault` 日志，返回空配置降级
3. 实现 `saveInstances(_:settings:)`：
   - 编码为 JSON → 调用原子写入（先写 `.tmp` 再 `replaceItemAt`）
4. 实现 `loadBalanceSnapshot(for:) -> BalanceSnapshot?`：
   - 读取 `{uuid}.json`，解析失败时记录日志返回 `nil`（触发基线重置）
5. 实现 `saveBalanceSnapshot(_:for:)`：
   - 编码为 JSON → 原子写入到 `{uuid}.json`
6. 实现 `getApiKey(for:) -> String?`：委托给 `KeychainService.retrieve(for:)`
7. 实现 `saveApiKey(_:for:)`：委托给 `KeychainService.store(key:for:)`
8. 实现 `deleteInstance(_:allInstances:)` 清理方法：
   - 删除 `{uuid}.json`
   - 若无其他实例共享同一 `api_key_ref` → 调用 `KeychainService.delete(for:)`
9. 实现 `applicationSupportDirectory` 计算属性（返回 Sandbox 容器内路径）
10. 确保所有 JSON 写入使用 ARCHITECTURE §4.3 中定义的 `atomicWrite` 模式（临时文件 + 重命名）

**输出文件**：
- `APIUsageStatus/Services/PersistenceService.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 空目录启动 → `loadInstances()` 返回空数组 + 默认设置，不崩溃
- [ ] 写入 `instances.json` → 再次读取 → 数据一致
- [ ] 模拟中途崩溃：只写入一半的 `.tmp` 文件存在但未替换 → 原始 JSON 文件完好无损
- [ ] 写入损坏的 JSON 文本 → `loadInstances()` 返回空配置降级，日志中有 `.fault` 级别记录
- [ ] 实例删除后 `{uuid}.json` 被删除，Keychain 条目在无共享引用时被删除
- [ ] 余额快照读写正常

**需求追溯**：
- PRD: §3.7（数据持久化）、§3.8（配置数据持久化 — 实例删除清理规则）
- ARCHITECTURE: §2.9（持久化服务）、§3.4（设置写入流程）、§4.2（存储布局）、§4.3（原子文件写入）、§10.4（启动弹性）、ADR-009

---

### T-1.4 实现 NetworkClient + Endpoint + RetryPolicy

**所属阶段**：Phase 1  
**预估工时**：6h  
**前置任务**：T-1.1

**输入**：
- T-1.1 产出的 `RefreshError` / `ErrorType` 模型
- ARCHITECTURE §6（网络层设计）

**工作内容**：
1. 创建 `Network/Endpoint.swift`：定义 `Endpoint` struct，包含 `url`、`method`、`headers`、`timeout` 属性
2. 创建 `Network/NetworkClient.swift`，定义为 `actor`：
   - 持有 `URLSession`（默认配置，`waitsForConnectivity = false`，`timeoutIntervalForRequest = 30`）
   - 实现 `request(_:apiKey:) async throws -> Data`：
     - 构建 `URLRequest`，设置 Authorization header 和超时
     - 调用 `URLSession.shared.data(for:)`（async/await API）
     - 检查 HTTP 状态码：非 2xx 抛出 `RefreshError.httpError(statusCode:)`
     - 捕获 `URLError` 并映射到对应 `RefreshError`（`.networkTimeout` / `.networkUnreachable`）
3. 创建 `Network/RetryPolicy.swift`：实现指数退避 + 抖动重试：
   - 实现 `func withRetry<T>(maxAttempts:operation:) async throws -> T` 泛型函数
   - 初次失败立即重试（100ms 延迟），第 2 次等待 1s + random(0,1)s，第 3 次等待 2s + random(0,2)s
   - 使用 `Task.sleep` 挂起等待，非阻塞
   - 单例模式（`static let shared`）确保 URLSession 复用
4. 验证：编写一个简单的测试端点调用（如 `https://httpbin.org/get`），验证请求/响应/重试流程

**输出文件**：
- `APIUsageStatus/Network/NetworkClient.swift`
- `APIUsageStatus/Network/Endpoint.swift`
- `APIUsageStatus/Network/RetryPolicy.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 对可达 URL 发起 GET 请求 → 返回 Data，无错误
- [ ] 对不可达 URL（如 `http://localhost:1` 或超时配置极短的假 URL）发起请求 → 抛出 `RefreshError.networkUnreachable` 或 `.networkTimeout`
- [ ] 模拟 HTTP 500 响应 → 抛出 `RefreshError.httpError(statusCode: 500)`
- [ ] 重试逻辑：模拟 3 次全部失败 → 最终抛出错误，总耗时约 5s
- [ ] Authorization header 正确附加到请求中

**需求追溯**：
- PRD: §3.4（数据刷新 — 指数退避最多 3 次）
- ARCHITECTURE: §2.7（刷新服务中的重试）、§6（网络层设计）、§6.3（重试策略）、§10.1（错误分类）

---

### T-1.5 定义 Supplier 协议 + SupplierResponse + SupplierRegistry

**所属阶段**：Phase 1  
**预估工时**：2h  
**前置任务**：T-1.1

**输入**：
- T-1.1 产出的 `SupplierResponse` 模型
- ARCHITECTURE §2.8、§2.14

**工作内容**：
1. 创建 `Suppliers/Supplier.swift`：定义 `Supplier` 协议：
   - `var provider: Provider { get }`
   - `func fetchUsage(apiKey: String) async throws -> SupplierResponse`
   - 定义 `Provider` enum：`minimax`、`deepseek` 等
2. 确保 `Suppliers/Supplier.swift` 中的 `SupplierResponse` 与 T-1.1 的 `Models/SupplierResponse.swift` 一致（可使用同一类型，或在此处 import）
3. 创建 `Suppliers/SupplierRegistry.swift`：
   - 工厂方法：`static func getSupplier(for provider: Provider) -> Supplier`
   - 根据 `provider` 字符串返回对应的 `Supplier` 实现（`MiniMaxSupplier` 或 `DeepSeekSupplier`）
   - 对未知 provider 抛出错误（或在注册表中返回 nil 供上层处理）

**输出文件**：
- `APIUsageStatus/Suppliers/Supplier.swift`
- `APIUsageStatus/Suppliers/SupplierRegistry.swift`

**验证标准**：
- [ ] 编译通过
- [ ] `SupplierRegistry` 能根据 `Provider.minimax` 返回 `MiniMaxSupplier` 实例
- [ ] `SupplierRegistry` 能根据 `Provider.deepseek` 返回 `DeepSeekSupplier` 实例
- [ ] 协议方法签名与 ARCHITECTURE §2.8 一致

**需求追溯**：
- PRD: §3.3（支持的供应商）
- ARCHITECTURE: §2.8（供应商协议）、§2.14（供应商注册表）、§6.4（供应商实现）

---

### T-1.6 实现 MiniMaxSupplier + MiniMaxResponseParser

**所属阶段**：Phase 1  
**预估工时**：6h  
**前置任务**：T-1.4, T-1.5

**输入**：
- T-1.4 产出的 `NetworkClient`、`Endpoint`、`RetryPolicy`
- T-1.5 产出的 `Supplier` 协议、`SupplierRegistry`
- PRD 附录 B（MiniMax API 基本信息）

**工作内容**：
1. **前置步骤 — 获取真实 API 响应**：
   - 使用真实 MiniMax Token Plan API Key，调用 `GET https://www.minimaxi.com/v1/token_plan/remains`
   - 记录完整的 JSON 响应体（包含所有字段名、嵌套结构、数据类型）
   - 对照 PRD 附录 B 中描述的计费机制（文本模型 5h、非文本每日、周累计等），确认各维度对应字段
2. 创建 `Suppliers/MiniMaxSupplier.swift`：
   - 实现 `Supplier` 协议
   - `fetchUsage(apiKey:)` 构建 Endpoint → 调用 `NetworkClient.request` → 通过 `withRetry` 包装
3. 创建 `Suppliers/MiniMaxResponseParser.swift`：
   - 接收原始 JSON → 解析 → 返回 `SupplierResponse`（`rawData` 字典按内部维度标识符 `text_model_5h` / `non_text_daily` / `weekly_total` 组织）
   - 若 API 响应格式与预期不同，Parser 内部适配即可，不影响调用方
   - 解析失败时抛出 `RefreshError.parsingError`
4. 日志：响应解析细节使用 `.debug` 级别

**输出文件**：
- `APIUsageStatus/Suppliers/MiniMaxSupplier.swift`
- `APIUsageStatus/Suppliers/MiniMaxResponseParser.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 使用有效 API Key 调用 → 返回非空 `SupplierResponse`，`rawData` 包含至少 `text_model_5h` 字段
- [ ] 使用无效 API Key 调用 → 抛出认证错误
- [ ] 模拟畸形 JSON 响应 → 抛出 `RefreshError.parsingError`
- [ ] 重试逻辑在 MiniMax 调用中正常工作（模拟临时网络故障）
- [ ] Debug 日志可验证解析出的各维度数据

**需求追溯**：
- PRD: §3.3（MiniMax 统计维度）、附录 B（MiniMax API）
- ARCHITECTURE: §2.8（MiniMaxSupplier 设计）、§6.4（MiniMax 响应解析映射）、§11.3（HTTP 请求执行策略）
- DEVELOPMENT_PLAN: Phase 1 风险（MiniMax API 响应格式未公开）

---

### T-1.7 实现 DeepSeekSupplier + DeepSeekResponseParser

**所属阶段**：Phase 1  
**预估工时**：4h  
**前置任务**：T-1.4, T-1.5

**输入**：
- T-1.4 产出的 `NetworkClient`、`Endpoint`、`RetryPolicy`
- T-1.5 产出的 `Supplier` 协议、`SupplierRegistry`
- PRD 附录 A（DeepSeek API 响应 schema）

**工作内容**：
1. 创建 `Suppliers/DeepSeekSupplier.swift`：
   - 实现 `Supplier` 协议
   - `fetchUsage(apiKey:)` 构建 Endpoint（URL: `https://api.deepseek.com/user/balance`）→ 调用 `NetworkClient.request` → 通过 `withRetry` 包装
2. 创建 `Suppliers/DeepSeekResponseParser.swift`：
   - 解析 JSON 响应，提取以下字段：
     - `is_available`（Boolean）
     - `balance_infos` 数组 → 优先取第一条 `currency == "CNY"` 的记录，若无 CNY 则取第一条
     - 从选中记录中提取 `total_balance`、`granted_balance`、`topped_up_balance`、`currency`
   - 返回 `SupplierResponse`，`rawData` 包含以上字段
   - 若 `is_available = false`，`rawData` 中标记 `is_available: false`
3. 日志：余额值以 `.info` 级别记录（非敏感数据）

**输出文件**：
- `APIUsageStatus/Suppliers/DeepSeekSupplier.swift`
- `APIUsageStatus/Suppliers/DeepSeekResponseParser.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 使用有效 API Key 调用 → 返回 `SupplierResponse`，`rawData` 包含 `topped_up_balance`、`is_available`、`currency` 等字段
- [ ] 优先取 `CNY` 记录逻辑正确（若 `balance_infos` 同时含 CNY 和 USD）
- [ ] 使用无效 API Key 调用 → 抛出认证错误（401/403）
- [ ] 解析失败时抛出 `RefreshError.parsingError`

**需求追溯**：
- PRD: 附录 A（DeepSeek API 响应 schema — `is_available`, `topped_up_balance`, `currency` 等）
- ARCHITECTURE: §2.8（DeepSeekSupplier 设计）、§6.4（DeepSeek 响应解析逻辑）

---

### T-1.8 实现 AppState Actor

**所属阶段**：Phase 1  
**预估工时**：4h  
**前置任务**：T-1.1

**输入**：
- T-1.1 产出的所有数据模型（`Instance`, `SlotViewData`, `RefreshState`, `ErrorSummary`, `GlobalSettings`）
- ARCHITECTURE §2.6、§9.2

**工作内容**：
1. 创建 `AppState/AppState.swift`，定义为 `actor`
2. 声明所有私有存储属性：`instances: [Instance]`、`slotViewDataList: [SlotViewData]`、`refreshState: RefreshState`、`errorSummaries: [ErrorSummary]`、`globalSettings: GlobalSettings`
3. 实现变更方法（全部标记为 `async` 或为同步 Actor 方法）：
   - `setInstances(_:)`
   - `updateSlotData(_:)`
   - `setRefreshState(_:)`
   - `setErrorSummaries(_:)`
   - `updateSettings(_:)`
   - `updateInstance(_:)`：更新单个实例（用于货币自动修正等场景）
4. 提供只读访问器：`getInstances()`、`getSlotViewDataList()` 等（供 `AppStateProxy.syncFromState()` 调用）
5. Actor 方法保持简短，不在多步状态变更中间使用 `await`（遵循 ADR-002 建议）

**输出文件**：
- `APIUsageStatus/AppState/AppState.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 初始化后所有属性为合理默认值（空数组, `.idle`, `.default`）
- [ ] 连续多次调用 `setInstances` → 数据正确覆盖
- [ ] 从不同 Task 并发调用 Actor 方法 → 无数据竞争（由 Swift 编译器保证）

**需求追溯**：
- ARCHITECTURE: §2.6（AppState 设计）、§9.2（AppState Actor 定义）、ADR-002（Actor 并发模型）

---

### T-1.9 实现 RefreshService Actor

**所属阶段**：Phase 1  
**预估工时**：8h  
**前置任务**：T-1.3, T-1.4, T-1.5, T-1.6, T-1.7, T-1.8

**输入**：
- T-1.3 产出的 `PersistenceService`（可读写实例配置和余额快照）
- T-1.4 产出的网络层（`NetworkClient`, `RetryPolicy`）
- T-1.5 产出的 `SupplierRegistry`
- T-1.6 产出的 `MiniMaxSupplier` + Parser
- T-1.7 产出的 `DeepSeekSupplier` + Parser
- T-1.8 产出的 `AppState` Actor

**工作内容**：
1. 创建 `Services/RefreshService.swift`，定义为 `actor`
2. 实现定时刷新循环（基于 `Task.sleep`，遵循 ADR 设计）：
   - `start(interval:)` → 创建 `Task`，先立即执行一次 `performRefresh()`，然后 `while !Task.isCancelled` 循环中 `Task.sleep` + `performRefresh()`
   - `stop()` → 取消 Task
   - `restartTimer(interval:)` → 先 stop 再 start
   - 记录 `lastRefreshAt: Date`，用于计算 `nextRefreshMinutes`
3. 实现 `performRefresh()` 核心编排：
   a. 从 AppState 读取 instances，过滤 `enabled == true`
   b. 按 `api_key_ref` 分组实例（ADR-006 去重）
   c. 设置 `refreshState = .refreshing`
   d. 串行遍历每个 `api_key_ref` 组（ADR 设计：各组串行执行）：
      - 从 Keychain 获取 API Key
      - 通过 `SupplierRegistry` 获取 Supplier
      - 调用 `withRetry { supplier.fetchUsage(apiKey:) }`
      - 成功：解析 `SupplierResponse` → 映射到各实例的 `SlotViewData`
      - 失败：为该组所有实例生成 `ErrorSummary`
   e. 对配额型实例计算时间派生字段：`nextRefreshMinutes`、`cycleRemainingDays`
   f. 对余额型实例：触发货币自动修正（若 API 返回的 currency 与实例当前值不同 → 更新 AppState + 写回 instances.json）
   g. 调用 `AppState.updateSlotData`、`AppState.setErrorSummaries`、`AppState.setRefreshState(.idle)`
   h. 调用 `AppStateProxy.syncFromState()` 触发 UI 更新
4. 实现 `triggerManualRefresh()`（供 UI 手动刷新按钮调用）：直接调用 `performRefresh()`
5. 日志：刷新开始/完成使用 `.info` 级别，错误使用 `.error` 级别

**输出文件**：
- `APIUsageStatus/Services/RefreshService.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 启动刷新：应用启动后 3s 内完成首次 `performRefresh()`（日志验证）
- [ ] 定时刷新：等待完整间隔后自动触发下一轮
- [ ] 手动触发：调用 `triggerManualRefresh()` → 立即执行刷新
- [ ] `api_key_ref` 去重：3 个 MiniMax 实例共享同一 API Key → 仅 1 次 HTTP 请求，数据分发给 3 个实例
- [ ] 串行执行：MiniMax 组失败不影响 DeepSeek 组的刷新
- [ ] 重试逻辑：网络故障时指数退避重试，最多 3 次，失败后该组实例生成 ErrorSummary
- [ ] 货币自动修正：API 返回 CNY 而实例配置为 USD → 实例 currency 自动更新为 CNY
- [ ] `stop()` 后定时刷新停止，Task 取消无泄漏

**需求追溯**：
- PRD: §3.4（数据刷新 — 定时/手动/启动刷新、指数退避最多 3 次、api_key_ref 去重）
- ARCHITECTURE: §2.7（刷新服务）、§3.2（刷新周期完整流程）、§9（状态管理）、§11.3（HTTP 请求执行策略）、§11.4（Timer 管理 — Task.sleep 循环）、ADR-002、ADR-006

---

### T-1.10 实现 AppStateProxy（@MainActor ObservableObject 桥接）

**所属阶段**：Phase 1  
**预估工时**：3h  
**前置任务**：T-1.8

**输入**：
- T-1.8 产出的 `AppState` Actor
- ARCHITECTURE §9.3

**工作内容**：
1. 创建 `AppState/AppStateProxy.swift`，定义为 `@MainActor final class`，遵循 `ObservableObject`
2. 声明 `@Published` 属性（与 AppState 中的数据类型一致）：`instances`、`slotViewDataList`、`refreshState`、`errorSummaries`、`globalSettings`
3. 持有 `AppState` 的引用（`private let state: AppState`）
4. 实现 `syncFromState() async`：
   - 从 `AppState` Actor 中读取所有数据（通过 `await state.getInstances()` 等只读方法）
   - 赋值给 `@Published` 属性 → 触发 SwiftUI 重绘
5. 实现 `triggerManualRefresh() async`：
   - 委托给 `RefreshService.triggerManualRefresh()`
6. 在 `APIUsageStatusApp.swift` 中初始化 `AppStateProxy`，注入到 SwiftUI 视图层级

**输出文件**：
- `APIUsageStatus/AppState/AppStateProxy.swift`

**验证标准**：
- [ ] 编译通过
- [ ] `syncFromState()` 调用后，`@Published` 属性正确更新
- [ ] SwiftUI 视图观察 `AppStateProxy` 的 `@Published` 属性 → 数据变更自动触发 UI 重绘
- [ ] `triggerManualRefresh()` 正确委托给 RefreshService

**需求追溯**：
- ARCHITECTURE: §2.6（AppState）、§9.3（AppStateProxy 设计）、§9.5（视图观察）

---

### T-1.11 实现 Logger + 工具扩展

**所属阶段**：Phase 1  
**预估工时**：3h  
**前置任务**：无

**输入**：
- ARCHITECTURE §10.3（日志记录设计）
- PRD §3.7（涉及日期计算需求）

**工作内容**：
1. 创建 `Utilities/Logger.swift`：封装 `os.Logger`，提供便利初始化：
   - `Logger(subsystem: "com.example.APIUsageStatus", category:)` 按模块分 category（`refresh`, `persistence`, `network`, `keychain`, `supplier`, `render`, `app`）
   - 提供类别化便利静态方法或全局 logger 实例
2. 创建 `Extensions/Date+Extensions.swift`：
   - `startOfDay`：当天 00:00:00
   - `startOfWeek`：当周周日 00:00:00（周日为第一天）
   - `daysUntilEndOfWeek`：距本周六 23:59:59 的天数
   - `isSameDay(as:)`：判断两日期是否为同一天
   - `isToday`：判断日期是否在今天
3. 创建 `Extensions/Decimal+Extensions.swift`：
   - 从字符串安全初始化 `Decimal`
   - 格式化为指定小数位数的字符串
   - 比较/运算辅助方法（用于余额精确保留）
4. 创建 `Utilities/FileManager+Atomic.swift`：
   - `func atomicWrite<T: Encodable>(_ value: T, to url: URL) throws`
   - 实现：先写入 `.tmp` 文件，再 `replaceItemAt`
5. 创建 `Extensions/String+Extensions.swift`（可选）：
   - UUID 格式校验

**输出文件**：
- `APIUsageStatus/Utilities/Logger.swift`
- `APIUsageStatus/Extensions/Date+Extensions.swift`
- `APIUsageStatus/Extensions/Decimal+Extensions.swift`
- `APIUsageStatus/Utilities/FileManager+Atomic.swift`
- `APIUsageStatus/Extensions/String+Extensions.swift`（可选）

**验证标准**：
- [ ] 编译通过
- [ ] `Logger` 在 Console.app 中可按 subsystem 过滤，按 category 区分
- [ ] `Date.startOfDay` / `startOfWeek` 计算正确（用已知日期验证）
- [ ] `Decimal` 扩展能正确处理 `"98.50"` 等余额字符串的解析和比较
- [ ] `FileManager+Atomic`：写入中途模拟崩溃 → 原始文件完好无损（通过手动测试验证：写入大文件，中途终止进程）

**需求追溯**：
- PRD: §3.7（日期计算需求）
- ARCHITECTURE: §4.3（原子文件写入）、§10.3（日志记录）、ADR-010

---

## Phase 2：菜单栏图标渲染

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-2.1 | 实现 CharMapLetters（5×7 位图） | 像素字模 | 4h | 无 |
| T-2.2 | 实现 CharMapDigits（3×5 位图） | 像素字模 | 3h | 无 |
| T-2.3 | 实现 PixelFontEngine（渲染引擎） | 像素字模 | 8h | T-2.1, T-2.2 |
| T-2.4 | 实现 MenuBarIconRenderer | 菜单栏渲染 | 8h | T-2.3, T-1.10 |
| T-2.5 | 连接 MenuBarController 数据绑定到 AppStateProxy | 菜单栏 | 4h | T-2.4, T-1.10, T-0.3 |

---

### T-2.1 实现 CharMapLetters（5×7 位图）

**所属阶段**：Phase 2  
**预估工时**：4h  
**前置任务**：无

**输入**：
- ARCHITECTURE §8.1—§8.2（字符集与数据结构）
- PRD §3.1（菜单栏图标 — 所需字符集定义）

**工作内容**：
1. 创建 `PixelFont/CharMapLetters.swift`
2. 定义 `CharMapLetters` 类型（enum 或 struct 内嵌静态常量字典），包含以下字符的 5×7 布尔矩阵：
   - **A–Z**（26 个大写字母）
   - **符号**：`%`、`¥`、`$`、`.`、`?`、`•`、`/`
3. 每个字符为一个 `[[Bool]]` 类型（5 列 × 7 行）
4. 设计字形时需要保证在 22pt 槽位高度下像素清晰可辨：
   - 所有字符在 5×7 网格内可辨识度最大化
   - 参考经典像素字体设计（如 Apple II 字体风格）
   - 为字母 `I`、`J`、`L` 等窄字符设计合适的视觉居中
5. 以编译时常量字典存储（`static let map: [Character: [[Bool]]]`）

**输出文件**：
- `APIUsageStatus/PixelFont/CharMapLetters.swift`

**验证标准**：
- [ ] 编译通过，字典类型正确
- [ ] 覆盖 26 个大写字母 + 7 个符号（`%`, `¥`, `$`, `.`, `?`, `•`, `/`）共 33 个字符
- [ ] 每个字符的位图为 5×7（5 列 7 行的 `[[Bool]]`）
- [ ] 在 Phase 0 的原型图标中临时替换 `?` 为像素字模版本，截图验证可读性（非正式测试，仅视觉 check）

**需求追溯**：
- PRD: §3.1（菜单栏图标 — 像素字模、字符集覆盖 A-Z 及必要半角符号）
- ARCHITECTURE: §8.1（5×7 字符集）、§8.2（数据结构）、ADR-003

---

### T-2.2 实现 CharMapDigits（3×5 位图）

**所属阶段**：Phase 2  
**预估工时**：3h  
**前置任务**：无

**输入**：
- ARCHITECTURE §8.1—§8.2

**工作内容**：
1. 创建 `PixelFont/CharMapDigits.swift`
2. 定义 `CharMapDigits` 类型，包含数字 0–9 的 3×5 布尔矩阵
3. 每个数字为一个 `[[Bool]]` 类型（3 列 × 5 行）
4. 设计字形要求：
   - 3×5 网格内数字清晰可辨（比 5×7 更紧凑）
   - 数字 `0`、`6`、`8`、`9` 的圆形特征在有限像素内保持辨识度
   - 数字 `1` 为窄字符，在 3 列网格内居中
5. 以编译时常量字典存储

**输出文件**：
- `APIUsageStatus/PixelFont/CharMapDigits.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 覆盖 10 个数字（0–9）
- [ ] 每个数字为 3×5 的 `[[Bool]]`
- [ ] 视觉可辨识度：在模拟渲染中能区分 0/8、6/9 等容易混淆的数字

**需求追溯**：
- PRD: §3.1（像素字模 — 3×5 数字）
- ARCHITECTURE: §8.1（3×5 数字字符集）、§8.2（数据结构）、ADR-003

---

### T-2.3 实现 PixelFontEngine（渲染引擎）

**所属阶段**：Phase 2  
**预估工时**：8h  
**前置任务**：T-2.1, T-2.2

**输入**：
- T-2.1 产出的 `CharMapLetters`（5×7 位图）
- T-2.2 产出的 `CharMapDigits`（3×5 位图）
- ARCHITECTURE §2.11、§8.3—§8.4

**工作内容**：
1. 创建 `PixelFont/PixelFontEngine.swift`，定义为纯函数模块（无状态，不依赖 Actor）
2. 定义 `CharSize` enum：`.letter`（5×7）、`.digit`（3×5）
3. 实现 `renderChar(_:size:color:scale:context:origin:)`：
   - 根据 `char` 和 `CharSize` 查找对应位图
   - 遍历位图中每个 `true` 像素 → `CGContext.fill(rect:)` 绘制矩形
   - 矩形尺寸 = `scale` × `scale`
4. 实现 `renderText(_:size:color:scale:gap:context:origin:)`：
   - 水平拼接渲染每个字符
   - 字符间间距 = `gap` pt
   - 自动根据字符是字母/数字选择 `CharSize`
5. 实现 `renderSlot(context:data:color:mode:)`：
   - 接收 `CGContext`、`SlotViewData`、`NSColor`、`ColorMode`
   - 对配额型实例：绘制简称（`shortName`，2 字母，5×7）→ 进度条（3pt 高 × 18pt 宽矩形）→ 百分比数字文本（3×5）
   - 对余额型实例：绘制简称（2 字母，5×7）→ 余额数值文本（3×5 + 货币符号 5×7）
6. 实现像素缩放计算：
   - 槽位高度 = 22pt，可用垂直空间 ≈ 20pt（上下各 1pt 边距）
   - 5×7 字符：`scale = floor(20pt / 7) = 2pt`（14pt 实际高度，垂直居中）
   - 3×5 数字：使用相同 2pt 缩放保持一致（10pt 实际高度）
   - 所有 `CGRect` 坐标取整（`round`），防止 Retina 屏幕下半像素渲染模糊
7. 实现 `renderProgressBar(context:x:y:width:height:percent:color:)`：
   - 绘制进度条背景（空心线框或浅灰矩形）
   - 根据百分比填充（0-50% 空心、50-80% 半填充、80-100% 全填充）

**输出文件**：
- `APIUsageStatus/PixelFont/PixelFontEngine.swift`

**验证标准**：
- [ ] 编译通过
- [ ] `renderChar("A", .letter, ...)` → 在 `CGContext` 中正确绘制 5×7 的 `A` 字形
- [ ] `renderText("MX", .letter, ...)` → 水平拼接 `M` + `X`，字符间距正确
- [ ] 金额 `renderText("¥45", ...)` → 货币符号 `¥`（5×7）+ 数字 `4` `5`（3×5）正确渲染
- [ ] 百分比 `renderText("82%", ...)` → 数字（3×5）+ `%`（5×7）正确渲染
- [ ] 进度条：70% → 半填充矩形宽度正确
- [ ] 所有渲染坐标取整，Retina 屏幕下无模糊像素
- [ ] 不使用任何 `NSFont` / `CTFont` / `attributedString` API

**需求追溯**：
- PRD: §3.1（菜单栏图标 — 像素字模绘制规范、进度条、槽位单行布局）
- ARCHITECTURE: §2.11（PixelFontEngine）、§7.1（槽位布局规格）、§8（像素字模系统设计）、ADR-003

---

### T-2.4 实现 MenuBarIconRenderer

**所属阶段**：Phase 2  
**预估工时**：8h  
**前置任务**：T-2.3, T-1.10

**输入**：
- T-2.3 产出的 `PixelFontEngine`
- T-1.10 产出的 `AppStateProxy`（提供 `slotViewDataList` 数据）
- ARCHITECTURE §2.3、§7

**工作内容**：
1. 创建 `MenuBar/MenuBarIconRenderer.swift`
2. 定义渲染方法 `func render(slotViewDataList: [SlotViewData], colorMode: ColorMode, refreshState: RefreshState, instancesCount: Int, enabledCount: Int) -> NSImage`：
   a. 特殊状态判断（优先级从高到低）：
      - `instancesCount == 0` → 渲染单个 `?` 字符（置灰色 `#D6D0A0`）
      - `enabledCount == 0 && instancesCount > 0` → 渲染 `NO API`（5×7，置灰）
      - `refreshState == .refreshing` 且首次刷新 → 渲染 `•••`（置灰）
   b. 正常状态：取 `slotViewDataList` 中按 `sortOrder` 升序的前 2 个槽位
   c. 对每个槽位：
      - 计算颜色：根据 `colorMode` + `colorState` 决定
        - 单色模式：`normal` → 系统黑/白，`warning` → 进度条半填充，`critical` → 进度条全填充 + 闪烁
        - 彩色模式：`normal` → `#4CAF50`，`warning` → `#FFC107`，`critical` → `#F44336`
        - 非活跃状态（`disabled`/`unavailable`/`loading`/`error`）→ 全部 `#D6D0A0`
      - 调用 `PixelFontEngine.renderSlot(...)` 绘制
   d. 组装：创建 `NSImage`（高度 22pt，宽度 = 槽位数 × 44pt + (槽位数 − 1) × 2pt 间距）
3. 实现色彩模式逻辑：
   - 单色模式：文字色跟随系统 `NSApp.effectiveAppearance`（深色 → 白，浅色 → 黑），进度条填充比编码阈值
   - 彩色模式：每个槽位独立颜色，基于阈值选择
4. 实现严重阈值闪烁动画：
   - 提供 `startFlashing(forSlot:)` 方法：使用 `Timer.scheduledTimer` 以 1s 为间隔切换可见状态
   - Timer 内检查槽位是否仍处于 `.critical` 状态 → 若否，`invalidate()` 停止
   - 闪烁通过切换 `isFlashingVisible: Bool` 属性实现，重绘时若 `isFlashingVisible == false` 则跳过该槽位
5. 实现特殊状态渲染：
   - `?`（无配置）、`•••`（加载中）、`NO API`（全部禁用）、`N/A`（余额不可用，通过 `SlotViewData.colorState == .unavailable` 触发）
   - 以上所有状态使用 `#D6D0A0` 颜色，不使用透明度
6. 处理 Retina 屏幕：`NSImage` 使用 `size`（逻辑 pt）而非 `pixels`（像素），确保 2x/3x 屏幕正确缩放

**输出文件**：
- `APIUsageStatus/MenuBar/MenuBarIconRenderer.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 0 个实例 → 渲染 22pt 高、约 14pt 宽的 `?` 图标，颜色 `#D6D0A0`
- [ ] 1 个配额型实例 → 渲染 44pt 宽槽位：简称 + 进度条 + 百分比数字
- [ ] 1 个余额型实例 → 渲染 44pt 宽槽位：简称 + 余额数字（无进度条）
- [ ] 2 个实例 → 渲染 90pt 宽（44 + 2 + 44），两槽位间距 2pt
- [ ] ≥3 个实例 → 仅渲染前 2 个槽位
- [ ] 单色模式：暗色主题下文字白色，亮色主题下文字黑色
- [ ] 彩色模式：安全绿/警告黄/严重红色正确着色
- [ ] 严重阈值时闪烁动画以 1Hz 频率运行
- [ ] 全部禁用 → 显示 `NO API`（5×7 像素字模），置灰
- [ ] 余额不可用 → 对应槽位显示 `N/A`，置灰
- [ ] 渲染结果设为 `NSStatusBarButton.image` → 菜单栏正常显示
- [ ] Retina 屏幕下像素锐利无模糊

**需求追溯**：
- PRD: §3.1（菜单栏图标全部规则 — 无配置/启动中/全部禁用/余额不可用/刷新失败状态、槽位尺寸与布局、单色/彩色模式、严重闪烁、槽位排序与截断）
- ARCHITECTURE: §2.3（MenuBarIconRenderer）、§7（菜单栏渲染管线）、§7.3（色彩模式逻辑）、§7.4（闪烁动画）、§7.5（特殊状态）

---

### T-2.5 连接 MenuBarController 数据绑定到 AppStateProxy

**所属阶段**：Phase 2  
**预估工时**：4h  
**前置任务**：T-2.4, T-1.10, T-0.3

**输入**：
- T-0.3 产出的 `MenuBarController`（已有的 NSStatusItem + Popover）
- T-2.4 产出的 `MenuBarIconRenderer`
- T-1.10 产出的 `AppStateProxy`

**工作内容**：
1. 修改 `MenuBarController.swift`：
   - 持有 `MenuBarIconRenderer` 实例
   - 持有 `AppStateProxy` 引用
   - 移除 Phase 0 中的静态 `?` 标题文本
   - 改为观察 `AppStateProxy` 的 `@Published` 属性
2. 数据绑定实现：
   - 使用 Combine `sink` 观察 `AppStateProxy.$slotViewDataList`、`AppStateProxy.$refreshState`、`AppStateProxy.$instances`、`AppStateProxy.$globalSettings`
   - 任何变化 → 调用 `updateMenuBarIcon()`
3. 实现 `updateMenuBarIcon()`：
   - 调用 `MenuBarIconRenderer.render(...)` 生成 `NSImage`
   - 将 `NSImage` 设置到 `NSStatusBarButton.image`
   - `NSStatusBarButton.imagePosition = .imageOnly`
   - `NSStatusBarButton.needsDisplay = true`
4. 处理 `refreshState` 变更：
   - `.refreshing` → 触发加载中 `•••` 渲染
   - `.idle` → 正常渲染
5. 保持已有功能：左键 Popover、右键菜单不变
6. 管理刷新后的图标更新：`RefreshService` 完成刷新 → `AppStateProxy.syncFromState()` → `@Published` 触发 `MenuBarController` 更新

**输出文件**：
- `APIUsageStatus/MenuBar/MenuBarController.swift`（修改）

**验证标准**：
- [ ] 编译通过
- [ ] 应用启动：尚未有数据 → 图标渲染加载中 `•••`
- [ ] 首次刷新完成 → 图标切换为实际槽位渲染
- [ ] Phase 0 的 Popover 左键/右键交互功能保持正常
- [ ] 运行时添加/修改实例 → 图标实时更新（延迟 ≤ 刷新周期）
- [ ] 无 Combine 订阅泄漏（`AnyCancellable` 存储在 `Set<AnyCancellable>` 中，在 `deinit` 时释放）

**需求追溯**：
- PRD: §4（用户交互流程 — 菜单栏图标点击交互）
- ARCHITECTURE: §2.2（MenuBarController 监听 AppState）、§3.3（菜单栏渲染流程）、§9.5（视图观察）

---

## Phase 3：Popover 用量面板

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-3.1 | 实现 UsageCardView（单实例用量卡片） | 视图 | 6h | T-1.10 |
| T-3.2 | 实现 UsagePanelView（卡片列表 + 错误栏 + 操作按钮） | 视图 | 6h | T-3.1, T-1.10 |
| T-3.3 | 连接 UsagePanelView 数据绑定到 AppStateProxy | 视图 | 4h | T-3.2, T-1.10, T-0.3 |

---

### T-3.1 实现 UsageCardView（单实例用量卡片）

**所属阶段**：Phase 3  
**预估工时**：6h  
**前置任务**：T-1.10

**输入**：
- T-1.10 产出的 `AppStateProxy`（提供 `slotViewDataList` 中的 `SlotViewData`）
- T-1.1 产出的 `SlotViewData`、`InstanceType` 等模型

**工作内容**：
1. 创建 `Views/UsageCardView.swift`，SwiftUI 视图
2. 实现配额型实例卡片：
   - 显示名（`displayName`）
   - 用量进度条（`ProgressView` + 百分比数字 + 用量/上限数值）
   - 距下次定时刷新的分钟数（`nextRefreshMinutes`）
   - 自然天/周配额型额外显示「周期剩余天数」（`cycleRemainingDays`）
3. 实现余额型实例卡片：
   - 显示名
   - 当前剩余余额（金额，带货币符号）
   - 当日用量（本地统计值，标注「约」）
   - 日均消耗（用户配置的统计周期，多个周期分列展示）
4. 实现通用卡片元素：
   - 最近一次刷新时间显示
   - 卡片视觉样式（圆角矩形背景、阴影、内边距）
   - 紧凑布局，适配 Popover 宽度（约 280–320pt）
5. 卡片使用 `@ObservedObject` 或接收 `SlotViewData` 的绑定（通过 `AppStateProxy` 驱动）

**输出文件**：
- `APIUsageStatus/Views/UsageCardView.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 配额型卡片：进度条百分比与 `percent` 值一致，用量/上限数值正确
- [ ] 余额型卡片：余额金额、货币符号、当日用量（约）、日均消耗正确显示
- [ ] `nextRefreshMinutes` 正确显示剩余分钟数
- [ ] SwiftUI Preview 中可用 Mock 数据预览配额型和余额型两张卡片

**需求追溯**：
- PRD: §3.2（用量面板卡片展示规则 — 配额型/余额型卡片内容）
- ARCHITECTURE: §2.4（UsageCardView 设计）、§4.1（SlotViewData 模型）

---

### T-3.2 实现 UsagePanelView（卡片列表 + 错误栏 + 操作按钮）

**所属阶段**：Phase 3  
**预估工时**：6h  
**前置任务**：T-3.1, T-1.10

**输入**：
- T-3.1 产出的 `UsageCardView`
- T-1.10 产出的 `AppStateProxy`
- ARCHITECTURE §2.4（UsagePanelView 设计）

**工作内容**：
1. 创建 `Views/UsagePanelView.swift`，SwiftUI 视图
2. 实现可滚动卡片列表：
   - 使用 `ScrollView` + `LazyVStack` 或 `List`
   - 根据 `AppStateProxy.slotViewDataList` 遍历渲染 `UsageCardView`
3. 实现错误摘要栏：
   - 当 `AppStateProxy.errorSummaries` 非空时，在面板顶部显示
   - 区分错误类型显示文案：
     - `networkTimeout` / `networkUnreachable` → "Network error, retrying in X min"
     - `authFailed` → "API Key invalid, check settings"
     - `apiError(code:)` → "API error (code: XXX)"
   - 每条错误关联到实例的 `displayName`
4. 实现手动刷新按钮：
   - 按钮文案：「刷新」
   - 点击调用 `AppStateProxy.triggerManualRefresh()`
   - 刷新期间按钮禁用或显示 loading 状态
5. 实现「设置」入口按钮（齿轮图标 + 文字）
   - 点击 → 打开设置窗口（Phase 4 实现，此阶段可先无操作或打开占位窗口）
6. 实现空状态视图：
   - 当 `slotViewDataList` 为空且无不活跃实例时 → 显示引导文案 + 「添加第一个服务」按钮
   - 创建 `Views/EmptyStateView.swift`
7. 处理 Popover 尺寸：
   - 初始尺寸：宽约 300pt，高度自适应（最大约 500pt）
   - 使用 `fixedSize` 或手动设置 `NSPopover.contentSize`

**输出文件**：
- `APIUsageStatus/Views/UsagePanelView.swift`
- `APIUsageStatus/Views/EmptyStateView.swift`

**验证标准**：
- [ ] 编译通过
- [ ] Popover 显示所有实例卡片，按 `sortOrder` 排序
- [ ] 无实例 → 显示空状态引导视图 + 「添加第一个服务」按钮
- [ ] 有刷新失败的实例 → 错误摘要栏正确显示错误类型和实例名
- [ ] 点击刷新按钮 → 触发手动刷新，按钮显示 loading 状态
- [ ] 设置按钮可点击（不要求实际功能，可打印日志）
- [ ] 面板内容可滚动（≥3 个实例时）
- [ ] Popover 外部点击可正常关闭

**需求追溯**：
- PRD: §3.2（用量面板 — 错误摘要栏、手动刷新、设置入口、空状态）
- ARCHITECTURE: §2.4（UsagePanelView 设计）、§9.5（视图观察）

---

### T-3.3 连接 UsagePanelView 数据绑定到 AppStateProxy

**所属阶段**：Phase 3  
**预估工时**：4h  
**前置任务**：T-3.2, T-1.10, T-0.3

**输入**：
- T-3.2 产出的 `UsagePanelView`
- T-1.10 产出的 `AppStateProxy`
- T-0.3 产出的 `MenuBarController`（持有 Popover）

**工作内容**：
1. 修改 `MenuBarController.swift`（继续 T-2.5 的修改）：
   - 移除 Phase 0 中的占位 Popover 内容
   - 替换为 `UsagePanelView`（SwiftUI 视图，通过 `NSHostingView` 或 `NSHostingController` 包装）
2. 将 `AppStateProxy` 注入 `UsagePanelView`：
   - 通过环境对象或直接传递 `@ObservedObject` 引用
3. 确保 Popover 数据流正确：
   - `AppStateProxy.syncFromState()` → `@Published` 属性 → SwiftUI 更新 `UsagePanelView` → 卡片列表刷新
4. 处理 Popover 尺寸自适应：
   - 在 `UsagePanelView` 渲染完成后，根据内容高度动态调整 `NSPopover.contentSize`
5. 保留 Phase 0 的右键菜单功能不变

**输出文件**：
- `APIUsageStatus/MenuBar/MenuBarController.swift`（修改）

**验证标准**：
- [ ] 编译通过
- [ ] 点击菜单栏图标 → Popover 显示 `UsagePanelView`（非占位内容）
- [ ] 刷新完成后 → Popover 内容自动更新（无需手动关闭再打开）
- [ ] 右键菜单「立即刷新」「打开设置」「退出」仍正常工作
- [ ] Popover 尺寸随实例数量自适应（1 个实例 ≈ 120pt 高，3 个实例 ≈ 300pt 高）
- [ ] 无内存泄漏（`NSHostingView` 在 Popover 关闭时正确释放）

**需求追溯**：
- PRD: §4（用户交互流程 — 点击图标展开 Popover）
- ARCHITECTURE: §2.4（UsagePanelView 与 Popover 集成）、§3.2（刷新周期中 UI 更新步骤）、§9.5（视图观察）

---

## Phase 4：设置窗口

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-4.1 | 实现 InstanceEditorView（添加/编辑实例表单） | 视图 | 8h | T-1.1 |
| T-4.2 | 实现 SettingsView（实例列表 + 通用设置） | 视图 | 6h | T-4.1, T-1.10 |
| T-4.3 | 实现 SettingsWindow（NSWindow 包装） | 视图 | 2h | T-4.2 |
| T-4.4 | 实现 SettingsViewModel（协调设置数据读写） | 视图模型 | 6h | T-4.2, T-1.3, T-1.8 |
| T-4.5 | 连接设置入口点（Popover + 右键菜单） | 集成 | 2h | T-4.3, T-4.4, T-3.3 |

---

### T-4.1 实现 InstanceEditorView（添加/编辑实例表单）

**所属阶段**：Phase 4  
**预估工时**：8h  
**前置任务**：T-1.1

**输入**：
- T-1.1 产出的所有数据模型（`Instance`, `Thresholds`, `GlobalSettings`，理解所有字段及其含义）

**工作内容**：
1. 创建 `Views/InstanceEditorView.swift`，SwiftUI 视图
2. 实现基本字段表单：
   - **供应商选择**：`Picker` — `MiniMax` / `DeepSeek`（联动后续字段）
   - **统计维度选择**：`Picker`，选项根据供应商联动：
     - MiniMax → `text_model_5h` / `non_text_daily` / `weekly_total`
     - DeepSeek → `balance`
   - **显示名**（`TextField`，用户自定义，默认空）
   - **显示名简称**（`TextField`，限 2 个大写字母，默认空）
   - **API Key**（`SecureField`，保存到 Keychain）
   - **货币类型**（仅余额型实例出现，`Picker` — `CNY` / `USD`，默认 `CNY`）
3. 实现阈值配置区域（根据实例类型动态切换）：
   - **配额型**：
     - 用量百分比警告线 `Slider` + 数值输入（默认 80%，范围 0–100）
     - 用量百分比严重线 `Slider` + 数值输入（默认 95%，范围 0–100）
   - **余额型**：
     - 余额警示阈值 `TextField`（默认 10.00，货币符号根据实例绑定）
     - 余额严重阈值 `TextField`（默认 2.00）
     - 日均消耗统计周期多选：`Toggle` 列表 — 当前自然周 / 当前自然月 / 倒数 7 天 / 倒数 30 天
     - 历史保留天数 `TextField`（默认 0，表示永久保留）
4. 表单验证：
   - 显示名简称必须为 2 个大写字母（正则 `^[A-Z]{2}$`），为空时提示
   - 阈值合法性：警告线 < 严重线（配额型），警示阈值 > 严重阈值（余额型）
5. 区分添加模式（新建 `Instance`，自动生成 UUID v4）和编辑模式（修改现有 `Instance`，保持 UUID 不变）
6. 创建辅助视图 `Views/ThresholdConfigView.swift`（阈值配置的可复用组件）

**输出文件**：
- `APIUsageStatus/Views/InstanceEditorView.swift`
- `APIUsageStatus/Views/ThresholdConfigView.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 供应商切换 → 统计维度选项联动更新
- [ ] 选择 MiniMax → 货币选择器隐藏；选择 DeepSeek → 货币选择器显示
- [ ] 配额型阈值滑块和余额型阈值输入框根据类型正确切换
- [ ] 表单验证：简称非法（非 2 位大写字母）→ 显示错误提示
- [ ] 警告线 > 严重线（配额型）→ 显示错误提示
- [ ] 添加模式：自动生成 UUID v4，所有字段为默认值
- [ ] 编辑模式：预填现有值，UUID 不可修改
- [ ] SwiftUI Preview 中可预览表单

**需求追溯**：
- PRD: §3.3（供应商与统计维度 — 实例管理）、§3.5（偏好设置 — 服务实例管理、配色与阈值、通用设置）
- ARCHITECTURE: §2.5（设置窗口中的实例编辑）、§4.1（Instance / Thresholds 模型）

---

### T-4.2 实现 SettingsView（实例列表 + 通用设置）

**所属阶段**：Phase 4  
**预估工时**：6h  
**前置任务**：T-4.1, T-1.10

**输入**：
- T-4.1 产出的 `InstanceEditorView`
- T-1.10 产出的 `AppStateProxy`

**工作内容**：
1. 创建 `Views/SettingsView.swift`，SwiftUI 视图
2. 实现标签页式或分区布局：
   - **「服务实例」标签**：
     - 现有实例 `List`，每个实例行显示：启用/禁用 `Toggle`、显示名、供应商标签、编辑/删除按钮
     - 「添加实例」按钮 → 打开 `InstanceEditorView`（Sheet 或 NavigationLink）
     - 编辑按钮 → 打开 `InstanceEditorView`（编辑模式）
     - 删除按钮 → 确认对话框 → 执行删除
     - 拖拽排序：`List` + `.onMove` 或自定义拖拽手势调整 `sortOrder`
   - **「通用设置」标签**：
     - 刷新间隔 `Stepper` + 数值输入（1–60 分钟，默认 5）
     - 图标色彩模式 `Picker`（单色 / 彩色）
     - 开机自启 `Toggle`（暂不实现实际功能，Phase 7 接入）
     - 通知开关 `Toggle`（暂不实现实际功能，Phase 6 接入）
3. 删除确认逻辑：
   - 使用 `.alert` 或 `.confirmationDialog`，提示「删除后数据不可恢复」
4. 拖拽排序实现：
   - macOS 13 兼容：使用 `.onMove(perform:)`（SwiftUI List 原生支持）或自定义手势
   - 排序完成后批量更新 `sortOrder` 并调用保存
5. 实例列表按 `sortOrder` 排序显示

**输出文件**：
- `APIUsageStatus/Views/SettingsView.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 实例列表显示所有现有实例，按 `sortOrder` 排序
- [ ] 启用/禁用 Toggle 可切换
- [ ] 添加按钮 → 打开 InstanceEditorView（添加模式）
- [ ] 编辑按钮 → 打开 InstanceEditorView（编辑模式，预填数据）
- [ ] 删除按钮 → 确认后实例消失
- [ ] 拖拽调整顺序 → `sortOrder` 正确更新
- [ ] 通用设置中刷新间隔、色彩模式可正常调整
- [ ] 开机自启/通知 Toggle 可切换（不要求实际生效）

**需求追溯**：
- PRD: §3.5（偏好设置 — 服务实例管理、配色与阈值、通用设置、拖拽排序）
- ARCHITECTURE: §2.5（SettingsView 设计）、§4.1（GlobalSettings 模型）

---

### T-4.3 实现 SettingsWindow（NSWindow 包装）

**所属阶段**：Phase 4  
**预估工时**：2h  
**前置任务**：T-4.2

**输入**：
- T-4.2 产出的 `SettingsView`

**工作内容**：
1. 创建 `Views/SettingsWindow.swift`（或作为 `NSWindowController` 子类的扩展）
2. 实现 `SettingsWindowController`：
   - 持有 `NSWindow`，包裹 `NSHostingView(rootView: SettingsView(...))`
   - 窗口标题：「设置 — API Usage Status」
   - 窗口属性：`styleMask = [.titled, .closable, .miniaturizable, .resizable]`
   - 最小尺寸：宽 500pt，高 400pt
   - 默认尺寸：宽 600pt，高 500pt
   - 居中显示（`window.center()`）
3. 处理窗口生命周期：
   - 关闭时调用 `window.orderOut(nil)` 而非释放
   - 再次打开时重用同一 `SettingsWindowController` 实例（避免多窗口）
4. 提供 `open()` 和 `close()` 方法

**输出文件**：
- `APIUsageStatus/Views/SettingsWindow.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 调用 `open()` → 窗口正确显示，标题栏完整
- [ ] 窗口可拖动、可缩放、可关闭
- [ ] 关闭后再次 `open()` → 重用同一窗口实例（非创建新窗口）
- [ ] 窗口内容为 `SettingsView`，表单可交互

**需求追溯**：
- PRD: §3.5（偏好设置 — 设置窗口）
- ARCHITECTURE: §2.5（SettingsWindow 设计）

---

### T-4.4 实现 SettingsViewModel（协调设置数据读写）

**所属阶段**：Phase 4  
**预估工时**：6h  
**前置任务**：T-4.2, T-1.3, T-1.8

**输入**：
- T-4.2 产出的 `SettingsView`（UI 框架就绪）
- T-1.3 产出的 `PersistenceService`（读写 instances.json + Keychain）
- T-1.8 产出的 `AppState`（更新运行时状态）

**工作内容**：
1. 创建 `Views/SettingsViewModel.swift`（或放在 `AppState/` 下），定义为 `@MainActor class`，遵循 `ObservableObject`
2. 实现数据加载：`loadFromDisk()` → 调用 `PersistenceService.loadInstances()` → 填充 `@Published` 属性
3. 实现保存逻辑 `save()`：
   a. 验证所有实例数据（简称合法性、阈值一致性等）
   b. `PersistenceService.saveInstances(instances, settings)` → 原子写入 `instances.json`
   c. 若 API Key 变更 → `PersistenceService.saveApiKey(ref, key)` → 写入 Keychain
   d. 若实例被删除 → 调用 `PersistenceService.deleteInstance(...)`（清理 JSON + Keychain）
   e. 通知 `AppState` 更新：`await appState.setInstances(newInstances)`、`await appState.updateSettings(newSettings)`
   f. 调用 `AppStateProxy.syncFromState()` 触发 UI 刷新
   g. 若刷新间隔变更 → `await refreshService.restartTimer(newInterval)`
4. 实现实例增删改的辅助方法：
   - `addInstance(_:)`、`updateInstance(_:)`、`deleteInstance(_:)`
   - 这些方法操作本地 `@Published` 副本，仅在 `save()` 时持久化
5. 注入依赖：`PersistenceService`、`AppState`、`RefreshService` 的引用

**输出文件**：
- `APIUsageStatus/Views/SettingsViewModel.swift`（或 `APIUsageStatus/AppState/SettingsViewModel.swift`）

**验证标准**：
- [ ] 编译通过
- [ ] 打开设置窗口 → 自动加载现有实例和设置
- [ ] 添加实例 → 保存 → `instances.json` 文件更新，菜单栏/Popover 即时反映
- [ ] 编辑实例 → 保存 → 变更正确持久化
- [ ] 删除实例 → `{uuid}.json` 和 Keychain（无共享引用时）被清理
- [ ] 修改刷新间隔 → 保存 → RefreshService Timer 重启生效
- [ ] 修改 API Key → 保存 → Keychain 条目更新
- [ ] 验证失败时（如简称非法）→ 提示用户，不执行保存

**需求追溯**：
- PRD: §3.5（偏好设置保存逻辑）、§3.8（实例删除清理规则）
- ARCHITECTURE: §2.5（SettingsViewModel 设计）、§3.4（设置写入流程）、§9（状态管理方案）

---

### T-4.5 连接设置入口点（Popover + 右键菜单）

**所属阶段**：Phase 4  
**预估工时**：2h  
**前置任务**：T-4.3, T-4.4, T-3.3

**输入**：
- T-4.3 产出的 `SettingsWindow`
- T-4.4 产出的 `SettingsViewModel`
- T-3.3 产出的 Popover 中的「设置」入口按钮 + 右键菜单「打开设置」

**工作内容**：
1. 修改 `UsagePanelView.swift` 中的「设置」按钮：
   - 点击 → 调用 `SettingsWindow.open()`
2. 修改 `MenuBarController.swift` 中的右键菜单：
   - 「打开设置」菜单项 → 调用 `SettingsWindow.open()`
3. 确保 `SettingsWindow` 在应用中以单例形式存在（或在 `AppDelegate` 中创建一次，注入各处）
4. 确保 `SettingsViewModel` 在 `SettingsView` 打开时已正确初始化（从 `PersistenceService` 加载最新数据）

**输出文件**：
- `APIUsageStatus/Views/UsagePanelView.swift`（修改 — 设置按钮 action）
- `APIUsageStatus/MenuBar/MenuBarController.swift`（修改 — 右键菜单 action）

**验证标准**：
- [ ] 编译通过
- [ ] 从 Popover 点击「设置」按钮 → 设置窗口正常打开
- [ ] 从右键菜单点击「打开设置」→ 设置窗口正常打开
- [ ] 反复打开/关闭设置窗口 → 每次打开均加载最新数据
- [ ] 在设置窗口修改并保存 → 关闭窗口 → 菜单栏/Popover 反映最新变更

**需求追溯**：
- PRD: §3.5（偏好设置入口 — 面板内设置图标 + 右键菜单打开设置）
- ARCHITECTURE: §2.2（右键菜单）、§2.4（Popover 设置入口）

---

## Phase 5：余额跟踪

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-5.1 | 实现 BalanceCalculator（纯函数计算模块） | 余额 | 8h | T-1.1 |
| T-5.2 | 集成 BalanceSnapshot 持久化到 RefreshService | 服务层 | 4h | T-5.1, T-1.9, T-1.3 |
| T-5.3 | 增强 UsageCardView 余额型卡片（日用量 + 日均消耗） | 视图 | 4h | T-5.1, T-3.1, T-1.10 |

---

### T-5.1 实现 BalanceCalculator（纯函数计算模块）

**所属阶段**：Phase 5  
**预估工时**：8h  
**前置任务**：T-1.1

**输入**：
- T-1.1 产出的 `BalanceSnapshot`、`DailyUsageEntry`、`AvgDailyPeriod` 模型
- PRD §3.7（余额型算法完整描述）

**工作内容**：
1. 创建 `Balance/BalanceCalculator.swift`，定义为纯函数模块（enum 或 struct 内嵌静态方法，无状态）
2. 实现核心计算函数 `calculate(currentToppedUp: String, latestSnapshot: BalanceSnapshot?) -> BalanceUpdate`：
   a. **跨日检测**：比较 `latestSnapshot.todayDate` 与当前日期 → 若不是同一天：
      - 将昨日 `todayUsage` 归档到 `history` 数组
      - 重置 `todayDate` 为当前日期，`todayUsage` 为 `"0"`
      - 保留 `latestToppedUp` 和 `latestToppedUpTs` 不变（跨场景不改变余额基线）
   b. **首次刷新处理**：`latestSnapshot == nil` → 不计算消耗，将 `currentToppedUp` 作为基线写入新 `BalanceSnapshot`
   c. **正常消耗**：`currentToppedUp < latestToppedUp` → 差值 = `latestToppedUp - currentToppedUp`，累加到 `todayUsage`
   d. **充值检测**：`currentToppedUp > latestToppedUp` → 不计消耗，更新 `lastTopupDate` 为当前日期，将 `latestToppedUp` 更新为新值
   e. **余额不变**：`currentToppedUp == latestToppedUp` → 消耗为 0
3. 实现日均消耗计算函数 `calculateDailyAverages(history: [DailyUsageEntry], periods: [AvgDailyPeriod]) -> [AvgDailyPeriod: Decimal]`：
   - 根据 `periods` 中选中的周期计算对应区间的日均消耗
   - `currentWeek`：从当周周日到今天的 `history` 数据合计 ÷ 天数
   - `currentMonth`：从本月 1 日到今天的 `history` 数据合计 ÷ 天数
   - `last7Days`：过去 7 个自然日的 `history` 数据合计 ÷ 7
   - `last30Days`：过去 30 个自然日的 `history` 数据合计 ÷ 30
   - 无记录的天视为 0，不影响分母
4. 实现历史清理函数 `trimHistory(history: [DailyUsageEntry], retentionDays: Int) -> [DailyUsageEntry]`：
   - `retentionDays == 0` → 不裁剪（永久保留）
   - `retentionDays > 0` → 仅保留最近 N 天的条目
5. 所有余额比较/计算使用 `Decimal` 类型（字符串 → Decimal 解析），确保精度
6. 返回 `BalanceUpdate` struct（包含新的 `BalanceSnapshot` 和可选的日均消耗数据）

**输出文件**：
- `APIUsageStatus/Balance/BalanceCalculator.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 跨日场景：昨天 23:59 `todayUsage = "5.00"`，今天 00:01 刷新 → `todayUsage` 归零，昨天的 `"5.00"` 出现在 `history` 中
- [ ] 正常消耗：`latestToppedUp = "100.00"`，本次 `currentToppedUp = "95.00"` → `todayUsage` 增加 `"5.00"`
- [ ] 充值检测：`latestToppedUp = "10.00"`，本次 `currentToppedUp = "110.00"` → `todayUsage` 不变，`lastTopupDate` 更新，基线更新为 `"110.00"`
- [ ] 首次刷新：`latestSnapshot = nil` → 返回基线快照，`todayUsage = "0"`
- [ ] 日均消耗：`currentWeek` 周期正确筛选最近周日到今天的数据
- [ ] 历史裁剪：`retentionDays = 30` → 仅保留最近 30 天条目
- [ ] 精度：`Decimal` 运算无浮点精度丢失（如 `"100.00" - "95.50" = "4.50"` 精确）

**需求追溯**：
- PRD: §3.7（余额型当日用量本地统计 — 完整算法：跨日检测/差值计算/充值检测/首次刷新/日均消耗 4 种周期/历史保留天数）
- ARCHITECTURE: §2.13（BalanceCalculator 设计）、§4.1（BalanceSnapshot / DailyUsageEntry 模型）、ADR-007

---

### T-5.2 集成 BalanceSnapshot 持久化到 RefreshService

**所属阶段**：Phase 5  
**预估工时**：4h  
**前置任务**：T-5.1, T-1.9, T-1.3

**输入**：
- T-5.1 产出的 `BalanceCalculator`
- T-1.9 产出的 `RefreshService`（刷新编排）
- T-1.3 产出的 `PersistenceService`（读写 `{uuid}.json`）

**工作内容**：
1. 修改 `RefreshService.swift`（在 T-1.9 实现的基础上）：
   a. 在 `performRefresh()` 的余额型实例处理步骤中：
      - 从 `PersistenceService.loadBalanceSnapshot(for: uuid)` 读取当前快照
      - 将 API 返回的 `topped_up_balance`（字符串）和快照传给 `BalanceCalculator.calculate(...)`
      - 获取返回的 `BalanceUpdate`，调用 `PersistenceService.saveBalanceSnapshot(...)` 即时保存
      - 将 `BalanceUpdate` 中的 `todayUsage`、`dailyAverages` 等数据写入对应的 `SlotViewData`
   b. 货币自动修正逻辑（Phase 1 已实现基础版本，此处增强）：
      - 若 `currency` 变更导致小数位变化 → 保留原始精度
2. 确保余额快照读写不阻塞其他刷新步骤
3. 确保应用终止时的数据一致性：每次刷新后即时保存（已在架构中设计），无需额外 `applicationWillTerminate` 逻辑

**输出文件**：
- `APIUsageStatus/Services/RefreshService.swift`（修改）

**验证标准**：
- [ ] 编译通过
- [ ] 每次刷新后 `{uuid}.json` 内容更新（`latestToppedUpTs` 时间戳变化）
- [ ] 跨日时 `todayUsage` 正确归档到 `history`
- [ ] 充值后 `lastTopupDate` 更新
- [ ] `BalanceSnapshot` JSON 与 PRD §3.7 schema 一致
- [ ] 首次刷新后 `{uuid}.json` 文件创建（含基线数据）
- [ ] 余额历史 JSON 损坏 → 重置基线，日志记录 `.fault` 级别

**需求追溯**：
- PRD: §3.7（数据持久化 — 每次刷新即时保存到 `{uuid}.json`）
- ARCHITECTURE: §3.2（刷新周期中余额处理步骤）、§4.2（存储布局）

---

### T-5.3 增强 UsageCardView 余额型卡片（日用量 + 日均消耗）

**所属阶段**：Phase 5  
**预估工时**：4h  
**前置任务**：T-5.1, T-3.1, T-1.10

**输入**：
- T-5.1 产出的 `BalanceCalculator`（日均消耗数据格式）
- T-3.1 产出的 `UsageCardView`（已有基础余额卡片）
- T-1.10 产出的 `AppStateProxy`

**工作内容**：
1. 修改 `UsageCardView.swift` 的余额型部分：
   a. 当日用量展示：从 `SlotViewData` 中读取 `todayUsage`，显示为「约 ¥X.XX」（标注「约」）
   b. 日均消耗展示：从 `SlotViewData` 中读取 `dailyAverages` 字典，按用户配置的统计周期分列展示：
      - « 当前自然周：¥X.XX/天
      - « 当前自然月：¥X.XX/天
      - « 倒数 7 天：¥X.XX/天
      - « 倒数 30 天：¥X.XX/天
   c. 充值余额 vs 赠金余额区分展示：
      - 补充显示 `topped_up_balance`（标注「充值余额」）与 `total_balance`（标注「总余额」）的区分
   d. 紧凑布局优化：若配置了多个统计周期，使用两列网格或可折叠区域避免卡片过高
2. 确保 `SlotViewData` 的 `InstanceType.balance` 关联值中包含 `todayUsage`、`dailyAverages` 等必要字段
3. 若 `SlotViewData` 类型需扩展以容纳余额追踪数据，同步修改 T-1.1 中定义的模型

**输出文件**：
- `APIUsageStatus/Views/UsageCardView.swift`（修改）
- 可能需要修改：`APIUsageStatus/Models/SlotViewData.swift`（扩展余额字段）

**验证标准**：
- [ ] 编译通过
- [ ] 余额型卡片显示当日用量并标注「约」
- [ ] 日均消耗按选中周期分列展示（如「当前自然周 ¥3.50/天」）
- [ ] 充值余额 vs 赠金余额区分展示在卡片中
- [ ] 卡片高度在多个统计周期选中时仍可接受（不超 200pt）
- [ ] 无选中统计周期时（`avgDailyPeriods` 为空）→ 不显示日均消耗区域

**需求追溯**：
- PRD: §3.2（余额型卡片 — 当日用量（约）、日均消耗分列展示）、§3.7（`topped_up_balance` vs `granted_balance` 区分）
- ARCHITECTURE: §2.4（UsageCardView 余额型展示）、ADR-007

---

## Phase 6：通知系统

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-6.1 | 实现 NotificationManager（阈值评估 + UN 通知） | 服务层 | 6h | T-1.1, T-1.8 |
| T-6.2 | 实现 InstanceDetailPanel（NSPanel 独立详情窗口） | 视图 | 4h | T-3.1, T-1.10 |
| T-6.3 | 连接通知开关 + 集成 NotificationManager 到 RefreshService | 集成 | 4h | T-6.1, T-6.2, T-1.9, T-4.4 |

---

### T-6.1 实现 NotificationManager（阈值评估 + UN 通知）

**所属阶段**：Phase 6  
**预估工时**：6h  
**前置任务**：T-1.1, T-1.8

**输入**：
- T-1.1 产出的 `Instance`、`Thresholds`、`SlotViewData`、`ColorState` 等模型
- T-1.8 产出的 `AppState`（运行时实例数据）

**工作内容**：
1. 创建 `Services/NotificationManager.swift`，定义为 `actor`（或 `@MainActor class`，因 `UNUserNotificationCenter` 的 delegate 需在主线程）
2. 实现 `requestPermission()`：
   - 调用 `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])`
   - 处理用户拒绝的情况（记录日志，不崩溃）
3. 实现 `evaluateThresholds(instances: [Instance], slotData: [SlotViewData])`：
   a. 检查全局通知开关（`globalSettings.notificationsEnabled`），关闭则直接返回
   b. 遍历每个实例：
      - **配额型**：`percent >= thresholds.usage_critical_percent` → 准备通知
      - **余额型**：`remainingBalance <= thresholds.balance_critical` → 准备通知
   c. 通知内容：
      - 配额型：标题「⚠️ {displayName} 用量严重」，正文「当前 {percent}%，严重线 {criticalPercent}%」
      - 余额型：标题「⚠️ {displayName} 余额不足」，正文「当前 ¥{remaining}，严重线 ¥{critical}」
   d. 使用 `UNMutableNotificationContent` 构建通知
   e. 附加 `userInfo`：`["instance_uuid": uuid]`，用于点击通知时定位实例
4. 实现 `scheduleNotification(content:)`：
   - `UNNotificationRequest` 使用唯一标识符（基于 `instance_uuid + timestamp`）
   - 添加到 `UNUserNotificationCenter`
5. 实现 `UNUserNotificationCenterDelegate`：
   - 处理前台通知展示（允许前台显示）
   - 处理通知点击：从 `userInfo` 中提取 `instance_uuid` → 打开 `InstanceDetailPanel`

**输出文件**：
- `APIUsageStatus/Services/NotificationManager.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 应用首次启动 → 请求通知权限（macOS 对话框弹出）
- [ ] 配额型实例 `percent = 96`（严重线 95）→ 触发通知
- [ ] 余额型实例剩余 ¥1.50（严重线 ¥2.00）→ 触发通知
- [ ] 正常用量/余额 → 不触发通知
- [ ] 通知关闭（`notificationsEnabled = false`）→ 不触发任何通知
- [ ] 点击通知 → 打开 `InstanceDetailPanel`（T-6.2 完成后验证）

**需求追溯**：
- PRD: §3.1（严重阈值闪烁）、§3.5（通知开关、点击通知打开独立面板）、§4（通知 → NSPanel 交互）
- ARCHITECTURE: §2.12（NotificationManager 设计）、§3.2（刷新周期中阈值评估步骤）、ADR-008

---

### T-6.2 实现 InstanceDetailPanel（NSPanel 独立详情窗口）

**所属阶段**：Phase 6  
**预估工时**：4h  
**前置任务**：T-3.1, T-1.10

**输入**：
- T-3.1 产出的 `UsageCardView`（可复用的卡片视图）
- T-1.10 产出的 `AppStateProxy`

**工作内容**：
1. 创建 `Views/InstanceDetailPanel.swift`
2. 实现 `InstanceDetailPanelController`（`NSWindowController` 子类）：
   - 创建 `NSPanel`：
     - `styleMask = [.titled, .closable, .nonactivatingPanel]`
     - `hidesOnDeactivate = true`（失活时自动关闭）
     - `isFloatingPanel = false`
     - 标题：实例的 `displayName`
   - 内容视图：`NSHostingView(rootView: UsageCardView(slot: slotData))`
   - 窗口尺寸：宽 350pt，高自适应
3. 提供 `show(for instanceUUID: String)`：
   - 从 `AppStateProxy.slotViewDataList` 中根据 `uuid` 查找对应 `SlotViewData`
   - 创建 Panel 并显示
   - 若找不到 → 记录日志
4. 确保 `NSPanel` 生命周期管理正确：
   - 失活自动关闭后 `NSWindowController` 释放
   - 同一实例重复点击通知 → 关闭旧 Panel 再打开新的（或重用）

**输出文件**：
- `APIUsageStatus/Views/InstanceDetailPanel.swift`

**验证标准**：
- [ ] 编译通过
- [ ] 调用 `show(for:)` → 独立 NSPanel 窗口显示指定实例的 UsageCardView
- [ ] NSPanel 标题为实例显示名
- [ ] 点击 Panel 外部 → 自动关闭
- [ ] 同时打开 Popover 和 NSPanel → 两者独立显示，互不影响
- [ ] NSPanel 关闭后窗口控制器正确释放

**需求追溯**：
- PRD: §3.5（点击通知打开独立用量详情面板）、§4（通知 → NSPanel）
- ARCHITECTURE: §2.4（InstanceDetailPanel 设计）、ADR-008

---

### T-6.3 连接通知开关 + 集成 NotificationManager 到 RefreshService

**所属阶段**：Phase 6  
**预估工时**：4h  
**前置任务**：T-6.1, T-6.2, T-1.9, T-4.4

**输入**：
- T-6.1 产出的 `NotificationManager`
- T-6.2 产出的 `InstanceDetailPanel`
- T-1.9 产出的 `RefreshService`（刷新编排）
- T-4.4 产出的 `SettingsViewModel`（通知开关读写）

**工作内容**：
1. 修改 `RefreshService.swift`（在 T-5.2 修改的基础上）：
   a. 在 `performRefresh()` 的末尾（更新 AppState 后、设置 `refreshState = .idle` 前）：
      - 调用 `NotificationManager.evaluateThresholds(...)`
   b. 注入 `NotificationManager` 依赖
2. 修改 `SettingsViewModel`（或 `SettingsView`）：
   a. 连接「通知」Toggle 的实际逻辑：
      - 保存 `notificationsEnabled` 到 `GlobalSettings`
      - 若从关闭切换到开启 → 调用 `NotificationManager.requestPermission()`
3. 在 `AppDelegate.applicationDidFinishLaunching` 中：
   a. 设置 `UNUserNotificationCenter.current().delegate` 为 `NotificationManager`
   b. 若 `notificationsEnabled == true` → 调用 `requestPermission()`
4. 连接通知点击到 `InstanceDetailPanel`：
   - `NotificationManager` 的 `UNUserNotificationCenterDelegate` 方法中 → 提取 `instance_uuid` → 调用 `InstanceDetailPanel.show(for:)`

**输出文件**：
- `APIUsageStatus/Services/RefreshService.swift`（修改）
- `APIUsageStatus/Views/SettingsViewModel.swift`（修改）
- `APIUsageStatus/APIUsageStatusApp.swift`（修改 — 注册通知 delegate）

**验证标准**：
- [ ] 编译通过
- [ ] 每次刷新完成后自动评估阈值
- [ ] 超过严重线 → 系统通知弹出
- [ ] 通知关闭 → 刷新完成后不触发通知
- [ ] 通知开启但首次未授权 → 再次提示请求权限
- [ ] 点击通知 → InstanceDetailPanel 正确打开对应实例详情
- [ ] 多次刷新同一实例持续超过严重线 → 每次都触发通知（V1 行为，后续可优化去重）

**需求追溯**：
- PRD: §3.1（严重阈值通知）、§3.5（通知开关）、§4（通知交互流程）
- ARCHITECTURE: §2.12（NotificationManager 集成）、§3.1（启动流程 — 通知权限请求）、§3.2（刷新周期 — 阈值评估步骤）

---

## Phase 7：打磨与收尾

| 任务编号 | 任务名称 | 所属模块 | 预估工时 | 前置依赖 |
|----------|----------|----------|----------|----------|
| T-7.1 | 实现 SMAppService 开机自启 + AppLaunchService | 服务层 | 3h | T-4.4 |
| T-7.2 | 优化闪烁动画稳定性（Timer 生命周期验证） | 菜单栏渲染 | 3h | T-2.4 |
| T-7.3 | 验证边缘情况错误恢复 | 全模块 | 4h | 所有 Phase 0–6 任务 |
| T-7.4 | 编写核心单元测试（BalanceCalculator / Parser / RetryPolicy） | 测试 | 6h | T-5.1, T-1.6, T-1.7, T-1.4 |
| T-7.5 | 编写 PixelFontEngine 测试 + MenuBarIconRenderer 快照测试 | 测试 | 4h | T-2.3, T-2.4 |
| T-7.6 | 性能验证（启动时间 / CPU / 内存 / Instruments 分析） | 全模块 | 4h | 所有 Phase 0–6 任务 |
| T-7.7 | 部署验证（ad-hoc 签名 / xattr / SMAppService / 24h 稳定性） | 部署 | 3h | 所有 Phase 0–7 任务 |

---

### T-7.1 实现 SMAppService 开机自启 + AppLaunchService

**所属阶段**：Phase 7  
**预估工时**：3h  
**前置任务**：T-4.4

**输入**：
- T-4.4 产出的 `SettingsViewModel`（开机自启 Toggle 已存在但无实际功能）
- `SMAppService` API（macOS 13+）

**工作内容**：
1. 创建 `Services/AppLaunchService.swift`：
   - 封装 `SMAppService.mainApp` 的 `register()` 和 `unregister()` 方法
   - 错误处理：`register()` 失败时记录日志并向用户显示提示
   - 封装 `var isRegistered: Bool { get }` 状态查询
2. 修改 `SettingsViewModel`：
   - 连接「Launch at Login」Toggle 的实际逻辑：
     - 勾选 → `AppLaunchService.register()`
     - 取消 → `AppLaunchService.unregister()`
3. 在 `APIUsageStatusApp.swift` 的 `applicationDidFinishLaunching` 中：
   - 若 `settings.launchAtLogin == true` → 确保注册状态一致
4. 处理 ad-hoc 签名下的兼容性：部分 macOS 版本可能限制非签名 app 的 `SMAppService`，若受限则降级为 `LSSharedFileList` 方案作为后备

**输出文件**：
- `APIUsageStatus/Services/AppLaunchService.swift`
- `APIUsageStatus/Views/SettingsViewModel.swift`（修改）

**验证标准**：
- [ ] 编译通过
- [ ] 勾选「Launch at Login」→ 系统偏好设置中「登录项」出现 `APIUsageStatus`
- [ ] 取消勾选 → 登录项中移除
- [ ] 重启 Mac → 应用自动启动（在「登录项」中可见）
- [ ] ad-hoc 签名下功能正常（macOS 13+）

**需求追溯**：
- PRD: §3.5（通用设置 — 开机自启）、§8.2（SMAppService 在 ad-hoc 签名下工作）
- ARCHITECTURE: §2.1（应用入口注册 SMAppService）、§3.1（启动流程）

---

### T-7.2 优化闪烁动画稳定性（Timer 生命周期验证）

**所属阶段**：Phase 7  
**预估工时**：3h  
**前置任务**：T-2.4

**输入**：
- T-2.4 产出的 `MenuBarIconRenderer`（闪烁动画基础实现）
- ARCHITECTURE §7.4（闪烁动画设计）、§11.4（Timer 管理）

**工作内容**：
1. 审查 `MenuBarIconRenderer.swift` 中的 `Timer` 使用：
   a. 确保 `Timer` 使用 `weak self` 避免循环引用
   b. 确保 `Timer.invalidate()` 在以下场景被调用：
      - 槽位退出严重状态（`colorState != .critical`）→ 自动停止
      - 实例被禁用/删除 → 停止对应槽位闪烁
      - 应用进入后台/终止 → 停止所有闪烁
      - `MenuBarController.deinit` → 停止所有 Timer
   c. 验证长时间运行（>1 小时）下 Timer 无泄漏
2. 边界情况处理：
   a. 两个槽位同时达到严重线 → 两个 Timer 独立运行，互不干扰
   b. 色彩模式切换（彩色 → 单色）→ 单色模式下闪烁逻辑仍然工作（进度条编码阈值 + 闪烁）
3. 考虑将 `Timer` 替换为 `Task.sleep` 循环（与 RefreshService 保持一致）：
   - 优点：与结构化并发更兼容，取消传播自动
   - 注意：`MenuBarIconRenderer` 在 `@MainActor` 上运行，`Task` 在主 Actor 上执行不会引起线程问题
   - 若替换：`Timer.scheduledTimer` → `Task { while true { try await Task.sleep(for: .seconds(1)); ... } }`
4. 验证闪烁不会导致菜单栏 CPU 飙升（应 <1%）

**输出文件**：
- `APIUsageStatus/MenuBar/MenuBarIconRenderer.swift`（修改/优化）

**验证标准**：
- [ ] 编译通过
- [ ] 实例达到严重线 → 1Hz 闪烁正常
- [ ] 实例恢复安全状态 → 闪烁自动停止
- [ ] 应用运行 1 小时后 → Instruments 无 Timer 泄漏
- [ ] 两个槽位同时闪烁 → 独立运行
- [ ] 切换色彩模式 → 闪烁按新模式规则运行
- [ ] 应用终止 → 无残留 Timer（通过 Instruments 验证）

**需求追溯**：
- PRD: §3.1（严重阈值 1Hz 闪烁）
- ARCHITECTURE: §7.4（闪烁动画）、§11.4（Timer 管理）

---

### T-7.3 验证边缘情况错误恢复

**所属阶段**：Phase 7  
**预估工时**：4h  
**前置任务**：所有 Phase 0–6 任务

**输入**：
- 所有已实现模块
- ARCHITECTURE §10（错误处理策略）、§10.4（启动弹性）

**工作内容**：
1. 逐一验证以下边缘情况的恢复行为：
   a. **网络恢复后自动重试**：
      - 断开网络 → 等待刷新失败 → 恢复网络 → 下次定时刷新自动成功
      - 验证指数退避重试在此场景正常工作
   b. **沙盒容器路径变化**：
      - 模拟 Sandbox 容器路径不可用（如迁移到新 Mac 但数据未迁移）
      - → 应用以空配置启动，不崩溃
   c. **Keychain 访问失败**：
      - 模拟 Keychain 读取异常（通过权限不足或手动损坏条目）
      - → 对应实例视为已禁用（`ErrorSummary.authFailed`），其他实例正常
      - → 日志记录 `.fault` 级别
   d. **`instances.json` 损坏**：
      - 手动写入畸形 JSON → 启动时 `.fault` 日志 + 降级为空配置
      - 验证空配置下显示 `?`，用户可通过设置重新配置
   e. **`{uuid}.json` 损坏**：
      - 写入畸形余额历史 → 下次刷新时检测到，重置基线
      - 验证日志记录 `.fault`，新基线正常建立
2. 手动测试清单：
   - 所有场景记录在 TASKS.md 的验证标准中，逐一勾选

**输出文件**：
- 无新增文件；修改已知问题的 Bug 修复（如有）

**验证标准**：
- [ ] 网络中断 5 分钟后恢复 → 下次刷新自动成功（< 10 分钟）
- [ ] `instances.json` 损坏 → 应用以空配置启动，显示 `?`
- [ ] `instances.json` 缺失 → 同上
- [ ] Keychain 条目损坏 → 对应实例产生 ErrorSummary，其他实例正常
- [ ] 余额历史 JSON 损坏 → 基线重置，日志记录错误
- [ ] 所有上述场景下应用不崩溃、不卡死

**需求追溯**：
- PRD: §5（可靠性 — 网络异常优雅降级）
- ARCHITECTURE: §10（错误处理策略）、§10.4（启动弹性）、§3.1（启动流程）

---

### T-7.4 编写核心单元测试（BalanceCalculator / Parser / RetryPolicy）

**所属阶段**：Phase 7  
**预估工时**：6h  
**前置任务**：T-5.1, T-1.6, T-1.7, T-1.4

**输入**：
- T-5.1 产出的 `BalanceCalculator`（纯函数，天然可测）
- T-1.6 产出的 `MiniMaxResponseParser`
- T-1.7 产出的 `DeepSeekResponseParser`
- T-1.4 产出的 `RetryPolicy`

**工作内容**：
1. 创建测试文件组织：
   - `APIUsageStatusTests/BalanceCalculatorTests.swift`
   - `APIUsageStatusTests/MiniMaxResponseParserTests.swift`
   - `APIUsageStatusTests/DeepSeekResponseParserTests.swift`
   - `APIUsageStatusTests/RetryPolicyTests.swift`
2. **BalanceCalculatorTests**（覆盖所有边界情况）：
   - 正常消耗：`latest = "100.00"` → `current = "95.00"` → `todayUsage` 增加 `"5.00"`
   - 跨日归档：切换 `todayDate` → 昨日数据写入 `history`
   - 首次刷新：`latestSnapshot = nil` → 基线建立，消耗为 0
   - 充值检测：`current > latest` → 消耗为 0，`lastTopupDate` 更新
   - 余额不变：`current == latest` → 消耗为 0
   - 日均消耗：4 种周期正确筛选历史数据并计算平均值
   - 历史裁剪：`retentionDays` 不同值下的裁剪结果
   - 精度验证：`Decimal` 运算精度
3. **MiniMaxResponseParserTests**（使用真实 API 响应样本）：
   - 从真实 API 调用中获取一份 JSON 响应样本（保存为测试 fixture）
   - 验证解析后各维度字段正确映射
   - 验证缺少字段时的错误处理
   - 验证响应格式变更时的解析失败行为
4. **DeepSeekResponseParserTests**（使用真实 API 响应样本）：
   - 正常响应解析（`is_available: true`，多币种记录）
   - `is_available: false` 解析
   - 优先取 CNY 记录逻辑
   - 无 CNY 时取第一条逻辑
   - 畸形 JSON 解析失败
5. **RetryPolicyTests**：
   - 验证首次失败立即重试
   - 验证第 2 次重试延迟（1s + jitter）
   - 验证第 3 次重试延迟（2s + jitter）
   - 验证全部失败后抛出错误
   - 验证首次成功不重试

**输出文件**：
- `APIUsageStatusTests/BalanceCalculatorTests.swift`
- `APIUsageStatusTests/MiniMaxResponseParserTests.swift`
- `APIUsageStatusTests/DeepSeekResponseParserTests.swift`
- `APIUsageStatusTests/RetryPolicyTests.swift`

**验证标准**：
- [ ] 所有测试编译通过
- [ ] `BalanceCalculatorTests`：12+ 测试用例全部通过，覆盖所有边界条件
- [ ] `MiniMaxResponseParserTests`：使用真实响应样本的解析测试通过
- [ ] `DeepSeekResponseParserTests`：正常响应 + 边界情况（`is_available: false`、多币种、畸形 JSON）全部通过
- [ ] `RetryPolicyTests`：退避延迟、重试次数、成功快速返回测试通过

**需求追溯**：
- PRD: §5（非功能性需求 — 可靠性）、§7（成功指标）
- ARCHITECTURE: §14.6（可测试性）、§2.13（BalanceCalculator 测试重点）、§6.3（RetryPolicy 测试）
- DEVELOPMENT_PLAN: Phase 7 §7d 测试

---

### T-7.5 编写 PixelFontEngine 测试 + MenuBarIconRenderer 快照测试

**所属阶段**：Phase 7  
**预估工时**：4h  
**前置任务**：T-2.3, T-2.4

**输入**：
- T-2.3 产出的 `PixelFontEngine`
- T-2.4 产出的 `MenuBarIconRenderer`

**工作内容**：
1. 创建 `APIUsageStatusTests/PixelFontEngineTests.swift`：
   - 验证每个字母/数字/符号的渲染输出位图与预期位图一致（`renderChar("A", ...)` vs `CharMapLetters` 中的 `"A"` 位图）
   - 验证 `renderText` 水平拼接逻辑（字符间距、顺序）
   - 验证不同 `CharSize` 下的渲染结果
   - 验证未知字符的跳过处理（不崩溃）
2. 创建 `APIUsageStatusTests/MenuBarIconRendererTests.swift`（快照测试）：
   - 使用 Mock `AppStateProxy` 数据构建各种场景：
     - 0 实例 → 捕获渲染结果（`?` 图标）
     - 1 配额型实例（安全状态、彩色模式）
     - 1 余额型实例（警告状态、单色模式）
     - 2 实例混合（配额型 + 余额型）
     - 全部禁用（`NO API` 状态）
     - 加载中（`•••` 状态）
   - 每种场景渲染为 `NSImage` → 转为 `PNG` 数据 → 与参考图像对比
   - 参考图像首次运行时生成（Golden Master 模式）
   - 使用 `XCTAssert` 比较 PNG 数据字节（或 `NSImage` 像素级对比）

**输出文件**：
- `APIUsageStatusTests/PixelFontEngineTests.swift`
- `APIUsageStatusTests/MenuBarIconRendererTests.swift`
- 参考图像（`APIUsageStatusTests/ReferenceImages/` 目录下）

**验证标准**：
- [ ] `PixelFontEngineTests`：覆盖全部 43 个字符（A–Z + 10 个数字 + 7 个符号）+ 拼接逻辑，全部通过
- [ ] `MenuBarIconRendererTests`：6+ 种场景的快照测试通过
- [ ] 若未来 PixelFontEngine 或渲染逻辑变更 → 测试失败（防止回归）
- [ ] 参考图像提交到 Git（二进制文件）

**需求追溯**：
- PRD: §3.1（像素字模渲染要求）
- ARCHITECTURE: §8（像素字模系统设计）、§14.6（可测试性 — 快照测试）

---

### T-7.6 性能验证（启动时间 / CPU / 内存 / Instruments 分析）

**所属阶段**：Phase 7  
**预估工时**：4h  
**前置任务**：所有 Phase 0–6 任务

**输入**：
- 完整应用（所有功能已实现）
- Xcode Instruments（Time Profiler, Allocations, Leaks）
- PRD §7（成功指标）

**工作内容**：
1. **启动时间验证**：
   - 使用 `xcodebuild` 或 Xcode 测量冷启动到首次菜单栏图标展示的时间
   - 目标：< 3s
   - 若超标：使用 Time Profiler 定位热点 → 优化（延迟初始化非关键服务、减少启动时 I/O）
2. **CPU 占用验证**：
   - 应用空闲状态（不刷新，仅后台运行）→ 打开活动监视器
   - 目标：平均 CPU < 1%
   - 若超标：Time Profiler 定位 → 可能原因：Timer 频率过高、SwiftUI 重绘频繁、像素渲染未缓存
3. **内存常驻验证**：
   - 应用运行 1 小时后 → Xcode Memory Graph / Instruments Allocations
   - 目标：< 50MB
   - 若超标：Allocations 定位 → 可能原因：余额历史无限增长、NSImage 缓存未释放、Combine 订阅泄漏
4. **Instruments 完整分析**：
   - Time Profiler：CPU 热点分析
   - Allocations：内存分配热点分析
   - Leaks：内存泄漏检测（Timer、Combine 订阅、NSWindow/NSPanel 生命周期）
   - App Launch：启动时间测量
5. 记录所有发现问题的修复

**输出文件**：
- 无新增文件；记录优化修改和性能测试结果

**验证标准**：
- [ ] 冷启动到首次图标展示 < 3s
- [ ] 空闲状态 CPU < 1%（活动监视器平均）
- [ ] 运行 1 小时后内存 < 50MB
- [ ] Instruments Leaks 无内存泄漏（Timer / Combine / NSWindow）
- [ ] 刷新期间 CPU 峰值 < 5%（HTTP 请求 + 解析 + 渲染）

**需求追溯**：
- PRD: §7（成功指标 — 启动 < 3s / CPU < 1% / 内存 < 50MB）
- ARCHITECTURE: §14.1（性能分析）、§14.2（可靠性）

---

### T-7.7 部署验证（ad-hoc 签名 / xattr / SMAppService / 24h 稳定性）

**所属阶段**：Phase 7  
**预估工时**：3h  
**前置任务**：所有 Phase 0–7 任务

**输入**：
- 完整应用（Release 构建）
- PRD §8（自用部署要求）

**工作内容**：
1. **ad-hoc 签名验证**：
   - `xcodebuild -project APIUsageStatus.xcodeproj -scheme APIUsageStatus -configuration Release build`
   - 验证构建成功的 `.app` 签名信息：`codesign -dvvv APIUsageStatus.app`
   - 确认签名 Identity 为 `-`（ad-hoc）
2. **Gatekeeper 绕过验证**：
   - 将 `.app` 复制到 `/Applications/`
   - 首次打开（可能需要右键 →「打开」绕过 Gatekeeper）
   - 验证 `xattr -cr APIUsageStatus.app` 命令可作为备选方案
3. **SMAppService 验证**：
   - 在设置中开启「Launch at Login」
   - 重启 Mac → 验证应用自动启动
   - ad-hoc 签名下 SMAppService 是否正常工作
4. **macOS 13 24h 稳定性测试**：
   - 在 macOS 13 实体机上运行应用 24 小时
   - 期间保持至少 1 个实例配置（如 DeepSeek 余额监控）
   - 验证 24 小时后：
     - 无崩溃
     - 无内存泄漏（活动监视器内存趋势平稳）
     - 菜单栏图标持续更新
     - 定时刷新正常工作
     - 通知正常触发
5. **本地部署流程整体验证**（按 PRD §8.3 的步骤完整走一遍）：
   ```bash
   git clone <repo> && cd api-usage-check
   xcodebuild -project APIUsageStatus.xcodeproj -scheme APIUsageStatus -configuration Release build
   open -a APIUsageStatus
   ```
   - 验证每个步骤的可执行性

**输出文件**：
- 无新增文件；记录部署验证结果

**验证标准**：
- [ ] Release 构建 ad-hoc 签名（签名身份 `-`）
- [ ] 右键 →「打开」可绕过 Gatekeeper
- [ ] `xattr -cr` 命令可清除隔离标记
- [ ] SMAppService 开机自启在 ad-hoc 签名下工作正常
- [ ] macOS 13 上 24 小时运行无崩溃
- [ ] 24 小时后内存趋势平稳（无持续增长）
- [ ] PRD §8.3 的 4 步本地部署流程可完整执行

**需求追溯**：
- PRD: §8（自用部署要求 — ad-hoc 签名 / Gatekeeper / SMAppService / 本地部署流程）
- ARCHITECTURE: 附录 A（Entitlements 配置）、附录 B（最低部署目标）

---

## 任务统计汇总

| 阶段 | 任务数 | 总预估工时 |
|------|--------|------------|
| Phase 0：可行性原型 | 3 | 12h |
| Phase 1：核心数据管道 | 11 | 50h |
| Phase 2：菜单栏图标渲染 | 5 | 27h |
| Phase 3：Popover 用量面板 | 3 | 16h |
| Phase 4：设置窗口 | 5 | 24h |
| Phase 5：余额跟踪 | 3 | 16h |
| Phase 6：通知系统 | 3 | 14h |
| Phase 7：打磨与收尾 | 7 | 27h |
| **合计** | **40** | **186h** |

> **换算参考**：186h ≈ 23–31 工程师人天（6–8h/天）≈ 10–12 周（按业余时间每周 15–18h 有效编码时间）。

### 各阶段可并行任务统计

| 阶段 | 可并行组数 | 最大并行度 |
|------|-----------|-----------|
| Phase 1 | 3 组 | T-1.1、T-1.2、T-1.11 可同时进行；Layer 2 中 T-1.3、T-1.4、T-1.5、T-1.8 可并行；T-1.6 与 T-1.7 可并行 |
| Phase 2 | 1 组 | T-2.1 与 T-2.2 可并行 |
| Phase 4 | 1 组 | — |
| Phase 5 | 1 组 | — |
| Phase 6 | 1 组 | T-6.1 与 T-6.2 可并行 |
| Phase 7 | 3 组 | T-7.1、T-7.4、T-7.5 可并行；T-7.3、T-7.6 可并行 |
