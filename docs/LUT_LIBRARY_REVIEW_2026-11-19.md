# 两个 LUT 库的分析：Silverphase / SpektraLab

日期 2026-11-19。目的：Pocket CCD 的 3D LUT 还没做，先看这两个库怎么做、哪些能借。
**只分析，未改任何代码。**

## 0. 结论先行

- 两个库同源：`spektrafilm`（Andrea Volpato，GPL-3.0）→ **SpektraLab**（Hanze Qiu，C++/Metal 重写 + Mac App）→ **Silverphase**（独立衍生，SwiftUI + 共享 C++20/Metal，iPhone/iPad/Mac）。
- 它们是**胶片 + 相纸的物理模拟器**（81 波长光谱追踪），不是滤镜 App。LUT 在它们那里是**性能路径**：把完整光谱渲染烘成表，切相纸 167 ms → 47 ms，误差 1.7e-3。
- 对我们最有用的不是代码，是**已踩过的工程方法**：点wise LUT + 空间效应外置、离线烘焙、与完整渲染比对 ≤1/65535、转置/写序/NaN 的测试。
- **许可红线**：代码 GPL-3.0-or-later，film/paper profile 与 print LUT 数据 CC BY-SA 4.0。闭源商业 App 既不能拷代码，也不能打包它们的 LUT 数据；能借的是数学与做法。

## 1. 两个库的定位与规模

| | SpektraLab | Silverphase |
|---|---|---|
| 作者 | JamesQiu2005（Hanze Qiu） | akinal5765-byte |
| 形态 | Mac Catalyst App + C++20/Metal 引擎 | SwiftUI + 共享 C++20/Metal 引擎，Mac/iPhone/iPad |
| 来源 | C++/Metal 实现 spektrafilm | SpektraLab 的独立衍生 |
| 内容 | 28 组实测胶片/相纸 profile、print LUT、Cineon DI | 25 胶片 + 9 相纸 + 29 实验胶片 |
| 文件数 | 1470 | 779 |
| 许可 | GPL-3.0-or-later；数据 CC BY-SA 4.0 | 同上 |

两者都强调"光谱，不是 LUT"：LUT 是给交互预览/切相纸用的缓存，不是最终画质的来源。

## 2. 它们怎么做 3D LUT（三种，值得分开看）

### A. Print preview LUT —— 33³，离线烘焙，C++/Metal

- **输入**：显影后的负片密度（均匀轴，但范围不是 [0,1]；`print_lut_axes` 给 lo/hi，kernel 用 `lo + inv_span` 映射）。
- **输出**：Display P3 + CCTF 编码，**不 clamp**——107,811 个值里有 1,056 个负值（gamut 外），由消费端 clamp。
- **存储**：float32，33³×3 = 431 kB/stock；`print_luts.json` 一个注册表（`lut_size`、`paired_film`、`output_color_space`、`declared_pairing`）。
- **查表**：`minilab.metal` 的 trilinear（8 邻点、`(S,S,S,3)` row-major、红最快）。
- **收益**：全分辨率切相纸 47 ms，对比重新跑光谱 167 ms；误差 mean abs 0.00085 → 0.00177。
- **边界**：不含 glare（空间效应），也不含 grain。
- **验证**：`parity_lut.py` 表 bit-exact、apply ≤8e-6；`PrintLUTTests` 断言 NaN/Inf 不存在、表极值精确（防转置/半长/错 dtype）。

### B. DI view LUT —— 65³，Swift 生成 .cube，文本

- **用途**：Cineon log（ProPhoto 原色）→ ProPhoto/Rec709 的"数字中间片视图"。
- **四步数学**（全烘进表）：
  1. Cineon decode：white 685、black 95、300 codes/decade、负片 gamma 0.6。
  2. **亮度 tone** + m=2 smooth-min shoulder；knee 是**二分求解**的（最软的、把顶码落在白下 1/16 档）。
  3. **Oklab 恒 hue 路径到白**（超 gamut 时降 chroma，不逐通道 clip）。
  4. ROMM 或 Rec709 γ2.4 编码。
- **形式**：65³ 文本 `.cube`，canvas 采样**同一个文件**——"数据即实现"，不会两套代码漂移。
- **教训**：per-channel 曲线会让亮肤色偏黄 13.6°，必须亮度 tone（和 Pocket CCD 今晚修的"逐通道对比推红"是同一类错误）。

### C. Camera fast look —— 49³ + log shaper，iOS 实时（**最接近我们**）

- **输入**：scene-linear ProPhoto，可到 16.0；log shaper 把 [0,16] 映射到 [0,1]：
  `toe=0.002`，`logRange=log2(1+16/0.002)`，`coord(x)=log2(1+x/toe)/logRange`。
- **表**：49³，`MTLTexture` `.type3D`、`rgba32Float`，compute shader `mobileCameraFastLook` 用硬件线性采样。
- **烘焙**：把 49³ 网格当一张图喂给完整引擎（`spk_render_color_samples`），输出 P3 16-bit，再转纹理。
- **每帧**：CIImage 曝光 → `RGBAf` buffer（linear ProPhoto）→ kernel（log 坐标 → 采样）→ P3 CGImage。
- **缓存**：最多 2 个 cube（LRU）；低电量只降分辨率/帧率，不降 look。
- **验证**：与完整引擎 file/develop 路径比对，**色差 ≤1/65535**（18 组 film×metering + 换帧）。

## 3. 对 Pocket CCD 的映射

现状（`CCDLook.swift`）：

- 输入 `kCVPixelFormatType_32BGRA`（sRGB，已经 tone-map），不是 scene-linear。
- 链：`sceneBalanced`（按图像平均色，**全局依赖**）→ tone curve → `lumaContrastCube`（64³）→ grain（空间随机）→ `shoulderCube`（32³）→ clamp。
- 没有任何 `.cube` I/O，没有"整条 look 一张表"。

**能借的（思想/做法，不涉及代码）**

1. **LUT 只装 pointwise**。`sceneBalanced` 是图像依赖，必须留在 LUT 前；grain、vignette、bloom、色差留在 LUT 后。这是他们"glare 不进表"的同一条原则。
2. **把 tone + lumaContrast + shoulder + clamp 合并成一张 33³**，替代现在两个 cube pass。33³ 对他们够用（17³ LUT 的 ΔE max 也只有 1e-4 级）。
3. **测试照抄思路**：NaN/Inf、表极值（防转置）、index-encoding 表测 `.cube` 写序（red-fastest vs Core Image 的 blue-fastest 正好相反，**这是最容易踩的坑**）、未知参数报错。
4. **若以后接 ProRAW/HDR**，再加 log shaper（Silverphase 的 toe/max 公式），把 LUT 输入域从 [0,1] 扩到 [0,16]。
5. **导出 `.cube`** 时写清 domain、输出色彩空间（sRGB/P3）、是否带 shaper——他们的 DI 包就是靠"文件与视图 LUT 同源"保证一致。

**不能用的**

- GPL-3.0 代码：不能进闭源 App（传染）。
- CC BY-SA 4.0 的 profile/LUT 数据：不能打包（必须同许可分发）。
- 光谱引擎、CAM16 gamut compression：对我们过重；Oklab 恒 hue 或简单 clip 就够。

## 4. 设计建议（未实施）

**P0（最小可用，1–2 天）**：离线烘焙一张 33³ 总 look LUT（覆盖 toned→lumaContrast→shoulder→clamp），运行时 `CIColorCube` 一次采样；grain/vignette/bloom 保持在外；预览与成片共用同一张表。
- 注意：shoulder 现在在 grain **之后**；改成 LUT 先于 grain 时，颗粒峰值会顶穿 white，需要 grain 后再轻 clamp 一次（或保留 shoulder 在 grain 后，LUT 只到 lumaContrast）。

**P1（可选）**：`.cube` 导入/导出 + 可选 shaper，面向专业用户/社媒素材。
- 导出必须同时给：domain、输出空间、shaper 参数；否则外部加载必错。

**目标要先定**（影响方案）：
- 性能（预览提速、减少 CIFilter pass）→ P0 就够。
- 可导出/可换 look（给用户 `.cube`）→ P1。
- 画质统一（预览=成片）→ P0 + 一致性测试。

## 5. 一句话

这两个库证明了一件事：**3D LUT 应该是"已验证 look 的快速路径"，不是调色引擎本身**。我们该借的是它们的验证纪律（转置、写序、NaN、与完整渲染 ≤1 count），不是它们的表。
