# Kimi 会员套餐用量接口说明

> 文档目的：说明 Kimi `Supplier` 的数据源选择、API 接口、响应解析、双窗口维度模型，以及与项目其它模块的耦合点。
> 编写日期：2026-07-19
> 实现源码：
> - `APIUsageStatus/Suppliers/KimiSupplier.swift`
> - `APIUsageStatus/Suppliers/KimiResponseParser.swift`

---

## 1. 结论先行

| 维度 | 说明 |
|------|------|
| 数据源 | 远端 HTTPS API（`api.kimi.com/coding/v1/usages`，即 Kimi Code CLI `/usage` 面板的后端端点） |
| 认证方式 | Bearer Token（Kimi Code Console 创建的 API Key，存 Keychain） |
| 监控粒度 | **单实例双窗口**（固定 group `kimi`：5h 滚动窗口 + weekly 周配额） |
| 配额类型 | 周期配额型（百分比 + `end_time` 倒计时，与 MiniMax 契约一致） |
| 无限套餐 | 周配额 limit ≤ 0 或 `usage` 块缺失时按无限处理（flowing glow bar） |
| 模块独立性 | 通过 `Supplier` 协议接入；`RefreshService` 零改动 |

**数据源选型（2026-07-19 调研）**：
- 官方帮助文档《如何查看 Kimi API 余额和用量》指向的是 `api.moonshot.cn/v1/users/me/balance` —— 那是**开放平台按量付费账户**的余额（available/voucher/cash 三个金额），与会员套餐用量是两个产品，数据粒度也粗得多，未采用。
- `kimi` CLI **没有** `usage` 子命令；`/usage` 是 TUI 内斜杠命令面板，`kimi -p "/usage"` 不会执行（实测被当成普通消息发给 Agent）。但其面板数据来自真实 HTTP 端点 `GET https://api.kimi.com/coding/v1/usages`，可直接调用——本实现即采用该端点。

---

## 2. 模块组成

```
Suppliers/
├── Supplier.swift               # Supplier 协议 + Provider 枚举（.kimi）
├── KimiSupplier.swift           # HTTP 请求 + 委托给 Parser
├── KimiResponseParser.swift     # 响应解析 + 双窗口 rawData 构造
└── SupplierRegistry.swift       # Provider → Supplier 的工厂映射
```

**职责分层**：与 MiniMax / DeepSeek 完全一致 —— Supplier 只拼装 `Endpoint`、调 `NetworkClient.request`（自动注入 `Authorization: Bearer <apiKey>`），Parser 只做 JSON → `SupplierResponse`。

---

## 3. HTTP 接口

### 3.1 端点

```
GET https://api.kimi.com/coding/v1/usages
Authorization: Bearer <kimiCodeConsoleApiKey>
```

没有 query 参数、没有 body。该端点同时接受两种凭证：
1. **Kimi Code Console 创建的 API Key**（本实现使用；Console 地址 https://www.kimi.com/code/console，与第三方工具接入 `api.kimi.com/coding/v1` 使用的是同一类 Key）
2. `kimi login` 的 OAuth access_token（存于 `~/.kimi-code/credentials/kimi-code.json`，约 1 小时过期，需 refresh 流程）——未采用，避免与 CLI 内部存储格式耦合

### 3.2 响应结构（2026-07-19 实测捕获）

```json
{
  "user": { "userId": "...", "region": "REGION_CN", "membership": { "level": "LEVEL_INTERMEDIATE" } },
  "usage": { "limit": "100", "used": "1", "remaining": "99", "resetTime": "2026-07-26T05:20:54.627714Z" },
  "limits": [
    { "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
      "detail": { "limit": "100", "used": "6", "remaining": "94", "resetTime": "2026-07-19T10:20:54.627714Z" } }
  ],
  "parallel": { "limit": "20" },
  "totalQuota": { "limit": "100", "remaining": "99" },
  "authentication": { "method": "METHOD_ACCESS_TOKEN", "scope": "FEATURE_CODING" },
  "subType": "TYPE_PURCHASE"
}
```

### 3.3 字段含义

| 字段 | 说明 |
|------|------|
| `usage` | **周配额窗口**（订阅日起每 7 天刷新）。`limit` / `used` / `remaining` 为 **JSON string** 数字；`resetTime` 为带小数秒（实测 6 位）的 ISO 8601 |
| `limits[]` | **滚动限流窗口**数组。每个元素的 `window` 描述窗口（实测为 300 分钟 = 5h），`detail` 同 `usage` 结构 |
| `user.membership.level` | 会员等级（如 `LEVEL_INTERMEDIATE`），仅作展示/调试 |
| `parallel.limit` | 并发上限，仅作展示/调试 |
| `totalQuota` | 与 `usage` 重复的汇总视图，未使用 |

**关键设计点**：
- **用量百分比 = `used / limit * 100`**（API 不直接给百分比）。limit ≤ 0 视为窗口不生效：周报无限、5h 报 0%
- **`limits[]` 按 `window.duration == 300 && timeUnit == "TIME_UNIT_MINUTE"` 定位 5h 窗口**，找不到时兜底取第一个元素（窗口形态未来可能演进），数组为空则 5h 报 0%
- **`resetTime` 解析失败不抛错**，写 `end_time = 0`，`RefreshService` 视为"无倒计时"（与 Copilot parser 的语义一致）

---

## 4. 解析后的 `rawData` 契约

固定 group = `kimi`，完全对齐 MiniMax 的 rawData 键约定，因此 `RefreshService` / `SlotViewData` / 菜单栏渲染全部零改动复用：

| 键 | 值 | 消费方 |
|----|----|--------|
| `kimi` | 5h 已用百分比（`"%.1f"`） | `MetricConfig(key: "kimi", group: "kimi", window: "5h")` 的主值 |
| `kimi:status` | `"1"` = 5h 窗口存在，`"0"` = 无 | 调试 |
| `kimi:remaining` | 5h 剩余百分比 | 调试/详情 |
| `kimi:end_time` | 5h `resetTime` 的 epoch 毫秒（无则 `"0"`） | `RefreshService` → `cycleEndTime` 倒计时 |
| `kimi:weekly_percent` | 周已用百分比 | `MetricConfig(key: "kimi:weekly_percent", group: "kimi", window: "weekly")` 的主值 |
| `kimi:weekly_status` | `"1"` = 有限额，`"0"` = 无限（limit ≤ 0 或 `usage` 缺失） | `RefreshService` 无限判定（≠ 1 → flowing glow bar，百分比记 0） |
| `kimi:weekly_remaining` | 周剩余百分比 | 卡片 `slot.weekly` |
| `kimi:weekly_percent:end_time` | 周 `resetTime` 的 epoch 毫秒 | 周窗口倒计时（键名是 `RefreshService` 对 weekly metric 的标准查询格式） |
| `kimi:membership` | 会员等级字符串（可选） | 调试/未来详情面板 |
| `kimi:parallel_limit` | 并发上限（可选） | 调试/未来详情面板 |

**严格性（对齐 Copilot parser）**：窗口块存在但 `limit` / `used` 缺失或非数值时**抛 `RefreshError.parsingError`** —— 不静默默认 0，避免 API 变更时触发假告警。整块缺失才走 0% / 无限语义（对齐 MiniMax parser 的 "no quota tracked"）。

---

## 5. 与 `Supplier` 协议的对应

```swift
struct KimiSupplier: Supplier {
    let provider: Provider = .kimi
    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        let response = try await networkClient.request(endpoint, apiKey: apiKey)
        return try parser.parse(response)
    }
}
```

实例 metrics 由 `InstanceEditorView` 固定生成（无自动发现，与 MiniMax 的 `_model_names` 机制不同——Kimi 只有一个固定 group）：

```swift
MetricConfig(key: "kimi", group: "kimi", window: "5h")
MetricConfig(key: "kimi:weekly_percent", group: "kimi", window: "weekly")
```

编辑器里两个窗口各自可勾选/取消，可分别配 2-3 位菜单栏短名（复用 MiniMax 的 `metricShortNameField`）。

---

## 6. 上层消费路径

```
RefreshService
   ↓ SupplierRegistry.getSupplier(for: .kimi) → KimiSupplier
   ↓ supplier.fetchUsage(apiKey:)  → SupplierResponse
   ↓ mapInstanceToSlotData 按 metrics 遍历（通用 quota 路径，无 provider 分支）
   ↓ MetricSnapshot(5h, weekly) → SlotViewData
   ↓ UsageCardView.multiMetricContent → flatMetricContent（非 MiniMax 不走分组）
   ↓ MenuBarIconRenderer（每个 displayInMenuBar 的 metric 一个槽位）
```

**关键耦合点**：
- `Views/UsageCardView.swift` 的 `providerURL`：`.kimi` → `https://www.kimi.com/code/console`
- `Views/InstanceEditorView.swift`：`kimiMetricsList`（OpenCode 风格的双窗口开关列表）、`apiKeyPlaceholder`、`resetMetricsForProvider` 三处分支
- `Extensions/Provider+Icon.swift`：`moon.stars`
- 凭据存储：复用 `KeychainService`（service = "APIUsageStatus"，apiKeyRef = UUID），与其它供应商一致

---

## 7. 错误处理

| 错误来源 | 抛出 | 映射 |
|---------|------|------|
| JSON 解析失败 | `RefreshError.parsingError("Invalid JSON from Kimi API")` | UI 显示"解析失败" |
| 窗口块存在但 `limit`/`used` 缺失或非数值 | `RefreshError.parsingError(...)` | 同上（故意严格，防止假数据触发误报） |
| `limits` 空 / `usage` 缺失 | **不抛错**，5h 报 0%、周报无限 | 正常展示 |
| `resetTime` 缺失/不可解析 | **不抛错**，`end_time = "0"` | 无倒计时，其余正常 |
| HTTP 401（Key 无效/过期） | `NetworkClient` 抛 `httpError(statusCode: 401)` | UI 显示"鉴权失败" |

---

## 8. 测试覆盖

`APIUsageStatusTests/KimiResponseParserTests.swift` — **11 个测试用例**：

- 实测响应正常解析（string 数字、6 位小数秒 resetTime、双窗口、membership/parallel）
- JSON number 容错（非 string 数字）
- `limits`/`usage` 整块缺失 → 0% + 无限语义
- 周 limit = 0 → 无限
- 300 分钟窗口定位（乱序数组）与未知窗口兜底取首条
- resetTime 无小数秒解析、不可解析写 0
- `limit` 非数值 / `used` 缺失 / 非法 JSON → 抛 parsingError

---

## 9. 风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| `/usages` 端点未出现在公开 API 文档（CLI 面板后端） | 端点可能改版 | 解析只依赖核心字段（limit/used/resetTime）；块级缺失走 0%/无限而非崩溃；关键字段缺失抛清晰 parsingError |
| Console API Key 对 `/usages` 的兼容性未逐 Key 验证（调研时手头无 Key，OAuth token 实测 200） | 首次接入可能 401 | UI 显示"鉴权失败"，引导用户到 Console 重建 Key；备选方案是读 CLI OAuth 凭证（需实现 refresh，见 §1） |
| limit/used 单位变化（如从配额点数改为 token 数） | 百分比仍正确（used/limit 比值不变），但绝对值不可解读 | 当前 UI 只展示百分比，与 MiniMax 一致 |
| 新会员体系上线（官方已预告套餐权益拆分） | 响应结构可能变化 | 解析容错 + 严格字段校验会在刷新失败时显式报错，不会静默显示错数据 |
