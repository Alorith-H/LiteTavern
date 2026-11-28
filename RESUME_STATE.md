## 本轮 v0.47.0 —— 富文本渲染 + 对话动效（用户需求：加入富文本支持和对话渲染效果）

- **自写富文本解析层**：新增 `lib/services/rich_text.dart`（不依赖 flutter_markdown，纯函数便于单测）——
  - `RichBlockType`：paragraph / heading / codeBlock / quote / bullet / numbered / divider / table；
  - `RichSpan`（bold / italic / code / strike / dialogue / url）与 `RichBlock`（含 level / code / language / prefix / rows）；
  - `parseRichText(source)` 逐行解析：围栏代码块、`#` 标题、`>` 引用（连续行合并）、`-`/`*`/`+` 列表、`1.` 有序列表、`|a|b|` 表格（跳过分隔行）、`---` 分隔线、其余段落（遇到空行或块级语法即停，前导空格记为缩进层级）；
  - `parseInline(text)`：`**粗**` / `*斜*` / `***粗斜***` / `` `代码` `` / `~~删除~~` / `[文字](链接)`；中文 `「台词」`、`“台词”` 标记为 dialogue 样式；未闭合标记按原文保留，不吞字符。
- **渲染组件**：新增 `lib/widgets/rich_message_text.dart`——
  - 标题按级别放大加粗；代码块等宽字体 + 横向滚动 + 底色圆角；引用左侧竖线；列表圆点/序号用强调色；表格带表头底色与行分隔线；分隔线用细 Divider；
  - 行内：粗体 600、斜体副色调、台词用主题强调色、行内代码等宽小一号带底纹、链接可点击（`openExternalLink`）、删除线；
  - 生成中在文本末尾显示闪烁光标（`ValueKey('rich-text-caret')`，620ms 呼吸）；整体可选 `SelectableText` 以支持复制。
- **聊天页接入**：`chat_screen.dart` 的 `_buildMessage` 里原 `MarkdownBody` 换成 `RichMessageText`（先过 `DisplayRegexLibrary.apply`，显示正则仍然生效），关掉开关时退回纯 `Text`；最后一条消息出现时用 `_MessageEntrance`（240ms 淡入 + 上浮 10px）。
- **两个新开关**（`lib/services/storage.dart` + 设置 → 外观与显示）：`richTextEnabled`（`rich_text_enabled`，默认开）、`chatAnimations`（`chat_animations`，默认开）——关掉富文本即完全回到纯文本显示；关掉动效则没有光标与浮现动画。
- **测试**：新增 `test/rich_text_test.dart` 20 例（块级解析 / 行内解析 / 台词与未闭合 / 表格 / 缩进 / `RichMessageText` 渲染与光标）；全量 **689 测试通过**。
- **版本**：`pubspec.yaml` `0.47.0+56`、`kAppVersion='0.47.0'`；CHANGELOG、`whats_new` v0.47.0 三条；`docs/index.html` 静态版本 v0.47.0。

### 本次运行记录（v0.47.0）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（12.3s） |
| `flutter test` | **+689 All tests passed!** |
| `flutter build apk --release` | 61.6MB（64,630,903 字节），versionCode 56 / 0.47.0 |
| 模拟器装机 | `adb -s emulator-5556 install -r` Success |
| 实机验证 | mock 服务返回带格式回复：斜体动作、紫色台词、加粗、圆点列表、引用竖线、等宽代码块均正确；流式时显示「思考中…」，完成后淡入；设置 → 外观与显示里「富文本渲染」「对话动效」两个开关均默认开启 |


## 本轮 v0.46.1 —— 变量改在对话里确认 + 默认主题色改为紫色（用户需求：不要弹窗；有变量就不再问；默认主题色紫色）

- **变量不再弹窗**：删除 `lib/widgets/card_variables_dialog.dart` 与其测试，`card_creator_screen.dart` 的 `_generateCard()` 不再询问，改为 `wantsInitialVariables(_transcript())` 按对话内容判断。
  - 采访提示词（`lib/services/card_creator_prompts.dart` 的 `creatorInterviewSystem`）新增一条：变量只在收尾时问一次；用户说不加就不再加；对话里已经聊过变量或用户自己提了数值，就不再问。
  - 新增 `wantsInitialVariables(String transcript)`：只看用户说的话（避免把采访者提问里的「要不要加变量」当成同意），明确否定优先 → false；明确肯定 → true；对话里问过变量且用户最后一句是「好 / 可以 / 行 / 嗯」→ true；其余（没聊过、说不清）→ false，宁可卡片干净。
  - 生成提示词同步：不加变量时 system 写「不要输出 "extensions" 字段：用户在对话里没有要求初始变量。」，user 追加「用户在对话里没有要求初始变量：不要输出 extensions 字段。」；解析后仍兜底清空 extensions。
- **默认主题色改为紫色**：`lib/services/storage.dart` 新增 `kDefaultThemeSeed = 0xFF9C27B0`；`themeSeed` 默认取紫色，并把旧默认棕色 `0xFF9C4632` 一次性迁移成紫色（用户自己挑过的其它颜色不动）。
- **测试**：`test/card_creator_test.dart` 增 6 例对话判断（明确拒绝 / 明确同意 / 问过后回「好」/ 没聊过 / 否定优先 / 空对话）+ 采访提示词断言改为「变量只在收尾时问一次」「不要问世界书」；`test/widget_test.dart` 主题色用例改为「默认紫色、老默认值迁移、用户选择保留」。全量 **669 测试通过**。
- **版本**：`pubspec.yaml` `0.46.1+55`、`kAppVersion='0.46.1'`；CHANGELOG、`whats_new` v0.46.1 两条；`docs/index.html` 静态版本 v0.46.1。

### 本次运行记录（v0.46.1）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | **+669 All tests passed!** |
| `flutter build apk --release` | 61.6MB（64,581,751 字节），versionCode 55 / 0.46.1 |
| 模拟器装机 | `adb -s emulator-5556 install -r` Success |
| 实机验证 | 更新说明弹窗为紫色主题；创建角色卡点「生成角色卡」直接生成（无变量弹窗）；请求体 system/user 均为「没有要求初始变量，不要输出 extensions」 |


## 本轮 v0.46.0 —— AI 创建角色卡去掉步骤限制 + 变量先询问（用户需求：不要步骤限制；变量与状态要先问是否加入）

- **自由节奏的采访**：删除 `lib/services/card_creator_flow.dart`（`CreatorStep` / `CardCreatorFlow` / `kCreatorStepCount` / `creatorStepTransitionHint` 全部移除），新增 `lib/services/card_creator_prompts.dart`：
  - `creatorInterviewSystem`：每次只问一个问题，心里按「名字与题材 → 性格与说话习惯 → 外貌与来历 → 相遇场景与开场白」推进，但不报编号、不显示进度、不说「第几步」；用户一次给多项就只补缺的；不追问数值 / 变量 / 世界书；用户说够了就提示点右下角「生成角色卡」。
  - `buildCardJsonSystem({required bool withVariables})`：生成提示词按开关决定是否给出 `extensions.mvu.initialVariables` 示例；不加变量时明确写「不要输出 "extensions" 字段」。
  - `cardVariablesInstruction({required bool withVariables})`：生成时追加在对话记录后的变量说明。
  - `creatorContinueHint`：继续按钮的提示文案。
- **生成前询问变量**：新增 `lib/widgets/card_variables_dialog.dart` 的 `showCardVariablesDialog(context)`——「要加初始变量吗？」说明变量用途，按钮「取消」（不生成）/「不加，直接生成」/「加上变量」。`card_creator_screen.dart` 的 `_generateCard()` 先弹它，返回 null 就中止；不加变量时即便模型输出了 extensions，也会 `copyWith(extensions: const <String, dynamic>{})` 清空，卡片保持干净。
- **界面**：`card_creator_screen.dart` 移除步骤条（第 N/6 步、进度条、上一步、跳过这步、步骤快速选项）与 `_flow` 状态；空态改为「想到什么就说什么，AI 会顺着往下问。」+「聊得差不多了，点右下角「生成角色卡」。」+ 三个题材快捷入口（都市奇幻 / 校园日常 / 科幻悬疑），聊天区与输入栏下移占满。
- **模型**：`CharacterCard.copyWith` 新增 `Map<String, dynamic>? extensions` 参数，便于清空。
- **测试**：重写 `test/card_creator_test.dart`（16 例：提示词不含步骤编号、一次一问、不追问变量、收尾提示、两种生成提示词、变量说明两态、copyWith 清空、extensions 解析 5 例、空态无进度条/无「跳过这步」）；新增 `test/card_variables_dialog_test.dart`（4 例：文案与三个按钮、加变量→true、不加→false、取消→null）。
- **版本**：`pubspec.yaml` `0.46.0+54`、`kAppVersion='0.46.0'`；CHANGELOG 新增 v0.46.0 两条；`whats_new` 新增 0.46.0「AI 创建角色卡更自由」两条；`docs/index.html` 静态版本同步 v0.46.0。

### 本次运行记录（v0.46.0）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | **+667 All tests passed!** |
| `flutter build apk --release` | 61.6MB（64,581,751 字节），versionCode 54 / 0.46.0 |
| 模拟器装机 | `adb -s emulator-5556 install -r` Success |
| 实机验证（模拟器 + mock 接口） | 创建页无步骤条；发一句「都市奇幻」后 AI 自由提问；点「生成角色卡」先弹「要加初始变量吗？」；选「不加，直接生成」后请求体 system 含「不要输出 "extensions" 字段」、user 含「用户不需要初始变量」，生成的角色卡字段正常 |


## 本轮 v0.45.1 —— 长按菜单精简（用户需求：取消「编辑 / 危险操作」分组与角色名标题，只留按钮）

- **角色操作弹层**：`lib/screens/home_screen.dart` 的 `_showActions` 改为调用新文件 `lib/widgets/character_actions_sheet.dart` 的 `showCharacterActionsSheet(context, card:, onEdit:, onDelete:)`。弹层只剩「编辑角色」「删除角色」两个按钮（删除仍为危险色，副标题说明会连聊天记录与书签一起删），不再显示角色名、「角色操作」标题和「编辑 / 危险操作」分组。
- **测试**：新增 `test/character_actions_sheet_test.dart` 3 例（只有两个按钮且无标题/分组；点编辑回调并关闭；点删除回调并关闭）。
- **版本**：`pubspec.yaml` `0.45.1+53`、`kAppVersion='0.45.1'`；CHANGELOG 新增 v0.45.1 一条；`whats_new` 新增 0.45.1 一条；`docs/index.html` 静态版本同步 v0.45.1。

### 本次运行记录（v0.45.1）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | **+665 All tests passed!** |
| `flutter build apk --release` | 61.6MB（64,581,751 字节），versionCode 53 / 0.45.1 |
| 装机 / 截图 | 模拟器 emulator-5556：安装成功（versionName 0.45.1）；启动弹「长按菜单精简 · 版本 0.45.1」一条说明 |

## 本轮 v0.45.0 —— 角色卡市场免责声明 + AI 创建引导 + 编辑页 AI 修改（用户需求：市场第三方说明、AI 逐步引导与变量适配、头像点击编辑、编辑页 AI 修改、导入弹窗顺序）

- **免责声明**（`lib/services/market_disclaimer.dart`、`lib/widgets/disclaimer_sheet.dart`）：`MarketDisclaimer` 用 `market_disclaimer_ack`（版本号）/`market_disclaimer_ack_at` 记确认状态，`currentVersion = 1`。首次进入角色卡市场先弹整页说明（不可点空白关闭，系统返回视为不同意）：内容来自第三方用户、与本软件及作者无关、不存储不审核不担保、可改用 AI 生成或本地导入；「我了解并继续」写入 ack 后加载市场，「不同意」直接退出（市场页 `maybePop(false)`，引导第 4 步据此留在引导页）。设置 → 角色卡市场与翻译 新增只读入口，可查看确认状态并「重新确认」清除 ack。
- **AI 创建角色卡逐步引导**（`lib/services/card_creator_flow.dart`、`lib/screens/card_creator_screen.dart`）：六步（名字与题材 / 性格与说话方式 / 外貌与背景 / 场景与开场白 / 变量与状态 / 世界书要点），每步一个固定问题 + 四组快速选项 + 上一步 / 跳过这步，顶部进度条显示「第 N/6 步 · 标题」；采访时 system 提示由 `creatorInterviewSystem(flow)` 生成（带已确认摘要），说完一步后追加 `creatorStepTransitionHint`；空态文案改为「一步一步来，一次只聊一件事。」
- **变量适配**：`_kCardJsonSystem` 输出新增 `extensions.mvu.initialVariables`；`lib/services/generated_card.dart` 的 `_parseExtensions` 只接受 `mvu.initialVariables` / `initial_variables` 里的数字、字符串、布尔（键 1–40 字），生成后可在「变量与状态」页看到。
- **编辑页 AI 修改**（`lib/services/card_ai_edit.dart`、`lib/screens/character_edit_screen.dart`）：AppBar 新增「AI 修改」（在翻译按钮之前）。四个范围（只改性格 / 只改开场白 / 只改背景 / 整体润色），输入一句要求 → 只把范围内字段送去模型（范围外截 160 字作参考并注明不改）→ 解析只含改动字段的 JSON（兼容 ``` 围栏与 `{"fields":{…}}` 包裹）→ 弹「AI 修改预览」逐字段勾选、原文/新文对照 → 确认后写进输入框，仍需点「保存」才落库。未配置模型时提示先去设置。
- **头像点击编辑**（`lib/screens/chat_screen.dart`）：单聊标题栏头像、群聊气泡头像都可点，打开对应角色的 `CharacterEditScreen`；群聊保存返回后替换 `_members` 里同一 id 的角色。
- **导入弹窗顺序**（`lib/screens/home_screen.dart`）：AI 创建角色卡排第一并带「推荐」，角色卡市场排第二且不再标推荐；副标题改为「支持 .png、.json、.charx，也可以让 AI 陪你写一张。」
- **引导文案**：「配置模型服务」一条去掉「教」字（按要求不写进更新日志）。
- **测试**：新增 `test/market_disclaimer_test.dart` 12 例、`test/card_creator_test.dart` 18 例、`test/character_edit_ai_test.dart` 16 例、`test/character_edit_sheet_test.dart` 3 例；同步 `test/card_market_screen_test.dart`、`test/onboarding_screen_test.dart`。
- **版本**：`pubspec.yaml` `0.45.0+52`、`kAppVersion='0.45.0'`；CHANGELOG 新增 v0.45.0 七条；`whats_new` 新增 0.45.0 五条；`docs/index.html` 静态版本同步 v0.45.0。

### 本次运行记录（v0.45.0）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | **+662 All tests passed!** |
| `flutter build apk --release` | 61.6MB（64,581,751 字节），versionCode 52 / 0.45.0 |
| 装机 / 截图 | 模拟器 emulator-5556：启动弹 0.45.0 更新说明；导入弹窗 AI 创建在前带推荐、市场第二；首次进市场弹整页第三方说明，同意后加载、顶部显示「已显示全部内容」；AI 创建页显示「第 1/6 步 · 名字与题材」、进度条与四组快速选项 |

## 本轮 v0.44.2 —— 内容开关默认隐藏 + 文案统一（用户需求：默认隐藏成人内容开关、隐藏入口、文案更简洁官方）

- **隐藏入口**：新增 `lib/services/tap_unlock.dart`（`TapUnlock`：3 秒窗口内累计 5 次，可注入时钟便于测试）。设置 → 帮助与关于 页脚新增可点文本「LiteTavern v0.44.2」，连点 5 次解锁并提示「已解锁。」；解锁状态存 `nsfw_unlocked`（默认关）。
- **门控**：`AppSettings.showNsfw` 改为 `nsfwUnlocked && stored`，未解锁时恒为 false。「角色卡市场与翻译」页未解锁只显示「内容过滤：仅显示全年龄角色卡。」；解锁后才出现「显示全部内容」开关；设置首页摘要同步为「仅全年龄 / 全部内容」。
- **修复**：`_showAbout()` 的版本行原为 `Text('版本 vkAppVersion')`（少了 `$`，显示字面量），已修正。
- **文案**：引导第 5 步「导入第一张角色卡」与收尾页、导入弹窗页脚、角色卡市场来源说明、`whats_new` 0.44.0–0.44.2、CHANGELOG 全部改为更简洁的官方表述，去除口语化与感叹。
- **测试**：新增 `test/nsfw_gate_test.dart` 9 例（存储门控、`TapUnlock`、设置页三态）；同步 `test/onboarding_screen_test.dart`、`test/v16_test.dart`、`test/card_market_screen_test.dart`。
- **版本**：`pubspec.yaml` `0.44.2+51`、`kAppVersion='0.44.2'`；CHANGELOG 仅记「小幅修复与优化。」；`docs/index.html` 静态版本同步 v0.44.2。

### 本次运行记录（v0.44.2）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | **+614 All tests passed!** |
| `flutter build apk --release` | 61.4MB（64,335,803 字节），versionCode 51 / 0.44.2 |
| 装机 / 截图 | 模拟器 emulator-5556：设置页未见开关 → 帮助与关于页脚连点 5 次 → 「已解锁。」→ 市场页出现「显示全部内容」并拨到开 → 摘要变「全部内容」；关于弹窗显示「版本 v0.44.2」；市场页顶部「已显示全部内容」；导入弹窗四入口平铺 |

## 本轮 v0.44.1 —— 引导收尾页排版 + 导入弹窗去分组（用户需求：「优化新手教程最后一页的排版，导入角色卡界面不要在线获取/从文件导入/自己创建的分栏」）

- **引导收尾页**（`lib/screens/onboarding_screen.dart` `_buildDone`）：顶部改成整页唯一的居中块（primary 12% 底的圆形 ✓ + 居中标题 + 一句说明），下方新增两个分组：
  - `_sectionLabel`（小标题，caption + w700 + 字距 0.6）；
  - `_groupCard`（surface 底 + 1px 描边 + 圆角 12，条目间 `Divider(height:1, thickness:0.6, outline)`）；
  - `_stepRow(number,title,desc)`：24×24 primary 12% 圆角方块序号 + 标题/说明；
  - `_noteRow(icon,title,desc)`：18px primary 图标 + 标题/说明。
  内容拆为「进去之后」（01 点个角色进聊天 / 02 输入框左边的按钮 / 03 想改什么去设置）与「它会替你处理」（长对话自动摘要 / 更新后告诉你改了什么），再接原来的「数据都在你手机里」强调块与「重看新手引导」脚注；文案顺带收紧（设置那条从三行长句压成一行）。
  - 02 文案按当前 `AssistMode` 走：`AssistMode.off` 时显示「现在是关闭的。想要时去 设置 → 聊天 → 输入栏辅助按钮 打开。」，其余用 `_assistMode.summary`——默认就是闭合状态，避免让人去输入栏找一个不存在的按钮。
  - 删除不再使用的 `_featureRow`（analyze 报 unused_element）。
- **导入角色卡弹窗**（`lib/screens/home_screen.dart` `_showImportSheet`）：删掉 `SheetMenuSection('在线获取')`、`SheetMenuSection('从手机或链接')`、`SheetMenuSection('自己创建')` 三个分组标题，四个 `SheetMenuItem` 平铺；市场仍带「推荐」徽章，标题下的说明与底部格式说明保留。
- **测试**：`test/onboarding_screen_test.dart` 第 6 步用例改为断言「进去之后 / 它会替你处理 / 01 02 03」与新文案（含 `重看新手引导`），共 **+605 全过**。
- **版本**：`pubspec.yaml` `0.44.1+50`、`kAppVersion='0.44.1'`；`whats_new.dart` 新增 0.44.1 条目（2 条）；CHANGELOG 新增 v0.44.1 段。

### 本次运行记录（v0.44.1）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（9.0s） |
| `flutter test` | **+605 All tests passed!**（19s） |
| `flutter build apk --release` | 61.4MB（64,335,803 字节），versionCode 50 / 0.44.1 |
| 装机 / 截图 | 模拟器 emulator-5556：`pm clear` 后走完 6 步引导 → 收尾页两张截图 `build/v441_onboarding_done.png`（首屏）/`build/v441_onboarding_done_scroll.png`（下滑后两张卡 + 数据块）；收尾页「进入 LiteTavern」→ 主页 → 右下角「导入」→ 弹窗截图 `build/import_sheet.png`（四个入口平铺、无分组标题） |

## 本轮 v0.44.0 —— 更新下载多源测速 + 断点续传（用户需求：国内下载很慢甚至无法更新）

- **多源下载**（`lib/services/updater.dart`）：新增 `DownloadSource{label,url}`、`UpdateSourceMode{auto,githubOnly,custom}`（枚举与文案放在 storage 层，避免 updater ↔ storage 循环依赖）、`UpdateService.downloadSourcesFor()`；`mirrorPrefixes` 只留实测可用的 4 个：ghfast、gh-proxy、ghproxy.imciel、ghproxy.net（`hub.gitmirror.com` 域名解析失败、`github.moeyy.xyz` 连接超时，已去掉）。
- **测速与换源**：`downloadApk` 先对候选源并行 `_probe`（Range 0–65535、5 秒超时、按 bytesPerSecond 排序），按速度依次下载；某个源失败/中断自动换下一个；服务器忽略 Range 回 200 时从头重写，不把文件写坏。
- **断点续传**：`.part` 保留、带 `Range: bytes=<已下载>-` 续传，取消下载不删 `.part`；新增「已下完就直接复用」——目标 APK 或满长的 `.part` 存在时不再请求网络（对应「卡在允许安装」后重试的场景）。
- **安装权限引导**：安装前 `canRequestPackageInstalls()` 检查；未允许时弹「还差一步：允许安装应用」，按钮「去打开设置」直接跳到本应用的「安装未知应用」页；`MainActivity.kt` 新增通道方法 `canInstallApk` / `openInstallSettings`，`installApk` 未授权时返回 `need_permission`；`apk_installer.dart` 增 `ApkInstallPermissionException`、`canInstall()`、`openInstallSettings()`。
- **UI**：`update_flow.dart` 下载中显示「已下 / 总量（%）」、实时速度与来源、取消后说明；设置 → 帮助与关于新增「更新下载源」（自动 / 只走 GitHub / 自定义加速前缀 + 内置镜像说明）。
- **设置项**：`AppSettings.updateSourceMode`（键 `update_source_mode`，默认 auto）、`updateCustomMirror`（键 `update_custom_mirror`）。
- **测试**：新增 `test/update_sources_test.dart` 12 例（候选源顺序/三种模式/斜杠归一、断点续传、自动换源、取消保留、忽略 Range、全失败不留成品、已下完复用、半成品补名）。

### 本次运行记录（v0.44.0）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（18.7s） |
| `flutter test` | **+605 All tests passed!**（19s） |
| `flutter build apk --release` | 61.4MB（64,335,739 字节），versionCode 49 / 0.44.0 |
| 镜像实测 | ghfast ≈ 600KB/s、gh-proxy ≈ 143KB/s、ghproxy.imciel ≈ 202KB/s、ghproxy.net 可用但慢；GitHub 直连 814KB/s |
| 装机 / 端到端 | 模拟器 emulator-5556：装 0.43.1 → 启动检测到 v0.44.0 → 下载走「加速镜像·ghfast」1.2MB/s → 弹「还差一步：允许安装应用」→ 打开系统开关 → 回来复用已下好的包 → 系统安装器 Update → **0.44.0 / code 49** → 更新说明弹窗四条 + 设置里「更新下载源 · 自动（推荐）」 |
| 提交 / 发布 | commit 5ef9012 · tag v0.44.0 · Release id 461289905（APK asset 803224713） |

> 教训：GitHub Releases 创建/上传用 `Invoke-RestMethod` 会报 `Received an unexpected EOF or 0 bytes from the transport stream`，改用 `curl.exe --ssl-no-revoke --http1.1 --data-binary @file` 稳定；上传地址用 `https://uploads.github.com/repos/<owner>/<repo>/releases/<id>/assets?name=app-release.apk`。

## 本轮 v0.43.1（关于页入口 / 文案再顺 / 官网重做）

- **关于弹窗**（`settings_screen._showAbout`）重写：新增「官网」「源代码」两行（`_aboutLink` 用 `openExternalLink`，点开跳浏览器），介绍改成正常句子，底部「作者 Alorith · MIT License」。
- **文案**：市场来源说明改成「角色卡来自 Chub.ai。现在只显示全年龄内容…」，NSFW 开着时改为「成人向内容也显示，觉得不合适就去 设置 → 角色卡市场 关掉」；`test/card_market_screen_test.dart` 两处断言同步。
- **更新说明**：`whats_new.dart` 增加 0.43.1 条目（3 条）。
- **官网重做**（`docs/index.html` + `docs/assets/style.css`，页面 13.6KB / 样式 12KB）：编辑部式排版（大标题 + 交替行 + 时间线）、纯 CSS 手机与对话气泡示意、三种界面预览（气泡/小说/两级菜单）、六条问答、深色模式、`prefers-reduced-motion` 适配、滚动浮现、窄屏重排；下载按钮与版本号从 Releases API 读取。

### 本次运行记录（v0.43.1）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（5.3s） |
| `flutter test` | **+593 All tests passed!**（17s） |
| `flutter build apk --release` | 61.3MB（64,237,435 字节），versionCode 48 / 0.43.1 |
| 装机 | 真机 192.168.0.102:37433 → Success（0.43.1 / code 48） |
| 官网 | Pages built 到 a9c128f；首页 200、`assets/style.css` 200，新设计关键字「把故事」「门没锁」命中；无头 Chrome 截图 `build/site_home.png`（1440×2400） |
| 提交 / 发布 | commit a9c128f · tag v0.43.1 · Release id 461274320（APK asset 803069120） |
## 本轮 v0.43.0（文案 / 引导 / 更新提示 / 官网）

- **文案去 AI 味**：设置页 14 条说明改写为口语；主页空态与导入弹层 5 条改写；去掉了说明里的版本号。
- **新手引导**：开场补「大概 2 分钟」；完成页新增「更新后会告诉你改了什么」条目。
- **更新说明**：新增 `lib/services/whats_new.dart`（登记 0.43.0 / 0.42.0 两版要点、`pendingWhatsNew`、`markWhatsNewSeen`）与 `lib/widgets/whats_new_dialog.dart`；`home_screen` 启动后弹一次；设置 → 帮助与关于 → 「更新说明」可回看（回看不改已读状态）；`AppSettings.lastSeenVersion`（键 `last_seen_version`）。
- **静态官网**：`docs/index.html` + `docs/assets/style.css` + `icon.svg`；GitHub Pages 从 dev 分支 /docs 发布，地址 https://alorith-h.github.io/LiteTavern/ ；页面 JS 从 Releases API 读取最新版本与 APK 大小。

### 本次运行记录（v0.43.0）
| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（4.3s） |
| `flutter test` | **+593 All tests passed!**（20s，含 v43 新增 6 例） |
| `flutter build apk --release` | 61.3MB（64,237,327 字节），versionCode 47 / 0.43.0 |
| 装机 | 真机 192.168.0.102:37433 → Success（0.43.0 / code 47） |
| 真机点验 | 首次启动弹出「这一版更顺手了」四条要点 + 「知道了」，点掉后进入主页（`build/v430_whatsnew.png`、`v430_home.png`） |
| 官网 | Pages 构建 built（commit 065cd7a），https://alorith-h.github.io/LiteTavern/ 返回 200 |
| 提交 / 发布 | commit 065cd7a · tag v0.43.0 · Release id 461269240（APK asset 803040109） |
## 本轮 v0.42.0 —— 长会话性能（增量保存 / 分页 / 索引 / 长图进度）

> 用户需求：会话增量保存 + 分页加载，聊天统计/搜索做缓存索引，长图导出改后台 isolate + 进度条。

### 变更
| 文件 | 内容 |
| --- | --- |
| lib/services/storage.dart | loadConversationData 兼容数组 / 对象（含 gen）并重放 .journal；saveConversation 改为「快照 + 增量日志」（首次仍写旧格式；日志行 400 或 512KB 自动合并）；deleteConversation 连日志一起删；initForTest 清内存缓存 |
| lib/screens/chat_screen.dart | 分页渲染（_pageSize = 200，上滑加载更早消息 + 顶部提示）；_showChatStats 走索引聚合；导出长图 / EPUB 时弹进度对话框；ChatIndexCache 在所有 _msgCache.clear() 处同步失效 |
| lib/services/chat_index_cache.dart | 新增：全量小写文本 + 聚合统计缓存（条数 / 双方条数 / 输入输出 / 缓存命中 / 估算标记） |
| lib/services/chat_transcript.dart | searchMessages 增可选 lowerTexts（搜索框传入缓存索引） |
| lib/services/chat_image_export.dart | ender(onProgress:)：测量每 30 条、绘制每 40 条让出事件循环并回报进度，收尾 0.96 → 1.0 |
| lib/services/chat_export_files.dart | uildBytes/shareChat 透传 onProgress |
| 	est/v42_test.dart | 15 例：首次数组格式、只写日志、重放、编辑 upsert、截断、摘要日志、400 行自动合并（gen 递增）、坏行跳过、删除清日志、缓存失效、统计聚合、搜索索引一致性、长图进度单调到 1.0 |

### 已知边界
- 长图仍在主 isolate 里分块生成（每块让出一次事件循环，界面可刷新），真正离线渲染需要额外 isolate + 平台通道，留到后续版本。
- 增量日志只保证「进程正常退出」的一致性；进程被系统杀死时，日志里已 flush 的行仍然有效，未 flush 的最后一两行可能丢失（与旧版整份重写的最坏情况相同）。
- 分页只是渲染窗口，_messages 仍全量在内存（搜索 / 统计 / 导出都作用于全量）。
## 本轮 v0.41.0 —— 商用加固（极限情况与崩溃防护）

> 审查记录详见 `docs/HARDENING.md`。目标：把「崩溃 / 卡死 / 丢数据」的路径堵上。

### 新增的防护
| 位置 | 防护 | 上限 |
| --- | --- | --- |
| `lib/services/charx_importer.dart` | CHARX 压缩包守卫（`_guardArchive`） | 条目 ≤ 2000、单文件 ≤ 100MB、解压总量 ≤ 200MB |
| `lib/services/backup_service.dart` | 备份包守卫 | 条目 ≤ 20000、单文件 ≤ 200MB、解压总量 ≤ 1GB |
| `lib/services/st_chat_importer.dart` | `.jsonl` 导入守卫 | 文件 ≤ 100MB、行数 ≤ 20 万、单行 ≤ 2MB |
| `lib/services/display_regex.dart` | 正则安全 | pattern ≤ 1000 字符、单次文本 ≤ 20 万字符、单次导入 ≤ 200 条 |
| `lib/services/api_client.dart` | 响应体守卫 | 整段 ≤ 8MB、流式累积 ≤ 200 万字符、错误页最多读 64KB |
| `lib/screens/home_screen.dart` | 角色卡文件导入 | ≤ 50MB（读入内存前拦） |
| `lib/services/app_log.dart`（新） | 本地诊断日志 | 内存 300 行 / 文件 256KB，不联网、永不抛异常 |
| `lib/main.dart` | 全局错误处理 | `FlutterError.onError` + `PlatformDispatcher.onError` 写入诊断日志 |
| `lib/screens/diagnostics_screen.dart`（新） | 诊断日志页 | 最近 150 条，可复制、可清空；入口：设置 → 帮助与关于 → 诊断日志 |

### 验证（2026-11-28）
- `flutter analyze` → No issues found!
- `flutter test` → **+572 All tests passed!**（新增 `test/v41_test.dart` 12 例）
- `flutter build apk --release` → **61.2MB**，versionCode **45** / versionName **0.41.0**
- 真机 `192.168.0.102:37433` install → Success（versionCode 45 / 0.41.0），启动正常，数据保留
- 模拟器 monkey 压测：`adb shell monkey -p com.alorith.litetavern -v 300` → 300 事件注入完成，`logcat -b crash` 空、无 `FATAL`，App 进程存活
- 真机点验诊断日志：显示「App 启动 · v0.41.0」，重复条目已去重

### 已知残余风险（下一轮）
- 显示正则仍是 Dart `RegExp`，超长文本直接跳过（降级而非崩溃）；要彻底防 ReDoS 需换线性时间匹配实现。
- file_picker / share_plus 等插件的系统层崩溃无法被 Dart 捕获，只能靠降级提示规避。
- 大长图导出在低端机可能耗时数秒，目前只有 toast 提示。
- 备份包未加密（含 API Key），分享时需注意。

## 本轮 v0.40.3 —— 所有预设按官方文档核对

| 服务商 | 预设模型 | 上下文（官方） | 依据 |
| --- | --- | --- | --- |
| DeepSeek | deepseek-flash (V4.1-Flash) | 1M（输出 384K） | api-docs.deepseek.com 模型&价格 |
| 智谱 GLM | glm-4.6（免费型号 glm-4.6v-flash 128K） | 200K（输出 128K） | docs.bigmodel.cn 模型概览 |
| Kimi | kimi-k3.1-pro（kimi-k3 同 1M；moonshot-v1-* 已下线） | 1M | platform.kimi.com/docs/models |
| 小米 MiMo | mimo-v2.6-flash | 1M（输出 128K） | mimo.mi.com 模型规格 |
| Ollama | qwen2.5:7b（本地） | 32K | 本地默认 |

- 自动推断同步：GLM-4.6/4.7/5.x 200K、GLM-4 老型号 128K、Kimi K3 1M / K2 256K、MiMo 1M、
  GPT-6.x 1.05M、GPT-5 400K、GPT-4.1 1M、GPT-4o 128K、Qwen3.8 1M、Claude 200K（1M 为 beta）、Gemini 1M。
- 测试：test/v20_test.dart 增「Kimi / MiMo 预设跟进官方现役模型」等断言；全量 **560 全过**。
- 真机点验（设置 → 模型与生成 → 模型服务 → 编辑）：智谱 GLM → `glm-4.6`、Kimi → `kimi-k3.1-pro`、
  小米 MiMo → `mimo-v2.6-flash`；当前配置显示「deepseek-flash · 上下文 1M（自动）」。未保存，未改用户数据。

## 本次运行记录（2026-11-28，v0.40.3）

- `flutter analyze` → No issues found!（9.8s）
- `flutter test` → +560 All tests passed!（17s）
- `flutter build apk --release` → **61.1MB**，versionCode **44** / versionName **0.40.3**
- 真机 `adb -s 192.168.0.102:37433 install -r` → **Success**（dumpsys：versionCode 44 / 0.40.3）
- 真机点验：见上表预设回填；当前配置「deepseek-flash · 上下文 1M（自动）」
# 交接状态：v0.40.2 修正 DeepSeek 上下文为 1M（2026-11-28 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.x（市场筛选、用户侧建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.x（6 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话、市场 NSFW 开关）、
> v0.16.0（用户人设、作者注释、宏增强、替我说一句、导出对话文件）、
> v0.17.0（多聊天文件、对话分支、消息书签）、
> v0.18.x（输入栏辅助三选一、自动摘要后台静默 + token 说明、菜单可滚动、建议回复并行提速）、
> v0.19.0（翻译接入必应：Azure Key + 网页版兜底）、
> v0.20.0（模型配置与上下文改造：按模型自动、获取模型列表）、
> v0.21.x（设置页二级菜单、引导新建配置、气泡下模型名、上下文按接口自报）、
> v0.22.0（服务商改回 DeepSeek 第一、智谱只留一家、本地 LibreTranslate）、
> v0.23.0（应用内自动更新）、
> v0.24.0（消息操作三件套、对话内搜索、功能评估清单）、
> v0.25.0（分支树页、导出长图 / EPUB）、
> v0.26.0（整库备份与恢复 zip）、
> v0.27.0（世界书导出 / 命中测试 / 四范围绑定）、
> v0.28.0（提示词检视升级：缓存断点 + 省钱排序）、
> v0.29.0（显示正则库：导入 ST 正则 / 作用域 / 试一下 / 只改显示）、
> v0.30.0（SillyTavern 预设只读解析）、
> v0.31.0（SillyTavern 兼容模式：预设提示词真实注入）、
> v0.32.0（CHARX 导入、`.jsonl` 聊天导入、导入体检报告）、
> v0.33.0（变量与状态只读、卡内脚本安全提示）、
> v0.34.0（每聊天生成参数覆盖：6 个采样键）、
> v0.35.0（聊天统计里的缓存命中与费用估算）、
> v0.36.0（群聊主持：发言名单与顺序、让大家接着说）、
> v0.37.0（对话排版：气泡 / 小说）、
> v0.38.0（备份恢复可选内容）、
> v0.39.0（菜单布局重做：统一零件、分组、图标）、
> v0.40.0（聊天菜单改为二级：一级只列六组）、
> v0.40.1（二级菜单返回上一级 + 设置页重新分组）、v0.40.2（DeepSeek 现役模型上下文 1M、预设改 deepseek-flash）。
>
> **本轮 v0.40.1 —— 菜单层级与设置分组**：
> 1. **二级菜单返回上一级**：`showGroupedSheetMenu` 改为自绘 `showGeneralDialog` + `PopScope`；
>    二级里按系统返回键、或点菜单外的空白处，都先回到一级（不关闭），一级再返回/点空白才关。
> 2. **设置页重新分组**：`SettingsSection` 改为
>    `model / chat / appearance / market / worldBooks / help`，标题为
>    **模型与生成 / 聊天与上下文 / 外观与显示 / 角色卡市场与翻译 / 世界书 / 帮助与关于**；
>    首页入口顺序与图标随分组走（`SettingsSection.icon`）。
> 3. **模型与生成**：原首页「模型服务」配置行 + 「生成参数」子页合成一页（`_modelChildren`），
>    首页只留一个入口，副标题为「配置名 · 模型 · t/p」（`_modelSummary()`）。
> 4. **显示项归入外观**：对话排版 / 聊天气泡字号 / 消息时间戳 / 显示快捷回复 / 快捷回复管理 /
>    显示正则，从「聊天与上下文」移到「外观与显示」顶部「排版与显示」；
>    其后是主题模式、主题色、自定义颜色。
> 5. **版本号规则**：只有布局与交互调整 → 版本记 **0.40.1**（补丁号 +1）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.40.2+43**，`lib/app_info.dart` `kAppVersion = '0.40.2'`。
- 本轮新增 / 修改：
  - `lib/widgets/sheet_menu.dart`：`showGroupedSheetMenu` 改为自绘对话框 + `PopScope`；
    新增 `_SheetGroupHeader`（返回箭头 + 组名）、`_SheetDragHandle`；`_back()` 负责逐级返回。
  - `lib/screens/settings_screen.dart`：枚举 / 标题 / 图标重排；新增 `_modelChildren`、
    `_modelSummary()`；删除无用的 `_generationSummary()`；显示项移入 `_appearanceChildren`；
    `_appearanceSummary()` 带上排版名。
  - `test/v40_test.dart`：改为 5 例（返回箭头回一级 / 点空白回一级 / 系统返回先回一级等）。
  - `test/v21_test.dart`、`test/v37_test.dart`、`test/v39_test.dart`：同步新分组与图标。
  - `CHANGELOG.md`（v0.40.1 段）、`docs/FEATURE_AUDIT.md`（第 7 节本轮变更记录）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（3.8s） |
| `flutter test` | **+559 All tests passed!**（12s） |
| `flutter build apk --release` | 见下方「本次运行记录」 |
| 回归 | 单人 / 群聊、导出、世界书、ST 兼容、备份、排版等原有测试全绿 |

## 已知边界

- 二级菜单是自绘 `showGeneralDialog`（不是 `showModalBottomSheet`），因此不能再用
  `showModalBottomSheet` 的 `showDragHandle`；拖动条由内部 `_SheetDragHandle` 画（仅装饰、不可拖）。
- 设置首页六个入口的副标题里，模型与生成只显示「配置名 · 模型 · t/p」，不显示上下文窗口；
  上下文窗口在子页与模型配置里。
- 其它沿用 v0.40.0 / v0.39.0 的边界（消息长按菜单在模拟器上无法注入长按；
  底部弹层条目多时依赖滚动；恢复是覆盖；费用是估算；ST 兼容是叠加；变量只读；卡内脚本不执行）。

## 环境与常用命令

```powershell
# Flutter（不在 PATH）
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release

# 真机（无线调试，端口每次可能变化）
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe devices
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe connect <ip:port>
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s <ip:port> install -r build\app\outputs\flutter-apk\app-release.apk

# 模拟器（真机不在手边时；AVD 已建好）
C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio `
  -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556
adb -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk

# mock 模型服务（写 build\mock_last.json 便于核对请求体）
python build\mock_llm.py    # 监听 127.0.0.1:8765，模拟器用 http://10.0.2.2:8765/v1

# 发布（GitHub Release 需要 token；上传地址直接拼 assets?name=）
# https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk
```

## 下一轮建议

`docs/FEATURE_AUDIT.md` 里 ✅ 已覆盖绝大部分本地功能，剩下的 ❌ 都是「明确不做 / 依赖外部服务」
（卡内脚本执行沙箱、HTML 整页画布、TTS / 语音输入、图像生成、向量记忆、Web 搜索、Live2D、STscript）。

后续可做的小项：聊天统计按模型拆分、自动更新忽略版本、恢复前自动快照、
其余底部弹层（聊天列表 / 书签 / 导出格式 / 市场筛选 / 模型列表）也换成 `sheet_menu` 零件、
把「设置首页」也改成二级菜单风格（目前是长列表 + 分节标题）。

## 本轮 v0.40.2 —— DeepSeek 上下文修正

- 官方文档核对（2026-11）：现役 `deepseek-flash`（V4.1-Flash）与 `deepseek-v4-pro`
  最大上下文均为 **1M**，输出上限 384K；旧名 `deepseek-chat` / `deepseek-reasoner`
  已路由到 V4.1-Flash，同为 1M（旧名三个月后停用，已过停用期）。
- 修改：`lib/services/api_presets.dart` 里 DeepSeek 预设模型改 `deepseek-flash`、
  `contextWindow` 改 1000000、note 标「1M 上下文」；`contextWindowForModel` 的
  `deepseek*` 分支由 65536 改为 1000000。
- 测试：`test/v20_test.dart`、`test/onboarding_screen_test.dart` 同步断言；全量 **559 全过**。
- 影响：已保存的配置 `contextWindow = 0`（自动）会立刻按 1M 计算，无需迁移；
  之前若手填过 64K 的仍以手填为准（可在模型配置里清空恢复自动）。

## 本次运行记录（2026-11-28，v0.40.2）

- `flutter analyze` → No issues found!（4.2s）
- `flutter test` → +559 All tests passed!（16s）
- `flutter build apk --release` → **61.1MB（64,056,935 字节）**，versionCode **43** / versionName **0.40.2**（Gradle 50.2s）
- 真机 `adb -s 192.168.0.102:37433 install -r` → **Success**（dumpsys：versionCode 43 / 0.40.2 / lastUpdateTime 2026-11-28 10:03:52，数据保留）
- 真机点验：设置 → 模型与生成 → 模型服务，dump 显示 **「Deepseek · deepseek-flash · 上下文 1M」**（修复前为「上下文 64K（自动）」）

- `flutter analyze` → No issues found!（3.8s）
- `flutter test` → +559 All tests passed!（12s）
- `flutter build apk --release` → **61.1MB（64,056,935 字节）**，versionCode **42** / versionName **0.40.1**（Gradle 52.1s）
- 真机 `adb -s 192.168.0.102:37433 install -r` → **Success**（dumpsys：versionCode 42 / 0.40.1 / lastUpdateTime 2026-11-28 09:52:27，数据保留）
- 真机点验：
  - 设置首页 dump 确认新分组：模型与生成（`Deepseek · deepseek-flash · t0.8 · p1.0`）/ 聊天与上下文 / 外观与显示（`气泡排版 · 跟随系统 · 主题色 #9C27B0 · 字号 15sp`）/ 角色卡市场与翻译 / 世界书 / 帮助与关于（`版本 v0.40.1`），截图 `build/v401_settings.png`；
  - 聊天菜单一级只有六组与概括、无标题（`build/v401_menu1.png`）；
  - 点「生成」进二级（`build/v401_menu2.png`）后按**系统返回** → 回到一级（六组仍在，`build/v401_afterback.png`）；
  - 二级点空白 → 回一级；一级点空白 → 菜单关闭（断言：level2→level1 groups=3，再点 groups=0 且输入栏可见）。

### 本次运行记录（v0.42.0）
| 项目 | 结果 |
| --- | --- |
| lutter analyze | No issues found!（8.2s） |
| lutter test | **+587 All tests passed!**（23s，含新增 15 例 v42） |
| lutter build apk --release | 61.2MB（64,220,775 字节），versionCode 46 / 0.42.0 |
| 装机 | db -s 192.168.0.102:37433 install -r → Success（0.42.0 / code 46，数据保留） |
| 真机冒烟 | 启动正常、打开原有长会话正常（截图 uild/v420_home.png / 420_chat.png），logcat -b crash 无记录 |
| 提交 / 发布 | commit 55fa18f · tag v0.42.0 · Release id 461261819（APK asset 803000802） |
