# 交接状态：v0.12.0 市场筛选 + 三候选回复（2026-11-18 更新）

> 历史：v0.9.0（两级设置 + 真实采样参数 + 胶囊按钮）、v0.10.0（后台生成不中断）、
> v0.11.0（角色卡市场）均已落地并通过验证。
> **本轮 v0.12.0**：① 角色卡市场加筛选/排序；② 设置新增「自动生成回复」开关，
> 开启后单聊每次先生成 3 个候选、由用户挑一条采用。analyze 清零、测试 145 条全过、
> release APK 构建成功并已装机（真机 `23113RKC6C`，Android 16）。

## 仓库状态

- 分支 `dev`，远端 `origin = https://github.com/Alorith-H/LiteTavern.git`
- 上一版 commit `ed5a06c`（v0.11.0 docs），本轮改动见 `git log -1`
- `pubspec.yaml:5` → `version: 0.12.0+3`；`lib/app_info.dart` → `kAppVersion = '0.12.0'`
  （`test/version_test.dart` 校验两者一致，防漂移）
- 产物：`build\app\outputs\flutter-apk\app-release.apk`（57.8 MB，
  `build\app\outputs\apk\release\output-metadata.json` versionCode 3 / versionName 0.12.0）
- 已装机：`adb install -r` → Success；`dumpsys package com.alorith.litetavern` 显示
  versionCode=3 / versionName=0.12.0；`am start` 正常启动

## v0.12.0 功能一：角色卡市场筛选

- 入口不变：主页 FAB「导入」→「角色卡市场」→ 搜索框下方新增**横向筛选行**
- 排序 ChoiceChip：**相关**（默认，不传 `sort`）/ **热门**（`sort=star_count`）/
  **新上架**（`sort=created_at`）；空关键词时仍兜底热门，保证「浏览」不回归
- 「标签」对话框：英文/中文逗号分隔、去空去重、最多 3 个（服务端多标签为 **AND**）；
  chip 回显「标签：Fantasy+OC」
- 「长度」底部弹窗：不限 / 短（<1k tokens）/ 中（1k–3k）/ 长（>3k）→
  `min_tokens` / `max_tokens`（只发 >0 的值）
- 任一筛选变化 → 页码回 1 重载，沿用 `_seq` 竞态代次；有筛选时右侧出现「清除」；
  空结果文案区分「无筛选空」与「筛选条件下无结果」
- 代码：`lib/services/card_market.dart` 新增值对象 `MarketFilters`
  （`sort` / `topics` / `minTokens` / `maxTokens`、`none`、`isEmpty`、`parseTopics`、
  `copyWith` 用 `_unset` 哨兵支持清空、`==`/`hashCode`），`searchUri` 与 `search`
  增加 `MarketFilters filters = MarketFilters.none` 默认参数（旧调用零改动）；
  `lib/screens/card_market_screen.dart` 加筛选行/两个弹窗/清除；
  `test/card_market_test.dart` 10 → 22 例（全离线 MockClient）

## v0.12.0 功能二：「自动生成回复」三候选

- 设置：`设置 → 生成参数`，在「流式传输」下方新增 **自动生成回复** 开关（默认关），
  副标题「单聊生效：每次先生成 3 个候选，由你挑一条采用」；
  持久化键 `auto_reply_candidates`（`storage.dart` `AppSettings.autoReplyCandidates`）
- 行为：开关打开后，单聊发送消息 → 并行发出 **3 个非流式请求**（同一 prompt 与采样
  参数；seed 非空时按 `seed + 0/1/2` 偏移，见 `SamplingParams.forCandidate`）→
  命中任一条即弹底部选择器「选择一条回复」，点卡片采用，关闭则不写入
  （占位气泡标错「未选择候选回复」，可点重试）
- 采用后：占位消息正文 = 所选候选；3 条候选写入 `variants`、`variantIndex` = 选中下标，
  可横滑查看；token 按 3 条实际花销合计记账
- 选择器支持 **「换一批」**（再取 3 条，失败显示错误并保留原候选）；
  部分请求失败时只用成功的（1–2 条也能选）；全失败 → 占位标错可重试
- 停止：`_stop` 会 cancel 这 3 条候选请求；离开页面即取消本次候选
  （页面私有请求，不走 `ActiveGenerations` —— 同 key 单任务模型装不下并行候选）
- 代码：新增 `lib/widgets/reply_candidates_sheet.dart`（约 300 行选择器）、
  `test/v12_test.dart`（9 例：`forCandidate` 偏移、设置持久化、选择器 widget 行为）；
  `chat_screen.dart` 新增 `_runSingleReply` / `_generateCandidatesSingle` /
  `_fetchCandidates` / `_fetchOneCandidate` / `_applyCandidateChoice` 等方法
  （每个候选独立 `ApiClient`，共用会互相 cancel）

## 验证结果（本机实测，2026-11-18）

| 项目 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze` | **No issues found!** |
| 单元/组件测试 | `flutter test` | **+145 All tests passed!**（v0.12.0 新增 21 例） |
| Release 构建 | `flutter build apk --release` | **成功**，57.8 MB，48.7s |
| 装机 | `adb install -r` | **Success**，真机 versionName 0.12.0 / code 3 |

构建仅有两类非阻塞警告：`share_plus` 使用 KGP（未来 Flutter 会拒绝，届时升级插件）；
NDK 版本不匹配（`android/app/build.gradle.kts:19` 写 27.0.12077973，插件建议
28.2.13676358，但不影响构建；要消除就改这行并确保对应 NDK 已安装）。

## 真机自测建议（本轮已装机，未逐项手测）

1. 市场筛选：进入市场 → 点「热门」「新上架」看结果变化 → 「标签」输 `Fantasy,OC`
   → 「长度：中」→ 观察结果收窄、chip 回显、清除恢复
2. 三候选：设置打开「自动生成回复」→ 回聊天发一条 → 应弹 3 条候选 →
   点一条采用，气泡出现该回复；重发一次点「换一批」；关闭选择器看错误提示与重试
3. 停止：候选生成中点停止按钮，应立刻取消且不写正文
4. 回归：关闭该开关 → 手动写回复回到流式；群聊轮转不受影响；「继续生成」仍流式追加

## 已知边界（有意保留，不阻塞发布）

- **候选模式不走后台管理器**：候选生成期间离开会话页会取消本次候选（普通流式回复
  仍可在后台完成落库）；群聊轮转与「继续生成」永远走流式，不受该开关影响
- **候选模式 token 消耗 ×3**：一次发送发出 3 个完整回复请求（预期行为，设置副标题已提示）
- **S3 自动继续不跨页面**（v0.10 遗留）：离开页面后完成的消息会落库，但自动继续
  /群聊轮转的后续链条不续跑
- **S4 创建器「生成角色卡」仍是页面私有请求**：中途退出会取消该请求（访谈主流程已接入）
- **S5/S6 纯 UI 细节**：预设名显示在分区标题下；top_k/stop 超范围时存裁剪值、框内文本不回写
- **B2/B3 低风险竞态**：停止后立刻重生成时旧任务收尾写盘可能交错（`chat_message.dart`
  的 fromJson 有自愈）；后台落库只写 content/error
- **市场筛选行在窄屏可能需横滑**：标签/长度文案变长后「清除」在 430dp 视口外

## 环境

- Flutter 3.47.6 stable：`C:\flutter\bin\flutter.bat`（不在 PATH；`dart` 同样不在）
- 跑任何 flutter 命令前设：`$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"`
- Android SDK：`C:/Users/28351/Android/Sdk`；adb 绝对路径
  `C:\Users\28351\Android\Sdk\platform-tools\adb.exe`（不在 PATH）
- 测试真机：`23113RKC6C`（Android 16 / API 36，arm64），USB 连接
- 角色卡来源与合规说明：`docs/card_market_sources.md`
