# 交接状态：v0.19.0 翻译接入必应（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.0（5 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话）、
> v0.15.1（角色卡市场 NSFW 开关，默认关）、
> v0.16.0（用户人设 Persona、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）、
> v0.18.0（输入栏辅助三选一、6 步新手引导、自动摘要后台静默 + token 说明）、
> v0.18.1（菜单可滚动、建议回复并行提速）。
>
> **本轮 v0.19.0**（已发布）：
> ① **翻译接入必应**：新增 `AzureBingProvider`（用户自己的 Azure 翻译 Key，引擎即必应，免费层每月 200 万字符）
> 与 `BingWebProvider`（网页版免 Key、best-effort）；默认顺序 必应（Azure）→ 必应网页 → MyMemory → Google；
> ② **设置 → 翻译**：Key / 区域两个输入框 + 「去申请必应（Azure）翻译 Key」外链；
> ③ 必应网页接口被风控时自动换源，不影响使用。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.19.0+18**，`lib/app_info.dart` `kAppVersion = '0.19.0'`。
- v0.19.0 改动文件：`lib/services/translator.dart`（两个必应 Provider + 默认源顺序）、
  `lib/services/storage.dart`（`azureTranslatorKey` / `azureTranslatorRegion`）、
  `lib/screens/settings_screen.dart`（「翻译」分节）、`lib/widgets/card_translation_sheet.dart`（文案）、
  `test/translation_test.dart`、`test/v19_test.dart`（新增）、`CHANGELOG.md`、`README.md`、`RESUME_STATE.md`。
- v0.18.x 改动文件：`lib/services/storage.dart`（`AssistMode` + `assistMode` 设置）、
  `lib/screens/settings_screen.dart`、`lib/screens/chat_screen.dart`、
  `lib/screens/onboarding_screen.dart`、`test/v12_test.dart`、`test/onboarding_screen_test.dart`。


## 本轮变更（v0.19.0）

### 1. 必应翻译（Azure Key）

- `lib/services/translator.dart` 新增 `AzureBingProvider`（id `azure`，label「必应翻译（Azure Key）」）：
  `POST https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&to=zh-Hans`，
  header `Ocp-Apim-Subscription-Key`、可选 `Ocp-Apim-Subscription-Region`，body `[{"Text": …}]`；
  401/403 → quotaExceeded（Key 无效），429 → 额度用尽；长文本按 ≤3000 字符分块。
- Key 留空时立刻抛 `TranslationFailure`，不产生网络请求，由调度器换下一个源。

### 2. 必应网页版（免 Key，best-effort）

- 新增 `BingWebProvider`（id `bing`）：先 `GET https://www.bing.com/translator`，
  用正则取页面里的 `IG:"…"` 与 `params_AbusePreventionHelper = [key,"token",ttl]`，
  再 `POST /ttranslatev3?isVertical=1&&IG=…&IID=translator.5028.1`（表单 `fromLang=auto-detect`、
  `text`、`to=zh-Hans`、`token`、`key`）。
- 令牌静态缓存 45 分钟（`resetCacheForTest()` 供单测清理）；手动跟随 301/302/307/308 且保持 POST。
- **实测限制**：本机网络下该接口返回 `{"ShowCaptcha":false}`（被要求人机验证），
  因此它只作「先试一试」，失败即换 MyMemory；国内移动网络可能可用，不能用也不影响功能。
- 分块上限 900 字符；`zh-CN → zh-Hans`、`zh-TW → zh-Hant`。

### 3. 默认免费源顺序与设置

- `TranslationService` 默认 `freeProviders` = `[AzureBingProvider(), BingWebProvider(),
  MyMemoryProvider(), GoogleFreeProvider()]`（`_preferred` 记忆上次成功的源，跳过高成本试探）。
- 设置页新增「翻译」分节（在「角色卡市场」之后、「聊天」之前）：说明默认顺序 +
  「必应翻译 Key（Azure，可留空）」密码框 + 「区域（可选）」+ 「去申请必应（Azure）翻译 Key」外链；
  `AppSettings.azureTranslatorKey` / `azureTranslatorRegion` 存 prefs（写入 trim，空值删键）。
- 角色卡翻译弹层文案改为「优先使用免费翻译服务（必应 / MyMemory）」。

## 历史变更（v0.18.0）


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
| `flutter analyze` | **No issues found!**（53.6s，v0.19.0，含 pub get） |
| `flutter test` | **+283 All tests passed!**（10s，v0.19.0） |
| `flutter build apk --release` | 59.2MB（Gradle 60.8s），versionCode **18** / versionName **0.19.0** |
| 装机 | **Success**（versionCode 18 / 0.19.0 / 2026-11-22 21:43:26，数据保留） |
| 真机自测 | 见下「真机自测清单」 |

## 真机自测清单（v0.19.0）

1. 设置 → 翻译：显示默认顺序说明、Key 输入框、区域输入框、「去申请 Key」按钮（已真机确认渲染，截图 `build\v190_device_translate2.png`）。
2. 角色卡编辑页点「翻译」→「翻译为中文（免费）」：能出译文（必应被风控时自动换 MyMemory，可能略慢）。
3. 填了 Azure Key 后重复第 2 步：应明显更快、更稳（若 Key 无效会提示并自动换源）。
4. 市场详情页「译」按钮同样走免费源顺序，原文/译文对照正常。
5. 不填 Key 也不影响任何功能（最差回落到 MyMemory）。

## 已知边界

- 必应网页版接口按 IP/风控返回 `ShowCaptcha`，属正常现象：自动换源，不会卡住流程。
- Azure 翻译 Key 存在本机 SharedPreferences，明文（与 API Key 同等处理）；免费层每月 200 万字符。
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

## 本次运行记录（v0.19.0）

- `flutter analyze`：No issues found!（53.6s，首次带 pub get）
- `flutter test`：+283 All tests passed!（10s）
- `flutter build apk --release`：59.2MB（Gradle 60.8s），versionCode **18** / versionName **0.19.0**
- 装机：`adb -s 192.168.0.102:42543 install -r` → **Success**；
  dumpsys 确认 versionCode 18 / versionName 0.19.0 / lastUpdateTime 2026-11-22 21:43:26，数据保留。
- 真机抽查：主页正常（角色 SCP 在）、设置 → 翻译分节完整渲染
  （截图 `build\v190_device_home.png`、`build\v190_device_settings.png`、`build\v190_device_translate2.png`）。

