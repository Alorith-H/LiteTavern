# 交接状态：v0.30.0 SillyTavern 预设导入（只读解析 + 采样套用）（2026-11-27 更新）

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
> v0.29.0（显示正则库：导入 ST 正则 / 作用域 / 试一下 / 只改显示）。
>
> **本轮 v0.30.0 —— SillyTavern 预设兼容第一步（评估清单 R6 的「只读解析」）**：
> 设置 → 生成参数 → SillyTavern 预设：从文件或粘贴导入 ST 预设 JSON，
> 解析采样参数（可一键套用到当前生成预设，超范围自动收敛）与提示词顺序
> （按 `prompt_order` 展示、逐条开关、上移下移、退出后保留）；
> 不认识的字段不报错，在「导入说明」里列出哪些本轮不参与。
> **本轮不注入**这些提示词——执行阶段（兼容模式）留给下一步。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.30.0+31**，`lib/app_info.dart` `kAppVersion = '0.30.0'`。
- 本轮新增文件：
  - `lib/services/st_preset.dart`：
    - `StPromptItem`（identifier / name / role（system|user|assistant）/ content /
      isMarker / isSystemPrompt / injectionPosition / injectionDepth / enabled；
      `hasContent`、`injectsInChat`、`roleLabel`、`orderNote`、`preview`、`copyWith(enabled)`）；
    - `StPresetSnapshot`（name + 采样字段 + prompts + warnings；
      `hasSampling`、`samplingCount`、`enabledCount`（只算非占位且启用）、`markerCount`、
      `samplingRows`（界面逐行）、`copyWith(prompts)`、`toJson` / `toJsonString` / `fromJson`、
      `tryParseStored`）；
    - `StPresetParser.parse(raw, {fallbackName})`：支持整份预设与 `{preset:{...}}` 包裹；
      读 `temperature/top_p/top_k/frequency_penalty/presence_penalty/repetition_penalty/
      min_p/max_tokens（或 openai_max_tokens）/seed/stop（或 stopstrings/stop_strings）`；
      `prompts` 数组映射 + 未知 role 落 system 并记 warning；
      `_applyOrder` 按第一份 `prompt_order`（character_id 100000 那种）重排并带 enabled，
      顺序表里缺失的条目保持原相对顺序追加；顺序表引用不存在的 identifier 记 warning。
  - `lib/screens/st_preset_screen.dart`：`StPresetScreen`
    （AppBar：文件导入 / 粘贴 JSON / 清除；空态引导；摘要卡「采样参数 N 项 · 提示词 M 条」；
    采样参数表 + 「套用到当前生成预设」；导入说明（warnings）；提示词顺序列表
    `ExpansionTile` + 序号 + 角色/占位/深度徽章 + 开关 + 上移下移 + 展开看正文）。
  - `test/v30_test.dart`（11 例：解析采样与顺序、越界/未知 role/忽略字段进 warnings、
    无 prompt_order 保序、`{preset:{}}` 与 stopstrings、坏 JSON / 空 prompts 抛错、
    快照 JSON 往返、坏存储回 null、套用采样写入 AppSettings（含越界收敛）、
    开关与上移落盘、清除删除存储）。
- 本轮修改文件：
  - `lib/services/storage.dart`：`stPresetJson` / `setStPresetJson(String?)`，键 `st_preset`。
  - `lib/screens/settings_screen.dart`：生成参数子页「高级设置」之后新增
    「SillyTavern 预设」入口 → `_openStPreset()`；返回后 `_syncFromSettings()`
    （修掉「套用采样后滑条仍显示旧值」的问题）。
  - `CHANGELOG.md` 新增 v0.30.0 段；`docs/FEATURE_AUDIT.md` 第 42 行 → 🟡（已导入/展示/套用采样，
    执行待下一步）、R6 行注明只读解析已 ✅。
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
| `flutter analyze` | No issues found!（8.7s） |
| `flutter test` | **+435 All tests passed!**（12s；新增 11 例） |
| `flutter build apk --release` | 60.7MB，versionCode 31 / versionName 0.30.0 |
| 模拟器安装 | `adb -s emulator-5556 install -r` → Success |
| 导入 | Downloads 里的 `st_preset.json` → 「已解析「ST 测试预设」：4 条提示词」 |
| 摘要 | 「采样参数 6 项 · 提示词 4 条（启用 2 条）」；顺序与占位/深度徽章正确 |
| 套用采样 | 确认框列出 6 项 → 套用后生成参数变 `t1.1 · p0.9 · 上限 400`、随机度 1.10、采样范围 0.95 |
| 顺序编辑 | 打开 NSFW 开关 → 返回再进仍显示「启用 3 条」（落盘生效） |

## 已知边界

- 本轮**不注入** ST 提示词：不改变实际发给模型的内容（下一步「兼容模式」才接）。
- 只取 `prompt_order` 的第一份顺序（通常 character_id 100000）；多角色各自的顺序表不支持。
- `marker` 条目只展示不可开关；`injection_trigger`、`forbid_overrides`、
  `squash_system_messages`、`continue_prefill` 等字段本轮不参与，会写进「导入说明」。
- 套用采样时按本 App 取值范围收敛（温度 0–2、topP 0–1、topK 0–200、penalty 0–2、
  repetition 1–2、minP 0–0.5、stop ≤4 条）。
- 显示正则 / 备份 / 自动更新等既有边界不变（备份含导入的 ST 预设；API Key 明文存本机）。

## 下一轮建议（评估清单）

- **R6 第二步：兼容模式执行**——把启用的 ST 提示词按顺序拼进 system（或按注入深度插进历史），
  加开关可退回自研提示词；注意 `{{char}}/{{user}}` 宏与 `system_prompt` 覆盖。
- 之后 R7：CHARX 导入、SillyTavern `.jsonl` 聊天导入、导入体检报告（坏卡逐条原因）。

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

- `flutter analyze`：No issues found!（8.7s）
- `flutter test`：+435 All tests passed!（12s）
- `flutter build apk --release`：60.7MB，versionCode 31 / versionName 0.30.0
- 装机：`adb -s emulator-5556 install -r` → Success；导入 / 套用采样 / 顺序编辑三处点验通过
- 提交与发布：见本轮 git log 与 GitHub Releases（tag v0.30.0）
