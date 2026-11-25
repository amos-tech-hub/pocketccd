# 照片质量 / 拍照速度：两个库还能给什么

日期 2026-11-19。基于 SpektraLab / Silverphase 源码与 Pocket CCD 现状的对照。
只分析，未改代码。

## 0. 三个最大发现

1. **我们的预览每帧走全尺寸 buffer**：`videoSettings` 只设了 BGRA，没设宽高 → 4032×3024×4 ≈ **48 MB/帧**，30 fps 约 **1.4 GB/s** 内存带宽；Silverphase 用 `deliversPreviewSizedOutputBuffers` 只给预览尺寸。
2. **成片被编码两次**：相机 JPEG/HEIC → `UIImage` 解码 → look → `jpegData(0.95)`。他们用 ProRAW/HEIC 源 + 16-bit 管线。少一次有损编码，是画质最直接的一刀。
3. **光学层缺 halation 和 diffusion**：我们只有 `CIBloom` + vignette；他们有两套物理模型（背反射光晕、黑柔/白柔）。这是"胶片/CCD 感"里我们还没做的那部分。

## 1. 拍照速度

### 1.1 预览输出尺寸（P0，最大的一刀）

- 他们：`frames.deliversPreviewSizedOutputBuffers = true`、`automaticallyConfiguresOutputBufferDimensions = false`（iOS 26+），预览数据通路只拿预览尺寸；`alwaysDiscardsLateVideoFrames = true`。
- 我们：`videoOutput.videoSettings` 只设 `kCVPixelFormatType_32BGRA`，没设宽高 → 全尺寸 4032×3024。
- 收益：相机写入 + GPU 采样带宽约 **10×**；`detectOpenHand` 的 Vision 输入从 12 MP 降到 1280 级；发热/续航同步改善。
- 低版本兼容：老 API 可在 `videoSettings` 指定 `kCVPixelBufferWidthKey/HeightKey`（iOS 26 之前）。
- 风险：bloom、grain 的 pixel-space 参数依赖预览宽度（代码里已有 `pitch` 归一化），换尺寸要用同一套归一化复验，别让预览和成片观感漂移。

### 1.2 预置拍摄设置（P1，只有高分辨率才值得）

- 他们：只有 `maxPhotoDimensions` ≥ 40 MP 时才 `setPreparedPhotoSettingsArray`，普通 12 MP 不预置。
- 我们：12 MP，可不做；如果上 48 MP，这是降快门延迟的标准手段。

### 1.3 质量/速度档位（现状是对的）

- 他们：Bayer RAW `.speed`、12 MP `.balanced`、非人像默认 `.quality`。
- 我们：日常拍照 `.balanced`、闪光连拍 `.quality`——和"CCD 直出"的定位一致，不用改。

### 1.4 零快门延迟（现状是对的）

- 我们关掉了，理由写在注释里（pre-roll 帧曝光早于快速场景变化，会过曝）。他们也没开。保留这个取舍。

### 1.5 响应式拍摄（已开）

- `isResponsiveCaptureEnabled = true` 已开，保留。`isFastCapturePrioritizationEnabled = false` 也对——质量优先。

### 1.6 动态预览分辨率（P1）

- 他们按交互耗时调：`> 200 ms` 降 80%，`< 70 ms` 升 15%（`MobilePreviewPolicy.nextInteractionEdge`）。
- 我们固定 1280 + 24 fps 门（今天刚修掉把 30 fps 砍半的 bug）。可以加"手指拖动曝光/对焦时临时降一档"，比固定帧率更贴实际。

### 1.7 保存路径（P2）

- 他们：`PHPhotoLibrary.performChanges`，ProRAW 作为 `alternatePhoto` 一起存。
- 我们：保存路径可对照检查是否同步阻塞主线程。

### 1.8 拍摄方向（P2）

- 他们：`RotationCoordinator` + 快门瞬间锁定的物理姿态，不靠预览层推断。
- 我们：固定 `.right` / `.leftMirrored`。如果 App 允许横拍（当前是竖拍 UI 则无碍），横拍方向会错。

## 2. 照片质量

### 2.1 双重编码（P0，最大的质量提升）

- 我们：`photo.fileDataRepresentation()` → `UIImage` → `CIImage` → look → `jpegData(0.95)`。
- 他们：ProRAW / HEIC 源，16-bit 处理，最后才编码一次。
- 改法（按收益排序）：
  1. 优先用 `photo.pixelBuffer`（未压缩像素）进 look，跳过第一次 JPEG/HEIC 解码；
  2. 输出改 HEIC（10-bit），或高质量模式输出 16-bit PNG；
  3. 如果保留 JPEG，至少避免 `UIImage` 往返（直接 `CIImage(pixelBuffer:)`）。

### 2.2 ProRAW / 48 MP（P2–P3，看定位）

- 他们：ProRAW 优先，12 MP 可选。
- 收益：绕开 Apple 计算摄影的过度锐化/降噪——今天质感分析里锐化占 15%，正是我们的硬问题之一（双重锐化）。
- 成本：RAW 解码、色彩管理、处理时间、存储；对"CCD 直出"定位可能过重，更适合付费专业版。

### 2.3 Halation + diffusion（P2，最像"胶片"的物理层）

- 他们：`halation_amount` / `boost_ev` / `scatter_amount` / `antihalation_removed` / `headroom_ev`；`diffusion_filter_family/strength/spatial_scale`（黑柔、白柔等）。
- 我们：`CIBloom` + vignette，没有背反射红晕和柔光滤镜。
- 收益：夜景高光边缘的红晕、直闪人物的柔光，是 CCD/胶片观感里最容易被眼睛认出的部分，成本远低于整套光谱引擎（一个径向模糊 + 门限 + 色相偏置即可）。
- 注意：halation 是空间效应，不能进 3D LUT，要留在 look 链上。

### 2.4 曝光/白平衡与预览一致（P0–P1）

- 今天修的白平衡缓存串图 bug 就是这类问题：预览复用了 0.5 s 缓存，成片继承了墙面的增益。
- 他们 1.3.0 专门做了"匹配相机预览亮度"作为每张照片的起始曝光。
- 建议：成片与预览用**同一套测量函数**，缓存只允许给 live 预览；成片必须自测。这条今天已经修了，补一条回归测试即可锁住。

### 2.5 多镜头/焦段（P3）

- 他们：超广角 / 1× / 35 mm / 2× / 3× / 长焦 / 8× / 前置。
- 我们：后置广角 + 前置。0.5× 和 2× 对构图有用，但对"CCD 一机一镜"的身份是减法，不建议跟。

### 2.6 人像深度（P3）

- 他们：portrait depth + matte。我们没有人像模式；和 CCD 定位不符，跳过。

## 3. 优先级

| 动作 | 收益 | 成本 | 风险 |
|---|---|---|---|
| 预览输出降尺寸 | 高（带宽/发热/帧率） | 低（配置 + 复验归一化） | 中（观感漂移） |
| 去掉双重 JPEG 编码 | 高（画质） | 中（capture 路径改造） | 低 |
| HEIC 输出（10-bit） | 中高 | 低 | 低（兼容性） |
| halation / diffusion | 中高（质感） | 中（shader/CI 实现） | 低（可调参数） |
| 动态预览分辨率 | 中 | 低 | 低 |
| 48 MP / ProRAW | 高（专业向） | 高 | 中（定位偏移） |

## 4. 一句话

拍照速度上，我们最大的浪费是**把 12 MP 的帧当预览用**；画质上，最大的浪费是**把成片编码了两次**。这两件都不用动渲染架构，改配置和 capture 路径就能拿到；halation/diffusion 再往上，才是"像不像胶片"的那层。
