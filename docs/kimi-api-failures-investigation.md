# Kimi API 频繁失败 vs CLI `/usage` 正常 — Investigation

> **日期**: 2026-07-30
> **状态**: 诊断日志已落地,**未实机验证** —— 合并前需要在真实环境触发一次 Kimi 失败,确认 `log show` 真的能看到 `body=` 那一行(否则整套诊断白做,见 §4 "实机验证步骤")
> **报告**: app 调 Kimi API 经常失败,但 `kimi` CLI 的 `/usage` 始终正常

---

## 1. 现象

(待用户补充:失败频率、错误提示、是状态栏完全 N/A 还是偶发、是否和具体账户/套餐相关)

## 2. 候选根因(按概率排)

### 假设 1 — 凭证类型不匹配(高)

- CLI 用的是 `kimi login` 的 **OAuth access_token**,存于 `~/.kimi-code/credentials/kimi-code.json`,约 1 小时过期
- app 用的是 **Kimi Code Console 创建的 API Key**,存于 macOS Keychain
- `docs/provider-interfaces/kimi.md:201` 自承:"Console API Key 对 `/usages` 的兼容性未逐 Key 验证(调研时手头无 Key,OAuth token 实测 200)"——**当时就没用 Console Key 实测过**
- 如果服务端 `/usages` 端点只对 OAuth 会话放行,Console Key 会被持续 401
- 区分:curl 测试时 **OAuth 200 + Console Key 401** 即确认

### 假设 2 — 字段类型严格校验触发 `parsingError`(中)

- `KimiResponseParser.numericValue` 对 `limit` / `used` 严格数值校验,非数值直接 abort 整次 refresh
- `KimiResponseParserTests.testNonNumericLimitThrows` 显式锁定了这个行为
- 某些套餐 / 会员等级可能让 `limit` 变成 `"unlimited"` 字符串,parser 会抛 `parsingError("Non-numeric value for limit...")`
- 跟 `resetTime` 解析失败(写 0 静默)不同,这种是"宁死不屈"——会看到整次 refresh fail 而不是单字段降级
- 区分:日志里 `Kimi response parse failed: ... Non-numeric value for limit ...` 即确认

### 假设 3 — User-Agent / 限流(低-中)

- app 用 URLSession 默认 User-Agent(类似 `api-usage-status/1.0`),CLI 用 `kimi-code/x.x.x`
- 服务端可能对未知 UA 限流或拒绝
- 区分:日志里 `HTTP error: statusCode=403, body=...` 或 `429` 即确认

## 3. 诊断日志覆盖范围(本分支已加)

为了让上述任一假设都能被一次失败定位,本分支在以下两个失败点加了带定位信息的响应体前 512 字符记录:

| 位置 | 触发条件 | 日志内容 |
|------|---------|---------|
| `NetworkClient.swift:41-70` | HTTP status 非 2xx(对**所有** supplier) | `HTTP error: url=<endpoint URL>, statusCode=<code>, body=<前 512 字符>` |
| `KimiSupplier.swift:19-42` | parser 抛错(任意 `RefreshError`) | `Kimi response parse failed: provider=<Provider rawValue>, url=<endpoint URL>; error=<error description>; body=<前 512 字符>` |

**实现细节**:
- 截断方式: 先取 `data.prefix(4096)` (4 KB 字节窗口,足以覆盖 512 个 UTF-8 字符的最坏情况),再 `String(data:encoding:.utf8)`,最后 `String(s.prefix(512))` 按字符切。**不是** `data.prefix(512)` 按字节切(那样会在多字节字符中间切断,导致 `String(data:encoding:)` 返回 nil,日志变成 `<undecodable>`)。
- 字段值: 全部 `privacy: .public`(经 `AppLogger.publicError`),`log show` / Console.app 能看到真实值而不是 `<private>`。这是**诊断专用**的隐私豁免,不要扩展到成功路径。
- URL + provider: 多实例并发刷新时区分供应商,避免看到 401 不知道是 Kimi 还是 Copilot 撞的。

## 4. 复现步骤(用户执行)

1. 合并本 PR 后,**先做一次实机验证**(关键,见下)
2. 触发一次 Kimi 刷新失败(自然触发或等 5 分钟定时)
3. 查日志(任选一种):
   ```bash
   log show --predicate 'subsystem == "com.example.APIUsageStatus" AND category == "supplier"' --last 5m
   log show --predicate 'subsystem == "com.example.APIUsageStatus" AND category == "network"' --last 5m
   ```
   或在 Console.app 过滤 `subsystem:com.example.APIUsageStatus`
4. 把日志中包含 `body=` 的行贴到本节下方的"复现数据"小节

### 4.1 实机验证(合并前必做,别跳)

新加的 `AppLogger.publicError` 依赖 Swift `os.Logger` 的 `OSLogMessage` 重载。如果重载没被正确选中,所有插值还是 `.private`,`log show` 仍然会显示 `<private>`,**整个 PR 的诊断价值归零**。

**验证脚本**:
```bash
# 1. 临时把 KimiSupplier.fetchUsage 里的 body 改成固定字符串,触发一次强制失败
#    (或者直接断网/换错误 Key 让 parser / network 报一次错)
# 2. 然后跑:
log show --predicate 'subsystem == "com.example.APIUsageStatus" AND category == "supplier"' --last 1m --info
# 3. 检查输出
#    - 如果 body= 后面是 <private> → publicError 没生效,需要修
#    - 如果 body= 后面是真实响应内容 → 成功,可以放心合并
```

也可以不修改代码,等真实环境自然失败一次——但如果连续几天都不失败(用户说的是"频繁",但可能不等于"100%"),验证会被卡住。**建议临时改 Key 强制触发一次**。

## 5. 复现数据(待填)

```
<paste log here>
```

## 6. 拿到响应后的处置表

| 看到什么 | 假设成立 | 下一步(独立分支) |
|---------|---------|------------------|
| `statusCode=401, body={"error":"invalid_token"\|"unauthorized"...}` | 1 | 改用 OAuth token + refresh 流程,涉及 keychain 多凭证管理 |
| `statusCode=200` 但 parser 抛 `Non-numeric value for limit/used` | 2 | parser 加宽容模式:把 `limit: "unlimited"` 视作无限套餐,而不是 abort |
| `statusCode=403\|429` 且 body 含 UA 提示 | 3 | `NetworkClient` 加 `User-Agent: kimi-code/x.x.x`(或类似) |
| 其它 | - | 开新分支深入,补额外日志或重试策略 |

## 7. 本分支实际包含的改动

| Commit | 文件 | 性质 |
|--------|------|------|
| 1. `fix(kimi-test): align fixture with test name` | `KimiResponseParserTests.swift` | 测试 fixture 改对(补合法 `limits` + 坏 weekly),让 `testUnparseableWeeklyResetTimeDoesNotDeclareFiveHourPolicy` 真的测它名字说的东西;**不修生产代码** |
| 1. (同 commit) `docs(kimi): explain retain-previous policy in else branch` | `KimiResponseParser.swift` | 上一条对应的生产侧注释,说清楚 e462fa3 选了"宁可误保、不可误丢"的保守策略;**无业务行为变更** |
| 2. `chore(kimi): surface response body on HTTP + parse failures` | `NetworkClient.swift` / `KimiSupplier.swift` / `Logger.swift` | 失败路径打响应体前 512 字符,带 URL + provider,`privacy: .public` 防止 `log show` 出 `<private>` |

**注**: 之前一版计划里写的"在 `KimiResponseParser` 的 `else` 分支用 `json["usage"] == nil` 守卫来收紧 5h 策略"被回退掉了——理由是用"周配额在不在"推断"账号是否真的有 5h 窗口"是脆弱的,会回退 e462fa3 明确要修的 partial-degrade 场景。e462fa3 选择"5h 缺失一律保留上次 5h 倒计时"是 conservative,不要没新证据就反转。

**Commit 1 的语义**:
- 测试 fixture 现在长这样:合法 5h `limits` 块 + 坏 weekly `usage` 块
- 现在的代码路径走 `if let detail = rollingEntry?["detail"]`(5h 有效),`parsedEndTimeMs > 0` → 不设 policy
- 不动 `else` 分支

## 8. 备注

- **复现数据 ≠ 复现代码**: 第 5 节等的是**用户**拿 app 跑一次失败的 Kimi 刷新,把日志贴过来——不是由 Claude 重跑测试。xcodebuild test 在沙盒里成功跑通不能替代真实网络环境的复现。
- **加日志对成功路径无影响**(只在 catch 块)。
- **NetworkClient 改动对所有 supplier 都生效**: 任何 supplier 撞 non-2xx 都会多一行 body 预览。这是设计意图(同样适用于未来的"私有端点 + 特殊凭证"模式),但同时也是**扩大的 leak 面**——见 §9。
- **不要把 `privacy: .public` 沿用到成功路径**: `AppLogger.publicError` 的注释明确写了"诊断专用,never for tokens / secrets / PII"。未来如果有人想让成功日志可见,需要单独评估。

## 9. Leak 面评估

按 `AppLogger.publicError` 的注释,失败路径上 `privacy: .public` 的字段有:

| 字段 | 评估 |
|------|------|
| URL | 安全。Kimi/Copilot/DeepSeek/MiniMax 端点 URL 不带 query 参数。 |
| HTTP status code | 安全。 |
| 响应体(NetworkClient 通用) | **有条件不安全**。OpenCode 从本地 SQLite 读,响应体可能含 server-defined user identifiers。本分支是**诊断专用**,不会扩散到成功路径。 |
| 响应体(KimiSupplier) | **安全**。Kimi `/usages` 响应是 quota 数字(`limit` / `used` / `resetTime`),无 PII。 |
| error 实例 | 内部 RefreshError,不含 PII。 |

如果将来某个 supplier 失败响应体里出现 PII,首先应该在该 supplier 内部 catch 块(类似 `KimiSupplier` 现在的做法)用 `.public` 显式 log,而不是依赖 NetworkClient 的通用 log——后者会污染无关 supplier 的失败日志。
