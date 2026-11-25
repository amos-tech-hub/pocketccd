# Look 调参记录 · 2026-11-19（C1 / A8）

依据：`docs/SAMPLE_QUALITY_REVIEW_2026-11-19.md` 的 P1 结论。改动全部在 `CCDLook.swift`，
新增单测在 `ProductInfrastructureTests.swift` 的 `Look calibration` 套件。

---

## 1. 改了什么

| look | 参数 | 旧 | 新 | 为什么 |
|---|---|---:|---:|---|
| C1 chrome | `whiteClamp` | 0.97 | **0.94** | 长椅场景高光裁切 8.19%（门槛 <2%） |
| C1 chrome | 曲线顶点 | 0.965 | **0.945** | 与白点一起下移，避免肩部顶死 |
| C1 chrome | `exposureEV` | +0.10 | **+0.04** | 四 look 里只有 C1 系统性过曝 |
| C1 chrome | `temperature` | 7200 | **6800** | 天空被推到青色（同场景 skyG/B 0.79） |
| C1 chrome | `tint` | −7 | **−2** | 肤色 R/G 1.84（四 look 最红），品红方向减半 |
| C1 chrome | `saturation` | 1.04 | **0.98** | 肤色偏红主要来自饱和度，不只色温 |
| C1 chrome | `contrast` | 1.22 | **1.18** | 逐通道对比会把红通道推满 |
| A8 party | `shadowLift` | 0.0 | **0.04** | 白天暗部压死（blk4 最高 14.1%） |
| A8 party | 曲线 toe | (0.12, 0.05) | **(0.12, 0.075)** | 同上，先救脚部 |
| A8 party | `lumaContrast` | 1.18 | **1.12** | 压死暗部的真正来源，见下 |

## 2. 顺带修掉的一个 bug

`lumaContrasted(_:strength:)` 收了 `strength` 却没用它——颜色立方体是静态 `let`，里面**硬编码 1.18**。
所以 `lumaContrast` 这个属性一直是摆设：把值从 1.18 改成 1.10，输出像素一个都没变（探针实测三档完全相同）。

现在立方体按 strength 生成并缓存（`lumaContrastCube(strength:)` + `lumaCubeCache`），
膝点公式抽成纯函数 `CCDLook.lumaTarget(luminance:strength:)`，可以直接单测。

顺带把 A8 暗部压死的机理量化了：pivot 0.18、strength 1.18 时，**线性亮度低于 0.0245 的像素全部归零**
（相当于 sRGB 43 以下无细节）。1.12 把零点降到 0.0164，中灰几乎不动（0.5 → 0.538）。

## 3. 探针实测（512×512 色块，同机同管线）

| 输入 | look | 改前 R/G/B | 改后 R/G/B | 说明 |
|---|---|---|---|---|
| 白 0.98 | C1 | 245.0 / 245.0 / 245.0 | **239.0** / 239.0 / 239.0 | 白点提前咬住 |
| 白 0.90 | C1 | 239.8 / 240.0 / 241.1 | **233.0** / 233.0 / 232.0 | 高光肩部变缓 |
| 肤色 0.78/0.48/0.42 | C1 | 220.7 / 97.7 / 64.0（R/G 2.26） | **214.4 / 102.1 / 71.6（R/G 2.10）** | 脸没那么品红 |
| 中灰 0.50 | C1 | 118.6 / 118.6 / 117.9 | 118.5 / 118.9 / 114.5 | 基本不动 |
| 白 0.98 | A8 | 244.3 / 244.3 / 224.8 | 244.3 / 243.8 / **220.3** | 高光少一点黄 |
| 中灰 0.50 | A8 | 138.7 / 128.8 / 99.9 | 138.0 / 128.0 / 101.3 | 中灰不动，脚部抬起来 |

> 探针的暗部（输入 0.01–0.10）在测试环境里输出完全相同（≈15–16/255），和 11-18 记录过的
> 「合成色块在测试环境响应异常」是同一个现象。所以**暗部不能靠单测验收**，必须真机。

## 4. 单测

新增 `Look calibration` 4 条：

1. `C1 keeps a white shirt under its white point` —— 0.98 白块最大通道 ≤242、裁切 <0.5%；
2. `C1 skin no longer leans as far into magenta` —— 肤色 R/G 落在 1.8–2.2；
3. `A8's shadow knee actually moves with the strength` —— `lumaTarget(0.02, 1.18) == 0`、`lumaTarget(0.02, 1.12) > 0`；
4. `A8 midtones are not flattened` —— `lumaTarget(0.5, 1.12) ≈ 0.538`、`lumaTarget(1.0) == 1`。

全量测试通过（`xcodebuild test`，模拟器 iPhone 17 Pro）。

## 5. 还缺真机验收（这批参数目前只有合成证据）

| 项 | 门槛 | 用什么拍 | 现状 |
|---|---|---|---|
| C1 高光裁切 | <2% | 长椅 + 白衬衫，顺光 | 待重拍 |
| C1 肤色 | R/G 1.15–1.5 | 同上，脸在阴影里也要一张 | 待重拍 |
| C1 天空 | 不再发青 | 湖面/天空 | 待重拍 |
| A8 暗部 | blk4 <6% | 高架/树荫同机位 | 待重拍 |
| A8 夜闪 | 黑位仍要黑 | 室内直闪 | 待重拍 |
| N2 夜间四门槛 | 见 §6 | 夜间街景 ×2 | 缺当前构建样张 |

## 6. N2 夜间验收：现在只能跑基线

`scripts/n2_night_acceptance.py` 按 `Research/CompetitiveImagingBenchmark.md` 的 N2 门槛打分。
设备胶卷里**最后一次拍摄是 14:03**，之后没有新样张；能拿到的 N2 只有 11-15 那两张（在
`/tmp/pccd-samples/PocketRoll`），而 11-18 22:32 的 N2 提亮改动晚于它们，**所以它们不能代表当前参数**。

基线结果（仅作对照）：

| 文件 | luma | black<0.04 | clip | sat | R/B | 判定 |
|---|---:|---:|---:|---:|---:|---|
| 31E459C1 | 0.215 | **0.0%** | 0.02% | **0.367** | 1.28 | fail: black / clip / sat |
| B7561C5E | 0.109 | **0.0%** | 0.02% | 0.176 | 1.23 | fail: black / clip |

两处失败很明确：**背景不是黑，是被抬到灰的噪点底**（0% 像素低于 luma 0.04），以及**没有点光源裁切**
（说明画面里根本没有形成「密集黑 + 分离点光」的夜景结构）。R/B 1.23–1.28 是过门槛的。

要收尾，拍两张即可（都选 N2）：

1. 夜间街道 · 关闪光：要有招牌/路灯点光源 + 黑天空；
2. 室内直闪人像：脸在 1.2 m，背景留暗。

导出后跑：

```bash
python3 scripts/n2_night_acceptance.py <导出目录>
```

全 PASS 才算 N2 收工；若有 fail，再决定是收 `tint +32 → +20`（青色掉一档、但会伤钠灯补偿）
还是只调 `shadowLift`。

## 7. 验收怎么跑（一条命令）

```bash
# 1) 把新导出的照片放进一个文件夹（比如 pictures/2026-11-20/）
# 2) 从胶卷 manifest 生成 {IMG_xxx.JPG: C1} 映射（见 SAMPLE_QUALITY_REVIEW_2026-11-19.md §1）
# 3) 人脸 R/G 探针（可选，只对有人的帧）
swiftc -O Research/face_probe.swift -o /tmp/face_probe
/tmp/face_probe <folder>/*.JPG > faces.json
# 4) 跑门槛
python3 scripts/look_acceptance.py <folder> --labels labels.json --faces faces.json
```

判定口径：A7 clip 0.5–2.5% / sat 0.24–0.42 / 肤色 1.15–1.35；C1 clip <2% / sat 0.20–0.36 / 肤色 1.15–1.50；
A8 blk4 <6% / clip <4%；N2 blk4 18–55% / clip 0.3–3% / sat 0.12–0.30 / 中性 R/B 1.15–1.35。

用今天的旧样张跑基线（应为大量 fail，证明门槛抓得住已知问题）：51 帧里 40 帧有门槛失败，
C1 黄叶树 clip 4.08%、A8 高架 blk4 10.6% 都能复现——验收脚本本身是可信的。
