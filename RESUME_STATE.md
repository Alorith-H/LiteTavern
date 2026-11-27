# 交接状态：v0.29.0 显示正则库（2026-11-27 更新）

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
> v0.28.0（提示词检视升级：缓存断点 + 省钱排序）。
>
> **本轮 v0.29.0 —— 显示正则库（评估清单 R6）**：
> 设置 → 聊天与上下文 → 显示正则：导入 SillyTavern 正则 `.json`、逐条开关、
> 作用范围（全部 / 只对你 / 只对角色）、`i m s u` 标志与 `$1` `${1}` `$&` 分组引用、
> 「试一下」实时看替换前后对比、复制 JSON 到剪贴板。
> **只改「看到的内容」**：本地原文、导出、发给模型的提示词都不变（气泡渲染时套用）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.29.0+30**，`lib/app_info.dart` `kAppVersion = '0.29.0'`。
- 本轮新增文件：
  - `lib/services/display_regex.dart`：
    - `RegexScope { all, user, assistant }` + `RegexScopeLabel`（`label` / `id` / `fromId`）；
    - `DisplayRegex`（id / name / pattern / flags / replacement / enabled / scope）：
      `compile()`（支持 i/m/s/u，非法返回 null）、`hasError`、`matchesScope({isUser})`、
      `apply(text)`（`replaceAllMapped` + `_expandReplacement`：`$1`、`${1}`、`$&`、`$$`）、
      `toJson()`（写 SillyTavern 兼容的 `scriptName` / `findRegex: "/pattern/flags"` /
      `replaceString` / `disabled` / `scope`）、`fromSillyTavern(raw, {fallbackId})`、
      `splitFindRegex(raw)`（解析 `/pattern/flags`，只认 `imsu`）；
    - `DisplayRegexLibrary`：`all`（解析 `AppSettings.displayRegexesJson` + 内存缓存）、
      `invalidate()` / `resetForTest()`、`save` / `upsert` / `remove`、`sorted()`、
      `apply(text, {isUser})`（按顺序，跳过禁用与作用域不匹配）、
      `importFromJson(raw)`（数组 / `{entries:[...]}` / 单对象；同 id 覆盖，返回新增条数）。
  - `lib/screens/display_regex_screen.dart`：`DisplayRegexScreen`
    （AppBar：导入 .json / 复制 JSON / 试一下；列表卡片含开关、编辑删除菜单、作用范围与
    flags 徽章、正则写错红标、pattern 与替换预览；空态引导；FAB 新建；
    `_RegexEditDialog` 带实时校验；`_RegexTestSheet` 选「你的话 / 角色的回复」并实时显示替换后）。
  - `test/v29_test.dart`（16 例：解析与 ST 映射、分组引用与标志、禁用/非法/作用域、
    链式应用、导入与同 id 覆盖、坏 JSON、页面展示/开关落盘/试一下）。
- 本轮修改文件：
  - `lib/services/storage.dart`：`displayRegexesJson` / `setDisplayRegexesJson(String?)`，
    键 `display_regexes`（空值删键）。
  - `lib/screens/settings_screen.dart`：聊天与上下文 → 「快捷回复管理」之后新增
    「显示正则 · 只改看到的内容：导入 ST 正则、开关、替换前后对比（v0.29.0）」入口。
  - `lib/screens/chat_screen.dart`：气泡正文改为
    `DisplayRegexLibrary.apply(m.content, isUser: isUser)`（只影响显示）。
  - `CHANGELOG.md` 新增 v0.29.0 段；`docs/FEATURE_AUDIT.md` 第 44 行显示正则库 → ✅、
    R5 行注明正则库已在 v0.29.0 完成。
  - `RESUME_STATE.md` 即本文件。

## 工作方式

1. 每轮开始先读 `docs/FEATURE_AUDIT.md`，取下一个 R 批次，完成一项就把状态改 ✅ 并补证据文件。
2. 每个功能：先写服务层（纯逻辑、可单测）→ 再接 UI → 补 `test/vNN_test.dart`。
3. 收尾固定流程：`flutter analyze` → `flutter test` → `flutter build apk --release` →
   装机（真机 USB `19faf100`，或模拟器 `emulator-5556`）→ 点验截图 →
   改 CHANGELOG / RESUME → commit（**不要用 -c 覆盖提交身份**）→ push →
   `git tag -f vX.Y.Z` + push tag → GitHub Release 上传 APK。

## 验证（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（7.7s） |
| `flutter test` | **+424 All tests passed!**（18s；新增 16 例） |
| `flutter build apk --release` | 60.5MB，versionCode 30 / versionName 0.29.0 |
| 模拟器安装 | `adb -s emulator-5556 install -r` → Success |
| 正则导入 | 从 Downloads 选 `rx.json` → 列表两条 + toast「已导入 2 条正则」 |
| 试一下 | 输入「我们去酒馆坐坐吧」→ 替换后「我们去酒馆🏮坐坐吧」 |
| 聊天显示 | 历史气泡显示「你好呀，今天一起去酒馆🏮吧」；mock 回复仍回显原文（证明提示词未变） |

## 已知边界

- 显示正则**只改显示**：不改本地原文、不改导出、不改发给模型的提示词（v0.29.0 有意如此）。
- JS 专属标志（如 `g`）会被忽略；不支持 ST 的「深度 / 只对前 N 条」等高级作用域，也不支持
  「发送前替换」——这些属于后续可选项。
- 非法正则不会生效，列表里标红提示，不影响聊天。
- 正则按列表顺序链式应用；同一段文本可能被多条规则依次改写，建议少而精。
- 备份 zip 含正则（`display_regexes` 在 prefs 里）。
- 其它沿用：API Key 存在本机、备份不加密、自动更新走 GitHub Releases、必应网页翻译按 IP 风控。

## 下一轮建议（评估清单）

- **R7 ST 预设兼容**（高风险）：导入 ST 预设 JSON，先做只读解析 + 展示
  （`prompts` / `prompt_order` / 注入位置与深度 / `system_prompt` 覆盖 / `continue_prefill` 子集），
  再逐步接到提示词组装，保留「兼容模式」开关可退回。
- 之后 R8：CHARX 导入、SillyTavern `.jsonl` 聊天导入、导入体检报告；变量与状态只读展示。

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

- `flutter analyze`：No issues found!（7.7s）
- `flutter test`：+424 All tests passed!（18s）
- `flutter build apk --release`：60.5MB，versionCode 30 / versionName 0.29.0
- 装机：`adb -s emulator-5556 install -r` → Success；模拟器点验导入 / 试一下 / 聊天显示三处通过
- 提交与发布：见本轮 git log 与 GitHub Releases（tag v0.29.0）
