# MiniMax 套餐用量接口说明

> 文档目的：说明 MiniMax `Supplier` 的实现结构、API 接口、响应解析、维度模型，以及与项目其它模块的耦合点。
> 编写日期：2026-06-13
> 实现源码：
> - `APIUsageStatus/Suppliers/MiniMaxSupplier.swift`
> - `APIUsageStatus/Suppliers/MiniMaxResponseParser.swift`

---

## 1. 结论先行

| 维度 | 说明 |
|------|------|
| 数据源 | 远端 HTTPS API（`/v1/token_plan/remains`） |
| 认证方式 | Bearer Token（API Key 存 Keychain） |
| 监控粒度 | **每能力桶独立维度**（`model_name` = 能力桶，如 `general` / `video` / `speech-hd` / `music-2.6` / `image-01`），具体值随订阅套餐类型（general text / video / speech-hd 等）而异 |
| 配额类型 | 周期配额型（5h 窗口 + Weekly 窗口） |
| 是否有无限套餐 | 有（响应里 `status != 1` 时按无限处理，渲染 flowing glow bar） |
| 单实例多维度支持 | 是 — 一个 API Key 拉一次，所有 model 自动展开为多个 instance |
| 模块独立性 | 通过 `Supplier` 协议接入；新增供应商不影响已有代码 |

---

## 2. 模块组成

```
Suppliers/
├── Supplier.swift               # Supplier 协议 + Provider 枚举
├── MiniMaxSupplier.swift        # HTTP 请求 + 委托给 Parser
├── MiniMaxResponseParser.swift  # 响应解析 + rawData 构造
└── SupplierRegistry.swift       # Provider → Supplier 的工厂映射
```

**职责分层**：
- `MiniMaxSupplier` 只负责拼装 `Endpoint`、调 `NetworkClient.request`、把响应转给 Parser
- `MiniMaxResponseParser` 只负责 JSON → `SupplierResponse` 的转换
- `Supplier` 协议统一了 `fetchUsage(apiKey:)` 接口
- `SupplierRegistry.getSupplier(for:)` 是入口工厂

**注**：当前实现里 `NetworkClient.shared` 是单例，`Parser` 是 struct 临时实例，**没有 DI 抽象**。如需写单测，需要先抽出 protocol。

---

## 3. HTTP 接口

### 3.1 端点

```
GET https://www.minimaxi.com/v1/token_plan/remains
Authorization: Bearer <apiKey>
```

由 `MiniMaxSupplier.swift:13-15` 硬编码，**没有 query 参数、没有 body**。

### 3.2 响应结构

```json
{
  "model_remains": [
    {
      "model_name": "general",
      "current_interval_status": 1,
      "current_interval_remaining_percent": 28,
      "start_time": 1781247600000,
      "end_time": 1781265600000,
      "remains_time": 173501,
      "current_weekly_status": 3,
      "current_weekly_remaining_percent": 100,
      "weekly_start_time": 1780848000000,
      "weekly_end_time": 1781452800000,
      "weekly_remains_time": 187373501
    }
  ],
  "base_resp": { "status_code": 0, "status_msg": "success" }
}
```

### 3.3 字段含义

**包络字段**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `model_remains` | array | 每个 model 一条记录 |
| `base_resp.status_code` | int | 0 = 成功；1004/1003 = 鉴权失败（映射 HTTP 401） |

**每模型字段**：

| 字段 | 类型 | 含义 |
|------|------|------|
| `model_name` | string | 能力桶标识（如 `general`、`video`、`speech-hd`、`music-2.6`、`image-01`），非具体模型名；在应用中映射为 `MetricConfig.key` / `MetricConfig.group`。实际值由订阅套餐决定（general text、video、speech-hd 等），不同订阅等级可用的 model_name 集合不同 |
| `current_interval_status` | int | 5h 窗口状态：`1` = 配额生效中；其他值 = 窗口不计入（按 0% 处理） |
| `current_interval_remaining_percent` | number | 5h 窗口剩余百分比；**5h 用量 = `100 - 此值`** |
| `start_time` / `end_time` | int64 | 5h 窗口起止时间戳（毫秒） |
| `remains_time` | int64 | 5h 窗口剩余毫秒数 |
| `current_weekly_status` | int | 周窗口状态（同 5h 语义） |
| `current_weekly_remaining_percent` | number | 周窗口剩余百分比；**周用量 = `100 - 此值`** |
| `weekly_start_time` / `weekly_end_time` | int64 | 周窗口起止时间戳 |
| `weekly_remains_time` | int64 | 周窗口剩余毫秒数 |

**关键设计点**：
- API 只给"剩余百分比"，**不直接给用量百分比**。Parser 在 `MiniMaxResponseParser.swift:75-77` 做 `100 - remaining` 转换
- `status == 1` 是"配额生效"标志；其他值（如 `3`）表示"这个窗口目前不计入"。Parser 在 `MiniMaxResponseParser.swift:75-78` 和 `82-85` 显式判别，避免误导数字

---

## 4. 解析后的 `rawData` 形态

`MiniMaxResponseParser.parse(_:)` 输出 `SupplierResponse`，其 `rawData: [String: String]` 包含以下键（**每个 model 一套**）：

| 键 | 值 | 用途 |
|----|----|------|
| `<model_name>` | 5h 用量百分比（字符串 `%.1f`） | 主显示维度 |
| `<model_name>:status` | `current_interval_status` 原始值 | 判定 `isUnlimited` |
| `<model_name>:remaining` | `current_interval_remaining_percent` 原始值（字符串 `%.1f`） | 渲染精度 |
| `<model_name>:weekly_status` | `current_weekly_status` 原始值 | 判定 weekly `isUnlimited` |
| `<model_name>:weekly_remaining` | weekly 剩余百分比 | 周窗口精度 |
| `<model_name>:weekly_percent` | weekly 用量百分比 | 周窗口主显示 |
| `<model_name>:end_time` | 5h 窗口 end_time 毫秒时间戳 | **字段依赖**:RefreshService 算成 `cycleRemainingSeconds` 注入 `InstanceType.quota`,UI 层 `UsageCardView.formatRemainingTime` 格式化为 `Xh Ym` / `Xm` / `Xd remaining`。字段缺失则倒计时行整行隐藏 |
| `_model_names` | 逗号拼接的 model 列表 | `InstanceEditorView` 维度选择器 |

**示例**（响应里有 `general` 一条）：
```swift
[
  "general": "72.0",              // 5h 已用 72%
  "general:status": "1",
  "general:remaining": "28.0",
  "general:weekly_status": "3",   // weekly 不计入
  "general:weekly_remaining": "100.0",
  "general:weekly_percent": "0.0",
  "general:end_time": "1781265600000",
  "_model_names": "general"
]
```

---

## 5. 与 `Supplier` 协议的对应

```swift
protocol Supplier {
    var provider: Provider { get }
    func fetchUsage(apiKey: String) async throws -> SupplierResponse
}
```

`MiniMaxSupplier` 完整实现（23 行）：

```swift
struct MiniMaxSupplier: Supplier {
    let provider: Provider = .minimax
    private let networkClient = NetworkClient.shared
    private let parser = MiniMaxResponseParser()
    private let logger = AppLogger(category: "supplier")

    func fetchUsage(apiKey: String) async throws -> SupplierResponse {
        let endpoint = Endpoint.get(
            url: URL(string: "https://www.minimaxi.com/v1/token_plan/remains")!
        )
        let response = try await networkClient.request(endpoint, apiKey: apiKey)
        return try parser.parse(response)
    }
}
```

`Provider` 枚举（`Supplier.swift:5-15`）当前只列了两个 case，加新供应商时需要扩展这里。

---

## 6. 上层消费路径

```
RefreshService
   ↓
SupplierRegistry.getSupplier(for: .minimax)  // → MiniMaxSupplier
   ↓
supplier.fetchUsage(apiKey:)                 // 拿 SupplierResponse
   ↓
rawData["_model_names"] 解析为 [String]      // 拆成多个 Instance
   ↓
对每个 model: 用 rawData["<model>"] 作 dimension, rawData["<model>:status"] 判 isUnlimited
   ↓
SlotViewData → MenuBarIcon 渲染
```

**关键耦合点**：
- `Services/RefreshService.swift:143-147` 在拉取后**额外**调用 `appState.setMiniMaxModelNames(names)`，把 model 列表注入到全局 state，供 `InstanceEditorView` 做维度下拉
- `Models/SlotViewData.swift:52-64` 解释了为何 weekly_percent 在 status != 1 时按 0% 处理（避免误导数字）
- `Views/UsageCardView.swift:18-19` 是 MiniMax 实例点击后的 dashboard URL 跳转

---

## 7. 错误处理

| 错误来源 | 抛出 | 映射 |
|---------|------|------|
| JSON 解析失败 | `RefreshError.parsingError("Invalid JSON from MiniMax API")` | UI 显示"解析失败" |
| `base_resp.status_code` ∈ {1004, 1003} | `RefreshError.httpError(statusCode: 401)` | UI 显示"鉴权失败"，重试会一直失败 |
| `base_resp.status_code` 其他非 0 | `RefreshError.parsingError("API error (xxx): msg")` | UI 显示错误消息 |
| 缺 `model_remains` | `RefreshError.parsingError("Missing or invalid model_remains")` | 同上 |
| `current_interval_status != 1` | **不抛错**，按 0% 处理 | UI 渲染 flowing glow bar（视为无限） |
| `current_weekly_status != 1` | **不抛错**，按 0% 处理 | weekly 维度按无限显示 |

`RefreshError` 的 `parsingError` 和 `httpError` 定义在 `Services/RefreshService.swift` 周边（具体文件未拆分，独立模块）。

---

## 8. 测试覆盖

`APIUsageStatusTests/MiniMaxResponseParserTests.swift` — **10 个测试用例**：

- 正常解析（多 model）
- `base_resp.status_code != 0` 抛错
- 1004 / 1003 映射 401
- 缺字段 / 畸形 JSON
- 多 model 展开为多 dimension
- weekly 字段缺失 / status != 1 的 fallback
- `_model_names` 聚合
- 百分数边界（clamp 到 0~100）

测试用 fixture JSON，不走真实网络（`NetworkClient` 是单例所以没法 mock 端到端）。

---

## 9. 风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| 端点改版 / 新增字段 | 解析失败 | Parser 用 `as?` 兜底缺失字段；status != 0 才报错 |
| `model_name` 列表变化 | 用户已配置的 instance dimension 可能失效 | `InstanceEditorView` 的维度下拉基于当前响应动态生成，缺模型时仅显示已存 dimension |
| `NetworkClient` 是单例难 mock | Parser 单独可测，但 Supplier 端到端测试缺 | 抽取 `HTTPClient` 协议 |
| `status` 值含义变化 | 0% vs 100% 误判 | 当前硬编码 `status == 1`，若 MiniMax 改枚举需要同步改 Parser |
| 5h 窗口边界正好切到 0% | UI 闪烁 | 现有逻辑正确，但若要做"即将归零"预警需要新增阈值类型 |
