# Copilot 用量固定在 100% — Investigation

> **日期**: 2026-07-30
> **状态**: 根因已定位,修复已实施(见 `CopilotResponseParser` / `RefreshService`)
> **影响**: 所有 `premium_interactions` 配额超额场景(显示成 `100%+n%` 的路径)

---

## 1. 现象

- 状态栏图标与弹窗均显示 `100%`,即便用户实际已超额消耗。
- 前几天(约 2026-07-27 之前)还能正确显示 `100%+n%`(`100%+10%`、`100%+15%` 之类)。
- 应用进程无需重启——重启也不解决,说明问题不在缓存层。
- 状态栏图标能透传任意 `percent`,所以数值上游就被夹紧到 100。

## 2. 调查范围

| 层 | 嫌疑 | 理由 |
|----|------|------|
| 应用代码(CopilotResponseParser) | ✗ | 最近一次改动 `1bb68b4`(2026-06-23),距症状出现一个多月 |
| 应用代码(CopilotSupplier) | ✗ | 自 `6e320bd` 后未改动 |
| 最新 commit `e462fa3` | ✗ | 只影响 Kimi 的 `cycleEndTime` 继承,不碰 percent |
| 渲染层夹紧 | ✗ | 已逐层核对 `RefreshService.parsePercent`、`MenuBarIconRenderer`、`UsageCardView.overagePercentText` 全部透传 |
| 缓存 / 旧值 | ✗ | 每轮 refresh 真打 API |
| **GitHub `/copilot_internal/user` 字段语义** | **✓** | 见 §3 |

## 3. 上游 API 字段对照

直接 `curl` 当前 Copilot Internal API 的 `premium_interactions` 快照(命令见 §6.1):

| 字段 | 旧契约(parser 注释) | 现状(2026-07-30 实测) | 备注 |
|------|---------------------|------------------------|------|
| `entitlement` | 300 | **7000** | 月度配额上限 |
| `remaining` | 220(非负) | **-1055** | 已变为负数,代表超额 |
| `percent_remaining` | 73.33(可负) | **0.0** | ⚠️ 不再保留负精度,即使 `remaining < 0` 也被截到 0 |
| `overage_permitted` | `false`(无超额) / `true`(有超额) | **永远 `false`** | ⚠️ 语义似乎已改为"是否允许开通按量计费",而非"当前是否超额" |
| `overage_count` | 0 / 42 | **1000** | 仍有数据但因 `overage_permitted` 永假,parser 的 overage 分支永远走不到 |
| `unlimited` | false | false | 不变 |
| **`credits_used`** | ❌ 不存在 | **8054** | ✅ 新增——真正的"已用总数",**约等于** `entitlement + \|remaining\|`(实测 `7000 + 1055 = 8055` 而 `credits_used = 8054`,差 1,可能是 GitHub 内部舍入;比 `entitlement - remaining + overage_count` 准,因为后者在 `remaining<0` 时会重复计 overage_count) |
| **`quota_remaining`** | ❌ 不存在 | **-1054.2** | 负值 + 小数精度,等价于 `remaining` 但更细 |
| **`overage_entitlement`** | ❌ 不存在 | 1000 | overage 配额上限 |
| `quota_id` / `quota_reset_at` / `token_based_billing` / `has_quota` / `timestamp_utc` | ❌ | ✅ 新增 | 元数据,无计算用途 |
| `copilot_plan` | `"pro"` | **`"individual_pro"`** | 仅作显示标签,无逻辑影响 |
| `quota_reset_date_utc` | `"2026-07-01T00:00:00Z"` | **`"2026-08-01T00:00:00.000Z"`** | parser 的 `parseISO8601ToMs` 已兼容带毫秒格式 |

## 4. 根因(代码层)

`CopilotResponseParser.swift:59-66`(修复前):

```swift
let usagePercent: Double = {
    if unlimited { return 0 }
    if overagePermitted && overageCount > 0 {                  // ← 因 §3 变化永远 false
        let totalUsage = entitlement - remaining + overageCount
        return entitlement > 0 ? max(0, totalUsage / entitlement * 100) : 0
    }
    return max(0, min(100, 100.0 - percentRemaining))           // ← 100 - 0.0 = 100,被钉死
}()
```

两条路径都被堵:
1. **Overage 分支被锁死**:`overage_permitted` 永远 `false`,guard 失败。
2. **Fallback 分支被夹紧**:`percent_remaining` 被 GitHub 截到 `0.0`,`100 - 0 = 100`,再被 `min(100, ...)` 二次钉死。

正确的百分比在新 API 下应为 `credits_used / entitlement * 100 = 8054 / 7000 * 100 ≈ 115.06%`,即用户实际看到的 `100%+15%`。

## 5. 顺带的次要 Bug

`RefreshService.swift:817`(修复前):

```swift
let used = max(0, entitlement - remaining) + overageCount
```

代入新 API 真实值(`entitlement = 7000`, `remaining = -1055`, `overageCount = 1000`):

```
max(0, 7000 - (-1055)) + 1000 = 8055 + 1000 = 9055
```

但 `credits_used = 8054`(唯一可信值)。**`overage_count` 被重复计入**——`entitlement - remaining` 在 `remaining < 0` 时已经包含了超额部分,无需再加 `overage_count`。同样症状导致弹窗里的 `used / entitlement` 显示也会偏大 1000。

**修复后**(顺带解决了 parser 旧 fallback 同样的 bug):有 `credits_used` 时直接用,无时按 `remaining` 形状分流——`remaining < 0` 时用 `entitlement - remaining`(新 API 形状,`overage` 已嵌入),`remaining >= 0` 时用 `entitlement + overageCount`(旧 API 形状,`remaining` 被夹到 0)。这样无论哪种 API 形状都不会再把 overage 算两次。

## 6. 复现 / 验证步骤

### 6.1 拉取当前 API 真实响应

```bash
# 1. 取 token(macOS Keychain;service=APIUsageStatus,account=<uuid>)
security find-internet-password -s "APIUsageStatus" -a "<copilot apiKeyRef>" -w

# 2. 直接打 API
curl -sS \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/copilot_internal/user" \
  | jq .quota_snapshots.premium_interactions
```

### 6.2 应用内日志

`CopilotSupplier` 在 `fetchUsage` 末尾补了一行 `logger.debug("Copilot premium_interactions rawData: \(parsed.rawData)")`,把 parser 写出的所有副键打到 `os.log` 的 `supplier` category,便于未来类似诊断(此前 `AppLogger` 虽声明但从未调用,等于裸奔)。`rawData` 只含数字与布尔,无 PII / token。

## 7. 修复策略

按项目 [[provider-specific-logic-boundaries]] 约束:

1. **Parser 层**(`CopilotResponseParser`)独占 overage 识别:
   - 用 `remaining < 0` / `quota_remaining < 0` / `credits_used > entitlement` 三者任一作为 overage 信号,替代 `overage_permitted && overage_count > 0`
   - 有 `credits_used` 时百分比改为 `credits_used / entitlement * 100`(更准);无则按 `remaining` 形状分流(`remaining < 0` 用 `entitlement - remaining`,`remaining >= 0` 用 `entitlement + overageCount`),避免在 `remaining<0` 时把 overage 算两次
   - 把 `credits_used` 写进 `rawData["premium_interactions:credits_used"]`,供下游 RefreshService 读取
   - **写入契约**:parser 只在 `credits_used` 是权威绝对已用总量(真实超额计量)时写非零值,绝不写 partial / relative counter;这与 `RefreshService` 的 `creditsUsed > 0` 数值守卫互为前提——任何未来采用同 key 的 supplier 必须遵守同一语义,否则守卫不成立
   - **Overage 分支不夹紧 `[0, 100]`**,fallback 分支保留夹紧
2. **Service 层**(`RefreshService.swift:817`)改用 `credits_used`,缺失时回退,避免 `overage_count` 重复计入。
3. **AppState / MenuBarIconRenderer / UsageCardView** 不动——它们对任意 `percent` 已正确透传。
4. **测试**:新增一个新 API 形状的 fixture(`remaining = -1055`、`overage_permitted = false`、`credits_used = 8054` → 期望 `115.1%`);旧 `testOverageData` 保持原状继续通过。

## 8. 兼容性

- 新 API(有 `credits_used`):走新公式 `credits_used / entitlement * 100`,overage 信号来自 `remaining < 0`。
- 旧 API(无 `credits_used`):回退到旧公式;overage 信号回退到 `overage_permitted && overage_count > 0`。
- `unlimited == true` 仍返回 0(显式最高优先级)。
- fallback 分支(`percentRemaining` 反推)继续保留 `min(100, ...)` 夹紧——只在确实未超额时生效。

## 9. 相关文件

- `APIUsageStatus/Suppliers/CopilotResponseParser.swift` — 主修改
- `APIUsageStatus/Services/RefreshService.swift:817` — `used` 计算修正
- `APIUsageStatusTests/CopilotResponseParserTests.swift` — 新增 fixture + 用例
- `APIUsageStatusTests/RefreshServiceMappingTests.swift` — 新增 `testCopilotOverageUsesCreditsUsedNotOverageCount`
- `docs/provider-interfaces/copilot.md` — §1 / §3 字段表需后续同步更新(独立 PR)

## 10. 实施过程中顺带修复的预存在 Bug

为了让本分支能 `xcodebuild test` 通过,顺带改了两处 **与 Copilot overage 完全无关** 的 main 分支预存在编译错误。两处都是 `e462fa3 feat(refresh): inherit unexpired end_time when response is missing it`(2026-07-27) PR 引入的,合并前未跑过测试编译验证。

1. **`APIUsageStatusTests/RefreshServiceMappingTests.swift` line 633 — `testCopilotWeeklyWithoutGroupFallsThroughToCopilotBranch` 缺失收尾 `}`**
   - 现象:该测试最后一个 `XCTAssertEqual` 后直接跟 `// MARK:` 注释,**没有关闭函数体的 `}`**,导致从 line 633 到文件末尾的所有测试被解析成嵌套在该函数体内,`swiftc` 报 "expected '}' in class"。
   - 影响:整个测试 target 无法编译,任何 PR 都没法跑测试验证。

2. **`APIUsageStatusTests/RefreshServiceMappingTests.swift` line 1089 — Kimi 测试缺 `throws`**
   - 现象:`func testKimiParserEndToEndInvalidResetTimeInheritsPreviousEndTime() async {` 函数体内调用了 `try parser.parse(...)`,但函数声明没标 `throws`。
   - 影响:同上,编译失败。
   - 修复:加 `throws` 即可(JSON 合法,parse 不会抛)。

这两处不影响本 PR 的语义,**只是为了能验证 Copilot 修复而必须先解开的卡点**。如希望保留独立原子提交,可拆为 `fix(test): repair pre-existing compile errors in RefreshServiceMappingTests` 单独 PR。

另:`KimiResponseParserTests.testUnparseableWeeklyResetTimeDoesNotDeclareFiveHourPolicy` 当前在 main 上也会失败(本分支同样),与本次修复无关,未处理。
