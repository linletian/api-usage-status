# OpenCode Go 套餐用量接口说明

> 文档目的：说明 OpenCode Go 用量数据的来源（官方 HTTP API）、接口契约、以及 `Supplier` 协议下的落地设计。
> 更新日期：2026-09-02
> 历史：2026-06 ~ 2026-09 曾通过本地 SQLite（`opencode db` CLI）读取；官方 API（PR #16513）合并上线后已整体切换，本地查询路径已移除（见 §5）。

---

## 1. 结论先行

| 问题 | 答案 |
|------|------|
| 有公开的 HTTP 用量接口吗？ | **有**。`GET https://opencode.ai/zen/go/v1/usage`（PR #16513，已合并并上线） |
| 鉴权方式 | `Authorization: Bearer <Zen API Key>`（opencode.ai → workspace → API keys 创建） |
| 返回什么 | 三窗口（rolling 5h / weekly / monthly）各 `{status, percent, resetsAt}` |
| 多设备数据一致吗？ | **一致**。服务端统一记账，且仅统计套餐内用量（不含余额消费） |
| 本地 SQLite 路径 | **已移除**（2026-09-02） |

---

## 2. API 契约

### 2.1 请求

```
GET https://opencode.ai/zen/go/v1/usage
Authorization: Bearer <Zen API Key>
```

### 2.2 成功响应（200）

本机真实 key 实测（2026-09-02）：

```json
{
  "usage": {
    "rolling": { "status": "ok", "percent": 0,  "resetsAt": "2026-09-02T19:44:30.306Z" },
    "weekly":  { "status": "ok", "percent": 79, "resetsAt": "2026-09-07T00:00:00.306Z" },
    "monthly": { "status": "ok", "percent": 55, "resetsAt": "2026-09-25T11:33:14.306Z" }
  }
}
```

| 字段 | 说明 |
|------|------|
| `status` | `"ok"` / `"rate-limited"`（该窗口达到上限时） |
| `percent` | 已用百分比，0–100 整数（floor）；`rate-limited` 时恒为 100（客户端 parser 同样强制此规则） |
| `resetsAt` | 窗口重置的绝对时间，ISO8601 带毫秒（UTC）；客户端兼容无毫秒的秒级时间戳 |

**注意**：响应不包含美元金额，也不包含上限绝对值——`percent` 是唯一直接可用的用量信号，卡片渲染因此是纯百分比（无 `$已用 / $上限`）。

### 2.3 错误响应

| HTTP | `error.type` | 含义 |
|------|--------------|------|
| 401 | `AuthError` | 缺少或无效 API Key |
| 403 | `EntitlementError` | 账号无 OpenCode Go 订阅 |

错误体统一为 `{"type":"error","error":{"type":...,"message":...}}`，不含 PII——供应商端点已开 `Endpoint.exposesFailureBodyInLog`。

### 2.4 服务端语义（源码核查 2026-09-02，opencode dev 分支）

实现文件：`packages/console/app/src/routes/zen/go/v1/usage.ts`
相关提交：`2b8a5969e9 feat(console): add go usage endpoint (#16513)`、`d470434746 refactor(console): simplify go usage response`（响应简化为当前 shape）

- 用量数据源为服务端 `LiteTable.rollingUsage / weeklyUsage / monthlyUsage`；`trackUsage` **仅在 `billingSource === "lite"` 时累计**（`packages/console/app/src/routes/zen/util/handler.ts:1159`）。即 percent 天然排除「套餐用完后走 Zen 余额」的消费——本地 SQLite 时代的套餐/余额混算问题不复存在
- rolling：5h 滚动窗口（`Subscription.analyzeRollingUsage`），重置点 = 最近一次消费时间 + 5h；窗口内无消费时 percent=0
- weekly：UTC 周一 00:00 重置（`analyzeWeeklyUsage`）
- monthly：锚定订阅日（`analyzeMonthlyUsage`，以 `LiteTable.timeCreated` 为锚）
- 上限常量来自服务端 `Subscription.getLimits()["lite"]`（SST Resource 注入，不出现在仓库中；撰写时对应 $12 / $30 / $60 套餐）。客户端不再硬编码上限

---

## 3. 落地设计（当前实现）

### 3.1 `OpenCodeSupplier`

- `NetworkClient` 直连，Bearer 鉴权；`apiKey` 为空时直接抛「请在设置中配置 API Key」错误，不发请求
- 三个实例（5h / weekly / monthly）共享一个 keychain entry（`KeychainService.openCodePlaceholderRef`）；`RefreshService` 按 `api_key_ref` 去重，每个刷新 cycle 只发一次请求
- rawData 契约：`5h` / `weekly` / `monthly` 存 percent（`%.1f`），`{dim}:end_time` 存 `resetsAt` 的 Unix 毫秒；**不再写 `{dim}:used` / `{dim}:limit`**
- `RefreshService` 的 OpenCode 显示已并入通用 percent-only 分支（同 MiniMax / Kimi），`$` 金额与超额美元显示随本地路径一并移除

### 3.2 API Key 配置

- 设置 → 任一 OpenCode Go 实例 → 粘贴 Zen API Key（三实例共享同一 keychain entry，粘一次全部生效）
- **升级迁移**：从本地 SQLite 版本升级后，该 entry 为空字符串 → 卡片显示配置错误提示；粘贴 key 后下一次刷新自动恢复

### 3.3 仍保留的本地依赖

`OpenCodeWorkspaceResolver`（为「See details」深链恢复 workspace ID）仍需 shell 出 `/usr/bin/grep` 扫描 `~/.local/share/opencode/log/`——**App Sandbox 保持关闭的唯一原因现在是它**，与用量查询无关。详见 `opencode_workspace_resolver.md`。

---

## 4. 风险点

| 风险 | 影响 | 缓解 |
|------|------|------|
| API 响应格式变更 | 解析失败 | parser 窄校验，失败时卡片显错误；日志带响应 body（无 PII） |
| percent 为 floor 整数 | 显示精度 ±1% | 接受（服务端设计如此） |
| Zen API Key 被删除/失效 | 401 | 卡片显示错误，重新粘贴 key 即恢复 |
| 无 Go 订阅的账号 | 403 | 同上 |
| 套餐上限调整 | 无影响 | 客户端不硬编码上限、不显示美元 |

---

## 5. 历史：本地 SQLite 方案（2026-06 ~ 2026-09，已移除）

官方 API 出现之前，OpenCode 没有任何远程用量端点，唯一数据源是本地 `~/.local/share/opencode/opencode.db`，通过 `opencode db "<SQL>" --format json` 聚合 `message` 表的 `cost` 字段，自行实现三窗口重置算法（rolling 5h / UTC 周一 / 锚定首次使用日）。

该方案有两个无法本地解决的缺陷，也是本次切换的动机：

1. **多设备数据不准**：SQLite 只记录本机会话，多设备同时使用时各设备只看到自己的用量
2. **套餐/余额混算**：`message` 表不区分支付来源，「套餐用完后走余额」的消费被一并累加进 Monthly 窗口，百分比失真（2026-06-19 调查结论：本地库完全不存在计费元数据字段）

官方 API 上线后，服务端按 `billingSource` 区分记账，两个缺陷同时解决；本地 SQL 模板、窗口算法（`fiveHourResetDate` / `nextMondayMidnightUTC` / `anchoredMonthEnd`）、`OpenCodeGoLimits` 硬编码上限常量与 `Shell/` 子进程模块随之删除。历史细节见 Git 历史与本文件旧版本。
