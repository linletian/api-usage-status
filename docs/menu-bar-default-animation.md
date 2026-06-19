# 菜单栏默认状态动画设计文档

## 1. 动机

旧版菜单栏在没有任何 API 实例被配置时，显示一个灰色的 `?` 图标。这个设计有两个问题：

- **语义模糊**：问号图标无法传达"这是 API 用量监控工具"的身份信息。新用户首次启动后看到的是一个通用符号，而不是与产品相关的品牌标识，增加了认知摩擦。
- **第一印象单薄**：`?` 是一个静态图标，没有动态反馈表明应用正在运行、等待配置。用户可能误以为应用没有正常启动。

默认状态动画替代 `?` 后，用 "AI" 这个品牌化文字取代问号，同时配合底行循环滚动的 `%` → `%%` → `%%%` 动画，传达"等待 API 实例配置"的信号。这种处理方式：

- **品牌化**：两行布局的首行固定为 "AI"，让用户一眼就能识别出这是 AI 相关工具的监控面板。
- **动态暗示**：底行的百分比符号逐步递增（一个百分号 → 两个 → 三个），产生一种"正在就绪"或"等待填充"的视觉效果，暗示应用处于待配置状态但运行正常。
- **平滑过渡**：一旦用户添加第一个实例，动画自动停止并切换至正常状态，整个过程无感知中断。

## 2. 动画循环机制

默认动画的核心是一个三帧循环，由 `defaultAnimationTexts` 数组定义：

| 参数 | 值 |
|---|---|
| 文本序列 | `["%", "%%", "%%%"]` |
| 循环间隔 | 1.0 秒 |
| 索引更新公式 | `index = (index + 1) % 3` |

每一秒，当前索引递增后对 3 取模，从而在三个文本之间循环。视觉上底行的百分号个数依次递增（1 → 2 → 3 → 1 → 2 → 3 ...），形成一个连贯的"增长 → 重置 → 增长"节奏。

选择三帧的原因：

- **可见的变化幅度**：一个百分号到三个百分号的变化在 8pt 字号下肉眼可辨，同时不会因为帧数过多在 1Hz 刷新率下产生跳跃感。
- **简单可靠**：三帧循环不需要复杂的状态机或缓动函数，逻辑一目了然。

## 3. 渲染实现

默认状态的渲染在 `MenuBarIconRenderer.renderDefaultState()` 中完成。与正常状态同样采用两行堆叠布局，但内容固定而非来自外部数据。

**布局细节**：

- **首行**：固定文字 "AI"，使用 SF Pro Regular 8pt，居中对齐。
- **底行**：当前帧对应的循环文本（`%` / `%%` / `%%%`），使用 monospacedSystemFont 8pt，右对齐绘制。
- **颜色**：根据用户设置的色彩模式动态切换。
  - **单色模式**：浅色背景下使用黑色，深色背景下使用白色，与系统菜单栏原生图标风格保持一致。
  - **彩色模式**：使用 `safeColor`（`#4CAF50` 绿色），传达「就绪/等待配置」的积极语义，与正常状态的安全颜色保持品牌一致性。
- **槽位高度**：22pt，与正常状态槽位一致，确保状态切换时菜单栏整体高度不变。
- **宽度自适应**：以底行最长文本（`%%%`）的像素宽度为基准计算槽位总宽度，确保动画帧切换时槽位宽度不变，避免菜单栏图标抖动。首行文字居中对齐到槽位中心，底行文字右对齐到槽位右边缘。

渲染流程：创建 `NSImage`，锁定焦点后获取 `CGContext`，调用 `renderText()` 分别在两行的基线位置绘制文字。整个过程中不叠加阴影、不修改文字颜色、不附带任何呼吸效果——这是一个纯文本的静态循环动画。

**与呼吸动画的对比**：

- 呼吸动画每帧重新计算 shadow 半径和透明度，渲染成本较高（涉及 `saveGState` / `restoreGState` 和阴影计算）。
- 默认状态动画每帧只需绘制两行纯色文字，无任何叠加效果，渲染路径极短。

## 4. Timer 与 @MainActor

`MenuBarIconRenderer` 被标记为 `@MainActor`，这意味着它的所有方法和属性都必须在主线程执行。在这个约束下，有两种定时触发方案的对比：

| 方案 | 适用场景 | 本项目使用 |
|---|---|---|
| `Timer.scheduledTimer` | 低频 UI 更新（1Hz），依赖主 RunLoop | 默认状态动画 |
| `CVDisplayLink` | 高频显示同步更新（60fps），独立线程回调 | 呼吸动画 |

**Timer 为什么在这里可用**：`Timer.scheduledTimer` 需要所在线程有一个活跃的 `RunLoop` 才能正常触发。`@MainActor` 的关联线程是主线程，而主线程的 RunLoop 由 AppKit 持续运行，永远不会停止。因此 1.0 秒间隔的 Timer 能够稳定、准时地回调闭包，在闭包中更新 `defaultAnimationCycleIndex` 并触发 `onNeedsDisplay` 重绘菜单栏图标。

**与呼吸动画的对比**：呼吸动画需要 60fps 的刷新率以产生平滑的 shadow 脉冲，1Hz 的 Timer 显然无法胜任。因此呼吸动画使用 `CVDisplayLinkRunner`，通过 CoreVideo 层的显示链路与显示器刷新率同步，输出回调在独立线程执行后派发到主队列。而 1Hz 的默认动画完全没有这种精度需求，Timer 是最简单、资源消耗最小的方案。

**与 RefreshService 的对比**：项目中 RefreshService 使用 `Task.sleep` 驱动后台网络刷新。这是因为刷新逻辑需要在后台 actor 上执行，没有主 RunLoop，且刷新间隔（5 分钟 / 30 分钟）远超 Timer 的适用场景。默认动画在主 actor 上以 1 秒间隔驱动纯粹的 UI 更新，Timer 是最自然的选择。

## 5. 生命周期管理

默认状态动画的生命周期由三个方法控制：

- **`startDefaultAnimation()`**：创建一个 1.0 秒间隔、重复执行的 `Timer.scheduledTimer`。Timer 的闭包弱引用捕获 `self`，每 tick 调用 `advanceDefaultAnimationCycle()` 更新循环索引并触发 `onNeedsDisplay`。如果动画已在运行（`defaultAnimationTimer` 不为 nil），则直接跳过。
- **`stopDefaultAnimation()`**：对当前 Timer 调用 `invalidate()` 使其停止触发，随后将 Timer 置为 nil。调用后循环索引停留在最后一帧，直到下一次 `startDefaultAnimation()` 从索引 0 恢复。
- **`isDefaultAnimationRunning`**：计算属性，通过 `defaultAnimationTimer != nil` 判断当前动画是否运行中。

**deinit 清理**：`MenuBarIconRenderer` 的 `deinit` 中调用 `defaultAnimationTimer?.invalidate()`，确保对象销毁时 Timer 一并失效，避免闭包逃逸导致野指针访问。

**与呼吸动画的对比**：

| 维度 | 默认动画 | 呼吸动画 |
|---|---|---|
| 定时器类型 | Timer（Foundation） | CVDisplayLink（CoreVideo） |
| 刷新率 | 1 Hz | 60 Hz（与显示同步） |
| 启动方法 | `scheduledTimer` 单行创建 | `CVDisplayLinkRunner` 封装类 |
| 停止方法 | `invalidate()` + 置 nil | 停止链路 + 置空引用 |
| 状态查询 | `defaultAnimationTimer != nil` | `displayLink?.isRunning` |

## 6. 触发条件

动画的启停由 `MenuBarController` 在每次更新实例列表时根据 `instances` 数组的状态决定：

- **启动条件**：`instances.isEmpty` 且当前动画未运行（`!renderer.isDefaultAnimationRunning`）。表示用户尚未配置任何 API 实例，菜单栏应显示默认状态动画引导用户。
- **停止条件**：`!instances.isEmpty` 且当前动画正在运行（`renderer.isDefaultAnimationRunning`）。表示至少有一个实例已配置完毕，菜单栏切换至正常状态显示各实例的用量数据。

这段逻辑位于 `MenuBarController.updateUI()` 方法中，与呼吸动画的启停并列执行。动画启动后，`renderIcon()` 会调用 `render()` 方法，当 `instancesCount == 0` 时自动路由到 `renderDefaultState()`，无需额外的条件分支。

## 7. 视觉规格

### 参数总览

| 参数 | 值 |
|---|---|
| 循环间隔 | 1.0 秒 |
| 文本序列 | `["%", "%%", "%%%"]` |
| 索引更新 | `(index + 1) % 3` |
| 首行文字 | "AI" |
| 首行字体 | SF Pro Regular 8pt |
| 底行字体 | Monospaced System 8pt Regular |
| 首行文字颜色 | 单色模式：白（深色背景）/ 黑（浅色背景）；彩色模式：`safeColor` #4CAF50 |
| 底行文字颜色 | 同上，与首行保持一致 |
| 槽位高度 | 22 pt |
| 布局 | 首行居中，底行右对齐 |
| 宽度 | 固定宽度（以底行最长文本 `%%%` 为基准） |

### 与正常状态槽位的一致性

- 槽位高度相同（22pt），状态切换时菜单栏不会发生高度跳变。
- 使用相同的 `renderText()` 方法和基线计算逻辑，渲染路径一致，只是内容来源不同。
- 颜色根据色彩模式动态切换：单色模式下使用白/黑（跟随系统外观），彩色模式下使用 `safeColor`（绿色 `#4CAF50`），与正常状态的安全色保持一致。与旧版 `?` 图标使用 `dimColor` 的置灰策略不同，新设计在彩色模式下用品牌绿色传达「就绪」语义。
