# PocketCCD 图标 v2 · P + LENS

## 名字怎么进来的

`PocketCCD` 拆开是两段：**Pocket**（日常、随身）和 **CCD**（成像气质）。
字标里已经用“Pocket 暖白 + CCD 琥珀”把两段分开了，图标就不该再画一台相机——那正好是竞品的主场。

所以图标做**首字母 P**：竖笔是机身，圆环是镜头，圆环用 CCD 的琥珀色。一个字母同时说出名字和品类。

## 与竞品的位置

| 竞品 | 图标 | 我们的差异 |
| --- | --- | --- |
| ProCCD / CCD CAM / OldRoll / LoFi | 相机机身插画 | 不画机身，画字母 |
| Kapi / ism | 纯字母 | 字母里嵌镜头，不是纯字 |
| Dazz | 彩虹漩涡 | 黑 + 单色琥珀，不做渐变 |
| 0.3MP | 文字 | 一个字母，40px 仍可读 |

`docs/COMPETITOR_MATRIX.md` 的结论是：品类里大家都在卖“相机物件”，PocketCCD 卖的是拍摄行为。图标用名字打头、用镜头收尾，比再画一台相机更省识别成本。

## 几何

- 四角取景框：inset 132、臂长 176、线宽 24（沿用品牌既有 motif，也是 App 内真实存在的取景角）
- 竖笔：x 316–376，y 250–642
- 镜头环：圆心 (566, 446)，外径 196，环宽 58，琥珀 `#F0AD3D`
- 纯黑 `#0B0C0A` 底，零渐变、零阴影、零描边光晕

## 尺寸验收

`icon-sheet.png` 里 180 / 120 / 87 / 60 / 40 五档都验过：40px 下仍是“P + 琥珀圆环”的清晰剪影。
这是这一版最硬的一条——上一版“日期戳”方案在 40px 会退化成一个小方块，所以放弃。

## 字标

保持不动：SF Mono Semibold、+3% 字距、`Pocket` 暖白 `#E6E6E0`、`CCD` 琥珀 `#F0AD3D`。
`lockup-dark.png` / `lockup-light.png` 已按新图标重排，图标 170、间距 40。

## 交付物

- `icon-1024.png` + `icon-{180,120,87,60,40}.png`
- `lockup-dark.png` / `lockup-light.png`
- `icon-sheet.png`（新旧对比、尺寸检查、桌面圆角）
- 备选方向：`concept-shutter`（半开快门）、`concept-frame`（日期戳照片）、`concept-p_old` 等过程稿

## 尚未接线

App 仍使用旧图标。确认后我会：
1. 改 `scripts/generate_logo.py` 的 `draw_mark`，让新标可复现；
2. 重新生成 `Assets.xcassets/AppIcon.appiconset` 与 `brand/` 各尺寸；
3. 更新 `brand/README.md` 的几何说明（现在是“四角 + 镜头环 + 六边光圈”）。
