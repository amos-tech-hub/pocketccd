# 原片归档与机身记忆（2026-11-16）

这一轮是 P0：补上两处「产品说了但代码没做」的欠账，并给后续调色建立证据链。

## 1. 为什么先做这两件

- **机身记忆**：`selectedLook`、`flashMode`、`selectedLens` 原来都放在 `@State` 里，
  关掉 App 再打开必然回到 A7 + AUTO + 1×。产品承诺「打开即回到上次的机身」，实际是假的。
- **原片归档**：拍摄后只保留渲染过的 JPEG，原片渲染完即丢。这堵死了三件事——
  回归样张库、整卷重调、以及「用真实夜拍原片当护栏」。没有原片，
  `NIGHT_FLASH_TUNING_2026-11-15.md` 第 4 节记的坑会反复踩。

顺序是刻意的：先把证据留下来，再谈调色和护栏。

## 2. 机身记忆

| 项 | 行为 |
| --- | --- |
| 记什么 | 机身（A7/A8/C1/N2）、闪光状态（on/off/auto）、后置镜头（0.5×/1×/3×） |
| 何时写 | 每次改动即写 `UserDefaults`（`pocketCCD.identity.*`） |
| 何时读 | `CameraScreen.init()` 读机身，避免首帧闪一下 A7；闪光与镜头在 `prepare()` 之后恢复（那时才知道可用性） |
| 权限被拒 | 不消耗这次恢复：拿到权限并重新 `prepare()` 后会再试一次 |
| 付费撤销 | 记住的付费机身会回落到 A7 |
| 前置镜头 | 切前置会把镜头重置成 1×，但不覆盖后置记忆 |
| 提示 | 只要恢复出的组合不是出厂默认（A7 + AUTO + 1×），启动时出现一行 `RESUMED · A8 · FLASH · 1×`，2.2 秒后消失 |

为什么要那行提示：静默继承对「每天都用 A8」的人是好事，但对偶尔用一次 A8 的人，
第二天白天打开就是硬闪黑底配方。品牌 token（A8、FLASH、1×）不翻译，只有 `RESUMED` 走本地化。

## 3. 原片归档

设置 · ORIGINALS · **Keep original frames**，默认关闭。

- 存储：`Application Support/PocketCCD Originals/<yyyyMMdd-HHmmss>-<6位随机>/`
- 每次快门一个文件夹，内含 `frame-<n>-<role>.<ext>` 与 `capture.json`
- `capture.json` 记录机身、前后置、模式、镜头、EV、ISO、快门、色温、闪光状态、
  每帧角色 / 尺寸 / 字节数 / 像素宽高，时间用 ISO 8601
- 写入发生在 `captureSequence` 拿到原始 `Data` 之后、CCD 渲染之前，
  在归档 actor 的队列上执行，不占主线程，也不拖慢结果页
- 上限：**300 次拍摄或 1.5 GB**，超了从最旧的开始删，最新一次永不删
- Pocket Moment 暂不归档（它走的是视频管线，本轮的归档入口是静态帧）
- 关掉开关不会删除已存内容，设置页会显示「次数 · 占用」并提供 CLEAR（二次确认）

为什么存 `Application Support` 而不是 `Documents`：`Documents` 一旦开 `UIFileSharingEnabled`
会整目录暴露给「文件」App，当前产品没有这个需求；取原片用设备容器即可（见下）。

## 4. 怎么把原片取出来做样张库

真机连 Mac 后：

1. Xcode → Window → Devices and Simulators → 选中设备 → Installed Apps → PocketCCD
2. 齿轮 → **Download Container…**，保存 `.xcappdata`
3. 右键 → 显示包内容 → `AppData/Library/Application Support/PocketCCD Originals/`

每个子文件夹就是一次快门，`capture.json` 里有全部参数。

### 4.1 一键出表

```bash
swift Research/originals_report.swift <archive-root> [--roi face-rois.csv] [--csv out.csv] [--quiet]
```

它直接读归档目录，按 `capture.json` 分组，输出 `<root>/originals-report.csv` 和一段 Markdown 摘要。
测量口径与 `analyze_samples.swift` 一致（1024 px 缩略图、DeviceRGB、0–1 归一化），所以两边的
`grain_proxy`、`clip_ratio` 可以放在一起看。

比旧脚本多出来的三件东西，都是夜闪讨论里真正在用的：

| 列 | 含义 | 怎么来的 |
| --- | --- | --- |
| `skin_r_over_g` / `skin_r_over_b` | 受光侧皮肤通道比 | 用 CoreImage 人脸检测取最大的一张脸，再按左右半张比亮度，取更亮的那半的中位数 |
| `black_floor` / `black_share` | 黑位主峰（0–255）与该值占比 | 人脸框以外的亮度直方图，取 0–79 区间里最高的那一格 |
| `gate` / `verdict` / `failed_checks` | 是否过闸 | 闪光帧走夜闪门槛（R/G ≤ 2.5、R/B ≤ 4、黑位 ≤ 8），高亮度无闪帧走白天门槛（全局 R/B 1.15–1.35、无 255 簇），其余判 `—` |

人脸靠不住时（侧脸、大逆光、戴帽子）可以用人工框覆盖：

```csv
file,x,y,width,height
20261116-230412-4f2a1c/frame-0-flash.jpg,0.31,0.22,0.28,0.36
```

`file` 写 `<folder>/<frame>` 最稳；只写文件名会在多帧、多组拍摄里撞车。
坐标是**显示方向**左上角原点、0–1 归一化，和 `face-rois.example.csv` 一致。

摘要末尾还有「Within-capture spread」：同一次快门里各帧的肤色比与平均亮度极差。
这正是 Roll Consistency 那条承诺的可测形式——同一次连拍里肤色比跳了 0.3，就是这个问题。

### 4.2 已经验证过的部分

用合成样张跑过三条分支（仓库里不留这些图）：

- 暖肤色块 + 黑底：R/G 1.72、R/B 2.17、黑位 8，判 PASS；
- 红光块：R/G 4.25、R/B 5.67、黑位 50，三条同时判 FAIL；
- 高亮无闪帧：走白天门槛，全局 R/B 1.25 判 PASS；
- 无人脸帧：`FAIL: no face region`，而不是静默当成通过。

还没验证的：真实人脸检测的命中率、HEIC 帧、前置镜像帧的 ROI 是否要翻转。
真机拍到第一组原片时应该先看这三条。

## 5. 验收与残留

- `xcodebuild … build`（arm64 Simulator）通过；`xcodebuild … test` 39 项全过（14 个 suite）。
- 新增单测：机身记忆往返、存 `off` 不被当成「没存过」、坏值回落默认、
  摘要文案；归档裁剪策略（按数量、按字节、最新一次永不删）、JPEG 扩展名与像素尺寸，
  以及真实落盘用例（一次快门 = 一个文件夹 + capture.json + 两帧，清空后计数归零）。
- 仍待真机：重启后机身/闪光/镜头是否真的回来、`RESUMED` 提示位置是否压住状态条、
  归档写入对连拍节奏的影响、1.5 GB 上限下磁盘是否够用。

## 6. 下一批

1. A8 三场景基线 + 10 次真实夜拍（现在有原片了，可以直接建 fixture）
2. 把 A7/C1/N2 的 `lumaContrast` 改造铺过去
3. 引入 session 概念 + 结果页「这晚的接触印样」+ 单图 9:16 Story 卡
4. 锁屏 / Control Center 直达（Widget + App Intent，从零开始）
