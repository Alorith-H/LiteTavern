# 交接状态：v0.36.0 群聊主持（2026-11-27 更新）

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
> v0.36.0（群聊主持：发言名单与顺序、让大家接着说）。
>
> **本轮 v0.36.0 —— 评估清单「群聊主持」**：
> 1. **发言名单**：群聊页 ⋮ →「群聊主持」，勾选/取消成员，还可以上移下移决定轮转顺序；
>    名单为空 = 全员轮流（原来的行为）。名单按群保存（同一角色的多段聊天共用）。
> 2. **轮转只在名单内**：发一条消息后按名单顺序轮流发言；`@名字` 点名仍然优先，
>    但只会叫到名单里的角色；指针（`turnIndex`）依然跨轮保存。
> 3. **让大家接着说**：群聊页 ⋮ →「让大家接着说」，不插用户消息，直接让名单里的角色
>    顺着当前剧情再聊一轮。这条「继续」提示只作为最后一条 user 消息发给模型
>    （`PromptBuilder.buildGroup(hostNudge:)`），不会出现在聊天记录里。
> 4. **边界**：接着说这一轮不计命中率；不能通过取消勾选得到空名单（空名单语义是全员），
>    只有一个发言人时会提示「至少留一位发言人」；中途那一轮说一半停下，指针停在说过的下一位。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.36.0+37**，`lib/app_info.dart` `kAppVersion = '0.36.0'`。
- 本轮新增文件：
  - `lib/screens/group_host_screen.dart`：`GroupHostScreen({required group, required members, onChanged})`。
    顶部说明会随名单状态变化（全员 / 「只让名单里的 N 位角色发言」）；成员行 = Checkbox +
    序号 + 名字 + 一句话简介 + 上移/下移；未进名单的成员排在后面（方便勾回来）；
    底部「恢复全员轮流」；每次勾选/排序都即时 `onChanged(ChatGroup)` 回调给聊天页落盘。
  - `test/v36_test.dart`：18 例（`speakerIds` json 往返/空不写/`speakerIndexes` 过滤去重、
    `hostedTurnOrder` 5 例、`advanceHostTurn` 3 例、`buildGroup(hostNudge:)` 3 例、
    `GroupHostScreen` widget 3 例）。
- 本轮修改：
  - `lib/models/chat_group.dart`：`ChatGroup` 新增 `speakerIds`（空 = 全员）+ `withSpeakerIds` +
    `speakerIndexes()`；`fromJson`/`toJson` 处理（空不写）；新增顶层
    `hostedTurnOrder(memberCount, roster, turnIndex, mentioned)` 与
    `advanceHostTurn(memberCount, roster, spokenIndex)`；原有 `turnOrder`/`advanceTurn` 保留。
  - `lib/services/prompt_builder.dart`：`buildGroup` 新增可选 `String? hostNudge`，
    在所有注入之后追加一条 `role: 'user'` 的临时提示（走宏替换，不落库）。
  - `lib/screens/chat_screen.dart`：`_doSend` 群聊分支改用 `hostedTurnOrder`（名单外成员不会被选到）；
    `_runGroupRound` 用 `advanceHostTurn` 推进指针；新增 `_hostRoster()`、`_openGroupHost()`、
    `_continueGroupRound()`、`_continuationNudge` 与 `_kGroupContinueNudge`；`buildGroup` 调用传
    `hostNudge`；聊天菜单（仅群聊）新增「群聊主持」「让大家接着说」两个入口。
  - `CHANGELOG.md`（v0.36.0 段）、`docs/FEATURE_AUDIT.md`（群聊主持行 ✅；
    顺带把 SillyTavern 预设行从 🟡 更正为 ✅：v0.30 只读解析 + v0.31 兼容模式已全部落地）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（4.2s） |
| `flutter test` | **+529 All tests passed!**（16s，含新增 18 例） |
| `flutter build apk --release` | **61.1MB**，versionCode **37** / versionName **0.36.0** |
| 模拟器装机 | `adb -s emulator-5556 install -r` → Success（code 37 / 0.36.0） |
| 模拟器点验 | 新建群聊（3 位成员）→ ⋮「群聊主持」显示 1/2/3 名单与上下移 → 取消勾选第一位后文案变「只让名单里的 2 位角色发言」；截图 `build/v360_host.png`、`v360_host2.png` |
| 接着说的端到端 | ⋮「让大家接着说」→ 未插用户消息，直接生成 2 条（名单里的 CHARX 测试角色 + 恢复测试角色，未被勾选的成员没说话）→ `build/v360_continue.png`；`build/mock_last.json` 里确认请求最后一条正是「（没有新的用户发言…）」的 user 提示，且 `top_k 40 / temperature 1.1` 等沿用 |
| 回归 | 单人聊天、建议回复、摘要、导出等原有测试全绿 |

## 已知边界

- 发言名单按**群**保存，同一角色在这个群里的多段聊天共用一份名单；不支持「每段聊天单独一份名单」。
- 名单为空代表全员轮流，因此没有「一个人都不发言」的状态；只剩一人时会出现连续同角色回合。
- 「让大家接着说」不会给用户留一条消息，所以「重试」只能重试最后一条助手消息；
  中途停止后指针已推进到下一位（和正常一轮一致，不回退）。
- 其它沿用 v0.35.0 的边界（费用只是估算；每聊天覆盖只 6 键；ST 兼容模式是叠加不是替换；
  变量只读不写回；卡内脚本永不执行；必应网页接口受 IP 风控会自动换源）。

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

# mock 模型服务（写 build\mock_last.json 便于核对请求体）
python build\mock_llm.py    # 监听 127.0.0.1:8765，模拟器用 http://10.0.2.2:8765/v1

# 发布（GitHub Release 需要 token；上传地址直接拼 assets?name=）
# https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk
```

## 下一轮建议

`docs/FEATURE_AUDIT.md` 里 R1–R8 已全部完成，剩下的 ❌ 都是「明确不做 / 依赖外部服务」的项
（卡内脚本执行沙箱、HTML 整页画布、TTS / 语音输入、图像生成、向量记忆、Web 搜索、Live2D、STscript）。
下一轮可以转做小而实用的体验项，候选：

- **备份恢复可选内容**：现在整包恢复会覆盖所有数据，可加「只恢复聊天 / 只恢复设置 / 只恢复角色卡」。
- **聊天统计按模型拆分**：多套配置混用时，能看清各模型的 token 与花费。
- **自动更新增强**：支持「忽略这个版本」（现在只有「稍后」）、下载中断后从已下载部分续传提示。
- **导入体检报告接入备份恢复**：恢复前先给一份「会覆盖哪些数据」的体检，和导入卡一致。

## 本次运行记录（2026-11-27）

- analyze：No issues（4.2s）
- test：+529 全过（16s）
- build：61.1MB，versionCode 37 / 0.36.0
- 模拟器：`emulator-5556` 装机 Success（code 37），点验群聊主持页与「让大家接着说」
- 未真机：真机不在手边，按计划走模拟器 + mock 服务
