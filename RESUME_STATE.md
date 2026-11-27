# 交接状态：v0.25.0 分支树与导出长图 / EPUB（2026-11-27 更新）

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
> v0.24.0（消息操作三件套、对话内搜索、功能评估清单）。
>
> **本轮 v0.25.0 —— 分支树 + 导出长图 / EPUB（评估清单 R2）**：
> 聊天菜单新增「分支树」，按层级列出同一角色下的所有聊天与分叉；
> 导出菜单从 文本 / JSON 扩成 文本 / JSON / **长图 .png** / **电子书 .epub** 四种。
> 长图用纯 Canvas 自绘（无新依赖），EPUB 用 archive 手写最小 EPUB3 包。

## 仓库状态

- 分支 `dev`，版本 `pubspec.yaml` = **0.25.0+26**，`lib/app_info.dart` `kAppVersion = '0.25.0'`。
- 本轮新增文件：
  - `lib/screens/chat_tree_screen.dart`：`ChatTreeScreen({ownerId, currentConvId})`，
    用 `ChatIndex.tree` 按深度缩进列出根与分支，点一行 `pop(ChatInfo)` 回去切换；
    副标题显示条数 / 时间 / 「从第 N 条分出」；空态提示怎么创建分支。
  - `lib/services/chat_image_export.dart`：`ChatImageExport.render(...)` 纯 Canvas 长图
    （先量高再开图，宽 1080，最大高 20000px，超长自动截断并标注；隐藏消息画「对模型隐藏」）。
  - `lib/services/chat_epub_export.dart`：`ChatEpubExport.build(...)` 生成 EPUB3
    （mimetype / container.xml / content.opf / nav.xhtml / style.css / chapter1.xhtml）。
  - `test/v25_test.dart`（15 例：分支字段、`ChatIndex.tree`、EPUB 解包校验、长图 PNG 魔数与高度、导出格式常量、落盘）。
- 本轮修改文件：
  - `lib/services/chat_index.dart`：`ChatInfo` 新增 `parentId` / `forkIndex` / `isBranch`，
    JSON 只在有值时写；`ChatIndex.touch` 新增可选 `parentId` / `forkIndex`；
    新增 `ChatIndex.tree(chats)` → `List<ChatTreeNode>`（根按最近使用排序、子分支紧跟、孤儿当根、环安全）。
  - `lib/services/chat_export_files.dart`：新增 `ChatExportFormat { text, json, image, epub }`
    （label / hint / extension / isBinary）、`buildBytes(...)`、`writeTempBytes(...)`；
    `shareChat(...)` 改为按 `format` 分派（文本走字符串、长图与 EPUB 走字节）。
  - `lib/screens/chat_screen.dart`：`_branchFrom` 写入 `parentId: _convId` 与 `forkIndex: index`；
    聊天菜单新增「分支树」→ `_openChatTree()`；`_exportChatFile()` 改为四选一（二进制格式先 toast「正在生成…」）。
  - `docs/FEATURE_AUDIT.md`：分支树页、长图/EPUB 标为 ✅，R2 标为已完成。
  - `CHANGELOG.md`：新增 v0.25.0 段；版本号两处同步。

## 验证

| 命令 | 结果 |
| --- | --- |
| `flutter analyze` | No issues found（7.0s） |
| `flutter test` | **+368 All tests passed!**（新增 15 例） |
| `flutter build apk --release` | 59.9 MB（62,759,695 字节，Gradle 54.2s）versionCode **26** / 0.25.0 |
| 真机装机 | 手机不在线（`192.168.0.100:39203` offline）；改用 Android 模拟器验证 |
| 模拟器装机 | `emulator-5556 install -r` → Success，versionName 0.25.0 / code 26 |

## 模拟器（无真机时的测试环境）

- SDK：`C:\Users\28351\Android\Sdk`；本轮新装 `emulator` + `system-images;android-34;google_apis;x86_64`，已接受全部 licenses。
- AVD：`litetavern_test`（pixel_6 / Android 14 / x86_64），启动：
  `C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -no-snapshot -port 5556`
- 端口 5556 → `adb -s emulator-5556 shell ...`；屏幕 1080x2400。
- 已验证：冷启动 → 6 步引导（1/6 正常）→ 跳过 → 主页 → 设置（六入口 + 帮助与关于；版本 v0.25.0）
  → 帮助子页（检查更新 / 自动检查 / 重看引导 / 关于）→ 从链接导入 Chub 卡成功 →
  聊天菜单出现「导出对话文件…（纯文本 / JSON / 长图 / EPUB）」与「分支树」→
  长图导出调起系统分享（Sharing image + 缩略图）→ EPUB 导出调起分享（Sharing 1 file）→
  分支树页显示根聊天「当前 · 0 条消息」。

## 已知边界

- 分支树只展示 `ChatIndex` 里有记录的聊天；父节点被删除的分支会当作根显示（不会丢）。
- 分支是「创建时的快照」，之后父子各写各的，不双向同步；重命名只改索引显示名。
- 长图：单张最大高 20000px，超出在图上标注条数；不含附件图片，只有文字。
- EPUB：最小 EPUB3（单章 + 目录 + 内联样式），archive 3.6 限制了 mimetype store 方式，主流阅读器可读。
- 导出二进制格式生成需 1–3 秒，期间 toast「正在生成…」，完成后弹系统分享。
- 「对模型隐藏」的消息不进 prompt，但长图/EPUB 仍会导出并标注。

## 下一轮建议（详见 `docs/FEATURE_AUDIT.md` 第 3 节）

R3：整库备份与恢复 zip（角色卡 / 聊天 / 世界书 / 预设 / 设置）；
R4：世界书整本导入导出 + 命中测试 + 四范围绑定；
R5：显示正则库 + 提示词检视升级；
R6：ST 预设兼容（先只读解析）；
R7：CHARX / jsonl 导入 + 体检报告；R8：变量与状态只读 + 卡脚本安全提示。

## 环境命令

```powershell
$env:FLUTTER_STORAGE_BASE_URL="https://storage.flutter-io.cn"
& C:\flutter\bin\flutter.bat analyze
& C:\flutter\bin\flutter.bat test
& C:\flutter\bin\flutter.bat build apk --release
# 真机（USB 或无线调试地址会变）
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe devices
& C:\Users\28351\Android\Sdk\platform-tools\adb.exe -s <serial> install -r build\app\outputs\flutter-apk\app-release.apk
# 模拟器
& C:\Users\28351\Android\Sdk\emulator\emulator.exe -avd litetavern_test -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect -port 5556
```

发 Release 时 APK 上传地址直接拼
`https://uploads.github.com/repos/Alorith-H/LiteTavern/releases/<id>/assets?name=app-release.apk`；
token 用 `git credential fill` 取；含中文的脚本保存为 UTF-8 并用 `pwsh -File` 执行。
提交一律使用仓库配置身份，**不要**再传 `-c user.name/-c user.email`。

## 本次运行记录

- `flutter analyze`：No issues found（7.0s）
- `flutter test`：+368 All tests passed!
- `flutter build apk --release`：59.9 MB，versionCode 26 / versionName 0.25.0
- 真机：不在线（未装机）
- 模拟器：Success（0.25.0 / code 26），导出长图/EPUB、分支树、引导、设置、导入均逐项点过
