# 交接状态：v0.24.0 消息操作与对话内搜索（2026-11-27 更新）

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
> v0.23.0（应用内自动更新）。
>
> **本轮 v0.24.0 —— 消息操作与对话内搜索（功能评估计划的第一批）**：
> 长按消息可以「对模型隐藏 / 删除这一条 / 删除这条及以后」；聊天菜单新增「搜索对话」，
> 输入关键词实时匹配并跳回那条消息。同时新增 `docs/FEATURE_AUDIT.md`，
> 把「已实现 / 部分实现 / 未实现」的功能逐项列清楚，作为后续实现的总清单。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.24.0+25**，`lib/app_info.dart` `kAppVersion = '0.24.0'`。
- 本轮新增文件：
  - `lib/services/chat_transcript.dart`：`visibleForModel(messages)`（过滤 `hidden`）、
    `ChatSearchHit`、`searchMessages(messages, query, {max, snippetRadius})`、
    `snippetAround(text, matchStart, matchLength, {radius})`。纯函数、无 UI/存储依赖。
  - `lib/widgets/chat_search_sheet.dart`：`showChatSearchSheet(context, {messages, assistantName})`
    → 返回被点中的消息下标；`ChatSearchSheet` 实时搜索、显示发言方/时间/片段/隐藏标记。
  - `docs/FEATURE_AUDIT.md`：功能评估 + 未实现清单 + 分轮实施与验收表。
  - `test/v24_test.dart`（18 例）。
- 本轮修改文件：
  - `lib/models/chat_message.dart`：新增 `hidden`（默认 false；JSON `hidden: true`；旧数据缺字段回落 false；
    `copyWith` 支持切换）。
  - `lib/screens/chat_screen.dart`：
    - `_buildWith()` 组 prompt 前统一 `visibleForModel(history)`（占用估算/压缩同口径）；
    - `_showMessageActions()` 改为限高可滚动，新增「对模型隐藏 / 取消隐藏」「删除这一条」「删除这条及以后」；
    - 新增 `_toggleHidden` / `_deleteMessage` / `_deleteMessagesFrom` / `_confirmDelete` / `_showSearch`；
    - 隐藏消息气泡 `Opacity(0.45)` + 「对模型隐藏」小字标注；
    - 聊天菜单新增「搜索对话」（结果跳转复用 `_jumpToMessage`）。
  - `CHANGELOG.md`：新增 v0.24.0 段。
  - `pubspec.yaml` / `lib/app_info.dart`：版本号 0.24.0+25。

## 验证

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found |
| `flutter test` | **+353 All tests passed!**（新增 18 例） |
| `flutter build apk --release` | 见本次运行记录 |
| 真机装机 | 见本次运行记录 |

## 下一轮建议（详见 `docs/FEATURE_AUDIT.md` 第 3 节）

R2：分支树页 + 导出长图 / EPUB；R3：整库备份与恢复 zip；R4：世界书整本导入导出 + 命中测试 + 四范围绑定；
R5：显示正则库 + 检视升级；R6：ST 预设兼容（先只读解析）；R7：CHARX / jsonl 导入 + 体检报告；
R8：变量与状态只读 + 卡脚本安全提示。

## 已知边界

- 「对模型隐藏」只影响组 prompt；本地展示、导出、搜索、备份都保留该消息。
- 删除不可恢复，没有回收站（以后可随「整库备份」一起解决）。
- 搜索是本地子串匹配（大小写不敏感），不做分词/模糊匹配。
- 分支仍是快照式（不双向同步）；聊天列表按保存时间排序。
- 单聊新建聊天会写入开场白，群聊新聊天是空的。
- 删除角色/群聊会级联清理所有分段聊天、书签、后台任务。
- GitHub API 限流 60 次/小时（自动更新每天最多一次）。
- 真机点按坐标与 uiautomator bounds 常不一致，验证以截图为准。

## 环境

- Flutter：`C:\flutter\bin\flutter.bat`（不在 PATH），命令前设
  `$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`。
- adb：`C:\Users\28351\Android\Sdk\platform-tools\adb.exe`；USB 设备序列号 `19faf100`（23113RKC6C / Android 16），
  无线调试地址每次可能不同，先 `adb devices`；装入：`adb -s <设备> install -r build\app\outputs\flutter-apk\app-release.apk`。
- 提交：直接用仓库配置身份（`Alorith-H <2835147611@qq.com>`），**不要**再加 `-c user.name/-c user.email`。

## 本次运行记录

- `flutter analyze`：No issues found
- `flutter test`：+353 All tests passed!
- `flutter build apk --release`：59.4 MB，versionCode 25 / versionName 0.24.0（Gradle 103.7s 首次含新依赖，本次增量正常）
- 真机装机：`adb -s 192.168.0.100:39203 install -r` → Success（0.24.0 / code 25），真机实测隐藏/取消隐藏、消息菜单、上下文占比变化均正常
