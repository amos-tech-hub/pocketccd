# Pocket CCD 全量代码审查报告

- 审查日期：2026-11-25（Asia/Shanghai）
- 审查范围：仓库根目录全部 Swift 源码 18 个文件 / 18,748 行；`Info.plist`、`PocketCCD.entitlements`、`PrivacyInfo.xcprivacy`、`InfoPlist.xcstrings`、`PocketCCD.xcodeproj`、测试与脚本
- 审查方式：6 个专项并行静态审查（相机主界面、相机核心管线、成像与校准、存储与内购、UI 与外围、测试与工程配置），主审逐条复核关键结论并重新读取引用代码
- **修复进度**：P0 已全部修复，P1 主要项已修复，详见 [`FIXES_2026-11-25.md`](FIXES_2026-11-25.md)。下文保留审查当时的原始发现与行号。
- 构建验证：`xcodebuild -scheme PocketCCD -configuration Debug -destination 'generic/platform=iOS Simulator'` → **BUILD SUCCEEDED**（需 `danger-full-access`，原因见 1.2）
- 未执行：全量回归测试（遵循 `AGENTS.md`：只有用户明确要求测试时才跑全量）

**结论一句话**：工程整体健康，架构分层、注释质量和旧问题修复都明显好于 11-15 那次审查；但仍有 **3 个提审/崩溃级问题**（PrivacyInfo 缺 required-reason、胶卷空槽 Range 反向崩溃、索引修复后的备份无法还原）和 **一组会造成卡顿、错片、付费误锁的高优先级问题**。修完 P0 + P1 再提交。

---

## 0. 结论摘要

| 项目 | 结果 |
|---|---|
| 模拟器 Debug 构建 | ✅ 通过（App target；测试 target 未单独编译） |
| Swift 编译警告 | 2 条（均为 Swift 6 并发迁移相关）+ 5 条 Asset Catalog 警告 |
| 严重问题 | **P0 × 3，P1 × 14，P2 约 40 项（分组列出）** |
| 旧审查（2026-11-15）问题状态 | P0 日期戳 3× 放大已修复；快门超时、会话重建、权限恢复、麦克风移除、恢复购买、权益缓存等均已落地 |
| 最该先修的三件事 | ① `PrivacyInfo.xcprivacy` 补 FileTimestamp + DiskSpace；② 胶卷空槽 `ForEach` 反向 Range；③ 闪光灯 1/45s 上限在异常路径不恢复 |

---

## 1. 验证方式与结果

### 1.1 构建

```sh
xcodebuild -project PocketCCD.xcodeproj -scheme PocketCCD \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .tmp/review-build3 CODE_SIGNING_ALLOWED=NO build
# → ** BUILD SUCCEEDED **
```

编译警告（去重后）：

| 位置 | 警告 |
|---|---|
| [CameraScreen.swift:1761](../CameraScreen.swift#L1761) | 在同步 nonisolated 上下文调用 `@MainActor` 的 `pocketHUDFont`（Swift 6 模式会报错） |
| [ExperienceViews.swift:1597](../ExperienceViews.swift#L1597) | `RollPreviewPage: Equatable` 跨越 MainActor 隔离，Swift 6 模式会报错 |
| `Assets.xcassets` ×5 | `CameraBodyA8/C1/M1/N1/N2` 各有 2 个未分配子项（体积冗余，不影响运行） |
| AppIntents | 无 AppIntents 依赖，元数据提取跳过（正常） |

### 1.2 环境说明

默认 workspace 沙箱下 Swift 宏插件服务无法应用自身 sandbox（`sandbox_apply: Operation not permitted`），`@Observable`/`@State` 全部报 "malformed response"。这是**审查环境限制，不是工程问题**；用 `danger-full-access` 重跑后构建正常。后续在 DSH 里做构建验证也应使用完整权限。

### 1.3 未覆盖项

- 未跑全量测试（149+ 用例 / 出图矩阵），按工作区规则留给发布前。
- 无真机：闪光灯时序、MultiCam、配对拍摄、StoreKit 沙盒、相册元数据、横持方向、内存峰值均无法实测。
- 成像结论（白点、暗角、预览/成片一致性）只能做代码推断，已逐条标注「需样本/需真机验证」。

---

## 2. P0：提审或崩溃级，必须先修

### P0-1 胶卷空槽 `ForEach` 反向 Range，超过容量时必崩

- **位置**：[ExperienceViews.swift:553](../ExperienceViews.swift#L553)
- **证据**：

  ```swift
  ForEach(entries.count ..< store.capacity, id: \.self) { slot in
  ```

  Swift 的 `Range` 要求 `lowerBound <= upperBound`；`entries.count > store.capacity` 时构造 `20 ..< 12` 直接 `Fatal error: Range requires lowerBound <= upperBound`。
- **触发路径**：`RollStore.adoptUnindexedFrames()` 会把索引里没有的孤儿 JPEG 全部 append，并明确注释「may push the roll past its configured size」（[MemoryFeatures.swift:670-674](../MemoryFeatures.swift#L670-L674)）。即：索引写失败 → 下次启动收养孤儿 → 条目数超过 12/24 → 打开「当前胶卷」或归档页立刻崩溃。这正是「索引修复」要救的场景。
- **修复**：

  ```swift
  let emptySlots = max(store.capacity - entries.count, 0)
  ForEach(0..<emptySlots, id: \.self) { slot in ... }
  Text("\(emptySlots) MORE")
  ```

  更稳妥的做法是在 `adoptUnindexedFrames()` 后把超额条目自动转进归档，保证 `entries.count <= capacity` 这个不变量始终成立。

### P0-2 隐私清单缺 FileTimestamp / DiskSpace 两类 required-reason API

- **位置**：[PrivacyInfo.xcprivacy:11-21](../PrivacyInfo.xcprivacy#L11-L21)
- **证据**：清单只声明了 `NSPrivacyAccessedAPICategoryUserDefaults / CA92.1`，但生产代码实际使用：
  - 文件时间戳：`contentsOfDirectory(... includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey])`（[MemoryFeatures.swift:651](../MemoryFeatures.swift#L651)、[MemoryFeatures.swift:663](../MemoryFeatures.swift#L663)、[OriginalFrameArchive.swift:221](../OriginalFrameArchive.swift#L221)）
  - 磁盘容量：`volumeAvailableCapacityForImportantUsageKey`（[ProductInfrastructure.swift:844](../ProductInfrastructure.swift#L844)）
- **影响**：上传 App Store 会触发 ITMS-91053（missing required reason API），在审核/上传阶段被拒；即使侥幸上传，隐私标签与实际 API 使用不一致，后续审核也会被质疑。
- **修复**：补两类声明（reason code 以 Apple 官方列表为准）：

  ```xml
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>C617.1</string></array>
  </dict>
  <dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryDiskSpace</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array><string>E174.1</string></array>
  </dict>
  ```

  同时全仓再扫一遍 `systemUptime`、`mach_absolute_time`、`activeInput` 等其它 required-reason 类别，避免第二次返工。

### P0-3 索引修复过的胶卷，其备份导入必然整包失败

- **位置**：[MemoryFeatures.swift:569-572](../MemoryFeatures.swift#L569-L572)、[MemoryFeatures.swift:664-666](../MemoryFeatures.swift#L664-L666)、[MemoryFeatures.swift:512-514](../MemoryFeatures.swift#L512-L514)
- **证据**：

  ```swift
  private nonisolated static func hasSafeFileName(_ entry: RollEntry) -> Bool {
      let expected = "\(entry.id.uuidString).jpg"
      return entry.fileName.caseInsensitiveCompare(expected) == .orderedSame ...
  }
  ...

  return RollEntry(id: UUID(), fileName: url.lastPathComponent, ...) // 收养孤儿
  ```

  收养条目的 `id` 是新 UUID，`fileName` 却是真实文件名；导出备份时原样带上（[MemoryFeatures.swift:445-460](../MemoryFeatures.swift#L445-L460)），导入时 `suppliedEntries.allSatisfy(hasSafeFileName)` 失败，抛 `.invalidContents`，**整个备份被拒绝**。
- **影响**：用户遭遇索引损坏（adoption 存在的原因）后导出的备份，永远无法还原；这是「备份功能在最需要它的时刻 100% 失效」的数据丢失路径。错误提示还是 `.invalidContents`，无法自查。
- **修复**：二选一，建议都做：
  1. 导出时对收养条目重写 `fileName = "\(entry.id.uuidString).jpg"`，并把图片数据按新名写入 `imageDataByFileName`；
  2. 导入校验放宽为「文件名安全（无路径分隔符/无 `..`）且能在 `imageDataByFileName` 或目录中找到」，而不是强绑定 UUID。
  另补一条 export → 新目录 → import 的往返测试，覆盖收养条目。

---

## 3. P1：明确用户可见故障、数据/隐私风险或显著性能问题

### P1-1 闪光灯 1/45s 快门上限在抛错路径上不恢复，整机曝光被锁死

- **位置**：[CameraController.swift:343-370](../CameraController.swift#L343-L370)
- **证据**：先设置 `device.activeMaxExposureDuration = targetMaxShutter`，再 `try await requestPhoto(settings)`；只有正常返回后才恢复 `.invalid`。`requestPhoto` 的 8 秒 watchdog 超时、`Task.checkCancellation()`、或拍照 delegate 报错都会跳过恢复段。
- **影响**：一次闪光超时/取消后，该相机的自动曝光永久被限制在 ≤ 1/45s，之后所有夜景/室内照片系统性发黑，直到下一次闪光拍摄才可能恢复。现象与「闪光灯」无关联，用户和客服都很难定位。
- **修复**：把恢复放进 `defer`（或 `do/catch` 的 `catch` 里）：

  ```swift
  defer {
      if flashLimitApplied, let device = activeInput?.device {
          try? device.lockForConfiguration()
          device.activeMaxExposureDuration = .invalid
          device.unlockForConfiguration()
      }
  }
  ```

### P1-2 MultiCam 在 `commitConfiguration` 前 `startRunning`，且无 hardwareCost 校验与失败回滚

- **位置**：[DualMemoryController.swift:74-129](../DualMemoryController.swift#L74-L129)
- **证据**：`session.beginConfiguration()` 后 `defer { session.commitConfiguration() }`，但 `session.startRunning()` 在 defer 之前执行（:126）；全程没有检查 `hardwareCost` / `systemPressureCost`；失败后 `session/rearOutput/frontOutput` 已赋值，下次进入会命中「缓存分支」反复失败。
- **影响**：MultiCam 对配置完整性极敏感，资源超限时可能抛 ObjC 异常（Swift `do/catch` 接不住）；即便不崩，失败也没有回滚，双机功能会一直坏到杀进程。
- **修复**：把 `startRunning()` 移到 `commitConfiguration()` 之后；启动前断言 `session.hardwareCost < 1.0 && session.systemPressureCost < 1.0`，否则降级到 `SequentialDualCapture`；`catch`/失败分支把三个字段清空。
- **置信度**：高概率问题，**需真机确认**具体触发条件与 `isRunning` 行为。

### P1-3 三条路径把 12MP `look.render` 放在主线程，UI 冻结数百 ms 到数秒

- **位置**：[CameraScreen.swift:733-740](../CameraScreen.swift#L733-L740)（Dual Memory）、[CameraScreen.swift:914-923](../CameraScreen.swift#L914-L923)（Moment 静帧）、[CameraScreen.swift:1054-1064](../CameraScreen.swift#L1054-L1064)（导入照片）
- **证据**：这三处的 `Task { }` 继承 `View` 的 `@MainActor`，内部同步调用 `look.render(...)`；而同文件的 `performCapture` 明确把同一调用放进 `Task.detached(priority: .userInitiated)`（[CameraScreen.swift:835-855](../CameraScreen.swift#L835-L855)），说明主线程版本是遗漏。
- **影响**：导入、双人记忆（2 帧）、Pocket Moment（3 帧）时主线程串行跑 Core Image bloom/halation/grain + `createCGImage` + 日期戳，每帧 12MP 数百 ms；叠加 3 帧内存峰值可到 200–300MB，旧机型有 jetsam 风险。
- **修复**：把 `look.render` + `CaptureColorAnchor.measure` 统一移入 `Task.detached`，MainActor 只接收 `UIImage`；抽一个 `renderOffMain(...)` 包装，避免第四次遗漏。

### P1-4 手势识别把全分辨率缓冲喂给 Vision，且跑在预览串行队列上

- **位置**：[LivePreviewPipeline.swift:216](../LivePreviewPipeline.swift#L216)、[LivePreviewPipeline.swift:356-363](../LivePreviewPipeline.swift#L356-L363)
- **证据**：

  ```swift
  detectOpenHand(in: buffer, orientation: orientation, now: now)
  ...
  try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation).perform([request])
  ```

  `buffer` 是相机原始采样缓冲（iOS 17/18 上 4032×3024 BGRA），不是已缩放的 `previewSource`。
- **影响**：开启「手势快门」后，每 0.22s 在预览队列上做一次手部姿态检测，每次数十至数百 ms，直接抢渲染队列 → 掉帧、快门延迟、发热。模拟器上不明显，真机（尤其旧机型）明显。
- **修复**：把 `previewSource`（1280 或再降到 320）转成 `CGImage` 再跑 Vision，并移到独立低优先级队列；关闭手势时完全不构造 request。

### P1-5 Pocket Moment 的视频与同源静帧不是同一个画面

- **位置**：[CCDLook.swift:1108-1110](../CCDLook.swift#L1108-L1110)、[CameraScreen.swift:4056-4074](../CameraScreen.swift#L4056-L4074)、[CameraScreen.swift:914-917](../CameraScreen.swift#L914-L917)
- **证据**：视频走 `look.videoFrame(source, ...)`，签名里没有 `aspectRatio` / `focalCrop` / 前摄镜像；静帧则按 `aspectRatio` 裁剪、按 `shouldMirror` 镜像。视频每帧无 override 时还会重新测白平衡（[CCDLook.swift:1188-1194](../CCDLook.swift#L1188-L1194)），静帧只测一次锚点。
- **影响**：16:9、50mm（focalCrop 1.43）、自拍时视频与静帧构图不同；混合光下同一段视频白平衡逐帧漂移。用户会觉得「视频和照片不是同一次拍摄」。
- **修复**：`processedFrame` 先按 aspect/focalCrop 裁剪、按 `isFront` 镜像，再套 look；导出时锁定首帧 WB gain（或做 EMA），把同一 `colorAnchor` 传给所有帧。

### P1-6 权益「可达性」取自商品请求，会在边缘时序下清掉付费用户的解锁缓存

- **位置**：[ProductInfrastructure.swift:139-146](../ProductInfrastructure.swift#L139-L146)、[ProductInfrastructure.swift:123](../ProductInfrastructure.swift#L123)
- **证据**：

  ```swift
  let availability: StoreAvailability = storeReachable == true ? .reachable : .unreachable
  ...
  case .none: availability == .reachable ? false : cached
  ...
  UserDefaults.standard.set(unlocked, forKey: Self.unlockCacheKey)
  ```

  `storeReachable` 只在 `loadProduct()` 成功时置真，与「权益查询是否得到答复」不是同一件事。
- **影响**：商品请求成功（reachable）但 `Transaction.currentEntitlements` 短暂为空（StoreKit 抖动、刚装、账号切换）时，`evidence == .none` + `reachable` → 判定未解锁并**把缓存覆写为 false**，付费用户被上锁且下次启动仍锁。
- **修复**：让权益查询自带「是否得到 StoreKit 应答」信号；只有商品请求与权益查询都权威时才允许写 false。缓存只在 `revoked` 或明确的「已应答且无记录」时清除。
- **置信度**：需 StoreKit 沙盒/弱网实测确认影响面。

### P1-7 购买没有重入保护

- **位置**：[ProductInfrastructure.swift:168-199](../ProductInfrastructure.swift#L168-L199)
- **证据**：`restorePurchases` 有 `isRestoring`，`purchaseFullUnlock()` 没有任何 in-flight 守卫；付费墙按钮只 `.disabled(store.isLoading)`，首次购买完成后 `isLoading` 已复位。
- **影响**：双击「解锁」会并发发起两次 `purchase()`，`purchaseMessage` 互相覆盖，成功提示可能被后到的取消/错误冲掉；极端情况下产生两条交易处理。
- **修复**：加 `isPurchasing`，函数入口 `guard !isPurchasing else { return }`，按钮同步禁用。

### P1-8 备份导入/导出全量驻留内存，500MB 上限会变成 1.5GB 峰值

- **位置**：[MemoryFeatures.swift:500-514](../MemoryFeatures.swift#L500-L514)、[MemoryFeatures.swift:445-460](../MemoryFeatures.swift#L445-L460)
- **证据**：`guard data.count <= 500_000_000` 后用 `JSONDecoder` 整包 decode；导出把所有 JPEG 塞进 `[String: Data]` 再 `JSONEncoder`（base64 再 +33%）。
- **影响**：接近上限的备份在解码/编码时峰值可达 1.5GB+，旧机型直接 jetsam；24 帧胶卷导出也已有数百 MB 峰值。
- **修复**：改为逐文件流式写入（目录 + manifest 或 zip），上限降到 ~150MB 并在 UI 说明；导入按条目解码，不整包驻留；补一条内存/大文件测试。

### P1-9 配对会话离开页面后不断开，且被取消的超时任务仍会重发邀请

- **位置**：[PairedCapture.swift:81](../PairedCapture.swift#L81)、[PairedCapture.swift:96-104](../PairedCapture.swift#L96-L104)
- **证据**：

  ```swift
  func stop() { advertiser.stopAdvertisingPeer(); browser.stopBrowsingForPeers() }
  ```

  全文件没有 `session.disconnect()`；超时 Task 里 `try? await Task.sleep(...)` 吞掉 `CancellationError` 后继续执行，且没有 `Task.isCancelled` 检查。
- **影响**：离开配对页后 MCSession 仍连接，对方仍可推快门/推图（会写进 `receivedImage` 内存）；连续点 Connect 会积累旧任务，在取消瞬间再发邀请并覆盖 `connectTimeout`，对方因单槽 `pendingInvitation` 拒绝，表现为配对随机失败。
- **修复**：`stop()` 里 `session.disconnect()` + 清空 `connectedPeers/receivedImage/pendingInvitation`；sleep 用 `do/catch` 提前 return，或 sleep 后 `guard !Task.isCancelled`。

### P1-10 从设置进入 Dual Memory 时相机尚未重启，真机必现失败

- **位置**：[CameraScreen.swift:693-751](../CameraScreen.swift#L693-L751)、调用点 [CameraScreen.swift:2906](../CameraScreen.swift#L2906)
- **证据**：设置页回调是 `{ dismiss(); onDualMemory() }`；`beginDualMemory` 没有像 `beginPairedCapture`（[CameraScreen.swift:754-763](../CameraScreen.swift#L754-L763)）那样 `await camera.start()` 并等待。`SequentialDualCapture` 只有 `initialPosition != .back` 时才等 500ms，后摄起步时立即 `capturePhoto()` → `CameraController.capture` 的 `isSessionRunning()` 失败。
- **影响**：iPhone 上 `isMultiCamSupported` 为 false，走的正是 sequential 分支；用户从设置点「Dual Memory」得到「Couldn't capture Dual Memory.」，且在多数机型上稳定复现。
- **修复**：进入前 `await camera.start()` 并等待 `isConfigured/isRunning`，或复用 `beginPairedCapture` 的 350ms + restart 模式；更好的做法是让 `CameraScreen` 在 `onAppear`/`scenePhase` 恢复时统一重启会话并暴露 `await camera.ensureRunning()`。
- **置信度**：代码路径成立，**需真机/导航实测**确认 `onDisappear` 确实停会话。

### P1-11 LUT 静态缓存约 50–86MB，且首个 4MB 表在主线程烘焙

- **位置**：[CCDLook.swift:628-636](../CCDLook.swift#L628-L636)、[LivePreviewPipeline.swift:48](../LivePreviewPipeline.swift#L48)
- **证据**：`prewarmCubes()` 对 6 个 look 各生成 character/shoulder/redGuard×2；redGuard 是 64³ Float = 4MB/个，6×2×4MB ≈ 50MB；`lumaContrastCube`（64³）未预热，每个 look 首次渲染现烤 4MB，最多再 +28MB。调用链 `CameraScreen @State camera → CameraController → LivePreviewPipeline.init → prewarmCubes()` 在主线程。
- **影响**：打开相机首帧前阻塞 50–150ms；常驻 50–86MB 对 3GB 机型不友好，和 12MP 成片内存叠加。
- **修复**：大表降到 33³（约 143KB）；`prewarmCubes` 放 `Task.detached(.utility)`；给 `lumaCubeCache` / `toneCubes` 加条目上限或按 look 常量化。

### P1-12 三处静帧漏传 `dateStampFormat`，用户选的格式被静默忽略

- **位置**：[CameraScreen.swift:733-740](../CameraScreen.swift#L733-L740)、[CameraScreen.swift:914-923](../CameraScreen.swift#L914-L923)、[CameraScreen.swift:1054-1064](../CameraScreen.swift#L1054-L1064)
- **证据**：只有 [CameraScreen.swift:675](../CameraScreen.swift#L675) 与 [CameraScreen.swift:861](../CameraScreen.swift#L861) 传了 `dateStampFormat: stampFormat`；其余三处依赖默认 `.dayMonthYear`。
- **影响**：Dual Memory、Moment 静帧、导入照片永远烧 `dd MM ’yy`，用户在设置里选 `’yy MM dd` / `dd MM hh:mm` 无效，且不可撤销。
- **修复**：抽一个 `renderCapture(_:stampFormat:)` 包装，所有路径统一传；或在 `CCDLook.render` 里把 format 设为必填参数，让遗漏变成编译错误。

### P1-13 回归门禁实际不存在：脚本吞退出码 + 校准套件零断言 + 绝对路径

- **位置**：[scripts/test_report.sh:21](../scripts/test_report.sh#L21)、[ProductInfrastructureTests.swift:2161-2193](../ProductInfrastructureTests.swift#L2161-L2193)、[ProductInfrastructureTests.swift:95-107](../ProductInfrastructureTests.swift#L95-L107)
- **证据**：
  - `xcodebuild test ... | tee "$LOG" | grep ... || true`：`|| true` 把整条管道的失败状态清掉，测试红着脚本也 exit 0。
  - 5 个「Look render check」类套件只 `guard ... else { return }` / `continue`，零 `#expect`，且路径写死 `/Users/adam/code/apple/PocketCCD/.tmp/...`，换机器静默跳过。
  - `flashShutterClampEnforcesMinimum` 在测试内自己算 `min(requested, minClamp)`，从未调用生产代码，等于测 Swift 标准库。
- **影响**：`test_report.sh` 是仓库唯一的全量入口；它永远绿，等于没有 CI 门禁。出图回归、成像参数、快门钳制都没被真正验证。
- **修复**：脚本用 `rc=${PIPESTATUS[0]}` + `exit $rc`；校验改为「缺输入必须失败」而非跳过；把 clamp 提成生产纯函数并测它；出图工具移出 test target 或改成带尺寸/统计断言的快照测试。

### P1-14 白点/肩部/色调阈值处于线性空间，与注释的 sRGB 目标不一致（需样本验证）

- **位置**：[CCDLook.swift:1312-1316](../CCDLook.swift#L1312-L1316)、[CCDLook.swift:1779-1784](../CCDLook.swift#L1779-L1784)、[CCDLook.swift:900-921](../CCDLook.swift#L900-L921)
- **证据**：`CIColorClamp` 的 `whiteClamp`（0.94/0.968）作用在 `extendedLinearSRGB` 工作空间；肩部 knee 0.72 也在同一空间。按 sRGB 传输函数换算，0.968 线性 ≈ sRGB 0.987（252），0.94 线性 ≈ 0.974（248）；而注释写的是「reviewed 242 limit」。
- **影响**：如果注释的 242 才是验收目标，则高光滚降从 ~86.5% 才开始、白衬衫停在 248–251，过曝压缩比设计更弱；所有 look 的白点系统性偏高。
- **修复**：把 shoulder/tone/clamp 移到 `CILinearToSRGBToneCurve` 之后再作用，或把阈值换算成线性等价值（242 → 0.888，knee 0.72 → 0.474）。**先用真机白衬衫/灰卡样本实测当前落点再改**，不要凭公式直接调。

---

## 4. P2：按主题分组

### 4.1 性能与内存

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| 1 | 胶卷缩略图在主线程同步 ImageIO 解码（24 张滚动明显） | [MemoryFeatures.swift:253-255](../MemoryFeatures.swift#L253-L255)、[ExperienceViews.swift:1283-1298](../ExperienceViews.swift#L1283-L1298) | 改 actor + async 预解码 + 占位图 |
| 2 | 分享/保存时主线程同步解 12MP 原图 | [ExperienceViews.swift:1531-1538](../ExperienceViews.swift#L1531-L1538) | `Task.detached` + 复用 `RollPreviewImageCache` |
| 3 | 照片回调里同步做 12MP 解码 | [CameraController.swift:1464-1470](../CameraController.swift#L1464-L1470) | 回调只取数据，解码丢专用队列，按 requestID 保序 |
| 4 | `assessAll` 在 TaskGroup 里跑同步阻塞 Vision | [FrameAnalyzer.swift:27-31](../FrameAnalyzer.swift#L27-L31) | 用 `await assess(image)`，别绕过 `Task.detached` |
| 5 | 校准分析指针在 `CGContext` 作用域外使用（UB），且 512px 循环在主线程 | [CalibrationLab.swift:483-512](../CalibrationLab.swift#L483-L512) | 改用 `CGContext` 生命周期内拷贝；分析移后台 |
| 6 | 预览按 1280 套 look、成片按 4032 套 look，颗粒/bloom 强度不一致 | [LivePreviewPipeline.swift:211-215](../LivePreviewPipeline.swift#L211-L215) | 参数按长边归一化（需样本验证差异幅度） |
| 7 | 单击对焦被长按识别器拖慢 450ms | [CameraPreview.swift:50-51](../CameraPreview.swift#L50-L51) | 长按不阻塞单击，或改双击锁定 |
| 8 | `movieOutput.isRecording` 跨队列读取 | [CameraController.swift:541](../CameraController.swift#L541)、[CameraController.swift:1128](../CameraController.swift#L1128) | 用 @MainActor 自己的 recording 标志 |

### 4.2 正确性与生命周期

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| 9 | 定时拍摄中离开页面，`countdown` 不复位，回来遮罩定格、快门全锁（仍可点 CANCEL） | [CameraScreen.swift:283-287](../CameraScreen.swift#L283-L287)、[CameraScreen.swift:586-591](../CameraScreen.swift#L586-L591) | `onDisappear` 调用 `cancelCountdown()` 或 Task 兜底清态 |
| 10 | Moment 视频被删后结果页重弹，preview/share 指向已删文件 | [CameraScreen.swift:296-304](../CameraScreen.swift#L296-L304)、[CameraScreen.swift:1117-1126](../CameraScreen.swift#L1117-L1126) | 删除前判断 `rollSaveFailed`，重弹前校验文件存在 |
| 11 | `selectedFrame` 用 `count - 1` 兜底，空数组时下标 -1 崩溃 | [CameraScreen.swift:3931](../CameraScreen.swift#L3931) | 改 `frames.first` 或 preconditions |
| 12 | EXIF `DateTimeOriginal` 与 GPS 取保存时刻，非快门时刻 | [CameraController.swift:786](../CameraController.swift#L786)、[CameraController.swift:858-865](../CameraController.swift#L858-L865) | `CapturedPhoto` 带快门时 `capturedAt`/location 一路传下去 |
| 13 | Moment 结束后音频会话只 deactivate，不还原 `.ambient` 类别 | [CameraController.swift:975-978](../CameraController.swift#L975-L978)、[CameraController.swift:1095](../CameraController.swift#L1095) | 释放时恢复 `.ambient + .mixWithOthers`，`prepareIfNeeded` 可重入 |
| 14 | Vision 失败返回 0.45/0.48 中性分，可能压过真实模糊帧 | [FrameAnalyzer.swift:86-92](../FrameAnalyzer.swift#L86-L92) | 返回带 `analysisFailed` 的低分，或降低无脸权重 |
| 15 | `startNewRoll` 回滚不含标题/备注与 colorAnchors | [MemoryFeatures.swift:289-300](../MemoryFeatures.swift#L289-L300) | 先备份全部元数据再清 |
| 16 | 删除先删文件后写索引，persist 失败条目会以新 UUID 复活 | [MemoryFeatures.swift:365-367](../MemoryFeatures.swift#L365-L367) | 先写索引再删文件，或保留 tombstone |
| 17 | 备份 manifest `version` 只写不读；解码失败当空卷处理 | [MemoryFeatures.swift:83-85](../MemoryFeatures.swift#L83-L85)、[MemoryFeatures.swift:594-601](../MemoryFeatures.swift#L594-L601) | 版本不兼容显式失败并保留 `.bak` |
| 18 | 导入 persist 失败抛 `.unreadable`；已写图片不回滚 | [MemoryFeatures.swift:483-487](../MemoryFeatures.swift#L483-L487)、[MemoryFeatures.swift:537-543](../MemoryFeatures.swift#L537-L543) | 区分写盘/解码错误；失败清理已写文件 |
| 19 | `RollStore.capacity` 硬读 `UserDefaults.standard`，忽略注入实例 | [MemoryFeatures.swift:169-172](../MemoryFeatures.swift#L169-L172) | 改用 `defaults` 成员，测试可隔离 |
| 20 | 原始帧 1.5GB 配额未排除 iCloud 备份，也没有占用展示/手动清理 | [OriginalFrameArchive.swift:79](../OriginalFrameArchive.swift#L79)、[MemoryFeatures.swift:281-288](../MemoryFeatures.swift#L281-L288) | `isExcludedFromBackup = true` + 设置页显示占用 + 上限可调 |

### 4.3 隐私与配置

| # | 问题 | 位置 | 建议 |
|---|---|---|---|
| 21 | Bonjour 只声明 `_tcp`，Multipeer 同时走 UDP，附近设备发现可能静默失败 | [Info.plist:28-31](../Info.plist#L28-L31) | **真机验证**后补 `_pocketccd-shot._udp` |
| 22 | 空 entitlements + 工程无 `SystemCapabilities`（IAP 不依赖，但 ASC 侧要确认） | [PocketCCD.entitlements](../PocketCCD.entitlements) | 核对 ASC 的 In-App Purchase capability |
| 23 | 配对 `foundPeer` 不清 `pairingHint`，页面同时显示「No nearby phone」与设备列表 | [PairedCapture.swift:75-79](../PairedCapture.swift#L75-L79) | foundPeer 时清 hint |
| 24 | Instagram 分享失败时粘贴板图片仍留 5 分钟 | [SocialSharing.swift:76-84](../SocialSharing.swift#L76-L84) | 失败分支立即 `UIPasteboard.general.items = []` |
| 25 | DEBUG 启动面包屑写 Documents（仅 DEBUG，可接受） | [PocketCCDApp.swift:8-15](../PocketCCDApp.swift#L8-L15) | 保持 DEBUG 隔离即可 |

### 4.4 本地化与无障碍

- [CameraScreen.swift:4173](../CameraScreen.swift#L4173)：`String(localized: asLivePhoto ? "Live Photo saved." : "Video saved.")` —— key 运行时才确定，String Catalog 提取不到，永不翻译。
- [CameraScreen.swift:4555](../CameraScreen.swift#L4555)：`accessibilityValue(isOn ? "On" : "Off")` 硬编码英文，开关本身无 label。
- [CameraScreen.swift:1812](../CameraScreen.swift#L1812)：`"TIMER \(...)"` 句式拼接，语序不可译；[CameraScreen.swift:809](../CameraScreen.swift#L809)：「Captured N of M frames」无复数。
- [ExperienceViews.swift:1168-1197](../ExperienceViews.swift#L1168-L1197)：SensorPassport 一半行是硬编码英文（如 "Warm amber drift"），中文界面中英混排。
- [ExperienceViews.swift:506-549](../ExperienceViews.swift#L506-L549)：胶卷网格瓦片只有 `onTapGesture`，无 `accessibilityLabel`/button trait，VoiceOver 无法打开或多选。
- [CCDLook.swift:1985-1994](../CCDLook.swift#L1985-L1994)：日期戳用 `String(format:)` 固定语序，可接受但建议按 locale 模板。

### 4.5 代码卫生 / 死代码

- [CaptureModels.swift:277-291](../CaptureModels.swift#L277-L291)：`exportReady()` 生产代码零调用，注释却声称「every export shares」——要么接线，要么删，避免后人按注释改错地方。
- [CameraScreen.swift:3014](../CameraScreen.swift#L3014) `CameraSetupSummary`、[CameraScreen.swift:4222](../CameraScreen.swift#L4222) `ResultMetadata`、[CameraScreen.swift:4460](../CameraScreen.swift#L4460) `PocketBackBar` 全项目无引用；其中 `:3039` 硬编码 `"\(rollCount)/24"`，忽略 12 张容量。
- [CCDLook.swift:486-516](../CCDLook.swift#L486-L516) `toneCube()` / `toneGrid()` 无调用者且含 3 处 `!`；redNoise/greenNoise/blueNoise/banding/stripes 也已失联。
- 5 个 `CameraBody*.imageset` 有未分配子项，清理 Assets 可减包体。
- `SWIFT_VERSION = 5.0` + `SWIFT_STRICT_CONCURRENCY = complete` 只产生警告（2 条），未开 warnings-as-errors；建议至少 Debug 开 `SWIFT_TREAT_WARNINGS_AS_ERRORS`，再逐步升 Swift 6 mode。

### 4.6 测试

- **无 UI 测试 target**：工程只有 App + Unit 两个 target；`PocketCCDUITests.swift` 只存在于 `.review/harness/` 副本里。
- **无 `.storekit` 配置**：购买/退款/家庭共享/离线权益没有任何可重复的本地验证。
- **测试随机性**：`CIRandomGenerator` 颗粒导致 `sd/skew` 单次采样断言可能抖动（[CCDLook.swift:1366](../CCDLook.swift#L1366)、[ProductInfrastructureTests.swift:1629-1637](../ProductInfrastructureTests.swift#L1629-L1637)）；改多次采样取中位数。
- **弱断言**：`catch { #expect(error is StubError) }`（[ProductInfrastructureTests.swift:2803](../ProductInfrastructureTests.swift#L2803) 等）任何错误都通过；`context.makeImage()!` 等强解包若干。
- **隔离**：UserDefaults 套件创建后不清理；夹具依赖 `.enabled(if: hasSamples)`，CI 上静默跳过。

---

## 5. 文件级结论

| 文件 | 行数 | 结论 |
|---|---:|---|
| CameraScreen.swift | 4,877 | 功能最密集，状态机复杂；P1 × 4（主线程渲染、日期格式、Dual Memory 入口、定时残留），大量 P2。建议先抽 capture 状态机与 render 包装 |
| CameraController.swift | 1,638 | 旧问题修复到位；P1 闪光钳制泄漏、输入切换竞态、解码在回调队列；整体可用 |
| CCDLook.swift | 2,053 | 成像核心，注释质量高；P1 视频 recipe 与线性白点（待样本），P2 LUT 内存/死代码 |
| ExperienceViews.swift | 1,676 | P0 反向 Range；a11y/i18n 缺口；其余布局与缓存设计合理 |
| MemoryFeatures.swift | 1,301 | P0 备份文件名；P1 整包内存；存储模型整体谨慎，但错误路径仍有静默吞错 |
| ProductInfrastructure.swift | 857 | StoreKit 设计（离线缓存、撤销）方向正确；P1 权益时序、购买重入 |
| LivePreviewPipeline.swift | 448 | P1 全尺寸 Vision；其余双缓冲/锁使用基本正确 |
| CalibrationLab.swift | 529 | 校准矩阵可用；P2 指标基于烧戳成片、UI 状态与 UB |
| CaptureModels.swift | 396 | 几何/方向工具清晰；`exportReady` 死代码 |
| DualMemoryController.swift | 208 | sequential 回滚设计好；P1 MultiCam 配置时序 |
| PairedCapture.swift | 331 | 唯一连接管理缺口（不断开、取消后重邀）；P2 提示 |
| OriginalFrameArchive.swift | 289 | 归档/裁剪策略合理；P2 配额、备份排除、静默失败 |
| SocialSharing.swift | 103 | 基本正确；P2 粘贴板清理 |
| ShootingIdentity.swift | 90 | 无问题 |
| PocketCCDApp.swift / HardwareShutterView.swift | 82 | iOS 17.0/17.1 音量键静默无效（`#available(iOS 17.2)`），无提示 |
| ProductInfrastructureTests.swift | 3,251 | P1 门禁失效 + 零断言套件；建议先修脚本再补 5 条核心测试 |

---

## 6. 建议修复顺序

**第 0 批（半天内，提审前必须）**
1. PrivacyInfo 补 FileTimestamp + DiskSpace（P0-2）
2. `ForEach` 反向 Range（P0-1）
3. 备份收养条目文件名（P0-3）
4. 闪光钳制改 `defer`（P1-1）

**第 1 批（1–2 天，用户可感知）**
5. 三条主线程 `look.render` 移后台（P1-3）
6. 手势 Vision 降到 previewSource（P1-4）
7. Moment 视频补 aspect/focal/mirror + 锁 WB（P1-5）
8. 权益时序加「已应答」信号 + 购买重入（P1-6/7）
9. 配对 `disconnect` + 取消检查（P1-9）
10. LUT 降维 + 后台预热（P1-11）

**第 2 批（发布前）**
11. Dual Memory 入口等待会话（P1-10）
12. 日期格式统一（P1-12）
13. 备份流式化 / 上限下调（P1-8）
14. 测试脚本退出码 + clamp 生产函数 + 往返测试（P1-13）
15. 白点样本实测后决定是否调整（P1-14）

**第 3 批（下个版本）**
16. P2 性能/i18n/a11y/死代码清理，Swift 6 并发迁移。

---

## 7. 已确认修复的旧问题（2026-11-15 报告）

| 旧问题 | 现状 |
|---|---|
| P0 日期戳 3× 放大到 ~109MP | ✅ 已修：[CCDLook.swift:2013-2016](../CCDLook.swift#L2013-L2016) 固定 `format.scale` |
| 快门 continuation 无超时、无会话校验 | ✅ 已加 watchdog / `isSessionRunning` |
| 权限被拒后无法恢复 | ✅ `scenePhase` + 重试路径（[CameraScreen.swift:253-275](../CameraScreen.swift#L253-L275)） |
| 麦克风输入只加不删 | ✅ `removeInput` + `setActive(false)` |
| 媒体服务重置后不重建 | ✅ `isConfigured = false` + 重建（[CameraController.swift:1039-1071](../CameraController.swift#L1039-L1071)） |
| 设置里的恢复购买是空操作 | ✅ `AppStore.sync()` + `isRestoring` |
| 权益检查被商品请求串行阻塞 | ✅ 先 `refreshEntitlements`，再 `loadProduct` |
| Moment 静帧二次调色 | ✅ 从 `rawVideoURL` 抽帧 |
| 胶卷满时多帧静默丢帧 | ✅ 仍有 `storedCount` 提示逻辑（建议再核对边界） |

---

## 8. 复核说明

- 所有 P0/P1 与关键 P2 均由主审重新打开引用代码确认；行号基于 2026-11-25 工作树。
- 标「需真机/需样本/需 StoreKit」的条目是代码路径成立但无法在本环境证明触发概率的结论，已在正文标注。
- 本报告只读审查，未修改任何源码；构建产物在 `.tmp/review-build3/`，可删除。
