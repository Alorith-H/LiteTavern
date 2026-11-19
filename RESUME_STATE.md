# 交接状态：v0.12.1 市场筛选 + 用户侧建议回复（2026-11-19 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 三候选）均已落地。
> **本轮 v0.12.1**：按用户澄清修正「自动生成回复」的语义 —— 生成的是**用户自己**
> 要发出去的话（不是 AI 的回复），挑一条即作为用户消息发出；市场筛选沿用 v0.12.0。
> analyze 清零、测试 158 条全过、release APK 构建成功（57.7 MB）。

## 仓库状态

- 分支 `dev`，远端 `origin = https://github.com/Alorith-H/LiteTavern.git`
- `pubspec.yaml:5` → `version: 0.12.1+4`；`lib/app_info.dart` → `kAppVersion = '0.12.1'`
  （`test/version_test.dart` 校验两者一致，防漂移）
- 产物：`build\app\outputs\flutter-apk\app-release.apk`（57.7 MB，
  `build\app\outputs\apk\release\output-metadata.json` versionCode 4 / versionName 0.12.1）
- 装机状态：**本次未安装**（构建时手机未连接，`adb devices` 为空）。
  设备重新插上后执行：
  `adb install -r build\app\outputs\flutter-apk\app-release.apk`（仍为覆盖安装，数据保留）

## v0.12.0 功能一：角色卡市场筛选（沿用）

- 主页 FAB「导入」→「角色卡市场」→ 搜索框下方**横向筛选行**
- 排序 ChoiceChip：**相关**（默认，不传 `sort`）/ **热门**（`sort=star_count`）/
  **新上架**（`sort=created_at`）；空关键词仍兜底热门
- 「标签」：中英文逗号分隔、去空去重、最多 3 个（服务端多标签为 **AND**），chip 回显
- 「长度」：不限 / 短（<1k）/ 中（1k–3k）/ 长（>3k tokens）→ `min_tokens` / `max_tokens`
- 筛选变化 → 回第 1 页并沿用 `_seq` 竞态；有筛选时出现「清除」；空态文案区分有/无筛选
- 代码：`card_market.dart` 的 `MarketFilters`（`sort`/`topics`/`minTokens`/`maxTokens`、
  `none`、`isEmpty`、`parseTopics`、`copyWith` 用 `_unset` 哨兵支持清空、`==`/`hashCode`），
  `searchUri`/`search` 增加 `filters` 默认参数（旧调用零改动）；
  `test/card_market_test.dart` 22 例（全离线 MockClient）

## v0.12.1 功能二：自动生成「用户侧」回复（本轮修正）

- 设置：`设置 → 生成参数`，在「流式传输」下方 **自动生成回复** 开关（默认关），
  副标题「单聊生效：AI 回复后自动给出 3 条你可发送的话，点选即发出」；
  持久化键 `auto_reply_candidates`（`AppSettings.autoReplyCandidates`）
- 触发：① 单聊每次 AI 回复成功后自动请求一批（`_finishGeneration` →
  `_maybeSuggestReplies`）；② 输入栏左侧 ✨ 按钮手动触发 / 换一批（开关打开才显示）
- 生成方式：以当前对话 prompt 为底，末尾追加元指令 `kSuggestionInstruction`
  （明确要求「只扮演用户这一方、只输出这句话本身」），并行发 **3 个非流式请求**
  （每条独立 `ApiClient`；seed 非空时按 `seed + 0/1/2` 偏移，见
  `SamplingParams.forCandidate`），返回后 `normalizeSuggestion(s)` 清洗
  （去空白/前缀/成对引号、换行压单行、去重）
- 呈现：输入框上方「建议回复」条（`lib/widgets/reply_suggestions_bar.dart`）：
  每条一个 ✨ ActionChip（单行省略、最宽 240）、点按**直接作为用户消息发出**；
  末尾「换一批」；生成中显示行内 spinner + 「生成中…」并禁用
- 边界：只对单聊生效（群聊轮转不受影响）；建议失败静默（少一条不报错）；
  发新消息 / 停止 / 重新生成会作废旧建议；建议请求是页面私有请求，
  离开会话页即释放，不进 `ActiveGenerations`
- 代码：新增 `lib/services/reply_suggestions.dart`
  （`kSuggestionInstruction` / `appendSuggestionInstruction` / `normalizeSuggestion` /
  `normalizeSuggestions`）、`lib/widgets/reply_suggestions_bar.dart`；
  `chat_screen.dart` 新增 `_suggestReplies` / `_fetchOneSuggestion` /
  `_sendSuggestion` / `_clearSuggestions` / `_maybeSuggestReplies` 与
  `_suggestClients` / `_suggestions` / `_suggesting` / `_suggestSeq` 状态；
  **移除了 v0.12.0 的 AI 候选实现**（`reply_candidates_sheet.dart`、
  `_generateCandidatesSingle` 等，已删除）
- 测试：`test/v12_test.dart` 14 例（`forCandidate` 偏移、设置持久化/旧数据回落、
  指令追加、文本清洗与去重）、`test/reply_suggestions_bar_test.dart` 9 例（渲染/点选/
  换一批/loading 禁用/空态/超长不溢出）

## 验证结果（本机实测，2026-11-19）

| 项目 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | **No issues found!** |
| 单元/组件测试 | `flutter test` | **+158 All tests passed!** |
| Release 构建 | `flutter build apk --release` | **成功**，57.7 MB，81.6s |
| 装机 | `adb install -r` | **未执行**：构建时无设备连接 |

构建仅有两类非阻塞警告：`share_plus` 使用 KGP（未来 Flutter 会拒绝，届时升级插件）；
NDK 版本不匹配（`android/app/build.gradle.kts:19` 写 27.0.12077973，插件建议
28.2.13676358，不影响构建；要消除就改这行并确保对应 NDK 已安装）。

## 真机自测建议（装上新包后）

1. 设置 → 生成参数 → 打开「自动生成回复」→ 回单聊发一条消息，AI 回复后输入框
   上方应出现 3 条带 ✨ 的建议；点一条 → 该句作为**自己的消息**发出，AI 继续回复
2. 点「换一批」→ 建议刷新；生成中显示「生成中…」且不可点
3. 关掉开关 → 建议条与 ✨ 按钮消失，行为回到 v0.11
4. 市场筛选：进入市场 → 热门/新上架/标签（`Fantasy,OC`）/长度 中 → 结果收窄、
   chip 回显、清除恢复
5. 回归：群聊轮转、继续生成、停止、后台生成（退出会话再进）均不受影响

## 已知边界（有意保留，不阻塞发布）

- **建议是「用户侧口吻」的引导，模型偶尔可能仍以角色口吻输出**：属于提示词层面的
  概率问题，可在设置里关掉；未做强制校验
- **建议消耗额外 token**：每次自动/手动生成一批 = 3 个完整请求（预期行为）
- **离开会话页会丢弃本次建议请求**：与普通流式回复不同（后者可在后台完成落库）
- **S3 自动继续不跨页面**（v0.10 遗留）：离开页面后完成的消息会落库，但自动继续
  /群聊轮转的后续链条不续跑
- **S4 创建器「生成角色卡」仍是页面私有请求**：中途退出会取消该请求
- **S5/S6 纯 UI 细节**：预设名显示在分区标题下；top_k/stop 超范围时存裁剪值、框内文本不回写
- **B2/B3 低风险竞态**：停止后立刻重生成时旧任务收尾写盘可能交错（`fromJson` 有自愈）

## 环境

- Flutter 3.47.6 stable：`C:\flutter\bin\flutter.bat`（不在 PATH；`dart` 同样不在）
- 跑任何 flutter 命令前设：`$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`
- Android SDK：`C:/Users/28351/Android/Sdk`；adb 绝对路径
  `C:\Users\28351\Android\Sdk\platform-tools\adb.exe`（不在 PATH）
- 测试真机：`23113RKC6C`（Android 16 / API 36，arm64），需插 USB 后 `adb devices` 能看到
- 角色卡来源与合规说明：`docs/card_market_sources.md`
