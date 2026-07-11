# Auto Refresh Stops After Hours — Investigation

> **最后更新**: 2026-07-10　|　**作者**: 现象调查 + 设计变更记录（§13）+ spinner 泄漏修复（§12.6）
> **状态**: §4.1 / §4.6 修复实施完成；§4.7 spinner 泄漏**已修复**（统一清理 helper + 外层 do/catch），age-based force-clear 保留作 defense-in-depth
> **影响范围**: `RefreshService` 5 分钟自动刷新循环（手动刷新不受影响）
> **下一步**: 上线后用 §13.8 的预期信号验证 App Nap 路径不再冻结 timer，且系统 sleep 完全不受影响

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

**当前推荐**（已修订）：**候选 C 已撤回**（参见 §13 —— `NSAppSleepDisabled=true` 是进程级反 sleep 标志，会同时阻止系统睡眠，对笔记本用户不可接受）。**最终选择候选 A**（`DispatchSourceTimer`）—— 仅换 timer 实现路径，不影响 power management，对系统 sleep 完全透明。

---

## 7. 当前状态

| 项 | 状态 |
|---|---|
| 现象描述 | ✅ 完成 |
| 间接证据 | ✅ 完成（PID 55483 21h refresh-category 11 条日志分析）|
| 嫌疑根因排序 | ✅ 完成 + 扩展（§4.1 App Nap 坐实；§4.6 系统睡眠 + wake 不补发新发现；§4.7 cycle-slot 泄漏嫌疑，详见 §12）|
| 多角度诊断日志 | ✅ 已部署（`build/APIUsageStatus.app`，2026-06-27）|
| 直接证据（sleep drift 警告 + lifecycle 配对）| ⚠️ **部分** —— RunningBoard `AppDrawing` heartbeat gap 21h55m + 写盘 mtime 断层 22h 已坐实 App Nap；但 `sleep drift` 警告明文受 Swift `os.Logger` privacy 遮挡（见 §12.5）|
| 复现记录 | ✅ §10 第一条（2026-06-27） + §12（2026-07-01，22h 静默）|
| 修复方案决策 | ✅ **已修订** —— 候选 C 撤回（power management 副作用，详见 §13）；候选 A `DispatchSourceTimer` 进入实施；候选 D（wake 补发）+ cycle-slot 老化兜底（§4.7）保留；候选 B 维持冗余排除 |

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

### 9.4 本轮（§12 + §13）落地项

> 优先级与依据见 §12.8 修订版。**不依赖读 drift 警告明文**——App Nap 主因已被 RunningBoard heartbeat gap 直接坐实。

#### §4.1 修：**撤回候选 C**，改用候选 A `DispatchSourceTimer`

> ~~候选 C `NSAppSleepDisabled=true` 已撤回~~。该开关是进程级 anti-sleep 标志，会同时阻止 Mac 系统睡眠，对笔记本用户不可接受。详见 §13。

- [x] `Info.plist` 加 `NSAppSleepDisabled=true` —— **撤回**（已删除）|
- [x] `RefreshService.swift` 改写 `start()` / `stop()`，用 `DispatchSourceTimer` 替换 `Task.sleep` 循环；删除 `cycle tick` / `sleep drift` / `actualSleep` 诊断日志；新增 `_testHasTimerSource` 测试 seam
- [ ] 重建并替换 `/Applications/APIUsageStatus.app`，运行 1 周
- [ ] 验证：§13.8 heartbeat gap 不再出现；持久化文件 mtime ≤ 5 分钟内；`pmset -g log` 无 `PreventUserIdleSystemSleep` 类断言记录
- [ ] OK 后合并

#### §4.6 修：wake 补发

- [x] `APIUsageStatusApp.swift` 的 `observeLifecycle()` 在 `system didWake` block 内触发一次 `Task { await refreshService.triggerManualRefresh() }`（已在工作树，未 commit）
- [ ] 跨维护性睡眠后首拍就拿到最新数据，无须等 5 分钟

#### §4.7 修：cycle-slot 老化兜底

- [x] 方案 A：`runPeriodicCycle` 在 `currentToken != nil` 时检查 token 年龄；超过 `2 × refreshInterval` 强制 `cycleTask?.cancel()` + 清空，再发起新 cycle（已在工作树，未 commit）
- [x] 单测覆盖：`testStaleCycleTokenIsForceClearedOnNextPeriodicTick` + `testFreshCycleTokenIsNotForceCleared`（已在工作树）
- [x] 新增回归测试 `testStopCanBeCalledWhenTimerIsNotRunning` + `testStartThenStopClearsTimerSource`（已加，锁住 DispatchSourceTimer 生命周期）
- [x] **2026-07-10 增补**：统一 `clearRefreshStateIfStill(_ token:)` helper + `performRefresh` 外层 `do/catch` 兜住 `Task.checkCancellation()` 在 inner catch 之前抛出的路径（用户报告的 spinner 泄漏主路径）
- [x] 新增 4 条回归测试（`RefreshServiceCycleSlotTests.swift` §12.6 区段）：missing-UUID 早返回清理、全局无 enabled instances 清理、合作取消中途的 UUID 清理、preempt 不变量
- [x] 新增测试 seam `_testCancelCurrentCycleTask` 让测试可以确定性触发 `Task.checkCancellation()` 路径

#### §12.5 解红条：Logger.swift privacy

- [ ] 把 `APIUsageStatus/Utilities/Logger.swift` 第 13–15 / 17–19 / 21–23 / 25–27 / 29–31 五处 `logger.X("\(message)")` 改成 `logger.X("\(message, privacy: .public)")`
- [ ] 重新构建并部署
- [ ] 下次复现时 `log show --predicate 'subsystem == "com.example.APIUsageStatus"'` 能直接读到明文 `cycle tick` / `sleep drift` / `Periodic cycle skipped` / `Starting refresh cycle` 等
- [ ] 这条不阻塞 §4.1 修复，纯调查效率提升，建议单独一 PR

---

## 10. 复现记录（待填）

| 日期 | 复现时长 | cycle tick 总数 | sleep drift 警告次数 | burst 次数 | 根因 | 备注 |
|---|---|---|---|---|---|---|
| 2026-06-27 | 21h（PID 55483，无新日志）| 11 | 0（旧版无此日志）| 3 | 疑似 App Nap（间接证据）| 调查用数据 |
| 2026-07-01 | 22h+（PID 76691）| 未读到（隐私遮挡）| 未读到（隐私遮挡）| heartbeat gap = 1（21h55m）+ system sleep 2 次（3.5h / 4.4h）| §4.1 App Nap **坐实**；§4.6 系统睡眠 + wake **新发现**；§4.7 cycle-slot 泄漏 **结构可能** | §12 完整证据 |
| 2026-07-07 | n/a（修复实施日）| n/a（新机制不再使用 cycle tick 概念）| n/a | n/a | n/a | 候选 C 撤回 → 候选 A 实施；§13 设计变更记录 |

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

# AppDrawing 心跳 gap 判定（候选主因直接证据）
grep "AppDrawing.*target:76691" /tmp/lifecycle.log \
  | awk '{print $1, $2}' \
  | python3 -c "
import sys
from datetime import datetime
prev = None
for line in sys.stdin:
    p = line.strip().split()
    ts = datetime.strptime(p[0]+' '+p[1], '%Y-%m-%d %H:%M:%S.%f')
    if prev is not None and (ts-prev).total_seconds() > 90:
        print(f'GAP {prev} -> {ts} = {(ts-prev).total_seconds():.0f}s')
    prev = ts
"
```

---

## 12. 复现记录 #2 — 2026-07-01 PID 76691（22h 静默 + 新症状）

> **更新日期**：2026-07-02　|　**作者**：现象调查（接续 §10 第二条记录）
> **数据来源**：`/tmp/apiusage-sudo.log`（主进程子系统日志）+ `/tmp/apiusage-lifecycle.log`（RunningBoard + AppDrawing）
> **关键约束**：主进程 refresh / lifecycle 日志**仍为 `<private>`**（详见 §12.5），`sleep drift` 警告明文无法读
> **状态**：App Nap **坐实**；新增 §4.6 系统睡眠因；新增 §4.7 cycle-slot 泄漏因（结构可能但本机未直接观察）

### 12.1 进程与时窗

- **PID 76691**，ELAPSED ~5 天（2026-06-27 ~18:47 启动，至调查时仍存活）
- 调查窗口：`2026-07-01 22:00:00` ~ `2026-07-02 22:30:00`
- 进程状态：S（sleeping，等事件）
- Binary 已包含 §5.1 全部 11 条诊断字符串（`cycle tick` / `sleep drift` / `Periodic cycle skipped` 等）

### 12.2 硬证据（不依赖日志明文）

| 指标 | 数值 | 含义 |
|---|---|---|
| `~/Library/Application Support/APIUsageStatus/3B67E671-…-3B67E671.json` mtime（Deepseek 余额快照，每次成功 refresh 写）| **2026-07-01 22:55:21** | 最后一次成功 refresh 写盘 |
| `instances.json` mtime | 2026-06-27 16:24:41 | MiniMax auto-discover 未触发，正常 |
| 距下次成功写盘间隔 | **22h 14min**（至 2026-07-02 21:09 调查时刻）| 期望 ~264 次（5min × 264），实际 **0** |
| `AppDrawing` heartbeat 静默 gap | **21h55m19s**（22:52:29 → 20:47:49）| WindowServer 停止向 PID 76691 发 App Nap 续延 |
| 系统睡眠跨度 | 12:56:30→16:23:42 (3.5h) + 16:24:10→20:47:30 (4.4h) | 部分覆盖 heartbeat 静默期 |
| 纯运行状态导致的静默 | **~14h**（22:54 → 12:56:30，期间无系统睡眠）| **直接对应 §4.1** |

### 12.3 主因坐实路径

```
22:00–22:52    heartbeat 60s 间隔正常 (22:00:29, 22:01:29, …, 22:51:29, 22:52:29)
22:54 起       AppDrawing 心跳停止 → WindowServer 不再视 app 为"在画"
22:55:21       最近一次成功 refresh 写盘（最后一个活动周期）
...             14h 运行状态无写盘、无心跳（纯 App Nap 路径）
12:56:30       系统进入 Maintenance Sleep 3.5h
16:23:42       Wake（短暂）
16:24:10       系统再次入睡 4.4h
20:47:30       Wake；20:47:49 AppDrawing 心跳恢复（19s 后）
20:47:49–21:09 heartbeat 60s 间隔恢复但 refresh 仍未恢复 → 部分 App Nap 释放 ≠ 完全释放
```

### 12.4 RunningBoard 断言剖析（PID 76691）

持有的 App Nap 相关断言：
- `appnap:AppDrawing` —— WindowServer 只向真正在画窗口的进程发
- `appnap:AppVisible` —— WindowServer 只向前台 app 发
- `launchservicesd:RoleUserInteractive`

**未持有** `appnap:PreventAppNap` 断言 —— 这正是 §6 候选 C 想加的。`AppDrawing` / `AppVisible` 在 WindowServer 看来窗口被遮挡 / 缩到最小 / 关掉时就停发，menu bar accessory app 没有窗口概念，但 macOS 仍按"无窗口可见"标准把它归入 nap 候选。

> 心跳确实在 22:54:00 → 20:47:49 这段完全静默；wake 之后正常恢复。这是对 §4.1 App Nap 主因**直接证据级别**的确认，无须看到 `sleep drift` 明文。

### 12.5 主进程日志仍是 `<private>`（后续调查阻塞点）

所有主进程（PID 76691）的 `com.example.APIUsageStatus:refresh` / `:lifecycle` 日志 message body 是 `<private>`。**`sudo log show` 也无法显示**。

根因：

```swift
// APIUsageStatus/Utilities/Logger.swift:13-15
func debug(_ message: String) {
    logger.debug("\(message)")      // ← interpolation 默认 privacy: .auto → .private (Xcode 14+)
}
```

Swift `os.Logger` 自 Xcode 14 起对带 interpolation 的格式串默认打 private 标记。要解红条：

```swift
logger.debug("\(message, privacy: .public)")
```

这一改动是**独立 action item**，已进入 §9.4 跟进清单。

### 12.6 新症状：实例永久卡 spinner（cycle-slot 泄漏嫌疑）

用户新报告的现象，**调查文档未涵盖**：

> copilot 和 opencode go 实例一直卡在刷新状态，全局 Refresh 前也有执行刷新时的旋转图标，但不是手工触发的 → 手动触发 Refresh 后成功 → 后续自动刷新仍无效

代码路径上属于 **cycle-slot 泄漏**（参见 §3.2）：

- `RefreshService.runPeriodicCycle` `try await task.value`（line 184）在 `performRefresh` 永久悬挂时不会返回
- `clearCycleIfStill(token)`（line 191）永不执行
- `currentToken` 永不 → nil；后续所有 `runPeriodicCycle` 调用被 `if currentToken != nil { return }` 短路
- `appState.refreshingInstanceUUIDs`（`performRefresh` line 290 写入）只在 `pushProgress()` 每组成功/失败时清 / CancellationError 路径清 / 最终 cleanup（line 591–592）清，**永久悬挂的那一组 UUID 永远不清**
- UI spinner 来自陈旧 `refreshingInstanceUUIDs` ← 用户观察的"实例卡 spinner + Refresh 前已存在"
- 用户手动点 Refresh → `runPreemptiveCycle` line 208 `markPreempted()` + line 220 `adoptCycle` 接管，新 cycle cleanup 正确清空 → 体感"手动刷新成功"
- 但 **`refreshTask` 外层 `Task.sleep` 仍被 App Nap 冻结** → 自动定时不恢复 ← 用户观察的"后续自动刷新仍无效"

> 本机**未直接观察到** `Periodic cycle skipped` 明文（被 §12.5 隐私遮挡）。**结构上可能，但没有明文佐证**——下次复现前需先修 Logger privacy。

> **修复状态**：✅ 已修复（2026-07-10）。引入 `clearRefreshStateIfStill(_ token:)` helper（对称于既有的 `clearCycleIfStill`），把 `refreshState` + `refreshingInstanceUUIDs` 的清理统一到一个出口；`performRefresh` 全函数体外包一个 `do/catch` 兜住 `Task.checkCancellation()` 在 line 410 inner catch 之前抛出的路径（即本次用户报告的实际泄漏路径）；preempt 不变量由 helper 的 `currentToken === token` 守卫保证。4 条新回归测试锁住该修复（见 `RefreshServiceCycleSlotTests.swift` §4.7 区段）。`runPeriodicCycle` 的 age-based force-clear（§4.7 段落）作为 defense-in-depth 保留 —— 永远挂在 retry / withRetry sleep 上的 cycle 仍会被它在下次 tick 时强制清场。

### 12.7 §4 根因排序更新

| § | 嫌疑 | 本次复现状态 |
|---|---|---|
| 4.1 | App Nap 冻结 `Task.sleep` | ✅ **坐实** —— 21h55m heartbeat gap + 22h 写盘断层。修复手段**已变更**：候选 C 撤回，候选 A `DispatchSourceTimer` 实施（§13）|
| 4.2 | actor 重入 + `restartTimer` race | 排除 —— 无 `restartTimer called` 日志穿插 |
| 4.3 | 网络 retry 累积延迟 | 不构成主因 —— 22h 全空而非变慢 |
| 4.4 | persistence 文件锁 | 排除 |
| **4.6 新** | 系统睡眠 + wake 后 Refresh 不补发 | **新发现** —— 12:56:30 / 16:24:10 两次 Maintenance Sleep 跨越 heartbeat 静默期；wake 后 22 分钟 refresh 仍未恢复 |
| **4.7 新** | cycle-slot 泄漏（永久悬挂场景）| **结构嫌疑** —— §12.6 描述结构可行；本机未观察到 `Periodic cycle skipped` 明文（受 §12.5 隐私遮挡） |

### 12.8 实施优先级（2026-07-07 修订）

| 优先级 | 动作 | 解决 | 成本 |
|---|---|---|---|
| **1** | **§6 候选 A**：`RefreshService` 改用 `DispatchSourceTimer` 替换 `Task.sleep` 循环；删除 `cycle tick` / `sleep drift` 诊断日志 | §4.1 App Nap | ~30 行 + 删 ~15 行 |
| **2** | §6 候选 D（裁剪版）：`didWake` handler → `triggerManualRefresh()` | §4.6 系统睡眠补发 | 5–10 行 |
| **3** ✅ 已修复（2026-07-10） | cycle-slot 老化兜底：**主方案** = 统一 `clearRefreshStateIfStill(_ token:)` helper + 外层 `do/catch` 包住 `performRefresh` 兜住 `Task.checkCancellation()` 在 inner catch 之前抛出的路径；**保留** = `runPeriodicCycle` age-based force-clear 作为 defense-in-depth | §4.7 instance spinner 永久卡 | ~50 行（含 4 条新测试）|
| ~~撤回~~ | ~~§6 候选 C：`Info.plist NSAppSleepDisabled=true`~~ | ~~撤回原因：process-level 标志同时阻止系统 sleep，对笔记本用户不可接受；详见 §13~~ |
| 可选 | Logger.swift 隐私改 `.public`（§12.5）| 后续调查直接读 drift 警告 | 改 3 处 |

**候选 B（`Timer.scheduledTimer` on main RunLoop）经评估为冗余**，不推荐 —— A 选了 `DispatchSourceTimer` 之后所有定时机制都不再被节流，B 不能解决 §4.6 / §4.7 任何一项。

### 12.9 与 §10 复现记录的关系

§10 的 `2026-06-27` 行反映调查首轮复现（PID 55483，无新代码，仅借持久化 mtime + RunningBoard 做旁路推断）。
本节 `2026-07-01` 行反映调查第二轮复现（PID 76691，本轮诊断二进制已上线 5 天，用户主动重新启动过一次进程；记录 / 分析 / 修复方案均较首轮升级）。

两轮共同的"决策表"逻辑（§5.1.5）验证：

| 信号 | §10 第 1 行 | §12（本次）|
|---|---|---|
| 进程仍存活 | ✅ | ✅ |
| `cycle tick` 大段消失 | ✅（间接，11 条共 21h）| ✅（心跳 21h55m gap 直接）|
| 配上系统 Sleep/Wake | 无系统 sleep | 2 次 Maintenance Sleep |
| 配上 `app didResignActive` | 未读到 | 未读到（隐私遮挡，需要 §9.4 修）|
| 配上 `app didResignActive` → `cycle tick` 间隔远大于 300s | 未读到 | 同上（隐私遮挡）|

---

## 13. 设计变更记录：候选 A（`DispatchSourceTimer`）取代候选 C（`NSAppSleepDisabled`）

> **更新日期**：2026-07-07　|　**作者**：实施记录
> **状态**：候选 C 撤回；候选 A 进入实施；§4.6 + §4.7 保留。

### 13.1 变更背景

§12.8 把候选 C（`Info.plist NSAppSleepDisabled=true`）列为 §4.1 修复的最高优先级，代码落到工作树但**未发布**。

**Power management 评审否决候选 C**：`NSAppSleepDisabled` 是 process-level 标志，不只让定时器免于 App Nap，同时也告诉 Power Management"本进程有持续性工作，请据此判断系统能否进入 sleep"。对笔记本用户（合盖即睡眠）这一行为不可接受——本 app 只是一款菜单栏用量监控，合盖后无需也不应阻止系统睡眠。

### 13.2 替代方案：候选 A（`DispatchSourceTimer`）

`RefreshService.start()` 改用 `DispatchSourceTimer` 调度周期触发：

- DispatchSourceTimer 是 **kernel-level timer**。与 `Task.sleep` 走 Swift Concurrency cooperative pool 不同，它走内核 timer 队列，**RunningBoard 不对该队列类别施加 App Nap 节流**。
- DispatchSourceTimer **不影响 power management**——既不阻止 App Nap（事实上本 timer 仍可被 App Nap 暂停，但因不在 cooperative pool 上，**实际**不被节流），也不阻止系统 sleep。
- 用户离开电脑数小时后回来，menu bar 仍正常刷新，系统可正常进入 sleep → 唤醒。
- 改动 ~30 行（`RefreshService.swift`），无新依赖。

### 13.3 关键代码骨架

```swift
private var timerSource: DispatchSourceTimer?
private static let timerQueue = DispatchQueue(
    label: "com.example.APIUsageStatus.refresh.timer",
    qos: .utility
)

func start(interval: TimeInterval? = nil) {
    if let interval = interval { refreshInterval = interval * 60 }
    stop()
    let intervalSeconds = refreshInterval
    let source = DispatchSource.makeTimerSource(queue: Self.timerQueue)
    source.schedule(
        deadline: .now() + intervalSeconds,
        repeating: intervalSeconds,
        leeway: .milliseconds(250)
    )
    source.setEventHandler { [weak self] in
        guard let self = self else { return }
        Task { [weak self] in
            guard let self = self else { return }
            await self.runPeriodicCycle()
        }
    }
    source.resume()
    timerSource = source
    Task { [weak self] in
        guard let self = self else { return }
        await self.runPeriodicCycle()  // initial fire parity
    }
    logger.info("RefreshService started with interval: \(intervalSeconds)s (DispatchSourceTimer, leeway=250ms)")
}

func stop() {
    timerSource?.cancel()
    timerSource = nil
    logger.info("RefreshService stopped")
}
```

### 13.4 测试 seam 影响

`_testRunPeriodicCycle`、`_testSeedStaleToken`、`_testHasCurrentToken`、`_testCurrentTokenAge`、`_testSetRefreshInterval` **全部保留**——`_testRunPeriodicCycle` 与 dispatch source event handler 最终汇合于同一 `runPeriodicCycle()` 方法。

新增 `_testHasTimerSource: Bool` 测试 seam + 两条新回归测试：

- `testStopCanBeCalledWhenTimerIsNotRunning` — 重复 `stop()` 不崩、最终 `_testHasTimerSource == false`
- `testStartThenStopClearsTimerSource` — `start()` → `_testHasTimerSource == true`；`stop()` → `_testHasTimerSource == false`

### 13.5 旧机制遗物清理

`cycle tick` / `sleep drift OK` / `sleep drift` 警告日志**全部删除**——其唯一目的是检测 `Task.sleep` 的 App Nap 续延，新机制下永远不会触发。

§5.1.1「角度 A：Timer 活性 + Sleep 实测」中的决策表**整体失效**——`sleep drift` 信号不再存在；§13.6 新决策表取代。

### 13.6 新决策表（取代 §5.1.5）

| 信号 | 含义 |
|---|---|
| `Refresh cycle completed` 间隔 ≈ `refreshInterval`（±10%）| 健康；kernel timer 未被节流 |
| `Refresh cycle completed` 间隔远大于 `refreshInterval` | **kernel timer 被节流**（极端：系统休眠期间）—— 查 `lifecycle: system didWake` 配对 |
| `Forcibly clearing stale cycle token: age=...` 出现 | §4.7 cycle-slot 老化兜底触发；查 `performRefresh` 卡点 |
| `Periodic cycle skipped: token already in flight` 高频 | 手动点击抢周期入口；与本修复无关 |
| `ProcessInfo thermal → 2/3` 或 `lowPowerMode=true` | 系统级节流；DispatchSourceTimer 仍会触发（kernel 不被影响），仅记录 |

### 13.7 替换的二进制版本

`build/APIUsageStatus.app` 重新构建后替换 `/Applications/APIUsageStatus.app`。重建版：

- 包含 `DispatchSourceTimer`（§13.2-§13.3）
- 包含 `didWake` → `triggerManualRefresh()`（已在工作树）
- 包含 §4.7 cycle-slot 老化兜底（已在工作树）

不包含：

- `Info.plist NSAppSleepDisabled=true`（**撤回**）
- `Logger.swift privacy .public`（独立 PR，未在本轮处理）

### 13.8 预期验证信号（重建版上线后）

- §12.2 描述的 21h55m heartbeat gap：`DispatchSourceTimer` 不被 App Nap 节流，**预期 gap 不再出现** —— 这是修复坐实的关键证据
- §12.2 描述的 22h 持久化 mtime 断层：同理，**预期 mtime 间隔稳定在 `refreshInterval` ±10%**
- 系统 sleep/wake：行为完全不受影响。验证 `pmset -g log` 无 `PreventUserIdleSystemSleep` 类断言记录；本进程**不**持有 power management 断言

### 13.9 已撤回的候选 C 实施残留

若 §13.7 重建版上线时旧候选 C 实施（`Info.plist NSAppSleepDisabled=true`）还在工作树，必须先撤掉。否则会出现 §13.1 描述的"系统不让睡"回归。

本仓库当前（2026-07-07）状态：候选 C 已从 `Info.plist` 撤回；本节确认无残留。