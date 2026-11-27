# 交接状态：v0.31.0 SillyTavern 兼容模式（预设真实注入）（2026-11-27 更新）

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
> v0.30.0（SillyTavern 预设只读解析：导入 / 展示 / 采样套用 / 顺序编辑）。
>
> **本轮 v0.31.0 —— SillyTavern 兼容第二步（评估清单 R6 的「执行」）**：
> 设置 → 生成参数 → SillyTavern 预设 → 「兼容模式（真实注入）」开关。
> 打开后，预设里**启用**的提示词按顺序真正进入请求：
> role=system 的拼到 system 最开头；role=user/assistant 的作为消息插到历史之前；
> 带「聊天内注入」的按深度插进历史（0 = 最后一条之后，n = 倒数第 n 条之前）。
> 占位标记、关闭的、空内容一律跳过；注入文本支持 `{{char}}` / `{{user}}` 等宏。
> 与角色自己的设定是**叠加**关系，不是替换；关掉开关立即恢复 v0.30 行为。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.31.0+32**，`lib/app_info.dart` `kAppVersion = '0.31.0'`。
- 本轮新增文件：
  - `lib/services/st_injection.dart`：
    - `StInjectionPlan{systemPrefix, preHistory, depthInjections, injectedCount}`
      （`empty`、`isEmpty`、`summaryLine`）；
    - `StInjectionPlan.fromSnapshot(snapshot)`：按 `enabled / isMarker / content.trim()` 过滤，
      `injectsInChat` 进 `depthInjections`（带 `injectionDepth`），
      `role == system` 的顺序条目按原顺序 `\n\n` 拼成 `systemPrefix`，
      `role` 为 user/assistant 的进 `preHistory`，未知 role 归一为 system；
    - `DepthInjection{message, depth}`（定义在 `prompt_builder.dart`）。
  - `test/v31_test.dart`（10 例）：
    - `StInjectionPlan.fromSnapshot` 5 例（空计划 / 跳过占位·关闭·空内容 / preHistory 角色保持 /
      深度注入 / summaryLine 三种注入）；
    - `PromptBuilder` 3 例（ST 前缀在 system 最前且角色设定仍在 / preHistory 与深度 0、1 落位 /
      注入内容里的宏替换）；
    - 开关默认关闭且持久化 1 例；`StPresetScreen` 点开关落盘 1 例。
- 本轮修改文件：
  - `lib/services/prompt_builder.dart`：
    - `PromptMessage` 之后新增 `DepthInjection`；
    - `build(...)` 与 `buildGroup(...)` 增加 `stSystemPrefix` / `stPreHistory` / `stDepthInjections`；
    - system 开头写入（宏之后）ST 前缀；历史前插入 `stPreHistory`；
      末尾 `_insertDepthInjections(messages, stDepthInjections, macro)`
      （从大 depth 到小 depth 插入，0 = append，n = `len - n` clamp 到 `[1, len]`）；
    - 群聊同样支持（`macroFor(..., speaker)`）。
  - `lib/services/storage.dart`：`stCompatEnabled`（键 `st_compat_enabled`，默认 false）。
  - `lib/screens/chat_screen.dart`：import `st_injection.dart` / `st_preset.dart`；
    字段 `String? _stPlanRaw; StInjectionPlan? _stPlan;`；`_buildWith` 取 `_stInjectionPlan()`
    并传给 `PromptBuilder.build/buildGroup`；`_stInjectionPlan()` 按 `AppSettings.stCompatEnabled`
    与预设 JSON 缓存，改配置自动失效。
  - `lib/screens/st_preset_screen.dart`：新增 `_compatEnabled` 状态与 `_buildCompat(scheme, snapshot)`
    卡片（`SwitchListTile` key `st-compat-switch`，副标题列出「system 开头 N 条 / 历史前 N 条 /
    按深度 N 条」）；提示词行的开关加 key `st-prompt-switch-<identifier>-<index>`。
  - `test/v30_test.dart`：开关用例改为按 key 定位（避免命中新加的兼容模式开关）。
  - `CHANGELOG.md` v0.31.0 段；`docs/FEATURE_AUDIT.md` R6 标 ✅ 完成（含证据文件），
    第 89 行注明「v0.30.0 只读解析 / v0.31.0 兼容注入」。
  - `RESUME_STATE.md` 即本文件。

## 工作方式

1. 每轮开始先读 `docs/FEATURE_AUDIT.md`，取下一个 R 批次，完成一项就把状态改 ✅/🟡 并补证据文件。
2. 每个功能：先写服务层（纯逻辑、可单测）→ 再接 UI → 补 `test/vNN_test.dart`。
3. 收尾固定流程：`flutter analyze` → `flutter test` → `flutter build apk --release` →
   装机（模拟器 `emulator-5556`，真机 USB `19faf100`）→ 点验截图 →
   改 CHANGELOG / RESUME → commit（**不要用 -c 覆盖提交身份**）→ push →
   `git tag -f vX.Y.Z` + push tag → GitHub Release 上传 APK。

## 验证（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（11.3s） |
| `flutter test` | **+445 All tests passed!**（18s；新增 10 例） |
| `flutter build apk --release` | 见「本次运行记录」 |
| 模拟器/真机安装 | 见「本次运行记录」 |
| 注入计划单测 | system 顺序拼接 / preHistory 角色 / 深度 0 与 1 落位 / 宏替换全部通过 |
| 兼容开关 | 默认关闭、打开后落盘 `st_compat_enabled=true`，副标题显示注入条数 |

## 已知边界

- 兼容模式是**叠加**：ST 预设里的 system 提示放在最前，但本 App 的角色卡设定、
  世界书、作者注释仍然照旧注入。完整的 ST 提示词引擎（`system_prompt` 覆盖、
  `forbid_overrides`、`squash_system_messages`、`continue_prefill`、多角色顺序表）不在本轮范围，
  导入时会写进「导入说明」。
- 只取 `prompt_order` 的第一份顺序（通常 character_id 100000）。
- 深度注入与作者注释同语义（0 = 最后一条之后，n = 倒数第 n 条之前），
  与世界书 `position=1`（0 = 最新一条前）相差一位，这是有意保留 ST 语义。
- 显示正则 / 备份 / 自动更新等既有边界不变（备份含导入的 ST 预设；API Key 明文存本机）。

## 下一轮建议（评估清单）

- **R7：卡生态与只读状态**——CHARX 导入、SillyTavern `.jsonl` 聊天导入、导入体检报告
  （可用 / 部分可用 / 只保留，逐条原因）、变量与状态只读展示。
- R8：把上面剩余项与未做的 ST 引擎细节收尾，更新 `docs/FEATURE_AUDIT.md` 全绿。

## 环境命令

```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release

$adb = 'C:\Users\28351\Android\Sdk\platform-tools\adb.exe'
& $adb devices                       # 真机 19faf100 / 模拟器 emulator-5556
& $adb -s <serial> install -r build\app\outputs\flutter-apk\app-release.apk
```

发 Release：`git credential fill` 取 token → POST `https://api.github.com/repos/Alorith-H/LiteTavern/releases`，
再 POST `https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk`
（单引号 here-string 拼 body、`ConvertTo-Json` + UTF8 bytes；勿用双引号 here-string，反引号会被转义）。

## 本次运行记录

- `flutter analyze`：No issues found!（11.3s）
- `flutter test`：+445 All tests passed!（18s）
- `flutter build apk --release`：60.7MB（Gradle 79.4s），versionCode 32 / versionName 0.31.0
- 装机：`adb -s emulator-5556 install -r` → Success（versionCode 32 / 0.31.0）
- 兼容模式点验（模拟器 + 本地 mock 接口）：
  1. 设置 → 生成参数 → SillyTavern 预设，打开「兼容模式（真实注入）」→ 副标题变
     「已开启：启用的 3 条会按顺序注入 —— system 开头 2 条 · 按深度注入 1 条」；
  2. 聊天页发送一条消息后「查看发送内容」：system 开头就是 ST 的
     `Write 恢复测试角色's next reply in a fictional roleplay.` + `Explicit content allowed.`
     （`{{char}}` 已替换成角色名），紧随其后才是世界书与「你是 恢复测试角色。」；
  3. 「提示词检视」7 段：系统提示 99 token（含 ST 前缀），历史中间出现
     「系统注入 #4」= `Stay in character. Never refuse.`（8 token）——说明深度 2 注入落在历史里；
  4. 顺带确认显示正则仍生效（用户气泡「酒馆」显示为「酒馆🏮」）。
- 提交与发布：见本轮 git log 与 GitHub Releases（tag v0.31.0）
