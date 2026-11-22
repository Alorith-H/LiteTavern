# 交接状态：v0.16.0 对齐酒馆（人设 / 作者注释 / 宏 / 替我说一句 / 导出文件）（2026-11-22 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）、v0.12.0（市场筛选 + 设置开关）、v0.12.1（修正为「用户侧」建议回复）、
> v0.13.x（建议条纵向、角色卡翻译、市场全量筛选、原文/译文、下载进度）、
> v0.14.x（三风格建议、贴底、上下文占用提示、默认 1M 窗口、GitHub 页与首个 Release）、
> v0.15.0（5 步新手引导、跳转 API 官网、导入弹窗改版、摘要提示说人话）、
> v0.15.1（角色卡市场 NSFW 开关，默认关）。
>
> **本轮 v0.16.0**：对照 SillyTavern（酒馆）补齐 5 项核心能力——
> ① 用户人设 Persona（多套、注入 system、替换 `{{user}}`）；
> ② 作者注释 Author's Note（会话级、插入位置/深度/角色可选、默认注释继承）；
> ③ 宏增强（人设/角色卡字段/时间/随机/清理类宏）；
> ④ 替我说一句 Impersonate（生成一句「我」的话填进输入框）；
> ⑤ 导出对话文件（.txt / .json + 系统分享）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.16.0+14**，`lib/app_info.dart` `kAppVersion = '0.16.0'`。
- 新增文件：`lib/services/user_personas.dart`、`lib/services/authors_note.dart`、
  `lib/services/impersonate.dart`、`lib/services/chat_export_files.dart`、
  `lib/screens/personas_screen.dart`、`lib/screens/authors_note_screen.dart`、`test/v17_test.dart`。
- 改造文件：`lib/services/macros.dart`（重写）、`lib/services/prompt_builder.dart`、
  `lib/services/chat_export.dart`、`lib/services/storage.dart`、`lib/screens/chat_screen.dart`、
  `lib/screens/settings_screen.dart`。

## 本轮变更（v0.16.0）

### 1. 用户人设（Persona）

- `lib/services/user_personas.dart`：`UserPersona{id,name,description}` + `PersonaStore`
  （`load/save/find/active/activeName/activeDescription/setActive/upsert/remove/ensureSeeded`）。
  选中人设会同步 `AppSettings.userName`，所以历史渲染、宏替换、导出都自动跟随人设名。
- `lib/services/storage.dart`：新增 `personasJson`（键 `user_personas`）、
  `activePersonaId`（键 `active_persona_id`）。
- `lib/screens/personas_screen.dart`：列表 + 选用（单选）+ 新建/编辑（名字 + 设定）+ 删除；
  首次进入把设置里的名字包成一条默认人设。
- `lib/screens/settings_screen.dart`：聊天分节新增「用户人设」入口（显示当前人设摘要），
  返回后刷新「你在对话中的称呼」。
- `lib/services/prompt_builder.dart`：system 在角色设定之后插入
  `用户「<名字>」的设定：` + 人设描述；`{{user}}` 用人设名。

### 2. 作者注释（Author's Note）

- `lib/services/authors_note.dart`：`AuthorNote{content,enabled,depth(0..20),role(system/user),placement}`
  + `AuthorNoteStore`（会话级 map `convId → note` + `defaultNote` 默认注释）。
  存储键：`author_notes`、`author_note_default`。
- 插入位置：`afterScenario` = 写进 system（角色设定之后、示例对话之前）；
  `inChat` = 插进历史，`depth 0` 追加在最末尾，`depth n` 插在倒数第 n 条之前。
- `lib/screens/authors_note_screen.dart`：内容编辑、启用开关、位置切换、深度步进、角色切换、
  保存、恢复默认。
- 聊天菜单新增「作者注释」（副标题显示当前状态），保存后回聊天页重新载入。

### 3. 宏增强（`lib/services/macros.dart`）

`applyMacros(text,{charName,userName,personaText,cardFields,now,random})` 支持：
`{{char}}` / `<BOT>`、`{{user}}`、`{{persona}}`（未设置回落用户名）、
`{{description}}` / `{{personality}}` / `{{scenario}}`、
`{{time}}` / `{{date}}` / `{{weekday}}` / `{{isotime}}`、
`{{random::a::b}}` / `{{random:a,b}}` / `{{random}}`(0–99) / `{{pick::…}}`、
`{{newline}}`、`{{trim}}`、`{{// 注释}}`、`<START>`；未知宏原样保留。
PromptBuilder 的 system / 历史渲染 / 世界书内容都会过宏。

### 4. 替我说一句（Impersonate）

- `lib/services/impersonate.dart`：`kImpersonateInstruction`、`withImpersonateInstruction()`、
  `normalizeImpersonation()`（去前缀/引号/代码围栏/多余空行，>500 字截断）。
- `lib/screens/chat_screen.dart`：输入栏左侧新增 `record_voice_over` 按钮；
  `_impersonate()` 用独立 `ApiClient` 非流式请求，结果**只填进输入框**，不自动发送；
  生成中转圈、`_stop` 时取消、页面 dispose 时释放。

### 5. 导出对话文件

- `lib/services/chat_export.dart`：新增 `buildExportJson()`（format `litetavern-chat`、version 1、
  保留 variants/variantIndex、跳过空内容）与 `safeExportName()`。
- `lib/services/chat_export_files.dart`：写临时文件（`liteTavern_<名字>_<时间>.txt|json`）→
  `SharePlus.instance.share(...)` → 删除临时文件。
- 聊天菜单新增「导出对话文件…」：底部弹层选纯文本 / JSON。

## 验证

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | 见下方「本次运行记录」 |
| `flutter test` | 见下方「本次运行记录」 |
| `flutter build apk --release` | 见下方「本次运行记录」 |
| 真机安装 | 见下方「本次运行记录」 |

## 真机自测清单（装上新包后）

1. 设置 → 聊天 → 用户人设：新建一套（名字 + 设定），选中后开一个会话，确认角色用新名字称呼你、
   且回复内容受设定影响。
2. 聊天 ⋮ → 作者注释：写「回复控制在 3 段以内」，分别试「设定之后」和「聊天内 深度 0」，
   确认下一条回复变短、且聊天记录里看不到这段注释。
3. 输入框左侧 `record_voice_over`：点一下等 1–3 秒，确认输入框出现一句「你」的话；
   改一改再发出去，确认正常生成。
4. 聊天 ⋮ → 导出对话文件：分别导出 .txt 与 .json，用系统分享保存到文件管理器，确认能打开。
5. 宏：在角色卡 description 或世界书里写 `{{time}}`、`{{random::A::B}}`、`{{persona}}`，
   在「查看发送内容」里确认被替换；未知宏应保持原样。

## 已知边界

- 人设描述过长会占 system 预算，暂无长度提示（建议 < 300 字）。
- 作者注释 inChat 的说明按「深度 0 = 最末尾」实现；与 SillyTavern 的 depth 语义一致，
  但界面文案与早期文档表述不同，改文案时注意同步。
- 替我说一句不写入 token 统计（页面私有临时请求），失败只 toast 不弹窗。
- 导出文件依赖系统分享；无分享目标的设备会提示「当前设备不支持分享文件」。
- 未做（已知缺失，留给后续）：对话分支/多聊天文件、书签、TTS/STT、图像生成、
  向量长期记忆、Web 搜索、Regex 输出替换、背景图/深度主题定制、扩展系统。

## 环境与命令

```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
C:\flutter\bin\flutter.bat analyze
C:\flutter\bin\flutter.bat test
C:\flutter\bin\flutter.bat build apk --release
C:\Users\28351\Android\Sdk\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-release.apk
```

- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`（不在 PATH）；真机 23113RKC6C，
  无线调试地址曾为 `192.168.0.105:38767`。
- 真机点按请用**视觉坐标**（uiautomator 的 bounds 常与视觉位置不符）。

## 本次运行记录（2026-11-22 20:20）

| 项目 | 命令 | 结果 |
| --- | --- | --- |
| 静态检查 | `flutter analyze` | **No issues found!**（5.1s） |
| 单元/组件测试 | `flutter test` | **+256 All tests passed!**（其中 test/v17_test.dart 26 例） |
| Release 构建 | `flutter build apk --release` | 成功，`58.9 MB`，versionCode **14** / versionName **0.16.0**（Gradle 44.3s） |
| 真机安装 | `adb install -r` | **未完成**：`adb devices` 为空，无线调试 `192.168.0.105:38767` 连接超时（10060）；手机仍为 0.15.1 之前的版本 |

装上新包后按上面「真机自测清单」5 步验证即可。

