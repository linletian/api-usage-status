# Auto Refresh Stops After Hours — Investigation

> **最后更新**: 2026-06-27　|　**作者**: 现象调查
> **状态**: 间接证据坐实 App Nap 冻结 `Task.sleep`；待下次复现拿到配对时间序列直接确认
> **影响范围**: `RefreshService` 5 分钟自动刷新循环（手动刷新不受影响）
> **下一步**: 用 `build/APIUsageStatus.app` 跑一次复现，把日志片段贴回来定位

---

## 1. 现象

- 用户反馈：5 分钟自动刷新**一开始几个小时正常工作**，之后**完全停止**，需要手动触发才能恢复。
- "几个小时"在反馈中是用户感知而非测量；从症状分布看，最可能是 3–5 小时区间。
- 状态栏、窗口、菜单栏**均正常**——UI 层无影响。
- **手动刷新（全局 + 单实例）任何时候都正常**，能拿到所有数据——网络 / supplier / persistence 都健康。
- **关键约束**：手动刷新后定时器**不恢复**；**退出 APP 后重新启动可以恢复正常**。
  - 当前 `triggerManualRefresh` 走 `runPreemptiveCycle`，会 `markPreempted` 旧 cycle 并 cancel 旧 `cycleTask`
  - 这条事实把嫌疑收敛到 **只有 periodic 路径自身**——不是数据层

---

## 2. 调查范围

| 层 | 是否嫌疑 | 理由 |
|---|---|---|
| 网络 / API Key | 否 | 手动刷新正常 → 凭据、网络、supplier 实现均健康 |
| 持久化（instances / balance snapshot）| 否 | 文件 I/O 走 actor 同步方法；无异步挂起点 |
| AppState merge / slot 数据 | 否 | `mergeCycleResult` 是纯 actor 内同步方法 |
| `RefreshService` `performRefresh` | 否 | 手动刷新走同一路径成功 |
| **`RefreshService` periodic loop 的 `Task.sleep`** | **是** | 唯一会"启动后自跑"且与手动路径独立的异步挂起点 |
| `restartTimer` 取消 race | 否 | 调查期间无设置变更，无 `RefreshService started` 穿插日志 |

---

## 3. 关键代码路径（当前版本）

`RefreshService` 经过 `bd35c3b feat(refresh): per-instance refresh + cycle-slot concurrency model` 重构。当前结构：

### 3.1 Periodic timer 入口（`start()`）

```swift
// APIUsageStatus/Services/RefreshService.swift:90-127
func start(interval: TimeInterval? = nil) {
    if let interval = interval {
        refreshInterval = interval * 60
    }
    stop() // Cancel any existing task

    let intervalSeconds = refreshInterval

    refreshTask = Task { [weak self] in
        guard let self = self else { return }
        await self.runPeriodicCycle()  // initial refresh
        while !Task.isCancelled {
            // [cycle tick + sleep drift logs — 见 §5]
            try? await Task.sleep(for: .seconds(intervalSeconds))
            // [drift measurement — 见 §5]
            if !Task.isCancelled {
                await self.runPeriodicCycle()
            }
        }
    }
    logger.info("RefreshService started with interval: \(self.refreshInterval)s")
}
```

### 3.2 Periodic cycle 入口（`runPeriodicCycle()`）

```swift
// APIUsageStatus/Services/RefreshService.swift:157-181
private func runPeriodicCycle() async {
    // [periodic cycle skipped log — 见 §5]
    if currentToken != nil { return }
    let token = CycleToken(targetUUID: nil)
    let task = Task<Void, Error> {
        try await self.performRefresh(targetUUID: nil, token: token)
    }
    adoptCycle(token: token, task: task)
    do { try await task.value }
    catch { logger.info("Periodic cycle ended: \(error)") }
    clearCycleIfStill(token)
}
```

### 3.3 手动刷新入口（`runPreemptiveCycle()`）

```swift
// APIUsageStatus/Services/RefreshService.swift:192-244
private func runPreemptiveCycle(targetUUID: String?) async {
    currentToken?.markPreempted()           // 1. mark old preempted
    let oldTask = cycleTask                 // 2. capture old performRefresh
    let newToken = CycleToken(targetUUID: targetUUID)
    let task = Task<Void, Error> {
        try await self.performRefresh(targetUUID: targetUUID, token: newToken)
    }
    adoptCycle(token: newToken, task: task) // 3. publish new owner
    oldTask?.cancel()                       // 4. cancel old performRefresh
    if let oldTask = oldTask {              // 5. wait for old to unwind
        do { try await oldTask.value }
        catch is CancellationError {}
        catch { logger.error("Pre-empted cycle threw non-cancellation error: \(error)") }
    }
    do { try await task.value }             // 6. wait for new to finish
    catch { logger.info("Preemptive cycle ended: \(error)") }
    clearCycleIfStill(newToken)             // 7. clear slot if still owner
}
```

### 3.4 任务结构图

```
┌─────────────────────────────────────────┐
│ refreshTask（outer Task，cooperative pool）│
│                                         │
│  while !Task.isCancelled {              │
│    sleep(300s)  ← 可能被 App Nap 冻结   │
│    runPeriodicCycle()                   │
│  }                                      │
│                                         │
│  ┌──────────────────────────────────┐   │
│  │ runPeriodicCycle (actor)         │   │
│  │                                  │   │
│  │  Task<Void, Error> {             │   │
│  │    performRefresh (actor)        │   │
│  │  }  ← cycleTask                  │   │
│  └──────────────────────────────────┘   │
└─────────────────────────────────────────┘

手动刷新触发：
┌─────────────────────────────────────────┐
│ triggerManualRefresh / triggerInstance  │
│  → runPreemptiveCycle (actor)           │
│     → 新 cycleTask 抢占                 │
│     → 旧 cycleTask 被 cancel            │
│  ※ refreshTask（外层 sleep 循环）       │
│    完全不受影响                          │
└─────────────────────────────────────────┘
```

**关键洞察**：手动刷新起的是**新 Task**（`cycleTask`），与 periodic loop 的 `refreshTask` 是**完全独立的两条 Task**。手动刷新**不会**去碰那条被 App Nap 冻结的 `refreshTask.sleep`。

---

## 4. 嫌疑根因（按可能性排序）

### 4.1 App Nap 冻结 `Task.sleep` 续延 — **主嫌疑（已获强间接证据）**

**机制**：

- `APIUsageStatusApp.swift:23` 设置 `NSApp.setActivationPolicy(.accessory)`——菜单栏常驻，无 Dock 图标，无可见窗口。
- macOS 对菜单栏 accessory 应用**默认启用 App Nap**：约 30s 无用户交互后，cooperative pool 上的 dispatch timer 被节流。
- 用户离开电脑、屏幕睡眠、笔记本合盖时进一步收紧。
- `Task.sleep(for: .seconds(N))` 内部用 dispatch timer 调度续延；App Nap 期间该续延**被无限期推迟**（不是简单延后）。
- 用户交互瞬间 App Nap 释放，periodic sleep 续延**一次性补触发**多条积压任务——这就是用户看到的「burst」模式。

**为什么一开始正常**：用户在电脑前时 App Nap 触发条件不满足（鼠标移动、菜单栏重绘等都打破不活跃判定）。

**为什么手动刷新正常**：手动刷新走 `runPreemptiveCycle` → 新建 Task → 不依赖被冻结的 `refreshTask` → 立即执行。

**为什么手动刷新不恢复 timer**：手动刷新**根本没碰**被冻结的 `refreshTask`，那条 Task 仍卡在 `Task.sleep` 上。

**为什么退出重启能恢复**：杀进程 → App Nap 释放 → 新进程里 `Task.sleep` 不再被冻结。

### 4.2 actor 重入 + `restartTimer` 取消时序 — **次嫌疑**

`restartTimer` 走 `start()` → `stop()` + 创建新 task。如果被多次调用，task 队列出错。

- 但调查期间无设置变更，无 `RefreshService started` 穿插日志
- 手动刷新走 `runPreemptiveCycle`，**根本不调 `restartTimer`**

→ 排除。

### 4.3 网络层 retry 累积延迟 — **信息性**

单个 `apiKeyRef` 拉取最坏情况：3 × 30s + 重试间隔 ≈ **93s**。

如果用户某个 API key 持续失败，**周期膨胀**到 6.5 分钟。但这是**变慢**而不是**停止**——不符合症状。

→ 不构成主因。

### 4.4 Persistence 文件锁 — **基本排除**

所有 I/O 都在 actor 内串行，`atomicWrite` 用 temp + rename，不留持久锁。

→ 排除。

### 4.5 系统日志间接证据（2026-06-27 PID 55483 分析）

在本次调查（无新代码时）抓取的实际数据：

**PID 55483 存活 21 小时（2026-06-26 18:48 → 2026-06-27 15:47），refresh category 仅 11 条日志**：

| 时间 | 距上一次 | 模式 |
|---|---|---|
| 06-26 23:46:25 | 4h57m | 单条 |
| 06-27 08:15:11 | **8h29m** | 单条 |
| 06-27 11:59:33 | 3h44m | burst 开始 |
| 06-27 11:59:39 | 6s | burst |
| 06-27 11:59:41 | 2s | burst |
| 06-27 13:07:53 | 1h08m | burst 开始 |
| 06-27 13:07:54 | 1s | burst |
| 06-27 13:07:56 | 2s | burst |
| 06-27 13:43:20 | 35m | burst 开始 |
| 06-27 13:43:22 | 2s | burst |
| **06-27 13:43:22 → 15:47:35** | **2h04m 完全静默** | **timer 冻结** |
| 06-27 15:47:35 | — | 用户从菜单 Cmd+Q 退出 |

**排除项**：

- `pmset -g log` 全程无系统 Sleep/Wake 事件 → 系统未休眠
- `~/Library/Logs/DiagnosticReports/` 无 APIUsageStatus 崩溃报告 → 进程未 crash
- 同时段有 **4871 条** 系统 framework 日志 → 进程活着，**唯独 timer 死了**
- 无 `RefreshService started` 日志穿插 → restartTimer 未被调用
- 退出是 AppKit `perform action for menu item` + 多窗口 `op:0` 关闭序列 → 用户主动 Cmd+Q

**burst 模式解读**：11:59、13:07、13:43 三个时间点出现「数秒内 2-3 条 cycle」——这是用户交互（点菜单栏/切窗口）瞬间 App Nap 短暂释放，periodic sleep 续延**一次性补触发**多条积压。最长的 2h04m 静默对应用户离开 + 屏幕睡眠期间。

---

## 5. 验证方案

### 5.1 多角度诊断日志（2026-06-27 部署）

代码改动位于：

- `APIUsageStatus/Services/RefreshService.swift`
- `APIUsageStatus/APIUsageStatusApp.swift`
- `APIUsageStatus/Utilities/Logger.swift`（新增 `lifecycle` category）

#### 5.1.1 角度 A：Timer 活性 + Sleep 实测

```swift
// RefreshService.swift:108-128 (start() 循环体重写)
while !Task.isCancelled {
    let sleepStartedAt = Date()
    logger.info("cycle tick: next interval=\(intervalSeconds)s, now=\(sleepStartedAt)")
    try? await Task.sleep(for: .seconds(intervalSeconds))
    let actualSleep = Date().timeIntervalSince(sleepStartedAt)
    let drift = actualSleep - intervalSeconds
    let driftPct = intervalSeconds > 0 ? (drift / intervalSeconds) * 100.0 : 0
    if driftPct > 50 {
        logger.warning("sleep drift: requested=\(Int(intervalSeconds))s actual=\(Int(actualSleep))s drift=+\(Int(drift))s (\(Int(driftPct))%) — possible App Nap suspension")
    } else {
        logger.debug("sleep drift OK: requested=\(Int(intervalSeconds))s actual=\(Int(actualSleep))s drift=+\(Int(drift))s")
    }
    if !Task.isCancelled { await self.runPeriodicCycle() }
}
```

- `cycle tick` —— 每周期一次（`.info`），与 `Refresh cycle completed` 配对得到实际周期
- `sleep drift OK` —— 每周期一次（`.debug`，默认隐藏）
- `sleep drift` —— **drift > 50% 时升级 `.warning`，是 App Nap 的直接证据**

#### 5.1.2 角度 B：Periodic 抢占碰撞

```swift
// RefreshService.swift:158-162 (runPeriodicCycle)
if currentToken != nil {
    logger.debug("periodic cycle skipped: token already in flight (id=\(ObjectIdentifier(currentToken!)))")
    return
}
```

#### 5.1.3 角度 C：App 生命周期

```swift
// APIUsageStatusApp.swift:observeLifecycle()
// 注意：NSWorkspace 事件走 NSWorkspace.shared.notificationCenter，
//      NSApplication active/resign 事件走 NotificationCenter.default。
//      混挂会让 didBecomeActive/didResignActive 静默丢失。
lifecycle: app launched at <Date>
lifecycle: system willSleep at <Date>
lifecycle: system didWake at <Date>
lifecycle: screens didSleep at <Date>
lifecycle: screens didWake at <Date>
lifecycle: app didBecomeActive at <Date>
lifecycle: app didResignActive at <Date>
lifecycle: app will terminate at <Date>
lifecycle: ProcessInfo initial: thermal=0 lowPowerMode=false
lifecycle: ProcessInfo thermalState changed → <0..3>
lifecycle: ProcessInfo isLowPowerModeEnabled → <true/false>
```

> **2026-06-27 修正**：初版（移植自 commit 932899d）把全部 6 个事件都挂到 `NSWorkspace.shared.notificationCenter`，导致 `didBecomeActive` / `didResignActive` **永不触发**——决策表里「空档对齐 didResignActive → App Nap 路径坐实」这一最关键信号失效。已修正：NSWorkspace 事件用 `NSWorkspace.shared.notificationCenter`，NSApplication 事件用 `NotificationCenter.default`。

#### 5.1.4 角度 D：触发来源区分

```swift
// RefreshService.swift:138 (triggerManualRefresh)
logger.info("RefreshService manual refresh triggered")

// RefreshService.swift:135 (restartTimer)
logger.info("RefreshService restartTimer called with interval: \(interval * 60)s — this cancels the existing periodic task")
```

#### 5.1.5 决策表

| `cycle tick` 间隔 | `sleep drift` | 配合 `lifecycle` 事件 | 含义 |
|---|---|---|---|
| ≈ 300s（±5%）| `drift OK` | 无 sleep / wake 事件 | 健康，App Nap / 系统休眠排除 |
| 远大于 300s | **drift 警告** | 空档对齐 `willSleep → didWake` | **系统休眠冻结 timer**，确凿 |
| 远大于 300s | **drift 警告** | 空档对齐 `screens didSleep`（无 system 事件）| 仅显示睡眠，仍可冻结 |
| 远大于 300s | **drift 警告** | 空档对齐 `didResignActive` | **App Nap 路径坐实** |
| ≈ 300s 但 periodic cycle 偶尔没 fire | `drift OK` | 无 sleep / wake 事件 | 可能 §4.2 race，查 `restartTimer` / `periodic cycle skipped` |
| 永远不出现新的 `cycle tick` | — | 进程仍存活（无 `app will terminate`）| Task 已死，需查 §4.2 race |
| `periodic cycle skipped` 高频 | — | — | manual 点击抢周期入口，与卡住可能无关 |
| `ProcessInfo thermal → 2/3` 或 `lowPowerMode=true` | — | — | 系统级节流，可能加重 App Nap |

**查询命令**：

```bash
# 实时流（推荐先开再启动 app）
log stream --predicate 'subsystem == "com.example.APIUsageStatus"' --info --debug --style compact

# 历史快照
log show --last 6h --predicate 'subsystem == "com.example.APIUsageStatus"' --info --debug --style compact

# 仅看告警（drift 异常 + thermal 严重）
log show --last 6h --predicate 'subsystem == "com.example.APIUsageStatus" AND messageType >= 16' --style compact
```

### 5.2 排除 §4.2 race

调查期间不需要——已确认无 `RefreshService started` 穿插。如果下次复现时**仍**看到 `restartTimer called` 日志穿插在 `cycle tick` 静默期前，说明设置变更引发的 task 取消 race 是复合诱因。

---

## 6. 修复候选（待 §5 直接确认后决策）

按侵入性从小到大排列：

### 候选 A：`DispatchSourceTimer` 替换 `Task.sleep`

```swift
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
timer.setEventHandler { [weak self] in
    Task { await self?.performRefresh() }
}
timer.resume()
```

- **优势**：DispatchSourceTimer 与 RunLoop 关联更紧；通常在 App Nap 唤醒后会立即补偿触发
- **代价**：与 Swift 并发风格不一致；需要手动管理生命周期

### 候选 B：`Timer.scheduledTimer` on main RunLoop

类似 A，但用 Foundation `Timer`。侵入性最低。

- **代价**：必须 add 到 RunLoop 才能 fire；与 actor 隔离的 performRefresh 仍需 hop

### 候选 C：进程级反 App Nap（Info.plist）—— **菜单栏 accessory 应用推荐**

```xml
<!-- Info.plist -->
<key>NSAppSleepDisabled</key>
<true/>
```

- **优势**：从根上解决，timer 不会被冻结
- **适用性**：**菜单栏常驻应用本来就不需要 App Nap**——它们没有可见窗口，App Nap 节流毫无意义
- **代价**：
  - 始终禁用 App Nap，电量轻微增加（实测对菜单栏应用影响可忽略）
  - App Store 审核 risk（self-use 不受影响）

### 候选 D：保留 `Task.sleep`，加 App Nap 通知监听

监听 `willSleep` / `didWake`，睡眠时记录时间戳，唤醒时立即触发一次刷新补齐。

- **优势**：侵入性最小
- **代价**：逻辑复杂；要新增状态字段；不能避免 App Nap 期间的延迟，只能补偿

**当前推荐**（待 §5 直接确认后）：优先试 **候选 C**（一行 Info.plist），如果 sleep drift 警告消失即根因坐实，再视情况做 **A** 作为更彻底的修复。

---

## 7. 当前状态

| 项 | 状态 |
|---|---|
| 现象描述 | ✅ 完成 |
| 间接证据 | ✅ 完成（PID 55483 21h refresh-category 11 条日志分析）|
| 嫌疑根因排序 | ✅ 完成（§4.1 App Nap 为主嫌疑）|
| 多角度诊断日志 | ✅ 已部署（`build/APIUsageStatus.app`，2026-06-27）|
| 直接证据（sleep drift 警告 + lifecycle 配对）| ⏳ 等下次复现 |
| 修复方案决策 | ⏳ 等直接证据后决策（候选 C 优先）|

---

## 8. 验证产物

### 8.1 已构建 .app

```
build/APIUsageStatus.app
```

- 配置：Release
- 架构：universal（x86_64 + arm64）
- 签名：ad-hoc（runtime hardened，自用足够）
- 包含全部 11 条诊断日志（`strings build/APIUsageStatus.app/Contents/MacOS/APIUsageStatus | grep -E "cycle tick|sleep drift|periodic cycle skipped|ProcessInfo|lifecycle:|app launched"`）

### 8.2 首次启动

```bash
# 如果 Gatekeeper 拦截：Finder 里右键该 .app → 打开 → 打开
open /Users/linletian/Documents/SoftwareWorkspace/api-usage-status-myworktree/fix-fix-bugs-2/build/APIUsageStatus.app

# 或替换已安装版本
killall APIUsageStatus
cp -R build/APIUsageStatus.app /Applications/
open /Applications/APIUsageStatus.app
```

### 8.3 复现期间的实时观察

```bash
# 在另一终端实时流（建议复现开始前就启动）
log stream --predicate 'subsystem == "com.example.APIUsageStatus"' --info --debug --style compact

# 复现结束后拉历史快照
log show --start "<复现开始时间>" --end "<复现结束时间>" \
    --predicate 'subsystem == "com.example.APIUsageStatus"' \
    --info --debug --style compact > ~/Desktop/refresh-debug-$(date +%Y%m%d-%H%M).log
```

---

## 9. 跟进清单

### 9.1 下次复现时

- [ ] 用 `build/APIUsageStatus.app` 替换现有版本运行
- [ ] 复现开始前在另一终端启动 `log stream`
- [ ] 复现结束后拉 `log show` 历史
- [ ] 关注以下信号：
  - 是否出现 `sleep drift: requested=300s actual=...` 警告
  - 警告时刻前后是否有 `app didResignActive` / `screens didSleep` / `ProcessInfo thermal → 2`
  - 是否出现「cycle tick 完全消失但进程存活」的窗口
- [ ] 把日志片段贴回到本 doc 的 §10「复现记录」或 issue

### 9.2 如果 sleep drift 警告坐实 App Nap

- [ ] 临时改 Info.plist 加 `NSAppSleepDisabled=true`
- [ ] 重新构建（`xcodebuild -scheme APIUsageStatus -configuration Release -derivedDataPath build/derivedData build`）
- [ ] 运行观察一周，确认 `sleep drift OK` 全部正常、`cycle tick` 间隔稳定在 300s
- [ ] 若 OK → 候选 C 作为正式修复合并

### 9.3 如果 sleep drift 警告不出现

- [ ] 检查 `cycle tick` 是否出现 → 排除 Task 完全死掉
- [ ] 检查 `restartTimer called` 是否穿插 → 排除 §4.2 race
- [ ] 重新评估嫌疑根因排序，可能需要新假设

---

## 10. 复现记录（待填）

| 日期 | 复现时长 | cycle tick 总数 | sleep drift 警告次数 | burst 次数 | 根因 | 备注 |
|---|---|---|---|---|---|---|
| 2026-06-27 | 21h（PID 55483，无新日志）| 11 | 0（旧版无此日志）| 3 | 疑似 App Nap（间接证据）| 调查用数据 |

---

## 11. 相关文件索引

### 11.1 代码

- `APIUsageStatus/Services/RefreshService.swift:90-127` —— `start()` 主循环 + cycle tick + sleep drift 日志
- `APIUsageStatus/Services/RefreshService.swift:135-141` —— `restartTimer()` + 日志
- `APIUsageStatus/Services/RefreshService.swift:138-150` —— `triggerManualRefresh()` + 日志
- `APIUsageStatus/Services/RefreshService.swift:157-181` —— `runPeriodicCycle()` + skip 日志
- `APIUsageStatus/Services/RefreshService.swift:192-244` —— `runPreemptiveCycle()`（cycle-slot 模型）
- `APIUsageStatus/APIUsageStatusApp.swift:14-26` —— `lifecycleObservers` 字段
- `APIUsageStatus/APIUsageStatusApp.swift:21-32` —— launch 日志 + `observeLifecycle()` 调用
- `APIUsageStatus/APIUsageStatusApp.swift:103-130` —— ProcessInfo 初始快照 + thermal/power observer
- `APIUsageStatus/APIUsageStatusApp.swift:132-134` —— terminate 日志
- `APIUsageStatus/APIUsageStatusApp.swift:170-194` —— `observeLifecycle()` 方法（6 种 NSWorkspace/NSApplication 事件）
- `APIUsageStatus/Utilities/Logger.swift:46` —— `lifecycle` category

### 11.2 文档与计划

- `/Users/linletian/.claude/plans/commit-932899d-enchanted-graham.md` —— 本次移植 + 新增日志的实施计划
- commit `932899d` —— 原始 commit（未合并，含初版日志）

### 11.3 系统命令参考

```bash
# PID 切换 / 进程退出轨迹
log show --last 2d --predicate 'subsystem == "com.example.APIUsageStatus"' --info --style compact

# 系统休眠 / 唤醒
pmset -g log | grep -E "Sleep|Wake|DarkWake|Hibernate"

# App Nap 子系统（不一定有针对我们进程的条目）
log show --last 2d --predicate 'subsystem == "com.apple.AppNap"' --info --debug --style compact

# RunningBoard 对我们进程的 assertion 状态变化
log show --last 2d --predicate 'subsystem == "com.apple.runningboard" AND eventMessage CONTAINS "APIUsageStatus"' --info --style compact
```