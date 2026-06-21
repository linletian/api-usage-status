# Menu Bar Stale Slot Pill Rendering（刷新失败时挖空圆角矩形）

> **日期**: 2026-06-21　|　**作者**: `MenuBarIconRenderer.swift`

## 概述

当实例刷新失败时，其菜单栏槽位从普通纯色文字切换为**挖空圆角矩形 pill**：绘制一个 `#D6D0A0` 灰色圆角矩形，文字以 `destinationOut` 混合模式镂空，让菜单栏系统背景穿透文字形状显示。pill 是一种**异常信号**——仅在需要提醒用户"这个槽位的数据不是最新的"时出现。正常活跃的槽位保持纯色文字渲染（无 pill 背景）。

## 设计理由

1. **pill = 异常信号**：新鲜数据以彩色纯文字显示（与 macOS 菜单栏原生图标类似）；刷新失败时加上灰色 pill 背景，让用户一眼区分"当前数据"和"缓存数据"。
2. **陈旧统一**：所有失败的槽位（无论原本对应 warning/critical/normal 阈值）统一归入 `colorState.error`，pill 以固定 `#D6D0A0` 灰色渲染。不依赖 alpha 降透明度（与 `docs/ARCHITECTURE.md §7.3` 一致）。
3. **语义清晰**：正常槽位 = 纯文字，陈旧槽位 = 灰 pill。用户无需查文档就能理解——pill 出现表示"出问题了"。

## 触发条件

- `SlotViewData.isStale == true` → `colorState` 计算属性短路返回 `.error`。
- `colorForSlot` 对 `.error` 返回 `dimColor` = `#D6D0A0`。
- 渲染循环检测到 `slot.colorState == .error` 时走 pill 路径；其他状态走纯文字路径。

## 渲染管线

对陈旧槽位执行以下步骤：

```
1. 计算 pill 矩形
   CGRect(x: originX, y: pillVerticalMargin, width: width, height: slotHeight - 2 * pillVerticalMargin)

2. 创建圆角路径
   CGPath(roundedRect: pillRect, cornerWidth: pillCornerRadius, cornerHeight: pillCornerRadius, …)

3. 填充 pill
   context.setFillColor(dimColor.cgColor)
   context.fillPath()
   （陈旧槽位不触发呼吸动画，无 shadow）

4. 挖空文字
   context.saveGState()
   context.addPath(pillPath)
   context.clip()
   context.setBlendMode(.destinationOut)
   绘制两行文字（opaque 颜色，alpha=1——blend mode 只看 alpha）
   context.restoreGState()
```

## 布局常量

| 常量 | 值 | 说明 |
|------|-----|------|
| `pillCornerRadius` | 3pt | 圆角半径 |
| `pillVerticalMargin` | 2pt | pill 上/下边距（pill 高 = 22 - 4 = 18pt） |
| `pillHorizontalPadding` | 3pt | 文字左右边距（避免文字贴圆角边缘） |
| `slotHeight` | 22pt | 槽位总高度 |

## 文字渲染：CTLineDraw

文字在 `renderCutoutText` 中通过 `CTLineDraw` 绘制（而非 `NSString.draw(at:withAttributes:)`）。原因是 `destinationOut` blend mode 在某些实现中与 `NSAttributedString` 绘制路径不完全兼容——使用 Core Text 直接绘制保证 blend mode 正确穿透。

```swift
private func renderCutoutText(_ text: String, at position: CGPoint, font: NSFont, in context: CGContext) {
    let attrString = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor.black  // 颜色不重要——blend mode 只看 alpha
    ])
    let line = CTLineCreateWithAttributedString(attrString)
    context.textPosition = position
    CTLineDraw(line, context)
}
```

## 陈旧槽位

陈旧槽位的渲染通过 `colorForSlot` 自动处理——当 `slot.colorState == .error` 时返回 `dimColor`（`#D6D0A0`），pill 填充即为灰色。呼吸动画不会触发（`updateBreathingState` 仅将 warning / critical 槽位加入 set，`.error` 不在其中）。

`expandToMetricSlots` 在展开时保留源槽位的 `isStale` 标志——新创建的 slot 通过 `SlotViewData.init(isStale:)` 继承陈旧状态，确保 `colorState` 计算属性正确短路到 `.error`。

## 相关文件

- `APIUsageStatus/MenuBar/MenuBarIconRenderer.swift` — 主要实现
- `APIUsageStatus/Extensions/Color+Theme.swift` — `menuBarDim` / `menuBarSafe` / `menuBarWarning` / `menuBarCritical` 常量
- `APIUsageStatus/Models/SlotViewData.swift` — `colorState` 计算属性（`isStale ? .error : ...`）
- `APIUsageStatusTests/MenuBarIconRendererTests.swift` — 快照测试 + pill 单元测试

## 无 pill 的状态

以下状态不绘制 pill（仅 `renderText` 模式）：

- **默认状态**（无实例）：两行 "AI" + 动画 "%"，跟随系统外观（`renderDefaultState()`）。
- **特殊文本**：`NO API`、`•••`（`renderSpecialCenteredText()`）。
- **正常活跃槽位**：`colorState` 为 `.normal` / `.warning` / `.critical` / `.unavailable` 的槽位——使用纯色文字渲染，pill 仅作为 `isStale == true`（即 `colorState == .error`）时的异常信号。
