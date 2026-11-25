# Pocket CCD 推广方案（90 天）

日期：2026-11-13  
前提：产品按 `docs/DECISION_LIFETIME_SCREEN.md` 收窄为 $9.99 买断 + 3 台相机 + 保存/分享，英文区先发。

---

## 0. 先决条件：没有这三样，推广就是白送流量

| 必须有 | 为什么 | 对应动作 |
|---|---|---|
| 内购（StoreKit 2 买断） | 装 1,000 人却收不到钱，等于把广告费捐给 Apple 的服务器 | 免费 1 台相机 + $9.99 解锁其余 |
| 归因 | 不知道哪条内容带来安装，就只能凭感觉加码 | 每个创作者一个 Custom Product Page（70 个额度），ASC 里看该页下载 |
| 留痕 | 现在零埋点，D1/D7、保存率、解锁率全看不到 | 轻量方案（TelemetryDeck 或 ASC 自带 App Analytics + 自建保存成功率日志） |

---

## 1. 一句话定位

- **EN**：*The 2003 digicam that flashes your friends.*
- **CN**：*一台 2003 年的数码相机，闪光灯直打朋友。*

为什么必须是这句：系统相机（iOS 27 摄影风格 3）已经免费给了颗粒、光晕、底片质感；**它给不了的是「真开闪光灯」造成的脸部过曝 + 背景掉黑**。所有素材都要围绕「闪光灯直打」这一个动作，不要讲滤镜数量。

---

## 2. 经济账：为什么只做自然流量

| 项 | 数值 |
|---|---|
| 净单价（$9.99 抽 15%） | $8.49 / 付款人 |
| 安装→付费 | 1.2%（保守） |
| **每安装 LTV** | **≈ $0.10** |
| 美区 CPI | $1.5–3.0 |
| 结论 | 付费买量亏 15–30 倍，**90 天内不买量** |

预算上限：**90 天现金支出 < $300**（全部用于拍素材和寄实物，不用于买量）。唯一例外：Apple Search Ads 投 $50 做「转化率探针」，只看数据不扩量。

---

## 3. 渠道组合与目标

| 渠道 | 角色 | 90 天目标 | 成本 |
|---|---|---|---|
| TikTok + IG Reels + YouTube Shorts（同一素材三发） | 主引擎 | 1 条 ≥10 万播放，3 条 ≥2 万 | $0 |
| App Store ASO | 承接搜索需求 | `flash camera`、`g7x`、`digital camera 2000s` 进前 10 | $0 |
| 创作者寄送（30 个 5k–50k 粉的小号） | 借场景和信任 | 10 个履约，产出 15 条内容 | 兑换码 $0 + 寄样 $100 |
| Apple 推荐（ASC > Featuring Nomination） | 一次性大曝光 | 提交 4 次，期望命中 1 次 | $0 |
| 小红书（中文第二阶段） | 中文圈冷启动 | 20 条笔记，3 条 ≥1 万赞藏 | $0 |
| Reddit / Product Hunt / 独立开发者社区 | 长尾与背书 | 各 1 次，合计 ≥2,000 安装 | $0 |
| 媒体 pitch（9to5Mac / iMore / The Verge） | 彩票 | 发 15 封，命中 1 篇 | $0 |

**预期区间（90 天）**：3,000–15,000 安装，对应收入 $250（保守）到 $1,700（乐观）；若有 1 条破 50 万播放，20,000–60,000 安装。

---

## 4. ASO：具体到可提交的字

| 字段 | 内容 | 长度 |
|---|---|---|
| App 名称 | `Pocket CCD — Digicam Camera` | 26/30 |
| 副标题 | `Direct flash · 2000s look` | 25/30 |
| 关键词（79 B） | `ccd,film,grain,pocket,retro,party,y2k,disposable,compact,vintage,photos,receipt` | 79/100 |
| 备选加词 | `,g7x`（+4 B）—— Canon G7X 是当下最热的卡片机，搜索结果里最强只有 202 条评分；但它是 Canon 商标，先小范围试，收到投诉就撤 | |
| 中文名称 | `Pocket CCD：CCD 闪拍相机` | |
| 中文副标题 | `直闪人像 · 2003 数码质感` | |

搜索结果竞争度（美区，2026-11-13）：`flash camera` top3 中位 202 条评分（**最弱**）、`digital camera 2000s` 2,292、`ccd camera` 2,292、`g7x` 202、`digicam` 5,608、`disposable camera` 11,997、`point and shoot camera` 13,698。**先打前三个词，放弃 `vintage camera` / `film camera`（中位 4 万，红海）。**

首图三张（按顺序，每张 2–5 词）：

1. 直闪人像 → *Flash like 2003*
2. 三台相机对比 → *Three real cameras*
3. 胶卷 + 接触印样 → *Rolls & contact sheets*

其余：Promotional Text 随周末轮换（170 字，不需重新提审）；Custom Product Page 每个创作者一个（70 个额度，URL 带创建者名）；In-App Event 用 `Special Event` 徽章做「Flash Party Weekend」，与下一个活动首尾相接保持搜索可见；PPO 先 A/B 首图（人像 vs 相机机身），跑满 7 天、置信度 ≥90% 再定。

---

## 5. 内容配方：10 条可以直接拍的

统一规格：竖屏 9:16、7–15 秒、前 1 秒必须出现闪光或人脸、无口播、BGM 用 2000s 金曲。

| # | 选题 | 钩子（首帧字幕） |
|---|---|---|
| 1 | POV：2003 年的周五聚会 | `POV: it's 2003 and the flash is on` |
| 2 | 同一张脸，iPhone 相机 vs Pocket CCD 分屏 | `Same face. Different decade.` |
| 3 | 盲猜哪张是三千块的 CCD | `One of these is a $900 camera` |
| 4 | 关灯 → 开闪 → 倒数 3 秒 | `Turn the lights off. Wait for the flash.` |
| 5 | 给爸妈拍一张 2003 年的照片 | `I photographed my parents like it's 2003` |
| 6 | 相机回执卡（receipt）开箱 | `Your camera gives you a receipt` |
| 7 | 「我的相机没有屏幕」 | `This camera has no screen` |
| 8 | 一卷 24 张，拍完才能看 | `24 shots. You can't see them until the end.` |
| 9 | 日期戳的正确用法 | `The date stamp is the whole point` |
| 10 | 双机配对：两台手机同时按下快门 | `Two phones. One flash.` |

发布节奏：每周 3 条，同一素材发 TikTok / Reels / Shorts，标题按平台改（TikTok 口语、Reels 短句、Shorts 搜索词）。每条只测一个变量：钩子、时长、BGM、字幕位置。

---

## 6. 创作者寄送（不付钱，付兑换码 + 曝光）

目标画像：5k–50k 粉的夜生活/穿搭/胶片/学生生活账号，最近 30 天有 1 条 ≥5 万播放。

私信模板（EN，60 词内）：

> Hey — I built Pocket CCD, a camera app that makes flash photos look like a 2003 digicam. It's not a filter: it actually fires the phone flash. Want a free lifetime code to shoot with this weekend? If you post anything you like, I'll feature it on our page and send you a print.

中文版：

> 你好，我做了个相机 App：拍出来像 2003 年的数码相机，闪光灯是真的会闪。送你一个永久兑换码，这周末随便拍拍？喜欢的话我这边转发，并寄一张冲印给你。

履约清单：兑换码（StoreKit Offer Code，需先有内购）→ 专属 CPP 链接 → 48 小时内回评 → 收图进「Roll of the week」。

---

## 7. 90 天日历

| 周 | 动作 |
|---|---|
| W-2 | 建 3 个账号；发 9 张直闪样张测钩子（门槛：单条 ≥3 万曝光才继续）；备好 30 张成片与 3 条竖屏素材 |
| W-1 | 提交审核；TestFlight 外测 50 人；搭好 10 个 CPP；准备 Featuring Nomination 文案 |
| W1 | 上线；发 3 条内容；提 Apple 推荐；Product Hunt；给 30 个创作者发私信 |
| W2–W4 | 每周 3 条内容 + 2 个创作者到位；第一轮 PPO（首图）；收到首批评论后 24 小时内回复 |
| W5–W8 | 复制数据最好的那条的结构；上线第一个 In-App Event；ASO 关键词第一轮迭代（看排名变化） |
| W9–W12 | 复盘：渠道 ROI 表；决定第二轮或停 |

**停损门（任一触发即停止投入、进入维护）**：

- 30 天自然安装 < 1,000
- 解锁转化 < 0.5%
- 保存率（保存/拍摄）< 30%
- D7 < 15%
- 12 周内没有任何一条内容破 2 万播放

前三项是产品问题，不是推广问题——先修产品，别加预算。

---

## 8. 每周只看 6 个数

下载量 / 各 CPP 渠道下载 / 目标关键词排名（`flash camera`、`g7x`、`digital camera 2000s`）/ 保存率 / 解锁转化 / 单条内容播放与主页点击。

其他都不看。尤其不看点赞数。

---

## 9. 不要做的事

- 买量（LTV $0.10 vs CPI $1.5+）
- 刷评、买榜（封号，且这个品类评论区很敏感）
- 群发 DM（TikTok 会限流，30 个精准 > 3,000 个群发）
- 在 Reddit 硬发广告链接（r/iphoneography 等会直接删帖封人；要用「我做了个东西，听听意见」的姿态）
- 上线第一周就改定价（至少 4 周数据再动）
