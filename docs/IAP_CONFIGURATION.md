# PocketCCD 内购配置（当前状态：一次性买断，无订阅）

更新：2026-11-15

## 一句话

PocketCCD 现在**没有订阅**。唯一的付费项是「PocketCCD 完整版」——非消耗型一次性购买，
解锁 C1 与 N2 两台相机；A7 与 A8 永久免费。定价按项目决策为 **$9.99**（首发）。

## 产品定义

| 项目 | 值 |
| --- | --- |
| Product ID | `work.doublenine.pocketccd.full` |
| 类型 | Non-Consumable（非消耗型，一次买断） |
| Reference Name（ASC 内部名） | PocketCCD Full |
| Display Name | PocketCCD 完整版 / PocketCCD Full |
| 价格 | $9.99（建议首发；可测 $9.99–$14.99） |
| 家庭共享 | 建议开启（非消耗型支持） |
| 订阅 | 无 |

代码里唯一的硬编码位置：`ProductInfrastructure.swift` 的 `enum PocketProduct`。

## 权益与门禁

| 相机 | 未购买 | 已购买 |
| --- | --- | --- |
| A7（amber，暖调家庭） | 可用 | 可用 |
| A8（party，硬闪派对） | 可用 | 可用 |
| C1（chrome） | 锁定，点按弹出付费页 | 可用 |
| N2（night） | 锁定，点按弹出付费页 | 可用 |

- 门禁函数：`ProductAccess.canUse(_:isFullUnlocked:)`
- 权益来源：`Transaction.currentEntitlements`，只认 `productID == full` 且未退款（`revocationDate == nil`）
- 恢复购买：`PurchaseStore.restorePurchases()` → `AppStore.sync()`

## 付费页文案（当前实际使用）

| 位置 | 英文 | 中文 |
| --- | --- | --- |
| 标题 | PocketCCD Full | PocketCCD 完整版 |
| 副标题 | A7 and A8 stay free forever. Add C1 and N2 with one purchase. | A7 与 A8 永久免费。一次购买解锁 C1 与 N2。 |
| 权益 1 | Two more camera personalities | 另外两种相机个性 |
| 权益 2 | C1 and N2, including future refinements | C1 与 N2，包含后续优化 |
| 权益 3 | One purchase, no subscription | 一次购买，不含订阅 |
| 主按钮 | UNLOCK FOREVER · <价格> | 永久解锁 · <价格> |
| 次按钮 | RESTORE PURCHASES | 恢复购买 |
| 未配置时 | CHECK AVAILABILITY | 检查购买状态 |
| 脚注 | Payment is charged to your Apple Account. This non-consumable purchase does not expire. | 费用由你的 Apple 账户支付，此非消耗型购买不会过期。 |

## 为什么真机上显示 CHECK AVAILABILITY

`Product.products(for:)` 返回空，说明这个 Product ID 在 App Store Connect 还不存在、
或没有和当前构建关联、或沙盒账号不可用。代码会退化成「CHECK AVAILABILITY」按钮，
不会崩、也不会误扣费。

## 上线步骤（App Store Connect）

1. App Store Connect → 你的 App → 「App 内购买项目」→ 新建。
2. 类型选 **非消耗型（Non-Consumable）**。
3. Reference Name 填 `PocketCCD Full`，Product ID 填 `work.doublenine.pocketccd.full`
   （Product ID 创建后不可改，必须一字不差）。
4. 价格选 $9.99，启用 Family Sharing。
5. 添加本地化：
   - 英文：显示名 `PocketCCD Full`，描述 `Unlock C1 and N2 camera personalities forever. One purchase, no subscription.`
   - 简体中文：显示名 `PocketCCD 完整版`，描述 `永久解锁 C1 与 N2 两台相机。一次购买，不含订阅。`
6. 上传一张「审核截图」（付费页截图即可）。
7. 在 App 版本页面把该内购**关联到本次构建**，否则审核时找不到。
8. 用沙盒账号（Settings → App Store → 沙盒账户）在真机跑一次购买 + 恢复购买。

`PocketCCD Full` 只承诺永久解锁首发的 C1、N2 及这两台相机的后续优化，
不承诺自动包含未来独立推出的相机、视频套装或联名内容。

## 如果要改成订阅

现在代码只支持一次性购买。改订阅需要：

1. ASC 里新建 Auto-Renewable Subscription（组 + 周期 + 介绍优惠）。
2. `PocketProduct` 换成年订阅 product id，`Transaction.currentEntitlements` 判断逻辑不变。
3. 付费页补充：订阅周期、价格单位、自动续订说明、取消入口、隐私政策与使用条款链接
   （审核硬性要求）。
4. 权益判断要处理过期与宽限期（`expirationDate`、`isInGracePeriod`）。
5. 定价参考：竞品 NOMO 年订阅约 $24.99，Kapi 月 $9.99 / 年 $69.99 / 终身 $149；
   本项目 `docs/COMPETITOR_MATRIX.md` 的结论是**首发不做订阅**，用 $9.99 终身买断。

## 待补

- 已处理：`UNLOCK FOREVER · %@`、`RESTORE PURCHASES`、`CHECK AVAILABILITY`、`CHECKING…` 已进 String Catalog，
  支持 en / zh-Hans / zh-Hant。价格由 StoreKit 的 `displayPrice` 提供，不写死。
