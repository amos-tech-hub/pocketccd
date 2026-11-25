# 命名决策：PocketCCD 能不能用（最终沿用 PocketCCD）

日期：2026-11-13  
数据：iTunes Search API（US 店，当日）、公开商标记录  
状态：**2026-11-14 决定继续使用 PocketCCD；Nightroll 改名已回滚（代码、bundle id、内购 ID、Bonjour 服务名与商店元数据均已改回）。**  
本文件保留 B 方案的论证作为备查：若日后要换可注册的品牌，按第 5 节重做一遍占名检查即可。

---

> **2026-11-18 更新**：显示名改为 `Pocket CCD`（加空格）。理由：App Store 搜索会把 camelCase 自动拆词（`pocketcasts` 与 `pocket casts` 返回同一列表，`pccd` 首屏是 ProCCD），所以连写并不带来索引优势；加空格只改善可读性与口头拼写，`CFBundleDisplayName`、商店名、内购显示名、App 内文案一并改，bundle id / 产品 id / 文件名保持不变。


## 结论

**可用，但弱。建议现在就改 —— 这是改名成本最低的时刻（未上架）。**

若 4 周内必须上线且不想为品牌分心，退而求其次用 `Pocket CCD`（加空格），保留 CCD 的搜索索引。

---

## 三个硬问题

### 1. 撞名与混淆（不是致命，但会分流）

US 店搜 "pocket ccd" 的实际结果里已经有：

- `Pocket Digicam: Y2K CCD Cam`（0 评分）
- `CCD — Y2K Digicam Camera`（1 评分）
- `CCD Diary: Vintage Camera`
- `Haze Cam` 的商店描述里直接写了 "turns your Phone into a pocket CCD camera"

没有完全同名的 App（`PocketCCD` 目前未被占用），但「Pocket + CCD」这个组合已经不是空的，用户搜这两个词会同时看到别人。

### 2. 描述性太强 → 商标不可防御

`pocket`（通用词）+ `CCD`（通用技术名词）= 纯描述性组合。这类名字在美国很难直接注册，通常要证明「第二含义」（长期使用、消费者认知）。更现实的问题：**中国已有人就「CCD」在第 9 类（0908 数码摄像机 / 0909 数码相机）提出商标申请**（待审），说明品类里有人正在圈这个词 —— 你用了也无法独占，将来要么改名，要么花钱买授权。

### 3. 输入与口头传播成本

`PocketCCD` 一个词、两个连续大写。用户会打成 `Pocket CCD` / `Pocketccd` / `Pocket CD`；口头推荐时只能说「Pocket C-C-D」，听起来像型号不像品牌。

---

## 一个优点：别浪费

名字里含 `CCD` 确实让 App Store 索引到这个词，这是真实收益。**但这个收益可以搬到副标题和关键词字段**，不需要让品牌位承担。品牌位应该留给「能被记住、能被拼对、能注册」的词。

---

## 三个方案（元数据已按 30/30/100 字符校验）

| 方案 | 名称（≤30） | 副标题（≤30） | 关键词（≤100 B） | 适合 |
|---|---|---|---|---|
| A 零改动 | `Pocket CCD — Digicam Camera`（27） | `Direct flash · 2000s look`（25） | `film,grain,retro,party,night,y2k,disposable,compact,point,shoot,vintage,photos`（78） | 只想赶紧上线 |
| **B 换可拥有品牌（已采纳）** | `Nightroll — Digicam Camera`（26） | `Direct flash · 2000s look`（25） | `ccd,film,grain,pocket,retro,party,y2k,disposable,compact,vintage,photos,receipt`（79） | **推荐** |
| C 换摄影圈品牌 | `Hotshoe — CCD Camera`（20） | `Direct flash · 2000s digicam`（28） | `roll,film,grain,pocket,retro,party,night,y2k,disposable,compact,vintage,photos`（78） | 想走「懂行」路线 |

**为什么推荐 B（Nightroll）**

- 两个音节，听一次能拼对（night + roll），口头传播成本最低；
- 语义正好是产品核心：夜晚 + 一卷 24 张的仪式；
- 属任意组合词，显著性够，可注册、可防御；
- 搜索风险小：US 店目前没有同名 App（搜 "nightroll" 只出睡眠类，不构成品牌冲突）；
- 中文可对应「夜卷」，后续进中区不用二次改名。

**C（Hotshoe）的问题**：热靴是闪光灯接口，摄影圈一眼懂，但目标用户（20 岁上下、聚会开闪的那群人）不认识这个词，品牌记忆点会输给 B。

**A（Pocket CCD）的问题**：能过审、能上线，但一年后想做订阅、做活动相机、做联名时，你会发现这个名字注册不了、也讲不出故事。

---

## 今天就能做的占名检查（30 分钟）

1. **App Store Connect 建占位记录**：未上架的 App 记录也会锁住名称（名称按本地化唯一），这是唯一权威的可用性测试。先试 `Nightroll`，被占则试 `Hotshoe`，最后退回 `Pocket CCD`。
2. **商标检索**：USPTO TESS（查 nightroll / hotshoe，第 9 类与第 42 类）、CNIPA（中国，第 9 类 0908/0909）、EUIPO。只查你要用的那个字，别查组合。
3. **一次拿全同名资产**：域名（`nightroll.app` 优先，其次 `.co`/`.cam`）、TikTok、Instagram、小红书号。域名先查再定，别先改代码。
4. **合规检查**：≤30 字符；名称里不能有价格、不能蹭他人商标或热门 App 名（Guideline 2.3.7）。

## 改名成本提醒

上架后改名需要新版本送审，且搜索排名会重置。现在是唯一「改名字不要钱」的窗口 —— 一旦 App 记录建好、截图和 CPP 做完、创作者链接发出去，再改就要重做一轮素材。

## 相机命名（2026-11-18 实施）

App 名保持 `PocketCCD` 不动，先解决更亏的一层：三/四台相机叫 `A7 / A8 / C1 / N2`，用户在货架上无法建立性格认知，而 Gloam 用 `T3 / GRD / U2 / CCD12` 这些真实机型名直接借走了可信度。

做法：**内部型号不动，只加两词外显名。**

| 内部（持久化、元数据、小票） | 外显名（相机条、付费墙、Camera Guide） |
|---|---|
| `POCKET A7` | Warm 2003 / 暖调 2003 |
| `POCKET A8` | Party Flash / 派对闪光 |
| `POCKET C1` | Cold Sharp / 冷调锐利 |
| `POCKET N2` | Green Grain / 绿影颗粒 |

- 落点：相机条第二行、付费墙相机卡、Camera Guide 详情行；VoiceOver 用 `accessibilityValue` 读名字、`accessibilityHint` 读原来的功能短句。
- 约束：两词、≤12 字符（相机条单卡宽度），有 `CameraCopyTests.personalitiesAreShortAndDistinct` 守住。
- 持久化格式不变：`cameraRawValue` 继续写 `POCKET A7`，改名字不会让旧胶卷读不出来。

## 对现有文档的影响

`docs/GO_TO_MARKET.md` 里的 ASO 段落以本文件为准；若采用方案 B/C，记得同步改：Info.plist 的 `CFBundleDisplayName`、`PocketCCDInstagramAppID`、本地化字符串里的 "POCKET CCD" 水印文案（`ViewfinderStatus`），以及 App 内三台虚构相机的命名（建议保留 `POCKET A7 / C1 / N2`，它们现在是产品线型号，不再充当品牌）。
