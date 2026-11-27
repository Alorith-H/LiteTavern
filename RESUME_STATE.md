# 交接状态：v0.38.0 备份恢复可选内容（2026-11-28 更新）

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
> v0.38.0（备份恢复可选内容）。
>
> **本轮 v0.38.0 —— 评估清单「备份恢复可选内容」**：
> 1. **恢复前挑内容**：选完 .zip 后弹出「恢复哪些内容？」——角色卡（含头像）/ 聊天记录 /
>    世界书 / 群聊 / 设置（含 API Key、预设）五类，**勾哪几类就只恢复哪几类**，没勾的完全不动。
> 2. **看得见数量**：每类右侧显示备份里的文件数，底部实时显示
>    「将恢复：角色卡 2 · 聊天 1 · 世界书 0 · 群聊 1 · 设置 1 项」；可「全选 / 全不选」，
>    一项都没选时「恢复」按钮变灰并提示「至少选一项」。
> 3. **导出没变**：导出仍是整包；旧备份也能选着恢复。
> 4. **实现**：`BackupService.restoreBackup(..., options:)` 按目录过滤，
>    设置项只在勾了「设置」时才写回；`BackupRestoreOptions` 值对象 + 弹窗
>    `RestoreScopeDialog`（`lib/widgets/backup_sheet.dart`）。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.38.0+39**，`lib/app_info.dart` `kAppVersion = '0.38.0'`。
- 本轮新增 / 修改：
  - `lib/services/backup_service.dart`：`BackupArchive.fileCountIn(dir)`；
    新增 `class BackupRestoreOptions`（五类开关、`all`、`any`、`allowsDir`、`copyWith`、
    `selectedFileCount`、`summary`）；`restoreBackup` 增 `options` 参数（默认全选 = 旧行为），
    按目录过滤写盘、设置项受 `options.settings` 控制，全不选抛 `BackupException('没有选择要恢复的内容')`。
  - `lib/widgets/backup_sheet.dart`：恢复流程由「确认框」改为 `RestoreScopeDialog`
    （公开 class，`_RestoreScopeDialogState` 持有勾选状态），五条 `CheckboxListTile`
    + 数量 + 实时汇总 + 全选/全不选/取消/恢复；恢复完成的 SnackBar 区分
    「只恢复设置」（0 文件）与「恢复 N 个文件」。
  - `test/v38_test.dart`：9 例（`BackupRestoreOptions` 默认/`copyWith`/`any`/统计与 summary；
    只恢复聊天 → 角色卡不写、设置不动；只恢复设置 → 0 文件但设置被覆盖；
    全选等于旧行为；全不选抛错且不写盘；弹窗列出五类、全不选时「恢复」禁用）。
  - `CHANGELOG.md`（v0.38.0 段）、`docs/FEATURE_AUDIT.md`（数据组新增「恢复时可选内容」✅）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（10.4s） |
| `flutter test` | **+547 All tests passed!**（19s，含新增 9 例） |
| `flutter build apk --release` | **61.1MB**，versionCode **39** / versionName **0.38.0** |
| 模拟器装机 | `adb -s emulator-5556 install -r` → Success（code 39 / 0.38.0） |
| 弹窗点验 | 推入自造备份 `build/v38_backup.zip`（2 角色文件 + 1 聊天 + 1 群聊 + 1 设置）→ 设置 → 帮助与关于 → 备份与恢复 → 从备份恢复 → 弹窗显示五类与数量、汇总正确（截图 `build/v380_scope2.png`） |
| 选择性恢复点验 | 只勾「聊天记录 + 世界书」→「将恢复：聊天 1 · 世界书 0」→ 恢复完成（`build/v380_scope4.png`） |
| 结果核对（adb root 直接看应用目录） | `/data/data/com.alorith.litetavern/app_flutter/conversations/bk1.json` 出现（聊天的确写回）；`characters/` 下**没有** `bk1`（角色卡被跳过）；`groups/`、`worldbooks/` 未被改动 → 选择性恢复按预期生效；测试产生的 `bk1.json` 已删除 |
| 回归 | 单人/群聊、排版、导出、世界书、ST 兼容等原有测试全绿 |

## 已知边界

- 「设置」是一整类，不能只恢复其中几项（例如只恢复主题色）。
- 恢复仍是**覆盖**同名文件，不删除备份里没有的数据；没有「先备份当前数据再恢复」的自动保护。
- 恢复后需要重启 App 才能让全部数据生效（与之前一致）。
- 备份里的 API Key 是明文，导出时已提示只存到信任的地方。
- 其它沿用 v0.37.0 的边界（排版只管显示；发言名单按群保存；接着说不计命中率；
  费用是估算；每聊天覆盖只 6 键；ST 兼容模式是叠加不是替换；变量只读；卡内脚本不执行）。

## 环境与常用命令

```powershell
# Flutter（不在 PATH）
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release

# 模拟器（真机不在手边时；AVD 已建好）
C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio `
  -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556
adb -s emulator-5556 install -r build\app\outputs\flutter-apk\app-release.apk

# 模拟器是 google_apis（可 root）：核对应用私有目录
adb -s emulator-5556 root
adb -s emulator-5556 shell "ls -R /data/data/com.alorith.litetavern/app_flutter"

# mock 模型服务（写 build\mock_last.json 便于核对请求体）
python build\mock_llm.py    # 监听 127.0.0.1:8765，模拟器用 http://10.0.2.2:8765/v1

# 发布（GitHub Release 需要 token；上传地址直接拼 assets?name=）
# https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk
```

## 下一轮建议

`docs/FEATURE_AUDIT.md` 里 ✅ 已覆盖绝大部分本地功能，剩下的 ❌ 都是「明确不做 / 依赖外部服务」
（卡内脚本执行沙箱、HTML 整页画布、TTS / 语音输入、图像生成、向量记忆、Web 搜索、Live2D、STscript）。
下一轮候选：

- **聊天统计按模型拆分**：多套配置混用时，能看清各模型的 token 与花费。
- **自动更新增强**：支持「忽略这个版本」（现在只有「稍后」）、下载中断后续传提示。
- **恢复前自动快照**：恢复前先自动导出一份当前数据到缓存，误操作可退回。
- **排版继续打磨**：小说模式可选首行缩进 / 段落分隔线，或加第三种「视觉小说」样式。

## 本次运行记录（2026-11-28）

- analyze：No issues（10.4s）
- test：+547 全过（19s）
- build：61.1MB，versionCode 39 / 0.38.0
- 模拟器：`emulator-5556` 装机 Success（code 39）；导入自造备份 → 弹窗逐类勾选 → 只恢复聊天 →
  用 `adb root` 核对 `conversations/bk1.json` 已写回、`characters/bk1` 未写
- 未真机：真机不在手边，按计划走模拟器 + mock 服务
