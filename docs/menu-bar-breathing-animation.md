# 菜单栏呼吸动画设计文档

## 1. 动机

旧版菜单栏在 critical 状态下使用 1Hz 可见性切换（toggle visibility）来警示用户；warning 状态则保持静态显示。这种早期实现有两个问题：

- **视觉突兀**：槽位整体以固定频率在显示和消失之间切换，在人眼余光中造成明显干扰，尤其在菜单栏这种长期可见的区域，容易引发视觉疲劳。
- **状态覆盖单一**：可见性切换只覆盖 critical 状态，warning 状态下槽位与 normal 状态视觉上无法区分，用户需要主动打开用量面板才能感知到预警。

呼吸动画（Breathing Animation）替代上述机制后，用 **平滑的 shadow 脉冲** 替代二元的可见性开关，视觉上柔和得多。同时 warning 状态也获得了独立的呼吸节奏，不再是"要么安全、要么严重"的二值体验。三个状态形成完整的梯度：安全（无动画）→ 警告（慢速呼吸）→ 严重（快速呼吸），用户无需查看面板就能凭直觉判断紧急程度。

## 2. 数学原理

所有呼吸参数集中在 `BreathingConfig` 结构体中，每种状态独立配置完整的呼吸周期。呼吸周期分为吸入（inhale）和呼出（exhale）两段，分别控制 shadow 从弱到强、再从强到弱的完整脉冲。

**Warning 配置**：

| 参数 | 值 |
|---|---|
| 周期总时长 | 4.0 秒 |
| 吸入时长 | 1.4 秒 |
| 呼出时长 | 2.6 秒 |
| shadow 模糊半径范围 | 0 → 6 |
| shadow 透明度范围 | 0 → 0.7 |

**Critical 配置**：

| 参数 | 值 |
|---|---|
| 周期总时长 | 2.0 秒 |
| 吸入时长 | 0.7 秒 |
| 呼出时长 | 1.3 秒 |
| shadow 模糊半径范围 | 0 → 8 |
| shadow 透明度范围 | 0 → 0.85 |

核心相位函数 `breathingPhase()` 将经过的时间映射到 [0, 1] 区间，表示当前呼吸强度。映射规则：

- 吸入阶段（0 → inhaleDuration）：先对 elapsed 取模获得周期内的位置，然后归一化到 [0, 1]，再做 `t * t` ease-out 缓出。这意味着 shadow 在吸入开始时加速增长，越接近峰值越平缓，视觉上像自然的深呼吸。
- 呼出阶段（inhaleDuration → cycleDuration）：同样归一化后用 `1 - t * t` ease-in 缓入。shadow 在呼出开始时缓慢减弱，接近结束时快速归零，模仿肺部排气时先快后慢的节奏。

shadow 半径和透明度都是纯线性插值：

- `shadowRadius()`: minBlurRadius + phase * (maxBlurRadius - minBlurRadius)
- `shadowOpacity()`: minOpacity + phase * (maxOpacity - minOpacity)

两个函数从 phase 的 [0, 1] 均匀映射到各自的目标范围，配合 ease-out / ease-in 的 phase 曲线，最终渲染出的脉冲具有自然的加速-减速特征。

## 3. 渲染实现

呼吸动画的渲染层在 MenuBarIconRenderer 中。每个渲染周期，如果槽位 uuid 在 `breathingSlots` 集合中，则用 `CACurrentMediaTime() - breathingStartTime` 作为 elapsed 时间，按槽位自身的 colorState（warning / critical）选取对应的 BreathingConfig，计算当前 phase、shadow 半径和透明度。

实际渲染通过 Core Graphics 的 `CGContext.setShadow(offset:blur:color:)` 实现，其中 offset 恒为零、blur 传当前计算半径、color 为原文字色叠加呼吸透明度。在调用 `renderTwoLineSlot()` 绘制槽位文字之前，先 `saveGState()` 并设置 shadow，绘制完两行文字后 `restoreGState()` 恢复。shadow 的作用范围仅限于当前槽位的文字内容（shortName 和百分比/金额），不会影响相邻槽位。

关键设计决策：

- **只叠加 shadow，不修改文字内容**。槽位的文字（简称和数值）始终正常绘制，呼吸效果完全由 shadow 的模糊半径和透明度变化产生。这意味着文字在任何时候都清晰可读，呼吸只是外围光晕的强弱变化。
- **不修改原始文字颜色**。shadow 颜色使用原文字颜色叠加呼吸透明度，因此 shadow 色调始终与槽位的 Warning（黄色）或 Critical（红色）保持一致。
- **动画驱动**：`Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true)` 在 `@MainActor` 主 RunLoop 上以 5Hz 周期回调 `onNeedsDisplay` 闭包，触发菜单栏图标重绘。当所有 breathing 槽位退出 Warning/Critical 状态时 Timer 被 `invalidate()` 并置 nil。常量 `breathingAnimationInterval: TimeInterval = 0.2` 定义在 `APIUsageStatus/MenuBar/MenuBarIconRenderer.swift:53`。

## 4. 定时器选型：Timer vs CVDisplayLink

呼吸动画需要按固定间隔触发重绘。本项目对比过两种方案：

- **`CVDisplayLink`（CoreVideo，60Hz）**：与显示器刷新率同步的显示链路。CoreVideo C 回调在独立线程执行，需通过 `DispatchQueue.main.async` 派发到主队列以保证 `@MainActor` 闭包安全。优点是帧率与屏幕刷新率严格对齐。缺点是**持续以 60Hz 以上速率触发重绘**，对一个只在 2–4s 周期上做相位插值的 UI 来说严重过采样，per-frame 渲染成本是整体 CPU 占用的主导项（实测呼吸期间常驻占用一个核心，>80% CPU）。

- **`Timer.scheduledTimer`（Foundation，5Hz）**：依托 `@MainActor` 的主 RunLoop，以 0.2s 间隔（即 5Hz）周期触发 `onNeedsDisplay`。呼吸周期 2s / 4s 对应每周期 10–20 个采样点，对 shadow 半径 / 透明度的线性插值而言视觉上完全平滑（人眼无法分辨 5Hz 与 60Hz 在 2–4s 慢周期上的差异）。per-frame 渲染成本约为 CVDisplayLink 方案的 1/12，菜单栏空闲时不再持续占用核心。

**决策**：本项目选用 `Timer.scheduledTimer` 5Hz 方案。`CADisplayLink` 虽在 macOS 14+ 可用，但与本项目 macOS 13 最低部署目标不兼容（且即便可用，60Hz 仍属过度采样）。CVDisplayLink 在本场景下被验证为不必要的过度工程。常量 `breathingAnimationInterval: TimeInterval = 0.2` 在 `MenuBarIconRenderer.swift:53` 定义，`breathingStartTime` 在 `startBreathingAnimation()` 中重置为 `currentTimeProvider()`，每次 stop→start 形成新的相位原点（避免长时漂移）。

> 旧版实现曾使用 `CVDisplayLinkRunner` 封装 `CVDisplayLink`，相关代码已删除（见 `MenuBarIconRenderer.swift` 的内联注释了解切换原因）。

## 5. 视觉规格

### 参数对比

| 维度 | Warning | Critical |
|---|---|---|
| 周期时长 | 4.0 秒（较慢） | 2.0 秒（较快） |
| 吸入时长 | 1.4 秒 | 0.7 秒 |
| 呼出时长 | 2.6 秒 | 1.3 秒 |
| 吸入/呼出比 | 35:65 | 32:68 |
| 最大模糊半径 | 6 pt | 8 pt |
| 最大 shadow 透明度 | 0.7 | 0.85 |
| 颜色 | #FFC107（金黄） | #F44336（红色） |

### 视觉体验说明

**Warning 状态**：一个缓慢、温和的 4 秒脉冲。shadow 从完全不可见逐渐增强到约 5 号模糊半径的金黄色光晕，再缓缓消退。节奏接近静息状态下的自然呼吸频率（约 15 次/分钟），意在传达"请留意，但不必紧张"的提示信号，不打断用户当前的工作流。

**Critical 状态**：一个较快的 2.0 秒脉冲，恰好是 Warning 周期的一半（每 4 秒完成两个 Critical 呼吸），确保多槽位情况下节奏始终同步。节奏更快，暗示"需要立即处理"。这种快慢对比使用户在余光扫过菜单栏时，能凭速度而非仅凭颜色判断紧急程度——对色彩辨识能力有限的用户同样有效。

两种状态的吸入比呼出短（吸入约占周期的三分之一），这是有意为之：快速的吸入营造"警觉"感，较慢的呼出维持视觉残留，使光晕的可见时间更长，警示效果更持久。

## 6. 性能取舍

呼吸动画的渲染层只做一件事：每帧（按 5Hz 即每 200ms）调用一次 `setShadow` 设定模糊半径和透明度，再用 `drawText` 渲染两行文字。整个渲染路径在 `@MainActor` 上同步执行，单帧耗时亚毫秒级。

**采样率选择**：5Hz 是经过验证的最优点，更低（如 1Hz）会出现明显的阶梯感，更高（如 30Hz）则与 5Hz 在视觉上无差异但白白增加 CPU 占用。呼吸周期 2–4s 对应每周期 10–20 个采样点，对 shadow 半径 / 透明度的线性插值而言已远超视觉平滑所需的最小采样率。

**CPU 占用**：CVDisplayLink 方案下，呼吸期间进程 CPU 常驻 80%+（占满一个核心）。改为 5Hz Timer 后，CPU 占用降至 <5%，与无呼吸状态持平。代价仅是重绘时刻从每 16ms 一次变成每 200ms 一次 —— 在 22pt 高的菜单栏图标上无肉眼可辨的差异。

**生命周期**：`breathingTimer` 由 `MenuBarController` 通过 `renderer.needsBreathingAnimation()` / `renderer.isBreathingAnimationRunning()` 双重检查控制启停：无任何 warning/critical 槽位时 `stopBreathingAnimation()` 立即 `invalidate()` 并置 nil，避免空转。`MenuBarIconRenderer.deinit` 同样调用 `invalidate()` 兜底，防止闭包逃逸。
