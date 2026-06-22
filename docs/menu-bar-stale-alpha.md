# Menu Bar Stale Slot Rendering（刷新失败时 80% 透明度）

> **日期**: 2026-06-22　|　**作者**: `MenuBarIconRenderer.swift`

## 概述

当实例刷新失败时，其菜单栏槽位继续渲染**原阈值颜色**（warning yellow / critical red / safe green / 单色模式下的黑/白），但**整体应用 80% 透明度**——文字 + 呼吸阴影一并降低 20% 不透明度。这是一种**克制的视觉信号**：让用户能够区分"当前数据"和"缓存数据"，但不引入新的视觉元素。

## 设计理由

1. **保留原颜色语义**：warning/critical/normal 三种阈值在新数据时各自有不同颜色（黄/红/绿），用户已经建立"颜色 = 阈值"的心智模型。陈旧数据保留同一颜色，只是"略微变淡"——用户立刻就能识别"这个槽位现在显示的是缓存值，不是实时数据"。
2. **不引入新视觉元素**：避免 macOS 菜单栏上出现突兀的矩形块或文字镂空。
3. **呼吸动画自然延续**：warning/critical 槽位的呼吸动画是"数据接近阈值"的重要信号。陈旧数据保留这个动画 + 仅降低 20% 透明度，让用户既能感知"数据是缓存的"，又能继续注意到"数据本身在接近阈值"。

## 数据流

陈旧检测与阈值颜色判断**正交**：

- `SlotViewData.colorState` 计算属性始终反映 `metricSnapshots` 聚合的阈值状态（normal / warning / critical / unavailable / disabled / loading / error）。**不再**有 `isStale ? .error` 短路。
- `SlotViewData.isStale: Bool` 是存储字段，由 `AppState.mergeCycleResult` 在刷新失败时置 `true`、刷新成功时重置为 `false`。**这是陈旧检测的唯一通道**——面板的"陈旧样式"和菜单栏的"80% 透明度"都从这里读取。
- 之前作为绕路设计的 `SlotViewData.underlyingColorState` 已删除（无调用方后无存在必要）。

## 渲染管线

陈旧槽位的处理发生在主渲染循环的**颜色派生阶段**，而非独立的渲染函数：

```swift
// 1. 颜色直接取自阈值（陈旧不影响 colorState）
let slotColor = colorForSlot(slot, colorMode: colorMode, isDarkBackground: isDarkBackground)
//    e.g. warning slot → warning yellow (#FFC107)

// 2. 陈旧则整体降到 80% 透明度
let renderColor = slot.isStale
    ? slotColor.withAlphaComponent(Self.staleAlpha)
    : slotColor

// 3. 复用与新鲜槽位完全相同的渲染函数
renderTwoLineSlot(
    atX: slotOriginX,
    width: slotWidth,
    data: slot,
    color: renderColor,
    in: context,
    shadowBlurRadius: shadowBlur,  // 呼吸阴影也使用 renderColor
    shadowOpacity: shadowOp
)
```

陈旧与新鲜路径**完全共享** `renderTwoLineSlot`——所有文字、阴影、布局逻辑不变，唯一的差别是 `renderColor` 的 alpha。

## 关键设计点

### 呼吸动画在陈旧槽位上**保留**

`updateBreathingState` 直接读取 `slot.colorState` 决定哪些 UUID 加入 `breathingSlots` 集合——陈旧的 warning/critical 槽位因为 `colorState` 仍是 `.warning` / `.critical`，所以**也会**触发呼吸动画。这与"陈旧信号克制度"的设计目标一致：呼吸动画属于"数据状态"，陈旧只表示"数据时间"，两者正交，不应相互抑制。

### 单色模式下的颜色选择

单色模式下，`colorForSlot` 返回 `.white`（深色菜单栏）或 `.black`（浅色菜单栏）。陈旧槽位也走这条路径——文字保持黑/白，仅透明度降到 80%。这比旧的"陈旧 = 灰色"方案在视觉上更自然：黑/白本来就能很好地传达"暗"和"亮"，叠加 80% alpha 后"略微变淡"的暗示对单色模式用户同样直观。

## 布局常量

```swift
private static let staleAlpha: CGFloat = 0.8
```

无其他新增常量。文字基线、间距、字体均与新鲜槽位完全相同。

## 相关文件

- `APIUsageStatus/MenuBar/MenuBarIconRenderer.swift` — `staleAlpha` 常量、`colorForSlot`、`updateBreathingState`、主渲染循环的 `renderColor` 派生
- `APIUsageStatus/Models/SlotViewData.swift` — `colorState` 计算属性（无 `isStale` 短路）+ `isStale` 存储字段
- `APIUsageStatusTests/MenuBarIconRendererTests.swift` — `testStaleWarningSlotKeepsYellowColorAt80PercentAlpha` / `testStaleCriticalSlotKeepsRedColorAt80PercentAlpha` / `testStaleSlotKeepsUnderlyingColorInMonochromeMode` / `testStaleWarningSlotKeepsBreathingAnimation` / `testNoPillBackgroundForAnySlot` 等

## 不应用 80% alpha 的场景

以下场景与陈旧无关，渲染**不应用** 80% 透明度：

- **默认状态**（无实例）：两行 "AI" + 动画 "%"，跟随系统外观（`renderDefaultState()`）。
- **特殊文本**：`NO API`、`•••`（`renderSpecialCenteredText()`）。
- **正常活跃槽位**（`isStale == false`）：`colorState` 为 `.normal` / `.warning` / `.critical` / `.unavailable` 的槽位——使用原阈值颜色，**不**降透明度。
- **`isStale == true` 但 `colorState` 是 `.loading`（无 snapshot）**：陈旧时无成功数据，理论上不应进入此路径（陈旧必然有上次成功数据，刷新成功后 `isStale` 才会重置）。
