# X 发帖：招募首批用户（送终身解锁码）

链接：https://apps.apple.com/us/app/pocket-ccd-digicam-camera/id6834433326

---

## 1. 主推（240/280）

```
Pocket CCD is live on the App Store.

I'm looking for the first 50 people who actually shoot with it.

Download it, take a direct-flash photo, reply with it — I'll send a code that unlocks all four cameras, forever.

https://apps.apple.com/us/app/pocket-ccd-digicam-camera/id6834433326
```

## 2. 备选 B —— 更短，强调「现在就能拍」（208/280）

```
Pocket CCD is live.

First 50 people who download it, shoot a flash photo and reply with it get all four cameras unlocked — forever, free.

Two are already free, so you can start now.

https://apps.apple.com/us/app/pocket-ccd-digicam-camera/id6834433326
```

## 3. 备选 C —— 创始人框架，语气最克制（230/280）

```
Day one on the App Store.

I'm not looking for downloads, I'm looking for founding users: the first 50 people who shoot a real photo with it.

Reply with one and I'll send a lifetime code for every camera.

https://apps.apple.com/us/app/pocket-ccd-digicam-camera/id6834433326
```

## 4. 备选 D —— 极简（172/280）

```
Pocket CCD is live. Two cameras free, no subscription.

First 50 replies with a flash photo shot in the app get all four cameras unlocked, forever.

https://apps.apple.com/us/app/pocket-ccd-digicam-camera/id6834433326
```

---

## 5. 发完自己回一条（把规则说死）

```
How it works:

1. Download Pocket CCD (free) — A7 and A8 are already unlocked
2. Shoot one direct-flash photo
3. Reply here with it

I'll DM a one-time code. It unlocks C1 + N2 permanently, on the Apple ID you redeem it with. 50 codes, first come.
```

这条要放在自己帖子的第一条回复里，**不要**放在主帖里——主帖越短，转发率越高。

## 6. DM 模板

```
Here's your code: XXXX-XXXX-XXXX-XXXX

Redeem: App Store → your avatar → Redeem Gift Card or Code → enter it.
It unlocks C1 and N2 forever on this Apple ID. Open Pocket CCD afterwards —
the cameras appear without reinstalling.

If it doesn't stick, tell me and I'll send another.

(If you post the photo anywhere, tag @pocketccd — I'll repost the good ones.)
```

---

## 7. 在 App Store Connect 里怎么发这些码

苹果在 2026-03-26 停掉了 IAP 的 **promo code**，现在唯一通道是 **Offer Code**，而且它覆盖非消耗型内购——你的 `work.doublenine.pocketccd.full` 可以用。

1. ASC → **Monetization → In-App Purchases → Pocket CCD Full → Offer Codes**
2. 新建 offer：类型选 **Free**（100% off），适用地区选你上架的地区
3. 生成 **one-time use codes**：批量最小 **500**，最大 25,000 → 你只要 50 个，也得生成 500；剩下的留着做下一轮活动
4. 有效期：最长 **6 个月**，建议设满（半年内都还能发）
5. 下载 CSV，按顺序发给前 50 个回复的人，并在表里记：X 用户名 / 码 / 发放日期 / 是否兑换

限制（记在这，免得回头踩）：

| 项 | 值 |
|---|---|
| 每季度每 App 码上限 | 1,000,000（含所有内购） |
| 同时进行的 offer 数 | 最多 10 个 |
| 每人每个 offer 可兑换 | 1 次 |
| 码有效期 | ≤ 6 个月 |

**技术侧已经通了**：App 监听 `Transaction.updates`，用户在 App Store 里兑换后回到 App 会直接解锁，不用重装、不用重启。这条路径我在代码里确认过（`ProductStore.handle(transaction)` → `refreshEntitlements()`）。

---

## 8. 三条合规/运营红线

1. **不要用评价换码。** 「给 5 星就送你码」违反 App Review 3.2.2 的激励评价条款，被查到会影响上架。用「发张照片」换码是安全的——那是内容征集，不是评价交易。
2. **码不要公开发。** 一条推文里贴码等于立刻被爬走，必须在 DM 里一对一发。
3. **别写「限量 50 个，先到先得」却拖到第三天。** 回复要及时，前 24 小时是这件事能不能滚起来的关键。

---

## 9. 怎么判断这轮有没有用

| 指标 | 目标 | 看哪 |
|---|---|---|
| 回复数（带照片） | ≥ 30 | 自己数 |
| 码兑换率 | ≥ 60% | ASC → 内购 → Offer Codes 兑换数 |
| 回复里出现的场景词 | 记下来 | 后面写文案/选关键词用 |
| 二次传播 | ≥ 3 人转发自己的照片 | 通知里看 |

**最有价值的信息不是码发了多少，而是照片里他们在拍什么**——是宿舍、酒吧、还是街边摊。那决定第二支视频拍什么。
