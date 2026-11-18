# 角色卡市场数据源调研（2026-11-18）

目标：在 App 内直接浏览/下载公开角色卡，来源必须满足
**免鉴权、可搜索、能拿到标准卡文件（chara_card V2 PNG，含 `chara` 数据块）**。
本文件记录实测结论，供以后新增来源时参考。

## 结论表

| 来源 | 状态 | 实测证据 | 备注 |
|---|---|---|---|
| **Chub.ai** | ✅ 已接入（v0.11.0） | `api.chub.ai/search` 全参数 200；`nsfw=false` 只返回 SFW；`sort=star_count` 出全站热门；`page` 翻页有效；`topics=Fantasy` 过滤有效；卡文件 `chara_card_v2.png` 含 `tEXt chara` | 免鉴权、不校验 UA/Referer，连续 6 次请求全 200，目录最大 |
| Character Tavern | ❌ 本机不可达 | `character-tavern.com/` 与 `/api/characters/search` 均 15s 超时 | 疑似被网络阻断/需代理；如要接入需在可访问环境重新实测 |
| Pygmalion | ❌ 无公开接口 | `pygmalion.chat/api/characters` → 404（返回 Next.js HTML） | 站内 SPA，未公开文档化 API |
| Risu Realm | ❌ 未找到公开接口 | `realm.risuai.net/` 200，但 `/api/v1/character(s)`、`/api/characters` 猜测路径 404 HTML 或超时 | 前端调用内部接口，未公开 |
| JannyAI | ❌ 反爬 | `jannyai.com/` → 403（Cloudflare） | 需登录态/浏览器指纹，不适合内置 |
| JanitorAI | ❌ 本机不可达 | `janitorai.com/` 超时 | 需登录，无公开 API |
| Backyard AI | ❌ 本机不可达 | `backyard.ai/` 超时 | 桌面应用，API 需 key |

结论：**Chub.ai 是当前唯一满足「免鉴权 + 可搜索 + 标准 V2 卡文件」的源**，已作为默认源接入；
代码层保留了 `CardMarketSource` 抽象，后续有可用新源时只需新增一个实现。

## Chub.ai 接口（实测模板）

```text
# 搜索（关键词为空 = 浏览热门）
GET https://api.chub.ai/search?search=<关键词>&first=24&page=1&nsfw=false
GET https://api.chub.ai/search?search=&first=24&page=1&nsfw=false&sort=star_count

# 响应
{ "data": { "count": 8593, "nodes": [ { ...节点... } ] } }
```

节点关键字段（2026-11 实测）：

| 字段 | 含义 | 代码映射 |
|---|---|---|
| `id` | 源内 id | `MarketCard.id` |
| `name` | 卡名 | `MarketCard.name` |
| `fullPath` | `作者/卡片别名` | `MarketCard.fullPath`，前缀即 `creator` |
| `tagline` / `description` | 一句话 / 长简介 | `tagline`、`description`（列表副标题回退） |
| `avatar_url` | 封面缩略图（webp） | `thumbnailUrl` |
| `max_res_url` | 标准卡文件（= `chara_card_v2.png`） | `downloadUrl` |
| `topics[]` | 标签 | `topics` |
| `starCount` / `nTokens` / `nChats` | 收藏 / token / 对话数 | `stars` / `tokens` / `chats` |
| `nsfw_image` | 是否 NSFW 封面 | `nsfw`（服务端已按 `nsfw=false` 过滤） |

下载卡文件（直接是 chara_card V2 PNG，可喂给 `CardParser`）：

```text
https://avatars.charhub.io/avatars/<fullPath>/chara_card_v2.png
```

实测该 PNG 内含 `tEXt` 关键字 `chara`（base64 的 V2 JSON），与
`lib/services/card_parser.dart` 的解析路径完全兼容；`max_res_url` 缺失时上述地址可作兜底。

## 合规做法（已写进 UI 与代码注释）

- 只浏览服务端过滤后的 **SFW** 内容（请求固定 `nsfw=false`）；
- 不在 App 内持久缓存封面/卡文件，下载即入库为本地角色卡；
- 详情页署名「数据来自 Chub.ai · 版权归原作者所有」，不提供二次分发；
- 不内置账号/凭证，不做抓取式爬虫，只走公开 JSON 接口。

## 新增来源需要做什么

1. 实现 `lib/services/card_market.dart` 的 `CardMarketSource`：
   `name`、`siteUrl`、`pageSize`、`searchUri()`、`parseSearch()`（坏节点跳过而不是整体失败）、
   `download(card)`（返回卡文件字节）；
2. 用 `CardMarketClient(source: YourSource())` 注入（`CardMarketClient` 负责超时与中文错误映射）；
3. 加单测：请求地址参数、响应归一化/兜底、客户端错误映射、`importCardBytes` 入库。

## 复现（PowerShell）

```powershell
$r = Invoke-WebRequest 'https://api.chub.ai/search?search=elf&first=3&page=1&nsfw=false'
$r.StatusCode; ($r.Content | ConvertFrom-Json).data.nodes | Select-Object name,fullPath,starCount
```
