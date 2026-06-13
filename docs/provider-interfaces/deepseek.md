# DeepSeek 套餐用量接口说明

> 文档目的：说明 DeepSeek `Supplier` 的实现结构、API 接口、响应解析、金额处理，以及与项目其它模块的耦合点。
> 编写日期：2026-06-13
> 实现源码：
> - `APIUsageStatus/Suppliers/DeepSeekSupplier.swift`
> - `APIUsageStatus/Suppliers/DeepSeekResponseParser.swift`

---

## 1. 结论先行

| 维度 | 说明 |
|------|------|
| 数据源 | 远端 HTTPS API（`/user/balance`） |
| 认证方式 | Bearer Token（API Key 存 Keychain） |
| 监控粒度 | **单实例单维度**（账户余额） |
| 配额类型 | 余额型（由 `Thresholds.balance` 驱动） |
| 多币种支持 | 是（CNY 优先 + 兜底取首条） |
| 账户停服状态 | 是（`is_available=false` 在 `SupplierResponse.isAvailable` 透出，UI 可显示禁用） |
| 模块独立性 | 通过 `Supplier` 协议接入；新增供应商不影响已有代码 |

---

## 2. 模块组成

```
Suppliers/
├── Supplier.swift                # Supplier 协议 + Provider 枚举
├── DeepSeekSupplier.swift        # HTTP 请求 + 委托给 Parser
├── DeepSeekResponseParser.swift  # 响应解析 + 币种选择 + rawData 构造
└── SupplierRegistry.swift        # Provider → Supplier 的工厂映射
```

**职责分层**：
- `DeepSeekSupplier` 只负责拼装 `Endpoint`、调 `NetworkClient.request`、把响应转给 Parser
- `DeepSeekResponseParser` 只负责 JSON → `SupplierResponse` 的转换

---

## 3. HTTP 接口

### 3.1 端点

```
GET https://api.deepseek.com/user/balance
Authorization: Bearer <apiKey>
```

由 `DeepSeekSupplier.swift:13-15` 硬编码，**没有 query 参数、没有 body**。

### 3.2 响应结构

```json
{
  "is_available": true,
  "balance_infos": [
    {
      "currency": "CNY",
      "total_balance": "110.00",
      "granted_balance": "10.00",
      "topped_up_balance": "100.00"
    }
  ]
}
```

### 3.3 字段含义

**包络字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `is_available` | bool | 账户是否可用（被风控/欠费时为 false） |
| `balance_infos` | array | 余额记录列表；正常情况下长度为 1（CNY） |

**每条记录字段**：

| 字段 | 类型 | 含义 |
|------|------|------|
| `currency` | string | 币种标识（`CNY` / `USD` 等） |
| `total_balance` | string | 总余额 = `granted_balance + topped_up_balance` |
| `granted_balance` | string | 赠送余额（不可消耗尽） |
| `topped_up_balance` | string | 充值余额（可消耗） |

**关键设计点**：
- **所有金额字段都是 string**（不是 number）— 因为大金额会丢精度。Parser 在 `DeepSeekResponseParser.swift:50-52` 调 `stringValue(_:)` 容错
- **没有 quota/limit 字段** — DeepSeek 是余额型，没有"已用/上限"概念，UI 通过 `Thresholds.balance` 配阈值（金额数）触发告警
- **`is_available` 与 `balance_infos` 独立** — 账户停服时 `is_available=false` 但 `balance_infos` 可能仍存在；Parser 在 `DeepSeekResponseParser.swift:23-27` 单独处理（只把 `is_available` 透到 `SupplierResponse.isAvailable`，不阻止解析继续）

---

## 4. 余额选择策略

`DeepSeekResponseParser.parse(_:)` 选 balance_infos 的策略（`DeepSeekResponseParser.swift:30-47`）：

```
Priority 1: currency == "CNY" 的记录
Priority 2: 第一条记录
无记录    → 抛 parsingError("No balance info available")
```

**为什么 CNY 优先**：自用项目，用户主账户是 CNY 充值。如果 DeepSeek 后续支持多币种账户（比如同时有 USD 和 CNY），CNY 是国内用户主视图。

**为什么兜底取首条**：如果 DeepSeek 改了优先级或不返回 CNY（理论极端情况），不至于完全没数据。

---

## 5. 解析后的 `rawData` 形态

| 键 | 值 | 用途 |
|----|----|------|
| `balance` | `topped_up_balance`（可消耗充值余额） | 主显示维度、阈值告警计算 |
| `total_balance` | `granted + topped_up` 总和 | 详情面板展示 |
| `granted_balance` | 赠送余额 | 详情面板展示 |

`SupplierResponse.currency` 字段填 `currency`（如 `"CNY"`），供 `Instance.currency` 持久化和 UI 显示。

**示例**（上面那条响应解析后）：

```swift
SupplierResponse(
    rawData: [
        "balance": "100.00",
        "total_balance": "110.00",
        "granted_balance": "10.00"
    ],
    currency: "CNY",
    isAvailable: true
)
```

---

## 6. 与 `Supplier` 协议的对应

```swift
protocol Supplier {
    var provider: Provider { get }
    func fetchUsage(apiKey: String) async throws -> SupplierResponse
}
```

`DeepSeekSupplier` 完整实现（23 行）：

```swift
struct DeepSeekSupplier: Supplier {
    let provider: Provider = .deepseek
    private let networkClient = NetworkClient.shared
    private let parser = DeepSeekResponseParser()
    private let logger = AppLogger(category: "supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(
            url: URL(string: "https://api.deepseek.com/user/balance")!
        )
        let response = try await networkClient.request(endpoint, apiKey: apiKey)
        let result = try parser.parse(response)
        logger.info("DeepSeek balance: \(result.rawData["balance"] ?? "unknown"), available: \(result.isAvailable)")
        return result
    }
}
```

Supplier 内嵌一行 `logger.info(...)`（`DeepSeekSupplier.swift:20`），用于记录余额日志。

---

## 7. 上层消费路径

```
RefreshService
   ↓
SupplierRegistry.getSupplier(for: .deepseek)  // → DeepSeekSupplier
   ↓
supplier.fetchUsage(apiKey:)                  // 拿 SupplierResponse（含 currency + isAvailable）
   ↓
rawData["balance"] 作为 dimension value
   ↓
BalanceCalculator 计算 daily average / 历史快照
   ↓
SlotViewData → MenuBarIcon 渲染（显示金额 + 币种）
```

**关键耦合点**：
- `Views/UsageCardView.swift:16-17` 是 DeepSeek 实例点击后的 dashboard URL 跳转
- `Models/Instance.swift:12` 的 `currency` 字段从 DeepSeek 响应持久化
- `Balance/` 目录是 DeepSeek 专属的历史快照、日均消费计算
- `Models/Thresholds.swift` 中 `case .balance` 分支只对 DeepSeek 生效

---

## 8. 错误处理

| 错误来源 | 抛出 | 映射 |
|---------|------|------|
| JSON 解析失败 | `RefreshError.parsingError("Invalid JSON from DeepSeek API")` | UI 显示"解析失败" |
| 缺 `balance_infos` | `RefreshError.parsingError("Missing or invalid balance_infos")` | 同上 |
| `balance_infos` 为空数组 | `RefreshError.parsingError("No balance info available")` | 同上 |
| `is_available = false` | **不抛错**，透到 `SupplierResponse.isAvailable = false` | UI 可选显示"账户停服"状态，**但仍展示余额** |
| HTTP 401 | `NetworkClient` 抛 `httpError(statusCode: 401)` | UI 显示"鉴权失败" |

注意 `is_available = false` 的处理：**不是错误**。账户可能临时被风控（欠费、违规），但余额数据本身是有效的，UI 应该展示"账户不可用"但仍能看余额历史。

---

## 9. 测试覆盖

`APIUsageStatusTests/DeepSeekResponseParserTests.swift` — **8 个测试用例**：

- 正常 CNY 解析
- 多币种场景下 CNY 优先
- 缺 CNY 时兜底取首条
- `is_available = false` 不抛错
- `balance_infos` 为空数组抛错
- 缺字段 / 畸形 JSON 抛错
- 金额是 number 而非 string 时的容错（`NSNumber` 路径）
- `currency` 字段透传

---

## 10. 风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| DeepSeek 端点改版 | 解析失败 | `stringValue` 已容错数字/字符串；缺字段抛清晰的 parsingError |
| 账户被风控（`is_available=false`） | UI 状态 | 透出但不抛错，由 UI 决定如何展示 |
| 多币种账户返回非 CNY 记录 | 选了 USD 而用户预期 CNY | 优先级 1 = CNY；后续如需"按用户偏好选币种"，需要新增 `Instance.currency` 过滤 |
| 金额精度丢失 | 大金额四舍五入 | API 返回 string，Parser 直接保留，UI 渲染时再 `Decimal` 处理 |
| `NetworkClient` 是单例 | Supplier 端到端测试难 | 需要时抽 `HTTPClient` 协议 |
| DeepSeek 增加 quota 接口（不只是 balance） | 单维度不够用 | 当前架构是 1 supplier = 1 维度集合；如需按 model 切分要重构 |
