# 菜单栏呼吸动画设计文档

## 1. 动机

旧版菜单栏图标在 Warning 和 Critical 状态下使用 **1Hz 闪烁**（toggle visibility）来警示用户。这种闪烁有两个问题：

- **视觉突兀**：槽位整体以固定频率在显示和消失之间切换，在人眼余光中造成明显干扰，尤其在菜单栏这种长期可见的区域，容易引发视觉疲劳。
- **状态覆盖单一**：闪烁只作用于 Critical 状态，Warning 状态不下发任何动画效果，用户需要主动打开用量面板才能感知到预警。

呼吸动画（Breathing Animation）替代闪烁后，用 **平滑的 shadow 脉冲** 替代二元可见性开关，视觉上柔和得多。同时 Warning 状态也获得了独立的呼吸节奏，不再是"要么安全、要么严重"的二值体验。三个状态形成完整的梯度：安全（无动画）→ 警告（慢速呼吸）→ 严重（快速呼吸），用户无需查看面板就能凭直觉判断紧急程度。

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
- **动画驱动**：CVDisplayLink 以 60fps（与显示器刷新率同步）持续回调，触发 `onNeedsDisplay` 闭包，促使菜单栏图标重绘。当所有 breathing 槽位恢复到非 Warning/Critical 状态时，动画停止，display link 被销毁。

## 4. CVDisplayLink vs CADisplayLink

macOS 平台上实现高刷新率回调有两个选择：

- **CADisplayLink**：iOS 生态的标准方案，在 macOS 14+ 才被支持。本项目最低部署目标为 macOS 13，因此无法使用。
- **CVDisplayLink**：CoreVideo 层的显示链路 API，在 macOS 上长期可用（macOS 10.4+），不受部署目标版本限制。

项目使用 `CVDisplayLinkRunner` 封装 CVDisplayLink。初始化时通过 `CVDisplayLinkCreateWithActiveCGDisplays` 创建链路，输出回调在独立的显示链路线程上执行，通过 `DispatchQueue.main.async` 派发到主队列，保证 `@MainActor` 闭包的安全执行。

`CVDisplayLinkRunner` 的生命周期与呼吸动画绑定：

- `startBreathingAnimation()` 创建 runner 并启动，记录呼吸开始时间。
- `stopBreathingAnimation()` 停止链路并置空引用。
- 通过 `onNeedsDisplay` 闭包解耦渲染器和 display link，MenuBarIconRenderer 不需要直接管理 CoreVideo 的 C 回调。

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
