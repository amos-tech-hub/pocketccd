# PocketCCD · 生成式 logo prompt

这些 prompt 用来做**探索与比稿**，不是最终资产。AI 图像模型给不了精确几何，
最终图标仍以 `scripts/generate_logo.py` 的矢量/PIL 输出为准。

---

## 1. 主图标（当前方向：P + 镜头环）

**English**

> Minimal app icon for a retro digital camera app called PocketCCD.
> A capital letter P built from two flat shapes: a thick vertical bar and a ring
> as the bowl, the ring in warm amber #F0AD3D, the bar in warm off-white #E6E6E0.
> Four thin viewfinder corner brackets around the letter, off-white, equal arm
> length. Pure near-black background #0B0C0A. Flat vector, no gradients, no
> shadows, no glow, no bevels, no texture, no text, no camera body.
> Centered composition, generous margin, crisp geometry on an 8 px grid.
> Style: Swiss poster, industrial instrument, high contrast, screen-printed.

**中文（给支持中文的模型）**

> 复古数码相机 App「PocketCCD」的极简图标。大写字母 P 由两根纯色形状构成：
> 一竖为暖白 #E6E6E0 的粗竖条，一个圆环作 P 的碗部，圆环为琥珀色 #F0AD3D。
> 字母四周四个细的取景框直角，暖白，四臂等长。纯近黑背景 #0B0C0A。
> 扁平矢量、无渐变、无阴影、无发光、无倒角、无纹理、无文字、不出现相机机身。
> 居中构图、留足边距、8px 网格上的干净几何。风格：瑞士海报、工业仪表、高对比、丝网印刷。

**Negative prompt**

> gradient, glow, drop shadow, bevel, 3D, clay render, glass, chrome, texture, grain,
> photo, camera body, lens flare, rainbow, pastel, rounded squircle tile, text,
> lettering, watermark, clutter, multiple icons, mockup, hand, desk

---

## 2. App Store 图标版（要留安全边距）

> Same mark as above, composed for an iOS app icon: the brackets and letter occupy
> about 62% of the square, centered, with even black margin on all four sides.
> No rounded corner mask, no device frame, no background gradient.
> 1:1 canvas, 1024×1024, flat fills only.

---

## 3. 横向字标（图标 + 文字）

> Dark lockup: the P-lens mark at left, then the wordmark “PocketCCD” set in a
> monospaced grotesque, letter-spaced +3%, “Pocket” in warm off-white, “CCD” in
> amber. Thin baseline alignment, flat black background, no gradients, no effects.
> Wide horizontal composition, lots of negative space to the right.

⚠️ 文字部分模型经常写错，生成后只用来看比例，不要直接用。

---

## 4. 亮底版

> Same P-lens mark and brackets inverted for a warm paper background #ECE8DD:
> the bar and brackets become near-black #181916, the ring stays amber #F0AD3D.
> Flat vector, no shadows, generous margin.

---

## 5. 备选方向（想再比稿时用）

**半开快门**

> Minimal icon: a solid amber disc with a 45° wedge removed, like a half-open
> mechanical shutter, framed by four thin viewfinder corner brackets on near-black.
> Flat vector, two colors, no text.

**日期戳照片**

> Minimal icon: a flat amber photo rectangle with a small near-black square notch
> at its bottom-right corner, suggesting a burned-in date stamp, framed by four
> thin viewfinder brackets on near-black. Flat, two colors, no text.

---

## 6. 工具参数建议

| 工具 | 建议 |
| --- | --- |
| Midjourney | `--ar 1:1 --style raw --s 50`（低 stylize，几何更稳）；用 `--no gradient, glow, text` |
| DALL·E / ChatGPT | 直接贴第 1 段，追加「只要图标本身，不要展示在手机或桌面上」 |
| Ideogram | 需要字标时用它，文字准确率最高 |
| SDXL / Flux | 加 LoRA「flat vector icon」；CFG 6–7，steps 30 |

## 7. 生成之后

1. 选最接近的一张，用矢量工具（Figma / Illustrator）**重画**，不要直接位图缩放；
2. 对照 `icon-sheet.png` 在 40px 检查剪影；
3. 生产资产仍走 `python3 scripts/generate_logo.py`，保证每次一致、可复现。
