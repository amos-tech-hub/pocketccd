# PocketCCD In-App Purchase Setup (one-time unlock, no subscription)

Updated: 2026-11-15

## Summary

PocketCCD has **no subscription**. The only paid item is “PocketCCD Full”, a
non-consumable one-time purchase that unlocks the C1 and N2 cameras. A7 stays
free forever. Launch price: **$9.99**.

## Product definition

| Field | Value |
| --- | --- |
| Product ID | `work.doublenine.pocketccd.full` |
| Type | Non-Consumable |
| Reference name | PocketCCD Full |
| Display name | PocketCCD Full / PocketCCD 完整版 |
| Price | $9.99 at launch (test range $9.99–$14.99) |
| Family Sharing | Recommended (supported for non-consumables) |
| Subscription | None |

The identifier lives in one place: `enum PocketProduct` in
`ProductInfrastructure.swift`.

## Entitlement and gating

| Camera | Locked state | Unlocked state |
| --- | --- | --- |
| A7 (amber) | Available | Available |
| C1 (chrome) | Locked; tapping opens the paywall | Available |
| N2 (night) | Locked; tapping opens the paywall | Available |

- Gate: `ProductAccess.canUse(_:isFullUnlocked:)`.
- Entitlement source: `Transaction.currentEntitlements`, matched on
  `productID == full` and `revocationDate == nil`.
- Restore: `PurchaseStore.restorePurchases()` calls `AppStore.sync()`.

## Paywall copy (as shipped)

| Slot | English | Simplified Chinese |
| --- | --- | --- |
| Title | PocketCCD Full | PocketCCD 完整版 |
| Subtitle | A7 and A8 stay free forever. Add C1 and N2 with one purchase. | A7 与 A8 永久免费。一次购买解锁 C1 与 N2。 |
| Benefit 1 | Two more camera personalities | 另外两种相机个性 |
| Benefit 2 | C1 and N2, including future refinements | C1 与 N2，包含后续优化 |
| Benefit 3 | One purchase, no subscription | 一次购买，不含订阅 |
| Primary button | UNLOCK FOREVER · <price> | 永久解锁 · <价格> |
| Secondary button | RESTORE PURCHASES | 恢复购买 |
| Missing product | CHECK AVAILABILITY | 检查购买状态 |
| Footnote | Payment is charged to your Apple Account. This non-consumable purchase does not expire. | 费用由你的 Apple 账户支付，此非消耗型购买不会过期。 |

## Why the device shows CHECK AVAILABILITY

`Product.products(for:)` returns an empty array, which means the product does not
exist in App Store Connect yet, is not attached to the current build, or the
sandbox account is unavailable. The paywall degrades gracefully; nothing crashes
and nothing is charged.

## Launch checklist (App Store Connect)

1. App Store Connect → your app → In-App Purchases → create.
2. Choose **Non-Consumable**.
3. Reference name `PocketCCD Full`; Product ID
   `work.doublenine.pocketccd.full` (Product IDs are permanent — copy it exactly).
4. Price $9.99, enable Family Sharing.
5. Add localizations:
   - English — display name `PocketCCD Full`, description
     “Unlock the C1 and N2 camera personalities forever. One purchase, no subscription.”
   - Simplified Chinese — display name `PocketCCD 完整版`, description
     “永久解锁 C1 与 N2 两台相机。一次购买，不含订阅。”
6. Upload one review screenshot (the paywall is enough).
7. Attach the IAP to the version you submit, or review will not find it.
8. Test purchase and restore on a device with a sandbox account

`PocketCCD Full` permanently includes the launch C1 and N2 cameras and future
refinements to those cameras. It does not promise entitlement to separately
released cameras, video packs, collaborations, or other future products.
   (Settings → App Store → Sandbox Account).

## If you ever switch to a subscription

1. Create an Auto-Renewable Subscription in App Store Connect (group, duration,
   introductory offer).
2. Replace the product id in `PocketProduct`; the entitlement loop stays the same.
3. The paywall must then show duration, price unit, auto-renewal terms, a
   cancellation path, and links to privacy policy and terms — all review
   requirements.
4. Handle expiry and billing grace (`expirationDate`, `isInGracePeriod`).
5. Pricing reference: NOMO annual ≈ $24.99; Kapi $9.99/mo, $69.99/yr, $149
   lifetime. The project decision in `docs/COMPETITOR_MATRIX.md` is to launch
   without a subscription and charge $9.99 once.

## Open items

- Done: `UNLOCK FOREVER · %@`, `RESTORE PURCHASES`, `CHECK AVAILABILITY` and
  `CHECKING…` now live in the String Catalog (en / zh-Hans / zh-Hant). The price
  itself comes from StoreKit `displayPrice`, never hard-coded.
