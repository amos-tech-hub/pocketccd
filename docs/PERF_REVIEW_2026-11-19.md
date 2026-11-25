# 性能审查 · 2026-11-19（「试用时会卡」）

方法：静态审查 + 在 XCTest 里对三条热路径做微基准（模拟器 CPU/Metal，12MP 真实样张
`pictures/IMG_5610.JPG`）+ 在预览管线里加了一个 DEBUG 统计器，等设备解锁后可直接读真机数值。

---

## 0. 先给结论

- 预览管线本身**不是**主要瓶颈：1280 px 一帧 7–14 ms，24 fps 的预算是 41 ms。
- 真正能测到的两块成本：**整张渲染 113 ms**（快门后）、**人脸分析 160 ms**（已砍到 85 ms）。
- 剩下的「卡」大概率来自 **GPU→CPU 回读 + 主线程换图**（每帧一次 1280×960 的读回，24 次/秒），
  以及**快门后串行渲染多帧**。这两项要真机 trace 才能定量，代码里已埋好探针。

| 热路径 | 改前 | 改后 | 说明 |
|---|---:|---:|---|
| 预览帧（1280 px，全 look 管线 + 回读） | — | **7–14 ms** | 24 fps 预算 41 ms，有富余 |
| 整张成片渲染（4032 px，含日期戳） | — | **113 ms** | 首次 561 ms 含 GPU 管线编译 |
| 人脸/质量分析（4032 px） | **160 ms** | **85 ms** | 已改为 1280 px 分析 |
| 三连闪整段快门延迟 | ≈ 3×113 ms + 分析 | 未改 | 串行渲染，建议下一轮处理 |

---

## 1. 已修

### P0 · 人脸分析跑在 4032×3024 全分辨率上

`FrameAnalyzer.assessSynchronously` 对每帧跑两个 Vision 请求（`VNDetectFaceCaptureQuality`
+ `VNDetectFaceLandmarks`）外加全图统计。快门按下后，结果页要等这一轮跑完才出现；
`Flash Party` 三帧要跑三次。**实测 160 ms/帧，改成 1280 px 分析后 85 ms/帧**（同机同图）。

面部的相对大小在 1280 px 上仍有 ~2.5× 余量，眼睛开合与质量评分不受影响；`faceRects`
按比例放大回原始像素，`CCDLook.faceMask` 的语义没变。

### P1 · SwiftUI 每次刷新都重装预览回调

`CameraPreview.updateUIView` 每次都调用 `pipeline.setFrameHandler { … }`：取管线锁 + 新建闭包，
而闭包永远指向同一个 view。相机页每秒有多次 body 更新（倒计时、进度、toast），这些锁和分配都是白花的。
已删除；`makeUIView` 装、`dismantleUIView` 拆，生命周期已经够用。

---

## 2. 待办（按收益排序，需要真机数据确认）

### P0 · 预览每帧一次 GPU→CPU 回读

`LivePreviewPipeline.processFrame` 把 CIImage 渲染成 `CGImage`（1280×960 ≈ 5 MB），
主线程再 `UIImage(cgImage:)` 塞进 `UIImageView`，Core Animation 再把它传回 GPU。
等于每帧一次往返，24 次/秒 ≈ 120 MB/s。这是目前最像「抖动」的来源。

两条路：
1. **省事**：把 `filteredImageView` 换成 `CAMetalLayer`（或 `MTKView`），用
   `CIContext.render(_:to:commandBuffer:)` 直接画到 layer 的 drawable，彻底去掉回读；
2. **保守**：把预览降到 1024 px 并隔帧渲染（30 fps 输入 → 20 fps 显示），先看抖动是否消失。

我倾向 1，改动集中在 `PreviewView` + `LivePreviewPipeline` 两处，约 100 行。

### P1 · 快门后的多帧是串行渲染

`CameraScreen.capture` 里 `for step in plan` 逐帧 `await` 渲染，Flash Party 三帧就是三次 113 ms。
可选：先渲染建议帧并弹结果页，其余帧在 `Task` 里补渲染并原地更新；或三帧并发（GPU 会串行，
但能省掉 Swift 层的等待）。都要真机验内存峰值。

### P2 · 启动时胶卷索引在主线程

`RollStore` 是 `@MainActor`，`load()` 里读 manifest/archives JSON 并逐张 `fileExists`。
目前几十条记录问题不大；等用户卷攒到 24+ 张、或导入备份时会变成启动卡顿。建议把解码+校验搬到
`Task.detached`，只把结果回主线程。

### P2 · 手势快门每帧新建 Vision 请求

`detectOpenHand` 只在「定时器 + 手势快门」同时开启时跑，每 0.22 s 一次 `VNDetectHumanHandPoseRequest`，
对象每帧新建。优先级低，但可以复用 request 实例。

---

## 3. 真机探针怎么用（已埋好，仅 DEBUG）

`LivePreviewPipeline` 现在会在 `#if DEBUG` 下把每帧的渲染耗时、主线程延迟、丢帧数写进
`Documents/preview-stats.json`（每 2 秒落盘一次）：

```bash
# 手机解锁、App 停在取景页 10 秒以上，然后：
xcrun devicectl device copy from --device <UDID> \
  --domain-type appDataContainer --domain-identifier work.doublenine.pocketccd \
  --source Documents --destination /tmp/pccd-docs
cat /tmp/pccd-docs/preview-stats.json
```

判读：`renderAvgMs` 接近或超过 41 ms、或 `skipped` 增长很快 → 预览确实在掉帧；
两者都健康但用户体感仍卡 → 问题在回读/主线程，往 P0 的 Metal 方案走。

想要更细的火焰图，用 Instruments：

```bash
xcrun xctrace record --template 'Time Profiler' --device <UDID> \
  --attach PocketCCD --time-limit 20s --output /tmp/pocketccd-time.trace
```

---

## 4. 本轮改动清单

| 文件 | 改动 |
|---|---|
| `FrameAnalyzer.swift` | Vision 分析降到 1280 px；`faceRects` 按 `analysisScale` 换算回原始像素 |
| `CameraPreview.swift` | 删掉 `updateUIView` 里重复的 `setFrameHandler` |
| `LivePreviewPipeline.swift` | `#if DEBUG` 预览耗时统计（render / 主线程延迟 / 丢帧） |

测试：85 tests / 25 suites 通过（改动未触碰现有断言）。

---

## 5. 追加发现（2026-11-19 晚）：工程从未定义 `DEBUG`

埋了统计器之后，真机上一直读不到 `preview-stats.json`。查下来不是探针的问题：

```
$ grep -o "SWIFT_ACTIVE_COMPILATION_CONDITIONS = [^;]*" PocketCCD.xcodeproj/project.pbxproj
（无输出）
```

三个配置都没有定义 `DEBUG`，所以项目里**所有 `#if DEBUG` 块一直是死代码**——包括
`CaptureModels.exportReady()` 里那段把 `x / y / landscape / turns` 写进
`debug.lastOrientation` 的方向诊断（11-18 的记录里说「DEBUG 下可读」，其实从没生效过）。

已修：给三个 Debug 配置加上 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`。
Release 配置不带，行为不变。验证：重新构建后 `strings` 能在二进制里找到 `preview-stats.json`。

同时补了两条启动面包屑（仅 DEBUG），用来区分「App 没起来 / 相机没准备好 / 预览没跑」：

| 文件（容器 Documents） | 写入点 |
|---|---|
| `app-launch.txt` | `PocketCCDApp.init` |
| `camera-prepared.txt` | `CameraScreen` 的 `.task`，`await camera.prepare()` 之后 |
| `preview-stats.json` | 预览第一帧 + 每 2 秒 |

## 6. 怎么取真机数据（手机必须解锁）

`devicectl` 在锁屏状态下 install/launch 会**无输出挂住到超时**（本轮踩了两次）。
保持解锁，然后：

```bash
bash scripts/perf_probe.sh
```

脚本会：装 Debug 包 → 启动 → 等 15 秒 → 拉 `Documents` → 打印三个文件。
`renderAvgMs` 接近 41 ms 或 `skipped` 涨得快 → 预览是真瓶颈；
两项都健康但仍然卡 → 问题在每帧的 GPU→CPU 回读与主线程换图。

---

## 7. 真机数据（2026-11-19 20:50，室内夜间）

iPhone 16 Plus，取景页停留 15 秒，DEBUG 统计：

| 指标 | 值 | 判读 |
|---|---:|---|
| arrivals（相机送达帧） | 217 / 15 s ≈ **14.5 fps** | 相机本身在低光下把帧率降到 ~15，不是我们丢帧 |
| frames（处理并显示） | 217 | **零丢弃**，管线跟得上 |
| skipped | 0 | 主线程没有堵住管线 |
| renderAvgMs | **20.6 ms** | 单帧全 look 管线（含回读） |
| mainLatencyAvgMs | 20.7 ms | 渲染完成即交给主线程，没有额外排队 |
| renderMaxMs | 74.6 ms | 偶发尖峰，约等于丢掉一帧 |

**结论修正**：之前怀疑的「GPU→CPU 回读是主因」**被数据否掉了**——管线每帧都吃下、没有任何跳帧，
单帧 20.6 ms 也远低于同一帧率下的预算。夜间取景只有 ~14.5 fps 是**相机在低光下的行为**（AE 拉长曝光），
不是 App 的处理速度。

### 但发现一个真 bug：24 fps 节流把 30 fps 流砍成 15 fps

`processFrame` 原本是 `guard now - lastFrameTime >= 1.0 / 24.0`。在 30 fps 的流上：
帧落在 0 / 33 / 66 / 100 ms，41.7 ms 的门槛会接受 0、拒 33、接受 66、拒 100 → **稳定 15 fps**，
正好砍掉一半。白天（30 fps）取景会因此比应有的慢一倍；夜间因为源本来只有 15 fps，才看不出来。

已改为 `1/30 - 4 ms` 的容差门槛：30 fps 源每帧都能进，低光 15 fps 源照旧全收。
`arrivals == frames` 说明没有因为这次改动引入丢弃。

**白天需要复验**：目前是夜间数据，30 fps 的收益要等白天拍一次才能确认（同一脚本即可）。
