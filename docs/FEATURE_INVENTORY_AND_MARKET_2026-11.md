# PocketCCD — 功能盘点与未来市场判断

日期：2026-11-13  
范围：`PocketCCD/` 全部源码（15 个 Swift 文件，约 5,000 行）+ App Store 美区/中区当日数据 + 公开市场信号

---

## 一、功能盘点（以代码为准，不以 README 为准）

### 已实现且可演示

| 模块 | 内容 | 位置 |
|---|---|---|
| 取景与对焦 | 24fps 实时滤镜预览、点按对焦 + 对焦框、双指变焦 1–5×、EV ±2 | `LivePreviewPipeline.swift`、`CameraPreview.swift`、`CameraScreen.swift:673` |
| 三台相机 | POCKET A7（暖肤色）/ C1（冷调锐利）/ N2（绿影噪点），各有独立色调曲线、暗角、辉光、锐化、颗粒、条纹 | `CCDLook.swift:88-307` |
| 传感器指纹 | 每安装随机 seed，决定噪点相位与条纹宽度；`Sensor Passport` 展示固定图样 | `CaptureModels.swift:131`、`ExperienceViews.swift:297` |
| 色彩一致性 | 连拍时以首帧为色锚，后续帧按 0.14–0.8 强度稳定白平衡 | `CCDLook.swift:4-86`、`CameraScreen.swift:323-336` |
| 拍摄模式 ×5 | Standard / Flash Party（三连闪）/ Flash Pair（环境+闪光）/ Flash Sequence（环境+闪光+反应）/ Pocket Moment（2 秒视频 → 3 张抽帧） | `CaptureModels.swift:4`、`CameraScreen.swift:296-406` |
| 选帧与修复 | Vision 人脸质量 + 睁眼比例 + 清晰度打分，自动推荐最佳帧；识别脸暗/高光溢出/彩噪/模糊并给一键「轻度修复」 | `FrameAnalyzer.swift`、`CCDLook.swift:309` |
| 专业控制 | 手动 ISO / 快门 / 3000–8000K 白平衡、0.5×/1×/3× 物理镜头切换 | `CameraController.swift:243-354` |
| Pocket Roll | 24 张一卷、延迟冲洗、卷归档、方形/Story 接触印样、当日汇总视频、本地备份导出/恢复、卷备注 | `MemoryFeatures.swift`、`ExperienceViews.swift:4` |
| 双机配对 | MultipeerConnectivity + Bonjour `_pocketccd-shot._tcp`，两台 iPhone 同拍并生成双联图 | `PairedCapture.swift`、`MemoryFeatures.swift:616` |
| 双视角记忆 | 前后摄同时（多摄设备）或引导式先后拍，输出「场景 + 反应」 | `DualMemoryController.swift`、`CameraScreen.swift:241` |
| 手势快门 | Vision 手部姿态，连续 3 帧识别张开手掌触发（仅 3s/10s 定时） | `LivePreviewPipeline.swift:63-87` |
| 实体快门 | `AVCaptureEventInteraction`（音量键 / Camera Control） | `HardwareShutterView.swift` |
| 分享 | 系统分享面板、Instagram Stories 直发、相机回执卡、连拍样张、配对双联图、2 秒视频与 Live Photo 保存 | `SocialSharing.swift`、`CameraScreen.swift:1324-1416` |
| 导入 | PhotosPicker 导入后套用当前相机 | `CameraScreen.swift:422` |
| 本地化 | 英文本 + 简繁中文，187 条字符串 | `Localizable.xcstrings` |
| 工程 | iOS 17.0+，iPhone only，竖屏，bundle `work.doublenine.pocketccd`，签名团队已配 | `project.pbxproj`、`Info.plist` |

### 缺失或半成品（上架前必须处理）

1. **没有任何变现代码**：全仓无 StoreKit/IAP/订阅/付费墙。当前是一个彻底免费的 App。
2. **没有隐私清单** `PrivacyInfo.xcprivacy`（iOS 17+ 上架必需，尤其用到 UserDefaults 与照片写入）。
3. **iCloud 权限声明无对应代码**：`PocketCCD.entitlements` 声明了 CloudDocuments/ubiquity，但全仓无 iCloud 调用 —— 审核会问用途，建议删除。
4. **开发者工具出现在消费者界面**：Imaging Benchmark 实验室（30 场景校准、CSV 导出）、Experimental features、Sensor Passport 都挂在设置里。
5. **无引导 / 无评分请求 / 无任何分析埋点**：激活、留存、转化数据将完全拿不到。
6. **两张图不一致的风险**：预览端把暗角/辉光/锐化/噪点乘了 0.65–0.8 的折扣（`CCDLook.swift:156-186`），成片用满值 → 违反 spec 第 3 条「预览与成片一致」。
7. **Instagram 直发缺 App ID**：`PocketCCDInstagramAppID` 为空串，Stories 分享可能被静默拒绝。（2026-11-18 已填 `1881548479664873`，交接逻辑见 `SocialSharing.swift`）
8. **无测试**：0 个单元/UI 测试文件。
9. **构建未能在本会话验证**：xcodebuild 在沙箱内启动 Swift 宏插件服务失败（`swift-plugin-server produced malformed response`），属于环境限制而非代码错误；需在普通终端或授予完整权限后复验。

### 结论：功能面已经「超配」

spec 里的 MVP + V1 + V1.5 大部分实现，甚至包含 spec 标为「实验性」的双机配对、手势快门、双视角记忆。问题不是功能少了，而是**没有一个用户能一眼看懂的价值主张**、没有收费、没有上线。

---

## 二、未来市场：需求侧在涨，供给侧在挤，平台在侵蚀

### 需求侧（真需求，且在涨）

- CIPA：2026 年 4 月口径下，紧凑型相机发往美洲的出货量同比 **+34%**，全球相机出货连续两年增长（近 20 年首次）。
- 中国电商（2025-09–2026-08）：卡片机线上销售额 **¥87.8 亿，同比 +58%**，均价 ¥1,124 → ¥1,626。
- 线下同样热：贵阳复古数码相机店成为年轻人的打卡点，「复古经济」被主流媒体报道。
- 结论：**「像 2003 年数码相机那样拍照」这件事本身，2026 年仍是上升趋势**，不是将死的潮玩。

### 供给侧（克隆潮 + 巨头）

美区（2026-11-13 快照）：Dazz 117,877 / Lapse 118,322 / NOMO 48,160 / 1998 Cam 40,441 / radcam 39,491 评分；新进入者仍在破圈——y2k（2025-10 上架）13,173、WayShot（2025-08）5,009 且当日摄影免费榜第 11、101cam（2026-07）569。同时过去 90 天新上架、评分 0–14 的同质 App 至少 8 个。

中区（同日快照）更硬：Dazz 1,183,331 / NOMO 1,338,248 / CCD相机 104,604 / Kapi相机 90,902 / ProCCD 69,901 / OldRoll 60,970 / Remo 59,731 / LoFi 38,498 / Fomz 36,234 / Noka（2025-08 上架）29,354。**中区前十的门槛是 2–3 万评分**，新品没有大推流无法进榜。

### 平台侧（最大的结构性风险）

iOS 27 的原生「摄影风格 3」在 iPhone 18 Pro / iPhone Duo 上直接提供**柔肤 / 光晕 / 底片质感 + 可调胶片颗粒**。也就是说，「胶片颗粒 + 高光辉光」这一层将于 2026 年起被系统相机免费吃掉。App 能留下的差异只剩三样：

1. **行为**：直闪的脸部过曝与背景衰减、暗部色噪与条纹随亮度变化（不是滤镜能事后补的）；
2. **仪式**：卷、冲洗、接触印样、回执；
3. **关系**：双机配对、活动共享相册、成对记忆。

### 趋势轮换（时间风险）

2026 年下半年已出现「digicam 之后是 Cyber Y2K / 老式网络摄像头画质」的叙事迁移（印尼社媒报道）。**外观潮流 12–18 个月换一轮，而仪式与关系不随潮流换**。把宝押在「我的颗粒更好看」上，2027 年会打折；押在「朋友聚会时你会打开它」上，才跟着需求走。

---

## 三、12–24 个月判断

| 层级 | 2026 现状 | 12–24 个月判断 | 可防守性 |
|---|---|---|---|
| 外观/滤镜 | 免费克隆满地，系统已内置颗粒与光晕 | 归零，成为 table stakes | 无 |
| 行为（直闪、噪点、条纹） | 少数团队做，PocketCCD 已有 | 6–12 个月内被 2–3 家追上 | 中（工程难、可验证） |
| 仪式（卷/冲洗/印样） | NOMO、mood、L8R 已有 | 一年内普及，不再是卖点 | 低 |
| 关系（双机/活动相册） | 只有活动相机品类在做（POV 15.6k、Lapse 118k、Dispo 8.3k） | **唯一有网络效应的层**，也是唯一能支撑订阅/单次活动收费的层 | 高，但冷启动最难 |

**收入预判**（沿用 `scripts/lifetime_screen.py` 的安装驱动模型，$9.99 买断，净 $8.49/付款人）：基准 5 万安装 × 1.2% ≈ **$5,100 / 12 个月**；乐观 20 万安装 × 1.8% ≈ **$30,600**。做成「活动/聚会相机 + 每人一卷」的话，单次活动可变现 $3–10（主办方付费），这是唯一能把 ARPU 抬一个量级的方向，但需要先有真实聚会场景的使用证据。

---

## 四、接下来 4 周的动作（按顺序，不跳步）

1. **冻结功能**。把 Imaging Benchmark、Experimental features、Sensor Passport、手势快门、双机配对移入 `#if DEBUG` 或 TestFlight 开关。理由：这些是研发工具与未验证的差异点，会把「三秒能讲清的产品」变成说明书。
2. **补齐上架三件套**：StoreKit 2 买断（$9.99，1 台相机免费）+ `PrivacyInfo.xcprivacy` + 删除未使用的 iCloud entitlements。
3. **修预览/成片一致性**：预览端改用与成片同一组参数（或引入明确的「预览降耗系数」并在 spec 里承认差异）。
4. **只发英文区**（美/英/加/澳/日），中区作为第二阶段，靠小红书内容而非 ASO 进入——中区前十门槛 2–3 万评分，纯自然量进不去。
5. **内容验证仍是前置条件**：9 张直闪人像分 3 组发 1 条 TikTok + 1 条小红书，单条自然曝光 ≥ 3 万再投入后续。当前功能已经足够支撑这一测。
6. **30 天停损线**：自然安装 < 1,000 或解锁转化 < 0.5% → 停止迭代，仅维护。

---

## 五、一句话

功能已经做到「超出市场需要」的程度，缺的是收费、上架和一句话说清的价值；市场在未来 12–24 个月仍会涨，但钱会从「外观」层流向「关系」层——PocketCCD 手上恰好有双机配对这条别人没做通的线，却还没有一个能跑通的单一入口。
