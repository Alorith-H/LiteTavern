# 交接状态：v0.37.0 对话排版（气泡 / 小说）（2026-11-27 更新）

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
> v0.37.0（对话排版：气泡 / 小说）。
>
> **本轮 v0.37.0 —— 评估清单之外的体验项「对话排版」**：
> 1. **两种排版**：设置 → 聊天与上下文 → 显示 →「对话排版」，可选 **气泡**（默认，
>    左右分栏）或 **小说**（不分栏、无气泡底色，像读一段小说；你的话左侧一条细线 + 「你」）。
> 2. **只改显示**：聊天记录、发给模型的提示词、导出内容都不变；随时切回来。
> 3. **交互照旧**：长按菜单、变体横滑、书签、对模型隐藏、显示正则、字号、时间戳都正常。
> 4. **边界**：小说模式每段都会标发言者（单聊用角色名、群聊用发言者名字；你的话标「你」），
>    因此同一角色连续两条会各带一次名字——这是有意的分段感，不做首条省略。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.37.0+38**，`lib/app_info.dart` `kAppVersion = '0.37.0'`。
- 本轮新增文件：
  - `lib/services/chat_layout.dart`：`enum ChatLayout { bubble, novel }` +
    `extension ChatLayoutLabel`（`label` / `description` / `id`）+ `chatLayoutFromId` +
    `MessageLayoutStyle`（`bubble` / `alignRight` / `maxWidthFactor` / 内边距 / 行距 /
    `showSenderLabel` / `userAccentBar`）与 `MessageLayoutStyle.of(layout, isUser:)`。
  - `test/v37_test.dart`：9 例（解析与文案、两种模式 × 用户/角色的样式数值、
    `AppSettings.chatLayout` 默认值 / 落键 `chat_layout` / 无键回落、设置页切换后落盘）。
- 本轮修改：
  - `lib/services/storage.dart`：新增 `chatLayout` getter/setter（`_kChatLayout = 'chat_layout'`，
    存 `bubble` / `novel`；未知值回落气泡）。
  - `lib/screens/chat_screen.dart`：`_buildMessage` 按 `MessageLayoutStyle` 渲染——
    气泡模式保持原样；小说模式去掉气泡底色/描边，整行宽度、小内边距、段落间距更大，
    你的那段加左侧 3px 细线；名字标签改为 `_senderLabelOf(m)`
    （群聊取 `senderName`、单聊取角色名），小说模式给每段都标、气泡模式仍只在群聊标。
  - `lib/screens/settings_screen.dart`：「显示」分节新增「对话排版」行（副标题显示当前模式），
    点开底部弹层二选一（气泡 / 小说），选择即落盘并刷新；新增 `_openChatLayout()`。
  - `CHANGELOG.md`（v0.37.0 段）、`docs/FEATURE_AUDIT.md`（对话组新增「对话排版」行 ✅）、本文件。

## 验证表（本轮）

| 项目 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found!（13.1s） |
| `flutter test` | **+538 All tests passed!**（26s，含新增 9 例） |
| `flutter build apk --release` | **61.1MB**，versionCode **38** / versionName **0.37.0** |
| 模拟器装机 | `adb -s emulator-5556 install -r` → Success（code 38 / 0.37.0） |
| 气泡模式点验 | 打开「变量测试角色」→ 左右分栏气泡（截图 `build/v370_bubble.png`） |
| 小说模式点验 | 设置切到「小说」→ 回到聊天：无气泡、整行段落、每段带角色名（`build/v370_novel.png`）；发一句 `hi` → 你的话带「你」+ 左侧细线，角色回复照常带 token/模型行（`build/v370_novel_user2.png`） |
| 回归 | 单人/群聊、建议回复、摘要、导出、世界书等原有测试全绿 |

## 已知边界

- 小说模式下，同一角色连续两条会各标一次名字（有意的分段感）。
- 排版按**全局**设置，不支持「这段聊天用气泡、那段用小说」。
- 只影响显示：不改提示词、不改导出、不改备份内容。
- 其它沿用 v0.36.0 的边界（发言名单按群保存；接着说不计命中率；费用只是估算；
  每聊天覆盖只 6 键；ST 兼容模式是叠加不是替换；变量只读不写回；卡内脚本永不执行；
  必应网页接口受 IP 风控会自动换源）。

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

`docs/FEATURE_AUDIT.md` 里 ✅ 已覆盖绝大部分本地功能，剩下的 ❌ 都是「明确不做 / 依赖外部服务」
（卡内脚本执行沙箱、HTML 整页画布、TTS / 语音输入、图像生成、向量记忆、Web 搜索、Live2D、STscript）。
下一轮可以继续做小而实用的体验项：

- **备份恢复可选内容**：现在整包恢复会覆盖所有数据，可加「只恢复聊天 / 只恢复设置 / 只恢复角色卡」。
- **聊天统计按模型拆分**：多套配置混用时，能看清各模型的 token 与花费。
- **自动更新增强**：支持「忽略这个版本」（现在只有「稍后」）、下载中断后的续传提示。
- **排版继续打磨**：小说模式可选首行缩进 / 段落分隔线，或加第三种「视觉小说」样式。

## 本次运行记录（2026-11-27）

- analyze：No issues（13.1s）
- test：+538 全过（26s）
- build：61.1MB，versionCode 38 / 0.37.0
- 模拟器：`emulator-5556` 装机 Success（code 38），点验气泡 / 小说两种排版与发表消息
- 未真机：真机不在手边，按计划走模拟器 + mock 服务
