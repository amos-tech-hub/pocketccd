# 真机原片样张（不随仓库提交）

这个目录是**测试专用**的。`Real capture parity` 套件只在这里存在样张时才运行；
目录为空时该套件整组跳过，合成卡套件（`Preview parity`）照常运行。

## 为什么需要它

`Preview parity` 证明的是「同一张输入经过预览链路和成片链路后结果接近」——这是
软件路径的一致性，不是夜闪正确性。真实原片才能回答第二个问题：
A8 直闪的肤色、黑位、以及预览与成片的实际差距。

## 怎么导入

1. 真机连 Mac → Xcode → Window → Devices and Simulators → 选中设备 →
   Installed Apps → PocketCCD → 齿轮 → **Download Container…**
2. 右键 `.xcappdata` → 显示包内容 →
   `AppData/Library/Application Support/PocketCCD Originals/`
3. 把其中**拍摄文件夹**（`20261116-210000-abcdef/`，每个含 `capture.json` 与
   `frame-<n>-<role>.<ext>`）整个拷进本目录。整层拷贝也可以，读取器会递归查找
   `capture.json`。
4. 也可以在运行测试时指定别处：

   ```sh
   POCKETCCD_ORIGINALS_DIR=/path/to/PocketCCD\ Originals \
     xcodebuild test -project PocketCCD.xcodeproj -scheme PocketCCD \
     -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath .derived-index
   ```

## 读取器提供什么

- 每张样张的机身（`POCKET A7 / A8 / C1 / N2`）、闪光状态（`FLASH / NO FLASH / AUTO`）、
  拍摄模式（`flashParty` 等）、镜头与全部帧；
- 按机身 / 闪光 / 模式筛选，用于固定「A8 + FLASH + flashParty」这类组合；
- 坏掉的 `capture.json` 会被**报出来**（`skipped`），不会被静默忽略。

## 边界

- 现有套件不能证明 `.auto` 的亮度预测与真机 EXIF 一致；那需要暗场真机对照。
- 皮肤的 R/G 与黑位阈值要等这批样张进来之后再定，当前只打印测量值。

## roi.json（可选，但和调色日志比较时必须）

每个拍摄文件夹里可以放一个 `roi.json`，用**归一化坐标**（0–1，**左上角原点**）
标出两个区域：

```json
{
  "background": { "x": 0.62, "y": 0.10, "width": 0.30, "height": 0.40 },
  "faceLit":    { "x": 0.30, "y": 0.22, "width": 0.18, "height": 0.28 }
}
```

- `background`：画面背景的一块干净区域，用来读黑位；
- `faceLit`：闪光受光侧脸颊，用来读肤色 R/G；
- 两个键都可以省略；省略时该样张只做整图统计，报告会明确标注 `(whole-frame)`。

**为什么必须分区**：整图的 5% 分位数不是背景黑位。整张夜闪照片里既有黑背景又有
高光人脸，整图 p05 会把两者混在一起，数值无法与 `NIGHT_FLASH_TUNING_2026-11-15.md`
的「背景 ≤ 8」对照。

**为什么按机身分开**：A7 和 A8 的目标区间不同（A8 要求 R/G ≤ 2.5、背景 ≤ 8；A7 是
另一套）。报告按机身分组打印，阈值也按机身分别定，不共用一条门禁。

**背景只看 p05 会被骗。** p05 是区域里最暗的 5%：画面角落一小块真黑就能把它压到 1–3，
而背景其余部分可能是一片灰。所以报告同时给三个数：

| 字段 | 含义 | 怎么读 |
| --- | --- | --- |
| `bgP05` | 背景区域亮度 5% 分位数 | 最暗的部分有多黑 |
| `bgP50` | 背景区域亮度中位数 | 整块背景多数像素有多黑 |
| `bgBright` | 背景区域亮度 > 40 的像素占比 | 有多少面积是灰底 |

真黑背景：`p05` 低、`p50` 低、`bgBright` 接近 0。
灰底：`p05` 可能仍然很低，但 `p50` 在 40 以上、`bgBright` 明显偏高。
三个数一起看，才不会被一小块黑骗过去。
