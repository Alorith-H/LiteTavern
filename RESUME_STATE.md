# 交接状态：v0.34.0 每聊天生成参数覆盖（2026-11-27 更新）

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
> v0.32.0（CHARX 导入、`.jsonl` 聊天导入、导入体检报告）、v0.33.0（变量与状态只读、卡内脚本安全提示）。
>
> **本轮 v0.33.0 —— 评估清单 R8（变量与状态只读 + 卡内脚本安全提示）**：
> 1. **角色卡保留 `extensions` 字段**：导入 / 编辑 / 导出不再丢扩展信息（旧卡不受影响，
>    没有扩展时也不会往 JSON 里写空对象）。
> 2. **变量与状态（只读）**：聊天页 ⋮ →「变量与状态」。读卡扩展里的初始变量
>    （`extensions.mvu.initialVariables` / `extensions.variables` / 正文里的 `[InitVar]{...}`），
>    再合并对话里的状态更新块（`<UpdateVariable>` / `<UpdateVariableBlock>` / `<JSONPatch>`），
>    拍平成 `分组.变量 = 值` 展示。支持 JSON Patch 的 add / replace / remove 子集。
> 3. **卡内脚本安全提示**：识别 `regex_scripts` / `tavern_helper` / `mvu` / `st-script` 等
>    脚本类扩展，以及正文里的 `<script>` / `<iframe>` / `onerror=` / `javascript:` 片段，
>    明确写「只读展示、不会执行、不会渲染」。
> 4. **边界**：变量只读、不参与提示词、不写回对话；不支持变量编辑与 MVU 回退语义；
>    卡内脚本永不执行（这是产品选择，不是没做完）。
>
> **本轮 v0.34.0 —— 评估清单「每聊天预设覆盖」（6 个采样键）**：
> 1. 聊天页 ⋮ →「这段聊天的生成参数」：给这一段聊天单独设 temperature / top_p / top_k /
>    max_tokens / frequency_penalty / presence_penalty；留空 = 跟随全局生成预设。
> 2. 覆盖只作用于这一段聊天的生成（含「重新生成」「继续生成」「替我说一句」）；
>    菜单副标题显示当前覆盖（如「覆盖 t1.3 · k40」），随时点「全部恢复」回到跟随全局。
> 3. 存储：`AppSettings.chatPresetOverridesJson`（prefs 键 `chat_preset_overrides`，
>    `{convId: {temperature, top_p, top_k, max_tokens, frequency_penalty, presence_penalty}}`），
>    空覆盖会删键，坏 JSON 回退空。解析逻辑在 `lib/services/chat_gen_settings.dart`。
> 4. 边界：只覆盖这 6 个键，重复惩罚 / min_p / seed / stop 仍跟全局预设；群聊每段聊天各自独立。
>
## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.34.0+35**，`lib/app_info.dart` `kAppVersion = '0.34.0'`。
- 本轮新增文件：
  - `lib/services/mvu_state.dart`：
    - `MvuValue{name, value}`、`MvuSnapshot{values, updateCount, initCount}`（`isEmpty` / `entries` / `groupOf`）；
    - `MvuStateReader.fromCard(card)`：读 `extensions.mvu` 的
      `initialVariables` / `initial_variables` / `variables` / `initvar` / `state` / `stats`，
      读 `extensions.variables`，再读开场白 / 系统提示里的 `[InitVar]{...}`；
    - `MvuStateReader.fromMessages(messages, {base})`：找
      `<UpdateVariable>` / `<UpdateVariableBlock>` / `<JSONPatch>` 三种块，Map 直接合并，
      List 当作 JSON Patch（add / replace / remove），坏 JSON 跳过不抛；
    - 补丁路径优先匹配「扁平点号键」（如已有 `stats.好感度` 时，`/stats/好感度` 直接改它，
      不会再建一层 `stats` 造成两行同名变量）。
  - `lib/services/card_scripts.dart`：`ScriptFinding`、`CardScriptScan`（`hasScript` / `summary` / `findings`）、
    `CardScriptScanner.scan(card)` 与 `scanAll(cards)`（群聊合并，正文片段带角色名前缀）。
  - `lib/screens/card_state_screen.dart`：`CardStateScreen({cards, messages})` —— 只读说明卡、
    「卡内初始变量」表、「对话里读到的状态」表（无更新块时只提示，不重复列表）、
    「卡内脚本与动态内容」提示区；值用 `SelectableText` 方便复制。
  - `test/v33_test.dart`：16 例（扩展字段往返 / 拷贝 / withId；卡内变量解析三种来源；
    会话更新 Map / JSON Patch / 坏 JSON / 多条累积；脚本扩展与正文 HTML 识别、干净卡、群聊合并；
    页面正常渲染与空态）。
- 本轮修改：
  - `lib/models/character_card.dart`：新增 `final Map<String, dynamic> extensions`（构造默认 `const {}`），
    `fromJson` 读 `data['extensions']` 或顶层，`toJson` 非空才写，`copyWith` / `withId` 透传，
    新增 `_parseExtensions`。
  - `lib/screens/chat_screen.dart`：菜单「世界书绑定」之后新增「变量与状态」入口；
    新增 `_openCardState()`（单聊用 `_card`，群聊用 `_members`）。
  - `CHANGELOG.md`（v0.33.0 段）、`docs/FEATURE_AUDIT.md`（MVU 行 ✅、R8 ✅、卡内脚本行补安全提示说明）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found! |
| `flutter test` | +479 All tests passed! |
| `flutter build apk --release` | 61.0MB，versionCode **35** / versionName **0.34.0** |
| 模拟器（Android 14，emulator-5556） | `install -r` Success，versionCode 35 / 0.34.0；mock 接口 body 确认 `temperature 1.3 / top_k 40` 生效 |
| 变量与状态页（卡内变量） | ✅ 导入含 `extensions.mvu.initialVariables` 与 `[InitVar]` 的测试卡，页面显示 `stats.好感度 0 / stats.体力 100 / 金币 10 / 天气 晴` |
| 变量与状态页（会话更新） | ✅ 用 `.jsonl` 导入一条带 `<UpdateVariable>{"stats":{"好感度":7,"体力":90}}</UpdateVariable>` 的消息后，页面显示「找到 1 个状态更新块」，数值变为 `7 / 90`，未涉及的 `金币 / 天气` 保持原值 |
| 卡内脚本提示 | ✅ 同一张卡显示「卡内脚本扩展：mvu、regex_scripts」+「轻酒馆只读取、不运行它们」说明 |
| 导入体检（回归） | ✅ 导入该卡时弹「可用 / 有 1 处小提醒」+「不支持的扩展 mvu、regex_scripts」 |

## 已知边界

- 变量只读：不参与提示词、不写回对话、不能编辑，也没有 MVU 的「回退 / 重算」语义。
- 卡内脚本永不执行（包括 regex_scripts / tavern_helper / st-script 等），只看提示。
- `<UpdateVariable>` / `<JSONPatch>` 只认 JSON；不是 JSON 的块会被静默跳过（`updateCount` 只统计解析成功的块）。
- 变量名用「点号拼接」的扁平形式展示（`stats.好感度`），嵌套层级原样保留但只做只读展示。
- 群聊时合并所有成员的卡内变量与所有成员的脚本提示；同名变量按出现顺序后者覆盖前者。

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
- 推测试文件：`adb push build\xxx.json /sdcard/Download/xxx.json`
- 发 Release：用 `git credential fill` 取 token，单引号 here-string 拼 body，APK 上传地址直接拼
  `https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk`

## 下一轮建议

`docs/FEATURE_AUDIT.md` 里 A–D 组已完成 R1–R8，剩余项按「本地可做、风险低」排序：

1. **每聊天预设覆盖（6 个采样键）**：给每段聊天单独的 temperature / top_p / max_tokens 等覆盖，
   优先级「聊天 > 全局预设」，界面放在聊天菜单或设置里。
2. **群聊主持**：发言名单 / 顺序 / 「让大家接着说」，在下一条消息前可调整谁先说。
3. **缓存命中 / 费用估算统计**：在聊天统计里补缓存命中率与按模型单价估算花费（单价可让用户填）。
4. E 组（TTS / 图像生成 / 向量记忆 / Web 搜索 / Live2D / 卡内脚本执行）仍按原计划暂不做。

## 本次运行记录（2026-11-27）

- analyze：No issues found!（9.0s）
- test：+479 All tests passed!（17s）
- build：61.0MB，versionCode 35 / versionName 0.34.0
- 装机：`adb -s emulator-5556 install -r` → Success（versionCode 35 / 0.34.0）
- 真机不在手边，用 Android 14 模拟器点验「变量与状态」页两段状态与脚本提示
