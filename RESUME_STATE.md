# 交接状态：v0.32.0 卡生态与只读状态（CHARX / .jsonl 导入 + 导入体检）（2026-11-27 更新）

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
> v0.31.0（SillyTavern 兼容模式：预设提示词真实注入）。
>
> **本轮 v0.32.0 —— 评估清单 R7（卡生态与只读状态）**：
> 1. **CHARX 导入**：把 SillyTavern v3 的压缩卡（zip）解出来，找 `card.json`、
>    取包内体积最大的图片当头像，其余资源只计数不导入。
> 2. **SillyTavern `.jsonl` 聊天导入**：聊天页 ⋮ →「导入聊天记录」，
>    按 `is_user` / `name` 分角色，读 `send_date`（ISO 字符串或秒级 / 毫秒时间戳），
>    接在当前对话后面。
> 3. **导入体检报告**：导入角色卡或聊天后弹「导入体检」，
>    给出「可用 / 部分可用 / 只保留」，并逐条说明缺了什么、
>    哪些扩展（regex_scripts / mvu / depth_prompt / tavern_helper / st-script 等）不会执行、
>    哪些字段只是只读保留（变量与状态系统本轮只做「只读提示」，不做编辑与回退）。
> 4. **顺手修的坑**：Android 的 file_picker 遇到 `.charx` / `.jsonl` 这种它不认识的扩展名
>    会直接抛 `PlatformException(Unsupported filter)`，导致点了没反应。
>    新增 `lib/services/file_pick.dart` 的 `pickFilesWithExtensions`：
>    先按扩展名过滤，失败自动退回「任意文件」，导入前照旧按内容校验。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.32.0+33**，`lib/app_info.dart` `kAppVersion = '0.32.0'`。
- 本轮新增文件：
  - `lib/services/import_report.dart`：
    - `enum ImportFit { usable, partial, preserveOnly }` + `ImportFitLabel`（label / isWarning）；
    - `ImportFinding{title, detail, isWarning}`、`ImportReport{fit, summary, findings, hasWarnings}`、`ImportReport.empty`；
    - `ImportAnalyzer.forCard(raw, card, {hasAvatar, assetCount})`：检查描述 / 开场白 / 性格场景系统提示 / 示例对话，
      列出卡内世界书、备用开场白、头像、CHARX 资源数，并按 `knownCardKeys` + `unsupportedExtensions`
      分出「不支持的扩展」「其它扩展字段（只读）」「未识别的字段（只读）」；
    - `ImportAnalyzer.forChat(messages, {rawLineCount, skippedLines})`：条数 / 双方条数 / 跳过行 / 额外行 / 角色不明。
  - `lib/services/charx_importer.dart`：
    - `CharxFormatException`、`CharxImportResult{card, avatarBytes, report, assetCount}`；
    - `CharxImporter.looksLikeZip` / `isCharxName` / `parse(bytes, {filename})` / `toParseResult`；
      卡 JSON 先按 `card.json` → `chara_card_v3.json` → `character.json` → `data/card.json` → `data/character.json`，
      再退到「任意非 assets 下能解出 name 的 .json」。
  - `lib/services/st_chat_importer.dart`：
    - `StChatFormatException`、`StChatImportResult{messages, report, lineCount, skippedLines}`；
    - `StChatImporter.isJsonlName` / `looksLikeJsonl` / `parse(bytes, {charName, userName})`。
  - `lib/services/file_pick.dart`：`pickFilesWithExtensions(extensions, {allowMultiple})`（过滤失败退回任意文件）。
  - `lib/widgets/import_report_dialog.dart`：`showImportReportDialog(context, report, {title, subtitle})`。
  - `test/v32_test.dart`：18 例（体检报告、CHARX zip 造包与头像挑选、jsonl 解析 / 时间戳 / 跳过行 / 错误）。
- 本轮修改：
  - `lib/services/card_importer.dart`：新增 `ImportedCard{card, report}` 与 `importCardFile`（CHARX 自动分流），
    `importCardBytes` 保持旧签名给市场 / 链接用。
  - `lib/screens/home_screen.dart`：文件选择加 `.charx`（走 `pickFilesWithExtensions`），
    `_importBytes` 用 `importCardFile` 并在有提醒 / 非可用时先弹体检报告；导入弹窗文案补 `.charx`。
  - `lib/screens/chat_screen.dart`：菜单新增「导入聊天记录」（`.jsonl`）：选择 → 确认条数 →
    追加到当前会话 → 清 `_msgCache` → 保存 → 体检报告。
  - `CHANGELOG.md`、`docs/FEATURE_AUDIT.md`（角色卡行 ✅、MVU 行 🟡 只读提示、R7 ✅）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | +463 All tests passed! |
| `flutter build apk --release` | 60.8MB，versionCode **33** / versionName **0.32.0** |
| 模拟器（Android 14，emulator-5556） | `install -r` Success，versionCode 33 / 0.32.0 |
| CHARX 导入（真机流程：文件选择 → 导入 → 体检） | ✅ 角色卡进入主页（头像取包内图），体检弹窗显示「可用」+「随身资源 1 个」+「不支持的扩展 mvu、regex_scripts」+「未识别的字段 unknown_extra」 |
| `.jsonl` 导入 | ✅ 选中 `chat_test.jsonl` → 确认「要导入 3 条消息吗」→ 3 条接在对话后面（2 你 / 1 角色），体检显示「可用 / 跳过 1 行」 |
| 文件选择器兼容 | ✅ 修复前 `.jsonl` 直接抛 Unsupported filter；修复后自动退回任意文件并可选中 |

## 已知边界

- CHARX 只取一张头像图，其它资源不导入；卡内脚本、变量系统不执行（体检里会提示「不生效」）。
- `.jsonl` 里认不出的行会计入「跳过 N 行」；没有 `is_user` 时按 `name` 与角色名 / 用户名比对判断。
- 体检报告只是提示，不阻断导入（除了连卡名都解析不出来的坏文件会直接报错）。
- `pickFilesWithExtensions` 在过滤失败时退回「任意文件」，用户会看到全部文件——导入前仍按内容校验。

## 环境与常用命令

```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release
$adb='C:\Users\28351\Android\Sdk\platform-tools\adb.exe'
& $adb devices -l
& $adb -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk
```

- 模拟器：`C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556`
- 本地假接口：`python build/mock_llm.py`（端口 8765，模拟端 `http://10.0.2.2:8765/v1`）
- 中文输入：`adb shell am broadcast -a ADB_INPUT_TEXT --es msg '文字'`（需先安装 ADBKeyboard 并设为输入法）
- 发 Release：用 `git credential fill` 取 token，单引号 here-string 拼 body，APK 上传地址直接拼
  `https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk`

## 下一轮建议

- 按 `docs/FEATURE_AUDIT.md` R8：变量与状态只读展示（不做回退语义）+ 卡内脚本安全提示（不执行）。
- 或者继续收尾：把体检报告扩展到世界书 / 预设导入。

## 本次运行记录（2026-11-27）

- analyze：No issues found!
- test：+463 All tests passed!
- build：60.8MB（63,727,863 字节），versionCode 33 / versionName 0.32.0
- 装机：`adb -s emulator-5556 install -r` → Success（versionCode 33 / 0.32.0）
- 真机不在手边，用 Android 14 模拟器点验 CHARX 与 .jsonl 两条导入链路
