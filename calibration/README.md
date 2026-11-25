# 校准资料：.cube 与色卡（2026-11-25）

本目录是「六台参考机型的 LUT / 色卡」调查结果与本地素材索引。**第三方图片与由它们派生的 LUT 只用于内部校准，不随 App 分发**（许可见每节）。

---

## A. `.cube` 总结

### 结论

- **六台相机没有公开的机型 `.cube`。**
  - A70 / IXUS 400 / W1 / F30 当年只能拍 JPEG，没有 RAW，也就没有可提取的 DCP/ICC。
  - GR Digital 有 RAW，但 Adobe DCP 闭源不可分发，公开的机型 `.cube` 也没有。
  - Contax T3 是胶片机，颜色来自胶片 + 扫描，不存在「机身 LUT」。
- **RawTherapee HaldCLUT 只有胶片模拟**，不是相机 JPEG 色彩。六台里只有 **N1（Contax T3 + Portra）的胶片部分**能对上。

### 本地 `.cube` 文件

| 文件 | 尺寸 | 大小 | 来源 | 许可 |
|---|---|---|---|---|
| `cube/portra400-33.cube` | 33³ | 948 KB | RT `Kodak Portra 400 2`，144³ HaldCLUT 下采样 | CC BY-SA 4.0（RT Film Simulation）/ 镜像仓库 GPL-3.0 |
| `cube/portra400-65.cube` | 65³ | 7.1 MB | 同上 | 同上 |

- 源文件：`source-portra400-haldclut.png`（1728×1728，level 12 → 144³，8-bit sRGB）。
- 转换脚本：`haldclut_to_cube.py`（red-fastest；Core Image `CIColorCube` 是 blue-fastest，接入时要转置索引）。
- 原始下载地址：<https://raw.githubusercontent.com/cedeber/hald-clut/master/HaldCLUT/Film%20Simulation/Color/Kodak/Kodak%20Portra%20400%202.png>
- 效果预览：`previews/portra-before-after.jpg`（本机样张，左原始 / 右 Portra 400）。

> 许可提醒：RT 胶片包为 CC BY-SA 4.0，GitHub 镜像整体 GPL-3.0。**不能直接打进闭源商业 App**；可以内部参考，或把 `.cube` 作为单独可选下载并按其许可分发。

---

## B. 公开色卡总结

已找到并下载 Imaging Resource 的 Davebox / 多目标靶，均为 24 色 Macbeth ColorChecker + 灰阶。EXIF 已核对机型（W1 无 EXIF，按页面标注）。

| 机身 | 参考机 | 色卡文件 | 变体 | 原图尺寸 | 来源 |
|---|---|---|---|---|---|
| A7 | Canon PowerShot A70 | `charts/A70-auto.jpg`、`A70-daylight.jpg`、`A70-manual.jpg` | 自动 / 日光 / 手动 WB | 2048×1536 | [IR A70](https://old.imaging-resource.com/PRODS/A70/A70PICS.HTM) |
| A8 | Canon PowerShot S400 (IXUS 400) | `charts/S400-auto.jpg`、`S400-daylight.jpg`、`S400-manual.jpg` | 自动 / 日光 / 手动 WB | 2272×1704 | [IR S400](https://old.imaging-resource.com/PRODS/S400/S40PICS.HTM) |
| C1 | Sony Cyber-shot DSC-W1 | `charts/W1-auto.jpg`、`W1-daylight.jpg` | 自动 / 日光 WB | 2592×1944 | [IR W1](https://old.imaging-resource.com/PRODS/W1/W1PICS.HTM) |
| N2 | Fujifilm FinePix F30 | `charts/F30-multi.jpg` | 多目标靶（Macbeth + Kodak Q13 + 人像） | 2848×2136 | [IR F30](https://old.imaging-resource.com/PRODS/F30/F30PICS.HTM) |

缺失：

- **M1 Ricoh GR Digital**：IR 没测初代 GR Digital 的 Davebox；DPReview 只有噪声测试的 ColorChecker 裁切（<https://www.dpreview.com/reviews/ricohgrd/6>），不是完整 24 色靶。M1 是黑白 look，色卡不是瓶颈。
- **N1 Contax T3**：胶片机，没有数码色卡；走 Portra 胶片参考 / LUT。

每张图的完整来源 URL、EXIF、尺寸、WB 变体都在 `manifest.json` 的 `charts` 数组里。

---

## C. 色卡在图片里的位置

色卡在原图中是 **4 列 × 6 行**（标准 ColorChecker 旋转 90°），**最右列是 6 级中性灰**；编号按行优先 1–24，见 `overlays/*-grid.png`。

取样四角（TL / TR / BL / BR，原图像素坐标）：

| 相机 | TL | TR | BL | BR |
|---|---|---|---|---|
| A70 | (232, 102) | (820, 102) | (232, 858) | (820, 858) |
| S400 | (340, 102) | (898, 102) | (340, 760) | (898, 760) |
| W1 | (350, 125) | (1050, 125) | (350, 1190) | (1050, 1190) |
| F30 | (575, 300) | (1185, 285) | (600, 1200) | (1200, 1185) |

- 24 个格心坐标（每张图）在 `manifest.json` 的 `patch_centers_24`。
- 可视化：`overlays/<chart>-grid.png`（红框 = 四角，黄圈 1–24 = 取样点）。
- 注意：F30 有轻微透视/旋转，W1 底行略偏；这两张的坐标是**首轮估计**，正式拟合前需要用 overlay 再校一次。A70/S400 已对齐。

---

## D. 首轮取样（可行性验证，非最终参数）

| 机型 | 白平衡 R/G, B/G | 中性灰 6 级（0→255） | 色彩饱和度 |
|---|---|---|---|
| A70 | 0.973 / 0.987 | 34 → 70 → 111 → 170 → 208 → 235 | 0.646 |
| S400 | 0.952 / 0.986 | 34 → 72 → 90 → 112 → 171 → 209 | 0.617 |
| W1 | 1.000 / 0.986 | 25 → 66 → 117 → 175 → 213 → 165* | 0.620 |
| F30 | 0.978 / 1.078 | 31 → 55 → 101 → 158 → 67* → 191 | 0.527 |

\* 网格未对齐的采样值（W1 第 6 行、F30 第 5 行），只用于趋势判断。

趋势：A70/S400 是同一套 Canon 色彩（轻微偏绿、饱和 0.62–0.65）；W1 最中性（R/G=1.000）；F30 更淡更偏蓝（B/G=1.078，饱和 0.527）。

---

## E. 下一步

1. 用四角单应 + 24 格心把 A70/S400/W1/F30 的色卡值取准（先修 F30/W1 网格）。
2. 以 ColorChecker 参考值 + IR 灯光假设拟合 3×3 矩阵 + 色调曲线，或直接烘 33³ LUT；留出 6 个色块做 ΔE2000 验收。
3. GR 用 DPReview 裁切补；T3 用 Portra 参考。
4. 拟合结果先只用于内部对比，不随包分发。

---

## 文件索引

```
calibration/
├── README.md                      # 本文件
├── manifest.json                  # 每张色卡的来源/EXIF/四角/24 格心
├── patch-centers.csv              # 216 个格心（9 张图 × 24）平铺成表
├── haldclut_to_cube.py            # HaldCLUT PNG → .cube
├── source-portra400-haldclut.png  # RT Portra 400 源图（144³）
├── cube/
│   ├── portra400-33.cube
│   └── portra400-65.cube
├── charts/                        # 9 张公开色卡原图（内部校准用）
├── overlays/                      # 9 张取样点可视化
└── previews/                      # 色卡拼图 / Portra 前后对比
```
