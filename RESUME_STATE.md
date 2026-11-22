# 交接状态：v0.20.0 模型配置与上下文长度改造（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.0（5 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话）、
> v0.15.1（角色卡市场 NSFW 开关，默认关）、
> v0.16.0（用户人设 Persona、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）、
> v0.18.x（输入栏辅助三选一、6 步新手引导、自动摘要后台静默 + token 说明、菜单可滚动、建议回复并行提速）、
> v0.19.0（翻译接入必应：Azure Key + 网页版兜底）。
>
> **本轮 v0.20.0**（已发布）：
> ① **智谱 GLM-4-Flash（免费）**加入预设并排在新手指引第 2 步第一位（「免费」徽章）；
> ② **上下文长度跟模型配置走**：模型服务 → 编辑配置 新增「上下文长度（token）」，留空 = 按模型自动
>   （GLM-4 系列 128K、DeepSeek 64K、Kimi 128K、Gemini 1M…），也可手填覆盖；配置列表直接显示大小；
> ③ **获取模型列表**：编辑配置 / 引导第 3 步点按钮从 `GET /models` 拉回可选模型，点一个自动填；
> ④ 设置页全局「上下文窗口」输入框移除，改成一行说明（点进去即到模型服务）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.20.0+19**，`lib/app_info.dart` `kAppVersion = '0.20.0'`。
- v0.20.0 改动文件：`lib/services/api_presets.dart`（`free` / `contextWindow` / `contextWindowForModel` /
  `formatContextWindow`、GLM-4-Flash 置顶）、`lib/services/storage.dart`（`ApiConfig.contextWindow`、
  `AppSettings.contextWindow` 改为按配置/模型计算、旧全局键清理）、`lib/services/api_client.dart`
  （`fetchModels` / `extractModelIds`）、`lib/screens/api_config_screen.dart`（上下文长度输入 +
  「获取模型列表」+ `_ModelPickerSheet` + 列表行显示上下文）、`lib/screens/onboarding_screen.dart`
  （第 2 步免费徽章/动态家数、第 3 步获取模型列表 + 上下文提示、`_ModelListSheet`）、
  `lib/screens/settings_screen.dart`（上下文窗口改说明行）、`test/v20_test.dart`（新增 17 例）、
  `test/v12_test.dart`（上下文测试改为按模型自动）、`test/onboarding_screen_test.dart`（家数动态）、
  `CHANGELOG.md`、`RESUME_STATE.md`。
- v0.19.0 改动文件：`lib/services/translator.dart`（两个必应 Provider + 默认源顺序）、
  `lib/services/storage.dart`（`azureTranslatorKey` / `azureTranslatorRegion`）、
  `lib/screens/settings_screen.dart`（「翻译」分节）、`lib/widgets/card_translation_sheet.dart`（文案）、
  `test/translation_test.dart`、`test/v19_test.dart`、`README.md`。
- v0.18.x 改动文件：`lib/services/storage.dart`（`AssistMode` + `assistMode`）、
  `lib/screens/settings_screen.dart`、`lib/screens/chat_screen.dart`、
  `lib/screens/onboarding_screen.dart`、`test/v12_test.dart`、`test/onboarding_screen_test.dart`。


## 本轮变更（v0.20.0）

### 1. 智谱 GLM-4-Flash（免费）置顶

- `lib/services/api_presets.dart`：`ApiPreset` 新增 `free` 与 `contextWindow` 两个字段；
  `kApiPresets` 顺序改为 **GLM-4-Flash（free: true，128K）** → GLM-4-Air（128K）→ DeepSeek（64K）
  → Kimi moonshot-v1-8k（8K）→ 小米 MiMo（64K）→ Ollama（32K）。
- 新手引导第 2 步按预设顺序渲染，GLM-4-Flash 第一张卡带「免费」徽章；「下面 5 家」改成按
  `kApiPresets.length` 动态显示。

### 2. 上下文长度跟着模型配置走

- `ApiConfig` 新增 `contextWindow`（默认 **0 = 按模型自动**），参与 `toJson` / `fromJson` / `copyWith`。
- `AppSettings.contextWindow` 改为：配置里 > 0 就用配置值，否则 `contextWindowForModel(当前模型)`；
  setter 写回**当前激活配置**，不再有全局键；`_migrateContextWindow1M()` 只负责清掉旧全局键。
- 设置页「模型上下文窗口」由输入框改为说明行（显示当前值 + 「在 设置 → 模型服务 → 编辑配置 里改」，
  点按直达模型服务页）。
- 模型服务编辑页新增「上下文长度（token）」输入框：留空 = 自动（hint 显示自动值），手填则覆盖；
  右侧 `autorenew` 按钮一键改回自动；预设 chip 会带上该预置的上下文长度。
- 模型服务列表每行副标题显示「模型 · 上下文 128K（自动）」这一类信息。

### 3. 获取模型列表

- `ApiClient.fetchModels({baseUrl, apiKey})`：`GET {baseUrl}/models`，20s 超时，非 200 走中文错误映射；
  `ApiClient.extractModelIds(body)` 兼容 `{data:[{id}]}`、`{models:[]}`、`{items:[]}`、`{list:[]}`、纯数组，
  元素支持 `id` / `name` / `model`，去重排序。
- 编辑配置页与引导第 3 步都有「获取模型列表」按钮：弹底部列表（带搜索），点一个即填入「模型名」。

## 历史变更（v0.19.0）

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

## 历史修复（v0.18.1）

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
| `flutter analyze` | **No issues found!**（6.7s，v0.20.0） |
| `flutter test` | **+300 All tests passed!**（7s，v0.20.0，其中 test/v20_test.dart 17 例） |
| `flutter build apk --release` | 59.3MB（Gradle 48.3s），versionCode **19** / versionName **0.20.0** |
| 装机 | **Success**（versionCode 19 / 0.20.0 / 2026-11-22 22:02:20，数据保留） |
| 真机自测 | 见下「真机自测清单」 |

## 真机自测清单（v0.20.0）

1. 设置页：原「上下文窗口」输入框已变成说明行「当前 64K（按模型自动）· 在 设置 → 模型服务 → 编辑配置 里改」
   （已真机确认渲染，截图 `build\v200_settings.png`）。
2. 设置 → 模型服务 → 编辑配置：可见「获取模型列表」按钮与「上下文长度（token）」输入框；
   留空时 hint 显示自动值，手填后出现 `autorenew` 复位按钮。
3. 点「获取模型列表」：能拉到当前 Key 可用的模型（接口不支持会明确提示），点选后模型名被填入。
4. 换模型（如 deepseek-chat → glm-4-flash）后回到设置：上下文自动值跟着变（64K → 128K）。
5. 全新安装/重看引导：第 2 步第一张卡是「智谱 GLM-4-Flash」且带「免费」徽章；
   第 3 步能「获取模型列表」，下方提示上下文自动值。

## 已知边界

- 上下文长度「自动」是按模型名规则推断（见 `contextWindowForModel`），不是真的问服务商；
  特殊私有模型名会回落到 64K，可在配置里手填。
- 「获取模型列表」依赖服务商支持 `GET /models`；不支持时给出中文提示，不影响手动填模型名。
- 设置 0 仍保留旧语义「关闭占用%与自动压缩」，但 UI 上留空 = 自动，只有手填 0 才会关。
- 必应网页版接口按 IP/风控返回 `ShowCaptcha`，属正常现象：自动换源，不会卡住流程。
- Azure 翻译 Key 存在本机 SharedPreferences，明文（与 API Key 同等处理）；免费层每月 200 万字符。
- `assistMode` 默认值为 off（沿用旧版「自动生成回复默认关」）；从旧版本升级时读取 `auto_reply_candidates` 迁移一次。
- 自动摘要静默执行意味着：长对话首次发送会有一次不易察觉的额外等待；可用发送钮的停止态打断。
- 引导页第 5 步从市场返回即完成引导；外链/跳转未纳入单测（无平台通道 mock）。



## 环境与常用命令

- Flutter：`C:\flutter\bin\flutter.bat`（不在 PATH）；先设
  `$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`。
- 构建：`flutter build apk --release` → `build\app\outputs\flutter-apk\app-release.apk`。
- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`；真机 23113RKC6C（Android 16，1440×3200）。
  无线调试最近可用地址：`192.168.0.102:42543`（会变，用 `adb connect` 重连）。
- 真机点按用**视觉坐标**（uiautomator bounds 常与视觉位置不符）。

## 本次运行记录（v0.20.0）

- `flutter analyze`：No issues found!（6.7s）
- `flutter test`：+300 All tests passed!（7s）
- `flutter build apk --release`：59.3MB（Gradle 48.3s），versionCode **19** / versionName **0.20.0**
- 装机：`adb -s 192.168.0.102:42543 install -r` → **Success**；
  dumpsys 确认 versionCode 19 / versionName 0.20.0 / lastUpdateTime 2026-11-22 22:02:20，数据保留。
- 真机抽查：启动正常（2 个角色在）；设置页「模型上下文窗口」说明行渲染正常
  （截图 `build\v200_device_home.png`、`build\v200_models.png`）。
  编辑配置页因无线调试端口变化（`192.168.0.102:42543` 报 10061/offline）未继续点验，
  下次连上后按上面「真机自测清单」第 2–4 条补验。


