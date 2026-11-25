# 从拍到发：空间、片段、预览与出口（2026-11-16）

这一批是继「索引自愈」之后的四件事，顺序按对用户的伤害排序：
**会丢素材的（B/C）→ 每天都能感到的（D）→ 每次都要多点几下的（E）**。

## 1. P0-B 空间护栏

问题不是「没有提示」，而是**满盘时快门照样响、照片照样没有**。

| 位置 | 行为 |
| --- | --- |
| `StorageGuard`（`ProductInfrastructure.swift`） | 用 `volumeAvailableCapacityForImportantUsage` 判定 `ok / low(600 MB) / critical(150 MB)`；查询失败按 `ok` 处理——一次读不到容量不该在聚会中途锁死快门 |
| 快门（`capture()`、`beginDualMemory()`） | `critical` 时不开拍，弹一句「先开发这一卷或清理原片」，而不是拍完才发现没存下 |
| 原片归档 | `critical` 时直接跳过：可选证据永远让位于主产物 |
| 卷写入（`RollStore.add`） | `critical` 时提前拒绝并置 `blockedByStorage`，提示语与「卷满了」分开——两者该去的地方不同 |
| 启动 | `low` 给一行警告，`critical` 给可执行提示 |

阈值是按这个 App 的写入量定的：渲染帧 3–6 MB、24 帧一卷约 120 MB、原片约 4 倍。
单测锁定的是判定边界（`StorageGuardTests`），不是某个具体机型。

## 2. P0-C Moment 片段留存

2 秒原始片段写在临时目录，结果页一关就被删（`CameraScreen` 的 `onDismiss`）。
用户点右上角 × 的那一刻，片段就永久消失，只剩一张最佳帧。

改动：结果页的关闭按钮改为 `attemptClose()`——片段未保存到相册时，先出一张
`UNSAVED CLIP` 面板，两个出口：

- **Save clip to Photos**：保存成功后自动关闭（失败仍走原来的 COULDN'T SAVE 提示）；
- **Close without saving**：红色行，明确写出会丢失什么。

`clipSaved` 由包装后的保存闭包置位，视频与 Live Photo 两条路径都覆盖。
刻意没做的事：把片段移进卷目录。那需要给 `RollEntry` 加视频字段、迁移旧索引、
再补一套播放/导出 UI——在「一次拍摄只有一次机会」的诉求前，先让用户别误删。

## 3. P1-D 预览接受 flash 与卷锚

这是「预览与成片一致」的根因修复，不是调色。

- `CCDLook.livePreview` 新增 `flashStrength`、`colorAnchor`、`consistencyStrength` 三个入参，
  与 `render` 走**同一套顺序**（锚 → processed → lensCharacter → clamp）。
- `LivePreviewPipeline` 新增 `update(flashMode:)` 与 `update(colorAnchor:consistencyStrength:)`。
  `.on` / `.off` 是确定的；`.auto` 由画面平均亮度估计（阈值 0.16 / 0.24 带迟滞，
  每 250 ms 采样一次），因为真实答案只存在于成片的 EXIF 里。
- 卷锚走**只读** `RollStore.peekColorAnchor(for:)`。`colorAnchor(for:sample:)` 每次调用都会
  blend 并 persist，预览若直接用它，会以 24 fps 推动卷锚漂移——那不是修复一致性，是制造它。
- `consistencyStrength == 0` 时跳过稳定化：标准单拍本来就不吃锚，没必要每帧做一次
  面积平均。成片在这种情况下也是恒等变换，输出不变。

门禁（`PreviewParityTests`，用同一张双色卡的均值比较两条链路）：

| 量 | 数值 |
| --- | --- |
| 闪光分支对均值的真实影响 | **0.205** |
| 无闪时 preview vs render | 0.00024（float16 量化级） |
| 有闪时 preview vs render | 0.000027 |
| 断言 | 有闪差值 < 0.01 |

也就是说：修复后两条链路差在量化噪声以内；一旦有人把 `flashStrength` 重新写死成 0，
差值会跳到 0.2，测试立刻红。

## 4. P1-E 整卷出口收敛

原来：卷 → EXPORT → 四格式选一（SQUARE / IG FEED / IG STORY / TIKTOK）→ 异步渲染 →
预览页 → SHARE → 系统面板。**五步，中间夹着一个产品决策。**

现在：主按钮 `EXPORT 9:16` 直接按 9:16 渲染并进入预览（预览里有 SHARE / SAVE IMAGE），
`FORMAT` 才是次级入口，Pocket Day 回到 `⋯ MORE`。

- 卷内点击：1（导出）+ 1（分享）= **2 步**；
- 格式不再挡在主路径上，但也没有被删掉；
- `EXPORT 9:16` 复用既有文案，新增的只有 `FORMAT`。

## 5. 验证

- 全量 **52 tests / 18 suites** 通过（Simulator arm64，iPhone 17 / iOS 27.2）。
- 新增套件：`Preview parity`（3）、`Storage guard`（2），并补了
  `Peeking the roll anchor does not move it` 守住只读约定。

仍待真机（Simulator 无摄像头）：

- 预览新增的两处 1×1 回读（自动闪判断 + 锚稳定化）对 24 fps 的实际影响；
- `auto` 闪光在真实暗场里是否与 EXIF 判定一致，迟滞是否够；
- `critical` 阈值在真实满盘设备上的手感（150 MB 是否太晚/太早）；
- 9:16 主按钮在 24 帧满卷上的渲染耗时。

## 6. 下一批

1. **P2-F 双链路原片回归**：把真机 `PocketCCD Originals/` 喂进 `PreviewParityTests` 的同构断言，
   用真实夜闪原片而不是合成卡做门禁。
2. Story 单图卡（一卷里挑一张，直接出 9:16 卡），把「选帧 → 分享」也压到两步。

## 7. 真机原片读取器（P2-F 的前半段）

`OriginalFrameArchive` 已经把原片和拍摄参数落盘，本轮补上读取这一侧。

**位置**：`ProductInfrastructureTests.swift` 的 `OriginalsFixtureReader`。
样张目录是 `Research/Samples/Originals/`，目录里只有 `README.md` 与 `.gitignore`，
真实照片不进仓库。也可用 `POCKETCCD_ORIGINALS_DIR` 指向刚导出的设备容器。

**读什么**：每个 `capture.json` 解析出机身、前后置、模式、镜头、ISO、快门、色温、
闪光状态，以及它列出的每一帧；帧文件缺失的样张会被跳过并计入 `skipped`，
而不是静默消失。

**筛什么**：`filter(captures, camera:flashMode:mode:)`，token 是品牌原文
（`POCKET A8` / `FLASH` / `flashParty`）。

**怎么跳过**：`Real capture parity` 套件带 `.enabled(if: OriginalsFixtureReader.hasSamples)`。
目录为空时整组显示为 skipped，合成卡套件（`Preview parity`）照常跑；
坏掉的 manifest 会让真实套件**失败**并列出路径，不会被当成「没有样张」。

**已经用一次临时样张验证过**（生成图，验证后已删除）：

| 检查 | 结果 |
| --- | --- |
| 测试进程能否读工作区里的样张目录 | 能（`#filePath` 派生的路径） |
| 读取器 → 统计 → 两条链路 | 跑通，打印 `REAL PARITY … delta=0.0` |
| 未对齐裁剪时 | delta=0.0137 —— 说明测试必须先按 4:3 裁再比，否则量的是裁剪不是配方 |

现阶段的断言只有一条：真实样张上 preview 与 render 的通道均值差 < 0.03（临时预算，
比合成卡的 0.01 宽，因为两条链路的实际分辨率不同）。**肤色 R/G 与黑位阈值不在这里定**，
等样张进来后按 `REAL FLASH` 打印出的数值定。

### 整图统计不能当背景黑位用

第一次打印出的是 `black=20`。这个数是**整图的 5% 分位数**，而调色日志里的「背景 ≤ 8」
量的是背景区域——夜闪照片里黑背景和高光人脸同时在画面里，整图分位数把两者混在一起，
两个数不可比。现在的处理：

- 整图统计只在没有 ROI 时输出，标签是 `frameP05`，并显式标注 `(whole-frame)`；
- 分区统计来自文件夹里的 `roi.json`（归一化、左上角原点，`background` / `faceLit` 两个键），
  输出 `bgP05` 与 `faceRG`，这才是能与日志对照的量；
- 报告按**机身材分**：`REAL BODY POCKET A8 n=…`，因为 A7 与 A8 的目标区间不同，
  不会共用一条肤色或黑位门禁；
- `roi.json` 存在但读不通时，该样张进 `skipped` 并让真实套件失败——否则会静默
  退回整图统计，正是这套东西要避免的「绿了但没测到」。

### 背景不能只看 p05

`p05` 只描述背景区域里**最暗的 5%**。画面角落一小块真黑就能把它压到 1–3，而背景其余部分
可能是一片灰——单看 p05 会把灰底读成黑底。现在 ROI 行同时给：

| 字段 | 含义 |
| --- | --- |
| `bgP05` | 背景亮度 5% 分位数（最暗的部分） |
| `bgP50` | 背景亮度中位数（多数像素在哪） |
| `bgBright` | 背景中亮度 > 40 的像素占比（有多少面积是灰底） |

`greyBackgroundIsNotMasked` 用「10% 真黑 + 90% 灰 60」的合成图把这条钉住：
p05 必须 < 8、p50 必须 > 40、bgBright 必须 > 0.8。三者一起看才是背景黑位。

写 ROI 之前有个坑值得记：给 `CGContext` 加垂直翻转会**反**掉区域映射（第一版实现就
翻错了，`regionMapping` 用例当场变红：上半白、下半黑的图，顶部 ROI 量出来是黑的）。
`CGImage` 的行本来就是自上而下，`context.draw` 不加翻转时位图第 0 行就是画面顶行。

### 这套东西不能证明什么

现有 parity 测试（合成的和真实的）都只证明：同一张输入经过预览链路与成片链路后结果接近。
它不能证明 `.auto` 的亮度预测与真机最终 EXIF 一致——那只存在于暗场真机对照里，
仍是待办，别把这里的绿灯当成那个结论。
