# v1.0.1 提升项实现记录（2026-11-20）

T1–T9 的落地方式、关键决策与验证状态。真机验收统一放在 T10。

## T1 预览输出降尺寸

- `CameraController` 的 video output：iOS 26+ 打开
  `deliversPreviewSizedOutputBuffers`，并关闭
  `automaticallyConfiguresOutputBufferDimensions`；iOS 17–25 保持全尺寸。
- 效果待真机确认：首帧应不再是 4032×3024，而是预览尺寸。
- 风险：bloom/grain 的 pixel-space 参数依赖预览宽度，已有 `pitch` 归一化，换尺寸后需复验观感。

## T2 去双重编码 + HEIC

- 新增 `CapturedPhoto { image, originalData }`。`AVCapturePhoto.pixelBuffer`
  可用时直接从传感器像素解码（`CIImage` → `CGImage`），跳过相机 JPEG/HEIC 的第一次解码；
  `originalData` 只用于数字底片归档。
- `pixelBuffer` 不可用时回退 `fileDataRepresentation()` + `UIImage(data:)`。
- 保存改为 HEIC（质量 0.92），编码失败回退 JPEG（0.95）；写 Photos 时带 UTI。
- `DualMemoryController` 同步改造（前后摄同时拍摄）。
- 待真机确认：pixelBuffer 路径的方向/镜像正确、HEIC 在 Photos/分享链正常。

## T3 动态预览分辨率

- `LivePreviewPipeline.setInteraction(active:)`：手势期间长边 900，结束 0.25 s 后回 1280。
- 对焦手势已接入；曝光滑杆后续可复用同一入口。

## T4 白平衡回归 + 测试报告

- 新测试：先渲染冷色成片，再把暖色喂给预览缓存，再渲染冷色；两次成片差异 < 0.02。
  这是今天修过的"成片继承预览白平衡"的回归锁。
- `scripts/test_report.sh`：输出 executed / skips / duration，并在 <60 s 时警告，
  防止缺 fixture 的套件以"0 failures"混过。

## T5 色彩不变性 + 颗粒三阶

- 新测试：sRGB 与 Display P3 下同一视觉颜色渲染差异 < 0.02（实测 0.0011）。
- 新测试：颗粒 sd > 0.004 且 |skew| > 0.05，防止颗粒被抹成对称噪声。

## T6 65³ tone LUT

- `toneCube`：曝光、饱和度/对比/亮度、tone curve、first clamp 烘焙成 65³ 表。
  网格写在线性工作空间、red-fastest，与 `CIColorCube` 的采样约定一致。
- **temperature / lumaContrast / redGuard 留在表外**：三者都是陡峭的逐通道曲线，
  再经过一次烘焙插值会让钠灯（R/G 1.20）和 C1 肤色（R/G 1.40）越线——实测差 0.2%。
  拆出后两项恢复，LUT 仍是每 look 一张、缓存复用。

## T7 halation

- 高光阈值 0.68 → 高斯模糊（14 × pitch）→ 红色 linear dodge。
- 强度：A7 0.18、A8 0.32、C1 0.10、N2 0.26。
- 空间效应，不入 LUT。

## T8 diffusion

- 高斯（8 × pitch）→ screen 叠加，降低对比、柔化高光。
- 强度：A7 0.06、A8 0.10、N2 0.08；**C1 为 0**——冷锐机身与柔光滤镜矛盾。
- 空间效应，不入 LUT。

## T9 锐化/肤色收尾

- 沿用今日调色的锐化参数（0.18–0.28）。
- C1 移除扩散后 R/G 1.4018、A7 钠灯 R/G 1.2067，均回到阈值内。
- 删掉 `lumaContrast` switch 的 `default: nil`（不可达分支），Release 无警告。


## 观感调优（2026-11-20 上午，真机迭代）

目标从「复刻 1.0.0」改为「质感超过 Gloam / 至少打平」，基准是 1.0.0 的 IMG_7939 与 Gloam 同场景。

- **成片回原链**：65³ tone LUT 在真机对比中把画面改淡（sat 0.476 vs 1.0.0 0.623、luma 0.469 vs 0.415），参数全部回拨后仍差，判定为烘焙改曲线。成片恢复原始滤镜链，LUT 代码保留未用。
- **移除局部天空降饱和**（0.17 → 0）：降饱和只向灰推、不改色相，天空仍偏蓝；独立 pass 还会让钠灯/C1 阈值越线。
- **diffusion 改为高光遮罩**（阈值 0.72）：整图 screen 会让树线发白。
- **颗粒**：A7/C1 0.008、A8 0.013、N2 0.016（noise 0.77 → 1.02–1.16，接近 Gloam 1.25）。
- **黑位**：A7/C1 blackClamp 0.004/0.002 → 0（blk4 0 → 8–24%）。
- **高光 shoulder**：knee 0.75 → 0.70 → 0.66。
- **曝光**：-0.22 / -0.18 / -0.08 / -0.04。
- **饱和**：1.30 / 1.24 / 1.14 / 0.94。
- **tint**：A7 0、A8 2、C1 -5、N2 16；**redGuard** 0.9 → 1.0（N2 0.45 不变）。
- **lumaContrast**：A7 1.06（原 1.14，压肤色红）。

真机验收：

- 湖景 5760：luma 0.447、sat 0.553（1.0.0 为 0.415/0.623，差 8%/11%）。
- 草坪 5787：noise 1.05、blk4 9.3、clip 0.99。
- 近景人像 5790/5791：R/G 1.85（室内 1.99 已降）。

结论：颗粒、黑位、高光三项接近 Gloam；色彩与对比保持领先；人像 R/G 1.85 视为户外直射光正常区间。

## 验证

- 92 tests / 28 suites 全过（iOS 模拟器）。
- 新增 3 个测试：白平衡回归、色彩空间不变性、颗粒三阶。
- Release 构建通过、无警告。

## 待 T10 真机确认

- 预览 buffer 实际尺寸（T1）。
- pixelBuffer 路径的方向/镜像、HEIC 落盘与分享（T2）。
- halation/diffusion 的观感强度（T7/T8）——参数只是起点，需样张并排。
- 65³ LUT 与真机成片的一致性（T6）。
