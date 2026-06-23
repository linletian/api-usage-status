# GitHub Copilot 套餐用量接口说明

> 文档目的：说明 Copilot 用量数据的来源、查询方式、以及在 `Supplier` 协议下的落地设计。
> 编写日期：2026-06-13
> API 调研起点：[tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar) —— 该仓库的 Copilot 子系统是 `/copilot_internal/user` 端点和 PAT 要求的早期发现来源,但本项目实际 `Supplier` 实现与 ClaudeBar 协议不同,见第 3 节说明。

---

## 1. 结论先行

| 问题 | 答案 |
|------|------|
| 个人账户能查吗？ | **能** |
| 有公开的 HTTP 用量接口吗？ | **有，但藏在 Billing / Internal 分类下，不在 "Copilot Usage" 分类** |
| 是否可以套用现有 `Supplier` 协议？ | **可以**（标准 HTTP `Supplier` 路径） |
| 落地成本 | 低 — 一个 `CopilotSupplier.swift` + Settings 加 PAT 输入框 + Keychain 复用 |

之前调研方向反了：把搜索词放在 "Copilot usage API" 上，GitHub 没有这个分类。真正的入口是 **Billing API** 和 **Copilot Internal API**。

---

## 2. 两个候选端点

ClaudeBar 实现了双探针模式（[CopilotUsageProbe.swift](https://github.com/tddworks/ClaudeBar/blob/main/Sources/Infrastructure/Copilot/CopilotUsageProbe.swift) 和 [CopilotInternalAPIProbe.swift](https://github.com/tddworks/ClaudeBar/blob/main/Sources/Infrastructure/Copilot/CopilotInternalAPIProbe.swift)），让用户在 Settings 里切换。本项目只需二选一，建议默认 Internal（覆盖度更广）。

### 2.1 Copilot Internal API（推荐）

```
GET https://api.github.com/copilot_internal/user
Authorization: Bearer <classic PAT, 需要 "copilot" scope>
Accept: application/json
```

**响应示例**（截取）：

```json
{
  "copilot_plan": "pro",
  "quota_reset_date_utc": "2026-07-01T00:00:00Z",
  "quota_snapshots": {
    "premium_interactions": {
      "entitlement": 300,
      "percent_remaining": 73.33,
      "remaining": 220,
      "unlimited": false,
      "overage_count": 0,
      "overage_permitted": false
    }
  }
}
```

**字段含义**：

| 字段 | 含义 |
|------|------|
| `entitlement` | 月度配额上限 |
| `remaining` | 剩余次数 |
| `percent_remaining` | 剩余百分比（首选渲染字段） |
| `unlimited` | true 时视为无限套餐（走项目的无限渲染分支） |
| `overage_count` / `overage_permitted` | 超额信息，可用于超额预警 |

**关键点**：
- 需要 **Classic PAT**（fine-grained 没有 `copilot` scope）
- 端点对**所有套餐通用**（Free / Pro / Pro+ / Business / Enterprise）
- 不需要 username，只用 token

### 2.2 GitHub Billing API（备选）

```
GET https://api.github.com/users/{username}/settings/billing/premium_request/usage
Authorization: Bearer <fine-grained PAT, 需要 "Plan: read" 权限>
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
```

**响应结构**（截取）：

```json
{
  "timePeriod": {"year": 2026, "month": 6},
  "user": "<username>",
  "usageItems": [
    {
      "product": "copilot",
      "model": "claude-3.7-sonnet",
      "grossQuantity": 42,
      "netQuantity": 38,
      "netAmount": 0.38
    }
  ]
}
```

**限制**：
- 需要 username
- 需要 fine-grained PAT 勾选 "Plan: read"
- **对 Business/Enterprise 通常返回空**（org 套餐不走个人 billing）
- 上限不返回，需要 Settings 里手动配（50/300/1000/1500 对应 Free/Pro/Business/Enterprise/Pro+）

### 2.3 双模式取舍

| 维度 | Internal API | Billing API |
|------|-------------|-------------|
| 套餐覆盖 | 全部 | 个人为主 |
| 上限数据 | API 直接返回 | 需用户配置 |
| 凭据类型 | Classic PAT | Fine-grained PAT |
| 实现复杂度 | 低（一次请求拿全部） | 中（要算 total + 处理空响应） |

**建议**：本项目**只实现 Internal API**。ClaudeBar 之所以做双模式，是为了让 Business/Enterprise 用户也能用——而本项目自用 Personal 套餐，单模式足矣。

---

## 3. 与现有 `Supplier` 协议的对应关系

> ⚠️ **以下代码块为 ClaudeBar 项目的设计草案,非本项目代码,不可直接套用。**
>
> ClaudeBar 的 `Supplier` 协议采用实例注入 + `fetch() -> UsageSnapshot` 模式,且自带 `APIInstance` / `HTTPClient` / `KeychainService` 等类型。本项目 `Supplier` 协议签名完全不同 —— 实际是 `func fetchUsage(apiKey: String) async throws -> SupplierResponse`,`NetworkClient` 是静态单例,Keychain 在 supplier 外部解析,响应解析由独立的 `CopilotResponseParser` 负责。代码块中的 `APIInstance` / `HTTPClient` / `UsageSnapshot` / `Self.makeSnapshot(...)` 等类型/方法在本项目都不存在。
>
> **本项目实际实现**:见 `APIUsageStatus/Suppliers/CopilotSupplier.swift` 和 `APIUsageStatus/Suppliers/CopilotResponseParser.swift`。

```swift
// === ClaudeBar 风格代码 —— 仅供端点行为参考,非本项目代码 ===
struct CopilotSupplier: Supplier {
    let instance: APIInstance
    let httpClient: HTTPClient
    let keychain: KeychainService

    func fetch() async throws -> UsageSnapshot {
        let token = try keychain.readToken(for: instance.id)
        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await httpClient.send(req)
        try Self.validate(response: response)

        let body = try JSONDecoder().decode(CopilotUserResponse.self, from: data)
        return Self.makeSnapshot(from: body)
    }
}
```

**本项目 `Copilot` 形态要点**(对应实际实现):
- 只有 monthly 一窗口,**重置时间优先取 API 响应里的 `quota_reset_date_utc` 字段**(ISO 8601 字符串,支持 `2026-07-01T00:00:00Z` 和 `2026-07-01T00:00:00.000Z` 两种格式)。`CopilotResponseParser` 在 parse 阶段把它解析为 epoch 毫秒并写入标准的 `<key>:end_time` rawData key,让 `RefreshService` 与其它供应商走同一套逻辑去算 `cycleEndTime` / `cycleRemainingSeconds`(与 `quota_reset_date_utc` 字符串 key 并存,保留供调试)。当 `quota_reset_date_utc` 缺失、为空或格式不可解析时,parser 回退到 `nextMonthlyResetMs()`(下个月第一天 UTC 零点)作为 `end_time`,确保倒计时始终有值——Copilot 配额均为自然月周期,回退值在下次 HTTP 刷新成功后自动被真实时间戳覆盖
- 无限套餐判定:`unlimited == true` 时,parser 写入 `:unlimited = "true"` 副键并把已用百分比统一记为 0(与 MiniMaxParser 对 `weekly_status != 1` 的处理一致);**本项目 Copilot 不渲染 flowing glow bar 动画**,菜单栏和面板的 0% 状态直接走正常颜色
- 凭据存储:复用现有 `KeychainService`,`service = "APIUsageStatus"`,以 `apiKeyRef`(UUID)为账号,没有 provider 专属 service 名

---

## 4. 配置面板设计

参考现有 Settings 卡片 + ClaudeBar 的 [CopilotConfigCard.swift](https://github.com/tddworks/ClaudeBar/blob/main/Sources/App/Views/Settings/CopilotConfigCard.swift) 思路：

**新增字段**：
- `APIKey`（Classic PAT，存 Keychain，service = "github-copilot"）
- 可选：`Username`（仅 Billing 模式需要）
- 可选：`MonthlyLimit`（仅 Billing 模式需要）

**UX 简化建议**（相比 ClaudeBar）：
- ClaudeBar 做了"凭据来源：env var vs 手动输入"的双输入模式，本项目**只需要手动输入**（自用 + 菜单栏应用不常跑 CI）
- 不做"Save & Test"按钮，复用现有"添加实例后自动首次拉取"的逻辑

---

## 5. 风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| `/copilot_internal/user` 端点未被官方文档正式推荐 | 端点可能改版 | 只用核心字段（`entitlement` / `remaining` / `percent_remaining`），其它字段作可选 |
| 套餐调整（GitHub 重命名为 "AI credits"） | 文案过时 | 解析时不硬编码 "premium requests"，从响应拿 `copilot_plan` 显示 |
| Business/Enterprise 套餐 | 返回结构可能不同 | 现阶段不做（自用 Personal 套餐） |
