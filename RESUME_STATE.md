# 交接状态：v0.14.3 三风格建议回复 + 贴合角色卡设定 + 输入框上方上下文提示 + 默认 1M 窗口（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 三候选）、v0.12.1（修正为「用户侧」建议回复）。
> **本轮 v0.13.0**：① 建议回复条改成**纵向完整展示**（不再横向截断只看一半）；
> ② 角色卡**翻译功能**（编辑页入口，免费翻译优先，失败按 token 报价改用模型）；
> ③ 市场筛选补齐 Chub 全部可用条件（标签**可选可输入**）；
> ④ 市场列表**原文 + 译文**展示（名字 / 简介 / 标签）；
> ⑤ 市场下载的角色卡检测到非中文 → 询问是否翻译（免费 / 模型报价 / 不翻译）。
> analyze 清零、测试 **197 条全过**、release APK 构建成功（58.1 MB）并已装机。
>
> **v0.13.1（2026-11-20）**：角色卡市场从「仅显示 SFW」改为**展示全部内容（含 NSFW）**，
> 列表行与详情页对 NSFW 卡显示红色 `NSFW` 标记；服务端参数改为 `nsfw=true`（不过滤）。
> 版本 0.13.1+6，已重新构建、装机并在真机确认市场可见 NSFW 卡。
>
> **v0.13.2（2026-11-20）**：市场下载与「从链接下载」都显示**下载进度**（LinearProgressIndicator + 「下载中 42%」，拿不到 Content-Length 时显示已下载 KB）；版本 0.13.2+7，已装机实测。
>
> **v0.14.0（2026-11-20）**：① 建议回复改为**三种不同语气/风格**（简短接话 / 情绪互动 / 推进剧情），并对高度相似的候选去重；② 建议条出现时**自动重新贴底**，最后一条气泡不再被建议行挡住。
>
> **v0.14.1（2026-11-20）**：① 上下文占用条从 AppBar 下方移到**输入栏最底部**（2.5px 细线 + 低透明度小字「上下文 0.3%」），不再显眼，点按仍打开明细；② 建议指令改为**严格贴合角色卡对用户的设定与当前剧情**，并明确「只写用户想表达的那一句、不要替角色说话」；③ AppSettings.contextWindow 默认值 **65536 → 1,000,000（1M）**，并对仍然是旧默认值的用户做一次性迁移（自己改过的不动）。版本 0.14.1+9，已装机实测。
>
> **v0.14.2（2026-11-20）**：上下文占用提示从输入栏底部改到**输入框正上方**一行（样式不变：2.5px 细线 + 低透明度「上下文 0.3%」，点开明细）。版本 0.14.2+10，已装机实测。
>
> **v0.14.3（2026-11-22）**：完善 GitHub 仓库页 —— 重写 README、新增 LICENSE(MIT)/CHANGELOG、仓库描述与 10 个 topics、homepage 指向 Releases；发布首个 Release `v0.14.3` 并上传 app-release.apk（58.2 MB，tag 已 push）；「关于」弹窗补充作者 Alorith 与仓库地址。版本 0.14.3+11；**装机未完成**（设备离线，手机仍是 0.14.2 / versionCode 10）。

## v0.14.0 本轮变更

### 1) 三风格建议回复（lib/services/reply_suggestions.dart）

- 新增 `const List<String> kSuggestionStyles`：A 简短接话（≤15 字、口语、不写动作）、
  B 情绪互动（关心/玩笑/撒娇，可稍长）、C 推进剧情（主动行动或提问）。
- `appendSuggestionInstruction(messages, {int styleIndex = 0})`：指令后追加对应风格要求，
  越界按取模；同一批三条各用一种风格，避免三条意思雷同。
- `normalizeSuggestions`：完全一致或**高度相似**（长度比 ≥0.6 且字符二元组 Jaccard ≥0.7；
  短句 <6 字符只按完全相同判定）时只保留第一条。
- `chat_screen._suggestReplies` 改为逐条按 `styleIndex: i` 组装 messages。

### 2) 建议条出现时气泡不被遮挡（lib/screens/chat_screen.dart）

- 新增 `_keepBottomVisible()`（仅在 `_followScroll` 为真时 `_scrollToBottom()`）；
  `_suggestReplies` 在「开始生成（行内 loading）」和「建议列表渲染完成」后各调用一次，
  输入栏变高导致的视口收缩会自动重新贴底。

### 3) 顶部上下文占用条（lib/screens/chat_screen.dart）

- 新增 `_buildContextBar(scheme)`：AppBar 下方一行 —— `Icons.data_usage` + 「上下文」+
  `LinearProgressIndicator` + 百分比 + `3,069/65,536`；超过预算（`overContextBudget`）转错误色；
  点按打开原有「上下文占用」明细弹窗（系统/世界书/摘要/历史 + 合计 + 上次实际）。
- `_ctxBarTokens()` 带缓存（消息条数 / 末条长度 / 摘要 / 记忆条数变化才重算），口径与明细弹窗一致。
- 窗口未设置（`AppSettings.contextWindow == 0`）或对话未就绪时整条不渲染。
- 真机确认：聊天页顶部显示「上下文 5% 3,069/65,536」。

### 测试

- `test/v12_test.dart` 新增 4 例：三风格指令互不相同、styleIndex 取模、相似长句去重、短句只按完全相同去重。

## 仓库状态

- 分支 `dev`，远端 `origin = https://github.com/Alorith-H/LiteTavern.git`
- `pubspec.yaml:5` → `version: 0.14.3+11`；`lib/app_info.dart` → `kAppVersion = '0.14.3'`
  （`test/version_test.dart` 校验两者一致，防漂移）
- 产物：`build\app\outputs\flutter-apk\app-release.apk`（58.1 MB，
  `build\app\outputs\apk\release\output-metadata.json` versionCode 10 / versionName 0.14.2）
- 装机：**已安装**到真机 `23113RKC6C`（`dumpsys` 确认 versionCode=10 / versionName=0.14.2，
  `am start` 正常，主页 6 个角色数据完好）

## 功能一：建议回复纵向完整展示

- `lib/widgets/reply_suggestions_bar.dart` 重写：标题行「建议回复」+ ✨ + 「换一批」；
  每条建议**整行平铺、不设 maxLines**（长文本换行完整显示），
  `ConstrainedBox(maxHeight: min(240, 屏高*0.32))` 内可滚动；
  加载态「生成中…」+ 12x12 spinner 且禁用点击；空且非 loading 时完全不占位。
- 仍只在**单聊**、开关「设置 → 生成参数 → 自动生成回复」打开时出现；
  点一条直接作为用户消息发出；发新消息 / 停止 / 重新生成即作废旧建议。
- 测试：`test/reply_suggestions_bar_test.dart` 9 例（纵向顺序、无横向滚动、不截断、点选/换一批/loading/空态）。

## 功能二：角色卡翻译（编辑页）

- 入口：编辑角色页 AppBar `Icons.translate`（draft 与已入库都有）→
  `lib/widgets/card_translation_sheet.dart` 底部弹层：
  逐段「原文（浅色、最多 6 行可展开）↔ 译文」对照（名字/简介/性格/场景/开场白/示例对话/标签），
  标题下显示「译者：xxx · 时间：MM-dd HH:mm」。
- 翻译策略（`lib/services/translator.dart`）：
  **MyMemory 免费优先**（`api.mymemory.translated.net`，自动识别语言，单次 ≤500 字符自动切段，
  全站匿名额度约 5k 字符/天）→ 失败自动换 **Google 免费端点**（常被限流）；
  两者全挂抛 `TranslationUnavailable`，弹层弹「免费翻译暂不可用」，
  用 `CardLocalizer.estimateTokens(card)` 报「预计约 N tokens」，
  用户确认后才用**设置中的模型**翻译（`LlmTranslationProvider`，走 `ApiClient` 非流式、temperature 0.2）。
- 「应用到角色卡」只回填表单（不自动保存，需点编辑页「保存」）；
  「恢复原文」读翻译前备份回填；译文与原文备份存 `TranslationStore`。
- 其它失败：弹层内红色错误条 + 主按钮变「重试」。
- 内核文件：`lib/services/translator.dart`（`looksChinese` / `splitForTranslation` /
  `TranslationService` / `MyMemoryProvider` / `GoogleFreeProvider` / `LlmTranslationProvider`）、
  `lib/services/card_localizer.dart`（`localize` / `estimateTokens`）、
  `lib/services/translation_store.dart`（key：`card_translations` / `card_originals` / `market_translations`）、
  `lib/models/card_translation.dart`。
- 测试：`test/translation_test.dart` 21 例（分词/实体反转义/额度/换源记忆/LLM 兜底/存储往返/淘汰/坏 JSON/本地化）。

## 功能三：市场筛选补齐 Chub 全部条件

- 搜索框右侧「筛选」按钮（带激活条件数 badge），底部弹层分组：
  - **排序** 6 种：相关（不传 sort）/ 热门（`star_count`）/ 新上架（`created_at`）/
    最新趋势（`trending`）/ 随机（`random`）/ 名称（`name`）；空关键词仍兜底热门；
  - **标签**：点开二级弹层，`fetchTags()` 拉 Chub 标签目录（`POST api.chub.ai/tags`，
    失败自动回落 45 个内置标签），可搜索、可多选（**最多 8**，服务端多标签为 AND），
    也支持手动输入（中英文逗号/顿号/分号）；
  - **排除标签**（`exclude_tags`，输入式，最多 8）；
  - **语言**：全部 / 中文 / 英文 / 日文 / 韩文；
  - **长度**：不限 / 短(<1k) / 中(1k–3k) / 长(>3k)，另有自定义 min/max 数字框；
  - **最少标签数** 0–5；**高级开关**：需要有图 / 需要有世界书 / 需要有表情。
  - 底部「重置 / 应用」；应用后回第 1 页并沿用 `_seq` 竞态。
- 服务层：`card_market.dart` 的 `MarketFilters`（sort/ascending/tags/excludeTags/language/
  minTokens/maxTokens/minTags/requireImages/requireLore/requireExpressions、`parseTags`、
  `copyWith` 支持传 null 清空、`==`）、`MarketTag{name,count}`、`fetchTags`、
  `ChubSource.searchUri` 参数映射；`test/card_market_test.dart` 34 例（全离线 MockClient）。

## 功能四：市场列表「原文 + 译文」

- 结果改为**单列纵向列表**：封面 64x86 + 原名 + 译名（次要色）+ 简介（译优先，最多 3 行）+
  标签 chips（译优先，最多 4 个 + “+N”）+ meta（作者 · ★ 星数 · 对话数）。
- 打开页面/翻页后只**读本地译文缓存**（`MarketTranslationService.cached`，不发网络）；
  每行「译」按钮点了才真正翻译（免费优先），翻译中行内 14x14 spinner；
  免费失败 → 弹「免费翻译暂不可用」+「预计约 N tokens」（`estimateTokensFor([card])`），
  确认后用模型翻译；译文缓存上限 400 条（超出按 updatedAt 淘汰到 200）。

## 功能五：下载非中文卡 → 询问是否翻译

- 市场详情「下载并导入」后，若 `!looksChinese('${card.name} ${card.description}')` 弹
  「这张角色卡不是中文」：**免费翻译（默认）/ 用模型翻译（≈N tokens）/ 不翻译**。
- 免费失败再弹报价确认 → 模型；本地化成功覆盖保存同 id 角色卡后返回导入成功；
  任何翻译失败都**回落原卡、不阻断导入**（toast 提示）。

## 验证表（2026-11-19）

| 项 | 命令 | 结果 |
|---|---|---|
| 静态检查 | `flutter analyze` | **No issues found!**（3.2s） |
| 单元/组件测试 | `flutter test` | **+208 All tests passed!** |
| Release 构建 | `flutter build apk --release` | 成功，58.2 MB，versionCode 10 / 0.14.2 |
| 装机 | `adb install -r ...apk` | **Success**，`am start` 正常 |

命令环境：`C:\flutter\bin\flutter.bat`（不在 PATH），每次先设
`$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`；
adb 在 `C:\Users\28351\Android\Sdk\platform-tools\adb.exe`（不在 PATH）。

## 真机自测清单（建议按序走）

1. 打开任一单聊 → 设置里开启「自动生成回复」→ 发一句 → AI 回复后输入框上方出现纵向建议卡，
   长建议完整换行；点一条直接发出；点「换一批」换新建议。
2. 编辑任一角色 → 右上「翻译」→ 免费翻译；断开免费源（或额度耗尽）时应弹带 token 报价的确认框。
3. 应用译文 → 保存；再开翻译弹层可「恢复原文」。
4. 市场页：筛选 → 排序/标签（含手动输入）/排除标签/语言/长度/最少标签/高级开关；
   列表显示原名+译名、简介与标签译文；点「译」按需翻译。
5. 市场下载一张英文卡 → 应询问是否翻译（免费 / 模型约 N tokens / 不翻译）。
6. 回归：群聊正常流式回复；继续生成正常；删除会话不残留后台任务。

## 已知边界（记录，不作为 bug）

- 免费翻译只有 MyMemory 稳定可用，匿名额度约 5k 字符/天、单次 500 字符；
  Google 免费端点常 429。额度耗尽会走「模型报价确认」流程。
- 标签是「整串翻译后按标点拆回」，个别标签可能保留原文（真实 API 通常能整体译好）。
- 建议回复仍是模型生成，偶有口吻偏差；开启后每次 AI 回复额外消耗 3 次请求的 token。
- 建议回复仅单聊；离开会话页会取消进行中的建议请求（页面私有，不进 `ActiveGenerations`）。
- 市场列表译文只读缓存，未缓存的卡需要手动点「译」（避免整页刷请求）。
- v0.11 之前遗留：后台完成不续跑自动继续（S3）、创建器「生成角色卡」仍页面私有请求（S4）、
  删除会话先 remove 再异步落库的极小交错窗口（B2）、管理器落库不带变体记账（B3）。
- 无自动化覆盖：市场标签二级弹层 / 排除标签 / 自定义长度 / require_* 控件 / 导入→本地化整链
  （仅代码走查 + teammate 一次性冒烟，已删临时文件）。编辑页端到端 widget 测试受真实文件 IO 限制未做。

## 主要文件索引

| 文件 | 作用 |
|---|---|
| `lib/services/translator.dart` | 免费/模型翻译源、切段、中文检测、报价 |
| `lib/services/card_localizer.dart` | 整卡翻译、原文备份、token 估算 |
| `lib/services/market_translation.dart` | 市场条目译文编排与缓存 |
| `lib/services/translation_store.dart` | 译文/原文持久化与淘汰 |
| `lib/widgets/card_translation_sheet.dart` | 编辑页翻译弹层 |
| `lib/widgets/reply_suggestions_bar.dart` | 纵向建议回复条 |
| `lib/services/card_market.dart` | Chub 搜索/筛选/标签目录 |
| `lib/screens/card_market_screen.dart` | 市场页（单列、筛选、译文、导入询问） |
| `lib/screens/chat_screen.dart` | 建议回复生成/发送、流式聊天主流程 |
| `lib/services/reply_suggestions.dart` | 建议元指令与文本归一化 |
