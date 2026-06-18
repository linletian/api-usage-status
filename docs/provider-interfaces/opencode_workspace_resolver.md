# OpenCode Workspace ID 调研与解析器说明

> 文档目的：说明为什么"See details"链接需要的 OpenCode workspace ID 无法通过 CLI / API 直接获取，记录所有排查过的途径，以及最终采用的日志扫描兜底方案。
> 编写日期：2026-06-18
> 关联代码：`APIUsageStatus/Suppliers/OpenCodeWorkspaceResolver.swift`

---

## 1. 结论先行

| 问题 | 答案 |
|------|------|
| 有公开 HTTP 接口能查 workspace ID 吗？ | **没有** |
| opencode CLI 会暴露 workspace ID 吗？ | **不会**（所有子命令、debug 路径、本地配置都没有） |
| 本地数据库 `~/.local/share/opencode/opencode.db` 存了吗？ | **没有**（`workspace` 表为空、`session.workspace_id` 全 NULL） |
| 那用户访问 `https://opencode.ai/workspace/<id>/go` 里的 `<id>` 从哪来？ | **OpenCode 后端生成**，仅服务端持有 |
| 那本机怎么拿到？ | **grep 日志**：当请求余额不足时，Zen 后端会在错误体里嵌入完整 workspace URL，OpenCode 进程把它写到 `~/.local/share/opencode/log/*.log` |

---

## 2. 排查过的渠道

### 2.1 OpenCode CLI 子命令

```
opencode providers list          → 只列凭据（api / oauth），不含 workspace
opencode providers login          → OAuth 流程，无 CLI 输出 workspace ID
opencode debug config             → 只显示 plugin / mcp / 指令配置
opencode debug paths              → 仅返回 data/log/cache 等目录
opencode debug info               → 版本 / OS / 插件列表
opencode stats                    → 历史用量聚合，无 workspace 字段
opencode session list             → session 列表（本地表的列也不含 wrk_）
opencode db ".tables"             → 表里 workspace / session.workspace_id 都为空
```

### 2.2 本地数据文件

| 路径 | 检查项 | 结果 |
|------|--------|------|
| `~/.local/share/opencode/auth.json` | 各 provider 的 API key / OAuth 凭据 | 仅凭证，无 workspace |
| `~/.local/share/opencode/opencode.db` 表 `workspace` | 行数 | 0 行 |
| 同库 `session.workspace_id` 列 | 1096 条 session 中非 NULL 数 | 0 |
| 同库 `session.share_url` 列 | 同上 | 0 |
| `~/.local/share/opencode/storage/`、`snapshot/` | 工作区相关字段 | 全部为空 |

### 2.3 OpenCode Zen HTTP API

Base URL：`https://opencode.ai/zen/go/v1/`

| 端点 | 用途 | 是否返回 workspace ID |
|------|------|------------------------|
| `POST /v1/chat/completions` | LLM 调用 | 否（成功响应里只有 cost / usage） |
| `GET /v1/models` | 模型列表 | 否 |
| `POST /v1/chat/completions`（无效 model） | 触发错误 | `ModelError` 消息，不含 wrk_ |
| `GET /v1/me`、`/v1/billing`、`/v1/usage`、`/v1/workspaces`、`/v1/balance`、`/v1/key/info` 等 | 推测的管理端点 | 全部 404 |

实测响应（节选）：

```http
$ curl -i https://opencode.ai/zen/go/v1/models -H "Authorization: Bearer sk-..."
HTTP/2 200
content-type: application/json

{"object":"list","data":[{"id":"minimax-m3",...}]}
```

```http
$ curl -i https://opencode.ai/zen/go/v1/chat/completions -d '{"model":"nonexistent"}'
HTTP/2 401
{"type":"error","error":{"type":"ModelError","message":"Model nonexistent-model-test is not supported"}}
```

无任何响应头或 body 字段携带 `wrk_` ID。

### 2.4 OpenCode 源码（anomalyco/opencode）

GitHub 搜索确认 workspace ID 的生成逻辑：

```
packages/core/src/workspace.ts:
  if (!id) return schema.make("wrk_" + Identifier.ascending())
  create: () => schema.make("wrk_" + Identifier.ascending()),
```

`Identifier.ascending()` 是 OpenCode 后端的 ID 生成器（Snowflake 风格），ID 永远在服务端创建，本地无同步。

`actor.ts` 里的 `workspace()` 函数返回 `actor.properties.workspaceID`，但 `actor` 是后端上下文对象，不下发给 CLI。

---

## 3. 唯一可行的途径：错误体嵌入

实测当 API key 余额为 0 时：

```http
$ curl -i -X POST https://opencode.ai/zen/go/v1/chat/completions \
    -d '{"model":"glm-5.1","max_tokens":1,"messages":[{"role":"user","content":"x"}]}'
HTTP/2 200
{"error":{"message":"Insufficient balance. Manage your billing here: https://opencode.ai/workspace/wrk_01ABCDEFGHIJKLMNOPQRSTUVWX/billing",...}}
```

错误 message 字段直接拼了完整 URL。OpenCode 进程把这个 message 记到自己的日志：

```
~/.local/share/opencode/log/2026-06-17T073630.log:
  ERROR ... service=session.processor ... error=Insufficient balance. Manage your billing here: https://opencode.ai/workspace/wrk_01ABCDEFGHIJKLMNOPQRSTUVWX/billing
```

由此可以反推 `wrk_` ID（`wrk_01ABCDEFGHIJKLMNOPQRSTUVWX`）。

⚠️ 局限：
- 只有用户触发过余额不足错误时才有这条记录。
- 用户充值后再次出现余额不足才会再写一行；但 wrk_ ID 是稳定的（一个账号对应一个），所以扫到一次即可永久缓存。

---

## 4. 解析器设计

### 4.1 行为

解析器对外暴露四档 API：

| 方法 | 线程 | 用途 |
|------|------|------|
| `cachedWorkspaceID() -> String?` | 同步、零 IO | **view 层专用** —— 只读 UserDefaults，永不扫描日志 |
| `resolveWorkspaceID() -> String?` | 同步、可能阻塞最多 5s | 测试 / 一次性全量解析；不在 view 路径上调用 |
| `prewarm()` | 异步（`Task.detached(priority: .utility)`） | App 启动时清缓存后后台扫描，确保切换账号后重启自动生效 |
| `refreshCache()` | 异步（`Task.detached(priority: .utility)`） | `RefreshService` 每次 OpenCode 刷新成功后调用，清缓存后后台重扫，账号切换无需重启即可感知 |

`resolveWorkspaceID()` 的执行步骤：
1. 先查 `UserDefaults.standard.string(forKey: "opencode.workspaceID")`。
2. 命中即返回（一次扫描，永久缓存）。
3. 未命中：扫日志目录找第一个匹配 `https://opencode\.ai/workspace/wrk_[A-Z0-9]+/` 的 URL，提取 `wrk_...` 部分，写回 `UserDefaults` 并返回。grep 模式带尾部 `/`，保证 `[A-Z0-9]+` 字符类被路径分隔符终止；Swift 侧再用 `wrk_[A-Z0-9]+(?=/)` 校验一次。这样小写或混合大小写 ID（如 `wrk_01kh8...`）会被彻底拒掉。
4. 都没找到返回 `nil`。

### 4.2 为什么 view 层不直接调 `resolveWorkspaceID`

- 日志扫描可能阻塞最多 5s（grep + `DispatchSemaphore.wait`）。
- `UsageCardView.providerURL` 是 SwiftUI `body` 链上的计算属性，会在主线程同步求值。
- 首次缓存为空时调用会卡住弹窗渲染。

因此 view 层只调 `cachedWorkspaceID()`，把扫描挪到 App 启动时 `prewarm()`。如果用户在 `prewarm` 还没完成时就打开弹窗，看到的是 `/zh/go` 兜底 URL；下一次 refresh 触发 view 重新求值时就会拿到已缓存的 workspace URL。

### 4.3 为什么用 grep 而不是 Swift 读文件

- 日志文件可能很大（实测 `opencode.db` 600MB+；log 文件单文件常达数十 MB）。
- Swift `String(contentsOf:)` 会一次读进内存。
- `Process` + `/usr/bin/grep -hoE pattern` 只把匹配行输出到 stdout，恒定内存。
- `DispatchSemaphore` 等 5 秒超时，超时即放弃（视作"暂无"，下次重新扫描）。

### 4.4 路径候选

按 `opencode debug paths` 实证输出排序：

1. `$HOME/.local/share/opencode/log`
2. `$XDG_DATA_HOME/opencode/log`（仅当环境变量显式设置）

### 4.5 UI 行为

`UsageCardView.providerURL`（`Views/UsageCardView.swift:14-30`）的 `opencode` 分支：

- 缓存命中 → `https://opencode.ai/workspace/<id>/go`
- 缓存未命中 → `https://opencode.ai/zh/go`（带登录按钮，用户自助登录后浏览器重定向到自己的 workspace）

App 启动时在 `AppDelegate.applicationDidFinishLaunching` 末尾调用 `OpenCodeWorkspaceResolver.prewarm()`，触发后台扫描。

### 4.6 测试覆盖

`APIUsageStatusTests/OpenCodeWorkspaceResolverTests.swift`：

| 用例 | 验证内容 |
|------|----------|
| `testReturnsNilWhenDirectoryEmpty` | 空目录 → `nil`，不写缓存 |
| `testReturnsNilWhenLogsHaveNoWorkspaceURL` | 无 URL 的日志 → `nil` |
| `testExtractsWorkspaceIDFromLogAndCachesIt` | 匹配 → 返回 ID 并写入 UserDefaults |
| `testCachedValueIsReturnedWithoutRescanning` | 缓存命中后新增的 log 不被读 |
| `testClearCacheRemovesCachedValue` | `clearCache()` 清空缓存 |
| `testNonLogFilesAreIgnored` | `.txt` 含 URL 也不被读 |
| `testMultipleLogsReturnAnID` | 字典序最小的 log 文件胜出（`scanLogs` 现在对 entries 排序，确保 first-hit 确定性） |
| `testScanReturnsNilWhenContentsOfDirectoryFails` | override 指向文件而非目录时，`contentsOfDirectory` 抛错被 catch，scan 返回 nil |
| `testScanReturnsNilWhenGrepBinaryMissing` | `grepPath` 指向不存在路径时，`Process.run()` 抛错被 catch，scan 返回 nil |
| `testScanReturnsNilOnTimeout` | 用 fake 慢 grep + 紧 timeout 验证 timeout 分支：scan 在 5s 内返回 nil，且僵尸子进程被 reap |
| `testCachedWorkspaceIDReturnsNilWhenEmpty` | 空缓存 → `nil` |
| `testCachedWorkspaceIDDoesNotScan` | 缓存空 + 有匹配 log → 仍返回 `nil`（不触发扫描） |
| `testCachedWorkspaceIDReturnsSeededValue` | 手动写入 UserDefaults 后能读到 |
| `testPrewarmPopulatesCache` | `prewarm()` 后台任务在 2s 内写好缓存 |
| `testRegexAcceptsCanonicalUppercaseID` | 标准大写格式 `wrk_01ABCDE...` 通过 |
| `testRegexRejectsLowercaseID` | 全小写 ID 被拒（`wrk_01kh8...`） |
| `testRegexRejectsMixedCaseID` | 混合大小写 ID 被拒（`wrk_01Kh8...`） |
| `testRegexRejectsNonAlphanumericID` | 含连字符等特殊字符的 ID 被拒 |
| `testRegexStopsAtNonAlphanumeric` | 验证 `(?=/)` 终止符对短 ID 同样有效 |

---

## 5. 已知风险与未来工作

| 风险 | 缓解 |
|------|------|
| OpenCode 日志格式变化（URL 模板修改） | 正则集中在 `OpenCodeWorkspaceResolver.urlRegex` / `idRegex`；5 个 boundary 测试 + `validateFormatContract()` 里的 debug-only `assert`（参照 `knownGoodSample`）会在 dev 启动时立即触发 |
| OpenCode wrk_ 字符集将来混入小写 / 特殊字符 | 同上：测试失败 + assert 告警，提醒同步更新正则和 `knownGoodSample` |
| 用户从未触发过余额不足错误 | 兜底 URL `/zh/go` 含登录入口；scan 路径在 `AppLogger.opencode` 记 `info` 级日志 |
| workspace ID 因切换账号或后端迁移发生变化 | `prewarm()` 每次启动时先清缓存再扫描；`refreshCache()` 每次 OpenCode 刷新成功后清缓存异步重扫 —— 无需手动干预或重启，下次刷新周期后自动生效 |
| macOS sandbox / 权限阻止 grep 访问日志目录 | `scanLogs` 把 `contentsOfDirectory` / `Process.run()` / 超时 / 非零退出 全部以 `warning` 级记到 `AppLogger.opencode`（category `opencode`），通过 Console.app 可见 |
| 超时后子进程变僵尸 | `process.terminate()` 后用 `process.isRunning` 轮询最多 2s 等待 reap，2s 未退出则 `fault` 级别记日志后放弃 wait |
| XCTest 未来并行化导致 `testDirectoryOverride` / `grepPath` / `scanTimeout` 全局可写变量竞态 | 当前依赖 XCTest 默认串行执行；如需并行化，将 resolver 改为基于实例的 API（每个测试持有一个 resolver 实例） |

---

## 6. 验证步骤

```bash
# 1. 单元测试
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project APIUsageStatus.xcodeproj -scheme APIUsageStatus \
  -destination 'platform=macOS' \
  -only-testing:APIUsageStatusTests/OpenCodeWorkspaceResolverTests \
  ENABLE_TESTABILITY=YES test

# 2. 手动验证 fallback URL
defaults delete APIUsageStatus opencode.workspaceID 2>/dev/null
# 打开 menubar popup → OpenCode 卡片 "See details" 应打开 https://opencode.ai/zh/go

# 3. 手动验证 workspace URL
mkdir -p ~/.local/share/opencode/log
echo 'ERROR ... https://opencode.ai/workspace/wrk_TESTID123/billing' \
  > ~/.local/share/opencode/log/manual.log
defaults delete APIUsageStatus opencode.workspaceID
# 打开 menubar popup → OpenCode 卡片 "See details" 应打开 https://opencode.ai/workspace/wrk_TESTID123/go
```