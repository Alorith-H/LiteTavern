# 交接状态：v0.18.1 体验修复（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.0（5 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话）、
> v0.15.1（角色卡市场 NSFW 开关，默认关）、
> v0.16.0（用户人设 Persona、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）。
>
> **本轮 v0.18.0**（已发布）：
> ① **输入栏辅助二选一**（建议回复 / 替我说一句 / 都关闭，三选一；关掉后按钮不显示）；
> ② **新手引导扩到 6 步**（新增「选一种顺手的方式」，新手选型提示置顶，新增「自定义接口」）；
> ③ **自动摘要后台静默执行**（不再显示「正在总结早期对话…」）；
> ④ **明确自动摘要的 token 开销**（设置标注 + 「自动摘要怎么工作」说明页）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.18.1+17**，`lib/app_info.dart` `kAppVersion = '0.18.1'`。
- 改动文件：`lib/services/storage.dart`（`AssistMode` + `assistMode` 设置）、
  `lib/screens/settings_screen.dart`、`lib/screens/chat_screen.dart`、
  `lib/screens/onboarding_screen.dart`、`test/v12_test.dart`、`test/onboarding_screen_test.dart`、
  `CHANGELOG.md`、`RESUME_STATE.md`。

## 本轮变更（v0.18.0）

### 1. 输入栏辅助方式三选一

- `lib/services/storage.dart` 新增顶层 `enum AssistMode { suggestions, impersonate, off }`：
  `fromLegacy(bool)`、`label`（生成建议回复 / 替我说一句 / 都关闭）、`summary`（含 token 提示）。
- `AppSettings.assistMode` 读写 prefs 键 `assist_mode`；非法/缺失时回退旧键
  `auto_reply_candidates` 的布尔语义（true → suggestions，false/缺失 → off）。
  `autoReplyCandidates` 保留为兼容别名。
- `lib/screens/settings_screen.dart`：「聊天」分节里把原「自动生成回复」开关换成
  「输入栏辅助按钮」三选一 `SegmentedButton<AssistMode>` + 当前模式说明；
  显式写明「两者只能二选一；选都关闭则输入栏左侧不显示按钮」。
- `lib/screens/chat_screen.dart`：
  - 输入栏左侧按钮按模式渲染：suggestions → ✨「生成建议回复」；impersonate → 「替我说一句」；
    off → 两个都不显示（v0.18.0 之前替我说一句是常驻）。
  - `_maybeSuggestReplies` 与建议条渲染都加了 `assistMode == AssistMode.suggestions` 门禁，
    避免「选了替我说一句还在后台跑三次建议请求」。

### 2. 自动摘要后台静默执行

- 删除聊天页的摘要进度块（原 spinner + 「正在总结早期对话…」+ 帮助按钮 + 跳过），
  以及 `_summarizeReason / _summarizeEarlyCount / _summarizeEstimatedTokens`、
  `_showSummaryWhy()`。自动摘要现在不显示任何提示。
- `_summarizing` 布尔保留：用于发送门禁；摘要期间发送钮显示为红色停止钮，仍可 `_cancelSummarize()` 打断。
- 摘要完成后照旧把 `ChatSummary` 存进会话，并在下一条请求里替换早期原文（模型侧不可见差异）。

### 3. 说明「自动摘要会花 token」

- 设置里「长对话自动摘要」副标题：「对话太长时把早期内容压成摘要，后台静默执行（会额外调用一次模型、消耗 token）」。
- 新增「自动摘要怎么工作」说明弹窗（`_showSummaryExplain`），5 段：
  触发条件（超过记忆长度 / 上下文超 90%）、不是额度不够、会消耗 token（独立小请求，通常几千 token，
  只在触发那次）、本机记录不删改、怎么关/怎么手动触发。
- 结论口径：**会消耗 token**，因为摘要是额外一次模型调用（输入早期对话、输出摘要），按服务商价格计费。

### 4. 新手指引完善（5 → 6 步）

- `lib/screens/onboarding_screen.dart`：`_totalSteps = 6`，`_primaryLabels` 同步；
  第 4 步新增 `_buildAssistMode()`（三张 `_assistCard`，点选即写入 `AppSettings.assistMode`），
  同时科普自动摘要会额外花 token、后台无提示、可在设置关。
- 第 2 步「新手怎么选、要注意什么」提示从底部**移到最上面**（标题之后、lead 之前）。
- 第 2 步末尾新增 `_customProviderCard()`「自定义接口（进阶）」：任何 OpenAI 兼容服务都能接，
  点「用自定义接口」清空地址/模型并直接翻到第 3 步填写。
- 第 6 步（完成页）说明按所选模式动态显示「左侧那个帮手按钮」的作用，并补「长对话会自动摘要」。

## 本轮修复（v0.18.1）

1. **聊天菜单滚不动 → 书签被挤到屏幕外**：`chat_screen.dart` 的 `_showMenu()`
   改为 `isScrollControlled: true` + `SafeArea > ConstrainedBox(maxHeight: 屏高 * 0.72) >
   SingleChildScrollView > Column`，菜单项再多也能滚到；顺带加了 `showDragHandle`。
2. **建议回复出现慢**：`_suggestReplies()` 改为三条并行 + 谁先回就先显示（`unawaited(...).then`，
   `_suggesting` 直到最后一条回来才关）；新增 `_buildSuggestionMessages()`
   （只发 system + 最近 10 条，不再整段世界书/摘要/全历史）与 `_suggestionMaxTokens`
   （单条上限 240 token），显著缩短等待。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found!**（6.6s，v0.18.1 修复后） |
| `flutter test` | **+273 All tests passed!**（9s，v0.18.1 修复后） |
| `flutter build apk --release` | 见「本次运行记录」 |
| 装机 | 见「本次运行记录」 |
| 真机自测 | 见下「真机自测清单」 |

## 真机自测清单（v0.18.1）

1. 聊天页 ⋮ 菜单：往下滚，确认「书签」「作者注释」等靠后的项都能看到并点到（小屏必须验证）。
2. 选「生成建议回复」后发一条消息：AI 回复完应立刻出现「生成中…」，并且三条建议陆续出现（不用等全部）。
3. 设置 → 聊天 → 输入栏辅助按钮：三种模式切换后左侧按钮随之出现/消失。
4. 设置里「长对话自动摘要」带有「会消耗 token」说明，点「自动摘要怎么工作」能打开弹窗。
5. 新手指引为 6 步，第 2 步新手提示在服务商列表上面，第 4 步可三选一。

## 已知边界

- `assistMode` 默认值为 off（沿用旧版「自动生成回复默认关」）；从旧版本升级时读取 `auto_reply_candidates` 迁移一次。
- 自动摘要静默执行意味着：长对话首次发送会有一次不易察觉的额外等待；可用发送钮的停止态打断。
- 摘要的 token 估算按字符折算，仅用于说明，不精确记账。
- 引导页第 5 步从市场返回即完成引导；外链/跳转未纳入单测（无平台通道 mock）。

## 环境与常用命令

- Flutter：`C:\flutter\bin\flutter.bat`（不在 PATH）；先设
  `$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`。
- 构建：`flutter build apk --release` → `build\app\outputs\flutter-apk\app-release.apk`。
- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`；真机 23113RKC6C（Android 16，1440×3200）。
  无线调试最近可用地址：`192.168.0.102:42543`（会变，用 `adb connect` 重连）。
- 真机点按用**视觉坐标**（uiautomator bounds 常与视觉位置不符）。

## 本次运行记录（由本轮执行后填写）

- `flutter analyze`：No issues found!（6.6s）
- `flutter test`：+273 All tests passed!（9s）
- `flutter build apk --release`：59.0MB（Gradle 41.1s），versionCode **17** / versionName **0.18.1**
- 装机：`adb -s 192.168.0.102:42543 install -r` → **Success**；
  dumpsys 确认 versionCode 17 / versionName 0.18.1 / lastUpdateTime 2026-11-22 21:20:49。
- 真机抽查：⋮ 菜单已可滚动，`书签` / `作者注释` / `继续生成` / `重新生成` / `立即总结早期对话` 都能看到并点到
  （截图 `build\v181_menu.png`、`build\v181_menu2.png`）；数据保留。
