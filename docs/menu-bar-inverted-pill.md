# Menu Bar Inverted Pill Rendering（挖空圆角矩形）

> **日期**: 2026-06-21　|　**作者**: `MenuBarIconRenderer.swift`

## 概述

菜单栏图标从"纯色文字无背景"改造为**挖空圆角矩形 pill**：每个槽位绘制一个圆角矩形填充槽位颜色，文字以 `destinationOut` 混合模式镂空，让菜单栏系统背景穿透文字形状显示。整体效果类似 iOS badge pill，但与 macOS 菜单栏风格协调。

## 设计理由

1. **可辨识性**：有色 pill 比纯色文字更容易在菜单栏中的其他图标群中定位。
2. **语义一致**：pill 颜色 = 槽位颜色 = 用量状态（绿 / 黄 / 红 / 灰），用户不需要重新学习。
3. **陈旧区分**：`#D6D0A0` 灰色 pill 在所有状态（包括原本 warning / critical）下统一置灰，不依赖 alpha 降透明度（与 `docs/ARCHITECTURE.md §7.3` 一致）。

## 渲染管线

每槽位在 `renderTwoLineSlot` 中执行以下步骤：

```
1. 计算 pill 矩形
   CGRect(x: originX, y: pillVerticalMargin, width: width, height: slotHeight - 2 * pillVerticalMargin)

2. 创建圆角路径
   CGPath(roundedRect: pillRect, cornerWidth: pillCornerRadius, cornerHeight: pillCornerRadius, …)

3. 呼吸阴影（仅 warning / critical 活跃槽位）
   context.setShadow(offset: .zero, blur: shadowBlurRadius, color: color.withAlphaComponent(shadowOpacity).cgColor)

4. 填充 pill
   context.setFillColor(color.cgColor)
   context.fillPath()

5. 挖空文字
   context.saveGState()
   context.addPath(pillPath)
   context.clip()                            ← 限定挖空范围在 pill 内
   context.setBlendMode(.destinationOut)    ← 源像素使目标通道变透明
   绘制两行文字（opaque 颜色，alpha=1 即可——blend mode 只看 alpha）
   context.restoreGState()
```

## 布局常量

| 常量 | 值 | 说明 |
|------|-----|------|
| `pillCornerRadius` | 3pt | 圆角半径 |
| `pillVerticalMargin` | 2pt | pill 上/下边距（pill 高 = 22 - 4 = 18pt） |
| `pillHorizontalPadding` | 3pt | 文字左右边距（避免文字贴圆角边缘） |
| `slotHeight` | 22pt | 槽位总高度（与 pill 无关的 gap 在相邻槽位间） |

## 文字渲染：CTLineDraw

文字在 `renderCutoutText` 中通过 `CTLineDraw` 绘制（而非 `NSString.draw(at:withAttributes:)`）。原因是 `destinationOut` blend mode 在某些实现中与 `NSAttributedString` 绘制路径不完全兼容——使用 Core Text 直接绘制保证 blend mode 正确穿透。

```swift
private func renderCutoutText(_ text: String, at position: CGPoint, font: NSFont, in context: CGContext) {
    let attrString = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor.black  // 颜色不值不重要——blend mode 只看 alpha
    ])
    let line = CTLineCreateWithAttributedString(attrString)
    context.textPosition = position
    CTLineDraw(line, context)
}
```

## 陈旧（stale）槽位

陈旧槽位的渲染完全通过 `colorForSlot` 自动处理——当 `slot.colorState == .error` 时返回 `dimColor`（`#D6D0A0`），pill 填充即为灰色。呼吸动画不会触发（`updateBreathingState` 仅将 warning / critical 槽位加入 set，`.error` 不在其中）。

`expandToMetricSlots` 在展开时保留源槽位的 `isStale` 标志——新创建的 slot 通过 `SlotViewData.init(isStale:)` 继承陈旧状态，确保 `colorState` 计算属性正确短路到 `.error`。

## 相关文件

- `APIUsageStatus/MenuBar/MenuBarIconRenderer.swift` — 主要实现
- `APIUsageStatus/Extensions/Color+Theme.swift` — `menuBarDim` / `menuBarSafe` / `menuBarWarning` / `menuBarCritical` 常量
- `APIUsageStatus/Models/SlotViewData.swift` — `colorState` 计算属性（`isStale ? .error : ...`）
- `APIUsageStatusTests/MenuBarIconRendererTests.swift` — 快照测试 + pill 单元测试

## 单行槽位（N/A 余额不可用）

不可用余额槽位仅显示一行 "N/A" 文字，使用 `renderSingleLinePillSlot` 渲染——pill + 单行文字，区别于两行的正常槽位。pill 同样绘制灰色 `#D6D0A0`。

## 无 pill 的状态

以下状态不绘制 pill（仅 `renderText` 模式）：

- **默认状态**（无实例）：两行 "AI" + 动画 "%"，跟随系统外观（`renderDefaultState()`）。
- **特殊文本**：`NO API`、`•••`（`renderSpecialCenteredText()`）。

这些状态没有槽位颜色，无需 pill 背景。
