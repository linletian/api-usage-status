# OpenCode Go 套餐用量接口说明

> 文档目的：说明 OpenCode Go 用量数据的来源（本地 SQLite + CLI）、SQL 查询模板、三窗口重置算法、以及 `Supplier` 协议下的落地设计。
> 编写日期：2026-06-13
> 参考实现：[tddworks/ClaudeBar](https://github.com/tddworks/ClaudeBar) — `Sources/Infrastructure/OpenCode/OpenCodeUsageProbe.swift`

---

## 1. 结论先行

| 问题 | 答案 |
|------|------|
| 有公开的 HTTP 用量接口吗？ | **没有**。OpenCode 不提供任何远程用量查询端点 |
| 那 ClaudeBar 怎么拿数据？ | **shell 出 `opencode db` 子命令查本地 SQLite** |
| 本机环境能跑通吗？ | **能**，已端到端验证通过 |
| 是否可以套用现有 `Supplier` 协议？ | **可以**（不依赖网络，走 `Process` shell） |
| 落地成本 | 中 — `OpenCodeSupplier.swift` + 三窗口卡片复用 + 路径探测逻辑 |

---

## 2. 数据源分析

### 2.1 为什么没有 HTTP API

OpenCode 是一款 CLI 工具，定位与 Claude Code / Aider 同类。它的设计哲学是"本地优先"：
- 会话历史、cost 数据**全部存在本地 SQLite** (`~/.local/share/opencode/opencode.db`)
- 官方没有提供"用量 dashboard"的 HTTP 接口
- 想要实时用量只能读本地 DB

### 2.2 ClaudeBar 的解法：shell 出 `opencode db`

```bash
opencode db "<SQL>" --format json
```

`opencode db` 子命令的本质是 sqlite3 的封装：支持交互式 shell、运行单条 SQL、或 `db path` 打印数据库路径。`--format json` 让 SQL 结果以 JSON 数组返回，便于解析。

**数据流**：

```
┌─────────────────┐    shell    ┌──────────────┐    SQL    ┌─────────────┐
│  OpenCodeSupplier│ ──────────→ │ opencode CLI │ ────────→ │ SQLite DB   │
│  (Swift)         │ ←────────── │  (jq-like)   │ ←──────── │ (本地)      │
└─────────────────┘   JSON      └──────────────┘   rows    └─────────────┘
```

---

## 3. 本机验证结果

已在 macOS 用户环境端到端跑通。

### 3.1 环境检查

| 项 | 值 |
|----|----|
| CLI 路径 | `~/.opencode/bin/opencode` |
| CLI 版本 | 1.15.13 |
| `opencode db` 子命令 | ✅ 存在 |
| `--format json` | ✅ 支持 |
| 数据库路径 | `~/.local/share/opencode/opencode.db` |
| `message` 表 | ✅ 含 `id, session_id, time_created, time_updated, data` |
| `data` JSON 字段 | ✅ 含 `$.providerID, $.role, $.cost, $.time.created` |

### 3.2 实测用量数据

执行 ClaudeBar 原始 SQL 后的结果（2026-06-13 实时）：

| 窗口 | 已用 | 上限 | 剩余 |
|------|------|------|------|
| **5h**（滚动） | $0.00 | $12 | 100% |
| **Weekly**（UTC 周一→周一） | $29.85 | $30 | 0.5% |
| **Monthly**（锚定首次使用日 2/25） | $32.62 | $60 | 45.6% |

**全量交叉验证**：
- `opencode-go` 消息总数：6869 条
- 累计 cost：$145.09（生命周期）
- 首次消息时间戳：1772019366076 → 2026-02-25 11:36:06 UTC

### 3.3 SQL 模板（直接抄 ClaudeBar）

**主查询**（5h + weekly 一次搞定）：

```sql
SELECT
  COALESCE(SUM(CASE WHEN t >= {five_hour_ms}  THEN cost ELSE 0 END), 0) AS five_hour_cost,
  COALESCE(SUM(CASE WHEN t >= {week_start_ms} THEN cost ELSE 0 END), 0) AS weekly_cost,
  MIN(CASE WHEN t >= {five_hour_ms} THEN t ELSE NULL END) AS five_hour_oldest_ms,
  MIN(t) AS anchor_ms
FROM (
  SELECT
    CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS t,
    CAST(json_extract(data, '$.cost') AS REAL) AS cost
  FROM message
  WHERE json_valid(data)
    AND json_extract(data, '$.providerID') = 'opencode-go'
    AND json_extract(data, '$.role') = 'assistant'
    AND json_type(data, '$.cost') IN ('integer', 'real')
)
```

**月度查询**（基于 anchor 算出的窗口）：

```sql
SELECT COALESCE(SUM(cost), 0) AS monthly_cost
FROM (
  SELECT
    CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS t,
    CAST(json_extract(data, '$.cost') AS REAL) AS cost
  FROM message
  WHERE json_valid(data)
    AND json_extract(data, '$.providerID') = 'opencode-go'
    AND json_extract(data, '$.role') = 'assistant'
    AND json_type(data, '$.cost') IN ('integer', 'real')
)
WHERE t >= {month_start_ms} AND t < {month_end_ms}
```

---

## 4. 三个窗口的重置算法

这是 ClaudeBar 最巧妙的部分，**三套完全不同的语义统一到一段纯函数里**。

### 4.1 5h 窗口（滚动）

```swift
// resetsAt = 窗口内最旧消息时间 + 5h
func fiveHourResetDate(from oldestMs: Int64?, fallback now: Date) -> Date {
    guard let oldestMs else { return now.addingTimeInterval(5 * 3600) }
    return Date(timeIntervalSince1970: TimeInterval(oldestMs) / 1000)
        .addingTimeInterval(5 * 3600)
}
```

- 没有任何消息时 `resetsAt = now + 5h`（开始新窗口）
- 有消息时 `resetsAt = 最旧消息 + 5h`（保持 5h 滚动）

### 4.2 Weekly 窗口（固定 UTC 周一→周一）

```swift
static func startOfWeekUTC(from date: Date) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    let weekday = cal.component(.weekday, from: date)  // 1=Sun..7=Sat
    let daysFromMonday = (weekday + 5) % 7             // Mon=0..Sun=6
    let monday = cal.date(byAdding: .day, value: -daysFromMonday, to: date) ?? date
    return cal.startOfDay(for: monday)
}
```

- `(weekday + 5) % 7` 这个公式把 Sun=1..Sat=7 映射到 Mon=0..Sun=6
- `resetsAt` = 当前周 UTC 周一 00:00

### 4.3 Monthly 窗口（**锚定首次使用日**）⭐ 关键

```swift
static func anchoredMonthBounds(now: Date, anchor: Date) -> (start: Date, end: Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt

    let anchorTime = cal.dateComponents([.day, .hour, .minute, .second], from: anchor)
    let nowMonth = cal.dateComponents([.year, .month], from: now)

    var comps = DateComponents()
    comps.year = nowMonth.year
    comps.month = nowMonth.month
    comps.day = anchorTime.day        // ← 取 anchor 的 day-of-month
    comps.hour = anchorTime.hour      // ← 同时取 hour/minute/second
    comps.minute = anchorTime.minute
    comps.second = anchorTime.second

    var start = cal.date(from: comps) ?? anchor
    if start > now {
        start = cal.date(byAdding: .month, value: -1, to: start) ?? start
    }
    let end = cal.date(byAdding: .month, value: 1, to: start)
        ?? start.addingTimeInterval(30 * 86400)
    return (start, end)
}
```

**这个算法为什么妙**：
- "自然月"语义（每月 1 日 → 下月 1 日）和"账单月"语义（按用户注册日 25 日 → 下月 25 日）在 ClaudeBar 里**统一成一段纯函数**，不需要存用户的"账单日"配置
- 用 `MIN(t)` 找首次消息时间戳作为 anchor，完全从数据里推
- `if start > now then -1 month` 是边界处理（窗口起点不能在将来）

**实测举例**（本机）：
- anchor = 2026-02-25 11:36:06（首次用 opencode-go 的时间）
- 当前 = 2026-06-13
- 计算：`{year:2026, month:6, day:25, hour:11, minute:36, second:6}` → 2026-06-25 11:36:06（> now）→ 减一月 → 2026-05-25 11:36:06
- 当前窗口：`[2026-05-25 11:36, 2026-06-25 11:36)`

---

## 5. 落地设计

### 5.1 `OpenCodeSupplier` 草图

```swift
struct OpenCodeSupplier: Supplier {
    let instance: APIInstance
    let processRunner: ProcessRunner  // 需要抽象 Process 出来

    func fetch() async throws -> UsageSnapshot {
        let opencodePath = try locateOpencode()
        let now = Date()

        let primaryData = try runQuery(
            opencodePath: opencodePath,
            sql: Self.primarySQL(
                fiveHourMs: Self.millis(now.addingTimeInterval(-5 * 3600)),
                weekStartMs: Self.millis(Self.startOfWeekUTC(from: now))
            )
        )
        let primary = try Self.parsePrimary(primaryData)

        // 月度窗口基于 anchor
        let monthlyData: Data
        let monthEnd: Date
        if let anchorMs = primary.anchorMs {
            let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1000)
            let bounds = Self.anchoredMonthBounds(now: now, anchor: anchor)
            monthEnd = bounds.end
            monthlyData = try runQuery(
                opencodePath: opencodePath,
                sql: Self.monthlySQL(
                    monthStartMs: Self.millis(bounds.start),
                    monthEndMs: Self.millis(bounds.end)
                )
            )
        } else {
            monthlyData = Data("[]".utf8)
            monthEnd = now.addingTimeInterval(30 * 86400)
        }

        let monthlyCost = try Self.parseMonthly(monthlyData)
        return Self.makeSnapshot(primary: primary, monthlyCost: monthlyCost, monthEnd: monthEnd)
    }
}
```

### 5.2 路径探测

`opencode` CLI 不一定在 `$PATH` 上（实测在 `~/.opencode/bin/opencode`），需要多策略查找：

```swift
func locateOpencode() throws -> String {
    let candidates = [
        "\(NSHomeDirectory())/.opencode/bin/opencode",  // 官方安装路径（macOS）
        "/usr/local/bin/opencode",
        "/opt/homebrew/bin/opencode"
    ]
    if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
        return path
    }
    // 退到 `which` 兜底（需 Process 探测）
    throw SupplierError.dependencyMissing("opencode CLI not found")
}
```

### 5.3 卡片渲染映射

三窗口需要三个 UsageQuota：

| 窗口 | `quotaType` | `resetsAt` | 上限常量 |
|------|------------|-----------|---------|
| 5h | `.session` | 滚动 + 5h | `$12.0` |
| Weekly | `.weekly` | UTC 周一 00:00 | `$30.0` |
| Monthly | `.timeLimit("Monthly")` | 锚定 + 1 month | `$60.0` |

需要确认 `MenuBarIconRenderer` 是否已支持 `.timeLimit("Monthly")` 类型的卡片布局（已有的无限套餐 flowing glow bar 渲染分支可直接复用）。

### 5.4 套餐上限常量

```swift
enum OpenCodeGoLimits {
    static let fiveHour:  Double = 12.0
    static let weekly:    Double = 30.0
    static let monthly:   Double = 60.0
}
```

如果 opencode 调整套餐价格需要同步改。可以考虑后续挪到 `Settings` 让用户配置（参考 ClaudeBar 当前的硬编码处理）。

---

## 6. 风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| `opencode db` 子命令改版 | SQL 或 JSON 字段名变 | 解析时只读 `data` JSON 内的字段，外层 schema 变化影响小 |
| 上限常量 ($12/$30/$60) 调整 | 百分比算错 | 文档化常量来源，加测试用例 |
| 某些消息 `cost=0`（流式中或被取消） | 略高估 used | 接受——粒度到 $0.01，影响有限 |
| 多设备用户 | 只能看到本机数据 | 与 opencode dashboard 一致，本就是 per-device 视角 |
| 用户未安装 / 未认证 opencode CLI | `isExecutableFile` 失败 | `Supplier.isAvailable()` 返回 false，UI 提示"opencode CLI 未找到" |
| 数据库被 opencode 占用（写锁） | 偶发查询失败 | 退避重试（复用现有 `RetryPolicy`） |
| 大量消息时 SQL 慢 | UI 卡顿 | 6869 条本地查询实测 < 50ms，无性能问题；后续若数据增长加 LIMIT |
