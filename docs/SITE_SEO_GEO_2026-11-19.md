# 官网 SEO / GEO 改版 · 2026-11-19（上架后）

App 已于 2026-11-18 上架（id `6834433326`，US 等 9 个 storefront）。本次把
`pocketccd.doublenine.work` 从"支撑页"改成"上架落地页"，并补齐 SEO 与 GEO。

## 改了什么

| 项 | 之前 | 现在 |
| --- | --- | --- |
| 页面 | 3 页（首页/support/privacy） | 4 个可索引页 + 404，新增 `ccd-camera-app.html` 指南页 |
| 上架入口 | 无 | 官方 App Store 徽章（paper chip），导航、正文、页脚 3 处外链 |
| 首页 title | PocketCCD — A real little digital camera | Pocket CCD · CCD camera app for iPhone (digicam, direct flash) |
| 结构化数据 | SoftwareApplication + Organization | WebSite + Organization + SoftwareApplication（含 downloadUrl / datePublished / 两档 offers）+ FAQPage；指南页有 Article + BreadcrumbList + FAQPage |
| 指南页 | 无 | "What is a CCD camera app"：5 个成因 + 3 张对比表 + 术语表 + 5 条 FAQ |
| GEO | llms.txt 仅 3 条链接 | llms.txt 重写：规范页、上架事实、关键事实、适用人群、描述口径、可用 storefront |
| robots.txt | `Allow: /` | 显式允许 GPTBot / OAI-SearchBot / ChatGPT-User / ClaudeBot / Claude-SearchBot / PerplexityBot / Google-Extended / Applebot-Extended / Bingbot / CCBot |
| 性能 | 首屏 hero PNG 2.5 MB | hero webp 130 KB（+jpg fallback），6 张截图 webp 各 25–41 KB，整站 652 KB |
| 社交分享 | 复用 1086×1448 竖图，无 og:image | 生成 1200×630 OG 卡片（重新排版：圆角 icon + Pocket CCD 字标 + Keep the night + NO SUBSCRIPTION 药丸 + 域名），4 个可索引页全部补齐 og:image/width/height/alt/locale 与 twitter card |
| 字体 | Inter | 系统栈（SF Pro / system-ui），去掉 Inter |

## 事实口径（不要改）

- 免费下载；A7 + A8 包含；Pocket CCD Full 一次性 US$9.99 解锁 C1 + N2；无订阅。
- iOS 17.0+，仅 iPhone。
- 首版 2026-11-18，version 1.0.0。
- storefront：US / GB / CA / AU / SG / JP / KR / HK / TW（DE / FR / CN 暂无）。
- 客户评级 0 条，因此**不写** aggregateRating、不写任何用户数或评分。

## 待办

- [ ] 发布 `sites/pocketccd-support/dist` 到 OpenAI hosting 项目
      `appgprj_6af9d38f9ecc819184b451e8c65a13df`
- [ ] 发布后确认 `/robots.txt`、`/sitemap.xml`、`/llms.txt` 为新版本
- [ ] Search Console 重新提交 sitemap（验证文件 `googled2cc34eb8f5979b3.html` 已随 dist 提交）
- [ ] 有首批评分后，再补 `aggregateRating` 与社证区块
- [ ] 发布后用 Facebook Sharing Debugger / Telegram 预览刷新 OG 缓存
- [ ] 可选：为 HK/TW 增加 zh-Hant 落地页（store 已有繁体文案）
