# 交接状态：v0.21.2 翻译阶段提示（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.0（5 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话）、
> v0.15.1（角色卡市场 NSFW 开关，默认关）、
> v0.16.0（用户人设 Persona、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）、
> v0.18.x（输入栏辅助三选一、6 步新手引导、自动摘要后台静默 + token 说明、菜单可滚动、建议回复并行提速）、
> v0.19.0（翻译接入必应：Azure Key + 网页版兜底）、
> v0.20.0（智谱 GLM-4-Flash 免费置顶、上下文长度跟模型配置、获取模型列表）。
>
> **本轮 v0.21.0**：
> ① **新手引导不再覆盖旧配置**：引导里填的模型信息会新建一套配置并设为当前使用，
>   之前填好的那套原样保留；只点跳过不会留下空配置。
> ② **气泡下面显示模型名**：AI 消息信息行变成「模型名 · tokens · 时间」，旧消息为 null 不显示。
> ③ **设置页二级菜单**：首页只留分组入口（生成参数 / 聊天与上下文 / 角色卡市场与翻译 /
>   世界书 / 外观 / 帮助与关于），点进去才是具体开关。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.21.2+22**，`lib/app_info.dart` `kAppVersion = '0.21.2'`。
- v0.21.1 改动文件：`lib/services/api_presets.dart`（`formatContextWindow` 十进制/1024 双规则、`contextWindowForModel` 补 o4/mixtral）、`lib/services/api_client.dart`（`RemoteModel` / `fetchModelInfos` / `extractModelInfos`）、`lib/screens/api_config_screen.dart`（`_reportedContext`、选模型按接口报告填上下文、列表副标题显示上下文）、`lib/screens/onboarding_screen.dart`（同上，写进草稿配置）、`lib/screens/chat_screen.dart`（信息行顺序 tokens → 模型名 → 时间）、`test/v20_test.dart`（新增 extractModelInfos 3 例、128000→128K）。
- v0.21.0 改动文件：
  - `lib/screens/onboarding_screen.dart`：控制器初始为空；`String? _draftConfigId`；
    `_ensureDraftConfig()`；`_saveModelConfig()` 改为「新建/更新草稿配置」；第 3 步加说明面板「这里会新建一套配置」。
  - `lib/models/chat_message.dart`：新增 `String? model`（构造 / fromJson / toJson / copyWith）。
  - `lib/screens/chat_screen.dart`：`_applyTokens` 写入本次模型名；`_buildMessage` 信息行
    `parts = [模型名, tokens, 时间].join(' · ')`。
  - `lib/screens/settings_screen.dart`：新增 `enum SettingsSection` + `SettingsSectionTitle`；
    `SettingsScreen({super.key, this.section})`；首页分组入口 + `_sectionChildren` 分节构建
    （`_generationChildren` / `_chatChildren` / `_marketChildren` / `_worldBookChildren` /
    `_appearanceChildren` / `_helpChildren`）。
  - `test/v21_test.dart`（新增 6 例）。

## 本轮变更（v0.21.2）详解

### 下载完成后翻译阶段显示「正在翻译…」

- `lib/screens/card_market_screen.dart`：详情页新增 `_translating` 状态；`_import()` 在 `importCardBytes` 成功后先把 `_downloading` 置 false，随即进入翻译分支；`_askAndLocalize` 在用户选了「免费翻译 / 用模型翻译」后置 `_translating = true`（`finally` 复位），原来的翻译主体拆成 `_localizeWithFallback()`。
- 按钮与进度条：`busy = _downloading || _translating`；翻译阶段进度条改为不确定进度（`value: null`），按钮禁用并显示「正在翻译…」；下载失败/解析失败/其它异常的三个 catch 分支同时复位两个状态。
- 已知边界：翻译阶段的进度条无法给百分比（翻译接口不报进度），只表示「还在处理」。

## 本轮变更（v0.21.1）详解

1. **气泡下方信息顺序**：`模型名 · tokens · 时间` 改成 `tokens · 模型名 · 时间`
   （`chat_screen.dart` 的 `parts` 顺序调整），模型名放到输入/输出后面。
2. **上下文长度更准**：
   - `ApiClient.fetchModelInfos` 拉 `GET /models` 时解析服务商自报字段
     （`context_length` / `context_window` / `max_context_length` / `max_model_len` /
     `max_input_tokens` / `context_size` / `n_ctx`），`extractModelInfos` 返回 `RemoteModel{id, contextWindow}`；
   - 选模型弹层每行显示「上下文 128K」，选中后如果上下文还是「自动」，直接把接口报告值填进输入框；
     helper 文案变成「按接口报告的窗口：128K」；
   - 服务商没自报时退回 `contextWindowForModel` 猜（补充 o4 / mixtral）；
   - `formatContextWindow` 修正：整千按 1000 折算（128000 → 128K），整 1024 倍按 1024 折算（131072 → 128K），
     不再出现「125K」。

## 本轮变更（v0.21.0）详解

### 1. 引导页配置另存为新的一套

- 三个输入框不再预填 `AppSettings.baseUrl/apiKey/model`，进来是空的。
- 用户真正填了内容（三栏任一非空）后才 `AppSettings.newConfigId()` 新建一套
  （名字取预设 label，或模型名，兜底「新手配置」），加入 `AppSettings.apiConfigs` 并设为激活；
  后续输入只更新这套草稿，不再触碰旧配置。
- 第 3 步顶部有说明面板，明确告知「不会覆盖你之前已经填好的那套；想切回去 设置 → 模型服务」。

### 2. 气泡下方显示模型名

- `ChatMessage.model` 记录生成该条回复时 `AppSettings.model`；空串存 null。
- 气泡下方信息行顺序：模型名 → tokens → 时间（时间是否显示仍由「显示时间戳」开关控制）。
- 兼容：旧消息没有该字段，反序列化为 null，不会崩溃也不会写入空值。

### 3. 设置页二级菜单

- 首页：`模型服务`（当前配置行）+ `设置`（五个分组行，副标题是各页当前状态摘要）+
  `帮助与关于`（版本 / 重看新手引导 / 作者）。
- 分组页：独立 `Scaffold` + AppBar 标题，内容即原来的分节；字号调节改为二级页内的滑条弹层。
- 深链：`SettingsScreen(section: SettingsSection.chat)` 可直接打开某个分组（测试已覆盖）。

## 历史变更（v0.20.0，已发布）

- 智谱 GLM-4-Flash（免费）加入预设并排在引导第 2 步第一位（「免费」徽章）。
- 上下文长度跟模型配置走：`ApiConfig.contextWindow`（0 = 按模型自动），
  `contextWindowForModel` 按模型名推断，配置列表显示大小；设置页旧的全局输入框改为说明行。
- `ApiClient.fetchModels` + `extractModelIds`：编辑配置 / 引导第 3 步可「获取模型列表」并点选填入。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | **No issues found!**（5.2s） |
| `flutter test` | **+309 All tests passed!**（9s，其中 test/v21_test.dart 6 例、extractModelInfos 3 例） |
| `flutter build apk --release` | 59.3MB（Gradle 49.3s），versionCode **22** / versionName **0.21.2** |
| 装机 | `adb -s 19faf100 install -r`（USB）→ **Success** |

## 真机自测清单（v0.21.0）

1. 设置页首页：只有分组入口，六行（生成参数 / 聊天与上下文 / 角色卡市场与翻译 / 世界书 /
   外观 / 帮助与关于），每行副标题显示当前状态摘要。
2. 点「生成参数」→ 二级页有预设行、随机度、采样范围、单次回复长度上限、高级设置。
3. 点「聊天与上下文」→ 用户人设、称呼、记忆与上下文、自动继续、流式传输、输入栏辅助三选一、
   自动摘要、显示（字号/时间戳/快捷回复）。
4. 聊天页：发一条消息，AI 气泡下方显示「模型名 · tokens · 时间」。
5. 重看新手引导（设置 → 帮助与关于）：第 3 步输入框是空的，填完后设置 → 模型服务里多出一套新配置，
   旧配置仍在且数值未变。

## 已知边界

- 模型名取的是「发送那一刻的 `AppSettings.model`」；若中途切了激活配置，旧消息仍显示当时的模型名（符合预期）。
- 旧消息（v0.21.0 之前）没有 `model` 字段，气泡下方不显示模型名。
- 引导页只填了一部分（比如只填 Key）也会新建一套配置；完全没填则不会。
- 设置二级页是 `push` 新页面（不改底部导航），返回即首页。
- 上下文长度「自动」是按模型名规则推断，不是真的问服务商；特殊私有模型名回落 64K，可手填。
- 「获取模型列表」依赖服务商支持 `GET /models`；不支持时给中文提示，仍可手填。
- 必应网页版接口按 IP/风控返回 `ShowCaptcha`，属正常现象：自动换源，不会卡住流程。
- `assistMode` 默认 off（沿用旧版「自动生成回复默认关」）；从旧版本升级时读 `auto_reply_candidates` 迁移一次。
- 自动摘要静默执行：长对话首次发送会有一次不易察觉的额外等待；可用发送钮的停止态打断。

## 环境与常用命令

- Flutter：`C:\flutter\bin\flutter.bat`（不在 PATH）；先设
  `$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`。
- 构建：`flutter build apk --release` → `build\app\outputs\flutter-apk\app-release.apk`。
- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`；真机 23113RKC6C（Android 16，1440×3200）。
  无线调试地址会变：先 `adb devices`，必要时 `adb connect <ip>:<port>`。
- 真机点按用**视觉坐标**（uiautomator bounds 常与视觉位置不符）。
- git 提交不要传 `-c user.name/-c user.email`（仓库配置已是 `Alorith-H <2835147611@qq.com>`）。

## 本次运行记录（v0.21.2）

- `flutter analyze`：No issues found!（4.7s）
- `flutter test`：+309 All tests passed!（9s）
- `flutter build apk --release`：59.3MB（Gradle 49.3s），versionCode **22** / versionName **0.21.2**
- 装机：`adb -s 19faf100 install -r`（USB）→ **Success**，lastUpdateTime 2026-11-22 23:05:51，数据保留；`am start` 正常。
- 说明：v0.21.2 只改了角色卡市场详情页的「正在翻译…」提示，未新增自动化测试（该路径涉及真实文件 IO，widget 测试需 runAsync；已手动装机交给用户自测）。
