# 产品文档 vs 当前实现 · 差距盘点

对照基准：`docs/PRODUCT_SPEC.md`（v2026-11-12）、`docs/PRODUCT_BACKLOG.md`、
`docs/IAP_CONFIGURATION.md`。盘点时间：2026-11-15。

一句话结论（2026-11-15 晚更新）：**第一批差距已全部补完，功能面约 97%；
剩下的只有验证类工作和一项明确不做的 iCloud 同步。**

---

## 1. 已对齐（有代码证据）

| 文档条目 | 实现位置 |
| --- | --- |
| 5.1 实时取景、前后置、点按对焦、捏合缩放、EV ±2、闪光开/关、日期戳、导入、仅新增保存 | `CameraScreen.swift`、`CameraController.swift` |
| 5.1 硬件快门（音量键 / Camera Control） | `HardwareShutterView.swift:15`（`AVCaptureEventInteraction`） |
| 5.2 三台虚构机芯 A7 / C1 / N2 | `CCDLook.swift:109`，各自参数在 `render` 链里 |
| 5.3 预览与成片同一配方（预览 1280px 降采样） | `LivePreviewPipeline.swift:79` → `CCDLook.livePreview` |
| 5.3 噪声、banding、bloom、暗角、锐化、白平衡倾向 | `CCDLook.swift:200-270` |
| 5.4 保存 / 分享 / Instagram Story / 取消保留结果 | `CameraScreen.swift`、`SocialSharing.swift` |
| 6.1 Flash Party（三帧直闪） | `CameraScreen.swift:359` |
| 6.2 Flash Pair（环境光 + 直闪） | `CameraScreen.swift:361` |
| 6.3 Flash Sequence（环境 / 直闪 / 反应） | `CameraScreen.swift:363` |
| 6.2 双机对拼导出 | `PairedMemoryRenderer` |
| 7.1 Pocket Roll（24 张、备注、归档） | `MemoryFeatures.swift:99` |
| 7.2 联系表（方形 / 9:16） | `MemoryFeatures.swift:504` |
| 7.3 Camera Receipt | `MemoryFeatures.swift:627` |
| 7.4 Sensor Passport | `SensorPassportView` |
| 8.1 Dual Memory（MultiCam 同时前后置） | `DualMemoryController.swift:5` |
| 8.2 手势快门（Vision 手部关键点，连续 3 帧稳定） | `LivePreviewPipeline.swift:100+` |
| 8.3 每台装机传感器指纹（可关） | `CameraScreen.swift:21`、`LivePreviewPipeline.swift:31` |
| 8.4 双机配对拍摄 | `PairedCapture.swift` |
| 10 免费一台（A7）+ $9.99 买断 | `ProductInfrastructure.swift:18`、`:14` |
| 10 恢复购买、已购状态 | `CameraSettingsView`、`UpgradeView` |

---

## 2. 有差距（按影响排序）

### ~~2.1 延迟冲洗是死开关~~ —— 已修复
`delayedRollEnabled` 只有 `@AppStorage` 和往设置页的传参（`CameraScreen.swift:20`、`:200`），
没有任何地方消费它。文档 7.1 承诺“可选延迟冲洗模式”，现在用户拨了开关什么都不会发生。
**工作量：半天**（拍完不弹结果，进胶卷等“冲洗”动作）。

### ~~2.2 快门声缺失~~ —— 已修复
文档 5.2 要求每台机芯有自己的 shutter sound。全工程没有 `AudioServices` /
`SystemSound` 引用，只有触感与闪白。
**工作量：2 小时**（三个短音频 + 一个开关）。

### ~~2.3 闪光没有参与成像~~ —— 已修复
`flashMode` 只传给 `AVCapturePhotoSettings`（`CameraController.swift:172`），
`CCDLook.render` 里没有任何直闪衰减项。文档 5.3 明确要
“direct-flash subject/background falloff”，而这正是产品的核心卖点。
现在“开闪光”只影响真实闪光灯有没有亮，成像上没有任何“打闪”的痕迹。
**工作量：1–2 天**（近景过曝、背景压暗、皮肤高光滚降，需要真机取样调参）。

### ~~2.4 色差与边缘软化~~ —— 已修复
文档 5.3 列了 brightness-dependent chromatic aberration 和 corner softness，
渲染链里没有。现在画面四角是均匀锐利的，和老 CCD 的观感有差。
**工作量：半天**。

### ~~2.5 校准集只有 8 个~~ —— 已扩到 30
`CalibrationLab.swift:8` 定义了 8 个场景（D01/D02/F01/F02/N01/N02/S01/S02），
文档 11 的验收门槛是 30 场景集。
**工作量：内容工作为主**，代码只需补枚举与提示。

### ~~2.6 联系表元数据不足~~ —— 已修复
文档 7.2 要求相机、日期、闪光状态、序号；`MemoryFeatures.swift:542` 只画了
`POCKET ROLL n/24` 和每格序号，没有相机与日期。
**工作量：2 小时**。

### ~~2.7 卷容量只有 24~~ —— 已支持 12/24
文档 7.1 写“12 或 24”，实现固定 24（`MemoryFeatures.swift:99`）。
**工作量：2 小时**（设置里加一个 12/24）。

### 2.8 iCloud 自动备份没做 —— 已按“不做”修正文档
`PRODUCT_BACKLOG.md` 写“backups can sync automatically through the app's iCloud
Drive container”，实际只有 `exportBackup()` / `importBackup()` 的手动文件
（`MemoryFeatures.swift:249`、`:285`）。
要么实现 iCloud，要么把这句改掉。

---

## 3. 做了但与文档冲突

- 免费水印已按产品决定移除，与文档 7.3 一致；导出文件不带任何标记。

---

## 4. 工程与验证侧缺口

| 项 | 现状 |
| --- | --- |
| 真机验证 | 相机、结果页、联系表在模拟器上跑不了；需要 30 场景实拍 + 分组夜拍 |
| UI 测试 | 0 个；13 个单测只覆盖本地化与少量模型 |
| 无障碍 / 动态字体 | 大量固定 pt 字号，未适配 Dynamic Type |
| 购买测试配置 | 没有 `.storekit` 文件，本地无法端到端测购买 |
| 性能基线 | 没有真机帧率/内存记录，只有一次 memory kill 的事后修复 |

---

## 5. 建议批次

**第一批（1 天，补齐承诺）**：延迟冲洗真实现、快门声、卷 12/24、联系表元数据、
修正 backlog 的 iCloud 表述。

**第二批（2–3 天，补质感）**：闪光衰减建模、色差与边缘软化、校准集扩到 30、
真机取样调参。

**第三批（上架前）**：`.storekit` 配置、真机全路径回归、UI 冒烟测试、无障碍字号、
性能基线。

---

## 6. 粗略量化

| 维度 | 完成度 |
| --- | --- |
| 功能面（文档条目有没有） | ~85% |
| 深度（同一功能做得多真） | ~65%（闪光、色差、快门声是主要缺口） |
| 验证（真机与用户测试） | ~40% |
| 文档一致性 | ~70%（iCloud、水印、卷容量） |

真正卡上架的不是功能，是第三批的验证与商店配置。
