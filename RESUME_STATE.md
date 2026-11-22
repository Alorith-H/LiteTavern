# 交接状态：v0.15.1 角色卡市场 NSFW 开关（默认不显示）（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用提示、默认 1M 窗口、GitHub 页与首个 Release）。
>
> **本轮 v0.15.1**：设置新增「角色卡市场 → 显示 NSFW 内容」开关（**默认关**）；
> 关闭时市场只请求全年龄（SFW）内容，市场顶部说明随之变化。
>
> 历史 v0.15.0：① 新手引导重写为 **5 步零基础手把手教学**（默认用户什么都不会）；
> ② 配置模型服务新增**「去官网获取 API Key」**（官网 / Key 页 / 文档 + 注册充值步骤，无浏览器降级复制链接）；
> ③ 主页**导入角色卡弹窗改版**（分组标题、说明、市场推荐标记、格式解释）；
> ④ 长对话摘要提示**说人话**：区分两种触发原因、显示条数、新增「为什么？」弹窗，取消改「跳过」。
> 新增依赖 `url_launcher`。analyze 清零、测试 **224 条全过**、release APK 构建成功（58.6 MB / versionCode 12）。
> **装机未完成**：构建时手机不在线（`adb devices` 为空），手机仍停留在 0.14.2 / versionCode 10。

## 本轮变更（v0.15.1）

### 角色卡市场「显示 NSFW 内容」开关（默认关）

- `lib/services/storage.dart`：新增 `AppSettings.showNsfw`（SharedPreferences 键 `show_nsfw`，默认 **false**）。
- `lib/services/card_market.dart`：`CardMarketSource.searchUri` / `ChubSource.searchUri` /
  `CardMarketClient.search` 都新增 `bool showNsfw = false` 参数；`ChubSource` 按它发
  `nsfw=false`（默认，只返回全年龄内容）或 `nsfw=true`（全部内容）。
- `lib/screens/card_market_screen.dart`：`_load()` 每次请求都带 `showNsfw: AppSettings.showNsfw`
  （设置改完重新进入市场即生效，无需重启）；顶部署名行文案随开关变化：
  关 → 「数据来自 Chub.ai · 仅显示全年龄（SFW）内容，可在 设置 → 角色卡市场 打开 NSFW」；
  开 → 「数据来自 Chub.ai · 已显示 NSFW 内容，可在 设置 → 角色卡市场 关闭」。
- `lib/screens/settings_screen.dart`：新增分节「角色卡市场」+ 开关行「显示 NSFW 内容」
  （副标题：默认关闭：市场只显示全年龄内容；打开后包含成人向角色卡）。
- 测试：新增 `test/v16_test.dart` 4 例（默认 false、写入 `show_nsfw` 并读回、显式关掉持久化 false、
  旧数据无键回落 false）；`test/card_market_test.dart` 中 5 处 `nsfw=true` 断言改为默认 `false`，
  并新增 1 例 `showNsfw: true` 映射；`test/card_market_screen_test.dart` 新增 1 例验证页面按设置传参
  并切换说明文案（`_FakeSource` 增加 `showNsfwFlags` 记录）。

## 本轮变更（v0.15.0）

### 1) 新手引导 5 步（lib/screens/onboarding_screen.dart，416 → 1081 行全量重写）

- 顶部「第 X / 5 步」+ 3dp 进度条；右上「跳过」直接进 App；底部「上一步」+ 主按钮。
- **第 1 步 欢迎与准备**：说明这是本地角色扮演聊天 App（角色/对话只存本机）；高亮卡写清
  「LiteTavern 本身不带 AI 模型，需要你自备模型服务的 API Key，按量计费由服务商收取，必须有网络」；
  三步概览（配置模型服务 → 导入角色卡 → 开始聊天）。
- **第 2 步 获取 API Key**：5 张服务商卡（来自 `kApiPresets`）：label、note、等宽 Base URL / 推荐模型，
  每张带「去官网获取 Key」（`showApiKeyHelp`：注册→充值→创建 Key→粘贴 4 步 + 三个链接按钮）
  与「直接打开」（`openExternalLink(keyUrl)`）；Ollama 卡识别为本地模型，按钮改为「去下载 Ollama」。
  底部推荐文案：DeepSeek / 智谱（有免费额度或便宜；智谱需实名）；Ollama 本地跑不要 Key；
  Key 只存本机不要发给别人。
- **第 3 步 填写并测试连接**：5 个 ChoiceChip 预设（只填 Base URL + 模型名，不动已填 Key；
  选中态由 `presetForBaseUrl` 判定）；三输入框各带「从哪抄」helper；「测试连接」中/成功/失败三态；
  失败时展开**常见错误对照卡**：401（Key 错）、404（地址错/少 /v1）、402/余额/quota（未充值）、
  超时/SocketException/Failed host lookup（网络或代理）。离开该步先落盘；没配好只 SnackBar 提醒不阻止前进。
- **第 4 步 导入第一个角色卡**：解释角色卡是 SillyTavern 格式（.png 内嵌设定 / .json，chara_card V2）；
  三入口按推荐序：从角色卡市场导入（推荐，push `CardMarketScreen`，返回即完成引导）/ 从本地文件导入
  （原 FilePicker → CardParser → Storage 保存链路）/ 先跳过进去自己逛。
- **第 5 步 完成**：三条使用说明（点角色进聊天 → 输入框发送；建议回复按钮与「自动生成回复」开关；
  设置里改生成参数/上下文窗口/字号/主题/换模型服务）+ 本地数据提示（卸载会删，重要对话先复制）+
  「想再看一遍：设置 → 帮助 → 重看新手引导」。
- 每页 `SingleChildScrollView`；全部走 Theme `colorScheme`（成功绿 dark `0xFF8FD3A0` / light `0xFF2E7D4F`）；
  三输入框 onChanged 即时 `_saveModelConfig()` 防丢。
- 测试：`test/onboarding_screen_test.dart` 10 例（首屏文案、5 步翻页与主按钮、5 家服务商全列出、
  预设只填 url/model 不动 Key 且落盘、空表单测试连接展示错误对照、未配置离开提示+落盘、
  第 4 步三入口、第 5 步说明、「上一步」、360×520 小屏五步逐页无溢出）。

### 2) 配置页跳官网（lib/services/api_presets.dart + lib/services/external_links.dart + api_config_screen.dart）

- `ApiPreset` 扩展字段：`siteUrl`（官网/控制台）、`keyUrl`（直接创建/复制 Key 的页面）、
  `docsUrl`（文档，可空）、`note`（一句话提示）；5 家地址：
  小米 MiMo `platform.xiaomimimo.com/#/console/api-keys`；DeepSeek `platform.deepseek.com/api_keys`；
  Kimi `platform.kimi.com/console/api-keys`；智谱 `bigmodel.cn/usercenter/proj-mgmt/apikeys`；
  Ollama `ollama.com/download`。新增 `presetForBaseUrl(baseUrl)`（忽略尾部斜杠）。
- `external_links.dart`：
  - `openExternalLink(context, url, {title})` → `launchUrl(..., LaunchMode.externalApplication)`；
    失败/无浏览器 → 弹窗展示地址 + 「复制链接」。
  - `showApiKeyHelp(context, {providerLabel, keyUrl, siteUrl, docsUrl, note})` → 底部帮助层：
    4 步编号说明 + 「打开 API Keys 页面」主按钮 + 「官网首页」「使用文档」次按钮。
  - `showApiKeyProviderPicker(context)` → 不知道自己是哪家时列出全部服务商选择。
- `lib/screens/api_config_screen.dart`（编辑/新建配置）：预设 chips 下方新增
  「去官网获取 API Key」TextButton（按当前地址匹配预设；匹配不到弹服务商选择器），旁边显示该家 note。

### 3) 导入角色页改版（lib/screens/home_screen.dart `_showImportSheet`）

- 弹窗加 `showDragHandle` + 可滚动；标题「导入角色卡」+ 副标题「第一次用？直接从『角色卡市场』挑一张」；
  「角色卡市场」行加「推荐」小徽章；四个 ListTile 副标题口语化；底部说明角色卡格式与导入后可见性。

### 4) 摘要提示说人话（lib/services/summarize.dart + lib/screens/chat_screen.dart）

- `summarize.dart` 新增：
  - `enum SummaryReason { historyWindow, contextBudget }`；
  - `summaryProgressText({reason, earlyCount})`：
    history → 「正在把 N 条较早的对话压成摘要…」；budget → 「上下文快满了，正在压缩 N 条早期对话…」；
  - `summaryProgressHint({reason})` 第二行小字（强调本地聊天记录不变、消息照常发出）；
  - `summaryWhyParagraphs({reason, historyLimit, earlyCount, contextWindow, estimatedTokens})`
    生成弹窗 5 段说明：触发原因（含具体数字）、**不是额度/token 用光**、压成 300 字摘要替代原文、
    本机记录不删改、怎么关掉（设置 → 长对话自动摘要）或手动触发（⋮ → 立即总结早期对话）。
- `chat_screen.dart`：
  - 新增字段 `_summarizeReason / _summarizeEarlyCount / _summarizeEstimatedTokens`；
    `_prepareAndSend`（历史窗口）、`_compressIfNeeded` 第 2 步（上下文预算，带估算 token）、
    `_manualSummarize` 各设置一次；
  - 输入栏上方进度区改为：spinner + 两行文案 + `help_outline`（打「为什么在总结早期对话？」弹窗）+
    「跳过」（原「取消」）；
  - 新增 `_showSummaryWhy()` 弹窗：「知道了」/「跳过本次」（跳过即取消本次摘要）。

## 仓库状态

- 分支 `dev`，远端 `origin = https://github.com/Alorith-H/LiteTavern.git`
- `pubspec.yaml:5` → `version: 0.15.1+13`；`lib/app_info.dart` → `kAppVersion = '0.15.1'`
  （`test/version_test.dart` 校验两者一致）
- 新增依赖：`url_launcher: ^6.3.0`（实际解析 6.3.3，含 `url_launcher_android 6.3.35` 等 4 个传递包）
- 产物：`build\app\outputs\flutter-apk\app-release.apk`（58.6 MB；
  `build\app\outputs\apk\release\output-metadata.json` → versionCode **13** / versionName **0.15.1**）
- 装机：**未完成**（构建后 `adb devices -l` 仍为空；真机 `23113RKC6C` 上次记录为 0.14.2 / code 10）

## 验证表（2026-11-22）

| 项 | 命令 | 结果 |
|---|---|---|
| 静态检查（全量） | `flutter analyze` | **No issues found!**（4.8s） |
| 单元/组件测试（全量） | `flutter test` | **+230 All tests passed!** |
| 新增测试 | `flutter test test\v16_test.dart` | +4 全过（NSFW 设置默认/持久化/回落） |
| 新增测试 | `flutter test test\v15_test.dart` | +6 全过（预设链接合法性、`presetForBaseUrl`、摘要三种文案/解释） |
| 引导页测试 | `flutter test test\onboarding_screen_test.dart` | +10 全过（含 360×520 小屏无溢出） |
| 市场页测试 | `flutter test test\card_market_screen_test.dart` | +7 全过（含「默认 SFW / 开关后 NSFW」传参与文案） |
| Release 构建 | `flutter build apk --release` | 成功，58.6 MB，versionCode 13 / 0.15.1（46.5s） |
| 装机 | `adb install -r ...apk` | **未执行**：设备离线 |

命令环境：`C:\flutter\bin\flutter.bat`（不在 PATH），每次先设
`$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`；
adb 在 `C:\Users\28351\Android\Sdk\platform-tools\adb.exe`（不在 PATH）。

## 装机步骤（手机插上 / 开无线调试后）

```powershell
& "C:\Users\28351\Android\Sdk\platform-tools\adb.exe" install -r `
  "C:\Users\28351\Desktop\LiteTavern\build\app\outputs\flutter-apk\app-release.apk"
& "C:\Users\28351\Android\Sdk\platform-tools\adb.exe" shell am start -n com.alorith.litetavern/.MainActivity
```

## 真机自测清单（建议按序走）

1. 首次安装（或清除数据）：应进入 5 步引导，逐页可翻、可跳过；第 2 步点「去官网获取 Key」应跳浏览器，
   第 3 步点预设填地址/模型、点「测试连接」看成功/失败对照卡。
2. 设置 → 模型服务 → 编辑当前配置 → 「去官网获取 API Key」应打开对应服务的 Key 页面；
   点击后能返回 App。
3. 主页右下「导入」→ 弹窗有标题/说明/「推荐」徽章/底部格式说明；市场入口可进入。
4. 长对话（消息数超过「记忆长度」设置）发送时：进度区显示「正在把 N 条较早的对话压成摘要…」，
   点 ⓘ 弹「为什么在总结早期对话？」说明，点「跳过」本次不总结直接发。
5. 上下文接近窗口上限时（可把上下文窗口调到很小触发）：显示「上下文快满了，正在压缩…」，
   点 ⓘ 说明里带估算 token 与窗口值。
6. 设置 → 角色卡市场 → 「显示 NSFW 内容」默认关；进市场顶部显示「仅显示全年龄（SFW）内容」，
   打开开关后再进市场顶部变「已显示 NSFW 内容」且出现成人向卡（NSFW 卡在列表里有标记）。
7. 回归：单聊/群聊流式回复、建议回复、角色卡翻译、市场筛选与下载进度、上下文占用提示。

## 已知边界（记录，不作为 bug）

- 引导页第 4 步「从角色卡市场导入」**返回即完成引导**（不论是否真的下载了卡）；如需改为
  「无新角色则停留在第 4 步」，改 `onboarding_screen.dart` 中该分支即可。
- 引导页外链按钮在 widget test 中只断言存在、不点击（无 url_launcher 平台通道 mock）；
  `_finish()` 的跳转（HomeScreen 全链路）也未纳入单测。
- 摘要「上下文预算」原因里的 token 数是发送前**估算值**（`_estimateSendTokens`），与真实计费可能有偏差。
- 三输入框每次 onChanged 都写 SharedPreferences（即时落盘防丢），未做 debounce。
- 免费翻译只有 MyMemory 稳定可用（约 5k 字符/天、单次 500 字符）；Google 免费端点常 429。
- 建议回复仅单聊、每次额外 3 次请求；离开会话页即取消（页面私有，不进 `ActiveGenerations`）。
- 市场列表译文只读缓存，未缓存的卡需手动点「译」。
- NSFW 开关在**每次请求时**读取 `AppSettings.showNsfw`（搜索/翻页/下拉刷新/改筛选都会重新读），
  所以设置改完再回到市场页（或下拉刷新）即生效，不需要重启 App。
- v0.11 之前遗留：后台完成不续跑自动继续（S3）、创建器「生成角色卡」仍页面私有请求（S4）、
  删除会话先 remove 再异步落库的极小交错窗口（B2）、管理器落库不带变体记账（B3）。

## 主要文件索引

| 文件 | 作用 |
|---|---|
| `lib/screens/onboarding_screen.dart` | 5 步新手引导（配置/测试/导入/完成） |
| `lib/services/api_presets.dart` | 服务商预设 + 官网/Key/文档链接 + `presetForBaseUrl` |
| `lib/services/external_links.dart` | 外部链接打开、复制降级、取 Key 帮助层、服务商选择器 |
| `lib/screens/api_config_screen.dart` | 模型配置列表与编辑（含「去官网获取 API Key」） |
| `lib/screens/home_screen.dart` | 主页与「导入角色卡」弹窗 |
| `lib/services/summarize.dart` | 摘要判断/切片/清洗 + 进度文案与解释段落 |
| `lib/screens/chat_screen.dart` | 聊天主流程、摘要进度提示与「为什么」弹窗 |
| `lib/screens/settings_screen.dart` | 设置（模型服务、生成参数、长对话自动摘要、帮助） |
